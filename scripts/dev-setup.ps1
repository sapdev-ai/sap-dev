# =============================================================================
# scripts/dev-setup.ps1 — onboarding bootstrap for new developers.
# =============================================================================
# What it does:
#   1. Verifies sap-dev-core/settings.json exists (the schema).
#   2. Creates settings.local.json if missing.
#   3. Prompts for the SAP connection fields (server, system, client, user,
#      password, language).
#   4. DPAPI-encrypts the password before storing.
#   5. Writes everything to settings.local.json via the merge helper —
#      settings.json is never touched.
#
# Re-runnable: existing values in settings.local.json are shown as defaults;
# pressing Enter keeps the existing value. Use -Force to be re-prompted for
# every field even when one is already set.
#
# Usage:
#   pwsh ./scripts/dev-setup.ps1
#   pwsh ./scripts/dev-setup.ps1 -Force
#
# Requirements:
#   - Windows PowerShell 5.1+ (DPAPI bindings)
#   - Run from anywhere; resolves paths relative to the script location.
# =============================================================================

[CmdletBinding()]
param(
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot     = Split-Path -Parent $PSScriptRoot
$CoreRoot     = Join-Path $RepoRoot 'plugins\sap-dev-core'
$SchemaPath   = Join-Path $CoreRoot 'settings.json'
$LocalPath    = Join-Path $CoreRoot 'settings.local.json'
$SharedScripts= Join-Path $CoreRoot 'shared\scripts'
$SettingsLib  = Join-Path $SharedScripts 'sap_settings_lib.ps1'
$DpapiHelper  = Join-Path $SharedScripts 'sap_dpapi.ps1'

if (-not (Test-Path $SchemaPath))    { throw "Schema not found: $SchemaPath" }
if (-not (Test-Path $SettingsLib))   { throw "Settings lib not found: $SettingsLib" }
if (-not (Test-Path $DpapiHelper))   { throw "DPAPI helper not found: $DpapiHelper" }

. $SettingsLib

Write-Host ""
Write-Host "sap-dev developer setup" -ForegroundColor Cyan
Write-Host "-----------------------"
Write-Host "Schema (read-only): $SchemaPath"
Write-Host "Local file (yours): $LocalPath"
Write-Host ""

# Bootstrap the local file if missing.
if (-not (Test-Path $LocalPath)) {
    $emptyShape = '{"userConfig":{}}'
    [System.IO.File]::WriteAllText($LocalPath, $emptyShape, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Created empty settings.local.json." -ForegroundColor Green
    Write-Host ""
}

# Re-read merged view so existing values become defaults.
Reset-SapSettingsCache
$cfg = Get-SapSettings

function Read-Field {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Prompt,
        [string] $Example = '',
        [switch] $Secret
    )
    $existing = ''
    if ($cfg.userConfig.PSObject.Properties.Name -contains $Key) {
        $existing = [string]$cfg.userConfig.$Key.value
    }

    $hasExisting = -not [string]::IsNullOrWhiteSpace($existing)

    # Skip if value already set and -Force not specified.
    if ($hasExisting -and -not $Force) {
        $shown = if ($Secret) { '<set, encrypted>' } else { $existing }
        Write-Host ("  {0,-25} = {1}" -f $Key, $shown) -ForegroundColor DarkGray
        return $existing
    }

    $hint = if ($hasExisting) {
        if ($Secret) { ' (press Enter to keep existing encrypted value)' }
        else { " (current: $existing — press Enter to keep)" }
    } elseif ($Example) { " (e.g. $Example — press Enter to skip)" }
    else { ' (press Enter to skip)' }

    if ($Secret) {
        $sec = Read-Host "$Prompt$hint" -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $entered = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } else {
        $entered = Read-Host "$Prompt$hint"
    }

    if ([string]::IsNullOrWhiteSpace($entered)) { return $existing }
    return $entered
}

Write-Host "Connection fields (Enter = keep existing/skip)" -ForegroundColor Cyan

$server = Read-Field -Key 'sap_application_server' -Prompt 'SAP server hostname/IP' -Example 'sap1.example.com'
$sysnr  = Read-Field -Key 'sap_system_number'      -Prompt 'System number (2 digits)' -Example '00'
$client = Read-Field -Key 'sap_client'             -Prompt 'Client (3 digits)'        -Example '100'
$user   = Read-Field -Key 'sap_user'               -Prompt 'SAP username'             -Example 'DEVELOPER'
$pwdRaw = Read-Field -Key 'sap_password'           -Prompt 'SAP password'             -Secret
$lang   = Read-Field -Key 'sap_language'           -Prompt 'Logon language (2 letters)' -Example 'EN'
$logon  = Read-Field -Key 'sap_logon_description'  -Prompt 'SAP Logon pad entry name (optional)' -Example 'DEV_100'

# Encrypt new plaintext passwords; pass DPAPI blobs through unchanged.
$pwdToStore = $pwdRaw
if (-not [string]::IsNullOrWhiteSpace($pwdRaw) -and -not $pwdRaw.StartsWith('dpapi:')) {
    Write-Host ""
    Write-Host "Encrypting password via DPAPI..." -ForegroundColor Cyan
    $enc = & powershell -NoProfile -ExecutionPolicy Bypass -File $DpapiHelper -Action protect -Value $pwdRaw 2>&1 |
           Where-Object { $_ -match '^dpapi:' } |
           Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($enc)) { throw "DPAPI encryption failed (no dpapi:... line on stdout)." }
    $pwdToStore = $enc
}

Write-Host ""
Write-Host "Writing to settings.local.json..." -ForegroundColor Cyan

$writes = @(
    @{ Key = 'sap_application_server'; Val = $server }
    @{ Key = 'sap_system_number';      Val = $sysnr  }
    @{ Key = 'sap_client';             Val = $client }
    @{ Key = 'sap_user';               Val = $user   }
    @{ Key = 'sap_password';           Val = $pwdToStore }
    @{ Key = 'sap_language';           Val = $lang   }
    @{ Key = 'sap_logon_description';  Val = $logon  }
)

foreach ($w in $writes) {
    if (-not [string]::IsNullOrWhiteSpace($w.Val)) {
        Set-SapUserSetting $w.Key $w.Val
        $shown = if ($w.Key -eq 'sap_password') { '<encrypted>' } else { $w.Val }
        Write-Host ("  wrote {0,-25} = {1}" -f $w.Key, $shown) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Done. Verifying gitignore..." -ForegroundColor Cyan
$ignore = & git -C $RepoRoot check-ignore -v 'plugins/sap-dev-core/settings.local.json' 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  OK — settings.local.json is gitignored ($ignore)" -ForegroundColor Green
} else {
    Write-Host "  WARNING — settings.local.json is NOT gitignored. Check .gitignore!" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Inside Claude Code: /sap-login   (verify the connection)"
Write-Host "  2. Inside Claude Code: /sap-dev-init  (bootstrap TR + package + FG)"
Write-Host "  3. Read docs/settings-local-faq.md for the full Q&A reference."
Write-Host ""
