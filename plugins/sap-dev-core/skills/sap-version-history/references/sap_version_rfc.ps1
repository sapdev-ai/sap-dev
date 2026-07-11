# =============================================================================
# sap_version_rfc.ps1  -  /sap-version-history RFC backend (list + fetch)
#
# Pure RFC (NCo 3.1, 32-bit PowerShell). No GUI, no session. Two actions:
#
#   -Action list  -ObjName <NAME> -ObjType <REPS|FUNC> [-OutFile <tsv>]
#       Version directory via SVRS_GET_VERSION_DIRECTORY_46 (DESTINATION='NONE' --
#       a blank destination intermittently throws "SQL error 4", verified S4D
#       2026-07-11), fallback RFC_READ_TABLE on VRSD. Joins each version's KORRNUM
#       to E070 (TRSTATUS/TRFUNCTION/AS4DATE). Emits one `VER:` line per version +
#       `STATUS: OK n=<k> last_released=<v>` (or `VH_NO_VERSIONS`). VERSNO 00000 is
#       the ACTIVE pseudo-entry (marked active=1); highest VERSNO whose TR is
#       released (TRSTATUS=R) is last_released. Deleted rows (LOEKZ=X) are dropped.
#
#   -Action fetch -ObjName <NAME> -ObjType <REPS|FUNC> -Versno <N> -OutFile <src>
#       Version source via SVRS_GET_REPS_FROM_OBJECT -> REPOS_TAB (single LINE
#       column), written UTF-8 to -OutFile. Emits `STATUS: OK lines=<n>` or
#       `VH_VERSION_NOT_FOUND`.
#
# Live-verified S4D (S/4HANA 1909) 2026-07-11: VERSION_LIST cols
# OBJTYPE/OBJNAME/VERSNO/KORRNUM/AUTHOR/DATUM/ZEIT/LOEKZ; the SVRS directory is
# MORE complete than a raw VRSD sample (surfaces the newest version a capped VRSD
# read can miss). Dot-source-safe (no side effects on load) so /sap-spau-triage
# can reuse this backend.
#
# Tokens: %%RFC_LIB_PS1%% %%SAP_SERVER%% %%SAP_SYSNR%% %%SAP_CLIENT%% %%SAP_USER%%
#   %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
# Exit: 0 = ran (incl. VH_NO_VERSIONS), 1 = object/version issue, 2 = connect/input.
# =============================================================================
param(
    [Parameter(Mandatory = $true)][ValidateSet('list', 'fetch')][string]$Action,
    [Parameter(Mandatory = $true)][string]$ObjName,
    [string]$ObjType = 'REPS',
    [string]$Versno = '',
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
. "%%RFC_LIB_PS1%%"

$ObjName = $ObjName.Trim().ToUpper()
$ObjType = $ObjType.Trim().ToUpper()

$dest = Connect-SapRfc -Server "%%SAP_SERVER%%" -Sysnr "%%SAP_SYSNR%%" -Client "%%SAP_CLIENT%%" `
    -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "VERHIST"
if (-not $dest) { Write-Output 'STATUS: RFC_LOGON_FAILED'; exit 2 }

# --- helper: chunk a WHERE clause into <=72-char OPTIONS rows at space boundaries
function Add-Where($optTab, [string]$where) {
    $line = ''
    foreach ($tok in ($where -split ' ')) {
        if (($line.Length + $tok.Length + 1) -gt 72) { $optTab.Append(); $optTab.SetValue('TEXT', $line); $line = $tok }
        elseif ($line -eq '') { $line = $tok }
        else { $line = "$line $tok" }
    }
    if ($line -ne '') { $optTab.Append(); $optTab.SetValue('TEXT', $line) }
}

# --- helper: read a narrow table with an optional WHERE, return array of hashtables
function Read-Narrow([string]$table, [string[]]$fields, [string]$where, [int]$rowcount) {
    $rt = $dest.Repository.CreateFunction('RFC_READ_TABLE')
    $rt.SetValue('QUERY_TABLE', $table); $rt.SetValue('DELIMITER', '|'); $rt.SetValue('ROWCOUNT', $rowcount)
    $ff = $rt.GetTable('FIELDS'); foreach ($f in $fields) { $ff.Append(); $ff.SetValue('FIELDNAME', $f) }
    if ($where) { Add-Where $rt.GetTable('OPTIONS') $where }
    $rt.Invoke($dest)
    $data = $rt.GetTable('DATA'); $out = @()
    for ($i = 0; $i -lt $data.RowCount; $i++) {
        $data.CurrentIndex = $i; $parts = ($data.GetValue('WA') -split '\|')
        $h = @{ }; for ($k = 0; $k -lt $fields.Count; $k++) { $h[$fields[$k]] = ($parts[$k]).Trim() }
        $out += $h
    }
    return $out
}

# =============================================================================
if ($Action -eq 'list') {
    # ---- 1. version directory (SVRS FM primary, VRSD fallback) ----------------
    $rows = @()
    $viaFm = $false
    try {
        $fn = $dest.Repository.CreateFunction('SVRS_GET_VERSION_DIRECTORY_46')
        $fn.SetValue('OBJNAME', $ObjName); $fn.SetValue('OBJTYPE', $ObjType); $fn.SetValue('DESTINATION', 'NONE')
        $fn.Invoke($dest)
        $vl = $fn.GetTable('VERSION_LIST')
        for ($i = 0; $i -lt $vl.RowCount; $i++) {
            $vl.CurrentIndex = $i
            $rows += @{ VERSNO = "$($vl.GetValue('VERSNO'))".Trim(); KORRNUM = "$($vl.GetValue('KORRNUM'))".Trim();
                AUTHOR = "$($vl.GetValue('AUTHOR'))".Trim(); DATUM = "$($vl.GetValue('DATUM'))".Trim();
                ZEIT = "$($vl.GetValue('ZEIT'))".Trim(); LOEKZ = "$($vl.GetValue('LOEKZ'))".Trim()
            }
        }
        $viaFm = $true
    }
    catch {
        # fallback: raw VRSD (no synthesized newest, but honest)
        try {
            $vr = Read-Narrow 'VRSD' @('VERSNO', 'KORRNUM', 'AUTHOR', 'DATUM', 'ZEIT', 'LOEKZ') "OBJTYPE = '$ObjType' AND OBJNAME = '$ObjName'" 0
            $rows = $vr
        }
        catch { Write-Output ("STATUS: RFC_ERROR " + ($_.Exception.Message -replace '\s+', ' ').Substring(0, 60)); exit 1 }
    }
    # drop deleted rows
    $rows = @($rows | Where-Object { $_.LOEKZ -ne 'X' })
    if ($rows.Count -eq 0) { Write-Output "STATUS: VH_NO_VERSIONS obj=$ObjName type=$ObjType"; exit 0 }

    # ---- 2. E070 TR-status join ----------------------------------------------
    $korrs = @($rows | ForEach-Object { $_.KORRNUM } | Where-Object { $_ } | Select-Object -Unique)
    $trInfo = @{ }
    if ($korrs.Count -gt 0) {
        $inList = "TRKORR IN (" + (($korrs | ForEach-Object { "'$_'" }) -join ',') + ")"
        try {
            $e070 = Read-Narrow 'E070' @('TRKORR', 'TRFUNCTION', 'TRSTATUS', 'AS4DATE') $inList 0
            foreach ($e in $e070) { $trInfo[$e.TRKORR] = $e }
        }
        catch { }   # TR join is best-effort; versions still list without it
    }

    # ---- 3. classify + emit ---------------------------------------------------
    # numbered versions sorted desc; 00000 = active pseudo-entry
    $numbered = @($rows | Where-Object { $_.VERSNO -ne '00000' } | Sort-Object { [int]$_.VERSNO } -Descending)
    $active = @($rows | Where-Object { $_.VERSNO -eq '00000' })
    $lastReleased = ''
    foreach ($r in $numbered) {
        $ti = $trInfo[$r.KORRNUM]
        if ($ti -and $ti.TRSTATUS -eq 'R') { $lastReleased = $r.VERSNO; break }
    }
    $tsv = @("VERSNO`tACTIVE`tRELEASED`tAUTHOR`tDATUM`tZEIT`tTRKORR`tTRSTATUS`tTRFUNCTION`tLAST_RELEASED")
    function _Emit($r, [int]$isActive) {
        $ti = $trInfo[$r.KORRNUM]
        $trStat = if ($ti) { $ti.TRSTATUS } elseif ($r.KORRNUM) { 'UNKNOWN' } else { '' }
        $trFunc = if ($ti) { $ti.TRFUNCTION } else { '' }
        $rel = if ($trStat -eq 'R') { 1 } else { 0 }
        $isLast = if ($r.VERSNO -eq $script:lastReleased -and $script:lastReleased) { 1 } else { 0 }
        Write-Output ("VER: versno={0} active={1} released={2} author={3} date={4} time={5} tr={6} trstatus={7} trfunc={8} last_released={9}" -f `
                $r.VERSNO, $isActive, $rel, $r.AUTHOR, $r.DATUM, $r.ZEIT, $r.KORRNUM, $trStat, $trFunc, $isLast)
        $script:tsv += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}" -f `
                $r.VERSNO, $isActive, $rel, $r.AUTHOR, $r.DATUM, $r.ZEIT, $r.KORRNUM, $trStat, $trFunc, $isLast)
    }
    foreach ($r in $active) { _Emit $r 1 }
    foreach ($r in $numbered) { _Emit $r 0 }
    if ($OutFile) { [System.IO.File]::WriteAllLines($OutFile, $tsv, (New-Object System.Text.UTF8Encoding($true))) }
    Write-Output ("STATUS: OK n={0} numbered={1} last_released={2} via={3}" -f $rows.Count, $numbered.Count, $(if ($lastReleased) { $lastReleased } else { 'none' }), $(if ($viaFm) { 'svrs_fm' } else { 'vrsd' }))
    exit 0
}

# =============================================================================
if ($Action -eq 'fetch') {
    if (-not $Versno) { Write-Output 'STATUS: INPUT_ERROR reason=versno_required'; exit 2 }
    if (-not $OutFile) { Write-Output 'STATUS: INPUT_ERROR reason=outfile_required'; exit 2 }
    $vn8 = "{0:D8}" -f [int]$Versno
    try {
        $fn = $dest.Repository.CreateFunction('SVRS_GET_REPS_FROM_OBJECT')
        $fn.SetValue('OBJECT_NAME', $ObjName); $fn.SetValue('OBJECT_TYPE', $ObjType)
        $fn.SetValue('VERSNO', $vn8); $fn.SetValue('DESTINATION', 'NONE')
        $fn.Invoke($dest)
        $rt = $fn.GetTable('REPOS_TAB')
        if ($rt.RowCount -eq 0) { Write-Output "STATUS: VH_VERSION_NOT_FOUND obj=$ObjName versno=$vn8"; exit 1 }
        $lines = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $rt.RowCount; $i++) { $rt.CurrentIndex = $i; $lines.Add("$($rt.GetValue('LINE'))") }
        [System.IO.File]::WriteAllLines($OutFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "STATUS: OK lines=$($rt.RowCount) versno=$vn8 out=$OutFile"
        exit 0
    }
    catch {
        Write-Output ("STATUS: VH_VERSION_NOT_FOUND obj=$ObjName versno=$vn8 reason=" + ($_.Exception.Message -replace '\s+', ' ').Substring(0, [Math]::Min(50, ($_.Exception.Message -replace '\s+', ' ').Length)))
        exit 1
    }
}
