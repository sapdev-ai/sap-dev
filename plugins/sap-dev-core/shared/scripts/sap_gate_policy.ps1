# =============================================================================
# sap_gate_policy.ps1  -  Gate computation for the reconciled finding model
#
# Phase-0 foundation primitive #3 (policy half; the model is in
# sap_finding_lib.ps1).
#
# Turns a finding's INTRINSIC severity into a GATE decision (BLOCK | WARN | INFO)
# using the customer brief's Quality bar (Sec6) - NOT a second policy store - plus
# the --strict flag. Keeping severity and gate separate is deliberate: the same
# MEDIUM finding BLOCKs under --strict and WARNs otherwise without its severity
# changing.
#
# Dot-source it (auto-loads sap_finding_lib.ps1 for the severity ranks):
#   . "<...>\sap_gate_policy.ps1"
#   $policy = Get-SapGatePolicy -BriefPath $brief -Strict:$false
#   Set-SapFindingGates -Findings $findings -Policy $policy   # sets $f.gate in place
#   $verdict = Get-SapVerdict -Findings $findings
#
# Pure-local: reads one markdown file (the brief). No SAP, no RFC.
# =============================================================================

if (-not (Get-Command Get-SapSeverityRank -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'sap_finding_lib.ps1')
}

# Default category -> gate map (applies when the brief is silent). Mirrors the
# table in the spec SecC.
function _New-SapDefaultCategoryGate {
    return @{
        INACTIVE_OBJECT          = 'BLOCK'
        SYNTAX_ERROR             = 'BLOCK'
        TMP_OBJECT               = 'BLOCK'
        UNRELEASED_TASK          = 'BLOCK'
        CUSTOMIZING_WRONG_CLIENT = 'BLOCK'
        LOCK_OTHER_USER          = 'WARN'
        MISSING_DEPENDENCY       = 'WARN'
        NO_EVIDENCE_PACK         = 'WARN'
    }
}

# Categories that --strict promotes from WARN to BLOCK.
$script:SapStrictPromote = @('LOCK_OTHER_USER', 'MISSING_DEPENDENCY')

# ---------------------------------------------------------------------------
# Parse the brief's Quality bar (Sec6). Heuristic + fail-safe:
#   * A line that still carries the template's option list (`a` / `b` / `c`) is
#     treated as UNFILLED -> defaults apply (ATC gates P1+P2, unit warns).
#   * A filled line (customer narrowed to one answer) is matched by keyword.
# Defaults: atc_gate_severity = HIGH (P1+P2 gating), unit_gate = WARN,
#           unit_gate_when_no_tests = WARN (an object with no test class is
#           COULD_NOT_CHECK, not a failure -> warn by default).
# ---------------------------------------------------------------------------
function _Read-SapBriefQualityBar {
    param([string] $Text)
    $atc         = 'HIGH'
    $unit        = 'WARN'
    $unitNoTests = 'WARN'
    foreach ($line in ($Text -split "`n")) {
        $l = $line.ToLower()
        # Gate directives live ONLY in the brief's Pick tables (`| Field | Pick |`).
        # Skip every non-table line so explanatory prose ("when no test class ->
        # block", "mandatory ...") can never be misread as a filled directive.
        if ($l -notmatch '^\s*\|') { continue }
        $isOptionsList = ($l -match '`\s*/\s*`')   # template option list -> skip

        if ($l -match 'atc' -and $l -match 'pass' -and -not $isOptionsList) {
            if     ($l -match '1\s*\+\s*2' -or $l -match '1\s*and\s*2')      { $atc = 'HIGH' }
            elseif ($l -match 'priority\s*1')                               { $atc = 'BLOCKER' }
            elseif ($l -match '\bno\b')                                     { $atc = '' }
        }
        # The "no test class" policy line is checked (and consumed) BEFORE the
        # main unit-bar parse: it also contains "abap unit", and its "no" in
        # "no test class" would otherwise trip the '\bno\b' -> INFO branch below.
        if (($l -match 'no test class' -or $l -match 'when no test') -and -not $isOptionsList) {
            if     ($l -match '\bblock\b') { $unitNoTests = 'BLOCK' }
            elseif ($l -match '\bwarn\b')  { $unitNoTests = 'WARN' }
            continue
        }
        if (($l -match 'abap unit' -or $l -match 'unit test') -and -not $isOptionsList) {
            if     ($l -match 'mandatory')      { $unit = 'BLOCK' }
            elseif ($l -match 'nice to have')   { $unit = 'WARN' }
            elseif ($l -match '\bno\b')         { $unit = 'INFO' }
        }
    }
    return @{ atc = $atc; unit = $unit; unit_no_tests = $unitNoTests }
}

# ---------------------------------------------------------------------------
# Get-SapGatePolicy - resolve the brief and build the policy object.
# Brief resolution (when -BriefPath omitted): {custom_url}\customer_brief.md ->
# <shared>\templates\customer_brief.md. Falls back to pure defaults if none.
# ---------------------------------------------------------------------------
function Get-SapGatePolicy {
    param(
        [string] $BriefPath = '',
        [switch] $Strict
    )
    $resolved = ''
    $source   = 'default'

    if ($BriefPath -and (Test-Path -LiteralPath $BriefPath)) {
        $resolved = $BriefPath
    } else {
        $customUrl = ''
        try {
            $settingsLib = Join-Path $PSScriptRoot 'sap_settings_lib.ps1'
            $connLib     = Join-Path $PSScriptRoot 'sap_connection_lib.ps1'
            if (Test-Path $settingsLib) { . $settingsLib }
            if (Test-Path $connLib)     { . $connLib }
            if (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue) {
                $customUrl = Get-SapSettingValue 'custom_url' ''
            }
            if ([string]::IsNullOrWhiteSpace($customUrl) -and (Get-Command Get-SapWorkDir -ErrorAction SilentlyContinue)) {
                $customUrl = Join-Path (Get-SapWorkDir) 'custom'
            }
        } catch { }
        $cand = @()
        if ($customUrl) { $cand += (Join-Path $customUrl 'customer_brief.md') }
        $cand += (Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\customer_brief.md')
        foreach ($c in $cand) { if ($c -and (Test-Path -LiteralPath $c)) { $resolved = $c; break } }
    }

    $atc         = 'HIGH'
    $unit        = 'WARN'
    $unitNoTests = 'WARN'
    if ($resolved) {
        try {
            $qb = _Read-SapBriefQualityBar -Text ([System.IO.File]::ReadAllText($resolved))
            $atc         = $qb.atc
            $unit        = $qb.unit
            $unitNoTests = $qb.unit_no_tests
            $source = 'brief'
        } catch { $source = 'default' }
    }

    return [pscustomobject][ordered]@{
        schema                  = 'sapdev.gate-policy/1'
        strict                  = [bool]$Strict
        atc_gate_severity       = $atc          # '' = ATC not gating
        unit_gate               = $unit         # BLOCK | WARN | INFO
        unit_gate_when_no_tests = $unitNoTests  # BLOCK | WARN (object with no test class)
        category_gate           = (_New-SapDefaultCategoryGate)
        strict_promote          = $script:SapStrictPromote
        brief_path              = $resolved
        source                  = $source
    }
}

# ---------------------------------------------------------------------------
# Resolve-SapGate - one finding + policy -> BLOCK | WARN | INFO.
# Order: couldn't-check cap -> ATC -> unit -> category map -> severity fallback
#        -> strict promotion.
# ---------------------------------------------------------------------------
function Resolve-SapGate {
    param(
        [Parameter(Mandatory)] $Finding,
        [Parameter(Mandatory)] $Policy
    )
    $cat = "$($Finding.category)".ToUpper()
    $src = "$($Finding.source)".ToUpper()
    $sev = "$($Finding.severity)".ToUpper()

    # 1. Couldn't actually check -> WARN. Never BLOCK on something unverified,
    #    never bury it as INFO. (Applies even under --strict.)
    if ("$($Finding.coverage)".ToUpper() -eq 'COULD_NOT_CHECK') { return 'WARN' }

    # 2. ATC - gated by the brief's severity threshold.
    if ($src -eq 'ATC' -or $cat -eq 'ATC') {
        if (-not $Policy.atc_gate_severity) { return 'INFO' }
        if ((Get-SapSeverityRank $sev) -ge (Get-SapSeverityRank $Policy.atc_gate_severity)) { return 'BLOCK' }
        return 'INFO'
    }

    # 3. ABAP Unit - gated by the brief.
    if ($cat -eq 'UNIT_TEST' -or $src -eq 'ABAP_UNIT') { return "$($Policy.unit_gate)" }

    # 4. Explicit category map.
    $gate = $null
    if ($Policy.category_gate -and $Policy.category_gate.ContainsKey($cat)) { $gate = $Policy.category_gate[$cat] }

    # 5. Severity fallback for unmapped categories.
    if (-not $gate) {
        $gate = switch ($sev) {
            'BLOCKER' { 'BLOCK' }
            'HIGH'    { 'BLOCK' }
            'MEDIUM'  { 'WARN' }
            default   { 'INFO' }
        }
    }

    # 6. --strict promotes the documented WARN subset to BLOCK.
    if ($Policy.strict -and $gate -eq 'WARN' -and ($Policy.strict_promote -contains $cat)) { $gate = 'BLOCK' }

    return $gate
}

# Apply gates to a collection in place; returns the same findings.
function Set-SapFindingGates {
    param(
        [object[]] $Findings = @(),
        [Parameter(Mandatory)] $Policy
    )
    foreach ($f in $Findings) {
        $f.gate = (Resolve-SapGate -Finding $f -Policy $Policy)
    }
    return ,$Findings
}
