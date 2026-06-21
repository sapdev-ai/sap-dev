' =============================================================================
' sap_se01_delete.vbs  -  Delete an (unreleased) Transport Request via SE01
'
' Deletes the request OBJECT (not release -- releasing would transport the
' request's objects onward). Used by /sap-dev-clean --reset to drop the dev TR
' once Steps 3a-3e have removed every object it held. IRREVERSIBLE -- the caller
' MUST confirm (and check the E071 child list) before invoking this.
'
' Tokens replaced at run time:
'   %%TRANSPORT%%   TR number to delete, e.g. "ER1K900234". Required, unreleased.
'   %%SESSION_PATH%% Session path (empty = default).
'   %%ATTACH_LIB_VBS%% / %%SESSION_LOCK_VBS%% shared-script paths.
'
' Flow (mirrors the proven sap_se01_release.vbs navigation):
'   1. /nSE01 -> Transport Organizer tab (tabpTSSN)
'   2. Enter TR -> Display (btn%_AUTOTEXT028) -> request-display screen SAPMSSY0/120
'   3. Focus the parent TR row (exact-text GuiLabel), press Delete (tbar[1]/btn[13]
'      = Shift+F1, a stable id) -> the shared WalkDeletePopups answers the
'      "delete request and its tasks?" confirm chain.
'   4. Verify: re-display the TR; if the request screen no longer opens
'      (Info.Program leaves SAPMSSY0), it is gone. Authoritative verification is
'      the caller's RFC E070 re-check.
'
' Pitfalls handled:
'   - A RELEASED request cannot be deleted (only reimported) -> surfaced.
'   - Verify by Info.Program (language-independent), never the localized title.
'   - Delete confirm popups handled by the shared DDIC-id-gated walker.
'
' Outputs (last line, parseable):
'   SUCCESS: Transport request <TR> deleted.
'   ERROR:   ...
' =============================================================================

Option Explicit

Const TRANSPORT    = "%%TRANSPORT%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER   = 0
Const VKEY_F3_BACK = 3

Const TR_FIELD       = "wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/ctxtTRDYSE01SN-TR_TRKORR"
Const DISPLAY_BUTTON = "wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/btn%_AUTOTEXT028"
Const DELETE_BUTTON  = "wnd[0]/tbar[1]/btn[13]"   ' Delete (Shift+F1) on the request-display screen
Const DISPLAY_PROG   = "SAPMSSY0"                 ' program of the request-display screen

' Include shared helpers: attach + session-lock + the post-delete popup walker
' (the walker path is derived from the attach-lib dir; both live in shared/scripts).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()
Dim oDpFso, sDpDir
Set oDpFso = CreateObject("Scripting.FileSystemObject")
sDpDir = oDpFso.GetParentFolderName("%%ATTACH_LIB_VBS%%")
ExecuteGlobal oDpFso.OpenTextFile(oDpFso.BuildPath(sDpDir, "sap_delete_popups.vbs"), 1).ReadAll()

Dim sTR : sTR = UCase(Trim(TRANSPORT))
If sTR = "" Then
    WScript.Echo "ERROR: TRANSPORT is empty. Pass a TR number to delete."
    WScript.Quit 1
End If

' ------ 1. Attach + navigate to SE01 ---------------------------------------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Deleting transport request " & sTR & "..."
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE01"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500

On Error Resume Next
oSess.findById("wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN").select
WScript.Sleep 400
Err.Clear
On Error GoTo 0

' ------ 2. Display the TR ---------------------------------------------------
On Error Resume Next
oSess.findById(TR_FIELD).Text = sTR
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not enter TR into field (" & TR_FIELD & "): " & Err.Description
    WScript.Quit 1
End If
Err.Clear
oSess.findById(DISPLAY_BUTTON).press
WScript.Sleep 2000
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Display button not found (" & DISPLAY_BUTTON & "): " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

If oSess.Info.Program <> DISPLAY_PROG Then
    Dim sb0 : sb0 = ""
    On Error Resume Next
    sb0 = oSess.findById("wnd[0]/sbar").Text
    On Error GoTo 0
    WScript.Echo "ERROR: Request display did not open for " & sTR & " (it may not exist). PROG=" & _
                 oSess.Info.Program & " sbar=" & sb0
    WScript.Quit 1
End If

' ------ 3. Focus the parent TR row + press Delete --------------------------
Dim wasLocked : wasLocked = TryLockSession(oSess)

Dim oUsr, oC, oTRLbl : Set oTRLbl = Nothing
On Error Resume Next
Set oUsr = oSess.findById("wnd[0]/usr")
If Not (oUsr Is Nothing) Then
    For Each oC In oUsr.Children
        If oC.Type = "GuiLabel" Then
            If Trim(oC.Text) = sTR Then Set oTRLbl = oC : Exit For
        End If
    Next
End If
Err.Clear
On Error GoTo 0
If Not (oTRLbl Is Nothing) Then
    On Error Resume Next
    oTRLbl.setFocus
    Err.Clear
    On Error GoTo 0
End If

WScript.Echo "INFO: Pressing Delete (Shift+F1)..."
On Error Resume Next
oSess.findById(DELETE_BUTTON).press
WScript.Sleep 1500
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not press Delete (" & DELETE_BUTTON & "): " & Err.Description
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' Walk the confirm chain (delete request + tasks? -> Yes). A TR delete raises
' only confirm popups -> pass empty objdir/lang/tr so only branch (d) fires.
Dim dpRes : dpRes = WalkDeletePopups(oSess, "", "", "")

ReleaseSession oSess, wasLocked

' ------ 4. Verify: re-display; request screen should no longer open ---------
WScript.Echo "INFO: Verifying deletion (try Display again)..."
On Error Resume Next
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE01"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1200
oSess.findById("wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN").select
WScript.Sleep 300
oSess.findById(TR_FIELD).Text = sTR
oSess.findById(DISPLAY_BUTTON).press
WScript.Sleep 1500
On Error GoTo 0

Dim sFinalProg, sFinalSbar, sFinalType
sFinalProg = oSess.Info.Program
On Error Resume Next
sFinalSbar = oSess.findById("wnd[0]/sbar").Text
sFinalType = oSess.findById("wnd[0]/sbar").MessageType
On Error GoTo 0

If sFinalProg = DISPLAY_PROG Then
    WScript.Echo "ERROR: TR " & sTR & " still exists after delete (display reopened). sbar=[" & _
                 sFinalType & "] " & sFinalSbar
    oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE01"
    oSess.findById("wnd[0]").sendVKey VKEY_ENTER
    WScript.Quit 1
End If

WScript.Echo "INFO: SAP status: [" & sFinalType & "] " & sFinalSbar
WScript.Echo "SUCCESS: Transport request " & sTR & " deleted."
WScript.Quit 0
