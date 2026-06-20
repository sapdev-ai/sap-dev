# =============================================================================
# sap_dev_default.ps1  --  CLI for task-scoped dev defaults (TR / package / ...)
#
# Default Scope=Session: a fresh TR/package a build creates becomes THIS
# conversation's default, keyed per (AI-session x pinned connection), WITHOUT
# touching connections.json -- so concurrent conversations on the same SAP
# connection never clobber each other (the 2026-06-20 069->074->075 thrash).
# Use -Scope Connection ONLY for a deliberate STANDING default (onboarding:
# /sap-dev-init, /sap-login).
#
# Reads always resolve session -> connection -> global (Get-SapCurrentDevDefault).
# Requires a pinned connection (run /sap-login first) OR a sole saved connection.
#
# Usage:
#   ... -Action set -Key sap_dev_transport_request -Value S4DK941289   # Session (default)
#   ... -Action set -Key sap_dev_package -Value ZMMA074
#   ... -Action set -Key sap_dev_package -Value ZMMA_DEV -Scope Connection   # standing
#   ... -Action get -Key sap_dev_transport_request
#
# Stdout last line: VALUE=<v> (get) | SET: key=<k> scope=<s> effective_value=<v> | ERROR: <msg>
# Exit: 0 ok, 2 error.
# =============================================================================
[CmdletBinding()]
param(
    [ValidateSet('get','set')][string] $Action = 'get',
    [string] $Key = '',
    [AllowEmptyString()][string] $Value = '',
    [ValidateSet('Session','Connection')][string] $Scope = 'Session'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sap_settings_lib.ps1')
. (Join-Path $PSScriptRoot 'sap_connection_lib.ps1')

try {
    if ([string]::IsNullOrWhiteSpace($Key)) { Write-Output 'ERROR: -Key is required'; exit 2 }
    $perConn = Get-SapPerConnectionDevKeys
    if ($perConn -notcontains $Key) {
        Write-Output "ERROR: '$Key' is not a per-connection dev key. Allowed: $($perConn -join ', ')"
        exit 2
    }

    if ($Action -eq 'get') {
        $v = Get-SapCurrentDevDefault -Key $Key
        Write-Output ("VALUE=" + $v)
        exit 0
    }

    # set
    Set-SapCurrentDevDefault -Key $Key -Value $Value -Scope $Scope
    $eff = Get-SapCurrentDevDefault -Key $Key
    Write-Output ("SET: key=$Key scope=$Scope effective_value=$eff")
    exit 0
} catch {
    Write-Output ("ERROR: " + $_.Exception.Message)
    exit 2
}
