# =============================================================================
# sap_settings_lib.ps1 — settings.json + settings.local.json merge helper.
# =============================================================================
# Two-file model:
#   settings.json         — TRACKED, schema + descriptions + defaults
#   settings.local.json   — GITIGNORED, per-developer values that override
#
# Read path  : merge per-key on the .value field, precedence (highest first):
#              env var SAPDEV_AI_WORK_DIR (work_dir only)
#              > settings.local.json (dev checkout override)
#              > userconfig.json (machine-global, {work_dir}\runtime)
#              > settings.json (tracked schema/defaults).
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

function Resolve-SapSettingsPaths {
    if ($null -ne $script:SapSettingsMainPath) { return }
    # This script lives at <root>\plugins\sap-dev-core\shared\scripts\sap_settings_lib.ps1
    $coreRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SapSettingsMainPath  = Join-Path $coreRoot 'settings.json'
    $script:SapSettingsLocalPath = Join-Path $coreRoot 'settings.local.json'
}

function Get-SapWorkDirBootstrap {
    # work_dir is the BOOTSTRAP pointer: it locates userconfig.json, so it must
    # be resolvable WITHOUT reading userconfig.json (otherwise infinite
    # recursion). Order: env var SAPDEV_AI_WORK_DIR -> settings.local.json ->
    # settings.json -> default C:\sap_dev_work. Reads the two plugin-dir files
    # DIRECTLY (never via Get-SapSettings) so it is safe to call from inside
    # Get-SapSettings.
    if (-not [string]::IsNullOrWhiteSpace($env:SAPDEV_AI_WORK_DIR)) {
        return ($env:SAPDEV_AI_WORK_DIR.Trim()).TrimEnd('\')
    }
    Resolve-SapSettingsPaths
    foreach ($p in @($script:SapSettingsLocalPath, $script:SapSettingsMainPath)) {
        if (Test-Path $p) {
            try {
                $o = Get-Content -Raw $p -Encoding UTF8 | ConvertFrom-Json
                if ($o.userConfig -and ($o.userConfig.PSObject.Properties.Name -contains 'work_dir')) {
                    $v = $o.userConfig.work_dir.value
                    if (-not [string]::IsNullOrWhiteSpace("$v")) { return "$v" }
                }
            } catch { }
        }
    }
    return 'C:\sap_dev_work'
}

function Get-SapUserConfigPath {
    # Machine-global override file, OUTSIDE the versioned plugin cache so it
    # survives plugin updates: {work_dir}\runtime\userconfig.json.
    return (Join-Path (Join-Path (Get-SapWorkDirBootstrap) 'runtime') 'userconfig.json')
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
        try {
            $uc = Get-Content -Raw $ucPath -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "sap_settings_lib: failed to parse userconfig.json: $_"
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
        try {
            $local = Get-Content -Raw $script:SapSettingsLocalPath -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "sap_settings_lib: failed to parse settings.local.json: $_"
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
                    # Key only in local — pass through as-is so the caller still sees it.
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
    # it via the dedicated bootstrap path — honors $env:SAPDEV_AI_WORK_DIR and
    # never recurses through userconfig.json.
    if ($Key -eq 'work_dir') { return Get-SapWorkDirBootstrap }
    # Per-connection isolation (Phase 4.3): for SAP-system-specific keys
    # (TR / package / function group) the source of truth is the pinned
    # connection's dev_defaults block in connections.json, not the global
    # settings.local.json. This is the read-side routing — Get-SapCurrentDevDefault
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
                    # Per-conn lookup failed (no pin / no store) — fall through
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
        Set-SapCurrentDevDefault — which targets the pinned connection's
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
        [switch] $SkipPerConnRouting
    )

    # Phase 4.4 write-path routing.
    if (-not $SkipPerConnRouting -and (Get-Command Get-SapPerConnectionDevKeys -ErrorAction SilentlyContinue)) {
        $perConnKeys = Get-SapPerConnectionDevKeys
        if ($perConnKeys -contains $Key) {
            if (Get-Command Set-SapCurrentDevDefault -ErrorAction SilentlyContinue) {
                Set-SapCurrentDevDefault -Key $Key -Value $Value
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

    $uc = $null
    if (Test-Path $ucPath) {
        try {
            $uc = Get-Content -Raw $ucPath -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "sap_settings_lib: failed to parse userconfig.json: $_"
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
    [System.IO.File]::WriteAllText($ucPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    Reset-SapSettingsCache
}
