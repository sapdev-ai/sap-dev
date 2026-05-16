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
        # Direct-server path. Pass -Server and -Sysnr, OR leave both blank
        # and supply -MessageServer + -SystemID for load-balanced login.
        [string]$Server   = '',
        [string]$Sysnr    = '',

        # Load-balanced path (NCo: MessageServerHost + LogonGroup + SystemID).
        # If -Server is blank and -MessageServer is non-blank, the function
        # builds a load-balanced destination. -SystemID is mandatory in that
        # case (NCo requires R3NAME to route to a candidate app server).
        [string]$MessageServer = '',
        [string]$LogonGroup    = '',
        [string]$SystemID      = '',

        # Phase 4.3: Client / User / Password / Language are NOT Mandatory any
        # more. When empty (or still a literal %%TOKEN%%), the function falls
        # back to the AI-session's pinned connection profile in
        # runtime/connections.json (DPAPI-decrypted password). This makes every
        # downstream RFC caller work without each one having to plumb
        # sap_password through settings.json. Callers that explicitly pass real
        # values are untouched -- the fallback only fills empty slots.
        [string]$Client   = '',
        [string]$User     = '',
        [string]$Password = '',
        [string]$Language = '',
        [string]$DestName = "SAPDEV"
    )

    # ---- Phase 4.3 cred fallback: pinned connection profile -----------------
    # Detect "field needs fallback" = empty OR still a literal %%TOKEN%%.
    function _Needs($v) {
        if ([string]::IsNullOrWhiteSpace($v)) { return $true }
        if ($v.StartsWith('%%') -and $v.EndsWith('%%')) { return $true }
        return $false
    }
    $needAny = (_Needs $Server) -and (_Needs $MessageServer)   # at least one endpoint
    if (-not $needAny) { $needAny = (_Needs $Client) -or (_Needs $User) -or (_Needs $Password) }
    if ($needAny) {
        try {
            $libDir = $PSScriptRoot
            if (-not (Get-Command Get-SapCurrentConnectionProfile -ErrorAction SilentlyContinue)) {
                $sl = Join-Path $libDir 'sap_settings_lib.ps1'
                $cl = Join-Path $libDir 'sap_connection_lib.ps1'
                if (Test-Path $sl) { . $sl }
                if (Test-Path $cl) { . $cl }
            }
            $prof = $null
            if (Get-Command Get-SapCurrentConnectionProfile -ErrorAction SilentlyContinue) {
                $prof = Get-SapCurrentConnectionProfile
            }
            if ($prof) {
                # Endpoint: prefer existing input shape (direct vs load-balanced);
                # only fill blanks.
                if (_Needs $Server)        { $Server        = "$($prof.application_server)" }
                if (_Needs $Sysnr)         { $Sysnr         = "$($prof.system_number)" }
                if (_Needs $MessageServer) { $MessageServer = "$($prof.message_server)" }
                if (_Needs $LogonGroup)    { $LogonGroup    = "$($prof.logon_group)" }
                if (_Needs $SystemID)      { $SystemID      = "$($prof.system_id)" }
                if (_Needs $Client)        { $Client        = "$($prof.client)" }
                if (_Needs $User)          { $User          = "$($prof.user)" }
                if (_Needs $Language)      { $Language      = "$($prof.language)" }
                if (_Needs $Password) {
                    $pwdField = "$($prof.password_dpapi)"
                    if (-not [string]::IsNullOrWhiteSpace($pwdField)) {
                        $dpapiPs = Join-Path $libDir 'sap_dpapi.ps1'
                        if (Test-Path $dpapiPs) {
                            try {
                                $Password = (& $dpapiPs -Action unprotect -Value $pwdField 2>$null) -as [string]
                                if ($Password) { $Password = $Password.Trim() }
                            } catch {
                                Write-Host "WARN: Connect-SapRfc: DPAPI decrypt failed ($($_.Exception.Message)); password stays empty."
                            }
                        }
                    }
                }
            }
        } catch {
            # Best-effort fallback; if it throws (lib not loadable, pin missing),
            # we fall through to the mandatory-field check below.
        }
    }
    if ([string]::IsNullOrWhiteSpace($Language)) { $Language = 'EN' }
    if ([string]::IsNullOrWhiteSpace($Client))   { Write-Host "ERROR: Connect-SapRfc -Client is empty and no pinned profile resolved Client. Run /sap-login first."; return $null }
    if ([string]::IsNullOrWhiteSpace($User))     { Write-Host "ERROR: Connect-SapRfc -User is empty and no pinned profile resolved User. Run /sap-login first."; return $null }
    if ([string]::IsNullOrWhiteSpace($Password)) { Write-Host "ERROR: Connect-SapRfc -Password is empty. Save the password on this connection via /sap-login (Step 5b)."; return $null }

    # Validate exactly one endpoint mode is selected. If both -Server and
    # -MessageServer are non-blank, prefer direct (matches the historic
    # implicit behaviour) but warn.
    $useDirect = -not [string]::IsNullOrWhiteSpace($Server)
    $useMsg    = -not [string]::IsNullOrWhiteSpace($MessageServer)
    if (-not $useDirect -and -not $useMsg) {
        Write-Host "ERROR: Connect-SapRfc requires either -Server (direct) or -MessageServer (load-balanced)."
        return $null
    }
    if ($useDirect -and $useMsg) {
        Write-Host "WARN: Connect-SapRfc got both -Server and -MessageServer; using direct (-Server)."
        $useMsg = $false
    }
    if ($useDirect -and [string]::IsNullOrWhiteSpace($Sysnr)) {
        Write-Host "ERROR: Connect-SapRfc -Server requires -Sysnr (2-digit system number)."
        return $null
    }
    if ($useMsg -and [string]::IsNullOrWhiteSpace($SystemID)) {
        Write-Host "ERROR: Connect-SapRfc -MessageServer requires -SystemID (R3NAME / 3-letter SID)."
        return $null
    }

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
            # Settings read merges settings.json + settings.local.json — see
            # sap_settings_lib.ps1.
            $settingsLib = Join-Path (Split-Path -Parent $PSCommandPath) 'sap_settings_lib.ps1'
            if (Test-Path $settingsLib) { . $settingsLib }
            $cfgWork = ''; $cfgLog = ''
            if (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue) {
                $cfgWork = Get-SapSettingValue 'work_dir' ''
                $cfgLog  = Get-SapSettingValue 'log_dir'  ''
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
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::Name,         $uniqueName)
    if ($useDirect) {
        $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::AppServerHost, $Server)
        $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::SystemNumber,  $Sysnr)
    } else {
        # Load-balanced: NCo requires MSHOST + GROUP + R3NAME.
        # LogonGroup defaults to "PUBLIC" when blank (NCo treats empty as
        # invalid; SAP GUI defaults to "SPACE" but for RFC we follow NCo's
        # documented default of "PUBLIC").
        $effGroup = if ([string]::IsNullOrWhiteSpace($LogonGroup)) { 'PUBLIC' } else { $LogonGroup }
        $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::MessageServerHost, $MessageServer)
        $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::LogonGroup,        $effGroup)
        $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::SystemID,          $SystemID)
    }
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::Client,        $Client)
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::User,          $User)
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::Password,      $Password)
    $params.Add([SAP.Middleware.Connector.RfcConfigParameters]::Language,      $Language)

    try {
        $dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($params)
        $dest.Ping()
        if ($useDirect) {
            Write-Host "INFO: RFC connected to $Server (sysnr $Sysnr) client $Client (NCo 3.1, direct)."
        } else {
            $effGroupMsg = if ([string]::IsNullOrWhiteSpace($LogonGroup)) { 'PUBLIC (default)' } else { $LogonGroup }
            Write-Host "INFO: RFC connected to $SystemID via msrv=$MessageServer group=$effGroupMsg client=$Client (NCo 3.1, load-balanced)."
        }
        $script:_SapRfc_Params = $params
        # Also expose at caller scope so legacy `RemoveDestination($g_rfcParams)` keeps working,
        # and re-publish the credential values as $g_sap* so consumers don't need their own
        # 6-line credential block (post-connect uses like $fn.SetValue("LANGU",$g_sapLanguage)).
        Set-Variable -Scope 1 -Name g_rfcParams     -Value $params        -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapServer     -Value $Server        -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapSysnr      -Value $Sysnr         -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapMsgServer  -Value $MessageServer -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapLogonGroup -Value $LogonGroup    -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapSystemId   -Value $SystemID      -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapClient     -Value $Client        -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapUser       -Value $User          -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapPassword   -Value $Password      -ErrorAction SilentlyContinue
        Set-Variable -Scope 1 -Name g_sapLanguage   -Value $Language      -ErrorAction SilentlyContinue
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
# NOTE: every NCo method call must be cast to [void] or piped to Out-Null —
# IRfcStructure.SetValue() etc. return the structure (fluent API) and PS
# captures the return value into the function's output pipeline, so callers
# get an Object[] instead of the table they expected.
function Add-RfcField($fn, [string]$name) {
    $tbl = $fn.GetTable("FIELDS")
    [void]$tbl.Append()
    [void]$tbl.SetValue("FIELDNAME", $name)
}

# Append an OPTIONS row (TEXT=<where>) to an RFC_READ_TABLE function call.
function Add-RfcOption($fn, [string]$where) {
    $tbl = $fn.GetTable("OPTIONS")
    [void]$tbl.Append()
    [void]$tbl.SetValue("TEXT", $where)
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
    # SetValue must be cast to [void] — NCo's IRfcFunction.SetValue returns
    # the function itself (fluent API), which PowerShell otherwise captures
    # into this function's output pipeline. That polluted return is what
    # caused the historic "$fn is an Object[]" cascade where callers ended
    # up calling GetTable() on an array and got cryptic
    # "PARAMETER DELIMITER ... cannot convert CHAR1 into IRfcTable" errors.
    [void]$fn.SetValue("QUERY_TABLE", $Table)
    [void]$fn.SetValue("DELIMITER",   $Delimiter)
    # CRITICAL: IRfcFunction implements IEnumerable<RfcParameter>; PowerShell's
    # output pipeline auto-enumerates IEnumerables, so a bare `return $fn`
    # would unroll the function into N RfcParameter objects and the caller
    # would receive an Object[] of parameters instead of the function itself.
    # The unary `,` operator wraps the value in a single-element array which
    # PS then unwraps back to the original object — preserving identity.
    return ,$fn
}
