# =============================================================================
# sap_su01_store.ps1  -  Test-user registry for /sap-su01 (LOCAL, no SAP)
#
# Tracks skill-created test users so cleanup (even in a LATER session) can find
# and remove them. JSONL (one flat object per line) at a predictable path -
# {work_dir}\runtime\su01_test_users.jsonl - keyed per (SID, client). Passwords
# are stored ONLY as dpapi:<b64> (never plaintext), mirroring connections.json.
#
#   upsert -Sid -Client -User [-Roles a,b] [-PwdDpapi dpapi:..] [-RunId ..]
#   remove -Sid -Client -User
#   list   [-Sid -Client]        # all skill-owned users (optionally scoped)
#   isowned -Sid -Client -User   # OWNED / NOT_OWNED (drives the delete confirm tier)
#
# Output (stdout): parseable line(s) + STATUS: OK | NOT_FOUND
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,
    [string] $Sid = '', [string] $Client = '', [string] $User = '',
    [string] $Roles = '', [string] $PwdDpapi = '', [string] $RunId = '',
    [string] $StorePath = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $StorePath) {
    $sh = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared\scripts')).Path
    . (Join-Path $sh 'sap_connection_lib.ps1')
    $StorePath = Join-Path (Join-Path (Get-SapWorkDir) 'runtime') 'su01_test_users.jsonl'
}
$dir = Split-Path $StorePath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

function Read-Entries {
    if (-not (Test-Path $StorePath)) { return @() }
    $out = @()
    foreach ($ln in [System.IO.File]::ReadAllLines($StorePath)) { if ($ln.Trim()) { try { $out += ($ln | ConvertFrom-Json) } catch {} } }
    return @($out)
}
function Write-Entries { param([object[]] $Entries)
    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $Entries) { [void]$sb.AppendLine(($e | ConvertTo-Json -Compress -Depth 6)) }
    [System.IO.File]::WriteAllText($StorePath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}
function Same { param($e) return ("$($e.sid)".ToUpper() -eq $Sid.ToUpper() -and "$($e.client)" -eq $Client -and "$($e.user)".ToUpper() -eq $User.ToUpper()) }

switch ($Action.ToLower()) {
    'upsert' {
        $entries = @(Read-Entries | Where-Object { -not (Same $_) })
        $rec = [ordered]@{ sid=$Sid.ToUpper(); client=$Client; user=$User.ToUpper(); created_ts=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'); created_by_run=$RunId; roles=@($Roles -split '[,; ]+' | Where-Object { $_ }); pwd_dpapi=$PwdDpapi }
        $entries += [pscustomobject]$rec
        Write-Entries $entries
        Write-Host ("UPSERT: user={0} sid={1} client={2}" -f $User.ToUpper(), $Sid.ToUpper(), $Client); Write-Host "STATUS: OK"; exit 0
    }
    'remove' {
        $all = Read-Entries; $kept = @($all | Where-Object { -not (Same $_) })
        Write-Entries $kept
        Write-Host ("REMOVE: user={0} removed={1}" -f $User.ToUpper(), ($all.Count - $kept.Count)); Write-Host "STATUS: OK"; exit 0
    }
    'isowned' {
        $owned = @(Read-Entries | Where-Object { Same $_ }).Count -gt 0
        Write-Host $(if ($owned) { "OWNED: user=$($User.ToUpper())" } else { "NOT_OWNED: user=$($User.ToUpper())" }); Write-Host "STATUS: OK"; exit 0
    }
    'list' {
        $entries = Read-Entries
        if ($Sid) { $entries = @($entries | Where-Object { "$($_.sid)".ToUpper() -eq $Sid.ToUpper() -and (-not $Client -or "$($_.client)" -eq $Client) }) }
        foreach ($e in $entries) { Write-Host ("TESTUSER: user={0} sid={1} client={2} created_ts={3} roles={4}" -f "$($e.user)", "$($e.sid)", "$($e.client)", "$($e.created_ts)", (@($e.roles) -join ',')) }
        Write-Host ("STATUS: OK count={0}" -f @($entries).Count); exit 0
    }
    default { Write-Host "STATUS: NOT_FOUND"; Write-Host "ERROR: unknown action $Action"; exit 1 }
}
