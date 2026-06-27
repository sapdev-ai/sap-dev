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
'   %%SAP_APPLICATION_SERVER%%   Application server hostname or IP   (direct login)
'   %%SAP_SYSTEM_NUMBER%%        2-digit system number               (direct login)
'   %%SAP_MESSAGE_SERVER%%       Message server hostname             (load-balanced)
'   %%SAP_LOGON_GROUP%%          Logon group  (default: SPACE)       (load-balanced)
'   %%SAP_SYSTEM_ID%%            3-letter R3NAME / SID               (load-balanced)
'   %%SAP_SYSTEM_NAME%%          SAP logical system name (Info.SystemName)
'                                Empty = legacy / no-SID profile -> identity
'                                match falls back to Client+User only.
'   %%SAP_CLIENT%%               3-digit client
'   %%SAP_USER%%                 SAP username
'   %%SAP_PASSWORD%%             SAP password (blank = wait for manual login)
'   %%SAP_LANGUAGE%%             Logon language
'
' Connection logic (in this order -- first match wins):
'   1. Session already on the login screen -> reuse it.
'   2. SAP_LOGON_DESC set -> OpenConnection(desc).
'   3. SAP_MESSAGE_SERVER set and SAP_SERVER empty -> load-balanced connection
'      string  /M/<msgsrv>/G/<grp>/S/<sysid>.  LogonGroup defaults to " " if blank.
'   4. SAP_SERVER set -> direct connection string  /H/<host>/S/<port>
'      (port = 3200 + sysnr).
'   5. Else -> ERROR (no endpoint configured).
' =============================================================================

Option Explicit

Const SAP_LOGON_DESC    = "%%SAP_LOGON_DESCRIPTION%%"
Const SAP_SERVER        = "%%SAP_APPLICATION_SERVER%%"
Const SAP_SYSNR         = "%%SAP_SYSTEM_NUMBER%%"
Const SAP_MESSAGE_SRV   = "%%SAP_MESSAGE_SERVER%%"
Const SAP_LOGON_GROUP   = "%%SAP_LOGON_GROUP%%"
Const SAP_SYSTEM_ID     = "%%SAP_SYSTEM_ID%%"
Const SAP_SYSTEM_NAME   = "%%SAP_SYSTEM_NAME%%"
Const SAP_CLIENT        = "%%SAP_CLIENT%%"
Const SAP_USER          = "%%SAP_USER%%"
Const SAP_PASSWORD      = "%%SAP_PASSWORD%%"
Const SAP_LANGUAGE      = "%%SAP_LANGUAGE%%"
Const VKEY_ENTER        = 0

' Detect unsubstituted tokens. PowerShell .Replace() is global, so we build
' the sentinel at runtime from Chr() codes -- wrapper substitution cannot
' touch a Chr-built string. Pattern lifted from sap_attach_lib.vbs.
Dim UNSUB_DESC, UNSUB_SRV, UNSUB_MSRV, UNSUB_GRP, UNSUB_SID, UNSUB_SYSNAME
UNSUB_DESC    = Chr(37) & Chr(37) & "SAP_LOGON_DESCRIPTION" & Chr(37) & Chr(37)
UNSUB_SRV     = Chr(37) & Chr(37) & "SAP_APPLICATION_SERVER" & Chr(37) & Chr(37)
UNSUB_MSRV    = Chr(37) & Chr(37) & "SAP_MESSAGE_SERVER" & Chr(37) & Chr(37)
UNSUB_GRP     = Chr(37) & Chr(37) & "SAP_LOGON_GROUP" & Chr(37) & Chr(37)
UNSUB_SID     = Chr(37) & Chr(37) & "SAP_SYSTEM_ID" & Chr(37) & Chr(37)
UNSUB_SYSNAME = Chr(37) & Chr(37) & "SAP_SYSTEM_NAME" & Chr(37) & Chr(37)

' Effective values -- empty when the wrapper left the token unsubstituted.
Dim eDesc, eSrv, eMsrv, eGrp, eSid, eSysName
eDesc    = SAP_LOGON_DESC
eSrv     = SAP_SERVER
eMsrv    = SAP_MESSAGE_SRV
eGrp     = SAP_LOGON_GROUP
eSid     = SAP_SYSTEM_ID
eSysName = SAP_SYSTEM_NAME
If eDesc    = UNSUB_DESC    Then eDesc    = ""
If eSrv     = UNSUB_SRV     Then eSrv     = ""
If eMsrv    = UNSUB_MSRV    Then eMsrv    = ""
If eGrp     = UNSUB_GRP     Then eGrp     = ""
If eSid     = UNSUB_SID     Then eSid     = ""
If eSysName = UNSUB_SYSNAME Then eSysName = ""

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

' ------ 2. Reuse an EXISTING CONNECTION FOR THE REQUESTED SYSTEM ------------
' Build the GuiConnection.Description the target system would carry. SAP GUI
' sets this to either the SAP Logon Pad entry name (OpenConnection path) or
' the connection string (OpenConnectionByConnectionString path). We compute
' both forms and accept either as a match -- that way a connection opened
' previously via the OTHER path still hits the reuse fast path.
Dim sExpectedDesc1, sExpectedDesc2, sExpectedDesc3
sExpectedDesc1 = "" : sExpectedDesc2 = "" : sExpectedDesc3 = ""
If eDesc <> "" Then sExpectedDesc1 = eDesc
If eMsrv <> "" And eSid <> "" Then
    Dim eGrpMatch : eGrpMatch = eGrp
    If eGrpMatch = "" Then eGrpMatch = " "
    sExpectedDesc2 = "/M/" & eMsrv & "/G/" & eGrpMatch & "/S/" & eSid
End If
If eSrv <> "" And SAP_SYSNR <> "" Then
    Dim sPortMatch : sPortMatch = CStr(3200 + CInt(SAP_SYSNR))
    sExpectedDesc3 = "/H/" & eSrv & "/S/" & sPortMatch
End If

' Two-tier match strategy:
'   (1) Identity match on oSession.Info (SystemName + Client + User). Two
'       endpoint shapes (pad-entry vs /M/.../G/.../S/... vs /H/.../S/...)
'       for the SAME backend produce different GuiConnection.Description
'       strings but the same Info, so identity catches the duplicate-tab
'       case the description-only match used to miss.
'   (2) Description-equality fallback. Covers sessions still on SAPMSYST
'       where Info is unreadable for ~500ms after open, and the legacy
'       no-SID profile case where eSysName is empty.
Set oSession = Nothing
Dim oCandidate, oSessIter, oSessInfo
Dim oLoginScreenCheck
Dim sCandDesc, bSystemMatch
Dim oFirstSes, oCandInfo
Dim sCandSys, sCandClient, sCandUser
On Error Resume Next
For Each oCandidate In oApplication.Children
    Err.Clear
    bSystemMatch = False
    sCandDesc = oCandidate.Description

    ' (1) Identity match.
    If oCandidate.Children.Count > 0 Then
        Set oFirstSes = oCandidate.Children(0)
        Err.Clear
        Set oCandInfo = oFirstSes.Info
        If Err.Number = 0 And Not (oCandInfo Is Nothing) Then
            sCandSys    = oCandInfo.SystemName
            sCandClient = oCandInfo.Client
            sCandUser   = oCandInfo.User
            If (eSysName = "" Or StrComp(sCandSys, eSysName, vbTextCompare) = 0) _
               And StrComp(sCandClient, SAP_CLIENT, vbTextCompare) = 0 _
               And StrComp(sCandUser, SAP_USER, vbTextCompare) = 0 Then
                bSystemMatch = True
            End If
        End If
        Err.Clear
    End If

    ' (2) Description-equality fallback.
    If Not bSystemMatch Then
        If sExpectedDesc1 <> "" And sCandDesc = sExpectedDesc1 Then bSystemMatch = True
        If sExpectedDesc2 <> "" And sCandDesc = sExpectedDesc2 Then bSystemMatch = True
        If sExpectedDesc3 <> "" And sCandDesc = sExpectedDesc3 Then bSystemMatch = True
    End If

    If bSystemMatch Then
        ' Prefer a session at the login screen (we'll fill credentials below).
        ' If none, take the first session -- it's already logged in for THIS
        ' system, so the bOnLogin check in Step 4 will see "Already logged in".
        For Each oSessIter In oCandidate.Children
            Err.Clear
            Set oLoginScreenCheck = oSessIter.findById("wnd[0]/usr/txtRSYST-MANDT")
            If Err.Number = 0 And Not (oLoginScreenCheck Is Nothing) Then
                Set oSession = oSessIter
                WScript.Echo "INFO: Reusing login-screen session of existing connection '" & sCandDesc & "'."
                Exit For
            End If
            Err.Clear
        Next
        If oSession Is Nothing And oCandidate.Children.Count > 0 Then
            Set oSession = oCandidate.Children(0)
            WScript.Echo "INFO: Reusing already-logged-in session of existing connection '" & sCandDesc & "'."
        End If
    End If
    If Not (oSession Is Nothing) Then Exit For
Next
On Error GoTo 0

' ------ 3. Open connection (only if no login-screen session found) -----------
If oSession Is Nothing Then
    If eDesc <> "" Then
        ' Path A: Use SAP Logon pad entry name
        WScript.Echo "INFO: Opening connection via SAP Logon: " & eDesc
        On Error Resume Next
        Dim oConnA
        Set oConnA = oApplication.OpenConnection(eDesc, True)
        If Err.Number <> 0 Then
            WScript.Echo "ERROR: Could not open connection '" & eDesc & "': " & Err.Description & vbCrLf & _
                         "       Verify the entry name matches exactly what is in SAP Logon pad (case-sensitive)."
            WScript.Quit 1
        End If
        On Error GoTo 0
    ElseIf eMsrv <> "" And eSrv = "" Then
        ' Path B: Load-balanced via Message Server + Logon Group + System ID
        ' Connection string shape: /M/<msgsrv>/G/<grp>/S/<sysid>
        ' LogonGroup defaults to "SPACE" (literal one-space) when blank.
        If eSid = "" Then
            WScript.Echo "ERROR: Load-balanced login requires SAP_SYSTEM_ID (R3NAME / 3-letter SID)." & vbCrLf & _
                         "       Set system_id on the connection profile."
            WScript.Quit 1
        End If
        Dim eGrpEff : eGrpEff = eGrp
        If eGrpEff = "" Then eGrpEff = " "
        Dim sConnStrLB
        sConnStrLB = "/M/" & eMsrv & "/G/" & eGrpEff & "/S/" & eSid
        WScript.Echo "INFO: Opening load-balanced connection: " & sConnStrLB
        On Error Resume Next
        Dim oConnLB
        Set oConnLB = oApplication.OpenConnectionByConnectionString(sConnStrLB, True)
        If Err.Number <> 0 Then
            WScript.Echo "ERROR: Could not open load-balanced connection '" & sConnStrLB & "': " & Err.Description
            WScript.Quit 1
        End If
        On Error GoTo 0
    Else
        ' Path C: Direct connection via Application Server + System Number
        If eSrv = "" Then
            WScript.Echo "ERROR: No endpoint configured. Set one of:" & vbCrLf & _
                         "       sap_logon_description  (SAP Logon pad entry)" & vbCrLf & _
                         "       sap_message_server     (load-balanced + sap_system_id)" & vbCrLf & _
                         "       sap_application_server (direct + sap_system_number)"
            WScript.Quit 1
        End If
        Dim sPort, sConnStr
        sPort = CStr(3200 + CInt(SAP_SYSNR))
        sConnStr = "/H/" & eSrv & "/S/" & sPort
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

    ' Compute the expected GuiConnection.Description for the connection we
    ' just opened so the wait loop only picks a session belonging to THAT
    ' connection. Without this filter, a pre-existing already-logged-in
    ' connection (e.g. from an earlier /sap-login in the same session) would
    ' be picked instead, and Step 4 would print a false "Already logged in"
    ' while the newly opened connection sits stuck on SAPMSYST.
    Dim sNewConnDesc
    If eDesc <> "" Then
        sNewConnDesc = eDesc
    ElseIf eMsrv <> "" And eSrv = "" Then
        sNewConnDesc = sConnStrLB
    Else
        sNewConnDesc = sConnStr
    End If

    ' Wait for a session to become available on the NEW connection.
    Set oSession = Nothing
    Dim iWait
    For iWait = 1 To 30
        WScript.Sleep 1000
        On Error Resume Next
        Set oApplication = oSAPGUI.GetScriptingEngine
        For Each oCandidate In oApplication.Children
            If oCandidate.Description = sNewConnDesc Then
                For Each oSessIter In oCandidate.Children
                    Set oSession = oSessIter
                    Exit For
                Next
                If Not (oSession Is Nothing) Then Exit For
            End If
        Next
        On Error GoTo 0
        If Not (oSession Is Nothing) Then Exit For
    Next

    If oSession Is Nothing Then
        WScript.Echo "ERROR: Could not obtain a SAP GUI session."
        WScript.Quit 1
    End If

    ' Defense-in-depth: assert the freshly-opened session belongs to the
    ' requested SAP system. Catches any regression where the wait loop
    ' attaches to an unrelated already-logged-in connection. Silent when
    ' eSysName is empty (legacy / no-SID profile) or when Info is still
    ' unreadable on SAPMSYST (Step 4 will surface the wrong-system case
    ' via its login-screen check).
    If eSysName <> "" Then
        On Error Resume Next
        Err.Clear
        Dim oNewInfo
        Set oNewInfo = oSession.Info
        If Err.Number = 0 And Not (oNewInfo Is Nothing) Then
            If StrComp(oNewInfo.SystemName, eSysName, vbTextCompare) <> 0 Then
                WScript.Echo "WARN: Attached session SystemName='" & oNewInfo.SystemName & "' does not match requested '" & eSysName & "'."
                WScript.Quit 2
            End If
        End If
        Err.Clear
        On Error GoTo 0
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

        ' ---- Handle any post-credential popup, discriminating by control id ----
        ' The pre-fix code blind-Entered ANY wnd[1], which silently dismissed a
        ' password-expired / system dialog and then reported SUCCESS on an unusable
        ' screen (Audit P7). Identify the popup by stable DDIC control id:
        '   * Password-change/expired (pwdRSYST-NCODE1) -> hard ERROR; do NOT
        '     dismiss (the logon is not usable until a new password is set).
        '   * Multiple-logon warning (radMULTI_LOGON_OPT*) -> accept with Enter.
        '   * Anything else (e.g. a benign system-message announcement) -> Enter
        '     once to clear it; the login is re-verified below regardless.
        On Error Resume Next
        If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
            Dim oPwdExpired, oMultiLogon, sPopTitle
            Set oPwdExpired = oSession.findById("wnd[1]/usr/pwdRSYST-NCODE1", False)
            Set oMultiLogon = oSession.findById("wnd[1]/usr/radMULTI_LOGON_OPT1", False)
            If oMultiLogon Is Nothing Then Set oMultiLogon = oSession.findById("wnd[1]/usr/radMULTI_LOGON_OPT2", False)
            If Not (oPwdExpired Is Nothing) Then
                On Error GoTo 0
                WScript.Echo "ERROR: SAP requires a password change for user '" & SAP_USER & "' (password expired/initial). Set a new password interactively in SAP GUI, then re-run /sap-login. The dialog was NOT auto-dismissed."
                WScript.Quit 1
            ElseIf Not (oMultiLogon Is Nothing) Then
                WScript.Echo "INFO: Multiple-logon warning - continuing with this logon."
                oSession.findById("wnd[1]").sendVKey VKEY_ENTER
                WScript.Sleep 1500
            Else
                sPopTitle = ""
                sPopTitle = oSession.findById("wnd[1]").Text
                WScript.Echo "INFO: Clearing post-credential popup [" & sPopTitle & "] - login re-verified below."
                oSession.findById("wnd[1]").sendVKey VKEY_ENTER
                WScript.Sleep 1500
            End If
        End If
        Err.Clear
        On Error GoTo 0

        ' ---- Verify login succeeded (locale-independent) ----
        ' Success requires BOTH that the login dynpro is gone AND that no
        ' Error/Abend is pending on the status bar. The pre-fix code checked only
        ' "is the login field gone?" and, on failure, printed a generic
        ' "check password" line that DISCARDED the real status text -- so an
        ' account lock read as a wrong password and invited a retry that drove
        ' further failed-logon counts (Audit P7). MessageType is locale-independent;
        ' the translated text is surfaced only as a diagnostic.
        Dim oStillLogin, bStillLogin, sLoginSbar, sLoginSbarType
        sLoginSbar = "" : sLoginSbarType = ""
        On Error Resume Next
        Set oStillLogin = oSession.findById("wnd[0]/usr/txtRSYST-MANDT", False)
        bStillLogin = Not (oStillLogin Is Nothing)
        sLoginSbar     = oSession.findById("wnd[0]/sbar").Text
        sLoginSbarType = oSession.findById("wnd[0]/sbar").MessageType
        Err.Clear
        On Error GoTo 0
        If bStillLogin Then
            If LCase(sLoginSbarType) = "e" Or LCase(sLoginSbarType) = "a" Then
                WScript.Echo "ERROR: Login rejected by SAP: " & sLoginSbar & " [MessageType " & sLoginSbarType & "]. Do NOT retry blindly -- if this is an account lock, repeated attempts extend it."
            Else
                WScript.Echo "ERROR: Login did not complete (still on the logon screen). Status: " & sLoginSbar
            End If
            WScript.Quit 1
        End If
        If LCase(sLoginSbarType) = "e" Or LCase(sLoginSbarType) = "a" Then
            WScript.Echo "ERROR: Logon screen cleared but SAP reported [" & sLoginSbarType & "]: " & sLoginSbar
            WScript.Quit 1
        End If
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
