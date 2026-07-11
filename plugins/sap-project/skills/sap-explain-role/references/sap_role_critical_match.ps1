# =============================================================================
# sap_role_critical_match.ps1  -  offline critical-grant matcher for /sap-explain-role
#
# Joins a role's decoded auth values (role_auths_decoded.tsv from the extractor)
# against critical_auths.tsv and writes critical_findings.tsv + findings.json.
# Pure-local, ZERO RFC - unit-testable with fixtures. The matching semantics are
# deterministic here (NOT left to the LLM), so the audit result is reproducible.
#
#   -AuthsTsv <role_auths_decoded.tsv> -CriticalTsv <critical_auths.tsv>
#   -OutDir <dir> [-Role <name>]
#
# Match rule (per critical row vs each granted OBJECT/FIELD/LOW/HIGH):
#   object must equal; then
#     rule.field blank            to object-presence hit (flags ANY grant of the object)
#     grant LOW '*'               to role grants everything for the field to hit (any rule)
#     rule.low '*'                to hit ONLY a wildcard grant (grant LOW='*')
#     rule.low trailing-'*'       to SAP prefix match against grant LOW
#     rule.low..high interval     to hit if grant range overlaps [low,high]
#     exact rule.low = V          to hit if V within grant [LOW..HIGH]
#
# Output: CRIT: check=<id> object=<o> field=<f> granted=<low..high> severity=<s>
#         STATUS: OK found=<n> critical=<n> high=<n> medium=<n> | NO_MATRIX | INPUT_ERROR
# Exit: 0 OK (incl. 0 findings) | 2 input/matrix error.
# =============================================================================

[CmdletBinding()]
param(
    [string] $AuthsTsv = '',
    [string] $CriticalTsv = '',
    [string] $OutDir = '',
    [string] $Role = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Read-TsvRows { param([string] $Path)
    $rows = @(); if (-not (Test-Path $Path)) { return ,$rows }
    $bom = [char]0xFEFF
    $txt = ([System.IO.File]::ReadAllText($Path)).TrimStart($bom) -replace "`r", ""
    $hdr = $null
    foreach ($ln0 in ($txt -split "`n")) {
        $ln = $ln0.TrimStart($bom)
        if ($ln -match '^\s*#' -or -not $ln.Trim()) { continue }
        $c = $ln -split "`t"
        if (-not $hdr) { $hdr = @($c | ForEach-Object { $_.TrimStart($bom).Trim() }); continue }
        $o = [ordered]@{}; for ($i = 0; $i -lt $hdr.Count; $i++) { $o[$hdr[$i]] = if ($i -lt $c.Count) { $c[$i].Trim() } else { '' } }
        $rows += ,([pscustomobject]$o)
    }
    return ,$rows
}

# lexical range helpers (SAP fixed-width codes compare correctly lexically)
function Rule-Hits {
    param([string] $rLow, [string] $rHigh, [string] $gLow, [string] $gHigh)
    if ($gLow -eq '*') { return $true }     # over-broad wildcard GRANT: covers any critical value
    if ($rLow -eq '*') { return $false }    # rule targets the wildcard grant; this grant is specific to no hit
    if ($rLow.EndsWith('*')) { $p = $rLow.TrimEnd('*'); return ($gLow.StartsWith($p)) }
    $gHi = if ($gHigh) { $gHigh } else { $gLow }
    if ($rHigh) { return -not (($gHi -lt $rLow) -or ($gLow -gt $rHigh)) }
    return (($rLow -ge $gLow) -and ($rLow -le $gHi))
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $AuthsTsv -or -not (Test-Path $AuthsTsv)) { Write-Host "STATUS: INPUT_ERROR reason=no_auths_tsv"; exit 2 }
    if (-not $CriticalTsv -or -not (Test-Path $CriticalTsv)) { Write-Host "STATUS: NO_MATRIX reason=critical_auths_tsv_missing"; exit 2 }
    if (-not $OutDir) { $OutDir = Split-Path $AuthsTsv }

    $rules = Read-TsvRows $CriticalTsv
    if (-not @($rules).Count) { Write-Host "STATUS: NO_MATRIX reason=empty_matrix"; exit 2 }
    # validate header
    foreach ($need in 'check_id','auth_object','field','low','high','severity') { if (-not ($rules[0].PSObject.Properties.Name -contains $need)) { Write-Host "STATUS: NO_MATRIX reason=bad_header_missing_$need"; exit 2 } }

    $auths = Read-TsvRows $AuthsTsv
    # index granted rows by object
    $byObj = @{}
    foreach ($a in @($auths)) { $ob = San $a.object; if (-not $ob) { continue }; if (-not $byObj.ContainsKey($ob)) { $byObj[$ob] = @() }; $byObj[$ob] += $a }

    $findings = @(); $seen = @{}
    foreach ($r in @($rules)) {
        $co = San $r.auth_object; $cf = San $r.field; $cl = San $r.low; $chh = San $r.high; $sev = (San $r.severity).ToUpper()
        if (-not $byObj.ContainsKey($co)) { continue }
        foreach ($a in $byObj[$co]) {
            $af = San $a.field; $al = San $a.low; $ah = San $a.high
            $hit = $false
            if (-not $cf) { $hit = $true }                                  # object-presence rule
            elseif ($af -eq $cf) { $hit = (Rule-Hits $cl $chh $al $ah) }
            if ($hit) {
                $key = "$($r.check_id)|$co|$af|$al"
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    $findings += [pscustomobject]@{ check_id=(San $r.check_id); object=$co; object_text=(San $a.object_text); field=$af; granted_low=$al; granted_high=$ah; severity=$sev; rationale=(San $r.rationale) }
                }
            }
        }
    }

    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("check_id`tobject`tobject_text`tfield`tgranted_low`tgranted_high`tseverity`trationale")
    foreach ($f in $findings) {
        [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f $f.check_id,$f.object,$f.object_text,$f.field,$f.granted_low,$f.granted_high,$f.severity,$f.rationale))
        Write-Host ("CRIT: check={0} object={1} field={2} granted={3}..{4} severity={5}" -f $f.check_id,$f.object,$f.field,$f.granted_low,$f.granted_high,$f.severity)
    }
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'critical_findings.tsv'), $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    @{ role=$Role; findings=$findings; generated=$true } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'findings.json') -Encoding UTF8

    $nc = @($findings | Where-Object { $_.severity -eq 'CRITICAL' }).Count
    $nh = @($findings | Where-Object { $_.severity -eq 'HIGH' }).Count
    $nm = @($findings | Where-Object { $_.severity -eq 'MEDIUM' }).Count
    Write-Host ("STATUS: OK found=$($findings.Count) critical=$nc high=$nh medium=$nm")
    exit 0
}
