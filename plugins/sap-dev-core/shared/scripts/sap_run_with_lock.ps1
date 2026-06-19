# sap_run_with_lock.ps1 -- run a command while holding a machine-global named mutex.
#
# Serializes a critical section that contends on an OS-global singleton which no
# per-run folder can isolate. The motivating case is SE38's source paste: it
# stages ABAP source on the Windows CLIPBOARD (Set-Clipboard) and pastes it with
# SendKeys ^v behind an OS-FOREGROUND guard. Both the clipboard and the
# foreground/focus owner are process-global, machine-wide singletons -- two
# concurrent SE38 pastes would cross-paste each other's source. The session
# broker + {RUN_TEMP} fix per-session and per-file collisions, but NOT these OS
# singletons; this wrapper does, by serializing the whole paste-driving cscript
# behind a named mutex. GUI deploys serialize here BY DESIGN (they share one
# foreground/clipboard, so they cannot truly run in parallel regardless).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File sap_run_with_lock.ps1 `
#       -MutexName SapDevGuiPaste_v1 -TimeoutMs 180000 `
#       -Command "cscript //NoLogo ""C:\...\run\sap_se38_create_run.vbs"""
#
# - Stdout/stderr of the wrapped command pass through unchanged so the caller's
#   parser (SUCCESS:/ERROR:/PROGDIR: lines, etc.) is unaffected. The lock's own
#   diagnostics go to STDERR to keep stdout clean.
# - Exit code = the wrapped command's exit code, EXCEPT:
#     2 = could not acquire the mutex within -TimeoutMs (the command did NOT run).
#
# Mirrors the With-...Lock idiom from sap_connection_lib.ps1 / sap_session_broker.ps1:
# WaitOne(timeout), tolerate AbandonedMutexException (a crashed prior holder), and
# ReleaseMutex + Dispose in finally.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MutexName,
    [Parameter(Mandatory)][string]$Command,
    [int]$TimeoutMs = 180000
)

$mutex = [System.Threading.Mutex]::new($false, $MutexName)
$acquired = $false
$exitCode = 0
try {
    try {
        $acquired = $mutex.WaitOne($TimeoutMs)
    } catch [System.Threading.AbandonedMutexException] {
        # A prior holder crashed before releasing; we now own the mutex. The
        # protected resource is the OS clipboard/foreground, which is
        # self-correcting on the next paste, so it is safe to proceed.
        $acquired = $true
    }
    if (-not $acquired) {
        [Console]::Error.WriteLine("ERROR: sap_run_with_lock could not acquire mutex '$MutexName' within ${TimeoutMs}ms; command NOT run")
        exit 2
    }
    # Success path is silent so the wrapped command's stdout/stderr reach the
    # caller's parser unpolluted; only the failure path above is loud.
    # Run the command line as given. cmd /c lets the caller pass a full
    # "cscript //NoLogo ""<path>"" args" string with its own quoting intact.
    & cmd /c $Command
    $exitCode = $LASTEXITCODE
} finally {
    if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
    try { $mutex.Dispose() } catch { }
}
exit $exitCode
