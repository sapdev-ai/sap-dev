# =============================================================================
# sap_connection_lib.ps1  -  Multi-profile SAP connection store.
# -----------------------------------------------------------------------------
# Storage: {work_dir}\runtime\connections.json (durable; survives `temp` wipes).
#   * 'temp\' = ephemeral scratch (cleared by sap-dev-clean)
#   * 'runtime\' = persistent operational state (connections, session pins)
# Passwords are DPAPI-encrypted at rest via the shared sap_dpapi helpers
# (CurrentUser scope, "dpapi:<base64>" prefix). Plaintext is never written.
#
# Identity model
# --------------
# A profile is identified for **dedup** by a 4-step compare against the
# (live or saved) "connection info" tuple. For **runtime references** every
# profile carries a stable UUID 'id' generated once at first save, so edits
# to a profile (server IP changes, etc.) don't break references.
#
# 4-step compare (Test-SapConnectionsEqual) — short-circuits on first match:
#   1. system_name == system_name AND client == client AND user == user.
#      If any differ -> different. Necessary precondition for steps 2-4.
#   2. Both 'logon_pad_entry' non-empty: equal -> SAME.   Else fall through.
#   3. Both 'message_server'  non-empty: equal -> SAME.   Else fall through.
#   4. Both 'application_server' AND 'system_number' non-empty: pair equal
#      on both sides -> SAME. Else -> DIFFERENT.
#
# This is intentionally strict at step (1) (same SID/Client/User is necessary)
# and lenient at steps 2-4 (any one endpoint identifier agreeing is enough).
#
# Concurrency
# -----------
# All reads pass through a per-process cache, invalidated on every write.
# All writes take a named Windows mutex (`SapDevConnectionsStore_v2`),
# 10s timeout, abandoned-mutex tolerated (crash recovery). Pattern mirrors
# sap_session_broker.ps1.
#
# Usage
# -----
#     . "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1"
#     . "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1"
#     . "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1"
#     $store = Read-SapConnectionStore
#     $profile = New-SapConnectionInfo -SystemName 'S4D' -Client '100' -User 'X' ...
#     $saved   = Save-SapConnection -Profile $profile
#
# Public functions:
#   Get-SapWorkRuntimeDir            -> "{work_dir}\runtime"
#   Get-SapConnectionStorePath       -> "{work_dir}\runtime\connections.json"
#   Read-SapConnectionStore          -> hashtable (whole store)
#   Write-SapConnectionStore         -> under mutex; invalidates cache
#   New-SapConnectionInfo            -> normalized hashtable
#   Test-SapConnectionsEqual         -> $true|$false (4-step compare)
#   Find-SapConnectionByMatch        -> first matching profile
#   Find-SapConnectionById           -> profile by UUID
#   Get-SapDefaultConnection         -> profile with is_default_target=$true (or $null)
#   Set-SapDefaultConnection         -> singleton enforce; clears others
#   Save-SapConnection               -> dedup + insert/update; returns saved profile
#   Remove-SapConnection             -> remove by id
#   New-SapConnectionAutoDescription -> "<msgsrv|appsrv>_<sid>_<client>_<user>"
#   Import-LegacyConnectionFromSettings -> one-shot migration of legacy settings.json fields
# =============================================================================

$ErrorActionPreference = 'Stop'

# --- Caches / paths ---------------------------------------------------------

$script:SapConnStore_Cache       = $null
$script:SapConnStore_PathCache   = $null
$script:SapConnStore_MutexName   = 'SapDevConnectionsStore_v2'
$script:SapConnStore_MutexTimeoutMs = 10000

# --- Path resolution --------------------------------------------------------

function Get-SapWorkDir {
    # Resolve via the shared settings helper; default to C:\sap_dev_work
    if (-not (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue)) {
        $libPath = Join-Path $PSScriptRoot 'sap_settings_lib.ps1'
        if (Test-Path $libPath) { . $libPath }
    }
    $wd = ''
    if (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue) {
        $wd = Get-SapSettingValue 'work_dir' ''
    }
    if ([string]::IsNullOrWhiteSpace($wd)) { $wd = 'C:\sap_dev_work' }
    return $wd
}

function Get-SapWorkRuntimeDir {
    $dir = Join-Path (Get-SapWorkDir) 'runtime'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Get-SapConnectionStorePath {
    if ($script:SapConnStore_PathCache) { return $script:SapConnStore_PathCache }
    $script:SapConnStore_PathCache = Join-Path (Get-SapWorkRuntimeDir) 'connections.json'
    return $script:SapConnStore_PathCache
}

# --- Mutex helper -----------------------------------------------------------

function With-ConnectionStoreLock {
    param([scriptblock] $Body)
    $mutex = [System.Threading.Mutex]::new($false, $script:SapConnStore_MutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($script:SapConnStore_MutexTimeoutMs)
        } catch [System.Threading.AbandonedMutexException] {
            # A prior holder crashed before releasing. Continue, but treat
            # the state as questionable — caller is responsible for re-reading.
            $acquired = $true
        }
        if (-not $acquired) {
            throw "sap_connection_lib: could not acquire mutex within $($script:SapConnStore_MutexTimeoutMs)ms"
        }
        & $Body
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        try { $mutex.Dispose() } catch {}
    }
}

# --- Empty store factory ----------------------------------------------------

function New-EmptyConnectionStore {
    return @{
        version           = 2
        default_target_id = ''
        connections       = @()
    }
}

# --- Read / Write -----------------------------------------------------------

function Read-SapConnectionStore {
    if ($null -ne $script:SapConnStore_Cache) { return $script:SapConnStore_Cache }
    $path = Get-SapConnectionStorePath
    if (-not (Test-Path $path)) {
        $script:SapConnStore_Cache = New-EmptyConnectionStore
        return $script:SapConnStore_Cache
    }
    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $script:SapConnStore_Cache = New-EmptyConnectionStore
            return $script:SapConnStore_Cache
        }
        $obj = $raw | ConvertFrom-Json

        $store = New-EmptyConnectionStore
        if ($obj.version)           { $store.version = [int]$obj.version }
        if ($obj.default_target_id) { $store.default_target_id = [string]$obj.default_target_id }
        if ($obj.connections) {
            foreach ($c in $obj.connections) {
                $p = @{}
                foreach ($pp in $c.PSObject.Properties) { $p[$pp.Name] = $pp.Value }
                # Coerce key fields to string / bool defensively.
                foreach ($f in @('id','description','logon_pad_entry','system_name','client','user','language',
                                  'password_dpapi','message_server','logon_group','system_id',
                                  'application_server','system_number','created_at','last_used_at')) {
                    if ($p.ContainsKey($f)) { $p[$f] = "$($p[$f])" } else { $p[$f] = '' }
                }
                foreach ($b in @('is_default_target','rfc_tested','gui_tested')) {
                    if ($p.ContainsKey($b)) { $p[$b] = [bool]$p[$b] } else { $p[$b] = $false }
                }
                $store.connections += $p
            }
        }
        $script:SapConnStore_Cache = $store
        return $store
    } catch {
        Write-Host "WARN: sap_connection_lib: connections.json unreadable ($($_.Exception.Message)); resetting"
        $script:SapConnStore_Cache = New-EmptyConnectionStore
        return $script:SapConnStore_Cache
    }
}

function Reset-SapConnectionStoreCache {
    $script:SapConnStore_Cache = $null
}

function Write-SapConnectionStore {
    param([Parameter(Mandatory)][hashtable] $Store)
    With-ConnectionStoreLock {
        # Coerce the version + atomically write under the mutex.
        if (-not $Store.version)           { $Store.version = 2 }
        if (-not $Store.default_target_id) { $Store.default_target_id = '' }
        if (-not $Store.connections)       { $Store.connections = @() }
        $json = $Store | ConvertTo-Json -Depth 8
        $path = Get-SapConnectionStorePath
        [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    }
    Reset-SapConnectionStoreCache
}

# --- Profile factory --------------------------------------------------------

function New-SapConnectionInfo {
    <#
    .SYNOPSIS
        Return a normalised profile hashtable. Use this anywhere a profile-
        shaped object is needed (active SAP connections, user input, etc.).
    #>
    [CmdletBinding()]
    param(
        [string]$Id                = '',
        [string]$Description       = '',
        [string]$LogonPadEntry     = '',
        [string]$SystemName        = '',
        [string]$Client            = '',
        [string]$User              = '',
        [string]$Language          = '',
        [string]$PasswordDpapi     = '',
        [string]$MessageServer     = '',
        [string]$LogonGroup        = '',
        [string]$SystemId          = '',
        [string]$ApplicationServer = '',
        [string]$SystemNumber      = '',
        [bool]  $IsDefaultTarget   = $false,
        [string]$CreatedAt         = '',
        [string]$LastUsedAt        = '',
        [bool]  $RfcTested         = $false,
        [bool]  $GuiTested         = $false
    )
    return @{
        id                 = "$Id"
        description        = "$Description"
        logon_pad_entry    = "$LogonPadEntry"
        system_name        = "$SystemName"
        client             = "$Client"
        user               = "$User"
        language           = "$Language"
        password_dpapi     = "$PasswordDpapi"
        message_server     = "$MessageServer"
        logon_group        = "$LogonGroup"
        system_id          = "$SystemId"
        application_server = "$ApplicationServer"
        system_number      = "$SystemNumber"
        is_default_target  = [bool]$IsDefaultTarget
        created_at         = "$CreatedAt"
        last_used_at       = "$LastUsedAt"
        rfc_tested         = [bool]$RfcTested
        gui_tested         = [bool]$GuiTested
    }
}

# --- 4-step compare ---------------------------------------------------------

function _NotEmpty {
    param([string]$s)
    return -not [string]::IsNullOrWhiteSpace($s)
}

function Test-SapConnectionsEqual {
    <#
    .SYNOPSIS
        4-step identity compare. Returns $true if the two profile-shaped
        objects describe the same logical SAP connection.
    .DESCRIPTION
        Both inputs must be hashtables produced by New-SapConnectionInfo
        (or ConvertTo-SapConnectionInfo on a live GUI connection record).
        Anything missing the seven identity fields is treated as empty.

        Step 1 is conditional: SystemName is only known post-login (it's
        not in settings.json or in raw user input). A profile imported
        from legacy settings.json or freshly entered by the user has
        system_name='' until the first successful login + capture. We
        treat empty-vs-known SystemName as "not yet decidable" and fall
        through to identifier-based matching (steps 2-4). If both sides
        know SystemName, they must match.

        Client and User are always user-supplied; they require exact match.
    #>
    param(
        [Parameter(Mandatory)] $A,
        [Parameter(Mandatory)] $B
    )

    # Step 1 — precondition. SystemName mismatch only fails when BOTH sides know it.
    if ((_NotEmpty "$($A.system_name)") -and (_NotEmpty "$($B.system_name)") -and
        ("$($A.system_name)" -ne "$($B.system_name)")) {
        return $false
    }
    if (("$($A.client)") -ne ("$($B.client)"))  { return $false }
    if (("$($A.user)")   -ne ("$($B.user)"))    { return $false }

    # Step 2 — Logon pad entry.
    if ((_NotEmpty "$($A.logon_pad_entry)") -and (_NotEmpty "$($B.logon_pad_entry)")) {
        if ("$($A.logon_pad_entry)" -eq "$($B.logon_pad_entry)") { return $true }
        # else fall through
    }

    # Step 3 — MessageServer.
    if ((_NotEmpty "$($A.message_server)") -and (_NotEmpty "$($B.message_server)")) {
        if ("$($A.message_server)" -eq "$($B.message_server)") { return $true }
        # else fall through
    }

    # Step 4 — ApplicationServer + SystemNumber (pair).
    if ((_NotEmpty "$($A.application_server)") -and (_NotEmpty "$($B.application_server)") -and
        (_NotEmpty "$($A.system_number)")      -and (_NotEmpty "$($B.system_number)")) {
        if ("$($A.application_server)" -eq "$($B.application_server)" -and
            "$($A.system_number)"      -eq "$($B.system_number)") { return $true }
    }

    return $false
}

# --- Lookups ----------------------------------------------------------------

function Find-SapConnectionByMatch {
    <#
    .SYNOPSIS
        Return the first stored profile that 4-step-matches $Probe, or $null.
    #>
    param([Parameter(Mandatory)] $Probe)
    $store = Read-SapConnectionStore
    foreach ($p in $store.connections) {
        if (Test-SapConnectionsEqual -A $p -B $Probe) { return $p }
    }
    return $null
}

function Find-SapConnectionById {
    param([Parameter(Mandatory)][string] $Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $store = Read-SapConnectionStore
    return ($store.connections | Where-Object { "$($_.id)" -eq $Id } | Select-Object -First 1)
}

function Get-SapDefaultConnection {
    $store = Read-SapConnectionStore
    if (-not [string]::IsNullOrWhiteSpace($store.default_target_id)) {
        $p = $store.connections | Where-Object { "$($_.id)" -eq $store.default_target_id } | Select-Object -First 1
        if ($p) { return $p }
    }
    # Fallback: flag-based lookup in case default_target_id was hand-edited away.
    return ($store.connections | Where-Object { $_.is_default_target } | Select-Object -First 1)
}

# --- Mutation ---------------------------------------------------------------

function Set-SapDefaultConnection {
    <#
    .SYNOPSIS
        Mark profile $Id as the default and clear the flag on all others.
        Pass an empty $Id to clear the default entirely.
    #>
    param([string] $Id = '')
    $store = Read-SapConnectionStore
    $store.default_target_id = "$Id"
    foreach ($p in $store.connections) {
        $p.is_default_target = ("$($p.id)" -eq "$Id")
    }
    Write-SapConnectionStore -Store $store
}

function New-SapConnectionAutoDescription {
    <#
    .SYNOPSIS
        Build "<msgsrv|appsrv>_<sid>_<client>_<user>" when description blank.
    .NOTES
        Collision-aware: if the derived name already exists on a DIFFERENT
        profile in the store, suffix with the first 4 chars of the UUID.
    #>
    param(
        [Parameter(Mandatory)] $Profile
    )
    if (-not [string]::IsNullOrWhiteSpace("$($Profile.description)")) {
        return "$($Profile.description)"
    }
    $endpoint = ''
    if (_NotEmpty "$($Profile.message_server)")     { $endpoint = "$($Profile.message_server)" }
    elseif (_NotEmpty "$($Profile.application_server)") { $endpoint = "$($Profile.application_server)" }
    else { $endpoint = 'SAP' }

    $base = "$($endpoint)_$($Profile.system_name)_$($Profile.client)_$($Profile.user)"
    $base = $base -replace '[^A-Za-z0-9_\.\-]','_'

    # Collision check vs the rest of the store.
    $store = Read-SapConnectionStore
    $collision = $store.connections | Where-Object {
        "$($_.description)" -eq $base -and "$($_.id)" -ne "$($Profile.id)"
    } | Select-Object -First 1
    if ($collision) {
        $suffix = if ("$($Profile.id)".Length -ge 4) { "$($Profile.id)".Substring(0,4) } else { 'x' }
        return "${base}_$suffix"
    }
    return $base
}

function Save-SapConnection {
    <#
    .SYNOPSIS
        Dedup against existing profiles via 4-step compare, then insert or update.
    .DESCRIPTION
        * If a match exists -> update it. Logon-pad-entry is overwritten ONLY
          when $Profile supplies a non-empty value (user told us "this is the
          new Logon description"); empty input preserves the existing value.
          Password, language, MessageServer/Group, SystemID, ApplicationServer/
          SystemNumber are updated when supplied non-empty.
        * If no match -> assign a UUID, set created_at, append.
        * Auto-derive description if blank.
        * Touch last_used_at.
        Returns the saved profile (with assigned id + description).
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $Profile
    )

    $store = Read-SapConnectionStore
    $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

    $match = $null
    foreach ($p in $store.connections) {
        if (Test-SapConnectionsEqual -A $p -B $Profile) { $match = $p; break }
    }

    if ($match) {
        # Field-by-field merge — overwrite only when $Profile supplied a value.
        # Endpoint / language / password fields can shift across logins (e.g.,
        # load-balancer routes to a different app server), so we overwrite.
        foreach ($f in @('logon_pad_entry','language','password_dpapi','message_server',
                          'logon_group','application_server','system_number')) {
            if (_NotEmpty "$($Profile[$f])") { $match[$f] = "$($Profile[$f])" }
        }
        # Identity fill-ins: system_name / system_id are part of the profile's
        # identity. We only set them when previously empty (e.g., the profile
        # was migrated from legacy settings.json that didn't carry SystemName,
        # and the post-login capture now knows it). We do NOT overwrite an
        # existing non-empty value — that would silently mutate identity.
        foreach ($id in @('system_name','system_id')) {
            if (-not (_NotEmpty "$($match[$id])") -and (_NotEmpty "$($Profile[$id])")) {
                $match[$id] = "$($Profile[$id])"
            }
        }
        # Description: user-supplied override; else keep existing or auto-derive.
        if (_NotEmpty "$($Profile.description)") { $match.description = "$($Profile.description)" }
        if (-not (_NotEmpty "$($match.description)")) {
            $match.description = New-SapConnectionAutoDescription -Profile $match
        }
        $match.last_used_at = $now
        if ($Profile.rfc_tested) { $match.rfc_tested = $true }
        if ($Profile.gui_tested) { $match.gui_tested = $true }
        Write-SapConnectionStore -Store $store
        return $match
    }

    # New profile.
    $new = @{}
    foreach ($k in $Profile.Keys) { $new[$k] = $Profile[$k] }
    if (-not (_NotEmpty "$($new.id)")) { $new.id = [guid]::NewGuid().ToString() }
    if (-not (_NotEmpty "$($new.created_at)")) { $new.created_at = $now }
    $new.last_used_at = $now
    if (-not (_NotEmpty "$($new.description)")) {
        $new.description = New-SapConnectionAutoDescription -Profile $new
    }
    foreach ($f in @('id','description','logon_pad_entry','system_name','client','user','language',
                      'password_dpapi','message_server','logon_group','system_id',
                      'application_server','system_number','created_at','last_used_at')) {
        if (-not $new.ContainsKey($f)) { $new[$f] = '' }
    }
    foreach ($b in @('is_default_target','rfc_tested','gui_tested')) {
        if (-not $new.ContainsKey($b)) { $new[$b] = $false }
    }
    $store.connections += $new
    Write-SapConnectionStore -Store $store
    return $new
}

function Remove-SapConnection {
    param([Parameter(Mandatory)][string] $Id)
    $store = Read-SapConnectionStore
    $store.connections = @($store.connections | Where-Object { "$($_.id)" -ne $Id })
    if ($store.default_target_id -eq $Id) { $store.default_target_id = '' }
    Write-SapConnectionStore -Store $store
}

# =============================================================================
# AI-session identity (Phase 4.1: parent-PID-based, NOT machine-global)
# -----------------------------------------------------------------------------
# The Phase-4 model pins each Claude Code conversation (and its subagents) to
# a single SAP connection. The pin is keyed by an AI-session id. The id must
# satisfy three properties:
#
#   1. SAME id for every skill / subagent invocation within ONE conversation.
#   2. DIFFERENT id across concurrent conversations on the same machine.
#   3. SURVIVES script-host hops (powershell -> cscript -> nested powershell).
#
# The original Phase-4 implementation wrote a single ai_session_id.txt per
# machine, which silently shared one id across every parallel Claude Code
# conversation (Bug). The fix below derives the id from the FIRST non-script-
# host ancestor of the calling PowerShell process. Claude Code itself isn't
# a script host (powershell/pwsh/cscript/wscript/cmd/conhost) -- it's the
# CLI binary. So walking up `ParentProcessId` and skipping script-host
# processes lands on the Claude Code conversation process. Subagents launched
# from the same conversation share that ancestor, so they share the id.
# Parallel conversations have different parent PIDs and therefore different
# ids.
#
# State is stored per-ancestor-PID at
#   {RuntimeDir}\ai_session_by_pid\<owner_pid>.txt
# GC runs opportunistically on every create -- entries whose ancestor PID
# is no longer alive are dropped, so the directory stays small even with
# many short-lived conversations.
#
# Override hook: the env var SAPDEV_AI_SESSION_ID takes precedence over the
# walked id. Tests and one-off manual invocations can use it to pin a
# specific id without touching files.
# =============================================================================

$script:_SapAi_ScriptHosts = @('powershell','pwsh','cscript','wscript','cmd','conhost')
$script:_SapAi_MutexName   = 'SapDevAiSessionId_v1'

function _Get-AiOwnerPid {
    <#
    .SYNOPSIS
        Walk up the process tree from $StartPid (default: current process)
        until we hit a process whose name is NOT a known script host.
        Returns that ancestor's PID -- the "AI session owner".
    .NOTES
        Capped at 12 hops as a safety against pathological process trees.
        On any introspection failure, returns the last known PID (best
        effort -- a stable-but-wrong id is better than throwing).
    #>
    param([int]$StartPid = $PID)
    $current = $StartPid
    for ($i = 0; $i -lt 12; $i++) {
        $p = $null
        try { $p = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction Stop } catch {}
        if (-not $p) { return $current }
        $parentPid = [int]$p.ParentProcessId
        if ($parentPid -le 0) { return $current }
        $parent = $null
        try { $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$parentPid" -ErrorAction Stop } catch {}
        if (-not $parent) { return $current }
        $parentName = [System.IO.Path]::GetFileNameWithoutExtension("$($parent.Name)").ToLower()
        if ($script:_SapAi_ScriptHosts -contains $parentName) {
            $current = $parentPid
            continue
        }
        # Parent is not a script host -- it's the conversation owner.
        return $parentPid
    }
    return $current
}

function _Invoke-AiSessionGc {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return }
    foreach ($f in Get-ChildItem $Dir -Filter '*.txt' -ErrorAction SilentlyContinue) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $ownerPid = 0
        if (-not [int]::TryParse($stem, [ref]$ownerPid)) { continue }
        if ($ownerPid -le 0) { continue }
        $alive = $false
        try { Get-Process -Id $ownerPid -ErrorAction Stop | Out-Null; $alive = $true } catch {}
        if (-not $alive) {
            try { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Get-SapAiSessionId {
    <#
    .SYNOPSIS
        Return the AI-session id for THIS Claude Code conversation. Idempotent
        within a conversation (same parent PID -> same id every call); unique
        across parallel conversations (different parent PIDs).
    .PARAMETER RuntimeDir
        Override for the runtime directory holding ai_session_by_pid/. When
        empty, resolves via Get-SapWorkRuntimeDir (production default).
        Passed explicitly by the broker so its -WorkTemp sandbox is honored
        in tests.
    #>
    param([string]$RuntimeDir = '')

    # Honor an explicit env var if set (tests + manual overrides).
    if (-not [string]::IsNullOrWhiteSpace($env:SAPDEV_AI_SESSION_ID)) {
        return $env:SAPDEV_AI_SESSION_ID
    }

    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) {
        $RuntimeDir = Get-SapWorkRuntimeDir
    }
    $dir = Join-Path $RuntimeDir 'ai_session_by_pid'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $ownerPid = _Get-AiOwnerPid -StartPid $PID
    $file = Join-Path $dir "$ownerPid.txt"

    $mutex = [System.Threading.Mutex]::new($false, $script:_SapAi_MutexName)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(5000) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            # Mutex unavailable but file may already exist - best-effort read.
            if (Test-Path $file) {
                $v = (Get-Content $file -Raw -Encoding UTF8).Trim()
                if ($v) { return $v }
            }
            throw "sap_connection_lib: could not acquire ai_session mutex within 5000ms"
        }

        if (Test-Path $file) {
            $existing = (Get-Content $file -Raw -Encoding UTF8).Trim()
            if ($existing) { return $existing }
        }

        $id = [guid]::NewGuid().ToString()
        [System.IO.File]::WriteAllText($file, $id, [System.Text.UTF8Encoding]::new($false))

        # Opportunistic cleanup of files for dead PIDs.
        _Invoke-AiSessionGc -Dir $dir

        return $id
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        try { $mutex.Dispose() } catch {}
    }
}

# --- Legacy migration -------------------------------------------------------

function Import-LegacyConnectionFromSettings {
    <#
    .SYNOPSIS
        One-shot migration: if any of the legacy single-connection
        userConfig fields (sap_application_server / sap_system_number /
        sap_client / sap_user) is non-empty AND the store is empty, build
        a profile and mark it as default.
    .OUTPUTS
        $null  -> nothing to migrate (no legacy data OR store already
                   populated). Otherwise the migrated profile hashtable.
    #>
    if (-not (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue)) {
        $libPath = Join-Path $PSScriptRoot 'sap_settings_lib.ps1'
        if (Test-Path $libPath) { . $libPath }
    }
    if (-not (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue)) {
        return $null
    }

    $store = Read-SapConnectionStore
    if ($store.connections.Count -gt 0) { return $null }

    $legacy = @{
        logon_pad_entry    = (Get-SapSettingValue 'sap_logon_description'   '')
        application_server = (Get-SapSettingValue 'sap_application_server'  '')
        system_number      = (Get-SapSettingValue 'sap_system_number'       '')
        client             = (Get-SapSettingValue 'sap_client'              '')
        user               = (Get-SapSettingValue 'sap_user'                '')
        language           = (Get-SapSettingValue 'sap_language'            '')
        password_dpapi     = (Get-SapSettingValue 'sap_password'            '')
    }
    $any = $false
    foreach ($k in $legacy.Keys) { if (_NotEmpty "$($legacy[$k])") { $any = $true; break } }
    if (-not $any) { return $null }

    # We do NOT yet have system_name; it gets filled in post-login by the
    # capture step. For migration we leave it blank — Test-SapConnectionsEqual
    # treats the migrated record as "unique" (no other connections yet) so
    # there's no risk of a false dedup.
    $profile = New-SapConnectionInfo `
        -LogonPadEntry     $legacy.logon_pad_entry `
        -ApplicationServer $legacy.application_server `
        -SystemNumber      $legacy.system_number `
        -Client            $legacy.client `
        -User              $legacy.user `
        -Language          $legacy.language `
        -PasswordDpapi     $legacy.password_dpapi `
        -IsDefaultTarget   $true

    $saved = Save-SapConnection -Profile $profile
    Set-SapDefaultConnection -Id $saved.id
    Write-Host "INFO: sap_connection_lib: migrated legacy single-connection settings to connections.json (id=$($saved.id))"
    return $saved
}
