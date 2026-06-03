# =============================================================================
# sap_diagnose_correlate.ps1  -  Deterministic correlation engine for /sap-diagnose
#
# Reads every evidence_*.json in -RunDir (shape: diagnose_evidence_schema.json),
# builds a weighted evidence graph, clusters by connected components (edges with
# weight >= MED), and writes correlation.json.
#
# PURE DATA PROCESSING -- no RFC, no GUI, no SAP. Fully deterministic and
# offline-testable. Runs on Windows PowerShell 5.1 and PowerShell 7.
#
# Edge weights / confidence:
#   explicit            3 / HIGH   one event's explicit_links references another
#   business-key        3 / HIGH   shared object_keys KEY=VALUE across two events
#   identity+temporal   2 / MED    same user+client OR same program OR same tcode,
#                                   AND |dt| <= TightSeconds
#   temporal            1 / LOW    |dt| <= TightSeconds, nothing else shared
#
# Clustering uses edges with weight >= 2 (MED+). LOW edges are recorded but do
# NOT merge clusters (informational only).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sap_diagnose_correlate.ps1 -RunDir <dir> [-TightSeconds 5]
#
# Output:
#   <RunDir>\correlation.json
#   stdout last line: CORRELATION: clusters=<n> events=<m> edges=<e> file=<path>
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [int]$TightSeconds = 5
)

$ErrorActionPreference = 'Stop'

function Parse-Ts([string]$ts) {
    if ([string]::IsNullOrWhiteSpace($ts)) { return $null }
    $ts = $ts.Trim()
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($f in @('yyyyMMddHHmmss', 'yyyyMMddHHmm', 'yyyyMMdd', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-dd HH:mm:ss')) {
        try { return [datetime]::ParseExact($ts, $f, $ci) } catch { }
    }
    try { return [datetime]::Parse($ts, $ci) } catch { }
    return $null
}

# object_keys (PSCustomObject) -> hashtable KEY(upper)->VALUE(trim), non-empty only
function Keys-Of($e) {
    $h = @{}
    if ($e.object_keys) {
        foreach ($p in $e.object_keys.PSObject.Properties) {
            $v = "$($p.Value)"
            if (-not [string]::IsNullOrWhiteSpace($v)) { $h[$p.Name.ToUpperInvariant()] = $v.Trim() }
        }
    }
    return $h
}

# does link string $l reference event $b (whose keys are $bKeys)?
function Link-Matches([string]$l, $b, $bKeys) {
    if ([string]::IsNullOrWhiteSpace($l)) { return $false }
    $l = $l.Trim()
    if ($l -ieq "$($b.id)") { return $true }
    if ($b.tech) {
        foreach ($p in $b.tech.PSObject.Properties) {
            if ("$($p.Value)".Trim() -ieq $l) { return $true }
        }
    }
    foreach ($kv in $bKeys.GetEnumerator()) {
        if ($kv.Value -ieq $l) { return $true }
        if ("$($kv.Key):$($kv.Value)" -ieq $l) { return $true }
    }
    return $false
}

# ---- load evidence -------------------------------------------------------
$files   = @(Get-ChildItem -Path $RunDir -Filter 'evidence_*.json' -File -ErrorAction SilentlyContinue)
$events  = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList

foreach ($f in $files) {
    $obj = $null
    try { $obj = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { [void]$skipped.Add([pscustomobject]@{ source = $f.BaseName; reason = "parse_error: $($_.Exception.Message)" }); continue }
    if ($null -eq $obj) { continue }
    if ("$($obj.status)" -eq 'skipped') {
        [void]$skipped.Add([pscustomobject]@{ source = "$($obj.source)"; reason = "$($obj.reason)" }); continue
    }
    if ($obj.events) {
        foreach ($e in $obj.events) {
            $ev = [pscustomobject]@{
                id             = "$($e.id)"
                source         = "$($e.source)"
                ts             = "$($e.ts)"
                tsDate         = (Parse-Ts "$($e.ts)")
                severity       = "$($e.severity)"
                client         = "$($e.client)"
                user           = "$($e.user)"
                tcode          = "$($e.tcode)"
                program        = "$($e.program)"
                object_keys    = $e.object_keys
                tech           = $e.tech
                explicit_links = @($e.explicit_links)
            }
            if ([string]::IsNullOrWhiteSpace($ev.id)) { $ev.id = "$($ev.source)-$($events.Count + 1)" }
            [void]$events.Add($ev)
        }
    }
}

$n = $events.Count
$keysArr = @()
for ($i = 0; $i -lt $n; $i++) { $keysArr += , (Keys-Of $events[$i]) }

# ---- union-find ----------------------------------------------------------
$parent = @{}
for ($i = 0; $i -lt $n; $i++) { $parent[$i] = $i }
function Find($x) {
    $root = $x
    while ($parent[$root] -ne $root) { $root = $parent[$root] }
    while ($parent[$x] -ne $root) { $t = $parent[$x]; $parent[$x] = $root; $x = $t }
    return $root
}
function Union($a, $b) { $ra = Find $a; $rb = Find $b; if ($ra -ne $rb) { $parent[$rb] = $ra } }

# ---- build edges ---------------------------------------------------------
$edges = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $n; $i++) {
    for ($j = $i + 1; $j -lt $n; $j++) {
        $a = $events[$i]; $b = $events[$j]
        $ka = $keysArr[$i]; $kb = $keysArr[$j]
        $w = 0; $type = ''; $conf = ''

        # explicit
        $explicit = $false
        foreach ($l in $a.explicit_links) { if (Link-Matches $l $b $kb) { $explicit = $true; break } }
        if (-not $explicit) { foreach ($l in $b.explicit_links) { if (Link-Matches $l $a $ka) { $explicit = $true; break } } }
        if ($explicit) { $w = 3; $type = 'explicit'; $conf = 'HIGH' }

        # business-key
        if ($w -lt 3) {
            $shared = $false
            foreach ($kv in $ka.GetEnumerator()) { if ($kb.ContainsKey($kv.Key) -and ($kb[$kv.Key] -ieq $kv.Value)) { $shared = $true; break } }
            if ($shared) { $w = 3; $type = 'business-key'; $conf = 'HIGH' }
        }

        # identity signals (shared by the temporal and context edges)
        $sameUser   = [bool]$a.user -and ($a.user -ieq $b.user)
        $sameClient = (-not [bool]$a.client) -or (-not [bool]$b.client) -or ($a.client -ieq $b.client)
        $sameProg   = [bool]$a.program -and ($a.program -ieq $b.program)
        $sameTcode  = [bool]$a.tcode -and ($a.tcode -ieq $b.tcode)

        # temporal (tight window)
        $dt = $null
        if ($a.tsDate -and $b.tsDate) { $dt = [math]::Abs(($a.tsDate - $b.tsDate).TotalSeconds) }
        if (($null -ne $dt) -and ($dt -le $TightSeconds)) {
            if (($w -lt 2) -and ((($sameUser) -and ($sameClient)) -or $sameProg -or $sameTcode)) {
                $w = 2; $type = 'identity+temporal'; $conf = 'MED'
            } elseif ($w -lt 1) {
                $w = 1; $type = 'temporal'; $conf = 'LOW'
            }
        }

        # context: same day + same actor + same program/tcode. Links coarse-time
        # sources (SM13 VBHDR is date-only) to precise-time sources (ST22) that
        # belong to the same incident but fall outside the tight temporal window.
        if (($w -lt 2) -and $a.tsDate -and $b.tsDate -and ($a.tsDate.Date -eq $b.tsDate.Date) `
                -and $sameUser -and $sameClient -and ($sameProg -or $sameTcode)) {
            $w = 2; $type = 'context'; $conf = 'MED'
        }

        if ($w -ge 1) {
            [void]$edges.Add([pscustomobject]@{ from = $a.id; to = $b.id; type = $type; confidence = $conf; weight = $w })
            if ($w -ge 2) { Union $i $j }
        }
    }
}

# ---- anchor (optional) ---------------------------------------------------
$anchorTs = $null
$anchorFile = Join-Path $RunDir 'anchor.json'
if (Test-Path $anchorFile) {
    try {
        $a = Get-Content $anchorFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $fts = Parse-Ts "$($a.window.from_ts)"; $tts = Parse-Ts "$($a.window.to_ts)"
        if ($fts -and $tts) { $anchorTs = $fts.AddSeconds((($tts - $fts).TotalSeconds) / 2) }
    } catch { }
}

# ---- assemble clusters ---------------------------------------------------
$groups = @{}
for ($i = 0; $i -lt $n; $i++) {
    $r = Find $i
    if (-not $groups.ContainsKey($r)) { $groups[$r] = New-Object System.Collections.ArrayList }
    [void]$groups[$r].Add($i)
}

$clusters = New-Object System.Collections.ArrayList
$cid = 0
foreach ($g in ($groups.Values | Sort-Object { - $_.Count })) {
    $cid++
    $idxs = @($g)
    $evs  = @($idxs | ForEach-Object { $events[$_] })
    $ordered = @($evs | Sort-Object { if ($_.tsDate) { $_.tsDate } else { [datetime]::MaxValue } })
    $earliest = $ordered[0].id
    $anchorEv = $null
    if ($anchorTs) {
        $withTs = @($evs | Where-Object { $_.tsDate })
        if ($withTs.Count -gt 0) {
            $anchorEv = ($withTs | Sort-Object { [math]::Abs(($_.tsDate - $anchorTs).TotalSeconds) } | Select-Object -First 1)
        }
    }
    if (-not $anchorEv) { $anchorEv = $ordered[$ordered.Count - 1] }   # latest
    $idset = @{}; foreach ($x in $idxs) { $idset[$events[$x].id] = $true }
    $cl = @($edges | Where-Object { $idset.ContainsKey($_.from) -and $idset.ContainsKey($_.to) })
    [void]$clusters.Add([pscustomobject]@{
        cluster_id        = "C$cid"
        size              = $idxs.Count
        sources           = @($evs | ForEach-Object { $_.source } | Select-Object -Unique)
        event_ids         = @($evs | ForEach-Object { $_.id })
        timeline          = @($ordered | ForEach-Object { $_.id })
        anchor_event_id   = $anchorEv.id
        earliest_event_id = $earliest
        links             = $cl
    })
}

$out = [pscustomobject]@{
    generated_from  = $RunDir
    tight_seconds   = $TightSeconds
    event_count     = $n
    edge_count      = $edges.Count
    cluster_count   = $clusters.Count
    clusters        = $clusters
    skipped_sources = @($skipped)
}
$json = $out | ConvertTo-Json -Depth 12
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $RunDir 'correlation.json'), $json, $enc)

Write-Host ("CORRELATION: clusters={0} events={1} edges={2} file={3}" -f $clusters.Count, $n, $edges.Count, (Join-Path $RunDir 'correlation.json'))
