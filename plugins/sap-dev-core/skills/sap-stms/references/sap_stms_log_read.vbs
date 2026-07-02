' =============================================================================
' sap_stms_log_read.vbs  -  /sap-stms reader: import log return code (READ-ONLY)
'
' Opens the target system's STMS import queue / history, locates the TR, and
' reads its import RETURN CODE (0/4/8/12). The caller maps RC -> verdict
' (0=OK, 4=OK_WITH_WARNINGS, 8=ERROR, 12=FATAL). RC is TRUTH -- a row can look
' "done" while carrying RC 8.
'
' READ-ONLY: opens lists and reads cells; presses no write button. Control IDs
' vary by release -- tries candidates, degrades to status=skipped with a
' /sap-gui-record hint. Language-independent (IDs + MessageType, no text).
'
' Tokens:
'   %%TARGET_SID%%   the system whose import log to read
'   %%TR%%           the transport request
'   %%OUTPUT_FILE%%  absolute path of the log.json to write
'   %%SESSION_PATH%% session hint (or empty)
'   %%ATTACH_LIB_VBS%% absolute path to sap_attach_lib.vbs
' =============================================================================
Option Explicit

Const TARGET_SID   = "%%TARGET_SID%%"
Const TR           = "%%TR%%"
Const OUTPUT_FILE  = "%%OUTPUT_FILE%%"
Const SESSION_PATH = "%%SESSION_PATH%%"

Const VKEY_ENTER = 0

Dim oSession, oFSO

ExecuteGlobal CreateObject("Scripting.FileSystemObject").OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Set oFSO = CreateObject("Scripting.FileSystemObject")
Set oSession = AttachSapSession(SESSION_PATH)

On Error Resume Next
oSession.findById("wnd[0]").maximize
DismissModals
oSession.findById("wnd[0]/tbar[0]/okcd").text = "/nSTMS_IMPORT"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500
DismissModals
On Error GoTo 0

' Navigate INTO the target system's import queue. STMS_IMPORT can land on the
' overview (a list of ALL systems) or the last-opened queue -- reading RC from
' whatever landed would attribute another system's RC to TARGET_SID. Open the
' named queue first; if it cannot be reached, do NOT read (and do NOT stamp the
' output with a SID we never navigated to).
Dim bOnQueue : bOnQueue = OpenTargetQueue(TARGET_SID)

Dim grid : Set grid = FindGridShell()
If grid Is Nothing Then
    WriteLog "skipped", "STMS grid not found for this release. Run /sap-gui-record on STMS_IMPORT and update candidate IDs in sap_stms_log_read.vbs.", "", ""
    WScript.Quit 0
End If

' If we could not confirm the target-system queue is open, refuse rather than
' mislabel another queue's RC as TARGET_SID's.
If Not bOnQueue Then
    WriteLog "skipped", "Could not open the import queue for " & TARGET_SID & " (system not found in the STMS overview, or the queue view differs on this release). Run /sap-gui-record on STMS_IMPORT and update OpenTargetQueue candidate IDs.", "", ""
    WScript.Echo "LOG: tr=" & TR & " system=" & TARGET_SID & " rc=- verdict=QUEUE_NOT_REACHED file=" & OUTPUT_FILE
    WScript.Quit 0
End If

' Scan the grid for the TR row and read its RC column.
Dim rowCount, cols, ri, ci, cId, cVal, sTrkorr, sRc, sStatus, found
On Error Resume Next
rowCount = grid.RowCount
Set cols = grid.ColumnOrder
On Error GoTo 0
If rowCount < 0 Then rowCount = 0

found = False : sRc = "" : sStatus = ""
For ri = 0 To rowCount - 1
    sTrkorr = ""
    On Error Resume Next
    For ci = 0 To cols.Count - 1
        cId = cols(ci)
        cVal = Trim(grid.GetCellValue(ri, cId))
        Select Case UCase(cId)
            Case "TRKORR", "REQUEST"        : sTrkorr = cVal
            Case "RETCODE", "RC", "MAXRC"   : If UCase(sTrkorr) = UCase(TR) Then sRc = OnlyDigits(cVal)
            Case "STATUS", "STAT", "ICON"   : If UCase(sTrkorr) = UCase(TR) And Len(sStatus) = 0 Then sStatus = cVal
        End Select
    Next
    Err.Clear
    On Error GoTo 0
    If UCase(sTrkorr) = UCase(TR) Then
        found = True
        ' re-read RC now that we matched the row (column order independent)
        On Error Resume Next
        If Len(sRc) = 0 Then sRc = OnlyDigits(Trim(grid.GetCellValue(ri, "RETCODE")))
        If Len(sRc) = 0 Then sRc = OnlyDigits(Trim(grid.GetCellValue(ri, "RC")))
        If Len(sRc) = 0 Then sRc = OnlyDigits(Trim(grid.GetCellValue(ri, "MAXRC")))
        Err.Clear
        On Error GoTo 0
        Exit For
    End If
Next

If Not found Then
    WriteLog "ok", "TR not present in the current queue/history view (may be already imported and aged out, or never queued)", "", "NOT_IMPORTED"
    WScript.Echo "LOG: tr=" & TR & " system=" & TARGET_SID & " rc=- verdict=NOT_IMPORTED file=" & OUTPUT_FILE
    WScript.Quit 0
End If

Dim verdict
verdict = VerdictForRc(sRc)
WriteLog "ok", "rc read from STMS grid", sRc, verdict
WScript.Echo "LOG: tr=" & TR & " system=" & TARGET_SID & " rc=" & sRc & " verdict=" & verdict & " file=" & OUTPUT_FILE
WScript.Quit 0

' =============================================================================
' Helpers
' =============================================================================
Function VerdictForRc(sRc)
    If Len(sRc) = 0 Then VerdictForRc = "UNKNOWN" : Exit Function
    Select Case CLng(sRc)
        Case 0  : VerdictForRc = "OK"
        Case 4  : VerdictForRc = "OK_WITH_WARNINGS"
        Case 8  : VerdictForRc = "ERROR"
        Case 12 : VerdictForRc = "FATAL"
        Case Else : VerdictForRc = "RC_" & sRc
    End Select
End Function

Function FindGridShell()
    Dim cand, id, g
    cand = Array( _
        "wnd[0]/usr/cntlCTRL_IMPORT_QUEUE/shellcont/shell", _
        "wnd[0]/usr/cntlGRID_IMPORT/shellcont/shell", _
        "wnd[0]/usr/cntlGRID1/shellcont/shell", _
        "wnd[0]/usr/cntlCONTAINER/shellcont/shell")
    For Each id In cand
        On Error Resume Next
        Set g = Nothing
        Set g = oSession.findById(id)
        If Err.Number = 0 And Not (g Is Nothing) Then
            Dim rc : rc = -1 : rc = g.RowCount
            If Err.Number = 0 And rc >= 0 Then Err.Clear : On Error GoTo 0 : Set FindGridShell = g : Exit Function
        End If
        Err.Clear
        On Error GoTo 0
    Next
    Set FindGridShell = Nothing
End Function

' Open the import queue of the named system from the STMS_IMPORT overview by
' double-clicking its row (SYSNAM/SYSTEM cell match -- locale-independent). Copied
' from sap_stms_import.vbs so RC is read from the RIGHT system's queue. READ-ONLY
' (double-click is navigation). Returns True only when a matching row was found +
' opened; False when the overview isn't present or the SID isn't listed (caller
' must then refuse rather than read whatever landed).
Function OpenTargetQueue(sSid)
    OpenTargetQueue = False
    Dim ov : Set ov = FindGridShell()
    If ov Is Nothing Then Exit Function
    Dim rc, i, v
    On Error Resume Next
    rc = ov.RowCount
    For i = 0 To rc - 1
        v = "" : v = Trim(ov.GetCellValue(i, "SYSNAM"))
        If Len(v) = 0 Then v = Trim(ov.GetCellValue(i, "SYSTEM"))
        If UCase(v) = UCase(sSid) Then
            ov.setCurrentCell i, ""
            ov.doubleClickCurrentCell
            WScript.Sleep 1200
            DismissModals
            OpenTargetQueue = True
            Exit For
        End If
    Next
    Err.Clear
    On Error GoTo 0
End Function

Function OnlyDigits(s)
    Dim i, c, o : o = ""
    For i = 1 To Len(s)
        c = Mid(s, i, 1)
        If c >= "0" And c <= "9" Then o = o & c
    Next
    OnlyDigits = o
End Function

Function JsonEsc(s)
    Dim t : t = s & ""
    t = Replace(t, "\", "\\")
    t = Replace(t, """", "\""")
    t = Replace(t, vbCr, " ") : t = Replace(t, vbLf, " ") : t = Replace(t, vbTab, " ")
    JsonEsc = t
End Function

Function JKV(k, v)
    JKV = """" & k & """:""" & JsonEsc(v) & """"
End Function

Sub WriteLog(status, reason, rc, verdict)
    Dim o, j
    j = "{" & """source"":""STMS_LOG""," & """status"":""" & JsonEsc(status) & ""","  & _
        JKV("reason", reason) & "," & JKV("system", TARGET_SID) & "," & JKV("tr", TR) & "," & _
        JKV("rc", rc) & "," & JKV("verdict", verdict) & "}"
    Set o = oFSO.CreateTextFile(OUTPUT_FILE, True, False)
    o.Write j
    o.Close
End Sub

Sub DismissModals()
    Dim attempt, idx, oWnd
    For attempt = 1 To 4
        Dim any : any = False
        For idx = 3 To 1 Step -1
            On Error Resume Next
            Set oWnd = Nothing
            Set oWnd = oSession.findById("wnd[" & idx & "]")
            If Err.Number = 0 And Not (oWnd Is Nothing) Then
                Err.Clear
                oWnd.sendVKey 12
                any = True
                WScript.Sleep 250
            End If
            Err.Clear
            On Error GoTo 0
        Next
        If Not any Then Exit Sub
    Next
End Sub
