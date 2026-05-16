' =============================================================================
' sap_session_broker_com.vbs
' -----------------------------------------------------------------------------
' SAP COM helper for sap_session_broker.ps1.
'
' The broker is written in PowerShell for cross-process mutex / JSON handling,
' but PowerShell 7+ / .NET 5+ cannot bind to the SAP GUI Scripting Engine
' (it's a 32-bit out-of-proc COM server, and GetActiveObject is removed).
' Even 32-bit Windows PowerShell 5.1 fails because the ProgID isn't in ROT.
' VBScript run via 32-bit cscript binds fine. So the broker shells out here
' for every COM operation.
'
' MULTI-CONNECTION CONTRACT (Phase 3.5 onwards)
' ---------------------------------------------
' Every command treats `oApp.Children` as a multi-element collection.
' INFO walks all connections. SPAWN/RESET/PROBE either receive a connection-
' qualified path (e.g. /app/con[1]/ses[2]) or a connection path (e.g.
' /app/con[1]) — there is no implicit "first connection" fallback.
'
' Commands (one or two argv args, output one line of JSON):
'
'   INFO                       -- list every connection with all its sessions
'     Output:
'       {"ok":true,"connections":[
'         {"connection_path":"/app/con[0]",
'          "description":"S4HANA_1909_MICHAELLI",
'          "system_name":"S4D","client":"100","user":"MICHAELLI",
'          "language":"EN","logon_id":"000C29...",
'          "sessions":[ {"path":"/app/con[0]/ses[0]","session_number":1,...}, ... ]},
'         {"connection_path":"/app/con[1]", ...},
'         ...
'       ]}
'     On failure: {"ok":false,"error":"<reason>"}
'
'   SPAWN <connection_path>    -- spawn a new session on a SPECIFIC connection
'     Output: {"ok":true,"connection_path":"/app/con[N]","path":"/app/con[N]/ses[M]","session_number":K}
'         or: {"ok":false,"error":"<reason>"}
'
'   RESET <session_path>       -- send /n to a session (back to Easy Access)
'     Output: {"ok":true} or {"ok":false,"error":"<reason>"}
'
'   PROBE <session_path>       -- single-session info (used to verify a claim)
'     Output: {"ok":true,"path":"...","transaction":"...","screen":N,"has_popup":bool,
'              "program":"...","session_number":N}
'         or: {"ok":false,"error":"gone"}                    if findById fails
'
'   CLOSE <session_path>       -- close a session (for skills that created it
'                                   themselves; broker's release with
'                                   -WasCreated calls this instead of RESET).
'     Output: {"ok":true} or {"ok":false,"error":"<reason>"}
'
' Exit codes:
'   0  -- success
'   1  -- usage error
'   2  -- SAP GUI not running / scripting unavailable
'   3  -- command-specific failure (details in JSON "error" field)
' =============================================================================
Option Explicit

If WScript.Arguments.Count < 1 Then
    WScript.StdOut.WriteLine "{""ok"":false,""error"":""usage: sap_session_broker_com.vbs <CMD> [args]""}"
    WScript.Quit 1
End If

Dim sCmd : sCmd = UCase(WScript.Arguments(0))

' --- Attach to SAP GUI ----------------------------------------------------
Dim oSAP, oApp
On Error Resume Next
Set oSAP = GetObject("SAPGUI")
If Err.Number <> 0 Or oSAP Is Nothing Then
    WScript.StdOut.WriteLine "{""ok"":false,""error"":""SAP GUI not running""}"
    WScript.Quit 2
End If
Err.Clear
Set oApp = oSAP.GetScriptingEngine
If Err.Number <> 0 Or oApp Is Nothing Then
    WScript.StdOut.WriteLine "{""ok"":false,""error"":""scripting engine unavailable""}"
    WScript.Quit 2
End If
Err.Clear
On Error GoTo 0

If oApp.Children.Count = 0 Then
    WScript.StdOut.WriteLine "{""ok"":false,""error"":""no SAP GUI connection""}"
    WScript.Quit 2
End If

' Note: we deliberately do NOT bind a default connection here. Each command
' picks its own connection from argv or walks all connections explicitly.

' --- JSON-safe quoting helper ---------------------------------------------
Function J(s)
    Dim t : t = "" & s
    t = Replace(t, "\", "\\")
    t = Replace(t, """", "\""")
    t = Replace(t, Chr(13), "\r")
    t = Replace(t, Chr(10), "\n")
    t = Replace(t, Chr(9),  "\t")
    J = t
End Function

' --- Helper: does a session have a wnd[1] popup? --------------------------
Function HasPopup(oSes)
    On Error Resume Next
    Dim w : Set w = oSes.findById("wnd[1]", False)
    On Error GoTo 0
    HasPopup = Not (w Is Nothing)
End Function

' --- Helper: parse one segment from a /M/<msrv>/G/<grp>/S/<sid> string -----
Function ParseConnFlag(sConn, sFlag)
    ParseConnFlag = ""
    If sConn = "" Then Exit Function
    Dim p : p = Split(sConn, "/")
    Dim i
    For i = 0 To UBound(p) - 1
        If UCase(p(i)) = UCase(sFlag) Then
            ParseConnFlag = p(i + 1)
            Exit Function
        End If
    Next
End Function

' --- Helper: serialise one session as JSON --------------------------------
' Adds 'program' alongside the existing fields so the broker can record
' a stuck-screen marker (Program / ScreenNumber) when a skill fails mid-flow.
Function SessionJson(oSes)
    Dim sId, sTxn, nScr, bPop, nNum, sProg
    sId  = "" : sTxn = "" : nScr = 0 : bPop = False : nNum = 0 : sProg = ""
    On Error Resume Next
    sId   = oSes.Id
    sTxn  = oSes.Info.Transaction
    nScr  = oSes.Info.ScreenNumber
    nNum  = oSes.Info.SessionNumber
    sProg = oSes.Info.Program
    On Error GoTo 0
    bPop = HasPopup(oSes)
    SessionJson = "{""path"":""" & J(sId) & _
                  """,""session_number"":" & nNum & _
                  ",""transaction"":""" & J(sTxn) & _
                  """,""program"":""" & J(sProg) & _
                  """,""screen"":" & nScr & _
                  ",""has_popup"":" & LCase(CStr(bPop)) & "}"
End Function

' --- Helper: emit one connection block, with all its sessions -------------
' Now also emits message_server, logon_group, system_id, application_server,
' system_number so sap_login_select.ps1 can 4-step-compare active connections
' against saved profiles. Reads them from GuiSessionInfo (per the SAP help
' reference) and falls back to parsing GuiConnection.Description for the
' load-balanced /M/<msrv>/G/<grp>/S/<sid> case where Info.MessageServer is
' sometimes left blank.
Function ConnectionJson(oCon)
    Dim sId, sDesc, sSys, sClnt, sUser, sLang, sLogon
    Dim sMsrv, sGrp, sSid, sAsrv, sSysnr
    sId    = "" : sDesc = "" : sSys = "" : sClnt = "" : sUser = "" : sLang = "" : sLogon = ""
    sMsrv  = "" : sGrp  = "" : sSid = "" : sAsrv = "" : sSysnr = ""
    On Error Resume Next
    sId    = oCon.Id
    sDesc  = oCon.Description
    On Error GoTo 0

    ' (system_name/client/user/language/logon_id/...) live on each session's
    ' Info struct. They are identical across all sessions of one connection
    ' (per-logon), so we read from the first available session.
    If oCon.Children.Count > 0 Then
        Dim oFirst : Set oFirst = oCon.Children(0)
        On Error Resume Next
        sSys   = oFirst.Info.SystemName
        sClnt  = oFirst.Info.Client
        sUser  = oFirst.Info.User
        sLang  = oFirst.Info.Language
        sLogon = oFirst.Info.SystemSessionId
        sMsrv  = oFirst.Info.MessageServer
        sGrp   = oFirst.Info.Group
        sAsrv  = oFirst.Info.ApplicationServer
        sSysnr = oFirst.Info.SystemNumber
        On Error GoTo 0
    End If

    ' Fallbacks from the connection-string description: SAP GUI sometimes
    ' leaves MessageServer / Group / SystemNumber blank on GuiSessionInfo
    ' even when the connection was opened via /M/.../G/.../S/...
    If sMsrv  = "" Then sMsrv  = ParseConnFlag(sDesc, "M")
    If sGrp   = "" Then sGrp   = ParseConnFlag(sDesc, "G")
    If sSid   = "" Then sSid   = sSys     ' system_id == system_name on most setups
    If sSysnr = "" Then
        Dim sPort : sPort = ParseConnFlag(sDesc, "S")
        If IsNumeric(sPort) Then
            Dim nP : nP = CInt(sPort)
            If nP >= 3200 And nP <= 3298 Then sSysnr = Right("0" & CStr(nP - 3200), 2)
        End If
    End If

    Dim sOut, oS, bFirst : bFirst = True
    sOut = "{""connection_path"":""" & J(sId) & _
           """,""description"":"""        & J(sDesc) & _
           """,""system_name"":"""        & J(sSys) & _
           """,""client"":"""             & J(sClnt) & _
           """,""user"":"""               & J(sUser) & _
           """,""language"":"""           & J(sLang) & _
           """,""logon_id"":"""           & J(sLogon) & _
           """,""message_server"":"""     & J(sMsrv) & _
           """,""logon_group"":"""        & J(sGrp) & _
           """,""system_id"":"""          & J(sSid) & _
           """,""application_server"":""" & J(sAsrv) & _
           """,""system_number"":"""      & J(sSysnr) & _
           """,""sessions"":["
    For Each oS In oCon.Children
        If bFirst Then bFirst = False Else sOut = sOut & ","
        sOut = sOut & SessionJson(oS)
    Next
    sOut = sOut & "]}"
    ConnectionJson = sOut
End Function

' =========================================================================
Select Case sCmd

    Case "INFO"
        Dim sOut : sOut = "{""ok"":true,""connections"":["
        Dim oCon, bFirstCon : bFirstCon = True
        For Each oCon In oApp.Children
            If bFirstCon Then bFirstCon = False Else sOut = sOut & ","
            sOut = sOut & ConnectionJson(oCon)
        Next
        sOut = sOut & "]}"
        WScript.StdOut.WriteLine sOut
        WScript.Quit 0

    Case "SPAWN"
        If WScript.Arguments.Count < 2 Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""SPAWN requires <connection_path> arg""}"
            WScript.Quit 1
        End If
        Dim sSpawnConn : sSpawnConn = WScript.Arguments(1)
        On Error Resume Next
        Dim oSpawnCon : Set oSpawnCon = oApp.findById(sSpawnConn, False)
        On Error GoTo 0
        If oSpawnCon Is Nothing Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""connection not found: " & J(sSpawnConn) & """}"
            WScript.Quit 3
        End If
        If oSpawnCon.Children.Count >= 6 Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""at cap (6 sessions) on " & J(sSpawnConn) & """}"
            WScript.Quit 3
        End If
        ' Snapshot existing paths so we can identify the newcomer.
        Dim sBefore : sBefore = "|"
        Dim oCS
        For Each oCS In oSpawnCon.Children
            sBefore = sBefore & oCS.Id & "|"
        Next

        Dim oAnchor : Set oAnchor = oSpawnCon.Children(0)
        On Error Resume Next
        ' Park anchor at Easy Access first.
        oAnchor.findById("wnd[0]/tbar[0]/okcd").Text = "/n"
        oAnchor.findById("wnd[0]").sendVKey 0
        WScript.Sleep 600
        ' Spawn via /oSESSION_MANAGER (the OK-code mechanism verified on
        ' S/4HANA 1909 kernel 754; bare /o is a no-op on this build).
        oAnchor.findById("wnd[0]/tbar[0]/okcd").Text = "/oSESSION_MANAGER"
        oAnchor.findById("wnd[0]").sendVKey 0
        On Error GoTo 0
        WScript.Sleep 1500

        Dim oNew : Set oNew = Nothing
        Dim oS2
        For Each oS2 In oSpawnCon.Children
            If InStr(sBefore, "|" & oS2.Id & "|") = 0 Then
                Set oNew = oS2
                Exit For
            End If
        Next
        If oNew Is Nothing Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""spawn did not produce a new session on " & J(sSpawnConn) & """}"
            WScript.Quit 3
        End If
        Dim nNum : nNum = 0
        On Error Resume Next
        nNum = oNew.Info.SessionNumber
        On Error GoTo 0
        WScript.StdOut.WriteLine "{""ok"":true,""connection_path"":""" & J(sSpawnConn) & _
                                 """,""path"":""" & J(oNew.Id) & _
                                 """,""session_number"":" & nNum & "}"
        WScript.Quit 0

    Case "RESET"
        If WScript.Arguments.Count < 2 Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""RESET requires <session_path> arg""}"
            WScript.Quit 1
        End If
        Dim sResetPath : sResetPath = WScript.Arguments(1)
        On Error Resume Next
        Dim oReset : Set oReset = oApp.findById(sResetPath, False)
        On Error GoTo 0
        If oReset Is Nothing Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""session not found: " & J(sResetPath) & """}"
            WScript.Quit 3
        End If
        On Error Resume Next
        oReset.findById("wnd[0]/tbar[0]/okcd").Text = "/n"
        oReset.findById("wnd[0]").sendVKey 0
        Dim sResetErr : sResetErr = ""
        If Err.Number <> 0 Then sResetErr = Err.Description
        On Error GoTo 0
        WScript.Sleep 600
        If sResetErr <> "" Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""" & J(sResetErr) & """}"
            WScript.Quit 3
        End If
        WScript.StdOut.WriteLine "{""ok"":true}"
        WScript.Quit 0

    Case "PROBE"
        If WScript.Arguments.Count < 2 Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""PROBE requires <session_path> arg""}"
            WScript.Quit 1
        End If
        Dim sProbePath : sProbePath = WScript.Arguments(1)
        On Error Resume Next
        Dim oProbe : Set oProbe = oApp.findById(sProbePath, False)
        On Error GoTo 0
        If oProbe Is Nothing Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""gone""}"
            WScript.Quit 3
        End If
        Dim sPJ : sPJ = SessionJson(oProbe)
        ' Strip the leading "{" so we can splice in ok:true.
        WScript.StdOut.WriteLine "{""ok"":true," & Mid(sPJ, 2)
        WScript.Quit 0

    Case "CLOSE"
        ' Close a session by calling oConnection.CloseSession(sessionId). Used
        ' by broker release with -WasCreated when the broker spawned the
        ' session itself (vs claiming an existing free one). Best-effort: SAP
        ' refuses to close the only remaining session of a connection; in
        ' that case we fall back to RESET (drive /n).
        If WScript.Arguments.Count < 2 Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""CLOSE requires <session_path> arg""}"
            WScript.Quit 1
        End If
        Dim sClosePath : sClosePath = WScript.Arguments(1)
        On Error Resume Next
        Dim oCloseSes : Set oCloseSes = oApp.findById(sClosePath, False)
        On Error GoTo 0
        If oCloseSes Is Nothing Then
            ' Already gone — treat as success (idempotent close).
            WScript.StdOut.WriteLine "{""ok"":true,""note"":""already_gone""}"
            WScript.Quit 0
        End If
        ' Walk up to the GuiConnection (parent of GuiSession).
        Dim partsCl : partsCl = Split(sClosePath, "/")
        If UBound(partsCl) < 2 Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""malformed session path: " & J(sClosePath) & """}"
            WScript.Quit 3
        End If
        Dim sCloseConPath : sCloseConPath = "/" & partsCl(1) & "/" & partsCl(2)
        On Error Resume Next
        Dim oCloseCon : Set oCloseCon = oApp.findById(sCloseConPath, False)
        On Error GoTo 0
        If oCloseCon Is Nothing Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""connection not found: " & J(sCloseConPath) & """}"
            WScript.Quit 3
        End If
        ' If this is the only session of the connection, fall back to /n —
        ' SAP refuses to close the last session and the user typically wants
        ' the connection to stay alive for future tasks.
        If oCloseCon.Children.Count <= 1 Then
            On Error Resume Next
            oCloseSes.findById("wnd[0]/tbar[0]/okcd").Text = "/n"
            oCloseSes.findById("wnd[0]").sendVKey 0
            On Error GoTo 0
            WScript.Sleep 600
            WScript.StdOut.WriteLine "{""ok"":true,""note"":""last_session_reset_instead""}"
            WScript.Quit 0
        End If
        On Error Resume Next
        oCloseCon.CloseSession sClosePath
        Dim sCloseErr : sCloseErr = ""
        If Err.Number <> 0 Then sCloseErr = Err.Description
        On Error GoTo 0
        If sCloseErr <> "" Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""" & J(sCloseErr) & """}"
            WScript.Quit 3
        End If
        WScript.StdOut.WriteLine "{""ok"":true}"
        WScript.Quit 0

    Case Else
        WScript.StdOut.WriteLine "{""ok"":false,""error"":""unknown command: " & J(sCmd) & """}"
        WScript.Quit 1

End Select
