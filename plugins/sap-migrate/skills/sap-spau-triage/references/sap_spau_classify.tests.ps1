# =============================================================================
# sap_spau_classify.tests.ps1  -  Offline fixture tests for the SPAU classifier
#
# Builds synthetic evidence TSVs (no SAP) exercising each rule R1-R6 and asserts
# the deterministic class / confidence / coverage columns. Run with any PowerShell:
#   powershell -ExecutionPolicy Bypass -File sap_spau_classify.tests.ps1
# =============================================================================
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$classify = Join-Path $here 'sap_spau_classify.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("spau_test_" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$work = @"
obj_type`tobj_name`tpackage`tsmodilog_rows`toperations`tlast_mod_user`tlast_mod_date`taccess_key`ttrkorrs`tupgrade`tspau_code
CLAS`tZ_EQUAL`tZPKG`t1`tALL`tU1`t20240101`t`tT1`t0`t
CLAS`tZ_CONFLICT`tZPKG`t1`tALL`tU1`t20240101`tY`tT1`t0`t
REPS`tNOTE_2222222`tZPKG`t1`tNOTE`tU1`t20240101`t`tT1`t0`t
CLAS`tZ_NOTE_UNK`tZPKG`t1`tNOTE`tU1`t20240101`t`tT1`t0`t
FUGR`tZ_FG`tZPKG`t1`tALL`tU1`t20240101`t`tT1`t0`t
PROG`tZ_MOD`tZPKG`t15`tREPL`tU1`t20240101`t`tT1`t0`t
TABD`tZ_TAB`tZPKG`t`t`tU1`t20240101`t`t`t0`t
"@
$verwork = @"
obj_type`tobj_name`tequal_source`tnumbered
CLAS`tZ_EQUAL`tY`t5
CLAS`tZ_CONFLICT`tY`t5
"@
$notework = @"
num`tstatus
0002222222`tcompleted
"@
$wf = Join-Path $tmp 'wl.tsv'; $vf = Join-Path $tmp 'ver.tsv'; $nf = Join-Path $tmp 'notes.tsv'; $of = Join-Path $tmp 'triage.tsv'
[System.IO.File]::WriteAllText($wf, $work);     [System.IO.File]::WriteAllText($vf, $verwork); [System.IO.File]::WriteAllText($nf, $notework)

& powershell -NoProfile -ExecutionPolicy Bypass -File $classify -WorklistTsv $wf -VersionsTsv $vf -NotesTsv $nf -OutFile $of | Out-Null

$rows = @{}
$lines = [System.IO.File]::ReadAllLines($of)
$hdr = $lines[0] -split "`t"
$ci = @{}; for ($k=0;$k -lt $hdr.Count;$k++){ $ci[$hdr[$k]]=$k }
for ($i=1;$i -lt $lines.Count;$i++){ if($lines[$i].Trim()){ $c=$lines[$i] -split "`t"; $rows[$c[$ci['obj_name']]] = @{ class=$c[$ci['class']]; conf=$c[$ci['confidence']]; eff=$c[$ci['effort_band']]; cov=$c[$ci['coverage']] } } }

$expect = @(
    @{ n='Z_EQUAL';     class='reset-candidate'; conf='HIGH'; cov='CHECKED';         desc='R1 clean reset' }
    @{ n='Z_CONFLICT';  class='unclear';         conf='';     cov='CHECKED';         desc='R6 conflict beats R1' }
    @{ n='NOTE_2222222';class='reset-candidate'; conf='LOW';  cov='CHECKED';         desc='R2 own note completed' }
    @{ n='Z_NOTE_UNK';  class='adopt';           conf='LOW';  cov='COULD_NOT_CHECK'; desc='note, no linkage -> adopt/CNC' }
    @{ n='Z_FG';        class='re-implement';    conf='MEDIUM';cov='CHECKED';        desc='R4 enhancement-adjacent' }
    @{ n='Z_MOD';       class='adopt';           conf='MEDIUM';cov='CHECKED';        eff='L'; desc='R3 mod-assistant, effort L' }
    @{ n='Z_TAB';       class='unclear';         conf='';     cov='COULD_NOT_CHECK'; eff='M'; desc='R5 no evidence' }
)
$pass=0; $fail=0
foreach ($e in $expect) {
    $r = $rows[$e.n]
    $ok = $r -and $r.class -eq $e.class -and $r.conf -eq $e.conf -and $r.cov -eq $e.cov
    if ($e.ContainsKey('eff')) { $ok = $ok -and $r.eff -eq $e.eff }
    if ($ok) { $pass++; Write-Host ("PASS  {0,-14} -> {1}/{2}/{3}  ({4})" -f $e.n,$r.class,$r.conf,$r.cov,$e.desc) }
    else { $fail++; Write-Host ("FAIL  {0,-14} -> got {1}/{2}/{3} expected {4}/{5}/{6}  ({7})" -f $e.n,($r.class),($r.conf),($r.cov),$e.class,$e.conf,$e.cov,$e.desc) }
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host ("RESULT: pass=$pass fail=$fail")
if ($fail -gt 0) { exit 1 } else { exit 0 }
