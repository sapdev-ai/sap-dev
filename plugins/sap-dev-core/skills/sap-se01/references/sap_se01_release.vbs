' =============================================================================
' sap_se01_release.vbs  -  Release a Transport Request (and its tasks) via SE01
'
' Tokens replaced at run time:
'   %%TRANSPORT%%   TR number to release, e.g. "ER1K900234"
'
' Flow:
'   1. /nse01 -> Transport Organizer tab (tabpTSSN)
'   2. Enter TR -> press Display button (btn%_AUTOTEXT028)
'   3. Collect EVERY task node number (TR-shaped GuiLabel != parent TR) ONCE,
'      then release each task EXACTLY once (locate its label by exact number,
'      refresh display between releases). No re-scan-and-re-release loop.
'   4. Release the parent request (label located by exact number match).
'   5. Detect a request-release FAILURE (status type E/A, or a non-zero transport-
'      control (tp) return code in the status) and refuse to claim DONE.
'   6. Back to SE01 main.
'
' Two fixes (2026-06-26, from the create->release->delete lifecycle test):
'   P1 - the old design re-scanned for "the first task label" each pass and
'        re-released the SAME (already-released) task until a 10-pass cap, so a
'        1-task TR burned 9 wasted "already released" round-trips. Now each task
'        is collected up front and released once.
'   P4 - on a system whose transport route is not configured, releasing the
'        REQUEST returns "tp ... return code 0012" (status type S) and leaves the
'        request MODIFIABLE (E070-TRSTATUS=D) -- yet the VBS used to print DONE.
'        Now a tp-RC / E-A request-release status makes the VBS WARN + exit 1.
'        The AUTHORITATIVE check is still the caller's RFC verify of
'        E070-TRSTATUS=R (SKILL.md R7) -- the VBS cannot read E070.
'
' Pitfalls handled:
'   - Nodes located by EXACT number match (locale/layout independent), never by
'     fixed lbl[col,row] positions or the localized "Display Request <TR>" header.
'   - Label coordinates shift after each release -> re-display before each lookup.
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

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim sTR
Dim gLastStat, gLastType    ' last release-status text + MessageType, set by ReleaseRow
gLastStat = "" : gLastType = ""

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

' ------ 4. Release each task EXACTLY ONCE (P1) -------------------------------
' Collect every task node number up front, then release each once (locating its
' label by exact number after a fresh display). The old re-scan-first-label loop
' re-released the same already-released task until a 10-pass cap.
Dim aTasks : aTasks = CollectTaskNumbers(sTR)
WScript.Echo "INFO: " & (UBound(aTasks) + 1) & " task(s) to release."
Dim iT, sLblId
For iT = 0 To UBound(aTasks)
    RefreshDisplay sTR
    sLblId = FindLabelIdByNumber(aTasks(iT))
    If sLblId = "" Then
        WScript.Echo "INFO: task " & aTasks(iT) & " not on display (already released/gone); skip."
    Else
        WScript.Echo "INFO: releasing task " & aTasks(iT) & "..."
        ReleaseRow sLblId
    End If
Next

' ------ 5. Release the parent request (located by exact number) --------------
Dim bReqTried, bReqFailed
bReqTried = False : bReqFailed = False
RefreshDisplay sTR
Dim sReqLbl : sReqLbl = FindLabelIdByNumber(sTR)
If sReqLbl = "" Then
    WScript.Echo "WARN: Could not find request label " & sTR & " after task release " & _
                 "(already gone, or layout differs). Verify E070-TRSTATUS."
Else
    WScript.Echo "INFO: releasing request " & sTR & "..."
    ReleaseRow sReqLbl
    bReqTried = True
    ' P4: a request release that hits a transport-control (tp) error leaves the
    ' request MODIFIABLE even though the status message type is S. Flag E/A
    ' status OR a non-zero tp return code so we never claim a false DONE.
    If gLastType = "E" Or gLastType = "A" Then bReqFailed = True
    If LooksLikeTpFailure(gLastStat) Then bReqFailed = True
End If

' ------ 6. Back to SE01 main -------------------------------------------------
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_F3_BACK
WScript.Sleep 400
oSess.findById("wnd[0]").sendVKey VKEY_F3_BACK
WScript.Sleep 400
Err.Clear
On Error GoTo 0

' ------ 7. Verdict (P4) -----------------------------------------------------
' The AUTHORITATIVE check is the caller's RFC verify of E070-TRSTATUS=R (this
' GUI step cannot read E070). Here we only refuse a clean DONE when the request
' release visibly failed.
If bReqTried And bReqFailed Then
    WScript.Echo "WARNING: request " & sTR & " release appears to have FAILED (last status: [" & _
                 gLastType & "] " & gLastStat & "). The request is likely still MODIFIABLE " & _
                 "(E070-TRSTATUS=D) -- e.g. a transport-control (tp) error / unconfigured " & _
                 "transport route. Do NOT treat as released; verify E070-TRSTATUS."
    WScript.Quit 1
End If
WScript.Echo "DONE: TR " & sTR & " release flow ran (no visible failure). Caller MUST verify " & _
             "E070-TRSTATUS=R for the request AND every task -- this GUI step cannot read E070."
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

' Collect EVERY task node number (TR-shaped GuiLabel whose text != parent TR)
' from the current display, deduped. Returns an array (possibly empty).
Function CollectTaskNumbers(sParentTR)
    Dim dict, oUsrLocal, oChild, sText
    Set dict = CreateObject("Scripting.Dictionary")
    On Error Resume Next
    Set oUsrLocal = oSess.findById("wnd[0]/usr")
    If Err.Number = 0 Then
        If Not (oUsrLocal Is Nothing) Then
            For Each oChild In oUsrLocal.Children
                If oChild.Type = "GuiLabel" Then
                    sText = Trim(oChild.Text)
                    If LooksLikeTRNumber(sText) And sText <> sParentTR Then
                        If Not dict.Exists(sText) Then dict.Add sText, True
                    End If
                End If
            Next
        End If
    End If
    Err.Clear
    On Error GoTo 0
    CollectTaskNumbers = dict.Keys
End Function

' Return the ID of the GuiLabel whose text EXACTLY equals sNum on the current
' display. "" if not found.
Function FindLabelIdByNumber(sNum)
    Dim oUsrLocal, oChild
    FindLabelIdByNumber = ""
    On Error Resume Next
    Set oUsrLocal = oSess.findById("wnd[0]/usr")
    If Err.Number = 0 Then
        If Not (oUsrLocal Is Nothing) Then
            For Each oChild In oUsrLocal.Children
                If oChild.Type = "GuiLabel" Then
                    If Trim(oChild.Text) = sNum Then
                        FindLabelIdByNumber = oChild.Id
                        Exit For
                    End If
                End If
            Next
        End If
    End If
    Err.Clear
    On Error GoTo 0
End Function

' P4 heuristic: does a transport-control status carry a non-zero tp return code?
' tp/RDDIMPDP RCs are universal digits inside a localized sentence (0004 warn,
' 0008/0012/0016/0020 error). Treat >= 0008 as a release-failure signal.
Function LooksLikeTpFailure(sStat)
    LooksLikeTpFailure = False
    If sStat = "" Then Exit Function
    If InStr(sStat, "0008") > 0 Or InStr(sStat, "0012") > 0 _
       Or InStr(sStat, "0016") > 0 Or InStr(sStat, "0020") > 0 Then
        LooksLikeTpFailure = True
    End If
End Function

' SAP TR/task numbers: 3-char SID + 'K9' + 5+ digits (e.g. ER1K900235,
' S4HK903102). The SID's first char is a letter; chars 2-3 may be letters
' OR digits (e.g. S4H, S42, C11) -- so only char 1 is constrained to A-Z.
Function LooksLikeTRNumber(s)
    Dim i, ch, c1
    LooksLikeTRNumber = False
    If Len(s) < 8 Or Len(s) > 12 Then Exit Function
    If InStr(2, s, "K9") = 0 Then Exit Function
    c1 = UCase(Mid(s, 1, 1))
    If c1 < "A" Or c1 > "Z" Then Exit Function
    For i = 2 To 3
        ch = UCase(Mid(s, i, 1))
        If Not ((ch >= "A" And ch <= "Z") Or (ch >= "0" And ch <= "9")) Then Exit Function
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
    ' Record the last release status so the caller (request-release verdict, P4)
    ' can detect a tp-error / E-A failure.
    gLastStat = sStat
    gLastType = sType
    If sStat <> "" Then WScript.Echo "  status[" & sType & "]: " & sStat
End Sub
