' =============================================================================
' sap_gateway_errlog_deep.vbs  -  /sap-gateway-service reader: SAP Gateway error
'                                 log (/IWFND/ERROR_LOG, GUI mode)
'
' /IWFND/SU_ERRLOG is NOT RFC-readable (its RSTR/STRG string columns trip an
' ASSIGN-CASTING dump in SAPLSDTX/SAPLBBPB), so the Gateway error list is read by
' driving /IWFND/ERROR_LOG in the SAP GUI. This reader is READ-ONLY: it opens the
' monitor, optionally widens the selection via the Re-Select popup, and scrapes
' the error-list ALV into a JSON evidence file. The list level yields
' date/time/user/T100-id/service/http-status/error-text per entry.
'
' DEEP mode (DEEP=1): additionally double-clicks each in-scope entry so the
' detail ALV -- which populates IN PLACE on the same screen (no navigation, no
' popup) -- is read into that entry's "detail" array as {tag, value} pairs. Deep
' extraction is strictly additive: an undrillable/missing detail grid degrades to
' an empty detail array and NEVER loses the list-level evidence (all list rows
' are collected up front, before any drill).
'
' Language independence: controls are addressed by component ID + column
' TECHNICAL name only -- no branching on .Text / .Tooltip / window titles. The
' column technical names and control IDs below are locale-stable (captured under
' EN; valid on any logon language).
'
' Grid-not-found is a graceful skip (status=skipped, GRID_NOT_FOUND) -- the
' reader never crashes; it hints to re-record the flow for this release.
'
' Tokens:
'   %%PARAMS_FILE%%    KEY=VALUE lines: FROMDATE=YYYYMMDD TODATE=YYYYMMDD
'                      USER=<bname> SERVICE=<name> TOPN=<n> [DEEP=1]
'   %%OUTPUT_FILE%%    absolute path of the errlog JSON to write
'   %%SESSION_PATH%%   session hint (or empty)
'   %%ATTACH_LIB_VBS%% absolute path to sap_attach_lib.vbs
' =============================================================================
Option Explicit

Const PARAMS_FILE  = "%%PARAMS_FILE%%"
Const OUTPUT_FILE  = "%%OUTPUT_FILE%%"
Const SESSION_PATH = "%%SESSION_PATH%%"

Const VKEY_ENTER  = 0
Const VKEY_F6     = 6
Const VKEY_CANCEL = 12

' Error-list ALV column technical names (locale-stable), in emit order.
Dim COLIDS
COLIDS = Array( _
    "LINENO", "SUBNO", "LOCAL_DATE", "LOCAL_TIME", "USERNAME", "T100_ERROR_ID", _
    "INFO_ICON", "ERROR_COUNT", "ICF_NODE", "REQUEST_KIND_DESCR", "HTTP_STATUS", _
    "BACKEND_ERROR", "ERROR_TEXT", "ERROR_COMPONENT", "NAMESPACE", "SERVICE_NAME", _
    "TRANSACTION_ID", "REQUEST_ID", "REMOTE_ADDRESS", "FIRST_DATE", "FIRST_TIME", _
    "EXPIRY_DATE")

Dim oSession, oFSO, oTS, sLine
Dim sFromDate, sToDate, sUser, sService, nTopN, bDeep
sFromDate = "" : sToDate = "" : sUser = "" : sService = "" : nTopN = 200 : bDeep = False

' scan-fallback state (module-level, used by ScanGrid / WalkGrids)
Dim gWantIdx, gSeen, gFoundGrid
gWantIdx = 0 : gSeen = 0
Set gFoundGrid = Nothing

ExecuteGlobal CreateObject("Scripting.FileSystemObject").OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Set oFSO = CreateObject("Scripting.FileSystemObject")

' ---- read params ----------------------------------------------------------
If oFSO.FileExists(PARAMS_FILE) Then
    Set oTS = oFSO.OpenTextFile(PARAMS_FILE, 1, False, -2)
    Do While Not oTS.AtEndOfStream
        sLine = Trim(oTS.ReadLine)
        If InStr(sLine, "=") > 0 Then
            Dim k, v
            k = UCase(Trim(Left(sLine, InStr(sLine, "=") - 1)))
            v = Trim(Mid(sLine, InStr(sLine, "=") + 1))
            Select Case k
                Case "FROMDATE" : sFromDate = OnlyDigits(v)
                Case "TODATE"   : sToDate   = OnlyDigits(v)
                Case "USER"     : sUser     = v
                Case "SERVICE"  : sService  = v
                Case "TOPN"     : If IsNumeric(v) Then nTopN = CLng(v)
                Case "DEEP"     : bDeep = (v = "1" Or UCase(v) = "TRUE" Or UCase(v) = "YES")
            End Select
        End If
    Loop
    oTS.Close
End If
If nTopN < 1 Then nTopN = 200

Set oSession = AttachSapSession(SESSION_PATH)

' ---- navigate to the Gateway error-log monitor ----------------------------
' okcd /n/IWFND/ERROR_LOG lands DIRECTLY on the monitor (program /IWFND/SUTIL_LOG,
' screen 100) -- there is no selection screen.
On Error Resume Next
oSession.findById("wnd[0]").maximize
DismissModals
oSession.findById("wnd[0]/tbar[0]/okcd").text = "/n/IWFND/ERROR_LOG"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500
DismissModals
On Error GoTo 0

' ---- locate the error-list ALV --------------------------------------------
Dim listGrid
Set listGrid = FindListGrid()

' ---- optional widen: Re-Select popup (screen 200) -------------------------
' The default monitor selection is "today only" and often yields 0 rows. When a
' selection filter is supplied (from-date, to-date, user or service), open the
' Re-Select popup, apply the filter and re-read. The capture named FROMDATE as
' the canonical trigger; user/service/to-date are honoured too so those filters
' are not silently dropped.
Dim bWantFilter, bWidened
bWantFilter = (Len(sFromDate) > 0 Or Len(sToDate) > 0 Or Len(sUser) > 0 Or Len(sService) > 0)
bWidened = False
If bWantFilter Then
    If DoReselect() Then bWidened = True
    Set listGrid = FindListGrid()
End If

' ---- grid-not-found -> graceful skip --------------------------------------
If listGrid Is Nothing Then
    WriteSkipped "error-list ALV not found at known IDs for this release"
    WScript.Echo "STATUS: GRID_NOT_FOUND -- run /sap-gui-probe --record on /IWFND/ERROR_LOG for this release"
    WScript.Quit 0
End If

' ---- Pass 1: read the list rows into a 2D array (BEFORE any drill) ---------
' (Collecting all list evidence up front makes deep extraction strictly
'  additive -- a later drill can never lose a list row.)
Dim rowCount, firstCol, ri, ci, cv
On Error Resume Next
rowCount = -1 : rowCount = listGrid.RowCount
On Error GoTo 0
If rowCount < 0 Then rowCount = 0

' Fallback widen: an empty result plus a filter that was not yet applied (the
' up-front Re-Select attempt failed) -> retry once.
If rowCount = 0 And bWantFilter And Not bWidened Then
    If DoReselect() Then bWidened = True
    Set listGrid = FindListGrid()
    If Not (listGrid Is Nothing) Then
        On Error Resume Next
        rowCount = -1 : rowCount = listGrid.RowCount
        On Error GoTo 0
        If rowCount < 0 Then rowCount = 0
    End If
End If

If listGrid Is Nothing Then
    WriteSkipped "error-list ALV lost after Re-Select for this release"
    WScript.Echo "STATUS: GRID_NOT_FOUND -- run /sap-gui-probe --record on /IWFND/ERROR_LOG for this release"
    WScript.Quit 0
End If

If rowCount > nTopN Then rowCount = nTopN

' first column id for the drill (setCurrentCell needs a valid column)
firstCol = "LINENO"
On Error Resume Next
If Not (listGrid.ColumnOrder Is Nothing) Then
    If listGrid.ColumnOrder.Count > 0 Then firstCol = listGrid.ColumnOrder(0)
End If
On Error GoTo 0

Dim nCols : nCols = UBound(COLIDS) + 1
Dim arrCells(), arrDetail()
If rowCount > 0 Then
    ReDim arrCells(rowCount - 1, nCols - 1)
    ReDim arrDetail(rowCount - 1)
End If

For ri = 0 To rowCount - 1
    For ci = 0 To nCols - 1
        cv = ""
        On Error Resume Next
        cv = listGrid.GetCellValue(ri, COLIDS(ci))
        On Error GoTo 0
        arrCells(ri, ci) = Trim(cv & "")
    Next
    arrDetail(ri) = ""
Next

' ---- Pass 2 (DEEP): drill each entry, read the in-place detail ALV ---------
Dim nDeepCaptured : nDeepCaptured = 0
If bDeep Then
    For ri = 0 To rowCount - 1
        Dim dJson
        dJson = DrillDetail(ri, firstCol)
        arrDetail(ri) = dJson
        If Len(dJson) > 0 Then nDeepCaptured = nDeepCaptured + 1
    Next
End If

' ---- emit JSON ------------------------------------------------------------
Dim jEntries, entry
jEntries = ""
For ri = 0 To rowCount - 1
    entry = "{"
    For ci = 0 To nCols - 1
        If ci > 0 Then entry = entry & ","
        entry = entry & JKV(COLIDS(ci), arrCells(ri, ci))
    Next
    If bDeep Then entry = entry & ",""detail"":[" & arrDetail(ri) & "]"
    entry = entry & "}"
    If jEntries <> "" Then jEntries = jEntries & ","
    jEntries = jEntries & entry
Next

WriteOk jEntries, rowCount
' deep=<d> is the number of entries for which a detail payload was captured (0
' when DEEP was off), mirroring the ST22 reader's deep counter.
WScript.Echo "GWERR: entries=" & rowCount & " deep=" & nDeepCaptured & " file=" & OUTPUT_FILE
WScript.Echo "STATUS: OK"
WScript.Quit 0

' =============================================================================
' Helpers
' =============================================================================

Function DrillDetail(rowIdx, colId)
    ' Double-click the list row so the detail ALV populates in place, then read
    ' it. Best-effort: any failure returns "" (empty detail) and never aborts.
    Dim g, dg
    DrillDetail = ""
    Set g = FindListGrid()
    If g Is Nothing Then Exit Function
    On Error Resume Next
    g.setCurrentCell rowIdx, colId
    g.selectedRows = CStr(rowIdx)
    g.doubleClickCurrentCell
    On Error GoTo 0
    WScript.Sleep 400
    Set dg = FindDetailGrid()
    If dg Is Nothing Then Exit Function
    DrillDetail = ReadDetailGrid(dg)
End Function

Function ReadDetailGrid(dg)
    ' Detail ALV = 3 cols (EXCO_ICON, TAG_NAME, TAG_VALUE); TAG_NAME carries the
    ' tree depth as leading dots. Emit each non-empty row as {tag, value}.
    Dim n, i, tag, val, s
    s = ""
    On Error Resume Next
    n = -1 : n = dg.RowCount
    On Error GoTo 0
    If n < 0 Then ReadDetailGrid = "" : Exit Function
    For i = 0 To n - 1
        tag = "" : val = ""
        On Error Resume Next
        tag = dg.GetCellValue(i, "TAG_NAME")
        val = dg.GetCellValue(i, "TAG_VALUE")
        On Error GoTo 0
        If Len(tag & "") > 0 Or Len(val & "") > 0 Then
            If s <> "" Then s = s & ","
            s = s & "{" & JKV("tag", tag & "") & "," & JKV("value", val & "") & "}"
        End If
    Next
    ReadDetailGrid = s
End Function

Function DoReselect()
    ' Open the Re-Select popup (toolbar btn[6] / F6), apply the supplied filters
    ' by DDIC id, Continue. Fully guarded; returns True when Continue was pressed.
    Dim ok, w1
    ok = False
    On Error Resume Next
    oSession.findById("wnd[0]/tbar[1]/btn[6]").press
    If Err.Number <> 0 Then
        Err.Clear
        oSession.findById("wnd[0]").sendVKey VKEY_F6
    End If
    On Error GoTo 0
    WScript.Sleep 700

    Set w1 = Nothing
    On Error Resume Next
    Set w1 = oSession.findById("wnd[1]")
    On Error GoTo 0
    If w1 Is Nothing Then DoReselect = False : Exit Function

    ' Prefer free selection so the entered fields take effect (best-effort; the
    ' radio is a no-op if already free or absent on this release).
    On Error Resume Next
    oSession.findById("wnd[1]/usr/radRB_FREE").select
    On Error GoTo 0

    ' Dates go in as YYYY.MM.DD (the format captured on the monitor).
    If Len(sFromDate) = 8 Then SetField "wnd[1]/usr/ctxtIP_FDAT", FmtDotDate(sFromDate)
    If Len(sToDate)   = 8 Then SetField "wnd[1]/usr/ctxtIP_TDAT", FmtDotDate(sToDate)
    If Len(sUser)     > 0 Then SetField "wnd[1]/usr/ctxtIP_USER", UCase(sUser)
    If Len(sService)  > 0 Then SetField "wnd[1]/usr/ctxtIP_SERV", UCase(sService)

    On Error Resume Next
    oSession.findById("wnd[1]/tbar[0]/btn[0]").press
    If Err.Number = 0 Then ok = True
    Err.Clear
    On Error GoTo 0
    WScript.Sleep 900
    DismissModals
    DoReselect = ok
End Function

Sub SetField(sId, sVal)
    On Error Resume Next
    oSession.findById(sId).text = sVal
    Err.Clear
    On Error GoTo 0
End Sub

Function FindListGrid()
    Dim cands, g
    cands = Array( _
        "wnd[0]/usr/cntlGUI_AREA/shellcont/shell/shellcont[0]/shell", _
        "wnd[0]/usr/cntlGUI_AREA/shellcont/shell/shellcont[0]/shell/shellcont[0]/shell")
    Set g = FindGridByCandidates(cands)
    If g Is Nothing Then Set g = ScanGrid(0)
    Set FindListGrid = g
End Function

Function FindDetailGrid()
    Dim cands, g
    cands = Array( _
        "wnd[0]/usr/cntlGUI_AREA/shellcont/shell/shellcont[1]/shell")
    Set g = FindGridByCandidates(cands)
    If g Is Nothing Then Set g = ScanGrid(1)
    Set FindDetailGrid = g
End Function

Function FindGridByCandidates(cands)
    Dim id, g, rc
    For Each id In cands
        On Error Resume Next
        Set g = Nothing
        Set g = oSession.findById(id)
        If Err.Number = 0 And Not (g Is Nothing) Then
            rc = -1 : rc = g.RowCount
            If Err.Number = 0 And rc >= 0 Then
                Err.Clear
                On Error GoTo 0
                Set FindGridByCandidates = g
                Exit Function
            End If
        End If
        Err.Clear
        On Error GoTo 0
    Next
    Set FindGridByCandidates = Nothing
End Function

Function ScanGrid(wantIdx)
    ' Fallback: walk wnd[0]/usr, collect GuiShell controls exposing a RowCount
    ' (the ALV grids) in document order, and return the wantIdx-th (0 = list,
    ' 1 = detail -- mirroring shellcont[0] / shellcont[1]).
    Dim root
    gWantIdx = wantIdx : gSeen = 0
    Set gFoundGrid = Nothing
    Set root = Nothing
    On Error Resume Next
    Set root = oSession.findById("wnd[0]/usr")
    On Error GoTo 0
    If Not (root Is Nothing) Then WalkGrids root, 0
    Set ScanGrid = gFoundGrid
End Function

Sub WalkGrids(ctrl, depth)
    If depth > 12 Then Exit Sub
    If Not (gFoundGrid Is Nothing) Then Exit Sub
    Dim ty, rc, kids, i, child
    On Error Resume Next
    ty = "" : ty = ctrl.Type
    If ty = "GuiShell" Then
        rc = -2 : rc = ctrl.RowCount
        If Err.Number = 0 And rc >= 0 Then
            If gSeen = gWantIdx Then Set gFoundGrid = ctrl
            gSeen = gSeen + 1
        End If
        Err.Clear
    End If
    Set kids = Nothing
    Set kids = ctrl.Children
    On Error GoTo 0
    If Not (kids Is Nothing) Then
        For i = 0 To kids.Count - 1
            If Not (gFoundGrid Is Nothing) Then Exit For
            On Error Resume Next
            Set child = Nothing
            Set child = kids(i)
            On Error GoTo 0
            If Not (child Is Nothing) Then WalkGrids child, depth + 1
        Next
    End If
End Sub

Sub DismissModals()
    Dim attempt, idx, oWnd, any
    For attempt = 1 To 4
        any = False
        For idx = 3 To 1 Step -1
            On Error Resume Next
            Set oWnd = Nothing
            Set oWnd = oSession.findById("wnd[" & idx & "]")
            If Err.Number = 0 And Not (oWnd Is Nothing) Then
                Err.Clear
                oWnd.sendVKey VKEY_CANCEL   ' F12 = Cancel
                any = True
                WScript.Sleep 250
            End If
            Err.Clear
            On Error GoTo 0
        Next
        If Not any Then Exit Sub
    Next
End Sub

Function FmtDotDate(s)
    If Len(s) = 8 And IsNumeric(s) Then
        FmtDotDate = Left(s, 4) & "." & Mid(s, 5, 2) & "." & Mid(s, 7, 2)
    Else
        FmtDotDate = s
    End If
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
    t = Replace(t, vbCr, " ")
    t = Replace(t, vbLf, " ")
    t = Replace(t, vbTab, " ")
    JsonEsc = t
End Function

Function JKV(k, v)
    JKV = """" & k & """:""" & JsonEsc(v) & """"
End Function

Sub WriteOk(entriesJson, total)
    Dim j
    j = "{" & JKV("source", "IWFND_ERROR_LOG") & "," & _
        JKV("status", "ok") & "," & _
        """total_count"":" & total & "," & _
        """entries"":[" & entriesJson & "]}"
    WriteFileUtf8 OUTPUT_FILE, j
End Sub

Sub WriteSkipped(reason)
    Dim j
    j = "{" & JKV("source", "IWFND_ERROR_LOG") & "," & _
        JKV("status", "skipped") & "," & _
        JKV("reason", reason) & "," & _
        """entries"":[]}"
    WriteFileUtf8 OUTPUT_FILE, j
End Sub

Sub WriteFileUtf8(sPath, sText)
    ' UTF-8 without BOM (repo convention for VBS-emitted data files, per
    ' sap_log_lib.vbs); falls back to an FSO Unicode write if ADODB.Stream is
    ' unavailable. Either path preserves non-ASCII error text.
    Dim st, bin, okStream
    okStream = False
    On Error Resume Next
    Set st = CreateObject("ADODB.Stream")
    st.Type = 2 : st.Charset = "utf-8" : st.Open
    st.WriteText sText
    st.Position = 3            ' skip the UTF-8 BOM (EF BB BF)
    Set bin = CreateObject("ADODB.Stream")
    bin.Type = 1 : bin.Open
    st.CopyTo bin
    st.Flush : st.Close
    bin.SaveToFile sPath, 2    ' adSaveCreateOverWrite
    bin.Flush : bin.Close
    If Err.Number = 0 Then okStream = True
    Err.Clear
    On Error GoTo 0
    If Not okStream Then
        On Error Resume Next
        Dim o
        Set o = oFSO.CreateTextFile(sPath, True, True)
        o.Write sText : o.Close
        On Error GoTo 0
    End If
End Sub
