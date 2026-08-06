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
#   - DDDDLSRC (CDS/DDL source: SOURCE = STRING). Verify DDLS via TADIR +
#              DD02L/DD25L (classic) or DWINACTIV (activation state); read the
#              DDL text through CL_DD_DDL_HANDLER, not RFC_READ_TABLE.
#
# Callers that go through `New-RfcReadTable` (recommended) get this guard for
# free. Callers that still use `$dest.Repository.CreateFunction("RFC_READ_TABLE")`
# directly MUST invoke `Assert-RfcReadTableAllowed -QueryTable <name>` after
# the first `SetValue("QUERY_TABLE", ...)`.
#
# CROSS-SYSTEM TARGET GUARD (SAPDEV_EXPECT_SYSTEM / SAPDEV_EXPECT_CLIENT)
# -----------------------------------------------------------------------
# Connect-SapRfc mirrors AssertSapGuiTarget (sap_attach_lib.vbs) on the RFC
# transport. Every successful connect stamps one line:
#
#     RFC_TARGET: system=<SID> client=<NNN> user=<U> endpoint=<...> via=<source>
#
# (via = pin | gui-active | default | single-profile | explicit-params --
# which step of the resolution chain chose the target), matching the
# GUI_TARGET convention so transcripts carry provenance for BOTH transports.
# When the calling wrapper exported SAPDEV_EXPECT_SYSTEM / SAPDEV_EXPECT_CLIENT
# (Set-SapGuiTargetExpectation in sap_connection_lib.ps1 -- child processes
# inherit them), a mismatching resolution is a HARD REFUSAL (ERROR + $null,
# before logon when the identity is known pre-connect): continuing would
# read/write TWO DIFFERENT SAP SYSTEMS in one run. Unset expectation = legacy
# behaviour, still stamped.
#
# Identity comparison uses the resolved PROFILE's system_name/client. It must
# NOT use RfcDestination.SystemID -- that is the configured R3NAME and is
# EMPTY on a direct -Server/-Sysnr connection (the d7942b5 trap). For
# caller-supplied endpoints the guard attributes the SID via an exact
# endpoint match against the saved connection store, then falls back to the
# live logon identity in RfcDestination.SystemAttributes (best-effort; same
# read as _RfcDestIdentity in sap_rfc_read_source.ps1).
#
# A DELIBERATE cross-system connect (the second leg of /sap-compare,
# /sap-transport-sequencer, /sap-cc-* source reads) must clear the pair in
# its own process first (Set-SapGuiTargetExpectation -Clear) -- those skills
# set no expectation today, so they are unaffected until one is exported.
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
    # Detect "field needs fallback" = empty, a literal %%TOKEN%%, or an
    # unsubstituted THE_<FIELD> doc placeholder.
    function _Needs($v) {
        if ([string]::IsNullOrWhiteSpace($v)) { return $true }
        if ($v.StartsWith('%%') -and $v.EndsWith('%%')) { return $true }
        # An unsubstituted 'THE_<FIELD>' doc placeholder: several SKILL.md
        # token-fill blocks emit THE_SERVER / THE_SYSNR / THE_CLIENT / THE_USER
        # / THE_PASSWORD / THE_LANGUAGE when the intent is "let the pinned-
        # profile fallback supply this". Treat it as needs-fallback so it never
        # reaches NCo as a literal -- otherwise NCo raised, e.g.,
        # "THE_SYSNR is not a valid system number" and the skill exited 2.
        # Case-SENSITIVE (-cmatch): the placeholder convention is all-uppercase,
        # so this never swallows a real mixed/lower-case value (hostname / user
        # / logon group). Accepting a real all-uppercase THE_* connection value
        # as a placeholder is a deliberate trade-off (fix 2026-06-07).
        if ($v -cmatch '^THE_[A-Z_]+$') { return $true }
        return $false
    }
    # Remember whether each endpoint slot came from the caller (explicit)
    # vs. was filled by the profile fallback below. Used after fallback to
    # decide direct-vs-load-balanced when the profile carries BOTH (which
    # happens routinely for load-balanced logins -- SAP GUI also reports
    # an internal-name application_server alongside the message_server).
    $explicitServer        = -not (_Needs $Server)
    $explicitMessageServer = -not (_Needs $MessageServer)
    $needAny = (_Needs $Server) -and (_Needs $MessageServer)   # at least one endpoint
    if (-not $needAny) { $needAny = (_Needs $Client) -or (_Needs $User) -or (_Needs $Password) }
    # Resolution provenance for the RFC_TARGET stamp + target guard below.
    $prof = $null; $profVia = ''
    if ($needAny) {
        try {
            $libDir = $PSScriptRoot
            if (-not (Get-Command Get-SapCurrentConnectionProfile -ErrorAction SilentlyContinue)) {
                $sl = Join-Path $libDir 'sap_settings_lib.ps1'
                $cl = Join-Path $libDir 'sap_connection_lib.ps1'
                if (Test-Path $sl) { . $sl }
                if (Test-Path $cl) { . $cl }
            }
            $gcpCmd = Get-Command Get-SapCurrentConnectionProfile -ErrorAction SilentlyContinue
            if ($gcpCmd) {
                # -PreferGuiActive: when no AI-session pin resolves, prefer the
                # profile matching the SAP GUI session this AI session is
                # actually driving over the saved DEFAULT profile. Without this,
                # a manual GUI login that bypassed /sap-login's pin step let RFC
                # silently target the unrelated default system (wrong-system
                # write hazard). Explicit-param callers never reach this block;
                # pinned sessions resolve the pin first (GUI step is skipped).
                if ($gcpCmd.Parameters.ContainsKey('ResolvedVia')) {
                    $prof = Get-SapCurrentConnectionProfile -PreferGuiActive -ResolvedVia ([ref]$profVia)
                } else {
                    # Older sap_connection_lib.ps1 without the out-param
                    # (mixed plugin-cache versions): resolve without provenance.
                    $prof = Get-SapCurrentConnectionProfile -PreferGuiActive
                }
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

    # Phase 4.4: classify the failure mode so the error is actionable.
    # When the fallback ran but produced nothing usable, inspect the store
    # to tell the user WHY -- no profiles, multiple profiles + no pin, or
    # one profile but password missing.
    if ($needAny -and -not $prof) {
        $store = $null
        try {
            if (Get-Command Read-SapConnectionStore -ErrorAction SilentlyContinue) {
                $store = Read-SapConnectionStore
            }
        } catch { }
        $profileCount = 0
        if ($store -and $store.connections) { $profileCount = @($store.connections).Count }
        if ($profileCount -eq 0) {
            Write-Host "ERROR: Connect-SapRfc: no SAP connection profiles saved. Run /sap-login to add one."
            return $null
        }
        if ($profileCount -gt 1) {
            Write-Host "ERROR: Connect-SapRfc: $profileCount SAP profiles saved but none pinned to this AI session. Run /sap-login --switch <SID> (e.g. S4D) or /sap-login --list to see options."
            return $null
        }
        $single = @($store.connections)[0]
        if ([string]::IsNullOrWhiteSpace("$($single.password_dpapi)")) {
            Write-Host "ERROR: Connect-SapRfc: profile '$($single.description)' has no saved password. Run /sap-login Step 5b to save it (or /sap-login to log in interactively)."
            return $null
        }
        # Profile found, password present, but resolution still came up empty
        # -- fall through to the field-by-field checks below for a final
        # message that names the missing slot.
    }

    if ([string]::IsNullOrWhiteSpace($Client))   { Write-Host "ERROR: Connect-SapRfc -Client is empty and no pinned profile resolved Client. Run /sap-login --list to see saved profiles, then /sap-login --switch <ref>."; return $null }
    if ([string]::IsNullOrWhiteSpace($User))     { Write-Host "ERROR: Connect-SapRfc -User is empty and no pinned profile resolved User. Run /sap-login --list to see saved profiles, then /sap-login --switch <ref>."; return $null }
    if ([string]::IsNullOrWhiteSpace($Password)) { Write-Host "ERROR: Connect-SapRfc -Password is empty. Save the password on this connection via /sap-login (Step 5b), or run /sap-login --check to confirm DPAPI decryption works."; return $null }

    # Validate exactly one endpoint mode is selected. If both -Server and
    # -MessageServer are non-blank, the precedence depends on PROVENANCE:
    #   * Caller passed BOTH explicitly                    -> prefer direct
    #     (historic behaviour; explicit overrides win, with a WARN).
    #   * Caller explicitly passed direct AND profile      -> direct wins
    #     supplied message_server                              (explicit beats fallback).
    #   * Caller explicitly passed message_server          -> load-balanced wins
    #     AND profile supplied application_server              (explicit beats fallback).
    #   * BOTH came from the profile fallback              -> prefer LOAD-BALANCED.
    #     SAP GUI captures both fields for load-balanced
    #     logins (Info.ApplicationServer returns whichever
    #     physical instance the message server routed to --
    #     usually an internal name that won't DNS-resolve
    #     from the workstation). The user's *intent* is
    #     load-balanced -- that's what they typed. Picking
    #     direct silently downgrades to a routing that will
    #     fail on `hostname unknown`.
    $useDirect = -not [string]::IsNullOrWhiteSpace($Server)
    $useMsg    = -not [string]::IsNullOrWhiteSpace($MessageServer)
    if (-not $useDirect -and -not $useMsg) {
        Write-Host "ERROR: Connect-SapRfc requires either -Server (direct) or -MessageServer (load-balanced)."
        return $null
    }
    if ($useDirect -and $useMsg) {
        if ($explicitServer -and $explicitMessageServer) {
            Write-Host "WARN: Connect-SapRfc got both -Server and -MessageServer (both explicit); using direct (-Server)."
            $useMsg = $false
        } elseif ($explicitServer) {
            # Caller wanted direct; profile happened to add message_server.
            $useMsg = $false
        } elseif ($explicitMessageServer) {
            # Caller wanted load-balanced; profile happened to add application_server.
            $useDirect = $false
        } else {
            # Both filled from profile fallback -- load-balanced is the
            # deliberate signal (user typed message_server at login time;
            # application_server is the post-routing internal name).
            Write-Host "INFO: Connect-SapRfc: profile has both endpoints; preferring load-balanced (-MessageServer) -- message_server is the user's deliberate choice, application_server is the post-routing internal name."
            $useDirect = $false
        }
    }
    if ($useDirect -and [string]::IsNullOrWhiteSpace($Sysnr)) {
        Write-Host "ERROR: Connect-SapRfc -Server requires -Sysnr (2-digit system number)."
        return $null
    }
    if ($useMsg -and [string]::IsNullOrWhiteSpace($SystemID)) {
        Write-Host "ERROR: Connect-SapRfc -MessageServer requires -SystemID (R3NAME / 3-letter SID)."
        return $null
    }

    # ---- Cross-system target guard (RFC transport) --------------------------
    # Mirror of AssertSapGuiTarget (sap_attach_lib.vbs). See the header block
    # "CROSS-SYSTEM TARGET GUARD" and gotcha 5 in
    # contributing/parallel_safe_session_attach.md. Live incident 2026-08-06
    # (second cross-system contamination, RFC transport this time): a headless
    # child session's fresh session id resolved a PINLESS AI session, this
    # function fell through to the saved DEFAULT profile (S4H/400) and
    # faithfully read the wrong system's source while the driver's pin, syntax
    # check and verdict all pointed at S4D/100. Nothing on the RFC leg said
    # which system it used -- the GUI leg has refused that drift since
    # d7942b5; this closes the same hole here.
    $expSys    = "$env:SAPDEV_EXPECT_SYSTEM".Trim()
    $expCli    = "$env:SAPDEV_EXPECT_CLIENT".Trim()
    $effClient = "$Client".Trim()

    # Attribute the target system. The resolved profile's system_name applies
    # only when the ENDPOINT actually came from the profile fallback -- a
    # caller that passed -Server / -MessageServer itself chose the target
    # (e.g. the deliberate second legs of /sap-compare or
    # /sap-transport-sequencer), and the pinned profile's system_name says
    # nothing about where that endpoint points. Comparison deliberately uses
    # profile identity, NOT $dest.SystemID -- that is the configured R3NAME
    # and is EMPTY on a direct -Server/-Sysnr connection (the d7942b5 trap).
    $endpointFromProfile = ($null -ne $prof) -and -not ($explicitServer -or $explicitMessageServer)
    $rfcVia = 'explicit-params'
    if ($endpointFromProfile) { $rfcVia = if ($profVia) { $profVia } else { 'profile' } }
    $resolvedSid = ''
    if ($endpointFromProfile) { $resolvedSid = "$($prof.system_name)".Trim() }
    if (-not $resolvedSid -and $useMsg) { $resolvedSid = "$SystemID".Trim() }   # R3NAME = declared SID
    if (-not $resolvedSid -and ($expSys -or $expCli)) {
        # Expectation declared but the caller supplied its own direct endpoint:
        # attribute it via an exact endpoint match against the saved connection
        # store. Covers the verify/lookup scripts that resolve the pinned
        # profile themselves and pass -Server/-Sysnr explicitly -- their SID
        # becomes checkable BEFORE logon. Best-effort; no match leaves the
        # post-connect SystemAttributes leg below to decide.
        try {
            if (-not (Get-Command Read-SapConnectionStore -ErrorAction SilentlyContinue)) {
                $sl2 = Join-Path $PSScriptRoot 'sap_settings_lib.ps1'
                $cl2 = Join-Path $PSScriptRoot 'sap_connection_lib.ps1'
                if (Test-Path $sl2) { . $sl2 }
                if (Test-Path $cl2) { . $cl2 }
            }
            $epStore = $null
            if (Get-Command Read-SapConnectionStore -ErrorAction SilentlyContinue) { $epStore = Read-SapConnectionStore }
            if ($epStore -and $epStore.connections) {
                $epSids = @($epStore.connections | Where-Object {
                    ("$($_.application_server)".Trim() -eq "$Server".Trim()) -and
                    ("$($_.system_number)".Trim()      -eq "$Sysnr".Trim())
                } | ForEach-Object { "$($_.system_name)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
                if ($epSids.Count -eq 1) { $resolvedSid = $epSids[0] }
            }
        } catch { }
    }

    if ($expSys -or $expCli) {
        $tgtBad = $false
        if ($expSys -and $resolvedSid -and ($resolvedSid -ne $expSys)) { $tgtBad = $true }
        if ($expCli -and $effClient -and ($effClient -ne $expCli))     { $tgtBad = $true }
        if ($tgtBad) {
            $shownSid = if ($resolvedSid) { $resolvedSid } else { '?' }
            Write-Host "ERROR: SAP RFC target mismatch. Expected $expSys/$expCli but Connect-SapRfc resolved $shownSid/$effClient (via $rfcVia)."
            Write-Host "       This run declared its SAP target via SAPDEV_EXPECT_SYSTEM/_CLIENT (Set-SapGuiTargetExpectation), so continuing would read/write TWO DIFFERENT SAP SYSTEMS in one run. Refusing before logon."
            Write-Host "       Fix: run /sap-login --switch $expSys to re-pin this AI session (headless child sessions: hand the driver's SAPDEV_AI_SESSION_ID through), or clear SAPDEV_EXPECT_SYSTEM/_CLIENT first if connecting to another system is genuinely intended (deliberate cross-system compare)."
            return $null
        }
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
            # Settings read merges settings.json + settings.local.json -- see
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
            # Non-fatal -- NCo will fall back to the original CWD if redirect fails.
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

        # ---- RFC_TARGET stamp + post-connect leg of the target guard --------
        # Best-effort live identity from the logon handshake
        # (RfcDestination.SystemAttributes -- same read as _RfcDestIdentity in
        # sap_rfc_read_source.ps1; degrades to blank, never throws). Fills the
        # stamp for caller-supplied endpoints no saved profile matched, and
        # closes the guard for that path.
        $liveSid = ''
        try {
            $sa = $dest.SystemAttributes
            if ($sa) { $liveSid = "$($sa.SystemID)".Trim() }
        } catch { }
        if ($resolvedSid -and $liveSid -and ($liveSid -ne $resolvedSid)) {
            Write-Host "WARN: Connect-SapRfc: the resolved target claims system '$resolvedSid' but the live logon reports '$liveSid' -- stale saved profile? Re-run /sap-login to refresh it."
        }
        $stampSid = if ($resolvedSid) { $resolvedSid } else { $liveSid }
        if (-not $stampSid) { $stampSid = '?' }
        $endpointDesc = if ($useDirect) { "${Server}:${Sysnr}" } else { "/M/${MessageServer}/G/${effGroup}/S/${SystemID}" }
        Write-Host "RFC_TARGET: system=$stampSid client=$effClient user=$User endpoint=$endpointDesc via=$rfcVia"

        if ($expSys -and -not $resolvedSid) {
            # SID was not decidable before logon (caller-supplied endpoint,
            # no store match). Enforce on the live identity; mirror
            # AssertSapGuiTarget's unverified-target refusal when even the
            # live read comes back blank -- an unverifiable target is exactly
            # the case this guard exists for.
            if (-not $liveSid) {
                Write-Host "ERROR: SAP RFC target could not be identified (caller-supplied endpoint matches no saved profile and SystemAttributes.SystemID is blank) but SAPDEV_EXPECT_SYSTEM=$expSys was declared. Refusing to use an unverified connection."
                try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($params) | Out-Null } catch { }
                return $null
            }
            if ($liveSid -ne $expSys) {
                Write-Host "ERROR: SAP RFC target mismatch. Expected $expSys/$expCli but the live logon landed on $liveSid/$effClient (endpoint $endpointDesc, via $rfcVia)."
                Write-Host "       This run declared its SAP target via SAPDEV_EXPECT_SYSTEM/_CLIENT (Set-SapGuiTargetExpectation), so continuing would read/write TWO DIFFERENT SAP SYSTEMS in one run."
                Write-Host "       Fix: run /sap-login --switch $expSys to re-pin this AI session (headless child sessions: hand the driver's SAPDEV_AI_SESSION_ID through), or clear SAPDEV_EXPECT_SYSTEM/_CLIENT first if connecting to another system is genuinely intended (deliberate cross-system compare)."
                try { [SAP.Middleware.Connector.RfcDestinationManager]::RemoveDestination($params) | Out-Null } catch { }
                return $null
            }
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
# NOTE: every NCo method call must be cast to [void] or piped to Out-Null --
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
$script:_SapRfc_ForbiddenReadTables = @('REPOSRC', 'DDDDLSRC')

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
            'DDDDLSRC' { "DDDDLSRC.SOURCE is a STRING column that raises ASSIGN ... CASTING in SAPLSDTX (same class as REPOSRC; confirmed by the D13 CDS spike). Verify CDS/DDL objects via TADIR(OBJECT=DDLS) + the generated SQL view (DD02L/DD25L) or DWINACTIV for activation state; read DDL source through the CL_DD_DDL_HANDLER API, not RFC_READ_TABLE." }
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
    # SetValue must be cast to [void] -- NCo's IRfcFunction.SetValue returns
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
    # PS then unwraps back to the original object -- preserving identity.
    return ,$fn
}
