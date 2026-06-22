' =============================================================================
' sap_function_group_gui_delete.vbs  -  Delete a Function Group via SE38 SAPL<FG>
'
' Deletes the function group by deleting its function-pool program SAPL<FUGR>
' via SE38 (Shift+F2 = sendVKey 14) + the shared sap_delete_popups.vbs walker.
' Deleting SAPL<FUGR> cascades the function-group delete (the pool program with
' its FMs / includes / screens, and the TLIBG registration) on BOTH ECC 6.0 /
' NW 7.31 AND S/4HANA -- verified EC2/ERP + S4D 2026-06-22.
'
' >>> Prefer invoking the /sap-function-group skill (delete mode) via the Skill
'     tool -- it wraps this VBS with TR resolution, the dependent-FM pre-check,
'     the post-delete RFC verification (TLIBG / TFDIR), and logging. This VBS
'     does only a quick Display re-check; the authoritative verify is the
'     skill's. Driving this VBS directly is fine for skill dev/debug. <<<
'
' History: this replaced the SE80 WB_DELETE path on 2026-06-22. SE80's HTML
' type/name control is absent on ECC6 (classic navigator) and, even on S/4, its
' hand-rolled inline popup walker looped on a $TMP/local FG and emitted a false
' SUCCESS on an empty status bar (S4D: TLIBG=1 yet "deleted"). SE38 SAPL<FG> +
' the shared DDIC-id-gated walker (SAPLSETX / KO007 / TR-prompt / confirm) is
' release- and locale-robust and deletes cleanly on both, so it is the single
' path now. (Deleting the function-pool program is the same mechanism the old
' code already used as its ECC6 fallback.)
'
' Tokens replaced at run time:
'   %%FUGR_ID%%        Function group name (UPPERCASE), e.g. "ZDEV_FG".
'   %%TRANSPORT%%      TR for a transportable FG's post-delete prompt. Empty for
'                        $TMP / already-locked; if the TR prompt appears with
'                        TRANSPORT empty the script aborts (resolve a TR first).
'   %%PACKAGE%%        Package for the ECC6 KO007 "Create Object Directory Entry"
'                        popup. Empty => accept pre-filled / Local Object.
'   %%ORIG_LANG%%      1-char original language for an empty KO007 package field.
'   %%SESSION_PATH%%   Session path (empty = default).
'   %%ATTACH_LIB_VBS%% / %%SESSION_LOCK_VBS%% shared-script paths (the shared
'                        sap_delete_popups.vbs walker is derived from the
'                        attach-lib dir -- same folder).
'
' Outputs (last line, parseable):
'   SUCCESS: Function group <FUGR> deleted.
'   ERROR:   ...
' =============================================================================

Option Explicit

Const FUGR_ID       = "%%FUGR_ID%%"
Const SAP_TRANSPORT = "%%TRANSPORT%%"
Const SESSION_PATH  = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER    = 0
Const VKEY_SHIFT_F2 = 14   ' Delete from the SE38 initial screen

' Optional fill for the ECC6 "Create Object Directory Entry" (SAPLSTRD) popup.
' Empty => accept SAP's pre-filled package / Local Object; OBJDIR_LANG is the
' 1-char original language used only when filling an empty package field.
Dim OBJDIR_PKG  : OBJDIR_PKG  = "%%PACKAGE%%"
Dim OBJDIR_LANG : OBJDIR_LANG = "%%ORIG_LANG%%"
If Left(OBJDIR_PKG, 2)  = Chr(37) & Chr(37) Then OBJDIR_PKG  = ""
If Left(OBJDIR_LANG, 2) = Chr(37) & Chr(37) Then OBJDIR_LANG = ""
If OBJDIR_LANG = "" Then OBJDIR_LANG = "E"

' Include shared helpers (attach first; session-lock's pre-unlock sweep reads
' from oSession), then the shared post-delete popup walker (same dir as attach).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()
Dim oDpFso, sDpDir
Set oDpFso = CreateObject("Scripting.FileSystemObject")
sDpDir = oDpFso.GetParentFolderName("%%ATTACH_LIB_VBS%%")
ExecuteGlobal oDpFso.OpenTextFile(oDpFso.BuildPath(sDpDir, "sap_delete_popups.vbs"), 1).ReadAll()

Dim sFugr : sFugr = UCase(Trim(FUGR_ID))
If sFugr = "" Then
    WScript.Echo "ERROR: FUGR_ID is empty. Pass a function group name to delete."
    WScript.Quit 1
End If
Dim sProg : sProg = "SAPL" & sFugr

' ------ 1. Attach + navigate to SE38 ---------------------------------------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Deleting function group " & sFugr & " via its pool program " & sProg & " (SE38)..."
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE38"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000

' ------ 2. Enter the pool-program name -------------------------------------
On Error Resume Next
oSess.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").Text = sProg
oSess.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").caretPosition = Len(sProg)
If Err.Number <> 0 Then
    WScript.Echo "ERROR: SE38 program-name field not found (ctxtRS38M-PROGRAMM): " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' ------ 3. Lock + press Delete (Shift+F2) ----------------------------------
Dim wasLocked : wasLocked = TryLockSession(oSess)
If wasLocked Then
    WScript.Echo "INFO: Session UI locked for the delete + popup-confirm critical section."
Else
    WScript.Echo "INFO: LockSessionUI not available on this SAP GUI build; continuing without lock."
End If

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

' ------ 4. Walk the post-delete popup chain --------------------------------
' Deleting SAPL<FG> can chain several modals: a confirm, a dependents+confirm
' pair (the FG's FMs cascade with the pool program), the SAPLSETX language
' popup, the KO007 Object-Directory entry (ECC6), and a TR prompt for a
' transportable FG -- all dispatched by DDIC control id in the shared walker,
' which walks the active window so stacked popups (wnd[1]+wnd[2]) clear in order.
Dim dpRes : dpRes = WalkDeletePopups(oSess, OBJDIR_PKG, OBJDIR_LANG, SAP_TRANSPORT)
If dpRes = "ABORT_EMPTY_TR" Then
    WScript.Echo "ERROR: SAP prompted for a transport request but TRANSPORT is empty."
    WScript.Echo "       Resolve a TR via /sap-transport-request and re-run."
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If

' ------ 5. Quick verify via Display ----------------------------------------
' If Display re-opens the editor (the program-name field is gone), SAPL<FG>
' still exists. If the field survives (we stayed on the SE38 initial screen),
' it is gone. Authoritative verification (TLIBG / TFDIR zero rows) is the
' caller's job -- see SKILL.md Step 3e.
WScript.Echo "INFO: Verifying deletion (try Display)..."
On Error Resume Next
oSess.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").Text = sProg
oSess.findById("wnd[0]/usr/btnSHOP").press
WScript.Sleep 1500
On Error GoTo 0

Dim sFinalMsg, sFinalType
On Error Resume Next
sFinalMsg  = oSess.findById("wnd[0]/sbar").Text
sFinalType = oSess.findById("wnd[0]/sbar").MessageType
On Error GoTo 0

ReleaseSession oSess, wasLocked
If wasLocked Then WScript.Echo "INFO: Session UI lock released."

Dim oNameField : Set oNameField = Nothing
On Error Resume Next
Set oNameField = oSess.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM")
Dim bNameFieldStillThere : bNameFieldStillThere = (Err.Number = 0) And Not (oNameField Is Nothing)
Err.Clear
On Error GoTo 0

If Not bNameFieldStillThere Then
    WScript.Echo "ERROR: " & sProg & " still exists after delete (Display opened the editor)."
    WScript.Echo "       sbar=[" & sFinalType & "] " & sFinalMsg
    oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE38"
    oSess.findById("wnd[0]").sendVKey VKEY_ENTER
    WScript.Quit 1
End If

WScript.Echo "INFO: SAP status: [" & sFinalType & "] " & sFinalMsg
WScript.Echo "SUCCESS: Function group " & sFugr & " deleted."
WScript.Quit 0
