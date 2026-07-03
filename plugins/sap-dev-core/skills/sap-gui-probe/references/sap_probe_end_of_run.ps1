# =============================================================================
# sap_probe_end_of_run.ps1
# -----------------------------------------------------------------------------
# End-of-run aggregator for the sap-gui-probe skill (SKILL.md Step 4b).
#
# Walks every step_NN_post.json in the run folder (excluding the cleanup
# step_99), aggregates sbar/popup observations, and merges the result into the
# run state file (sap_gui_probe_run.json) as the "observed" and
# "scenario_type" keys.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sap_probe_end_of_run.ps1 `
#       -RunFolder    <abs-path>
#       -ScenarioType <type>      # success | not_found | auth_error |
#                                 # popup_recovery | validation_error
#       [-Aborted     <bool>]     # $false (default) or $true
#
# Always exits 0 -- must never block the probe's own exit path.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunFolder,
    [Parameter(Mandatory)][string]$ScenarioType,
    [bool]$Aborted = $false
)

$ErrorActionPreference = 'Continue'

try {

    if (-not (Test-Path -LiteralPath $RunFolder)) {
        Write-Host "probe_end_of_run: RunFolder not found: $RunFolder (nothing to aggregate)"
        exit 0
    }

    # --- Collect post-action sidecars (exclude step_99 cleanup) ----------------
    $postFiles = Get-ChildItem -Path $RunFolder -Filter 'step_*_post.json' -File |
                 Where-Object { $_.Name -notmatch '^step_99_' } |
                 Sort-Object Name

    $finalMsgType   = ''
    $finalSbarText  = ''
    $completedSteps = 0
    $popupsSeen     = [System.Collections.Generic.List[object]]::new()
    $popupSet       = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($file in $postFiles) {
        $rec = $null
        try {
            $rec = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            continue   # skip malformed sidecars
        }
        if ($null -eq $rec) { continue }

        # Count steps that carry a numeric step number (excludes reset/pre steps).
        if ($null -ne $rec.step) {
            $completedSteps++
        }

        # Track the last observed sbar state.
        $finalMsgType  = "$($rec.message_type)"
        $finalSbarText = "$($rec.sbar_text)"

        # Collect distinct popup (program, screen) pairs.
        if ($rec.popup_present -eq $true) {
            $prog = "$($rec.popup_program)"
            $scrn = "$($rec.popup_screen)"
            $key  = "${prog}:${scrn}"
            if ($popupSet.Add($key)) {
                $popupsSeen.Add([pscustomobject]@{ program = $prog; screen = $scrn })
            }
        }
    }

    # --- Read existing run state file ------------------------------------------
    $stateFile = Join-Path $RunFolder 'sap_gui_probe_run.json'
    $state = $null
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $state = $null
        }
    }
    if ($null -eq $state) {
        $state = [pscustomobject]@{ skill = 'sap-gui-probe' }
    }

    # --- Build observed object --------------------------------------------------
    $observed = [pscustomobject]@{
        final_message_type = $finalMsgType
        final_sbar_text    = $finalSbarText
        popups_seen        = @($popupsSeen)
        noops              = @()
        completed_steps    = $completedSteps
        aborted            = $Aborted
    }

    # Merge scenario_type + observed into state (overwrite on re-run -- idempotent).
    $state | Add-Member -NotePropertyName 'scenario_type' -NotePropertyValue $ScenarioType -Force
    $state | Add-Member -NotePropertyName 'observed'      -NotePropertyValue $observed     -Force

    # --- Write back (UTF-8 no BOM) ----------------------------------------------
    $json = $state | ConvertTo-Json -Depth 5 -Compress
    [System.IO.File]::WriteAllText($stateFile, $json, [System.Text.UTF8Encoding]::new($false))

    Write-Host "probe_end_of_run: wrote scenario_type=$ScenarioType observed{completed_steps=$completedSteps popups=$($popupsSeen.Count) aborted=$Aborted} -> $stateFile"

} catch {
    Write-Host "probe_end_of_run: unexpected error: $($_.Exception.Message)"
}

exit 0
