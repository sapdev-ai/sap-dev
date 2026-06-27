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
# 4-step compare (Test-SapConnectionsEqual) -- short-circuits on first match:
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
    # Resolution order: env var SAPDEV_AI_WORK_DIR -> settings.local.json ->
    # %APPDATA%\sapdev-ai\work_dir.txt (durable out-of-cache pointer) ->
    # settings.json -> default C:\sap_dev_work. The env var and the pointer are
    # the durable, update-proof roots (the plugin cache is versioned per release;
    # neither is). The pointer ALSO bridges the current session, since a freshly
    # set User env var never reaches already-running processes. Everything stable
    # (connections.json, dev defaults, logs) lives under work_dir, so making this
    # one value update-proof makes them all update-proof.
    if (-not [string]::IsNullOrWhiteSpace($env:SAPDEV_AI_WORK_DIR)) {
        return ($env:SAPDEV_AI_WORK_DIR.Trim()).TrimEnd('\')
    }
    if (-not (Get-Command Get-SapWorkDirBootstrap -ErrorAction SilentlyContinue)) {
        $libPath = Join-Path $PSScriptRoot 'sap_settings_lib.ps1'
        if (Test-Path $libPath) { . $libPath }
    }
    # Delegate to the settings-lib bootstrap resolver (env -> settings.local ->
    # %APPDATA% pointer -> settings -> default). It NEVER reads userconfig.json,
    # so there is no circular dependency (userconfig.json lives under work_dir).
    if (Get-Command Get-SapWorkDirBootstrap -ErrorAction SilentlyContinue) {
        return Get-SapWorkDirBootstrap
    }
    # Fallback if the settings lib is unavailable.
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

function Get-SapRunTemp {
    # Per-invocation scratch directory: {work_dir}\temp\run_<guid8>.
    #
    # Mints a FRESH unique subdirectory each call and creates it. Each skill
    # invocation -- INCLUDING each parallel sub-agent -- calls this ONCE in its
    # Step 0 and reuses the returned path for the rest of the run, so two
    # concurrent runs never share a scratch file name. This is the fix for the
    # fixed-name {WORK_TEMP} collision class: the generate-then-execute TOCTOU on
    # *_run.vbs (a concurrent run clobbering the file between write and cscript
    # exec -> wrong object deployed), the sap_<skill>_run.json log-state clobber,
    # and scratch-txt clobber.
    #
    # CONTRACT: call once, in Step 0; reuse the value. Do NOT re-mint mid-skill
    # (a second call returns a DIFFERENT dir and would fork a write-then-read
    # handoff such as se38's "Write {RUN_TEMP}\<PGM>.abap then read it").
    #
    # Unlike the broker / Get-SapCurrentSessionPath / Get-SapCurrentConnectionProfile
    # family, this builds DOWN from {work_dir}\temp and NEVER does
    # `Split-Path -Parent`, so it cannot disturb the durable runtime-dir
    # derivation ({work_dir}\runtime, home of session_registry.json + the
    # AI-session pin). Callers MUST keep `-WorkTemp` on the base {work_dir}\temp
    # for those helpers; only the skill's OWN scratch goes under this run dir.
    param([string]$WorkDir = '')
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Get-SapWorkDir }
    $base = Join-Path $WorkDir 'temp'
    if (-not (Test-Path $base)) { New-Item -ItemType Directory -Force -Path $base | Out-Null }
    # Retry a few times so an old, not-yet-GC'd run dir with the same 8-hex
    # token cannot be silently reused (which would re-introduce sharing).
    for ($i = 0; $i -lt 20; $i++) {
        $token = 'run_' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $dir = Join-Path $base $token
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            return $dir
        }
    }
    # Astronomically unlikely (20 GUID collisions). Fall back to a full GUID.
    $dir = Join-Path $base ('run_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Remove-SapStaleRunTemp {
    # Best-effort GC of orphaned per-run scratch dirs ({work_dir}\temp\run_*).
    # A crashed or abandoned run never reaches its `rmdir {RUN_TEMP}` cleanup, so
    # sweep run_* dirs whose last-write is older than -MaxAgeHours (default 24h).
    # Intended for /sap-login Step 6 alongside the broker `gc`. Never throws;
    # returns the count removed.
    param(
        [string]$WorkDir = '',
        [int]$MaxAgeHours = 24
    )
    try {
        if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Get-SapWorkDir }
        $base = Join-Path $WorkDir 'temp'
        if (-not (Test-Path $base)) { return 0 }
        $cutoff = (Get-Date).AddHours(-1 * [math]::Abs($MaxAgeHours))
        $removed = 0
        Get-ChildItem -LiteralPath $base -Directory -Filter 'run_*' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.LastWriteTime -lt $cutoff) {
                try {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                    $removed++
                } catch { }
            }
        }
        return $removed
    } catch { return 0 }
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
            # the state as questionable -- caller is responsible for re-reading.
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

function _Backup-CorruptConnectionStore {
    <#
    .SYNOPSIS
        Preserve a timestamped copy of an unparseable connections.json next to
        the original before we refuse to continue. Best-effort -- a backup
        failure must not mask the underlying corruption error.
    #>
    param([string]$Path, [string]$Raw)
    try {
        $stamp  = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $backup = "$Path.corrupt.$stamp"
        [System.IO.File]::WriteAllText($backup, $Raw, ([System.Text.UTF8Encoding]::new($false)))
        return $backup
    } catch {
        return '(backup failed)'
    }
}

function _Normalize-ConnectionRecord {
    <#
    .SYNOPSIS
        Coerce ONE raw connection record (PSCustomObject from ConvertFrom-Json)
        into the normalized hashtable shape. Field coercion is total-loss-proof:
        a single bad field (e.g. a non-numeric gui_major) defaults that field
        instead of throwing -- so it can never cascade into wiping the whole
        store (Audit P1). The CALLER additionally wraps this in a per-record
        try/catch as a backstop.
    #>
    param([Parameter(Mandatory)]$Record)
    $p = @{}
    foreach ($pp in $Record.PSObject.Properties) { $p[$pp.Name] = $pp.Value }
    # String fields.
    foreach ($f in @('id','description','logon_pad_entry','system_name','client','user','language',
                      'password_dpapi','message_server','logon_group','system_id',
                      'application_server','system_number','created_at','last_used_at',
                      'gui_version_raw','server_kernel_release','server_release_family',
                      'server_release_marker','server_release_raw')) {
        if ($p.ContainsKey($f)) { $p[$f] = "$($p[$f])" } else { $p[$f] = '' }
    }
    # Integer fields -- TryParse, never a hard [int] cast that could throw.
    foreach ($i in @('gui_major','gui_minor','gui_patch')) {
        $iv = 0
        if ($p.ContainsKey($i) -and $null -ne $p[$i]) {
            $parsed = 0
            if ([int]::TryParse("$($p[$i])", [ref]$parsed)) { $iv = $parsed }
        }
        $p[$i] = $iv
    }
    # Boolean fields.
    foreach ($b in @('is_default_target','rfc_tested','gui_tested')) {
        if ($p.ContainsKey($b)) { try { $p[$b] = [bool]$p[$b] } catch { $p[$b] = $false } } else { $p[$b] = $false }
    }
    if (-not $p.ContainsKey('software_components') -or $null -eq $p['software_components']) {
        $p['software_components'] = @()
    }
    # dev_defaults -- per-connection overrides for system-keyed settings
    # (sap_dev_transport_request / sap_dev_package / sap_dev_function_group).
    # Coerce PSCustomObject -> hashtable so we can index/Update freely.
    if (-not $p.ContainsKey('dev_defaults') -or $null -eq $p['dev_defaults']) {
        $p['dev_defaults'] = @{}
    } elseif ($p['dev_defaults'] -is [System.Management.Automation.PSCustomObject]) {
        $hh = @{}
        foreach ($pp2 in $p['dev_defaults'].PSObject.Properties) { $hh[$pp2.Name] = "$($pp2.Value)" }
        $p['dev_defaults'] = $hh
    }
    return $p
}

function Read-SapConnectionStore {
    if ($null -ne $script:SapConnStore_Cache) { return $script:SapConnStore_Cache }
    $path = Get-SapConnectionStorePath
    if (-not (Test-Path $path)) {
        $script:SapConnStore_Cache = New-EmptyConnectionStore
        return $script:SapConnStore_Cache
    }

    # Read the bytes with a short retry: a concurrent atomic swap
    # (Write-SapConnectionStore's temp-write + File.Replace) can momentarily lock
    # the file or expose a not-found window. That is transient, NOT corruption --
    # so retry rather than treat it as an unreadable store.
    $raw = $null
    $ioErr = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try { $raw = Get-Content -Path $path -Raw -Encoding UTF8; $ioErr = $null; break }
        catch { $ioErr = $_; Start-Sleep -Milliseconds 60 }
    }
    if ($null -ne $ioErr) {
        # Persisted IO failure (permissions / disk / vanished). Do NOT reset to an
        # empty store -- a later Save would then overwrite the real file and
        # destroy every saved connection + DPAPI password (Audit P1). Fail loud.
        throw "sap_connection_lib: connections.json could not be read after retries ($($ioErr.Exception.Message)). Refusing to continue so the credential store is not overwritten. Path: $path"
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        $script:SapConnStore_Cache = New-EmptyConnectionStore
        return $script:SapConnStore_Cache
    }

    $obj = $null
    try { $obj = $raw | ConvertFrom-Json }
    catch {
        # File has content but is not valid JSON -> genuine corruption (or a torn
        # write the atomic swap should have prevented). Preserve a timestamped
        # backup and FAIL LOUD instead of silently resetting to an empty store --
        # the old "resetting" path let a later Save overwrite the real file, so
        # ALL saved connections + DPAPI passwords were lost (Audit P1).
        $backup = _Backup-CorruptConnectionStore -Path $path -Raw $raw
        throw "sap_connection_lib: connections.json is not valid JSON ($($_.Exception.Message)). A backup of the corrupt file was saved to '$backup'. Refusing to continue so the credential store is not overwritten."
    }

    $store = New-EmptyConnectionStore
    try { if ($obj.version) { $store.version = [int]$obj.version } } catch { $store.version = 2 }
    if ($obj.default_target_id) { $store.default_target_id = [string]$obj.default_target_id }
    if ($obj.connections) {
        foreach ($c in $obj.connections) {
            # Isolate per-record normalization: one malformed connection (or one
            # bad field within it) drops just THAT record, never the whole store.
            try {
                $store.connections += (_Normalize-ConnectionRecord -Record $c)
            } catch {
                Write-Host "WARN: sap_connection_lib: skipping one unreadable connection record ($($_.Exception.Message))"
            }
        }
    }
    $script:SapConnStore_Cache = $store
    return $store
}

function Reset-SapConnectionStoreCache {
    $script:SapConnStore_Cache = $null
}

function _Write-SapConnectionStoreInner {
    <#
    .SYNOPSIS
        The actual normalize + atomic-swap write, WITHOUT taking the store mutex.
        Callers MUST already hold the lock (Write-SapConnectionStore /
        Update-SapConnectionStore). Factored out so Update-SapConnectionStore's
        transactional read-modify-write can reuse the exact same write path under
        a single lock acquisition (Audit P2).
    #>
    param([Parameter(Mandatory)][hashtable] $Store)
    if (-not $Store.version)           { $Store.version = 2 }
    if (-not $Store.default_target_id) { $Store.default_target_id = '' }
    if (-not $Store.connections)       { $Store.connections = @() }
    $json = $Store | ConvertTo-Json -Depth 8
    $path = Get-SapConnectionStorePath
    # Atomic swap: Read-SapConnectionStore takes NO lock, so a concurrent reader
    # must never see a half-written file. Temp-write + NTFS Replace (Move when
    # the target is new) closes that race.
    $enc = [System.Text.UTF8Encoding]::new($false)
    $tmp = "$path.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $json, $enc)
    try {
        if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($tmp, $path, $null) }
        else { [System.IO.File]::Move($tmp, $path) }
    } catch {
        [System.IO.File]::WriteAllText($path, $json, $enc)
        if (Test-Path -LiteralPath $tmp) { try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {} }
    }
}

function Write-SapConnectionStore {
    param([Parameter(Mandatory)][hashtable] $Store)
    With-ConnectionStoreLock { _Write-SapConnectionStoreInner -Store $Store }
    Reset-SapConnectionStoreCache
}

function Update-SapConnectionStore {
    <#
    .SYNOPSIS
        Transactional read-modify-write of the connection store (Audit P2).
    .DESCRIPTION
        Runs the WHOLE cycle -- fresh on-disk read, the caller's mutation, and
        the write -- under ONE mutex acquisition. The previous pattern (Save /
        Set-default / Remove each called Read-SapConnectionStore OUTSIDE the lock,
        then Write-SapConnectionStore locked only the write) let two concurrent
        processes read the same baseline and silently drop one of the two saved
        profiles -- the product's headline parallel-multi-system scenario.
        Routing every mutator through here closes that window.

        The -Mutator scriptblock receives the freshly-read $store hashtable as
        its single argument, mutates it in place, and MAY return a value (e.g.
        the saved profile) which Update passes back to the caller verbatim. Note
        Read-SapConnectionStore now fails loud on a corrupt store, so a mutation
        can never run against -- or persist over -- an unreadable file.
    #>
    param([Parameter(Mandatory)][scriptblock] $Mutator)
    $captured = With-ConnectionStoreLock {
        Reset-SapConnectionStoreCache
        $store = Read-SapConnectionStore
        $r = & $Mutator $store
        _Write-SapConnectionStoreInner -Store $store
        $r
    }
    Reset-SapConnectionStoreCache
    return $captured
}

# --- Profile factory --------------------------------------------------------

function New-SapConnectionInfo {
    <#
    .SYNOPSIS
        Return a normalised profile hashtable. Use this anywhere a profile-
        shaped object is needed (active SAP connections, user input, etc.).
    .NOTES
        Version fields (gui_*, server_*) carry SAP GUI + server release
        info captured at login time. Used by sap-gui-skill-scaffold and
        sap_select_vbs_variant.ps1 for version-aware VBS variant selection.
        Optional -- left empty when RFC system info isn't available.
    #>
    [CmdletBinding()]
    param(
        [string]$Id                  = '',
        [string]$Description         = '',
        [string]$LogonPadEntry       = '',
        [string]$SystemName          = '',
        [string]$Client              = '',
        [string]$User                = '',
        [string]$Language            = '',
        [string]$PasswordDpapi       = '',
        [string]$MessageServer       = '',
        [string]$LogonGroup          = '',
        [string]$SystemId            = '',
        [string]$ApplicationServer   = '',
        [string]$SystemNumber        = '',
        [bool]  $IsDefaultTarget     = $false,
        [string]$CreatedAt           = '',
        [string]$LastUsedAt          = '',
        [bool]  $RfcTested           = $false,
        [bool]  $GuiTested           = $false,
        # Version info (captured at login; optional)
        [string]$GuiVersionRaw       = '',
        [int]   $GuiMajor            = 0,
        [int]   $GuiMinor            = 0,
        [int]   $GuiPatch            = 0,
        [string]$ServerKernelRelease = '',
        [string]$ServerReleaseFamily = '',
        [string]$ServerReleaseMarker = '',
        [string]$ServerReleaseRaw    = '',
        $SoftwareComponents          = $null
    )
    return @{
        id                     = "$Id"
        description            = "$Description"
        logon_pad_entry        = "$LogonPadEntry"
        system_name            = "$SystemName"
        client                 = "$Client"
        user                   = "$User"
        language               = "$Language"
        password_dpapi         = "$PasswordDpapi"
        message_server         = "$MessageServer"
        logon_group            = "$LogonGroup"
        system_id              = "$SystemId"
        application_server     = "$ApplicationServer"
        system_number          = "$SystemNumber"
        is_default_target      = [bool]$IsDefaultTarget
        created_at             = "$CreatedAt"
        last_used_at           = "$LastUsedAt"
        rfc_tested             = [bool]$RfcTested
        gui_tested             = [bool]$GuiTested
        gui_version_raw        = "$GuiVersionRaw"
        gui_major              = [int]$GuiMajor
        gui_minor              = [int]$GuiMinor
        gui_patch              = [int]$GuiPatch
        server_kernel_release  = "$ServerKernelRelease"
        server_release_family  = "$ServerReleaseFamily"
        server_release_marker  = "$ServerReleaseMarker"
        server_release_raw     = "$ServerReleaseRaw"
        software_components    = if ($null -ne $SoftwareComponents) { $SoftwareComponents } else { @() }
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

    # Step 1 -- precondition. SystemName mismatch only fails when BOTH sides know it.
    if ((_NotEmpty "$($A.system_name)") -and (_NotEmpty "$($B.system_name)") -and
        ("$($A.system_name)" -ne "$($B.system_name)")) {
        return $false
    }
    if (("$($A.client)") -ne ("$($B.client)"))  { return $false }
    if (("$($A.user)")   -ne ("$($B.user)"))    { return $false }

    # Step 2 -- Logon pad entry.
    if ((_NotEmpty "$($A.logon_pad_entry)") -and (_NotEmpty "$($B.logon_pad_entry)")) {
        if ("$($A.logon_pad_entry)" -eq "$($B.logon_pad_entry)") { return $true }
        # else fall through
    }

    # Step 3 -- MessageServer.
    if ((_NotEmpty "$($A.message_server)") -and (_NotEmpty "$($B.message_server)")) {
        if ("$($A.message_server)" -eq "$($B.message_server)") { return $true }
        # else fall through
    }

    # Step 4 -- ApplicationServer + SystemNumber (pair).
    if ((_NotEmpty "$($A.application_server)") -and (_NotEmpty "$($B.application_server)") -and
        (_NotEmpty "$($A.system_number)")      -and (_NotEmpty "$($B.system_number)")) {
        if ("$($A.application_server)" -eq "$($B.application_server)" -and
            "$($A.system_number)"      -eq "$($B.system_number)") { return $true }
    }

    return $false
}

# --- Language compare -------------------------------------------------------

function ConvertTo-SapCanonicalLanguage {
    <#
    .SYNOPSIS
        Normalise a SAP logon-language token to a canonical 2-char ISO code
        so EN == E == "English" all compare equal.
    .DESCRIPTION
        oSession.Info.Language returns EITHER the 1-char SAP language key
        (E / D / J / 1 / ...) OR the 2-char ISO code (EN / DE / JA / ZH / ...)
        depending on the SAP GUI release. Stored profiles, login fields and
        user input can each carry either form (or an English language word).
        This collapses them to one token.

        Unknown tokens are returned trimmed + upper-cased unchanged, so two
        equal-but-unmapped codes still compare equal; only cross-form unknown
        pairs fail to match (acceptable -- mappings cover the languages SAP
        and this project actually use). Mapping mirrors the 1-char<->ISO table
        in sap_syntax_check_lib.vbs (GetSyntaxErrorWord).
    #>
    param([string]$Language)
    if ([string]::IsNullOrWhiteSpace($Language)) { return '' }
    $k = $Language.Trim().ToUpperInvariant()
    $map = @{
        'E'='EN'; 'EN'='EN'; 'ENGLISH'='EN'
        'D'='DE'; 'DE'='DE'; 'GERMAN'='DE'
        'F'='FR'; 'FR'='FR'; 'FRENCH'='FR'
        'S'='ES'; 'ES'='ES'; 'SPANISH'='ES'
        'I'='IT'; 'IT'='IT'; 'ITALIAN'='IT'
        'P'='PT'; 'PT'='PT'; 'PORTUGUESE'='PT'
        '1'='ZH'; 'ZH'='ZH'; 'CHINESE'='ZH'   # simplified
        'M'='ZF'; 'ZF'='ZF'                    # traditional
        'J'='JA'; 'JA'='JA'; 'JAPANESE'='JA'
        '3'='KO'; 'KO'='KO'; 'KOREAN'='KO'
        'R'='RU'; 'RU'='RU'; 'RUSSIAN'='RU'
    }
    if ($map.ContainsKey($k)) { return $map[$k] }
    return $k
}

function Test-SapLanguageEqual {
    <#
    .SYNOPSIS
        $true if two SAP logon-language tokens denote the same language
        (after canonicalisation).
    .DESCRIPTION
        Blank on EITHER side returns $true ("cannot decide -> treat as a
        match"), so a missing / unreadable Info.Language never triggers a
        disruptive close+relogin. Callers gate the comparison on the
        REQUESTED language being non-blank before relying on the result.
    #>
    param([string]$A, [string]$B)
    $ca = ConvertTo-SapCanonicalLanguage $A
    $cb = ConvertTo-SapCanonicalLanguage $B
    if ([string]::IsNullOrWhiteSpace($ca) -or [string]::IsNullOrWhiteSpace($cb)) { return $true }
    return ($ca -eq $cb)
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

function Resolve-SapProfileHint {
    <#
    .SYNOPSIS
        Resolve a human-friendly hint to one or more stored profiles.
    .DESCRIPTION
        Hint grammar (single shell token):
          <UUID>                            - exact UUID
          last                              - profile with most recent last_used_at
          default                            - the default target (Get-SapDefaultConnection)
          <SID>                              - profiles whose system_name == <SID>
          <SID>/<CLIENT>                     - + client filter
          <SID>/<CLIENT>/<USER>              - + user filter
          <description>                      - exact description, then substring on
                                               description or system_name
        Slash-form is recognized when the hint contains 1 or 2 `/` AND every
        non-empty segment looks SID/client/user-shaped (alphanumeric, no
        whitespace). This keeps descriptions containing `/` (e.g. "dev/test")
        from being mis-routed.
        Returns an array of matching profile objects (possibly empty, possibly
        single, possibly many -- callers decide what "many" means).
    .OUTPUTS
        Array of profile pscustomobjects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hint)

    # NB: callers must wrap with @(...) -- e.g. `$matches = @(Resolve-SapProfileHint -Hint $h)`.
    # The function streams matches via PowerShell's normal output pipeline; an
    # empty result yields nothing (caller's @() turns it into an empty array),
    # a single match yields one object (caller's @() wraps it), and a multi
    # result streams them all. Do NOT prepend `,` -- that wraps in a 1-element
    # outer array and defeats the caller's @() unwrap.

    $store = Read-SapConnectionStore
    if (-not $store -or -not $store.connections) { return }

    $h = "$Hint".Trim()
    if ([string]::IsNullOrWhiteSpace($h)) { return }

    # 1. UUID exact (preserves all today's callers).
    $byId = $store.connections | Where-Object { "$($_.id)" -eq $h } | Select-Object -First 1
    if ($byId) { return $byId }

    # 2. Reserved 'last' -> most recent last_used_at.
    if ($h -ieq 'last') {
        $sorted = @($store.connections | Sort-Object { try { [datetime]$_.last_used_at } catch { [datetime]::MinValue } } -Descending)
        if ($sorted.Count -gt 0) { return $sorted[0] }
        return
    }

    # 3. Reserved 'default'.
    if ($h -ieq 'default') {
        $d = Get-SapDefaultConnection
        if ($d) { return $d }
        return
    }

    # 4. Structured <SID>[/<CLIENT>[/<USER>]] - detected by 1 or 2 slashes,
    #    all segments alphanumeric (no whitespace). Anything else falls
    #    through to description matching below.
    $segs = $h.Split('/')
    $isStructured = ($segs.Count -ge 2 -and $segs.Count -le 3)
    if ($isStructured) {
        foreach ($s in $segs) {
            if ([string]::IsNullOrEmpty($s)) { $isStructured = $false; break }
            if ($s -notmatch '^[A-Za-z0-9_-]+$') { $isStructured = $false; break }
        }
    }
    if ($isStructured) {
        $needSid    = $segs[0]
        $needClient = if ($segs.Count -ge 2) { $segs[1] } else { $null }
        $needUser   = if ($segs.Count -ge 3) { $segs[2] } else { $null }
        $byStruct = @($store.connections | Where-Object {
            $sysOk    = ("$($_.system_name)".ToUpperInvariant() -eq $needSid.ToUpperInvariant())
            $clientOk = ($null -eq $needClient) -or ("$($_.client)" -eq "$needClient")
            $userOk   = ($null -eq $needUser)   -or ("$($_.user)".ToUpperInvariant() -eq $needUser.ToUpperInvariant())
            $sysOk -and $clientOk -and $userOk
        })
        # Stream each match; empty $byStruct streams nothing.
        return $byStruct
    }

    # 5. system_name exact (case-insensitive).
    $bySid = @($store.connections | Where-Object {
        "$($_.system_name)".ToUpperInvariant() -eq $h.ToUpperInvariant()
    })
    if ($bySid.Count -ge 1) { return $bySid }

    # 6. description exact (case-insensitive).
    $byDescExact = @($store.connections | Where-Object {
        "$($_.description)".ToUpperInvariant() -eq $h.ToUpperInvariant()
    })
    if ($byDescExact.Count -eq 1) { return $byDescExact }

    # 7. substring on description OR system_name.
    $needle = $h.ToUpperInvariant()
    $bySub = @($store.connections | Where-Object {
        "$($_.description)".ToUpperInvariant().Contains($needle) -or
        "$($_.system_name)".ToUpperInvariant().Contains($needle)
    })
    return $bySub
}

# --- Mutation ---------------------------------------------------------------

function Set-SapDefaultConnection {
    <#
    .SYNOPSIS
        Mark profile $Id as the default and clear the flag on all others.
        Pass an empty $Id to clear the default entirely.
    #>
    param([string] $Id = '')
    Update-SapConnectionStore {
        param($store)
        $store.default_target_id = "$Id"
        foreach ($p in $store.connections) {
            $p.is_default_target = ("$($p.id)" -eq "$Id")
        }
    } | Out-Null
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

# --- ApplicationServer reconciliation --------------------------------------
#
# SAP GUI's GuiSessionInfo.ApplicationServer returns the SAP host's INTERNAL
# identity (the hostname as the SAP host knows itself, per its profile
# parameters like SAPSYSTEMNAME / INSTANCE_NAME). On LAN deployments this
# usually equals the DNS name the user typed into SAP Logon Pad. But on
# NAT / dynamic-DNS / reverse-proxy deployments the two diverge: SAP returns
# e.g. "s4sapdev" while the workstation can only reach the host via
# "xxxsap.xxx.com". SAP GUI keeps working (it routes through saplogon.ini's
# ConnectionString), but NCo/RFC cannot resolve the internal name and every
# `Connect-SapRfc` fails with "hostname unknown".
#
# This block adds a three-step resolver: DNS-test the captured value, then
# the user-typed hint (if any), then the actual server hostname from the SAP
# Logon Pad entry's SAPUILandscape.xml / saplogon.ini config. First DNS hit
# wins; on total failure return the captured value with a flag so callers
# can WARN (never block -- SAP GUI still works).

function Test-SapHostResolvable {
    <#
    .SYNOPSIS
        $true when the given hostname resolves via DNS / hosts file / IP literal.
    .DESCRIPTION
        Wraps [System.Net.Dns]::GetHostEntry with error suppression. IPv4/IPv6
        literals short-circuit (no DNS round-trip). Empty input returns $false.
    #>
    param([string] $HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($HostName, [ref]$ip)) { return $true }
    try {
        $null = [System.Net.Dns]::GetHostEntry($HostName)
        return $true
    } catch {
        return $false
    }
}

function Get-SapLogonPadEntryServer {
    <#
    .SYNOPSIS
        Look up the host:port that a SAP Logon Pad entry resolves to.
    .DESCRIPTION
        Reads (in order):
          1. %APPDATA%\SAP\Common\SAPUILandscape.xml       (per-user)
          2. %PROGRAMDATA%\SAP\Common\SAPUILandscapeGlobal.xml (global)
          3. %APPDATA%\SAP\Common\saplogon.ini             (legacy INI)
        for a service/section whose name matches $EntryName. Returns
        @{ server='host'; port='3270'; sysnr='70' } on first hit, or $null
        when no match.

        SCOPE: direct-server entries only. Load-balanced SAPUILandscape
        entries (no `server=` attribute; carry `messageServer=` + `group=`
        + `systemid=` instead) return $null on purpose. Reason: the
        capture VBS already extracts message_server / logon_group /
        system_id directly from SAP GUI's Info object (with a parse-
        connection-string fallback for builds where Info.MessageServer
        is blank), so load-balanced profiles never need to consult the
        XML for routing. If a future build forces us to do that lookup,
        extend this function to return a shape like
        @{ type='load_balanced'; message_server='...'; logon_group='...';
           system_id='...' }.
    #>
    param([Parameter(Mandatory)] [string] $EntryName)
    if ([string]::IsNullOrWhiteSpace($EntryName)) { return $null }

    $xmlPaths = @(
        (Join-Path $env:APPDATA      'SAP\Common\SAPUILandscape.xml')
        (Join-Path $env:PROGRAMDATA  'SAP\Common\SAPUILandscapeGlobal.xml')
    )
    foreach ($p in $xmlPaths) {
        if (-not (Test-Path $p)) { continue }
        try { [xml]$doc = Get-Content -Path $p -Raw -ErrorAction Stop } catch { continue }
        # Service nodes live at //Services/Service with name= and server= attrs.
        $node = $doc.SelectSingleNode("//Service[@name='$EntryName']")
        if (-not $node) { continue }
        $srv = "$($node.server)"
        if ([string]::IsNullOrWhiteSpace($srv)) { continue }
        $hostName = $srv; $port = ''; $sysnr = ''
        if ($srv -match '^(.+?):(\d+)$') {
            $hostName = $matches[1]
            $port = $matches[2]
            $portInt = [int]$port
            if ($portInt -ge 3200 -and $portInt -le 3298) {
                $sysnr = '{0:D2}' -f ($portInt - 3200)
            }
        }
        return @{ server = $hostName; port = $port; sysnr = $sysnr }
    }

    # Legacy saplogon.ini (SAP GUI < 7.40)
    $ini = Join-Path $env:APPDATA 'SAP\Common\saplogon.ini'
    if (Test-Path $ini) {
        $inSection = $false
        foreach ($l in (Get-Content $ini)) {
            if ($l -match '^\[(.+?)\]\s*$') { $inSection = ($matches[1] -eq $EntryName); continue }
            if ($inSection -and $l -match '^\s*Server\s*=\s*(\S+)(?:\s+(\d+))?') {
                $hostName = $matches[1]; $sysnr = ''
                if ($matches[2]) { $sysnr = '{0:D2}' -f [int]$matches[2] }
                return @{ server = $hostName; port = ''; sysnr = $sysnr }
            }
        }
    }
    return $null
}

function Get-SapLogonLandscapeEntries {
    <#
    .SYNOPSIS
        Enumerate ALL SAP Logon Pad entries (direct + load-balanced) from
        SAPUILandscape.xml / SAPUILandscapeGlobal.xml / saplogon.ini.
    .DESCRIPTION
        Returns a flat array of [pscustomobject] entries -- each holds enough
        to pre-fill a new connection profile in /sap-login's ADD_NEEDED flow.
        Per-user XML wins over global XML wins over legacy INI; duplicate
        entry names (case-insensitive) are kept only on first hit.
    .OUTPUTS
        Array of objects with fields:
          name             - entry display name (the SAP Logon Pad label)
          kind             - 'direct' | 'load_balanced'
          server           - app server host (direct)
          system_number    - 2-digit (derived from port for direct)
          message_server   - msg server host (load_balanced)
          logon_group      - logon group (load_balanced)
          system_id        - SID / R3NAME (both kinds)
          system_name      - same as system_id (compatibility shim)
          description      - free-text description from XML (may be empty)
          source           - 'user_xml' | 'global_xml' | 'ini'
        Returns @() when no source files exist or no entries match.
    #>
    $entries = New-Object System.Collections.Generic.List[Object]
    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

    $xmlSources = @(
        @{ Path = (Join-Path $env:APPDATA     'SAP\Common\SAPUILandscape.xml');       Tag = 'user_xml' },
        @{ Path = (Join-Path $env:PROGRAMDATA 'SAP\Common\SAPUILandscapeGlobal.xml'); Tag = 'global_xml' }
    )
    foreach ($src in $xmlSources) {
        if (-not (Test-Path $src.Path)) { continue }
        try { [xml]$doc = Get-Content -Path $src.Path -Raw -ErrorAction Stop } catch { continue }

        # Pre-index Messageservers by uuid so load-balanced Service nodes (which
        # reference message servers via a `msid` attribute, not inline) can be
        # resolved without a second XPath per Service.
        $msMap = @{}
        foreach ($ms in $doc.SelectNodes('//Messageserver')) {
            $msid = "$($ms.uuid)"
            if (-not $msid) { $msid = "$($ms.id)" }
            if ($msid) {
                $msMap[$msid] = @{
                    Host = "$($ms.host)"
                    Port = "$($ms.port)"
                    Name = "$($ms.name)"
                }
            }
        }

        foreach ($n in $doc.SelectNodes('//Service')) {
            $name = "$($n.name)"
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($seenNames.Contains($name)) { continue }

            $srv  = "$($n.server)"
            $msid = "$($n.msid)"
            $grp  = "$($n.group)"
            $sid  = "$($n.systemid)"
            $desc = "$($n.description)"

            $kind = ''; $hostName = ''; $sysnr = ''; $msHost = ''
            if ($srv) {
                $kind = 'direct'
                $hostName = $srv
                if ($srv -match '^(.+?):(\d+)$') {
                    $hostName = $matches[1]
                    $portInt = [int]$matches[2]
                    if ($portInt -ge 3200 -and $portInt -le 3298) {
                        $sysnr = '{0:D2}' -f ($portInt - 3200)
                    }
                }
            } elseif ($msid -and $msMap.ContainsKey($msid)) {
                $kind = 'load_balanced'
                $msHost = $msMap[$msid].Host
            } else {
                # Not recognisable as either direct or load-balanced; skip
                # silently -- the entry list isn't supposed to be exhaustive,
                # just useful.
                continue
            }

            [void]$entries.Add([pscustomobject]@{
                name           = $name
                kind           = $kind
                server         = $hostName
                system_number  = $sysnr
                message_server = $msHost
                logon_group    = $grp
                system_id      = $sid
                system_name    = $sid
                description    = $desc
                source         = $src.Tag
            })
            [void]$seenNames.Add($name)
        }
    }

    # Legacy saplogon.ini (SAP GUI < 7.40). Sections look like:
    #   [Entry Name]
    #   Server=host port
    #   SID=S4D
    # or load-balanced:
    #   [Entry Name]
    #   MSSRV=msrv-host
    #   Group=DEFAULT
    #   SID=S4D
    $ini = Join-Path $env:APPDATA 'SAP\Common\saplogon.ini'
    if (Test-Path $ini) {
        $section = ''
        $cur = @{}
        $flush = {
            param($SectionName, $Cur)
            if (-not $SectionName) { return }
            if ($seenNames.Contains($SectionName)) { return }
            $kindL = ''; $hostL = ''; $sysnrL = ''; $msrvL = ''; $grpL = ''; $sidL = "$($Cur.SID)"
            $srvL = "$($Cur.Server)"
            if ($srvL -match '^(\S+)(?:\s+(\d+))?') {
                $kindL = 'direct'
                $hostL = $matches[1]
                if ($matches[2]) { $sysnrL = '{0:D2}' -f [int]$matches[2] }
            } elseif ("$($Cur.MSSRV)") {
                $kindL = 'load_balanced'
                $msrvL = "$($Cur.MSSRV)"
                $grpL  = "$($Cur.Group)"
            }
            if ($kindL) {
                [void]$entries.Add([pscustomobject]@{
                    name           = $SectionName
                    kind           = $kindL
                    server         = $hostL
                    system_number  = $sysnrL
                    message_server = $msrvL
                    logon_group    = $grpL
                    system_id      = $sidL
                    system_name    = $sidL
                    description    = ''
                    source         = 'ini'
                })
                [void]$seenNames.Add($SectionName)
            }
        }
        foreach ($l in (Get-Content $ini)) {
            if ($l -match '^\[(.+?)\]\s*$') {
                & $flush $section $cur
                $section = $matches[1]
                $cur = @{}
                continue
            }
            if ($l -match '^\s*([A-Za-z_]+)\s*=\s*(.+?)\s*$') {
                $cur[$matches[1]] = $matches[2]
            }
        }
        & $flush $section $cur
    }

    return $entries.ToArray()
}

function Resolve-SapApplicationServer {
    <#
    .SYNOPSIS
        Reconcile the captured ApplicationServer with what the workstation can resolve.
    .DESCRIPTION
        Three-step cascade -- first DNS hit wins:
          1. Captured value (Info.ApplicationServer) resolves          -> keep captured.
          2. User-typed hint resolves                                  -> use hint.
          3. SAPUILandscape.xml / saplogon.ini lookup for the logon-pad
             entry returns a server that resolves                     -> use that.
        On total failure, returns the captured value with Source=
        'captured_unresolvable' so the caller can WARN. Never throws;
        never blocks GUI work -- RFC degradation only.
    .OUTPUTS
        Hashtable: @{
            Server     = 'hostname-to-save'
            Source     = 'captured' | 'user_hint' | 'saplogon' | 'captured_unresolvable' | 'none'
            Sysnr      = '00'    # populated when source='saplogon' and port encoded sysnr
            CaptureRaw = '<original captured value>'
            Resolvable = $true | $false
        }
    #>
    param(
        [string] $CapturedAppServer,
        [string] $UserHint        = '',
        [string] $LogonPadEntry   = ''
    )
    $captureRaw = "$CapturedAppServer"

    if ([string]::IsNullOrWhiteSpace($captureRaw) -and
        [string]::IsNullOrWhiteSpace($UserHint) -and
        [string]::IsNullOrWhiteSpace($LogonPadEntry)) {
        return @{ Server=''; Source='none'; Sysnr=''; CaptureRaw=''; Resolvable=$false }
    }

    if ((_NotEmpty $captureRaw) -and (Test-SapHostResolvable $captureRaw)) {
        return @{ Server=$captureRaw; Source='captured'; Sysnr='';
                  CaptureRaw=$captureRaw; Resolvable=$true }
    }
    if ((_NotEmpty $UserHint) -and (Test-SapHostResolvable $UserHint)) {
        return @{ Server="$UserHint"; Source='user_hint'; Sysnr='';
                  CaptureRaw=$captureRaw; Resolvable=$true }
    }
    if (_NotEmpty $LogonPadEntry) {
        $padHit = Get-SapLogonPadEntryServer -EntryName $LogonPadEntry
        if ($padHit -and (Test-SapHostResolvable $padHit.server)) {
            return @{ Server="$($padHit.server)"; Source='saplogon';
                      Sysnr="$($padHit.sysnr)"; CaptureRaw=$captureRaw; Resolvable=$true }
        }
    }
    return @{ Server=$captureRaw; Source='captured_unresolvable';
              Sysnr=''; CaptureRaw=$captureRaw; Resolvable=$false }
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

    # Transactional read-modify-write (Audit P2): dedup + insert/update + persist
    # all run under ONE store-mutex acquisition against a fresh on-disk baseline,
    # so two concurrent /sap-login finalize calls can't drop one saved profile.
    return (Update-SapConnectionStore {
        param($store)
        $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

        $match = $null
        foreach ($p in $store.connections) {
            if (Test-SapConnectionsEqual -A $p -B $Profile) { $match = $p; break }
        }

        if ($match) {
            # Field-by-field merge -- overwrite only when $Profile supplied a value.
            # Endpoint / language / password fields can shift across logins (e.g.,
            # load-balancer routes to a different app server), so we overwrite.
            foreach ($f in @('logon_pad_entry','language','password_dpapi','message_server',
                              'logon_group','application_server','system_number')) {
                if (_NotEmpty "$($Profile[$f])") { $match[$f] = "$($Profile[$f])" }
            }
            # Version info -- overwrite when supplied (refreshed on every login;
            # SAP patches change these between sessions).
            foreach ($v in @('gui_version_raw','server_kernel_release','server_release_family',
                              'server_release_marker','server_release_raw')) {
                if (_NotEmpty "$($Profile[$v])") { $match[$v] = "$($Profile[$v])" }
            }
            foreach ($v in @('gui_major','gui_minor','gui_patch')) {
                if ($Profile.ContainsKey($v) -and [int]$Profile[$v] -gt 0) { $match[$v] = [int]$Profile[$v] }
            }
            if ($Profile.ContainsKey('software_components') -and $Profile['software_components']) {
                $match['software_components'] = $Profile['software_components']
            }
            # Identity fill-ins: system_name / system_id are part of the profile's
            # identity. We only set them when previously empty (e.g., the profile
            # was migrated from legacy settings.json that didn't carry SystemName,
            # and the post-login capture now knows it). We do NOT overwrite an
            # existing non-empty value -- that would silently mutate identity.
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
                          'application_server','system_number','created_at','last_used_at',
                          'gui_version_raw','server_kernel_release','server_release_family',
                          'server_release_marker','server_release_raw')) {
            if (-not $new.ContainsKey($f)) { $new[$f] = '' }
        }
        foreach ($i in @('gui_major','gui_minor','gui_patch')) {
            if (-not $new.ContainsKey($i) -or $null -eq $new[$i]) { $new[$i] = 0 }
        }
        foreach ($b in @('is_default_target','rfc_tested','gui_tested')) {
            if (-not $new.ContainsKey($b)) { $new[$b] = $false }
        }
        if (-not $new.ContainsKey('software_components') -or $null -eq $new['software_components']) {
            $new['software_components'] = @()
        }
        if (-not $new.ContainsKey('dev_defaults') -or $null -eq $new['dev_defaults']) {
            $new['dev_defaults'] = @{}
        }
        $store.connections += $new
        return $new
    })
}

function Remove-SapConnection {
    param([Parameter(Mandatory)][string] $Id)
    Update-SapConnectionStore {
        param($store)
        $store.connections = @($store.connections | Where-Object { "$($_.id)" -ne $Id })
        if ($store.default_target_id -eq $Id) { $store.default_target_id = '' }
    } | Out-Null
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

$script:_SapAi_ScriptHosts = @('powershell','pwsh','cscript','wscript','cmd','conhost','bash','sh','git-bash','sh.distrib','busybox')
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

# ---------------------------------------------------------------------------
# AI-session HEARTBEAT (stable-id liveness) -- complements the pid->id
# breadcrumb below. When Get-SapAiSessionId resolves the id from a stable env
# var (CLAUDE_CODE_SESSION_ID / SAPDEV_AI_SESSION_ID), the owner-PID anchor
# (_Get-AiOwnerPid) can land on a PER-TURN ephemeral process -- e.g. the Claude
# Code Electron host spawns a short-lived worker per turn (the durable top-level
# process is SHARED across conversations, so it cannot be the per-conversation
# anchor). That worker dies between turns, so the pid breadcrumb goes stale and
# the broker wrongly treats a still-running conversation as dead -- collapsing
# parallel sessions onto one (the recurring 2026-06-20 multi-session contention).
# The heartbeat decouples liveness from the PID: a file keyed by the STABLE id,
# whose mtime is refreshed on every Get-SapAiSessionId call; "live" = refreshed
# within the TTL. PID liveness stays the fast path / non-env-host fallback; the
# broker UNIONs both (Get-LiveAiSessionIds) and the sweep keeps a dead-pid claim
# alive while its heartbeat is fresh.
# ---------------------------------------------------------------------------
$script:_SapAi_HeartbeatTtlResolved = $null

function Get-SapAiHeartbeatTtlMinutes {
    if ($null -ne $script:_SapAi_HeartbeatTtlResolved) { return $script:_SapAi_HeartbeatTtlResolved }
    $ttl = 30
    try {
        if (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue) {
            $v = Get-SapSettingValue 'ai_liveness_ttl_minutes' ''
            $n = 0
            if ($v -and [int]::TryParse(("" + $v), [ref]$n) -and $n -gt 0) { $ttl = $n }
        }
    } catch {}
    $script:_SapAi_HeartbeatTtlResolved = $ttl
    return $ttl
}

function Get-SapAiHeartbeatDir {
    param([string]$RuntimeDir = '')
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { $RuntimeDir = Get-SapWorkRuntimeDir }
    return (Join-Path $RuntimeDir 'ai_session_alive')
}

function _Get-AiHeartbeatFileName {
    param([string]$AiId)
    return ((($AiId -replace '[^A-Za-z0-9._-]', '_')) + '.txt')
}

function Set-SapAiHeartbeat {
    # Best-effort: refresh (mtime) the stable-id heartbeat file. Never throws.
    param([string]$RuntimeDir = '', [string]$AiId)
    if ([string]::IsNullOrWhiteSpace($AiId)) { return }
    try {
        $dir = Get-SapAiHeartbeatDir -RuntimeDir $RuntimeDir
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $file = Join-Path $dir (_Get-AiHeartbeatFileName -AiId $AiId)
        # ALWAYS write (even if content is identical) so the mtime advances = heartbeat.
        [System.IO.File]::WriteAllText($file, $AiId, [System.Text.UTF8Encoding]::new($false))
        # Opportunistic GC: drop heartbeats older than 2x TTL.
        $cutoff = (Get-Date).AddMinutes(-2 * (Get-SapAiHeartbeatTtlMinutes))
        foreach ($f in (Get-ChildItem $dir -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
            if ($f.LastWriteTime -lt $cutoff) { try { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue } catch {} }
        }
    } catch {}
}

function Get-SapLiveHeartbeatIds {
    # Map ai_session_id -> $true for every heartbeat refreshed within the TTL.
    param([string]$RuntimeDir = '')
    $live = @{}
    try {
        $dir = Get-SapAiHeartbeatDir -RuntimeDir $RuntimeDir
        if (-not (Test-Path $dir)) { return $live }
        $cutoff = (Get-Date).AddMinutes(-1 * (Get-SapAiHeartbeatTtlMinutes))
        foreach ($f in (Get-ChildItem $dir -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
            if ($f.LastWriteTime -ge $cutoff) {
                $aid = ''
                try { $aid = (Get-Content $f.FullName -Raw -Encoding UTF8) } catch {}
                $aid = ("" + $aid).Trim()
                if ($aid -ne '') { $live[$aid] = $true }
            }
        }
    } catch {}
    return $live
}

function Test-SapAiHeartbeatLive {
    param([string]$AiId, [string]$RuntimeDir = '')
    if ([string]::IsNullOrWhiteSpace($AiId)) { return $false }
    return ((Get-SapLiveHeartbeatIds -RuntimeDir $RuntimeDir).ContainsKey($AiId))
}

function _Set-AiLivenessBreadcrumb {
    <#
    .SYNOPSIS
        Write/refresh the pid->ai_session_id liveness breadcrumb at
        {RuntimeDir}\ai_session_by_pid\<owner_pid>.txt that the SAP session
        broker's contention check reads (Get-LiveAiSessionIds /
        Get-PidForAiSession in sap_session_broker.ps1).
    .DESCRIPTION
        When the conversation id is supplied by an env var
        (CLAUDE_CODE_SESSION_ID / SAPDEV_AI_SESSION_ID) the id itself needs no
        file -- but the broker still needs this breadcrumb to know the
        conversation is ALIVE. Without it the directory stays empty,
        Get-LiveAiSessionIds returns @{}, ensure-own-session never sees that a
        parallel conversation already holds ses[0], and every conversation
        adopts the SAME session -- parallel-session isolation silently collapses
        (and the conversations then also share the work_dir / memory dir).

        The owner PID (parent-process walk past script hosts) is the liveness
        anchor: it is the long-lived Claude conversation process, so it stays
        alive for the whole conversation and dies with it (PID-death GC then
        reclaims the file). The short-lived per-skill PowerShell process ($PID)
        would be useless here -- it exits the instant the skill returns.

        Fully best-effort: ANY failure is swallowed so id resolution is never
        made more fragile than a plain env-var read. The env id is
        authoritative, so the file is overwritten unconditionally -- it
        supersedes any stale GUID a prior (env-less) run wrote for this same,
        possibly OS-reused, owner PID.
    #>
    param([string]$RuntimeDir, [string]$AiId)
    if ([string]::IsNullOrWhiteSpace($AiId)) { return }
    # Stable-id heartbeat: liveness that survives the per-turn owner PID dying
    # between turns (see the heartbeat helpers above). Independent of the pid
    # breadcrumb below; has its own try/catch so it never breaks id resolution.
    Set-SapAiHeartbeat -RuntimeDir $RuntimeDir -AiId $AiId
    try {
        if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { $RuntimeDir = Get-SapWorkRuntimeDir }
        $dir = Join-Path $RuntimeDir 'ai_session_by_pid'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $ownerPid = _Get-AiOwnerPid -StartPid $PID
        $file = Join-Path $dir "$ownerPid.txt"

        $mutex = [System.Threading.Mutex]::new($false, $script:_SapAi_MutexName)
        $acquired = $false
        try {
            try { $acquired = $mutex.WaitOne(5000) }
            catch [System.Threading.AbandonedMutexException] { $acquired = $true }
            if (-not $acquired) { return }   # another writer holds it; breadcrumb is best-effort

            $existing = ''
            if (Test-Path $file) { try { $existing = (Get-Content $file -Raw -Encoding UTF8).Trim() } catch {} }
            if ($existing -ne $AiId) {
                [System.IO.File]::WriteAllText($file, $AiId, [System.Text.UTF8Encoding]::new($false))
            }
            _Invoke-AiSessionGc -Dir $dir
        } finally {
            if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
            try { $mutex.Dispose() } catch {}
        }
    } catch {}
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
        # Drop the pid->id liveness breadcrumb (see _Set-AiLivenessBreadcrumb)
        # so the broker can still tell this conversation apart under an
        # explicit-id override too.
        _Set-AiLivenessBreadcrumb -RuntimeDir $RuntimeDir -AiId $env:SAPDEV_AI_SESSION_ID
        return $env:SAPDEV_AI_SESSION_ID
    }

    # Prefer the Claude-provided conversation id. It is STABLE for the whole
    # conversation and survives a Claude host-process restart -- unlike the
    # parent-PID owner heuristic below, which mints a NEW id when the host PID
    # changes, silently orphaning this AI session's broker pin / session
    # dev-defaults and falling resolution back to the DEFAULT connection (a
    # latent wrong-system risk for long-running or parallel builds across a
    # host restart). Every consumer routes through this function (broker
    # `acquire`, /sap-login `Resolve-AiSessionId`, Get-SapCurrentConnectionProfile,
    # the log filename), so anchoring here fixes them all at once. Falls through
    # to the parent-PID walk when unset (non-Claude-Code invocations, older
    # hosts) -- behaviour outside Claude Code is unchanged.
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CODE_SESSION_ID)) {
        # CRITICAL for parallel-session isolation: this early return used to skip
        # the pid->id breadcrumb write further below, leaving
        # {RuntimeDir}\ai_session_by_pid empty. The broker's ensure-own-session
        # then read an EMPTY live-session set (Get-LiveAiSessionIds), never
        # detected that another conversation already held ses[0], and every
        # parallel conversation adopted the SAME session -- silently collapsing
        # isolation. Drop the breadcrumb here so the stable env id and the
        # broker's liveness detection coexist.
        _Set-AiLivenessBreadcrumb -RuntimeDir $RuntimeDir -AiId $env:CLAUDE_CODE_SESSION_ID
        return $env:CLAUDE_CODE_SESSION_ID
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

# =============================================================================
# Current-session resolution (Phase 4.2: replaces sap_active_session.json)
# -----------------------------------------------------------------------------
# Consumer skills used to read {WORK_TEMP}\sap_active_session.json to find
# the session path and version info for the currently active SAP connection.
# Phase 4.2 eliminates that file. The same data is now derived live:
#   - session_path: broker registry (session_registry.json)'s ai_sessions
#                   pin -> matching connection block -> a usable session
#   - version info: from the matching connection's profile in connections.json
#
# Use these helpers in any skill wrapper that previously set
# `$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'`. Replace
# with:
#   $env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp $WorkTemp
# and (optionally, for version-aware skills) call
# Get-SapCurrentConnectionProfile to read gui_major / server_release_marker
# / etc.
# =============================================================================

function _Read-SessionRegistry {
    <#
    .SYNOPSIS
        Read the broker's session_registry.json (Phase 4 location).
    .NOTES
        Lightweight read -- doesn't lock the broker mutex. The broker handles
        its own write atomicity; readers see a consistent JSON document.
    #>
    param([string]$RuntimeDir = '')
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { $RuntimeDir = Get-SapWorkRuntimeDir }
    $regFile = Join-Path $RuntimeDir 'session_registry.json'
    if (-not (Test-Path $regFile)) { return $null }
    try {
        $raw = Get-Content $regFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Get-SapCurrentSessionPath {
    <#
    .SYNOPSIS
        Return the SAP GUI session path this AI session should drive.
        Replacement for the legacy `{WORK_TEMP}\sap_active_session.json`
        session_path field.
    .DESCRIPTION
        Resolution order:
          1. $env:SAPDEV_SESSION_PATH if set non-empty (explicit override).
          2. Walk this AI session's pin -> connection block in
             session_registry.json -> pick a session on that block, preferring
             entries this AI session has claimed, then any free entry, then
             the first entry.
          3. If no AI-session pin: sole-connection fallback (only one
             connection block in the registry -> first session of it).
          4. Otherwise return empty string. Caller is responsible for handling
             "ambiguous, must run /sap-login" -- the attach lib's Strategy 4
             (sole connection) or Strategy 5 (refuse) covers downstream.
    .PARAMETER WorkTemp
        Path to {work_dir}\temp (mirrors broker's convention). Used only to
        derive the runtime dir.
    .PARAMETER RuntimeDir
        Override the runtime dir directly (test sandbox).
    #>
    param(
        [string]$WorkTemp    = '',
        [string]$RuntimeDir  = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($env:SAPDEV_SESSION_PATH)) {
        return $env:SAPDEV_SESSION_PATH
    }

    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) {
        if (-not [string]::IsNullOrWhiteSpace($WorkTemp)) {
            $RuntimeDir = Join-Path (Split-Path -Parent $WorkTemp) 'runtime'
        } else {
            $RuntimeDir = Get-SapWorkRuntimeDir
        }
    }

    $aid = Get-SapAiSessionId -RuntimeDir $RuntimeDir
    $reg = _Read-SessionRegistry -RuntimeDir $RuntimeDir
    if (-not $reg) { return '' }

    # Find this AI session's pinned connection_id.
    $pinnedConnId = ''
    if ($reg.ai_sessions -and $reg.ai_sessions.PSObject.Properties[$aid]) {
        $pinnedConnId = "$($reg.ai_sessions.$aid.connection_id)"
    }

    # Walk connections looking for the pinned one (or sole-conn fallback).
    $connBlocks = @()
    if ($reg.connections) { $connBlocks = @($reg.connections) }

    $target = $null
    if ($pinnedConnId) {
        $target = $connBlocks | Where-Object { "$($_.connection_id)" -eq $pinnedConnId } | Select-Object -First 1
    }
    if (-not $target -and $connBlocks.Count -eq 1) {
        # Sole-connection default: no pin, but only one connection -- safe.
        $target = $connBlocks[0]
    }
    if (-not $target) { return '' }

    if (-not $target.entries) { return '' }

    # Prefer an entry this AI session has claimed.
    $entry = $target.entries | Where-Object {
        "$($_.ai_session_id)" -eq $aid -and "$($_.status)" -eq 'claimed'
    } | Select-Object -First 1
    if (-not $entry) {
        # Then a free entry (Easy Access, no other claim).
        $entry = $target.entries | Where-Object { "$($_.status)" -eq 'free' } | Select-Object -First 1
    }
    if (-not $entry) {
        # Fall back to the first entry -- anything alive on this connection.
        $entry = $target.entries | Select-Object -First 1
    }
    if (-not $entry) { return '' }
    return "$($entry.path)"
}

function Get-SapCurrentConnectionProfile {
    <#
    .SYNOPSIS
        Return the connection profile this AI session is pinned to (full
        profile hashtable from connections.json, including version info).
        Replacement for the version-info portion of sap_active_session.json.
    .DESCRIPTION
        Resolution order:
          1. AI session's pin from session_registry.json
             (ai_sessions[<id>].connection_id).
          2. Default profile (Get-SapDefaultConnection).
          3. Phase 4.4 auto-bootstrap: exactly one saved profile with a
             non-empty password_dpapi -> return that profile, emit INFO
             to stderr so the action is visible. Skip when -StrictMode is
             set (callers that must fail on ambiguity).
        Returns $null when nothing resolves -- caller decides what to do
        (skills using version info typically default to "no marker" and
        fall back to non-versioned VBS variants).
    .PARAMETER StrictMode
        When set, skip the Phase 4.4 single-profile auto-bootstrap. The
        function returns the pin or default exactly; ambiguous / empty
        states return $null instead of guessing.
    #>
    param(
        [string]$WorkTemp    = '',
        [string]$RuntimeDir  = '',
        [switch]$StrictMode
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) {
        if (-not [string]::IsNullOrWhiteSpace($WorkTemp)) {
            $RuntimeDir = Join-Path (Split-Path -Parent $WorkTemp) 'runtime'
        } else {
            $RuntimeDir = Get-SapWorkRuntimeDir
        }
    }

    $aid = Get-SapAiSessionId -RuntimeDir $RuntimeDir
    $reg = _Read-SessionRegistry -RuntimeDir $RuntimeDir
    $pinnedConnId = ''
    if ($reg -and $reg.ai_sessions -and $reg.ai_sessions.PSObject.Properties[$aid]) {
        $pinnedConnId = "$($reg.ai_sessions.$aid.connection_id)"
    }

    if ($pinnedConnId) {
        $p = Find-SapConnectionById -Id $pinnedConnId
        if ($p) { return $p }
    }

    $defp = Get-SapDefaultConnection
    if ($defp) { return $defp }

    if ($StrictMode) { return $null }

    # Phase 4.4 auto-bootstrap. Only triggers when:
    #   - no pin for this AI session,
    #   - no default profile set,
    #   - exactly one saved profile has a non-empty password_dpapi.
    # That's the "single-system happy path" -- user has saved a profile, hasn't
    # bothered to mark it default, and now runs an RFC skill before /sap-login.
    # Better to proceed (with a visible INFO line) than fail opaquely.
    try {
        $store = Read-SapConnectionStore
        if ($store -and $store.connections) {
            $candidates = @($store.connections | Where-Object {
                -not [string]::IsNullOrWhiteSpace("$($_.password_dpapi)")
            })
            if ($candidates.Count -eq 1) {
                $only = $candidates[0]
                # Stderr so the line surfaces above the skill's normal output
                # without contaminating stdout that downstream JSON parsers consume.
                [Console]::Error.WriteLine("INFO: auto-bootstrap pinned single saved profile id=$($only.id) description='$($only.description)' (no default; password present)")
                return $only
            }
        }
    } catch { }
    return $null
}

# =============================================================================
# Banner emission (Phase 4.4)
# -----------------------------------------------------------------------------
# Format a single-line summary of the currently pinned connection for
# emission at the top of every sap-* skill (wired into sap_log_helper.ps1
# -Action start). Cached per-process: the parent-PID walk inside
# Get-SapAiSessionId costs ~50-200ms cold via Get-CimInstance, so callers
# can hit this once and reuse the answer for the rest of the process.
# =============================================================================

$script:_SapBannerCache = $null
$script:_SapBannerCachePopulated = $false

function Format-SapBannerLine {
    <#
    .SYNOPSIS
        Render the active-connection banner: one line, or empty when no
        pin / no profile resolves. Safe to call from any sap-* skill.
    .OUTPUTS
        String. Shape:
          [active: <SID>/<CLIENT>/<USER> via <endpoint> | TR=... PKG=... FG=...]
        Endpoint priority: message_server -> application_server -> pad:<entry>.
        Dev-defaults segment included only when dev_defaults has at least
        one set field; entirely omitted when empty.
    .PARAMETER WorkTemp
        Optional override for the work temp dir (mirrors broker convention).
    .PARAMETER IncludeDevDefaults
        Append the `| TR=... PKG=... FG=...` tail when dev_defaults are set.
        Defaults to $true.
    .PARAMETER NoCache
        Bypass the per-process cache and re-resolve. Set to $true after the
        pin changes within the same process (rare).
    #>
    param(
        [string]$WorkTemp = '',
        [bool]$IncludeDevDefaults = $true,
        [bool]$NoCache = $false
    )

    $p = $null
    if (-not $NoCache -and $script:_SapBannerCachePopulated) {
        $p = $script:_SapBannerCache
    } else {
        try {
            $p = Get-SapCurrentConnectionProfile -WorkTemp $WorkTemp
        } catch {
            $p = $null
        }
        $script:_SapBannerCache = $p
        $script:_SapBannerCachePopulated = $true
    }
    if (-not $p) { return '' }

    $sid = if ("$($p.system_name)") { "$($p.system_name)" } else { '?' }
    $where = ''
    if     ("$($p.message_server)")     { $where = "$($p.message_server)" }
    elseif ("$($p.application_server)") { $where = "$($p.application_server)" }
    elseif ("$($p.logon_pad_entry)")    { $where = "pad:$($p.logon_pad_entry)" }
    else                                 { $where = '?' }

    $core = "active: $sid/$($p.client)/$($p.user) via $where"

    if ($IncludeDevDefaults -and $p.dev_defaults) {
        $parts = @()
        $dd = $p.dev_defaults
        if ("$($dd.sap_dev_transport_request)") { $parts += "TR=$($dd.sap_dev_transport_request)" }
        if ("$($dd.sap_dev_package)")           { $parts += "PKG=$($dd.sap_dev_package)" }
        if ("$($dd.sap_dev_function_group)")    { $parts += "FG=$($dd.sap_dev_function_group)" }
        if ($parts.Count -gt 0) { $core += ' | ' + ($parts -join ' ') }
    }

    return "[$core]"
}

function Clear-SapBannerCache {
    <#
    .SYNOPSIS
        Invalidate the per-process banner cache. Call after switching the
        pin in-process (e.g. sap_login_select.ps1's switch action).
    #>
    $script:_SapBannerCache = $null
    $script:_SapBannerCachePopulated = $false
}

# =============================================================================
# Per-connection dev defaults (Phase 4.3)
# -----------------------------------------------------------------------------
# Some sap-dev settings are SAP-system-specific -- most notably the transport
# request (TR numbers carry the SID prefix like S4DK..., so a TR resolved on
# S4D is meaningless on S4H). Storing them in settings.local.json with a
# single global slot causes silent contamination when a user runs Claude on
# two SAP systems in parallel.
#
# Phase 4.3 adds a `dev_defaults` hashtable to each connection profile in
# connections.json. Keys in $script:SapPerConnectionDevKeys are read from /
# written to the pinned connection's dev_defaults first; settings.local.json
# remains the global fallback for connections that haven't set a value yet.
#
# Read order  : pinned-connection dev_defaults[<key>] -> settings.local.json
# Write order : pinned-connection dev_defaults[<key>] (if pinned), else file
#
# `Get-SapSettingValue` (sap_settings_lib.ps1) checks this list and routes
# through Get-SapCurrentDevDefault automatically -- most callers don't need to
# change.
# =============================================================================

$script:SapPerConnectionDevKeys = @(
    'sap_dev_transport_request',     # Phase 4.3
    'sap_dev_package',               # Phase 4.3
    'sap_dev_function_group',        # Phase 4.3
    'sap_dev_mode',                  # Phase 4.4 -- GUI/RFC/BDC; system capability varies
    'way_to_get_transport_request',  # Phase 4.4 -- TR-workflow policy varies per project
    'rule_of_tr_description',        # Phase 4.4 -- naming-convention varies per customer
    'tr_description_template'        # Phase 4.4 -- coupled to rule_of_tr_description
)

function Get-SapPerConnectionDevKeys {
    return ,$script:SapPerConnectionDevKeys
}

$script:_SapDevDefaultAmbigWarned = $false

function Get-SapDevDefaultProfile {
    <#
    .SYNOPSIS
        Resolve the connection profile whose dev_defaults this AI session may
        READ / WRITE -- ONLY when it is unambiguously this session's:
          1. explicit AI-session pin (ai_sessions[<aid>].connection_id).
          2. no pin BUT the store holds exactly one connection -> that one.
          3. otherwise -> $null  (ambiguous: >=2 connections and no pin).
    .DESCRIPTION
        Unlike Get-SapCurrentConnectionProfile this deliberately does NOT fall
        back to Get-SapDefaultConnection or the single-password auto-bootstrap.
        Those fallbacks are correct for the banner / version info, but for
        SYSTEM-SPECIFIC dev defaults they are silent cross-system contamination:
        a TR carries the SID prefix (S4DK... vs S4HK...), so an unpinned S4H
        session resolving to "the default connection" (S4D) would READ S4D's TR
        and, on save, WRITE an S4H value into S4D's dev_defaults block. Returning
        $null on ambiguity lets the caller fall through to the global file value
        (read) or refuse-to-guess (write) instead.
    .OUTPUTS
        Profile hashtable, or $null when ambiguous.
    #>
    param([string]$RuntimeDir = '')
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { $RuntimeDir = Get-SapWorkRuntimeDir }
    $aid = Get-SapAiSessionId -RuntimeDir $RuntimeDir
    $reg = _Read-SessionRegistry -RuntimeDir $RuntimeDir
    $pinnedConnId = ''
    if ($reg -and $reg.ai_sessions -and $reg.ai_sessions.PSObject.Properties[$aid]) {
        $pinnedConnId = "$($reg.ai_sessions.$aid.connection_id)"
    }
    if ($pinnedConnId) {
        $p = Find-SapConnectionById -Id $pinnedConnId
        if ($p) { return $p }
        # Pin dangles (the connection was removed) -> treat as unpinned below.
    }
    $conns = @((Read-SapConnectionStore).connections)
    if ($conns.Count -eq 1) { return $conns[0] }
    return $null
}

function Test-SapDevDefaultAmbiguous {
    # $true when this AI session has NO pin AND >=2 connections are saved -- the
    # state where guessing a connection for a system-specific dev default would
    # contaminate across systems. Drives the one-shot WARN below.
    param([string]$RuntimeDir = '')
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { $RuntimeDir = Get-SapWorkRuntimeDir }
    $aid = Get-SapAiSessionId -RuntimeDir $RuntimeDir
    $reg = _Read-SessionRegistry -RuntimeDir $RuntimeDir
    $pinned = ''
    if ($reg -and $reg.ai_sessions -and $reg.ai_sessions.PSObject.Properties[$aid]) {
        $pinned = "$($reg.ai_sessions.$aid.connection_id)"
    }
    if ($pinned) {
        # A pin that dangles (deleted connection) is still ambiguous if >=2 remain.
        if (Find-SapConnectionById -Id $pinned) { return $false }
    }
    return (@((Read-SapConnectionStore).connections).Count -ge 2)
}

function Write-SapDevDefaultAmbiguityWarning {
    param([Parameter(Mandatory)][string]$Key, [ValidateSet('read','write')][string]$Mode = 'read')
    if ($script:_SapDevDefaultAmbigWarned) { return }
    $script:_SapDevDefaultAmbigWarned = $true
    if ($Mode -eq 'write') {
        [Console]::Error.WriteLine("WARN: sap_connection_lib: per-connection key '$Key' -- this AI session is not pinned to a connection and >=2 are saved. Writing to the GLOBAL settings file instead of guessing a system (would corrupt the default connection's dev_defaults). Run /sap-login to pin the target system so TR/package/FG land on the right connection.")
    } else {
        [Console]::Error.WriteLine("WARN: sap_connection_lib: per-connection key '$Key' -- this AI session is not pinned and >=2 connections are saved; using the GLOBAL fallback rather than the default connection's value (avoids cross-system contamination). Run /sap-login to pin the target system.")
    }
}

function Get-SapCurrentDevDefault {
    <#
    .SYNOPSIS
        Resolve a system-specific dev setting for this AI session's pinned
        connection. Falls back to settings.local.json on miss, then empty.
    .PARAMETER Key
        One of sap_dev_transport_request / sap_dev_package /
        sap_dev_function_group (or any other key -- non-listed keys still
        work, they just won't have per-connection isolation by default).
    #>
    param([Parameter(Mandatory)][string]$Key)
    $profile = $null
    try { $profile = Get-SapDevDefaultProfile } catch {}
    # 1. Session layer (per AI-session x THIS connection) wins -- task-scoped,
    #    isolates concurrent conversations on the same connection (2026-06-20).
    if ($profile -and (_NotEmpty "$($profile.id)")) {
        try {
            $sv = Get-SapSessionDevDefault -Key $Key -ConnId "$($profile.id)"
            if ("$sv" -ne '') { return "$sv" }
        } catch {}
    }
    # 2. Connection-level standing default.
    if ($profile -and $profile.ContainsKey('dev_defaults') -and $profile['dev_defaults']) {
        $dd = $profile['dev_defaults']
        $v = $null
        if ($dd -is [hashtable] -and $dd.ContainsKey($Key)) {
            $v = $dd[$Key]
        } elseif ($dd.PSObject -and ($dd.PSObject.Properties.Name -contains $Key)) {
            $v = $dd.$Key
        }
        if ($null -ne $v -and "$v" -ne '') { return "$v" }
    }
    if (-not $profile) {
        # No unambiguous connection for this session. We deliberately do NOT read
        # the default connection's dev_defaults (cross-system contamination); warn
        # once when that ambiguity is real (>=2 connections, unpinned) and fall
        # through to the global file value below.
        try { if (Test-SapDevDefaultAmbiguous) { Write-SapDevDefaultAmbiguityWarning -Key $Key -Mode 'read' } } catch {}
    }
    # File-based fallback -- read raw from merged settings WITHOUT re-entering
    # the per-conn path (avoid the Get-SapSettingValue<->Get-SapCurrentDevDefault
    # loop).
    if (Get-Command Get-SapSettings -ErrorAction SilentlyContinue) {
        $s = Get-SapSettings
        if ($s.userConfig.PSObject.Properties.Name -contains $Key) {
            $vv = $s.userConfig.$Key.value
            if ($null -ne $vv -and "$vv" -ne '') { return [string]$vv }
        }
    }
    return ''
}

function Set-SapCurrentDevDefault {
    <#
    .SYNOPSIS
        Write a per-connection dev default. Targets the pinned connection's
        dev_defaults dict in connections.json; falls back to writing
        settings.local.json when no connection is pinned (caller is on a
        fresh box that hasn't run /sap-login yet, etc.).
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [ValidateSet('Connection','Session')][string]$Scope = 'Session'
    )
    $profile = $null
    try { $profile = Get-SapDevDefaultProfile } catch {}
    # DEFAULT = Session: a write is task-scoped (per AI-session x connection) and
    # never touches connections.json, so concurrent conversations on the same
    # connection don't clobber. Pass -Scope Connection for a deliberate STANDING
    # default (onboarding). Session needs an unambiguous connection (the
    # system-qualifying ConnId); with none, fall through to the connection/global
    # write below (best effort).
    if ($Scope -eq 'Session' -and $profile -and (_NotEmpty "$($profile.id)")) {
        Set-SapSessionDevDefault -Key $Key -Value $Value -ConnId "$($profile.id)"
        return
    }
    if (-not $profile -or -not (_NotEmpty "$($profile.id)")) {
        # No unambiguous connection -> do NOT guess the default connection (that
        # writes one system's value into another's dev_defaults block). Warn when
        # the ambiguity is real (>=2 connections, unpinned) and fall back to the
        # global settings file -- inert because the read path checks each
        # connection's own dev_defaults first.
        try { if (Test-SapDevDefaultAmbiguous) { Write-SapDevDefaultAmbiguityWarning -Key $Key -Mode 'write' } } catch {}
        if (Get-Command Set-SapUserSetting -ErrorAction SilentlyContinue) {
            # -SkipPerConnRouting breaks the cycle: Set-SapUserSetting routes
            # per-conn keys through us; we route no-pin writes back through it.
            # Without the switch, the two would call each other forever.
            Set-SapUserSetting -Key $Key -Value $Value -SkipPerConnRouting
            return
        }
        throw "Set-SapCurrentDevDefault: no pinned connection and Set-SapUserSetting unavailable."
    }
    # Resolve target + write atomically (Audit P2): the find-target -> set ->
    # persist cycle runs under one store-mutex acquisition against a fresh
    # baseline, so a concurrent connection mutation can't drop this dev default.
    # The mutator returns $true when it found + updated the pinned connection,
    # $false when the pinned id is absent (so we fall through to the global file).
    $found = Update-SapConnectionStore {
        param($store)
        $target = $null
        foreach ($p in $store.connections) {
            if ("$($p.id)" -eq "$($profile.id)") { $target = $p; break }
        }
        if (-not $target) { return $false }
        if (-not $target.ContainsKey('dev_defaults') -or $null -eq $target['dev_defaults']) {
            $target['dev_defaults'] = @{}
        } elseif ($target['dev_defaults'] -is [System.Management.Automation.PSCustomObject]) {
            $h = @{}
            foreach ($pp in $target['dev_defaults'].PSObject.Properties) { $h[$pp.Name] = "$($pp.Value)" }
            $target['dev_defaults'] = $h
        }
        $target['dev_defaults'][$Key] = "$Value"
        return $true
    }
    if (-not $found) {
        if (Get-Command Set-SapUserSetting -ErrorAction SilentlyContinue) {
            # -SkipPerConnRouting breaks the cycle: Set-SapUserSetting routes
            # per-conn keys through us; we route no-pin writes back through it.
            # Without the switch, the two would call each other forever.
            Set-SapUserSetting -Key $Key -Value $Value -SkipPerConnRouting
            return
        }
        throw "Set-SapCurrentDevDefault: pinned connection id=$($profile.id) not found in store."
    }
}

# =============================================================================
# Session-scoped dev defaults (per AI-session x connection)  [added 2026-06-20]
# -----------------------------------------------------------------------------
# Phase 4.4's per-connection dev_defaults fixed cross-SYSTEM leakage but NOT
# cross-SESSION-same-system contention: N AI sessions pinned to ONE connection
# share one dev_defaults block and clobber each other (the 2026-06-20
# 069->074->075 thrash on S4D). This layer scopes a TASK's TR/package to the
# (AI-session x connection) pair, so concurrent conversations on the same
# connection don't fight, while the connection block stays the standing
# fallback. Keyed on BOTH the AI session AND the connection so a /sap-login
# --switch mid-conversation can't carry an S4DK... TR onto S4H. Decoupled from
# the broker's hot session_registry.json (own file + own mutex) so the broker's
# reconcile/rewrite never stomps it and vice-versa.
# Resolution (in Get-SapCurrentDevDefault): session layer -> connection
# dev_defaults -> global file. GC: age-pruned on write (entries older than
# _SapSessDD_MaxAgeDays); task defaults are ephemeral, so dropping an old
# conversation's is correct.
# =============================================================================
$script:_SapSessDD_MutexName      = 'SapDevSessionDevDefaults_v1'
$script:_SapSessDD_MutexTimeoutMs = 10000
$script:_SapSessDD_MaxAgeDays     = 7

function Get-SapSessionDevDefaultPath {
    param([string]$RuntimeDir = '')
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { $RuntimeDir = Get-SapWorkRuntimeDir }
    return (Join-Path $RuntimeDir 'session_dev_defaults.json')
}

function _With-SessionDevDefaultLock {
    param([scriptblock]$Body)
    $mutex = [System.Threading.Mutex]::new($false, $script:_SapSessDD_MutexName)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne($script:_SapSessDD_MutexTimeoutMs) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "sap_connection_lib: could not acquire session-dev-default mutex within $($script:_SapSessDD_MutexTimeoutMs)ms" }
        & $Body
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        try { $mutex.Dispose() } catch {}
    }
}

function _Read-SessionDevDefaultFile {
    # -> hashtable { <aid> = @{ _ts=<iso>; by_conn = @{ <connId> = @{ key=val } } } }
    param([string]$RuntimeDir = '')
    $path = Get-SapSessionDevDefaultPath -RuntimeDir $RuntimeDir
    if (-not (Test-Path $path)) { return @{} }
    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $h = @{}
        foreach ($aidProp in $obj.PSObject.Properties) {
            $blk = @{ _ts = ''; by_conn = @{} }
            $v = $aidProp.Value
            if ($v.PSObject.Properties['_ts']) { $blk._ts = "$($v._ts)" }
            if ($v.PSObject.Properties['by_conn'] -and $v.by_conn) {
                foreach ($cp in $v.by_conn.PSObject.Properties) {
                    $kv = @{}
                    foreach ($kp in $cp.Value.PSObject.Properties) { $kv[$kp.Name] = "$($kp.Value)" }
                    $blk.by_conn[$cp.Name] = $kv
                }
            }
            $h[$aidProp.Name] = $blk
        }
        return $h
    } catch { return @{} }
}

function _Write-SessionDevDefaultFile {
    param([hashtable]$Data, [string]$RuntimeDir = '')
    $path = Get-SapSessionDevDefaultPath -RuntimeDir $RuntimeDir
    $json = $Data | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function _Prune-SessionDevDefaults {
    param([hashtable]$Data)
    try {
        $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * [math]::Abs($script:_SapSessDD_MaxAgeDays))
        foreach ($aid in @($Data.Keys)) {
            $ts = $null
            try {
                if ($Data[$aid].ContainsKey('_ts') -and $Data[$aid]['_ts']) {
                    $ts = [datetime]::Parse($Data[$aid]['_ts'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                }
            } catch {}
            if ($ts -and $ts.ToUniversalTime() -lt $cutoff) { $Data.Remove($aid) | Out-Null }
        }
    } catch {}
    return $Data
}

function Get-SapSessionDevDefault {
    <#
    .SYNOPSIS
        Read a TASK-scoped dev default for the (AI-session x connection) pair.
        Returns '' on any miss. ConnId is REQUIRED (the system the default
        belongs to) -- a session default is meaningless without it.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$Aid = '',
        [string]$ConnId = '',
        [string]$RuntimeDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($ConnId)) { return '' }
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { $RuntimeDir = Get-SapWorkRuntimeDir }
    if ([string]::IsNullOrWhiteSpace($Aid)) { try { $Aid = Get-SapAiSessionId -RuntimeDir $RuntimeDir } catch { return '' } }
    $data = _Read-SessionDevDefaultFile -RuntimeDir $RuntimeDir
    if ($data.ContainsKey($Aid) -and $data[$Aid].by_conn.ContainsKey($ConnId)) {
        $kv = $data[$Aid].by_conn[$ConnId]
        if ($kv.ContainsKey($Key) -and "$($kv[$Key])" -ne '') { return "$($kv[$Key])" }
    }
    return ''
}

function Set-SapSessionDevDefault {
    <#
    .SYNOPSIS
        Write a TASK-scoped dev default under (AI-session x connection). Does NOT
        touch connections.json -- so concurrent conversations on the same
        connection never clobber each other. Mutex-serialized; age-pruned.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [string]$Aid = '',
        [string]$ConnId = '',
        [string]$RuntimeDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($ConnId)) { throw "Set-SapSessionDevDefault: -ConnId is required (the system this default belongs to)." }
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { $RuntimeDir = Get-SapWorkRuntimeDir }
    if ([string]::IsNullOrWhiteSpace($Aid)) { $Aid = Get-SapAiSessionId -RuntimeDir $RuntimeDir }
    _With-SessionDevDefaultLock {
        $data = _Read-SessionDevDefaultFile -RuntimeDir $RuntimeDir
        if (-not $data.ContainsKey($Aid)) { $data[$Aid] = @{ _ts = ''; by_conn = @{} } }
        if (-not $data[$Aid].by_conn.ContainsKey($ConnId)) { $data[$Aid].by_conn[$ConnId] = @{} }
        $data[$Aid].by_conn[$ConnId][$Key] = "$Value"
        $data[$Aid]['_ts'] = (Get-Date).ToUniversalTime().ToString('o')
        $data = _Prune-SessionDevDefaults -Data $data
        _Write-SessionDevDefaultFile -Data $data -RuntimeDir $RuntimeDir
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
    # capture step. For migration we leave it blank -- Test-SapConnectionsEqual
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
