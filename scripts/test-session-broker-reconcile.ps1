# =============================================================================
# test-session-broker-reconcile.ps1
# -----------------------------------------------------------------------------
# Offline regression test for the SAP session broker's identity
# reconciliation (sap_session_broker.ps1 discover + Sweep-StaleEntries).
#
# Reproduces the 2026-06-07 bug: a /app/con[N] slot reused by a DIFFERENT SAP
# system kept the previous system's stale identity in the registry, because
# the broker only detected change via logon_id (SystemSessionId) -- which on
# S/4HANA 1909 kernel 754 is per-workstation, NOT per-logon, so it stays
# byte-identical across an A->B system swap on one slot.
#
# Drives the REAL broker as a subprocess (so the test exercises shipped code),
# feeding canned live state through the SAPDEV_BROKER_FAKE_INFO test seam so no
# live SAP GUI is required. Each scenario uses an isolated temp workspace.
#
# Exit 0 = all scenarios pass; 1 = at least one failure.
# Run:  pwsh -File sap-dev/scripts/test-session-broker-reconcile.ps1
# =============================================================================
[CmdletBinding()]
param(
    [string] $Broker = (Join-Path $PSScriptRoot '..\plugins\sap-dev-core\shared\scripts\sap_session_broker.ps1')
)

$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Total    = 0

function Assert-Eq {
    param($Actual, $Expected, [string] $Msg)
    $script:Total++
    if ("$Actual" -ne "$Expected") {
        Write-Host "  FAIL: $Msg  (expected '$Expected', got '$Actual')"
        $script:Failures++
    } else {
        Write-Host "  ok  : $Msg = '$Actual'"
    }
}

function New-Workspace {
    $root = Join-Path $env:TEMP ("brokertest_" + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'temp')    | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'runtime') | Out-Null
    return $root
}

function Set-StaleRegistry {
    param($Root, $Json)
    $p = Join-Path $Root 'runtime\session_registry.json'
    [System.IO.File]::WriteAllText($p, $Json, [System.Text.UTF8Encoding]::new($false))
}

function Get-RegistryBlock0 {
    param($Root)
    $p = Join-Path $Root 'runtime\session_registry.json'
    $reg = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    return $reg.connections[0]
}

function Invoke-BrokerAction {
    param($Root, $Action, $FakeInfoJson)
    $fi = Join-Path $Root 'fake_info.json'
    [System.IO.File]::WriteAllText($fi, $FakeInfoJson, [System.Text.UTF8Encoding]::new($false))
    $env:SAPDEV_BROKER_FAKE_INFO = $fi
    try {
        $wt  = Join-Path $Root 'temp'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Broker -Action $Action -WorkTemp $wt 2>&1
        return ($out | Out-String)
    } finally {
        Remove-Item Env:SAPDEV_BROKER_FAKE_INFO -ErrorAction SilentlyContinue
    }
}

# --- Canned payloads ---------------------------------------------------------

# The stale registry block exactly as observed on 2026-06-07: con[0] still
# describes the long-gone S4H/22700/JA logon, but connection_id already drifted
# to S4D's profile id (df91fed6) and logon_id matches the live S4D session.
$RegStaleS4H = @'
{"updated_at":"2026-06-07T15:41:30","connections":[{"system_id":"S4H","system_number":"22","logon_id":"000C298056DE1FD198C1B88645F11013","entries":[{"claim_time":"","owner_pid":0,"stuck_program":"","discovered":true,"ai_session_id":"","was_created":false,"task_id":"","owner_skill":"","stuck_screen":"","status":"user_owned","ttl_seconds":600,"path":"/app/con[0]/ses[0]","session_number":1},{"claim_time":"","owner_pid":0,"stuck_program":"","discovered":true,"ai_session_id":"","was_created":false,"task_id":"","owner_skill":"","stuck_screen":"","status":"user_owned","ttl_seconds":600,"path":"/app/con[0]/ses[2]","session_number":3}],"user":"22700","system_name":"S4H","description":"S4H [S42022.topsap.net]","language":"JA","client":"100","logon_group":"","message_server":"","connection_path":"/app/con[0]","connection_id":"df91fed6-8913-4ce2-98e3-ef6a06881475","application_server":"vhcalhdbdb"}],"ai_sessions":{}}
'@

# A clean, already-correct S4D block (used by the "no change" / language /
# transient-empty scenarios as the starting point).
$RegCleanS4D = @'
{"updated_at":"2026-06-07T16:00:00","connections":[{"system_id":"S4D","system_number":"70","logon_id":"000C298056DE1FD198C1B88645F11013","entries":[{"claim_time":"","owner_pid":0,"stuck_program":"","discovered":true,"ai_session_id":"","was_created":false,"task_id":"","owner_skill":"","stuck_screen":"","status":"free","ttl_seconds":600,"path":"/app/con[0]/ses[0]","session_number":1},{"claim_time":"","owner_pid":0,"stuck_program":"","discovered":true,"ai_session_id":"","was_created":false,"task_id":"","owner_skill":"","stuck_screen":"","status":"free","ttl_seconds":600,"path":"/app/con[0]/ses[2]","session_number":3}],"user":"MICHAELLI","system_name":"S4D","description":"S4HANA_1909_MICHAELLI","language":"ZH","client":"100","logon_group":"","message_server":"","connection_path":"/app/con[0]","connection_id":"df91fed6-8913-4ce2-98e3-ef6a06881475","application_server":"s4sapdev"}],"ai_sessions":{}}
'@

# Live INFO: the actual S4D/MICHAELLI/ZH session captured from the live system.
$LiveS4D = @'
{"ok":true,"connections":[{"connection_path":"/app/con[0]","description":"S4HANA_1909_MICHAELLI","system_name":"S4D","client":"100","user":"MICHAELLI","language":"ZH","logon_id":"000C298056DE1FD198C1B88645F11013","message_server":"","logon_group":"","system_id":"S4D","application_server":"s4sapdev","system_number":"70","sessions":[{"path":"/app/con[0]/ses[0]","session_number":1,"transaction":"SMEN","program":"SAPLSMTR_NAVIGATION","screen":101,"has_popup":false},{"path":"/app/con[0]/ses[2]","session_number":3,"transaction":"S000","program":"SAPMSYST","screen":40,"has_popup":false}]}]}
'@

# Live INFO: same S4D system/client/user, but logged on in EN (relogin), same
# logon_id (the per-workstation kernel quirk).
$LiveS4D_EN = @'
{"ok":true,"connections":[{"connection_path":"/app/con[0]","description":"S4HANA_1909_MICHAELLI","system_name":"S4D","client":"100","user":"MICHAELLI","language":"EN","logon_id":"000C298056DE1FD198C1B88645F11013","message_server":"","logon_group":"","system_id":"S4D","application_server":"s4sapdev","system_number":"70","sessions":[{"path":"/app/con[0]/ses[0]","session_number":1,"transaction":"SMEN","program":"SAPLSMTR_NAVIGATION","screen":101,"has_popup":false},{"path":"/app/con[0]/ses[2]","session_number":3,"transaction":"S000","program":"SAPMSYST","screen":40,"has_popup":false}]}]}
'@

# Live INFO: connection present but identity not yet readable (every session on
# the SAPMSYST logon screen -> Info struct empty). Must NOT wipe stored data.
$LiveEmptyIdentity = @'
{"ok":true,"connections":[{"connection_path":"/app/con[0]","description":"","system_name":"","client":"","user":"","language":"","logon_id":"","message_server":"","logon_group":"","system_id":"","application_server":"","system_number":"","sessions":[{"path":"/app/con[0]/ses[0]","session_number":1,"transaction":"S000","program":"SAPMSYST","screen":40,"has_popup":false},{"path":"/app/con[0]/ses[2]","session_number":3,"transaction":"S000","program":"SAPMSYST","screen":40,"has_popup":false}]}]}
'@

Write-Host "Broker under test: $Broker"
Write-Host ""

# =============================================================================
# Scenario 1 -- the bug: slot reused by a different system (S4H -> S4D).
# =============================================================================
Write-Host "Scenario 1: con[0] reused S4H -> S4D (the reported bug)"
$ws = New-Workspace
Set-StaleRegistry -Root $ws -Json $RegStaleS4H
$out = Invoke-BrokerAction -Root $ws -Action 'discover' -FakeInfoJson $LiveS4D
$b   = Get-RegistryBlock0 -Root $ws
Assert-Eq $b.system_name        'S4D'                 'system_name reconciled to live'
Assert-Eq $b.user               'MICHAELLI'           'user reconciled to live'
Assert-Eq $b.language           'ZH'                  'language reconciled to live'
Assert-Eq $b.system_id          'S4D'                 'system_id reconciled to live'
Assert-Eq $b.application_server 's4sapdev'            'application_server reconciled to live'
Assert-Eq $b.system_number      '70'                  'system_number reconciled to live'
Assert-Eq $b.description        'S4HANA_1909_MICHAELLI' 'description reconciled to live'
Assert-Eq $b.connection_id      ''                    'stale connection_id cleared on system change'
Assert-Eq $b.logon_id           '000C298056DE1FD198C1B88645F11013' 'logon_id mirrored (unchanged here)'
Assert-Eq @($b.entries).Count   2                     'entries re-discovered for the new system'
$disc1 = ($out -split "`r?`n" | Where-Object { $_ -match '^DISCOVERED:' } | Select-Object -First 1)
Assert-Eq ($disc1 -match 'DISCOVERED: 2 new') $true   "discover reports 2 new ('$($disc1.Trim())')"
Remove-Item -Recurse -Force $ws -ErrorAction SilentlyContinue
Write-Host ""

# =============================================================================
# Scenario 2 -- no change: identity + connection_id + entries all preserved.
# =============================================================================
Write-Host "Scenario 2: no change (S4D stays S4D)"
$ws = New-Workspace
Set-StaleRegistry -Root $ws -Json $RegCleanS4D
$out = Invoke-BrokerAction -Root $ws -Action 'discover' -FakeInfoJson $LiveS4D
$b   = Get-RegistryBlock0 -Root $ws
Assert-Eq $b.system_name   'S4D'                                  'system_name unchanged'
Assert-Eq $b.language      'ZH'                                   'language unchanged'
Assert-Eq $b.connection_id 'df91fed6-8913-4ce2-98e3-ef6a06881475' 'connection_id preserved (no system change)'
Assert-Eq @($b.entries).Count 2                                   'existing entries preserved'
$disc2 = ($out -split "`r?`n" | Where-Object { $_ -match '^DISCOVERED:' } | Select-Object -First 1)
Assert-Eq ($disc2 -match 'DISCOVERED: 0 new') $true               "discover reports 0 new ('$($disc2.Trim())')"
Remove-Item -Recurse -Force $ws -ErrorAction SilentlyContinue
Write-Host ""

# =============================================================================
# Scenario 3 -- same system, relogin in a different language (ZH -> EN).
# Language must refresh, entries drop+rediscover, connection_id PRESERVED.
# =============================================================================
Write-Host "Scenario 3: same system, language relogin ZH -> EN"
$ws = New-Workspace
Set-StaleRegistry -Root $ws -Json $RegCleanS4D
$out = Invoke-BrokerAction -Root $ws -Action 'discover' -FakeInfoJson $LiveS4D_EN
$b   = Get-RegistryBlock0 -Root $ws
Assert-Eq $b.system_name   'S4D'                                  'system_name unchanged'
Assert-Eq $b.language      'EN'                                   'language refreshed to live'
Assert-Eq $b.connection_id 'df91fed6-8913-4ce2-98e3-ef6a06881475' 'connection_id preserved (same system)'
Assert-Eq @($b.entries).Count 2                                   'entries re-discovered after relogin'
$disc3 = ($out -split "`r?`n" | Where-Object { $_ -match '^DISCOVERED:' } | Select-Object -First 1)
Assert-Eq ($disc3 -match 'DISCOVERED: 2 new') $true               "discover reports 2 new ('$($disc3.Trim())')"
Remove-Item -Recurse -Force $ws -ErrorAction SilentlyContinue
Write-Host ""

# =============================================================================
# Scenario 4 -- transient empty read must NOT wipe good stored identity.
# =============================================================================
Write-Host "Scenario 4: transient empty live read (logon screen)"
$ws = New-Workspace
Set-StaleRegistry -Root $ws -Json $RegCleanS4D
$null = Invoke-BrokerAction -Root $ws -Action 'discover' -FakeInfoJson $LiveEmptyIdentity
$b   = Get-RegistryBlock0 -Root $ws
Assert-Eq $b.system_name   'S4D'                                  'system_name preserved (not wiped by empty read)'
Assert-Eq $b.language      'ZH'                                   'language preserved'
Assert-Eq $b.connection_id 'df91fed6-8913-4ce2-98e3-ef6a06881475' 'connection_id preserved'
Assert-Eq @($b.entries).Count 2                                   'entries preserved'
Remove-Item -Recurse -Force $ws -ErrorAction SilentlyContinue
Write-Host ""

# =============================================================================
# Scenario 5 -- gc surfaces the system_changed drop reason.
# =============================================================================
Write-Host "Scenario 5: gc reports system_changed drops"
$ws = New-Workspace
Set-StaleRegistry -Root $ws -Json $RegStaleS4H
$out = Invoke-BrokerAction -Root $ws -Action 'gc' -FakeInfoJson $LiveS4D
$gcLine = ($out -split "`r?`n" | Where-Object { $_ -match '^GC: dropped' } | Select-Object -First 1)
Assert-Eq ($gcLine -match 'GC: dropped 2') $true                  "gc dropped 2 stale entries ('$($gcLine.Trim())')"
$hasReason = ($out -match 'reason=system_changed')
Assert-Eq $hasReason $true                                        'gc emits reason=system_changed'
$b = Get-RegistryBlock0 -Root $ws
Assert-Eq $b.system_name   'S4D'                                  'gc also reconciled identity'
Assert-Eq $b.connection_id ''                                     'gc cleared stale connection_id'
Remove-Item -Recurse -Force $ws -ErrorAction SilentlyContinue
Write-Host ""

# --- Summary -----------------------------------------------------------------
Write-Host "================================================================"
if ($script:Failures -eq 0) {
    Write-Host "PASS: $($script:Total)/$($script:Total) assertions passed."
    exit 0
} else {
    Write-Host "FAIL: $($script:Failures)/$($script:Total) assertions failed."
    exit 1
}
