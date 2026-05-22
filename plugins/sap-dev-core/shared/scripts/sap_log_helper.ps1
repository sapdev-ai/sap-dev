# sap-dev shared logging helper
# Tiny wrapper around sap_log_lib.ps1 that persists the run state to a JSON
# file between skill steps, so a Claude-driven skill made of multiple bash
# blocks can append to one logical run.
#
# Usage:
#   sap_log_helper.ps1 -Action start -StateFile <path> -Skill <name> [-ParamsJson '{"k":"v"}']
#   sap_log_helper.ps1 -Action step  -StateFile <path> -Step <name> -Message <msg> [-Level INFO|WARN|ERROR]
#   sap_log_helper.ps1 -Action end   -StateFile <path> [-Status SUCCESS|FAILED|SKIPPED|EXISTED|ABANDONED] [-ExitCode 0] [-ErrorClass <code>] [-ErrorMsg <text>]
#
# All actions are idempotent and never throw - logging failures must not break the skill.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('start','step','end')][string]$Action,
    [Parameter(Mandatory)][string]$StateFile,
    [string]$Skill,
    [string]$ParamsJson,
    [string]$Step,
    [string]$Message,
    [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$Level = 'INFO',
    [ValidateSet('SUCCESS','FAILED','SKIPPED','EXISTED','ABANDONED','TEST_FIXED','TEST_FAILED_MODES','SUCCESS_WITH_DIRTY_FIXTURES','ABORTED_BUDGET')][string]$Status = 'SUCCESS',
    [int]$ExitCode = 0,
    [string]$ErrorClass,
    [string]$ErrorMsg
)

$ErrorActionPreference = 'Continue'

try {
    $libPath = Join-Path $PSScriptRoot 'sap_log_lib.ps1'
    . $libPath
} catch {
    # If the lib can't be loaded, silently no-op (logging is best-effort).
    Write-Host "log_helper: lib load failed: $($_.Exception.Message)"
    exit 0
}

function Save-State {
    param($Run, [string]$Path)
    $obj = [pscustomobject]@{
        Skill       = $Run.Skill
        RunId       = $Run.RunId
        ParentRunId = $Run.ParentRunId
        StartTime   = $Run.StartTime.ToString('o')
        Path        = $Run.Path
        Enabled     = $Run.Enabled
        LevelNum    = $Run.LevelNum
    }
    $obj | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Load-State {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $s = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{
        Skill       = $s.Skill
        RunId       = $s.RunId
        ParentRunId = $s.ParentRunId
        StartTime   = [datetime]$s.StartTime
        Path        = $s.Path
        Enabled     = [bool]$s.Enabled
        LevelNum    = [int]$s.LevelNum
    }
}

switch ($Action) {

    'start' {
        if (-not $Skill) { Write-Host "log_helper: -Skill is required for 'start'"; exit 0 }
        $params = @{}
        if ($ParamsJson) {
            try {
                $obj = $ParamsJson | ConvertFrom-Json
                if ($obj) {
                    $obj.PSObject.Properties | ForEach-Object { $params[$_.Name] = $_.Value }
                }
            } catch { }
        }
        try {
            $run = Start-SapLog -Skill $Skill -Params $params
            Save-State -Run $run -Path $StateFile
            Write-Host "log_helper: started run_id=$($run.RunId) parent=$($run.ParentRunId)"
        } catch {
            Write-Host "log_helper: start failed: $($_.Exception.Message)"
        }
        # Banner: emit one line summarising the currently pinned SAP connection
        # so every sap-* skill output starts with "which system am I hitting?".
        # Best-effort: silently no-ops on lib-load failure or when no pin exists.
        try {
            $connLib = Join-Path $PSScriptRoot 'sap_connection_lib.ps1'
            if (Test-Path -LiteralPath $connLib) {
                . $connLib
                $banner = Format-SapBannerLine
                if ($banner) { Write-Host "INFO: $banner" }
            }
        } catch { }
    }

    'step' {
        $run = Load-State -Path $StateFile
        if (-not $run) { Write-Host "log_helper: no state file at $StateFile (skipping step)"; exit 0 }
        try {
            Write-SapLog -Run $run -Level $Level -Step $Step -Message $Message
        } catch {
            Write-Host "log_helper: step failed: $($_.Exception.Message)"
        }
    }

    'end' {
        $run = Load-State -Path $StateFile
        if (-not $run) { Write-Host "log_helper: no state file at $StateFile (skipping end)"; exit 0 }
        try {
            $errObj = $null
            if ($ErrorMsg) { $errObj = $ErrorMsg }
            Stop-SapLog -Run $run -Status $Status -ExitCode $ExitCode -ErrorClass $ErrorClass -ErrorObject $errObj
        } catch {
            Write-Host "log_helper: end failed: $($_.Exception.Message)"
        }
        # Do NOT delete the state file when it also carries a probe end-of-run
        # summary. /sap-gui-probe Step 4b writes observed{}/scenario_type into
        # the SAME sap_gui_probe_run.json via sap_probe_end_of_run.ps1, and the
        # scaffolder's merge step reads it. Deleting here wiped that summary, so
        # the merge defaulted every probe to scenario_type=success (the
        # failure-mode catalog came out empty). Keep the file when it has been
        # augmented; transient logging-only state files are still cleaned up.
        $keepState = $false
        try {
            $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($raw -and ($raw -match '"observed"' -or $raw -match '"scenario_type"')) { $keepState = $true }
        } catch {}
        if (-not $keepState) {
            Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
        }
    }
}

exit 0
