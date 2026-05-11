' =============================================================================
' sap_gui_security_warmup.vbs  -  Persist SAP GUI Security trust for {work_dir}
'
' Run by /sap-dev-init exactly once per workstation. Drives a benign local
' file IO via the SAP GUI to make the "SAP GUI Security" dialog appear, so
' the parallel sidecar (sap_gui_security_sidecar.ps1) can auto-click "Allow"
' with the "Remember My Decision" checkbox ticked. After this single warmup,
' SAP GUI itself persists the trust decision for the work_dir path in its
' own (version-specific) config — so subsequent skill runs (SE38 source
' upload, SE11 activation log save, SE16N download, etc.) never see the
' dialog.
'
' Why warmup + sidecar in two processes (and why the sidecar is PowerShell, not VBS)
' ----------------------------------------------------------------------------------
' VBS is single-threaded. `oWnd.Hardcopy` blocks waiting for the security
' dialog to be dismissed, so the same script cannot poll and click Allow —
' that would deadlock.
'
' Worse, when the security dialog is modal, the SAP GUI Scripting COM API
' is FULLY SUSPENDED — even a separate cscript process attached to the same
' SAP GUI session cannot see wnd[0] / wnd[1] / etc. (Confirmed empirically
' 2026-05: tree dump while dialog is on screen returns nothing.)
'
' The fix is OS-level automation: the orchestrator (PowerShell, called from
' /sap-dev-init Step 1b) launches `sap_gui_security_sidecar.ps1` FIRST in
' the background. The sidecar uses UI Automation (and SendKeys as fallback)
' to detect and dismiss the dialog at the Windows level, completely
' independent of SAP GUI's Scripting API. The orchestrator then runs this
' warmup, then joins both processes.
'
' Why this approach (versus writing the registry directly)
' --------------------------------------------------------
' SAP GUI's permission store has changed format multiple times across
' releases (7.50/7.60/7.70/7.80) and is undocumented. By driving the dialog
' through its own "Remember" mechanism, we let SAP GUI write its own config
' in whatever format the installed version expects. Result is the same as
' the customer manually clicking through, but automated.
'
' Tokens replaced at run time:
'   %%PROBE_FILE%%   Absolute path the warmup writes to (under {work_dir})
'
' Stdout contract (last line):
'   ALLOWED          -> Hardcopy completed (poller dismissed the dialog or
'                       path was already trusted)
'   NO_GUI           -> no SAP GUI session attached
'   ERROR: <message> -> Hardcopy failed (e.g. trust did not persist, or
'                       group policy denied the access)
' =============================================================================

Option Explicit

Dim PROBE_FILE
PROBE_FILE = "%%PROBE_FILE%%"

Dim oSAPGUI, oApp, oConn, oSess
On Error Resume Next
Set oSAPGUI = GetObject("SAPGUI")
If Err.Number <> 0 Or oSAPGUI Is Nothing Then
    WScript.Echo "ERROR: SAPGUI scripting object not available"
    WScript.Echo "NO_GUI"
    WScript.Quit 2
End If

Set oApp = oSAPGUI.GetScriptingEngine
If Err.Number <> 0 Or oApp Is Nothing Then
    WScript.Echo "ERROR: GetScriptingEngine failed: " & Err.Description
    WScript.Echo "NO_GUI"
    WScript.Quit 2
End If

If oApp.Connections.Count < 1 Then
    WScript.Echo "ERROR: No SAP GUI connections open"
    WScript.Echo "NO_GUI"
    WScript.Quit 2
End If

Set oConn = oApp.Connections(0)
If oConn.Sessions.Count < 1 Then
    WScript.Echo "ERROR: No SAP GUI sessions open"
    WScript.Echo "NO_GUI"
    WScript.Quit 2
End If
Set oSess = oConn.Sessions(0)
On Error GoTo 0

' Trigger the security check via Hardcopy. The poller (running in parallel)
' will detect wnd[1] and click Allow + Remember. If the path is already
' trusted, Hardcopy completes silently and the poller times out.
On Error Resume Next
Dim oWnd, sError
Set oWnd = oSess.findById("wnd[0]")
If oWnd Is Nothing Then
    WScript.Echo "ERROR: Cannot resolve wnd[0]"
    WScript.Quit 1
End If

oWnd.Hardcopy PROBE_FILE
sError = Err.Description
Err.Clear
On Error GoTo 0

' Clean up the probe file (harmless if it doesn't exist).
Dim oFSO
Set oFSO = CreateObject("Scripting.FileSystemObject")
On Error Resume Next
If oFSO.FileExists(PROBE_FILE) Then oFSO.DeleteFile PROBE_FILE, True
On Error GoTo 0

If Len(sError) = 0 Then
    WScript.Echo "ALLOWED"
    WScript.Quit 0
Else
    WScript.Echo "ERROR: Hardcopy failed: " & sError
    WScript.Echo "ERROR: This usually means the customer clicked Deny, the poller missed the dialog, or group policy is overriding the security setting."
    WScript.Quit 1
End If
