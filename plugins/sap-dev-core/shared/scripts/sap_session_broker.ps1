# =============================================================================
# sap_session_broker.ps1
# -----------------------------------------------------------------------------
# Cross-process broker for SAP GUI session ownership. Multi-connection aware
# from Phase 3.5 onwards -- the registry tracks every attached SAP connection
# (different SID, different client, different user logon) separately, and
# every acquire call must specify which connection it wants (or use the
# single-connection auto-resolve).
#
# Contract -- what the broker promises:
#   * Mutual exclusion: at any instant, at most one task_id holds a "claimed"
#     entry for any given session path.
#   * Reactive cleanup + identity reconciliation: every acquire/release/
#     discover/gc call mirrors live SAP identity onto each connection block
#     (live is source of truth) and drops entries that no longer reflect
#     reality (session window closed, owner process died, TTL expired,
#     relogin). A reused /app/con[N] slot now hosting a DIFFERENT system is
#     detected by the (system,client,user) identity tuple -- NOT by
#     SystemSessionId, which on the kernels we run is per-workstation, not
#     per-logon, and stays identical across an A->B swap on one slot.
#   * Spawn-on-demand: if no free session exists on the target connection,
#     the broker spawns one via /oSESSION_MANAGER (the only OK-code reliably
#     honoured on the S/4HANA 1909 kernel 754 build verified during design).
#   * Connection isolation: a claim against /app/con[1] never returns a
#     /app/con[0] path. The acquire-time resolution refuses to default
#     across connections when ambiguous.
#
# Contract -- what the broker does NOT promise (by design):
#   * Path stability across re-acquires. SAP's (path, SessionNumber) tuple
#     is recyclable on this kernel, so we cannot prove "today's path is
#     yesterday's session". Callers that need continuity hold the claim
#     open across all sub-calls.
#   * Allocation of user-owned sessions. Sessions discovered mid-work
#     (non-Easy-Access) are tracked as "user_owned" and never handed out.
#   * Recovery if the user manually closes a session mid-task. The next
#     findById in the consumer's VBS will fail; the consumer must report
#     the failure cleanly. The broker drops the entry on the next sweep.
#
# Cross-process locking: a Windows named mutex `SapDevSessionBroker_v2`
# (bumped from v1 because the registry schema is incompatible with the
# pre-3.5 shape -- a v1 broker and a v2 broker MUST NOT both run; v2
# rejects v1's flat-entries registry by recognising the missing
# `connections` field and rebuilding fresh).
#
# Usage -- see shared/rules/sap_session_broker.md for the full contract.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('acquire', 'release', 'gc', 'list', 'discover',
                 'stuck', 'pin', 'unpin', 'set-connection-id')]
    [string] $Action,

    [Parameter(Mandatory = $true)]
    [string] $WorkTemp,

    # Optional override for the directory holding session_registry.json.
    # Default: $(Split-Path $WorkTemp -Parent)\runtime  (i.e. sibling of
    # {work_dir}\temp). This keeps existing callers working -- they all
    # pass `-WorkTemp {work_dir}\temp` and the registry now auto-relocates
    # to {work_dir}\runtime\session_registry.json. Callers that want a
    # custom location pass -WorkRuntime explicitly.
    [string] $WorkRuntime = '',

    [string] $TaskId       = '',
    [string] $AiSessionId  = '',   # NEW (Phase 4): AI-session pin scope.
    [string] $OwnerSkill   = '',
    [int]    $TtlSeconds   = 600,
    [int]    $OwnerPid     = 0,

    # Connection-targeting filters (acquire). Resolution order:
    #   1. -SessionPath /app/con[N]/ses[M]   -- explicit; derives connection.
    #   2. -ConnectionPath /app/con[N]       -- pick this connection.
    #   3. -SystemName + -Client + -User     -- find matching connection by
    #                                          GuiSession.Info tuple.
    #   4. -PinFile <path>                   -- read pin file; honour its
    #                                          session_path if non-empty,
    #                                          else its (system,client,user).
    #   5. AI-session pin                    -- ai_sessions[$AiSessionId]
    #                                          .connection_id -> match a live
    #                                          connection with same id.
    #   6. Exactly 1 connection attached     -- silent default.
    #   7. Else                              -- DENIED: ambiguous.
    [string] $SessionPath    = '',
    [string] $ConnectionPath = '',
    [string] $SystemName     = '',
    [string] $Client         = '',
    [string] $User           = '',
    [string] $PinFile        = '',

    # Stuck-screen markers (Action=stuck).
    [string] $Program        = '',
    [string] $Screen         = '',

    # Release semantics. When set on `release`, the broker calls CLOSE
    # (drop the session) on the COM helper instead of RESET (/n to Easy
    # Access). Used when the skill spawned the session itself and wants
    # to clean up after.
    [switch] $WasCreated,

    # `pin` / `unpin` / `set-connection-id` args.
    [string] $ConnectionId   = '',   # opaque profile UUID; pin scope.
    [string] $PinReason      = '',
    [switch] $ForceUnpin             # `acquire`: bypass pin enforcement.
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# Phase 4: move session_registry.json from {work_dir}\temp\ to
# {work_dir}\runtime\ so it survives `sap-dev-clean` temp wipes. Callers
# pass -WorkTemp as today; we derive the runtime dir from it.
if ([string]::IsNullOrWhiteSpace($WorkRuntime)) {
    $WorkRuntime = Join-Path (Split-Path -Parent $WorkTemp) 'runtime'
}
if (-not (Test-Path $WorkRuntime)) {
    New-Item -ItemType Directory -Path $WorkRuntime -Force | Out-Null
}

$script:WorkTempDir    = $WorkTemp
$script:WorkRuntimeDir = $WorkRuntime
$script:RegistryFile   = Join-Path $WorkRuntime 'session_registry.json'
$script:LegacyRegistryFile = Join-Path $WorkTemp 'session_registry.json'  # pre-Phase-4 location
$script:MutexName      = 'SapDevSessionBroker_v2'   # bumped from v1 in Phase 3.5
$script:MutexTimeout   = 10000

$script:ComHelperVbs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'sap_session_broker_com.vbs'
$script:Cscript      = 'C:\Windows\SysWOW64\cscript.exe'

if (-not (Test-Path $WorkTemp)) {
    New-Item -ItemType Directory -Path $WorkTemp -Force | Out-Null
}

# Phase 4.1: dot-source sap_connection_lib.ps1 for Get-SapAiSessionId.
# The lib has no top-level param() block so it cannot clobber our params.
# It dot-sources sap_settings_lib.ps1 lazily inside Get-SapWorkDir (also
# param-block-free), so the broker's own param block is safe.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'sap_connection_lib.ps1')

# Resolve AiSessionId once for this broker invocation. If the caller
# (sap_login_select.ps1 etc.) passed -AiSessionId explicitly, honour it.
# Otherwise walk the parent-process tree to find this Claude Code
# conversation's owner PID and look up its id. Subagents within one
# conversation converge on the same id; parallel conversations diverge.
if ([string]::IsNullOrWhiteSpace($AiSessionId)) {
    try { $AiSessionId = Get-SapAiSessionId -RuntimeDir $WorkRuntime }
    catch { $AiSessionId = '' }   # non-fatal -- actions that need it will fail loud later
}

# Per-invocation cache for SAP state.
$script:CachedInfo = $null

# ===========================================================================
# Mutex helpers
# ===========================================================================

function With-RegistryLock {
    param([scriptblock] $Body)
    $mutex = [System.Threading.Mutex]::new($false, $script:MutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($script:MutexTimeout)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "could not acquire registry mutex within $($script:MutexTimeout)ms"
        }
        & $Body
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        try { $mutex.Dispose() } catch {}
    }
}

# ===========================================================================
# Registry I/O (multi-connection schema)
# ===========================================================================

function New-EmptyRegistry {
    return @{ updated_at = ''; ai_sessions = @{}; connections = @() }
}

function Read-Registry {
    # Phase 4: prefer the new runtime location, but auto-migrate a v3
    # registry that's still sitting in the legacy temp folder.
    $registryPath = $script:RegistryFile
    if (-not (Test-Path $registryPath) -and (Test-Path $script:LegacyRegistryFile)) {
        try {
            Move-Item -Path $script:LegacyRegistryFile -Destination $registryPath -ErrorAction Stop
            Write-Host "INFO: migrated session_registry.json from $($script:LegacyRegistryFile) to $registryPath"
        } catch {
            # Couldn't move -- keep using the new path (empty) and let the
            # next discover rebuild from live state.
            Write-Host "WARN: could not migrate legacy session_registry.json: $($_.Exception.Message)"
        }
    }
    if (-not (Test-Path $registryPath)) {
        return New-EmptyRegistry
    }
    try {
        $raw = Get-Content -Path $registryPath -Raw -Encoding UTF8
        if (-not $raw -or $raw.Trim() -eq '') { return New-EmptyRegistry }
        $obj = $raw | ConvertFrom-Json

        # Detect v1 (flat-entries) shape and reject it. Forward-compat: a v1
        # registry has top-level "entries"; v2/v3 has "connections".
        if ($obj.PSObject.Properties['entries'] -and -not $obj.PSObject.Properties['connections']) {
            Write-Host 'WARN: v1 registry detected; rebuilding under v3 schema'
            return New-EmptyRegistry
        }

        $reg = New-EmptyRegistry
        $reg.updated_at = "$($obj.updated_at)"

        # ai_sessions map (Phase 4). May not exist on v2 registries.
        if ($obj.PSObject.Properties['ai_sessions'] -and $obj.ai_sessions) {
            foreach ($p in $obj.ai_sessions.PSObject.Properties) {
                $v = $p.Value
                $reg.ai_sessions[$p.Name] = @{
                    connection_id = "$($v.connection_id)"
                    pinned_at     = "$($v.pinned_at)"
                    pin_reason    = "$($v.pin_reason)"
                    last_seen_at  = "$($v.last_seen_at)"
                }
            }
        }

        if ($obj.connections) {
            foreach ($c in $obj.connections) {
                $conBlock = @{
                    connection_path    = "$($c.connection_path)"
                    connection_id      = "$($c.connection_id)"
                    system_name        = "$($c.system_name)"
                    client             = "$($c.client)"
                    user               = "$($c.user)"
                    language           = "$($c.language)"
                    description        = "$($c.description)"
                    logon_id           = "$($c.logon_id)"
                    message_server     = "$($c.message_server)"
                    logon_group        = "$($c.logon_group)"
                    system_id          = "$($c.system_id)"
                    application_server = "$($c.application_server)"
                    system_number      = "$($c.system_number)"
                    entries            = @()
                }
                if ($c.entries) {
                    foreach ($e in $c.entries) {
                        $conBlock.entries += @{
                            path           = "$($e.path)"
                            session_number = if ($e.session_number) { [int]$e.session_number } else { 0 }
                            task_id        = "$($e.task_id)"
                            ai_session_id  = "$($e.ai_session_id)"
                            owner_pid      = if ($e.owner_pid) { [int]$e.owner_pid } else { 0 }
                            owner_skill    = "$($e.owner_skill)"
                            status         = "$($e.status)"
                            claim_time     = "$($e.claim_time)"
                            ttl_seconds    = if ($e.ttl_seconds) { [int]$e.ttl_seconds } else { 600 }
                            discovered     = [bool]$e.discovered
                            stuck_program  = "$($e.stuck_program)"
                            stuck_screen   = "$($e.stuck_screen)"
                            was_created    = [bool]$e.was_created
                        }
                    }
                }
                $reg.connections += $conBlock
            }
        }
        return $reg
    } catch {
        Write-Host "WARN: registry file unreadable ($($_.Exception.Message)); resetting"
        return New-EmptyRegistry
    }
}

function Write-Registry {
    param([hashtable] $Registry)
    $Registry.updated_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $json = $Registry | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText(
        $script:RegistryFile,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

# Persist the registry if Sweep-StaleEntries dropped anything. Callers that
# Sweep then exit early (e.g. release -> NOT_FOUND, acquire -> DENIED) MUST
# invoke this before returning, otherwise the sweep's in-memory drops are
# lost and stale claims "come back from the dead" on the next read. The
# happy paths already call Write-Registry directly, so this helper is for
# the error / not-found exit paths only.
function Persist-IfSwept {
    param([hashtable] $Registry, [int] $Swept)
    if ($Swept -gt 0) { Write-Registry -Registry $Registry }
}

# ===========================================================================
# SAP GUI introspection (shells out to the cscript COM helper)
# ===========================================================================

function Invoke-ComHelper {
    param([Parameter(Mandatory)][string[]] $Args)
    $cscriptArgs = @('//NoLogo', $script:ComHelperVbs) + $Args
    $raw = & $script:Cscript @cscriptArgs 2>&1
    $exit = $LASTEXITCODE
    if (-not $raw) { return @{ ok = $false; error = "com helper produced no output (exit=$exit)" } }
    $jsonLine = ($raw | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
    if (-not $jsonLine) { return @{ ok = $false; error = "com helper output not JSON: $raw" } }
    try { $obj = $jsonLine | ConvertFrom-Json } catch {
        return @{ ok = $false; error = "com helper JSON parse failed: $($_.Exception.Message)" }
    }
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Get-SapState {
    <#
    .SYNOPSIS
        Return cached SAP state (all connections + their sessions). Loaded
        on first call within this broker invocation; returns the cached
        copy thereafter.
    #>
    if ($null -ne $script:CachedInfo) { return $script:CachedInfo }
    # Test seam: SAPDEV_BROKER_FAKE_INFO lets an offline regression test feed a
    # canned INFO payload (a file path or inline JSON, same shape the COM
    # helper emits) so the identity-reconciliation logic can be exercised
    # without a live SAP GUI. Never set in production.
    if (-not [string]::IsNullOrWhiteSpace($env:SAPDEV_BROKER_FAKE_INFO)) {
        try {
            $fakeRaw = if (Test-Path -LiteralPath $env:SAPDEV_BROKER_FAKE_INFO) {
                Get-Content -LiteralPath $env:SAPDEV_BROKER_FAKE_INFO -Raw -Encoding UTF8
            } else { $env:SAPDEV_BROKER_FAKE_INFO }
            $obj = $fakeRaw | ConvertFrom-Json
            $h = @{}
            foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
            if (-not $h.ContainsKey('ok')) { $h['ok'] = $true }
            $script:CachedInfo = $h
            return $h
        } catch {
            $script:CachedInfo = $null
            return $null
        }
    }
    $info = Invoke-ComHelper -Args @('INFO')
    if (-not $info.ok) { $script:CachedInfo = $null; return $null }
    $script:CachedInfo = $info
    return $info
}

function Invalidate-SapStateCache { $script:CachedInfo = $null }

function Resolve-SapSessionSnap {
    <#
    .SYNOPSIS
        Look up a session by path across all connections. Returns a
        hashtable describing the session (or $null if not found).
    #>
    param([string] $Path)
    $state = Get-SapState
    if (-not $state) { return $null }
    foreach ($c in $state.connections) {
        foreach ($s in $c.sessions) {
            if ("$($s.path)" -eq $Path) {
                return @{
                    path            = "$($s.path)"
                    session_number  = [int]$s.session_number
                    transaction     = "$($s.transaction)"
                    program         = "$($s.program)"
                    screen          = [int]$s.screen
                    has_popup       = [bool]$s.has_popup
                    connection_path = "$($c.connection_path)"
                    system_name     = "$($c.system_name)"
                    client          = "$($c.client)"
                    user            = "$($c.user)"
                    logon_id        = "$($c.logon_id)"
                }
            }
        }
    }
    return $null
}

function Find-SapConnection {
    <#
    .SYNOPSIS
        Resolve a connection from the live SAP state by one of three keys.
        Returns the matching connection hashtable, or $null.
    #>
    param(
        [string] $ConnectionPath = '',
        [string] $SystemName     = '',
        [string] $Client         = '',
        [string] $User           = ''
    )
    $state = Get-SapState
    if (-not $state) { return $null }
    foreach ($c in $state.connections) {
        if ($ConnectionPath -ne '' -and "$($c.connection_path)" -ne $ConnectionPath) { continue }
        if ($SystemName     -ne '' -and "$($c.system_name)"     -ne $SystemName)     { continue }
        if ($Client         -ne '' -and "$($c.client)"          -ne $Client)         { continue }
        if ($User           -ne '' -and "$($c.user)"            -ne $User)           { continue }
        return $c
    }
    return $null
}

function Is-SessionAtEasyAccess {
    param($Snap)
    if (-not $Snap) { return $false }
    $txn = "$($Snap.transaction)"
    if ($txn -ne '' -and $txn -ne 'SMEN' -and $txn -ne 'S000') { return $false }
    if ($Snap.has_popup) { return $false }
    return $true
}

function Spawn-NewSession {
    param([Parameter(Mandatory)][string] $TargetConnectionPath)
    $result = Invoke-ComHelper -Args @('SPAWN', $TargetConnectionPath)
    Invalidate-SapStateCache
    if (-not $result.ok) { return $null }
    return @{
        connection_path = "$($result.connection_path)"
        path            = "$($result.path)"
        session_number  = [int]$result.session_number
    }
}

function Reset-SessionToEasyAccess {
    param([string] $Path)
    $result = Invoke-ComHelper -Args @('RESET', $Path)
    Invalidate-SapStateCache
    return [bool]$result.ok
}

function Close-SapSession {
    <#
    .SYNOPSIS
        Close a session via the COM helper. Returns $true on success or
        when the session is already gone (idempotent). The COM helper
        falls back to /n when the target is the only session of its
        connection -- that's still reported as ok.
    #>
    param([string] $Path)
    $result = Invoke-ComHelper -Args @('CLOSE', $Path)
    Invalidate-SapStateCache
    return [bool]$result.ok
}

# ===========================================================================
# 4-step identity compare (mirror of sap_connection_lib.ps1::Test-SapConnectionsEqual)
# Lives here as a duplicate because the broker can't dot-source another lib
# safely without risking circular dependencies; the logic is tiny.
# ===========================================================================

function Test-IdentityMatch {
    param($A, $B)
    # Mirror of sap_connection_lib.ps1::Test-SapConnectionsEqual. SystemName
    # is only decidable when both sides know it (empty = unknown, fall through).
    if (("$($A.system_name)") -and ("$($B.system_name)") -and
        ("$($A.system_name)" -ne "$($B.system_name)")) { return $false }
    if (("$($A.client)") -ne ("$($B.client)")) { return $false }
    if (("$($A.user)")   -ne ("$($B.user)"))   { return $false }
    # Lenient OR across endpoint identifiers.
    $aLpe = "$($A.logon_pad_entry)"
    if (-not $aLpe) { $aLpe = "$($A.description)" }   # registry blocks use description for the SAP-Logon name
    $bLpe = "$($B.logon_pad_entry)"
    if (-not $bLpe) { $bLpe = "$($B.description)" }
    if ($aLpe -and $bLpe -and ($aLpe -eq $bLpe)) { return $true }
    if ("$($A.message_server)" -and "$($B.message_server)" -and
        ("$($A.message_server)" -eq "$($B.message_server)")) { return $true }
    if ("$($A.application_server)" -and "$($B.application_server)" -and
        "$($A.system_number)"      -and "$($B.system_number)"      -and
        ("$($A.application_server)" -eq "$($B.application_server)") -and
        ("$($A.system_number)"      -eq "$($B.system_number)")) { return $true }
    return $false
}

# ===========================================================================
# Process liveness
# ===========================================================================

function Is-ProcessAlive {
    param([int] $ProcessId)
    if ($ProcessId -le 0) { return $false }
    try { $p = Get-Process -Id $ProcessId -ErrorAction Stop; return ($null -ne $p) } catch { return $false }
}

# ===========================================================================
# Identity reconciliation helpers
# ---------------------------------------------------------------------------
# The live SAP state is the SOURCE OF TRUTH for every field the COM helper
# reads from GuiSessionInfo (system_name / client / user / language /
# description / logon_id + the endpoint quintet). A /app/con[N] slot is
# recyclable -- the user can close system A's connection and open system B in
# the same slot -- so the persisted block must follow the live identity, not
# stick to whatever was first written. The ONLY field the broker (not SAP)
# owns is connection_id (a profile UUID assigned by set-connection-id); these
# helpers never touch it.
# ===========================================================================

# Stable, case-insensitive identity key for a connection: the (system, client,
# user) tuple that uniquely names a logged-on system. Used to detect when a
# slot now hosts a DIFFERENT system -- logon_id (SystemSessionId) cannot, since
# on the kernels we run (S/4HANA 1909, 754) it is per-workstation, not per-
# logon, and stays byte-identical across an A->B system swap on one slot.
function Get-IdentityKey {
    param($Src)
    return (("$($Src.system_name)").Trim().ToUpperInvariant() + '|' +
            ("$($Src.client)").Trim().ToUpperInvariant()      + '|' +
            ("$($Src.user)").Trim().ToUpperInvariant())
}

# Mirror the live SAP-read identity/metadata fields onto a registry block.
# -Full overwrites every field verbatim (used when the slot now hosts a
# DIFFERENT system -- take the live identity wholesale, including any
# legitimately-empty endpoint fields). Without -Full, each field is refreshed
# only when the live value is non-empty, so a transient empty read (e.g. a
# session still sitting on the SAPMSYST logon screen, whose Info struct has no
# SystemName yet) cannot wipe good stored data, while a relogin in a different
# language is still picked up. $Live may be a hashtable (the sweep's live
# lookup) or a PSCustomObject (discover's parsed INFO) -- both index the same.
function Copy-LiveIdentityToBlock {
    param([hashtable] $Block, $Live, [switch] $Full)
    $fields = @('system_name','client','user','language','description',
                'logon_id','message_server','logon_group','system_id',
                'application_server','system_number')
    foreach ($f in $fields) {
        $v = "$($Live.$f)"
        if ($Full -or $v -ne '') { $Block[$f] = $v }
    }
}

# ===========================================================================
# Sweep -- reconciles each connection block against live SAP state, then
# drops entries that no longer reflect reality.
# First, per connection block: mirror the live identity/metadata onto the
# block (live is source of truth). If the slot now hosts a DIFFERENT system
# (identity tuple changed), take the live identity wholesale and clear the
# stale connection_id. If a relogin is detected (tuple changed, OR logon_id
# rotated, OR language changed -- any of which closes the prior sessions),
# drop ALL of that connection's entries so they re-discover fresh.
# Then, per surviving entry, drop it when it:
#   (a) points to a non-existent session
#   (b) belongs to a dead owner PID (only when owner_pid > 0)
#   (c) has a TTL-expired claim
# A connection whose connection_path no longer resolves is dropped whole.
# ===========================================================================

function Sweep-StaleEntries {
    param([hashtable] $Registry, [bool] $VerboseDrops = $false)

    $state = Get-SapState
    if (-not $state) {
        # SAP unreachable -- leave the registry alone; the next call retries.
        return 0
    }

    # Build a lookup of current live state by connection_path. Capture the
    # FULL identity/metadata set (not just logon_id) so the reconciliation
    # below can mirror live values onto the registry block.
    $live = @{}
    foreach ($c in $state.connections) {
        $sessionMap = @{}
        foreach ($s in $c.sessions) { $sessionMap["$($s.path)"] = $true }
        $live["$($c.connection_path)"] = @{
            system_name        = "$($c.system_name)"
            client             = "$($c.client)"
            user               = "$($c.user)"
            language           = "$($c.language)"
            description        = "$($c.description)"
            logon_id           = "$($c.logon_id)"
            message_server     = "$($c.message_server)"
            logon_group        = "$($c.logon_group)"
            system_id          = "$($c.system_id)"
            application_server = "$($c.application_server)"
            system_number      = "$($c.system_number)"
            sessions           = $sessionMap
        }
    }

    $now = Get-Date
    $dropped = 0
    $survivingConnections = @()

    foreach ($conBlock in $Registry.connections) {
        $conPath = "$($conBlock.connection_path)"

        if (-not $live.ContainsKey($conPath)) {
            # Connection itself is gone (user closed the whole SAP Logon entry).
            if ($VerboseDrops) {
                foreach ($e in $conBlock.entries) {
                    Write-Host "DROP: $($e.path)  task=$($e.task_id)  reason=connection_closed (connection $conPath gone)"
                }
            }
            $dropped += $conBlock.entries.Count
            continue
        }

        $liveConn = $live[$conPath]

        # --- Identity reconciliation -----------------------------------------
        # Detect whether this slot now hosts a different logon than the block
        # records. logon_id (SystemSessionId) alone is NOT enough: on the
        # kernels we run it is per-workstation, not per-logon, so it stays
        # identical across an A->B system swap on one /app/con[N] slot. Compare
        # the real identity tuple (system/client/user) as the primary signal,
        # and treat a rotated logon_id or a changed language as relogin signals
        # too (any of which closes the prior sessions).
        $storedKnown  = ("$($conBlock.system_name)" -ne '')
        $liveKnown    = ("$($liveConn.system_name)" -ne '' -and
                         "$($liveConn.client)"      -ne '' -and
                         "$($liveConn.user)"        -ne '')
        $tupleChanged = $storedKnown -and $liveKnown -and
                        ((Get-IdentityKey $conBlock) -ne (Get-IdentityKey $liveConn))
        $loginRotated = ("$($conBlock.logon_id)" -ne '' -and "$($liveConn.logon_id)" -ne '' -and
                         "$($conBlock.logon_id)" -ne "$($liveConn.logon_id)")
        $langChanged  = ("$($conBlock.language)" -ne '' -and "$($liveConn.language)" -ne '' -and
                         "$($conBlock.language)" -ne "$($liveConn.language)")

        if ($tupleChanged) {
            # Different system on the slot: take the live identity wholesale
            # and drop the now-invalid profile association. The next login
            # finalize re-assigns connection_id via set-connection-id.
            $reason = "system_changed (was $(Get-IdentityKey $conBlock) -> $(Get-IdentityKey $liveConn))"
            Copy-LiveIdentityToBlock -Block $conBlock -Live $liveConn -Full
            $conBlock.connection_id = ''
        } else {
            # Same (or not-yet-known) system: refresh non-empty live values so
            # a relogin in a different language is reflected, without letting a
            # transient empty read wipe good data. connection_id is preserved.
            $reason = if ($loginRotated)     { "logon_changed (was $($conBlock.logon_id))" }
                      elseif ($langChanged)  { "language_changed (was $($conBlock.language) -> $($liveConn.language))" }
                      else                   { '' }
            Copy-LiveIdentityToBlock -Block $conBlock -Live $liveConn
        }

        # A changed identity / logon / language means the previous sessions are
        # gone (relogin closes them) even when SAP recycles the same
        # /app/con[N]/ses[M] paths. Drop ALL of this connection's entries so
        # they are re-discovered fresh against the new logon.
        if ($tupleChanged -or $loginRotated -or $langChanged) {
            if ($VerboseDrops) {
                foreach ($e in $conBlock.entries) {
                    Write-Host "DROP: $($e.path)  task=$($e.task_id)  reason=$reason"
                }
            }
            $dropped += $conBlock.entries.Count
            $conBlock.entries = @()
            $survivingConnections += $conBlock
            continue
        }

        # Per-entry sweep.
        $survivingEntries = @()
        foreach ($e in $conBlock.entries) {
            $drop = $false
            $reason = ''
            if (-not $liveConn.sessions.ContainsKey("$($e.path)")) {
                $drop = $true; $reason = 'session_closed'
            }
            if (-not $drop -and $e.status -eq 'claimed' -and $e.owner_pid -gt 0) {
                if (-not (Is-ProcessAlive -ProcessId $e.owner_pid)) {
                    $drop = $true; $reason = "pid_dead (pid=$($e.owner_pid))"
                }
            }
            if (-not $drop -and $e.status -eq 'claimed' -and $e.claim_time) {
                try {
                    $claimed = [datetime]::Parse($e.claim_time)
                    $age = ($now - $claimed).TotalSeconds
                    if ($age -gt $e.ttl_seconds) {
                        $drop = $true; $reason = "ttl_expired (age=$([int]$age)s ttl=$($e.ttl_seconds)s)"
                    }
                } catch { $drop = $true; $reason = 'bad_claim_time' }
            }
            if ($drop) {
                if ($VerboseDrops) {
                    Write-Host "DROP: $($e.path)  task=$($e.task_id)  reason=$reason"
                }
                $dropped += 1
            } else {
                $survivingEntries += $e
            }
        }
        $conBlock.entries = $survivingEntries
        $survivingConnections += $conBlock
    }

    $Registry.connections = $survivingConnections
    return $dropped
}

# ===========================================================================
# Pin-file resolution helper (used by acquire when -PinFile is supplied).
# ===========================================================================

function Read-Pin {
    param([string] $PinPath)
    if (-not $PinPath -or -not (Test-Path $PinPath)) { return $null }
    try {
        $raw = Get-Content $PinPath -Raw -Encoding UTF8
        if (-not $raw) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

# ===========================================================================
# Target-connection resolution (the core of multi-connection acquire).
# Returns @{ connection_path = "..."; session_path = "..." (optional) } or $null.
# ===========================================================================

function Resolve-TargetConnection {
    param(
        [string] $SessionPath,
        [string] $ConnectionPath,
        [string] $SystemName,
        [string] $Client,
        [string] $User,
        [string] $PinFile
    )

    # (1) Explicit SessionPath -> derive connection.
    if ($SessionPath -ne '') {
        if ($SessionPath -match '^(/app/con\[\d+\])/ses\[\d+\]$') {
            $con = $matches[1]
            $c = Find-SapConnection -ConnectionPath $con
            if ($c) {
                return @{ connection_path = "$($c.connection_path)"; session_path = $SessionPath; via = 'session_path' }
            }
            return @{ error = "explicit -SessionPath connection segment ($con) not attached"; via = 'session_path' }
        }
        return @{ error = "invalid -SessionPath: $SessionPath"; via = 'session_path' }
    }

    # (2) Explicit ConnectionPath.
    if ($ConnectionPath -ne '') {
        $c = Find-SapConnection -ConnectionPath $ConnectionPath
        if ($c) { return @{ connection_path = "$($c.connection_path)"; via = 'connection_path' } }
        return @{ error = "-ConnectionPath $ConnectionPath not attached"; via = 'connection_path' }
    }

    # (3) (System, Client, User) tuple -- any non-empty subset filters.
    if ($SystemName -ne '' -or $Client -ne '' -or $User -ne '') {
        $c = Find-SapConnection -SystemName $SystemName -Client $Client -User $User
        if ($c) { return @{ connection_path = "$($c.connection_path)"; via = 'tuple' } }
        return @{ error = "no connection matches system=$SystemName client=$Client user=$User"; via = 'tuple' }
    }

    # (4) Pin file.
    if ($PinFile -ne '') {
        $pin = Read-Pin -PinPath $PinFile
        if ($pin) {
            # 4a -- pin has a session_path; derive connection.
            $pinSp = "$($pin.session_path)"
            if ($pinSp -match '^(/app/con\[\d+\])/ses\[\d+\]$') {
                $con = $matches[1]
                $c = Find-SapConnection -ConnectionPath $con
                if ($c) {
                    return @{ connection_path = "$($c.connection_path)"; session_path = $pinSp; via = 'pin_session_path' }
                }
            }
            # 4b -- pin has (system, client, user); match by tuple.
            $sys  = "$($pin.system_name)"
            $clt  = "$($pin.client)"
            $usr  = "$($pin.user)"
            if ($sys -ne '' -or $clt -ne '' -or $usr -ne '') {
                $c = Find-SapConnection -SystemName $sys -Client $clt -User $usr
                if ($c) { return @{ connection_path = "$($c.connection_path)"; via = 'pin_tuple' } }
            }
        }
        # Fall through; pin file existed but didn't resolve to a live connection.
    }

    # (5) Exactly one connection attached -> use it.
    $state = Get-SapState
    if ($state -and $state.connections.Count -eq 1) {
        $c = $state.connections[0]
        return @{ connection_path = "$($c.connection_path)"; via = 'sole_connection' }
    }

    # (6) Ambiguous.
    $count = if ($state) { $state.connections.Count } else { 0 }
    return @{ error = "ambiguous target: $count connections attached and no resolver supplied (use -SessionPath, -ConnectionPath, -SystemName/-Client/-User, or -PinFile)"; via = 'none' }
}

# ===========================================================================
# Action: list
# ===========================================================================

function Invoke-List {
    With-RegistryLock {
        $reg = Read-Registry
        Write-Host ($reg | ConvertTo-Json -Depth 6)
    }
}

# ===========================================================================
# Action: discover -- walk every connection; register new sessions.
# ===========================================================================

function Invoke-Discover {
    With-RegistryLock {
        $reg = Read-Registry
        [void](Sweep-StaleEntries -Registry $reg -VerboseDrops $false)

        $state = Get-SapState
        if (-not $state) {
            Write-Host 'ERROR: SAP GUI not running or no connection'
            exit 2
        }

        $newCount    = 0
        $totalFree   = 0
        $totalUser   = 0

        # Index existing connection blocks by connection_path.
        $byCon = @{}
        foreach ($cb in $reg.connections) { $byCon["$($cb.connection_path)"] = $cb }

        foreach ($liveCon in $state.connections) {
            $cp = "$($liveCon.connection_path)"
            if (-not $byCon.ContainsKey($cp)) {
                $newBlock = @{
                    connection_path    = $cp
                    connection_id      = ''   # populated post-login by sap_login_select.ps1
                    system_name        = "$($liveCon.system_name)"
                    client             = "$($liveCon.client)"
                    user               = "$($liveCon.user)"
                    language           = "$($liveCon.language)"
                    description        = "$($liveCon.description)"
                    logon_id           = "$($liveCon.logon_id)"
                    message_server     = "$($liveCon.message_server)"
                    logon_group        = "$($liveCon.logon_group)"
                    system_id          = "$($liveCon.system_id)"
                    application_server = "$($liveCon.application_server)"
                    system_number      = "$($liveCon.system_number)"
                    entries            = @()
                }
                $reg.connections += $newBlock
                $byCon[$cp] = $newBlock
            }
            $cb = $byCon[$cp]

            # Refresh per-connection metadata from live. The preceding
            # Sweep-StaleEntries already reconciled a system swap on a reused
            # /app/con[N] slot (mirrored the new identity, cleared the stale
            # connection_id, dropped the old entries); this mirror keeps the
            # block current for the unchanged case too -- e.g. a relogin in a
            # different language. Mirror only non-empty live values so a
            # transient empty read (a session still on the SAPMSYST logon
            # screen) cannot wipe good data. connection_id is NOT touched here:
            # it is broker-owned (assigned by set-connection-id), not read from
            # SAP, and the sweep already cleared it if the system changed.
            Copy-LiveIdentityToBlock -Block $cb -Live $liveCon

            $existingPaths = @{}
            foreach ($e in $cb.entries) { $existingPaths["$($e.path)"] = $e }

            foreach ($s in $liveCon.sessions) {
                $sp = "$($s.path)"
                if ($existingPaths.ContainsKey($sp)) {
                    if ($existingPaths[$sp].status -eq 'free')           { $totalFree += 1 }
                    elseif ($existingPaths[$sp].status -eq 'user_owned') { $totalUser += 1 }
                    continue
                }
                $snap = @{
                    path        = $sp
                    transaction = "$($s.transaction)"
                    has_popup   = [bool]$s.has_popup
                }
                $atEasy = Is-SessionAtEasyAccess -Snap $snap
                $status = if ($atEasy) { 'free' } else { 'user_owned' }
                $cb.entries += @{
                    path           = $sp
                    session_number = [int]$s.session_number
                    task_id        = ''
                    ai_session_id  = ''
                    owner_pid      = 0
                    owner_skill    = ''
                    status         = $status
                    claim_time     = ''
                    ttl_seconds    = $TtlSeconds
                    discovered     = $true
                    stuck_program  = ''
                    stuck_screen   = ''
                }
                $newCount += 1
                if ($status -eq 'free') { $totalFree += 1 } else { $totalUser += 1 }
            }
        }

        Write-Registry -Registry $reg
        Write-Host "DISCOVERED: $newCount new across $($state.connections.Count) connection(s) (total free=$totalFree user_owned=$totalUser)"
    }
}

# ===========================================================================
# Action: gc
# ===========================================================================

function Invoke-Gc {
    With-RegistryLock {
        $reg = Read-Registry
        $dropped = Sweep-StaleEntries -Registry $reg -VerboseDrops $true
        Write-Registry -Registry $reg
        Write-Host "GC: dropped $dropped stale entries"
    }
}

# ===========================================================================
# Action: acquire
# ===========================================================================

function Invoke-Acquire {
    if ($TaskId -eq '') {
        Write-Host 'ERROR: -TaskId is required for acquire'
        exit 2
    }

    $script:Result = ''
    With-RegistryLock {
        $reg = Read-Registry
        $swept = Sweep-StaleEntries -Registry $reg -VerboseDrops $false

        # Idempotent re-acquire: same task_id with a still-live claim wins
        # regardless of connection target. AI-session pin is also bypassed
        # for the idempotent path (the claim already exists; we're just
        # touching the heartbeat).
        foreach ($cb in $reg.connections) {
            $hit = $cb.entries | Where-Object {
                $_.task_id -eq $TaskId -and $_.status -eq 'claimed'
            } | Select-Object -First 1
            if ($hit) {
                $hit.claim_time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
                if ($AiSessionId -and -not $hit.ai_session_id) { $hit.ai_session_id = $AiSessionId }
                Write-Registry -Registry $reg
                $script:Result = "ACQUIRED: path=$($hit.path) sessionNumber=$($hit.session_number) connection=$($cb.connection_path) reused=true"
                return
            }
        }

        # Phase 4: honor AI-session pin BEFORE running the targeting
        # resolver, but only when no explicit target was supplied. If the
        # caller passed an explicit -SessionPath / -ConnectionPath / tuple
        # / -PinFile, that wins; we still enforce the pin AFTER resolution.
        $pinConnId = ''
        $pinConnPath = ''
        if ($AiSessionId -and $reg.ai_sessions.ContainsKey($AiSessionId)) {
            $pinConnId = "$($reg.ai_sessions[$AiSessionId].connection_id)"
            if ($pinConnId) {
                # Find the live connection_path that owns this connection_id.
                $cbPin = $reg.connections | Where-Object { "$($_.connection_id)" -eq $pinConnId } | Select-Object -First 1
                if ($cbPin) { $pinConnPath = "$($cbPin.connection_path)" }
            }
        }
        $usedPinForResolution = $false
        if (-not $SessionPath -and -not $ConnectionPath -and
            -not $SystemName -and -not $Client -and -not $User -and -not $PinFile -and
            $pinConnPath) {
            $ConnectionPath = $pinConnPath
            $usedPinForResolution = $true
        }

        # Resolve which connection this acquire targets.
        $target = Resolve-TargetConnection `
            -SessionPath    $SessionPath `
            -ConnectionPath $ConnectionPath `
            -SystemName     $SystemName `
            -Client         $Client `
            -User           $User `
            -PinFile        $PinFile
        if ($target.error) {
            Persist-IfSwept -Registry $reg -Swept $swept
            $script:Result = "DENIED: $($target.error)"
            return
        }
        $targetCon = $target.connection_path

        # Locate (or create) the registry block for this connection.
        $cb = $reg.connections | Where-Object { $_.connection_path -eq $targetCon } | Select-Object -First 1
        if (-not $cb) {
            # The connection exists in SAP but not yet in our registry --
            # discover would normally create it. Inline the registration here.
            $liveCon = $null
            $state = Get-SapState
            if ($state) { $liveCon = $state.connections | Where-Object { "$($_.connection_path)" -eq $targetCon } | Select-Object -First 1 }
            if (-not $liveCon) {
                Persist-IfSwept -Registry $reg -Swept $swept
                $script:Result = "DENIED: target connection $targetCon disappeared during acquire"
                return
            }
            $cb = @{
                connection_path    = "$($liveCon.connection_path)"
                connection_id      = ''
                system_name        = "$($liveCon.system_name)"
                client             = "$($liveCon.client)"
                user               = "$($liveCon.user)"
                language           = "$($liveCon.language)"
                description        = "$($liveCon.description)"
                logon_id           = "$($liveCon.logon_id)"
                message_server     = "$($liveCon.message_server)"
                logon_group        = "$($liveCon.logon_group)"
                system_id          = "$($liveCon.system_id)"
                application_server = "$($liveCon.application_server)"
                system_number      = "$($liveCon.system_number)"
                entries            = @()
            }
            $reg.connections += $cb
        }

        # Phase 4: enforce the AI-session pin AFTER resolution. Refuse if
        # the resolved connection's connection_id differs from the pinned
        # connection_id (unless -ForceUnpin was passed, which sap-login
        # itself uses on user-driven re-pin).
        if ($AiSessionId -and -not $ForceUnpin) {
            if ($pinConnId -and "$($cb.connection_id)" -and ("$($cb.connection_id)" -ne $pinConnId)) {
                Persist-IfSwept -Registry $reg -Swept $swept
                $script:Result = "DENIED: ai_session $AiSessionId is pinned to connection_id=$pinConnId; this acquire targets $($cb.connection_id) on $targetCon. Re-run /sap-login to switch pins, or pass -ForceUnpin."
                return
            }
        }

        # Pick a free entry. Prefer the explicit SessionPath if supplied
        # AND it's free in this connection; otherwise any free.
        $chosen = $null
        if ($target.session_path) {
            $chosen = $cb.entries | Where-Object {
                $_.path -eq $target.session_path -and $_.status -eq 'free'
            } | Select-Object -First 1
        }
        if (-not $chosen) {
            $chosen = $cb.entries | Where-Object { $_.status -eq 'free' } | Select-Object -First 1
        }

        # Spawn-on-demand if nothing free on this connection.
        $spawned = $false
        if (-not $chosen) {
            $newSes = Spawn-NewSession -TargetConnectionPath $targetCon
            if (-not $newSes) {
                Persist-IfSwept -Registry $reg -Swept $swept
                $script:Result = "DENIED: no free session on $targetCon and spawn failed (cap reached or SAP GUI unreachable)"
                return
            }
            $chosen = @{
                path           = "$($newSes.path)"
                session_number = [int]$newSes.session_number
                task_id        = ''
                ai_session_id  = ''
                owner_pid      = 0
                owner_skill    = ''
                status         = 'free'
                claim_time     = ''
                ttl_seconds    = $TtlSeconds
                discovered     = $false
                stuck_program  = ''
                stuck_screen   = ''
                was_created    = $true   # used by `release -WasCreated` to call CLOSE
            }
            $cb.entries += $chosen
            $spawned = $true
        }

        # Pre-allocation Easy-Access verification.
        $snap = Resolve-SapSessionSnap -Path $chosen.path
        if (-not $snap) {
            $cb.entries = $cb.entries | Where-Object { $_.path -ne $chosen.path }
            Write-Registry -Registry $reg
            $script:Result = "DENIED: chosen session $($chosen.path) disappeared during acquire (retry)"
            return
        }
        if (-not (Is-SessionAtEasyAccess -Snap $snap)) {
            $resetOk = Reset-SessionToEasyAccess -Path $chosen.path
            $snap = Resolve-SapSessionSnap -Path $chosen.path
            if ((-not $resetOk) -or (-not (Is-SessionAtEasyAccess -Snap $snap))) {
                $chosen.status = 'user_owned'
                Write-Registry -Registry $reg
                $script:Result = "DENIED: chosen session $($chosen.path) could not be returned to Easy Access (marked user_owned)"
                return
            }
        }

        # Claim it.
        $chosen.task_id        = $TaskId
        $chosen.ai_session_id  = "$AiSessionId"
        $chosen.owner_pid      = if ($OwnerPid -gt 0) { $OwnerPid } else { 0 }
        $chosen.owner_skill    = $OwnerSkill
        $chosen.status         = 'claimed'
        $chosen.claim_time     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        $chosen.ttl_seconds    = $TtlSeconds
        # Clear any prior stuck-screen marker -- the session is back at Easy
        # Access by now (we verified above).
        $chosen.stuck_program  = ''
        $chosen.stuck_screen   = ''

        # Auto-bootstrap pin: if -AiSessionId supplied and no pin yet, AND
        # the resolved connection has a connection_id, write the pin so
        # subsequent acquires for the same AI session land on the same
        # connection.
        if ($AiSessionId -and "$($cb.connection_id)" -and
            -not ($reg.ai_sessions.ContainsKey($AiSessionId) -and $reg.ai_sessions[$AiSessionId].connection_id)) {
            $reg.ai_sessions[$AiSessionId] = @{
                connection_id = "$($cb.connection_id)"
                pinned_at     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
                pin_reason    = 'acquire_bootstrap'
                last_seen_at  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
            }
        } elseif ($AiSessionId -and $reg.ai_sessions.ContainsKey($AiSessionId)) {
            $reg.ai_sessions[$AiSessionId].last_seen_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        }

        Write-Registry -Registry $reg
        $script:Result = "ACQUIRED: path=$($chosen.path) sessionNumber=$($chosen.session_number) connection=$targetCon reused=$(-not $spawned)"
    }

    Write-Host $script:Result
    if ($script:Result.StartsWith('DENIED')) { exit 1 }
}

# ===========================================================================
# Action: release -- find claim by task_id across all connections.
# ===========================================================================

function Invoke-Release {
    if ($TaskId -eq '') {
        Write-Host 'ERROR: -TaskId is required for release'
        exit 2
    }
    $script:Result = ''
    With-RegistryLock {
        $reg = Read-Registry
        $swept = Sweep-StaleEntries -Registry $reg -VerboseDrops $false

        $matched = $null
        foreach ($cb in $reg.connections) {
            $hit = $cb.entries | Where-Object { $_.task_id -eq $TaskId -and $_.status -eq 'claimed' } | Select-Object -First 1
            if ($hit) { $matched = @{ block = $cb; entry = $hit }; break }
        }
        if (-not $matched) {
            Persist-IfSwept -Registry $reg -Swept $swept
            # Distinguish "task_id was here but the reactive cleanup just
            # dropped it" from "never seen this task_id". The first case
            # is the common scaffolder pattern -- long-running parallel
            # batches hit the default 600s TTL between acquire and release.
            # Both outcomes are idempotent (the SAP-side state is whatever
            # the sweep left), but the message is the caller's only signal
            # to know whether their bookkeeping was honored or expired.
            # Exit code stays 0 -- release remains non-fatal-by-design.
            if ($swept -gt 0) {
                $script:Result = "NOT_FOUND: task=$TaskId (entry was here but dropped by reactive cleanup before this release fired -- likely ttl_expired or session_closed; raise -TtlSeconds on acquire if batches are long-running)"
            } else {
                $script:Result = "NOT_FOUND: task=$TaskId (no matching claim in registry -- already released, or never acquired with this task_id)"
            }
            return
        }

        $entry = $matched.entry
        $closeIt = $WasCreated -or [bool]$entry.was_created

        # Cleanup the SAP-side state. CLOSE for sessions the broker spawned;
        # RESET (/n) for sessions we just borrowed from the user.
        $snap = Resolve-SapSessionSnap -Path $entry.path
        if ($snap) {
            if ($closeIt) {
                [void](Close-SapSession -Path $entry.path)
            } else {
                [void](Reset-SessionToEasyAccess -Path $entry.path)
            }
        }

        if ($closeIt) {
            # Drop the entry entirely -- the session is gone (or about to be).
            $matched.block.entries = @($matched.block.entries | Where-Object { $_.path -ne $entry.path })
            $script:Result = "RELEASED: path=$($entry.path) connection=$($matched.block.connection_path) closed=true"
        } else {
            $entry.task_id        = ''
            $entry.ai_session_id  = ''
            $entry.owner_pid      = 0
            $entry.owner_skill    = ''
            $entry.status         = 'free'
            $entry.claim_time     = ''
            $entry.stuck_program  = ''
            $entry.stuck_screen   = ''
            $script:Result = "RELEASED: path=$($entry.path) connection=$($matched.block.connection_path) closed=false"
        }

        Write-Registry -Registry $reg
    }
    Write-Host $script:Result
}

# ===========================================================================
# Action: stuck -- record Program / ScreenNumber on a still-claimed entry.
# Used by skills that fail mid-flow to leave a breadcrumb so the next
# acquire from the same task_id knows the session is NOT at Easy Access.
# Does NOT release the claim; the skill calls release separately when ready.
# ===========================================================================

function Invoke-Stuck {
    if ($TaskId -eq '') {
        Write-Host 'ERROR: -TaskId is required for stuck'
        exit 2
    }
    $script:Result = ''
    With-RegistryLock {
        $reg = Read-Registry

        $hit = $null
        foreach ($cb in $reg.connections) {
            $e = $cb.entries | Where-Object { $_.task_id -eq $TaskId -and $_.status -eq 'claimed' } | Select-Object -First 1
            if ($e) { $hit = $e; break }
        }
        if (-not $hit) { $script:Result = 'NOT_FOUND'; return }

        $hit.stuck_program = "$Program"
        $hit.stuck_screen  = "$Screen"
        Write-Registry -Registry $reg
        $script:Result = "STUCK_RECORDED: path=$($hit.path) program=$Program screen=$Screen"
    }
    Write-Host $script:Result
}

# ===========================================================================
# Action: set-connection-id -- associate a live connection_path with a
# profile UUID. Called once by sap_login_select.ps1 post-login.
# ===========================================================================

function Invoke-SetConnectionId {
    if ([string]::IsNullOrWhiteSpace($ConnectionPath)) {
        Write-Host 'ERROR: -ConnectionPath is required for set-connection-id'
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($ConnectionId)) {
        Write-Host 'ERROR: -ConnectionId is required for set-connection-id'
        exit 2
    }

    $script:Result = ''
    With-RegistryLock {
        $reg = Read-Registry
        $swept = Sweep-StaleEntries -Registry $reg -VerboseDrops $false

        $cb = $reg.connections | Where-Object { $_.connection_path -eq $ConnectionPath } | Select-Object -First 1
        if (-not $cb) {
            # Pull the live block from SAP state and add it.
            $state = Get-SapState
            $liveCon = $null
            if ($state) { $liveCon = $state.connections | Where-Object { "$($_.connection_path)" -eq $ConnectionPath } | Select-Object -First 1 }
            if (-not $liveCon) {
                Persist-IfSwept -Registry $reg -Swept $swept
                $script:Result = "ERROR: connection $ConnectionPath not attached"
                return
            }
            $cb = @{
                connection_path    = "$($liveCon.connection_path)"
                connection_id      = ''
                system_name        = "$($liveCon.system_name)"
                client             = "$($liveCon.client)"
                user               = "$($liveCon.user)"
                language           = "$($liveCon.language)"
                description        = "$($liveCon.description)"
                logon_id           = "$($liveCon.logon_id)"
                message_server     = "$($liveCon.message_server)"
                logon_group        = "$($liveCon.logon_group)"
                system_id          = "$($liveCon.system_id)"
                application_server = "$($liveCon.application_server)"
                system_number      = "$($liveCon.system_number)"
                entries            = @()
            }
            $reg.connections += $cb
        }
        $cb.connection_id = "$ConnectionId"
        Write-Registry -Registry $reg
        $script:Result = "SET_CONNECTION_ID: path=$ConnectionPath connection_id=$ConnectionId"
    }
    Write-Host $script:Result
}

# ===========================================================================
# Action: pin -- write ai_sessions[$AiSessionId] = { connection_id = ... }.
# When this changes the pin to a different connection AND ALSO existing
# claims for this AI session live on the old connection, releases them.
# ===========================================================================

function Invoke-Pin {
    if ([string]::IsNullOrWhiteSpace($AiSessionId)) {
        Write-Host 'ERROR: -AiSessionId is required for pin'
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($ConnectionId)) {
        Write-Host 'ERROR: -ConnectionId is required for pin'
        exit 2
    }

    $script:Result = ''
    $script:ReleasedCount = 0
    With-RegistryLock {
        $reg = Read-Registry

        $oldConnId = ''
        if ($reg.ai_sessions.ContainsKey($AiSessionId)) {
            $oldConnId = "$($reg.ai_sessions[$AiSessionId].connection_id)"
        }

        $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        $reasonEff = if ($PinReason) { $PinReason } else { 'user_picked' }
        $reg.ai_sessions[$AiSessionId] = @{
            connection_id = "$ConnectionId"
            pinned_at     = $now
            pin_reason    = $reasonEff
            last_seen_at  = $now
        }

        # If switching, release this AI session's claims on the old connection.
        if ($oldConnId -and $oldConnId -ne $ConnectionId) {
            foreach ($cb in $reg.connections) {
                if ("$($cb.connection_id)" -ne $oldConnId) { continue }
                $myEntries = @($cb.entries | Where-Object {
                    $_.ai_session_id -eq $AiSessionId -and $_.status -eq 'claimed'
                })
                foreach ($e in $myEntries) {
                    $snap = Resolve-SapSessionSnap -Path $e.path
                    if ($snap) { [void](Reset-SessionToEasyAccess -Path $e.path) }
                    $e.task_id        = ''
                    $e.ai_session_id  = ''
                    $e.owner_pid      = 0
                    $e.owner_skill    = ''
                    $e.status         = 'free'
                    $e.claim_time     = ''
                    $e.stuck_program  = ''
                    $e.stuck_screen   = ''
                    $script:ReleasedCount += 1
                }
            }
        }

        Write-Registry -Registry $reg
        $script:Result = "PINNED: ai_session=$AiSessionId connection_id=$ConnectionId released=$($script:ReleasedCount) old=$oldConnId"
    }
    Write-Host $script:Result
}

# ===========================================================================
# Action: unpin -- drop ai_sessions[$AiSessionId]. Does NOT release claims;
# call release separately if needed.
# ===========================================================================

function Invoke-Unpin {
    if ([string]::IsNullOrWhiteSpace($AiSessionId)) {
        Write-Host 'ERROR: -AiSessionId is required for unpin'
        exit 2
    }
    $script:Result = ''
    With-RegistryLock {
        $reg = Read-Registry
        if ($reg.ai_sessions.ContainsKey($AiSessionId)) {
            $reg.ai_sessions.Remove($AiSessionId) | Out-Null
            Write-Registry -Registry $reg
            $script:Result = "UNPINNED: ai_session=$AiSessionId"
        } else {
            $script:Result = "NOT_FOUND: ai_session=$AiSessionId not pinned"
        }
    }
    Write-Host $script:Result
}

# ===========================================================================
# Dispatch
# ===========================================================================

switch ($Action) {
    'list'              { Invoke-List }
    'discover'          { Invoke-Discover }
    'gc'                { Invoke-Gc }
    'acquire'           { Invoke-Acquire }
    'release'           { Invoke-Release }
    'stuck'             { Invoke-Stuck }
    'pin'               { Invoke-Pin }
    'unpin'             { Invoke-Unpin }
    'set-connection-id' { Invoke-SetConnectionId }
}
exit 0
