# =============================================================================
# sap_session_broker.ps1
# -----------------------------------------------------------------------------
# Cross-process broker for SAP GUI session ownership. Multi-connection aware
# from Phase 3.5 onwards — the registry tracks every attached SAP connection
# (different SID, different client, different user logon) separately, and
# every acquire call must specify which connection it wants (or use the
# single-connection auto-resolve).
#
# Contract — what the broker promises:
#   * Mutual exclusion: at any instant, at most one task_id holds a "claimed"
#     entry for any given session path.
#   * Reactive cleanup: every acquire/release call drops entries that no
#     longer reflect reality (session window closed, owner process died,
#     TTL expired, user logged out — the latter detected per-connection
#     via SystemSessionId change).
#   * Spawn-on-demand: if no free session exists on the target connection,
#     the broker spawns one via /oSESSION_MANAGER (the only OK-code reliably
#     honoured on the S/4HANA 1909 kernel 754 build verified during design).
#   * Connection isolation: a claim against /app/con[1] never returns a
#     /app/con[0] path. The acquire-time resolution refuses to default
#     across connections when ambiguous.
#
# Contract — what the broker does NOT promise (by design):
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
# pre-3.5 shape — a v1 broker and a v2 broker MUST NOT both run; v2
# rejects v1's flat-entries registry by recognising the missing
# `connections` field and rebuilding fresh).
#
# Usage — see shared/rules/sap_session_broker.md for the full contract.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('acquire', 'release', 'gc', 'list', 'discover')]
    [string] $Action,

    [Parameter(Mandatory = $true)]
    [string] $WorkTemp,

    [string] $TaskId      = '',
    [string] $OwnerSkill  = '',
    [int]    $TtlSeconds  = 600,
    [int]    $OwnerPid    = 0,

    # Connection-targeting filters (acquire). Resolution order:
    #   1. -SessionPath /app/con[N]/ses[M]   — explicit; derives connection.
    #   2. -ConnectionPath /app/con[N]       — pick this connection.
    #   3. -SystemName + -Client + -User     — find matching connection by
    #                                          GuiSession.Info tuple.
    #   4. -PinFile <path>                   — read pin file; honour its
    #                                          session_path if non-empty,
    #                                          else its (system,client,user).
    #   5. Exactly 1 connection attached     — silent default.
    #   6. Else                              — DENIED: ambiguous.
    [string] $SessionPath    = '',
    [string] $ConnectionPath = '',
    [string] $SystemName     = '',
    [string] $Client         = '',
    [string] $User           = '',
    [string] $PinFile        = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:RegistryFile = Join-Path $WorkTemp 'session_registry.json'
$script:MutexName    = 'SapDevSessionBroker_v2'   # bumped from v1 in Phase 3.5
$script:MutexTimeout = 10000

$script:ComHelperVbs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'sap_session_broker_com.vbs'
$script:Cscript      = 'C:\Windows\SysWOW64\cscript.exe'

if (-not (Test-Path $WorkTemp)) {
    New-Item -ItemType Directory -Path $WorkTemp -Force | Out-Null
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
    return @{ updated_at = ''; connections = @() }
}

function Read-Registry {
    if (-not (Test-Path $script:RegistryFile)) {
        return New-EmptyRegistry
    }
    try {
        $raw = Get-Content -Path $script:RegistryFile -Raw -Encoding UTF8
        if (-not $raw -or $raw.Trim() -eq '') { return New-EmptyRegistry }
        $obj = $raw | ConvertFrom-Json

        # Detect v1 (flat-entries) shape and reject it. Forward-compat: a v1
        # registry has top-level "entries"; v2 has "connections".
        if ($obj.PSObject.Properties['entries'] -and -not $obj.PSObject.Properties['connections']) {
            Write-Host 'WARN: v1 registry detected; rebuilding under v2 schema'
            return New-EmptyRegistry
        }

        $reg = New-EmptyRegistry
        $reg.updated_at = "$($obj.updated_at)"
        if ($obj.connections) {
            foreach ($c in $obj.connections) {
                $conBlock = @{
                    connection_path = "$($c.connection_path)"
                    system_name     = "$($c.system_name)"
                    client          = "$($c.client)"
                    user            = "$($c.user)"
                    description     = "$($c.description)"
                    logon_id        = "$($c.logon_id)"
                    entries         = @()
                }
                if ($c.entries) {
                    foreach ($e in $c.entries) {
                        $conBlock.entries += @{
                            path           = "$($e.path)"
                            session_number = if ($e.session_number) { [int]$e.session_number } else { 0 }
                            task_id        = "$($e.task_id)"
                            owner_pid      = if ($e.owner_pid) { [int]$e.owner_pid } else { 0 }
                            owner_skill    = "$($e.owner_skill)"
                            status         = "$($e.status)"
                            claim_time     = "$($e.claim_time)"
                            ttl_seconds    = if ($e.ttl_seconds) { [int]$e.ttl_seconds } else { 600 }
                            discovered     = [bool]$e.discovered
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

# ===========================================================================
# Process liveness
# ===========================================================================

function Is-ProcessAlive {
    param([int] $ProcessId)
    if ($ProcessId -le 0) { return $false }
    try { $p = Get-Process -Id $ProcessId -ErrorAction Stop; return ($null -ne $p) } catch { return $false }
}

# ===========================================================================
# Sweep — drops entries that no longer reflect reality.
# Walks every connection block, dropping per-connection entries that:
#   (a) point to a non-existent session
#   (b) belong to a dead owner PID (only when owner_pid > 0)
#   (c) have a TTL-expired claim
#   (d) belong to a connection whose SystemSessionId changed (entire
#       connection block dropped if logon_id mismatched).
# ===========================================================================

function Sweep-StaleEntries {
    param([hashtable] $Registry, [bool] $VerboseDrops = $false)

    $state = Get-SapState
    if (-not $state) {
        # SAP unreachable — leave the registry alone; the next call retries.
        return 0
    }

    # Build a lookup of current live state by connection_path.
    $live = @{}
    foreach ($c in $state.connections) {
        $sessionMap = @{}
        foreach ($s in $c.sessions) { $sessionMap["$($s.path)"] = $true }
        $live["$($c.connection_path)"] = @{
            logon_id   = "$($c.logon_id)"
            sessions   = $sessionMap
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

        # Logon ID changed (user logged out + back in on the same SAP Logon slot)?
        if ("$($conBlock.logon_id)" -ne '' -and
            $liveConn.logon_id -ne '' -and
            "$($conBlock.logon_id)" -ne $liveConn.logon_id) {
            if ($VerboseDrops) {
                foreach ($e in $conBlock.entries) {
                    Write-Host "DROP: $($e.path)  task=$($e.task_id)  reason=logon_changed (was $($conBlock.logon_id))"
                }
            }
            $dropped += $conBlock.entries.Count
            # Keep the connection block but reset metadata + entries.
            $conBlock.logon_id = $liveConn.logon_id
            $conBlock.entries  = @()
            $survivingConnections += $conBlock
            continue
        }
        if ("$($conBlock.logon_id)" -eq '' -and $liveConn.logon_id -ne '') {
            $conBlock.logon_id = $liveConn.logon_id
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

    # (3) (System, Client, User) tuple — any non-empty subset filters.
    if ($SystemName -ne '' -or $Client -ne '' -or $User -ne '') {
        $c = Find-SapConnection -SystemName $SystemName -Client $Client -User $User
        if ($c) { return @{ connection_path = "$($c.connection_path)"; via = 'tuple' } }
        return @{ error = "no connection matches system=$SystemName client=$Client user=$User"; via = 'tuple' }
    }

    # (4) Pin file.
    if ($PinFile -ne '') {
        $pin = Read-Pin -PinPath $PinFile
        if ($pin) {
            # 4a — pin has a session_path; derive connection.
            $pinSp = "$($pin.session_path)"
            if ($pinSp -match '^(/app/con\[\d+\])/ses\[\d+\]$') {
                $con = $matches[1]
                $c = Find-SapConnection -ConnectionPath $con
                if ($c) {
                    return @{ connection_path = "$($c.connection_path)"; session_path = $pinSp; via = 'pin_session_path' }
                }
            }
            # 4b — pin has (system, client, user); match by tuple.
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
# Action: discover — walk every connection; register new sessions.
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
                    connection_path = $cp
                    system_name     = "$($liveCon.system_name)"
                    client          = "$($liveCon.client)"
                    user            = "$($liveCon.user)"
                    description     = "$($liveCon.description)"
                    logon_id        = "$($liveCon.logon_id)"
                    entries         = @()
                }
                $reg.connections += $newBlock
                $byCon[$cp] = $newBlock
            }
            $cb = $byCon[$cp]

            # Refresh per-connection metadata in case logon_id was newly known.
            if (-not $cb.system_name) { $cb.system_name = "$($liveCon.system_name)" }
            if (-not $cb.client)      { $cb.client      = "$($liveCon.client)" }
            if (-not $cb.user)        { $cb.user        = "$($liveCon.user)" }
            if (-not $cb.description) { $cb.description = "$($liveCon.description)" }
            if (-not $cb.logon_id)    { $cb.logon_id    = "$($liveCon.logon_id)" }

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
                    owner_pid      = 0
                    owner_skill    = ''
                    status         = $status
                    claim_time     = ''
                    ttl_seconds    = $TtlSeconds
                    discovered     = $true
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
        [void](Sweep-StaleEntries -Registry $reg -VerboseDrops $false)

        # Idempotent re-acquire: same task_id with a still-live claim wins
        # regardless of connection target.
        foreach ($cb in $reg.connections) {
            $hit = $cb.entries | Where-Object {
                $_.task_id -eq $TaskId -and $_.status -eq 'claimed'
            } | Select-Object -First 1
            if ($hit) {
                $hit.claim_time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
                Write-Registry -Registry $reg
                $script:Result = "ACQUIRED: path=$($hit.path) sessionNumber=$($hit.session_number) connection=$($cb.connection_path) reused=true"
                return
            }
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
            $script:Result = "DENIED: $($target.error)"
            return
        }
        $targetCon = $target.connection_path

        # Locate (or create) the registry block for this connection.
        $cb = $reg.connections | Where-Object { $_.connection_path -eq $targetCon } | Select-Object -First 1
        if (-not $cb) {
            # The connection exists in SAP but not yet in our registry —
            # discover would normally create it. Inline the registration here.
            $liveCon = $null
            $state = Get-SapState
            if ($state) { $liveCon = $state.connections | Where-Object { "$($_.connection_path)" -eq $targetCon } | Select-Object -First 1 }
            if (-not $liveCon) {
                $script:Result = "DENIED: target connection $targetCon disappeared during acquire"
                return
            }
            $cb = @{
                connection_path = "$($liveCon.connection_path)"
                system_name     = "$($liveCon.system_name)"
                client          = "$($liveCon.client)"
                user            = "$($liveCon.user)"
                description     = "$($liveCon.description)"
                logon_id        = "$($liveCon.logon_id)"
                entries         = @()
            }
            $reg.connections += $cb
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
                $script:Result = "DENIED: no free session on $targetCon and spawn failed (cap reached or SAP GUI unreachable)"
                return
            }
            $chosen = @{
                path           = "$($newSes.path)"
                session_number = [int]$newSes.session_number
                task_id        = ''
                owner_pid      = 0
                owner_skill    = ''
                status         = 'free'
                claim_time     = ''
                ttl_seconds    = $TtlSeconds
                discovered     = $false
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
        $chosen.task_id     = $TaskId
        $chosen.owner_pid   = if ($OwnerPid -gt 0) { $OwnerPid } else { 0 }
        $chosen.owner_skill = $OwnerSkill
        $chosen.status      = 'claimed'
        $chosen.claim_time  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        $chosen.ttl_seconds = $TtlSeconds

        Write-Registry -Registry $reg
        $script:Result = "ACQUIRED: path=$($chosen.path) sessionNumber=$($chosen.session_number) connection=$targetCon reused=$(-not $spawned)"
    }

    Write-Host $script:Result
    if ($script:Result.StartsWith('DENIED')) { exit 1 }
}

# ===========================================================================
# Action: release — find claim by task_id across all connections.
# ===========================================================================

function Invoke-Release {
    if ($TaskId -eq '') {
        Write-Host 'ERROR: -TaskId is required for release'
        exit 2
    }
    $script:Result = ''
    With-RegistryLock {
        $reg = Read-Registry
        [void](Sweep-StaleEntries -Registry $reg -VerboseDrops $false)

        $matched = $null
        foreach ($cb in $reg.connections) {
            $hit = $cb.entries | Where-Object { $_.task_id -eq $TaskId -and $_.status -eq 'claimed' } | Select-Object -First 1
            if ($hit) { $matched = @{ block = $cb; entry = $hit }; break }
        }
        if (-not $matched) { $script:Result = 'NOT_FOUND'; return }

        # Best-effort reset to Easy Access.
        $snap = Resolve-SapSessionSnap -Path $matched.entry.path
        if ($snap) { [void](Reset-SessionToEasyAccess -Path $matched.entry.path) }

        $matched.entry.task_id     = ''
        $matched.entry.owner_pid   = 0
        $matched.entry.owner_skill = ''
        $matched.entry.status      = 'free'
        $matched.entry.claim_time  = ''

        Write-Registry -Registry $reg
        $script:Result = "RELEASED: path=$($matched.entry.path) connection=$($matched.block.connection_path)"
    }
    Write-Host $script:Result
}

# ===========================================================================
# Dispatch
# ===========================================================================

switch ($Action) {
    'list'     { Invoke-List }
    'discover' { Invoke-Discover }
    'gc'       { Invoke-Gc }
    'acquire'  { Invoke-Acquire }
    'release'  { Invoke-Release }
}
exit 0
