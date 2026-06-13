# sap-dev shared logging helper
# Tiny wrapper around sap_log_lib.ps1 that persists the run state to a JSON
# file between skill steps, so a Claude-driven skill made of multiple bash
# blocks can append to one logical run.
#
# Usage:
#   sap_log_helper.ps1 -Action start -StateFile <path> -Skill <name> [-ParamsJson '{"k":"v"}']
#   sap_log_helper.ps1 -Action step  -StateFile <path> -Step <name> -Message <msg> [-Level INFO|WARN|ERROR]
#   sap_log_helper.ps1 -Action end   -StateFile <path> [-Status SUCCESS|FAILED|SKIPPED|EXISTED|ABANDONED] [-ExitCode 0] [-ErrorClass <code>] [-ErrorMsg <text>] [-MetricsJson '{"gate":"ATC","verdict":"PASS","p1":0}']
#
# -MetricsJson (end only): a compact JSON object of build-KPI fields. It is
# parsed and merged into the JSONL end record via Stop-SapLog -Extra, so the
# offline aggregator (sap_build_kpi.ps1) can reconstruct first-pass-yield KPIs
# from the logs alone. The only required key is `gate`. Best-effort: malformed
# or absent JSON never changes the run's status or exit code. Contract:
# shared/rules/build_metrics.md.
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
    [string]$ErrorMsg,
    [string]$MetricsJson
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

# Running plugin version (cache- vs repo-aware): read from the plugin.json two
# levels up from shared/scripts (= the sap-dev-core plugin root). When the skill
# runs from the marketplace cache, $PSScriptRoot is the cache path, so this
# returns the cache's version (the version that actually generated the code) --
# NOT the repo version, which diverges in the --plugin-dir dev loop. Build-KPI
# rows stamp this so trends are attributable to a release. Best-effort: '' on
# any failure. See shared/rules/build_metrics.md section 4.
function Get-RunningPluginVersion {
    try {
        $pluginRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $manifest   = Join-Path $pluginRoot '.claude-plugin\plugin.json'
        if (Test-Path -LiteralPath $manifest) {
            $j = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.version) { return [string]$j.version }
        }
    } catch { }
    return ''
}

switch ($Action) {

    'start' {
        if (-not $Skill) { Write-Host "log_helper: -Skill is required for 'start'"; exit 0 }

        # Orphan guard: a leftover state file means a previous run's 'end' was
        # never called. Close that orphan as ABANDONED now (it writes to its own
        # start-date log file) so a later 'end' can't silently close it as a
        # bogus SUCCESS. Skip probe state files that intentionally persist a
        # summary (observed/scenario_type) -- the 'end' action keeps those on
        # purpose for the scaffolder and they were already closed.
        if (Test-Path -LiteralPath $StateFile) {
            try {
                $rawState  = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                $probeKept = $rawState -and ($rawState -match '"observed"' -or $rawState -match '"scenario_type"')
                if (-not $probeKept) {
                    $orphan = Load-State -Path $StateFile
                    if ($orphan) {
                        Stop-SapLog -Run $orphan -Status ABANDONED -Extra @{ stale_state = $true; closed_by = 'start-eviction' }
                        Write-Host "log_helper: closed orphaned run_id=$($orphan.RunId) as ABANDONED (previous run had no end)"
                    }
                }
            } catch { }
        }

        $params = @{}
        if ($ParamsJson) {
            try {
                $obj = $ParamsJson | ConvertFrom-Json
                if ($obj) {
                    $obj.PSObject.Properties | ForEach-Object { $params[$_.Name] = $_.Value }
                }
            } catch { }
        }
        # Stamp the running plugin version into every start record so build-KPI
        # rows can attribute first-pass-yield trends to a plugin release.
        if (-not $params.ContainsKey('plugin_version')) {
            $pv = Get-RunningPluginVersion
            if ($pv) { $params['plugin_version'] = $pv }
        }
        # Resolve the active-connection banner BEFORE writing the start record so
        # the SAP system identity (SID_client) can be stamped into params for
        # build-KPI per-system grouping. Reuses the banner's own cached profile
        # ($script:_SapBannerCache) -- no extra connection lookup. Best-effort:
        # any failure here never blocks the start.
        $bannerLine = ''
        try {
            $connLib = Join-Path $PSScriptRoot 'sap_connection_lib.ps1'
            if (Test-Path -LiteralPath $connLib) {
                . $connLib
                $bannerLine = Format-SapBannerLine
                if (-not $params.ContainsKey('system_id') -and $script:_SapBannerCache) {
                    $prof = $script:_SapBannerCache
                    $sid = "$($prof.system_name)"
                    $cli = "$($prof.client)"
                    if ($sid -or $cli) { $params['system_id'] = ($sid + '_' + $cli).ToLower() }
                }
            }
        } catch { }
        try {
            $run = Start-SapLog -Skill $Skill -Params $params
            Save-State -Run $run -Path $StateFile
            Write-Host "log_helper: started run_id=$($run.RunId) parent=$($run.ParentRunId)"
        } catch {
            Write-Host "log_helper: start failed: $($_.Exception.Message)"
        }
        # Emit the banner line resolved above (best-effort): every sap-* skill
        # output starts with "which system am I hitting?".
        if ($bannerLine) { Write-Host "INFO: $bannerLine" }
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
            # Parse -MetricsJson (build-KPI gate payload) into a hashtable and
            # merge it onto the end record via -Extra. Best-effort: bad JSON is
            # ignored and the end record is still written with status/exit only.
            $extra = $null
            if ($MetricsJson) {
                try {
                    $mo = $MetricsJson | ConvertFrom-Json
                    if ($mo) {
                        $extra = @{}
                        $mo.PSObject.Properties | ForEach-Object { $extra[$_.Name] = $_.Value }
                    }
                } catch { }
            }
            if ($extra -and $extra.Count -gt 0) {
                Stop-SapLog -Run $run -Status $Status -ExitCode $ExitCode -ErrorClass $ErrorClass -ErrorObject $errObj -Extra $extra
            } else {
                Stop-SapLog -Run $run -Status $Status -ExitCode $ExitCode -ErrorClass $ErrorClass -ErrorObject $errObj
            }
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
