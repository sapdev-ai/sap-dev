' =============================================================================
' sap_se21_delete.vbs  -  Delete a development package via SE21
'
' Drives the recorded flow:
'
'   1. /nse21
'   2. ctxtPBENSCREEN-PACKNAME = <PACKAGE>
'   3. btnDISPLAY  -> Display (verifies the package opens)
'   4. tbar[0]/btn[3]  -> Back to initial screen
'   5. sendVKey 14  -> Shift+F2 = Delete from initial screen
'   6. Confirmation popup wnd[1]:
'        btnBUTTON_1                 (recorded popup style)
'        fallback: btnSPOP-OPTION1   (Yes/No SPOP)
'        fallback: sendVKey 0        (Enter)
'   7. Optional follow-on popups (TR prompt, dependents) -- handled by a
'      generic active-window walker.
'   8. Verify deletion: re-fill the name, press btnDISPLAY again. SAP must
'      stay on the SE21 initial screen with an error / info sbar message
'      ("Package <X> does not exist").
'
' Tokens replaced at run time:
'   %%PACKAGE%%        Package name (UPPERCASE), e.g. "ZHKPKG00001". Required.
'   %%TRANSPORT%%      Transport request for the post-delete TR popup, when
'                       SAP prompts. Optional. Empty when the package is
'                       local ($TMP) or already locked to a modifiable TR.
'                       If the popup appears with TRANSPORT blank the script
'                       aborts so the caller can resolve a TR.
'   %%SESSION_LOCK_VBS%% Path to sap_session_lock.vbs (shared scripts).
'
' Recording reference: C:\Temp\Record_SE21_DeletePackage_01.vbs (S/4HANA 1909).
'
' Output (last line, parseable):
'   SUCCESS: Package <PKG> deleted.
'   ERROR:   ...
'
' IMPORTANT: This skill assumes the operator has confirmed the deletion
' BEFORE the VBS is launched. The VBS itself does NOT prompt -- confirmation
' is the orchestrator's responsibility (see SKILL.md Step 8).
' =============================================================================

Option Explicit

Const PACKAGE       = "%%PACKAGE%%"
Const SAP_TRANSPORT = "%%TRANSPORT%%"
Const SESSION_PATH  = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER    = 0
Const VKEY_F3_BACK  = 3
Const VKEY_SHIFT_F2 = 14   ' Delete on SE21 initial screen

' Include shared helpers (attach first; session-lock's pre-unlock sweep
' reads from oSession).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

If Trim(PACKAGE) = "" Then
    WScript.Echo "ERROR: PACKAGE token is empty."
    WScript.Quit 1
End If

' --- 1. Attach to existing SAP GUI session (via shared attach helper) ------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)

' --- 2. Navigate to SE21 ---------------------------------------------------
WScript.Echo "INFO: Navigating to SE21 to delete package " & UCase(PACKAGE) & "..."
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE21"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1200

' --- 3. Fill package name --------------------------------------------------
On Error Resume Next
oSess.findById("wnd[0]/usr/ctxtPBENSCREEN-PACKNAME").Text = UCase(PACKAGE)
oSess.findById("wnd[0]/usr/ctxtPBENSCREEN-PACKNAME").caretPosition = Len(PACKAGE)
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not fill package name (ctxtPBENSCREEN-PACKNAME): " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' --- Lock session for the delete + popup-confirm critical section ---
Dim wasLocked : wasLocked = TryLockSession(oSess)
If wasLocked Then
    WScript.Echo "INFO: Session UI locked for the delete + popup-confirm critical section."
End If

' --- 4. Press Delete (Shift+F2 = sendVKey 14) ------------------------------
WScript.Echo "INFO: Pressing Delete (Shift+F2)..."
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_SHIFT_F2
WScript.Sleep 1500
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not send Shift+F2: " & Err.Description
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' --- 5. Walk all post-delete confirmation popups ---------------------------
'
' SE21 deletion shows a confirmation popup with btnBUTTON_1 (recorded
' style). Some package configurations chain a TR-prompt popup
' (ctxtKO008-TRKORR) or a "delete subpackage / contents" popup. We loop
' on the active window -- each iteration:
'
'   (a) if the popup carries ctxtKO008-TRKORR -> fill TR or abort
'   (b) try btnBUTTON_1 (recorded confirmation style)
'   (c) try btnSPOP-OPTION1 (Yes/No SPOP fallback)
'   (d) try tbar[0]/btn[0] (Continue button)
'   (e) sendVKey 0 (Enter) as last resort
Dim iPop, sActWnd, sActPrefix
For iPop = 1 To 6
    sActWnd = ""
    On Error Resume Next
    sActWnd = oSess.ActiveWindow.Id
    On Error GoTo 0
    If sActWnd = "" Then Exit For
    If Right(sActWnd, 6) = "wnd[0]" Then Exit For

    ' Compute prefix "wnd[N]" from the absolute id.
    Dim posWnd : posWnd = InStrRev(sActWnd, "/wnd[")
    If posWnd > 0 Then
        sActPrefix = Mid(sActWnd, posWnd + 1)
    Else
        sActPrefix = "wnd[1]"
    End If

    ' (a) TR popup?
    On Error Resume Next
    Dim oTr : Set oTr = Nothing
    Set oTr = oSess.findById(sActPrefix & "/usr/ctxtKO008-TRKORR")
    If Err.Number = 0 And Not (oTr Is Nothing) Then
        If SAP_TRANSPORT = "" Then
            WScript.Echo "ERROR: SAP prompted for a transport request but TRANSPORT is empty."
            WScript.Echo "       Resolve a TR via /sap-transport-request and re-run."
            ReleaseSession oSess, wasLocked
            WScript.Quit 1
        End If
        WScript.Echo "INFO: Filling transport " & SAP_TRANSPORT & " on " & sActPrefix & "..."
        oTr.Text = SAP_TRANSPORT
        oSess.findById(sActPrefix).sendVKey VKEY_ENTER
        WScript.Sleep 1500
        Err.Clear
        On Error GoTo 0
    Else
        Err.Clear
        ' (b) btnBUTTON_1 (recorded popup style for SE21 delete)
        Dim oBtn1 : Set oBtn1 = Nothing
        Set oBtn1 = oSess.findById(sActPrefix & "/usr/btnBUTTON_1")
        If Err.Number = 0 And Not (oBtn1 Is Nothing) Then
            WScript.Echo "INFO: Confirming popup " & iPop & " on " & sActPrefix & " (btnBUTTON_1)..."
            oBtn1.press
            WScript.Sleep 1200
            Err.Clear
        Else
            Err.Clear
            ' (c) btnSPOP-OPTION1 (Yes/No SPOP)
            Dim oYes : Set oYes = Nothing
            Set oYes = oSess.findById(sActPrefix & "/usr/btnSPOP-OPTION1")
            If Err.Number = 0 And Not (oYes Is Nothing) Then
                WScript.Echo "INFO: Confirming popup " & iPop & " on " & sActPrefix & " (Yes)..."
                oYes.press
                WScript.Sleep 1200
                Err.Clear
            Else
                Err.Clear
                ' (d) tbar[0]/btn[0] (Continue)
                Dim oCont : Set oCont = Nothing
                Set oCont = oSess.findById(sActPrefix & "/tbar[0]/btn[0]")
                If Err.Number = 0 And Not (oCont Is Nothing) Then
                    WScript.Echo "INFO: Confirming popup " & iPop & " on " & sActPrefix & " (Continue/btn[0])..."
                    oCont.press
                    WScript.Sleep 1200
                    Err.Clear
                Else
                    Err.Clear
                    ' (e) Enter
                    WScript.Echo "INFO: Confirming popup " & iPop & " on " & sActPrefix & " (Enter)..."
                    oSess.findById(sActPrefix).sendVKey VKEY_ENTER
                    WScript.Sleep 1200
                    Err.Clear
                End If
            End If
        End If
        On Error GoTo 0
    End If
Next

If iPop > 6 Then
    WScript.Echo "WARN: Popup loop hit cap; SAP may have left a modal on screen."
End If

' --- 6. Verify deletion via Display ----------------------------------------
WScript.Echo "INFO: Verifying deletion (try Display)..."
On Error Resume Next
oSess.findById("wnd[0]/usr/ctxtPBENSCREEN-PACKNAME").Text = UCase(PACKAGE)
oSess.findById("wnd[0]/usr/btnDISPLAY").press
WScript.Sleep 1500
On Error GoTo 0

Dim sFinalMsg, sFinalType
On Error Resume Next
sFinalMsg  = oSess.findById("wnd[0]/sbar").Text
sFinalType = oSess.findById("wnd[0]/sbar").MessageType
On Error GoTo 0

ReleaseSession oSess, wasLocked
If wasLocked Then WScript.Echo "INFO: Session UI lock released."

' Decide: if the package-name field is still present on the initial
' screen, we did NOT navigate into the editor -- so the package is gone.
On Error Resume Next
Dim oNameField : Set oNameField = Nothing
Set oNameField = oSess.findById("wnd[0]/usr/ctxtPBENSCREEN-PACKNAME")
Dim bStillOnInitial : bStillOnInitial = _
    (Err.Number = 0) And Not (oNameField Is Nothing)
Err.Clear
On Error GoTo 0

If Not bStillOnInitial Then
    WScript.Echo "ERROR: Package still exists after delete (Display opened the editor)."
    WScript.Echo "       sbar=[" & sFinalType & "] " & sFinalMsg
    WScript.Echo "HINT:  The package may have non-empty TADIR children (Z* objects)"
    WScript.Echo "       that block deletion. Move them to another package, or run"
    WScript.Echo "       /sap-dev-status to enumerate, then retry."
    On Error Resume Next
    oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE21"
    oSess.findById("wnd[0]").sendVKey VKEY_ENTER
    On Error GoTo 0
    WScript.Quit 1
End If

WScript.Echo "INFO: SAP status: [" & sFinalType & "] " & sFinalMsg
WScript.Echo "SUCCESS: Package " & UCase(PACKAGE) & " deleted."
WScript.Quit 0
