# =============================================================================
# run_mode_test.ps1
# -----------------------------------------------------------------------------
# Test-runner for the autonomous test/fix loop (sap-gui-skill-scaffold Step 5.5).
#
# Drives ONE generated mode of a DRAFT skill folder against the live SAP system,
# exactly the way the generated SKILL.md's Step 2 wrapper would: pick the
# version-aware VBS variant, substitute the %%TOKEN%% parameters + the
# session-attach tokens, run via 32-bit cscript, then capture the resulting
# end-state (status-bar MessageType, popup-left-open, screen identity) into a
# machine-readable result.json so the loop can classify pass/fail.
#
# This does NOT validate the outcome — it only runs and observes. Pass/fail
# classification is the loop's job (verify_create_object.ps1 + Step 5.5b prose).
#
# MUST run under 32-bit PowerShell? No — this script only shells out to 32-bit
# cscript (SAP GUI Scripting COM) and to sap_gui_probe_dump.ps1 (which itself
# uses 32-bit cscript). It can run under either host.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File run_mode_test.ps1 `
#       -SkillFolder <abs-path-to-draft-skill-folder> `   # contains references/
#       -SkillName   sap-se11-domain `                    # to derive the fn base
#       -Mode        create-domain `                      # mode label
#       [-ParamsJson '{"DOMNAME_VAL":"ZDOMSCAF001","L_DEVCLASS":"$TMP"}'] `
#       [-SessionPath /app/con[0]/ses[1]] `               # empty => AI-session pin
#       [-OutputDir <abs-path>] `                         # default {SkillFolder}\_test\<Mode>
#       [-WorkTemp <abs-path>]
#
# Output: writes <OutputDir>\result.json and <OutputDir>\end_state.txt.
# Last stdout line: "RESULT: exit=<rc> popup=<bool> msgType=<X> -> <result.json>".
# ALWAYS exits 0 — a failed mode is data, not a script error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SkillFolder,
    [Parameter(Mandatory = $true)] [string] $SkillName,
    [Parameter(Mandatory = $true)] [string] $Mode,
    [string] $ParamsJson  = '{}',
    [string] $SessionPath = '',
    [string] $OutputDir   = '',
    [string] $WorkTemp    = ''
)

if (-not $WorkTemp) {
    if ($env:WORK_TEMP) { $WorkTemp = $env:WORK_TEMP } else { $WorkTemp = 'C:\sap_dev_work\temp' }
}

# Filename base mirrors emit_skill_folder.ps1: strip leading "sap-", "-" -> "_".
$fnBase = ($SkillName.ToLowerInvariant() -replace '^sap-','') -replace '-','_'

if (-not $OutputDir) { $OutputDir = Join-Path $SkillFolder ("_test\" + $Mode) }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$resultFile    = Join-Path $OutputDir 'result.json'
$endStateFile  = Join-Path $OutputDir 'end_state.txt'

# Shared scripts dir: <plugin-root>\shared\scripts (3 up from this references dir).
$sharedDir = Join-Path $PSScriptRoot '..\..\..\shared\scripts'
$sharedDir = (Resolve-Path -Path $sharedDir -ErrorAction SilentlyContinue).Path
# sap-gui-probe lives as a sibling skill: ..\..\sap-gui-probe\references
$probeDump = Join-Path $PSScriptRoot '..\..\sap-gui-probe\references\sap_gui_probe_dump.ps1'

function Write-Result {
    param([hashtable]$Fields)
    $ordered = [ordered]@{}
    foreach ($k in $Fields.Keys) { $ordered[$k] = $Fields[$k] }
    ($ordered | ConvertTo-Json -Depth 5) | Set-Content -Path $resultFile -Encoding UTF8
}

# --- 1. Resolve the VBS variant for the current pin --------------------------
$variantPath = ''
$selector = if ($sharedDir) { Join-Path $sharedDir 'sap_select_vbs_variant.ps1' } else { '' }
if ($selector -and (Test-Path $selector)) {
    $selOut = & $selector -ReferencesDir (Join-Path $SkillFolder 'references') -BaseName ("sap_{0}_{1}" -f $fnBase, $Mode) -WorkTemp $WorkTemp 2>&1
    if ($LASTEXITCODE -eq 0) {
        $variantPath = @("$selOut" -split "`r?`n" | Where-Object { $_ -match '\.vbs\s*$' } | Select-Object -Last 1) | Select-Object -First 1
        if ($variantPath) { $variantPath = $variantPath.Trim() }
    }
}
if (-not $variantPath) {
    $direct = Join-Path $SkillFolder ("references\sap_{0}_{1}.vbs" -f $fnBase, $Mode)
    if (Test-Path $direct) { $variantPath = $direct }
}
if (-not $variantPath -or -not (Test-Path $variantPath)) {
    Write-Result @{
        skill_name = $SkillName; mode = $Mode; ran_at = (Get-Date -Format 'o')
        exit_code = -1; stdout_tail = "ERROR: no VBS variant found for mode '$Mode'"
        message_type = ''; popup_left_open = $false; vbs_path = ''
    }
    Write-Output "RESULT: exit=-1 popup=False msgType= -> $resultFile (no VBS variant)"
    exit 0
}

# --- 2. Substitute parameters + session-attach tokens ------------------------
$content = Get-Content $variantPath -Raw

$paramsObj = $null
try { $paramsObj = $ParamsJson | ConvertFrom-Json } catch { $paramsObj = $null }
if ($paramsObj) {
    foreach ($prop in $paramsObj.PSObject.Properties) {
        $content = $content.Replace("%%$($prop.Name)%%", "$($prop.Value)")
    }
}

# Resolve the effective session: explicit arg wins, else the AI-session pin.
$effSession = $SessionPath
if (-not $effSession -and $sharedDir) {
    $connLib = Join-Path $sharedDir 'sap_connection_lib.ps1'
    if (Test-Path $connLib) {
        . $connLib
        try { $effSession = Get-SapCurrentSessionPath -WorkTemp $WorkTemp } catch {}
    }
}
$attachLib = if ($sharedDir) { Join-Path $sharedDir 'sap_attach_lib.vbs' } else { '' }

# Mirror the generated wrapper: substitute SESSION_PATH + ATTACH_LIB_VBS, then
# also export SAPDEV_SESSION_PATH so AttachSapSession resolves the pin even
# when SESSION_PATH is left blank.
$content = $content.Replace('%%SESSION_PATH%%',   "$effSession")
$content = $content.Replace('%%ATTACH_LIB_VBS%%', "$attachLib")
$env:SAPDEV_SESSION_PATH = "$effSession"

$runtimeVbs = Join-Path $OutputDir 'run.vbs'
Set-Content -Path $runtimeVbs -Value $content -Encoding Unicode

# --- 3. Run via 32-bit cscript -----------------------------------------------
$cscript = 'C:\Windows\SysWOW64\cscript.exe'
$stdout = & $cscript //NoLogo $runtimeVbs 2>&1
$rc = $LASTEXITCODE
$lines = @($stdout | ForEach-Object { "$_" })
$joined = ($lines -join "`n")
$lastLine = if ($lines.Count -gt 0) { $lines[-1].Trim() } else { '' }

# --- 4. Capture end-state --------------------------------------------------
$dumpDestSession = if ($effSession) { $effSession } else { '/app/con[0]/ses[0]' }
if (Test-Path $probeDump) {
    try {
        & $probeDump -OutputFile $endStateFile -Mode tree -SessionPath $dumpDestSession | Out-Null
    } catch {}
}

$popupOpen = $false; $scrPgm = ''; $scrTcd = ''; $scrId = ''
if (Test-Path $endStateFile) {
    $dump = Get-Content $endStateFile -Raw
    if ($dump -match '(?m)^POPUP WINDOW wnd\[') { $popupOpen = $true }
    $mp = [regex]::Match($dump, '(?m)^Program:\s*(.*)$');     if ($mp.Success) { $scrPgm = $mp.Groups[1].Value.Trim() }
    $mt = [regex]::Match($dump, '(?m)^Transaction:\s*(.*)$'); if ($mt.Success) { $scrTcd = $mt.Groups[1].Value.Trim() }
    $ms = [regex]::Match($dump, '(?m)^Screen:\s*(.*)$');      if ($ms.Success) { $scrId  = $ms.Groups[1].Value.Trim() }
}

# --- 5. Derive MessageType ---------------------------------------------------
# The generated mode VBS echoes "ERROR: status-bar reported MessageType=<X>" on
# Quit 3, and "DONE" on Quit 0. Prefer the explicit echo; else infer from rc.
$msgType = ''
$mm = [regex]::Match($joined, 'MessageType=(\w)')
if ($mm.Success)       { $msgType = $mm.Groups[1].Value }
elseif ($lastLine -eq 'DONE') { $msgType = 'S' }

# --- 6. Write result.json ----------------------------------------------------
Write-Result @{
    skill_name             = $SkillName
    mode                   = $Mode
    ran_at                 = (Get-Date -Format 'o')
    vbs_path               = $variantPath
    runtime_vbs            = $runtimeVbs
    session_path           = $effSession
    params                 = $ParamsJson
    exit_code              = $rc
    stdout_tail            = $lastLine
    stdout                 = $joined
    message_type           = $msgType
    popup_left_open        = $popupOpen
    end_screen_program     = $scrPgm
    end_screen_transaction = $scrTcd
    end_screen_id          = $scrId
    end_state_file         = $endStateFile
}

Write-Output "RESULT: exit=$rc popup=$popupOpen msgType=$msgType -> $resultFile"
exit 0
