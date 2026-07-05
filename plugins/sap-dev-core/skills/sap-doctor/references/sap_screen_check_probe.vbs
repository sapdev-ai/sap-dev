' =============================================================================
' sap_screen_check_probe.vbs
' -----------------------------------------------------------------------------
' Read-only, single-checkpoint golden-screen probe for /sap-doctor --screens.
' Driven per checkpoint by the orchestrator references/sap_screen_check.ps1
' (or once, with all tokens empty, by the SKILL.md Step-1 data-loss guard).
'
' What it does (one checkpoint per invocation):
'   1. Self-resolves the target SAP GUI session (see resolution order below).
'   2. DATA-LOSS GUARD: when a navigation OK-code is supplied, refuses unless
'      the session is idle on an initial screen (SAP Easy Access program
'      SAPLSMTR_NAVIGATION / logon screen SAPMSYST / transaction
'      SESSION_MANAGER) with no modal wnd[1]. It never navigates (/n...) away
'      from a screen that may hold unsaved user data.
'   3. Navigates via the checkpoint's OK-code (/n<tcode> form) when supplied.
'   4. Reads the live screen identity (session.Info.Program + ScreenNumber).
'   5. Tests every required control path with findById(id, False).
'   6. Best-effort restores the session to SAP Easy Access (/n) after a
'      navigated check, so a multi-checkpoint sweep starts each probe idle.
'
' Session resolution order (Tier-3 EXEMPT: this probe self-resolves like
' sap_gui_object_details.vbs instead of including sap_attach_lib.vbs -- it is
' listed in TIER3_EXEMPT_VBS in scripts/check-consistency.mjs):
'   1. %%SESSION_PATH%% token (explicit /app/con[N]/ses[M] from the caller)
'   2. SAPDEV_SESSION_PATH environment variable (the AI-session pin)
'   3. Sole-connection + sole-session auto-default
'   4. Refuse loud (multiple connections/sessions and no explicit path)
'
' Tokens (replaced by the calling wrapper; empty = feature off):
'   %%SESSION_PATH%%   explicit session path, or empty
'   %%OKCODE%%         navigation OK-code, e.g. "/nSE38"; empty = assess-only
'                      (no guard, no navigation -- read the CURRENT screen)
'   %%REQUIRED_IDS%%   pipe-separated findById control paths to test; may be
'                      empty (identity-only probe)
'
' Stdout contract (one parseable line per result; ASCII, key=value):
'   PROBE: session=<path> via=<arg|env|sole>
'   NAVSTATUS: <sbar MessageType>          (only when non-empty after navigate)
'   IDENTITY: program=<pgm> dynpro=<nnn> transaction=<tcode>
'   ID: <findById path> | FOUND
'   ID: <findById path> | MISSING
'   PROBE: restored=/n                     (after a navigated check)
'   PROBE: result=RAN ids_found=<n> ids_missing=<m>
'   REFUSED: <reason>                      (guard / ambiguity refusals)
'   ERROR: <reason>                        (SAP unreachable et al.)
'
' Exit codes:
'   0  probe ran (identity + ID lines emitted; MISSING ids do NOT change the
'      exit code -- the orchestrator computes the drift verdict)
'   2  SAP unreachable (GUI not running, engine unavailable, session gone)
'   3  refused (session busy / not idle, or ambiguous session resolution)
'
' Language independence: control flow uses component IDs, Info.Program /
' Info.Transaction codes and sbar.MessageType only -- never displayed text.
' Run via 32-bit cscript: C:\Windows\SysWOW64\cscript.exe //NoLogo <this>
' =============================================================================
Option Explicit

Dim SESSION_PATH : SESSION_PATH = "%%SESSION_PATH%%"
Dim OKCODE       : OKCODE       = "%%OKCODE%%"
Dim REQUIRED_IDS : REQUIRED_IDS = "%%REQUIRED_IDS%%"

' Unsubstituted-token sentinels, built from Chr(37) ('%') at runtime so the
' wrapper's global token replacement cannot rewrite the comparison strings
' (same idiom as sap_gui_object_details.vbs -- do NOT inline the literal).
Dim PC : PC = Chr(37) & Chr(37)
If SESSION_PATH = PC & "SESSION_PATH" & PC Then SESSION_PATH = ""
If OKCODE       = PC & "OKCODE"       & PC Then OKCODE       = ""
If REQUIRED_IDS = PC & "REQUIRED_IDS" & PC Then REQUIRED_IDS = ""
SESSION_PATH = Trim(SESSION_PATH)
OKCODE       = Trim(OKCODE)
REQUIRED_IDS = Trim(REQUIRED_IDS)

' ---------------------------------------------------------------------------
' Bind the SAP GUI Scripting engine
' ---------------------------------------------------------------------------
Dim oSapGui, oEngine
On Error Resume Next
Set oSapGui = GetObject("SAPGUI")
If Err.Number <> 0 Or oSapGui Is Nothing Then
    WScript.Echo "ERROR: SAP GUI is not running."
    WScript.Quit 2
End If
Err.Clear
Set oEngine = oSapGui.GetScriptingEngine
If Err.Number <> 0 Or oEngine Is Nothing Then
    WScript.Echo "ERROR: SAP GUI Scripting engine not available (enable RZ11 sapgui/user_scripting)."
    WScript.Quit 2
End If
Err.Clear
On Error GoTo 0

' ---------------------------------------------------------------------------
' Resolve the target session (arg -> env -> sole-connection -> refuse loud)
' ---------------------------------------------------------------------------
Dim oSession, sVia
Set oSession = Nothing
sVia = ""

If SESSION_PATH <> "" Then
    Set oSession = ResolveSessionByPath(oEngine, SESSION_PATH)
    If oSession Is Nothing Then
        WScript.Echo "ERROR: No SAP session at explicit path " & SESSION_PATH & "."
        WScript.Quit 2
    End If
    sVia = "arg"
End If

If oSession Is Nothing Then
    Dim sEnvPath
    sEnvPath = ""
    On Error Resume Next
    sEnvPath = CreateObject("WScript.Shell").Environment("PROCESS")("SAPDEV_SESSION_PATH")
    If Err.Number <> 0 Then sEnvPath = "" : Err.Clear
    On Error GoTo 0
    sEnvPath = Trim(sEnvPath)
    If sEnvPath <> "" Then
        Set oSession = ResolveSessionByPath(oEngine, sEnvPath)
        If oSession Is Nothing Then
            WScript.Echo "ERROR: No SAP session at SAPDEV_SESSION_PATH " & sEnvPath & "."
            WScript.Quit 2
        End If
        sVia = "env"
    End If
End If

If oSession Is Nothing Then
    Dim nCon
    nCon = 0
    On Error Resume Next
    nCon = oEngine.Children.Count
    If Err.Number <> 0 Then nCon = 0 : Err.Clear
    On Error GoTo 0
    If nCon = 0 Then
        WScript.Echo "ERROR: No SAP connections attached. Run /sap-login first."
        WScript.Quit 2
    End If
    If nCon > 1 Then
        WScript.Echo "REFUSED: " & nCon & " SAP connections attached; cannot pick one safely. Set SAPDEV_SESSION_PATH or pass an explicit session path."
        WScript.Quit 3
    End If
    Dim oCon, nSes
    Set oCon = oEngine.Children(0)
    nSes = 0
    On Error Resume Next
    nSes = oCon.Children.Count
    If Err.Number <> 0 Then nSes = 0 : Err.Clear
    On Error GoTo 0
    If nSes = 0 Then
        WScript.Echo "ERROR: The attached SAP connection has no sessions."
        WScript.Quit 2
    End If
    If nSes > 1 Then
        WScript.Echo "REFUSED: " & nSes & " sessions open on the sole connection; cannot pick one safely. Set SAPDEV_SESSION_PATH or pass an explicit session path."
        WScript.Quit 3
    End If
    Set oSession = oCon.Children(0)
    sVia = "sole"
End If

WScript.Echo "PROBE: session=" & SafeSessionId(oSession) & " via=" & sVia

' ---------------------------------------------------------------------------
' Data-loss guard + navigation (only when an OK-code was supplied)
' ---------------------------------------------------------------------------
Dim bNavigated : bNavigated = False
If OKCODE <> "" Then
    Dim sCurPgm, sCurTcd, bModal, bIdle
    sCurPgm = SafeInfoProgram(oSession)
    sCurTcd = SafeInfoTransaction(oSession)
    bModal  = HasModalWindow(oSession)
    bIdle   = False
    If Not bModal Then
        If UCase(sCurPgm) = "SAPLSMTR_NAVIGATION" Then bIdle = True
        If UCase(sCurPgm) = "SAPMSYST" Then bIdle = True
        If UCase(sCurTcd) = "SESSION_MANAGER" Then bIdle = True
    End If
    If Not bIdle Then
        WScript.Echo "REFUSED: session not idle (program=" & sCurPgm & " transaction=" & sCurTcd & " modal=" & CStr(bModal) & "); will not navigate away from a screen that may hold user data."
        WScript.Quit 3
    End If

    On Error Resume Next
    oSession.findById("wnd[0]/tbar[0]/okcd").Text = OKCODE
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Could not reach the OK-code field wnd[0]/tbar[0]/okcd (" & Err.Description & ")."
        WScript.Quit 2
    End If
    oSession.findById("wnd[0]").sendVKey 0
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Navigation via OK-code " & OKCODE & " failed (" & Err.Description & ")."
        WScript.Quit 2
    End If
    On Error GoTo 0
    bNavigated = True
    WScript.Sleep 200

    ' Status-bar MessageType after navigation (language-independent code).
    ' E/A usually means the transaction was rejected; the orchestrator uses
    ' this to suppress identity CAPTURE on pending_live checkpoints.
    Dim sNavType : sNavType = SafeSbarType(oSession)
    If sNavType <> "" Then WScript.Echo "NAVSTATUS: " & sNavType
End If

' ---------------------------------------------------------------------------
' Screen identity
' ---------------------------------------------------------------------------
WScript.Echo "IDENTITY: program=" & SafeInfoProgram(oSession) & _
             " dynpro=" & SafeInfoScreenNumber(oSession) & _
             " transaction=" & SafeInfoTransaction(oSession)

' ---------------------------------------------------------------------------
' Required control-ID presence tests
' ---------------------------------------------------------------------------
Dim nFound, nMissing
nFound = 0 : nMissing = 0
If REQUIRED_IDS <> "" Then
    Dim aIds, i, sId, oCtl
    aIds = Split(REQUIRED_IDS, "|")
    For i = 0 To UBound(aIds)
        sId = Trim(aIds(i))
        If sId <> "" Then
            Set oCtl = Nothing
            On Error Resume Next
            Set oCtl = oSession.findById(sId, False)
            If Err.Number <> 0 Then Set oCtl = Nothing : Err.Clear
            On Error GoTo 0
            If oCtl Is Nothing Then
                nMissing = nMissing + 1
                WScript.Echo "ID: " & sId & " | MISSING"
            Else
                nFound = nFound + 1
                WScript.Echo "ID: " & sId & " | FOUND"
            End If
        End If
    Next
End If

' ---------------------------------------------------------------------------
' Restore to SAP Easy Access after a navigated check (best-effort)
' ---------------------------------------------------------------------------
If bNavigated Then RestoreToEasyAccess oSession

WScript.Echo "PROBE: result=RAN ids_found=" & nFound & " ids_missing=" & nMissing
WScript.Quit 0

' =============================================================================
' Helpers
' =============================================================================
Function ResolveSessionByPath(oEng, sPath)
    Set ResolveSessionByPath = Nothing
    Dim o
    Set o = Nothing
    On Error Resume Next
    Set o = oEng.findById(sPath, False)
    If Err.Number <> 0 Then Set o = Nothing : Err.Clear
    On Error GoTo 0
    If Not (o Is Nothing) Then Set ResolveSessionByPath = o
End Function

Function HasModalWindow(oSes)
    HasModalWindow = False
    Dim oW
    Set oW = Nothing
    On Error Resume Next
    Set oW = oSes.findById("wnd[1]", False)
    If Err.Number <> 0 Then Set oW = Nothing : Err.Clear
    On Error GoTo 0
    If Not (oW Is Nothing) Then HasModalWindow = True
End Function

Function SafeInfoProgram(oSes)
    SafeInfoProgram = ""
    On Error Resume Next
    Dim v : v = oSes.Info.Program
    If Err.Number = 0 Then SafeInfoProgram = Trim(CStr(v)) Else Err.Clear
    On Error GoTo 0
End Function

Function SafeInfoScreenNumber(oSes)
    SafeInfoScreenNumber = ""
    On Error Resume Next
    Dim v : v = oSes.Info.ScreenNumber
    If Err.Number = 0 Then SafeInfoScreenNumber = Trim(CStr(v)) Else Err.Clear
    On Error GoTo 0
End Function

Function SafeInfoTransaction(oSes)
    SafeInfoTransaction = ""
    On Error Resume Next
    Dim v : v = oSes.Info.Transaction
    If Err.Number = 0 Then SafeInfoTransaction = Trim(CStr(v)) Else Err.Clear
    On Error GoTo 0
End Function

Function SafeSbarType(oSes)
    SafeSbarType = ""
    On Error Resume Next
    Dim v : v = oSes.findById("wnd[0]/sbar").MessageType
    If Err.Number = 0 Then SafeSbarType = Trim(CStr(v)) Else Err.Clear
    On Error GoTo 0
End Function

Function SafeSessionId(oSes)
    SafeSessionId = ""
    On Error Resume Next
    Dim v : v = oSes.Id
    If Err.Number = 0 Then SafeSessionId = CStr(v) Else Err.Clear
    On Error GoTo 0
End Function

Sub RestoreToEasyAccess(oSes)
    On Error Resume Next
    ' Sweep unexpected modal popups (cap 3) with F12/Cancel so the OK-code
    ' field is reachable; F12 closes popups without committing anything.
    Dim k
    For k = 1 To 3
        If Not HasModalWindow(oSes) Then Exit For
        oSes.findById("wnd[1]").sendVKey 12
        Err.Clear
    Next
    Err.Clear
    oSes.findById("wnd[0]/tbar[0]/okcd").Text = "/n"
    oSes.findById("wnd[0]").sendVKey 0
    If Err.Number <> 0 Then
        WScript.Echo "WARN: could not restore the session to SAP Easy Access via /n (" & Err.Description & ")."
        Err.Clear
    Else
        WScript.Echo "PROBE: restored=/n"
    End If
    On Error GoTo 0
End Sub
