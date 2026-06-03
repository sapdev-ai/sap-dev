' =============================================================================
' sap_trace_sat.vbs  -  Open an existing SAT (runtime analysis) measurement,
' display its Hit List, and write the grid as a tab-delimited file for /sap-trace.
'
' v1 DISPLAYS an already-saved measurement. It does NOT start a new measurement
' (capture orchestration is a later phase).
'
' Tokens replaced at run time:
'   %%OUTPUT_FILE%%    absolute path of the tab-delimited export
'   %%MEASUREMENT%%    substring to match a measurement row ('' = latest = row 0)
'   %%SESSION_PATH%%   target SAP GUI session ('' = default resolver)
'   %%ATTACH_LIB_VBS%% absolute path to sap_attach_lib.vbs
'
' Control IDs CAPTURED LIVE on S4D / S/4HANA 1909 via /sap-gui-probe
' (2026-06-03). The evaluation-desktop ids embed program/screen names
' (SAPLATRA_TOOL_SE30_AGG_MAIN:0300, ...:0100) that may shift across releases --
' re-probe with /sap-gui-probe if a step fails.
'   SAT main screen      : SAPLS_ABAP_TRACE_DATA screen 100 (tabs Measr./Evaluate)
'   Evaluation desktop   : SAPLATRA_TOOL_SE30_AGG_MAIN  (tab "Hit List")
'
' EXPORT NOTE: reads the Hit List ALV grid directly (ColumnOrder / RowCount /
' GetCellValue) and writes the TSV via FSO -- robust and avoids the SAP GUI
' Security modal (no SAP-GUI-side file IO).
'
' Last line: EXPORTED=<path> rows=<n> / TRACE_EMPTY: <reason> / ERROR: <msg>
' =============================================================================

Option Explicit

Const OUTPUT_FILE  = "%%OUTPUT_FILE%%"
Const MEASUREMENT  = "%%MEASUREMENT%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

' ---- Control IDs (captured on S4D / 1909) -----------------------------------
Const EVAL_TAB    = "wnd[0]/usr/tabsTS_START/tabpLIST"   ' SAT main: "Evaluate" tab
Const MEAS_LIST   = "wnd[0]/usr/tabsTS_START/tabpLIST/ssubLIST_REF1:SAPLS_ABAP_TRACE_DATA:0102/cntlCONTENT_CONTROL/shellcont/shell"
Const HITLIST_TAB = "wnd[0]/usr/ssubTPDAMYMAIN:SAPLATRA_TOOL_SE30_AGG_MAIN:0300/tabsTAB_MAIN/tabpMAIN_TAB_HIT"
Const RESULT_GRID = "wnd[0]/usr/ssubTPDAMYMAIN:SAPLATRA_TOOL_SE30_AGG_MAIN:0300/tabsTAB_MAIN/tabpMAIN_TAB_HIT/ssubFULL:SAPLATRA_TOOL_HITLIST:0100/cntlCONTROL_HIT/shellcont/shell"
' ----------------------------------------------------------------------------

ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim oSession, oFSO
Set oFSO = CreateObject("Scripting.FileSystemObject")
Set oSession = AttachSapSession(SESSION_PATH)

oSession.findById("wnd[0]").maximize
DismissModals

' --- open SAT ---
oSession.findById("wnd[0]/tbar[0]/okcd").text = "/nSAT"
oSession.findById("wnd[0]").sendVKey 0
WScript.Sleep 1200

' --- select the Evaluate tab ---
On Error Resume Next
oSession.findById(EVAL_TAB).select
On Error GoTo 0
WScript.Sleep 1500

' --- read the measurements list ---
Dim mlist : Set mlist = Nothing
On Error Resume Next
Set mlist = oSession.findById(MEAS_LIST)
On Error GoTo 0
If mlist Is Nothing Then
    WScript.Echo "TRACE_EMPTY: SAT measurements list not found (re-probe SAT for this release)."
    WScript.Quit 0
End If

Dim nMeas : nMeas = 0
On Error Resume Next
nMeas = mlist.RowCount
On Error GoTo 0
If nMeas <= 0 Then
    WScript.Echo "TRACE_EMPTY: no saved SAT measurements (run a measurement in SAT first)."
    WScript.Quit 0
End If

' --- pick the target row (latest = 0, or first row matching MEASUREMENT) ---
Dim cols : Set cols = mlist.ColumnOrder
Dim targetRow : targetRow = 0
If Len(MEASUREMENT) > 0 Then
    Dim rr, cc, hit : hit = -1
    For rr = 0 To nMeas - 1
        For cc = 0 To cols.Count - 1
            On Error Resume Next
            If InStr(1, mlist.GetCellValue(rr, cols.ElementAt(cc)), MEASUREMENT, 1) > 0 Then hit = rr
            On Error GoTo 0
            If hit >= 0 Then Exit For
        Next
        If hit >= 0 Then Exit For
    Next
    If hit >= 0 Then targetRow = hit
End If

' --- open the measurement (double-click) ---
On Error Resume Next
mlist.setCurrentCell targetRow, cols.ElementAt(0)
mlist.doubleClickCurrentCell
On Error GoTo 0
WScript.Sleep 2500

' --- select the Hit List tab in the evaluation desktop ---
On Error Resume Next
oSession.findById(HITLIST_TAB).select
On Error GoTo 0
WScript.Sleep 1500

' --- locate the Hit List grid ---
Dim oGrid : Set oGrid = Nothing
On Error Resume Next
Set oGrid = oSession.findById(RESULT_GRID)
On Error GoTo 0
If oGrid Is Nothing Then
    WScript.Echo "TRACE_EMPTY: Hit List grid not present (evaluation-desktop ids may differ on this release)."
    WScript.Quit 0
End If

' --- write the grid to a TSV (direct read; no ALV export dialog) ---
Dim n : n = WriteGridTsv(oGrid, OUTPUT_FILE)
If Not oFSO.FileExists(OUTPUT_FILE) Then
    WScript.Echo "ERROR: export file not created: " & OUTPUT_FILE
    WScript.Quit 1
End If
If n <= 0 Then
    WScript.Echo "TRACE_EMPTY: Hit List grid has no rows"
    WScript.Quit 0
End If
WScript.Echo "EXPORTED=" & OUTPUT_FILE & " rows=" & n
WScript.Quit 0

' ============================ helpers ========================================

' Read a GuiShell ALV GridView directly and write a tab-delimited file with the
' column titles as the header row. Returns the number of data rows written.
Function WriteGridTsv(byval oGrid, byval sOutFile)
    Dim cols, nCols, nRows, c, r, colName, t, titles, k, cand, v, hdr, line, oOut
    WriteGridTsv = 0
    On Error Resume Next
    Set cols = oGrid.ColumnOrder
    nCols = cols.Count
    nRows = oGrid.RowCount
    On Error GoTo 0
    If nCols = 0 Then Exit Function

    hdr = ""
    For c = 0 To nCols - 1
        colName = cols.ElementAt(c)
        t = colName
        On Error Resume Next
        Set titles = oGrid.GetColumnTitles(colName)
        If Not (titles Is Nothing) Then
            For k = titles.Count - 1 To 0 Step -1
                cand = titles.ElementAt(k)
                If Len(Trim(cand)) > 0 Then t = cand : Exit For
            Next
        End If
        Err.Clear
        On Error GoTo 0
        If c > 0 Then hdr = hdr & vbTab
        hdr = hdr & Replace(t, vbTab, " ")
    Next

    Set oOut = oFSO.CreateTextFile(sOutFile, True, True)   ' overwrite, Unicode
    oOut.WriteLine hdr
    For r = 0 To nRows - 1
        line = ""
        For c = 0 To nCols - 1
            colName = cols.ElementAt(c)
            v = ""
            On Error Resume Next
            v = oGrid.GetCellValue(r, colName)
            Err.Clear
            On Error GoTo 0
            If c > 0 Then line = line & vbTab
            line = line & Replace(Replace(Replace(v, vbTab, " "), vbCr, " "), vbLf, " ")
        Next
        oOut.WriteLine line
    Next
    oOut.Close
    WriteGridTsv = nRows
End Function

Sub DismissModals
    Dim attempt, idx, oWnd, oCancelBtn
    For attempt = 1 To 5
        Dim anyDismissed : anyDismissed = False
        For idx = 5 To 1 Step -1
            On Error Resume Next
            Set oWnd = Nothing
            Set oWnd = oSession.findById("wnd[" & idx & "]")
            If Err.Number = 0 And Not (oWnd Is Nothing) Then
                Err.Clear
                Set oCancelBtn = Nothing
                Set oCancelBtn = oSession.findById("wnd[" & idx & "]/usr/btnSPOP-OPTION2")
                If Err.Number = 0 And Not (oCancelBtn Is Nothing) Then
                    Err.Clear
                    oCancelBtn.press
                Else
                    Err.Clear
                    oWnd.sendVKey 12
                End If
                anyDismissed = True
                WScript.Sleep 300
            End If
            Err.Clear
            On Error GoTo 0
        Next
        If Not anyDismissed Then Exit Sub
    Next
End Sub
