# =============================================================================
# emit_skill_folder.ps1
# -----------------------------------------------------------------------------
# Consumes _merge_report.json + the two reference templates and writes a
# scaffolded skill folder: SKILL.md, README.md, references/*.vbs, plus a
# _source_probes folder of symlinks back to the probes that informed the
# scaffold.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File emit_skill_folder.ps1 `
#       -MergeReport <abs-path-to-_merge_report.json> `
#       -SkillName   <new-skill-name>      # sap-kebab-case
#       -OutputDir   <abs-path-to-new-skill-folder>
#       [-Tcd        <2-5-char TCD>]       # informational only, for SKILL.md header
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $MergeReport,

    [Parameter(Mandatory = $true)]
    [string] $SkillName,

    [Parameter(Mandatory = $true)]
    [string] $OutputDir,

    [string] $Tcd = '',

    # Optional server-release marker (e.g. "S4HANA_2022") read from the
    # active-session pin. When supplied, emitted VBS filenames are tagged
    # with .<marker>.vbs so the version-aware selector (sap_select_vbs_variant.ps1)
    # can pick the right variant at execution time. Untagged when empty.
    [string] $ServerMarker = '',

    # Override merge classification: any touchpoint whose target ends in one
    # of these DDIC field suffixes (e.g. KO007-L_DEVCLASS, KO008-TRKORR) is
    # forced from `constant` to `parameter` and gets a %%TOKEN%% derived from
    # the tail. Use when every probe happened to use the same value but you
    # know real users will want to vary it (the canonical example: package
    # name when all your scenarios said "in <one-package>"). String[] --
    # match is case-insensitive and only against the field tail.
    [string[]] $ForceParam = @()
)

if (-not (Test-Path $MergeReport)) {
    Write-Error "merge report not found: $MergeReport"
    exit 1
}
if ($SkillName -notmatch '^sap-[a-z0-9][a-z0-9-]+$') {
    Write-Error "skill name must match ^sap-[a-z0-9-]+$ (got '$SkillName')"
    exit 1
}

$report = Get-Content -Path $MergeReport -Raw -Encoding UTF8 | ConvertFrom-Json

# ----- Apply -ForceParam overrides ---------------------------------------------
# For each touchpoint whose target tail matches one of -ForceParam, flip the
# classification from `constant` to `parameter`, derive a %%TOKEN%% from the
# tail, and rebuild per_probe_values from each probe's recorded action value
# so downstream logic (Get-ModeParameters / argument-hint / VBS emit) sees a
# real parameter.
if ($ForceParam -and $ForceParam.Count -gt 0) {
    $forceUpper = @($ForceParam | ForEach-Object { $_.ToUpperInvariant() })
    foreach ($tp in $report.touchpoints) {
        # Force-promote both `constant` (same value across all probes) AND
        # `mode-specific` (only some probes touched it -- e.g. when a warmup
        # probe followed a different flow). Before this change ForceParam
        # silently no-op'd on mode-specific touchpoints, leaving the field
        # baked as a literal in the canonical-probe body and untokenized
        # in popup handler fallbacks -- breaking any per-call override.
        if ($tp.class -ne 'constant' -and $tp.class -ne 'mode-specific') { continue }
        if ([string]::IsNullOrWhiteSpace($tp.target)) { continue }
        if ($tp.target -notmatch '([A-Z][A-Z0-9_/]*-[A-Z][A-Z0-9_]*)$') { continue }
        $field = $matches[1]
        $tail  = ($field -split '-')[-1]
        if ($forceUpper -notcontains $tail.ToUpperInvariant()) { continue }
        $tp.class = 'parameter'
        $tp.token = "%%${tail}%%"
        $perProbe = @{}
        foreach ($p in $report.probes) {
            $hit = $p.actions | Where-Object {
                $_.verb -eq $tp.verb -and $_.target -eq $tp.target
            } | Select-Object -First 1
            if ($hit) { $perProbe[$p.id] = "$($hit.value)" }
        }
        $tp.per_probe_values = $perProbe
        # When promoting mode-specific -> parameter, ensure the touchpoint's
        # `modes` list covers EVERY mode in the run -- otherwise downstream
        # Get-ModeParameters / dispatch-table filtering will hide the param
        # from modes whose canonical probe didn't observe the field.
        $allModes = @($report.probes | ForEach-Object { $_.mode } | Sort-Object -Unique)
        $tp.modes = $allModes
    }
}

$skillNameLower = $SkillName.ToLowerInvariant()
# Filename base: strip the leading "sap-" so we don't double-prefix, then
# replace hyphens with underscores. Matches the existing convention
# (sap_se37_update.vbs, sap_function_group_gui_delete.vbs).
$skillFnBase = ($skillNameLower -replace '^sap-','') -replace '-','_'
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

# Locate templates (siblings of this script).
$thisDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tplSkill = Join-Path $thisDir 'skill_md.template'
$tplVbs   = Join-Path $thisDir 'mode_vbs.template'
foreach ($t in @($tplSkill, $tplVbs)) {
    if (-not (Test-Path $t)) {
        Write-Error "template missing: $t"
        exit 1
    }
}

# Ensure output dirs exist.
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir 'references') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir '_source_probes') | Out-Null

# ------------------------------------------------------------------------------
# Mode metadata: distinct modes preserved in probe order.
# ------------------------------------------------------------------------------
$modes = $report.probes | ForEach-Object { $_.mode } | Select-Object -Unique
$modeList = ($modes -join ', ')

# Build per-mode parameter lists by walking touchpoints whose 'modes' include
# the mode AND class == parameter. Same parameter across modes shares its token.
#
# PARAM_NN tokens (auto-numbered fallback when no DDIC field tail could be
# derived from the target) are HIDDEN from user-visible lists -- they carry
# no semantic name, so exposing them in argument-hint or the dispatch table
# tells the user nothing actionable. They still survive in the merge report
# for diagnostic purposes, but the action-emit logic in the foreach loop
# below also skips token substitution for them (falls back to the source
# probe's literal value) so the generated VBS doesn't contain an unfilled
# `%%PARAM_NN%%` placeholder.
function Test-IsRealParamToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    return ($Token -notmatch '^%%PARAM_\d+%%$')
}

function Get-ModeParameters {
    param($mode, $touchpoints)
    $params = @()
    foreach ($tp in $touchpoints) {
        if ($tp.class -ne 'parameter') { continue }
        if ($tp.modes -notcontains $mode) { continue }
        if (-not (Test-IsRealParamToken $tp.token)) { continue }
        $tokenName = ($tp.token -replace '%%','')
        $params += [pscustomobject]@{
            token  = $tokenName
            target = $tp.target
            verb   = $tp.verb
        }
    }
    return $params | Sort-Object token -Unique
}

# ------------------------------------------------------------------------------
# Popup signature catalog. Maps (program, screen) of a popup observed in a
# probe to a smart handler (fill expected fields + press Save) rather than
# the generic "press wnd[1]/tbar[0]/btn[0]" dismiss. Keyed by program +
# screen number (language-independent identifiers per CLAUDE.md Rule 5).
#
# Entry shape:
#   key  : "<PROGRAM>/<SCREEN>"
#   value: scriptblock returning an array of VBS lines. Takes the merge
#          report's touchpoints list so it can re-use any constant or
#          parameter-token discovered for the popup's entry fields.
# ------------------------------------------------------------------------------
function Get-PopupHandler {
    param([string]$Program, [string]$Screen, $Touchpoints)

    function _Find-TouchpointValue {
        param($Touchpoints, [string]$TargetSuffix)
        $tp = $Touchpoints | Where-Object {
            $_.verb -eq 'SET_TEXT' -and "$($_.target)" -like "*$TargetSuffix"
        } | Select-Object -First 1
        if (-not $tp) { return $null }
        if ($tp.class -eq 'parameter' -and $tp.token) { return $tp.token }   # %%TOKEN%%
        # Otherwise pull the constant value from the first per-probe entry
        # we observed it on. Constants have no per_probe_values dict; pull
        # from the broader probe action list via the caller's context. Here
        # we just return $null so the caller emits a TODO marker.
        return $null
    }

    $lines = New-Object System.Collections.Generic.List[string]
    switch ("$Program/$Screen") {
        'SAPLSTRD/100' {
            # Object Directory Entry popup. Needs L_DEVCLASS filled before Save.
            # Fallback token name matches the DDIC field tail (L_DEVCLASS) so
            # callers passing `-ForceParam L_DEVCLASS` get a single coherent
            # name across SKILL.md argument-hint, dispatch table, and VBS body.
            $pkgVal = _Find-TouchpointValue -Touchpoints $Touchpoints -TargetSuffix 'ctxtKO007-L_DEVCLASS'
            if (-not $pkgVal) { $pkgVal = '%%L_DEVCLASS%%' }   # TODO -- wrapper must fill; pass -ForceParam L_DEVCLASS
            $lines.Add('    ' + "' SAPLSTRD/100 = Object Directory Entry popup -- fill package then Save")
            $lines.Add('    ' + "oSess.findById(`"wnd[1]/usr/ctxtKO007-L_DEVCLASS`").Text = `"$pkgVal`"")
            $lines.Add('    ' + 'oSess.findById("wnd[1]/tbar[0]/btn[0]").press')
            $lines.Add('    ' + 'WScript.Sleep 500')
            return ,$lines.ToArray()
        }
        'SAPLSTRD/300' {
            # Workbench Request popup. Needs TRKORR filled before Save.
            $trVal = _Find-TouchpointValue -Touchpoints $Touchpoints -TargetSuffix 'ctxtKO008-TRKORR'
            if (-not $trVal) { $trVal = '%%TRKORR%%' }          # TODO -- wrapper must fill; pass -ForceParam TRKORR
            $lines.Add('    ' + "' SAPLSTRD/300 = Workbench Request popup -- fill TR then Save")
            $lines.Add('    ' + "oSess.findById(`"wnd[1]/usr/ctxtKO008-TRKORR`").Text = `"$trVal`"")
            $lines.Add('    ' + 'oSess.findById("wnd[1]/tbar[0]/btn[0]").press')
            $lines.Add('    ' + 'WScript.Sleep 500')
            return ,$lines.ToArray()
        }
        default {
            # Generic dismiss with Continue (the legacy behaviour). Caller
            # already emits a TODO marker so the human reviews.
            $lines.Add('    ' + "' default: dismiss with Continue (wnd[1]/tbar[0]/btn[0]); adjust if needed")
            $lines.Add('    ' + 'oSess.findById("wnd[1]/tbar[0]/btn[0]").press')
            $lines.Add('    ' + 'WScript.Sleep 500')
            return ,$lines.ToArray()
        }
    }
}

# ------------------------------------------------------------------------------
# Worklist-aware SELECT_ROW: when the target hits SAPLSEWORKINGAREA (the
# DDIC / repo-object "inactive objects" worklist), the absolute row index is
# volatile (it depends on what other inactive objects the user has). The
# emit step prefers a select-by-cell-value call using the probe's own
# DDIC entry-field value (e.g. the ZCMDMxxx domain name set earlier via
# ctxtRSRD1-DOMA_VAL). Falls back to the hard-coded getAbsoluteRow on miss.
# ------------------------------------------------------------------------------
function Get-WorklistMatchValue {
    param($probeActions)
    # Walk earlier actions in the same probe; pick the FIRST SET_TEXT whose
    # target is a repo-object NAME-entry field -- that's the name the
    # inactive-objects worklist will display in its OBJ_NAME column.
    #
    # Two families are recognised (both are stable DDIC field names, so this
    # stays language-independent):
    #   * SE11 / repo-browser entry screens: "-<NAME>_VAL" suffix
    #     (e.g. ctxtRSRD1-DOMA_VAL, ctxtRSRD1-TBMA_VAL).
    #   * SE37 / SE38 / SE24 initial-screen name fields:
    #     RS38L-NAME (FM), RS38M-PROGRAMM (program), SEOCLASS-CLSNAME /
    #     -CLSKEY (class/interface), RS38L-AREA (function group).
    # Without the second family, SE37/SE38/SE24 scaffolds fell back to the
    # brittle absolute getAbsoluteRow(N) baked from the probe -- which raised
    # "invalid argument" whenever the worklist contents differed from probe
    # time (regression caught by the sap-se37-v02 autotest, 2026-05-22).
    foreach ($a in $probeActions) {
        if ($a.verb -eq 'SET_TEXT' -and (
                $a.target -match '-[A-Z][A-Z0-9_]*_VAL$' -or
                $a.target -match '-(RS38L-NAME|RS38M-PROGRAMM|SEOCLASS-CLSNAME|SEOCLASS-CLSKEY|RS38L-AREA)$' -or
                $a.target -match '/(ctxt|txt)(RS38L-NAME|RS38M-PROGRAMM|SEOCLASS-CLSNAME|SEOCLASS-CLSKEY)$')) {
            return @{ value = "$($a.value)"; target = $a.target }
        }
    }
    return $null
}

# ------------------------------------------------------------------------------
# Pick the canonical probe per mode (Bug #3 fix).
#
# When N probes share the same mode label (e.g. all 12 SE11-domain probes
# end up as `create-domain`), the old behaviour was "last probe written
# wins" -- Set-Content on the same VBS path silently overwrote earlier
# iterations. That made the canonical body whichever probe happened to
# sort last (dict-order, not semantically). Result: probe_12 (INT4, no
# DECIMALS field) won over probe_5 (DEC, has DECIMALS), and the DECIMALS
# parameter ended up declared in SKILL.md but unreferenced in the body.
#
# Score each probe by **how many of its action targets are SHARED with
# at least one other probe in the same mode-group**. Targets unique to
# one probe (typical of the warmup-scenario pattern: probe_1 may do
# /nSE01 + /nSE21 prerequisite setup that no other probe in the group
# does) are EXCLUDED from the score. So the winner is the probe that
# best represents the SHARED flow of the mode -- not the one with the
# longest action list. For SE11-domain the warmup (probe_1) has many
# unique SE01/SE21 targets and zero shared-unique targets above the
# baseline; DEC/CURR/QUAN each have the shared baseline PLUS the
# shared-extra DECIMALS target -> they win.
#
# Tie-break: lowest action_count (least quirky / fewest popup-recovery
# detours like the TIMS double-Enter).
# ------------------------------------------------------------------------------
function Get-SharedTargetSet {
    param($Probes)
    # Count how many probes touch each distinct target. Any target seen
    # in >=2 probes is "shared"; targets unique to one probe are not.
    $counts = @{}
    foreach ($p in $Probes) {
        $seenInThisProbe = @{}
        foreach ($a in $p.actions) {
            $t = "$($a.target)"
            if ([string]::IsNullOrWhiteSpace($t)) { $t = "<verb=$($a.verb)>" }
            if (-not $seenInThisProbe.ContainsKey($t)) {
                $seenInThisProbe[$t] = $true
                if ($counts.ContainsKey($t)) { $counts[$t] += 1 } else { $counts[$t] = 1 }
            }
        }
    }
    $shared = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $counts.Keys) {
        if ($counts[$k] -ge 2) { [void]$shared.Add($k) }
    }
    return $shared
}

function Get-ProbeSharedCoverageScore {
    param($Probe, $SharedTargets)
    $hits = @{}
    foreach ($a in $Probe.actions) {
        $t = "$($a.target)"
        if ([string]::IsNullOrWhiteSpace($t)) { $t = "<verb=$($a.verb)>" }
        if ($SharedTargets.Contains($t) -and -not $hits.ContainsKey($t)) {
            $hits[$t] = $true
        }
    }
    return $hits.Count
}

$canonicalProbeIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($mode in $modes) {
    $candidates = @($report.probes | Where-Object { $_.mode -eq $mode })
    if ($candidates.Count -eq 1) {
        [void]$canonicalProbeIds.Add("$($candidates[0].id)")
        continue
    }
    $sharedTargets = Get-SharedTargetSet -Probes $candidates
    $scored = $candidates | ForEach-Object {
        [pscustomobject]@{
            id           = $_.id
            shared_cov   = (Get-ProbeSharedCoverageScore -Probe $_ -SharedTargets $sharedTargets)
            action_count = [int]$_.action_count
        }
    } | Sort-Object @{Expression='shared_cov';Descending=$true},
                    @{Expression='action_count';Descending=$false}
    $best = $scored | Select-Object -First 1
    [void]$canonicalProbeIds.Add("$($best.id)")
    Write-Host ("INFO: mode='{0}' canonical probe={1} (shared_coverage={2}/{3} action_count={4}; other candidates: {5})" -f `
        $mode, $best.id, $best.shared_cov, $sharedTargets.Count, $best.action_count,
        (($scored | Select-Object -Skip 1 | ForEach-Object { "$($_.id)(sc=$($_.shared_cov),ac=$($_.action_count))" }) -join ', '))
}

# ------------------------------------------------------------------------------
# Emit one VBS per mode (only the canonical probe per mode emits its body;
# non-canonical probes are still listed in _source_probes/INDEX.txt for
# full provenance, just not selected as the body source).
# ------------------------------------------------------------------------------
$probeProvenance = @()
foreach ($p in $report.probes) {
    if (-not $canonicalProbeIds.Contains("$($p.id)")) { continue }
    $mode = $p.mode
    $params = Get-ModeParameters -mode $mode -touchpoints $report.touchpoints
    $worklistMatch = Get-WorklistMatchValue -probeActions $p.actions

    # Generate action lines from the probe's actions, substituting %%TOKEN%%
    # for any touchpoint marked 'parameter'. Use the touchpoint's value for
    # constants, and emit popup-branch guards before any step where any probe
    # observed a popup.
    $vbsActions = New-Object System.Collections.Generic.List[string]
    $vbsActions.Add("' source probe   : $($p.folder)")
    $vbsActions.Add("' source scenario: (mode=$mode, $($p.action_count) actions)")
    $vbsActions.Add('')

    $probeActionList = @($p.actions)
    for ($ai = 0; $ai -lt $probeActionList.Count; $ai++) {
        $a = $probeActionList[$ai]
        $nextA = $null
        if ($ai + 1 -lt $probeActionList.Count) { $nextA = $probeActionList[$ai + 1] }
        # CAREFUL: PowerShell -like treats `[1]` as a character class, so
        # `'wnd[1]/foo' -like 'wnd[1]/*'` is FALSE (matches "wnd1/..." literally).
        # Use StartsWith for a plain substring test. Bug fixed 2026-05-17.
        $nextTargetsPopup = $nextA -and "$($nextA.target)".StartsWith('wnd[1]/')
        $vbsActions.Add("' --- step $('{0:D2}' -f $a.step) | $($a.verb) | $($a.note)")

        # Find this action's touchpoint to know if its value is a parameter.
        # SET_OKCD touchpoints are keyed by VALUE as well as (verb,target) -- see
        # merge_probes.ps1::Get-TouchpointKey -- so the action-to-touchpoint
        # match must include the value, otherwise an unrelated `parameter`
        # entry for the same OK-code field could bind here.
        $vbsValue = "$($a.value)"
        $vbsRow   = $a.row
        $tp = $report.touchpoints | Where-Object {
            $_.verb -eq $a.verb -and $_.target -eq $a.target -and $_.class -eq 'parameter' -and
            ($a.verb -ne 'SET_OKCD' -or ([string]($_.per_probe_values.Values | Select-Object -First 1) -eq "$($a.value)"))
        } | Select-Object -First 1
        if ($tp -and (Test-IsRealParamToken $tp.token)) {
            if ($a.verb -eq 'SELECT_ROW') {
                $vbsRow = $tp.token        # row is parameterised
            } else {
                $vbsValue = $tp.token      # value is parameterised
            }
        }

        switch ($a.verb) {
            'SET_TEXT' {
                # GuiComboBox (cmb* leaf, e.g. lock mode cmbENQMODE) has a
                # READONLY .Text -- select the entry via .Key instead.
                $stLeaf = ($a.target -split '/')[-1]
                if ($stLeaf -match '^cmb') {
                    $vbsActions.Add("oSess.findById(`"$($a.target)`").Key = `"$vbsValue`"")
                }
                elseif ($vbsValue -match "`r|`n") {
                    # MULTI-LINE value (e.g. an ABAP source paste into the
                    # SE37/SE38 AbapEditor shell). A raw inline VBScript string
                    # literal CANNOT span physical lines -- emitting it directly
                    # produces "unterminated string constant" at compile time
                    # (regression caught by the sap-se37-v02 autotest,
                    # 2026-05-22). Build the value as a vbCrLf-joined string and
                    # write it under On Error Resume Next: the AbapEditor
                    # GuiShell .Text is READ-ONLY in a headless/background
                    # scripting session, so the assignment may fail -- in which
                    # case we proceed on SAP's auto-generated template (which
                    # still syntax-checks / saves / activates) rather than
                    # aborting the whole replay.
                    $stVar = 'sTxt' + $ai
                    $lines = $vbsValue -split "`r`n|`r|`n"
                    for ($li = 0; $li -lt $lines.Count; $li++) {
                        $esc = $lines[$li].Replace('"', '""')
                        if ($li -eq 0) {
                            $vbsActions.Add("$stVar = `"$esc`"")
                        } elseif ($li -eq $lines.Count - 1) {
                            $vbsActions.Add("$stVar = $stVar & vbCrLf & `"$esc`"")
                        } else {
                            $vbsActions.Add("$stVar = $stVar & vbCrLf & `"$esc`"")
                        }
                    }
                    $vbsActions.Add("On Error Resume Next")
                    $vbsActions.Add("oSess.findById(`"$($a.target)`").Text = $stVar")
                    $vbsActions.Add("If Err.Number <> 0 Then WScript.Echo `"INFO: target .Text is read-only in this session; proceeding (Err `" & Err.Number & `").`" : Err.Clear")
                    $vbsActions.Add("On Error GoTo 0")
                }
                else {
                    $vbsActions.Add("oSess.findById(`"$($a.target)`").Text = `"$vbsValue`"")
                }
            }
            'SET_OKCD' {
                $tgt = if ($a.target) { $a.target } else { 'wnd[0]/tbar[0]/okcd' }
                $vbsActions.Add("oSess.findById(`"$tgt`").Text = `"$vbsValue`"")
                $vbsActions.Add('oSess.findById("wnd[0]").sendVKey 0')
            }
            'SEND_VKEY' {
                $tgt = if ($a.target) { $a.target } else { 'wnd[0]' }
                $vbsActions.Add("oSess.findById(`"$tgt`").sendVKey $($a.vkey)")
            }
            'PRESS' {
                # Control-type discrimination by id leaf (language-independent):
                # GuiRadioButton (rad*) needs .select, GuiCheckBox (chk*) needs
                # .selected=True; only GuiButton (btn*/push*) takes .press.
                # Emitting .press on a radio throws "method not supported".
                $leaf = ($a.target -split '/')[-1]
                $pressLine = if ("$($a.target)" -match '/mbar/') {
                    # GuiMenu (menu bar item) is selected, not pressed.
                    "oSess.findById(`"$($a.target)`").select"
                } elseif ($leaf -match '^rad') {
                    "oSess.findById(`"$($a.target)`").select"
                } elseif ($leaf -match '^tabp') {
                    # GuiTab (tab page) is selected, not pressed.
                    "oSess.findById(`"$($a.target)`").select"
                } elseif ($leaf -match '^chk') {
                    "oSess.findById(`"$($a.target)`").selected = True"
                } else {
                    "oSess.findById(`"$($a.target)`").press"
                }
                # Guard popup-targeted actions: on replay the popup may not be
                # open if timing differs from the probe, and an unconditional
                # findById on wnd[1]/wnd[2] throws "control could not be found".
                if ("$($a.target)".StartsWith('wnd[1]/') -or "$($a.target)".StartsWith('wnd[2]/')) {
                    $vbsActions.Add("If Not oSess.findById(`"$($a.target)`", False) Is Nothing Then")
                    $vbsActions.Add("    $pressLine")
                    $vbsActions.Add('End If')
                } else {
                    $vbsActions.Add($pressLine)
                }
            }
            'SELECT' {
                # SELECT is a first-class probe verb (sap_gui_probe_action.vbs):
                # radios/tabs select, checkboxes tick. Without this case the
                # emit dropped every SELECT action as "unknown verb" and the
                # generated VBS skipped radio/tab selection entirely.
                $leaf = ($a.target -split '/')[-1]
                $selLine = if ("$($a.target)" -match '/mbar/') {
                    "oSess.findById(`"$($a.target)`").select"
                } elseif ($leaf -match '^rad') {
                    "oSess.findById(`"$($a.target)`").select"
                } elseif ($leaf -match '^tabp') {
                    "oSess.findById(`"$($a.target)`").select"
                } elseif ($leaf -match '^chk') {
                    $on = if ("$($a.value)".Trim().ToLower() -in @('','true','x','1')) { 'True' } else { 'False' }
                    "oSess.findById(`"$($a.target)`").selected = $on"
                } else {
                    "oSess.findById(`"$($a.target)`").press"
                }
                if ("$($a.target)".StartsWith('wnd[1]/') -or "$($a.target)".StartsWith('wnd[2]/')) {
                    $vbsActions.Add("If Not oSess.findById(`"$($a.target)`", False) Is Nothing Then")
                    $vbsActions.Add("    $selLine")
                    $vbsActions.Add('End If')
                } else {
                    $vbsActions.Add($selLine)
                }
            }
            'SELECT_ROW' {
                if ($a.target -match 'SAPLSEWORKINGAREA' -and $worklistMatch) {
                    # If the worklist's match value is parameterised somewhere
                    # in the touchpoint report, prefer that token (so the
                    # generated skill matches whatever the user passes in).
                    # Otherwise bake in the probe-recorded literal value.
                    $matchExpr = "`"$($worklistMatch.value)`""
                    $matchTp = $report.touchpoints | Where-Object {
                        $_.verb -eq 'SET_TEXT' -and $_.target -eq $worklistMatch.target -and $_.class -eq 'parameter'
                    } | Select-Object -First 1
                    if ($matchTp) { $matchExpr = "`"$($matchTp.token)`"" }
                    $vbsActions.Add("' inactive-objects worklist: select by OBJ_NAME (probe row was $($a.row); index varies if other inactive objects coexist)")
                    $vbsActions.Add("If Not SelectRowByCellValue(oSess, `"$($a.target)`", `"OBJ_NAME`", $matchExpr) Then")
                    $vbsActions.Add("    ' TODO (human review): worklist did not contain OBJ_NAME=$matchExpr -- falling back to probe-recorded row index")
                    $vbsActions.Add("    oSess.findById(`"$($a.target)`").getAbsoluteRow($vbsRow).Selected = True")
                    $vbsActions.Add('End If')
                } else {
                    $vbsActions.Add("oSess.findById(`"$($a.target)`").getAbsoluteRow($vbsRow).Selected = True")
                }
            }
            'DOUBLE_CLICK' {
                $vbsActions.Add("oSess.findById(`"$($a.target)`").doubleClick")
            }
            default {
                $vbsActions.Add("' WARNING: unknown verb '$($a.verb)' -- skipped")
            }
        }
        $vbsActions.Add('WScript.Sleep 800')

        # If ANY probe observed a popup at this step, emit a branch.
        #
        # Suppression rule (Bug #4 fix): suppress the auto-dismiss branch ONLY
        # when THIS PROBE itself saw the popup AND its next action targets
        # wnd[1]/* (canonical popup-fill recorded by the probe -- next step's
        # findById handles it naturally). Suppressing based on next-action
        # alone -- without confirming this probe observed the popup -- let
        # cross-probe popup observations leak into the suppression decision,
        # producing the "popup-reminder fires before recovery" symptom seen
        # in the 2026-05-17 test run.
        #
        # The all-probes count is kept for the informational comment so the
        # human reviewer sees how many probes hit the popup across the run.
        $popupHereAll = @($report.popups_observed | Where-Object { $_.step -eq $a.step })
        $thisProbeId = "$($p.id)"
        $popupHereThisProbe = @($popupHereAll | Where-Object { "$($_.probe_id)" -eq $thisProbeId })
        $thisProbeHandlesPopup = $nextTargetsPopup -and ($popupHereThisProbe.Count -gt 0)
        if ($popupHereAll.Count -gt 0 -and -not $thisProbeHandlesPopup) {
            $popupModes = ($popupHereAll | ForEach-Object { $_.mode } | Sort-Object -Unique) -join ', '
            $popupProg  = "$($popupHereAll[0].after.program)"
            $popupScrn  = "$($popupHereAll[0].after.screen)"
            $handler = Get-PopupHandler -Program $popupProg -Screen $popupScrn -Touchpoints $report.touchpoints
            $vbsActions.Add('')
            $vbsActions.Add("' POPUP REMINDER: $($popupHereAll.Count) probe(s) observed a wnd[1] popup at this step (modes: $popupModes; program=$popupProg screen=$popupScrn).")
            $vbsActions.Add("' TODO (human review): confirm dismiss / fill logic for this popup.")
            $vbsActions.Add('If IsPopupOpen(oSess) Then')
            foreach ($l in $handler) { $vbsActions.Add($l) }
            $vbsActions.Add('End If')
            $vbsActions.Add('')
        } elseif ($popupHereAll.Count -gt 0) {
            $vbsActions.Add('')
            $vbsActions.Add("' Popup observed by $($popupHereAll.Count) probe(s) at this step; this probe's next action targets wnd[1] -- next step handles it; no auto-dismiss emitted.")
            $vbsActions.Add('')
        }
    }

    # Orphan-param TODO sentinel (Bug #3 followup).
    #
    # The canonical probe may not touch every parameter declared for this
    # mode (e.g. INT4 doesn't set DD01D-DECIMALS, but CURR/QUAN/DEC do; if
    # the richest-probe scoring above happened to pick INT4 anyway, the
    # DECIMALS line would be missing from the body). Walk the declared
    # params and verify each `%%TOKEN%%` appears at least once in the
    # emitted action lines. For each orphan, append a TODO at the end of
    # the body so the human author sees what's missing.
    $bodyText = $vbsActions -join "`n"
    $orphanParams = @($params | Where-Object { $bodyText -notmatch [regex]::Escape("%%$($_.token)%%") })
    if ($orphanParams.Count -gt 0) {
        $vbsActions.Add('')
        $vbsActions.Add("' ============================================================================")
        $vbsActions.Add("' TODO (human review): orphan parameters declared but not referenced in body")
        $vbsActions.Add("' ----------------------------------------------------------------------------")
        $vbsActions.Add("' The following parameters were detected across the probe set but the")
        $vbsActions.Add("' canonical probe chosen for this mode did NOT include a SET_TEXT for them.")
        $vbsActions.Add("' Insert SET_TEXT lines at appropriate screen positions before the Save")
        $vbsActions.Add("' action. The target paths are listed below for copy-paste convenience.")
        foreach ($op in $orphanParams) {
            $vbsActions.Add("'   - %%$($op.token)%%   target: $($op.target)   ($($op.verb))")
        }
        $vbsActions.Add("' ============================================================================")
        $vbsActions.Add('')
    }

    # Param doc block for the VBS header
    $paramDoc = New-Object System.Collections.Generic.List[string]
    if ($params.Count -eq 0) {
        $paramDoc.Add("'   (no parameters -- all values are constants)")
    } else {
        foreach ($pa in $params) {
            $paramDoc.Add("'   %%$($pa.token)%%   $($pa.target)   ($($pa.verb))")
        }
    }

    # Substitute into the VBS template.
    $vbs = [System.IO.File]::ReadAllText($tplVbs, [System.Text.Encoding]::UTF8)
    $vbs = $vbs.Replace('{{SKILL_NAME_LOWER}}',     $skillFnBase)
    $vbs = $vbs.Replace('{{MODE}}',                 $mode)
    $vbs = $vbs.Replace('{{SCAFFOLD_TIMESTAMP}}',   $timestamp)
    $vbs = $vbs.Replace('{{SOURCE_PROBE_FOLDER}}',  $p.folder)
    $vbs = $vbs.Replace('{{SOURCE_SCENARIO}}',      "mode=$mode")
    $vbs = $vbs.Replace('{{PARAM_DOC}}',            ($paramDoc -join "`r`n"))
    $vbs = $vbs.Replace('{{ACTION_LINES}}',         ($vbsActions -join "`r`n"))

    if ($ServerMarker) {
        $vbsPath = Join-Path $OutputDir ("references\sap_{0}_{1}.{2}.vbs" -f $skillFnBase, $mode, $ServerMarker)
    } else {
        $vbsPath = Join-Path $OutputDir ("references\sap_{0}_{1}.vbs" -f $skillFnBase, $mode)
    }
    # Committed reference .vbs = UTF-8 no BOM (git-diffable, ASCII-policy clean);
    # the generated wrapper reads it back as UTF-8. Runtime *_run.vbs stays UTF-16 LE.
    [System.IO.File]::WriteAllText($vbsPath, $vbs, [System.Text.UTF8Encoding]::new($false))

    $probeId      = $p.id
    $actionCount  = $p.action_count
    $probeProvenance += "- **$mode** (probe ``$probeId``, $actionCount actions) -> ``$vbsPath``"
}

# ------------------------------------------------------------------------------
# Mode dispatch table for SKILL.md
# ------------------------------------------------------------------------------
$dispatchLines = @()
$dispatchLines += "| MODE | Reference VBS | Required parameters |"
$dispatchLines += "|---|---|---|"
foreach ($mode in $modes) {
    $params = Get-ModeParameters -mode $mode -touchpoints $report.touchpoints
    $paramList = if ($params.Count -eq 0) { '(none)' } else { ($params.token | ForEach-Object { "``$_``" }) -join ', ' }
    if ($ServerMarker) {
        $vbsBase = "sap_${skillFnBase}_${mode}.${ServerMarker}.vbs"
    } else {
        $vbsBase = "sap_${skillFnBase}_${mode}.vbs"
    }
    $dispatchLines += "| ``$mode`` | ``references\$vbsBase`` | $paramList |"
}
$dispatchTable = $dispatchLines -join "`r`n"

# Param-hint for argument-hint. PARAM_NN tokens are hidden -- see
# Test-IsRealParamToken above for the rationale.
$allParams = $report.touchpoints |
    Where-Object class -eq 'parameter' |
    Where-Object { Test-IsRealParamToken $_.token } |
    ForEach-Object { ($_.token -replace '%%','') } |
    Sort-Object -Unique
$paramHint = if ($allParams) { ($allParams | ForEach-Object { "<$_>" }) -join ' ' } else { '' }
$paramMapHint = if ($allParams) {
    ($allParams | ForEach-Object { "$_ = ''" }) -join '; '
} else {
    "(none)"
}

# ------------------------------------------------------------------------------
# Description / provenance bullets
# ------------------------------------------------------------------------------
$descLine = if ($Tcd) {
    "Driven transaction $Tcd with $($modes.Count) mode$(if ($modes.Count -ne 1) {'s'} else {''}) ($modeList)."
} else {
    "Driven SAP transaction with $($modes.Count) mode$(if ($modes.Count -ne 1) {'s'} else {''}) ($modeList)."
}

$provenanceBullets = $probeProvenance -join "`r`n"

# ------------------------------------------------------------------------------
# Generate the three failure-mode documentation sections (B4 in the plan).
# All three are derived from the merge report; each section emits empty
# when its underlying observation array is empty so legacy scaffolds and
# pure-success runs don't get noise sections.
# ------------------------------------------------------------------------------

# Suggested-recovery hint for a popup (program, screen). Mirrors
# Get-PopupHandler's catalog so the SKILL.md mentions the same recovery
# strategy the VBS injects.
function Get-PopupRecoveryHint {
    param([string]$Program, [string]$Screen)
    $sig = "$Program/$Screen"
    switch ($sig) {
        'SAPLSTRD/100'         { return 'Fill `wnd[1]/usr/ctxtKO007-L_DEVCLASS` (package) then Save (Enter).' }
        'SAPLSTRD/300'         { return 'Fill `wnd[1]/usr/ctxtKO008-TRKORR` (transport) then Continue (Enter).' }
        'SAPLSEWORKINGAREA/205'{ return 'Inactive Objects worklist -- Deselect All (`tbar[0]/btn[21]`), then SELECT_ROW the target by OBJ_NAME, then Continue.' }
        default                { return 'Default: dismiss with Continue (`wnd[1]/tbar[0]/btn[0]`). Review whether this is the right recovery for `' + $sig + '`.' }
    }
}

# ---- Known Issues Observed During Scaffolding -------------------------------
$knownIssuesLines = New-Object System.Collections.Generic.List[string]
$hasStatusBar = ($report.status_bar_observations -and $report.status_bar_observations.Count -gt 0)
$hasPopupAgg  = ($report.popups_observed       -and $report.popups_observed.Count       -gt 0)
$hasNoops     = ($report.noop_events           -and $report.noop_events.Count           -gt 0)

if ($hasStatusBar -or $hasPopupAgg -or $hasNoops) {
    $successCount = @($report.probes | Where-Object { (-not $_.scenario_type) -or $_.scenario_type -eq 'success' }).Count
    $failureCount = $report.probe_count - $successCount
    $knownIssuesLines.Add("## Known Issues Observed During Scaffolding")
    $knownIssuesLines.Add("")
    $knownIssuesLines.Add("Generated from $($report.probe_count) probes ($successCount success, $failureCount failure-expected). Review the popup branches in the per-mode VBS and adjust recovery actions if any of these are runtime concerns.")
    $knownIssuesLines.Add("")

    if ($hasStatusBar) {
        $knownIssuesLines.Add("### Status-bar warnings/errors")
        $knownIssuesLines.Add("")
        $knownIssuesLines.Add("| Step | MessageType | Text observed | Frequency |")
        $knownIssuesLines.Add("|---|---|---|---|")
        $sortedSbar = @($report.status_bar_observations) |
            Sort-Object @{Expression={[int]$_.step}}, message_type
        foreach ($e in $sortedSbar) {
            $texts = @($e.sbar_text_seen) -join ' / '
            if ($texts.Length -gt 120) { $texts = $texts.Substring(0,117) + '...' }
            $knownIssuesLines.Add("| $($e.step) | $($e.message_type) | $texts | $($e.frequency_text) |")
        }
        $knownIssuesLines.Add("")
    }

    if ($hasPopupAgg) {
        # Aggregate popups by (step, program, screen) so the table is concise.
        $popKeyMap = @{}
        foreach ($p in $report.popups_observed) {
            $prog = "$($p.after.program)"; $scrn = "$($p.after.screen)"
            $k = "$($p.step)|$prog|$scrn"
            if (-not $popKeyMap.ContainsKey($k)) {
                $popKeyMap[$k] = @{ step=$p.step; program=$prog; screen=$scrn; probes=New-Object 'System.Collections.Generic.HashSet[string]' }
            }
            [void]$popKeyMap[$k].probes.Add($p.probe_id)
        }
        $knownIssuesLines.Add("### Popups encountered")
        $knownIssuesLines.Add("")
        $knownIssuesLines.Add("| Step | Program/Screen | Frequency | Suggested recovery |")
        $knownIssuesLines.Add("|---|---|---|---|")
        # Sort by step number (numeric), then alphabetically by program/screen.
        $sortedKeys = $popKeyMap.Keys |
            Sort-Object @{Expression={[int]$popKeyMap[$_].step}},
                        @{Expression={"$($popKeyMap[$_].program)/$($popKeyMap[$_].screen)"}}
        foreach ($k in $sortedKeys) {
            $e = $popKeyMap[$k]
            $hint = Get-PopupRecoveryHint -Program $e.program -Screen $e.screen
            $knownIssuesLines.Add("| $($e.step) | $($e.program)/$($e.screen) | $($e.probes.Count)/$($report.probe_count) probes | $hint |")
        }
        $knownIssuesLines.Add("")
    }

    if ($hasNoops) {
        $knownIssuesLines.Add("### NOOPs and retries")
        $knownIssuesLines.Add("")
        $knownIssuesLines.Add("| Step | Probe | Verb | Target / Screen |")
        $knownIssuesLines.Add("|---|---|---|---|")
        $sortedNoops = @($report.noop_events) | Sort-Object @{Expression={[int]$_.step}}, probe_id
        foreach ($n in $sortedNoops) {
            $knownIssuesLines.Add("| $($n.step) | $($n.probe_id) | $($n.verb) | $($n.target) (screen $($n.screen)) |")
        }
        $knownIssuesLines.Add("")
        $knownIssuesLines.Add("A NOOP usually means a field-validation error left the screen unchanged. Read the corresponding ``step_NN_after.txt`` in ``_source_probes/`` for the sbar text.")
        $knownIssuesLines.Add("")
    }
}
$knownIssuesSection = $knownIssuesLines -join "`r`n"

# ---- Failure Modes Handled --------------------------------------------------
$failureModesLines = New-Object System.Collections.Generic.List[string]
$failureProbes = @($report.probes | Where-Object { $_.scenario_type -and $_.scenario_type -ne 'success' })
if ($failureProbes.Count -gt 0) {
    $failureModesLines.Add("## Failure Modes Handled")
    $failureModesLines.Add("")
    $failureModesLines.Add("This skill was scaffolded with $($failureProbes.Count) expected-failure probe(s). Each mode below documents the observed end state of the corresponding failure scenario. Callers of this skill should expect these end states when invoking the matching mode; the VBS replays the probe's path through them, but the **recovery / error-classification logic in the caller is the human author's responsibility** -- adjust the per-mode VBS popup branches and add ``If StatusBarType=`"E`"`` checks as needed.")
    $failureModesLines.Add("")
    foreach ($fp in $failureProbes) {
        $failureModesLines.Add("### Mode: ``$($fp.mode)`` (scenario_type=``$($fp.scenario_type)``)")
        $failureModesLines.Add("")
        $failureModesLines.Add("- Source probe: ``$($fp.folder)``")
        if ($fp.observed) {
            $obs = $fp.observed
            if ($obs.final_message_type)  { $failureModesLines.Add("- Final status-bar MessageType: ``$($obs.final_message_type)``") }
            if ($obs.final_sbar_text)     { $failureModesLines.Add("- Final status-bar text: ""$($obs.final_sbar_text)""") }
            if ($obs.popups_seen -and @($obs.popups_seen).Count -gt 0) {
                $popList = @($obs.popups_seen) | ForEach-Object { "$($_.program)/$($_.screen)" }
                $failureModesLines.Add("- Popups seen: $($popList -join ', ')")
            }
            if ($null -ne $obs.completed_steps) { $failureModesLines.Add("- Completed steps before end: $($obs.completed_steps)") }
            if ($null -ne $obs.aborted)         { $failureModesLines.Add("- Probe aborted: $($obs.aborted)") }
        } else {
            $failureModesLines.Add("- (no observed{} block -- probe may pre-date end-of-run summary capture)")
        }
        $failureModesLines.Add("- Caller advice: after running this mode, check the status-bar via the shared `StatusBarType` helper. ``E`` / ``A`` = the expected failure mode reproduced. ``S`` = unexpected -- the probe's failure path may not have triggered this run.")
        $failureModesLines.Add("")
    }
}
$failureModesSection = $failureModesLines -join "`r`n"

# ---- Recovery Strategies ----------------------------------------------------
$recoveryLines = New-Object System.Collections.Generic.List[string]
if ($hasPopupAgg) {
    # Distinct (program, screen) pairs across the full run, regardless of step.
    $popSigMap = @{}
    foreach ($p in $report.popups_observed) {
        $sig = "$($p.after.program)/$($p.after.screen)"
        if (-not $popSigMap.ContainsKey($sig)) {
            $popSigMap[$sig] = @{ program=$p.after.program; screen=$p.after.screen; count=0 }
        }
        $popSigMap[$sig].count += 1
    }
    if ($popSigMap.Count -gt 0) {
        $recoveryLines.Add("## Recovery Strategies")
        $recoveryLines.Add("")
        $recoveryLines.Add("Distinct popups observed across the probe set, with the recovery the scaffolder's popup catalog suggests. The per-mode VBS already injects these as `If IsPopupOpen Then ... End If` blocks (with TODO markers); use this table to cross-check that the injected handler matches your operational intent.")
        $recoveryLines.Add("")
        $recoveryLines.Add("| Popup signature | Observations | Suggested recovery |")
        $recoveryLines.Add("|---|---|---|")
        foreach ($k in ($popSigMap.Keys | Sort-Object)) {
            $e = $popSigMap[$k]
            $hint = Get-PopupRecoveryHint -Program $e.program -Screen $e.screen
            $recoveryLines.Add("| ``$($e.program)/$($e.screen)`` | $($e.count) | $hint |")
        }
        $recoveryLines.Add("")
    }
}
$recoverySection = $recoveryLines -join "`r`n"

# ------------------------------------------------------------------------------
# Emit SKILL.md
# ------------------------------------------------------------------------------
$skillMd = Get-Content $tplSkill -Raw
$skillMd = $skillMd.Replace('{{SKILL_NAME}}',                $SkillName)
$skillMd = $skillMd.Replace('{{SKILL_NAME_LOWER}}',          $skillFnBase)
$skillMd = $skillMd.Replace('{{TCD}}',                       $(if ($Tcd) { $Tcd } else { '(unspecified TCD)' }))
$skillMd = $skillMd.Replace('{{MODE_LIST}}',                 $modeList)
$skillMd = $skillMd.Replace('{{DESCRIPTION_LINE}}',          $descLine)
$skillMd = $skillMd.Replace('{{SCAFFOLD_TIMESTAMP}}',        $timestamp)
$skillMd = $skillMd.Replace('{{PROBE_COUNT}}',               "$($report.probe_count)")
$skillMd = $skillMd.Replace('{{PROBE_PROVENANCE_BULLETS}}',  $provenanceBullets)
$skillMd = $skillMd.Replace('{{MODE_DISPATCH_TABLE}}',       $dispatchTable)
$skillMd = $skillMd.Replace('{{PARAM_HINT}}',                $paramHint)
$skillMd = $skillMd.Replace('{{PARAM_MAP_HINT}}',            $paramMapHint)
$skillMd = $skillMd.Replace('{{KNOWN_ISSUES_SECTION}}',      $knownIssuesSection)
$skillMd = $skillMd.Replace('{{FAILURE_MODES_SECTION}}',     $failureModesSection)
$skillMd = $skillMd.Replace('{{RECOVERY_STRATEGIES_SECTION}}', $recoverySection)

Set-Content -Path (Join-Path $OutputDir 'SKILL.md') -Value $skillMd -Encoding UTF8

# ------------------------------------------------------------------------------
# README.md (stub)
# ------------------------------------------------------------------------------
$readme = @"
# $SkillName

Auto-scaffolded by ``/sap-gui-skill-scaffold`` on $timestamp from $($report.probe_count) probe(s).

## Modes

$modeList

See ``SKILL.md`` for the per-mode parameter list and dispatch table.

## Provenance

$provenanceBullets

## Status

Generated draft. Before shipping, work through the "Notes for the human editor"
section at the bottom of ``SKILL.md``. The smoke-test path is: re-run each
probe's original scenario through this skill and verify the same screen
identity is reached.
"@
Set-Content -Path (Join-Path $OutputDir 'README.md') -Value $readme -Encoding UTF8

# ------------------------------------------------------------------------------
# _source_probes provenance -- write a small index file rather than symlinks
# (symlinks need admin on Windows; an index file is just as useful for humans).
# ------------------------------------------------------------------------------
$probeIndex = New-Object System.Collections.Generic.List[string]
$probeIndex.Add("# Source probes that informed this scaffold")
$probeIndex.Add("# Generated: $timestamp")
$probeIndex.Add("")
foreach ($p in $report.probes) {
    $probeIndex.Add("$($p.id) | mode=$($p.mode) | $($p.action_count) actions")
    $probeIndex.Add("  -> $($p.folder)")
    $probeIndex.Add("")
}
Set-Content -Path (Join-Path $OutputDir '_source_probes\INDEX.txt') -Value ($probeIndex -join "`r`n") -Encoding UTF8

# Also copy the merge report into the scaffold for full provenance.
# Skip if the merge report is already inside $OutputDir (the merge step may
# have written it there directly).
$reportDest = Join-Path $OutputDir '_merge_report.json'
if ((Resolve-Path $MergeReport).Path -ne (Resolve-Path -Path $reportDest -ErrorAction SilentlyContinue).Path) {
    Copy-Item -Path $MergeReport -Destination $reportDest -Force
}

Write-Output "EMIT OK: $OutputDir"
Write-Output "  SKILL.md, README.md, _merge_report.json"
Write-Output "  references/: $($modes.Count) mode VBS file(s) -- $modeList"
exit 0
