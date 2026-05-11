' =============================================================================
' sap_login.vbs  -  SAP GUI Scripting: Open connection and log in
'
' Shared template used by all skills that require SAP GUI login.
' DO NOT commit the filled-in version - it contains credentials.
'
' Run sap_check_gui_login_status.vbs first to skip this if already logged in.
'
' Tokens replaced at run time:
'   %%SAP_LOGON_DESCRIPTION%%    SAP Logon pad entry name (may be empty)
'   %%SAP_APPLICATION_SERVER%%   Application server hostname or IP
'   %%SAP_SYSTEM_NUMBER%%        2-digit system number
'   %%SAP_CLIENT%%               3-digit client
'   %%SAP_USER%%                 SAP username
'   %%SAP_PASSWORD%%             SAP password (blank = wait for manual login)
'   %%SAP_LANGUAGE%%             Logon language
'
' Connection logic:
'   1. If a session is on the login screen, reuse it (skip opening a new connection)
'   2. If SAP_LOGON_DESCRIPTION is set, use OpenConnection (SAP Logon pad)
'   3. Otherwise, use OpenConnectionByConnectionString with server + sysnr
' =============================================================================

Option Explicit

Const SAP_LOGON_DESC = "%%SAP_LOGON_DESCRIPTION%%"
Const SAP_SERVER     = "%%SAP_APPLICATION_SERVER%%"
Const SAP_SYSNR      = "%%SAP_SYSTEM_NUMBER%%"
Const SAP_CLIENT     = "%%SAP_CLIENT%%"
Const SAP_USER       = "%%SAP_USER%%"
Const SAP_PASSWORD   = "%%SAP_PASSWORD%%"
Const SAP_LANGUAGE   = "%%SAP_LANGUAGE%%"
Const VKEY_ENTER     = 0

Dim oSAPGUI, oApplication, oSession

' ------ 1. Attach to SAP GUI (start SAP Logon if not running) ---------------
On Error Resume Next
Set oSAPGUI = GetObject("SAPGUI")
If Err.Number <> 0 Then
    Err.Clear
    WScript.Echo "INFO: SAP Logon is not running. Starting SAP Logon..."

    Dim oShell, oFSO, aSapPaths, iPath, bLaunched
    Set oShell = CreateObject("WScript.Shell")
    Set oFSO   = CreateObject("Scripting.FileSystemObject")
    aSapPaths  = Array( _
        "C:\Program Files (x86)\SAP\FrontEnd\SAPgui\saplogon.exe", _
        "C:\Program Files\SAP\FrontEnd\SAPgui\saplogon.exe")
    bLaunched = False

    For iPath = 0 To UBound(aSapPaths)
        If oFSO.FileExists(aSapPaths(iPath)) Then
            oShell.Run """" & aSapPaths(iPath) & """"
            bLaunched = True
            Exit For
        End If
    Next

    If Not bLaunched Then
        oShell.Run "saplogon.exe"
        If Err.Number <> 0 Then
            WScript.Echo "ERROR: Could not start SAP Logon." & vbCrLf & _
                         "       Please start SAP Logon manually and re-run."
            WScript.Quit 1
        End If
        Err.Clear
    End If

    Dim iStartWait
    For iStartWait = 1 To 30
        WScript.Sleep 1000
        Set oSAPGUI = GetObject("SAPGUI")
        If Err.Number = 0 Then Exit For
        Err.Clear
    Next

    If Err.Number <> 0 Or oSAPGUI Is Nothing Then
        WScript.Echo "ERROR: SAP Logon started but scripting engine is unavailable." & vbCrLf & _
                     "       Enable scripting: SAP Logon > Options > Scripting > Enable Scripting."
        WScript.Quit 1
    End If
    WScript.Echo "INFO: SAP Logon started successfully."
End If
On Error GoTo 0

Set oApplication = oSAPGUI.GetScriptingEngine
If oApplication Is Nothing Then
    WScript.Echo "ERROR: Could not get SAP Scripting Engine." & vbCrLf & _
                 "       Enable scripting: SAP Logon > Options > Scripting > Enable Scripting."
    WScript.Quit 1
End If

' ------ 2. Check for login-screen session (reuse if found) -------------------
Set oSession = Nothing
Dim oCandidate, oSessIter, oSessInfo
Dim oLoginScreenCheck
On Error Resume Next
For Each oCandidate In oApplication.Children
    For Each oSessIter In oCandidate.Children
        Err.Clear
        Set oLoginScreenCheck = oSessIter.findById("wnd[0]/usr/txtRSYST-MANDT")
        If Err.Number = 0 And Not (oLoginScreenCheck Is Nothing) Then
            ' Found a session on the login screen — reuse this connection
            Set oSession = oSessIter
            WScript.Echo "INFO: Found existing session on login screen. Reusing connection."
            Exit For
        End If
        Err.Clear
    Next
    If Not (oSession Is Nothing) Then Exit For
Next
On Error GoTo 0

' ------ 3. Open connection (only if no login-screen session found) -----------
If oSession Is Nothing Then
    If SAP_LOGON_DESC <> "" Then
        ' Path A: Use SAP Logon pad entry name
        WScript.Echo "INFO: Opening connection via SAP Logon: " & SAP_LOGON_DESC
        On Error Resume Next
        Dim oConnA
        Set oConnA = oApplication.OpenConnection(SAP_LOGON_DESC, True)
        If Err.Number <> 0 Then
            WScript.Echo "ERROR: Could not open connection '" & SAP_LOGON_DESC & "': " & Err.Description & vbCrLf & _
                         "       Verify the entry name matches exactly what is in SAP Logon pad (case-sensitive)."
            WScript.Quit 1
        End If
        On Error GoTo 0
    Else
        ' Path B: Use connection string (no SAP Logon description)
        If SAP_SERVER = "" Then
            WScript.Echo "ERROR: Neither SAP Logon description nor application server is configured." & vbCrLf & _
                         "       Set sap_logon_description or sap_application_server in settings."
            WScript.Quit 1
        End If
        Dim sPort, sConnStr
        sPort = CStr(3200 + CInt(SAP_SYSNR))
        sConnStr = "/H/" & SAP_SERVER & "/S/" & sPort
        WScript.Echo "INFO: Opening connection via connection string: " & sConnStr
        On Error Resume Next
        Dim oConnB
        Set oConnB = oApplication.OpenConnectionByConnectionString(sConnStr, True)
        If Err.Number <> 0 Then
            WScript.Echo "ERROR: Could not open connection with string '" & sConnStr & "': " & Err.Description
            WScript.Quit 1
        End If
        On Error GoTo 0
    End If

    ' Wait for session to become available
    Set oSession = Nothing
    Dim iWait
    For iWait = 1 To 30
        WScript.Sleep 1000
        On Error Resume Next
        Set oApplication = oSAPGUI.GetScriptingEngine
        For Each oCandidate In oApplication.Children
            For Each oSessIter In oCandidate.Children
                Set oSession = oSessIter
                Exit For
            Next
            If Not (oSession Is Nothing) Then Exit For
        Next
        On Error GoTo 0
        If Not (oSession Is Nothing) Then Exit For
    Next

    If oSession Is Nothing Then
        WScript.Echo "ERROR: Could not obtain a SAP GUI session."
        WScript.Quit 1
    End If
End If
WScript.Echo "INFO: Session acquired."

' ------ 4. Log in (session should be on login screen) -------------------------
On Error Resume Next
Dim oLoginCheck
Set oLoginCheck = oSession.findById("wnd[0]/usr/txtRSYST-MANDT")
Dim bOnLogin
bOnLogin = (Err.Number = 0) And Not (oLoginCheck Is Nothing)
Err.Clear
On Error GoTo 0

If bOnLogin Then
    If SAP_PASSWORD <> "" Then
        WScript.Echo "INFO: Login screen detected - entering credentials..."
        oSession.findById("wnd[0]/usr/txtRSYST-MANDT").Text = SAP_CLIENT
        oSession.findById("wnd[0]/usr/txtRSYST-BNAME").Text = SAP_USER
        oSession.findById("wnd[0]/usr/pwdRSYST-BCODE").Text = SAP_PASSWORD
        oSession.findById("wnd[0]/usr/txtRSYST-LANGU").Text = SAP_LANGUAGE
        oSession.findById("wnd[0]").sendVKey VKEY_ENTER
        WScript.Sleep 3000

        ' Handle "other sessions" warning if present
        On Error Resume Next
        If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
            oSession.findById("wnd[1]").sendVKey VKEY_ENTER
            WScript.Sleep 1500
        End If
        On Error GoTo 0

        ' Verify login succeeded
        On Error Resume Next
        Set oLoginCheck = oSession.findById("wnd[0]/usr/txtRSYST-MANDT")
        If Err.Number = 0 And Not (oLoginCheck Is Nothing) Then
            WScript.Echo "ERROR: Login failed. Check client, username, and password."
            WScript.Quit 1
        End If
        Err.Clear
        On Error GoTo 0
        WScript.Echo "INFO: Login successful."
    Else
        WScript.Echo "INFO: Login screen detected - waiting for manual login (up to 5 minutes)..."
        Dim iLoginWait
        For iLoginWait = 1 To 300
            WScript.Sleep 1000
            On Error Resume Next
            Set oLoginCheck = oSession.findById("wnd[0]/usr/txtRSYST-MANDT")
            Dim bStillOnLogin
            bStillOnLogin = (Err.Number = 0) And Not (oLoginCheck Is Nothing)
            Err.Clear
            On Error GoTo 0
            If Not bStillOnLogin Then Exit For
        Next
        On Error Resume Next
        Set oLoginCheck = oSession.findById("wnd[0]/usr/txtRSYST-MANDT")
        If Err.Number = 0 And Not (oLoginCheck Is Nothing) Then
            WScript.Echo "ERROR: Login timed out after 5 minutes."
            WScript.Quit 1
        End If
        Err.Clear
        On Error GoTo 0
        WScript.Echo "INFO: Login detected - continuing."
    End If
Else
    WScript.Echo "INFO: Already logged in - skipping login."
End If

' Report final session info
On Error Resume Next
Set oSessInfo = oSession.Info
Dim sFinalDesc
sFinalDesc = ""
For Each oCandidate In oApplication.Children
    For Each oSessIter In oCandidate.Children
        If oSessIter.Id = oSession.Id Then
            sFinalDesc = oCandidate.Description
            Exit For
        End If
    Next
    If sFinalDesc <> "" Then Exit For
Next
On Error GoTo 0

WScript.Echo "SUCCESS: Logged in to " & sFinalDesc & " (" & oSessInfo.SystemName & "/" & oSessInfo.Client & ")."
WScript.Quit 0
