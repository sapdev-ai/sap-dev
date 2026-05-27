# =============================================================================
# sap_se38_post_activate_verify.ps1
# -----------------------------------------------------------------------------
# Post-activate verifier for ABAP programs (reports / module pools / includes).
# Closes the SE38 deploy-time false-success path identified 2026-05-27 against
# ZMMRMAT044R01: when the locale-bound syntax matcher missed an error AND the
# AbapEditor swallowed the post-Ctrl+F3 sbar=E message AND F8-from-SA38
# returned to screen 101 with a clean sbar, the existing GUI-only verify in
# sap_se38_create.vbs / sap_se38_update.vbs accepted "screen 101 + clean sbar"
# as SUCCESS while PROGDIR.STATE was still 'I'.
#
# This script is the language-independent / screen-independent / popup-
# independent gate. It runs after Ctrl+F3 and queries PROGDIR directly.
#
# Contract (mirrors sap_se11_post_activate_verify.ps1):
#
#     pwsh -File sap_se38_post_activate_verify.ps1 \
#          -ObjectType PROGRAM -ObjectName ZMMRMAT046R01
#
# Exit codes / stdout last line:
#   0  ACTIVE     PROGDIR has at least one STATE='A' row for NAME and no STATE='I'
#   1  ERROR: <message>     (RFC unreachable / no creds / decrypt failed)
#   2  INACTIVE   PROGDIR has at least one STATE='I' row for NAME (deploy failed)
#   3  MISSING    PROGDIR has zero rows for NAME (silent half-deploy)
#
# PROGDIR row model (S/4HANA 1909 confirmed):
#   - A program saved-but-not-activated has STATE='I' row only.
#   - A program saved-and-activated has STATE='A' row only (SAP atomically
#     replaces the 'I' with 'A' on successful activate).
#   - During a failed activate attempt, both rows can briefly coexist:
#     STATE='A' (the old code that's still active) + STATE='I' (the newly-
#     saved-but-rejected version). The 'I' row is the failure signal — we
#     fail-closed regardless of whether 'A' also exists.
#
# Callers should fail-closed on INACTIVE / MISSING, soft-warn on ERROR.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ObjectType,
    [Parameter(Mandatory)][string]$ObjectName
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\sap_settings_lib.ps1"
. "$PSScriptRoot\sap_connection_lib.ps1"
. "$PSScriptRoot\sap_rfc_lib.ps1"

$type = $ObjectType.ToUpperInvariant()
$name = $ObjectName.ToUpperInvariant()

if ($type -ne 'PROGRAM') {
    Write-Host "ERROR: Unknown OBJECT_TYPE '$type' (this verifier supports only PROGRAM; for DDIC objects use sap_se11_post_activate_verify.ps1)."
    exit 1
}

# Resolve the AI-session's pinned connection profile.
$profile = $null
try { $profile = Get-SapCurrentConnectionProfile } catch {
    Write-Host "ERROR: Could not resolve pinned connection profile: $($_.Exception.Message)"
    exit 1
}
if (-not $profile) {
    Write-Host "ERROR: No pinned SAP connection for this AI session. Run /sap-login first."
    exit 1
}

$server = "$($profile.application_server)"
$sysnr  = "$($profile.system_number)"
if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($sysnr)) {
    Write-Host "INFO: Re-run /sap-login so the post-login capture refreshes the endpoint."
    Write-Host "ERROR: Pinned connection (id=$($profile.id)) has no application_server / system_number - cannot open RFC."
    exit 1
}

$pwdField = "$($profile.password_dpapi)"
if ([string]::IsNullOrWhiteSpace($pwdField)) {
    Write-Host "INFO: Re-run /sap-login and accept the post-login prompt to save the password (DPAPI-encrypted at rest)."
    Write-Host "ERROR: Pinned connection (id=$($profile.id)) has no saved password - cannot run RFC verify."
    exit 1
}
$pwd = ''
try {
    $pwd = & "$PSScriptRoot\sap_dpapi.ps1" -Action unprotect -Value $pwdField 2>$null
    $pwd = "$pwd".Trim()
} catch {
    Write-Host "ERROR: Password decrypt failed: $($_.Exception.Message)"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($pwd)) {
    Write-Host "ERROR: Password decrypt returned empty (different Windows user / different machine / corrupted ciphertext?)."
    exit 1
}

$client = "$($profile.client)"
$user   = "$($profile.user)"
$lang   = "$($profile.language)"
if ([string]::IsNullOrWhiteSpace($lang)) { $lang = 'EN' }

$g_dest = $null
try {
    $g_dest = Connect-SapRfc -Server   $server `
                             -Sysnr    $sysnr `
                             -Client   $client `
                             -User     $user `
                             -Password $pwd `
                             -Language $lang `
                             -DestName 'SE38_PA_VERIFY'
} catch {
    Write-Host "ERROR: RFC connect failed: $($_.Exception.Message)"
    exit 1
}
if (-not $g_dest) {
    Write-Host "ERROR: RFC connect returned no destination (check NCo 3.1 GAC + endpoint)."
    exit 1
}

try {
    # PROGDIR is the program directory: one row per (NAME, STATE) pair.
    # STATE='A' = active version, STATE='I' = inactive (saved-but-not-activated).
    # Both can coexist briefly during a failed activate.
    $fn = $g_dest.Repository.CreateFunction('RFC_READ_TABLE')
    $fn.SetValue('QUERY_TABLE', 'PROGDIR')
    $fn.SetValue('DELIMITER',   '|')
    Add-RfcOption $fn ("NAME = '{0}'" -f $name)
    Add-RfcField  $fn 'NAME'
    Add-RfcField  $fn 'STATE'
    Add-RfcField  $fn 'SUBC'
    $fn.Invoke($g_dest)
    $data = $fn.GetTable('DATA')

    $hasActive   = $false
    $hasInactive = $false
    $rowCount    = 0
    for ($i = 0; $i -lt $data.RowCount; $i++) {
        $data.CurrentIndex = $i
        $row  = $data.GetString('WA')
        $cols = $row.Split('|') | ForEach-Object { $_.Trim() }
        if ($cols.Count -ge 2) {
            $rowCount++
            $st = $cols[1].Trim()
            if ($st -eq 'A') { $hasActive   = $true }
            if ($st -eq 'I') { $hasInactive = $true }
        }
    }

    # Fail-closed contract:
    #   - 'I' row present  -> deploy did not complete (regardless of whether 'A' coexists).
    #   - 'I' absent + 'A' present -> active, no half-state.
    #   - both absent      -> PROGDIR has no row for NAME at all (silent half-deploy:
    #                         the program either was never saved or was deleted between
    #                         save and verify). Same severity as INACTIVE.
    if     ($hasInactive)              { Write-Host 'INACTIVE'; exit 2 }
    elseif ($hasActive)                { Write-Host 'ACTIVE';   exit 0 }
    else                               { Write-Host 'MISSING';  exit 3 }
}
catch {
    Write-Host "ERROR: RFC_READ_TABLE on PROGDIR failed: $($_.Exception.Message)"
    exit 1
}
finally {
    try { Disconnect-SapRfc | Out-Null } catch {}
}
