# =============================================================================
# sap_se37_post_activate_verify.ps1
# -----------------------------------------------------------------------------
# Post-activate verifier for FUNCTION MODULES. Closes the SE37 deploy-time
# false-success path identified 2026-06-22 on EC2 (ECC6 / 7.31): when the
# function group's framework (SAPL<FG> / L<FG>TOP) is INACTIVE at FM-activation
# time, Ctrl+F3 raises a syntax-error popup (the inactive FUNCTION-POOL context)
# that the worklist handler does not distinguish, "activate anyway" suppresses
# it, the final Ctrl+F2 grid reads clean, and sap_se37_create/update.vbs printed
# SUCCESS while the FM was not actually usable (RFC calls would fail because the
# FG never loads). The GUI flow has no language/screen-independent active gate,
# so this RFC check is it (mirrors sap_se38_post_activate_verify.ps1).
#
# Contract (mirrors the se38 / se11 verifiers; consumed by PostActivateVerifyOrFail
# in sap_se11_post_activate_verify.vbs):
#
#     pwsh -File sap_se37_post_activate_verify.ps1 -ObjectType FM -ObjectName Z_MY_FM
#
# An FM is "active / usable" when its function group's MAIN program SAPL<FG> is
# active. We resolve FM -> FG via ENLFDIR (FUNCNAME -> AREA), then check PROGDIR
# for SAPL<FG>:
#
#   stdout last line / exit:
#     ACTIVE     0   SAPL<FG> has STATE='A' and no STATE='I'
#     INACTIVE   2   SAPL<FG> has STATE='I' (framework not activated) -- deploy failed
#     MISSING    3   FM not in ENLFDIR (never registered) -- silent half-deploy
#     ERROR: <m> 1   RFC unreachable / no creds / decrypt failed (soft-warn, do not block)
#
# Callers fail-closed on INACTIVE / MISSING, soft-warn on ERROR.
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

if ($type -ne 'FM' -and $type -ne 'FUNCTION' -and $type -ne 'FUNCTION_MODULE') {
    Write-Host "ERROR: Unknown OBJECT_TYPE '$type' (this verifier supports only FM; use sap_se38_/sap_se11_post_activate_verify.ps1 for programs / DDIC)."
    exit 1
}

# Resolve the AI-session's pinned connection profile (same as the se38 verifier).
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
                             -DestName 'SE37_PA_VERIFY'
} catch {
    Write-Host "ERROR: RFC connect failed: $($_.Exception.Message)"
    exit 1
}
if (-not $g_dest) {
    Write-Host "ERROR: RFC connect returned no destination (check NCo 3.1 GAC + endpoint)."
    exit 1
}

try {
    # 1. FM -> function group: ENLFDIR maps FUNCNAME -> AREA. Also proves the FM
    #    is registered at all (else MISSING = silent half-deploy).
    $fn = $g_dest.Repository.CreateFunction('RFC_READ_TABLE')
    $fn.SetValue('QUERY_TABLE', 'ENLFDIR')
    $fn.SetValue('DELIMITER',   '|')
    Add-RfcOption $fn ("FUNCNAME = '{0}'" -f $name)
    Add-RfcField  $fn 'FUNCNAME'
    Add-RfcField  $fn 'AREA'
    $fn.Invoke($g_dest)
    $d = $fn.GetTable('DATA')
    if ($d.RowCount -lt 1) { Write-Host 'MISSING'; exit 3 }
    $d.CurrentIndex = 0
    $cols = $d.GetString('WA').Split('|') | ForEach-Object { $_.Trim() }
    $area = if ($cols.Count -ge 2) { $cols[1] } else { '' }
    if ([string]::IsNullOrWhiteSpace($area)) { Write-Host 'MISSING'; exit 3 }
    $mainPgm = 'SAPL' + $area

    # 2. FG main program must be active: PROGDIR NAME='SAPL<FG>' STATE='A', no 'I'.
    #    (An inactive framework is the false-success signal -- the FM cannot load.)
    $fn2 = $g_dest.Repository.CreateFunction('RFC_READ_TABLE')
    $fn2.SetValue('QUERY_TABLE', 'PROGDIR')
    $fn2.SetValue('DELIMITER',   '|')
    Add-RfcOption $fn2 ("NAME = '{0}'" -f $mainPgm)
    Add-RfcField  $fn2 'NAME'
    Add-RfcField  $fn2 'STATE'
    $fn2.Invoke($g_dest)
    $d2 = $fn2.GetTable('DATA')

    $hasActive   = $false
    $hasInactive = $false
    for ($i = 0; $i -lt $d2.RowCount; $i++) {
        $d2.CurrentIndex = $i
        $c = $d2.GetString('WA').Split('|') | ForEach-Object { $_.Trim() }
        if ($c.Count -ge 2) {
            if ($c[1] -eq 'A') { $hasActive   = $true }
            if ($c[1] -eq 'I') { $hasInactive = $true }
        }
    }

    if     ($hasInactive) { Write-Host 'INACTIVE'; exit 2 }   # framework not activated
    elseif ($hasActive)   { Write-Host 'ACTIVE';   exit 0 }
    else                  { Write-Host 'INACTIVE'; exit 2 }   # FM registered but FG main has no active row
}
catch {
    Write-Host "ERROR: RFC verify failed: $($_.Exception.Message)"
    exit 1
}
finally {
    try { Disconnect-SapRfc | Out-Null } catch {}
}
