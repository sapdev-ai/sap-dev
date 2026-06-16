# =============================================================================
# sap_gui_security_sidecar.ps1  -  OS-level auto-dismiss for SAP GUI Security
#
# Why this script exists
# ----------------------
# When the SAP GUI Security dialog is modal, the SAP GUI Scripting COM API is
# fully suspended -- even `oSess.findById("wnd[0]")` returns nothing. So a VBS/
# cscript skill that triggered the file IO blocks, and cannot dismiss the
# dialog itself. Detection + dismissal must happen at the OS level, in a
# separate process that is not blocked by the modal.
#
# Detection (validated 2026-05-22 on SAP GUI 7.70 / S/4HANA 1909)
# ---------------------------------------------------------------
# The dialog is a STANDARD Win32 dialog: window class `#32770`, caption
# "SAP GUI Security", **owned** by the SAP GUI process (saplogon.exe). Two
# consequences that broke earlier attempts:
#   * It is an OWNED top-level window, so `FindWindow(null,"SAP GUI Security")`
#     (which matches non-owned top-level windows) returns 0.
#   * SAP GUI does NOT expose it through the standard UI Automation tree -- a
#     UIA descendant scan from the root finds zero checkboxes / no dialog.
# `EnumWindows` (which DOES enumerate owned top-level windows) finds it, and
# its child controls are real Win32 `Button`s -- `&Remember my decision`,
# `&Allow`, `&Deny`, `&Help` -- enumerable via `EnumChildWindows` and
# clickable via `SendMessage(BM_CLICK)` with no focus/foreground dependency.
#
# So this sidecar polls `EnumWindows` for a visible `#32770` window that is
# the security dialog (caption matches /SAP GUI Security/i, OR -- locale-proof --
# it has both an "Allow" and a "Deny" child button), then ticks the Remember
# checkbox (BM_SETCHECK) and clicks Allow (BM_CLICK). Ticking Remember makes
# SAP GUI persist an Allow rule into %APPDATA%\SAP\Common\saprules.xml LIVE
# (no GUI restart) -- so the next sap_gui_security_precheck.ps1 for that path
# returns ALLOWED and no dialog appears.
#
# Usage (run as a background process BEFORE the file-IO action; see
# shared/rules/sap_gui_security_handling.md):
#   $w = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
#       '-NoProfile','-ExecutionPolicy','Bypass','-File','<this script>',
#       '-TimeoutSeconds','40','-LogPath',"$env:TEMP\sap_secdlg.log")
#   # ... trigger the dialog (Upload/Download/Export/Hardcopy) ...
#   $w | Wait-Process -Timeout 45
#
# Stdout contract (last line):
#   DISMISSED:WIN32   -> Found and CLOSED >=1 dialog (Remember ticked + Allow
#                        clicked AND verified the window actually went away). A
#                        preceding "INFO: closed N security dialog(s)" line gives
#                        the count. The watcher keeps polling through re-prompts /
#                        unresponsive-click retries until a quiet grace window, so
#                        it cannot report success while a modal is still up.
#   FOUND_BUT_STUCK   -> Saw the dialog but the click never closed it (retried to
#                        timeout) -- caller must surface this, NOT assume OK.
#   TIMEOUT           -> Timeout expired with no dialog seen
#   NO_SAP_GUI        -> No SAP GUI process running at all
#   ERROR: <message>  -> Win32 interop load failure
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

try {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class SapSecWin {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
}
"@ -ErrorAction Stop
} catch {
    Write-Output "ERROR: Failed to load Win32 interop: $($_.Exception.Message)"
    exit 1
}

$BM_SETCHECK = 0x00F1
$BM_CLICK    = 0x00F5

function Get-WinText([IntPtr]$h)  { $sb = New-Object System.Text.StringBuilder 512; [void][SapSecWin]::GetWindowText($h, $sb, 512); return $sb.ToString() }
function Get-WinClass([IntPtr]$h) { $sb = New-Object System.Text.StringBuilder 256; [void][SapSecWin]::GetClassName($h, $sb, 256); return $sb.ToString() }

# Collect this dialog's child Buttons as {h, txt}.
function Get-DialogButtons([IntPtr]$dlg) {
    $script:_sapSecKids = New-Object System.Collections.ArrayList
    $cb = [SapSecWin+EnumProc]{
        param($hh, $ll)
        if ((Get-WinClass $hh) -eq 'Button') {
            [void]$script:_sapSecKids.Add([pscustomobject]@{ h = $hh; txt = (Get-WinText $hh) })
        }
        return $true
    }
    [void][SapSecWin]::EnumChildWindows($dlg, $cb, [IntPtr]::Zero)
    return $script:_sapSecKids
}

# Is this #32770 window the SAP GUI Security dialog? Caption match (fast) OR
# the locale-proof structural test: it has both an Allow and a Deny button.
function Test-IsSecurityDialog([IntPtr]$h, [string]$title) {
    if ($title -match '(?i)SAP\s*GUI\s*Security') { return $true }
    $btns = Get-DialogButtons $h
    $hasAllow = $false; $hasDeny = $false
    foreach ($b in $btns) {
        if ($b.txt -match '(?i)allow') { $hasAllow = $true }
        if ($b.txt -match '(?i)deny')  { $hasDeny  = $true }
    }
    return ($hasAllow -and $hasDeny)
}

function Invoke-Dismiss([IntPtr]$dlg) {
    $btns = Get-DialogButtons $dlg
    $remember = $btns | Where-Object { $_.txt -match '(?i)remember' } | Select-Object -First 1
    if ($remember) {
        [void][SapSecWin]::SendMessage($remember.h, $BM_SETCHECK, [IntPtr]1, [IntPtr]::Zero)
        Write-Log "ticked '$($remember.txt)'"
        Start-Sleep -Milliseconds 150
    }
    $allow = $btns | Where-Object { $_.txt -match '(?i)allow' } | Select-Object -First 1
    if ($allow) {
        [void][SapSecWin]::SendMessage($allow.h, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
        Write-Log "clicked '$($allow.txt)'"
        return $true
    }
    Write-Log "no Allow button found among $($btns.Count) child buttons"
    return $false
}

# Find candidate security dialogs among visible #32770 top-level windows.
function Find-SecurityDialogs {
    $script:_sapSecHits = New-Object System.Collections.ArrayList
    $cb = [SapSecWin+EnumProc]{
        param($hh, $ll)
        if ([SapSecWin]::IsWindowVisible($hh)) {
            if ((Get-WinClass $hh) -eq '#32770') {
                if (Test-IsSecurityDialog $hh (Get-WinText $hh)) { [void]$script:_sapSecHits.Add($hh) }
            }
        }
        return $true
    }
    [void][SapSecWin]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:_sapSecHits
}

# Is this hwnd STILL a visible security dialog (i.e. our click did NOT close it)?
# A successfully-dismissed dialog is destroyed, so IsWindowVisible() goes false.
function Test-StillOpen([IntPtr]$h) {
    if (-not [SapSecWin]::IsWindowVisible($h)) { return $false }
    if ((Get-WinClass $h) -ne '#32770') { return $false }
    return (Test-IsSecurityDialog $h (Get-WinText $h))
}

# ----- Main poll loop --------------------------------------------------------
# CRITICAL: do NOT exit on the first BM_CLICK. Invoke-Dismiss returns true the
# moment it SENDS the click, but the click is a no-op if it lands before the
# dialog's buttons are responsive, and SAP can raise a SECOND prompt for the same
# file IO. The pre-2026-06-17 loop exited immediately on the send, so a no-op
# click left the triggering VBS hung on a still-open modal (observed live: a
# 12-minute block whose sidecar had already reported DISMISSED). So after each
# click VERIFY the window actually closed (retry next poll if not), and keep
# watching through re-prompts until a quiet grace window passes with no dialog.
$sawSap = $false
try { $sawSap = [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)sap' }) } catch {}

$GraceMs      = 2500          # quiet period after the last close before declaring done
$dismissCount = 0
$foundAny     = $false
$idleDeadline = $null
$deadline     = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $dialogs = @(Find-SecurityDialogs)
    if ($dialogs.Count -gt 0) {
        $foundAny = $true
        foreach ($d in $dialogs) {
            $pid2 = 0; [void][SapSecWin]::GetWindowThreadProcessId($d, [ref]$pid2)
            Write-Log "detected #32770 security dialog hwnd=$d pid=$pid2"
            [void](Invoke-Dismiss $d)
            Start-Sleep -Milliseconds 300
            if (Test-StillOpen $d) {
                Write-Log "hwnd=$d still open after click; will retry next poll"
            } else {
                $dismissCount++
                Write-Log "hwnd=$d closed (count=$dismissCount)"
            }
        }
        # A dialog was present this iteration -> reset the quiet timer so we keep
        # watching for a re-prompt (or to retry a click that did not take effect).
        $idleDeadline = (Get-Date).AddMilliseconds($GraceMs)
    } elseif ($dismissCount -gt 0 -and $null -ne $idleDeadline -and (Get-Date) -gt $idleDeadline) {
        break   # closed >=1 dialog and stayed quiet for the grace window -> done
    }
    Start-Sleep -Milliseconds $PollIntervalMs
}

if ($dismissCount -gt 0) {
    Write-Log "done: closed $dismissCount dialog(s)"
    Write-Output "INFO: closed $dismissCount security dialog(s)"
    Write-Output "DISMISSED:WIN32"          # last line kept stable for callers
    exit 0
}
if ($foundAny) { Write-Output "FOUND_BUT_STUCK"; exit 4 }   # saw it, click never closed it
if (-not $sawSap) { Write-Output "NO_SAP_GUI"; exit 2 }
Write-Output "TIMEOUT"
exit 3
