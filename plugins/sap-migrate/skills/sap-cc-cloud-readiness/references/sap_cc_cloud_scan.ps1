# =============================================================================
# sap_cc_cloud_scan.ps1  -  Offline ABAP Cloud-readiness scanner (no SAP/RFC)
# -----------------------------------------------------------------------------
# Reads already-downloaded ABAP source files, matches the cloud knowledge pack
# (forbidden-statement ruleset + cloudification repository), and classifies each
# object onto the ABAP Cloud distance ladder:
#     TIER_1_READY | TIER_2_WRAPPABLE | TIER_3_CLASSIC | COULD_NOT_CHECK
# Writes cloud_tier.tsv + blockers.tsv. PURE LOCAL -- runs in any PowerShell, so
# the engine is unit-testable on fixtures with zero SAP dependency (the RFC
# source download is the SKILL.md's job; this script never connects).
#
# Object list + per-object coverage come from an optional coverage.tsv in
# -SourceDir (object_type/object_name/package/coverage/reason); absent -> the
# .abap files present are the scope (coverage=FULL). Source filename convention:
#     <TYPE>__<NAME>.abap        (NAME uses '#' for '/', e.g. #ns#zcl -> /ns/zcl)
#
# Honesty contract (see knowledge/cloud/README.md):
#   - a forbidden-statement hit is high-confidence -> TIER_3_CLASSIC
#   - an API ref absent from the repo is 'unknown': counted, NEVER a blocker, so
#     a partial pack cannot manufacture a false TIER_3; the cost is disclosed as
#     coverage=PARTIAL (a TIER_1 object with unknown refs is never a clean FULL)
#   - a source that could not be read is TIER=COULD_NOT_CHECK, never TIER_1
#   - any dynamic token (CALL FUNCTION <var>, dynamic CREATE OBJECT / SELECT)
#     sets dynamic_blindspot=YES on the row (the regex scanner is blind to it)
#
# Output grammar (parseable; sap-cc line style):
#   TIER: <TYPE> <NAME> = <tier> blockers=<n> blindspot=<Y|N> coverage=<c>
#   KP: version=<v> snapshot=<d> [STALE age_days=<n>]
#   STATUS: OK t1=<n> t2=<n> t3=<n> could_not_check=<n> file=<path>
#   STATUS: EMPTY | STATUS: ERROR msg=<...>
# Exit: 0 ok | 1 empty (no objects in scope) | 2 error (bad input / no pack)
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$KnowledgePack = '',     # shipped pack dir; else resolved next to this script
    [string]$CustomUrl = '',         # {custom_url}: override pack file-by-file under \knowledge\cloud\
    [string]$ScannedOn = ''          # yyyyMMdd; default = today (kept a param so tests are deterministic)
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8Bom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($true)   # BOM: Excel-safe TSVs
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}
function Fail([string]$msg) { Write-Output "STATUS: ERROR msg=$msg"; exit 2 }

# ---- knowledge pack resolution (custom override wins file-by-file) -----------
if (-not $KnowledgePack) { $KnowledgePack = Join-Path (Split-Path -Parent $PSCommandPath) '..\..\..\shared\knowledge\cloud' }
function Resolve-PackFile([string]$name) {
    if ($CustomUrl) {
        $c = Join-Path $CustomUrl ("knowledge\cloud\" + $name)
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $s = Join-Path $KnowledgePack $name
    if (Test-Path -LiteralPath $s) { return $s }
    return $null
}

$fbFile = Resolve-PackFile 'forbidden_statements.tsv'
$repoFile = Resolve-PackFile 'cloudification_repository.json'
$metaFile = Resolve-PackFile 'kp_meta.json'
if (-not $fbFile)   { Fail "CC_KP_MISSING forbidden_statements.tsv (looked in custom_url + $KnowledgePack)" }
if (-not $repoFile) { Fail "CC_KP_MISSING cloudification_repository.json" }

# forbidden ruleset
$rules = @()
foreach ($ln in @(Get-Content -LiteralPath $fbFile)) {
    if (-not $ln.Trim() -or $ln -like 'rule_id`t*') { continue }
    $c = $ln -split "`t"
    if ($c.Count -lt 4) { continue }
    $rules += [pscustomobject]@{
        RuleId = $c[0]; Pattern = $c[1]; Tier = $c[2]; Category = $c[3]
        Rx = [regex]::new($c[1], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
}
if ($rules.Count -eq 0) { Fail "CC_KP_MISSING forbidden ruleset parsed 0 rows" }

# cloudification repository
$repo = @{}
try {
    $rj = (Get-Content -LiteralPath $repoFile -Raw | ConvertFrom-Json)
    foreach ($p in $rj.entries.PSObject.Properties) { $repo[$p.Name.ToUpper()] = $p.Value }
} catch { Fail "CC_KP_MISSING cloudification_repository.json parse: $($_.Exception.Message)" }

# meta + staleness
$kpVersion = 'unknown'; $snapshot = ''
if ($metaFile) {
    try {
        $mj = (Get-Content -LiteralPath $metaFile -Raw | ConvertFrom-Json)
        if ($mj.kp_version) { $kpVersion = [string]$mj.kp_version }
        if ($mj.snapshot_date) { $snapshot = [string]$mj.snapshot_date }
        $staleAfter = 180; if ($mj.stale_after_days) { $staleAfter = [int]$mj.stale_after_days }
    } catch { $staleAfter = 180 }
} else { $staleAfter = 180 }
$kpLine = "KP: version=$kpVersion snapshot=$snapshot"
if ($snapshot) {
    try {
        $age = ([datetime]::Today - [datetime]::ParseExact($snapshot, 'yyyy-MM-dd', $null)).Days
        if ($age -gt $staleAfter) { $kpLine += " STALE age_days=$age" }
    } catch {}
}
Write-Output $kpLine

if (-not $ScannedOn) { $ScannedOn = (Get-Date).ToString('yyyyMMdd') }

# ---- ABAP preprocessing: strip comments, join into statements ---------------
function Split-AbapStatements([string]$text) {
    # Returns @( @{ Text=<normalised, original-case>; Line=<1-based start> } )
    $physical = $text -split "`r?`n"
    # phase 1: strip comments per physical line, keep (clean, origLine)
    $clean = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $physical.Count; $i++) {
        $line = $physical[$i]
        if ($line.Length -gt 0 -and $line[0] -eq '*') { $clean.Add(@{ T = ''; L = $i + 1 }); continue }
        $sb = New-Object System.Text.StringBuilder
        $inStr = $false; $inTpl = $false
        for ($j = 0; $j -lt $line.Length; $j++) {
            $ch = $line[$j]
            if ($inStr) {
                [void]$sb.Append($ch)
                if ($ch -eq "'") { if ($j + 1 -lt $line.Length -and $line[$j + 1] -eq "'") { [void]$sb.Append("'"); $j++ } else { $inStr = $false } }
                continue
            }
            if ($inTpl) { [void]$sb.Append($ch); if ($ch -eq '`') { $inTpl = $false }; continue }
            if ($ch -eq '"') { break }         # inline comment to EOL
            if ($ch -eq "'") { $inStr = $true; [void]$sb.Append($ch); continue }
            if ($ch -eq '`') { $inTpl = $true; [void]$sb.Append($ch); continue }
            [void]$sb.Append($ch)
        }
        $clean.Add(@{ T = $sb.ToString(); L = $i + 1 })
    }
    # phase 2: join into statements, split on '.' outside string literals
    $stmts = New-Object System.Collections.Generic.List[object]
    $cur = New-Object System.Text.StringBuilder
    $startLine = 0; $inStr = $false; $inTpl = $false
    foreach ($cl in $clean) {
        $lt = [string]$cl.T
        if ($startLine -eq 0 -and $lt.Trim()) { $startLine = $cl.L }
        for ($j = 0; $j -lt $lt.Length; $j++) {
            $ch = $lt[$j]
            if ($inStr) { [void]$cur.Append($ch); if ($ch -eq "'") { if ($j + 1 -lt $lt.Length -and $lt[$j + 1] -eq "'") { [void]$cur.Append("'"); $j++ } else { $inStr = $false } }; continue }
            if ($inTpl) { [void]$cur.Append($ch); if ($ch -eq '`') { $inTpl = $false }; continue }
            if ($ch -eq "'") { $inStr = $true; [void]$cur.Append($ch); continue }
            if ($ch -eq '`') { $inTpl = $true; [void]$cur.Append($ch); continue }
            if ($ch -eq '.') {
                $t = ($cur.ToString() -replace '\s+', ' ').Trim()
                if ($t) { $stmts.Add(@{ Text = $t; Line = $startLine }) }
                [void]$cur.Clear(); $startLine = 0; continue
            }
            [void]$cur.Append($ch)
        }
        [void]$cur.Append(' ')   # line break becomes whitespace inside a statement
    }
    $t = ($cur.ToString() -replace '\s+', ' ').Trim()
    if ($t) { $stmts.Add(@{ Text = $t; Line = $startLine }) }
    return $stmts
}

# ---- API extraction ---------------------------------------------------------
$reStop = @{ 'DATABASE'=1;'MEMORY'=1;'SCREEN'=1;'TABLE'=1;'LOGFILE'=1;'ID'=1;'SHARED'=1;'DATASET'=1 }
$reFm      = [regex]'(?i)\bCALL\s+FUNCTION\s+''([^'']+)'''
$reClass   = [regex]'(?i)\b([A-Z_/][A-Z0-9_/]*)\s*=>'
$reFrom    = [regex]'(?i)\b(?:FROM|JOIN)\s+([A-Z_/][A-Z0-9_/]*)'
$reTables  = [regex]'(?i)\bTABLES\s+([A-Z_/][A-Z0-9_/]*)'
# dynamic blind-spot tokens
$reDyn = @(
    [regex]'(?i)\bCALL\s+FUNCTION\s+(?!'')',      # CALL FUNCTION <var>
    [regex]'(?i)\bCREATE\s+OBJECT\s+\(',          # dynamic class
    [regex]'(?i)\bCALL\s+METHOD\s+\(',            # dynamic method
    [regex]'(?i)\b(?:FROM|JOIN)\s+\(',            # dynamic table in SELECT
    [regex]'(?i)\bPERFORM\s+\(',                  # dynamic perform
    [regex]'(?i)\bASSIGN\s+\(',                   # dynamic assign
    [regex]'(?i)^DEFINE\b'                         # macro definition (opaque body)
)

function Get-Refs($stmts) {
    $refs = @{}   # "KIND:NAME" -> @{Kind;Name}
    foreach ($s in $stmts) {
        $tx = [string]$s.Text
        foreach ($m in $reFm.Matches($tx))     { $n = $m.Groups[1].Value.ToUpper(); $refs["FUNCTION:$n"] = @{ Kind='FUNCTION'; Name=$n } }
        foreach ($m in $reClass.Matches($tx))  { $n = $m.Groups[1].Value.ToUpper(); if ($n.Length -ge 2) { $refs["CLASS:$n"] = @{ Kind='CLASS'; Name=$n } } }
        foreach ($m in $reFrom.Matches($tx))   { $n = $m.Groups[1].Value.ToUpper(); if (-not $reStop.ContainsKey($n)) { $refs["TABLE:$n"] = @{ Kind='TABLE'; Name=$n } } }
        foreach ($m in $reTables.Matches($tx)) { $n = $m.Groups[1].Value.ToUpper(); if (-not $reStop.ContainsKey($n)) { $refs["TABLE:$n"] = @{ Kind='TABLE'; Name=$n } } }
    }
    return $refs
}

# ---- object list (coverage.tsv authoritative if present) --------------------
if (-not (Test-Path -LiteralPath $SourceDir)) { Fail "CC_SCAN_BAD_INPUT SourceDir not found: $SourceDir" }
[void][System.IO.Directory]::CreateDirectory($OutDir)

$objects = @()   # @{ Type; Name; Package; Coverage; Reason; File }
$covPath = Join-Path $SourceDir 'coverage.tsv'
$covIdx = @{}
if (Test-Path -LiteralPath $covPath) {
    $cl = @(Get-Content -LiteralPath $covPath)
    if ($cl.Count -ge 1) {
        $h = @($cl[0] -split "`t")
        for ($i = 0; $i -lt $h.Count; $i++) { $covIdx[($h[$i].Trim().ToLower())] = $i }
        for ($i = 1; $i -lt $cl.Count; $i++) {
            if (-not $cl[$i].Trim()) { continue }
            $c = $cl[$i] -split "`t"
            $ty = if ($covIdx.ContainsKey('object_type')) { $c[$covIdx['object_type']] } else { '' }
            $nm = if ($covIdx.ContainsKey('object_name')) { $c[$covIdx['object_name']] } else { '' }
            if (-not $ty -or -not $nm) { continue }
            $pk = if ($covIdx.ContainsKey('package')) { $c[$covIdx['package']] } else { '' }
            $cv = if ($covIdx.ContainsKey('coverage')) { $c[$covIdx['coverage']] } else { 'FULL' }
            $rs = if ($covIdx.ContainsKey('reason')) { $c[$covIdx['reason']] } else { '' }
            $safe = ($nm -replace '/', '#')
            $f = Join-Path $SourceDir ("{0}__{1}.abap" -f $ty.ToUpper(), $safe)
            $objects += @{ Type = $ty.ToUpper(); Name = $nm; Package = $pk; Coverage = $cv.ToUpper(); Reason = $rs; File = $f }
        }
    }
}
if ($objects.Count -eq 0) {
    foreach ($f in @(Get-ChildItem -LiteralPath $SourceDir -Filter '*.abap' -File -ErrorAction SilentlyContinue)) {
        if ($f.BaseName -match '^([A-Za-z]+)__(.+)$') {
            $objects += @{ Type = $Matches[1].ToUpper(); Name = ($Matches[2] -replace '#', '/'); Package = ''; Coverage = 'FULL'; Reason = ''; File = $f.FullName }
        }
    }
}
if ($objects.Count -eq 0) { Write-Output 'STATUS: EMPTY'; exit 1 }

# ---- scan loop --------------------------------------------------------------
$tierRows = New-Object System.Collections.Generic.List[string]
$tierRows.Add(("object_type`tobject_name`tpackage`ttier`tblocker_count`tdynamic_blindspot`tapi_refs_total`tapi_refs_released`tapi_refs_successor`tapi_refs_unknown`tatc_verdict`tcoverage`tkp_version`tscanned_on"))
$blkRows = New-Object System.Collections.Generic.List[string]
$blkRows.Add(("object`tinclude`tline`tblocker_kind`trule_id`tapi`ttoken`tsuccessor`ttier_impact"))

$cnt = @{ t1=0; t2=0; t3=0; cnc=0 }
foreach ($o in $objects) {
    $okey = "$($o.Type):$($o.Name)"
    if ($o.Coverage -eq 'COULD_NOT_CHECK' -or $o.Coverage -eq 'NONE' -or -not (Test-Path -LiteralPath $o.File)) {
        $reason = if ($o.Reason) { $o.Reason } else { 'SOURCE_UNREADABLE' }
        $tierRows.Add("$($o.Type)`t$($o.Name)`t$($o.Package)`tCOULD_NOT_CHECK`t0`tN`t0`t0`t0`t0`t-`tNONE:$reason`t$kpVersion`t$ScannedOn")
        Write-Output "TIER: $($o.Type) $($o.Name) = COULD_NOT_CHECK coverage=NONE:$reason"
        $cnt.cnc++; continue
    }
    $src = ''
    try { $src = [System.IO.File]::ReadAllText($o.File) } catch { }
    $stmts = Split-AbapStatements $src

    # forbidden statements
    $forbidden = @()
    foreach ($s in $stmts) {
        foreach ($r in $rules) {
            if ($r.Rx.IsMatch([string]$s.Text)) {
                $tok = [string]$s.Text; if ($tok.Length -gt 80) { $tok = $tok.Substring(0, 80) }
                $forbidden += @{ Line = $s.Line; RuleId = $r.RuleId; Token = $tok; Tier = $r.Tier }
            }
        }
    }
    # dynamic blind-spot
    $blind = $false
    foreach ($s in $stmts) { foreach ($rx in $reDyn) { if ($rx.IsMatch([string]$s.Text)) { $blind = $true; break } }; if ($blind) { break } }

    # API refs
    $refs = Get-Refs $stmts
    $released = 0; $unknown = 0
    $t2Api = @(); $t3Api = @()
    foreach ($k in $refs.Keys) {
        $e = $repo[$k]
        if ($null -eq $e) { $unknown++; continue }
        if ([string]$e.state -eq 'released') { $released++; continue }
        $succ = [string]$e.successor
        if ($succ) { $t2Api += @{ Api = $k; Token = $refs[$k].Name; Successor = $succ } }
        else { $t3Api += @{ Api = $k; Token = $refs[$k].Name; Successor = '' } }
    }
    $refsTotal = $refs.Count

    # tier
    $tier = 'TIER_1_READY'
    if ($forbidden.Count -gt 0 -or $t3Api.Count -gt 0) { $tier = 'TIER_3_CLASSIC' }
    elseif ($t2Api.Count -gt 0) { $tier = 'TIER_2_WRAPPABLE' }

    # coverage
    $coverage = 'FULL'
    if ($unknown -gt 0) { $coverage = "PARTIAL:UNKNOWN_APIS_$unknown" }

    $blockerCount = $forbidden.Count + $t2Api.Count + $t3Api.Count
    $inc = "$($o.Type)__$($o.Name)"
    foreach ($b in $forbidden) { $blkRows.Add("$okey`t$inc`t$($b.Line)`tFORBIDDEN_STMT`t$($b.RuleId)`t`t$($b.Token)`t`t$($b.Tier)") }
    foreach ($b in $t3Api)     { $blkRows.Add("$okey`t$inc`t`tUNRELEASED_API`t`t$($b.Api)`t$($b.Token)`t$($b.Successor)`tT3") }
    foreach ($b in $t2Api)     { $blkRows.Add("$okey`t$inc`t`tUNRELEASED_API`t`t$($b.Api)`t$($b.Token)`t$($b.Successor)`tT2") }

    $bs = if ($blind) { 'Y' } else { 'N' }
    $tierRows.Add("$($o.Type)`t$($o.Name)`t$($o.Package)`t$tier`t$blockerCount`t$bs`t$refsTotal`t$released`t$($t2Api.Count)`t$unknown`t-`t$coverage`t$kpVersion`t$ScannedOn")
    Write-Output "TIER: $($o.Type) $($o.Name) = $tier blockers=$blockerCount blindspot=$bs coverage=$coverage"
    switch ($tier) { 'TIER_1_READY' { $cnt.t1++ } 'TIER_2_WRAPPABLE' { $cnt.t2++ } 'TIER_3_CLASSIC' { $cnt.t3++ } }
}

$tierPath = Join-Path $OutDir 'cloud_tier.tsv'
$blkPath  = Join-Path $OutDir 'blockers.tsv'
Write-Utf8Bom $tierPath (($tierRows -join "`r`n") + "`r`n")
Write-Utf8Bom $blkPath  (($blkRows  -join "`r`n") + "`r`n")
Write-Output "STATUS: OK t1=$($cnt.t1) t2=$($cnt.t2) t3=$($cnt.t3) could_not_check=$($cnt.cnc) file=$tierPath"
exit 0
