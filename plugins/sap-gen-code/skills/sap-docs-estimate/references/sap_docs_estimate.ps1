# =============================================================================
# sap_docs_estimate.ps1  -  deterministic, offline effort scorer for /sap-docs-estimate
#
# LOCAL ONLY (no SAP, no RFC). Scores a spec work folder's structural signals against
# estimate_weights.tsv, maps the class to a WIDE band from effort_bands.tsv, and emits a
# transparent, uncalibrated estimate. Missing input -> that signal COULD_NOT_CHECK (band
# widened + confidence dropped), never a silent zero.
#
#   default : -Folder <work-folder>            score one spec
#   batch   : -Batch  <folder-of-folders>      score every sub-folder that has spec inputs
#   ledger  : -Ledger <findings_triaged.tsv>   band each row by (tier x object_type)
#   common  : [-WeightsFile <tsv>] [-BandsFile <tsv>] [-CustomUrl <dir>] [-OutDir <dir>]
#
# stdout: SIGNAL: name=<s> count=<n> weight=<w> contrib=<c> coverage=<CHECKED|COULD_NOT_CHECK>
#         SCORE: raw=<r> class=<XS|S|M|L|XL> covered=<c>/<t> program_type=<t>
#         BAND: type=<t> class=<c> low=<pd> high=<pd> total_low=<pd> total_high=<pd> calibration=<NONE|n>
#         LEDGER: object=<o> type=<t> tier=<r> low=<pd> high=<pd>   (ledger mode)
#         STATUS: OK | EST_INPUT_MISSING   ; exit 0/1
# =============================================================================
[CmdletBinding()]
param(
    [string] $Folder      = '',
    [string] $Batch       = '',
    [string] $Ledger      = '',
    [string] $WeightsFile = '',
    [string] $BandsFile   = '',
    [string] $CustomUrl   = '',
    [string] $CalibFile   = '',
    [string] $OutDir      = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Resolve-Ref { param([string]$explicit,[string]$baseName)
    if ($explicit -and (Test-Path $explicit)) { return $explicit }
    if ($CustomUrl) { $cand = Join-Path $CustomUrl $baseName; if (Test-Path $cand) { return $cand } }
    return (Join-Path $PSScriptRoot $baseName)
}
function Read-TsvRows { param([string]$path)
    if (-not (Test-Path $path)) { return }
    $lines = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF) -split "`r`n|`n"
    $hdr = $null
    foreach ($ln in $lines) {
        if ($null -eq $ln -or $ln.TrimStart().StartsWith('#') -or $ln.Trim() -eq '') { continue }
        $cells = @($ln -split "`t")
        if ($null -eq $hdr) { $hdr = $cells; continue }
        $rec = [ordered]@{}
        for ($i = 0; $i -lt $hdr.Count; $i++) { $key = "$($hdr[$i])".Trim(); if ($key -eq '') { $key = "c$i" }; $rec[$key] = if ($i -lt $cells.Count) { "$($cells[$i])".Trim() } else { '' } }
        [pscustomobject]$rec
    }
}
function CountLines { param([string]$path)
    if (-not (Test-Path $path)) { return -1 }   # -1 = absent (COULD_NOT_CHECK)
    $n = 0
    foreach ($ln in ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) -split "`r`n|`n")) {
        $t = "$ln".Trim(); if ($t -ne '' -and -not $t.StartsWith('#')) { $n++ }
    }
    return $n
}
function CountSteps { param([string]$path)
    if (-not (Test-Path $path)) { return -1 }
    $n = 0
    foreach ($ln in ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) -split "`r`n|`n")) {
        $t = "$ln".Trim(); if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -match '^\s*(\d+[\.\)]|[-*]|Step\b|STEP\b)' -or $t.Length -gt 0) { $n++ }
    }
    return $n
}
function CountBranches { param([string]$path)
    if (-not (Test-Path $path)) { return -1 }
    $txt = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    return ([regex]::Matches($txt, '(?i)\b(if|case|when|loop|check|otherwise|else|for each|foreach)\b')).Count
}
function CountFiles { param([string]$folder,[string]$prefix)
    if (-not (Test-Path $folder)) { return -1 }
    return @(Get-ChildItem -Path $folder -Filter "$prefix*" -File -ErrorAction SilentlyContinue).Count
}
function CountCheck { param([string]$folder,[string]$sev)  # sev = ERROR | WARNING
    $tot = 0; $seen = $false
    foreach ($bn in @('check_result_ddic.txt','check_result_process.txt')) {
        $p = Join-Path $folder $bn
        if (-not (Test-Path $p)) { continue }
        $seen = $true
        $tot += ([regex]::Matches([IO.File]::ReadAllText($p,[Text.Encoding]::UTF8), "(?im)\b$sev\b")).Count
    }
    if (-not $seen) { return -1 }
    return $tot
}

# ---- load weights + bands ----
$wPath = Resolve-Ref $WeightsFile 'estimate_weights.tsv'
$bPath = Resolve-Ref $BandsFile   'effort_bands.tsv'
$weights = @{}
foreach ($r in (Read-TsvRows $wPath)) { if ($r.signal) { $weights[$r.signal] = [double]$r.weight } }
$bands = @(Read-TsvRows $bPath)
$calib = 'NONE'
if ($CalibFile -and (Test-Path $CalibFile)) { try { $cj = Get-Content $CalibFile -Raw | ConvertFrom-Json; if ($cj.pairs) { $calib = "$($cj.pairs)" } } catch { } }

function Class-Of { param([double]$score)
    if ($score -lt 8)   { return 'XS' }
    if ($score -lt 25)  { return 'S' }
    if ($score -lt 60)  { return 'M' }
    if ($score -lt 120) { return 'L' }
    return 'XL'
}
function ProgramType { param([string]$folder)
    $p = Join-Path $folder '_PGM_summary.txt'
    if (-not (Test-Path $p)) { return 'unknown' }
    $t = [IO.File]::ReadAllText($p,[Text.Encoding]::UTF8).ToLower()
    if ($t -match 'module pool|dialog|dynpro|screen flow|pai|pbo') { return 'dialog' }
    if ($t -match 'idoc|rfc dest|proxy|soap|interface|ale|file transfer') { return 'interface' }
    if ($t -match 'badi|exit|enhancement|user-exit|customer exit') { return 'enhancement' }
    if ($t -match 'function module|function group|\bfm\b|remote-enabled') { return 'fm' }
    if ($t -match 'report|executable|selection screen|alv') { return 'report' }
    return 'unknown'
}

# ---- score one folder: returns a hashtable with signals/score/class/coverage/ptype ----
function Score-Folder { param([string]$dir)
    $sig = [ordered]@{}
    $sig['ddic_domain']      = CountLines (Join-Path $dir '_domains.txt')
    $sig['ddic_dataelement'] = CountLines (Join-Path $dir '_dataElements.txt')
    $sig['ddic_table']       = CountLines (Join-Path $dir '_tables.txt')
    $sig['ddic_tabledata']   = CountFiles $dir 'table_data_'
    $sig['process_step']     = CountSteps (Join-Path $dir '_process.txt')
    $sig['process_branch']   = CountBranches (Join-Path $dir '_process.txt')
    $sig['screen_field']     = CountLines (Join-Path $dir '_selection_definition.txt')
    $sig['screen_present']   = $(if (Test-Path (Join-Path $dir '_selection_screen_layout.png')) { 1 } else { 0 })
    $sig['interface_point']  = CountLines (Join-Path $dir '_interface.txt')
    $inMap = CountLines (Join-Path $dir '_file_mapping_in.txt'); $outMap = CountLines (Join-Path $dir '_file_mapping_out.txt')
    $sig['file_mapping_field'] = $(if ($inMap -lt 0 -and $outMap -lt 0) { -1 } else { [Math]::Max(0,$inMap) + [Math]::Max(0,$outMap) })
    $sig['test_errmsg']      = CountLines (Join-Path $dir '_errorMsgs.txt')
    $sig['test_golden']      = CountLines (Join-Path $dir '_golden.txt')
    $sig['test_textelem']    = CountLines (Join-Path $dir '_textElements.txt')
    $sig['deps']             = CountLines (Join-Path $dir '_deps.txt')
    $sig['ambiguity_error']  = CountCheck $dir 'ERROR'
    $sig['ambiguity_warning']= CountCheck $dir 'WARNING'

    $score = 0.0; $covered = 0; $total = 0; $rows = @()
    foreach ($name in $sig.Keys) {
        $total++
        $cnt = [int]$sig[$name]
        $w = if ($weights.ContainsKey($name)) { [double]$weights[$name] } else { 0.0 }
        if ($cnt -lt 0) {
            $rows += [pscustomobject]@{ name=$name; count=0; weight=$w; contrib=0.0; coverage='COULD_NOT_CHECK' }
        } else {
            $covered++; $c = [Math]::Round($cnt * $w, 2); $score += $c
            $rows += [pscustomobject]@{ name=$name; count=$cnt; weight=$w; contrib=$c; coverage='CHECKED' }
        }
    }
    return [pscustomobject]@{ signals=$rows; score=[Math]::Round($score,2); class=(Class-Of $score); covered=$covered; total=$total; ptype=(ProgramType $dir) }
}
function Has-Inputs { param([string]$dir)
    foreach ($bn in @('_process.txt','_tables.txt','_dataElements.txt','_interface.txt','_golden.txt','_domains.txt','_PGM_summary.txt')) {
        if (Test-Path (Join-Path $dir $bn)) { return $true }
    }
    return $false
}
function Band-For { param([string]$ptype,[string]$cls)
    $row = $bands | Where-Object { $_.kind -eq 'SPEC' -and $_.key1 -eq $ptype -and $_.key2 -eq $cls } | Select-Object -First 1
    if (-not $row) { $row = $bands | Where-Object { $_.kind -eq 'SPEC' -and $_.key1 -eq 'unknown' -and $_.key2 -eq $cls } | Select-Object -First 1 }
    return $row
}
function Emit-Estimate { param($scored,[string]$label)
    foreach ($s in $scored.signals) { Write-Host ("SIGNAL: name={0} count={1} weight={2} contrib={3} coverage={4}" -f $s.name,$s.count,$s.weight,$s.contrib,$s.coverage) }
    Write-Host ("SCORE: raw={0} class={1} covered={2}/{3} program_type={4}" -f $scored.score,$scored.class,$scored.covered,$scored.total,$scored.ptype)
    $b = Band-For $scored.ptype $scored.class
    if ($b) {
        $upl = [double]$b.uplift_test + [double]$b.uplift_integration + [double]$b.uplift_functional
        $tl = [Math]::Round([double]$b.band_low_pd  * (1 + $upl), 1)
        $th = [Math]::Round([double]$b.band_high_pd * (1 + $upl), 1)
        Write-Host ("BAND: type={0} class={1} low={2} high={3} total_low={4} total_high={5} calibration={6} drivers=`"{7}`"" -f $scored.ptype,$scored.class,$b.band_low_pd,$b.band_high_pd,$tl,$th,$calib,$b.drivers)
    } else { Write-Host ("BAND: type={0} class={1} low=? high=? calibration={2} drivers=`"no band row`"" -f $scored.ptype,$scored.class,$calib) }
}

# =========================== dispatch =======================================
if ($Ledger) {
    if (-not (Test-Path $Ledger)) { Write-Host 'STATUS: EST_INPUT_MISSING reason=ledger_not_found'; exit 1 }
    $tri = @(Read-TsvRows $Ledger)
    if ($tri.Count -eq 0) { Write-Host 'STATUS: EST_INPUT_MISSING reason=ledger_empty'; exit 1 }
    $sumLow = 0.0; $sumHigh = 0.0; $n = 0
    foreach ($row in $tri) {
        $obj = "$($row.object)"; $ot = "$($row.obj_type)".ToUpper(); $tier = "$($row.tier)".ToUpper()
        if (-not $tier) { continue }
        $ot2 = if ($ot -in @('PROG','CLAS','FUGR','TABL')) { $ot } else { 'PROG' }
        $br = $bands | Where-Object { $_.kind -eq 'LEDGER' -and $_.key1 -eq $tier -and $_.key2 -eq $ot2 } | Select-Object -First 1
        if (-not $br) { continue }
        $upl = [double]$br.uplift_test + [double]$br.uplift_integration + [double]$br.uplift_functional
        $lo = [Math]::Round([double]$br.band_low_pd  * (1 + $upl), 2); $hi = [Math]::Round([double]$br.band_high_pd * (1 + $upl), 2)
        $sumLow += $lo; $sumHigh += $hi; $n++
        Write-Host ("LEDGER: object={0} type={1} tier={2} low={3} high={4}" -f $obj,$ot2,$tier,$lo,$hi)
    }
    Write-Host ("STATUS: OK mode=ledger items={0} total_low={1} total_high={2} calibration={3}" -f $n,[Math]::Round($sumLow,1),[Math]::Round($sumHigh,1),$calib)
    exit 0
}
elseif ($Batch) {
    if (-not (Test-Path $Batch)) { Write-Host 'STATUS: EST_INPUT_MISSING reason=batch_not_found'; exit 1 }
    $subs = @(Get-ChildItem -Path $Batch -Directory -ErrorAction SilentlyContinue | Where-Object { Has-Inputs $_.FullName })
    if ($subs.Count -eq 0) { Write-Host 'STATUS: EST_INPUT_MISSING reason=no_spec_folders'; exit 1 }
    foreach ($sub in $subs) {
        $sc = Score-Folder $sub.FullName
        $b = Band-For $sc.ptype $sc.class
        $lo = if ($b) { $b.band_low_pd } else { '?' }; $hi = if ($b) { $b.band_high_pd } else { '?' }
        Write-Host ("PORTFOLIO: folder={0} class={1} type={2} score={3} low={4} high={5} covered={6}/{7}" -f $sub.Name,$sc.class,$sc.ptype,$sc.score,$lo,$hi,$sc.covered,$sc.total)
    }
    Write-Host ("STATUS: OK mode=batch folders={0}" -f $subs.Count)
    exit 0
}
else {
    if (-not $Folder -or -not (Test-Path $Folder)) { Write-Host 'STATUS: EST_INPUT_MISSING reason=folder_not_found'; exit 1 }
    if (-not (Has-Inputs $Folder)) { Write-Host 'STATUS: EST_INPUT_MISSING reason=no_scoreable_inputs'; exit 1 }
    $scored = Score-Folder $Folder
    Emit-Estimate $scored (Split-Path $Folder -Leaf)
    Write-Host ("STATUS: OK mode=score class={0} covered={1}/{2}" -f $scored.class,$scored.covered,$scored.total)
    exit 0
}
