' =============================================================================
' sap_login_capture_active_session.vbs
' -----------------------------------------------------------------------------
' Capture GUI-side metadata for the active SAP GUI session and (optionally)
' present a multi-connection picker. Writes a flat JSON snippet to stdout that
' the caller (PowerShell side of sap-login Step 7) merges with the server-side
' record from sap_rfc_system_info.ps1 and persists into the connection
' profile in {work_dir}\runtime\connections.json (via sap_login_select.ps1
' -Action finalize -> Save-SapConnection).
'
' Usage:
'   cscript //NoLogo sap_login_capture_active_session.vbs <pinned-session-id>
'
' If <pinned-session-id> is omitted and there is more than one connection on
' GuiApplication, the script emits "MULTI:<json-of-options>" so the caller can
' present an AskUserQuestion. The caller then re-invokes the script with the
' chosen session id (e.g. "/app/con[1]/ses[0]").
'
' Stdout last line is exactly one of:
'   * JSON record (single line) -- success
'   * MULTI:<json-array>        -- needs caller to disambiguate
'   * ERROR: <text>             -- failure
'
' Notes:
'   * Only GUI-side fields are emitted here. The caller merges these with the
'     RFC-side fields (server_release_marker, software_components, etc.).
'   * Avoid SAP GUI menus / translated text in this script (per
'     language_independence_rules.md). Everything is property reads on
'     GuiApplication / GuiConnection / GuiSession.
' =============================================================================
Option Explicit

Dim sPinned : sPinned = ""
If WScript.Arguments.Count >= 1 Then sPinned = WScript.Arguments(0)

' --- attach to SAP GUI ------------------------------------------------------
Dim oSAP, oApp
On Error Resume Next
Set oSAP = GetObject("SAPGUI")
If Err.Number <> 0 Or oSAP Is Nothing Then
    WScript.Echo "ERROR: SAP GUI not running"
    WScript.Quit 2
End If
Set oApp = oSAP.GetScriptingEngine
If Err.Number <> 0 Or oApp Is Nothing Then
    WScript.Echo "ERROR: SAP GUI scripting engine unavailable"
    WScript.Quit 2
End If
On Error GoTo 0
If oApp.Children.Count = 0 Then
    WScript.Echo "ERROR: no SAP GUI connection"
    WScript.Quit 2
End If

' --- helpers ----------------------------------------------------------------
Function JsonEscape(s)
    Dim t : t = s
    t = Replace(t, "\", "\\")
    t = Replace(t, """", "\""")
    t = Replace(t, vbCrLf, " ")
    t = Replace(t, vbCr,   " ")
    t = Replace(t, vbLf,   " ")
    t = Replace(t, vbTab,  " ")
    JsonEscape = t
End Function

Function JsonStr(s)
    JsonStr = """" & JsonEscape("" & s) & """"
End Function

' Parse "/M/<msgsrv>/G/<grp>/.../S/<sysid>" or "/H/<host>/S/<port>" fragments
' from a connection-string. Returns empty if not present. Used as a fallback
' when GuiSessionInfo.MessageServer is empty (some SAP GUI releases leave
' MessageServer blank even on load-balanced connections; the connection
' description still carries /M/.../G/... segments).
Function ParseConnStringField(sConn, sFlag)
    ParseConnStringField = ""
    If sConn = "" Then Exit Function
    Dim parts : parts = Split(sConn, "/")
    Dim i
    For i = 0 To UBound(parts) - 1
        If UCase(parts(i)) = UCase(sFlag) Then
            ParseConnStringField = parts(i + 1)
            Exit Function
        End If
    Next
End Function

' Build a one-line JSON object for a single (conn, sess) pair using its Info.
' Captures the full identity tuple needed by the multi-profile store:
'   * Logical identity:    SystemName / Client / User / Language
'   * Direct endpoint:     ApplicationServer / SystemNumber
'   * Load-balanced:       MessageServer / Group  (with connection-string fallback)
'   * Runtime state:       Program / ScreenNumber  (for stuck-screen recovery)
' All reads are guarded with On Error Resume Next because not every release
' exposes every property and we don't want one missing field to mask the rest.
Function BuildSessionRecord(oConn, oSess, sPath, sPinReason)
    Dim sysName, sysClient, sysUser, sysLang, sysAppServer
    Dim sysMsgServer, sysGroup, sysSysnr, sysProgram, sysScreen
    sysName = "" : sysClient = "" : sysUser = "" : sysLang = ""
    sysAppServer = "" : sysMsgServer = "" : sysGroup = "" : sysSysnr = ""
    sysProgram = "" : sysScreen = 0

    On Error Resume Next
    sysName       = oSess.Info.SystemName
    sysClient     = oSess.Info.Client
    sysUser       = oSess.Info.User
    sysLang       = oSess.Info.Language
    sysAppServer  = oSess.Info.ApplicationServer
    sysMsgServer  = oSess.Info.MessageServer
    sysGroup      = oSess.Info.Group
    sysSysnr      = oSess.Info.SystemNumber
    sysProgram    = oSess.Info.Program
    sysScreen     = oSess.Info.ScreenNumber
    On Error GoTo 0

    ' MessageServer fallback — some SAP GUI builds leave it blank even on
    ' load-balanced connections, but the GuiConnection.Description carries
    ' /M/<msgsrv>/G/<grp>/S/<sysid>.
    Dim sConnDesc : sConnDesc = ""
    On Error Resume Next
    sConnDesc = oConn.Description
    On Error GoTo 0
    If sysMsgServer = "" Then sysMsgServer = ParseConnStringField(sConnDesc, "M")
    If sysGroup     = "" Then sysGroup     = ParseConnStringField(sConnDesc, "G")
    ' SystemNumber fallback (from /S/<port>: portnum-3200 = sysnr)
    If sysSysnr = "" Then
        Dim sPort : sPort = ParseConnStringField(sConnDesc, "S")
        If IsNumeric(sPort) Then
            Dim nP : nP = CInt(sPort)
            If nP >= 3200 And nP <= 3298 Then sysSysnr = Right("0" & CStr(nP - 3200), 2)
        End If
    End If

    Dim guiVer, guiMaj, guiMin, guiPat
    guiMaj = 0 : guiMin = 0 : guiPat = 0
    On Error Resume Next
    guiMaj = oApp.MajorVersion
    guiMin = oApp.MinorVersion
    guiPat = oApp.PatchLevel
    On Error GoTo 0
    guiVer = guiMaj & "." & guiMin & "." & guiPat

    Dim s : s = "{"
    s = s & JsonStr("session_path")        & ":" & JsonStr(sPath) & ","
    s = s & JsonStr("system_name")         & ":" & JsonStr(sysName) & ","
    s = s & JsonStr("client")              & ":" & JsonStr(sysClient) & ","
    s = s & JsonStr("user")                & ":" & JsonStr(sysUser) & ","
    s = s & JsonStr("language")            & ":" & JsonStr(sysLang) & ","
    s = s & JsonStr("application_server")  & ":" & JsonStr(sysAppServer) & ","
    s = s & JsonStr("system_number")       & ":" & JsonStr(sysSysnr) & ","
    s = s & JsonStr("message_server")      & ":" & JsonStr(sysMsgServer) & ","
    s = s & JsonStr("logon_group")         & ":" & JsonStr(sysGroup) & ","
    s = s & JsonStr("program")             & ":" & JsonStr(sysProgram) & ","
    s = s & JsonStr("screen_number")       & ":" & sysScreen & ","
    s = s & JsonStr("gui_version_raw")     & ":" & JsonStr(guiVer) & ","
    s = s & JsonStr("gui_major")           & ":" & guiMaj & ","
    s = s & JsonStr("gui_minor")           & ":" & guiMin & ","
    s = s & JsonStr("gui_patch")           & ":" & guiPat & ","
    s = s & JsonStr("connection_string")   & ":" & JsonStr(sConnDesc) & ","
    s = s & JsonStr("logon_pad_entry")     & ":" & JsonStr(sConnDesc) & ","
    s = s & JsonStr("pin_reason")          & ":" & JsonStr(sPinReason)
    s = s & "}"
    BuildSessionRecord = s
End Function

' --- branch: pinned vs single vs multi --------------------------------------
Dim nConn : nConn = oApp.Children.Count

If sPinned <> "" Then
    ' Caller already picked a session; just emit its record.
    Dim oPin
    On Error Resume Next
    Set oPin = oApp.findById(sPinned, False)
    On Error GoTo 0
    If oPin Is Nothing Then
        WScript.Echo "ERROR: pinned session not found: " & sPinned
        WScript.Quit 3
    End If
    ' Accept connection-only paths (/app/con[N]) by descending to the first
    ' session. GuiConnection has no .Info, so without this we would silently
    ' return empty SystemName/Client/User/Language because every .Info.* read
    ' is swallowed by On Error Resume Next inside BuildSessionRecord.
    Dim sPinType : sPinType = ""
    On Error Resume Next
    sPinType = oPin.Type
    On Error GoTo 0
    If sPinType = "GuiConnection" Then
        If oPin.Children.Count = 0 Then
            WScript.Echo "ERROR: connection " & sPinned & " has no session"
            WScript.Quit 3
        End If
        Set oPin = oPin.Children(0)
        sPinned = oPin.Id
    End If
    ' Walk up to find the GuiConnection ancestor.
    Dim parts : parts = Split(sPinned, "/")
    Dim conPath : conPath = "/" & parts(1) & "/" & parts(2)   '   /app/con[N]
    Dim oConn : Set oConn = oApp.findById(conPath, False)
    If oConn Is Nothing Then
        WScript.Echo "ERROR: cannot resolve connection for " & sPinned
        WScript.Quit 3
    End If
    WScript.Echo BuildSessionRecord(oConn, oPin, sPinned, "explicit pin")
    WScript.Quit 0
End If

If nConn = 1 Then
    Dim oC : Set oC = oApp.Children(0)
    If oC.Children.Count = 0 Then
        WScript.Echo "ERROR: connection 0 has no session"
        WScript.Quit 3
    End If
    Dim oS : Set oS = oC.Children(0)
    Dim sPath : sPath = "/app/con[0]/ses[0]"
    WScript.Echo BuildSessionRecord(oC, oS, sPath, "auto-picked single connection")
    WScript.Quit 0
End If

' Multi-connection: emit MULTI:<json-array> and exit.
Dim s : s = "["
Dim i, j, oConn2, oSess2
i = 0
For Each oConn2 In oApp.Children
    j = 0
    For Each oSess2 In oConn2.Children
        Dim path2 : path2 = "/app/con[" & i & "]/ses[" & j & "]"
        If Len(s) > 1 Then s = s & ","
        s = s & BuildSessionRecord(oConn2, oSess2, path2, "candidate")
        j = j + 1
    Next
    i = i + 1
Next
s = s & "]"
WScript.Echo "MULTI:" & s
WScript.Quit 0
