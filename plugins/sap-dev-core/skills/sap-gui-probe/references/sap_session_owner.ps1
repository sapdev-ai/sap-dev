# =============================================================================
# sap_session_owner.ps1
# -----------------------------------------------------------------------------
# Session-ownership lock helper for parallel SAP GUI skill execution.
#
# When multiple AI sub-agents (or AI sessions) drive SAP GUI in parallel,
# each one needs to claim a specific session (e.g. /app/con[0]/ses[1]) and
# release it on exit. Without coordination, two agents can both attach to
# the first session they find (the historical "For Each Children" idiom)
# and trample each other.
#
# This script writes a sidecar JSON to {WORK_TEMP}\session_locks\<escaped_path>.lock
# describing who owns the session, when, and from which run. Other agents
# can check the lock before claiming. The lock is advisory -- the SAP GUI
# Scripting API has no native concept of "session is in use" -- but it
# catches the common case where two parallel probes pick the same session
# by accident.
#
# Lock layout: one JSON file per session path, named by sanitizing the
# path (replace / [ ] with _). E.g. /app/con[0]/ses[1] -> _app_con_0__ses_1_.lock
#
# File content (UTF-8 no BOM):
#   {
#     "session_path": "/app/con[0]/ses[1]",
#     "owner_pid":     12345,
#     "owner_run_id":  "abc12345",
#     "owner_skill":   "sap-gui-probe",
#     "claimed_at":    "2026-05-14T10:30:00",
#     "ttl_seconds":   600
#   }
#
# Stale locks: claims older than ttl_seconds are treated as stale and can
# be overwritten. Default TTL = 600s (10 min) -- long enough for any single
# probe / skill run, short enough that a crashed agent's lock doesn't
# permanently block the session.
#
# Usage:
#
#   # Claim a session (writes the lock, fails if another live lock exists)
#   pwsh -File sap_session_owner.ps1 -Action claim `
#       -SessionPath "/app/con[0]/ses[1]" `
#       -OwnerSkill  "sap-gui-probe" `
#       -OwnerRunId  $env:SAPDEV_RUN_ID `
#       -WorkTemp    "C:\sap_dev_work\temp"
#   # Last line: "CLAIMED" or "DENIED: held by <owner_skill> pid=<pid> age=<sec>"
#
#   # Check (read-only, no side effects)
#   pwsh -File sap_session_owner.ps1 -Action check -SessionPath "..." -WorkTemp ...
#   # Last line: "FREE" or "HELD: <owner_skill> pid=<pid> age=<sec>"
#
#   # Release (deletes the lock; no-op if missing)
#   pwsh -File sap_session_owner.ps1 -Action release -SessionPath "..." -WorkTemp ...
#   # Last line: "RELEASED"
#
# Exit codes:
#   0 = success (CLAIMED / FREE / RELEASED)
#   1 = claim denied (held by another live owner)
#   2 = bad arguments / IO failure
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('claim', 'check', 'release')]
    [string] $Action,

    [Parameter(Mandatory = $true)]
    [string] $SessionPath,

    [Parameter(Mandatory = $true)]
    [string] $WorkTemp,

    [string] $OwnerSkill = '',
    [string] $OwnerRunId = '',
    [int]    $TtlSeconds = 600
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve the lock file path. Sanitize the session path so it's filesystem-
# safe -- replace /, [, ] with _; collapse runs of _; trim trailing _.
# ---------------------------------------------------------------------------
$lockDir = Join-Path $WorkTemp 'session_locks'
if (-not (Test-Path $lockDir)) {
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
}

$sanitized = $SessionPath -replace '[/\[\]]', '_'
$sanitized = $sanitized -replace '_+', '_'
$sanitized = $sanitized.TrimEnd('_')
$lockFile  = Join-Path $lockDir ($sanitized + '.lock')

# ---------------------------------------------------------------------------
# Read the existing lock (if any) and decide whether it is live or stale.
# ---------------------------------------------------------------------------
function Read-Lock {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if (-not $raw) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        # Malformed lock -- treat as missing so a fresh claim can overwrite.
        return $null
    }
}

function Is-LockLive {
    param($Lock, [int] $Ttl)
    if (-not $Lock) { return $false }
    if (-not $Lock.claimed_at) { return $false }
    try {
        $claimed = [datetime]::Parse($Lock.claimed_at)
    } catch {
        return $false
    }
    $age = (Get-Date) - $claimed
    return ($age.TotalSeconds -lt $Ttl)
}

function Format-LockSummary {
    param($Lock)
    if (-not $Lock) { return '(no lock)' }
    $age = '?'
    try {
        $claimed = [datetime]::Parse($Lock.claimed_at)
        $age = [int]((Get-Date) - $claimed).TotalSeconds
    } catch {}
    return "$($Lock.owner_skill) pid=$($Lock.owner_pid) age=${age}s"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
switch ($Action) {

    'check' {
        $lock = Read-Lock $lockFile
        if ((Is-LockLive -Lock $lock -Ttl $TtlSeconds)) {
            Write-Host "HELD: $(Format-LockSummary $lock)"
        } else {
            Write-Host 'FREE'
        }
        exit 0
    }

    'release' {
        if (Test-Path $lockFile) {
            try { Remove-Item -Path $lockFile -Force } catch {}
        }
        Write-Host 'RELEASED'
        exit 0
    }

    'claim' {
        $existing = Read-Lock $lockFile
        if (Is-LockLive -Lock $existing -Ttl $TtlSeconds) {
            # Same owner? Allow re-claim (idempotent for the same run).
            if ($existing.owner_pid -eq $PID -and
                $existing.owner_run_id -eq $OwnerRunId) {
                # Touch the claimed_at timestamp.
            } else {
                Write-Host ("DENIED: held by " + (Format-LockSummary $existing))
                exit 1
            }
        }

        $record = [ordered]@{
            session_path = $SessionPath
            owner_pid    = $PID
            owner_run_id = $OwnerRunId
            owner_skill  = $OwnerSkill
            claimed_at   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
            ttl_seconds  = $TtlSeconds
        }
        $json = ($record | ConvertTo-Json -Compress)
        [System.IO.File]::WriteAllText($lockFile, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Host 'CLAIMED'
        exit 0
    }
}
