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
    # name when all your scenarios said "in <one-package>"). String[] —
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
        if ($tp.class -ne 'constant') { continue }
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
# derived from the target) are HIDDEN from user-visible lists — they carry
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
            $pkgVal = _Find-TouchpointValue -Touchpoints $Touchpoints -TargetSuffix 'ctxtKO007-L_DEVCLASS'
            if (-not $pkgVal) { $pkgVal = '%%PACKAGE%%' }   # TODO -- wrapper must fill
            $lines.Add('    ' + "' SAPLSTRD/100 = Object Directory Entry popup -- fill package then Save")
            $lines.Add('    ' + "oSess.findById(`"wnd[1]/usr/ctxtKO007-L_DEVCLASS`").Text = `"$pkgVal`"")
            $lines.Add('    ' + 'oSess.findById("wnd[1]/tbar[0]/btn[0]").press')
            $lines.Add('    ' + 'WScript.Sleep 500')
            return ,$lines.ToArray()
        }
        'SAPLSTRD/300' {
            # Workbench Request popup. Needs TRKORR filled before Save.
            $trVal = _Find-TouchpointValue -Touchpoints $Touchpoints -TargetSuffix 'ctxtKO008-TRKORR'
            if (-not $trVal) { $trVal = '%%TR%%' }          # TODO -- wrapper must fill
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
    # target ends in "-<NAME>_VAL" (the SE11 / repo-browser entry-screen
    # convention) — that's the name the worklist will display in its OBJ_NAME
    # column.
    foreach ($a in $probeActions) {
        if ($a.verb -eq 'SET_TEXT' -and $a.target -match '-[A-Z][A-Z0-9_]*_VAL$') {
            return @{ value = "$($a.value)"; target = $a.target }
        }
    }
    return $null
}

# ------------------------------------------------------------------------------
# Emit one VBS per mode.
# ------------------------------------------------------------------------------
$probeProvenance = @()
foreach ($p in $report.probes) {
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
        $nextTargetsPopup = $nextA -and ("$($nextA.target)" -like 'wnd[1]/*')
        $vbsActions.Add("' --- step $('{0:D2}' -f $a.step) | $($a.verb) | $($a.note)")

        # Find this action's touchpoint to know if its value is a parameter.
        # SET_OKCD touchpoints are keyed by VALUE as well as (verb,target) — see
        # merge_probes.ps1::Get-TouchpointKey — so the action-to-touchpoint
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
                $vbsActions.Add("oSess.findById(`"$($a.target)`").Text = `"$vbsValue`"")
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
                $vbsActions.Add("oSess.findById(`"$($a.target)`").press")
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
        #   - If THIS probe's next action targets wnd[1]/*, the popup is the
        #     canonical popup-fill flow recorded by the probe; emit nothing
        #     and let the next step's findById run naturally. (The previous
        #     emit version blindly dismissed the popup with btn[0] BEFORE
        #     the next step ran, which broke the chain — see Bug 13.)
        #   - Otherwise dispatch to the popup-signature catalog (SAPLSTRD/100,
        #     /300, ...) for a smart fill+save when we can; fall back to
        #     generic dismiss when the popup signature is not in the catalog.
        $popupHere = @($report.popups_observed | Where-Object { $_.step -eq $a.step })
        if ($popupHere.Count -gt 0 -and -not $nextTargetsPopup) {
            $popupModes = ($popupHere | ForEach-Object { $_.mode } | Sort-Object -Unique) -join ', '
            $popupProg  = "$($popupHere[0].after.program)"
            $popupScrn  = "$($popupHere[0].after.screen)"
            $handler = Get-PopupHandler -Program $popupProg -Screen $popupScrn -Touchpoints $report.touchpoints
            $vbsActions.Add('')
            $vbsActions.Add("' POPUP REMINDER: $($popupHere.Count) probe(s) observed a wnd[1] popup at this step (modes: $popupModes; program=$popupProg screen=$popupScrn).")
            $vbsActions.Add("' TODO (human review): confirm dismiss / fill logic for this popup.")
            $vbsActions.Add('If IsPopupOpen(oSess) Then')
            foreach ($l in $handler) { $vbsActions.Add($l) }
            $vbsActions.Add('End If')
            $vbsActions.Add('')
        } elseif ($popupHere.Count -gt 0) {
            $vbsActions.Add('')
            $vbsActions.Add("' Popup observed by $($popupHere.Count) probe(s) at this step, but next action targets wnd[1] -- next step handles it; no auto-dismiss emitted.")
            $vbsActions.Add('')
        }
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
    $vbs = Get-Content $tplVbs -Raw
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
    Set-Content -Path $vbsPath -Value $vbs -Encoding Unicode

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

# Param-hint for argument-hint. PARAM_NN tokens are hidden — see
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
