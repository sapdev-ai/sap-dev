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

' Create the missing sessions. Three strategies, in order of preference:
'
'   A) oConn.CreateSession  -- the documented SAP GUI Scripting method.
'      Available since SAP GUI 7.20. Some newer SAP GUI builds expose the
'      connection via an `ISapConnectionTarget` interface that does NOT
'      surface CreateSession at the COM level -- a call raises "object
'      doesn't support this property or method".
'
'   B) OK-code "/o" (no transaction code) on an existing session of this
'      connection -- the SAP keyboard equivalent of "System > Create New
'      Session". Opens a fresh session at SAP Easy Access. Universally
'      available across kernels.
'
'   C) OK-code "/oSESSION_MANAGER" -- last-ditch. Some 1909 builds ignore
'      bare "/o" but accept "/oSMEN" / "/oSESSION_MANAGER" as a transaction
'      launch.
'
' We try A first, fall back to B on error, and to C if B also no-ops.
' Either way the resulting child session is bound to the SAME GuiConnection
' (same SID / client / user) because every spawn is scoped to oConn.
'
' CRITICAL: each spawn attempt is followed by a poll of oConn.Children.Count
' to confirm the count actually increased. Without this, /o silently
' fails when the anchor session is mid-flow on a non-Easy-Access screen
' (the OK-code field gets buried under whatever popup is up) and we
' silently iterate without spawning anything. Today's symptom was
' "SESSIONS: 2 -> 2" with no error -- that is what this loop fixes.
Dim i, anchor, useFallback, beforeCount, afterCount, spawned
useFallback = False

For i = 1 To nNeed
    spawned = False
    beforeCount = oConn.Children.Count

    ' --- Strategy A: oConn.CreateSession ---------------------------------------
    If Not useFallback Then
        On Error Resume Next
        Err.Clear
        oConn.CreateSession
        If Err.Number <> 0 Then
            WScript.Echo "WARNING: CreateSession not supported (" & Err.Description & "); falling back to OK-code."
            useFallback = True
            Err.Clear
        End If
        On Error GoTo 0
        WScript.Sleep 700
        If oConn.Children.Count > beforeCount Then spawned = True
    End If

    ' --- Strategy B: OK-code "/o" on the anchor, after parking it at Easy Access -
    If Not spawned Then
        On Error Resume Next
        Err.Clear
        Set anchor = oConn.Children(0)
        ' Park the anchor at Easy Access first -- /o is a no-op (or worse,
        ' a tooltip into a frozen field) when the anchor is on a popup or
        ' edit screen. /n is the universal "abandon current screen and go
        ' back to SAP Easy Access" OK-code.
        anchor.findById("wnd[0]/tbar[0]/okcd").Text = "/n"
        anchor.findById("wnd[0]").sendVKey 0
        WScript.Sleep 400
        anchor.findById("wnd[0]/tbar[0]/okcd").Text = "/o"
        anchor.findById("wnd[0]").sendVKey 0
        If Err.Number <> 0 Then
            WScript.Echo "WARNING: /o OK-code failed at iteration " & i & ": " & Err.Description
            Err.Clear
        End If
        On Error GoTo 0
        WScript.Sleep 700
        If oConn.Children.Count > beforeCount Then spawned = True
    End If

    ' --- Strategy C: OK-code "/oSESSION_MANAGER" (last resort) -----------------
    If Not spawned Then
        On Error Resume Next
        Err.Clear
        Set anchor = oConn.Children(0)
        anchor.findById("wnd[0]/tbar[0]/okcd").Text = "/n"
        anchor.findById("wnd[0]").sendVKey 0
        WScript.Sleep 400
        anchor.findById("wnd[0]/tbar[0]/okcd").Text = "/oSESSION_MANAGER"
        anchor.findById("wnd[0]").sendVKey 0
        If Err.Number <> 0 Then
            WScript.Echo "WARNING: /oSESSION_MANAGER OK-code failed at iteration " & i & ": " & Err.Description
            Err.Clear
        End If
        On Error GoTo 0
        WScript.Sleep 700
        If oConn.Children.Count > beforeCount Then spawned = True
    End If

    ' --- Fail loud rather than silently iterate without spawning ---------------
    If Not spawned Then
        afterCount = oConn.Children.Count
        WScript.Echo "ERROR: failed to spawn additional SAP GUI session at iteration " & i & _
                     " (before=" & beforeCount & " after=" & afterCount & "); aborting."
        WScript.Quit 3
    End If
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

' Enumerate the actual session paths so the scaffolder can dispatch agents
' to real indices rather than assuming /ses[0..N-1] contiguous. SAP can
' allocate non-contiguous indices when sessions are destroyed and re-
' spawned (e.g. after Shift+F3 from initial screen).
Dim sPaths : sPaths = ""
For Each oS In oConn.Children
    If sPaths = "" Then
        sPaths = oS.Id
    Else
        sPaths = sPaths & "," & oS.Id
    End If
Next

WScript.Echo "SESSIONS: " & nHave & " -> " & nFinal
WScript.Echo "PATHS: " & sPaths
WScript.Quit 0
