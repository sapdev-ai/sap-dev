# =============================================================================
# sap_sm12_list.ps1  -  /sap-sm12 list mode + release-mode re-reader / verifier
#
# Calls ENQUEUE_READ (the live enqueue table is in memory -- NEVER RFC_READ_TABLE
# on SEQG3) and renders the current lock entries with a computed AGE column and,
# with -WithLiveness, a BEST-EFFORT owner-liveness column (LIVE/GONE/UNKNOWN).
# The best-effort column is display only -- the AUTHORITATIVE release gate lives
# in sap_sm12_liveness.ps1, which also covers multi-instance systems.
#
# Doubles as the release-mode candidate re-reader and the post-delete verifier:
#   -ExpectGone  -> exit 0 only when 0 rows match the selectors (RELEASED),
#                   exit 1 otherwise (rows still present).
#
# Read-only. Connects via the pinned connection profile: the %%SAP_*%% tokens are
# left literal by the SKILL and Connect-SapRfc fills them from connections.json.
#
# Tokens: %%RFC_LIB_PS1%% %%SM12_LIB_PS1%%
#   %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%% %%SAP_USER%% %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
# =============================================================================
param(
    [string]$User        = '',
    [string]$Table       = '',
    [string]$LockArg     = '',      # GARG pattern (-like, '*' wildcards allowed)
    [string]$Client      = '',
    [switch]$AllClients,
    [int]   $OlderThanMin = 0,
    [int]   $Max         = 200,
    [string]$OutTsv      = '',
    [switch]$WithLiveness,
    [switch]$ExpectGone
)
$ErrorActionPreference = 'Stop'
. "%%RFC_LIB_PS1%%"
. "%%SM12_LIB_PS1%%"

$dest = Connect-SapRfc -Server "%%SAP_SERVER%%" -Sysnr "%%SAP_SYSNR%%" -Client "%%SAP_CLIENT%%" `
                       -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "SM12_LIST"
if (-not $dest) { Write-Host "STATUS: RFC_ERROR rfc_connect_failed"; exit 2 }

# ---- ENQUEUE_READ ----------------------------------------------------------
$enq = $null
try {
    $fn = $dest.Repository.CreateFunction('ENQUEUE_READ')
    # GCLIENT importing: '' = all clients; a value narrows server-side.
    $gcli = if ($AllClients) { '' } elseif ($Client) { $Client } else { '' }
    try { [void]$fn.SetValue('GCLIENT', $gcli) } catch { }
    $fn.Invoke($dest)
    $enq = $fn.GetTable('ENQ')
} catch {
    Disconnect-SapRfc
    Write-Host "STATUS: RFC_ERROR ENQUEUE_READ not RFC-callable here ($($_.Exception.Message)); on such systems read locks via Z_GENERIC_RFC_WRAPPER_TBL"
    exit 2
}

$serverNow = Get-SapServerNow $dest

# ---- filter ----------------------------------------------------------------
$rows = @()
$total = $enq.RowCount
for ($i = 0; $i -lt $total; $i++) {
    $enq.CurrentIndex = $i
    $gu = $enq.GetString('GUNAME').Trim(); $gc = $enq.GetString('GCLIENT').Trim()
    $gn = $enq.GetString('GNAME').Trim();  $ga = $enq.GetString('GARG').Trim()
    $gt = $enq.GetString('GTCODE').Trim(); $gd = $enq.GetString('GTDATE').Trim()
    $gm = $enq.GetString('GMODE').Trim();  $gtt = $enq.GetString('GTTIME').Trim()
    if ($User    -and ($gu -ine $User))       { continue }
    if ($Table   -and ($gn -ine $Table))      { continue }
    if ($LockArg -and ($ga -notlike $LockArg)) { continue }
    $age = Get-SapLockAgeMin $gd $gtt $serverNow
    if ($OlderThanMin -gt 0 -and ($age -lt 0 -or $age -lt $OlderThanMin)) { continue }
    $rows += [pscustomobject]@{ client = $gc; user = $gu; table = $gn; arg = $ga
        mode = $gm; tcode = $gt; gtdate = $gd; gttime = $gtt; age_min = $age }
}

# ---- release-mode verifier: only care whether anything matched -------------
if ($ExpectGone) {
    if ($rows.Count -gt 0) { Write-Host "STATUS: NOT_GONE n=$($rows.Count)"; Disconnect-SapRfc; exit 1 }
    Write-Host "STATUS: GONE n=0"; Disconnect-SapRfc; exit 0
}

# ---- best-effort liveness column (display only) ----------------------------
$liveSet = @{}; $servers = 0; $livenessOk = $false
if ($WithLiveness) {
    try {
        $slt = Read-SapFmTables $dest ($dest.Repository.CreateFunction('TH_SERVER_LIST'))
        $servers = (Get-SapFieldValues $slt @('NAME', 'APPLSERVER', 'SERVERNAME')).values.Count
        $ult = Read-SapFmTables $dest ($dest.Repository.CreateFunction('TH_USER_LIST'))
        $uv = Get-SapFieldValues $ult @('BNAME', 'USER', 'UNAME')   # union over LIST + USRLIST
        if ($uv.found) { foreach ($n in $uv.values) { $liveSet[$n] = $true }; $livenessOk = $true }
    } catch { $livenessOk = $false }
}
function Get-BestEffortLiveness([string]$u) {
    if (-not $WithLiveness -or -not $livenessOk) { return 'UNKNOWN' }
    if ($liveSet.ContainsKey($u.ToUpper())) { return 'LIVE' }
    if ($servers -eq 1) { return 'GONE' }
    return 'UNKNOWN'
}

# ---- emit ------------------------------------------------------------------
$shown = if ($Max -gt 0) { @($rows | Select-Object -First $Max) } else { $rows }
foreach ($r in $shown) {
    $ageDisp = if ($r.age_min -lt 0) { '?' } else { $r.age_min }
    Write-Host ("LOCK: client={0} user={1} table={2} arg={3} mode={4} tcode={5} age_min={6} liveness={7}" -f `
            $r.client, $r.user, $r.table, $r.arg, $r.mode, $r.tcode, $ageDisp, (Get-BestEffortLiveness $r.user))
}
if ($OutTsv) {
    $lines = @("client`tuser`ttable`targ`tmode`ttcode`tgtdate`tgttime`tage_min`tliveness")
    foreach ($r in $shown) {
        $lines += ($r.client, $r.user, $r.table, $r.arg, $r.mode, $r.tcode, $r.gtdate, $r.gttime, $r.age_min, (Get-BestEffortLiveness $r.user)) -join "`t"
    }
    [IO.File]::WriteAllText($OutTsv, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
    Write-Host "OUT_TSV: $OutTsv rows=$($shown.Count)"
}
$capped = if ($Max -gt 0 -and $rows.Count -gt $Max) { 'true' } else { 'false' }
Write-Host "STATUS: OK n=$($shown.Count) total=$($rows.Count) capped=$capped servers=$servers"
Disconnect-SapRfc
exit 0
