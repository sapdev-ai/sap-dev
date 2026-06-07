' =============================================================================
' sap_close_connection.vbs  -  Close a specific SAP GUI connection by path.
'
' Used by /sap-login Step 0.9 when a requested logon language differs from an
' active connection's language: the connection is closed here, then the normal
' login flow (sap_login.vbs) reopens it fresh in the requested language.
' Logon language is fixed at logon time, so a full re-logon is the only way to
' change it -- you cannot re-language an established session in place.
'
' Usage:
'   C:/Windows/SysWOW64/cscript.exe //NoLogo sap_close_connection.vbs "/app/con[0]"
'   A full session path (/app/con[N]/ses[M]) is accepted too -- it is reduced
'   to its /app/con[N] connection ancestor before closing.
'
' Closing a GuiConnection drops ALL of its sessions, so the caller MUST have
' confirmed with the user first (Step 0.9 does, unless --force).
'
' Stdout last line is exactly one of:
'   CLOSED: <connection_path>     -- success (a connection was removed)
'   ERROR: <text>                 -- failure
'
' Exit codes: 0 closed, 2 SAP unreachable / scripting unavailable,
'             3 bad arg / connection not found / close not confirmed.
'
' Language-independence (per language_independence_rules.md): pure property /
' method calls on GuiApplication / GuiConnection -- no menu text, no status-bar
' string parsing, no branching on translated UI.
'
' Tier-3 note: this is a connection-level (not session-level) bootstrap helper,
' like sap_login_capture_active_session.vbs -- it takes a connection path
' directly and does NOT use the AttachSapSession() session contract. It is
' listed in TIER3_EXEMPT_VBS in scripts/check-consistency.mjs for that reason.
' =============================================================================
Option Explicit

Dim sArg : sArg = ""
If WScript.Arguments.Count >= 1 Then sArg = Trim(WScript.Arguments(0))
If sArg = "" Then
    WScript.Echo "ERROR: no connection path supplied"
    WScript.Quit 3
End If

' Reduce a session path (/app/con[N]/ses[M]) to its connection (/app/con[N]).
Dim sConnPath : sConnPath = sArg
Dim iSes : iSes = InStr(sConnPath, "/ses[")
If iSes > 0 Then sConnPath = Left(sConnPath, iSes - 1)

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

' --- resolve the connection -------------------------------------------------
Dim oConn
On Error Resume Next
Set oConn = oApp.findById(sConnPath, False)
On Error GoTo 0
If oConn Is Nothing Then
    WScript.Echo "ERROR: connection not found: " & sConnPath
    WScript.Quit 3
End If

' Defensive: never call CloseConnection on a session / window object.
Dim sType : sType = ""
On Error Resume Next
sType = oConn.Type
On Error GoTo 0
If sType <> "GuiConnection" Then
    WScript.Echo "ERROR: " & sConnPath & " is a " & sType & ", not a GuiConnection"
    WScript.Quit 3
End If

' --- close ------------------------------------------------------------------
' Verify success by connection COUNT, not by re-looking-up the path: SAP GUI
' renumbers the remaining connections after a close, so /app/con[N] may now
' resolve to a DIFFERENT (still-open) connection. A count decrease is the
' renumber-proof signal that our target was torn down.
Dim nBefore : nBefore = oApp.Children.Count

On Error Resume Next
oConn.CloseConnection
Dim nCloseErr      : nCloseErr      = Err.Number
Dim sCloseErrDesc  : sCloseErrDesc  = Err.Description
On Error GoTo 0
If nCloseErr <> 0 Then
    WScript.Echo "ERROR: CloseConnection failed: " & sCloseErrDesc
    WScript.Quit 3
End If

Dim nAfter, iWait
nAfter = nBefore
For iWait = 1 To 10
    WScript.Sleep 300
    On Error Resume Next
    nAfter = oApp.Children.Count
    On Error GoTo 0
    If nAfter < nBefore Then Exit For
Next

If nAfter >= nBefore Then
    WScript.Echo "ERROR: connection still present after CloseConnection (a logoff confirmation popup may have blocked it): " & sConnPath
    WScript.Quit 3
End If

WScript.Echo "CLOSED: " & sConnPath
WScript.Quit 0
