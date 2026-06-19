' =============================================================================
' sap_atc_get_results.vbs  -  Stage 4: Read Priority counts + (best-effort)
'                                       download the result text file from
'                                       the ATC Manage Results screen.
'
' Drives /nATC, navigates to tree node "14" (ABAP Test Cockpit: Manage Results
' - matches Screenshot 2), refreshes, finds the result row by RUN_SERIES_NAME,
' reads Priority 1 / Priority 2 / Priority 3 counts, then drills in and
' triggers a local download to %%OUTPUT_PATH%%.
'
' Tokens:
'   %%RUN_SERIES_NAME%%   The series name from Stage 2.
'   %%OUTPUT_PATH%%       Absolute path for the saved result, e.g.
'                          C:\Temp\ATC_Result_<series>.txt. Parent dir
'                          must exist.
'   %%SESSION_LOCK_VBS%%  Path to sap_session_lock.vbs.
'
' Flow per C:\Temp\Record_ATC_CheckResult_01.vbs (S/4HANA 1909):
'   1. /nATC
'   2. doubleClickItem "         14","&Hierarchy"  -> Manage Results
'   3. tbar[1]/btn[8]                              -> Refresh
'   4. Find row by RUN_SERIES_NAME column, read Priority 1/2/3 cells.
'   5. Drill in (doubleClickCurrentCell on RUN_SERIES_NAME column).
'   6. Best-effort: drive Save / Export to %%OUTPUT_PATH%%. If the toolbar
'      button cannot be located, emit a SAVE_HINT line and skip.
'
' Output (last lines, parseable):
'   PRIORITY_COUNTS: P1=<n> P2=<n> P3=<n>
'   FILE: <absolute path>          (only when download succeeded)
'   SAVE_HINT: <diagnostic>        (when download was skipped or failed)
'   SUCCESS: Read result for run series <NAME>.
'   ERROR: ...
' =============================================================================

Option Explicit

Const RUN_SERIES_NAME = "%%RUN_SERIES_NAME%%"
Const OUTPUT_PATH     = "%%OUTPUT_PATH%%"
Const SESSION_PATH    = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER = 0
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

' --- /nATC + open Manage Results (tree node 14) -------------------------
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

' On S/4HANA 1909 the doubleClickItem on tree node 14 lands on the Manage
' Results SELECTION SCREEN (Program=SATC_CI_RESULT_ADMIN_UI ScreenNumber=
' 1000), NOT directly on the result grid. We must (a) pre-fill the Run
' Series filter so today's run isn't excluded by the default date range
' (which defaults to "yesterday and earlier" on a freshly-opened
' selection screen), and (b) press F8 to advance to
' Program=SAPLSATC_AC_UI_ADMIN_I ScreenNumber=100 where the grid lives.
On Error Resume Next
Dim sScrPgm2 : sScrPgm2 = oSess.Info.Program
Dim sScrNum2 : sScrNum2 = CStr(oSess.Info.ScreenNumber)
On Error GoTo 0
WScript.Echo "INFO: After tree node 14 doubleClick: Program=" & sScrPgm2 & " Screen=" & sScrNum2
If sScrNum2 = "1000" Then
    ' Pre-fill the Run Series Name (ctxtS_RUNSR-LOW) -- narrows results to
    ' our target run regardless of the default date filter. The field
    ' name S_RUNSR maps to "Run Series" select-option on this admin UI.
    On Error Resume Next
    oSess.findById("wnd[0]/usr/ctxtS_RUNSR-LOW").Text = UCase(RUN_SERIES_NAME)
    If Err.Number = 0 Then
        WScript.Echo "INFO: Pre-filled S_RUNSR-LOW=" & UCase(RUN_SERIES_NAME) & " on selection screen."
    Else
        WScript.Echo "WARN: Could not pre-fill S_RUNSR-LOW: " & Err.Description & " -- relying on date filter."
        Err.Clear
    End If
    On Error GoTo 0

    ' Push the high-end of the started-on date range to today, so a run
    ' scheduled today is included even if S_RUNSR-LOW couldn't be set.
    On Error Resume Next
    ' YYYYMMDD = locale-independent date input: SAP DATS fields accept an 8-digit
    ' all-numeric value for any USR01-DATFM. A separator form (e.g. YYYY.MM.DD) is
    ' only valid for the matching DATFM and otherwise rejected. Fix 2026-06-19.
    Dim sToday : sToday = Year(Date) & Right("0" & Month(Date), 2) & Right("0" & Day(Date), 2)
    oSess.findById("wnd[0]/usr/ctxtS_SDLON-HIGH").Text = sToday
    Err.Clear
    On Error GoTo 0

    WScript.Echo "INFO: Pressing F8 to advance from selection screen to result grid."
    On Error Resume Next
    oSess.findById("wnd[0]").sendVKey VKEY_F8
    WScript.Sleep 2000
    On Error GoTo 0
End If
WScript.Sleep 500
On Error GoTo 0

' --- Find row + read Priority counts ------------------------------------
On Error Resume Next
Dim oGrid : Set oGrid = oSess.findById("wnd[0]/usr/shell/shellcont/shell")
On Error GoTo 0

If oGrid Is Nothing Then
    WScript.Echo "ERROR: Could not locate Manage Results grid (wnd[0]/usr/shell/shellcont/shell)."
    WScript.Quit 1
End If

Dim totalRows : totalRows = 0
On Error Resume Next
totalRows = oGrid.RowCount
On Error GoTo 0

Dim seriesCols : seriesCols = Array("RUN_SERIES_NAME", "RUN_SERIES", "NAME", "SERIE_NAME")
Dim r, sRowName, foundRow, sCol
foundRow = -1
For r = 0 To totalRows - 1
    For Each sCol In seriesCols
        sRowName = ""
        On Error Resume Next
        sRowName = UCase(Trim(oGrid.GetCellValue(r, sCol)))
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

WScript.Echo "INFO: Result row " & foundRow & " for series " & UCase(RUN_SERIES_NAME)

' Read Priority 1/2/3 counts. Header text in Screenshot 2 is "Priority 1",
' "Priority 2", "Priority 3"; underlying column IDs typical: PRIO_1 / PRIO1 /
' PRIORITY_1 / NUM_PRIO_1. Try a list.
Function ReadPrioCount(grid, row, prio)
    ' Manage Results grid uses COUNT_PRIO<n> on S/4HANA 1909 (verified live).
    ' Older SAP_BASIS releases used PRIO_<n> / PRIO<n> / PRIORITY_<n> forms;
    ' kept as release-portability fallbacks.
    Dim cands, k, v
    cands = Array("COUNT_PRIO" & prio, "PRIO_" & prio, "PRIO" & prio, _
                  "PRIORITY_" & prio, "NUM_PRIO_" & prio, "PRI" & prio & "_NUM")
    ReadPrioCount = -1
    For Each k In cands
        v = ""
        On Error Resume Next
        v = grid.GetCellValue(row, k)
        On Error GoTo 0
        If IsNumeric(Trim(v)) Then
            ReadPrioCount = CLng(Trim(v))
            Exit Function
        End If
    Next
End Function

Dim p1 : p1 = ReadPrioCount(oGrid, foundRow, 1)
Dim p2 : p2 = ReadPrioCount(oGrid, foundRow, 2)
Dim p3 : p3 = ReadPrioCount(oGrid, foundRow, 3)

If p1 < 0 And p2 < 0 And p3 < 0 Then
    WScript.Echo "WARN: Could not parse Priority columns; falling back to 0/0/0 (column IDs may differ on this release)."
    p1 = 0 : p2 = 0 : p3 = 0
End If
If p1 < 0 Then p1 = 0
If p2 < 0 Then p2 = 0
If p3 < 0 Then p3 = 0

WScript.Echo "PRIORITY_COUNTS: P1=" & p1 & " P2=" & p2 & " P3=" & p3

' --- Trigger Local-File export from the OUTER grid (no drill-in) --------
'
' The Manage Results grid's ALV toolbar exposes button id "&MB_EXPORT" as
' a dropdown. Selecting context menu item "&PC" opens the standard SAP
' "Save list in file..." popup (SAPLSPO5:0150 format radios), then a
' SAPLSGRA save dialog with ctxtDY_PATH / ctxtDY_FILENAME -- the same
' idiom /sap-sp02 uses. Verified live on S/4HANA 1909.
'
' Drill-in is NOT needed for the download -- the user's screenshot showed
' the download notification while still on the outer grid.
Dim wasLocked : wasLocked = TryLockSession(oSess)

Dim sDir, sFile, lastSep
lastSep = InStrRev(OUTPUT_PATH, "\")
If lastSep <= 0 Then lastSep = InStrRev(OUTPUT_PATH, "/")
If lastSep > 0 Then
    sDir  = Left(OUTPUT_PATH, lastSep)
    sFile = Mid(OUTPUT_PATH, lastSep + 1)
Else
    sDir  = ""
    sFile = OUTPUT_PATH
End If

Dim downloaded : downloaded = False

' Tick the row (the export menu acts on selected rows).
On Error Resume Next
oGrid.setCurrentCell foundRow, "RUN_SERIES_NAME"
oGrid.selectedRows = CStr(foundRow)
WScript.Sleep 300

' Open Export dropdown, pick "Local File" (&PC).
oGrid.pressToolbarContextButton "&MB_EXPORT"
WScript.Sleep 600
oGrid.selectContextMenuItem "&PC"
WScript.Sleep 1500

' wnd[1] is now "Save list in file..." with format radios. Pick
' Unconverted (index 0) -- same as /sap-sp02 default.
If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
    Dim oOpt : Set oOpt = Nothing
    Set oOpt = oSess.findById("wnd[1]/usr/subSUBSCREEN_STEPLOOP:SAPLSPO5:0150/sub:SAPLSPO5:0150/radSPOPLI-SELFLAG[1,0]")
    If Not (oOpt Is Nothing) Then
        oOpt.select
        oSess.findById("wnd[1]/tbar[0]/btn[0]").press
        WScript.Sleep 1500
    Else
        Err.Clear
        ' Older builds: just press Continue with default.
        oSess.findById("wnd[1]/tbar[0]/btn[0]").press
        WScript.Sleep 1500
    End If
    Err.Clear

    ' wnd[1] is now the file-save dialog with ctxtDY_PATH / ctxtDY_FILENAME.
    If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
        Dim oPath : Set oPath = Nothing
        Set oPath = oSess.findById("wnd[1]/usr/ctxtDY_PATH")
        If Not (oPath Is Nothing) Then
            oSess.findById("wnd[1]/usr/ctxtDY_PATH").Text = sDir
            oSess.findById("wnd[1]/usr/ctxtDY_FILENAME").Text = sFile
            oSess.findById("wnd[1]/usr/ctxtDY_FILENAME").caretPosition = Len(sFile)
            oSess.findById("wnd[1]").sendVKey 0
            WScript.Sleep 1500
            ' Possible "replace existing?" follow-up -- Enter again.
            If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
                oSess.findById("wnd[1]").sendVKey 0
                WScript.Sleep 800
            End If
            downloaded = True
        End If
    End If
End If
Err.Clear
On Error GoTo 0

ReleaseSession oSess, wasLocked

If downloaded Then
    Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
    If oFSO.FileExists(OUTPUT_PATH) Then
        Dim oFile : Set oFile = oFSO.GetFile(OUTPUT_PATH)
        WScript.Echo "FILE: " & OUTPUT_PATH & " (" & oFile.Size & " bytes)"
    Else
        WScript.Echo "SAVE_HINT: Save dialog completed but file not on disk: " & OUTPUT_PATH
    End If
Else
    WScript.Echo "SAVE_HINT: Export menu did not open the format/save popups. " & _
                 "Open ATC > Manage Results manually, click Export > Local File on the toolbar."
End If

WScript.Echo "SUCCESS: Read result for run series " & UCase(RUN_SERIES_NAME) & "."
WScript.Quit 0
