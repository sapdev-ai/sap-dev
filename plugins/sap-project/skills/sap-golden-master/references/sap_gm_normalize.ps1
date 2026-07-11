# =============================================================================
# sap_gm_normalize.ps1  -  Volatile-token normalizer for /sap-golden-master (OFFLINE)
#
# Canonicalizes a spool or table capture so a re-run's volatile tokens (dates,
# times, timestamps, the capture user, page-break headers) do not read as diffs.
# Regex token classes come from golden_master_normalization_rules.tsv (default +
# {custom_url} override); CAPTURE_USER and PAGE_FEED are handled structurally.
#
# Idempotent: normalize(normalize(x)) == normalize(x). No SAP access.
#
# Output (stdout): NORM: lines_in=<n> lines_out=<n> rules=<n> file=<path>
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $InputFile,
    [Parameter(Mandatory)] [string] $OutputFile,
    [ValidateSet('SPOOL','TABLE')] [string] $AppliesTo = 'SPOOL',
    [string] $RulesFile = '',
    [string] $CustomUrl = '',
    [string] $CaptureUser = '',
    [string] $SortKeys = '',          # comma-separated key columns (TABLE legs)
    [ValidateSet('none','lines')] [string] $Sort = 'none',
    [switch] $HasHeader,              # TABLE dump has a header row (keep it on top)
    [string] $ExtraRuleIds = ''       # comma-separated opt-in rule_ids to force-enable
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $RulesFile) { $RulesFile = Join-Path $PSScriptRoot 'golden_master_normalization_rules.tsv' }

function Import-GmRules {
    param([string] $RulesFile, [string] $CustomUrl, [string] $AppliesTo, [string[]] $ForceOn)
    $rules = [ordered]@{}
    $files = @($RulesFile)
    if ($CustomUrl) { $ovr = Join-Path $CustomUrl 'golden_master_normalization_rules.tsv'; if (Test-Path $ovr) { $files += $ovr } }
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        foreach ($ln in [System.IO.File]::ReadAllLines($f)) {
            if ($ln -match '^\s*#' -or $ln.Trim() -eq '') { continue }
            $c = $ln -split "`t"; if ($c.Count -lt 6) { continue }
            if ($c[0].Trim() -eq 'rule_id') { continue }
            $id = $c[0].Trim(); $ap = $c[1].Trim().ToUpper(); $rx = $c[3]; $rep = $c[4]; $en = $c[5].Trim()
            if ($ap -ne 'BOTH' -and $ap -ne $AppliesTo) { continue }
            $on = ($en -eq '1') -or ($ForceOn -contains $id)
            if (-not $on) { continue }
            $rules[$id] = @{ regex = $rx; replacement = $rep }   # override wins (same id)
        }
    }
    return $rules
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-Path $InputFile)) { Write-Host "ERROR: input not found: $InputFile"; exit 2 }
    $force = @($ExtraRuleIds -split '[,; ]+' | Where-Object { $_ })
    $rules = Import-GmRules -RulesFile $RulesFile -CustomUrl $CustomUrl -AppliesTo $AppliesTo -ForceOn $force

    $text = [System.IO.File]::ReadAllText($InputFile)
    # PAGE_FEED: strip form-feed page-break characters (structural, locale-independent)
    if ($AppliesTo -eq 'SPOOL') { $text = $text -replace "`f", '' }
    $lines = $text -split "`r?`n"
    $inCount = $lines.Count

    # header handling for table sort
    $header = $null
    if ($HasHeader -and $lines.Count -gt 0) { $header = $lines[0]; $lines = $lines[1..($lines.Count-1)] }

    # apply regex rules line by line (order = insertion order of the ordered map)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $l = $line
        foreach ($id in $rules.Keys) { $l = [regex]::Replace($l, $rules[$id].regex, $rules[$id].replacement) }
        if ($CaptureUser) { $l = [regex]::Replace($l, ('\b' + [regex]::Escape($CaptureUser) + '\b'), '<USER>') }
        $out.Add($l)
    }

    # sort
    $arr = @($out)
    if ($Sort -eq 'lines') {
        $arr = @($arr | Sort-Object -Culture '')
    } elseif ($SortKeys) {
        $keys = @($SortKeys -split '[,; ]+' | Where-Object { $_ })
        # table dump columns are TAB-separated; sort by the named key columns using the header
        if ($header) {
            $cols = @($header -split "`t")
            $idx = @($keys | ForEach-Object { $c = $_; [Array]::IndexOf($cols, ($cols | Where-Object { $_.Trim() -eq $c.Trim() } | Select-Object -First 1)) })
            $idx = @($idx | Where-Object { $_ -ge 0 })
            if ($idx.Count) { $arr = @($arr | Sort-Object -Property @($idx | ForEach-Object { $i = $_; @{ Expression = { ($_ -split "`t")[$i] } } })) }
        } else { $arr = @($arr | Sort-Object -Culture '') }
    }

    $final = if ($header -ne $null) { ,$header + $arr } else { $arr }
    # trim a single trailing empty line artifact
    [System.IO.File]::WriteAllText($OutputFile, (($final -join "`r`n").TrimEnd("`r","`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("NORM: lines_in={0} lines_out={1} rules={2} file={3}" -f $inCount, $final.Count, $rules.Count, $OutputFile)
    exit 0
}
