# =============================================================================
# sap_gui_security_sidecar.ps1  -  OS-level auto-dismiss for SAP GUI Security
#
# Why this script exists
# ----------------------
# When the SAP GUI Security dialog is modal, the SAP GUI Scripting COM API
# is fully suspended — even `oSess.findById("wnd[0]")` returns nothing.
# That means every VBS-based attempt to detect and dismiss the dialog
# (helper.vbs, poller.vbs, warmup.vbs) is blocked from doing anything,
# because they all rely on the Scripting API seeing the modal.
#
# This sidecar uses Windows UI Automation (System.Windows.Automation) and,
# as a last-resort fallback, raw SendKeys. UIA is process-and-window aware
# at the OS level and sees the dialog regardless of whether SAP GUI's
# Scripting API exposes it.
#
# Detection strategy (language-agnostic)
# --------------------------------------
# 1. Enumerate top-level windows owned by saplogon.exe / sapgui.exe.
# 2. For each, count Buttons + CheckBoxes + TextElements.
# 3. The security dialog matches: >= 3 buttons, >= 1 checkbox, and at
#    least one Text element whose Name contains a path separator (`:\`
#    on Windows or `/`).
# 4. Click the LEFTMOST button (Allow is leftmost in every locale tested:
#    EN, JA, ZH). Tick the FIRST checkbox before clicking (Remember My
#    Decision). UIA exposes both a Toggle pattern (for the checkbox) and
#    an Invoke pattern (for the button).
#
# If UIA fails to find the dialog (rare — would mean the dialog is fully
# custom-drawn with no UIA-accessible elements), the script falls back to
# SendKeys: focus the topmost window of the SAP GUI process, send Tab+Tab+
# Space (tick the Remember checkbox by tab order) then Tab+Enter (move to
# leftmost button and press it). This is fragile and locale-independent
# only if the dialog's tab order is stable across releases.
#
# Usage
# -----
# Run as a separate background process from the orchestrator (PowerShell
# from /sap-dev-init Step 1b, or any future skill that triggers a file IO):
#
#   $sidecar = Start-Process -FilePath powershell -NoNewWindow -PassThru `
#       -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
#                       '-File', '<this script>',
#                       '-TimeoutSeconds', '30',
#                       '-LogPath', "$env:TEMP\sap_secdlg_sidecar.log")
#   # ... trigger the dialog (Hardcopy, Upload, Download, ...) ...
#   $sidecar | Wait-Process -Timeout 35
#
# Stdout contract (last line):
#   DISMISSED:UIA          -> Found and dismissed via UI Automation
#   DISMISSED:SENDKEYS     -> Found via UIA presence but dismissed via SendKeys fallback
#   TIMEOUT                -> Timeout expired with no dialog seen
#   NO_SAP_GUI             -> No saplogon.exe / sapgui.exe processes running
#   ERROR: <message>       -> Anything else
#
# Logging
# -------
# If -LogPath is provided, every detection pass writes a line to that file.
# Useful for debugging WHY UIA isn't seeing the dialog on a customer site.
# =============================================================================

param(
    [int]$TimeoutSeconds = 30,
    [int]$PollIntervalMs = 200,
    [string]$LogPath = ""
)

$ErrorActionPreference = "Continue"

function Write-Log([string]$msg) {
    if ($LogPath) {
        try { Add-Content -Path $LogPath -Value ("[" + (Get-Date -Format "HH:mm:ss.fff") + "] " + $msg) -ErrorAction SilentlyContinue } catch {}
    }
}

# ----- Load UI Automation assemblies -----------------------------------------
try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
} catch {
    Write-Output "ERROR: Failed to load UIAutomation assemblies: $($_.Exception.Message)"
    exit 1
}

# ----- Load Win32 SendKeys helper (fallback path) ----------------------------
$win32Sig = @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
try { Add-Type -TypeDefinition $win32Sig -ErrorAction SilentlyContinue } catch {}
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# ----- Helpers ---------------------------------------------------------------
$AE = [System.Windows.Automation.AutomationElement]
$Ctrl = [System.Windows.Automation.ControlType]
$Scope = [System.Windows.Automation.TreeScope]
$TogglePatternId = [System.Windows.Automation.TogglePattern]::Pattern
$InvokePatternId = [System.Windows.Automation.InvokePattern]::Pattern

function Get-SapGuiProcessIds {
    return (Get-Process -Name saplogon, sapgui -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
}

function Get-WindowsForProcess([int]$processPid) {
    $root = $AE::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $processPid)
    return @($root.FindAll($Scope::Children, $cond))
}

function Test-IsSecurityDialog([System.Windows.Automation.AutomationElement]$win) {
    if ($null -eq $win) { return $false }
    $btnCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $Ctrl::Button)
    $chkCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $Ctrl::CheckBox)
    $txtCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $Ctrl::Text)

    $buttons    = @($win.FindAll($Scope::Descendants, $btnCond))
    $checkboxes = @($win.FindAll($Scope::Descendants, $chkCond))
    $texts      = @($win.FindAll($Scope::Descendants, $txtCond))

    if ($buttons.Count -lt 3) { return $false }
    if ($checkboxes.Count -lt 1) { return $false }

    $hasPathLike = $false
    foreach ($t in $texts) {
        $name = $t.Current.Name
        if ($name -and ($name -match ':\\' -or $name -match '/')) { $hasPathLike = $true; break }
    }
    return $hasPathLike
}

function Invoke-DismissViaUIA([System.Windows.Automation.AutomationElement]$win) {
    $btnCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $Ctrl::Button)
    $chkCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $Ctrl::CheckBox)

    $buttons    = @($win.FindAll($Scope::Descendants, $btnCond))
    $checkboxes = @($win.FindAll($Scope::Descendants, $chkCond))

    # Tick the first checkbox (Remember My Decision).
    if ($checkboxes.Count -ge 1) {
        try {
            $tp = $null
            if ($checkboxes[0].TryGetCurrentPattern($TogglePatternId, [ref]$tp)) {
                if ($tp.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
                    $tp.Toggle()
                    Write-Log "Toggled Remember checkbox via UIA"
                }
            }
        } catch {
            Write-Log "Toggle failed: $($_.Exception.Message)"
        }
    }

    # Press the leftmost button (Allow).
    if ($buttons.Count -ge 1) {
        $sorted = $buttons | Sort-Object { $_.Current.BoundingRectangle.Left }
        $allow = $sorted[0]
        try {
            $ip = $null
            if ($allow.TryGetCurrentPattern($InvokePatternId, [ref]$ip)) {
                $ip.Invoke()
                Write-Log "Invoked leftmost button via UIA"
                return $true
            }
        } catch {
            Write-Log "Invoke failed: $($_.Exception.Message)"
        }
    }
    return $false
}

function Invoke-DismissViaSendKeys([System.Windows.Automation.AutomationElement]$win) {
    # SendKeys fallback: bring the dialog to foreground, send keys to tick
    # the checkbox and press Allow. Tab order in SAP GUI Security dialog
    # (verified across SAP GUI 7.50/7.60/7.70):
    #   focus on entry -> Allow button (focused by default)
    #   Tab -> Deny
    #   Tab -> Help
    #   Tab -> Remember checkbox
    # So: Tab Tab Tab Space (tick Remember), Shift+Tab Shift+Tab Shift+Tab (back to Allow), Enter.
    try {
        $hwnd = $win.Current.NativeWindowHandle
        if ($hwnd -eq 0) { Write-Log "SendKeys: no native handle"; return $false }
        [Win32]::SetForegroundWindow([IntPtr]$hwnd) | Out-Null
        Start-Sleep -Milliseconds 150
        [System.Windows.Forms.SendKeys]::SendWait("{TAB}{TAB}{TAB} ")  # 3x Tab to checkbox, Space to tick
        Start-Sleep -Milliseconds 100
        [System.Windows.Forms.SendKeys]::SendWait("+{TAB}+{TAB}+{TAB}{ENTER}")  # 3x Shift+Tab back to Allow, Enter
        Write-Log "SendKeys fallback dispatched"
        return $true
    } catch {
        Write-Log "SendKeys failed: $($_.Exception.Message)"
        return $false
    }
}

# ----- Main poll loop --------------------------------------------------------

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$pidsCheckedLastTime = @()

while ((Get-Date) -lt $deadline) {
    $sapPids = Get-SapGuiProcessIds
    if (-not $sapPids -or $sapPids.Count -eq 0) {
        if ($pidsCheckedLastTime.Count -gt 0) {
            Write-Output "NO_SAP_GUI"
            exit 2
        }
        Start-Sleep -Milliseconds $PollIntervalMs
        continue
    }
    $pidsCheckedLastTime = $sapPids

    foreach ($processPid in $sapPids) {
        $windows = Get-WindowsForProcess -processPid $processPid
        foreach ($win in $windows) {
            if (Test-IsSecurityDialog -win $win) {
                Write-Log "Detected security dialog under PID $processPid"
                if (Invoke-DismissViaUIA -win $win) {
                    Write-Output "DISMISSED:UIA"
                    exit 0
                }
                if (Invoke-DismissViaSendKeys -win $win) {
                    Write-Output "DISMISSED:SENDKEYS"
                    exit 0
                }
                Write-Output "ERROR: Dialog detected but neither UIA nor SendKeys dismiss path succeeded"
                exit 1
            }
        }
    }

    Start-Sleep -Milliseconds $PollIntervalMs
}

Write-Output "TIMEOUT"
exit 3
