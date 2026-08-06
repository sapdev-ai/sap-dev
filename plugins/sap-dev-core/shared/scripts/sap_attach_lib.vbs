' =============================================================================
' sap_attach_lib.vbs  -  Shared GUI-session attach helper for sap-dev VBS skills
'
' Replaces the boilerplate nested For-Each-Children attach idiom that lives
' in ~95 operational VBS files. Every skill that drives SAP GUI now goes
' through this one helper, gaining a `--session` contract for free: callers
' that supply a specific path use it; callers that don't get today's
' legacy "first session of first connection" behaviour.
'
' Include via:
'   ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
'       .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
'
' Token convention: the calling PowerShell wrapper substitutes
' `%%ATTACH_LIB_VBS%%` with the absolute path to this file, matching the
' established `%%SESSION_LOCK_VBS%%`, `%%LOG_LIB_VBS%%` patterns.
'
' Public API
' ----------
'
'   Function AttachSapSession(sHint) As GuiSession
'     sHint   -- optional path hint, e.g. "/app/con[0]/ses[1]". Empty
'               string or the unsubstituted token literal both mean
'               "no hint; fall through".
'
'     Resolution order (first hit wins):
'       1. sHint, if non-empty and resolves via findById.
'       2. Environment variable SAPDEV_SESSION_PATH, if non-empty and
'          resolves. Set by skill wrappers using Get-SapCurrentSessionPath
'          to point at the AI-session's currently pinned SAP session.
'       3. Sole-connection / sole-session safe default.
'       4. Refuse loud -- multiple connections with no pin.
'
'     Phase 4.2 removed the legacy "SAPDEV_PIN_FILE -> read JSON for
'     session_path" strategy. Skill wrappers now compute the path in
'     PowerShell via Get-SapCurrentSessionPath (in sap_connection_lib.ps1)
'     and pass it via $env:SAPDEV_SESSION_PATH.
'
'     On failure: emits `ERROR: <text>` to stdout and calls WScript.Quit 2.
'     Callers do NOT need their own error-handling block around the call.
'
'     Whichever strategy wins, the helper then emits the SAP identity of the
'     session it attached to:
'
'         GUI_TARGET: system=<SID> client=<NNN> user=<USER> path=<...>
'
'     and, when the caller has declared an expected target, ENFORCES it.
'
' Target assertion (SAPDEV_EXPECT_SYSTEM / SAPDEV_EXPECT_CLIENT)
' --------------------------------------------------------------
' A skill that reads over BOTH transports -- RFC (Connect-SapRfc) and GUI
' (this helper) -- resolves its SAP target twice, through two different
' chains. RFC follows pin -> GUI-active -> default -> sole-profile;
' this helper follows hint -> env -> sole-connection -> refuse. Those
' chains can disagree, and when they do the skill reads TWO DIFFERENT SAP
' SYSTEMS while believing it read one.
'
' Live incident (2026-08-06, S4D/100 vs S4H/400): /sap-se38 downloaded
' Z_EXCEPTION_1 through the GUI leg while the RFC leg read the pinned
' profile. The AI session was pinned to S4D/100 but the only attached GUI
' connection was S4H/400, so Strategy 3 below silently retargeted. Both
' systems host an independently-maintained Z_EXCEPTION_1; the two reads
' differed on 7 lines and nothing in either output said which system it
' came from. A check-fix-upload loop on that basis reverts live edits.
'
' So: when the wrapper sets SAPDEV_EXPECT_SYSTEM (and optionally
' SAPDEV_EXPECT_CLIENT) -- see Set-SapGuiTargetExpectation in
' sap_connection_lib.ps1, which reads the SAME profile Connect-SapRfc
' would pick -- a mismatch is a hard refusal, not a silent retarget.
' Unset = today's behaviour (identity still echoed), so this is additive
' for every VBS that has not been wired up yet.
'
' Since 2026-08-06 (second incident, RFC transport) the RFC leg enforces
' the SAME pair: Connect-SapRfc (sap_rfc_lib.ps1) refuses a resolution
' that mismatches the expectation and stamps "RFC_TARGET: ..." on every
' successful connect, the sibling of the GUI_TARGET line below -- so both
' transports answer to one declared target.
'
' Why a helper rather than every skill rolling its own
' ----------------------------------------------------
' The legacy idiom:
'
'     Set oSession = Nothing
'     For Each oCandidate In oApplication.Children
'         For Each oSessIter In oCandidate.Children
'             Set oSession = oSessIter
'             Exit For
'         Next
'         If Not (oSession Is Nothing) Then Exit For
'     Next
'
' grabs the first session it finds. When two skills run in parallel they
' both grab session 0 and trample each other. The helper accepts an
' explicit path so the broker (or the user via --session) can hand each
' caller a different session. Skills that don't care still work because
' the legacy default is preserved as the final fallback.
'
' This helper does NOT participate in the broker's claim lifecycle --
' that's a separate concern handled by the skill wrapper (PowerShell)
' calling `sap_session_broker.ps1 -Action acquire/release`. The helper
' is just the attach primitive.
'
' Notes on the sentinel-token detection
' -------------------------------------
' PowerShell `.Replace('%%SESSION_PATH%%', $value)` is global, so if we
' wrote the literal `<%>%>SESSION_PATH<%>%>` inside this file as a sentinel
' for "is this still the placeholder?", the wrapper would rewrite it
' too and the check would become useless (this exact bug existed in
' sap_gui_object_details.vbs and was fixed via the same Chr(37) idiom
' used here). We build the unsubstituted-token sentinel at runtime
' from Chr() codes so no wrapper substitution can corrupt it.
' =============================================================================

' -----------------------------------------------------------------------------
' AssertSapGuiTarget(oSes, sVia)
'
' NOTE: no leading underscore. VBScript identifiers must start with a letter --
' a `_`-prefixed Sub name is a compile error, and because this lib is pulled in
' via ExecuteGlobal the failure surfaces on the CALLER's ExecuteGlobal line,
' not here, which makes it needlessly hard to diagnose.
'
' Echo the SAP identity of the session we just attached to, then enforce the
' caller's declared expectation. Called from EVERY success path of
' AttachSapSession, so no strategy can return an unstamped session.
'
' Identity is read from GuiSession.Info (SystemName / Client / User) -- these
' are IDs, never localised display text, so the check is language-independent
' per shared/rules/language_independence_rules.md.
'
' Comparison is case-insensitive and trims blanks. Client is compared only
' when SAPDEV_EXPECT_CLIENT is set, so a caller can pin "the S4D system, any
' client" if that is genuinely what it wants.
' -----------------------------------------------------------------------------
Sub AssertSapGuiTarget(oSes, sVia)
    Dim sSid, sCli, sUsr, sPath
    sSid = "" : sCli = "" : sUsr = "" : sPath = ""
    On Error Resume Next
    sPath = "" & oSes.Id
    sSid  = "" & oSes.Info.SystemName
    sCli  = "" & oSes.Info.Client
    sUsr  = "" & oSes.Info.User
    On Error GoTo 0
    sSid = Trim(sSid) : sCli = Trim(sCli) : sUsr = Trim(sUsr)

    WScript.Echo "GUI_TARGET: system=" & sSid & " client=" & sCli & _
                 " user=" & sUsr & " path=" & sPath & " via=" & sVia

    Dim oEnvShell, sExpSys, sExpCli
    Set oEnvShell = CreateObject("WScript.Shell")
    On Error Resume Next
    sExpSys = oEnvShell.Environment("Process")("SAPDEV_EXPECT_SYSTEM")
    sExpCli = oEnvShell.Environment("Process")("SAPDEV_EXPECT_CLIENT")
    On Error GoTo 0
    sExpSys = Trim("" & sExpSys)
    sExpCli = Trim("" & sExpCli)

    ' No expectation declared -> legacy behaviour (stamped, unenforced).
    If sExpSys = "" And sExpCli = "" Then Exit Sub

    ' If the expectation is set but identity could not be read, refuse: an
    ' unverifiable target is exactly the case this guard exists for.
    If sSid = "" Then
        WScript.Echo "ERROR: SAP GUI target could not be identified (Info.SystemName empty) " & _
                     "but SAPDEV_EXPECT_SYSTEM=" & sExpSys & " was declared. Refusing to drive an unverified session."
        WScript.Quit 2
    End If

    Dim bBad : bBad = False
    If sExpSys <> "" And StrComp(sExpSys, sSid, 1) <> 0 Then bBad = True
    If sExpCli <> "" And StrComp(sExpCli, sCli, 1) <> 0 Then bBad = True

    If bBad Then
        WScript.Echo "ERROR: SAP GUI target mismatch. Expected " & sExpSys & "/" & sExpCli & _
                     " but attached session " & sPath & " is " & sSid & "/" & sCli & "/" & sUsr & "."
        WScript.Echo "       The RFC leg of this skill targets " & sExpSys & "/" & sExpCli & _
                     ", so continuing would read/write TWO DIFFERENT SAP SYSTEMS in one run."
        WScript.Echo "       Fix: open a SAP GUI session on " & sExpSys & "/" & sExpCli & _
                     ", or run /sap-login --switch " & sSid & " to re-pin this AI session to the system the GUI is on."
        WScript.Quit 2
    End If
End Sub

Function AttachSapSession(sHint)
    Dim oSAP, oApp
    On Error Resume Next
    Set oSAP = GetObject("SAPGUI")
    If Err.Number <> 0 Or oSAP Is Nothing Then
        WScript.Echo "ERROR: SAP GUI is not running (GetObject(""SAPGUI"") failed)."
        WScript.Quit 2
    End If
    Err.Clear
    Set oApp = oSAP.GetScriptingEngine
    If Err.Number <> 0 Or oApp Is Nothing Then
        WScript.Echo "ERROR: SAP GUI Scripting engine unavailable (check RZ11 sapgui/user_scripting)."
        WScript.Quit 2
    End If
    Err.Clear
    On Error GoTo 0

    ' Phase 4: emit a single diagnostic line if SAPDEV_AI_SESSION_ID is set.
    ' AI-session pin enforcement lives in the broker (sap_session_broker.ps1
    ' refuses cross-connection acquires). Attach lib only echoes the ID so
    ' multi-AI-session debug logs can reconstruct who-attached-to-what.
    Dim oShellDiag, sAi
    Set oShellDiag = CreateObject("WScript.Shell")
    On Error Resume Next
    sAi = oShellDiag.Environment("Process")("SAPDEV_AI_SESSION_ID")
    On Error GoTo 0
    sAi = Trim("" & sAi)
    If sAi <> "" Then WScript.Echo "INFO: ai_session=" & sAi

    ' Build the unsubstituted-token sentinel at runtime so the PowerShell
    ' wrapper's `.Replace('%%SESSION_PATH%%', ...)` cannot rewrite it.
    Dim UNSUB_TOKEN
    UNSUB_TOKEN = Chr(37) & Chr(37) & "SESSION_PATH" & Chr(37) & Chr(37)

    ' --- Strategy 1: explicit hint -------------------------------------------
    Dim sCandidate : sCandidate = ""
    If Not IsNull(sHint) Then sCandidate = "" & sHint
    sCandidate = Trim(sCandidate)
    If sCandidate = UNSUB_TOKEN Then sCandidate = ""

    If sCandidate <> "" Then
        Dim oSes1 : Set oSes1 = Nothing
        On Error Resume Next
        Set oSes1 = oApp.findById(sCandidate, False)
        On Error GoTo 0
        If Not (oSes1 Is Nothing) Then
            WScript.Echo "INFO: attached to " & sCandidate & " (via explicit hint)"
            AssertSapGuiTarget oSes1, "explicit-hint"
            Set AttachSapSession = oSes1
            Exit Function
        End If
        ' Explicit hint that didn't resolve is a hard error -- the caller
        ' specifically asked for this path and we cannot honour it. Fall-
        ' through would silently retarget to a different session and
        ' that's how parallel skills trample each other.
        WScript.Echo "ERROR: explicit session path not found: " & sCandidate
        WScript.Quit 2
    End If

    ' --- Strategy 2: SAPDEV_SESSION_PATH env var -----------------------------
    Dim oShell, sEnv
    Set oShell = CreateObject("WScript.Shell")
    On Error Resume Next
    sEnv = oShell.Environment("Process")("SAPDEV_SESSION_PATH")
    On Error GoTo 0
    sEnv = Trim("" & sEnv)
    If sEnv <> "" And sEnv <> UNSUB_TOKEN Then
        Dim oSes2 : Set oSes2 = Nothing
        On Error Resume Next
        Set oSes2 = oApp.findById(sEnv, False)
        On Error GoTo 0
        If Not (oSes2 Is Nothing) Then
            WScript.Echo "INFO: attached to " & sEnv & " (via SAPDEV_SESSION_PATH env var)"
            AssertSapGuiTarget oSes2, "session-path-env"
            Set AttachSapSession = oSes2
            Exit Function
        End If
        ' Env var that didn't resolve -- also a hard error. Same reasoning
        ' as strategy 1: silent retargeting is worse than failing loud.
        WScript.Echo "ERROR: SAPDEV_SESSION_PATH points to a session that doesn't resolve: " & sEnv
        WScript.Quit 2
    End If

    ' --- Strategy 3: single-connection / single-session safe default --------
    ' Today's 99% case: exactly one SAP connection attached. Unambiguous about
    ' WHICH session to drive -- but note it says nothing about whether that
    ' session is the system the caller actually meant. "Sole" is not "right":
    ' when the AI session is pinned to system A and the only GUI window is on
    ' system B, this strategy hands back B. That is the 2026-08-06 cross-system
    ' read described in the header, and it is why AssertSapGuiTarget runs
    ' here too -- callers that declared SAPDEV_EXPECT_SYSTEM get a refusal
    ' instead of another system's source.
    If oApp.Children.Count = 1 Then
        Dim oOnlyCon : Set oOnlyCon = oApp.Children(0)
        If oOnlyCon.Children.Count = 1 Then
            Dim oOnly : Set oOnly = Nothing
            For Each oOnly In oOnlyCon.Children : Exit For : Next
            WScript.Echo "INFO: attached to " & oOnly.Id & " (sole connection, sole session)"
            AssertSapGuiTarget oOnly, "sole-connection"
            Set AttachSapSession = oOnly
            Exit Function
        End If
        ' Sole connection but >1 session: still unambiguous about which
        ' SAP system to target, but ambiguous which session. Refuse with a
        ' helpful message rather than picking arbitrarily.
        WScript.Echo "ERROR: 1 SAP connection but " & oOnlyCon.Children.Count & " sessions; pass an explicit path via SESSION_PATH or set $env:SAPDEV_SESSION_PATH."
        WScript.Quit 2
    End If

    ' --- Strategy 4: refuse -- multiple connections + no hint ----------------
    WScript.Echo "ERROR: " & oApp.Children.Count & " SAP connections attached; cannot pick one safely. Run /sap-login to pin a connection, or set $env:SAPDEV_SESSION_PATH explicitly."
    WScript.Quit 2
End Function
