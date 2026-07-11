# =============================================================================
# sap_sm12_liveness.ps1  -  /sap-sm12 release-mode owner-liveness GATE
#
# Proves whether the lock owner still has ANY session anywhere before a release
# is allowed. The verdict logic lives ONLY here (single source of truth):
#
#   * Default run: TH_SERVER_LIST (server count) + TH_USER_LIST (connected-server
#     user list). n=1 -> connected server IS full coverage, verdict decided here.
#     n>1 -> connected-server absence is NOT enough; emit NEED_SYSTEMWIDE and
#     refuse as UNVERIFIABLE, so the SKILL runs the TH_SYSTEMWIDE_USER_LIST leg
#     through /sap-rfc-wrapper and re-invokes this script with -MergeUserList.
#   * -MergeUserList <file>: verdict from a precomputed cross-instance live-user
#     set (one BNAME per line) -- LIVE if the owner appears, else GONE.
#
# FAIL-SAFE: any RFC error, unparseable table, or zero servers -> UNVERIFIABLE
# (exit 2, a REFUSAL) -- never a false GONE. A false GONE would delete a live
# lock and can corrupt an in-flight transaction, so "couldn't check" == refuse.
#
# Exit: 0 = GONE (owner absent, coverage complete)
#       1 = LIVE (owner has a session -> release must refuse)
#       2 = UNVERIFIABLE / NEED_SYSTEMWIDE / RFC error (release must refuse)
#
# Read-only. Tokens: %%RFC_LIB_PS1%% %%SM12_LIB_PS1%%
#   %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%% %%SAP_USER%% %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$User,
    [string]$MergeUserList = ''
)
$ErrorActionPreference = 'Stop'
. "%%RFC_LIB_PS1%%"
. "%%SM12_LIB_PS1%%"
$U = $User.Trim().ToUpper()

function Deny([string]$reason, [string]$servers = '?') {
    Write-Host "REASON: $reason"
    Write-Host "LIVENESS: UNVERIFIABLE servers=$servers covered=0 user=$User"
    exit 2
}

# ---- Phase 2: verdict from a precomputed systemwide live-user set -----------
if ($MergeUserList) {
    if (-not (Test-Path $MergeUserList)) { Deny 'merge_file_missing' }
    $live = @(Get-Content -LiteralPath $MergeUserList -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
    if ($live -contains $U) {
        Write-Host "SESSION: user=$User source=systemwide"
        Write-Host "LIVENESS: LIVE servers=multi covered=all user=$User"; exit 1
    }
    Write-Host "LIVENESS: GONE servers=multi covered=all user=$User"; exit 0
}

# ---- Phase 1: connected-server read ----------------------------------------
$dest = Connect-SapRfc -Server "%%SAP_SERVER%%" -Sysnr "%%SAP_SYSNR%%" -Client "%%SAP_CLIENT%%" `
                       -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "SM12_LIVE"
if (-not $dest) { Deny 'rfc_connect_failed' }

# Server list (how many application servers must be covered). TH_SERVER_LIST
# splits across LIST + LIST_IPV6 (same server names) -> UNION distinct NAMEs.
try { $slt = Read-SapFmTables $dest ($dest.Repository.CreateFunction('TH_SERVER_LIST')) }
catch { Disconnect-SapRfc; Deny "th_server_list_failed:$($_.Exception.Message)" }
$srvVals = Get-SapFieldValues $slt @('NAME', 'APPLSERVER', 'SERVERNAME')
if (-not $srvVals.found) { Disconnect-SapRfc; Deny 'server_table_unparsed' }
$servers = $srvVals.values.Count
$srvDisp = Find-SapRichestTable $slt @('NAME', 'APPLSERVER', 'SERVERNAME')
if ($srvDisp) {
    foreach ($r in $srvDisp.rows) {
        $nm = $r[$srvDisp.field]; if (-not $nm) { continue }
        Write-Host "SERVER: name=$nm host=$(Get-SapRowValue $r @('HOST','HOSTNAME','HOST_NAME'))"
    }
}
if ($servers -lt 1) { Disconnect-SapRfc; Deny 'server_count_zero' '0' }

# User list on the connected server. TH_USER_LIST splits across LIST (often
# empty) + USRLIST (populated) -> UNION non-empty BNAMEs. Reading only one table
# by hash order would risk an empty decoy == a false GONE (S4D 2026-07-11).
try { $ult = Read-SapFmTables $dest ($dest.Repository.CreateFunction('TH_USER_LIST')) }
catch { Disconnect-SapRfc; Deny "th_user_list_failed:$($_.Exception.Message)" $servers }
$usrVals = Get-SapFieldValues $ult @('BNAME', 'USER', 'UNAME')
if (-not $usrVals.found) { Disconnect-SapRfc; Deny 'user_table_unparsed' $servers }
$liveHere = $usrVals.values   # distinct, non-empty, UPPER-cased

if ($liveHere -contains $U) {
    Write-Host "SESSION: user=$User source=connected_server"
    Write-Host "LIVENESS: LIVE servers=$servers covered=1 user=$User"; Disconnect-SapRfc; exit 1
}
if ($servers -le 1) {
    Write-Host "LIVENESS: GONE servers=$servers covered=1 user=$User"; Disconnect-SapRfc; exit 0
}
# n>1: absence on the connected server is not proof -- the SKILL must run the
# systemwide leg and re-invoke with -MergeUserList.
Write-Host "NEED_SYSTEMWIDE servers=$servers user=$User"
Write-Host "LIVENESS: UNVERIFIABLE servers=$servers covered=1 user=$User"
Disconnect-SapRfc
exit 2
