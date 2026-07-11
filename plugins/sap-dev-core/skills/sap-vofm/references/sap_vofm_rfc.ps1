# =============================================================================
# sap_vofm_rfc.ps1  -  Read backend for /sap-vofm (list / check / resolve)
# -----------------------------------------------------------------------------
# READ-ONLY. 32-bit PowerShell + NCo 3.1. Reads the VOFM routine registry and
# proves the three things developers get wrong: is the routine REGISTERED
# (TFRM), does its include EXIST + ACTIVE (PROGDIR), and did RV80HGEN WIRE IT
# into the frame include (frame-membership scan) -- plus optional transport
# completeness (E071/E071K). Screen text is never trusted; every verdict is an
# authoritative RFC re-read.
#
# The caller (SKILL.md) resolves the friendly <type> to its GRPZE + frame +
# prefixes from vofm_routine_groups.tsv and passes them in, so this script is
# group-agnostic.
#
# TFRM layout (verified S4D 2026-07-11): key GRPZE(CHAR4)+GRPNO(NUMC3); AKTIV,
# KAPPL, GNDAT, GNZEI. Customer routines are GRPNO >= 600 and their include is
# <CustomerPrefix><nnn> (e.g. RV61A902); RV80HGEN wires each into the frame
# include <FrameInclude> as `INCLUDE <CustomerPrefix><nnn>`. A customer routine
# present in TFRM+PROGDIR but ABSENT from the frame set = registered=N (the
# classic "routine not found at runtime -- regen never ran" trap).
#
# Actions:
#   list    -Grpze -FrameInclude -CustomerPrefix [-StandardPrefixes] [-CustomerOnly] [-Max]
#   check   -Grpze -Nnn -FrameInclude -CustomerPrefix [-StandardPrefixes] [-Tr]
#   resolve -Grpze -Nnn -CustomerPrefix [-StandardPrefixes]     (include-name only, for explain)
#
# Grammar (parseable):
#   list  : VOFM: grpno=<nnn> active=<Y|N> include=<name|-> exists=<Y|N> state=<A|I|-> registered=<Y|N|STD> text="<..>"
#           STATUS: OK total=<n> registered=<r> gaps=<g> file=<tsv>
#   check : VOFM_CHECK grpze=<> nnn=<> tfrm=<PRESENT|ABSENT> active=<Y|N|-> include=<name|-> exists=<Y|N>
#                      state=<A|I|-> inactive_pending=<Y|N> registered=<Y|N|STD> transport=<COMPLETE|GAP:..|NOT_CHECKED>
#           FINDING sev=<..> detail=<..>            (0+)
#           VERDICT: <GO|GO_WITH_WARNINGS|NO_GO|NOT_FOUND>
#   resolve: VOFM_RESOLVE nnn=<> include=<name|-> exists=<Y|N> state=<A|I|->
#   STATUS: ERROR msg=<..>
# Exit: 0 ok | 1 not-found (check on an absent routine) | 2 error (connect/input)
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('list','check','resolve')][string]$Action,
    [Parameter(Mandatory)][string]$Grpze,
    [string]$Nnn = '',
    [string]$FrameInclude = '',
    [string]$CustomerPrefix = '',
    [string]$StandardPrefixes = '',
    [string]$Tr = '',
    [int]$CustomerFloor = 600,
    [switch]$CustomerOnly,
    [int]$Max = 0,
    [string]$OutFile = '',
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if ($WorkDir) { $env:SAPDEV_AI_WORK_DIR = $WorkDir }
$Grpze = $Grpze.ToUpper()
function Fail([string]$m) { Write-Output "STATUS: ERROR msg=$m"; exit 2 }

# NCo lib lives next to sap_rfc_read_source in shared\scripts; find it from this skill dir
# (sap-vofm is a sap-dev-core skill, so ..\..\.. is the plugin root).
$sharedScripts = Join-Path (Split-Path -Parent $PSCommandPath) '..\..\..\shared\scripts'
$rfcLib = Join-Path $sharedScripts 'sap_rfc_lib.ps1'
$srcLib = Join-Path $sharedScripts 'sap_rfc_read_source.ps1'
if (-not (Test-Path $rfcLib)) { Fail "sap_rfc_lib.ps1 not found ($rfcLib)" }
. $rfcLib
if (Test-Path $srcLib) { . $srcLib }   # for the frame-include source read

$script:Dest = Connect-SapRfc -DestName 'VOFM'
if (-not $script:Dest) { Fail 'RFC_LOGON_FAILED' }

function Read-Rows($table, $where, $rowc, $fields) {
    $fn = New-RfcReadTable -Destination $script:Dest -Table $table
    [void]$fn.SetValue('DELIMITER', '')
    if ($rowc) { [void]$fn.SetValue('ROWCOUNT', $rowc) }
    if ($where) { Add-RfcOption $fn $where }
    if ($fields) { foreach ($f in $fields) { Add-RfcField $fn $f } }
    $ok = $true
    try { $fn.Invoke($script:Dest) } catch { if ($_.Exception.Message -match 'TABLE_WITHOUT_DATA') { $ok = $false } else { throw } }
    if (-not $ok) { return ,@() }
    $flds = $fn.GetTable('FIELDS'); $data = $fn.GetTable('DATA'); $cols = @()
    for ($i = 0; $i -lt $flds.RowCount; $i++) { $flds.CurrentIndex = $i; $cols += [pscustomobject]@{ Name = $flds.GetString('FIELDNAME'); Off = [int]$flds.GetString('OFFSET'); Len = [int]$flds.GetString('LENGTH') } }
    $rows = @()
    for ($r = 0; $r -lt $data.RowCount; $r++) {
        $data.CurrentIndex = $r; $wa = [string]$data.GetString('WA'); $o = [ordered]@{}
        foreach ($c in $cols) { $v = ''; if ($c.Off -lt $wa.Length) { $end = [Math]::Min($c.Len, $wa.Length - $c.Off); $v = $wa.Substring($c.Off, $end).TrimEnd() }; $o[$c.Name] = $v }
        $rows += [pscustomobject]$o
    }
    return ,$rows
}

# frame-membership: parse `INCLUDE <prefix><nnn>` from the frame include source
function Get-FrameSet($frame, $prefix) {
    if (-not $frame -or -not (Get-Command Read-SapAbapSource -ErrorAction SilentlyContinue)) { return $null }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vofm_frame_" + $frame)
    $r = $null
    try { $r = Read-SapAbapSource -Name $frame -Type include -OutDir $tmp -Dest $script:Dest } catch { return $null }
    if (-not $r -or $r.Status -ne 'OK' -or -not (Test-Path $r.SourceFile)) { return $null }
    $set = @{}
    $rx = [regex]("(?i)^\s*INCLUDE\s+" + [regex]::Escape($prefix) + "(\d{3})\b")
    foreach ($ln in (Get-Content -LiteralPath $r.SourceFile)) { $m = $rx.Match($ln); if ($m.Success) { $set[$m.Groups[1].Value] = $true } }
    return $set
}

# include-name resolution: customer prefix first, then standard prefixes; first PROGDIR hit wins
$stdPfx = @(); if ($StandardPrefixes) { $stdPfx = @($StandardPrefixes -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Resolve-Include($nnn) {
    $cands = @()
    if ($CustomerPrefix) { $cands += ($CustomerPrefix + $nnn) }
    foreach ($p in $stdPfx) { $cands += ($p + $nnn) }
    foreach ($c in $cands) {
        $pd = Read-Rows 'PROGDIR' "NAME = '$c'" 1 @('NAME', 'STATE')
        if ($pd.Count -gt 0) { return [pscustomobject]@{ Name = $c; Exists = $true; State = $pd[0].STATE } }
    }
    # nothing active/exists; still return the customer-derived name as the expected one
    $exp = if ($CustomerPrefix) { $CustomerPrefix + $nnn } elseif ($cands.Count) { $cands[0] } else { '-' }
    return [pscustomobject]@{ Name = $exp; Exists = $false; State = '-' }
}

try {
    if ($Action -eq 'list') {
        $where = "GRPZE = '$Grpze'"
        if ($CustomerOnly) { $where += " AND GRPNO GE '$('{0:000}' -f $CustomerFloor)'" }
        $rows = Read-Rows 'TFRM' $where 0 @('GRPZE', 'GRPNO', 'AKTIV', 'KAPPL')
        if ($rows.Count -eq 0) { Write-Output "STATUS: OK total=0 registered=0 gaps=0 file="; exit 0 }
        # text table (EN), keyed grpno
        $txt = @{}; foreach ($t in (Read-Rows 'TFRMT' "GRPZE = '$Grpze' AND SPRAS = 'E'" 0 @('GRPZE', 'GRPNO', 'BEZEI'))) { $txt[$t.GRPNO] = $t.BEZEI }
        $frameSet = Get-FrameSet $FrameInclude $CustomerPrefix
        $rows = $rows | Sort-Object { [int]$_.GRPNO }
        if ($Max -gt 0) { $rows = $rows | Select-Object -First $Max }
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("grpno`tactive`tinclude`texists`tstate`tregistered`ttext")
        $reg = 0; $gaps = 0
        foreach ($r in $rows) {
            $nnn = $r.GRPNO; $isCust = ([int]$nnn -ge $CustomerFloor)
            $inc = Resolve-Include $nnn
            $active = if ($r.AKTIV -eq 'X') { 'Y' } else { 'N' }
            $registered = 'STD'
            if ($isCust) {
                if ($null -eq $frameSet) { $registered = '?' }
                elseif ($frameSet.ContainsKey($nnn)) { $registered = 'Y'; $reg++ }
                else { $registered = 'N'; $gaps++ }
            }
            $ex = if ($inc.Exists) { 'Y' } else { 'N' }
            $tx = $txt[$nnn]
            Write-Output ("VOFM: grpno=$nnn active=$active include=$($inc.Name) exists=$ex state=$($inc.State) registered=$registered text=""$tx""")
            $out.Add("$nnn`t$active`t$($inc.Name)`t$ex`t$($inc.State)`t$registered`t$tx")
        }
        if ($OutFile) { $enc = New-Object System.Text.UTF8Encoding($true); [System.IO.File]::WriteAllText($OutFile, (($out -join "`r`n") + "`r`n"), $enc) }
        Write-Output "STATUS: OK total=$($rows.Count) registered=$reg gaps=$gaps file=$OutFile"
        exit 0
    }

    if ($Action -eq 'resolve') {
        if (-not $Nnn) { Fail 'resolve needs -Nnn' }
        $inc = Resolve-Include $Nnn
        Write-Output ("VOFM_RESOLVE nnn=$Nnn include=$($inc.Name) exists=$(if($inc.Exists){'Y'}else{'N'}) state=$($inc.State)")
        exit 0
    }

    # ---- check ----
    if (-not $Nnn) { Fail 'check needs -Nnn' }
    $isCust = ([int]$Nnn -ge $CustomerFloor)
    $tf = Read-Rows 'TFRM' "GRPZE = '$Grpze' AND GRPNO = '$Nnn'" 1 @('GRPZE', 'GRPNO', 'AKTIV')
    $inc = Resolve-Include $Nnn
    $findings = New-Object System.Collections.Generic.List[string]
    if ($tf.Count -eq 0) {
        Write-Output ("VOFM_CHECK grpze=$Grpze nnn=$Nnn tfrm=ABSENT active=- include=$($inc.Name) exists=$(if($inc.Exists){'Y'}else{'N'}) state=$($inc.State) inactive_pending=- registered=- transport=NOT_CHECKED")
        Write-Output "VERDICT: NOT_FOUND"
        exit 1
    }
    $active = if ($tf[0].AKTIV -eq 'X') { 'Y' } else { 'N' }
    # inactive pending via DWINACTIV (REPS/PROG object for the include)
    $inact = 'N'
    if ($inc.Name -ne '-') {
        $dw = Read-Rows 'DWINACTIV' "OBJ_NAME = '$($inc.Name)'" 5 @('OBJECT', 'OBJ_NAME')
        if ($dw.Count -gt 0) { $inact = 'Y' }
    }
    # frame membership
    $registered = 'STD'
    if ($isCust) {
        $frameSet = Get-FrameSet $FrameInclude $CustomerPrefix
        if ($null -eq $frameSet) { $registered = '?' }
        elseif ($frameSet.ContainsKey($Nnn)) { $registered = 'Y' } else { $registered = 'N' }
    }
    # transport completeness (optional)
    $transport = 'NOT_CHECKED'
    if ($Tr) {
        $progIn = $false; $tfrmIn = $false; $tfrmtIn = $false
        if ($inc.Name -ne '-') {
            $e = Read-Rows 'E071' "TRKORR = '$Tr' AND OBJ_NAME = '$($inc.Name)'" 5 @('TRKORR', 'PGMID', 'OBJECT', 'OBJ_NAME')
            if ($e.Count -gt 0) { $progIn = $true }
        }
        $key = "$Grpze$Nnn"
        $ek = Read-Rows 'E071K' "TRKORR = '$Tr'" 0 @('TRKORR', 'OBJNAME', 'TABKEY')
        foreach ($row in $ek) {
            if ($row.OBJNAME -eq 'TFRM' -and $row.TABKEY -like "*$key*") { $tfrmIn = $true }
            if ($row.OBJNAME -eq 'TFRMT' -and $row.TABKEY -like "*$key*") { $tfrmtIn = $true }
        }
        $miss = @()
        if (-not $progIn) { $miss += 'PROG' }
        if (-not $tfrmIn) { $miss += 'TFRM_KEY' }
        if (-not $tfrmtIn) { $miss += 'TFRMT_KEY' }
        $transport = if ($miss.Count -eq 0) { 'COMPLETE' } else { 'GAP:' + ($miss -join '+') }
    }

    Write-Output ("VOFM_CHECK grpze=$Grpze nnn=$Nnn tfrm=PRESENT active=$active include=$($inc.Name) exists=$(if($inc.Exists){'Y'}else{'N'}) state=$($inc.State) inactive_pending=$inact registered=$registered transport=$transport")
    # findings + verdict
    $verdict = 'GO'
    if (-not $inc.Exists) { $findings.Add("FINDING sev=HIGH detail=include_$($inc.Name)_missing_in_PROGDIR"); $verdict = 'NO_GO' }
    elseif ($inc.State -ne 'A') { $findings.Add("FINDING sev=HIGH detail=include_$($inc.Name)_not_active_state=$($inc.State)"); $verdict = 'NO_GO' }
    if ($inact -eq 'Y') { $findings.Add("FINDING sev=MEDIUM detail=inactive_version_pending_in_DWINACTIV"); if ($verdict -eq 'GO') { $verdict = 'GO_WITH_WARNINGS' } }
    if ($registered -eq 'N') { $findings.Add("FINDING sev=HIGH detail=NOT_wired_into_frame_$FrameInclude-run_RV80HGEN"); $verdict = 'NO_GO' }
    elseif ($registered -eq '?') { $findings.Add("FINDING sev=INFO detail=frame_membership_COULD_NOT_CHECK"); if ($verdict -eq 'GO') { $verdict = 'GO_WITH_WARNINGS' } }
    if ($active -eq 'N') { $findings.Add("FINDING sev=MEDIUM detail=TFRM_AKTIV_flag_not_set"); if ($verdict -eq 'GO') { $verdict = 'GO_WITH_WARNINGS' } }
    if ($transport -like 'GAP:*') { $findings.Add("FINDING sev=MEDIUM detail=transport_$transport-add_via_SE01_include_objects"); if ($verdict -eq 'GO') { $verdict = 'GO_WITH_WARNINGS' } }
    foreach ($f in $findings) { Write-Output $f }
    Write-Output "VERDICT: $verdict"
    exit 0
}
finally { try { Disconnect-SapRfc -Destination $script:Dest } catch {}; try { Disconnect-SapRfc } catch {} }
