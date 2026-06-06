' =============================================================================
' sap_session_lock.vbs  -  Session lock helpers for sap-dev VBScript skills
'
' Wraps SAP GUI Scripting's session.LockSessionUI / UnlockSessionUI methods in
' a defensive idiom that:
'   1. Degrades gracefully on older SAP GUI builds that lack the API.
'   2. Survives errors mid-script (idempotent ReleaseSession).
'   3. Cannot leak a lock to a different session (lock state is per-call).
'
' Include this file via the standard VBS include trick:
'
'   ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
'       .OpenTextFile("<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs", 1).ReadAll()
'
' Or have the wrapper inject the file path via the %%SESSION_LOCK_VBS%% token
' and dot-include it the same way (matches the LOG_LIB_VBS pattern).
'
' Pattern at call site:
'
'   Dim wasLocked : wasLocked = TryLockSession(oSession)
'   On Error Resume Next
'   ' ... critical section: source paste, save, activate, popup handling ...
'   ReleaseSession oSession, wasLocked
'   On Error GoTo 0
'
'   ' Before EVERY WScript.Quit, also release:
'   ReleaseSession oSession, wasLocked
'   WScript.Quit nExitCode
'
' Why lock at all
' ---------------
' The SAP GUI window can lose focus mid-script if the user clicks somewhere,
' a tooltip / balloon dialog appears, or an internal SAP popup arrives in an
' unexpected order. LockSessionUI blocks ALL user input on the targeted
' session, so the script is the only thing driving it. This is complementary
' to AppActivate-loop foreground guards, which protect against focus stealing
' by EXTERNAL apps; LockSessionUI protects against internal user-input races.
'
' Limitations
' -----------
'   - LockSessionUI is session-scoped, not application-scoped. Other SAP
'     sessions in the same SAP Logon remain interactive.
'   - LockSessionUI does NOT prevent another application (Outlook toast,
'     alt-tab, Windows notification) from stealing OS-level focus --
'     critical for SendKeys-based pastes. Pair with
'     `shared/scripts/sap_gui_foreground_guard.ps1`, which uses the Win32
'     `AttachThreadInput` trick to actually force SAP to OS foreground.
'     Older skills used `WshShell.AppActivate` in a retry loop for this;
'     that approach fails on Windows 7+ because SetForegroundWindow is
'     suppressed for non-foreground processes (AppActivate returns success
'     while Windows just flashes the taskbar button).
'   - Older SAP GUI builds may not expose LockSessionUI on the GuiSession
'     interface. TryLockSession degrades gracefully (returns False) on
'     such builds; the rest of the script runs without lock protection.
'   - If the script crashes between lock and release, the SAP GUI session
'     stays frozen until the user kills SAP from Task Manager. ALWAYS
'     pair TryLockSession with ReleaseSession in EVERY exit path
'     (success, error, early return).
' =============================================================================

' Returns True if the lock succeeded; False if the API is unavailable, the
' session is Nothing, or the call raised an error. Callers MUST capture the
' return value and pass it to ReleaseSession in every exit path.
Function TryLockSession(sess)
    TryLockSession = False
    If sess Is Nothing Then Exit Function
    On Error Resume Next
    sess.LockSessionUI
    If Err.Number = 0 Then
        TryLockSession = True
    Else
        ' Most common cause: SAP GUI build that doesn't expose LockSessionUI
        ' on the GuiSession interface. Continue without lock -- the script is
        ' less defended against focus races but still functional.
        Err.Clear
    End If
    On Error GoTo 0
End Function

' Best-effort unlock. No-op if wasLocked is False or sess is Nothing.
' Idempotent -- safe to call multiple times in cleanup paths.
'
' BEFORE unlocking, this sweeps up to 5 chained modal popups from the active
' session window via sendVKey 12 (F12 / Cancel). This addresses Pitfall #2
' from Rule 7: if the script reaches the release point with an undismissed
' modal popup still on screen, unlocking would hand control back to a user
' who can't interact with anything except that opaque modal. The sweep
' guarantees the user receives a clean main-window session.
'
' F12 (Cancel) is the safest dismissal key -- it closes most popups WITHOUT
' committing pending changes. If the script is on a success path the
' critical section already saved/activated what it needed; any leftover
' popup is informational. If the script is on an abort path, F12 keeps
' the user's prior state intact while clearing the modal.
'
' Localised text is echoed for diagnostics only (per Rule 4) -- control
' flow uses ActiveWindow.Id, not popup titles.
Sub ReleaseSession(sess, wasLocked)
    If Not CBool(wasLocked) Then Exit Sub
    If sess Is Nothing Then Exit Sub

    ' --- Pitfall #2 defence: sweep up to 5 chained modal popups ---
    On Error Resume Next
    Dim iSweep, sActiveId, sPopupText
    For iSweep = 1 To 5
        sActiveId = sess.ActiveWindow.Id
        If Err.Number <> 0 Then
            Err.Clear
            Exit For
        End If
        ' Active window ending in "wnd[0]" = main window, no modal. Done.
        If Right(sActiveId, 6) = "wnd[0]" Then Exit For

        ' Echo the popup title (localised text -- diagnostic only).
        sPopupText = sess.ActiveWindow.Text
        If Err.Number <> 0 Then
            sPopupText = "(text unreadable)"
            Err.Clear
        End If
        WScript.Echo "WARN: Pre-unlock sweep " & iSweep & " -- dismissing modal " & _
                     sActiveId & " (" & sPopupText & ")"

        sess.ActiveWindow.sendVKey 12   ' F12 = Cancel (safest)
        If Err.Number <> 0 Then Err.Clear
        WScript.Sleep 500
    Next
    On Error GoTo 0

    ' --- Unlock ---
    On Error Resume Next
    sess.UnlockSessionUI
    If Err.Number <> 0 Then Err.Clear
    On Error GoTo 0
End Sub
