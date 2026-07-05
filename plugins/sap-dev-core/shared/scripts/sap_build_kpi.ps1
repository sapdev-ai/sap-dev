# sap_build_kpi.ps1 -- offline first-pass-yield aggregator for generated ABAP.
#
# OFFLINE: never opens a SAP session, makes no RFC call. Pure file math over the
# JSONL logs that the gate skills already write (Rule 4 Step 0.5 / Final blocks).
# DERIVED, not instrumented: it reconstructs one "build" per logical generate ->
# check -> deploy -> ATC -> unit-test run by clustering log records, then rolls
# up first-pass-yield KPIs. No new write path, no agent-level instrumentation.
# Contract + schema (sapdev.buildkpi/1): shared/rules/build_metrics.md.
#
# Usage:
#   sap_build_kpi.ps1 -LogDir <dir> [-OutDir <dir>] [-Since YYYY-MM-DD]
#                     [-BuildGapHours 3] [-Quiet]
#
# Output:
#   {OutDir}\build_kpi.jsonl   one sapdev.buildkpi/1 row per reconstructed build
#   {OutDir}\dashboard.md      headline + by-week + by-family + by-system tables
#   stdout                     STABLE grammar (mirrors sap_cc_campaign.ps1):
#     BUILD:  <build_id> | OUTCOME: <SUCCESS|FAILED|ABORTED>
#     GROUP:  <dim>=<value> | BUILDS: <n>
#     METRIC: <name> | VALUE: <int>          (-1 = n/a)  [GROUP: <dim>=<value>]
#     INFO / WARN: <text>
# Exit: 0 ok | 1 no builds reconstructed | 2 error (bad/missing log dir)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LogDir,
    [string]$OutDir,
    [string]$Since,
    [double]$BuildGapHours = 3.0,
    [string]$ArtifactIndex,   # reserved (P2): secondary source for coverage/verdict
    [switch]$Quiet            # suppress per-build BUILD: lines (KPI rollup only)
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers (PowerShell 5.1-safe: hashtable tallies, plain returns, ASCII only).
# ---------------------------------------------------------------------------

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# First non-empty value among $keys on a (possibly null) params PSCustomObject.
function Get-ParamValue($params, [string[]]$keys) {
    if ($null -eq $params) { return '' }
    foreach ($k in $keys) {
        $p = $params.PSObject.Properties[$k]
        if ($p -and "$($p.Value)") { return "$($p.Value)" }
    }
    return ''
}

# A field off a (possibly null) end record. Returns $null when absent.
function Get-EndField($end, [string]$name) {
    if ($null -eq $end) { return $null }
    $p = $end.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

function To-IntOrNull($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    $n = 0
    if ([int]::TryParse("$v", [ref]$n)) { return $n }
    if ("$v" -eq 'True') { return 1 }
    if ("$v" -eq 'False') { return 0 }
    return $null
}

function To-BoolOrNull($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [bool]) { return [bool]$v }
    $s = "$v".ToLower()
    if ($s -eq 'true' -or $s -eq '1') { return $true }
    if ($s -eq 'false' -or $s -eq '0') { return $false }
    return $null
}

# Normalise an object name: uppercase, strip a trailing _TEST so a program and
# its test program cluster into the same build.
function Normalize-Object([string]$n) {
    if (-not $n) { return '' }
    $u = $n.Trim().ToUpper()
    if ($u.EndsWith('_TEST')) { $u = $u.Substring(0, $u.Length - 5) }
    return $u
}

# Spec family + language from a spec/work path (gen-abap's `input`, or an
# abap_file path). Returns @{family=..;lang=..} or $null.
function Get-SpecInfo($params) {
    $p = Get-ParamValue $params @('input', 'abap_file', 'spec', 'doc')
    if (-not $p) { return $null }
    $up = $p.ToUpper()
    $lang = 'unknown'
    foreach ($pair in @(@('_EN', 'EN'), @('_JA', 'JA'), @('_CN', 'CN'), @('_ZH', 'ZH'))) {
        if ($up.Contains($pair[0])) { $lang = $pair[1]; break }
    }
    $fam = ''
    $m = [regex]::Match($p, 'spec[_\-]([A-Za-z][A-Za-z0-9]*)', 'IgnoreCase')
    if ($m.Success) { $fam = $m.Groups[1].Value.ToUpper() }
    if (-not $fam) { return $null }
    return @{ family = $fam; lang = $lang }
}

# Suffix-collapsed family from an object name (fallback when no spec info):
# ZMMRMAT058R01 -> ZMMRMAT#R# so 036/050/058 roll up to one family.
function Get-ObjectFamily([string]$obj) {
    if (-not $obj) { return 'UNKNOWN' }
    return [regex]::Replace($obj, '\d{2,}', '#')
}

function Get-GateForSkill([string]$skill) {
    switch ($skill) {
        'sap-gen-abap'           { return 'GEN' }
        'sap-check-abap'         { return 'CHECK' }
        'sap-check-fm'           { return 'CHECK' }
        'sap-docs-check'         { return 'SPEC' }
        'sap-se38'               { return 'DEPLOY' }
        'sap-se37'               { return 'DEPLOY' }
        'sap-se24'               { return 'DEPLOY' }
        'sap-atc'                { return 'ATC' }
        'sap-run-abap-unit'      { return 'AUNIT' }
        default                  { return '' }
    }
}

function Get-EventVerdict($ev) {
    $v = Get-EndField $ev.end 'verdict'
    if ($v) { return "$v".ToUpper() }
    switch ($ev.status) {
        'SUCCESS' { return 'PASS' }
        'EXISTED' { return 'PASS' }
        'SKIPPED' { return 'SKIPPED' }
        default   { return 'FAIL' }   # FAILED / ABANDONED / ''
    }
}

function Get-IsoWeekLabel([datetime]$dt) {
    $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    $wk = $cal.GetWeekOfYear($dt, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [System.DayOfWeek]::Monday)
    return ('{0}-W{1:00}' -f $dt.Year, $wk)
}

function PctOrNa([int]$num, [int]$den) {
    if ($den -le 0) { return -1 }
    return [int][math]::Round(100.0 * $num / $den)
}

# Mean of a numeric list x100 (so fractional averages survive the integer
# grammar: 1.30 iterations -> 130). Empty -> -1 (n/a).
function AvgX100($vals) {
    $a = @($vals)
    if ($a.Count -eq 0) { return -1 }
    $s = 0.0
    foreach ($v in $a) { $s += [double]$v }
    return [int][math]::Round(100.0 * $s / $a.Count)
}

function Pct([int]$v) { if ($v -lt 0) { return 'n/a' } else { return "$v%" } }
function Num100([int]$v) { if ($v -lt 0) { return 'n/a' } else { return ('{0:0.00}' -f ($v / 100.0)) } }

# ---------------------------------------------------------------------------
# 1. Read log records.
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $LogDir)) {
    Write-Output "ERROR: log directory not found: $LogDir"
    exit 2
}
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $LogDir) 'metrics' }
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

$sinceDt = $null
if ($Since) {
    try { $sinceDt = [datetime]::Parse($Since) } catch { Write-Output "ERROR: invalid -Since: $Since"; exit 2 }
}

$files = Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '\.log(\.\d+)?$' }
if (-not $files -or @($files).Count -eq 0) {
    Write-Output "ERROR: no .log files in $LogDir"
    exit 2
}

# run_id -> @{ skill; start; end }
$runs = @{}
$badLines = 0
foreach ($f in $files) {
    $reader = $null
    try {
        $reader = [System.IO.StreamReader]::new($f.FullName)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $rec = $null
            try { $rec = $line | ConvertFrom-Json -ErrorAction Stop } catch { $badLines++; continue }
            if (-not $rec.run_id -or -not $rec.phase) { continue }
            $rid = "$($rec.run_id)"
            if (-not $runs.ContainsKey($rid)) { $runs[$rid] = @{ skill = ''; start = $null; end = $null } }
            if ($rec.phase -eq 'start') {
                $runs[$rid].start = $rec
                $runs[$rid].skill = "$($rec.skill)"
            } elseif ($rec.phase -eq 'end') {
                $runs[$rid].end = $rec
                if (-not $runs[$rid].skill) { $runs[$rid].skill = "$($rec.skill)" }
            }
        }
    } finally {
        if ($reader) { $reader.Close() }
    }
}

# ---------------------------------------------------------------------------
# 2. Build events (one per run that maps to a build gate).
# ---------------------------------------------------------------------------

$events = New-Object System.Collections.Generic.List[object]
foreach ($rid in $runs.Keys) {
    $r = $runs[$rid]
    $skill = $r.skill
    $gate = Get-GateForSkill $skill
    if (-not $gate) { continue }   # only gate-producing skills form builds

    $st = $r.start; $en = $r.end
    $params = if ($st) { $st.params } else { $null }
    $tsStr = if ($st) { "$($st.ts)" } elseif ($en) { "$($en.ts)" } else { '' }
    $ts = $null
    try { $ts = [datetime]::Parse($tsStr) } catch { }
    if (-not $ts) { continue }
    if ($sinceDt -and $ts -lt $sinceDt) { continue }

    $objRaw = Get-ParamValue $params @('object_name', 'program', 'object')
    if (-not $objRaw) {
        $af = Get-ParamValue $params @('abap_file')
        if ($af) { try { $objRaw = [System.IO.Path]::GetFileNameWithoutExtension($af) } catch { } }
    }
    $obj = Normalize-Object $objRaw
    $spec = Get-SpecInfo $params

    $stale = $false
    if ($en) { $sv = Get-EndField $en 'stale_state'; if ($sv -eq $true) { $stale = $true } }

    $events.Add([pscustomobject]@{
        run_id         = $rid
        skill          = $skill
        gate           = $gate
        ts             = $ts
        obj            = $obj
        spec_family    = $(if ($spec) { $spec.family } else { '' })
        spec_lang      = $(if ($spec) { $spec.lang } else { '' })
        system_id      = (Get-ParamValue $params @('system_id'))
        plugin_version = (Get-ParamValue $params @('plugin_version'))
        build_id       = (Get-ParamValue $params @('build_id'))
        atc_variant    = (Get-ParamValue $params @('variant', 'atc_variant'))
        hasEnd         = ($null -ne $en)
        stale          = $stale
        status         = $(if ($en) { "$($en.status)" } else { '' })
        end            = $en
    })
}

if ($events.Count -eq 0) {
    Write-Output "INFO: no gate events found (bad_lines=$badLines). Nothing to aggregate."
    exit 1
}

# ---------------------------------------------------------------------------
# 3. Cluster events into builds (object + time-gap; gen-abap attached by time).
# ---------------------------------------------------------------------------

function Get-BuildWindow($b) {
    $mn = $null; $mx = $null
    foreach ($e in $b.events) {
        if ($null -eq $mn -or $e.ts -lt $mn) { $mn = $e.ts }
        if ($null -eq $mx -or $e.ts -gt $mx) { $mx = $e.ts }
    }
    return @{ min = $mn; max = $mx }
}

$builds = New-Object System.Collections.Generic.List[object]
$sorted = @($events | Sort-Object ts)
$objful = @($sorted | Where-Object { $_.obj -ne '' })
$objless = @($sorted | Where-Object { $_.obj -eq '' })

# 3a. Object-keyed builds, split on gaps > BuildGapHours.
$byObj = @{}
foreach ($ev in $objful) {
    if (-not $byObj.ContainsKey($ev.obj)) { $byObj[$ev.obj] = New-Object System.Collections.Generic.List[object] }
    $byObj[$ev.obj].Add($ev)
}
foreach ($obj in $byObj.Keys) {
    $list = @($byObj[$obj] | Sort-Object ts)
    $cur = $null; $lastTs = $null
    foreach ($ev in $list) {
        if ($null -eq $cur -or ($ev.ts - $lastTs).TotalHours -gt $BuildGapHours) {
            $cur = [pscustomobject]@{ events = New-Object System.Collections.Generic.List[object] }
            $builds.Add($cur)
        }
        $cur.events.Add($ev); $lastTs = $ev.ts
    }
}

# 3b. Attach object-less events (gen-abap) to the nearest build in time.
$leftover = New-Object System.Collections.Generic.List[object]
foreach ($ev in $objless) {
    $best = $null; $bestScore = $null
    foreach ($b in $builds) {
        $w = Get-BuildWindow $b
        $lo = $w.min.AddHours(-$BuildGapHours)
        $hi = $w.max.AddHours($BuildGapHours)
        if ($ev.ts -ge $lo -and $ev.ts -le $hi) {
            $score = [math]::Abs(($w.min - $ev.ts).TotalMinutes)
            if ($null -eq $bestScore -or $score -lt $bestScore) { $bestScore = $score; $best = $b }
        }
    }
    if ($best) { $best.events.Add($ev) } else { $leftover.Add($ev) }
}

# 3c. Left-over object-less events form their own builds, keyed by spec family.
$byFam = @{}
foreach ($ev in @($leftover | Sort-Object ts)) {
    $key = if ($ev.spec_family) { $ev.spec_family } else { 'UNKNOWN' }
    if (-not $byFam.ContainsKey($key)) { $byFam[$key] = New-Object System.Collections.Generic.List[object] }
    $byFam[$key].Add($ev)
}
foreach ($k in $byFam.Keys) {
    $list = @($byFam[$k] | Sort-Object ts)
    $cur = $null; $lastTs = $null
    foreach ($ev in $list) {
        if ($null -eq $cur -or ($ev.ts - $lastTs).TotalHours -gt $BuildGapHours) {
            $cur = [pscustomobject]@{ events = New-Object System.Collections.Generic.List[object] }
            $builds.Add($cur)
        }
        $cur.events.Add($ev); $lastTs = $ev.ts
    }
}

# ---------------------------------------------------------------------------
# 4. Assemble one sapdev.buildkpi/1 row per build.
# ---------------------------------------------------------------------------

function First-NonEmpty($evs, [string]$prop, [string]$skip = '') {
    foreach ($e in $evs) {
        $v = "$($e.$prop)"
        if ($v -and $v -ne $skip) { return $v }
    }
    return ''
}

function Build-Row($b) {
    $evs = @($b.events | Sort-Object ts)
    $w = Get-BuildWindow $b

    $obj = First-NonEmpty $evs 'obj'
    if (-not $obj) { $obj = 'UNKNOWN' }
    $famSpec = First-NonEmpty $evs 'spec_family'
    $family = if ($famSpec) { $famSpec } else { Get-ObjectFamily $obj }
    $lang = First-NonEmpty $evs 'spec_lang' 'unknown'
    if (-not $lang) { $lang = 'unknown' }
    $sys = First-NonEmpty $evs 'system_id'
    if (-not $sys) { $sys = 'unknown' }
    $pv = First-NonEmpty $evs 'plugin_version'
    if (-not $pv) { $pv = 'unknown' }
    $variant = First-NonEmpty $evs 'atc_variant'
    if (-not $variant) { $variant = 'DEFAULT' }
    $bid = First-NonEmpty $evs 'build_id'
    if (-not $bid) { $bid = ('{0}_{1}' -f $w.min.ToString('yyyyMMdd_HHmmss'), $obj) }

    $gatesOf = { param($g) @($evs | Where-Object { $_.gate -eq $g -and $_.hasEnd -and (-not $_.stale) }) }

    $gates = [ordered]@{}

    # GEN
    $genE = @(& $gatesOf 'GEN')
    if ($genE.Count -gt 0) {
        $g = $genE[0]
        $gates.GEN = [ordered]@{
            verdict        = (Get-EventVerdict $g)
            attempt        = 1
            test_file      = "$(Get-EndField $g.end 'test_file')"
            methods        = (To-IntOrNull (Get-EndField $g.end 'methods'))
            hints_injected = (To-IntOrNull (Get-EndField $g.end 'hints_injected'))
        }
    }

    # SPEC (verdict only; docs-check skills are not metric-enriched)
    $specE = @(& $gatesOf 'SPEC')
    if ($specE.Count -gt 0) {
        $anyFail = $false
        foreach ($e in $specE) { if ((Get-EventVerdict $e) -eq 'FAIL') { $anyFail = $true } }
        $gates.SPEC = [ordered]@{ verdict = $(if ($anyFail) { 'FAIL' } else { 'PASS' }) }
    }

    # CHECK (iterations = count of check runs in the cluster; first-pass keys on
    # the FIRST check being clean)
    $checkE = @(& $gatesOf 'CHECK')
    if ($checkE.Count -gt 0) {
        $first = $checkE[0]; $last = $checkE[$checkE.Count - 1]
        $gates.CHECK = [ordered]@{
            verdict     = (Get-EventVerdict $last)
            attempt     = 1
            iterations  = $checkE.Count
            errors      = (To-IntOrNull (Get-EndField $first.end 'errors'))
            warnings    = (To-IntOrNull (Get-EndField $first.end 'warnings'))
            first_clean = ((Get-EventVerdict $first) -eq 'PASS')
        }
    }

    # DEPLOY -> fan out into SYNTAX / ACTIVATE / TEXT
    $depE = @(& $gatesOf 'DEPLOY')
    if ($depE.Count -gt 0) {
        $d = $depE[0]
        $se = To-IntOrNull (Get-EndField $d.end 'syntax_errors')
        $act = To-BoolOrNull (Get-EndField $d.end 'activated')
        $txt = "$(Get-EndField $d.end 'text_elements')"
        $synV = if ($null -ne $se) { $(if ($se -eq 0) { 'PASS' } else { 'FAIL' }) } else { (Get-EventVerdict $d) }
        $actV = if ($null -ne $act) { $(if ($act) { 'PASS' } else { 'FAIL' }) } else { (Get-EventVerdict $d) }
        $gates.SYNTAX = [ordered]@{ verdict = $synV; attempt = 1; syntax_errors = $se }
        $gates.ACTIVATE = [ordered]@{ verdict = $actV; attempt = 1; activated = $act }
        if ($txt -and $txt.ToUpper() -ne 'NA' -and $txt -ne '') {
            $applied = ($txt.ToUpper() -eq 'APPLIED')
            $gates.TEXT = [ordered]@{ verdict = $(if ($applied) { 'PASS' } else { 'FAIL' }); applied = $applied }
        }
    }

    # ATC
    $atcE = @(& $gatesOf 'ATC')
    if ($atcE.Count -gt 0) {
        $a = $atcE[0]
        $gates.ATC = [ordered]@{
            verdict = (Get-EventVerdict $a)
            attempt = 1
            p1 = (To-IntOrNull (Get-EndField $a.end 'p1'))
            p2 = (To-IntOrNull (Get-EndField $a.end 'p2'))
            p3 = (To-IntOrNull (Get-EndField $a.end 'p3'))
        }
    }

    # AUNIT
    $auE = @(& $gatesOf 'AUNIT')
    if ($auE.Count -gt 0) {
        $a = $auE[0]
        $cov = To-IntOrNull (Get-EndField $a.end 'coverage')
        $gates.AUNIT = [ordered]@{
            verdict  = (Get-EventVerdict $a)
            methods  = (To-IntOrNull (Get-EndField $a.end 'methods'))
            passed   = (To-IntOrNull (Get-EndField $a.end 'passed'))
            failed   = (To-IntOrNull (Get-EndField $a.end 'failed'))
            coverage = $cov
        }
    }

    # mode
    $mode = 'deploy'
    if ($gates.Contains('GEN')) { $mode = 'build' }
    elseif ($gates.Contains('CHECK') -or $gates.Contains('ATC')) { $mode = 'fix' }

    # outcome
    $incomplete = $false
    foreach ($e in $evs) { if ((-not $e.hasEnd) -or $e.stale) { $incomplete = $true } }
    $hasFail = $false
    foreach ($e in $evs) { if ($e.status -eq 'FAILED') { $hasFail = $true } }
    foreach ($gk in $gates.Keys) { if ($gates[$gk].verdict -eq 'FAIL') { $hasFail = $true } }
    $outcome = if ($hasFail) { 'FAILED' } elseif ($incomplete) { 'ABORTED' } else { 'SUCCESS' }

    return [pscustomobject]@{
        schema         = 'sapdev.buildkpi/1'
        build_id       = $bid
        ts_start       = $w.min.ToString('yyyy-MM-ddTHH:mm:sszzz')
        ts_end         = $w.max.ToString('yyyy-MM-ddTHH:mm:sszzz')
        mode           = $mode
        object         = $obj
        spec_family    = $family
        spec_lang      = $lang
        system_id      = $sys
        atc_variant    = $variant
        plugin_version = $pv
        outcome        = $outcome
        incomplete     = $incomplete
        week           = (Get-IsoWeekLabel $w.min)
        gates          = $gates
    }
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($b in $builds) { $rows.Add((Build-Row $b)) }
$rowArr = @($rows | Sort-Object ts_start)

# ---------------------------------------------------------------------------
# 5. KPI computation over a set of rows.
# ---------------------------------------------------------------------------

function Has-Gate($row, [string]$g) { return $row.gates.Contains($g) }
function GVerdict($row, [string]$g) { if ($row.gates.Contains($g)) { return $row.gates[$g].verdict } return '' }
function GField($row, [string]$g, [string]$f) {
    if ($row.gates.Contains($g)) { $gg = $row.gates[$g]; if ($gg.Contains($f)) { return $gg[$f] } }
    return $null
}

function Compute-Kpis($rowsIn) {
    $rs = @($rowsIn)
    $k = [ordered]@{}
    $k.builds_total = $rs.Count

    # gen_first_pass: of builds that ran CHECK, the first check was clean AND
    # generation did not fail to emit a mandated test file.
    $chk = @($rs | Where-Object { Has-Gate $_ 'CHECK' })
    $genPass = @($chk | Where-Object {
        (GField $_ 'CHECK' 'first_clean') -eq $true -and (("$(GField $_ 'GEN' 'test_file')") -ne 'FAILED')
    })
    $k.gen_first_pass_pct = PctOrNa $genPass.Count $chk.Count
    $k.fix_iters_avg = AvgX100 (@($chk | ForEach-Object { GField $_ 'CHECK' 'iterations' } | Where-Object { $null -ne $_ }))

    $syn = @($rs | Where-Object { Has-Gate $_ 'SYNTAX' })
    $k.syntax_first_pass_pct = PctOrNa (@($syn | Where-Object { (GVerdict $_ 'SYNTAX') -eq 'PASS' }).Count) $syn.Count

    $act = @($rs | Where-Object { Has-Gate $_ 'ACTIVATE' })
    $k.activation_first_pass_pct = PctOrNa (@($act | Where-Object { (GVerdict $_ 'ACTIVATE') -eq 'PASS' }).Count) $act.Count

    $txt = @($rs | Where-Object { Has-Gate $_ 'TEXT' })
    $k.text_elements_applied_pct = PctOrNa (@($txt | Where-Object { (GField $_ 'TEXT' 'applied') -eq $true }).Count) $txt.Count

    $atc = @($rs | Where-Object { Has-Gate $_ 'ATC' })
    $k.atc_first_pass_pct = PctOrNa (@($atc | Where-Object { (GVerdict $_ 'ATC') -eq 'PASS' }).Count) $atc.Count
    $k.atc_p1_first_run_avg = AvgX100 (@($atc | ForEach-Object { GField $_ 'ATC' 'p1' } | Where-Object { $null -ne $_ }))
    $k.atc_p2_first_run_avg = AvgX100 (@($atc | ForEach-Object { GField $_ 'ATC' 'p2' } | Where-Object { $null -ne $_ }))
    $k.atc_p3_first_run_avg = AvgX100 (@($atc | ForEach-Object { GField $_ 'ATC' 'p3' } | Where-Object { $null -ne $_ }))

    $au = @($rs | Where-Object { Has-Gate $_ 'AUNIT' })
    $k.aunit_first_pass_pct = PctOrNa (@($au | Where-Object { (GVerdict $_ 'AUNIT') -eq 'PASS' }).Count) $au.Count
    $k.aunit_coverage_avg = AvgX100 (@($au | ForEach-Object { GField $_ 'AUNIT' 'coverage' } | Where-Object { $null -ne $_ -and $_ -ge 0 }))

    $k.e2e_success_pct = PctOrNa (@($rs | Where-Object { $_.outcome -eq 'SUCCESS' }).Count) $rs.Count
    $k.hints_injected_avg = AvgX100 (@($rs | ForEach-Object { GField $_ 'GEN' 'hints_injected' } | Where-Object { $null -ne $_ }))
    return $k
}

# Group rows by a key selector. Returns a plain array of group objects
# { key=<string>; rows=<object[]> } in first-seen order. Avoids passing an
# OrderedDictionary with List-typed values around (PS 5.1 chokes on @() over a
# dictionary-indexed List in some paths); a plain array of clean arrays is safe.
function Group-Rows($rowsIn, [scriptblock]$keyOf) {
    $order = New-Object System.Collections.Generic.List[string]
    $map = @{}
    foreach ($r in @($rowsIn)) {
        $key = [string](& $keyOf $r)
        if (-not $map.ContainsKey($key)) {
            $map[$key] = New-Object System.Collections.Generic.List[object]
            $order.Add($key)
        }
        $map[$key].Add($r)
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in $order) { $out.Add([pscustomobject]@{ key = $k; rows = @($map[$k].ToArray()) }) }
    return ,$out.ToArray()
}

$headline = Compute-Kpis $rowArr

# ---------------------------------------------------------------------------
# 6. Emit grammar to stdout.
# ---------------------------------------------------------------------------

if (-not $Quiet) {
    foreach ($r in $rowArr) { Write-Output ("BUILD: {0} | OUTCOME: {1}" -f $r.build_id, $r.outcome) }
}
foreach ($name in $headline.Keys) { Write-Output ("METRIC: {0} | VALUE: {1}" -f $name, $headline[$name]) }

$weekGroups = Group-Rows $rowArr { param($r) $r.week }
foreach ($grp in $weekGroups) {
    $wk = $grp.key
    $g = Compute-Kpis $grp.rows
    Write-Output ("GROUP: week=$wk | BUILDS: $($g.builds_total)")
    Write-Output ("METRIC: e2e_success_pct | VALUE: $($g.e2e_success_pct) | GROUP: week=$wk")
    Write-Output ("METRIC: gen_first_pass_pct | VALUE: $($g.gen_first_pass_pct) | GROUP: week=$wk")
    Write-Output ("METRIC: atc_first_pass_pct | VALUE: $($g.atc_first_pass_pct) | GROUP: week=$wk")
}

# ---------------------------------------------------------------------------
# 7. Write build_kpi.jsonl + dashboard.md.
# ---------------------------------------------------------------------------

$jsonlPath = Join-Path $OutDir 'build_kpi.jsonl'
$sbJ = New-Object System.Text.StringBuilder
foreach ($r in $rowArr) { [void]$sbJ.AppendLine(($r | ConvertTo-Json -Compress -Depth 8)) }
Write-Utf8NoBom $jsonlPath ($sbJ.ToString())

function KpiTable($k) {
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("| Metric | Value |")
    $L.Add("|--------|-------|")
    $L.Add("| Builds (total) | $($k.builds_total) |")
    $L.Add("| End-to-end success | $(Pct $k.e2e_success_pct) |")
    $L.Add("| Gen first-pass (check-1 clean) | $(Pct $k.gen_first_pass_pct) |")
    $L.Add("| Fix iterations (avg) | $(Num100 $k.fix_iters_avg) |")
    $L.Add("| Syntax first-pass | $(Pct $k.syntax_first_pass_pct) |")
    $L.Add("| Activation first-pass | $(Pct $k.activation_first_pass_pct) |")
    $L.Add("| Text elements applied | $(Pct $k.text_elements_applied_pct) |")
    $L.Add("| ATC first-pass (P1=P2=0) | $(Pct $k.atc_first_pass_pct) |")
    $L.Add("| ATC P1 / P2 / P3 first-run (avg) | $(Num100 $k.atc_p1_first_run_avg) / $(Num100 $k.atc_p2_first_run_avg) / $(Num100 $k.atc_p3_first_run_avg) |")
    $L.Add("| ABAP Unit first-pass | $(Pct $k.aunit_first_pass_pct) |")
    $L.Add("| ABAP Unit coverage (avg) | $(Num100 $k.aunit_coverage_avg) |")
    $L.Add("| frequently_errors hints injected (avg) | $(Num100 $k.hints_injected_avg) |")
    return $L
}

$today = (Get-Date).ToString('yyyy-MM-dd')
$D = New-Object System.Collections.Generic.List[string]
$D.Add("# Generated-ABAP build metrics -- dashboard ($today)")
$D.Add("")
$D.Add("Derived offline from $($files.Count) log file(s) in ``$LogDir`` (bad_lines=$badLines).")
$D.Add("Schema sapdev.buildkpi/1. Each ``n/a`` is an unmeasured KPI, never a 0%.")
$D.Add("")
$D.Add("## Headline (all builds)")
foreach ($l in (KpiTable $headline)) { $D.Add($l) }
$D.Add("")
$D.Add("## By ISO week")
$D.Add("| Week | Builds | E2E success | Gen 1st-pass | ATC 1st-pass | AUnit 1st-pass |")
$D.Add("|------|--------|-------------|--------------|--------------|----------------|")
foreach ($grp in $weekGroups) {
    $g = Compute-Kpis $grp.rows
    $D.Add("| $($grp.key) | $($g.builds_total) | $(Pct $g.e2e_success_pct) | $(Pct $g.gen_first_pass_pct) | $(Pct $g.atc_first_pass_pct) | $(Pct $g.aunit_first_pass_pct) |")
}
$D.Add("")
$D.Add("## By spec family")
$D.Add("| Family | Builds | E2E success | Gen 1st-pass | ATC 1st-pass | Fix iters |")
$D.Add("|--------|--------|-------------|--------------|--------------|-----------|")
$famGroups = Group-Rows $rowArr { param($r) $r.spec_family }
foreach ($grp in $famGroups) {
    $g = Compute-Kpis $grp.rows
    $D.Add("| $($grp.key) | $($g.builds_total) | $(Pct $g.e2e_success_pct) | $(Pct $g.gen_first_pass_pct) | $(Pct $g.atc_first_pass_pct) | $(Num100 $g.fix_iters_avg) |")
}
$D.Add("")
$D.Add("## By system + ATC variant")
$D.Add("_ATC counts are only comparable within one (system, variant) -- never blended._")
$D.Add("")
$D.Add("| System | Variant | Builds | ATC 1st-pass | ATC P1/P2/P3 avg |")
$D.Add("|--------|---------|--------|--------------|------------------|")
$sysGroups = Group-Rows $rowArr { param($r) "$($r.system_id)|$($r.atc_variant)" }
foreach ($grp in $sysGroups) {
    $g = Compute-Kpis $grp.rows
    $parts = $grp.key.Split('|')
    $D.Add("| $($parts[0]) | $($parts[1]) | $($g.builds_total) | $(Pct $g.atc_first_pass_pct) | $(Num100 $g.atc_p1_first_run_avg)/$(Num100 $g.atc_p2_first_run_avg)/$(Num100 $g.atc_p3_first_run_avg) |")
}
$D.Add("")
$dashPath = Join-Path $OutDir 'dashboard.md'
Write-Utf8NoBom $dashPath (($D -join "`r`n") + "`r`n")

Write-Output "INFO: wrote $jsonlPath ($($rowArr.Count) build row(s))"
Write-Output "REPORT: wrote $dashPath"
if ($rowArr.Count -eq 0) { exit 1 }
exit 0
