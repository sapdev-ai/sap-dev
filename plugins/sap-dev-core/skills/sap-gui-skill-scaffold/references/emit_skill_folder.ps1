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
    [string] $ServerMarker = ''
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
function Get-ModeParameters {
    param($mode, $touchpoints)
    $params = @()
    foreach ($tp in $touchpoints) {
        if ($tp.class -ne 'parameter') { continue }
        if ($tp.modes -notcontains $mode) { continue }
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
# Emit one VBS per mode.
# ------------------------------------------------------------------------------
$probeProvenance = @()
foreach ($p in $report.probes) {
    $mode = $p.mode
    $params = Get-ModeParameters -mode $mode -touchpoints $report.touchpoints

    # Generate action lines from the probe's actions, substituting %%TOKEN%%
    # for any touchpoint marked 'parameter'. Use the touchpoint's value for
    # constants, and emit popup-branch guards before any step where any probe
    # observed a popup.
    $vbsActions = New-Object System.Collections.Generic.List[string]
    $vbsActions.Add("' source probe   : $($p.folder)")
    $vbsActions.Add("' source scenario: (mode=$mode, $($p.action_count) actions)")
    $vbsActions.Add('')

    foreach ($a in $p.actions) {
        $vbsActions.Add("' --- step $('{0:D2}' -f $a.step) | $($a.verb) | $($a.note)")

        # Find this action's touchpoint to know if its value is a parameter.
        $vbsValue = "$($a.value)"
        $vbsRow   = $a.row
        $tp = $report.touchpoints | Where-Object {
            $_.verb -eq $a.verb -and $_.target -eq $a.target -and $_.class -eq 'parameter'
        } | Select-Object -First 1
        if ($tp) {
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
                $vbsActions.Add("oSess.findById(`"$($a.target)`").getAbsoluteRow($vbsRow).Selected = True")
            }
            'DOUBLE_CLICK' {
                $vbsActions.Add("oSess.findById(`"$($a.target)`").doubleClick")
            }
            default {
                $vbsActions.Add("' WARNING: unknown verb '$($a.verb)' -- skipped")
            }
        }
        $vbsActions.Add('WScript.Sleep 800')

        # If ANY probe observed a popup at this step, emit a branch reminder.
        $popupHere = @($report.popups_observed | Where-Object { $_.step -eq $a.step })
        if ($popupHere.Count -gt 0) {
            $popupModes = ($popupHere | ForEach-Object { $_.mode } | Sort-Object -Unique) -join ', '
            $vbsActions.Add('')
            $vbsActions.Add("' POPUP REMINDER: $($popupHere.Count) probe(s) observed a wnd[1] popup at this step (modes: $popupModes).")
            $vbsActions.Add("' TODO (human review): decide dismiss / accept / abort logic for the popup.")
            $vbsActions.Add('If IsPopupOpen(oSess) Then')
            $vbsActions.Add("    ' default: dismiss with Continue (wnd[1]/tbar[0]/btn[0]); adjust if needed")
            $vbsActions.Add('    oSess.findById("wnd[1]/tbar[0]/btn[0]").press')
            $vbsActions.Add('    WScript.Sleep 500')
            $vbsActions.Add('End If')
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

# Param-hint for argument-hint
$allParams = $report.touchpoints | Where-Object class -eq 'parameter' | ForEach-Object {
    ($_.token -replace '%%','')
} | Sort-Object -Unique
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
