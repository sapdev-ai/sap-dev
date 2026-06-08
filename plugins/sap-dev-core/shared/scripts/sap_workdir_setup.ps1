# =============================================================================
# sap_workdir_setup.ps1 -- work_dir onboarding helper for /sap-login and
# /sap-dev-init. Centralizes the probe / set / migrate logic so the skills'
# Step 0 stays declarative. See shared/rules/work_dir_onboarding.md.
# =============================================================================
# Actions:
#   probe                          Report current resolution + first-run signals.
#   set     -WorkDir <path>        Persist SAPDEV_AI_WORK_DIR (User scope) AND
#                                  the %APPDATA%\sapdev-ai\work_dir.txt pointer.
#                                  The caller MUST have the user's consent first
#                                  (setting a persistent env var is a standing
#                                  config change). Non-destructive; creates
#                                  {work_dir}\runtime.
#   pin     -WorkDir <path>        Write ONLY the durable pointer (no env var).
#                                  Idempotent (skips if already that value). Used
#                                  by onboarding to make an already-resolved
#                                  non-default work_dir durable + session-bridging
#                                  WITHOUT the consent-gated env-var write.
#   migrate -From <old> -To <new>  Copy connections.json + userconfig.json
#                                  old->new (non-destructive: never deletes the
#                                  source, never overwrites an existing target;
#                                  logs/caches are left at the old path).
#
# Output is KEY=VALUE lines on stdout, one per line, for easy parsing by the
# skill. Errors go to stderr + a final ERROR=... line (exit 2).
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('probe', 'set', 'pin', 'migrate')] [string] $Action,
    [string] $WorkDir,
    [string] $From,
    [string] $To
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sap_settings_lib.ps1')
. (Join-Path $PSScriptRoot 'sap_connection_lib.ps1')

function Out-KV { param([string]$k, $v) Write-Output ("$k=$v") }
function Clean-Path { param([string]$p) return ($p.Trim().Trim('"').TrimEnd('\')) }

try {
    switch ($Action) {
        'probe' {
            $wd = Get-SapWorkDir
            $runtime = [System.IO.Path]::Combine($wd, 'runtime')
            $ptr = Get-SapWorkDirPointerPath
            $ptrVal = Read-SapWorkDirPointer
            Out-KV 'WORK_DIR'          $wd
            Out-KV 'ENV_SET'           ([bool](-not [string]::IsNullOrWhiteSpace($env:SAPDEV_AI_WORK_DIR)))
            Out-KV 'ENV_VALUE'         ($env:SAPDEV_AI_WORK_DIR)
            Out-KV 'POINTER_PATH'      $ptr
            Out-KV 'POINTER_EXISTS'    ([bool](-not [string]::IsNullOrWhiteSpace($ptrVal)))
            Out-KV 'POINTER_VALUE'     $ptrVal
            Out-KV 'STORE_EXISTS'      ([bool](Test-Path ([System.IO.Path]::Combine($runtime, 'connections.json'))))
            Out-KV 'USERCONFIG_EXISTS' ([bool](Test-Path ([System.IO.Path]::Combine($runtime, 'userconfig.json'))))
            Out-KV 'OK' 'True'
        }
        'set' {
            if ([string]::IsNullOrWhiteSpace($WorkDir)) { throw "set requires -WorkDir" }
            $wd = Clean-Path $WorkDir
            # Validate we can create the runtime dir (catch a bad path early).
            $runtime = [System.IO.Path]::Combine($wd, 'runtime')
            if (-not (Test-Path $runtime)) { New-Item -ItemType Directory -Force -Path $runtime | Out-Null }
            # Persist at User scope (durable across plugin updates). Takes effect
            # for NEW processes only -- already-running processes (this AI host +
            # every sibling subprocess) never inherit a freshly-set User env var.
            [Environment]::SetEnvironmentVariable('SAPDEV_AI_WORK_DIR', $wd, 'User')
            # Mirror to the durable out-of-cache pointer file. This is what bridges
            # the CURRENT session across skills: every later sibling subprocess
            # reads %APPDATA%\sapdev-ai\work_dir.txt fresh (the env-var prefix only
            # bridges within one skill run). Also survives plugin updates, unlike a
            # value written into the versioned-cache settings.json.
            $ptr = Get-SapWorkDirPointerPath
            $ptrOk = $false
            if ($ptr) {
                try {
                    $ptrDir = [System.IO.Path]::GetDirectoryName($ptr)
                    if (-not (Test-Path $ptrDir)) { New-Item -ItemType Directory -Force -Path $ptrDir | Out-Null }
                    # UTF-8 NO BOM, no trailing newline -- read back by Read-SapWorkDirPointer.
                    [System.IO.File]::WriteAllText($ptr, $wd, (New-Object System.Text.UTF8Encoding($false)))
                    $ptrOk = $true
                } catch {
                    [Console]::Error.WriteLine("WARN: could not write work_dir pointer ${ptr}: $($_.Exception.Message)")
                }
            }
            Out-KV 'SET_OK'      'True'
            Out-KV 'WORK_DIR'    $wd
            Out-KV 'POINTER'     $ptr
            Out-KV 'POINTER_SET' ([bool]$ptrOk)
        }
        'pin' {
            # Pointer-only write -- NO env var. Makes an already-resolved work_dir
            # durable (survives plugin updates) + session-bridging (read fresh by
            # every sibling subprocess) without the consent-gated User env-var
            # write. Idempotent: a no-op when the pointer already holds this value.
            if ([string]::IsNullOrWhiteSpace($WorkDir)) { throw "pin requires -WorkDir" }
            $wd = Clean-Path $WorkDir
            $ptr = Get-SapWorkDirPointerPath
            if (-not $ptr) { throw "pin: cannot resolve %APPDATA% pointer path (APPDATA unset)" }
            $already = ((Read-SapWorkDirPointer) -ieq $wd)
            if (-not $already) {
                $ptrDir = [System.IO.Path]::GetDirectoryName($ptr)
                if (-not (Test-Path $ptrDir)) { New-Item -ItemType Directory -Force -Path $ptrDir | Out-Null }
                # UTF-8 NO BOM, no trailing newline -- read back by Read-SapWorkDirPointer.
                [System.IO.File]::WriteAllText($ptr, $wd, (New-Object System.Text.UTF8Encoding($false)))
            }
            Out-KV 'PIN_OK'   'True'
            Out-KV 'WORK_DIR' $wd
            Out-KV 'POINTER'  $ptr
            Out-KV 'ALREADY'  ([bool]$already)
        }
        'migrate' {
            if ([string]::IsNullOrWhiteSpace($From)) { throw "migrate requires -From" }
            if ([string]::IsNullOrWhiteSpace($To))   { throw "migrate requires -To" }
            $src = Clean-Path $From
            $dst = Clean-Path $To
            if ($src -ieq $dst) { Out-KV 'COPIED' ''; Out-KV 'NOTE' 'from==to, nothing to do'; Out-KV 'OK' 'True'; break }
            $dstRuntime = [System.IO.Path]::Combine($dst, 'runtime')
            if (-not (Test-Path $dstRuntime)) { New-Item -ItemType Directory -Force -Path $dstRuntime | Out-Null }
            $copied = @(); $skipped = @(); $missing = @()
            foreach ($name in @('connections.json', 'userconfig.json')) {
                $s = [System.IO.Path]::Combine($src, 'runtime', $name)
                $d = [System.IO.Path]::Combine($dstRuntime, $name)
                if (-not (Test-Path $s))      { $missing += $name; continue }
                if (Test-Path $d)             { $skipped += $name; continue }  # never overwrite
                Copy-Item -LiteralPath $s -Destination $d -Force
                $copied += $name
            }
            Out-KV 'COPIED'  ($copied  -join ',')
            Out-KV 'SKIPPED' ($skipped -join ',')   # already present at target -- left as-is
            Out-KV 'MISSING' ($missing -join ',')   # not present at source
            Out-KV 'FROM' $src
            Out-KV 'TO'   $dst
            Out-KV 'OK' 'True'
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    Out-KV 'ERROR' ($_.Exception.Message -replace "`r?`n", ' ')
    exit 2
}
