' =============================================================================
' sap_se01_release.vbs  -  Release a Transport Request (and its tasks) via SE01
'
' Tokens replaced at run time:
'   %%TRANSPORT%%   TR number to release, e.g. "ER1K900234"
'
' Flow:
'   1. /nse01 -> Transport Organizer tab (tabpTSSN)
'   2. Enter TR -> press Display button (btn%_AUTOTEXT028)
'   3. Scan wnd[0]/usr GuiLabels: any TR-shaped label != parent TR is a task.
'      Release each task (F9) one at a time, refreshing display in between.
'   4. Refresh display, find the parent TR label by EXACT text match, release.
'   5. Back to SE01 main.
'
' Pitfalls handled:
'   - The previous "first GuiLabel" pick caught lbl[0,0] (an empty header
'     cell) and released nothing. We now match by exact text.
'   - Label coordinates shift after each release -> re-scan + re-display.
'   - Use exact equality (oC.Text = TRANSPORT), NOT InStr -- the screen
'     header reads "Display Request <TR>" which would also match.
'   - VBScript "If A And B" does NOT short-circuit. Pre-Set Nothing + split
'     If Err = 0 / If Not (X Is Nothing) to avoid 424 on Empty Is Nothing.
' =============================================================================

Option Explicit

Const TRANSPORT = "%%TRANSPORT%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER       = 0
Const VKEY_F3_BACK     = 3
Const VKEY_F9_RELEASE  = 9

Const TR_FIELD       = "wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/ctxtTRDYSE01SN-TR_TRKORR"
Const DISPLAY_BUTTON = "wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/btn%_AUTOTEXT028"

Const MAX_TASK_PASSES = 10

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim sTR

sTR = UCase(Trim(TRANSPORT))
If sTR = "" Then
    WScript.Echo "ERROR: TRANSPORT is empty. Pass a TR number to release."
    WScript.Quit 1
End If

' ------ 1. Attach to existing SAP GUI session (via shared attach helper) ----
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Session acquired. Releasing TR " & sTR & "..."

' ------ 2. Navigate to SE01 ---------------------------------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nse01"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500

On Error Resume Next
oSess.findById("wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN").select
WScript.Sleep 500
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not select Transport Organizer tab (tabpTSSN). " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' ------ 3. Display TR --------------------------------------------------------
If Not OpenTRDisplay(sTR) Then WScript.Quit 1

' ------ 4. Release tasks one pass at a time ---------------------------------
Dim iPass, sFirstTask
For iPass = 1 To MAX_TASK_PASSES
    sFirstTask = FindFirstTaskLabelId(sTR)
    If sFirstTask = "" Then
        WScript.Echo "INFO: No more tasks to release (pass " & iPass & ")."
        Exit For
    End If
    WScript.Echo "INFO: Pass " & iPass & " - releasing task at " & sFirstTask & "..."
    ReleaseRow sFirstTask
    RefreshDisplay sTR
Next

' ------ 5. Find + release the parent TR by EXACT text match -----------------
Dim oUsr, oC, oTRLbl
Set oTRLbl = Nothing
On Error Resume Next
Set oUsr = oSess.findById("wnd[0]/usr")
If Err.Number = 0 Then
    If Not (oUsr Is Nothing) Then
        For Each oC In oUsr.Children
            If oC.Type = "GuiLabel" Then
                If oC.Text = sTR Then
                    Set oTRLbl = oC
                    Exit For
                End If
            End If
        Next
    End If
End If
Err.Clear
On Error GoTo 0

If oTRLbl Is Nothing Then
    WScript.Echo "WARN: Could not find TR label " & sTR & " after task release. " & _
                 "It may already be released, or the layout differs on this build."
Else
    WScript.Echo "INFO: Releasing TR " & sTR & " at " & oTRLbl.Id & "..."
    ReleaseRow oTRLbl.Id
End If

' ------ 6. Back to SE01 main -------------------------------------------------
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_F3_BACK
WScript.Sleep 400
oSess.findById("wnd[0]").sendVKey VKEY_F3_BACK
WScript.Sleep 400
Err.Clear
On Error GoTo 0

WScript.Echo "DONE: TR " & sTR & " release flow completed. Verify status via E070-TRSTATUS (R = Released)."
WScript.Quit 0


' ============================================================================
' Helpers
' ============================================================================

Function OpenTRDisplay(sTRNum)
    OpenTRDisplay = False
    On Error Resume Next
    oSess.findById(TR_FIELD).Text = sTRNum
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Could not enter TR into field. " & Err.Description
        Err.Clear
        On Error GoTo 0
        Exit Function
    End If
    Err.Clear
    oSess.findById(DISPLAY_BUTTON).press
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Display button (btn%_AUTOTEXT028) not found. " & Err.Description
        Err.Clear
        On Error GoTo 0
        Exit Function
    End If
    Err.Clear
    On Error GoTo 0
    WScript.Sleep 2000
    OpenTRDisplay = True
End Function

Sub RefreshDisplay(sTRNum)
    On Error Resume Next
    oSess.findById("wnd[0]/tbar[0]/btn[3]").press
    WScript.Sleep 1000
    Err.Clear
    On Error GoTo 0
    OpenTRDisplay sTRNum
End Sub

' Return the ID of the first GuiLabel whose text looks like a TR/task number
' AND is not the parent TR. "" if none found.
Function FindFirstTaskLabelId(sParentTR)
    Dim oUsrLocal, oChild, sText
    FindFirstTaskLabelId = ""
    On Error Resume Next
    Set oUsrLocal = oSess.findById("wnd[0]/usr")
    If Err.Number = 0 Then
        If Not (oUsrLocal Is Nothing) Then
            For Each oChild In oUsrLocal.Children
                If oChild.Type = "GuiLabel" Then
                    sText = Trim(oChild.Text)
                    If LooksLikeTRNumber(sText) And sText <> sParentTR Then
                        FindFirstTaskLabelId = oChild.Id
                        Exit For
                    End If
                End If
            Next
        End If
    End If
    Err.Clear
    On Error GoTo 0
End Function

' SAP TR/task numbers: 3-letter SID + 'K9' + 5+ digits (e.g. ER1K900235).
Function LooksLikeTRNumber(s)
    Dim i, ch
    LooksLikeTRNumber = False
    If Len(s) < 8 Or Len(s) > 12 Then Exit Function
    If InStr(2, s, "K9") = 0 Then Exit Function
    For i = 1 To 3
        ch = UCase(Mid(s, i, 1))
        If ch < "A" Or ch > "Z" Then Exit Function
    Next
    LooksLikeTRNumber = True
End Function

Sub ReleaseRow(sLblId)
    Dim iPopup, sStat, sType
    On Error Resume Next
    Err.Clear
    oSess.findById(sLblId).setFocus
    If Err.Number <> 0 Then
        WScript.Echo "  WARN: Could not focus " & sLblId & ": " & Err.Description
        Err.Clear
        On Error GoTo 0
        Exit Sub
    End If
    ' Release via menu path: Request/Task -> Release -> Direct
    ' (sendVKey 9 sometimes does Find instead of Release on this SAP build.)
    Err.Clear
    oSess.findById("wnd[0]/mbar/menu[0]/menu[3]/menu[0]").select
    If Err.Number <> 0 Then
        Err.Clear
        ' Fallback to F9 keystroke
        oSess.findById("wnd[0]").sendVKey VKEY_F9_RELEASE
    End If
    WScript.Sleep 1500
    For iPopup = 1 To 6
        If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
            WScript.Echo "  popup: " & oSess.findById("wnd[1]").Text
            oSess.ActiveWindow.sendVKey VKEY_ENTER
            WScript.Sleep 1500
        Else
            Exit For
        End If
    Next
    sStat = oSess.findById("wnd[0]/sbar").Text
    sType = oSess.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    If sStat <> "" Then WScript.Echo "  status[" & sType & "]: " & sStat
End Sub
