' =============================================================================
' sap_check_gui_login_status.vbs  -  Check SAP GUI session status
'
' Static script (no tokens). Run directly (32-bit host -- SAP GUI COM):
'   C:\Windows\SysWOW64\cscript.exe //NoLogo sap_check_gui_login_status.vbs
'
' Output (one STATUS line, plus detail lines if applicable):
'   STATUS: NO_GUI          SAP GUI / SAP Logon is not running
'   STATUS: NO_SCRIPTING    Scripting engine not available
'   STATUS: NO_SESSION      SAP GUI running but no sessions exist
'   STATUS: LOGIN_SCREEN    Session exists but not authenticated
'   STATUS: LOGGED_IN       Authenticated session found
'
' Detail lines (only with LOGGED_IN or LOGIN_SCREEN):
'   DESCRIPTION: <SAP Logon pad entry description>
'   SYSTEM: <system name>
'   CLIENT: <client number>
'   USER: <username>
'   LANGUAGE: <logon language>
'   CODEPAGE: <system codepage>
'
' Always exits 0. This is a read-only check, not an action.
' =============================================================================

Option Explicit

Dim oSAPGUI, oApplication

' ------ 1. Check SAP GUI availability ----------------------------------------
On Error Resume Next
Set oSAPGUI = GetObject("SAPGUI")
If Err.Number <> 0 Or oSAPGUI Is Nothing Then
    WScript.Echo "STATUS: NO_GUI"
    WScript.Quit 0
End If
Err.Clear
On Error GoTo 0

Set oApplication = oSAPGUI.GetScriptingEngine
If oApplication Is Nothing Then
    WScript.Echo "STATUS: NO_SCRIPTING"
    WScript.Quit 0
End If

' ------ 2. Scan sessions -----------------------------------------------------
Dim oConnection, oSession, oLoginCheck, oSessInfo
Dim bFoundLoginScreen, sLoginDesc
bFoundLoginScreen = False
sLoginDesc = ""

On Error Resume Next
For Each oConnection In oApplication.Children
    For Each oSession In oConnection.Children
        Err.Clear
        Set oLoginCheck = oSession.findById("wnd[0]/usr/txtRSYST-MANDT")

        If Err.Number <> 0 Or oLoginCheck Is Nothing Then
            ' Not on login screen -- this session is authenticated
            Err.Clear
            Set oSessInfo = oSession.Info
            WScript.Echo "STATUS: LOGGED_IN"
            WScript.Echo "DESCRIPTION: " & oConnection.Description
            WScript.Echo "SYSTEM: " & oSessInfo.SystemName
            WScript.Echo "CLIENT: " & oSessInfo.Client
            WScript.Echo "USER: " & oSessInfo.User
            WScript.Echo "LANGUAGE: " & oSessInfo.Language
            WScript.Echo "CODEPAGE: " & oSessInfo.Codepage
            WScript.Quit 0
        Else
            ' On login screen -- connection exists but not authenticated
            Err.Clear
            bFoundLoginScreen = True
            sLoginDesc = oConnection.Description
        End If
    Next
Next
On Error GoTo 0

' ------ 3. Report result ------------------------------------------------------
If bFoundLoginScreen Then
    WScript.Echo "STATUS: LOGIN_SCREEN"
    WScript.Echo "DESCRIPTION: " & sLoginDesc
Else
    WScript.Echo "STATUS: NO_SESSION"
End If

WScript.Quit 0
