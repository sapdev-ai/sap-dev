# =============================================================================
# sap_se11_post_activate_verify.ps1
# -----------------------------------------------------------------------------
# Self-contained post-activate verifier for SE11 DDIC objects (Phase 4.3).
#
# Replaces the token-substituted sap_se11_verify_active.ps1 with a version
# that reads credentials directly from the AI-session's pinned connection
# profile in connections.json (DPAPI-decrypted on the fly). This removes
# the dependency on legacy sap_user / sap_password keys in settings.json
# and lets every sap-se11 create/update VBS call us as a black box:
#
#     pwsh -File sap_se11_post_activate_verify.ps1 \
#          -ObjectType DOMAIN -ObjectName ZMMDM_VAL35
#
# Exit codes / stdout last-line (same contract as sap_se11_verify_active.ps1):
#   0  ACTIVE
#   1  ERROR: <message>     (RFC unreachable / no creds / decrypt failed)
#   2  INACTIVE
#   3  MISSING
#
# Callers should fail-closed on INACTIVE / MISSING, soft-warn on ERROR
# (the verify is defense in depth; the SAP GUI status bar still applies).
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ObjectType,
    [Parameter(Mandatory)][string]$ObjectName
)

$ErrorActionPreference = 'Stop'

# Bootstrap shared libs from the same directory as this script.
. "$PSScriptRoot\sap_settings_lib.ps1"
. "$PSScriptRoot\sap_connection_lib.ps1"
. "$PSScriptRoot\sap_rfc_lib.ps1"
# sap_dpapi.ps1 is invoked as a subprocess (it has its own param block) -- no dot-source.

$type = $ObjectType.ToUpperInvariant()
$name = $ObjectName.ToUpperInvariant()

$catalog = switch ($type) {
    'TABLE'        { @{ Tab='DD02L'; Key='TABNAME'   } }
    'STRUCTURE'    { @{ Tab='DD02L'; Key='TABNAME'   } }
    'DATAELEMENT'  { @{ Tab='DD04L'; Key='ROLLNAME'  } }
    'DOMAIN'       { @{ Tab='DD01L'; Key='DOMNAME'   } }
    'TABLETYPE'    { @{ Tab='DD40L'; Key='TYPENAME'  } }
    'VIEW'         { @{ Tab='DD25L'; Key='VIEWNAME'  } }
    'SEARCHHELP'   { @{ Tab='DD30L'; Key='SHLPNAME'  } }
    'LOCKOBJECT'   { @{ Tab='DD25L'; Key='VIEWNAME'  } }
    'TYPEGROUP'    { @{ Tab='DD40L'; Key='TYPENAME'  } }
    default        { $null }
}
if (-not $catalog) {
    Write-Host "ERROR: Unknown OBJECT_TYPE '$type' (allowed: TABLE STRUCTURE DATAELEMENT DOMAIN TABLETYPE VIEW SEARCHHELP LOCKOBJECT TYPEGROUP)."
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

# RFC endpoint -- direct (application_server + system_number).
# Load-balanced profiles (message_server) without app server set cannot
# be RFC'd via Connect-SapRfc -Server in its current shape; surface a
# clear error so the operator knows what to fix.
$server = "$($profile.application_server)"
$sysnr  = "$($profile.system_number)"
if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($sysnr)) {
    Write-Host "INFO: Re-run /sap-login so the post-login capture refreshes the endpoint."
    Write-Host "ERROR: Pinned connection (id=$($profile.id)) has no application_server / system_number - cannot open RFC."
    exit 1
}

# Password -- decrypt via sap_dpapi.ps1 (CLI mode). The profile carries either
# 'dpapi:<base64>' (preferred) or legacy plaintext; sap_dpapi pass-through
# handles both.
$pwdField = "$($profile.password_dpapi)"
if ([string]::IsNullOrWhiteSpace($pwdField)) {
    # Contract: last stdout line is the answer. Emit INFO first, ERROR last.
    Write-Host "INFO: Re-run /sap-login and accept the post-login prompt to save the password (DPAPI-encrypted at rest)."
    Write-Host "ERROR: Pinned connection (id=$($profile.id)) has no saved password - cannot run RFC verify."
    exit 1
}
$pwd = ''
try {
    # Subprocess invoke so dpapi's param block doesn't clobber ours (per
    # feedback_dot_source_param_clobber memory). 32-bit not required for
    # DPAPI itself -- runs in whatever PS is current.
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

# Open RFC.
$g_dest = $null
try {
    $g_dest = Connect-SapRfc -Server   $server `
                             -Sysnr    $sysnr `
                             -Client   $client `
                             -User     $user `
                             -Password $pwd `
                             -Language $lang `
                             -DestName 'SE11_PA_VERIFY'
} catch {
    Write-Host "ERROR: RFC connect failed: $($_.Exception.Message)"
    exit 1
}
if (-not $g_dest) {
    Write-Host "ERROR: RFC connect returned no destination (check NCo 3.1 GAC + endpoint)."
    exit 1
}

try {
    $fn = $g_dest.Repository.CreateFunction('RFC_READ_TABLE')
    $fn.SetValue('QUERY_TABLE', $catalog.Tab)
    $fn.SetValue('DELIMITER',   '|')
    Add-RfcOption $fn ("{0} = '{1}'" -f $catalog.Key, $name)
    Add-RfcField  $fn $catalog.Key
    Add-RfcField  $fn 'AS4LOCAL'
    $fn.Invoke($g_dest)
    $data = $fn.GetTable('DATA')

    $hasActive   = $false
    $hasInactive = $false
    for ($i = 0; $i -lt $data.RowCount; $i++) {
        $data.CurrentIndex = $i
        $row = $data.GetString('WA')
        $cols = $row.Split('|') | ForEach-Object { $_.Trim() }
        if ($cols.Count -ge 2) {
            $loc = $cols[1].Trim()
            if ($loc -eq 'A') { $hasActive   = $true }
            if ($loc -eq 'N') { $hasInactive = $true }
        }
    }

    if     ($hasActive)   { Write-Host 'ACTIVE';   exit 0 }
    elseif ($hasInactive) { Write-Host 'INACTIVE'; exit 2 }
    else                  { Write-Host 'MISSING';  exit 3 }
}
catch {
    Write-Host "ERROR: RFC_READ_TABLE failed: $($_.Exception.Message)"
    exit 1
}
finally {
    try { Disconnect-SapRfc | Out-Null } catch {}
}
