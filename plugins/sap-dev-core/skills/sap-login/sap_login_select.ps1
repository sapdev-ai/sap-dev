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
#   init        Bootstrap. Writes {work_dir}\runtime\ai_session_id.txt if
#               missing; runs a one-shot migration from the legacy
#               settings.json single-connection fields into connections.json.
#               Idempotent.
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
#               to the live connection in the broker registry, pins the AI
#               session, and writes the pin file at
#               {work_dir}\runtime\sap_active_session.json.
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
    [ValidateSet('init','decide','list','set-default','switch','delete','finalize')]
    [string]$Action = 'decide',

    [string]$WorkTemp = '',
    [string]$AiSessionId = '',

    # decide-mode picks
    [string]$PickProfileId      = '',
    [string]$PickConnectionPath = '',

    # set-default / switch / delete
    [string]$ProfileId = '',

    # finalize-mode inputs
    [string]$CapturedJson        = '',   # raw JSON from capture VBS (one-line)
    [string]$NewLogonDescription = '',   # user-supplied label, optional
    [string]$NewPasswordDpapi    = ''    # ciphertext from sap_dpapi.ps1, optional
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
$script:_ParamCapturedJson        = $CapturedJson
$script:_ParamNewLogonDescription = $NewLogonDescription
$script:_ParamNewPasswordDpapi    = $NewPasswordDpapi

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
$CapturedJson        = $script:_ParamCapturedJson
$NewLogonDescription = $script:_ParamNewLogonDescription
$NewPasswordDpapi    = $script:_ParamNewPasswordDpapi

if ([string]::IsNullOrWhiteSpace($WorkTemp)) {
    $WorkTemp = Join-Path (Get-SapWorkDir) 'temp'
}
if (-not (Test-Path $WorkTemp)) { New-Item -ItemType Directory -Force -Path $WorkTemp | Out-Null }
$script:WorkRuntimeDir = Get-SapWorkRuntimeDir
$script:BrokerPs1      = Join-Path $script:SharedDir 'sap_session_broker.ps1'
$script:CaptureVbs     = Join-Path $PSScriptRoot 'references\sap_login_capture_active_session.vbs'
$script:Cscript        = 'C:\Windows\SysWOW64\cscript.exe'
$script:PinFilePath    = Join-Path $script:WorkRuntimeDir 'sap_active_session.json'
$script:AiSessionFile  = Join-Path $script:WorkRuntimeDir 'ai_session_id.txt'

# ---------------------------------------------------------------------------
# AI-session bootstrap. The SessionStart hook is the preferred mechanism
# (writes ai_session_id.txt at conversation start). When the hook is not
# wired, fall back to deriving an id here and persisting it.
# ---------------------------------------------------------------------------
function Resolve-AiSessionId {
    if (-not [string]::IsNullOrWhiteSpace($AiSessionId)) { return $AiSessionId }
    if ($env:SAPDEV_AI_SESSION_ID) { return $env:SAPDEV_AI_SESSION_ID }
    if (Test-Path $script:AiSessionFile) {
        $v = (Get-Content $script:AiSessionFile -Raw -Encoding UTF8).Trim()
        if ($v) { return $v }
    }
    # Fallback: derive + persist. Format: ai_pid<PID>_<YYYYMMDDHHMMSS>.
    $id = "ai_pid$PID" + "_" + (Get-Date -Format 'yyyyMMddHHmmss')
    [System.IO.File]::WriteAllText($script:AiSessionFile, $id, [System.Text.UTF8Encoding]::new($false))
    return $id
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
    $r = Invoke-Broker -Args @('-Action','discover','-WorkTemp',$WorkTemp)
    # `list` then reads the v3 registry and emits a JSON blob.
    $r = Invoke-Broker -Args @('-Action','list','-WorkTemp',$WorkTemp)
    $blob = ($r.raw | Out-String).Trim()
    # The `list` action ConvertTo-Json's the entire registry. Find the JSON block.
    $start = $blob.IndexOf('{')
    if ($start -lt 0) { return $null }
    try {
        return ($blob.Substring($start) | ConvertFrom-Json)
    } catch {
        return $null
    }
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
                Write-Host "ATTACH_ACTIVE: path=$($a.connection_path) connection_path=$($a.connection_path) connection_id=$($p.id) description='$($p.description)'"
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
        Write-Host "ATTACH_ACTIVE: path=$($a.connection_path) connection_path=$($a.connection_path) description='$descEff'"
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
                    Write-Host "RESOLVED: path=$($a.connection_path) connection_path=$($a.connection_path) connection_id=$($pinnedProfile.id) description='$($pinnedProfile.description)' source=pin"
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
                Write-Host "ATTACH_ACTIVE: path=$($a.connection_path) connection_path=$($a.connection_path) connection_id=$($defP.id) description='$($defP.description)' source=default_match"
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
# Action: set-default
# =============================================================================
function Invoke-SetDefault {
    if (-not $ProfileId) { Write-Host 'ERROR: -ProfileId required'; exit 1 }
    $p = Find-SapConnectionById -Id $ProfileId
    if (-not $p) { Write-Host "ERROR: profile id=$ProfileId not found"; exit 1 }
    Set-SapDefaultConnection -Id $ProfileId
    Write-Host "SUCCESS: default_target_id=$ProfileId description='$($p.description)'"
}

# =============================================================================
# Action: switch  -- re-pin AI session to a different profile.
# =============================================================================
function Invoke-Switch {
    if (-not $ProfileId) { Write-Host 'ERROR: -ProfileId required'; exit 1 }
    $p = Find-SapConnectionById -Id $ProfileId
    if (-not $p) { Write-Host "ERROR: profile id=$ProfileId not found"; exit 1 }
    $aid = Resolve-AiSessionId
    $r = Invoke-Broker -Args @('-Action','pin','-WorkTemp',$WorkTemp,
                                '-AiSessionId',$aid,'-ConnectionId',$p.id,
                                '-PinReason','user_switched')
    foreach ($line in $r.raw) { Write-Host $line }
    Write-Host "SUCCESS: switched ai_session=$aid -> connection_id=$($p.id) description='$($p.description)'"
}

# =============================================================================
# Action: delete
# =============================================================================
function Invoke-Delete {
    if (-not $ProfileId) { Write-Host 'ERROR: -ProfileId required'; exit 1 }
    $p = Find-SapConnectionById -Id $ProfileId
    if (-not $p) { Write-Host "ERROR: profile id=$ProfileId not found"; exit 1 }
    Remove-SapConnection -Id $ProfileId
    Write-Host "SUCCESS: deleted profile id=$ProfileId description='$($p.description)'"
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

    # Build a profile candidate from the captured fields + user inputs.
    $candidate = New-SapConnectionInfo `
        -SystemName        "$($cap.system_name)" `
        -Client            "$($cap.client)" `
        -User              "$($cap.user)" `
        -Language          "$($cap.language)" `
        -ApplicationServer "$($cap.application_server)" `
        -SystemNumber      "$($cap.system_number)" `
        -MessageServer     "$($cap.message_server)" `
        -LogonGroup        "$($cap.logon_group)" `
        -SystemId          "$($cap.system_name)" `
        -LogonPadEntry     "$NewLogonDescription" `
        -PasswordDpapi     "$NewPasswordDpapi" `
        -Description       "$NewLogonDescription" `
        -GuiTested         $true
    # The capture VBS also emits logon_pad_entry (= connection_string). If the
    # user did not supply a new label, prefer the captured Logon-pad entry.
    if (-not $candidate.logon_pad_entry -and $cap.logon_pad_entry) {
        $candidate.logon_pad_entry = "$($cap.logon_pad_entry)"
    }

    # Save (dedup against existing).
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

    # Write the active-session pin file so attach_lib's strategy-3 reads it.
    $pinObj = @{
        session_path       = $sessionPath
        connection_path    = $connPath
        connection_id      = $saved.id
        ai_session_id      = $aid
        system_name        = $saved.system_name
        client             = $saved.client
        user               = $saved.user
        language           = $saved.language
        description        = $saved.description
        application_server = $saved.application_server
        system_number      = $saved.system_number
        message_server     = $saved.message_server
        logon_group        = $saved.logon_group
        system_id          = $saved.system_id
        recorded_at        = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        recorded_by_skill  = 'sap-login'
    }
    [System.IO.File]::WriteAllText(
        $script:PinFilePath,
        ($pinObj | ConvertTo-Json -Depth 6),
        [System.Text.UTF8Encoding]::new($false))

    Write-Host "INFO: profile saved id=$($saved.id) description='$($saved.description)'"
    Write-Host "INFO: pin file at $($script:PinFilePath)"
    Write-Host "SUCCESS: connection_id=$($saved.id) description='$($saved.description)' session_path=$sessionPath"
}

# =============================================================================
# Dispatch
# =============================================================================
switch ($Action) {
    'init'         { Invoke-Init }
    'decide'       { Invoke-Decide }
    'list'         { Invoke-List }
    'set-default'  { Invoke-SetDefault }
    'switch'       { Invoke-Switch }
    'delete'       { Invoke-Delete }
    'finalize'     { Invoke-Finalize }
}
exit 0
