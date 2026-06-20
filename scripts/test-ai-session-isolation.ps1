# =============================================================================
# test-ai-session-isolation.ps1
# -----------------------------------------------------------------------------
# Offline regression test for parallel-AI-session isolation.
#
# Reproduces the 2026-06-20 bug found while testing parallel sessions on a
# second PC: two conversations on the same SAP connection both ended up
# driving ses[0] (broker reported formalized=true instead of spawned=true),
# silently collapsing isolation.
#
# Root cause: Get-SapAiSessionId (sap_connection_lib.ps1) returns early when
# CLAUDE_CODE_SESSION_ID is set and -- before the fix -- skipped writing the
# pid->id liveness breadcrumb at {runtime}\ai_session_by_pid\<owner_pid>.txt.
# With that directory empty, the broker's Get-LiveAiSessionIds returned @{},
# so ensure-own-session never saw that another LIVE conversation already held
# ses[0] and just adopted it.
#
# Two halves:
#   Part A -- the fix: Get-SapAiSessionId now drops the breadcrumb in the
#             env-id path (CLAUDE_CODE_SESSION_ID and SAPDEV_AI_SESSION_ID),
#             and the legacy GUID path still works.
#   Part B -- the consumer: given a breadcrumb proving another conversation is
#             live on ses[0], the broker SPAWNS a fresh session (spawned=true)
#             instead of formalizing the shared one. Without the breadcrumb it
#             reproduces the collapse (formalized=true).
#
# Drives the REAL shipped scripts as subprocesses (the lib for Part A, the
# broker for Part B), using the SAPDEV_BROKER_FAKE_INFO / SAPDEV_BROKER_FAKE_SPAWN
# test seams so no live SAP GUI is required. Each scenario uses an isolated
# temp workspace.
#
# Exit 0 = all scenarios pass; 1 = at least one failure.
# Run:  pwsh -File sap-dev/scripts/test-ai-session-isolation.ps1
# =============================================================================
[CmdletBinding()]
param(
    [string] $Broker  = '',
    [string] $ConnLib = ''
)

$ErrorActionPreference = 'Stop'

# Resolve in the body (not param defaults): $PSScriptRoot is empty inside the
# param block under Windows PowerShell 5.1, so fall back to the invocation path.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
             else { (Get-Location).Path }
if (-not $Broker)  { $Broker  = (Join-Path $scriptDir '..\plugins\sap-dev-core\shared\scripts\sap_session_broker.ps1') }
if (-not $ConnLib) { $ConnLib = (Join-Path $scriptDir '..\plugins\sap-dev-core\shared\scripts\sap_connection_lib.ps1') }
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

function Assert-True {
    param([bool] $Cond, [string] $Msg)
    $script:Total++
    if (-not $Cond) {
        Write-Host "  FAIL: $Msg  (expected condition true)"
        $script:Failures++
    } else {
        Write-Host "  ok  : $Msg"
    }
}

function New-Workspace {
    $root = Join-Path $env:TEMP ("aisesstest_" + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'temp')    | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'runtime') | Out-Null
    return $root
}

# The probe runs the SHIPPED Get-SapAiSessionId in a clean child process and
# reports the resolved id plus every breadcrumb file (pid|content|alive). Takes
# the lib path as an arg so the here-string needs no interpolation/escaping.
$script:ProbeBody = @'
param([string]$RuntimeDir, [string]$ConnLib)
$ErrorActionPreference = 'Stop'
. $ConnLib
$id = Get-SapAiSessionId -RuntimeDir $RuntimeDir
Write-Output "RESULTID=$id"
$dir = Join-Path $RuntimeDir 'ai_session_by_pid'
if (Test-Path $dir) {
    foreach ($f in (Get-ChildItem $dir -Filter '*.txt' -File)) {
        $content = (Get-Content $f.FullName -Raw -Encoding UTF8).Trim()
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $alive = $false
        $n = 0
        if ([int]::TryParse($stem, [ref]$n)) {
            try { Get-Process -Id $n -ErrorAction Stop | Out-Null; $alive = $true } catch {}
        }
        Write-Output "CRUMB=$stem|$content|$alive"
    }
}
'@

function Invoke-Probe {
    # Runs the probe with a controlled env. $CcId / $SdId of '' clear the var.
    param($Root, [string] $CcId, [string] $SdId)
    $probePath = Join-Path $Root 'probe.ps1'
    [System.IO.File]::WriteAllText($probePath, $script:ProbeBody, [System.Text.UTF8Encoding]::new($false))
    $rt = Join-Path $Root 'runtime'
    $savedCc = $env:CLAUDE_CODE_SESSION_ID
    $savedSd = $env:SAPDEV_AI_SESSION_ID
    try {
        if ([string]::IsNullOrEmpty($CcId)) { Remove-Item Env:CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue }
        else { $env:CLAUDE_CODE_SESSION_ID = $CcId }
        if ([string]::IsNullOrEmpty($SdId)) { Remove-Item Env:SAPDEV_AI_SESSION_ID -ErrorAction SilentlyContinue }
        else { $env:SAPDEV_AI_SESSION_ID = $SdId }
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probePath $rt $ConnLib 2>&1
        return ($out | Out-String)
    } finally {
        if ($null -eq $savedCc) { Remove-Item Env:CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue } else { $env:CLAUDE_CODE_SESSION_ID = $savedCc }
        if ($null -eq $savedSd) { Remove-Item Env:SAPDEV_AI_SESSION_ID  -ErrorAction SilentlyContinue } else { $env:SAPDEV_AI_SESSION_ID  = $savedSd }
    }
}

function Get-Crumbs {
    param([string] $ProbeOut)
    $crumbs = @()
    foreach ($line in ($ProbeOut -split "`r?`n")) {
        if ($line -match '^CRUMB=([^|]*)\|([^|]*)\|(.*)$') {
            $crumbs += [pscustomobject]@{ Pid = $Matches[1]; Content = $Matches[2]; Alive = $Matches[3].Trim() }
        }
    }
    return ,$crumbs
}

function Get-ResultId {
    param([string] $ProbeOut)
    $m = ($ProbeOut -split "`r?`n" | Where-Object { $_ -match '^RESULTID=' } | Select-Object -First 1)
    if ($m -match '^RESULTID=(.*)$') { return $Matches[1].Trim() }
    return ''
}

Write-Host "Lib under test:    $ConnLib"
Write-Host "Broker under test: $Broker"
Write-Host ""

# =============================================================================
# PART A -- Get-SapAiSessionId writes the liveness breadcrumb (the fix).
# =============================================================================
Write-Host "Part A: Get-SapAiSessionId drops the pid->id liveness breadcrumb"
Write-Host ""

# --- A1: CLAUDE_CODE_SESSION_ID -> id returned AND a matching live breadcrumb.
Write-Host "A1: CLAUDE_CODE_SESSION_ID writes a live breadcrumb (the bug fix)"
$wsA = New-Workspace
$outA1   = Invoke-Probe -Root $wsA -CcId 'CC-AAA-111' -SdId ''
$idA1    = Get-ResultId -ProbeOut $outA1
$crumbA1 = @(Get-Crumbs -ProbeOut $outA1)
Assert-Eq   $idA1 'CC-AAA-111'        'returns the CLAUDE_CODE_SESSION_ID'
Assert-Eq   $crumbA1.Count 1          'exactly one breadcrumb written'
if ($crumbA1.Count -eq 1) {
    Assert-Eq   $crumbA1[0].Content 'CC-AAA-111' 'breadcrumb content = the id'
    Assert-Eq   $crumbA1[0].Alive   'True'       'breadcrumb pid is a live process'
}

# --- A2: idempotent -- a second call keeps a single breadcrumb (same owner pid).
Write-Host "A2: second call is idempotent (still one breadcrumb)"
$outA2   = Invoke-Probe -Root $wsA -CcId 'CC-AAA-111' -SdId ''
$crumbA2 = @(Get-Crumbs -ProbeOut $outA2)
Assert-Eq $crumbA2.Count 1            'still exactly one breadcrumb after re-call'
if ($crumbA2.Count -eq 1) { Assert-Eq $crumbA2[0].Content 'CC-AAA-111' 'content unchanged' }

# --- A3: SAPDEV_AI_SESSION_ID wins AND refreshes the breadcrumb to that id.
Write-Host "A3: SAPDEV_AI_SESSION_ID overrides + refreshes the breadcrumb"
$outA3   = Invoke-Probe -Root $wsA -CcId 'CC-AAA-111' -SdId 'SD-BBB-222'
$idA3    = Get-ResultId -ProbeOut $outA3
$crumbA3 = @(Get-Crumbs -ProbeOut $outA3)
Assert-Eq $idA3 'SD-BBB-222'          'SAPDEV_AI_SESSION_ID takes precedence'
Assert-True ([bool]($crumbA3 | Where-Object { $_.Content -eq 'SD-BBB-222' })) 'breadcrumb refreshed to the override id'
Assert-True (-not ($crumbA3 | Where-Object { $_.Content -eq 'CC-AAA-111' }))  'stale CC id overwritten (same owner pid)'
Remove-Item -Recurse -Force $wsA -ErrorAction SilentlyContinue
Write-Host ""

# --- A4: no env id -> legacy parent-PID + minted-GUID path still works.
Write-Host "A4: no env id -> legacy GUID path still mints + records an id"
$wsA4    = New-Workspace
$outA4   = Invoke-Probe -Root $wsA4 -CcId '' -SdId ''
$idA4    = Get-ResultId -ProbeOut $outA4
$crumbA4 = @(Get-Crumbs -ProbeOut $outA4)
Assert-True ($idA4 -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-') 'legacy path returns a GUID'
Assert-Eq   $crumbA4.Count 1                                 'legacy path writes one breadcrumb'
if ($crumbA4.Count -eq 1) { Assert-Eq $crumbA4[0].Content $idA4 'breadcrumb content = the minted GUID' }
Remove-Item -Recurse -Force $wsA4 -ErrorAction SilentlyContinue
Write-Host ""

# =============================================================================
# PART B -- the broker spawns (isolates) iff a live breadcrumb proves
# contention; without it, it reproduces the collapse.
# =============================================================================
Write-Host "Part B: ensure-own-session spawns vs. collapses based on the breadcrumb"
Write-Host ""

$nowTs = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

# Registry: con[0] pinned by BOTH AI sessions; ses[0] currently claimed by the
# OTHER conversation. ai_sessions has both ids so MINE resolves its pin.
$Registry = @"
{"updated_at":"$nowTs","ai_sessions":{"AISESS-MINE":{"connection_id":"CID-1","pinned_at":"$nowTs","pin_reason":"test","last_seen_at":"$nowTs"},"AISESS-OTHER":{"connection_id":"CID-1","pinned_at":"$nowTs","pin_reason":"test","last_seen_at":"$nowTs"}},"connections":[{"connection_path":"/app/con[0]","connection_id":"CID-1","system_name":"S4D","client":"100","user":"MICHAELLI","language":"ZH","description":"S4HANA_1909_TEST","logon_id":"LID-X","message_server":"","logon_group":"","system_id":"S4D","application_server":"s4sapdev","system_number":"70","entries":[{"path":"/app/con[0]/ses[0]","session_number":1,"task_id":"","ai_session_id":"AISESS-OTHER","owner_pid":0,"owner_skill":"","status":"claimed","claim_time":"$nowTs","ttl_seconds":600,"discovered":false,"stuck_program":"","stuck_screen":"","was_created":false}]}]}
"@

# Live INFO: con[0] identity matches the stored block (so the sweep keeps the
# entry). For B2 it also exposes the freshly-spawned ses[1] sitting at Easy
# Access (S000) so the post-spawn reset is skipped (no COM call needed).
$LiveInfoSes0 = '{"ok":true,"connections":[{"connection_path":"/app/con[0]","description":"S4HANA_1909_TEST","system_name":"S4D","client":"100","user":"MICHAELLI","language":"ZH","logon_id":"LID-X","message_server":"","logon_group":"","system_id":"S4D","application_server":"s4sapdev","system_number":"70","sessions":[{"path":"/app/con[0]/ses[0]","session_number":1,"transaction":"SMEN","program":"SAPLSMTR_NAVIGATION","screen":101,"has_popup":false}]}]}'
$LiveInfoSes01 = '{"ok":true,"connections":[{"connection_path":"/app/con[0]","description":"S4HANA_1909_TEST","system_name":"S4D","client":"100","user":"MICHAELLI","language":"ZH","logon_id":"LID-X","message_server":"","logon_group":"","system_id":"S4D","application_server":"s4sapdev","system_number":"70","sessions":[{"path":"/app/con[0]/ses[0]","session_number":1,"transaction":"SMEN","program":"SAPLSMTR_NAVIGATION","screen":101,"has_popup":false},{"path":"/app/con[0]/ses[1]","session_number":2,"transaction":"S000","program":"SAPMSYST","screen":40,"has_popup":false}]}]}'

function Invoke-EnsureOwn {
    param($Root, [string] $FakeInfoJson, [string] $FakeSpawnPath, [string[]] $LiveCrumbs)
    # Pre-seed any "other conversation is alive" breadcrumbs. Each entry is
    # "<pid>=<id>"; pid must be a live process for Is-ProcessAlive to count it.
    $crumbDir = Join-Path $Root 'runtime\ai_session_by_pid'
    if ($LiveCrumbs) {
        New-Item -ItemType Directory -Force -Path $crumbDir | Out-Null
        foreach ($c in $LiveCrumbs) {
            $parts = $c -split '=', 2
            [System.IO.File]::WriteAllText((Join-Path $crumbDir ($parts[0] + '.txt')), $parts[1], [System.Text.UTF8Encoding]::new($false))
        }
    }
    $fi = Join-Path $Root 'fake_info.json'
    [System.IO.File]::WriteAllText($fi, $FakeInfoJson, [System.Text.UTF8Encoding]::new($false))
    $env:SAPDEV_BROKER_FAKE_INFO = $fi
    if ($FakeSpawnPath) { $env:SAPDEV_BROKER_FAKE_SPAWN = $FakeSpawnPath }
    try {
        $wt  = Join-Path $Root 'temp'
        # Pass -AiSessionId explicitly so the decision is driven purely by the
        # seeded breadcrumbs, independent of this runner's real env id.
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Broker `
                    -Action 'ensure-own-session' -WorkTemp $wt -AiSessionId 'AISESS-MINE' 2>&1
        return ($out | Out-String)
    } finally {
        Remove-Item Env:SAPDEV_BROKER_FAKE_INFO  -ErrorAction SilentlyContinue
        Remove-Item Env:SAPDEV_BROKER_FAKE_SPAWN -ErrorAction SilentlyContinue
    }
}

# --- B1: NO breadcrumb for the other conversation -> the collapse (the bug).
Write-Host "B1: no live breadcrumb -> broker formalizes the shared ses[0] (collapse repro)"
$wsB1 = New-Workspace
[System.IO.File]::WriteAllText((Join-Path $wsB1 'runtime\session_registry.json'), $Registry, [System.Text.UTF8Encoding]::new($false))
$outB1 = Invoke-EnsureOwn -Root $wsB1 -FakeInfoJson $LiveInfoSes0 -FakeSpawnPath '' -LiveCrumbs @()
$lineB1 = ($outB1 -split "`r?`n" | Where-Object { $_ -match 'OWN_SESSION:' } | Select-Object -First 1)
Assert-True ($outB1 -match 'formalized=true')  "without a breadcrumb it adopts ses[0] ('$($lineB1.Trim())')"
Assert-True (-not ($outB1 -match 'spawned=true')) 'and does NOT spawn'
Assert-True ($outB1 -match "INFO: formalizing .* ai_session 'AISESS-OTHER'") 'emits a diagnostic instead of collapsing silently'
Remove-Item -Recurse -Force $wsB1 -ErrorAction SilentlyContinue
Write-Host ""

# --- B2: live breadcrumb for the other conversation -> spawn a fresh session.
Write-Host "B2: live breadcrumb present -> broker spawns ses[1] (isolation preserved)"
$wsB2 = New-Workspace
[System.IO.File]::WriteAllText((Join-Path $wsB2 'runtime\session_registry.json'), $Registry, [System.Text.UTF8Encoding]::new($false))
# Seed the other conversation as alive: map THIS test runner's pid (definitely
# alive) to AISESS-OTHER.
$outB2 = Invoke-EnsureOwn -Root $wsB2 -FakeInfoJson $LiveInfoSes01 -FakeSpawnPath '/app/con[0]/ses[1]' -LiveCrumbs @("$PID=AISESS-OTHER")
$lineB2 = ($outB2 -split "`r?`n" | Where-Object { $_ -match 'OWN_SESSION:' } | Select-Object -First 1)
Assert-True ($outB2 -match 'spawned=true')        "with a live breadcrumb it spawns a new session ('$($lineB2.Trim())')"
Assert-True ($outB2 -match 'ses\[1\]')             'the claimed session is the newly spawned ses[1]'
Assert-True (-not ($outB2 -match 'formalized=true')) 'and does NOT formalize the shared ses[0]'
Remove-Item -Recurse -Force $wsB2 -ErrorAction SilentlyContinue
Write-Host ""

# =============================================================================
# PART C -- stable-id HEARTBEAT liveness (the 2026-06-20 *79 follow-up fix).
# On hosts where Get-SapAiSessionId resolves the id from CLAUDE_CODE_SESSION_ID,
# the owner-PID anchor (_Get-AiOwnerPid) lands on a PER-TURN process that dies
# between turns -- so the Part A/B pid breadcrumb goes stale and a conversation
# that logged in a turn earlier looks dead, collapsing onto the shared ses[0].
# The heartbeat decouples liveness from the PID; the broker UNIONs both and the
# sweep keeps a dead-pid claim while the heartbeat is fresh.
# =============================================================================
Write-Host "Part C: stable-id heartbeat keeps a conversation live across turns"
Write-Host ""
. $ConnLib   # bring Set-SapAiHeartbeat / Get-SapLiveHeartbeatIds / Test-SapAiHeartbeatLive into scope

# --- C1: a fresh heartbeat is live + counted.
Write-Host "C1: fresh heartbeat -> live + in the live map"
$wsC = New-Workspace
$rtC = Join-Path $wsC 'runtime'
Set-SapAiHeartbeat -RuntimeDir $rtC -AiId 'HB-ONE'
Assert-True (Test-SapAiHeartbeatLive -AiId 'HB-ONE' -RuntimeDir $rtC)           'fresh heartbeat is live'
Assert-True ((Get-SapLiveHeartbeatIds -RuntimeDir $rtC).ContainsKey('HB-ONE')) 'fresh heartbeat appears in the live map'

# --- C2: a heartbeat older than the TTL is not live.
Write-Host "C2: heartbeat older than the TTL -> not live"
$hbFile = Join-Path (Get-SapAiHeartbeatDir -RuntimeDir $rtC) 'HB-ONE.txt'
[System.IO.File]::SetLastWriteTime($hbFile, (Get-Date).AddMinutes(-1440))
Assert-True (-not (Test-SapAiHeartbeatLive -AiId 'HB-ONE' -RuntimeDir $rtC)) 'an aged heartbeat is not live'
Remove-Item -Recurse -Force $wsC -ErrorAction SilentlyContinue
Write-Host ""

# --- C3: OTHER conversation alive via HEARTBEAT ONLY (no pid crumb) -> spawn.
#     The exact *79 scenario: the two logins were in different turns, so the
#     other conversation's pid crumb is dead, but its heartbeat is fresh -> the
#     broker must STILL isolate (spawn ses[1]), not collapse onto ses[0].
Write-Host "C3: other live via heartbeat only (no pid crumb) -> broker spawns"
$wsC3 = New-Workspace
[System.IO.File]::WriteAllText((Join-Path $wsC3 'runtime\session_registry.json'), $Registry, [System.Text.UTF8Encoding]::new($false))
Set-SapAiHeartbeat -RuntimeDir (Join-Path $wsC3 'runtime') -AiId 'AISESS-OTHER'
$outC3 = Invoke-EnsureOwn -Root $wsC3 -FakeInfoJson $LiveInfoSes01 -FakeSpawnPath '/app/con[0]/ses[1]' -LiveCrumbs @()
$lineC3 = ($outC3 -split "`r?`n" | Where-Object { $_ -match 'OWN_SESSION:' } | Select-Object -First 1)
Assert-True ($outC3 -match 'spawned=true')          "heartbeat-only liveness still spawns ('$($lineC3.Trim())')"
Assert-True (-not ($outC3 -match 'formalized=true')) 'and does NOT collapse onto the shared ses[0]'
Remove-Item -Recurse -Force $wsC3 -ErrorAction SilentlyContinue
Write-Host ""

# --- C3b / C3c: the sweep guard -- a dead owner_pid claim survives the sweep
#     IFF its conversation is still heartbeat-live.
$RegistryDeadPid = $Registry -replace '"owner_pid":0', '"owner_pid":999990'

Write-Host "C3b: dead owner_pid + fresh heartbeat -> claim survives the sweep"
$wsC3b = New-Workspace
[System.IO.File]::WriteAllText((Join-Path $wsC3b 'runtime\session_registry.json'), $RegistryDeadPid, [System.Text.UTF8Encoding]::new($false))
Set-SapAiHeartbeat -RuntimeDir (Join-Path $wsC3b 'runtime') -AiId 'AISESS-OTHER'
$null = Invoke-EnsureOwn -Root $wsC3b -FakeInfoJson $LiveInfoSes01 -FakeSpawnPath '/app/con[0]/ses[1]' -LiveCrumbs @()
$regAfterB = Get-Content (Join-Path $wsC3b 'runtime\session_registry.json') -Raw
Assert-True (@(($regAfterB | ConvertFrom-Json).connections[0].entries | Where-Object { "$($_.ai_session_id)" -eq 'AISESS-OTHER' }).Count -ge 1) 'dead-pid claim with a fresh heartbeat is NOT swept'
Remove-Item -Recurse -Force $wsC3b -ErrorAction SilentlyContinue

Write-Host "C3c: dead owner_pid + NO heartbeat -> claim reclaimed (guard inactive)"
$wsC3c = New-Workspace
[System.IO.File]::WriteAllText((Join-Path $wsC3c 'runtime\session_registry.json'), $RegistryDeadPid, [System.Text.UTF8Encoding]::new($false))
$null = Invoke-EnsureOwn -Root $wsC3c -FakeInfoJson $LiveInfoSes01 -FakeSpawnPath '/app/con[0]/ses[1]' -LiveCrumbs @()
$regAfterC = Get-Content (Join-Path $wsC3c 'runtime\session_registry.json') -Raw
Assert-True (@(($regAfterC | ConvertFrom-Json).connections[0].entries | Where-Object { "$($_.ai_session_id)" -eq 'AISESS-OTHER' }).Count -eq 0) 'dead-pid claim without a heartbeat is swept (pid_dead)'
Remove-Item -Recurse -Force $wsC3c -ErrorAction SilentlyContinue
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
