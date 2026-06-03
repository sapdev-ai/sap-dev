# =============================================================================
# sap_finding_lib.ps1  -  Reconciled finding model for delivery-assurance skills
#
# Phase-0 foundation primitive #3 (model half; gate computation lives in
# sap_gate_policy.ps1). See contributing/phase0_delivery_assurance_spec.md SecC.
#
# ONE severity / category / coverage / gate vocabulary that impact-analysis,
# transport-readiness, ATC, and check-abap all map into. Two non-negotiables:
#
#   1. severity (intrinsic) is SEPARATE from gate (computed by policy). The same
#      MEDIUM finding can BLOCK under --strict and WARN otherwise without its
#      severity changing.
#   2. The honesty contract: a CHECK reports a tri-state so "couldn't run" is
#      never silently "passed":
#         CHECKED_CLEAN | CHECKED_FINDINGS | COULD_NOT_CHECK | NOT_APPLICABLE
#
# Pure-local: in-memory records + TSV/JSON serialization. No SAP, no RFC.
# Dot-source it:
#
#   . "<...>\sap_finding_lib.ps1"
#   $f = New-SapFinding -Severity BLOCKER -Category INACTIVE_OBJECT -Object $obj `
#            -Detail 'Object is inactive in DWINACTIV' -Source DWINACTIV `
#            -Remediation 'Activate object before TR release'
#   $check = New-SapCheckResult -Check 'inactive_objects' -Findings @($f)
#   # ... apply gates via sap_gate_policy.ps1 ...
#   Export-SapFindingsTsv  -Findings @($f) -Path $tsv -Scope 'TR_DEVK900123' -Verdict 'NO_GO'
# =============================================================================

# Severity ordering. BLOCKER > HIGH > MEDIUM > LOW > INFO.
$script:SapSeverityRank = @{ BLOCKER = 5; HIGH = 4; MEDIUM = 3; LOW = 2; INFO = 1 }
$script:_FindingSeq = 0

function Reset-SapFindingSeq { $script:_FindingSeq = 0 }

function Get-SapSeverityRank {
    param([string] $Severity)
    $r = $script:SapSeverityRank["$($Severity.ToUpper())"]
    if ($r) { return $r } else { return 0 }
}

# --- Adapters: map existing producers into the unified severity --------------
function ConvertFrom-SapAtcPriority {
    param([int] $Priority)
    switch ($Priority) {
        1 { 'BLOCKER' } 2 { 'HIGH' } 3 { 'MEDIUM' } 4 { 'LOW' } default { 'INFO' }
    }
}
function ConvertFrom-SapCheckAbapSeverity {
    param([string] $Severity)
    switch ("$Severity".ToUpper()) {
        'ERROR'   { 'HIGH' }
        'WARNING' { 'MEDIUM' }
        'INFO'    { 'INFO' }
        default   { 'INFO' }
    }
}

function _Normalize-SapFindingObject {
    param($Object)
    if (-not $Object) { return [ordered]@{ pgmid = ''; object = ''; obj_name = '' } }
    return [ordered]@{
        pgmid    = "$($Object.pgmid)"
        object   = "$($Object.object)"
        obj_name = "$($Object.obj_name)"
    }
}

# ---------------------------------------------------------------------------
# New-SapFinding - build one sapdev.finding/1 record. gate is '' until a policy
# is applied (sap_gate_policy.ps1). -Object accepts a resolver record or any
# object exposing .pgmid/.object/.obj_name (or $null).
# ---------------------------------------------------------------------------
function New-SapFinding {
    param(
        [Parameter(Mandatory)] [ValidateSet('BLOCKER','HIGH','MEDIUM','LOW','INFO')] [string] $Severity,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Detail,
        $Object = $null,
        [string] $Location = '',
        [string] $Remediation = '',
        [string] $Evidence = '',
        [string] $Source = '',
        [ValidateSet('HIGH','MEDIUM','LOW')] [string] $Confidence = 'HIGH',
        [ValidateSet('CHECKED','COULD_NOT_CHECK')] [string] $Coverage = 'CHECKED',
        [string] $Id = ''
    )
    if (-not $Id) { $script:_FindingSeq++; $Id = 'F-{0:0000}' -f $script:_FindingSeq }
    return [pscustomobject][ordered]@{
        schema      = 'sapdev.finding/1'
        id          = $Id
        severity    = $Severity.ToUpper()
        category    = $Category.ToUpper()
        object      = (_Normalize-SapFindingObject $Object)
        location    = $Location
        detail      = $Detail
        remediation = $Remediation
        evidence    = $Evidence
        source      = $Source.ToUpper()
        confidence  = $Confidence.ToUpper()
        coverage    = $Coverage.ToUpper()
        gate        = ''
    }
}

# ---------------------------------------------------------------------------
# New-SapCheckResult - the honesty contract. Status is derived unless given:
#   -NotApplicable -> NOT_APPLICABLE
#   -CouldNotCheck -> COULD_NOT_CHECK   (auth denied / RFC fail / run errored)
#   findings > 0   -> CHECKED_FINDINGS
#   else           -> CHECKED_CLEAN
# ---------------------------------------------------------------------------
function New-SapCheckResult {
    param(
        [Parameter(Mandatory)] [string] $Check,
        [object[]] $Findings = @(),
        [switch] $CouldNotCheck,
        [switch] $NotApplicable,
        [string] $Detail = '',
        [ValidateSet('','CHECKED_CLEAN','CHECKED_FINDINGS','COULD_NOT_CHECK','NOT_APPLICABLE')] [string] $Status = ''
    )
    if (-not $Status) {
        if     ($NotApplicable) { $Status = 'NOT_APPLICABLE' }
        elseif ($CouldNotCheck) { $Status = 'COULD_NOT_CHECK' }
        elseif (@($Findings).Count -gt 0) { $Status = 'CHECKED_FINDINGS' }
        else   { $Status = 'CHECKED_CLEAN' }
    }
    return [pscustomobject][ordered]@{
        schema   = 'sapdev.check/1'
        check    = $Check
        status   = $Status
        detail   = $Detail
        findings = @($Findings)
    }
}

# ---------------------------------------------------------------------------
# Get-SapGateCounts / Get-SapVerdict - roll up gated findings.
#   any BLOCK            -> NO_GO
#   else any WARN        -> GO_WITH_WARNINGS
#   else                 -> GO
# A COULD_NOT_CHECK anywhere (finding coverage or a check status) downgrades a
# clean GO to GO_WITH_WARNINGS - we never claim GO on something we couldn't check.
# ---------------------------------------------------------------------------
function Get-SapGateCounts {
    param([object[]] $Findings = @())
    $c = @{ BLOCK = 0; WARN = 0; INFO = 0 }
    foreach ($f in $Findings) {
        switch ("$($f.gate)".ToUpper()) {
            'BLOCK' { $c.BLOCK++ }
            'WARN'  { $c.WARN++ }
            'INFO'  { $c.INFO++ }
        }
    }
    return $c
}

function Get-SapVerdict {
    param(
        [object[]] $Findings = @(),
        [string[]] $CheckStatuses = @()
    )
    $counts = Get-SapGateCounts -Findings $Findings
    $verdict = if ($counts.BLOCK -gt 0) { 'NO_GO' } elseif ($counts.WARN -gt 0) { 'GO_WITH_WARNINGS' } else { 'GO' }

    if ($verdict -eq 'GO') {
        $couldNot = $false
        if ($CheckStatuses -contains 'COULD_NOT_CHECK') { $couldNot = $true }
        foreach ($f in $Findings) { if ("$($f.coverage)".ToUpper() -eq 'COULD_NOT_CHECK') { $couldNot = $true; break } }
        if ($couldNot) { $verdict = 'GO_WITH_WARNINGS' }
    }
    return $verdict
}

# ---------------------------------------------------------------------------
# Serialization. TSV is the reviewer-facing file (Excel) and keeps the
# check-abap header-block + columns muscle memory. JSON is the machine sibling.
# ---------------------------------------------------------------------------
function _SapFindingObjLabel {
    param($Finding)
    $o = $Finding.object
    if ($o -and "$($o.obj_name)") {
        if ("$($o.object)") { return "$($o.object):$($o.obj_name)" }
        return "$($o.obj_name)"
    }
    return ''
}

function _SapTsvClean {
    param([string] $Text)
    return (("$Text") -replace "[`t`r`n]", ' ')
}

function Export-SapFindingsTsv {
    param(
        [object[]] $Findings = @(),
        [Parameter(Mandatory)] [string] $Path,
        [string] $Scope = '',
        [string] $Verdict = '',
        [string] $Status = ''
    )
    $counts = Get-SapGateCounts -Findings $Findings
    if (-not $Status) {
        $Status = if (@($Findings).Count -gt 0) { 'CHECKED_FINDINGS' } else { 'CHECKED_CLEAN' }
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("STATUS: $Status")
    [void]$sb.AppendLine("SCOPE: $Scope")
    [void]$sb.AppendLine("VERDICT: $Verdict")
    [void]$sb.AppendLine("TIMESTAMP: $((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))")
    [void]$sb.AppendLine("TOTAL_FINDINGS: $(@($Findings).Count)   BLOCK: $($counts.BLOCK)   WARN: $($counts.WARN)   INFO: $($counts.INFO)")
    [void]$sb.AppendLine(('-' * 60))
    $cols = 'id','severity','gate','category','object','location','detail','remediation','source','confidence','coverage'
    [void]$sb.AppendLine(($cols -join "`t"))
    foreach ($f in $Findings) {
        $row = @(
            $f.id, $f.severity, $f.gate, $f.category, (_SapFindingObjLabel $f),
            (_SapTsvClean $f.location), (_SapTsvClean $f.detail), (_SapTsvClean $f.remediation),
            $f.source, $f.confidence, $f.coverage
        )
        [void]$sb.AppendLine(($row -join "`t"))
    }
    # UTF-8 WITH BOM so Excel opens non-ASCII (JA/ZH) finding text correctly.
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $enc)
    return $Path
}

function Export-SapFindingsJson {
    param(
        [object[]] $Findings = @(),
        [Parameter(Mandatory)] [string] $Path,
        [string] $Scope = '',
        [string] $Verdict = '',
        [string] $Status = ''
    )
    if (-not $Status) {
        $Status = if (@($Findings).Count -gt 0) { 'CHECKED_FINDINGS' } else { 'CHECKED_CLEAN' }
    }
    $doc = [ordered]@{
        schema    = 'sapdev.findings-report/1'
        scope     = $Scope
        status    = $Status
        verdict   = $Verdict
        timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        counts    = (Get-SapGateCounts -Findings $Findings)
        findings  = @($Findings)
    }
    $json = $doc | ConvertTo-Json -Depth 12
    $enc = New-Object System.Text.UTF8Encoding($false)   # no BOM (machine sibling)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
    return $Path
}
