' =============================================================================
' sap_update_addon_prog.vbs -- Maintain add-on table via ZCMRUPDATE_ADDON_TABLE
'
' Runs ZCMRUPDATE_ADDON_TABLE in SA38 with Upload mode.
' The program handles type conversion and MODIFY (upsert) internally.
'
' Tokens:
'   %%TABLE_NAME%%     Table name (Y/Z prefix)
'   %%DATA_FILE%%      Absolute path to TAB-delimited data file
'   %%TEMP_DIR%%       Working temp directory    e.g. "C:\sap_dev_work\temp"
' =============================================================================
Option Explicit

Const TABLE_NAME = "%%TABLE_NAME%%"
Const DATA_FILE  = "%%DATA_FILE%%"
Const TEMP_DIR   = "%%TEMP_DIR%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

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
Dim sMsgText
On Error Resume Next
sMsgText = oSession.findById("wnd[0]/sbar").Text
Err.Clear
On Error GoTo 0
WScript.Echo "INFO: Status bar: " & sMsgText

' Save list output
If sScreen <> "1000" Then
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
    WScript.Echo "INFO: List saved to " & TEMP_DIR & "\sap_update_addon_output.txt"
End If

WScript.Echo "SUCCESS: ZCMRUPDATE_ADDON_TABLE execution completed for " & TABLE_NAME
