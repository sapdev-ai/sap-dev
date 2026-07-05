' =============================================================================
' sap_st22_read.vbs  -  /sap-diagnose reader: ABAP runtime errors (ST22, GUI mode)
'
' SNAP (the dump store) is a cluster table -- NOT RFC-readable -- so dumps are read
' by driving ST22 in the SAP GUI. This reader is READ-ONLY: it sets the date/user
' selection, displays the dump list, and scrapes the list grid into the shared
' evidence contract (diagnose_evidence_schema.json). The list level yields
' date/time/user/program/exception/short-text.
'
' DEEP mode (DEEP=1): additionally opens each in-scope dump and scrapes the
' failing source line + snippet from the detail screen into the event's
' include/line fields and a dump_detail object. Strictly additive -- every deep
' failure degrades to dump_detail.detail_status = partial|skipped and never loses
' the list-level evidence. The error line is anchored on the locale-independent
' ">>>>" marker, so no branching on a translated section header. Call-stack and
' chosen-variables parsing are a follow-up (left empty in this v1 deep).
'
' Language independence: controls addressed by ID + DDIC field; status via
' MessageType; navigation via okcd + VKey. No branching on translated text.
'
' Component IDs for the ST22 selection screen + result grid + the dump detail
' view vary across releases. This reader tries known candidates and then scans
' for the result grid / detail text controls; if it cannot locate the list it
' emits status=skipped with a hint to run /sap-gui-probe --record on ST22 for this
' release (same policy as /sap-atc). The detail scrape relies on the dump body
' being a GuiTextedit control; releases that render the dump as an HTML viewer
' yield detail_status=partial until the detail container ID is recorded.
'
' Tokens:
'   %%PARAMS_FILE%%  line params: FROMDATE=YYYYMMDD TODATE=YYYYMMDD USER=<bname>
'                    TOPN=<n> [DEEP=1] [DUMPKEY=<key>] [MAXDEEP=<n>]
'   %%OUTPUT_FILE%%  absolute path of the evidence_st22.json to write
'   %%SESSION_PATH%% session hint (or empty)
'   %%ATTACH_LIB_VBS%% absolute path to sap_attach_lib.vbs
' =============================================================================
Option Explicit

Const PARAMS_FILE  = "%%PARAMS_FILE%%"
Const OUTPUT_FILE  = "%%OUTPUT_FILE%%"
Const SESSION_PATH = "%%SESSION_PATH%%"

Const VKEY_ENTER = 0
Const VKEY_F3    = 3
Const VKEY_F8    = 8

Dim oSession, oFSO, oTS, sLine
Dim sFromDate, sToDate, sUser, nTopN
Dim bDeep, sDumpKey, nMaxDeep
sFromDate = "" : sToDate = "" : sUser = "" : nTopN = 200
bDeep = False : sDumpKey = "" : nMaxDeep = 5

ExecuteGlobal CreateObject("Scripting.FileSystemObject").OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Set oFSO = CreateObject("Scripting.FileSystemObject")

' ---- read params ---------------------------------------------------------
If oFSO.FileExists(PARAMS_FILE) Then
    Set oTS = oFSO.OpenTextFile(PARAMS_FILE, 1, False, -2)
    Do While Not oTS.AtEndOfStream
        sLine = Trim(oTS.ReadLine)
        If InStr(sLine, "=") > 0 Then
            Dim k, v : k = UCase(Trim(Left(sLine, InStr(sLine, "=") - 1))) : v = Trim(Mid(sLine, InStr(sLine, "=") + 1))
            Select Case k
                Case "FROMDATE" : sFromDate = v
                Case "TODATE"   : sToDate = v
                Case "USER"     : sUser = v
                Case "TOPN"     : If IsNumeric(v) Then nTopN = CLng(v)
                Case "DEEP"     : bDeep = (v = "1" Or UCase(v) = "TRUE" Or UCase(v) = "YES")
                Case "DUMPKEY"  : sDumpKey = v
                Case "MAXDEEP"  : If IsNumeric(v) Then nMaxDeep = CLng(v)
            End Select
        End If
    Loop
    oTS.Close
End If

Set oSession = AttachSapSession(SESSION_PATH)

' ---- navigate to ST22 ----------------------------------------------------
On Error Resume Next
oSession.findById("wnd[0]").maximize
DismissModals
oSession.findById("wnd[0]/tbar[0]/okcd").text = "/nST22"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1200
On Error GoTo 0

' ---- set selection (best-effort, candidate IDs) --------------------------
' ST22 selection-screen field IDs differ across releases; try candidates.
Dim dateLowIds, dateHighIds, userIds, p
dateLowIds  = Array("wnd[0]/usr/ctxtRST22_SUBMIT-FROMDATE", "wnd[0]/usr/ctxtDATE_LOW", "wnd[0]/usr/ctxt%_DATUM_LOW")
dateHighIds = Array("wnd[0]/usr/ctxtRST22_SUBMIT-TODATE",   "wnd[0]/usr/ctxtDATE_HIGH","wnd[0]/usr/ctxt%_DATUM_HIGH")
userIds     = Array("wnd[0]/usr/ctxtRST22_SUBMIT-UNAME",    "wnd[0]/usr/ctxtUSER",     "wnd[0]/usr/ctxtUNAME")

If Len(sFromDate) = 8 Then SetFirst dateLowIds, FmtDate(sFromDate)
If Len(sToDate)   = 8 Then SetFirst dateHighIds, FmtDate(sToDate)
If Len(sUser)     > 0 Then SetFirst userIds, sUser

' Execute / display the dump list (F8).
On Error Resume Next
oSession.findById("wnd[0]").sendVKey VKEY_F8
WScript.Sleep 1500
DismissModals
On Error GoTo 0

' ---- locate + read the result grid ---------------------------------------
Dim grid
Set grid = FindGridShell()

If grid Is Nothing Then
    WriteSkipped "ST22 dump-list grid not found at known IDs for this release. Run /sap-gui-probe --record on ST22 and update the candidate IDs in sap_st22_read.vbs."
    WScript.Quit 0
End If

' ---- Pass 1: read the list rows into arrays --------------------------------
' (Collect BEFORE any deep open. Opening a dump navigates away and invalidates
'  the grid reference, so all list-level data is captured up front; deep
'  extraction is then strictly additive and can never lose v1 evidence.)
Dim rowCount, cols, jEvents, ri, ci, cId, cVal
Dim sDate, sTime, sUserCol, sProg, sExc, sShort, sHost
On Error Resume Next
rowCount = grid.RowCount
Set cols = grid.ColumnOrder
On Error GoTo 0
If rowCount > nTopN Then rowCount = nTopN
If rowCount < 0 Then rowCount = 0

Dim arrDate(), arrTime(), arrUser(), arrProg(), arrExc(), arrShort(), arrHost()
If rowCount > 0 Then
    ReDim arrDate(rowCount - 1)  : ReDim arrTime(rowCount - 1) : ReDim arrUser(rowCount - 1)
    ReDim arrProg(rowCount - 1)  : ReDim arrExc(rowCount - 1)  : ReDim arrShort(rowCount - 1)
    ReDim arrHost(rowCount - 1)
End If

For ri = 0 To rowCount - 1
    sDate = "" : sTime = "" : sUserCol = "" : sProg = "" : sExc = "" : sShort = "" : sHost = ""
    On Error Resume Next
    For ci = 0 To cols.Count - 1
        cId = cols(ci)
        cVal = Trim(grid.GetCellValue(ri, cId))
        Select Case UCase(cId)
            Case "DATUM", "DATE", "ADATUM"            : sDate = OnlyDigits(cVal)
            Case "UZEIT", "TIME", "AUZEIT", "ATIME"   : sTime = OnlyDigits(cVal)
            Case "UNAME", "USER", "BNAME"             : sUserCol = cVal
            Case "PROG", "PROGRAM", "RABAX_PROG", "AREPNAME", "GPROGRAM" : sProg = cVal
            Case "ERRORID", "EXCEPTION", "FEHLERID", "ERRID", "RABAX_ID", "EXCP" : If Len(sExc) = 0 Then sExc = cVal
            Case "HOST", "MANDT_HOST", "AHOST"        : sHost = cVal
            Case "SHORTTEXT", "TEXT", "SHORT_TEXT", "ATEXT" : sShort = cVal
        End Select
    Next
    Err.Clear
    On Error GoTo 0
    arrDate(ri) = sDate : arrTime(ri) = sTime : arrUser(ri) = sUserCol
    arrProg(ri) = sProg : arrExc(ri) = sExc   : arrShort(ri) = sShort : arrHost(ri) = sHost
Next

' ---- Pass 2: build evidence events (+ optional deep per-dump detail) --------
Dim sTs, sSev, sMsg, sExId, sExc2
Dim sInclude, sLineNo, jDetail
jEvents = ""
Dim cntEmitted : cntEmitted = 0
Dim deepCount  : deepCount = 0
For ri = 0 To rowCount - 1
    sDate = arrDate(ri) : sTime = arrTime(ri) : sUserCol = arrUser(ri)
    sProg = arrProg(ri) : sExc = arrExc(ri)   : sShort = arrShort(ri) : sHost = arrHost(ri)

    sTs = ""
    If Len(sDate) >= 8 Then
        sTs = Left(sDate, 8)
        If Len(sTime) >= 6 Then sTs = sTs & Left(sTime, 6) Else sTs = sTs & "000000"
    End If
    sSev = "A"   ' a short dump is an abort-class event
    sExc2 = sExc
    If Len(sExc2) = 0 Then sExc2 = sShort
    sMsg = sShort
    If Len(sMsg) = 0 Then sMsg = sExc2
    sExId = Left(sDate, 8) & Left(sTime & "000000", 6) & sProg   ' synthetic dump_key for explicit linking

    ' Optional deep extraction: open the dump, scrape failing line / snippet /
    ' stack, fill include+line; bounded by nMaxDeep and scoped by sDumpKey.
    sInclude = "" : sLineNo = "" : jDetail = ""
    If bDeep Then
        If (Len(sDumpKey) = 0 Or sDumpKey = sExId) And deepCount < nMaxDeep Then
            jDetail = ScrapeDumpDetail(ri, sExc2, sProg, sInclude, sLineNo)
            deepCount = deepCount + 1
        End If
    End If

    If jEvents <> "" Then jEvents = jEvents & ","
    jEvents = jEvents & "{" & _
        JKV("id", "ST22-" & (cntEmitted + 1)) & "," & _
        JKV("source", "ST22") & "," & _
        JKV("ts", sTs) & "," & _
        JKV("severity", sSev) & "," & _
        JKV("client", "") & "," & _
        JKV("user", sUserCol) & "," & _
        JKV("tcode", "") & "," & _
        JKV("program", sProg) & "," & _
        JKV("include", sInclude) & "," & _
        JKV("line", sLineNo) & "," & _
        """object_keys"":{}," & _
        JKV("msg_id", "") & "," & _
        JKV("msg_no", "") & "," & _
        JKV("msg_text", sMsg) & "," & _
        """tech"":{" & JKV("exception", sExc2) & "," & JKV("dump_key", sExId) & "," & JKV("host", sHost) & "}," & _
        IIfStr(Len(jDetail) > 0, """dump_detail"":" & jDetail & ",", "") & _
        JKV("drilldown", "ST22 -> " & sDate & "/" & sTime) & "," & _
        """explicit_links"":[]" & _
        "}"
    cntEmitted = cntEmitted + 1
Next

Dim sReason : sReason = "dumps=" & cntEmitted
If bDeep Then sReason = sReason & " deep=" & deepCount
WriteEvidence "ok", sReason, jEvents, cntEmitted
WScript.Echo "EVIDENCE: source=ST22 status=ok events=" & cntEmitted & " deep=" & deepCount & " file=" & OUTPUT_FILE
WScript.Quit 0

' =============================================================================
' Helpers
' =============================================================================
Function FmtDate(s)  ' YYYYMMDD -> internal date field accepts YYYYMMDD on most installs
    FmtDate = s
End Function

Sub SetFirst(ids, val)
    Dim id
    For Each id In ids
        On Error Resume Next
        oSession.findById(id).text = val
        If Err.Number = 0 Then Err.Clear : On Error GoTo 0 : Exit Sub
        Err.Clear
        On Error GoTo 0
    Next
End Sub

Function FindGridShell()
    Dim cand, id, g
    cand = Array( _
        "wnd[0]/usr/cntlRSSHOWRABAX_ALV_100/shellcont/shell", _
        "wnd[0]/usr/cntlGRID1/shellcont/shell", _
        "wnd[0]/usr/cntlALV_CONTAINER/shellcont/shell", _
        "wnd[0]/usr/cntlCONTAINER/shellcont/shell", _
        "wnd[0]/usr/cntlGRID/shellcont/shell")
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

Sub WriteEvidence(status, reason, eventsJson, total)
    Dim o, j
    j = "{" & JKV("source", "ST22") & "," & JKV("status", status) & "," & JKV("reason", reason) & "," & _
        """truncated"":false," & """total_count"":" & total & "," & """events"":[" & eventsJson & "]}"
    Set o = oFSO.CreateTextFile(OUTPUT_FILE, True, False)
    o.Write j
    o.Close
End Sub

Sub WriteSkipped(reason)
    WriteEvidence "skipped", reason, "", 0
    WScript.Echo "EVIDENCE: source=ST22 status=skipped reason=" & reason
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

' =============================================================================
' Deep per-dump extraction (--deep)
'
' Opens one dump from the list, scrapes the failing source line + snippet from
' the detail screen, fills include/line, then returns to the list. Strictly
' best-effort: every failure path degrades to detail_status = partial|skipped
' and NEVER aborts the run, so the list-level evidence is always preserved.
'
' detail_status contract:
'   ok      - failing line and/or source snippet captured
'   partial - dump opened but the body was not scrapeable (typically an
'             HTML-rendered dump -> no GuiTextedit text to read). The
'             exception / program are still known from the list level.
'   skipped - could not even re-locate the list grid to open the dump.
'
' The error source line is anchored on the locale-independent ">>>>" marker
' that ABAP stamps on the failing statement in the Source Code Extract, so the
' parser does not branch on any translated section header.
' =============================================================================

Function IIfStr(cond, a, b)
    If cond Then IIfStr = a Else IIfStr = b
End Function

Function ScrapeDumpDetail(rowIdx, rowExc, rowProg, ByRef outInclude, ByRef outLine)
    Dim g2, firstCol, detailText, detStatus, jSrc, jStack, jVars, excClass, shortTxt
    outInclude = "" : outLine = ""
    detStatus = "skipped" : detailText = "" : jSrc = "" : jStack = "" : jVars = ""
    excClass = rowExc : shortTxt = ""

    ' (re)locate the list grid -- it was invalidated by the previous deep open
    On Error Resume Next
    Set g2 = Nothing
    Set g2 = FindGridShell()
    On Error GoTo 0
    If g2 Is Nothing Then
        ScrapeDumpDetail = DetailJson("skipped", excClass, "", "", "", "", "", "")
        Exit Function
    End If

    ' open the dump (double-click the row)
    On Error Resume Next
    firstCol = ""
    If Not (g2.ColumnOrder Is Nothing) Then
        If g2.ColumnOrder.Count > 0 Then firstCol = g2.ColumnOrder(0)
    End If
    g2.setCurrentCell rowIdx, firstCol
    g2.doubleClickCurrentCell
    WScript.Sleep 1200
    DismissModals
    On Error GoTo 0

    ' read whatever text the detail screen exposes (GuiTextedit controls)
    detailText = ReadDetailText()

    If Len(detailText) > 0 Then
        ParseDumpText detailText, rowProg, outInclude, outLine, jSrc, jStack, shortTxt
        If Len(outLine) > 0 Or Len(jSrc) > 0 Or Len(outInclude) > 0 Then
            detStatus = "ok"
        Else
            detStatus = "partial"
        End If
    Else
        ' dump opened but body not scrapeable (typically an HTML-rendered dump)
        detStatus = "partial"
    End If

    ' return to the dump list
    On Error Resume Next
    oSession.findById("wnd[0]").sendVKey VKEY_F3
    WScript.Sleep 800
    DismissModals
    On Error GoTo 0

    ScrapeDumpDetail = DetailJson(detStatus, excClass, shortTxt, outInclude, outLine, jSrc, jStack, jVars)
End Function

Function DetailJson(status, excClass, shortTxt, inc, ln, jSrc, jStack, jVars)
    DetailJson = "{" & _
        JKV("detail_status", status) & "," & _
        JKV("exception_class", excClass) & "," & _
        JKV("short_text", shortTxt) & "," & _
        JKV("failing_include", inc) & "," & _
        JKV("failing_line", ln) & "," & _
        """source_extract"":[" & jSrc & "]," & _
        """call_stack"":[" & jStack & "]," & _
        """chosen_variables"":[" & jVars & "]" & _
        "}"
End Function

' Walk wnd[0]/usr and accumulate the text of every GuiTextedit control. Returns
' "" when the body is an HTML viewer (no readable text control) -> partial.
Function ReadDetailText()
    Dim root, acc
    acc = ""
    On Error Resume Next
    Set root = Nothing
    Set root = oSession.findById("wnd[0]/usr")
    On Error GoTo 0
    If Not (root Is Nothing) Then CollectTextedit root, acc, 0
    ReadDetailText = acc
End Function

Sub CollectTextedit(ctrl, ByRef acc, depth)
    If depth > 8 Then Exit Sub
    Dim kids, i, child, t, ty
    On Error Resume Next
    ty = "" : ty = ctrl.Type
    If ty = "GuiTextedit" Then
        t = "" : t = ctrl.text
        If Len(t) > 0 Then acc = acc & t & vbLf
    End If
    Set kids = Nothing
    Set kids = ctrl.Children
    On Error GoTo 0
    If Not (kids Is Nothing) Then
        For i = 0 To kids.Count - 1
            On Error Resume Next
            Set child = Nothing
            Set child = kids(i)
            On Error GoTo 0
            If Not (child Is Nothing) Then CollectTextedit child, acc, depth + 1
        Next
    End If
End Sub

' Parse the scraped dump body. Anchors on the ">>>>" error marker (locale-
' independent); builds a source_extract window around it and sets the failing
' line. include is best-effort (falls back to the dumping program).
Sub ParseDumpText(txt, rowProg, ByRef outInclude, ByRef outLine, ByRef jSrc, ByRef jStack, ByRef shortTxt)
    Dim lines, i, ln, markerIdx, lo, hi, firstNum, srcText, isErr
    txt = Replace(txt, vbCr, vbLf)
    lines = Split(txt, vbLf)

    markerIdx = -1
    For i = 0 To UBound(lines)
        If InStr(lines(i), ">>>>") > 0 Then markerIdx = i : Exit For
    Next

    ' short text = first non-empty scraped line (best-effort dump title)
    For i = 0 To UBound(lines)
        If Len(Trim(lines(i))) > 0 Then shortTxt = Trim(lines(i)) : Exit For
    Next

    If markerIdx = -1 Then Exit Sub   ' no error-line marker in the scraped text

    lo = markerIdx - 6 : If lo < 0 Then lo = 0
    hi = markerIdx + 6 : If hi > UBound(lines) Then hi = UBound(lines)

    jSrc = ""
    For i = lo To hi
        ln = lines(i)
        isErr = (InStr(ln, ">>>>") > 0)
        firstNum = FirstIntToken(ln)
        If Len(firstNum) > 0 Then
            srcText = StripToSource(ln, firstNum)
            If jSrc <> "" Then jSrc = jSrc & ","
            jSrc = jSrc & "{" & JKV("line", firstNum) & "," & JKV("text", srcText) & "," & _
                   """is_error"":" & LCase(CStr(isErr)) & "}"
            If isErr Then outLine = firstNum
        End If
    Next

    If Len(outInclude) = 0 And Len(outLine) > 0 Then outInclude = rowProg
    jStack = ""   ' call-stack parsing is a follow-up; left empty in v1 deep
End Sub

Function FirstIntToken(s)
    Dim i, c, started, o : o = "" : started = False
    For i = 1 To Len(s)
        c = Mid(s, i, 1)
        If c >= "0" And c <= "9" Then
            o = o & c : started = True
        ElseIf started Then
            Exit For
        End If
    Next
    FirstIntToken = o
End Function

Function StripToSource(ln, numTok)
    Dim p : p = InStr(ln, numTok)
    If p > 0 Then
        StripToSource = Trim(Mid(ln, p + Len(numTok)))
    Else
        StripToSource = Trim(ln)
    End If
End Function
