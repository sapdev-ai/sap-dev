# =============================================================================
# sap_doctor_checks.ps1  -  Environment preflight checks for /sap-doctor
#
# Read-only health probe for the sap-dev runtime environment. Emits one
# parseable CHECK: line per probe plus a partial summary line. Runs in well
# under a second and DEGRADES GRACEFULLY: a probe that cannot be run (e.g. the
# server-side checks when RFC is down) reports RESULT: SKIP -- never a false
# PASS. This is the honesty contract borrowed from sap_finding_lib: "could not
# check" is never rendered as "passed".
#
# This script covers the cfg (workstation / config), rfc (connectivity), and
# srv (server-side) groups. Two groups are produced OUTSIDE this script and
# composed by the SKILL.md:
#   * gui    -- is SAP GUI Scripting reachable? Probed by the static
#               sap_check_gui_login_status.vbs (PowerShell 7+/.NET cannot bind
#               the SAPGUI Scripting COM object; it must be reached via cscript).
#   * devenv -- TR / package / function group / wrapper artefacts. Delegated to
#               /sap-dev-status (authoritative, already <1s over RFC).
#
# Tokens replaced at run time by the SKILL.md wrapper:
#   %%RFC_LIB_PS1%%   absolute path to sap_rfc_lib.ps1 (dot-sourced)
#   %%WORK_DIR%%      resolved work_dir (from Get-SapWorkDir)
#   %%SAP_SERVER%%  %%SAP_SYSNR%%  %%SAP_CLIENT%%
#   %%SAP_USER%%    %%SAP_PASSWORD%%  %%SAP_LANGUAGE%%
#       -- the SKILL.md substitutes these with EMPTY strings on purpose:
#          Connect-SapRfc (Phase 4.3) then falls back to the AI-session's
#          pinned connection profile in runtime/connections.json. The doctor
#          thereby probes the REAL pinned connection a user's skills would use,
#          and surfaces a broken pin / profile as an RFC_PING failure.
#
# Output (one line per check):
#   CHECK: <ID> | GROUP: <cfg|rfc|srv> | RESULT: <PASS|WARN|FAIL|SKIP> | DETAIL: <text> | FIX: <remediation or ->
#
# Partial summary (last line):
#   DOCTOR_PS: <READY|DEGRADED|BLOCKED> FAIL=<n> WARN=<n> SKIP=<n>
#
# Exit code:
#   0 = no FAIL (READY or DEGRADED)
#   1 = one or more FAIL (BLOCKED)
# =============================================================================

$workDir = "%%WORK_DIR%%"

$script:nFail = 0
$script:nWarn = 0
$script:nSkip = 0

function Emit($id, $group, $result, $detail, $fix) {
    if ([string]::IsNullOrWhiteSpace($fix)) { $fix = '-' }
    switch ($result) {
        'FAIL' { $script:nFail++ }
        'WARN' { $script:nWarn++ }
        'SKIP' { $script:nSkip++ }
    }
    Write-Host ("CHECK: {0} | GROUP: {1} | RESULT: {2} | DETAIL: {3} | FIX: {4}" -f $id, $group, $result, $detail, $fix)
}

# RFC_READ_TABLE helper (mirrors sap_dev_artefacts.ps1). Returns $null on RFC
# failure, an empty array on 0 rows (the comma operator forces array return so
# 0 rows != failure). Only used for safe (non-LRAW) tables.
function Q-RfcReadTable($dest, $table, $where, $cols) {
    $fn = $dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", $table)
    $fn.SetValue("DELIMITER", "|")
    if ($where) { Add-RfcOption $fn $where }
    foreach ($c in $cols) { Add-RfcField $fn $c }
    try { $fn.Invoke($dest) } catch { return $null }
    $data = $fn.GetTable("DATA")
    $rows = @()
    for ($i = 0; $i -lt $data.RowCount; $i++) {
        $data.CurrentIndex = $i
        $rows += ,$data.GetString("WA")
    }
    return ,$rows
}

# ---------------------------------------------------------------------------
# cfg 1. PowerShell bitness (this script is meant to run 32-bit for NCo)
# ---------------------------------------------------------------------------
if ([IntPtr]::Size -eq 4) {
    Emit 'PS_BITNESS' 'cfg' 'PASS' '32-bit PowerShell (NCo 3.1 compatible)' '-'
} else {
    Emit 'PS_BITNESS' 'cfg' 'WARN' ("64-bit PowerShell (IntPtr={0} bytes); NCo 3.1 is 32-bit only" -f [IntPtr]::Size) 'Launch via C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
}

# ---------------------------------------------------------------------------
# cfg 2. SAP NCo 3.1 present in the 32-bit GAC
# ---------------------------------------------------------------------------
$gacRoot   = "C:\Windows\Microsoft.NET\assembly\GAC_32"
$ncoDir    = Get-ChildItem -Path (Join-Path $gacRoot 'sapnco')       -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
$utilsDir  = Get-ChildItem -Path (Join-Path $gacRoot 'sapnco_utils') -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
$ncoPresent = ($null -ne $ncoDir -and $null -ne $utilsDir)
if ($ncoPresent) {
    Emit 'NCO_GAC' 'cfg' 'PASS' ("SAP NCo 3.1 present in GAC_32 ({0})" -f $ncoDir.Name) '-'
} else {
    Emit 'NCO_GAC' 'cfg' 'FAIL' 'SAP NCo 3.1 not found in GAC_32 (sapnco / sapnco_utils) - RFC features unavailable; GUI-only skills are unaffected' 'Install SAP Connector for .NET 3.1 (32-bit, .NET 4.0) into the GAC'
}

# ---------------------------------------------------------------------------
# cfg 3. work_dir pinned by an update-proof root: the SAPDEV_AI_WORK_DIR env var
#        OR the durable out-of-cache pointer %APPDATA%\sapdev-ai\work_dir.txt.
#        The pointer is what bridges the current session (a freshly-set User env
#        var never reaches already-running processes) AND survives plugin
#        updates -- so env-unset + pointer-present is a healthy, durable state.
# ---------------------------------------------------------------------------
$envWd = $env:SAPDEV_AI_WORK_DIR
$ptrPath = $null
$ptrVal  = ''
$appData = $env:APPDATA
if ([string]::IsNullOrWhiteSpace($appData)) { try { $appData = [Environment]::GetFolderPath('ApplicationData') } catch { $appData = '' } }
if (-not [string]::IsNullOrWhiteSpace($appData)) {
    $ptrPath = [System.IO.Path]::Combine($appData, 'sapdev-ai', 'work_dir.txt')
    if (Test-Path -LiteralPath $ptrPath) {
        try { $ptrVal = (([System.IO.File]::ReadAllText($ptrPath) -split "`r?`n")[0]).Trim().Trim('"').TrimEnd('\') } catch { $ptrVal = '' }
    }
}
if (-not [string]::IsNullOrWhiteSpace($envWd)) {
    Emit 'WORKDIR_ENV' 'cfg' 'PASS' ("SAPDEV_AI_WORK_DIR={0}" -f $envWd) '-'
} elseif (-not [string]::IsNullOrWhiteSpace($ptrVal)) {
    Emit 'WORKDIR_ENV' 'cfg' 'PASS' ("work_dir pinned by durable pointer {0} -> {1} (env var not in this process; pointer survives updates + bridges the session)" -f $ptrPath, $ptrVal) 'Optional: setx SAPDEV_AI_WORK_DIR "<work_dir>" so external shells inherit it too'
} else {
    Emit 'WORKDIR_ENV' 'cfg' 'WARN' 'work_dir is not pinned by SAPDEV_AI_WORK_DIR nor the %APPDATA%\sapdev-ai\work_dir.txt pointer - a custom work_dir set only in cache settings is lost on plugin update' 'Run /sap-login (writes the durable pointer), or setx SAPDEV_AI_WORK_DIR "<your work_dir>" then restart the terminal/host'
}

# ---------------------------------------------------------------------------
# cfg 4. work_dir resolves and is writable
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($workDir)) {
    Emit 'WORKDIR_WRITE' 'cfg' 'FAIL' 'work_dir resolved empty' 'Verify Get-SapWorkDir / settings.json work_dir'
} else {
    try {
        if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
        $probe = Join-Path $workDir ('.doctor_write_probe_' + $PID + '.tmp')
        Set-Content -Path $probe -Value 'ok' -Encoding ASCII -ErrorAction Stop
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
        Emit 'WORKDIR_WRITE' 'cfg' 'PASS' ("work_dir writable: {0}" -f $workDir) '-'
    } catch {
        Emit 'WORKDIR_WRITE' 'cfg' 'FAIL' ("work_dir not writable: {0} ({1})" -f $workDir, $_.Exception.Message) 'Grant write access or choose a different work_dir'
    }
}

# ---------------------------------------------------------------------------
# cfg 5. connections.json present and valid JSON
# ---------------------------------------------------------------------------
$connPath = if ([string]::IsNullOrWhiteSpace($workDir)) { '' } else { Join-Path $workDir 'runtime\connections.json' }
if (-not $connPath -or -not (Test-Path $connPath)) {
    Emit 'CONNECTIONS' 'cfg' 'FAIL' ("no connections.json (expected at {0})" -f $connPath) 'Run /sap-login --add to save a connection profile'
} else {
    try {
        $null = Get-Content $connPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Emit 'CONNECTIONS' 'cfg' 'PASS' ("connections.json present and valid: {0}" -f $connPath) '-'
    } catch {
        Emit 'CONNECTIONS' 'cfg' 'FAIL' ("connections.json is not valid JSON: {0}" -f $_.Exception.Message) 'Repair or re-create via /sap-login --add'
    }
}

# ---------------------------------------------------------------------------
# rfc 1. RFC connectivity to the pinned profile (also exercises the pin path)
# ---------------------------------------------------------------------------
$rfcOk = $false
$dest  = $null
$g_sapClient = ''
if (-not $ncoPresent) {
    Emit 'RFC_PING' 'rfc' 'SKIP' 'NCo 3.1 unavailable; cannot test RFC connectivity' 'Install NCo 3.1 (see NCO_GAC)'
} else {
    . "%%RFC_LIB_PS1%%"
    try {
        $dest = Connect-SapRfc -Server   "%%SAP_SERVER%%"   `
                               -Sysnr    "%%SAP_SYSNR%%"    `
                               -Client   "%%SAP_CLIENT%%"   `
                               -User     "%%SAP_USER%%"     `
                               -Password "%%SAP_PASSWORD%%" `
                               -Language "%%SAP_LANGUAGE%%" `
                               -DestName "SAP_DOCTOR"
    } catch { $dest = $null }
    if ($dest) {
        $rfcOk = $true
        if (-not [string]::IsNullOrWhiteSpace($g_sapClient)) { } # republished by the lib
        Emit 'RFC_PING' 'rfc' 'PASS' 'RFC connection to the pinned profile succeeded' '-'
    } else {
        Emit 'RFC_PING' 'rfc' 'FAIL' 'RFC connect failed (host/sysnr/client/user/password or a broken AI-session pin)' 'Check the pinned profile: /sap-login --list ; re-pin with /sap-login --switch <id>'
    }
}

# ---------------------------------------------------------------------------
# srv 1. Client repository modifiability (T000.CCNOCLIIND)
#        CCNOCLIIND: ' '=changes allowed; '1'=no cross-client cust changes;
#        '2'=no Repository changes; '3'=no Repository AND cross-client changes.
#        Repository (ABAP dev objects) is blocked when CCNOCLIIND in {2,3} -
#        every deploy/activate would fail, so surface it loudly.
# ---------------------------------------------------------------------------
if (-not $rfcOk) {
    Emit 'CLIENT_MODIFIABLE' 'srv' 'SKIP' 'RFC unavailable; cannot read T000 change option' '-'
} else {
    $client = if (-not [string]::IsNullOrWhiteSpace($g_sapClient)) { $g_sapClient } else { "%%SAP_CLIENT%%" }
    $rows = Q-RfcReadTable $dest "T000" "MANDT = '$client'" @("MANDT","CCCATEGORY","CCNOCLIIND","CCCORACTIV")
    if ($null -eq $rows) {
        Emit 'CLIENT_MODIFIABLE' 'srv' 'SKIP' 'RFC_READ_TABLE on T000 failed' '-'
    } elseif ($rows.Count -eq 0) {
        Emit 'CLIENT_MODIFIABLE' 'srv' 'SKIP' ("no T000 row for client {0}" -f $client) '-'
    } else {
        $parts = $rows[0] -split '\|' | ForEach-Object { $_.Trim() }
        $noChange = if ($parts.Count -ge 3) { $parts[2] } else { '' }
        if ($noChange -in @('2','3')) {
            Emit 'CLIENT_MODIFIABLE' 'srv' 'FAIL' ("client {0} blocks Repository changes (T000.CCNOCLIIND={1}) - deploy/activate will fail" -f $client, $noChange) 'Set the client to allow Repository changes (SCC4 / SE06 system change option)'
        } else {
            $cc = if ($noChange -eq '') { 'blank' } else { $noChange }
            Emit 'CLIENT_MODIFIABLE' 'srv' 'PASS' ("client {0} allows Repository changes (T000.CCNOCLIIND={1})" -f $client, $cc) '-'
        }
    }
}

# ---------------------------------------------------------------------------
# Summary + cleanup
# ---------------------------------------------------------------------------
if ($rfcOk) { try { Disconnect-SapRfc } catch {} }

$verdict = if ($script:nFail -gt 0) { 'BLOCKED' } elseif ($script:nWarn -gt 0) { 'DEGRADED' } else { 'READY' }
Write-Host ("DOCTOR_PS: {0} FAIL={1} WARN={2} SKIP={3}" -f $verdict, $script:nFail, $script:nWarn, $script:nSkip)
if ($script:nFail -gt 0) { exit 1 } else { exit 0 }
