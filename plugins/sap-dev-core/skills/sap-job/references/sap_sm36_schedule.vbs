' =============================================================================
' sap_sm36_schedule.vbs  -  Schedule a background job via SM36 (GUI fallback)
'
' Part of the /sap-job skill. The GUI fallback for `schedule` when the RFC path
' (sap_job_rfc.ps1 -> Z_RUN_REPORT) is unavailable, AND the required path for
' start-time / periodic scheduling (Z_RUN_REPORT submits immediately only).
' Attaches to an existing SAP GUI session, opens SM36, names the job + class,
' adds one ABAP step (program + variant), sets the start condition (immediate /
' date-time / periodic), and saves.
'
' IDs CAPTURED LIVE on S4G (S/4HANA, SAP GUI 7700) 2026-07-09; the initial screen
' confirmed IDENTICAL on EC2 (ECC 7.31, JA logon) -- the SM36 wizard is core
' SAPLBTCH kernel dialogs, stable across release and logon language. The immediate
' step+schedule flow was walked live during capture. Each transition is guarded --
' an unresolved control emits JOB: NEEDS_RECORDING, never a false "scheduled".
'
'   * Initial       = SAPLBTCH dynpro 1140: job name = txtBTCH1140-JOBNAME (a plain
'     GuiTextField, NOT ctxt), class = ctxtBTCH1140-JOBCLASS; Step = tbar[1]/btn[6],
'     Start condition = tbar[1]/btn[5], Save job = tbar[0]/btn[11] (Ctrl+S).
'   * Step popup     = SAPLBTCH dynpro 1120 (wnd[1]): program = ctxtBTCH1120-ABAPNAME,
'     variant = ctxtBTCH1120-VARIANT; Save step = wnd[1]/tbar[0]/btn[11].
'   * Start-cond     = SAPLBTCH dynpro 1010 (wnd[1]): Immediate = btnSOFORT_PUSH;
'     Date/Time = btnDATE_PUSH -> ctxtBTCH1010-SDLSTRTDT / -SDLSTRTTM; periodic =
'     chkBTCH1010-PERIODIC; Period Values = wnd[1]/tbar[0]/btn[5]; Save = wnd[1]/tbar[0]/btn[11].
'   * Period Values  = SAPLBTCH dynpro 1060 (wnd[2]): btnDAILYBUTTON / btnWEEKLYBUTTON /
'     btnMONTHLYBUTTON / btnHOURLYBUTTON; Save = wnd[2]/tbar[0]/btn[11].
'
' Language independence: controls by component id + DDIC field name; status via
' MessageType; VKey/captured ids for actions; no branching on displayed text.
'
' Tokens replaced at run time:
'   %%PROGRAM%%    ABAP report to schedule (UPPERCASE)
'   %%VARIANT%%    variant name, or "" (none)
'   %%JOBNAME%%    job name (default = program)
'   %%START%%      "immediate" | "YYYYMMDDHHMMSS" (date-time) | "event:<EVT>"
'   %%PERIOD%%     "" | "daily" | "weekly" | "monthly" | "hourly" (periodic recurrence)
'   %%JOBCLASS%%   "A" | "B" | "C" (priority; default "C")
'
' Output (last line, parseable by the SKILL.md wrapper):
'   JOB: SCHEDULED job=<name> count=? (<sbar>)   -- caller resolves count via TBTCO/list
'   JOB: NEEDS_RECORDING step=<init|step|start_cond|save> screen=<S>
'   ERROR: ...
' =============================================================================

Option Explicit

Const PROGRAM      = "%%PROGRAM%%"
Const RUN_VARIANT  = "%%VARIANT%%"
Const JOBNAME      = "%%JOBNAME%%"
Const JOB_START    = "%%START%%"
Const JOB_PERIOD   = "%%PERIOD%%"
Const JOB_CLASS    = "%%JOBCLASS%%"
Const SESSION_PATH = "%%SESSION_PATH%%"
Const VKEY_ENTER   = 0
Const VKEY_SAVE    = 11

' Include shared attach helper (Tier-3 parallel-safe session attach).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

Dim theJob : theJob = JOBNAME
If theJob = "" Then theJob = UCase(PROGRAM)

' ------ 1. Open SM36 and name the job (SAPLBTCH/1140) -----------------------
oSession.findById("wnd[0]").maximize
oSession.StartTransaction "SM36"
WScript.Sleep 1200

Dim oJn : Set oJn = Nothing
On Error Resume Next
Set oJn = oSession.findById("wnd[0]/usr/txtBTCH1140-JOBNAME")
On Error GoTo 0
If oJn Is Nothing Then
    WScript.Echo "JOB: NEEDS_RECORDING step=init screen=" & InfoScreen(oSession)
    WScript.Quit 0
End If
oJn.Text = theJob
SetTextIf oSession, "wnd[0]/usr/ctxtBTCH1140-JOBCLASS", DefClass()

' ------ 2. Define the ABAP step (program + variant) -------------------------
If Not DefineStep(oSession) Then
    WScript.Echo "JOB: NEEDS_RECORDING step=step screen=" & InfoScreen(oSession)
    WScript.Quit 0
End If

' ------ 3. Start condition (immediate / date-time / periodic) ---------------
If Not StartCondition(oSession) Then
    WScript.Echo "JOB: NEEDS_RECORDING step=start_cond screen=" & InfoScreen(oSession)
    WScript.Quit 0
End If

' ------ 4. Save the job (Ctrl+S on the initial screen) ----------------------
On Error Resume Next
Err.Clear
oSession.findById("wnd[0]").sendVKey VKEY_SAVE
WScript.Sleep 1500
If Err.Number <> 0 Then
    On Error GoTo 0
    WScript.Echo "JOB: NEEDS_RECORDING step=save screen=" & InfoScreen(oSession)
    WScript.Quit 0
End If
On Error GoTo 0

Dim t : t = SbarType(oSession)
If t = "E" Or t = "A" Then
    WScript.Echo "ERROR: SM36 save failed -- [" & t & "] " & SbarText(oSession)
    WScript.Quit 1
End If
' Job saved. SM36 does not surface the job NUMBER, so the caller resolves the
' newest count for this job+user via TBTCO (same convention as sap_sa38_run.vbs).
WScript.Echo "JOB: SCHEDULED job=" & theJob & " count=? (" & Left(SbarText(oSession), 100) & ")"
WScript.Quit 0

' ===========================================================================
' Define one ABAP step: Step (tbar[1]/btn[6]) -> step popup SAPLBTCH/1120 ->
' fill program + variant -> Save step (wnd[1]/tbar[0]/btn[11]) -> back to initial.
Function DefineStep(oSess)
    DefineStep = False
    On Error Resume Next
    Err.Clear
    oSess.findById("wnd[0]/tbar[1]/btn[6]").press          ' Step
    WScript.Sleep 1200
    On Error GoTo 0
    Dim oProg : Set oProg = Nothing
    On Error Resume Next
    Set oProg = oSess.findById("wnd[1]/usr/ctxtBTCH1120-ABAPNAME")
    On Error GoTo 0
    If oProg Is Nothing Then Exit Function
    ' ABAP-program is the default step type when Step is pressed (ABAPNAME is
    ' directly editable) -- fill it straight, verified live. btnABAP_PUSH exists
    ' to SWITCH to ABAP from another step type; pressing it here is unnecessary
    ' and avoided so no step-type re-render disturbs the fields.
    oProg.Text = UCase(PROGRAM)
    SetTextIf oSess, "wnd[1]/usr/ctxtBTCH1120-VARIANT", UCase(RUN_VARIANT)
    ' Save the step. On current releases this lands on the step-LIST overview
    ' (SAPMSSY0/120), not the initial screen -- Back out until the 1140 initial
    ' job-name field is showing again (verified live: post-save-step screen).
    On Error Resume Next
    oSess.findById("wnd[1]/tbar[0]/btn[11]").press
    WScript.Sleep 1000
    Dim guard : guard = 0
    Do While IsNothingId(oSess, "wnd[0]/usr/txtBTCH1140-JOBNAME") And guard < 4
        oSess.findById("wnd[0]").sendVKey 3
        WScript.Sleep 700
        guard = guard + 1
    Loop
    On Error GoTo 0
    DefineStep = True
End Function

' True when findById(id) resolves to nothing (control absent on the screen).
Function IsNothingId(oSess, id)
    Dim o : Set o = Nothing
    On Error Resume Next
    Set o = oSess.findById(id)
    On Error GoTo 0
    IsNothingId = (o Is Nothing)
End Function

' ---------------------------------------------------------------------------
' Start condition: immediate (default), date-time, or periodic.
Function StartCondition(oSess)
    StartCondition = False
    On Error Resume Next
    Err.Clear
    oSess.findById("wnd[0]/tbar[1]/btn[5]").press          ' Start condition
    WScript.Sleep 1200
    On Error GoTo 0
    ' Confirm we reached the start-condition dialog (SAPLBTCH/1010).
    Dim oImm : Set oImm = Nothing
    On Error Resume Next
    Set oImm = oSess.findById("wnd[1]/usr/btnSOFORT_PUSH")
    On Error GoTo 0
    If oImm Is Nothing Then Exit Function

    ' Event-based start (event:<EVT>) is not captured -- fail loud, never mis-schedule.
    If LCase(Left(JOB_START, 6)) = "event:" Then
        WScript.Echo "JOB: NEEDS_RECORDING step=start_cond_event screen=" & InfoScreen(oSess)
        WScript.Quit 0
    End If

    ' Pure immediate only when there is NO recurrence. A periodic job needs a
    ' date/time start ANCHOR, so --period forces the date-time route even when the
    ' start is "immediate" (the anchor defaults to now -- see StartDate/StartTime).
    If IsImmediate() And JOB_PERIOD = "" Then
        oImm.press
        WScript.Sleep 600
    Else
        ' Date-time: reveal the date/time fields, then fill them.
        On Error Resume Next
        oSess.findById("wnd[1]/usr/btnDATE_PUSH").press
        WScript.Sleep 700
        oSess.findById("wnd[1]/usr/ctxtBTCH1010-SDLSTRTDT").Text = StartDate()
        oSess.findById("wnd[1]/usr/ctxtBTCH1010-SDLSTRTTM").Text = StartTime()
        On Error GoTo 0
        If JOB_PERIOD <> "" Then
            CheckIf oSess, "wnd[1]/usr/chkBTCH1010-PERIODIC", True
            On Error Resume Next
            oSess.findById("wnd[1]/tbar[0]/btn[5]").press     ' Period Values -> wnd[2] SAPLBTCH/1060
            WScript.Sleep 900
            PressAny oSess, Array(PeriodButton())
            oSess.findById("wnd[2]/tbar[0]/btn[11]").press    ' Save period values
            WScript.Sleep 700
            On Error GoTo 0
        End If
    End If
    ' Save the start-condition dialog (if still open).
    On Error Resume Next
    If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then oSess.findById("wnd[1]/tbar[0]/btn[11]").press
    WScript.Sleep 800
    On Error GoTo 0
    StartCondition = True
End Function

' ------ small locale-independent helpers ------------------------------------
Function IsImmediate()
    IsImmediate = (LCase(JOB_START) = "immediate" Or JOB_START = "")
End Function

' True when JOB_START is an explicit YYYYMMDD[HHMMSS] datetime (not immediate/event).
Function IsDateTimeStart()
    IsDateTimeStart = (Len(JOB_START) >= 8 And IsNumeric(Left(JOB_START, 8)))
End Function

' Start DATE as YYYY/MM/DD. Explicit datetime -> its first 8 digits; otherwise
' (--period with an immediate/empty start) -> TODAY as the recurrence anchor.
' NOTE: the date-field display format is user-locale-specific; YYYY/MM/DD matches
' the observed format on S4G + EC2. The pure-immediate path uses no date at all.
Function StartDate()
    If IsDateTimeStart() Then
        Dim d : d = Left(JOB_START, 8)
        StartDate = Left(d, 4) & "/" & Mid(d, 5, 2) & "/" & Mid(d, 7, 2)
    Else
        StartDate = Right("0000" & Year(Date), 4) & "/" & Right("0" & Month(Date), 2) & "/" & Right("0" & Day(Date), 2)
    End If
End Function

' Start TIME as HH:MM:SS. Explicit datetime -> its HHMMSS; otherwise -> NOW.
Function StartTime()
    If IsDateTimeStart() Then
        Dim tm : tm = Mid(JOB_START & "000000", 9, 6)
        StartTime = Left(tm, 2) & ":" & Mid(tm, 3, 2) & ":" & Mid(tm, 5, 2)
    Else
        StartTime = Right("0" & Hour(Time), 2) & ":" & Right("0" & Minute(Time), 2) & ":" & Right("0" & Second(Time), 2)
    End If
End Function

Function PeriodButton()
    Select Case LCase(JOB_PERIOD)
        Case "hourly"  : PeriodButton = "wnd[2]/usr/btnHOURLYBUTTON"
        Case "daily"   : PeriodButton = "wnd[2]/usr/btnDAILYBUTTON"
        Case "weekly"  : PeriodButton = "wnd[2]/usr/btnWEEKLYBUTTON"
        Case "monthly" : PeriodButton = "wnd[2]/usr/btnMONTHLYBUTTON"
        Case Else      : PeriodButton = "wnd[2]/usr/btnDAILYBUTTON"
    End Select
End Function

Function PressAny(oSess, ids)
    PressAny = False
    Dim i
    On Error Resume Next
    For i = 0 To UBound(ids)
        Err.Clear
        oSess.findById(ids(i)).press
        If Err.Number = 0 Then PressAny = True : Exit For
    Next
    On Error GoTo 0
End Function

Sub SetTextIf(oSess, id, val)
    If val = "" Then Exit Sub
    Dim o : Set o = Nothing
    On Error Resume Next
    Set o = oSess.findById(id)
    If Not (o Is Nothing) Then o.Text = val
    On Error GoTo 0
End Sub

Sub CheckIf(oSess, id, wantOn)
    Dim o : Set o = Nothing
    On Error Resume Next
    Set o = oSess.findById(id)
    If Not (o Is Nothing) Then o.Selected = wantOn
    On Error GoTo 0
End Sub

Function DefClass()
    If JOB_CLASS = "" Then DefClass = "C" Else DefClass = UCase(JOB_CLASS)
End Function

Function SbarType(oSess)
    SbarType = ""
    On Error Resume Next
    SbarType = oSess.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
End Function

Function SbarText(oSess)
    SbarText = ""
    On Error Resume Next
    SbarText = oSess.findById("wnd[0]/sbar").Text
    On Error GoTo 0
End Function

Function InfoScreen(oSess)
    InfoScreen = ""
    On Error Resume Next
    InfoScreen = CStr(oSess.Info.ScreenNumber)
    On Error GoTo 0
End Function
