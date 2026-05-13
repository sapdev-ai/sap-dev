' =============================================================================
' ensure_sessions.vbs
' -----------------------------------------------------------------------------
' Ensure that the pinned SAP GUI connection has at least N sessions available.
' Used by /sap-gui-skill-scaffold's --parallel pre-flight to spawn extra
' sessions via oCon.CreateSession() so each probe sub-agent has its own.
'
' Usage:
'   cscript //NoLogo ensure_sessions.vbs <connectionPath> <requiredCount>
'
' Example:
'   cscript //NoLogo ensure_sessions.vbs "/app/con[0]" 4
'
' Stdout last line:
'   * "SESSIONS: <existing> -> <total>"  on success
'   * "ERROR: <text>"                    on failure
'
' Caps the total at 6 (SAP's default rdisp/max_alt_modes). If the connection
' already has >= required, no-op and reports the unchanged count. After each
' CreateSession, sleeps 500 ms to give SAP GUI time to open the new window.
'
' Also issues `/n` (OK-Code) to every existing session so each probe starts
' from SAP Easy Access -- avoids the "probe began mid-flow" failure mode.
' =============================================================================
Option Explicit

If WScript.Arguments.Count < 2 Then
    WScript.Echo "ERROR: usage: ensure_sessions.vbs <connectionPath> <requiredCount>"
    WScript.Quit 1
End If

Dim sConnPath  : sConnPath  = WScript.Arguments(0)
Dim nRequired  : nRequired  = CInt(WScript.Arguments(1))
Const MAX_SESSIONS = 6

If nRequired < 1 Then
    WScript.Echo "ERROR: requiredCount must be >= 1"
    WScript.Quit 1
End If
If nRequired > MAX_SESSIONS Then
    WScript.Echo "WARNING: requiredCount " & nRequired & " exceeds SAP default cap " & MAX_SESSIONS & "; capping."
    nRequired = MAX_SESSIONS
End If

Dim oSAP, oApp, oConn
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
Set oConn = oApp.findById(sConnPath, False)
On Error GoTo 0
If oConn Is Nothing Then
    WScript.Echo "ERROR: connection not found: " & sConnPath
    WScript.Quit 2
End If

Dim nHave : nHave = oConn.Children.Count
Dim nNeed : nNeed = nRequired - nHave
If nNeed < 0 Then nNeed = 0

' Create the missing sessions. Two strategies, in order of preference:
'
'   A) oConn.CreateSession  -- the documented SAP GUI Scripting method.
'      Available since SAP GUI 7.20. Some newer SAP GUI builds expose the
'      connection via an `ISapConnectionTarget` interface that does NOT
'      surface CreateSession at the COM level -- a call raises "object
'      doesn't support this property or method".
'
'   B) OK-code "/o" on an existing session of this connection -- the SAP
'      keyboard equivalent of "System > Create New Session". Universally
'      available; works regardless of which COM interface the connection
'      object happens to expose.
'
' We try A first, fall back to B on error. Either way the resulting child
' session is bound to the SAME GuiConnection -- same SID / client / user --
' because both spawning paths are scoped to oConn.
Dim i, anchor, useFallback
useFallback = False

For i = 1 To nNeed
    Dim spawned : spawned = False

    If Not useFallback Then
        On Error Resume Next
        Err.Clear
        oConn.CreateSession
        If Err.Number <> 0 Then
            ' CreateSession not supported on this build -- switch permanently
            ' to the OK-code fallback for the rest of this loop.
            WScript.Echo "WARNING: CreateSession not supported (" & Err.Description & "); falling back to /o OK-code."
            useFallback = True
            Err.Clear
        Else
            spawned = True
        End If
        On Error GoTo 0
    End If

    If Not spawned Then
        ' /oSESSION_MANAGER opens a NEW session running the SAP Easy Access
        ' transaction (the same starting screen probe expects). /o alone
        ' would open a Session List popup -- not what we want. Issue it on
        ' an existing session of this connection; the new session belongs
        ' to the same connection (same SID / client / user) by construction.
        On Error Resume Next
        Err.Clear
        Set anchor = oConn.Children(0)
        anchor.findById("wnd[0]/tbar[0]/okcd").Text = "/oSESSION_MANAGER"
        anchor.findById("wnd[0]").sendVKey 0
        If Err.Number <> 0 Then
            WScript.Echo "ERROR: /oSESSION_MANAGER OK-code fallback failed at iteration " & i & ": " & Err.Description
            WScript.Quit 3
        End If
        On Error GoTo 0
    End If

    WScript.Sleep 700   ' give SAP GUI time to materialise the new window
Next

' Re-check actual count (SAP may have refused silently if at max).
Dim nFinal : nFinal = oConn.Children.Count

' Reset every existing session to SAP Easy Access via /n. Best-effort -- if a
' session is locked by another script, this no-ops for that session.
' Use For Each (the SAP GUI collection rejects numeric indexing in For loops
' on some builds with "Bad index type for collection access").
Dim oS
For Each oS In oConn.Children
    On Error Resume Next
    oS.findById("wnd[0]/tbar[0]/okcd").Text = "/n"
    oS.findById("wnd[0]").sendVKey 0
    On Error GoTo 0
Next

WScript.Sleep 600   ' settle

WScript.Echo "SESSIONS: " & nHave & " -> " & nFinal
WScript.Quit 0
