' =============================================================================
' sap_atc_drill_findings.vbs  -  Stage 4b: Drill into an ATC run-series row,
'                                          enumerate per-finding details,
'                                          and export as TSV.
'
' Why this exists:
'   /sap-atc Stage 4 (sap_atc_get_results.vbs) reads aggregated P1/P2/P3
'   counts from the OUTER Manage Results grid (Program=SAPLSATC_AC_UI_ADMIN_I
'   ScreenNumber=100). When the gate FAILS, the operator still doesn't know
'   WHICH finding(s) blocked them — the check ID, source line, and message
'   text live one screen deeper, behind a doubleClick on the run-series row.
'   This script drills there and exports the findings grid as TSV.
'
' Drives /nATC, navigates to tree node "14" (Manage Results), filters by
' RUN_SERIES_NAME, doubleClicks the row to reach screen 201
' (SAPLSATC_AC__UI_RESULT_DISPL), reads the findings ALV grid, and writes
' one row per finding to OUTPUT_PATH.
'
' Tokens:
'   %%RUN_SERIES_NAME%%   The series name from Stage 2.
'   %%OUTPUT_PATH%%       Absolute path for the saved findings TSV, e.g.
'                          C:\Temp\ATC_R_260511_092755.findings.tsv. Parent
'                          dir must exist.
'   %%SESSION_LOCK_VBS%%  Path to sap_session_lock.vbs.
'
' Per-stage VBS references for the screen 201 ALV grid were observed on
' S/4HANA 1909 (sap-dev test build 2026-05-11). If the grid layout differs
' on your release, re-record via /sap-gui-record on the same screen.
'
' Column-ID lookup
' ----------------
' Logical → technical column names vary by SAP_BASIS release. The script
' resolves each logical column via GridView.ColumnOrder membership (the
' authoritative list of column technical names on the shell), NOT by
' probing GetCellValue — SAP's GridView silently returns "" for any
' unknown column name without raising, which made the prior probe-based
' approach lock in the first candidate and produce rows of empty cells.
'
' S/4HANA 1909 actuals (confirmed 2026-05-11): PRIORITY / CHECK_TITLE /
' MESSAGE_TITLE / OBJ_NAME / OBJ_TYPE. There is NO line-number column on
' the outer findings grid in 1909 — source line lives one drill deeper.
' The TSV emits a LINE column for forward-compat with releases that DO
' expose it; on 1909 it is always blank.
'
' Output (last lines, parseable):
'   FINDING_COUNT: <n>
'   FILE: <absolute path>          (only when TSV write succeeded)
'   SUCCESS: Drilled findings for run series <NAME>.
'   ERROR: ...
' =============================================================================

Option Explicit

Const RUN_SERIES_NAME = "%%RUN_SERIES_NAME%%"
Const OUTPUT_PATH     = "%%OUTPUT_PATH%%"
Const SESSION_PATH    = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER = 0
Const VKEY_F3    = 3
Const VKEY_F8    = 8

' Include shared helpers (attach first; session-lock's pre-unlock sweep
' reads from oSession).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

' ------ Attach to existing SAP GUI session (via shared attach helper) -------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)

' --- /nATC + tree node 14 + advance to Manage Results grid (screen 100) ---
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nATC"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500

On Error Resume Next
Dim oTree : Set oTree = oSess.findById("wnd[0]/shellcont/shell/shellcont[1]/shell")
oTree.topNode = "          1"
oTree.selectItem "         14", "&Hierarchy"
oTree.ensureVisibleHorizontalItem "         14", "&Hierarchy"
oTree.doubleClickItem "         14", "&Hierarchy"
WScript.Sleep 2000
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not navigate ATC tree to Manage Results (node 14): " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' Selection screen → grid (same pattern as sap_atc_get_results.vbs)
On Error Resume Next
Dim sScrNum : sScrNum = CStr(oSess.Info.ScreenNumber)
On Error GoTo 0
If sScrNum = "1000" Then
    On Error Resume Next
    oSess.findById("wnd[0]/usr/ctxtS_RUNSR-LOW").Text = UCase(RUN_SERIES_NAME)
    Err.Clear
    Dim sToday : sToday = Year(Date) & "." & Right("0" & Month(Date), 2) & "." & Right("0" & Day(Date), 2)
    oSess.findById("wnd[0]/usr/ctxtS_SDLON-HIGH").Text = sToday
    Err.Clear
    oSess.findById("wnd[0]").sendVKey VKEY_F8
    WScript.Sleep 2000
    On Error GoTo 0
End If

' --- Locate the run-series row on the outer grid -------------------------
On Error Resume Next
Dim oOuter : Set oOuter = oSess.findById("wnd[0]/usr/shell/shellcont/shell")
On Error GoTo 0

If oOuter Is Nothing Then
    WScript.Echo "ERROR: Outer Manage Results grid not found at wnd[0]/usr/shell/shellcont/shell."
    WScript.Quit 1
End If

Dim totalRows : totalRows = 0
On Error Resume Next
totalRows = oOuter.RowCount
On Error GoTo 0

Dim seriesCols : seriesCols = Array("RUN_SERIES_NAME", "RUN_SERIES", "NAME", "SERIE_NAME")
Dim r, sRowName, foundRow, sCol
foundRow = -1
For r = 0 To totalRows - 1
    For Each sCol In seriesCols
        sRowName = ""
        On Error Resume Next
        sRowName = UCase(Trim(oOuter.GetCellValue(r, sCol)))
        On Error GoTo 0
        If sRowName = UCase(Trim(RUN_SERIES_NAME)) Then
            foundRow = r
            Exit For
        End If
    Next
    If foundRow >= 0 Then Exit For
Next

If foundRow < 0 Then
    WScript.Echo "ERROR: Run series " & UCase(RUN_SERIES_NAME) & " not found in Manage Results grid (" & totalRows & " rows scanned)."
    WScript.Quit 1
End If

WScript.Echo "INFO: Outer row " & foundRow & " for series " & UCase(RUN_SERIES_NAME) & " — drilling in."

' --- Drill: doubleClick on the run-series cell -> screen 201 -----------
Dim wasLocked : wasLocked = TryLockSession(oSess)

On Error Resume Next
oOuter.setCurrentCell foundRow, "RUN_SERIES_NAME"
oOuter.selectedRows = CStr(foundRow)
WScript.Sleep 300
oOuter.doubleClickCurrentCell
WScript.Sleep 3000
Err.Clear
On Error GoTo 0

' Confirm we reached the result-display screen.
Dim sDrillScr, sDrillPgm
On Error Resume Next
sDrillScr = CStr(oSess.Info.ScreenNumber)
sDrillPgm = oSess.Info.Program
On Error GoTo 0
WScript.Echo "INFO: After drill: Program=" & sDrillPgm & " Screen=" & sDrillScr

' --- Locate findings grid on screen 201 --------------------------------
' Observed on S/4HANA 1909:
'   wnd[0]/usr/cntlQUICK_FILTER_01_DISPLAY/shell/shellcont[0]/shell
' Older builds may flatten to wnd[0]/usr/shell/shellcont/shell.
' Walk a fallback list.
Dim findingPaths : findingPaths = Array( _
    "wnd[0]/usr/cntlQUICK_FILTER_01_DISPLAY/shell/shellcont[0]/shell", _
    "wnd[0]/usr/cntlQUICK_FILTER_01_DISPLAY/shell/shellcont[1]/shell", _
    "wnd[0]/usr/shell/shellcont/shell", _
    "wnd[0]/usr/cntlGRID1/shellcont/shell", _
    "wnd[0]/shellcont/shell/shellcont[0]/shell")

Dim oFindings : Set oFindings = Nothing
Dim p, pi
For pi = 0 To UBound(findingPaths)
    p = findingPaths(pi)
    On Error Resume Next
    Set oFindings = Nothing
    Set oFindings = oSess.findById(p)
    If Err.Number = 0 And Not (oFindings Is Nothing) Then
        WScript.Echo "INFO: Findings grid located at " & p
        Exit For
    End If
    Err.Clear
    On Error GoTo 0
Next

If oFindings Is Nothing Then
    ReleaseSession oSess, wasLocked
    WScript.Echo "ERROR: Could not locate findings ALV grid after drill-in."
    WScript.Echo "       Tried: " & Join(findingPaths, " ; ")
    WScript.Echo "       Re-record via /sap-gui-record on screen " & sDrillScr & " (program " & sDrillPgm & ") to capture the current ID."
    WScript.Quit 1
End If

' --- Enumerate rows + dump to TSV -------------------------------------
Dim findingRows : findingRows = 0
On Error Resume Next
findingRows = oFindings.RowCount
On Error GoTo 0

WScript.Echo "FINDING_COUNT: " & findingRows

' Columns we want to capture, with fallbacks for column-ID variation across
' SAP_BASIS releases. The grid exposes columns by technical name; we resolve
' each logical column by membership test against the grid's actual
' ColumnOrder array — NOT by probing GetCellValue (SAP's GridView silently
' returns "" for any unknown column name without raising, so the prior
' "first that doesn't raise" probe locked in the first candidate every
' time and produced rows of empty cells).
'
' Candidate order matters: list the release we've actually observed FIRST,
' fallbacks after. S/4HANA 1909 actuals confirmed 2026-05-11 via
' ZMMRMAT032R01 ATC run: PRIORITY / CHECK_TITLE / MESSAGE_TITLE / OBJ_NAME
' / OBJ_TYPE. LINE has no equivalent on the OUTER findings grid on 1909 —
' source line lives one drill deeper (doubleClick on the finding row opens
' a source-context view); we leave LINE blank when no match is found
' rather than emitting a misleading column.
Dim wantedCols : wantedCols = Array( _
    Array("PRIORITY",      "PRIO",         "PRIO_TXT",     "MSGPR"), _
    Array("CHECK_ID",      "CI_CODE",      "TEST",         "CIID"), _
    Array("CHECK_TITLE",   "TITLE",        "DESCRIPTION",  "TEST_TITLE"), _
    Array("OBJ_NAME",      "OBJECT",       "OBJ_REF",      "OBJECTNAME"), _
    Array("OBJ_TYPE",      "OBJTYPE",      "OBJECT_TYPE",  "TYPE"), _
    Array("MESSAGE_TITLE", "MSG_TEXT",     "MSG",          "TEXT", "LONG_TEXT"), _
    Array("LINE",          "ROW",          "LINENO",       "OFFSET", "SRC_LINE"))
Dim colHeaders : colHeaders = Array("PRIO", "CHECK_ID", "CHECK_TITLE", "OBJ_NAME", "OBJ_TYPE", "MSG_TEXT", "LINE")
Dim canonicalCol : canonicalCol = Array("", "", "", "", "", "", "")

' Enumerate the grid's actual columns once. ColumnOrder is the authoritative
' list of technical column names on the GuiGridView shell. Build an
' uppercased "|NAME|NAME|" string for fast InStr membership tests.
Dim aColOrder, sColMember, iCol, ci, cj, sCand, rProbe, sProbeVal, rProbeMax
sColMember = ""
On Error Resume Next
aColOrder = oFindings.ColumnOrder
On Error GoTo 0
If IsArray(aColOrder) Then
    For iCol = 0 To UBound(aColOrder)
        sColMember = sColMember & "|" & UCase(CStr(aColOrder(iCol))) & "|"
    Next
    WScript.Echo "INFO: Findings grid columns (" & (UBound(aColOrder) + 1) & "): " & Join(aColOrder, ", ")
Else
    WScript.Echo "WARN: GridView.ColumnOrder not available — falling back to GetCellValue probe."
End If

' Resolve canonical column names. Prefer ColumnOrder membership; fall back
' to the legacy probe only when ColumnOrder is unavailable.
For ci = 0 To UBound(wantedCols)
    For cj = 0 To UBound(wantedCols(ci))
        sCand = UCase(CStr(wantedCols(ci)(cj)))
        If sColMember <> "" Then
            If InStr(sColMember, "|" & sCand & "|") > 0 Then
                canonicalCol(ci) = wantedCols(ci)(cj)
                Exit For
            End If
        Else
            ' Legacy probe: only accepted as canonical if it returns a
            ' non-empty value on at least one of the first few rows. This
            ' avoids the silent-empty match that broke the prior version.
            rProbeMax = findingRows - 1
            If rProbeMax > 4 Then rProbeMax = 4
            For rProbe = 0 To rProbeMax
                sProbeVal = ""
                On Error Resume Next
                sProbeVal = oFindings.GetCellValue(rProbe, wantedCols(ci)(cj))
                On Error GoTo 0
                If Err.Number = 0 And Len(Trim(CStr(sProbeVal))) > 0 Then
                    canonicalCol(ci) = wantedCols(ci)(cj)
                    Exit For
                End If
                Err.Clear
            Next
            If canonicalCol(ci) <> "" Then Exit For
        End If
    Next
    If canonicalCol(ci) = "" Then
        WScript.Echo "INFO: No matching grid column found for logical '" & colHeaders(ci) & "' — that field will be blank in the TSV."
    End If
Next

' Open output stream (UTF-8 with BOM so Excel reads JA / DE correctly).
Dim oOut, oFSO
Set oFSO = CreateObject("Scripting.FileSystemObject")
On Error Resume Next
Set oOut = CreateObject("ADODB.Stream")
oOut.Type = 2
oOut.Charset = "utf-8"
oOut.Open

If Err.Number <> 0 Then
    ReleaseSession oSess, wasLocked
    WScript.Echo "ERROR: Could not open output stream for " & OUTPUT_PATH & ": " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' Header row.
oOut.WriteText Join(colHeaders, vbTab) & vbCrLf

Dim rr, cc, cellVal, lineParts
For rr = 0 To findingRows - 1
    ReDim lineParts(UBound(colHeaders))
    For cc = 0 To UBound(colHeaders)
        cellVal = ""
        If canonicalCol(cc) <> "" Then
            On Error Resume Next
            cellVal = oFindings.GetCellValue(rr, canonicalCol(cc))
            On Error GoTo 0
        End If
        ' Strip embedded tabs/newlines so the TSV stays one-row-per-line.
        If InStr(cellVal, vbTab) > 0 Then cellVal = Replace(cellVal, vbTab, " ")
        If InStr(cellVal, vbCrLf) > 0 Then cellVal = Replace(cellVal, vbCrLf, " ")
        If InStr(cellVal, vbLf) > 0 Then cellVal = Replace(cellVal, vbLf, " ")
        lineParts(cc) = cellVal
    Next
    oOut.WriteText Join(lineParts, vbTab) & vbCrLf
Next

On Error Resume Next
oOut.SaveToFile OUTPUT_PATH, 2
oOut.Close
If Err.Number <> 0 Then
    ReleaseSession oSess, wasLocked
    WScript.Echo "ERROR: Could not write TSV to " & OUTPUT_PATH & ": " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

ReleaseSession oSess, wasLocked

If oFSO.FileExists(OUTPUT_PATH) Then
    Dim oFile : Set oFile = oFSO.GetFile(OUTPUT_PATH)
    WScript.Echo "FILE: " & OUTPUT_PATH & " (" & oFile.Size & " bytes)"
End If

WScript.Echo "SUCCESS: Drilled findings for run series " & UCase(RUN_SERIES_NAME) & "."
WScript.Quit 0
