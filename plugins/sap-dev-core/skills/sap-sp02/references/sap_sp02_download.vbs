' =============================================================================
' sap_sp02_download.vbs  -  Download an SAP spool request to a local text file
'
' Drives transaction SP02 (Output Controller — own spool requests):
'
'   1. /nsp02                                   -> spool list
'   2. Locate the row of %%SPOOL_NUMBER%% in the list (column scan)
'   3. Tick chk[1,<row>]                        -> select the spool
'   4. sendVKey 2                               -> F2 = Display contents
'   5. tbar[1]/btn[48]                          -> "Save..." (export to local)
'   6. Format popup wnd[1]:
'        radSPOPLI-SELFLAG[1,<fmt_idx>]         -> pick output format
'        tbar[0]/btn[0]                          -> Continue
'   7. File-save dialog wnd[1]:
'        ctxtDY_PATH      = %%OUTPUT_DIR%%
'        ctxtDY_FILENAME  = %%OUTPUT_FILE%%
'        sendVKey 0                              -> Save / Replace
'   8. Read sbar to confirm the byte-count message; back out.
'
' Tokens replaced at run time:
'   %%SPOOL_NUMBER%%   SAP spool request number (TSP01-RQIDENT). Required
'                       unless ROW_INDEX is non-zero. Numeric, no leading
'                       zeros (the script also matches "         <NUM>"
'                       padded forms in the list cell).
'   %%ROW_INDEX%%      Optional explicit row index in the SP02 list (0-based
'                       row number on the user-area). When non-empty / non-
'                       zero, the row scan is skipped. Useful when you
'                       already know the row from a recording or from a
'                       prior /sap-gui-object-details probe.
'   %%SPOOL_NUM_COL%%  Column index that carries the spool number on the
'                       SP02 list. Default 4 (S/4HANA 1909). Override if
'                       the list layout was customised.
'   %%FORMAT_INDEX%%   Index of the format radio on the export popup
'                       (radSPOPLI-SELFLAG[1,<idx>]). Default 0
'                       (Unconverted = plain text). 1=Spreadsheet,
'                       2=Rich text, 3=HTML on most S/4HANA installs.
'   %%OUTPUT_DIR%%     Local directory (must end with "\"), e.g. "C:\Temp\".
'   %%OUTPUT_FILE%%    Local filename (with extension), e.g. "SP02_397.txt".
'
' Recording reference: C:\Temp\Record_SP02__01.vbs (S/4HANA 1909).
'
' Output (last line of stdout, parseable):
'   SUCCESS: Spool <NUM> written to <PATH>.
'   ERROR:   ...
' =============================================================================

Option Explicit

Const SPOOL_NUMBER  = "%%SPOOL_NUMBER%%"
Const ROW_INDEX_RAW = "%%ROW_INDEX%%"
Const SPOOL_NUM_COL = "%%SPOOL_NUM_COL%%"
Const FORMAT_INDEX  = "%%FORMAT_INDEX%%"
Const OUTPUT_DIR    = "%%OUTPUT_DIR%%"
Const OUTPUT_FILE   = "%%OUTPUT_FILE%%"
Const SESSION_PATH  = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

' Include shared attach helper (AttachSapSession with explicit-hint /
' env-var / legacy-default resolution). Handles error paths internally.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Const VKEY_ENTER     = 0
Const VKEY_F2        = 2
Const VKEY_F3_BACK   = 3

Dim spoolCol, fmtIdx, rowIdx
spoolCol = 4
If IsNumeric(SPOOL_NUM_COL) And Trim(SPOOL_NUM_COL) <> "" Then spoolCol = CInt(SPOOL_NUM_COL)

fmtIdx = 0
If IsNumeric(FORMAT_INDEX) And Trim(FORMAT_INDEX) <> "" Then fmtIdx = CInt(FORMAT_INDEX)

rowIdx = -1
If IsNumeric(ROW_INDEX_RAW) And Trim(ROW_INDEX_RAW) <> "" Then rowIdx = CInt(ROW_INDEX_RAW)

If Trim(OUTPUT_DIR) = "" Or Trim(OUTPUT_FILE) = "" Then
    WScript.Echo "ERROR: OUTPUT_DIR and OUTPUT_FILE tokens must be filled."
    WScript.Quit 1
End If
If rowIdx < 0 And Trim(SPOOL_NUMBER) = "" Then
    WScript.Echo "ERROR: SPOOL_NUMBER must be supplied (or ROW_INDEX as a fallback)."
    WScript.Quit 1
End If

' --- Attach to existing SAP GUI session (via shared attach helper) ---------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)

' --- 1. Navigate to SP02 ---------------------------------------------------
WScript.Echo "INFO: Navigating to SP02..."
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSP02"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500

' --- 2. Locate the row ------------------------------------------------------
' SP02 renders the spool list as static labels in the user-area. Each row
' has a checkbox at chk[1,<row>] and the spool number as a text label at
' lbl[<spoolCol>,<row>]. Header rows occupy the first 1-3 indices (varies
' by SAP GUI theme); we scan from row 0 upward and accept the first row
' whose spoolCol cell trims to SPOOL_NUMBER.
If rowIdx < 0 Then
    WScript.Echo "INFO: Scanning SP02 list for spool " & SPOOL_NUMBER & " (col " & spoolCol & ")..."
    Dim r, sCellId, sCell, sTrim, bFound
    bFound = False
    r = 0
    Do While r < 300   ' hard cap; spool lists rarely exceed this
        sCellId = "wnd[0]/usr/lbl[" & spoolCol & "," & r & "]"
        On Error Resume Next
        sCell = oSess.findById(sCellId).Text
        Dim eNum : eNum = Err.Number
        Err.Clear
        On Error GoTo 0
        If eNum <> 0 Then
            ' No more rows at this column.
            Exit Do
        End If
        sTrim = Trim(sCell)
        If sTrim = Trim(SPOOL_NUMBER) Then
            rowIdx = r
            bFound = True
            Exit Do
        End If
        r = r + 1
    Loop
    If Not bFound Then
        WScript.Echo "ERROR: Spool " & SPOOL_NUMBER & " not found in SP02 list (scanned " & r & " rows in col " & spoolCol & ")."
        WScript.Echo "       The spool may not belong to the current user, may be older than the default selection,"
        WScript.Echo "       or the spool-number column may differ on this system. Try widening SP02 selection"
        WScript.Echo "       criteria, or pass an explicit ROW_INDEX after probing the list with"
        WScript.Echo "       /sap-gui-object-details (mode=type filter=GuiLabel)."
        WScript.Quit 1
    End If
    WScript.Echo "INFO: Spool " & SPOOL_NUMBER & " located on row " & rowIdx & "."
Else
    WScript.Echo "INFO: Using explicit ROW_INDEX=" & rowIdx & "."
End If

' --- 3. Tick the row's checkbox --------------------------------------------
Dim sChkId : sChkId = "wnd[0]/usr/chk[1," & rowIdx & "]"
On Error Resume Next
oSess.findById(sChkId).Selected = True
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not tick checkbox " & sChkId & ": " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0
WScript.Sleep 300

' --- 4. F2 = Display contents ----------------------------------------------
WScript.Echo "INFO: Opening spool contents (F2)..."
On Error Resume Next
oSess.findById("wnd[0]/usr/lbl[" & spoolCol & "," & rowIdx & "]").setFocus
Err.Clear
On Error GoTo 0
oSess.findById("wnd[0]").sendVKey VKEY_F2
WScript.Sleep 2000

If oSess.findById("wnd[0]/sbar").MessageType = "E" Then
    WScript.Echo "ERROR: F2 (Display contents) returned: " & oSess.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If

' --- 5. Save (export) — application toolbar btn[48] ------------------------
WScript.Echo "INFO: Pressing Save (tbar[1]/btn[48])..."
On Error Resume Next
oSess.findById("wnd[0]/tbar[1]/btn[48]").press
WScript.Sleep 1500
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not press Save (tbar[1]/btn[48]): " & Err.Description
    WScript.Echo "       Some SAP GUI versions place Save under the system toolbar — try tbar[0]/btn[11]."
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' --- 6. Format-selection popup ---------------------------------------------
'
' wnd[1] shows a step-loop of radio buttons for output format. The radios
' are at .../radSPOPLI-SELFLAG[1,<idx>]; we select the requested index
' (default 0 = Unconverted plain text).
WScript.Echo "INFO: Selecting export format index " & fmtIdx & "..."
On Error Resume Next
Dim sRadioId
sRadioId = "wnd[1]/usr/subSUBSCREEN_STEPLOOP:SAPLSPO5:0150/sub:SAPLSPO5:0150/radSPOPLI-SELFLAG[1," & fmtIdx & "]"
oSess.findById(sRadioId).select
oSess.findById(sRadioId).setFocus
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not select format radio (" & sRadioId & "): " & Err.Description
    WScript.Quit 1
End If
Err.Clear
oSess.findById("wnd[1]/tbar[0]/btn[0]").press   ' Continue
WScript.Sleep 1500
On Error GoTo 0

' --- 7. File-save dialog ---------------------------------------------------
WScript.Echo "INFO: Filling save dialog (path=" & OUTPUT_DIR & ", file=" & OUTPUT_FILE & ")..."
On Error Resume Next
If InStr(oSess.ActiveWindow.Id, "wnd[1]") = 0 Then
    WScript.Echo "ERROR: Expected file-save dialog but ActiveWindow=" & oSess.ActiveWindow.Id
    WScript.Quit 1
End If
oSess.findById("wnd[1]/usr/ctxtDY_PATH").Text     = OUTPUT_DIR
oSess.findById("wnd[1]/usr/ctxtDY_FILENAME").Text = OUTPUT_FILE
oSess.findById("wnd[1]/usr/ctxtDY_FILENAME").caretPosition = Len(OUTPUT_FILE)
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not fill DY_PATH/DY_FILENAME: " & Err.Description
    WScript.Quit 1
End If
Err.Clear
oSess.findById("wnd[1]").sendVKey VKEY_ENTER
WScript.Sleep 1500
On Error GoTo 0

' Some SAP GUI builds show a second confirmation popup if the file exists
' ("Replace existing file?"). Press Enter again on any leftover modal.
On Error Resume Next
If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
    oSess.findById("wnd[1]").sendVKey VKEY_ENTER
    WScript.Sleep 800
End If
Err.Clear
On Error GoTo 0

' --- 8. Read sbar; back out ------------------------------------------------
Dim sFinalMsg, sFinalType
On Error Resume Next
sFinalMsg  = oSess.findById("wnd[0]/sbar").Text
sFinalType = oSess.findById("wnd[0]/sbar").MessageType
On Error GoTo 0

WScript.Echo "INFO: SAP status: [" & sFinalType & "] " & sFinalMsg

' Back to SP02 list, then to SAP Easy Access — keeps the operator's
' session in a clean state.
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_F3_BACK
WScript.Sleep 500
On Error GoTo 0

' Verify the file was actually written.
Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
Dim sFullPath : sFullPath = OUTPUT_DIR & OUTPUT_FILE
If Not oFSO.FileExists(sFullPath) Then
    WScript.Echo "ERROR: Save dialog completed but file is not on disk: " & sFullPath
    WScript.Quit 1
End If

Dim oFile : Set oFile = oFSO.GetFile(sFullPath)
WScript.Echo "INFO: File written: " & sFullPath & " (" & oFile.Size & " bytes)"
WScript.Echo "SUCCESS: Spool " & SPOOL_NUMBER & " written to " & sFullPath & "."
WScript.Quit 0
