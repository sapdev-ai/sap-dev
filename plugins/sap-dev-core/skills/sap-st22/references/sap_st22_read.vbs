' =============================================================================
' sap_st22_read.vbs  -  /sap-diagnose reader: ABAP runtime errors (ST22, GUI mode)
'
' SNAP (the dump store) is a cluster table -- NOT RFC-readable -- so dumps are read
' by driving ST22 in the SAP GUI. This reader is READ-ONLY: it sets the date/user
' selection, displays the dump list, and scrapes the list grid into the shared
' evidence contract (diagnose_evidence_schema.json). Deep per-dump extraction
' (call stack / variables) is a v2 enhancement; the list level already yields
' date/time/user/program/exception/short-text.
'
' Language independence: controls addressed by ID + DDIC field; status via
' MessageType; navigation via okcd + VKey. No branching on translated text.
'
' Component IDs for the ST22 selection screen + result grid vary across releases.
' This reader tries known candidates and then scans for the result grid; if it
' cannot locate the list it emits status=skipped with a hint to run
' /sap-gui-record on ST22 for this release (same policy as /sap-atc).
'
' Tokens:
'   %%PARAMS_FILE%%  tab/line params: FROMDATE=YYYYMMDD TODATE=YYYYMMDD USER=<bname> TOPN=<n>
'   %%OUTPUT_FILE%%  absolute path of the evidence_st22.json to write
'   %%SESSION_PATH%% session hint (or empty)
'   %%ATTACH_LIB_VBS%% absolute path to sap_attach_lib.vbs
' =============================================================================
Option Explicit

Const PARAMS_FILE  = "%%PARAMS_FILE%%"
Const OUTPUT_FILE  = "%%OUTPUT_FILE%%"
Const SESSION_PATH = "%%SESSION_PATH%%"

Const VKEY_ENTER = 0
Const VKEY_F8    = 8

Dim oSession, oFSO, oTS, sLine
Dim sFromDate, sToDate, sUser, nTopN
sFromDate = "" : sToDate = "" : sUser = "" : nTopN = 200

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
    WriteSkipped "ST22 dump-list grid not found at known IDs for this release. Run /sap-gui-record on ST22 and update the candidate IDs in sap_st22_read.vbs."
    WScript.Quit 0
End If

' Read rows into events.
Dim rowCount, cols, jEvents, ri, ci, cId, cVal
Dim sDate, sTime, sUserCol, sProg, sExc, sShort, sHost
On Error Resume Next
rowCount = grid.RowCount
Set cols = grid.ColumnOrder
On Error GoTo 0
If rowCount > nTopN Then rowCount = nTopN

jEvents = ""
Dim cntEmitted : cntEmitted = 0
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
            Case "PROG", "PROGRAM", "RABAX_PROG", "AREPNAME" : sProg = cVal
            Case "EXCEPTION", "FEHLERID", "ERRID", "RABAX_ID", "EXCP" : sExc = cVal
            Case "HOST", "MANDT_HOST", "AHOST"        : sHost = cVal
            Case "SHORTTEXT", "TEXT", "SHORT_TEXT", "ATEXT" : sShort = cVal
        End Select
    Next
    Err.Clear
    On Error GoTo 0

    Dim sTs, sSev, sMsg, sExId
    sTs = ""
    If Len(sDate) >= 8 Then
        sTs = Left(sDate, 8)
        If Len(sTime) >= 6 Then sTs = sTs & Left(sTime, 6) Else sTs = sTs & "000000"
    End If
    sSev = "A"   ' a short dump is an abort-class event
    If Len(sExc) = 0 Then sExc = sShort
    sMsg = sShort
    If Len(sMsg) = 0 Then sMsg = sExc
    sExId = Left(sDate, 8) & Left(sTime & "000000", 6) & sProg   ' synthetic dump_key for explicit linking

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
        JKV("include", "") & "," & _
        JKV("line", "") & "," & _
        """object_keys"":{}," & _
        JKV("msg_id", "") & "," & _
        JKV("msg_no", "") & "," & _
        JKV("msg_text", sMsg) & "," & _
        """tech"":{" & JKV("exception", sExc) & "," & JKV("dump_key", sExId) & "," & JKV("host", sHost) & "}," & _
        JKV("drilldown", "ST22 -> " & sDate & "/" & sTime) & "," & _
        """explicit_links"":[]" & _
        "}"
    cntEmitted = cntEmitted + 1
Next

WriteEvidence "ok", "dumps=" & cntEmitted, jEvents, cntEmitted
WScript.Echo "EVIDENCE: source=ST22 status=ok events=" & cntEmitted & " file=" & OUTPUT_FILE
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
