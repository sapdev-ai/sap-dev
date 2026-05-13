' =============================================================================
' sap_login_capture_active_session.vbs
' -----------------------------------------------------------------------------
' Capture GUI-side metadata for the active SAP GUI session and (optionally)
' present a multi-connection picker. Writes a flat JSON snippet to stdout that
' the caller (PowerShell side of sap-login Step 7) merges with the server-side
' record from sap_rfc_system_info.ps1 into {WORK_TEMP}\sap_active_session.json.
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

' Build a one-line JSON object for a single (conn, sess) pair using its Info.
Function BuildSessionRecord(oConn, oSess, sPath, sPinReason)
    Dim sysName, sysClient, sysUser, sysLang, sysAppServer
    On Error Resume Next
    sysName       = oSess.Info.SystemName
    sysClient     = oSess.Info.Client
    sysUser       = oSess.Info.User
    sysLang       = oSess.Info.Language
    sysAppServer  = oSess.Info.ApplicationServer
    On Error GoTo 0

    Dim guiVer, guiMaj, guiMin, guiPat
    On Error Resume Next
    guiMaj = oApp.MajorVersion
    guiMin = oApp.MinorVersion
    guiPat = oApp.PatchLevel
    guiVer = guiMaj & "." & guiMin & "." & guiPat
    On Error GoTo 0

    Dim s : s = "{"
    s = s & JsonStr("session_path")        & ":" & JsonStr(sPath) & ","
    s = s & JsonStr("system_name")         & ":" & JsonStr(sysName) & ","
    s = s & JsonStr("client")              & ":" & JsonStr(sysClient) & ","
    s = s & JsonStr("user")                & ":" & JsonStr(sysUser) & ","
    s = s & JsonStr("language")            & ":" & JsonStr(sysLang) & ","
    s = s & JsonStr("application_server")  & ":" & JsonStr(sysAppServer) & ","
    s = s & JsonStr("gui_version_raw")     & ":" & JsonStr(guiVer) & ","
    s = s & JsonStr("gui_major")           & ":" & guiMaj & ","
    s = s & JsonStr("gui_minor")           & ":" & guiMin & ","
    s = s & JsonStr("gui_patch")           & ":" & guiPat & ","
    s = s & JsonStr("connection_string")   & ":" & JsonStr(oConn.Description) & ","
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
