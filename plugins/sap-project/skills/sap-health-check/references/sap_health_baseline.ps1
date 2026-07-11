# =============================================================================
# sap_health_baseline.ps1  -  per-system baseline delta for /sap-health-check (offline)
#
# Pure-local (no SAP). The genuinely-new core of the skill: classify each current
# finding NEW vs RECURRING against a persisted per-system baseline, and surface
# RESOLVED (in the baseline, gone now). This is what a manual ST22/SM13/SMQ walk can
# never give -- every signal judged against a known-good baseline instead of memory.
#
# Baseline file (Bucket A, durable): {work_dir}\runtime\health\<SID>_<CLIENT>_baseline.json
#   { schema, sid, client, fingerprints: { "<fp>": {first_seen, last_seen, accepted} } }
#
#   -Action classify|accept|show|reset -BaselineFile <path> [-FindingsTsv <path>]
#           [-Stamp YYYYMMDDHHMMSS] [-OutDir <dir>]
#
# stdout:
#   DELTA: class=<NEW|RECURRING|RESOLVED> area=<a> fingerprint=<fp> count=<n> [accepted=Y]
#   STATUS: OK new=<n> recurring=<n> resolved=<n> [accepted=<n>] | HC_BASELINE_CORRUPT | HC_NO_HISTORY
# Exit: 0 OK | 1 corrupt baseline / bad input.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('classify','accept','show','reset')][string] $Action,
    [Parameter(Mandatory)][string] $BaselineFile,
    [string] $FindingsTsv = '',
    [string] $Stamp       = '',
    [string] $OutDir      = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function JEsc { param([string]$s) return (("$s") -replace '\\','\\' -replace '"','\"' -replace "`t",' ' -replace "`r",' ' -replace "`n",' ') }

function Read-Findings { param([string]$p)
    $rows = @()
    if (-not (Test-Path $p)) { return $rows }
    $txt = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    $lines = $txt -split "`r`n|`n|`r" | Where-Object { $_ -ne '' }
    for ($i=1; $i -lt $lines.Count; $i++) { $c = $lines[$i] -split "`t"; if ($c.Count -lt 5) { continue }
        $rows += ,([pscustomobject]@{ area=$c[0]; fp=$c[1]; count=[int]("0"+$c[2]); sev=$c[3]; cov=$c[4]; sample=$(if($c.Count -gt 5){$c[5]}else{''}) }) }
    return $rows
}
function Load-Baseline { param([string]$p)
    if (-not (Test-Path $p)) { return @{ fingerprints = @{}; new = $true } }
    try { $j = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json } catch { return $null }   # null => corrupt
    $fps = @{}
    if ($j.fingerprints) { foreach ($prop in $j.fingerprints.PSObject.Properties) { $fps[$prop.Name] = @{ first_seen=$prop.Value.first_seen; last_seen=$prop.Value.last_seen; accepted=[bool]$prop.Value.accepted } } }
    return @{ fingerprints = $fps; new = $false }
}
function Save-Baseline { param([string]$p,$fps,[string]$stamp)
    $dir = Split-Path -Parent $p; if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $items = @()
    foreach ($k in $fps.Keys) { $v=$fps[$k]; $items += ("  ""$(JEsc $k)"": {""first_seen"":""$($v.first_seen)"",""last_seen"":""$($v.last_seen)"",""accepted"":$(if($v.accepted){'true'}else{'false'})}") }
    $json = "{`n  ""schema"": ""sapdev.healthbaseline/1"",`n  ""updated"": ""$stamp"",`n  ""fingerprints"": {`n" + ($items -join ",`n") + "`n  }`n}`n"
    [IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding($false)))
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Stamp) { $Stamp = '00000000000000' }   # caller passes the server/run stamp (Date.now is unavailable in some contexts)

$bl = Load-Baseline $BaselineFile
if ($null -eq $bl) { Write-Host 'STATUS: HC_BASELINE_CORRUPT'; exit 1 }
$fps = $bl.fingerprints

switch ($Action) {
    'show' {
        foreach ($k in ($fps.Keys | Sort-Object)) { $v=$fps[$k]; Write-Host ("BASELINE: fingerprint=$k first=$($v.first_seen) last=$($v.last_seen) accepted=$(if($v.accepted){'Y'}else{'N'})") }
        Write-Host ("STATUS: OK baseline=$($fps.Count)"); exit 0
    }
    'reset' {
        Save-Baseline $BaselineFile @{} $Stamp
        Write-Host 'STATUS: OK reset=1'; exit 0
    }
    'accept' {
        $cur = Read-Findings $FindingsTsv; $n=0
        foreach ($f in $cur) { if ($f.cov -ne 'CHECKED') { continue }; if ($fps.ContainsKey($f.fp)) { if (-not $fps[$f.fp].accepted) { $fps[$f.fp].accepted=$true; $n++ } } else { $fps[$f.fp]=@{ first_seen=$Stamp; last_seen=$Stamp; accepted=$true }; $n++ } }
        Save-Baseline $BaselineFile $fps $Stamp
        Write-Host ("STATUS: OK accepted=$n"); exit 0
    }
    'classify' {
        $cur = @(Read-Findings $FindingsTsv | Where-Object { $_.cov -eq 'CHECKED' })
        $curFp = @{}; foreach ($f in $cur) { $curFp[$f.fp] = $f }
        $new=0; $rec=0; $res=0
        foreach ($f in $cur) {
            if ($fps.ContainsKey($f.fp)) {
                $rec++; $acc = $fps[$f.fp].accepted; $fps[$f.fp].last_seen=$Stamp
                Write-Host ("DELTA: class=RECURRING area=$($f.area) fingerprint=$($f.fp) count=$($f.count)$(if($acc){' accepted=Y'}else{''})")
            } else {
                $new++; $fps[$f.fp]=@{ first_seen=$Stamp; last_seen=$Stamp; accepted=$false }
                Write-Host ("DELTA: class=NEW area=$($f.area) fingerprint=$($f.fp) count=$($f.count)")
            }
        }
        foreach ($k in @($fps.Keys)) { if (-not $curFp.ContainsKey($k)) { $res++; Write-Host ("DELTA: class=RESOLVED fingerprint=$k count=0") } }
        Save-Baseline $BaselineFile $fps $Stamp
        # snapshot
        if ($OutDir) {
            if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
            $snap = "{`n  ""schema"": ""sapdev.healthsnapshot/1"",`n  ""stamp"": ""$Stamp"",`n  ""new"": $new, ""recurring"": $rec, ""resolved"": $res, ""findings"": $($cur.Count)`n}`n"
            [IO.File]::WriteAllText((Join-Path $OutDir 'health_snapshot.json'), $snap, (New-Object Text.UTF8Encoding($false)))
        }
        Write-Host ("STATUS: OK new=$new recurring=$rec resolved=$res")
        exit 0
    }
}
