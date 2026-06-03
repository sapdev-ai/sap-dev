# =============================================================================
# sap_log_lib.ps1  -  Shared JSONL logging helpers for sap-dev skills
#
# Dot-source this file at the top of any PS1 skill wrapper:
#
#   . "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_lib.ps1"
#   $run = Start-SapLog -Skill 'sap-se11' -Params @{object_type='DOMAIN'; object_name='ZHKDM_X'}
#   try {
#       Write-SapLog -Run $run -Level INFO -Step 'create' -Message 'Saving...'
#       # ...skill body...
#       Stop-SapLog -Run $run -Status SUCCESS -ExitCode 0
#   } catch {
#       Stop-SapLog -Run $run -Status FAILED -ExitCode 1 -ErrorObject $_
#       throw
#   }
#
# Records are appended one JSON object per line to:
#   {log_dir}\{log_file_pattern}     (defaults: {work_dir}\logs\sap-dev-{YYYYMMDD}.log)
#
# Settings consumed from sap-dev-core/settings.json (userConfig):
#   log_enabled, log_level, log_dir, log_file_pattern, log_retention_days
#
# Run-ID propagation:
#   - Generated once per Start-SapLog
#   - Exported via $env:SAPDEV_RUN_ID and $env:SAPDEV_PARENT_RUN_ID so that
#     child PS1 / VBS invocations can chain into the call tree.
# =============================================================================

$script:SapLogSettings = $null
$script:SapLogLevels   = @{ DEBUG = 10; INFO = 20; WARN = 30; ERROR = 40; OFF = 99 }

function Get-SapLogSettings {
    if ($null -ne $script:SapLogSettings) { return $script:SapLogSettings }

    # Settings read merges settings.json + settings.local.json — see
    # sap_settings_lib.ps1. This script lives at
    # <root>\plugins\sap-dev-core\shared\scripts\sap_log_lib.ps1
    $settingsLib = Join-Path $PSScriptRoot 'sap_settings_lib.ps1'
    if (Test-Path $settingsLib) { . $settingsLib }

    $cfg = @{
        Enabled       = $true
        Level         = 'INFO'
        LevelNum      = 20
        Dir           = ''
        Pattern       = 'sap-dev-{YYYYMMDD}.log'
        RetentionDays = 30
        Format        = 'JSONL'
        ConsoleEcho   = $false
        MaxSizeMB     = 10
        MaxBackups    = 5
        StaleRunHours = 12
        RedactKeys    = @('sap_password','password','passwd','pwd','token','secret','api_key')
    }

    if (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue) {
        try {
            $workDir = Get-SapSettingValue 'work_dir' 'C:\sap_dev_work'

            $v = Get-SapSettingValue 'log_enabled' ''
            if ($v) { $cfg.Enabled = $v.ToLower() -eq 'true' }

            $v = Get-SapSettingValue 'log_level' ''
            if ($v) {
                $cfg.Level = $v.ToUpper()
                if ($script:SapLogLevels.ContainsKey($cfg.Level)) {
                    $cfg.LevelNum = $script:SapLogLevels[$cfg.Level]
                }
            }

            $v = Get-SapSettingValue 'log_dir' ''
            if ($v) { $cfg.Dir = $v } else { $cfg.Dir = Join-Path $workDir 'logs' }

            $v = Get-SapSettingValue 'log_file_pattern' ''
            if ($v) { $cfg.Pattern = $v }

            $v = Get-SapSettingValue 'log_retention_days' ''
            if ($v) { $n = 0; if ([int]::TryParse($v, [ref]$n)) { $cfg.RetentionDays = $n } }

            $v = Get-SapSettingValue 'log_format' ''
            if ($v) {
                $f = $v.ToUpper()
                if ($f -in 'JSONL','TSV','TEXT') { $cfg.Format = $f }
            }

            $v = Get-SapSettingValue 'log_console_echo' ''
            if ($v) { $cfg.ConsoleEcho = $v.ToLower() -eq 'true' }

            $v = Get-SapSettingValue 'log_max_size_mb' ''
            if ($v) { $n = 0; if ([int]::TryParse($v, [ref]$n)) { $cfg.MaxSizeMB = $n } }

            $v = Get-SapSettingValue 'log_max_backups' ''
            if ($v) { $n = 0; if ([int]::TryParse($v, [ref]$n)) { $cfg.MaxBackups = $n } }

            $v = Get-SapSettingValue 'log_stale_run_hours' ''
            if ($v) { $d = 0.0; if ([double]::TryParse($v, [ref]$d)) { $cfg.StaleRunHours = $d } }

            $v = Get-SapSettingValue 'log_redact_keys' ''
            if ($v) {
                $cfg.RedactKeys = @($v.Split(',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
            }
        } catch {
            # Fall back to defaults silently — logging must never break a skill.
            $cfg.Dir = 'C:\sap_dev_work\logs'
        }
    } else {
        $cfg.Dir = 'C:\sap_dev_work\logs'
    }

    $script:SapLogSettings = $cfg
    return $cfg
}

function Resolve-SapLogPath {
    param(
        [string]$Skill,
        [string]$RunId = ''
    )
    $cfg = Get-SapLogSettings
    if (-not (Test-Path $cfg.Dir)) {
        try { New-Item -ItemType Directory -Path $cfg.Dir -Force | Out-Null } catch {}
    }
    $now  = Get-Date
    $name = $cfg.Pattern
    # Date / time placeholders -- {HHMMSS} gives per-second uniqueness so a
    # pattern like 'sap-dev-{YYYYMMDD}-{HHMMSS}-{SKILL}.log' produces one
    # file per skill invocation. {RUN_ID} is the unique GUID assigned at
    # Start-SapLog; use it for absolute uniqueness even if two skills fire
    # in the same second.
    $name = $name.Replace('{YYYYMMDD}', $now.ToString('yyyyMMdd'))
    $name = $name.Replace('{YYYYMM}',   $now.ToString('yyyyMM'))
    $name = $name.Replace('{HHMMSS}',   $now.ToString('HHmmss'))
    $name = $name.Replace('{HHMM}',     $now.ToString('HHmm'))
    $name = $name.Replace('{RUN_ID}',   ($RunId   -replace '[^A-Za-z0-9_\-]', '_'))
    $name = $name.Replace('{SKILL}',    ($Skill   -replace '[^A-Za-z0-9_\-]', '_'))
    $name = $name.Replace('{USER}',     ($env:USERNAME -replace '[^A-Za-z0-9_\-]', '_'))
    $name = $name.Replace('{SYSTEM}',   ($env:COMPUTERNAME -replace '[^A-Za-z0-9_\-]', '_'))
    return Join-Path $cfg.Dir $name
}

function ConvertTo-SapLogJson {
    param([hashtable]$Record)
    return ($Record | ConvertTo-Json -Compress -Depth 10)
}

# Mask values for any key whose name (case-insensitive) matches a redact entry.
# Operates in-place on the passed-in OrderedDictionary / Hashtable.
function Invoke-SapLogRedact {
    param($Record)
    $cfg = Get-SapLogSettings
    if (-not $cfg.RedactKeys -or $cfg.RedactKeys.Count -eq 0) { return $Record }
    $redact = @{}
    foreach ($k in $cfg.RedactKeys) { $redact[$k.ToLower()] = $true }

    $keys = @($Record.Keys)
    foreach ($k in $keys) {
        $lk = $k.ToLower()
        $v  = $Record[$k]
        if ($redact.ContainsKey($lk)) {
            if ($null -ne $v -and "$v".Length -gt 0) { $Record[$k] = '***' } else { $Record[$k] = '' }
        } elseif ($v -is [hashtable] -or $v -is [System.Collections.Specialized.OrderedDictionary]) {
            Invoke-SapLogRedact -Record $v
        }
    }
    return $Record
}

function Format-SapLogTsv {
    param($Record)
    # Fixed column order; missing fields become empty. Extra fields collapsed into 'extra' JSON column.
    $cols = 'ts','run_id','parent_run_id','skill','phase','level','status','step','exit_code','duration_ms','error_class','msg','error_msg','params'
    $out = @()
    foreach ($c in $cols) {
        $v = if ($Record.Contains($c)) { $Record[$c] } else { '' }
        if ($v -is [hashtable] -or $v -is [System.Collections.Specialized.OrderedDictionary]) {
            $v = ($v | ConvertTo-Json -Compress -Depth 10)
        }
        # Strip control chars that would break TSV
        $s = ("$v" -replace "[`t`r`n]", ' ')
        $out += $s
    }
    return ($out -join "`t")
}

function Format-SapLogText {
    param($Record)
    $ts     = $Record['ts']
    $lvl    = ('{0,-5}' -f $Record['level'])
    $skill  = $Record['skill']
    $phase  = $Record['phase']
    $rid    = $Record['run_id']
    $tail   = ''
    switch ($phase) {
        'start' {
            $p = if ($Record.Contains('params')) { ($Record['params'] | ConvertTo-Json -Compress -Depth 5) } else { '{}' }
            $tail = "START params=$p"
        }
        'step'  {
            $tail = "[$($Record['step'])] $($Record['msg'])"
        }
        'end'   {
            $tail = "END status=$($Record['status']) exit=$($Record['exit_code']) duration_ms=$($Record['duration_ms'])"
            if ($Record.Contains('error_class')) { $tail += " error_class=$($Record['error_class'])" }
            if ($Record.Contains('error_msg'))   { $tail += " error_msg=" + ($Record['error_msg'] -replace "[`r`n]+", ' / ') }
        }
    }
    return "$ts $lvl $skill[$rid] $tail"
}

function Format-SapLogTsvHeader {
    return "ts`trun_id`tparent_run_id`tskill`tphase`tlevel`tstatus`tstep`texit_code`tduration_ms`terror_class`tmsg`terror_msg`tparams"
}

function Invoke-SapLogRotate {
    param([string]$Path)
    $cfg = Get-SapLogSettings
    if ($cfg.MaxSizeMB -le 0) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $sz = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length
    if ($null -eq $sz -or $sz -lt ($cfg.MaxSizeMB * 1MB)) { return }

    try {
        # Shift backups: .N-1 -> .N, ..., active -> .1; trim oldest.
        for ($i = $cfg.MaxBackups; $i -ge 1; $i--) {
            $src = "$Path.$($i-1)"
            $dst = "$Path.$i"
            if ($i -eq 1) { $src = $Path }
            if (Test-Path -LiteralPath $src) {
                if ($i -eq $cfg.MaxBackups) {
                    Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

function Write-SapLogLine {
    param([string]$Path, $Record)
    $cfg = Get-SapLogSettings
    Invoke-SapLogRedact -Record $Record | Out-Null

    $line = switch ($cfg.Format) {
        'TSV'  { Format-SapLogTsv  -Record $Record }
        'TEXT' { Format-SapLogText -Record $Record }
        default { ConvertTo-SapLogJson -Record $Record }
    }

    Invoke-SapLogRotate -Path $Path

    # TSV header on first write of a new file
    if ($cfg.Format -eq 'TSV' -and -not (Test-Path -LiteralPath $Path)) {
        $enc = New-Object System.Text.UTF8Encoding($false)
        try { [System.IO.File]::AppendAllText($Path, (Format-SapLogTsvHeader) + "`r`n", $enc) } catch {}
    }

    $enc = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::AppendAllText($Path, $line + "`r`n", $enc)
    } catch {
        try { Add-Content -Path $Path -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    }

    if ($cfg.ConsoleEcho) {
        $lvl = $Record['level']
        if ($lvl -eq 'ERROR' -or $lvl -eq 'WARN') {
            [Console]::Error.WriteLine($line)
        } else {
            [Console]::Out.WriteLine($line)
        }
    }
}

function Start-SapLog {
    param(
        [Parameter(Mandatory)][string]$Skill,
        [hashtable]$Params = @{},
        [string]$RunId,
        [string]$ParentRunId
    )
    $cfg = Get-SapLogSettings
    if (-not $RunId) {
        if ($env:SAPDEV_RUN_ID) {
            # If a parent already started a log, treat its run_id as our parent
            $ParentRunId = $env:SAPDEV_RUN_ID
        }
        $RunId = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    }

    $run = [pscustomobject]@{
        Skill        = $Skill
        RunId        = $RunId
        ParentRunId  = $ParentRunId
        StartTime    = Get-Date
        Path         = Resolve-SapLogPath -Skill $Skill -RunId $RunId
        Enabled      = $cfg.Enabled
        LevelNum     = $cfg.LevelNum
        Params       = $Params
    }

    # Propagate to children
    $env:SAPDEV_PARENT_RUN_ID = $ParentRunId
    $env:SAPDEV_RUN_ID        = $RunId

    if (-not $cfg.Enabled) { return $run }
    if ($script:SapLogLevels['INFO'] -lt $cfg.LevelNum) { return $run }  # OFF

    $rec = [ordered]@{
        ts            = $run.StartTime.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        run_id        = $RunId
        parent_run_id = $ParentRunId
        skill         = $Skill
        phase         = 'start'
        level         = 'INFO'
        host          = $env:COMPUTERNAME
        os_user       = $env:USERNAME
        params        = $Params
    }
    Write-SapLogLine -Path $run.Path -Record $rec

    # Cheap retention sweep (1-in-50 chance per run)
    if ($cfg.RetentionDays -gt 0 -and (Get-Random -Maximum 50) -eq 0) {
        Invoke-SapLogRetention -Days $cfg.RetentionDays
    }
    return $run
}

function Write-SapLog {
    param(
        [Parameter(Mandatory)]$Run,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$Level = 'INFO',
        [string]$Step,
        [string]$Message,
        [hashtable]$Extra
    )
    if (-not $Run -or -not $Run.Enabled) { return }
    $thr = $script:SapLogLevels[$Level]
    if ($thr -lt $Run.LevelNum) { return }

    $rec = [ordered]@{
        ts            = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        run_id        = $Run.RunId
        parent_run_id = $Run.ParentRunId
        skill         = $Run.Skill
        phase         = 'step'
        level         = $Level
        step          = $Step
        msg           = $Message
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $rec[$k] = $Extra[$k] } }
    Write-SapLogLine -Path $Run.Path -Record $rec
}

function Stop-SapLog {
    param(
        [Parameter(Mandatory)]$Run,
        [ValidateSet('SUCCESS','FAILED','SKIPPED','EXISTED','ABANDONED','TEST_FIXED','TEST_FAILED_MODES','SUCCESS_WITH_DIRTY_FIXTURES','ABORTED_BUDGET')][string]$Status = 'SUCCESS',
        [int]$ExitCode = 0,
        [string]$ErrorClass,
        $ErrorObject,
        [hashtable]$Extra
    )
    if (-not $Run) { return }
    # Always pop the run-id env vars regardless of Enabled
    if ($env:SAPDEV_RUN_ID -eq $Run.RunId) {
        $env:SAPDEV_RUN_ID = $Run.ParentRunId
    }
    if (-not $Run.Enabled) { return }

    $endTime = Get-Date

    # Stale-run guard: a run whose start is older than the configured threshold
    # almost certainly had its 'end' skipped when the work actually finished —
    # the per-skill state file was orphaned and is only being closed now by a
    # later invocation. Reporting that as the caller's requested SUCCESS would
    # stamp a bogus multi-day duration onto the run's START-date log file (the
    # filename is pinned at start). Demote success-like statuses to ABANDONED
    # and flag the record so log analysis (and humans) aren't misled.
    $reqStatus = $Status
    $elapsedH  = ($endTime - $Run.StartTime).TotalHours
    $cfgStale  = Get-SapLogSettings
    $isStale   = ($cfgStale.StaleRunHours -gt 0 -and $elapsedH -gt $cfgStale.StaleRunHours)
    if ($isStale -and ($Status -eq 'SUCCESS' -or $Status -eq 'EXISTED' -or $Status -eq 'SKIPPED')) {
        $Status = 'ABANDONED'
    }

    $level = if ($Status -eq 'SUCCESS' -or $Status -eq 'EXISTED' -or $Status -eq 'SKIPPED') { 'INFO' } else { 'ERROR' }
    if ($script:SapLogLevels[$level] -lt $Run.LevelNum) { return }

    $rec = [ordered]@{
        ts            = $endTime.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        run_id        = $Run.RunId
        parent_run_id = $Run.ParentRunId
        skill         = $Run.Skill
        phase         = 'end'
        level         = $level
        status        = $Status
        exit_code     = $ExitCode
        duration_ms   = [long]($endTime - $Run.StartTime).TotalMilliseconds
    }
    if ($isStale) {
        $rec.stale_state = $true
        $rec.stale_hours = [math]::Round($elapsedH, 1)
        if ($reqStatus -ne $Status) { $rec.requested_status = $reqStatus }
    }
    if ($ErrorClass)  { $rec.error_class = $ErrorClass }
    if ($ErrorObject) {
        $rec.error_msg = ($ErrorObject | Out-String).Trim()
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $rec[$k] = $Extra[$k] } }
    Write-SapLogLine -Path $Run.Path -Record $rec
}

function Invoke-SapLogRetention {
    param([int]$Days)
    $cfg = Get-SapLogSettings
    if ($Days -le 0 -or -not (Test-Path $cfg.Dir)) { return }
    $cutoff = (Get-Date).AddDays(-$Days)
    try {
        Get-ChildItem -Path $cfg.Dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Extension -eq '.log' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
}
