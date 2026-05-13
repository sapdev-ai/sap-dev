# =============================================================================
# sap_settings_lib.ps1 — settings.json + settings.local.json merge helper.
# =============================================================================
# Two-file model:
#   settings.json         — TRACKED, schema + descriptions + defaults
#   settings.local.json   — GITIGNORED, per-developer values that override
#
# Read path  : merge settings.local.json over settings.json (per-key override
#              of the .value field).
# Write path : ALL writes go to settings.local.json. Never mutate settings.json
#              from a skill — that file changes only when a developer adds a
#              new userConfig key by hand.
#
# USAGE (dot-source):
#
#     . "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1"
#     $cfg = Get-SapSettings                       # full merged object
#     $val = Get-SapSettingValue 'sap_password'    # convenience: just .value
#     Set-SapUserSetting 'sap_password' 'dpapi:...' # writes to settings.local.json
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
    $s = Get-SapSettings
    if ($s.userConfig.PSObject.Properties.Name -contains $Key) {
        $v = $s.userConfig.$Key.value
        if ($null -ne $v -and "$v" -ne '') { return [string]$v }
    }
    return $Default
}

function Set-SapUserSetting {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )
    Resolve-SapSettingsPaths

    if (Test-Path $script:SapSettingsLocalPath) {
        try {
            $local = Get-Content -Raw $script:SapSettingsLocalPath -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "sap_settings_lib: failed to parse settings.local.json: $_"
        }
    }
    if ($null -eq $local) { $local = [pscustomobject]@{ userConfig = [pscustomobject]@{} } }
    if ($null -eq $local.userConfig) {
        $local | Add-Member -NotePropertyName userConfig -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    if ($local.userConfig.PSObject.Properties.Name -contains $Key) {
        $local.userConfig.$Key.value = $Value
    } else {
        $entry = [pscustomobject]@{ value = $Value }
        $local.userConfig | Add-Member -NotePropertyName $Key -NotePropertyValue $entry -Force
    }

    $json = $local | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($script:SapSettingsLocalPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    Reset-SapSettingsCache
}
