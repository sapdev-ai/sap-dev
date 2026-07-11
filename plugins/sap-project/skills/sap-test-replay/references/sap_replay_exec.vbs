' ============================================================================
' sap_replay_exec.vbs  -  generic segment interpreter for /sap-test-replay
'
' Executes ONE compiled GUI segment (a flat TSV of steps) against the attached
' SAP session. Release variance lives in the scenario DATA, not this VBS. Per
' step: dispatch the action by control ID, then POLL session.Info.Program/
' ScreenNumber until it matches the step's guard (screen-identity-keyed wait -
' never a fixed sleep). Fail-loud, language-independent (control IDs + VKeys +
' MessageType, never displayed text).
'
' Output (parsed by sap_replay_report.ps1):
'   REPLAY: step=<n> result=<PASS|REPLAY_ERROR> [reason=<GUARD|POPUP|ACTION>] detail=..
'   MSG:    step=<n> msgid=<..> msgno=<..> msgty=<S|W|E|I|A> detail=..
' Tokens: %%SESSION_PATH%% %%ATTACH_LIB_VBS%% %%SESSION_LOCK_VBS%% %%STEPS_FILE%%
' 32-bit cscript only.
' ============================================================================
Option Explicit
Const SESSION_PATH = "%%SESSION_PATH%%"
Const STEPS_FILE   = "%%STEPS_FILE%%"

Dim oFso : Set oFso = CreateObject("Scripting.FileSystemObject")
ExecuteGlobal oFso.OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal oFso.OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

Dim oSession : Set oSession = AttachSapSession(SESSION_PATH)
If oSession Is Nothing Then WScript.Echo "REPLAY: step=0 result=REPLAY_ERROR reason=ATTACH detail=no_session" : WScript.Quit 2

Dim wasLocked : wasLocked = TryLockSession(oSession)

Dim aLines, i, sLine, aCols
aLines = Split(oFso.OpenTextFile(STEPS_FILE, 1).ReadAll(), vbCrLf)

Dim rc : rc = 0
For i = 1 To UBound(aLines)      ' row 0 = header
    sLine = aLines(i)
    If Trim(sLine) <> "" Then
        aCols = Split(sLine, vbTab)
        If UBound(aCols) >= 6 Then
            If Not DoStep(aCols) Then rc = 2 : Exit For
        End If
    End If
Next

ReleaseSession oSession, wasLocked
WScript.Quit rc

' ---------------------------------------------------------------------------
Function DoStep(aCols)
    Dim sStep, sId, sVerb, sVal, sProg, sDyn, nTo
    sStep = aCols(0) : sId = aCols(1) : sVerb = LCase(aCols(2)) : sVal = aCols(3)
    sProg = aCols(4) : sDyn = aCols(5) : nTo = CInt("0" & aCols(6))
    If nTo <= 0 Then nTo = 30

    On Error Resume Next
    Err.Clear
    Select Case sVerb
        Case "set"      : oSession.findById(sId).Text = sVal
        Case "select"   : oSession.findById(sId).Select
        Case "press"    : oSession.findById(sId).press
        Case "sendvkey" : oSession.findById("wnd[0]").sendVKey CInt("0" & sVal)
        Case "ok-code"  : oSession.findById("wnd[0]/tbar[0]/okcd").Text = sVal : oSession.findById("wnd[0]").sendVKey 0
        Case Else       : oSession.findById(sId).press
    End Select
    If Err.Number <> 0 Then
        WScript.Echo "REPLAY: step=" & sStep & " result=REPLAY_ERROR reason=ACTION detail=" & Replace(Err.Description, vbTab, " ")
        On Error Goto 0 : DoStep = False : Exit Function
    End If
    On Error Goto 0

    On Error Resume Next
    Dim oBar : Set oBar = oSession.findById("wnd[0]/sbar")
    If Not oBar Is Nothing Then
        If oBar.MessageType <> "" Then
            WScript.Echo "MSG: step=" & sStep & " msgid=" & oBar.MessageId & " msgno=" & oBar.MessageNumber & " msgty=" & oBar.MessageType & " detail=captured"
        End If
    End If
    On Error Goto 0

    On Error Resume Next
    Dim oPop : Set oPop = Nothing : Set oPop = oSession.findById("wnd[1]")
    On Error Goto 0
    If Not oPop Is Nothing Then
        WScript.Echo "REPLAY: step=" & sStep & " result=REPLAY_ERROR reason=POPUP detail=unexpected_wnd1"
        DoStep = False : Exit Function
    End If

    Dim t0, okGuard : okGuard = False
    t0 = Timer
    Do While (Timer - t0) < nTo
        On Error Resume Next
        Dim p, d : p = "" : d = ""
        p = oSession.Info.Program : d = oSession.Info.ScreenNumber
        On Error Goto 0
        If UCase(Trim(p)) = UCase(Trim(sProg)) And CStr(CInt("0" & d)) = CStr(CInt("0" & sDyn)) Then okGuard = True : Exit Do
        WScript.Sleep 250
    Loop

    If okGuard Then
        WScript.Echo "REPLAY: step=" & sStep & " result=PASS detail=guard_ok prog=" & sProg & " dynpro=" & sDyn
        DoStep = True
    Else
        WScript.Echo "REPLAY: step=" & sStep & " result=REPLAY_ERROR reason=GUARD detail=expected " & sProg & "/" & sDyn & " got " & p & "/" & d
        DoStep = False
    End If
End Function
