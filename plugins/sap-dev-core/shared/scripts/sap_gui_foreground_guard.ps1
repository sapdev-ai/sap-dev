# =============================================================================
# sap_gui_foreground_guard.ps1  -  Force SAP GUI window to OS-level foreground
#
# Why this script exists
# ----------------------
# Skills that paste ABAP source via clipboard + SendKeys (sap-se38, sap-se37,
# sap-se24, sap-se91) need the SAP GUI window to be the OS foreground window
# at the instant SendKeys "^v" fires -- otherwise the Ctrl+V lands in
# whatever other app has focus (Notepad, VS Code, browser, Outlook, ...).
#
# The skills already attempt:
#   1. `oSession.findById("wnd[0]").Maximize`          (Scripting API)
#   2. `WshShell.AppActivate(<title>)` in a 20x retry loop
#   3. `session.LockSessionUI` (sap_session_lock.vbs)
#
# None of these reliably brings SAP forward when another app holds focus:
#   - Maximize only resizes; it does not change Z-order.
#   - AppActivate wraps `SetForegroundWindow`. On Windows 7+, SFW is
#     suppressed when called from a process that doesn't already own the
#     foreground; instead Windows flashes the taskbar button and returns
#     "success" without actually moving the window. AppActivate returns
#     True; the window stays behind. Retries don't help because every
#     call hits the same suppression.
#   - LockSessionUI locks input INSIDE SAP. It does NOTHING for the
#     OS-level focus owner.
#
# The standard Win32 workaround is `AttachThreadInput`: temporarily attach
# our thread's input queue to the foreground thread's input queue. Once
# attached, our process effectively "owns" the foreground from Windows'
# perspective, so SetForegroundWindow is no longer suppressed. After we've
# brought SAP forward we detach. This is the documented and supported
# technique used by countless production tools (e.g. Sysinternals).
#
# Detection
# ---------
# The sidecar locates SAP's main HWND by enumerating top-level windows
# owned by processes named `saplogon.exe` or `sapgui.exe` and matching a
# title-substring (case-insensitive). The skill passes the title returned
# by `oSession.findById("wnd[0]").Text` (e.g. "SAP Easy Access" or the
# transaction's own title). If multiple windows match, the most-recently-
# updated SAP window wins (highest Z-order among saplogon/sapgui windows).
#
# Usage from a skill VBS
# ----------------------
#   Dim oWsh : Set oWsh = CreateObject("WScript.Shell")
#   Dim sapTitle : sapTitle = oSession.findById("wnd[0]").Text
#   Dim cmd : cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File """ & _
#                   "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_foreground_guard.ps1""" & _
#                   " -TargetTitle """ & sapTitle & """ -TimeoutSeconds 5"
#   Dim rc : rc = oWsh.Run(cmd, 0, True)
#   If rc <> 0 Then
#       WScript.Echo "ERROR: Could not bring SAP GUI to foreground..."
#       WScript.Quit 1
#   End If
#
# Stdout contract (last line)
# ---------------------------
#   FOREGROUND:OK:<hwnd>           -> SAP is now foreground; safe to SendKeys
#   FOREGROUND:STILL_NOT_FG:<hwnd> -> Could not bring SAP forward; do NOT SendKeys
#   FOREGROUND:NO_MATCH            -> No SAP window found with matching title
#   FOREGROUND:NO_SAP_GUI          -> No saplogon.exe / sapgui.exe processes running
#   FOREGROUND:ERROR:<message>     -> Anything else
#
# Exit code matches: 0 on OK, non-zero on anything else.
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetTitle,

    [int]$TimeoutSeconds = 5,
    [int]$PollIntervalMs = 100,
    [string]$LogPath = ''
)

function Write-Diag {
    param([string]$Line)
    if ($LogPath) {
        try { Add-Content -Path $LogPath -Value "$(Get-Date -Format 'HH:mm:ss.fff') $Line" -ErrorAction SilentlyContinue } catch {}
    }
}

# --- P/Invoke surface ------------------------------------------------------
$signature = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class FgWin32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
}
"@
try { Add-Type -TypeDefinition $signature -ErrorAction Stop } catch {
    Write-Output "FOREGROUND:ERROR:Add-Type failed: $($_.Exception.Message)"
    exit 1
}

# --- Find candidate SAP HWNDs ---------------------------------------------
$sapPids = @()
try {
    $sapProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -ieq 'saplogon' -or $_.ProcessName -ieq 'sapgui'
    }
    $sapPids = $sapProcs | ForEach-Object { [uint32]$_.Id }
} catch {}

if (-not $sapPids -or $sapPids.Count -eq 0) {
    Write-Diag "No saplogon/sapgui processes found"
    Write-Output "FOREGROUND:NO_SAP_GUI"
    exit 1
}

Write-Diag "Looking for title substring: '$TargetTitle'  in pids: $($sapPids -join ',')"

$candidates = New-Object 'System.Collections.Generic.List[IntPtr]'

# Closure-captured by EnumWindows
$enumCallback = {
    param([IntPtr]$hWnd, [IntPtr]$lParam)
    if (-not [FgWin32]::IsWindowVisible($hWnd)) { return $true }
    $winPid = [uint32]0
    [void][FgWin32]::GetWindowThreadProcessId($hWnd, [ref]$winPid)
    if ($sapPids -notcontains $winPid) { return $true }
    $len = [FgWin32]::GetWindowTextLength($hWnd)
    if ($len -le 0) { return $true }
    $sb = New-Object System.Text.StringBuilder ($len + 2)
    [void][FgWin32]::GetWindowText($hWnd, $sb, $sb.Capacity)
    $title = $sb.ToString()
    if ($title -and $title.IndexOf($TargetTitle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $candidates.Add($hWnd) | Out-Null
        Write-Diag "  candidate hwnd=$hWnd pid=$winPid title='$title'"
    }
    return $true
}

[void][FgWin32]::EnumWindows($enumCallback, [IntPtr]::Zero)

if ($candidates.Count -eq 0) {
    # Fallback: any visible window owned by sapgui/saplogon (in case the
    # transaction-specific title is hard to match exactly).
    Write-Diag "No title match; falling back to any visible SAP GUI window"
    $fallbackCallback = {
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        if (-not [FgWin32]::IsWindowVisible($hWnd)) { return $true }
        $winPid = [uint32]0
        [void][FgWin32]::GetWindowThreadProcessId($hWnd, [ref]$winPid)
        if ($sapPids -notcontains $winPid) { return $true }
        $len = [FgWin32]::GetWindowTextLength($hWnd)
        if ($len -le 0) { return $true }
        $candidates.Add($hWnd) | Out-Null
        return $true
    }
    [void][FgWin32]::EnumWindows($fallbackCallback, [IntPtr]::Zero)
}

if ($candidates.Count -eq 0) {
    Write-Diag "No matching window after fallback"
    Write-Output "FOREGROUND:NO_MATCH"
    exit 1
}

# Prefer the first candidate (Z-order top among SAP windows is what EnumWindows yields).
$sapHwnd = $candidates[0]
Write-Diag "Chosen hwnd=$sapHwnd (of $($candidates.Count) candidates)"

# --- Force-foreground loop -------------------------------------------------
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$myThread = [FgWin32]::GetCurrentThreadId()

while ((Get-Date) -lt $deadline) {
    $fg = [FgWin32]::GetForegroundWindow()
    if ($fg -eq $sapHwnd) {
        Write-Diag "Already foreground"
        Write-Output "FOREGROUND:OK:$sapHwnd"
        exit 0
    }

    # Restore from minimized first (Iconic windows can't take foreground).
    if ([FgWin32]::IsIconic($sapHwnd)) {
        [void][FgWin32]::ShowWindow($sapHwnd, 9)   # SW_RESTORE
        Start-Sleep -Milliseconds 50
    }

    # The AttachThreadInput dance -- temporarily share input queue with the
    # current foreground thread so SetForegroundWindow is no longer
    # suppressed by Windows' anti-focus-stealing logic.
    $fgPid = [uint32]0
    $fgThread = [FgWin32]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $myThread) {
        $attached = [FgWin32]::AttachThreadInput($myThread, $fgThread, $true)
    }
    try {
        [void][FgWin32]::BringWindowToTop($sapHwnd)
        [void][FgWin32]::SetForegroundWindow($sapHwnd)
        [void][FgWin32]::ShowWindow($sapHwnd, 5)   # SW_SHOW
    } finally {
        if ($attached) { [void][FgWin32]::AttachThreadInput($myThread, $fgThread, $false) }
    }

    Start-Sleep -Milliseconds $PollIntervalMs

    $fg2 = [FgWin32]::GetForegroundWindow()
    if ($fg2 -eq $sapHwnd) {
        Write-Diag "Brought to foreground via AttachThreadInput"
        Write-Output "FOREGROUND:OK:$sapHwnd"
        exit 0
    }
    Write-Diag "After attempt: foreground=$fg2 expected=$sapHwnd; retrying"
}

$finalFg = [FgWin32]::GetForegroundWindow()
Write-Diag "Timed out; finalFg=$finalFg expected=$sapHwnd"
Write-Output "FOREGROUND:STILL_NOT_FG:$sapHwnd"
exit 1
