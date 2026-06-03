# =============================================================================
# sap_evidence_pack.ps1  -  Delivery evidence assembler for /sap-evidence-pack
#
# "What did we change, how was it checked, and why is it safe?" - collects every
# artifact the other delivery-assurance skills registered (transport-readiness,
# impact-analysis, ATC, check-abap, ...) for a scope / ticket / date range from
# the artifact index, assembles them into one coherent pack, and writes a
# human-readable index.md - including a **Missing evidence** section that states
# honestly what was NOT produced (rather than pretending everything was checked).
#
# Pure-local: reads the artifact manifest (index.jsonl) + copies the referenced
# files. No SAP, no RFC. Dot-source the artifact lib for Find-SapArtifacts.
#
# Inputs (one of):
#   -ScopeKey TR_DEVK900123          a scope slug (preferred)
#   -Token    "TR DEVK900123"        TR/PACKAGE token -> scope slug derived locally
#                                    (object tokens: pass -ScopeKey from the resolver)
#   -Ticket   SAP-4821               collect everything tagged with a ticket
#   -Since    2026-06-01             collect everything registered since a date
#
# Output (stdout):
#   EVIDENCE: scope=<key> artifacts=<n> missing=<m> missing_files=<k> pack=<dir>
#   INDEX_MD: <path>
# Exit: 0 ok (even with 0 artifacts - emits an honest "no evidence" pack) |
#       2 on error.
# =============================================================================

[CmdletBinding()]
param(
    [string] $ScopeKey = '',
    [string] $Token = '',
    [string] $Ticket = '',
    [string] $Since = '',
    [string] $OutputDir = '',
    [string] $ArtifactDir = '',
    [string] $RunId = '',
    [switch] $IncludeLogs,
    [switch] $ReferenceOnly,   # list paths instead of copying files into the pack
    # Expected artifact kinds for the "complete delivery" checklist (override to taste).
    [string[]] $Expected = @('readiness_report','object_inventory','risk_findings','impact_report','atc_findings','unit_results')
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if ($ArtifactDir) { $env:SAPDEV_ARTIFACT_DIR = $ArtifactDir }

$here = Split-Path -Parent $PSCommandPath
$SharedScripts = Join-Path $here '..\..\..\shared\scripts'
try { $SharedScripts = (Resolve-Path -LiteralPath $SharedScripts -ErrorAction Stop).Path } catch { }
foreach ($lib in 'sap_artifact_lib.ps1','sap_finding_lib.ps1') {
    $p = Join-Path $SharedScripts $lib
    if (Test-Path $p) { . $p }
}
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

# =============================================================================
# PURE functions - offline-testable.
# =============================================================================

# Map an artifact kind to a pack subfolder.
function Get-SapEvidenceSubfolder {
    param([string] $Kind)
    switch ("$Kind".ToLower()) {
        { $_ -in 'readiness_report','impact_report','enhancement_advice','recommended_plan','release_notes','rollback_notes' } { 'reports' ; break }
        { $_ -in 'risk_findings','atc_findings','abap_check','fm_check','unit_results','dependency_findings','candidates','existing_implementations' } { 'validations' ; break }
        { $_ -in 'dependencies','reverse_dependencies','runtime_entrypoints','transport_history','graph' } { 'impact' ; break }
        { $_ -in 'object_inventory','changed_objects' } { 'inventory' ; break }
        'raw_log'    { 'logs' ; break }
        'screenshot' { 'screenshots' ; break }
        default      { 'attachments' }
    }
}

# Which expected kinds are absent from the present set.
function Get-SapEvidenceMissing {
    param([string[]] $PresentKinds = @(), [string[]] $Expected = @())
    $present = @{}
    foreach ($k in $PresentKinds) { $present["$k".ToLower()] = $true }
    $missing = @()
    foreach ($e in $Expected) { if (-not $present.ContainsKey("$e".ToLower())) { $missing += $e } }
    return $missing
}

# Roll up artifact verdicts (most severe wins) for the executive summary.
function Get-SapEvidenceVerdict {
    param([object[]] $Records = @())
    $v = ''
    foreach ($r in $Records) {
        $rv = "$($r.verdict)".ToUpper()
        if ($rv -eq 'NO_GO') { return 'NO_GO' }
        if ($rv -eq 'GO_WITH_WARNINGS') { $v = 'GO_WITH_WARNINGS' }
        elseif ($rv -eq 'GO' -and $v -eq '') { $v = 'GO' }
    }
    return $v
}

function Build-SapEvidenceIndexMarkdown {
    param(
        [string] $ScopeKey, [string] $Ticket, [object[]] $Records = @(),
        [string[]] $Missing = @(), [object[]] $MissingFiles = @(), [string] $Verdict = ''
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Delivery evidence pack - $ScopeKey")
    [void]$sb.AppendLine("")
    $head = "**$($Records.Count) artifact(s)**"
    if ($Verdict) { $head += "  |  overall verdict: **$Verdict**" }
    if ($Ticket)  { $head += "  |  ticket: $Ticket" }
    [void]$sb.AppendLine($head)
    [void]$sb.AppendLine("")

    # Executive summary
    [void]$sb.AppendLine("## Executive summary")
    if ($Records.Count -eq 0) {
        [void]$sb.AppendLine("No evidence was found for this scope. Nothing has been checked or recorded yet - run the delivery-assurance skills (e.g. /sap-transport-readiness, /sap-impact-analysis) first.")
    } else {
        $skills = @($Records | ForEach-Object { "$($_.skill)" } | Where-Object { $_ } | Select-Object -Unique)
        [void]$sb.AppendLine("Assembled from $($skills.Count) skill(s): $($skills -join ', ').")
        $couldNot = @($Records | Where-Object { "$($_.coverage)".ToUpper() -eq 'COULD_NOT_CHECK' })
        if ($couldNot.Count) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("> Note: $($couldNot.Count) artifact(s) are marked **COULD_NOT_CHECK** - this pack does NOT certify those areas clean.")
        }
    }
    [void]$sb.AppendLine("")

    # Contents table
    [void]$sb.AppendLine("## Contents")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| artifact | skill | format | verdict | coverage | file | when |")
    [void]$sb.AppendLine("|---|---|---|---|---|---|---|")
    foreach ($r in $Records) {
        $sub = Get-SapEvidenceSubfolder $r.artifact.kind
        $fname = Split-Path -Leaf "$($r.artifact.path)"
        [void]$sb.AppendLine("| $($r.artifact.kind) | $($r.skill) | $($r.artifact.format) | $($r.verdict) | $($r.coverage) | $sub/$fname | $($r.ts) |")
    }
    [void]$sb.AppendLine("")

    # Missing evidence - the honesty section.
    [void]$sb.AppendLine("## Missing evidence")
    if ($Missing.Count -eq 0 -and $MissingFiles.Count -eq 0) {
        [void]$sb.AppendLine("All expected evidence kinds are present.")
    } else {
        if ($Missing.Count) {
            [void]$sb.AppendLine("The following expected evidence was **not produced** (the corresponding check was not run, or registered no artifact):")
            [void]$sb.AppendLine("")
            foreach ($m in $Missing) { [void]$sb.AppendLine("- **$m** - not present. Run the matching skill to add it.") }
            [void]$sb.AppendLine("")
        }
        if ($MissingFiles.Count) {
            [void]$sb.AppendLine("The following artifacts are recorded in the index but their files are **missing on disk** (moved or deleted):")
            [void]$sb.AppendLine("")
            foreach ($mf in $MissingFiles) { [void]$sb.AppendLine("- $($mf.artifact.kind) -> $($mf.artifact.path)") }
            [void]$sb.AppendLine("")
        }
    }
    return $sb.ToString()
}

# =============================================================================
# Main - guarded so the pure functions are dot-source testable.
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    try {
        # --- resolve the scope key -------------------------------------------
        if (-not $ScopeKey -and $Token) {
            $t = $Token.Trim() -replace '\s+', ' '
            if ($t -match '^(?i:TR|TRANSPORT|REQUEST)\s+(\S+)$')        { $ScopeKey = 'TR_'  + ($matches[1].ToUpper() -replace '[^A-Za-z0-9_]', '_') }
            elseif ($t -match '^(?i:PACKAGE|DEVC|DEVCLASS)\s+(\S+)$')   { $ScopeKey = 'PKG_' + ($matches[1].ToUpper() -replace '[^A-Za-z0-9_]', '_') }
            else {
                Write-Host "ERROR: object tokens need a resolver-derived -ScopeKey (e.g. PROG_ZMMR001). Only 'TR <x>' / 'PACKAGE <x>' can be derived from -Token."
                exit 2
            }
        }
        if (-not $ScopeKey -and -not $Ticket -and -not $Since) {
            Write-Host "ERROR: provide one of -ScopeKey, -Token 'TR <x>'/'PACKAGE <x>', -Ticket, or -Since."
            exit 2
        }

        # --- query the index --------------------------------------------------
        $records = @(Find-SapArtifacts -ScopeKey $ScopeKey -Ticket $Ticket -Since $Since |
                     Where-Object { "$($_.artifact.kind)" -ne 'evidence_index' })   # don't recurse our own packs
        if (-not $IncludeLogs) {
            $records = @($records | Where-Object { "$($_.artifact.kind)" -ne 'raw_log' })
        }

        $label = if ($ScopeKey) { $ScopeKey } elseif ($Ticket) { "ticket_$Ticket" } else { "since_$Since" }
        $label = $label -replace '[^A-Za-z0-9_]', '_'

        # --- pack dir ---------------------------------------------------------
        $root = Get-SapArtifactRoot
        if ($OutputDir) { $packDir = $OutputDir }
        else { $packDir = Join-Path (Join-Path (Split-Path -Parent $root) 'evidence_pack') $label }
        if (-not (Test-Path $packDir)) { New-Item -ItemType Directory -Force -Path $packDir | Out-Null }

        # --- collect files ----------------------------------------------------
        $missingFiles = @()
        foreach ($r in $records) {
            $rel = "$($r.artifact.path)" -replace '/', '\'
            $src = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $root $rel }
            if (-not (Test-Path -LiteralPath $src)) { $missingFiles += $r; continue }
            if ($ReferenceOnly) { continue }
            $sub = Get-SapEvidenceSubfolder $r.artifact.kind
            $subDir = Join-Path $packDir $sub
            if (-not (Test-Path $subDir)) { New-Item -ItemType Directory -Force -Path $subDir | Out-Null }
            Copy-Item -LiteralPath $src -Destination (Join-Path $subDir (Split-Path -Leaf $src)) -Force
        }

        # --- missing-evidence checklist + verdict -----------------------------
        $presentKinds = @($records | ForEach-Object { "$($_.artifact.kind)" })
        $missing = @(Get-SapEvidenceMissing -PresentKinds $presentKinds -Expected $Expected)
        $verdict = Get-SapEvidenceVerdict -Records $records

        # --- index.md ---------------------------------------------------------
        $md = Build-SapEvidenceIndexMarkdown -ScopeKey $label -Ticket $Ticket -Records $records -Missing $missing -MissingFiles $missingFiles -Verdict $verdict
        $indexMd = Join-Path $packDir 'index.md'
        [System.IO.File]::WriteAllText($indexMd, $md, (New-Object System.Text.UTF8Encoding($false)))

        # --- register the pack itself ----------------------------------------
        if ($ScopeKey) {
            Register-SapArtifact -Skill 'sap-evidence-pack' -ScopeKey $ScopeKey -Kind 'evidence_index' -Format 'md' -Path $indexMd -Ticket $Ticket -Verdict $verdict -RunId $RunId | Out-Null
        }

        Write-Host ("EVIDENCE: scope={0} artifacts={1} missing={2} missing_files={3} pack={4}" -f $label, $records.Count, $missing.Count, $missingFiles.Count, $packDir)
        Write-Host "INDEX_MD: $indexMd"
        exit 0
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        exit 2
    }
}
