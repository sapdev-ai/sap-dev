' =============================================================================
' sap_sp02_download.vbs  -  Download an SAP spool request to a local text file
'
' Drives transaction SP02 (Output Controller -- own spool requests):
'
'   1. /nsp02                                   -> spool list
'   2. Locate the row by matching %%SPOOL_NUMBER%% against every list label
'      (layout- & language-independent -- column position is not assumed)
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
'                       zero, the label match is skipped. Useful when you
'                       already know the row from a recording or from a
'                       prior /sap-gui-inspect probe.
'   %%SPOOL_NUM_COL%%  Optional column-index filter. Empty (default) = match
'                       the spool number in ANY column, so the driver adapts to
'                       whatever column the list layout puts it in (col 3 on
'                       S/4HANA 400, col 4 elsewhere). Set it only to
'                       disambiguate a list where another cell could equal the
'                       number.
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

Dim filterCol, fmtIdx, rowIdx, matchedCol
' filterCol = -1 means "match the spool number in ANY column" (layout-independent).
' A caller-supplied SPOOL_NUM_COL narrows the match to that one column (a
' disambiguator for the rare list whose Title/Date cells could equal the number).
filterCol = -1
If IsNumeric(SPOOL_NUM_COL) And Trim(SPOOL_NUM_COL) <> "" Then filterCol = CInt(SPOOL_NUM_COL)
matchedCol = -1

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

' --- 2. Locate the row (layout- & language-independent) --------------------
' SP02 (SAPMSSY0/0120) renders the own-spool list as classic GuiLabel cells
' whose ids encode [col,row]; each data row also has a checkbox at chk[1,row].
' The spool-number COLUMN is not fixed across releases/layouts (col 4 on some
' installs, col 3 on S/4HANA client 400) and the data rows start BELOW a header
' row -- so the old fixed-column scan that anchored at row 0 and broke on the
' first empty cell reported "scanned 0 rows in col 4" on S4H even though the
' spool was right there. Instead we enumerate every label in the user area and
' match on the SPOOL NUMBER itself -- a value we already know -- so we find the
' row regardless of which column carries it and regardless of the header offset.
' Never branch on the (translated) header text.
If rowIdx < 0 Then
    WScript.Echo "INFO: Locating spool " & SPOOL_NUMBER & " among SP02 list labels..."
    Dim oChild, cType, cId, br, bc, nLbl
    nLbl = 0
    For Each oChild In oSess.findById("wnd[0]/usr").Children
        cType = oChild.Type
        If cType = "GuiLabel" Then
            nLbl = nLbl + 1
            cId = oChild.Id
            If ParseColRow(cId, bc, br) Then
                If filterCol < 0 Or bc = filterCol Then
                    If Trim(oChild.Text) = Trim(SPOOL_NUMBER) Then
                        rowIdx = br
                        matchedCol = bc
                        Exit For
                    End If
                End If
            End If
        End If
    Next
    If rowIdx < 0 Then
        WScript.Echo "ERROR: Spool " & SPOOL_NUMBER & " not found among " & nLbl & " list labels" & IIfStr(filterCol >= 0, " in col " & filterCol, " (any column)") & "."
        WScript.Echo "       It may be scrolled below the visible page, belong to another user, or be"
        WScript.Echo "       filtered out of the SP02 selection. Widen/scroll the list, or pass an"
        WScript.Echo "       explicit ROW_INDEX after probing with /sap-gui-inspect (mode=type filter=GuiLabel)."
        WScript.Quit 1
    End If
    WScript.Echo "INFO: Spool " & SPOOL_NUMBER & " located on row " & rowIdx & " (col " & matchedCol & ")."
Else
    WScript.Echo "INFO: Using explicit ROW_INDEX=" & rowIdx & "."
End If

' --- 3. Tick the row's checkbox --------------------------------------------
Dim sChkId : sChkId = "wnd[0]/usr/chk[1," & rowIdx & "]"
On Error Resume Next
oSess.findById(sChkId).Selected = True
Dim chkErr : chkErr = Err.Number
Err.Clear
On Error GoTo 0
If chkErr <> 0 Then
    ' Fallback: the selection checkbox isn't at column 1 on this layout --
    ' find any GuiCheckBox on the located row and tick it instead.
    Dim oc2, ccol, crow, chkDone : chkDone = False
    For Each oc2 In oSess.findById("wnd[0]/usr").Children
        If oc2.Type = "GuiCheckBox" Then
            If ParseColRow(oc2.Id, ccol, crow) Then
                If crow = rowIdx Then
                    On Error Resume Next
                    oc2.Selected = True
                    If Err.Number = 0 Then chkDone = True
                    Err.Clear
                    On Error GoTo 0
                    If chkDone Then sChkId = oc2.Id : Exit For
                End If
            End If
        End If
    Next
    If Not chkDone Then
        WScript.Echo "ERROR: Could not tick a selection checkbox on row " & rowIdx & "."
        WScript.Quit 1
    End If
End If
WScript.Sleep 300

' --- 4. Display the spool contents -----------------------------------------
' Reaching the CONTENT display is what makes "Save to local file" (Step 5)
' appear. F2 alone does NOT navigate on all releases (on S/4HANA client 400
' it stays on the list -- there "Display contents" is F6/btn[6]), so identify
' the button by its language-independent icon B_DISP and press it; fall back to
' F2 only if no such button exists (older layouts where F2 was the display key).
WScript.Echo "INFO: Opening spool contents..."
On Error Resume Next
oSess.findById(sChkId).setFocus
Err.Clear
On Error GoTo 0
Dim dispId : dispId = FindBtnByIcon("wnd[0]/tbar[1]", "B_DISP")
If dispId <> "" Then
    oSess.findById(dispId).press
Else
    oSess.findById("wnd[0]").sendVKey VKEY_F2
End If
WScript.Sleep 2000

If oSess.findById("wnd[0]/sbar").MessageType = "E" Then
    WScript.Echo "ERROR: Display contents returned: " & oSess.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If

' --- 5. Save (export) to local file ----------------------------------------
' On the content-display screen the "Save to local file" button carries icon
' B_DOWN (btn[48] on the tested release). Locate it by icon so a release that
' renumbers the toolbar still resolves it; fall back to the documented btn[48].
Dim saveId : saveId = FindBtnByIcon("wnd[0]/tbar[1]", "B_DOWN")
If saveId = "" Then saveId = "wnd[0]/tbar[1]/btn[48]"
WScript.Echo "INFO: Pressing Save (" & saveId & ")..."
On Error Resume Next
oSess.findById(saveId).press
WScript.Sleep 1500
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not press Save (" & saveId & "): " & Err.Description
    WScript.Echo "       Ensure the spool CONTENT is displayed (not the list); the Save-to-local"
    WScript.Echo "       button (icon B_DOWN) only exists on the content-display screen."
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

' Back to SP02 list, then to SAP Easy Access -- keeps the operator's
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

' ---------------------------------------------------------------------------
' Helpers
' ---------------------------------------------------------------------------

' Parse the trailing "[<col>,<row>]" coordinate off a GuiVComponent id
' (e.g. ".../usr/lbl[3,4]" -> col=3,row=4; also works for "chk[1,3]"). Returns
' True and sets oCol/oRow (ByRef) on success; False if the id has no numeric
' [c,r] coordinate. Uses InStrRev so it always reads the LAST bracket pair.
Function ParseColRow(sId, ByRef oCol, ByRef oRow)
    ParseColRow = False
    Dim p1, p2, inner, parts
    p1 = InStrRev(sId, "[")
    If p1 = 0 Then Exit Function
    p2 = InStr(p1, sId, "]")
    If p2 = 0 Then Exit Function
    inner = Mid(sId, p1 + 1, p2 - p1 - 1)
    parts = Split(inner, ",")
    If UBound(parts) <> 1 Then Exit Function
    If Not (IsNumeric(parts(0)) And IsNumeric(parts(1))) Then Exit Function
    oCol = CInt(parts(0))
    oRow = CInt(parts(1))
    ParseColRow = True
End Function

' Tiny string ternary for diagnostic messages (both args always evaluated).
Function IIfStr(bCond, sA, sB)
    If bCond Then IIfStr = sA Else IIfStr = sB
End Function

' Return the id of the first GuiButton on toolbar <sBar> whose IconName equals
' <sIcon> (case-insensitive), or "" if none. Icon names (B_DISP, B_DOWN, ...)
' are language-independent SAP codes, so this resolves a function button even
' when the release renumbers the toolbar or the logon language translates the
' tooltip. Caller uses it on a screen where the target icon is unambiguous.
Function FindBtnByIcon(sBar, sIcon)
    FindBtnByIcon = ""
    On Error Resume Next
    Dim oBar : Set oBar = oSess.findById(sBar)
    If Err.Number <> 0 Then Err.Clear : On Error GoTo 0 : Exit Function
    On Error GoTo 0
    Dim b, ic
    For Each b In oBar.Children
        If b.Type = "GuiButton" Then
            ic = ""
            On Error Resume Next
            ic = b.IconName
            On Error GoTo 0
            If UCase(ic) = UCase(sIcon) Then
                FindBtnByIcon = b.Id
                Exit Function
            End If
        End If
    Next
End Function
