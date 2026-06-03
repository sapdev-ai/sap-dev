# =============================================================================
# sap_transport_readiness.ps1  -  Release-gate engine for /sap-transport-readiness
#
# "Is this transport safe to release?" - RFC-only structural checks over a TR,
# evaluated into the reconciled finding model, gated by the customer brief,
# rolled up to a GO / GO_WITH_WARNINGS / NO_GO verdict, and written as a
# reviewer report + TSV/JSON, with every output registered in the artifact index.
#
# Read-only. Reads E070/E071/TADIR/DWINACTIV via the shared libs; never mutates
# SAP. ATC and ABAP-Unit are NOT run here - the SKILL.md runs /sap-atc and
# /sap-run-abap-unit and passes their verdicts via -AtcVerdict / -UnitVerdict so
# the engine folds them into ONE unified verdict.
#
# Reuses the Phase-0 primitives (contributing/phase0_delivery_assurance_spec.md):
#   sap_object_resolver.ps1  (Resolve-SapObject, Read-SapTableRows, Test-SapObjectActive)
#   sap_finding_lib.ps1      (New-SapFinding, Get-SapVerdict, Export-SapFindings*)
#   sap_gate_policy.ps1      (Get-SapGatePolicy, Set-SapFindingGates)
#   sap_artifact_lib.ps1     (New-SapScopeKey, Get-SapArtifactDir, Register-SapArtifact)
#
# Run with 32-bit PowerShell (SAP NCo 3.1 is 32-bit). Creds default to the
# pinned connection profile via Connect-SapRfc (so -Tr alone works when logged in).
#
# Output (stdout, parseable by SKILL.md):
#   READINESS: tr=<TR> verdict=<GO|GO_WITH_WARNINGS|NO_GO> block=<n> warn=<n> info=<n> objects=<n>
#   REPORT_MD: <path>   FINDINGS_TSV: <path>   FINDINGS_JSON: <path>   INVENTORY_TSV: <path>
# Exit: 0 = GO / GO_WITH_WARNINGS | 1 = NO_GO | 2 = TR not found / RFC failure.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Tr = '',
    [string] $SharedDir = '',
    [string] $OutputDir = '',
    [string] $BriefPath = '',
    [switch] $Strict,
    [string] $AtcVerdict = '',     # '' (not run) | GO | NO_GO | ERROR
    [string] $UnitVerdict = '',    # '' (not run) | GO | NO_GO | ERROR
    [string] $RunId = '',
    # Endpoint / creds - empty falls back to the pinned profile (sap_rfc_lib).
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $User = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# Resolve the shared scripts dir (default: ..\..\..\shared from references\).
if (-not $SharedDir) {
    try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\shared')).Path } catch { $SharedDir = '' }
}
$scripts = Join-Path $SharedDir 'scripts'

# sap_object_resolver.ps1 has its OWN param() block (Server/Sysnr/Client/...).
# Dot-sourcing it resets our identically named cred params to defaults (the
# dot-source param-clobber gotcha). Snapshot the creds, dot-source, then restore.
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; User=$User; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1','sap_finding_lib.ps1','sap_gate_policy.ps1','sap_artifact_lib.ps1') {
    $p = Join-Path $scripts $lib
    if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

# =============================================================================
# PURE evaluation functions - take plain data, return findings. Offline-testable
# (no RFC). The RFC layer below feeds them.
# =============================================================================

# Child tasks of the request that are still modifiable (D/L) block release.
function Get-SapTrChildTaskFindings {
    param([object[]] $ChildRows = @())
    $out = @()
    foreach ($r in $ChildRows) {
        $st = "$($r.TRSTATUS)".ToUpper()
        if ($st -eq 'D' -or $st -eq 'L') {
            $out += (New-SapFinding -Severity BLOCKER -Category UNRELEASED_TASK `
                        -Detail "Child task $($r.TRKORR) is unreleased (TRSTATUS=$st, owner $($r.AS4USER))" `
                        -Remediation "Release task $($r.TRKORR) before releasing the request" `
                        -Evidence "E070 STRKORR=<tr> TRKORR=$($r.TRKORR) TRSTATUS=$st" -Source E070)
        }
    }
    return $out
}

# $TMP / local objects in a transportable request, and a multi-package note.
function Get-SapInventoryFindings {
    param([object[]] $InvRecords = @())
    $out = @()
    $packages = @{}
    foreach ($o in $InvRecords) {
        # LIMU sub-objects (TABT/TABD/REPS/FUNC/METH/...) carry no own TADIR
        # package - they inherit the master R3TR object's. Only gate masters,
        # else legitimate sub-entries look like local/$TMP objects.
        if ("$($o.pgmid)".ToUpper() -ne 'R3TR') { continue }
        $pkg = "$($o.package)"
        $label = (& { if ("$($o.object)") { "$($o.object):$($o.obj_name)" } else { "$($o.obj_name)" } })
        if ([string]::IsNullOrWhiteSpace($pkg) -or $pkg -eq '$TMP' -or $pkg.StartsWith('$')) {
            $pkgShown = if ([string]::IsNullOrWhiteSpace($pkg)) { '<none>' } else { $pkg }
            $out += (New-SapFinding -Severity BLOCKER -Category TMP_OBJECT -Object $o `
                        -Detail "$label is a local / `$TMP object ($pkgShown) inside a transportable request" `
                        -Remediation "Reassign to a transportable package via /sap-change-package before release" `
                        -Evidence "TADIR DEVCLASS=$pkg" -Source TADIR)
        } elseif ($pkg) {
            $packages[$pkg] = $true
        }
    }
    if ($packages.Count -gt 1) {
        $out += (New-SapFinding -Severity LOW -Category MULTI_PACKAGE `
                    -Detail "Request spans $($packages.Count) packages: $(( $packages.Keys | Sort-Object ) -join ', ')" `
                    -Remediation "Confirm the multi-package split is intentional" -Source TADIR)
    }
    return $out
}

# Inactive objects (names that DWINACTIV reported) -> blockers. couldNotCheck =
# names whose active state could not be read (auth/RFC) -> a COULD_NOT_CHECK finding.
function Get-SapInactiveFindings {
    param([string[]] $InactiveNames = @(), [string[]] $CouldNotCheckNames = @(), [object[]] $InvRecords = @())
    $byName = @{}
    foreach ($o in $InvRecords) { $byName["$($o.obj_name)".ToUpper()] = $o }
    $out = @()
    foreach ($n in ($InactiveNames | Select-Object -Unique)) {
        $o = $byName["$n".ToUpper()]
        $out += (New-SapFinding -Severity BLOCKER -Category INACTIVE_OBJECT -Object $o `
                    -Detail "$n has an inactive version (DWINACTIV)" `
                    -Remediation "Activate via /sap-activate-object before release" `
                    -Evidence "DWINACTIV OBJ_NAME=$n" -Source DWINACTIV)
    }
    foreach ($n in ($CouldNotCheckNames | Select-Object -Unique)) {
        $o = $byName["$n".ToUpper()]
        $out += (New-SapFinding -Severity MEDIUM -Category INACTIVE_OBJECT -Object $o -Coverage COULD_NOT_CHECK `
                    -Detail "Could not read activation state of $n (auth / RFC)" `
                    -Remediation "Re-check with table read authorization (S_TABU_DIS) for DWINACTIV" `
                    -Source DWINACTIV)
    }
    return $out
}

# Fold a sub-skill (ATC / ABAP Unit) verdict into a finding.
function Get-SapSubSkillFinding {
    param([string] $Name, [string] $Verdict, [string] $Category, [string] $Source)
    $v = "$Verdict".ToUpper()
    if ($v -eq '' -or $v -eq 'GO') { return $null }
    if ($v -eq 'NO_GO') {
        return (New-SapFinding -Severity BLOCKER -Category $Category `
                    -Detail "$Name reported NO_GO" -Remediation "Resolve $Name findings, then re-run readiness" -Source $Source)
    }
    # ERROR / unexpected -> couldn't check
    return (New-SapFinding -Severity MEDIUM -Category $Category -Coverage COULD_NOT_CHECK `
                -Detail "$Name did not complete (verdict='$Verdict')" -Remediation "Re-run $Name" -Source $Source)
}

# Markdown reviewer report.
function Build-SapReadinessMarkdown {
    param(
        [string] $Tr, [string] $Verdict, [object[]] $Findings = @(),
        [object[]] $InvRecords = @(), [string[]] $CheckStatuses = @(), [hashtable] $Meta = @{}
    )
    $counts = Get-SapGateCounts -Findings $Findings
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Transport readiness - $Tr")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Verdict: $Verdict**  |$($InvRecords.Count) objects  |BLOCK $($counts.BLOCK) / WARN $($counts.WARN) / INFO $($counts.INFO)")
    if ($Meta.tr_status) { [void]$sb.AppendLine("TR status: $($Meta.tr_status)  |owner $($Meta.owner)  |type $($Meta.trfunction)") }
    [void]$sb.AppendLine("")
    $blocks = @($Findings | Where-Object { "$($_.gate)" -eq 'BLOCK' })
    $warns  = @($Findings | Where-Object { "$($_.gate)" -eq 'WARN' })
    if ($blocks.Count) {
        [void]$sb.AppendLine("## Blocking ($($blocks.Count))")
        foreach ($f in $blocks) { [void]$sb.AppendLine("- **[$($f.severity)] $($f.category)** - $($f.detail)  _-> $($f.remediation)_") }
        [void]$sb.AppendLine("")
    }
    if ($warns.Count) {
        [void]$sb.AppendLine("## Warnings ($($warns.Count))")
        foreach ($f in $warns) { [void]$sb.AppendLine("- [$($f.severity)] $($f.category) - $($f.detail)  _-> $($f.remediation)_") }
        [void]$sb.AppendLine("")
    }
    if ($CheckStatuses -contains 'COULD_NOT_CHECK') {
        [void]$sb.AppendLine("## Could not check")
        [void]$sb.AppendLine("Some checks could not run (auth / RFC). This report does NOT certify those areas clean - see COULD_NOT_CHECK findings.")
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("## Objects ($($InvRecords.Count))")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| pgmid | object | name | package |")
    [void]$sb.AppendLine("|---|---|---|---|")
    foreach ($o in $InvRecords) { [void]$sb.AppendLine("| $($o.pgmid) | $($o.object) | $($o.obj_name) | $($o.package) |") }
    return $sb.ToString()
}

# =============================================================================
# Main - skipped when dot-sourced (so the pure functions above are testable).
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    if ([string]::IsNullOrWhiteSpace($Tr)) {
        Write-Host "ERROR: -Tr is required (a transport request number)."
        Write-Host "READINESS: tr= verdict=ERROR block=0 warn=0 info=0 objects=0"
        exit 2
    }
    $Tr = $Tr.ToUpper()

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $User -Password $Password -Language $Language `
                             -DestName "SAPDEV_READINESS"
    if (-not $g_dest) {
        Write-Host "READINESS: tr=$Tr verdict=ERROR block=0 warn=0 info=0 objects=0"
        exit 2
    }

    try {
        $effClient = if ($Client) { $Client } else { "$g_sapClient" }

        # --- TR existence + status (E070) ------------------------------------
        $e070 = Read-SapTableRows -Destination $g_dest -Table 'E070' `
                    -Where "TRKORR EQ '$Tr'" -Fields @('TRKORR','TRFUNCTION','TRSTATUS','AS4USER') -RowCount 1
        if ($null -eq $e070) {
            Write-Host "ERROR: could not read E070 (auth?)."
            Write-Host "READINESS: tr=$Tr verdict=ERROR block=0 warn=0 info=0 objects=0"
            Disconnect-SapRfc; exit 2
        }
        if ($e070.Count -eq 0) {
            Write-Host "ERROR: transport request $Tr not found (no E070 row)."
            Write-Host "READINESS: tr=$Tr verdict=ERROR block=0 warn=0 info=0 objects=0"
            Disconnect-SapRfc; exit 2
        }
        $trStatus    = "$($e070[0].TRSTATUS)".ToUpper()
        $trFunction  = "$($e070[0].TRFUNCTION)"
        $trOwner     = "$($e070[0].AS4USER)"
        $trReleased  = ($trStatus -in @('R','N','O'))

        $findings = @()
        $checkStatuses = @()

        # --- Inventory (E071 via resolver) -----------------------------------
        $invRaw = Resolve-SapObject -Destination $g_dest -Token "TR $Tr" -Expand -Client $effClient
        $inv = @($invRaw | Where-Object { $_ -and $_.obj_name })
        if ($inv.Count -eq 0) { $checkStatuses += 'NOT_APPLICABLE' }

        # --- Child tasks (E070 STRKORR) --------------------------------------
        $children = Read-SapTableRows -Destination $g_dest -Table 'E070' `
                        -Where "STRKORR EQ '$Tr'" -Fields @('TRKORR','TRFUNCTION','TRSTATUS','AS4USER')
        if ($null -eq $children) {
            $checkStatuses += 'COULD_NOT_CHECK'
            $findings += (New-SapFinding -Severity MEDIUM -Category UNRELEASED_TASK -Coverage COULD_NOT_CHECK `
                            -Detail 'Could not read child tasks (E070)' -Source E070)
        } else {
            $findings += @(Get-SapTrChildTaskFindings -ChildRows $children)
            $checkStatuses += 'CHECKED'
        }

        # --- $TMP / multi-package (from inventory) ---------------------------
        $findings += @(Get-SapInventoryFindings -InvRecords $inv)

        # --- Inactive objects (DWINACTIV per object) -------------------------
        $inactive = @(); $couldNot = @()
        foreach ($name in (@($inv | ForEach-Object { $_.obj_name }) | Select-Object -Unique)) {
            $act = Test-SapObjectActive -Destination $g_dest -ObjName $name
            if ($null -eq $act) { $couldNot += $name }
            elseif (-not $act)  { $inactive += $name }
        }
        if ($couldNot.Count) { $checkStatuses += 'COULD_NOT_CHECK' } else { $checkStatuses += 'CHECKED' }
        $findings += @(Get-SapInactiveFindings -InactiveNames $inactive -CouldNotCheckNames $couldNot -InvRecords $inv)

        # --- Released-already note --------------------------------------------
        if ($trReleased) {
            $findings += (New-SapFinding -Severity INFO -Category TR_ALREADY_RELEASED `
                            -Detail "TR $Tr is already released (TRSTATUS=$trStatus) - nothing to gate" -Source E070)
        }

        # --- Fold in ATC / ABAP-Unit sub-verdicts ----------------------------
        $f = Get-SapSubSkillFinding -Name 'ATC'        -Verdict $AtcVerdict  -Category 'ATC'       -Source 'ATC'
        if ($f) { $findings += $f }
        $f = Get-SapSubSkillFinding -Name 'ABAP Unit'  -Verdict $UnitVerdict -Category 'UNIT_TEST'  -Source 'ABAP_UNIT'
        if ($f) { $findings += $f }

        # --- Gate + verdict ---------------------------------------------------
        $policy = Get-SapGatePolicy -BriefPath $BriefPath -Strict:$Strict
        [void](Set-SapFindingGates -Findings $findings -Policy $policy)
        $verdict = Get-SapVerdict -Findings $findings -CheckStatuses $checkStatuses
        $counts  = Get-SapGateCounts -Findings $findings

        # --- Outputs + artifact registration ---------------------------------
        $scope = New-SapScopeKey -Kind 'TR' -Name $Tr
        if ($OutputDir) {
            if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
            $dir = $OutputDir
        } else {
            $dir = Get-SapArtifactDir -ScopeKey $scope -Skill 'sap-transport-readiness' -RunId $RunId
        }
        $sample = if ($inv.Count) { $inv[0] } else { $null }

        $reportMd  = Join-Path $dir "${Tr}_readiness.md"
        $findTsv   = Join-Path $dir "${Tr}_findings.tsv"
        $findJson  = Join-Path $dir "${Tr}_findings.json"
        $invTsv    = Join-Path $dir "${Tr}_inventory.tsv"

        # inventory tsv
        $invSb = New-Object System.Text.StringBuilder
        [void]$invSb.AppendLine("pgmid`tobject`tobj_name`tkind`tpackage")
        foreach ($o in $inv) { [void]$invSb.AppendLine("$($o.pgmid)`t$($o.object)`t$($o.obj_name)`t$($o.kind)`t$($o.package)") }
        [System.IO.File]::WriteAllText($invTsv, $invSb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

        $meta = @{ tr_status = $trStatus; owner = $trOwner; trfunction = $trFunction }
        [System.IO.File]::WriteAllText($reportMd, (Build-SapReadinessMarkdown -Tr $Tr -Verdict $verdict -Findings $findings -InvRecords $inv -CheckStatuses $checkStatuses -Meta $meta), (New-Object System.Text.UTF8Encoding($false)))
        Export-SapFindingsTsv  -Findings $findings -Path $findTsv  -Scope $scope -Verdict $verdict | Out-Null
        Export-SapFindingsJson -Findings $findings -Path $findJson -Scope $scope -Verdict $verdict | Out-Null

        Register-SapArtifact -Skill 'sap-transport-readiness' -ScopeKey $scope -ScopeKind 'TR' -Kind 'readiness_report'  -Format 'md'   -Path $reportMd -Verdict $verdict -Coverage (& { if ($checkStatuses -contains 'COULD_NOT_CHECK') { 'COULD_NOT_CHECK' } elseif ($counts.BLOCK -or $counts.WARN) { 'CHECKED_FINDINGS' } else { 'CHECKED_CLEAN' } }) -RunId $RunId -System "$($sample.system)" -Client $effClient | Out-Null
        Register-SapArtifact -Skill 'sap-transport-readiness' -ScopeKey $scope -ScopeKind 'TR' -Kind 'risk_findings'     -Format 'tsv'  -Path $findTsv  -Verdict $verdict -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-transport-readiness' -ScopeKey $scope -ScopeKind 'TR' -Kind 'risk_findings'     -Format 'json' -Path $findJson -Verdict $verdict -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-transport-readiness' -ScopeKey $scope -ScopeKind 'TR' -Kind 'object_inventory'  -Format 'tsv'  -Path $invTsv   -Rows $inv.Count -RunId $RunId | Out-Null

        Write-Host ("READINESS: tr={0} verdict={1} block={2} warn={3} info={4} objects={5}" -f $Tr, $verdict, $counts.BLOCK, $counts.WARN, $counts.INFO, $inv.Count)
        Write-Host "REPORT_MD: $reportMd"
        Write-Host "FINDINGS_TSV: $findTsv"
        Write-Host "FINDINGS_JSON: $findJson"
        Write-Host "INVENTORY_TSV: $invTsv"

        Disconnect-SapRfc
        if ($verdict -eq 'NO_GO') { exit 1 } else { exit 0 }
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        Write-Host "READINESS: tr=$Tr verdict=ERROR block=0 warn=0 info=0 objects=0"
        Disconnect-SapRfc
        exit 2
    }
}
