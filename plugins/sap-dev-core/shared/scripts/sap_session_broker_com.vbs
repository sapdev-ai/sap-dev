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
' Commands (single argv arg, output to stdout):
'
'   INFO                       -- list all sessions of /app/con[0]
'     Output: JSON object with logon_id and sessions[].
'       {"ok":true,"logon_id":"...","connection_path":"/app/con[0]","sessions":[
'         {"path":"/app/con[0]/ses[1]","session_number":2,"transaction":"S000","screen":40,"has_popup":false}
'       ]}
'     On failure: {"ok":false,"error":"<reason>"}
'
'   SPAWN                      -- spawn a new session via /oSESSION_MANAGER
'     Output: {"ok":true,"path":"/app/con[0]/ses[N]","session_number":M}
'         or: {"ok":false,"error":"<reason>"}
'
'   RESET <path>               -- send /n to that session (back to Easy Access)
'     Output: {"ok":true} or {"ok":false,"error":"<reason>"}
'
'   PROBE <path>               -- single-session info (used to verify a claim)
'     Output: {"ok":true,"path":"...","transaction":"...","screen":N,"has_popup":bool}
'         or: {"ok":false,"error":"gone"}                    if findById fails
'
' All output is one line of JSON-ish text (no newlines inside values).
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
Dim oSAP, oApp, oCon
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
Set oCon = oApp.Children(0)

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

' --- Helper: serialise one session as JSON --------------------------------
Function SessionJson(oSes)
    Dim sId, sTxn, nScr, bPop, nNum
    sId  = "" : sTxn = "" : nScr = 0 : bPop = False : nNum = 0
    On Error Resume Next
    sId  = oSes.Id
    sTxn = oSes.Info.Transaction
    nScr = oSes.Info.ScreenNumber
    nNum = oSes.Info.SessionNumber
    On Error GoTo 0
    bPop = HasPopup(oSes)
    SessionJson = "{""path"":""" & J(sId) & _
                  """,""session_number"":" & nNum & _
                  ",""transaction"":""" & J(sTxn) & _
                  """,""screen"":" & nScr & _
                  ",""has_popup"":" & LCase(CStr(bPop)) & "}"
End Function

' =========================================================================
Select Case sCmd

    Case "INFO"
        Dim sLogon : sLogon = ""
        On Error Resume Next
        sLogon = oCon.Children(0).Info.SystemSessionId
        On Error GoTo 0

        Dim sOut : sOut = "{""ok"":true,""logon_id"":""" & J(sLogon) & _
                         """,""connection_path"":""" & J(oCon.Id) & _
                         """,""sessions"":["
        Dim oS, bFirst : bFirst = True
        For Each oS In oCon.Children
            If bFirst Then bFirst = False Else sOut = sOut & ","
            sOut = sOut & SessionJson(oS)
        Next
        sOut = sOut & "]}"
        WScript.StdOut.WriteLine sOut
        WScript.Quit 0

    Case "SPAWN"
        If oCon.Children.Count >= 6 Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""at cap (6 sessions)""}"
            WScript.Quit 3
        End If
        ' Snapshot existing paths so we can identify the newcomer.
        Dim sBefore : sBefore = "|"
        Dim oC
        For Each oC In oCon.Children
            sBefore = sBefore & oC.Id & "|"
        Next

        Dim oAnchor : Set oAnchor = oCon.Children(0)
        On Error Resume Next
        ' Park anchor at Easy Access first.
        oAnchor.findById("wnd[0]/tbar[0]/okcd").Text = "/n"
        oAnchor.findById("wnd[0]").sendVKey 0
        WScript.Sleep 600
        ' Spawn.
        oAnchor.findById("wnd[0]/tbar[0]/okcd").Text = "/oSESSION_MANAGER"
        oAnchor.findById("wnd[0]").sendVKey 0
        On Error GoTo 0
        WScript.Sleep 1500

        Dim oNew : Set oNew = Nothing
        Dim oS2
        For Each oS2 In oCon.Children
            If InStr(sBefore, "|" & oS2.Id & "|") = 0 Then
                Set oNew = oS2
                Exit For
            End If
        Next
        If oNew Is Nothing Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""spawn did not produce a new session""}"
            WScript.Quit 3
        End If
        Dim nNum : nNum = 0
        On Error Resume Next
        nNum = oNew.Info.SessionNumber
        On Error GoTo 0
        WScript.StdOut.WriteLine "{""ok"":true,""path"":""" & J(oNew.Id) & _
                                 """,""session_number"":" & nNum & "}"
        WScript.Quit 0

    Case "RESET"
        If WScript.Arguments.Count < 2 Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""RESET requires <path> arg""}"
            WScript.Quit 1
        End If
        Dim sResetPath : sResetPath = WScript.Arguments(1)
        On Error Resume Next
        Dim oReset : Set oReset = oApp.findById(sResetPath, False)
        On Error GoTo 0
        If oReset Is Nothing Then
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""session not found""}"
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
            WScript.StdOut.WriteLine "{""ok"":false,""error"":""PROBE requires <path> arg""}"
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

    Case Else
        WScript.StdOut.WriteLine "{""ok"":false,""error"":""unknown command: " & J(sCmd) & """}"
        WScript.Quit 1

End Select
