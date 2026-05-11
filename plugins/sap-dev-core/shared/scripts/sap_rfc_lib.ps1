# =============================================================================
# sap_rfc_lib.ps1  -  Shared SAP NCo 3.1 connect helpers (PowerShell library)
#
# Dot-source this file at the top of any RFC-using PowerShell script:
#
#     . "%%RFC_LIB_PS1%%"
#     $g_dest = Connect-SapRfc -Server   "%%SAP_APPLICATION_SERVER%%" `
#                              -Sysnr    "%%SAP_SYSTEM_NUMBER%%" `
#                              -Client   "%%SAP_CLIENT%%" `
#                              -User     "%%SAP_USER%%" `
#                              -Password "%%SAP_PASSWORD%%" `
#                              -Language "%%SAP_LANGUAGE%%" `
#                              -DestName "SAPDEV_PKG"
#     if (-not $g_dest) { exit 1 }
#     # ... use $g_dest.Repository.CreateFunction(...) ...
#     # The 6 credential values are also re-published at caller scope as
#     # $g_sapServer / $g_sapSysnr / $g_sapClient / $g_sapUser /
#     # $g_sapPassword / $g_sapLanguage for any post-connect use.
#     Disconnect-SapRfc
#
# Skills inject the absolute path to this file via the %%RFC_LIB_PS1%% token,
# resolved as: <SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1
#
# REQUIREMENTS
#   - SAP NCo 3.1 in 32-bit GAC (sapnco.dll + sapnco_utils.dll)
#   - Run with 32-bit PowerShell:
#       C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe
#
# Functions exposed:
#   Connect-SapRfc                -> RfcDestination (or $null on failure)
#   Disconnect-SapRfc             -> cleanup (uses last connection's RfcConfigParameters)
#   Add-RfcField                  -> append a FIELDNAME row to RFC_READ_TABLE FIELDS
#   Add-RfcOption                 -> append a TEXT row   to RFC_READ_TABLE OPTIONS
#   Assert-RfcReadTableAllowed    -> hard-fail if QUERY_TABLE is on the forbidden list
#   New-RfcReadTable              -> preferred RFC_READ_TABLE entry point (calls
#                                    Assert-RfcReadTableAllowed automatically)
#
# FORBIDDEN TABLES FOR RFC_READ_TABLE
# -----------------------------------
# `RFC_READ_TABLE` materializes the FULL row width before applying the FIELDS
# projection. Tables whose rows contain `LRAW` (compressed) or very wide text
# columns will exceed the 512-byte row buffer and the server raises
# `ASSIGN ... CASTING` in `SAPLSDTX`. Limiting FIELDS does NOT help.
#
#   - REPOSRC  (program source: DATA = LRAW). Use PROGDIR.STATE for activation
#              state, RPY_PROGRAM_READ for source, or `/sap-se16n REPOSRC`
#              (drives SAP GUI, not RFC) for a row listing.
#
# Callers that go through `New-RfcReadTable` (recommended) get this guard for
# free. Callers that still use `$dest.Repository.CreateFunction("RFC_READ_TABLE")`
# directly MUST invoke `Assert-RfcReadTableAllowed -QueryTable <name>` after
# the first `SetValue("QUERY_TABLE", ...)`.
# =============================================================================

# Module-scoped state so Disconnect-SapRfc can find what to remove.
$script:_SapRfc_Params = $null
$script:_SapRfc_NcoLoaded = $false

function _Load-SapNco {
    if ($script:_SapRfc_NcoLoaded) { return $true }
    $gacRoot  = "C:\Windows\Microsoft.NET\assembly\GAC_32"
    $ncoDir   = Get-ChildItem -Path (Join-Path $gacRoot "sapnco")       -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    $utilsDir = Get-ChildItem -Path (Join-Path $gacRoot "sapnco_utils") -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ncoDir -or -not $utilsDir) {
        Write-Host "ERROR: SAP NCo 3.1 not found in $gacRoot."
        Write-Host "       Install SAP Connector for .NET 3.1 (32-bit, .NET 4.0)."
        return $false
    }
    try {
        Add-Type -Path (Join-Path $ncoDir.FullName   "sapnco.dll")
        Add-Type -Path (Join-Path $utilsDir.FullName "sapnco_utils.dll")
    } catch {
        Write-Host "ERROR: Failed to load NCo assemblies: $($_.Exception.Message)"
        Write-Host "       Run with 32-bit PowerShell (SysWOW64\WindowsPowerShell\v1.0\powershell.exe)."
        return $false
    }
    $script:_SapRfc_NcoLoaded = $true
    return $true
}

function Connect-SapRfc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Server,
        [Parameter(Mandatory=$true)] [string]$Sysnr,
        [Parameter(Mandatory=$true)] [string]$Client,
        [Parameter(Mandatory=$true)] [string]$User,
        [Parameter(Mandatory=$true)] [string]$Password,
        [Parameter(Mandatory=$true)] [string]$Language,
        [string]$DestName = "SAPDEV"
    )

    if (-not (_Load-SapNco)) { return $null }

    # NCo writes a `dev_nco_rfc.log` trace file to the .NET process's current
    # working directory by default. Without intervention this drops noise into
    # whatever folder the caller happened to invoke from (e.g. the repo root).
    # Redirect by setting the .NET working directory to the configured log
    # folder BEFORE the first NCo API call. Resolves to:
    #   userConfig.log_dir if set
    #   else {work_dir}\logs (default work_dir = C:\sap_dev_work)
    if (-not $script:_SapRfc_LogDirSet) {
        try {
            $settingsPath = Join-Path (Split-Path -Parent $PSCommandPath) '..\..\settings.json'
            $cfgWork = ''; $cfgLog = ''
            if (Test-Path $settingsPath) {
                $cfg = Get-Content -Raw $settingsPath | ConvertFrom-Json
                $cfgWork = $cfg.userConfig.work_dir.value
                $cfgLog  = $cfg.userConfig.log_dir.value
            }
            if ([string]::IsNullOrWhiteSpace($cfgWork)) { $cfgWork = 'C:\sap_dev_work' }
            if ([string]::IsNullOrWhiteSpace($cfgLog))  { $cfgLog  = (Join-Path $cfgWork 'logs') }
            if (-not (Test-Path $cfgLog)) { New-Item -ItemType Directory -Force -Path $cfgLog | Out-Null }
            [System.IO.Directory]::SetCurrentDirectory($cfgLog)
            $script:_SapRfc_LogDirSet = $true
        } catch {
            # Non-fatal — NCo will fall back to the original CWD if redirect fails.
        }
    }

    # Unique destination name per call to avoid NCo's destination cache.
    $uniqueName = "{0}_{1}" -f $DestName, ([Guid]::NewGuid().ToString('N').Substring(0,8))

    $params = New-Object SAP.Middleware.Connector.RfcConfigParameters
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::Name,          $uniqueName)
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::AppServerHost, $Server)
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::SystemNumber,  $Sysnr)
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::Client,        $Client)
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::User,          $User)
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::Password,      $Password)
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::Language,      $Language)

    try {
        $dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($params)
        $dest.Ping()
        Write-Host "INFO: RFC connected to $Server client $Client (NCo 3.1)."
        $script:_SapRfc_Params = $params
        # Also expose at caller scope so legacy `RemoveDestination($g_rfcParams)` keeps working,
        # and re-publish the credential values as $g_sap* so consumers don't need their own
        # 6-line credential block (post-connect uses like $fn.SetValue("LANGU",$g_sapLanguage)).
        Set-Variable -Scope 1 -Name g_rfcParams   -Value $params   -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapServer   -Value $Server   -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapSysnr    -Value $Sysnr    -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapClient   -Value $Client   -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapUser     -Value $User     -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapPassword -Value $Password -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapLanguage -Value $Language -ErrorAction SilentlyContinue
        return $dest
    }
    catch [SAP.Middleware.Connector.RfcLogonException] {
        Write-Host "ERROR: RFC logon failed (bad user/password/client): $($_.Exception.Message)"
        return $null
    }
    catch [SAP.Middleware.Connector.RfcCommunicationException] {
        Write-Host "ERROR: RFC network/gateway failure: $($_.Exception.Message)"
        return $null
    }
    catch {
        Write-Host "ERROR: RFC connection failed: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        return $null
    }
}

function Disconnect-SapRfc {
    if ($script:_SapRfc_Params) {
        try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($script:_SapRfc_Params) | Out-Null } catch { }
        $script:_SapRfc_Params = $null
    }
}

# Append a FIELDS row (FIELDNAME=<name>) to an RFC_READ_TABLE function call.
function Add-RfcField($fn, [string]$name) {
    $tbl = $fn.GetTable("FIELDS")
    $tbl.Append() | Out-Null
    $tbl.SetValue("FIELDNAME", $name)
}

# Append an OPTIONS row (TEXT=<where>) to an RFC_READ_TABLE function call.
function Add-RfcOption($fn, [string]$where) {
    $tbl = $fn.GetTable("OPTIONS")
    $tbl.Append() | Out-Null
    $tbl.SetValue("TEXT", $where)
}

# Forbidden tables for RFC_READ_TABLE. See header comment for rationale.
# Match is case-insensitive. Extend this list only after confirming the
# table actually triggers the SAPLSDTX cast dump on the target release.
$script:_SapRfc_ForbiddenReadTables = @('REPOSRC')

# Hard-fail if QUERY_TABLE is on the forbidden list. Call this AFTER setting
# QUERY_TABLE on an RFC_READ_TABLE function but BEFORE Invoke(). Throws a
# terminating error with a clear migration hint, so the caller's `try { }
# catch { }` (or default script termination) surfaces the violation
# immediately instead of falling through to the cryptic SAPLSDTX dump.
function Assert-RfcReadTableAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$QueryTable
    )
    $upper = $QueryTable.ToUpperInvariant()
    if ($script:_SapRfc_ForbiddenReadTables -contains $upper) {
        $hint = switch ($upper) {
            'REPOSRC' { "REPOSRC contains LRAW DATA and exceeds the 512-byte row cap - use PROGDIR.STATE for activation state, RPY_PROGRAM_READ for source content, or /sap-se16n REPOSRC for a row listing." }
            default   { "(no migration hint registered for $upper - see sap_rfc_lib.ps1 header comments)" }
        }
        throw "RFC_READ_TABLE on '$QueryTable' is FORBIDDEN by sap_rfc_lib.ps1 policy. $hint"
    }
}

# Preferred RFC_READ_TABLE entry point. Creates the function object,
# sets QUERY_TABLE + DELIMITER, and applies the forbidden-table guard in
# one step. Callers chain SetValue / Add-RfcOption / Add-RfcField on the
# returned object exactly as before, then Invoke($dest).
#
# Usage:
#   $fn = New-RfcReadTable -Destination $g_dest -Table 'E070' -Delimiter '|'
#   Add-RfcOption $fn "TRKORR EQ 'S4DK941157'"
#   Add-RfcField  $fn 'TRKORR'
#   Add-RfcField  $fn 'TRSTATUS'
#   $fn.Invoke($g_dest)
function New-RfcReadTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Destination,
        [Parameter(Mandatory=$true)] [string]$Table,
        [string]$Delimiter = '|'
    )
    Assert-RfcReadTableAllowed -QueryTable $Table
    $fn = $Destination.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", $Table)
    $fn.SetValue("DELIMITER",   $Delimiter)
    return $fn
}
