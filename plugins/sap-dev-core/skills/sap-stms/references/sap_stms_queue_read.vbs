' =============================================================================
' sap_stms_queue_read.vbs  -  /sap-stms reader: STMS import queue (READ-ONLY)
'
' Navigates /nSTMS_IMPORT, opens the target system's import queue, and scrapes
' each row (TRKORR / owner / short text / status / RC if shown) into a JSON file.
' If a TR is given, also reports its position in the queue.
'
' READ-ONLY: opens lists and reads cells; never imports, never presses a write
' button. The STMS overview + queue control IDs vary by release -- this reader
' tries candidates and degrades to status=skipped with a /sap-gui-probe --record hint
' (same policy as /sap-atc and /sap-st22).
'
' Language independence: controls by ID; status via MessageType; navigation via
' okcd + VKey. No branching on translated text.
'
' Tokens:
'   %%TARGET_SID%%   the target system SID whose queue to read
'   %%TR%%           a transport request to locate (or empty)
'   %%OUTPUT_FILE%%  absolute path of the queue.json to write
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

' ---- navigate to STMS import overview -------------------------------------
On Error Resume Next
oSession.findById("wnd[0]").maximize
DismissModals
oSession.findById("wnd[0]/tbar[0]/okcd").text = "/nSTMS_IMPORT"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500
On Error GoTo 0

' ---- TMS-down guard (BEFORE any modal dismissal) ----------------------------
' A broken TMS communication layer renders the Alert Viewer + error popup
' instead of the queue; blind-dismissing it and then reporting "grid not
' found / re-record IDs" sent the operator chasing control-ID drift when the
' real fault is the TMSADM RFC destination (field 2026-07-11, S4H + ER1).
Dim sTmsAlert : sTmsAlert = DetectTmsAlert()
If Len(sTmsAlert) > 0 Then
    CloseTmsAlertPopup
    WriteJson "error", "STMS_TMS_RFC_DOWN: " & sTmsAlert, "", 0, ""
    WScript.Echo "QUEUE: status=error reason=STMS_TMS_RFC_DOWN " & sTmsAlert
    WScript.Quit 1
End If

On Error Resume Next
DismissModals
On Error GoTo 0

' ---- open the target system's queue ---------------------------------------
' The import overview lists systems; opening the target's queue is release-
' dependent. Try to locate + open the target row, then read the queue grid.
OpenTargetQueue TARGET_SID

' ---- locate + read the queue grid -----------------------------------------
Dim grid : Set grid = FindGridShell()
If grid Is Nothing Then
    WriteSkipped "STMS import-queue grid not found at known IDs for this release. Run /sap-gui-probe --record on STMS_IMPORT and update the candidate IDs in sap_stms_queue_read.vbs."
    WScript.Quit 0
End If

Dim rowCount, cols, ri, ci, cId, cVal
Dim sTrkorr, sOwner, sText, sStatus, sRc
Dim jRows, cnt, posFound
On Error Resume Next
rowCount = grid.RowCount
Set cols = grid.ColumnOrder
On Error GoTo 0
If rowCount < 0 Then rowCount = 0

jRows = "" : cnt = 0 : posFound = -1
For ri = 0 To rowCount - 1
    sTrkorr = "" : sOwner = "" : sText = "" : sStatus = "" : sRc = ""
    On Error Resume Next
    For ci = 0 To cols.Count - 1
        cId = cols(ci)
        cVal = Trim(grid.GetCellValue(ri, cId))
        Select Case UCase(cId)
            Case "TRKORR", "REQUEST"               : sTrkorr = cVal
            Case "AS4USER", "OWNER", "OWNR"        : sOwner = cVal
            Case "AS4TEXT", "TEXT", "SHORTTEXT"    : sText = cVal
            Case "STATUS", "STAT", "ICON"          : If Len(sStatus) = 0 Then sStatus = cVal
            Case "RETCODE", "RC", "MAXRC"          : sRc = OnlyDigits(cVal)
        End Select
    Next
    Err.Clear
    On Error GoTo 0

    If Len(sTrkorr) > 0 Then
        If Len(TR) > 0 And UCase(sTrkorr) = UCase(TR) Then posFound = cnt
        If jRows <> "" Then jRows = jRows & ","
        jRows = jRows & "{" & JKV("trkorr", sTrkorr) & "," & JKV("owner", sOwner) & "," & _
                JKV("text", sText) & "," & JKV("status", sStatus) & "," & JKV("rc", sRc) & "}"
        cnt = cnt + 1
    End If
Next

Dim sPos
If Len(TR) = 0 Then
    sPos = ""
ElseIf posFound >= 0 Then
    sPos = CStr(posFound)
Else
    sPos = "not-in-queue"
End If

WriteJson "ok", "rows=" & cnt, jRows, cnt, sPos
WScript.Echo "QUEUE: system=" & TARGET_SID & " rows=" & cnt & " tr=" & TR & " position=" & sPos & " file=" & OUTPUT_FILE
WScript.Quit 0

' =============================================================================
' Helpers
' =============================================================================
Sub OpenTargetQueue(sSid)
    ' Best-effort: on the import overview, find the row for sSid and open its
    ' queue (double-click). Release-dependent; degrades silently -- if this does
    ' not land on a queue, FindGridShell below returns Nothing and we skip.
    Dim ov : Set ov = FindGridShell()
    If ov Is Nothing Then Exit Sub
    Dim rc, i, v, col
    On Error Resume Next
    rc = ov.RowCount
    For i = 0 To rc - 1
        col = ""
        v = "" : v = Trim(ov.GetCellValue(i, "SYSNAM"))
        If Len(v) = 0 Then v = Trim(ov.GetCellValue(i, "SYSTEM"))
        If UCase(v) = UCase(sSid) Then
            ov.setCurrentCell i, ""
            ov.doubleClickCurrentCell
            WScript.Sleep 1200
            DismissModals
            Exit For
        End If
    Next
    Err.Clear
    On Error GoTo 0
End Sub

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

Sub WriteJson(status, reason, rowsJson, total, position)
    Dim o, j
    j = "{" & JKV("source", "STMS_QUEUE") & "," & JKV("status", status) & "," & _
        JKV("reason", reason) & "," & JKV("system", TARGET_SID) & "," & _
        JKV("tr", TR) & "," & JKV("position", position) & "," & _
        """total_count"":" & total & "," & """rows"":[" & rowsJson & "]}"
    Set o = oFSO.CreateTextFile(OUTPUT_FILE, True, False)
    o.Write j
    o.Close
End Sub

Sub WriteSkipped(reason)
    WriteJson "skipped", reason, "", 0, ""
    WScript.Echo "QUEUE: status=skipped reason=" & reason
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
                oWnd.sendVKey 12   ' F12 = Cancel
                any = True
                WScript.Sleep 250
            End If
            Err.Clear
            On Error GoTo 0
        Next
        If Not any Then Exit Sub
    Next
End Sub

' ---- TMS-down guard helpers -------------------------------------------------
' When the TMS communication layer is broken (TMSADM RFC destination
' unreachable, or its secure-storage logon data missing), STMS_IMPORT renders
' the TMS Alert Viewer (program SAPLTMSU_ALT) with an error popup instead of
' the import queue. Detection uses locale-stable signals only: the popup's
' DDIC field IDs (GS_DYN100-S_ALOG-*) and the program name -- both captured
' live on S/4HANA 2022 (S4H) and ECC (ER1) on 2026-07-11, identical IDs. The
' S_ALOG-ERROR value is a technical exception name (e.g.
' RFC_COMMUNICATION_FAILURE), not translated text.
Function DetectTmsAlert()
    DetectTmsAlert = ""
    Dim sProg, oFld, sAlErr, sAlFunc, sAlDest
    On Error Resume Next
    sProg = "" : sProg = oSession.Info.Program
    sAlErr = "" : sAlFunc = "" : sAlDest = ""
    Set oFld = Nothing
    Set oFld = oSession.findById("wnd[1]/usr/txtGS_DYN100-S_ALOG-ERROR")
    If Err.Number = 0 And Not (oFld Is Nothing) Then sAlErr = oFld.Text
    Err.Clear
    Set oFld = Nothing
    Set oFld = oSession.findById("wnd[1]/usr/txtGS_DYN100-S_ALOG-FUNCTION")
    If Err.Number = 0 And Not (oFld Is Nothing) Then sAlFunc = oFld.Text
    Err.Clear
    Set oFld = Nothing
    Set oFld = oSession.findById("wnd[1]/usr/txtGS_DYN100-MSG_LINE2")
    If Err.Number = 0 And Not (oFld Is Nothing) Then sAlDest = oFld.Text
    Err.Clear
    On Error GoTo 0
    If Len(sAlErr) > 0 Then
        DetectTmsAlert = "alert=" & sAlErr & " function=" & sAlFunc & " destination=" & sAlDest
    ElseIf sProg = "SAPLTMSU_ALT" Then
        DetectTmsAlert = "TMS Alert Viewer (SAPLTMSU_ALT) opened instead of the import queue"
    End If
End Function

' Close the alert popup so the session is not left modal-locked. The popup's
' confirm is Close (tbar[0]/btn[0], Enter); fall back to VKey 0 (Enter).
Sub CloseTmsAlertPopup()
    Dim oBtn
    On Error Resume Next
    Set oBtn = Nothing
    Set oBtn = oSession.findById("wnd[1]/tbar[0]/btn[0]")
    If Err.Number = 0 And Not (oBtn Is Nothing) Then
        oBtn.press
    Else
        Err.Clear
        oSession.findById("wnd[1]").sendVKey 0
    End If
    Err.Clear
    On Error GoTo 0
    WScript.Sleep 400
End Sub
