# =============================================================================
# sap_login_select.ps1  -  Multi-profile connection selection driver for sap-login.
# -----------------------------------------------------------------------------
# This script is the brain of /sap-login under the Phase-4 multi-profile
# model. It is invoked by SKILL.md across several stages; each stage outputs
# a structured signal that the SKILL.md (driven by Claude) parses and acts
# on. The script never prompts the user directly -- prompting is Claude's
# job via AskUserQuestion.
#
# Stages (-Action):
#
#   init        Bootstrap. Resolves this conversation's AI-session id
#               via Get-SapAiSessionId (parent-PID walk; creates
#               {work_dir}\runtime\ai_session_by_pid\<owner_pid>.txt as
#               needed) and runs a one-shot migration from the legacy
#               settings.json single-connection fields into
#               connections.json. Idempotent.
#
#   decide      Inspect (active SAP connections) x (saved profiles) x
#               (AI-session pin) and emit ONE of these stdout signals:
#                 RESOLVED        - existing pin matches an active session; attach.
#                 ATTACH_ACTIVE   - pick is a live SAP connection; attach.
#                 CONNECT_PROFILE - pick is a saved profile; open new GUI conn.
#                 PICK_NEEDED     - user must choose from a list (JSON follows).
#                 ADD_NEEDED      - no profiles + no active conns; prompt for new.
#               Accepts -PickProfileId or -PickConnectionPath when re-invoked
#               after a Claude-side picker round-trip.
#
#   list        Dump profiles + active connections + pin state to stdout.
#               Read-only.
#
#   set-default <id>   Mark a profile as default_target_id; clear flag elsewhere.
#
#   switch <id>        Re-pin the current AI session to profile <id>.
#                      Releases any claims this AI session holds on the
#                      old connection (broker `pin` action handles this).
#
#   delete <id>        Remove a profile. If it was default, default clears.
#
#   finalize    Called by SKILL.md AFTER sap_login.vbs has successfully
#               opened+logged into a SAP connection (or after attaching to
#               an existing one). Reads the JSON record produced by
#               sap_login_capture_active_session.vbs, builds/merges a
#               profile (dedup via 4-step compare), assigns a connection_id
#               to the live connection in the broker registry, and pins
#               the AI session. Phase 4.2 removed the pin file —
#               consumer skills use Get-SapCurrentSessionPath /
#               Get-SapCurrentConnectionProfile to resolve session path
#               and version info instead.
#
# Output protocol
# ---------------
# Every line of stdout has one of the prefixes:
#     INFO:    | WARN:    | ERROR:   | DEBUG:
#     RESOLVED:        path=...  connection_id=...  description=...
#     ATTACH_ACTIVE:   path=...  connection_path=...  description=...
#     CONNECT_PROFILE: id=...    description=...
#     PICK_NEEDED:     <json-array of options>
#     ADD_NEEDED:
#     SUCCESS:         connection_id=...  description=...  session_path=...
#     LIST:            <json-blob>
#
# Exit code: 0 on success/expected signal, 1 on error.
#
# Library dependencies (auto-resolved via PSScriptRoot/parent traversal):
#     sap_connection_lib.ps1, sap_settings_lib.ps1, sap_dpapi.ps1,
#     sap_session_broker.ps1 (invoked as child process)
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('init','decide','list','set-default','switch','delete','finalize','check','landscape-entries')]
    [string]$Action = 'decide',

    [string]$WorkTemp = '',
    [string]$AiSessionId = '',

    # decide-mode picks
    [string]$PickProfileId      = '',
    [string]$PickConnectionPath = '',

    # set-default / switch / delete: accepts hint forms (UUID, SID, SID/CLIENT,
    # SID/CLIENT/USER, description substring, 'last', 'default'). UUIDs work as
    # before — the matcher's first rule is UUID exact, so legacy callers passing
    # a GUID see no behaviour change.
    [string]$ProfileId = '',

    # switch-mode: skip the GUI fall-through. Default behaviour is "re-pin + open
    # GUI session for the new profile"; pass -NoConnect to re-pin only.
    [switch]$NoConnect,

    # finalize-mode inputs
    [string]$CapturedJson        = '',   # raw JSON from capture VBS (one-line)
    [string]$NewLogonDescription = '',   # user-supplied label, optional
    [string]$NewPasswordDpapi    = '',   # ciphertext from sap_dpapi.ps1, optional
    [string]$UserAppServerHint   = ''    # hostname the user typed in Step 2b ADD flow,
                                         # optional. Used by Resolve-SapApplicationServer
                                         # when the captured Info.ApplicationServer is
                                         # an internal name that doesn't DNS-resolve.
)

$ErrorActionPreference = 'Stop'

# Save our parameters before any dot-source. `sap_dpapi.ps1` (and any other
# CLI-style helper we dot-source) declares its own `param([string]$Action,
# [string]$Value)` block, which would rebind our $Action to empty when
# dot-sourced. Capture the originals, restore them after libs load.
$script:_ParamAction              = $Action
$script:_ParamValue               = $null
$script:_ParamWorkTemp            = $WorkTemp
$script:_ParamAiSessionId         = $AiSessionId
$script:_ParamPickProfileId       = $PickProfileId
$script:_ParamPickConnectionPath  = $PickConnectionPath
$script:_ParamProfileId           = $ProfileId
$script:_ParamNoConnect           = [bool]$NoConnect
$script:_ParamCapturedJson        = $CapturedJson
$script:_ParamNewLogonDescription = $NewLogonDescription
$script:_ParamNewPasswordDpapi    = $NewPasswordDpapi
$script:_ParamUserAppServerHint   = $UserAppServerHint

# ---------------------------------------------------------------------------
# Resolve shared paths.
# ---------------------------------------------------------------------------
$script:SharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'shared\scripts'
. (Join-Path $script:SharedDir 'sap_settings_lib.ps1')
. (Join-Path $script:SharedDir 'sap_dpapi.ps1')
. (Join-Path $script:SharedDir 'sap_connection_lib.ps1')

# Restore — the dot-source rebound $Action / $Value to empty.
$Action              = $script:_ParamAction
$WorkTemp            = $script:_ParamWorkTemp
$AiSessionId         = $script:_ParamAiSessionId
$PickProfileId       = $script:_ParamPickProfileId
$PickConnectionPath  = $script:_ParamPickConnectionPath
$ProfileId           = $script:_ParamProfileId
$NoConnect           = [switch]$script:_ParamNoConnect
$CapturedJson        = $script:_ParamCapturedJson
$NewLogonDescription = $script:_ParamNewLogonDescription
$NewPasswordDpapi    = $script:_ParamNewPasswordDpapi
$UserAppServerHint   = $script:_ParamUserAppServerHint

if ([string]::IsNullOrWhiteSpace($WorkTemp)) {
    $WorkTemp = Join-Path (Get-SapWorkDir) 'temp'
}
if (-not (Test-Path $WorkTemp)) { New-Item -ItemType Directory -Force -Path $WorkTemp | Out-Null }
$script:WorkRuntimeDir = Get-SapWorkRuntimeDir
$script:BrokerPs1      = Join-Path $script:SharedDir 'sap_session_broker.ps1'
$script:CaptureVbs     = Join-Path $PSScriptRoot 'references\sap_login_capture_active_session.vbs'
$script:Cscript        = 'C:\Windows\SysWOW64\cscript.exe'
$script:PinFilePath    = $null   # Phase 4.2: pin file eliminated — see Invoke-Finalize

# ---------------------------------------------------------------------------
# AI-session id resolution. Delegates to Get-SapAiSessionId in
# sap_connection_lib.ps1 which derives a stable id per Claude Code
# conversation by walking the parent-process tree. Parallel conversations
# get DIFFERENT ids; subagents within one conversation share the SAME id.
#
# Explicit -AiSessionId on the cmdline still wins (used by `switch` to
# operate on a remembered id from a previous run).
# ---------------------------------------------------------------------------
function Resolve-AiSessionId {
    if (-not [string]::IsNullOrWhiteSpace($AiSessionId)) { return $AiSessionId }
    return Get-SapAiSessionId
}

# ---------------------------------------------------------------------------
# Broker helpers (shell out — broker maintains its own mutex).
# ---------------------------------------------------------------------------
function Invoke-Broker {
    param([Parameter(Mandatory)] [string[]] $Args)
    $cmdArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $script:BrokerPs1) + $Args
    $raw = & 'powershell.exe' @cmdArgs 2>&1
    return @{ raw = $raw; exit = $LASTEXITCODE }
}

function Get-LiveSapConnections {
    # Run broker `discover` to register newcomers + fold a fresh enumeration.
    # When SAP COM is unreachable (no live GUI), discover exits 2 and
    # Sweep-StaleEntries deliberately leaves the persisted registry alone —
    # so the next `list` would echo back ghost connections from a previous
    # session. Guard against that: a non-zero discover exit means there is no
    # live state, so report zero connections (preserve ai_sessions for pin
    # introspection by the caller, which is still meaningful as a record of
    # intent even when nothing is currently attached).
    $rDiscover = Invoke-Broker -Args @('-Action','discover','-WorkTemp',$WorkTemp)
    # `list` then reads the v3 registry and emits a JSON blob.
    $r = Invoke-Broker -Args @('-Action','list','-WorkTemp',$WorkTemp)
    $blob = ($r.raw | Out-String).Trim()
    # The `list` action ConvertTo-Json's the entire registry. Find the JSON block.
    $start = $blob.IndexOf('{')
    if ($start -lt 0) { return $null }
    try {
        $obj = $blob.Substring($start) | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($rDiscover.exit -ne 0) {
        # Force-empty the connections list so decide doesn't emit ATTACH_ACTIVE
        # against a stale block. ai_sessions stays intact.
        $obj | Add-Member -NotePropertyName connections -NotePropertyValue @() -Force
    }
    return $obj
}

# ---------------------------------------------------------------------------
# Helpers — convert registry connection blocks + profiles into the canonical
# normalised hashtable shape expected by Test-SapConnectionsEqual.
# ---------------------------------------------------------------------------
function ConvertTo-IdentityHash {
    param($Source)
    if ($null -eq $Source) {
        return @{
            system_name = ''; client = ''; user = ''
            logon_pad_entry = ''; message_server = ''
            application_server = ''; system_number = ''
            description = ''
        }
    }
    $h = @{
        system_name        = "$($Source.system_name)"
        client             = "$($Source.client)"
        user               = "$($Source.user)"
        logon_pad_entry    = "$($Source.logon_pad_entry)"
        message_server     = "$($Source.message_server)"
        application_server = "$($Source.application_server)"
        system_number      = "$($Source.system_number)"
        description        = "$($Source.description)"
    }
    # Registry blocks use 'description' for the SAP-Logon entry name.
    if ((-not $h.logon_pad_entry) -and $h.description) { $h.logon_pad_entry = $h.description }
    return $h
}

function Match-ActiveToProfile {
    param($ActiveConn, $Profiles)
    $a = ConvertTo-IdentityHash $ActiveConn
    foreach ($p in $Profiles) {
        if (Test-SapConnectionsEqual -A $a -B (ConvertTo-IdentityHash $p)) { return $p }
    }
    return $null
}

# =============================================================================
# Action: init  -- bootstrap ai_session_id + migrate legacy settings.
# =============================================================================
function Invoke-Init {
    $aid = Resolve-AiSessionId
    Write-Host "INFO: ai_session_id=$aid"

    $migrated = Import-LegacyConnectionFromSettings
    if ($migrated) {
        Write-Host "INFO: migrated legacy connection id=$($migrated.id) description='$($migrated.description)'"
    } else {
        Write-Host "INFO: no legacy single-connection settings to migrate"
    }
    Write-Host "SUCCESS: init complete"
}

# =============================================================================
# Action: list  -- read-only state dump.
# =============================================================================
function Invoke-List {
    $aid    = Resolve-AiSessionId
    $store  = Read-SapConnectionStore
    $live   = Get-LiveSapConnections
    $pin    = $null
    if ($live -and $live.ai_sessions -and $live.ai_sessions.PSObject.Properties[$aid]) {
        $pin = $live.ai_sessions.$aid
    }
    $out = @{
        ai_session_id   = $aid
        pin             = $pin
        default_target  = $store.default_target_id
        profiles        = @($store.connections | ForEach-Object {
            @{
                id                 = $_.id
                description        = $_.description
                system_name        = $_.system_name
                client             = $_.client
                user               = $_.user
                language           = $_.language
                logon_pad_entry    = $_.logon_pad_entry
                message_server     = $_.message_server
                logon_group        = $_.logon_group
                system_id          = $_.system_id
                application_server = $_.application_server
                system_number      = $_.system_number
                is_default_target  = $_.is_default_target
                last_used_at       = $_.last_used_at
            }
        })
        active_connections = if ($live -and $live.connections) {
            @($live.connections | ForEach-Object {
                @{
                    connection_path    = $_.connection_path
                    connection_id      = $_.connection_id
                    description        = $_.description
                    system_name        = $_.system_name
                    client             = $_.client
                    user               = $_.user
                    language           = $_.language
                    message_server     = $_.message_server
                    logon_group        = $_.logon_group
                    system_id          = $_.system_id
                    application_server = $_.application_server
                    system_number      = $_.system_number
                }
            })
        } else { @() }
    }
    $json = $out | ConvertTo-Json -Depth 8 -Compress
    $json = _NormalizeEmptyArrays -Json $json
    Write-Host ("LIST: " + $json)
}

# =============================================================================
# Action: decide  -- the main selection algorithm.
# =============================================================================
function Invoke-Decide {
    $aid    = Resolve-AiSessionId
    $store  = Read-SapConnectionStore
    $live   = Get-LiveSapConnections
    $defP   = Get-SapDefaultConnection
    $pin    = $null
    if ($live -and $live.ai_sessions -and $live.ai_sessions.PSObject.Properties[$aid]) {
        $pin = $live.ai_sessions.$aid
    }

    $activeConns = @()
    if ($live -and $live.connections) { $activeConns = @($live.connections) }

    # --- Honor user-supplied pick (re-invocation after AskUserQuestion) ----
    if ($PickProfileId) {
        $p = Find-SapConnectionById -Id $PickProfileId
        if (-not $p) { Write-Host "ERROR: profile id=$PickProfileId not found"; exit 1 }
        # If the picked profile already has a matching active connection, attach.
        foreach ($a in $activeConns) {
            $match = Match-ActiveToProfile -ActiveConn $a -Profiles @($p)
            if ($match) {
                Write-Host "ATTACH_ACTIVE: path=$($a.connection_path)/ses[0] connection_path=$($a.connection_path) connection_id=$($p.id) description='$($p.description)'"
                return
            }
        }
        Write-Host "CONNECT_PROFILE: id=$($p.id) description='$($p.description)'"
        return
    }
    if ($PickConnectionPath) {
        $a = $activeConns | Where-Object { $_.connection_path -eq $PickConnectionPath } | Select-Object -First 1
        if (-not $a) { Write-Host "ERROR: active connection $PickConnectionPath not found"; exit 1 }
        $match = Match-ActiveToProfile -ActiveConn $a -Profiles $store.connections
        $descEff = if ($match) { $match.description } else { $a.description }
        Write-Host "ATTACH_ACTIVE: path=$($a.connection_path)/ses[0] connection_path=$($a.connection_path) description='$descEff'"
        return
    }

    # --- Phase A: existing AI-session pin resolves? ------------------------
    if ($pin -and $pin.connection_id) {
        $pinnedProfile = Find-SapConnectionById -Id $pin.connection_id
        # Try to attach to an active connection matching the pin.
        if ($pinnedProfile) {
            foreach ($a in $activeConns) {
                $match = Match-ActiveToProfile -ActiveConn $a -Profiles @($pinnedProfile)
                if ($match) {
                    Write-Host "RESOLVED: path=$($a.connection_path)/ses[0] connection_path=$($a.connection_path) connection_id=$($pinnedProfile.id) description='$($pinnedProfile.description)' source=pin"
                    return
                }
            }
            # Pin still resolves to a known profile, but no active conn — open one.
            Write-Host "CONNECT_PROFILE: id=$($pinnedProfile.id) description='$($pinnedProfile.description)' source=pin"
            return
        }
        Write-Host "WARN: AI-session pin points to unknown profile id=$($pin.connection_id); falling through to fresh selection"
    }

    # --- Phase B: no/invalid pin --------------------------------------------
    $profileCount = $store.connections.Count
    $activeCount  = $activeConns.Count

    if ($activeCount -eq 0 -and $profileCount -eq 0) {
        Write-Host "ADD_NEEDED:"
        return
    }
    if ($activeCount -eq 0 -and $defP -and $profileCount -eq 1) {
        Write-Host "CONNECT_PROFILE: id=$($defP.id) description='$($defP.description)' source=default_singleton"
        return
    }
    if ($activeCount -eq 0) {
        # Multiple profiles, no active — picker.
        Emit-Picker -Profiles $store.connections -Active @() -Default $defP
        return
    }

    # active >= 1
    if ($activeCount -eq 1) {
        $a = $activeConns[0]
        if ($defP) {
            $matchDefault = Test-SapConnectionsEqual -A (ConvertTo-IdentityHash $a) -B (ConvertTo-IdentityHash $defP)
            if ($matchDefault) {
                Write-Host "ATTACH_ACTIVE: path=$($a.connection_path)/ses[0] connection_path=$($a.connection_path) connection_id=$($defP.id) description='$($defP.description)' source=default_match"
                return
            }
        }
        # Single active, but not the default (or no default) — show picker
        # offering "use this active one" vs "switch to a saved profile".
        Emit-Picker -Profiles $store.connections -Active $activeConns -Default $defP
        return
    }

    # active > 1
    Emit-Picker -Profiles $store.connections -Active $activeConns -Default $defP
}

function Emit-Picker {
    param($Profiles, $Active, $Default)
    $options = @()
    # Active connections first, marked.
    foreach ($a in $Active) {
        $matched = Match-ActiveToProfile -ActiveConn $a -Profiles $Profiles
        $opt = @{
            kind               = 'active'
            connection_path    = "$($a.connection_path)"
            connection_id      = if ($matched) { $matched.id } else { '' }
            description        = if ($matched) { $matched.description } else { $a.description }
            system_name        = "$($a.system_name)"
            client             = "$($a.client)"
            user               = "$($a.user)"
            language           = "$($a.language)"
            endpoint_summary   = (Format-EndpointSummary $a)
            is_default         = ($matched -and $matched.is_default_target)
        }
        $options += $opt
    }
    # Saved profiles that aren't already shown as active.
    foreach ($p in $Profiles) {
        $alreadyActive = $false
        foreach ($a in $Active) {
            if (Test-SapConnectionsEqual -A (ConvertTo-IdentityHash $a) -B (ConvertTo-IdentityHash $p)) {
                $alreadyActive = $true; break
            }
        }
        if ($alreadyActive) { continue }
        $options += @{
            kind             = 'profile'
            profile_id       = "$($p.id)"
            description      = "$($p.description)"
            system_name      = "$($p.system_name)"
            client           = "$($p.client)"
            user             = "$($p.user)"
            language         = "$($p.language)"
            endpoint_summary = (Format-EndpointSummary $p)
            is_default       = [bool]$p.is_default_target
        }
    }
    $json = @{ options = $options } | ConvertTo-Json -Depth 8 -Compress
    $json = _NormalizeEmptyArrays -Json $json
    Write-Host ("PICK_NEEDED: " + $json)
}

function _NormalizeEmptyArrays {
    # PowerShell 5.1's ConvertTo-Json serialises an empty @() inside a
    # hashtable value as "{}" instead of "[]" (a long-standing quirk —
    # storage unwraps the empty array, and ConvertTo-Json then treats the
    # resulting $null/empty placeholder as an object). Fix by post-
    # processing the JSON string for the known array-typed fields we emit.
    param(
        [Parameter(Mandatory)] [string] $Json,
        [string[]] $Fields = @('profiles','active_connections','options')
    )
    foreach ($f in $Fields) {
        $pattern = '"' + [regex]::Escape($f) + '"\s*:\s*\{\s*\}'
        $Json = $Json -replace $pattern, ('"' + $f + '":[]')
    }
    return $Json
}

function Format-EndpointSummary {
    param($c)
    if ($c.message_server)      { return "msrv=$($c.message_server)/grp=$($c.logon_group)/sid=$($c.system_id)" }
    if ($c.application_server)  { return "host=$($c.application_server)/sysnr=$($c.system_number)" }
    if ($c.logon_pad_entry)     { return "logon_pad=$($c.logon_pad_entry)" }
    if ($c.description)         { return "logon_pad=$($c.description)" }
    return ''
}

# =============================================================================
# Hint resolution -- shared by set-default / switch / delete.
# =============================================================================
function Resolve-ProfileFromRef {
    <#
    .SYNOPSIS
        Resolve $ProfileId (now a hint, not necessarily a UUID) to a single
        profile, applying the output protocol on no-match / ambiguous.
    .OUTPUTS
        Profile object on single match. On no-match emits ERROR + exits 1.
        On multi-match emits AMBIGUOUS: <json> + exits 2 so the SKILL.md
        dispatch can drive a picker and re-invoke with the chosen UUID.
    #>
    if (-not $ProfileId) { Write-Host 'ERROR: -ProfileId required'; exit 1 }
    $matches = @(Resolve-SapProfileHint -Hint $ProfileId)
    if ($matches.Count -eq 0) {
        Write-Host "ERROR: no profile matches '$ProfileId'. Run /sap-login --list."
        exit 1
    }
    if ($matches.Count -gt 1) {
        $options = @($matches | ForEach-Object {
            @{
                profile_id  = "$($_.id)"
                description = "$($_.description)"
                system_name = "$($_.system_name)"
                client      = "$($_.client)"
                user        = "$($_.user)"
                endpoint_summary = (Format-EndpointSummary $_)
            }
        })
        $json = @{ options = $options } | ConvertTo-Json -Depth 6 -Compress
        $json = _NormalizeEmptyArrays -Json $json
        Write-Host ("AMBIGUOUS: " + $json)
        exit 2
    }
    return $matches[0]
}

# =============================================================================
# Action: set-default
# =============================================================================
function Invoke-SetDefault {
    $p = Resolve-ProfileFromRef
    Set-SapDefaultConnection -Id $p.id
    Write-Host "SUCCESS: default_target_id=$($p.id) description='$($p.description)'"
}

# =============================================================================
# Action: switch  -- re-pin AI session to a different profile.
#
# Phase 4.4: also bumps last_used_at so `--switch last` reflects the most
# recent switch (not just the last login finalize). Without -NoConnect the
# action emits CONTINUE_TO_STEP1 after SUCCESS so the SKILL.md dispatch
# falls through to opening the GUI session for the new profile.
# =============================================================================
function Invoke-Switch {
    $p = Resolve-ProfileFromRef
    $aid = Resolve-AiSessionId
    $r = Invoke-Broker -Args @('-Action','pin','-WorkTemp',$WorkTemp,
                                '-AiSessionId',$aid,'-ConnectionId',$p.id,
                                '-PinReason','user_switched')
    foreach ($line in $r.raw) { Write-Host $line }

    # Bump last_used_at so `--switch last` reflects the most recent switch.
    try {
        $store = Read-SapConnectionStore
        $target = $store.connections | Where-Object { "$($_.id)" -eq "$($p.id)" } | Select-Object -First 1
        if ($target) {
            $target.last_used_at = (Get-Date).ToString('o')
            Write-SapConnectionStore -Store $store
        }
    } catch {
        Write-Host "WARN: failed to bump last_used_at: $($_.Exception.Message)"
    }

    Write-Host "SUCCESS: switched ai_session=$aid -> connection_id=$($p.id) description='$($p.description)'"

    if (-not $NoConnect) {
        # Tell the SKILL.md dispatch to fall through to Step 1 (connect).
        # The skill driver re-runs `decide` for the new pin; from there
        # ATTACH_ACTIVE / CONNECT_PROFILE take over.
        Write-Host "CONTINUE_TO_STEP1: connection_id=$($p.id) description='$($p.description)'"
    }
}

# =============================================================================
# Action: delete
# =============================================================================
function Invoke-Delete {
    $p = Resolve-ProfileFromRef
    Remove-SapConnection -Id $p.id
    Write-Host "SUCCESS: deleted profile id=$($p.id) description='$($p.description)'"
}

# =============================================================================
# Action: finalize  -- save profile + set connection_id + pin AI session.
# =============================================================================
function Invoke-Finalize {
    if (-not $CapturedJson) { Write-Host 'ERROR: -CapturedJson required'; exit 1 }
    try {
        $cap = $CapturedJson | ConvertFrom-Json
    } catch {
        Write-Host "ERROR: -CapturedJson is not valid JSON: $($_.Exception.Message)"; exit 1
    }

    # Reconcile the captured ApplicationServer with what the workstation can
    # actually DNS-resolve. SAP's Info.ApplicationServer returns the host's
    # internal identity, which on NAT / dynamic-DNS / reverse-proxy
    # deployments is NOT routable from the client. Cascade: captured ->
    # user hint -> SAPUILandscape.xml / saplogon.ini lookup. Never blocks;
    # on total failure we keep the captured value and emit a WARN so RFC
    # consumers know to expect a hostname-unknown error.
    #
    # SKIPPED for load-balanced logins: when message_server is non-empty,
    # routing goes through the message server + logon group + system_id;
    # application_server in that case is a post-routing internal name SAP
    # GUI reports for diagnostic purposes only, not used for RFC. Saving
    # it unchanged is correct — Connect-SapRfc's profile-fallback logic
    # prefers load-balanced when both endpoints are populated.
    $padHint = "$($cap.logon_pad_entry)"
    $capMsgSrv = "$($cap.message_server)"
    if (-not [string]::IsNullOrWhiteSpace($capMsgSrv)) {
        $appServerForSave = "$($cap.application_server)"
        $sysnrForSave     = "$($cap.system_number)"
        Write-Host "INFO: load-balanced login detected (message_server='$capMsgSrv'); RFC will route via -MessageServer / -LogonGroup / -SystemID. application_server='$appServerForSave' saved as informational (not used for RFC routing)."
    } else {
        $reslv = Resolve-SapApplicationServer `
            -CapturedAppServer "$($cap.application_server)" `
            -UserHint          "$UserAppServerHint" `
            -LogonPadEntry     $padHint
        $appServerForSave = "$($reslv.Server)"
        $sysnrForSave     = "$($cap.system_number)"
        if ([string]::IsNullOrWhiteSpace($sysnrForSave) -and (_NotEmpty $reslv.Sysnr)) {
            $sysnrForSave = "$($reslv.Sysnr)"   # only fill from saplogon if capture left it blank
        }
        switch ("$($reslv.Source)") {
            'captured'              { Write-Host "INFO: application_server='$appServerForSave' (captured; DNS-resolvable)" }
            'user_hint'             { Write-Host "INFO: application_server='$appServerForSave' (user hint resolves; replacing captured '$($reslv.CaptureRaw)')" }
            'saplogon'              { Write-Host "INFO: application_server='$appServerForSave' (resolved via SAP Logon Pad entry '$padHint'; replacing captured '$($reslv.CaptureRaw)')" }
            'captured_unresolvable' { Write-Host "WARN: application_server='$appServerForSave' is NOT DNS-resolvable from this workstation. SAP GUI will work; RFC will not until you correct this value (edit connections.json or rerun /sap-login with -UserAppServerHint <hostname>)." }
            'none'                  { Write-Host "WARN: no application_server captured or hinted; RFC will not work." }
        }
    }

    # Build a profile candidate from the captured fields + user inputs.
    # Version fields (gui_*, server_*) come from the merged capture JSON:
    # GUI side populates gui_*; sap_rfc_system_info.ps1 populates server_*.
    # All optional — Save-SapConnection only updates non-empty fields.
    $candidate = New-SapConnectionInfo `
        -SystemName          "$($cap.system_name)" `
        -Client              "$($cap.client)" `
        -User                "$($cap.user)" `
        -Language            "$($cap.language)" `
        -ApplicationServer   "$appServerForSave" `
        -SystemNumber        "$sysnrForSave" `
        -MessageServer       "$($cap.message_server)" `
        -LogonGroup          "$($cap.logon_group)" `
        -SystemId            "$($cap.system_name)" `
        -LogonPadEntry       "$NewLogonDescription" `
        -PasswordDpapi       "$NewPasswordDpapi" `
        -Description         "$NewLogonDescription" `
        -GuiTested           $true `
        -GuiVersionRaw       "$($cap.gui_version_raw)" `
        -GuiMajor            ([int]$cap.gui_major) `
        -GuiMinor            ([int]$cap.gui_minor) `
        -GuiPatch            ([int]$cap.gui_patch) `
        -ServerKernelRelease "$($cap.server_kernel_release)" `
        -ServerReleaseFamily "$($cap.server_release_family)" `
        -ServerReleaseMarker "$($cap.server_release_marker)" `
        -ServerReleaseRaw    "$($cap.server_release_raw)" `
        -SoftwareComponents  $cap.software_components
    # The capture VBS also emits logon_pad_entry (= connection_string). If the
    # user did not supply a new label, prefer the captured Logon-pad entry.
    if (-not $candidate.logon_pad_entry -and $cap.logon_pad_entry) {
        $candidate.logon_pad_entry = "$($cap.logon_pad_entry)"
    }

    # Save (dedup against existing). Version fields propagate into the profile.
    $saved = Save-SapConnection -Profile $candidate

    # Set connection_id on the live broker registry block.
    $sessionPath = "$($cap.session_path)"
    $connPath = ''
    if ($sessionPath -match '^(/app/con\[\d+\])/ses\[\d+\]$') { $connPath = $matches[1] }
    if ($connPath) {
        $null = Invoke-Broker -Args @('-Action','set-connection-id','-WorkTemp',$WorkTemp,
                                       '-ConnectionPath',$connPath,'-ConnectionId',$saved.id)
    }

    # Pin AI session.
    $aid = Resolve-AiSessionId
    $null = Invoke-Broker -Args @('-Action','pin','-WorkTemp',$WorkTemp,
                                   '-AiSessionId',$aid,'-ConnectionId',$saved.id,
                                   '-PinReason','login_finalize')

    # Populate the registry's entries[] for the pinned connection by running
    # broker discover. Without this, Get-SapCurrentSessionPath (used by
    # consumer skills) sees the connection block with connection_id set but
    # entries[] empty, falls through to sole-connection default, and refuses
    # in multi-connection scenarios.
    $null = Invoke-Broker -Args @('-Action','discover','-WorkTemp',$WorkTemp)

    # Phase 4.2: NO pin file written. Consumer skills resolve the session
    # path via Get-SapCurrentSessionPath (which reads session_registry.json's
    # ai_sessions pin + broker registry) and version info via
    # Get-SapCurrentConnectionProfile (which reads connections.json by
    # connection_id). The pin file is gone.

    Write-Host "INFO: profile saved id=$($saved.id) description='$($saved.description)'"
    Write-Host "INFO: ai_session=$aid pinned to connection_id=$($saved.id)"
    Write-Host "SUCCESS: connection_id=$($saved.id) description='$($saved.description)' session_path=$sessionPath"
}

# =============================================================================
# Action: check  -- per-profile health doctor (Phase 4.4).
#
# Gates per profile, in order: DPAPI decrypt, DNS resolve, RFC ping, live GUI
# session. Read-only — never mutates connections.json or session_registry.json.
# RFC gate shells out to 32-bit Windows PowerShell (SAP NCo is 32-bit only).
# Plaintext password rides via process env var SAPDEV_RFC_PING_PAYLOAD (b64
# JSON), removed in a finally block after each profile.
# =============================================================================
function Invoke-Check {
    $store = Read-SapConnectionStore
    if (-not $store -or -not $store.connections -or $store.connections.Count -eq 0) {
        Write-Host "INFO: no saved profiles."
        return
    }

    # Read live registry for GUI gate (no broker discover — read-only doctor).
    $liveConnIds = @{}
    try {
        $regPath = Join-Path $script:WorkRuntimeDir 'session_registry.json'
        if (Test-Path -LiteralPath $regPath) {
            $reg = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($reg -and $reg.connections) {
                foreach ($c in $reg.connections) {
                    if ("$($c.connection_id)") { $liveConnIds["$($c.connection_id)"] = $true }
                }
            }
        }
    } catch { }

    $fmt = "{0,-32} {1,-6} {2,-6} {3,-6} {4,-4} {5}"
    Write-Host ($fmt -f 'DESCRIPTION','DPAPI','DNS','RFC','GUI','NOTE')
    Write-Host ('-' * 100)

    $dpapiPs = Join-Path $script:SharedDir 'sap_dpapi.ps1'
    $rfcLib  = Join-Path $script:SharedDir 'sap_rfc_lib.ps1'
    $psSys32 = 'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe'

    $childCmd = @'
try {
  $b = $env:SAPDEV_RFC_PING_PAYLOAD
  if (-not $b) { Write-Output 'RFC_FAIL: no payload'; exit 1 }
  $j = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json
  . 'RFCLIB_PATH'
  $d = Connect-SapRfc -Server $j.Server -Sysnr $j.Sysnr -Client $j.Client -User $j.User -Password $j.Password -Language $j.Language -MessageServer $j.MessageServer -LogonGroup $j.LogonGroup -SystemID $j.SystemID
  if (-not $d) { Write-Output 'RFC_FAIL: Connect returned null'; exit 1 }
  $null = $d.Ping()
  Disconnect-SapRfc
  Write-Output 'RFC_OK'
} catch { Write-Output ('RFC_FAIL: ' + $_.Exception.Message); exit 1 }
'@
    $childCmd = $childCmd.Replace('RFCLIB_PATH', $rfcLib)

    foreach ($p in $store.connections) {
        $dpapi = 'skip'; $dns = 'skip'; $rfc = 'skip'; $gui = 'no'; $note = ''
        $plaintext = ''

        # ---- DPAPI gate -----------------------------------------------------
        $pwdField = "$($p.password_dpapi)"
        if ($pwdField) {
            if ($pwdField -like 'dpapi:*') {
                try {
                    $out = & $dpapiPs -Action unprotect -Value $pwdField 2>&1
                    $rc = $LASTEXITCODE
                    $plaintext = ("$out").Trim()
                    if ($rc -eq 0 -and $plaintext) {
                        $dpapi = 'ok'
                    } else {
                        $dpapi = 'fail'
                        $note = 'decrypt failed (different Windows user / machine?)'
                        $plaintext = ''
                    }
                } catch {
                    $dpapi = 'fail'
                    $note = "decrypt threw: $($_.Exception.Message)"
                    $plaintext = ''
                }
            } else {
                # Legacy plaintext at rest — flag and reuse for RFC.
                $dpapi = 'plain'
                $note = 'password stored in plaintext'
                $plaintext = $pwdField
            }
        }

        # ---- DNS gate -------------------------------------------------------
        $hostToCheck = ''
        if     ("$($p.message_server)")     { $hostToCheck = "$($p.message_server)" }
        elseif ("$($p.application_server)") { $hostToCheck = "$($p.application_server)" }
        if ($hostToCheck) {
            if (Test-SapHostResolvable -HostName $hostToCheck) {
                $dns = 'ok'
            } else {
                $dns = 'fail'
                if (-not $note) { $note = "$hostToCheck unresolvable" }
            }
        }

        # ---- RFC gate -------------------------------------------------------
        if (($dpapi -eq 'ok' -or $dpapi -eq 'plain') -and $dns -eq 'ok') {
            $payload = @{
                Server        = "$($p.application_server)"
                Sysnr         = "$($p.system_number)"
                Client        = "$($p.client)"
                User          = "$($p.user)"
                Password      = $plaintext
                Language      = $(if ("$($p.language)") { "$($p.language)" } else { 'EN' })
                MessageServer = "$($p.message_server)"
                LogonGroup    = "$($p.logon_group)"
                SystemID      = "$($p.system_id)"
            }
            $json = $payload | ConvertTo-Json -Compress
            $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
            $env:SAPDEV_RFC_PING_PAYLOAD = $b64
            try {
                $out = & $psSys32 -NoProfile -ExecutionPolicy Bypass -Command $childCmd 2>&1
                $rc  = $LASTEXITCODE
                $tail = ("$out").Trim()
                if ($rc -eq 0 -and $tail -match 'RFC_OK') {
                    $rfc = 'ok'
                } else {
                    $rfc = 'fail'
                    if (-not $note) {
                        # Pick the last non-empty line as the reason.
                        $reason = ($tail -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1)
                        if ($reason) { $note = $reason -replace '^RFC_FAIL:\s*', '' }
                    }
                }
            } catch {
                $rfc = 'fail'
                if (-not $note) { $note = $_.Exception.Message }
            } finally {
                Remove-Item Env:SAPDEV_RFC_PING_PAYLOAD -ErrorAction SilentlyContinue
            }
        }

        # ---- GUI gate -------------------------------------------------------
        if ($liveConnIds["$($p.id)"]) { $gui = 'yes' }

        # ---- Render row -----------------------------------------------------
        $desc = "$($p.description)"
        if ($desc.Length -gt 32) { $desc = $desc.Substring(0, 30) + '..' }
        Write-Host ($fmt -f $desc, $dpapi, $dns, $rfc, $gui, $note)
    }
}

# =============================================================================
# Action: landscape-entries  (Phase 4.4)
#
# Enumerate SAP Logon Pad entries so the ADD_NEEDED flow can show a picker
# instead of asking the user to retype endpoint values. Emits one structured
# line:
#   LANDSCAPE: <json-array>
# Each element: { name, kind, server, system_number, message_server,
# logon_group, system_id, system_name, description, source }.
# Read-only — never touches connections.json.
# =============================================================================
function Invoke-LandscapeEntries {
    $list = @(Get-SapLogonLandscapeEntries)
    if (-not $list -or $list.Count -eq 0) {
        Write-Host "LANDSCAPE: []"
        return
    }
    # Order: user_xml first (highest signal), then global_xml, then ini.
    # Within a source, keep XML enumeration order (matches what SAP Logon shows).
    $sortKey = @{ 'user_xml' = 0; 'global_xml' = 1; 'ini' = 2 }
    $ordered = $list | Sort-Object { $sortKey["$($_.source)"] }
    $json = $ordered | ConvertTo-Json -Depth 4 -Compress
    # A single-element ConvertTo-Json emits a JSON object, not an array. Force
    # array shape for the SKILL.md JSON parser.
    if ($ordered.Count -eq 1) { $json = '[' + $json + ']' }
    Write-Host ("LANDSCAPE: " + $json)
}

# =============================================================================
# Dispatch
# =============================================================================
switch ($Action) {
    'init'              { Invoke-Init }
    'decide'            { Invoke-Decide }
    'list'              { Invoke-List }
    'set-default'       { Invoke-SetDefault }
    'switch'            { Invoke-Switch }
    'delete'            { Invoke-Delete }
    'finalize'          { Invoke-Finalize }
    'check'             { Invoke-Check }
    'landscape-entries' { Invoke-LandscapeEntries }
}
exit 0
