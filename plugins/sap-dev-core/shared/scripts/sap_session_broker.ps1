# =============================================================================
# sap_session_broker.ps1
# -----------------------------------------------------------------------------
# Cross-process broker for SAP GUI session ownership.
#
# Coordinates which AI task (sub-agent / skill run) is allowed to drive which
# SAP GUI session at any moment, without requiring a long-running process.
# State lives in a single JSON file under {WORK_TEMP}\session_registry.json;
# concurrent access is serialized via a named Windows mutex.
#
# Contract — what the broker promises:
#   * Mutual exclusion: at any instant, at most one task_id holds a "claimed"
#     entry for any given session path.
#   * Reactive cleanup: every acquire/release call drops entries that no
#     longer reflect reality (session window closed, owner process died,
#     TTL expired, user logged out).
#   * Spawn-on-demand: if no free session exists, the broker spawns one
#     via /oSESSION_MANAGER (the only OK-code reliably honoured on the
#     S/4HANA 1909 kernel 754 build verified during design).
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
# Cross-process locking: a Windows named mutex `SapDevSessionBroker_v1`.
# All registry reads and writes happen inside the mutex. Hold time per
# call is millisecond-scale; the 10s timeout is for crash recovery only.
#
# Usage:
#
#   acquire — claim a session for a task (spawns one if needed)
#     pwsh -File sap_session_broker.ps1 -Action acquire `
#         -TaskId      "agent_a83f96..." `
#         -OwnerSkill  "sap-se38-create" `
#         -WorkTemp    "C:\sap_dev_work\temp"
#     [-SessionPath  "/app/con[0]/ses[1]"]   # optional preference
#     [-ConnectionPath "/app/con[0]"]         # for spawn fallback
#     [-TtlSeconds 600]
#
#     stdout LAST line on success:
#       ACQUIRED: path=/app/con[0]/ses[1] sessionNumber=2 reused=true|false
#     stdout LAST line on failure:
#       DENIED: <reason>   (exit 1)
#       ERROR:  <reason>   (exit 2)
#
#   release — drop a claim (resets the session to Easy Access first)
#     pwsh -File sap_session_broker.ps1 -Action release `
#         -TaskId  "agent_a83f96..." `
#         -WorkTemp "C:\sap_dev_work\temp"
#
#     stdout: RELEASED: path=...   |   NOT_FOUND   |   ERROR: ...
#
#   gc — sweep stale entries without acquiring
#     pwsh -File sap_session_broker.ps1 -Action gc -WorkTemp "..."
#     stdout: GC: dropped <n> stale entries  + one line per drop with reason
#
#   list — read-only snapshot
#     pwsh -File sap_session_broker.ps1 -Action list -WorkTemp "..."
#     stdout: registry contents (JSON, pretty-printed)
#
#   discover — pre-flight: register any pre-existing sessions
#     pwsh -File sap_session_broker.ps1 -Action discover -WorkTemp "..."
#     stdout: DISCOVERED: <n> sessions (<f> free, <u> user-owned)
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('acquire', 'release', 'gc', 'list', 'discover')]
    [string] $Action,

    [Parameter(Mandatory = $true)]
    [string] $WorkTemp,

    [string] $TaskId = '',
    [string] $OwnerSkill = '',
    [string] $SessionPath = '',
    [string] $ConnectionPath = '/app/con[0]',
    [int]    $TtlSeconds = 600,

    # PID of the CALLER process (the skill / agent / task that wants the
    # claim), NOT the broker itself. Callers should pass their own $PID
    # so the broker can detect when the owning task crashes. If omitted
    # or 0, the broker skips the dead-task check for this entry and
    # relies solely on TTL for cleanup.
    [int]    $OwnerPid = 0
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:RegistryFile = Join-Path $WorkTemp 'session_registry.json'
$script:MutexName    = 'SapDevSessionBroker_v1'
$script:MutexTimeout = 10000      # ms; broker calls should complete in <500ms

# Resolve the COM helper. It lives next to this script in shared/scripts.
$script:ComHelperVbs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'sap_session_broker_com.vbs'
$script:Cscript      = 'C:\Windows\SysWOW64\cscript.exe'

# Ensure the work-temp folder exists (registry file lives inside it).
if (-not (Test-Path $WorkTemp)) {
    New-Item -ItemType Directory -Path $WorkTemp -Force | Out-Null
}

# Per-invocation cache for SAP state — INFO is moderately expensive (~100ms
# for the cscript spawn), so we resolve it lazily and reuse within one
# broker call.
$script:CachedInfo = $null

# ===========================================================================
# Mutex helpers
# ===========================================================================

function With-RegistryLock {
    <#
    .SYNOPSIS
        Run a scriptblock while holding the cross-process registry mutex.
        Ensures the mutex is released even if the scriptblock throws.

    .NOTES
        Hold time should be milliseconds. The 10s WaitOne timeout is for
        crash recovery (Windows releases mutexes on process exit, so this
        path almost never fires in practice). If WaitOne times out the
        function throws — callers should NOT retry blindly.
    #>
    param([scriptblock] $Body)

    $mutex = [System.Threading.Mutex]::new($false, $script:MutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($script:MutexTimeout)
        } catch [System.Threading.AbandonedMutexException] {
            # Previous holder process crashed without releasing. We now own
            # the mutex (the exception itself confirms acquisition).
            $acquired = $true
        }
        if (-not $acquired) {
            throw "could not acquire registry mutex within $($script:MutexTimeout)ms"
        }
        & $Body
    } finally {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        try { $mutex.Dispose() } catch {}
    }
}

# ===========================================================================
# Registry I/O
# ===========================================================================

function Read-Registry {
    <#
    .SYNOPSIS
        Read the registry JSON. Returns a hashtable with `logon_id` and
        `entries` keys. Returns an empty registry on missing/malformed file.
    #>
    if (-not (Test-Path $script:RegistryFile)) {
        return @{
            logon_id   = ''
            updated_at = ''
            entries    = @()
        }
    }
    try {
        $raw = Get-Content -Path $script:RegistryFile -Raw -Encoding UTF8
        if (-not $raw -or $raw.Trim() -eq '') {
            return @{ logon_id = ''; updated_at = ''; entries = @() }
        }
        $obj = $raw | ConvertFrom-Json
        # Normalise to hashtable so we can mutate freely.
        $entries = @()
        if ($obj.entries) {
            foreach ($e in $obj.entries) {
                $entries += @{
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
        return @{
            logon_id   = "$($obj.logon_id)"
            updated_at = "$($obj.updated_at)"
            entries    = $entries
        }
    } catch {
        # Malformed JSON — treat as empty so a fresh write can overwrite.
        Write-Host "WARN: registry file unreadable ($($_.Exception.Message)); resetting"
        return @{ logon_id = ''; updated_at = ''; entries = @() }
    }
}

function Write-Registry {
    param([hashtable] $Registry)
    $Registry.updated_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $json = $Registry | ConvertTo-Json -Depth 5
    # UTF-8 without BOM so cscript-side helpers can ADODB-Stream-load it.
    [System.IO.File]::WriteAllText(
        $script:RegistryFile,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

# ===========================================================================
# SAP GUI introspection — shells out to the 32-bit cscript COM helper
# because PowerShell 7+ / .NET 5+ cannot bind to the SAP GUI Scripting
# Engine directly (GetActiveObject is removed in .NET 5+, and even
# 32-bit Windows PowerShell 5.1 fails because the SAPGUI ProgID isn't
# in the Running Object Table). cscript 32-bit handles it fine.
# ===========================================================================

function Invoke-ComHelper {
    <#
    .SYNOPSIS
        Run the cscript COM helper with the given args. Returns the parsed
        JSON object from its stdout (one-line JSON convention). Throws on
        cscript launch failure; returns the object with .ok=false for
        command-level failures (caller decides how to handle).
    #>
    param([Parameter(Mandatory)][string[]] $Args)

    $cscriptArgs = @('//NoLogo', $script:ComHelperVbs) + $Args
    $raw = & $script:Cscript @cscriptArgs 2>&1
    $exit = $LASTEXITCODE
    if (-not $raw) {
        return @{ ok = $false; error = "com helper produced no output (exit=$exit)" }
    }
    # Helper writes one line of JSON. Pick the last non-empty line.
    $jsonLine = ($raw | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
    if (-not $jsonLine) {
        return @{ ok = $false; error = "com helper output not JSON: $raw" }
    }
    try {
        $obj = $jsonLine | ConvertFrom-Json
    } catch {
        return @{ ok = $false; error = "com helper JSON parse failed: $($_.Exception.Message)" }
    }
    # Normalise to a hashtable so the rest of the broker can probe properties.
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Get-SapState {
    <#
    .SYNOPSIS
        Return the cached SAP state (logon_id + sessions[]), loading it
        via INFO on first call within this broker invocation. Returns
        $null if SAP GUI is unreachable.
    #>
    if ($null -ne $script:CachedInfo) { return $script:CachedInfo }
    $info = Invoke-ComHelper -Args @('INFO')
    if (-not $info.ok) {
        $script:CachedInfo = $null
        return $null
    }
    $script:CachedInfo = $info
    return $info
}

function Invalidate-SapStateCache {
    # Call this after any operation that changes SAP state (SPAWN, RESET).
    $script:CachedInfo = $null
}

function Resolve-SapSession {
    <#
    .SYNOPSIS
        Return a hashtable describing the session at $Path, or $null if
        the path no longer resolves. Hashtable has .transaction, .screen,
        .has_popup, .session_number.
    #>
    param([string] $Path)
    $state = Get-SapState
    if (-not $state) { return $null }
    foreach ($s in $state.sessions) {
        if ("$($s.path)" -eq $Path) {
            return @{
                path           = "$($s.path)"
                session_number = [int]$s.session_number
                transaction    = "$($s.transaction)"
                screen         = [int]$s.screen
                has_popup      = [bool]$s.has_popup
            }
        }
    }
    return $null
}

function Get-CurrentLogonId {
    $state = Get-SapState
    if (-not $state) { return '' }
    return "$($state.logon_id)"
}

function Is-SessionAtEasyAccess {
    param($Snap)   # hashtable returned by Resolve-SapSession
    if (-not $Snap) { return $false }
    $txn = "$($Snap.transaction)"
    if ($txn -ne '' -and $txn -ne 'SMEN' -and $txn -ne 'S000') { return $false }
    if ($Snap.has_popup) { return $false }
    return $true
}

# ===========================================================================
# Process liveness — used to detect crashed task owners.
# ===========================================================================

function Is-ProcessAlive {
    # NOTE: parameter is named ProcessId because $Pid is a PowerShell
    # automatic read-only variable; you cannot bind to a param named $Pid.
    param([int] $ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return ($null -ne $p)
    } catch {
        return $false
    }
}

# ===========================================================================
# Reactive cleanup sweep — drops entries that don't reflect reality.
# Called from inside the mutex by acquire/release/gc.
# ===========================================================================

function Sweep-StaleEntries {
    <#
    .SYNOPSIS
        Mutate $Registry in place, dropping stale entries. Emits one
        `DROP: ...` line per drop with the reason. Returns the count of
        drops as an integer.

    .PARAMETER VerboseDrops
        When $true, emit DROP lines to stdout. Acquire/release call with
        $false; gc calls with $true.
    #>
    param(
        [hashtable] $Registry,
        [bool]      $VerboseDrops = $false
    )

    $dropCount = 0

    # --- Mode 4: logout + relogin (logon GUID changed) ---
    $currentLogon = Get-CurrentLogonId
    if ($currentLogon -ne '' -and
        $Registry.logon_id -ne '' -and
        $Registry.logon_id -ne $currentLogon) {
        # All entries are stale.
        $oldCount = $Registry.entries.Count
        if ($VerboseDrops) {
            foreach ($e in $Registry.entries) {
                Write-Host "DROP: $($e.path) reason=logon_changed (was $($Registry.logon_id))"
            }
        }
        $Registry.entries = @()
        $Registry.logon_id = $currentLogon
        $dropCount += $oldCount
        return $dropCount
    }
    if ($currentLogon -ne '' -and $Registry.logon_id -eq '') {
        # First time we've recorded a logon ID — stamp it.
        $Registry.logon_id = $currentLogon
    }

    $now = Get-Date
    $survivors = @()
    foreach ($e in $Registry.entries) {
        $drop = $false
        $reason = ''

        # --- Mode 1: window closed ---
        $oSes = Resolve-SapSession -Path $e.path
        if (-not $oSes) {
            $drop = $true
            $reason = 'session_closed'
        }

        # --- Mode 2: owner process died (claimed only) ---
        if (-not $drop -and $e.status -eq 'claimed' -and $e.owner_pid -gt 0) {
            if (-not (Is-ProcessAlive -ProcessId $e.owner_pid)) {
                $drop = $true
                $reason = "pid_dead (pid=$($e.owner_pid))"
            }
        }

        # --- Mode 3: TTL expired (claimed only) ---
        if (-not $drop -and $e.status -eq 'claimed' -and $e.claim_time) {
            try {
                $claimed = [datetime]::Parse($e.claim_time)
                $age = ($now - $claimed).TotalSeconds
                if ($age -gt $e.ttl_seconds) {
                    $drop = $true
                    $reason = "ttl_expired (age=$([int]$age)s ttl=$($e.ttl_seconds)s)"
                }
            } catch {
                # Malformed claim_time — drop conservatively.
                $drop = $true
                $reason = 'bad_claim_time'
            }
        }

        if ($drop) {
            if ($VerboseDrops) {
                Write-Host "DROP: $($e.path)  task=$($e.task_id)  reason=$reason"
            }
            $dropCount += 1
        } else {
            $survivors += $e
        }
    }

    $Registry.entries = $survivors
    return $dropCount
}

# ===========================================================================
# Session spawning — used by acquire when no free entry exists.
# ===========================================================================

function Spawn-NewSession {
    <#
    .SYNOPSIS
        Spawn a new SAP GUI session via the COM helper. Returns a
        hashtable with .path and .session_number on success, $null on
        failure. Invalidates the cached INFO so subsequent calls see
        the new state.
    #>
    $result = Invoke-ComHelper -Args @('SPAWN')
    Invalidate-SapStateCache
    if (-not $result.ok) { return $null }
    return @{
        path           = "$($result.path)"
        session_number = [int]$result.session_number
    }
}

function Reset-SessionToEasyAccess {
    <#
    .SYNOPSIS
        Send /n to the given path via the COM helper. Returns $true on
        success, $false otherwise.
    #>
    param([string] $Path)
    $result = Invoke-ComHelper -Args @('RESET', $Path)
    Invalidate-SapStateCache
    return [bool]$result.ok
}

# ===========================================================================
# Action: list
# ===========================================================================

function Invoke-List {
    With-RegistryLock {
        $reg = Read-Registry
        Write-Host ($reg | ConvertTo-Json -Depth 5)
    }
}

# ===========================================================================
# Action: discover  — register any pre-existing sessions
# ===========================================================================

function Invoke-Discover {
    With-RegistryLock {
        $reg = Read-Registry
        [void](Sweep-StaleEntries -Registry $reg -VerboseDrops $false)

        $state = Get-SapState
        if (-not $state) {
            Write-Host 'ERROR: SAP GUI not running or connection not found'
            exit 2
        }

        $existing = @{}
        foreach ($e in $reg.entries) { $existing[$e.path] = $true }

        $registered = 0
        $freeCount  = 0
        $userOwned  = 0
        foreach ($s in $state.sessions) {
            $path = "$($s.path)"
            if ($existing.ContainsKey($path)) {
                $found = $reg.entries | Where-Object { $_.path -eq $path } | Select-Object -First 1
                if ($found.status -eq 'free')           { $freeCount += 1 }
                elseif ($found.status -eq 'user_owned') { $userOwned += 1 }
                continue
            }
            $snap = @{
                path           = "$($s.path)"
                session_number = [int]$s.session_number
                transaction    = "$($s.transaction)"
                screen         = [int]$s.screen
                has_popup      = [bool]$s.has_popup
            }
            $status = if (Is-SessionAtEasyAccess -Snap $snap) { 'free' } else { 'user_owned' }
            $reg.entries += @{
                path           = $snap.path
                session_number = $snap.session_number
                task_id        = ''
                owner_pid      = 0
                owner_skill    = ''
                status         = $status
                claim_time     = ''
                ttl_seconds    = $TtlSeconds
                discovered     = $true
            }
            $registered += 1
            if ($status -eq 'free') { $freeCount += 1 } else { $userOwned += 1 }
        }

        Write-Registry -Registry $reg
        Write-Host "DISCOVERED: $registered new (total free=$freeCount user_owned=$userOwned)"
    }
}

# ===========================================================================
# Action: gc — sweep without acquiring
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
# Action: acquire — claim a session for a task
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

        # If this task already has an active claim, return it idempotently.
        $existing = $reg.entries | Where-Object {
            $_.task_id -eq $TaskId -and $_.status -eq 'claimed'
        } | Select-Object -First 1

        if ($existing) {
            # Refresh claim_time so long-running tasks don't TTL-expire.
            $existing.claim_time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
            Write-Registry -Registry $reg
            $script:Result = "ACQUIRED: path=$($existing.path) sessionNumber=$($existing.session_number) reused=true"
            return
        }

        # Try the explicit SessionPath preference first if supplied.
        $chosen = $null
        if ($SessionPath -ne '') {
            $chosen = $reg.entries | Where-Object {
                $_.path -eq $SessionPath -and $_.status -eq 'free'
            } | Select-Object -First 1
            if (-not $chosen) {
                # Preference unavailable — fall through to general allocation.
                $chosen = $null
            }
        }

        # Pick any free entry.
        if (-not $chosen) {
            $chosen = $reg.entries | Where-Object { $_.status -eq 'free' } | Select-Object -First 1
        }

        # None free — spawn one.
        $spawned = $false
        if (-not $chosen) {
            $newSes = Spawn-NewSession
            if (-not $newSes) {
                $script:Result = 'DENIED: no free session and spawn failed (cap reached or SAP GUI not running)'
                return
            }
            $newEntry = @{
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
            $reg.entries += $newEntry
            $chosen = $newEntry
            $spawned = $true
        }

        # Pre-allocation Easy-Access verification. If the session drifted from
        # Easy Access between discover and acquire, drive it back.
        $snap = Resolve-SapSession -Path $chosen.path
        if (-not $snap) {
            # Race: session disappeared between sweep and resolve. Drop and fail.
            $reg.entries = $reg.entries | Where-Object { $_.path -ne $chosen.path }
            Write-Registry -Registry $reg
            $script:Result = 'DENIED: chosen session disappeared during acquire (retry)'
            return
        }
        if (-not (Is-SessionAtEasyAccess -Snap $snap)) {
            $resetOk = Reset-SessionToEasyAccess -Path $chosen.path
            $snap = Resolve-SapSession -Path $chosen.path
            if ((-not $resetOk) -or (-not (Is-SessionAtEasyAccess -Snap $snap))) {
                $chosen.status = 'user_owned'
                Write-Registry -Registry $reg
                $script:Result = 'DENIED: chosen session could not be returned to Easy Access (marked user_owned; retry)'
                return
            }
        }

        # Claim it. owner_pid is the CALLER's PID (passed in), not the
        # broker's own PID -- the broker process is transient.
        $chosen.task_id     = $TaskId
        $chosen.owner_pid   = if ($OwnerPid -gt 0) { $OwnerPid } else { 0 }
        $chosen.owner_skill = $OwnerSkill
        $chosen.status      = 'claimed'
        $chosen.claim_time  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        $chosen.ttl_seconds = $TtlSeconds

        Write-Registry -Registry $reg
        $script:Result = "ACQUIRED: path=$($chosen.path) sessionNumber=$($chosen.session_number) reused=$(-not $spawned)"
    }

    Write-Host $script:Result
    if ($script:Result.StartsWith('DENIED')) { exit 1 }
}

# ===========================================================================
# Action: release — drop a claim, reset the session to Easy Access
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

        $entry = $reg.entries | Where-Object {
            $_.task_id -eq $TaskId -and $_.status -eq 'claimed'
        } | Select-Object -First 1

        if (-not $entry) {
            $script:Result = 'NOT_FOUND'
            return
        }

        # Best-effort reset to Easy Access. If the session was destroyed
        # mid-task, this is a no-op (the COM helper will report ok=false
        # and we just continue to free the registry entry).
        $snap = Resolve-SapSession -Path $entry.path
        if ($snap) { [void](Reset-SessionToEasyAccess -Path $entry.path) }

        # Return the entry to free state (preserve the slot for reuse).
        $entry.task_id     = ''
        $entry.owner_pid   = 0
        $entry.owner_skill = ''
        $entry.status      = 'free'
        $entry.claim_time  = ''

        Write-Registry -Registry $reg
        $script:Result = "RELEASED: path=$($entry.path)"
    }
    Write-Host $script:Result
}

# ===========================================================================
# Main dispatch
# ===========================================================================

switch ($Action) {
    'list'     { Invoke-List }
    'discover' { Invoke-Discover }
    'gc'       { Invoke-Gc }
    'acquire'  { Invoke-Acquire }
    'release'  { Invoke-Release }
}
exit 0
