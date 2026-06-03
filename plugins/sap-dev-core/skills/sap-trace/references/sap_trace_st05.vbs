' =============================================================================
' sap_trace_st05.vbs  -  Display the latest recorded ST05 SQL trace, switch to
' the summarized "Structure-Identical Statements" view, and write the grid as a
' tab-delimited file for /sap-trace analysis.
'
' v1 DISPLAYS an already-recorded trace. It does NOT Activate/Deactivate the
' trace (capture orchestration is a later phase).
'
' Tokens replaced at run time:
'   %%OUTPUT_FILE%%    absolute path of the tab-delimited export
'   %%FILTER_USER%%    user whose trace to display ('' = all)
'   %%FROM_TIME%%      display window start HH:MM:SS ('' = 00:00:00)
'   %%TO_TIME%%        display window end   HH:MM:SS ('' = 23:59:59)
'   %%SESSION_PATH%%   target SAP GUI session ('' = default resolver)
'   %%ATTACH_LIB_VBS%% absolute path to sap_attach_lib.vbs
'
' Control IDs CAPTURED LIVE on S4D / S/4HANA 1909 via /sap-gui-probe
' (2026-06-03). Re-verify per release with /sap-gui-probe if a step fails.
'   ST05 initial screen  : R_ST05_TRACE_MAIN  screen 10
'   Filter/restriction   : R_ST05_TRACE_FILTER screen 1000  -- a FULL wnd[0]
'                          screen, NOT a popup
'   Trace display (list) : SAPLSTMO            screen 201
'   Summarized view      : Trace > Structure-Identical Statements (menu .select)
'
' EXPORT NOTE: the ST05 ALV grid does NOT expose the SE16N-style "&MB_EXPORT"
' toolbar export, so we read the grid directly (ColumnOrder / RowCount /
' GetCellValue) and write the TSV via FSO. This is more robust AND avoids the
' SAP GUI Security modal entirely (no SAP-GUI-side file IO).
'
' Last line: EXPORTED=<path> rows=<n> / TRACE_EMPTY: <reason> / ERROR: <msg>
' =============================================================================

Option Explicit

Const OUTPUT_FILE  = "%%OUTPUT_FILE%%"
Const FILTER_USER  = "%%FILTER_USER%%"
Const FROM_TIME    = "%%FROM_TIME%%"
Const TO_TIME      = "%%TO_TIME%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

' ---- Control IDs (captured on S4D / 1909) -----------------------------------
Const DISPLAY_TRACE_BTN = "wnd[0]/tbar[1]/btn[7]"       ' ST05 main: "Display Trace" (F7)
Const FLT_USER_FIELD    = "wnd[0]/usr/ctxtUSER-LOW"     ' filter screen (full wnd[0])
Const FLT_FROMTIME      = "wnd[0]/usr/ctxtFROMTIME"
Const FLT_TOTIME        = "wnd[0]/usr/ctxtTOTIME"
Const FLT_EXECUTE_BTN   = "wnd[0]/tbar[1]/btn[8]"       ' filter screen: Execute (F8)
Const SUMMARIZE_MENU    = "wnd[0]/mbar/menu[0]/menu[0]" ' Trace > Structure-Identical Statements
Const RESULT_GRID       = "wnd[0]/usr/cntlGUI_CONTROL_CONTAINER/shellcont/shell" ' summarized ALV (GridView)
' ----------------------------------------------------------------------------

' Shared attach helper -- resolves the target session and handles all error
' paths internally (WScript.Echo + Quit).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim oSession, oFSO
Set oFSO = CreateObject("Scripting.FileSystemObject")
Set oSession = AttachSapSession(SESSION_PATH)

oSession.findById("wnd[0]").maximize
DismissModals

' --- open ST05 ---
oSession.findById("wnd[0]/tbar[0]/okcd").text = "/nST05"
oSession.findById("wnd[0]").sendVKey 0
WScript.Sleep 1000

' --- Display Trace -> filter screen ---
If Not PressIfExists(DISPLAY_TRACE_BTN) Then
    WScript.Echo "ERROR: Display Trace button not found (" & DISPLAY_TRACE_BTN & "). " & _
        "Re-probe ST05 for this release with /sap-gui-probe."
    WScript.Quit 1
End If
WScript.Sleep 1200

' --- filter screen (full wnd[0]) : set restrictions ---
On Error Resume Next
If Len(FILTER_USER) > 0 Then oSession.findById(FLT_USER_FIELD).text = FILTER_USER
If Len(FROM_TIME) > 0 Then
    oSession.findById(FLT_FROMTIME).text = FROM_TIME
Else
    oSession.findById(FLT_FROMTIME).text = "00:00:00"
End If
If Len(TO_TIME) > 0 Then
    oSession.findById(FLT_TOTIME).text = TO_TIME
Else
    oSession.findById(FLT_TOTIME).text = "23:59:59"
End If
Err.Clear
On Error GoTo 0

' --- Execute ---
If Not PressIfExists(FLT_EXECUTE_BTN) Then oSession.findById("wnd[0]").sendVKey 8
WScript.Sleep 2000

' --- no-data guard: an info popup (e.g. "Cannot open kernel trace file ...")
'     means there is no readable trace for the selected window. Detect by
'     wnd[1] presence (language-independent), dismiss, and report empty. ---
Dim w1 : Set w1 = Nothing
On Error Resume Next
Set w1 = oSession.findById("wnd[1]")
On Error GoTo 0
If Not (w1 Is Nothing) Then
    On Error Resume Next
    oSession.findById("wnd[1]").sendVKey 0   ' dismiss info popup -> returns to filter
    On Error GoTo 0
    WScript.Echo "TRACE_EMPTY: no readable trace records for the selected window " & _
        "(activate an ST05 SQL trace, run the workload, deactivate, then re-run)."
    WScript.Quit 0
End If

' --- summarize: Trace > Structure-Identical Statements (menu .select) ---
On Error Resume Next
oSession.findById(SUMMARIZE_MENU).select
On Error GoTo 0
WScript.Sleep 1500

' --- locate the summarized ALV grid ---
Dim oGrid : Set oGrid = Nothing
On Error Resume Next
Set oGrid = oSession.findById(RESULT_GRID)
On Error GoTo 0
If oGrid Is Nothing Then
    WScript.Echo "TRACE_EMPTY: summarized grid not present (no rows to aggregate)."
    WScript.Quit 0
End If

' --- write the grid to a TSV (direct read; no ALV export dialog) ---
Dim n : n = WriteGridTsv(oGrid, OUTPUT_FILE)
If Not oFSO.FileExists(OUTPUT_FILE) Then
    WScript.Echo "ERROR: export file not created: " & OUTPUT_FILE
    WScript.Quit 1
End If
If n <= 0 Then
    WScript.Echo "TRACE_EMPTY: summarized grid has no rows"
    WScript.Quit 0
End If
WScript.Echo "EXPORTED=" & OUTPUT_FILE & " rows=" & n
WScript.Quit 0

' ============================ helpers ========================================

Function PressIfExists(byval sId)
    PressIfExists = False
    On Error Resume Next
    Dim o : Set o = Nothing
    Set o = oSession.findById(sId)
    If Err.Number = 0 And Not (o Is Nothing) Then
        o.press
        If Err.Number = 0 Then PressIfExists = True
    End If
    Err.Clear
    On Error GoTo 0
End Function

' Read a GuiShell ALV GridView directly (ColumnOrder / RowCount / GetCellValue)
' and write a tab-delimited file with the column titles as the header row.
' Avoids the ALV "save to local file" dialog and the SAP GUI Security modal.
' Returns the number of data rows written.
' NOTE: reads rows 0..RowCount-1; for very large grids the ALV may lazy-load and
' need scrolling (acceptable for v1 summarized-trace volumes).
Function WriteGridTsv(byval oGrid, byval sOutFile)
    Dim cols, nCols, nRows, c, r, colName, t, titles, k, cand, v, hdr, line, oOut
    WriteGridTsv = 0
    On Error Resume Next
    Set cols = oGrid.ColumnOrder
    nCols = cols.Count
    nRows = oGrid.RowCount
    On Error GoTo 0
    If nCols = 0 Then Exit Function

    ' header line -- best column title (last non-empty wrapped title, else tech name)
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
