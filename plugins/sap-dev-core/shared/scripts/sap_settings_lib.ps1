# =============================================================================
# sap_settings_lib.ps1 -- settings.json + settings.local.json merge helper.
# =============================================================================
# Two-file model:
#   settings.json         -- TRACKED, schema + descriptions + defaults
#   settings.local.json   -- GITIGNORED, per-developer values that override
#
# Read path  : merge per-key on the .value field, precedence (highest first):
#              env var SAPDEV_AI_WORK_DIR (work_dir only)
#              > settings.local.json (dev checkout override)
#              > userconfig.json (machine-global, {work_dir}\runtime)
#              > settings.json (tracked schema/defaults).
# work_dir   : special BOOTSTRAP chain (it locates userconfig.json, so it must
#              resolve WITHOUT reading userconfig.json):
#              env var SAPDEV_AI_WORK_DIR
#              > settings.local.json (dev checkout override)
#              > %APPDATA%\sapdev-ai\work_dir.txt (durable out-of-cache pointer --
#                survives plugin updates AND is read fresh by every sibling
#                subprocess, so it bridges the current AI session when a
#                freshly-set User env var hasn't propagated to running processes)
#              > settings.json (tracked schema)
#              > C:\sap_dev_work (default).
# Write path : non-per-connection writes go to userconfig.json (durable, OUTSIDE
#              the versioned plugin cache). settings.json is never mutated;
#              settings.local.json is a hand-edited dev override, never written
#              by a skill.
#
# USAGE (dot-source):
#
#     . "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1"
#     $cfg = Get-SapSettings                       # full merged object
#     $val = Get-SapSettingValue 'sap_password'    # convenience: just .value
#     Set-SapUserSetting 'sap_password' 'dpapi:...' # writes to userconfig.json
#
# Caching: the merge is cached per-process. Call Reset-SapSettingsCache to
# force a re-read (after a write, the cache is invalidated automatically).
# =============================================================================

$script:SapSettingsCache     = $null
$script:SapSettingsLocalPath = $null
$script:SapSettingsMainPath  = $null

# Cross-process serialization for userconfig.json writes. Without it, two AI
# sessions (e.g. one on S4D, one on S4H) that both Set-SapUserSetting at
# overlapping times race on a bare WriteAllText: lost update at best, a torn /
# corrupt JSON file at worst -- after which Get-SapSettings throws and every
# settings read in that session dies. Mirrors sap_connection_lib's store mutex.
$script:SapUserConfig_MutexName     = 'SapDevUserConfigStore_v1'
$script:SapUserConfig_MutexTimeoutMs = 10000

function With-SapUserConfigLock {
    param([scriptblock] $Body)
    $mutex = [System.Threading.Mutex]::new($false, $script:SapUserConfig_MutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($script:SapUserConfig_MutexTimeoutMs)
        } catch [System.Threading.AbandonedMutexException] {
            # Prior holder crashed before releasing; the on-disk file is still a
            # complete document (writes are atomic), so it is safe to continue.
            $acquired = $true
        }
        if (-not $acquired) {
            throw "sap_settings_lib: could not acquire userconfig mutex within $($script:SapUserConfig_MutexTimeoutMs)ms"
        }
        & $Body
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        try { $mutex.Dispose() } catch {}
    }
}

function Write-SapJsonAtomic {
    # Write $Json to $Path so a concurrent reader NEVER sees a torn file: write a
    # sibling temp file, then atomically swap it in via NTFS File.Replace (or Move
    # when the target doesn't exist yet). Falls back to a direct write only if the
    # atomic swap throws (different volume / AV lock). UTF-8, no BOM.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Json)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $tmp = "$Path.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $Json, $enc)
    try {
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($tmp, $Path, $null)
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } catch {
        [System.IO.File]::WriteAllText($Path, $Json, $enc)
        if (Test-Path -LiteralPath $tmp) { try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {} }
    }
}

function Resolve-SapSettingsPaths {
    if ($null -ne $script:SapSettingsMainPath) { return }
    # This script lives at <root>\plugins\sap-dev-core\shared\scripts\sap_settings_lib.ps1
    $coreRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SapSettingsMainPath  = Join-Path $coreRoot 'settings.json'
    $script:SapSettingsLocalPath = Join-Path $coreRoot 'settings.local.json'
}

function Get-SapWorkDirPointerPath {
    # Durable, out-of-cache bootstrap pointer for work_dir:
    # %APPDATA%\sapdev-ai\work_dir.txt (a single line: the work_dir path).
    #
    # It lives under the per-user roaming profile -- NOT the versioned plugin
    # cache (so it survives plugin updates) and NOT under work_dir itself (so
    # there is no circular dependency). Onboarding's `set` action writes it
    # alongside the User env var; this resolver reads it. Its job is to bridge
    # the gap a freshly-set User env var leaves: already-running processes (the
    # AI host + every sibling subprocess it spawns) never inherit a new User env
    # var, but they DO read this file fresh on every call -- so a work_dir chosen
    # mid-session resolves correctly for every later skill, durably.
    $base = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        try { $base = [Environment]::GetFolderPath('ApplicationData') } catch { $base = '' }
    }
    if ([string]::IsNullOrWhiteSpace($base)) { return $null }
    return [System.IO.Path]::Combine($base, 'sapdev-ai', 'work_dir.txt')
}

function Read-SapWorkDirPointer {
    # Returns the cleaned work_dir from the pointer file, or '' if absent/empty.
    # Tolerant of a hand-edited file (trailing newline, quotes, trailing slash).
    $ptr = Get-SapWorkDirPointerPath
    if (-not $ptr -or -not (Test-Path -LiteralPath $ptr)) { return '' }
    try {
        $raw = [System.IO.File]::ReadAllText($ptr)
        if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
        $val = (($raw -split "`r?`n")[0]).Trim().Trim('"').TrimEnd('\')
        return $val
    } catch { return '' }
}

function Read-SapWorkDirFromSettingsFile {
    # Reads userConfig.work_dir.value from one settings file, or '' if absent.
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return '' }
    try {
        $o = Get-Content -Raw $Path -Encoding UTF8 | ConvertFrom-Json
        if ($o.userConfig -and ($o.userConfig.PSObject.Properties.Name -contains 'work_dir')) {
            $v = $o.userConfig.work_dir.value
            if (-not [string]::IsNullOrWhiteSpace("$v")) { return "$v" }
        }
    } catch { }
    return ''
}

function Get-SapWorkDirBootstrap {
    # work_dir is the BOOTSTRAP pointer: it locates userconfig.json, so it must
    # be resolvable WITHOUT reading userconfig.json (otherwise infinite
    # recursion). Order (highest first):
    #   1. env var SAPDEV_AI_WORK_DIR        -- live, process-explicit
    #   2. settings.local.json               -- dev checkout override (in cache)
    #   3. %APPDATA%\sapdev-ai\work_dir.txt  -- durable out-of-cache pointer that
    #                                           ALSO bridges the current session
    #   4. settings.json                     -- tracked schema (in cache)
    #   5. C:\sap_dev_work                   -- default
    # Reads the plugin-dir files DIRECTLY (never via Get-SapSettings) so it is
    # safe to call from inside Get-SapSettings.
    if (-not [string]::IsNullOrWhiteSpace($env:SAPDEV_AI_WORK_DIR)) {
        return ($env:SAPDEV_AI_WORK_DIR.Trim()).TrimEnd('\')
    }
    Resolve-SapSettingsPaths
    # (2) dev checkout override -- most specific, wins over the machine-global pointer.
    $v = Read-SapWorkDirFromSettingsFile $script:SapSettingsLocalPath
    if (-not [string]::IsNullOrWhiteSpace($v)) { return ("$v".TrimEnd('\')) }
    # (3) durable out-of-cache pointer (survives plugin updates; bridges this session).
    $v = Read-SapWorkDirPointer
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    # (4) tracked schema.
    $v = Read-SapWorkDirFromSettingsFile $script:SapSettingsMainPath
    if (-not [string]::IsNullOrWhiteSpace($v)) { return ("$v".TrimEnd('\')) }
    return 'C:\sap_dev_work'
}

function Get-SapUserConfigPath {
    # Machine-global override file, OUTSIDE the versioned plugin cache so it
    # survives plugin updates: {work_dir}\runtime\userconfig.json.
    # Use [IO.Path]::Combine, NOT Join-Path: Join-Path throws DriveNotFound when
    # work_dir points at a drive that doesn't exist yet, which (since this is on
    # the read path via Get-SapSettings) would break every settings read.
    return [System.IO.Path]::Combine((Get-SapWorkDirBootstrap), 'runtime', 'userconfig.json')
}

function Reset-SapSettingsCache {
    $script:SapSettingsCache = $null
}

function Get-SapSettings {
    if ($null -ne $script:SapSettingsCache) { return $script:SapSettingsCache }
    Resolve-SapSettingsPaths

    $main = $null
    if (Test-Path $script:SapSettingsMainPath) {
        try {
            $main = Get-Content -Raw $script:SapSettingsMainPath -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "sap_settings_lib: failed to parse settings.json: $_"
        }
    }
    if ($null -eq $main) { $main = [pscustomobject]@{ userConfig = [pscustomobject]@{} } }
    if ($null -eq $main.userConfig) {
        $main | Add-Member -NotePropertyName userConfig -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    # Overlay userconfig.json (machine-global, under {work_dir}\runtime, OUTSIDE
    # the versioned plugin cache) BELOW settings.local.json. Precedence:
    # settings.local.json > userconfig.json > settings.json.
    $ucPath = Get-SapUserConfigPath
    if (Test-Path $ucPath) {
        $uc = $null
        try {
            $uc = Get-Content -Raw $ucPath -Encoding UTF8 | ConvertFrom-Json
        } catch {
            # userconfig.json is machine-global and mutable (hand-edited, or torn
            # by a pre-fix concurrent writer). A parse failure here must NOT brick
            # every settings read -- WARN and fall back to settings.json defaults
            # for this run. (Set-SapUserSetting now writes atomically + under a
            # mutex, so this is a legacy / external-corruption safety net.)
            [Console]::Error.WriteLine("WARN: sap_settings_lib: userconfig.json unreadable ($($_.Exception.Message)); ignoring machine-global overrides for this run.")
            $uc = $null
        }
        if ($null -ne $uc -and $null -ne $uc.userConfig) {
            foreach ($p in $uc.userConfig.PSObject.Properties) {
                $key = $p.Name
                if ($key -eq 'work_dir') { continue }  # work_dir is bootstrap-only, never from userconfig
                $ucEntry = $p.Value
                if ($null -eq $ucEntry) { continue }
                if ($main.userConfig.PSObject.Properties.Name -contains $key) {
                    if ($null -ne $ucEntry.value) { $main.userConfig.$key.value = $ucEntry.value }
                } else {
                    $main.userConfig | Add-Member -NotePropertyName $key -NotePropertyValue $ucEntry -Force
                }
            }
        }
    }

    if (Test-Path $script:SapSettingsLocalPath) {
        $local = $null
        try {
            $local = Get-Content -Raw $script:SapSettingsLocalPath -Encoding UTF8 | ConvertFrom-Json
        } catch {
            # settings.local.json is a hand-edited dev override; a typo there
            # should WARN, not abort every skill that reads a setting.
            [Console]::Error.WriteLine("WARN: sap_settings_lib: settings.local.json unreadable ($($_.Exception.Message)); ignoring dev-checkout overrides for this run.")
            $local = $null
        }
        if ($null -ne $local -and $null -ne $local.userConfig) {
            foreach ($p in $local.userConfig.PSObject.Properties) {
                $key = $p.Name
                $localEntry = $p.Value
                if ($null -eq $localEntry) { continue }
                # Only override the .value field; preserve description/sensitive from main.
                if ($main.userConfig.PSObject.Properties.Name -contains $key) {
                    if ($null -ne $localEntry.value) {
                        $main.userConfig.$key.value = $localEntry.value
                    }
                } else {
                    # Key only in local -- pass through as-is so the caller still sees it.
                    $main.userConfig | Add-Member -NotePropertyName $key -NotePropertyValue $localEntry -Force
                }
            }
        }
    }

    $script:SapSettingsCache = $main
    return $main
}

function Get-SapSettingValue {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [string] $Default = ''
    )
    # work_dir is the bootstrap pointer (it locates userconfig.json), so resolve
    # it via the dedicated bootstrap path -- honors $env:SAPDEV_AI_WORK_DIR and
    # never recurses through userconfig.json.
    if ($Key -eq 'work_dir') { return Get-SapWorkDirBootstrap }
    # Per-connection isolation (Phase 4.3): for SAP-system-specific keys
    # (TR / package / function group) the source of truth is the pinned
    # connection's dev_defaults block in connections.json, not the global
    # settings.local.json. This is the read-side routing -- Get-SapCurrentDevDefault
    # handles its own file-based fallback so this remains safe even when
    # sap_connection_lib.ps1 isn't loaded (caller gets the file value).
    if (Get-Command Get-SapPerConnectionDevKeys -ErrorAction SilentlyContinue) {
        $perConnKeys = Get-SapPerConnectionDevKeys
        if ($perConnKeys -contains $Key) {
            if (Get-Command Get-SapCurrentDevDefault -ErrorAction SilentlyContinue) {
                try {
                    $vv = Get-SapCurrentDevDefault -Key $Key
                    if (-not [string]::IsNullOrWhiteSpace("$vv")) { return "$vv" }
                } catch {
                    # Per-conn lookup failed (no pin / no store) -- fall through
                    # to the file-based read below.
                }
                # Per-conn returned empty -> fall through to global default.
                return $Default
            }
        }
    }
    $s = Get-SapSettings
    if ($s.userConfig.PSObject.Properties.Name -contains $Key) {
        $v = $s.userConfig.$Key.value
        if ($null -ne $v -and "$v" -ne '') { return [string]$v }
    }
    return $Default
}

function Set-SapUserSetting {
    <#
    .SYNOPSIS
        Persist a userConfig value. Non-per-connection writes go to
        userconfig.json (machine-global, under {work_dir}\runtime, OUTSIDE the
        versioned plugin cache so they survive plugin updates). Neither
        settings.json (schema) nor settings.local.json (dev checkout override,
        hand-edited) is mutated by a skill.
    .DESCRIPTION
        Phase 4.4: per-connection routing. When $Key is in the
        SapPerConnectionDevKeys list (TR / package / function group /
        mode / TR-workflow keys), the write is delegated to
        Set-SapCurrentDevDefault -- which targets the pinned connection's
        dev_defaults block in connections.json, falling back to
        settings.local.json only when no profile is pinned. This stops
        cross-system contamination (e.g. saving an S4D-prefixed TR value
        while pinned to S4H would otherwise leak across systems).
    .PARAMETER SkipPerConnRouting
        Internal use. Set-SapCurrentDevDefault's no-pin fallback calls back
        into Set-SapUserSetting with this switch on so the per-conn check
        is bypassed and we don't recurse forever.
    #>
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [switch] $SkipPerConnRouting,
        [ValidateSet('Connection','Session')] [string] $Scope = 'Session'
    )

    # Phase 4.4 write-path routing (per-conn keys only). DEFAULT = Session: a
    # task TR/package is scoped per (AI-session x connection), so concurrent
    # conversations on one connection don't clobber. Pass -Scope Connection for a
    # deliberate STANDING per-connection default (onboarding).
    if (-not $SkipPerConnRouting -and (Get-Command Get-SapPerConnectionDevKeys -ErrorAction SilentlyContinue)) {
        $perConnKeys = Get-SapPerConnectionDevKeys
        if ($perConnKeys -contains $Key) {
            if (Get-Command Set-SapCurrentDevDefault -ErrorAction SilentlyContinue) {
                Set-SapCurrentDevDefault -Key $Key -Value $Value -Scope $Scope
                Reset-SapSettingsCache
                return
            }
        }
    }

    # Non-per-connection writes go to userconfig.json (machine-global, under
    # {work_dir}\runtime, OUTSIDE the versioned plugin cache) so they survive
    # plugin updates and never mutate the tracked schema. settings.local.json
    # stays a hand-edited, checkout-local READ override (higher precedence) and
    # is never written by a skill.
    $ucPath = Get-SapUserConfigPath
    $ucDir  = Split-Path -Parent $ucPath
    if (-not (Test-Path $ucDir)) { New-Item -ItemType Directory -Force -Path $ucDir | Out-Null }

    # The whole read-modify-write runs under the cross-process mutex so two
    # concurrent sessions can't lose each other's update, and the swap-in is
    # atomic so a concurrent READER never sees a half-written file.
    With-SapUserConfigLock {
        $uc = $null
        if (Test-Path $ucPath) {
            try {
                $uc = Get-Content -Raw $ucPath -Encoding UTF8 | ConvertFrom-Json
            } catch {
                # Corrupt on disk (legacy torn write / hand edit). Don't throw and
                # lose this write -- preserve the bad file for forensics and start
                # from an empty document so the key still gets persisted.
                try { Copy-Item -LiteralPath $ucPath -Destination "$ucPath.corrupt.$PID" -Force -ErrorAction SilentlyContinue } catch {}
                [Console]::Error.WriteLine("WARN: sap_settings_lib: userconfig.json was unreadable; backed up to userconfig.json.corrupt.$PID and rewritten.")
                $uc = $null
            }
        }
        if ($null -eq $uc) { $uc = [pscustomobject]@{ userConfig = [pscustomobject]@{} } }
        if ($null -eq $uc.userConfig) {
            $uc | Add-Member -NotePropertyName userConfig -NotePropertyValue ([pscustomobject]@{}) -Force
        }

        if ($uc.userConfig.PSObject.Properties.Name -contains $Key) {
            $uc.userConfig.$Key.value = $Value
        } else {
            $entry = [pscustomobject]@{ value = $Value }
            $uc.userConfig | Add-Member -NotePropertyName $Key -NotePropertyValue $entry -Force
        }

        $json = $uc | ConvertTo-Json -Depth 10
        Write-SapJsonAtomic -Path $ucPath -Json $json
    }

    Reset-SapSettingsCache
}
