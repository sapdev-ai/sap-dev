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
'     sHint   — optional path hint, e.g. "/app/con[0]/ses[1]". Empty
'               string or the unsubstituted token literal both mean
'               "no hint; fall through".
'
'     Resolution order (first hit wins):
'       1. sHint, if non-empty and resolves via findById.
'       2. Environment variable SAPDEV_SESSION_PATH, if non-empty and
'          resolves. Set by orchestrators that want to pin a session
'          for a multi-skill task without threading --session through
'          every call.
'       3. First session of first connection — the legacy default.
'          Preserves the behaviour of unmigrated callers.
'
'     On failure: emits `ERROR: <text>` to stdout and calls WScript.Quit 2.
'     Callers do NOT need their own error-handling block around the call.
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
' This helper does NOT participate in the broker's claim lifecycle —
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
            Set AttachSapSession = oSes2
            Exit Function
        End If
        ' Env var that didn't resolve — also a hard error. Same reasoning
        ' as strategy 1: silent retargeting is worse than failing loud.
        WScript.Echo "ERROR: SAPDEV_SESSION_PATH points to a session that doesn't resolve: " & sEnv
        WScript.Quit 2
    End If

    ' --- Strategy 3: SAPDEV_PIN_FILE env var --------------------------------
    ' Set by the calling SKILL.md PS wrapper to the pin file produced by
    ' /sap-login (typically {WORK_TEMP}\sap_active_session.json). The pin
    ' file's `session_path` field is THE canonical default in multi-
    ' connection environments: /sap-login --remember writes which session
    ' the user wants as default.
    Dim sPinFile, oSes3
    On Error Resume Next
    sPinFile = oShell.Environment("Process")("SAPDEV_PIN_FILE")
    On Error GoTo 0
    sPinFile = Trim("" & sPinFile)
    If sPinFile <> "" Then
        Dim sPinSessionPath : sPinSessionPath = ReadPinSessionPath(sPinFile)
        If sPinSessionPath <> "" Then
            On Error Resume Next
            Set oSes3 = oApp.findById(sPinSessionPath, False)
            On Error GoTo 0
            If Not (oSes3 Is Nothing) Then
                WScript.Echo "INFO: attached to " & sPinSessionPath & " (via SAPDEV_PIN_FILE: " & sPinFile & ")"
                Set AttachSapSession = oSes3
                Exit Function
            End If
            ' Pin file referenced a session that no longer resolves. Fall
            ' through to strategies 4/5 rather than failing — the pin may
            ' be stale and we'd rather attach to a single-connection
            ' default than refuse outright.
        End If
    End If

    ' --- Strategy 4: single-connection / single-session safe default --------
    ' Today's 99% case: exactly one SAP connection attached. With or without
    ' a pin file, this is unambiguous and safe to auto-use.
    If oApp.Children.Count = 1 Then
        Dim oOnlyCon : Set oOnlyCon = oApp.Children(0)
        If oOnlyCon.Children.Count = 1 Then
            Dim oOnly : Set oOnly = Nothing
            For Each oOnly In oOnlyCon.Children : Exit For : Next
            WScript.Echo "INFO: attached to " & oOnly.Id & " (sole connection, sole session)"
            Set AttachSapSession = oOnly
            Exit Function
        End If
        ' Sole connection but >1 session: still unambiguous about which
        ' SAP system to target, but ambiguous which session. Refuse with a
        ' helpful message rather than picking arbitrarily.
        WScript.Echo "ERROR: 1 SAP connection but " & oOnlyCon.Children.Count & " sessions; pass an explicit path via SESSION_PATH or set SAPDEV_PIN_FILE / SAPDEV_SESSION_PATH."
        WScript.Quit 2
    End If

    ' --- Strategy 5: refuse — multiple connections + no hint ----------------
    WScript.Echo "ERROR: " & oApp.Children.Count & " SAP connections attached; cannot pick one safely. Run '/sap-login --remember' to pin a default, or pass an explicit --session /app/con[N]/ses[M]."
    WScript.Quit 2
End Function

' --- Pin file reader (small enough that VBS regex suffices) -------------------
' The pin file is flat JSON written by /sap-login Step 6 / Step 0.6 capture.
' We only need the `session_path` field; bare regex is robust on a flat doc.
Function ReadPinSessionPath(sPath)
    ReadPinSessionPath = ""
    On Error Resume Next
    Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
    If Not oFSO.FileExists(sPath) Then Exit Function
    Dim oStream : Set oStream = CreateObject("ADODB.Stream")
    oStream.Type    = 2     ' text
    oStream.Charset = "utf-8"
    oStream.Open
    oStream.LoadFromFile sPath
    Dim sJson : sJson = oStream.ReadText()
    oStream.Close
    If Err.Number <> 0 Then Err.Clear : Exit Function
    On Error GoTo 0

    Dim re : Set re = New RegExp
    re.Pattern    = """session_path""\s*:\s*""([^""]+)"""
    re.Global     = False
    re.IgnoreCase = False
    Dim m : Set m = re.Execute(sJson)
    If m.Count > 0 Then ReadPinSessionPath = m(0).SubMatches(0)
End Function
