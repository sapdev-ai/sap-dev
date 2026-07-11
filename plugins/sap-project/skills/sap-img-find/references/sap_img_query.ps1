# =============================================================================
# sap_img_query.ps1  -  lexical prefilter over the harvested IMG index for /sap-img-find
#
# Pure local (no SAP). Reads {CacheDir}\img_index.tsv (from sap_img_harvest.ps1) and scores
# each row by case-insensitive keyword-token overlap against the caller's keyword list (Claude
# expands the NL question into SAP-vocabulary keywords BEFORE calling this). Emits the top
# shortlist (<=200 rows) so the full index is NEVER loaded into Claude's context -- only the
# shortlist, which Claude then semantically ranks. Always carries the full SPRO path + tcode +
# objects so a wrong hit costs one glance.
#
#   -CacheDir <dir> -Keywords "plant,werks,site,factory" [-Top 200] -OutFile <tsv>
# stdout: IMGQ: score=<s> tcode=<t> text=<..> path=<..> + STATUS: OK matches=<n>. Exit 0/1.
# =============================================================================

[CmdletBinding()]
param(
    [string] $CacheDir = '',
    [string] $Keywords = '',
    [int]    $Top      = 200,
    [string] $OutFile  = '',
    [string] $RunId    = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }

if ($MyInvocation.InvocationName -eq '.') { return }
$idx = Join-Path $CacheDir 'img_index.tsv'
if (-not (Test-Path $idx)) { Write-Host 'STATUS: IMG_CACHE_MISSING (run harvest first)'; exit 1 }
$kws = @($Keywords -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_.Length -ge 2 })
if ($kws.Count -eq 0) { Write-Host 'STATUS: IMG_NO_KEYWORDS'; exit 1 }

$lines = [IO.File]::ReadAllLines($idx, [Text.Encoding]::UTF8)
$scored = @()
for ($i=1; $i -lt $lines.Count; $i++) {   # skip header
    $c = $lines[$i] -split "`t"
    if ($c.Count -lt 5) { continue }
    $activity=$c[0]; $tcode=$c[1]; $text=$c[2]; $path=$c[3]; $objs=$c[4]
    $hay = ("$text $path $objs").ToLower()
    $score = 0
    foreach ($k in $kws) {
        if ($hay.Contains($k)) {
            $score += 2
            # a hit in the leaf node_text is worth more than deep in the path
            if ($text.ToLower().Contains($k)) { $score += 3 }
        }
    }
    if ($score -gt 0) { $scored += ,([pscustomobject]@{ score=$score; activity=$activity; tcode=$tcode; text=$text; path=$path; objs=$objs }) }
}
$topRows = @($scored | Sort-Object score -Descending | Select-Object -First $Top)
$sb=New-Object System.Text.StringBuilder;[void]$sb.AppendLine("score`tactivity`ttcode`tnode_text`tspro_path`tobjects")
foreach ($r in $topRows) { [void]$sb.AppendLine((@($r.score,$r.activity,$r.tcode,$r.text,$r.path,$r.objs) -join "`t")) }
if ($OutFile) { [IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object Text.UTF8Encoding($true))) }
foreach ($r in ($topRows | Select-Object -First 15)) { Write-Host ("IMGQ: score=$($r.score) tcode=$($r.tcode) text=`"$($r.text)`" path=`"$($r.path)`"") }
Write-Host ("STATUS: OK matches=$($scored.Count) shortlisted=$($topRows.Count)")
exit 0
