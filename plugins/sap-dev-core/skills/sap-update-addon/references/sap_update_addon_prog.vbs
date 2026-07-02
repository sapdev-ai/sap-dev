' =============================================================================
' sap_update_addon_prog.vbs -- Maintain add-on table via ZCMRUPDATE_ADDON_TABLE
'
' Runs ZCMRUPDATE_ADDON_TABLE in SA38 with Upload mode.
' The program handles type conversion and MODIFY (upsert) internally --
' it has NO DELETE mode, so OPERATION=DELETE is refused upfront.
'
' Verdict gates (SUCCESS prints only if ALL pass):
'   * status bar MessageType after F8 is not E/A
'   * the program actually left the selection screen (still 1000 = never ran)
'   * the saved list output contains the program's result-count block and its
'     error count is 0 (counts parsed locale-independently by digits; the JA
'     labels may mojibake, the integers and '=' separator lines never do).
'     If the list could not be saved at all, the run ends SUCCESS_UNVERIFIED.
'
' Tokens:
'   %%TABLE_NAME%%     Table name (Y/Z prefix)
'   %%DATA_FILE%%      Absolute path to TAB-delimited data file
'   %%TEMP_DIR%%       Working temp directory    e.g. "C:\sap_dev_work\temp"
'   %%OPERATION%%      INSERT / UPDATE (both = MODIFY upsert). DELETE refused.
' =============================================================================
Option Explicit

Const TABLE_NAME = "%%TABLE_NAME%%"
Const DATA_FILE  = "%%DATA_FILE%%"
Const TEMP_DIR   = "%%TEMP_DIR%%"
Const OPERATION  = "%%OPERATION%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

' --- 0. Refuse DELETE upfront ------------------------------------------------
' ZCMRUPDATE_ADDON_TABLE has exactly one write path: MODIFY (mv_table) FROM
' <fs_wa> (upsert; see references/ZCMRUPDATE_ADDON_TABLE.abap, do_upload).
' Running it for a DELETE request would silently UPSERT the rows instead.
' Unsubstituted-token sentinel via Chr(37) (stale wrappers -> default upsert).
Dim sOpProg
sOpProg = UCase(Trim(OPERATION))
If sOpProg = Chr(37) & Chr(37) & "OPERATION" & Chr(37) & Chr(37) Then sOpProg = ""
If sOpProg = "DELETE" Then
    WScript.Echo "ERROR: PROG method supports upsert (MODIFY) only -- ZCMRUPDATE_ADDON_TABLE has no DELETE mode."
    WScript.Echo "       Delete the rows manually (or via SM30 with a maintenance view)."
    WScript.Quit 1
End If

' --- 1. Attach to existing SAP GUI session (via shared attach helper) ------
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

' --- 2. Navigate to SA38 and run ZCMRUPDATE_ADDON_TABLE ---
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSA38"
oSession.findById("wnd[0]").sendVKey 0
WScript.Sleep 500

oSession.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").Text = "ZCMRUPDATE_ADDON_TABLE"
oSession.findById("wnd[0]").sendVKey 8  ' F8 = Execute
WScript.Sleep 1000

' Confirm selection screen
Dim sScreen
sScreen = CStr(oSession.Info.ScreenNumber)
If sScreen <> "1000" Then
    WScript.Echo "ERROR: Expected selection screen 1000, got " & sScreen
    WScript.Quit 1
End If

' Upload mode is default (RB_UP already selected)
' Fill table name (txtP_TABLE -- GuiTextField for TABNAME type)
oSession.findById("wnd[0]/usr/txtP_TABLE").Text = TABLE_NAME

' Fill file path (ctxtP_FILE -- GuiCTextField)
oSession.findById("wnd[0]/usr/ctxtP_FILE").Text = DATA_FILE

' Execute (F8)
WScript.Echo "INFO: Executing ZCMRUPDATE_ADDON_TABLE for " & TABLE_NAME & "..."
oSession.findById("wnd[0]").sendVKey 8
WScript.Sleep 3000

' Check screen after execute
sScreen = CStr(oSession.Info.ScreenNumber)
WScript.Echo "INFO: Screen after execute: " & sScreen

' Read status bar
Dim sMsgType, sMsgText
On Error Resume Next
sMsgType = oSession.findById("wnd[0]/sbar").MessageType
sMsgText = oSession.findById("wnd[0]/sbar").Text
Err.Clear
On Error GoTo 0
WScript.Echo "INFO: Status bar: [" & sMsgType & "] " & sMsgText

' Gate 1 -- status bar MessageType (locale-independent): E/A = hard failure.
If sMsgType = "E" Or sMsgType = "A" Then
    WScript.Echo "ERROR: ZCMRUPDATE_ADDON_TABLE failed (status-bar type " & sMsgType & "): " & sMsgText
    WScript.Quit 1
End If

' Gate 2 -- still on the selection screen = the program never ran (e.g. a
' selection-screen validation error).
If sScreen = "1000" Then
    WScript.Echo "ERROR: Still on selection screen 1000 after F8 -- ZCMRUPDATE_ADDON_TABLE did not run."
    WScript.Quit 1
End If

' Save list output (System > List > Save > Local File, unconverted format)
Dim sOutFile
sOutFile = TEMP_DIR & "\sap_update_addon_output.txt"
WScript.Echo "INFO: Saving list output..."
On Error Resume Next
oSession.findById("wnd[0]/mbar/menu[0]/menu[1]/menu[2]").Select
WScript.Sleep 1000

' Select Unconverted format
oSession.findById("wnd[0]/usr/subSUBSCREEN_STEPLOOP:SAPLSPO5:0150/sub:SAPLSPO5:0150/radSPOPLI-SELFLAG[4,0]").Select
oSession.findById("wnd[0]").sendVKey 0
WScript.Sleep 500

' File dialog
oSession.findById("wnd[1]/usr/ctxtDY_FILENAME").Text = "sap_update_addon_output.txt"
oSession.findById("wnd[1]/usr/ctxtDY_PATH").Text = TEMP_DIR & "\"
oSession.findById("wnd[1]").sendVKey 11  ' Replace
WScript.Sleep 1000
Err.Clear
On Error GoTo 0

' Gate 3 -- parse the result counts from the saved list.
' do_upload always ends a COMPLETED run with this block (ZCMRUPDATE_ADDON_TABLE
' source, do_upload tail):
'     ========================================
'     <completion line incl. table name>       (JA WRITE literal)
'     <success-count>  <error-count>           (JA labels; digits are ASCII)
'     ========================================
' The JA labels can render as '#' under a non-matching codepage, but the two
' integers and the all-'=' separator lines always survive. Locale-independent
' parse: the line directly above the LAST all-'=' line holds exactly two
' integers -> first = success count, second = error count. A saved list
' WITHOUT this block means the program aborted before processing any row
' (column-count mismatch, unreadable file, non-addon table, ...).
Dim oParseFso, oOut, sPLine, aOutLines(), iOutCount, iSep, iLast
Set oParseFso = CreateObject("Scripting.FileSystemObject")
If Not oParseFso.FileExists(sOutFile) Then
    WScript.Echo "WARNING: List output was not saved (" & sOutFile & ") -- result counts unread."
    WScript.Echo "SUCCESS_UNVERIFIED: sbar gate passed but the ZCMRUPDATE_ADDON_TABLE result counts could not be read."
    WScript.Echo "       Verify the table content via /sap-se16n."
    WScript.Quit 0
End If

iOutCount = 0
ReDim aOutLines(0)
Set oOut = oParseFso.OpenTextFile(sOutFile, 1)   ' ASCII read is enough: digits + '=' survive
Do While Not oOut.AtEndOfStream
    sPLine = Replace(oOut.ReadLine, Chr(0), "")  ' strip NULs defensively
    iOutCount = iOutCount + 1
    ReDim Preserve aOutLines(iOutCount)
    aOutLines(iOutCount) = sPLine
Loop
oOut.Close

iLast = 0
For iSep = 1 To iOutCount
    sPLine = Trim(aOutLines(iSep))
    If Len(sPLine) >= 10 And Replace(sPLine, "=", "") = "" Then iLast = iSep
Next

Dim lv_ok, lv_ng
lv_ok = -1 : lv_ng = -1
If iLast >= 2 Then
    Dim oRe, oMatches
    Set oRe = New RegExp
    oRe.Pattern = "\d+"
    oRe.Global = True
    Set oMatches = oRe.Execute(aOutLines(iLast - 1))
    If oMatches.Count = 2 Then
        lv_ok = CLng(oMatches(0).Value)
        lv_ng = CLng(oMatches(1).Value)
    End If
End If

If lv_ok < 0 Then
    WScript.Echo "ERROR: ZCMRUPDATE_ADDON_TABLE did not produce its result-count block --"
    WScript.Echo "       the program aborted before processing rows (e.g. column-count"
    WScript.Echo "       mismatch or unreadable data file). List saved to: " & sOutFile
    Dim iShow
    For iShow = 1 To iOutCount
        If iShow > 15 Then Exit For
        WScript.Echo "LIST: " & aOutLines(iShow)
    Next
    WScript.Quit 1
End If

WScript.Echo "RESULT_COUNTS: success=" & lv_ok & " error=" & lv_ng
WScript.Echo "INFO: List saved to " & sOutFile
If lv_ng > 0 Then
    WScript.Echo "ERROR: " & lv_ng & " row(s) failed in ZCMRUPDATE_ADDON_TABLE (success=" & lv_ok & "). See the saved list for per-row messages."
    WScript.Quit 1
End If
If lv_ok = 0 Then
    WScript.Echo "ERROR: ZCMRUPDATE_ADDON_TABLE processed 0 rows (success=0, error=0)."
    WScript.Quit 1
End If

WScript.Echo "SUCCESS: ZCMRUPDATE_ADDON_TABLE upserted " & lv_ok & " row(s) into " & TABLE_NAME & "."
