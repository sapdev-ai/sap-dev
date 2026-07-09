' =============================================================================
' sap_sm37_ops.vbs  -  SM37 background-job operations (GUI fallback driver)
'
' Part of the /sap-job skill. The GUI fallback for job MONITORING + CONTROL when
' the RFC backend (sap_job_rfc.ps1) is unavailable, or for the ops that are
' GUI-primary by design (log, cancel). Attaches to an existing SAP GUI session,
' opens SM37, fills the job-selection screen, F8 to the job list, then dispatches
' on %%OP%%:
'
'   LIST    -- best-effort row count for the selected job name
'   STATUS  -- read the target job row's status cell (raw text; RFC gives the code)
'   LOG     -- open the target job's Job log (+ optional %PC save)
'   SPOOL   -- open the target job's spool list (-> /sap-sp02 for the text)
'   CANCEL  -- Job > Cancel active job (abort a RUNNING job)  [confirm upstream]
'   DELETE  -- Job > Delete (remove the job definition)       [confirm upstream]
'
' IDs CAPTURED + VERIFIED LIVE on S4G (S/4HANA, SAP GUI 7700) 2026-07-09, and the
' selection/initial screens confirmed IDENTICAL on EC2 (ECC 7.31, JA logon) -- the
' SM37 screens are core SAPLBTCH / SAPMSSY0 kernel dialogs, stable across release
' and logon language (only displayed text differs, which this driver never reads).
' The row-select-then-op pattern (setFocus the job's name label, then press the
' toolbar/menu function) was live-verified for Job log. Each transition is still
' guarded -- an unresolved control emits JOB: NEEDS_RECORDING, never a false success.
'
'   * SM37 selection = SAPLBTCH dynpro 2170: job name = txtBTCH2170-JOBNAME (a plain
'     GuiTextField -- NOT ctxt), user = txtBTCH2170-USERNAME, status checkboxes =
'     chkBTCH2170-PRELIM/SCHEDUL/READY/RUNNING/FINISHED/ABORTED, dates = ctxt...-FROM_DATE/TO_DATE.
'   * SM37 job list = classic list SAPMSSY0 dynpro 120 (NOT an ALV grid): a job row
'     is a GuiLabel whose Text is the job name; select it via setFocus, then the op.
'   * Ops: Job log = tbar[1]/btn[47], Spool = tbar[1]/btn[44]; DELETE = Shift+F2
'     (sendVKey 14, release/locale-independent -- the Job-menu Delete index differs
'     across releases); Cancel active job = mbar/menu[0]/menu[1]; Back = tbar[0]/btn[3].
'
' Language independence: controls by component id + DDIC field name; status via
' MessageType (S/W/E/I/A); ops via captured function-code button / menu-index (never
' displayed text). GUI job ops target by job NAME (first matching row) -- the classic
' list does not show JOBCOUNT, so exact-jobcount targeting is the RFC path's job.
'
' Tokens replaced at run time:
'   %%OP%%           LIST | STATUS | LOG | SPOOL | CANCEL | DELETE
'   %%JOBNAME%%      job name (selection + row match); "" = any
'   %%JOBCOUNT%%     job number (echoed only; not matchable in the classic list)
'   %%USER%%         scheduling user filter; "" = any (screen default is *)
'   %%FROM_DATE%%    selection from-date (display format, e.g. 2026/07/09); "" = default
'   %%TO_DATE%%      selection to-date; "" = default
'   %%STATUS_FILTER%% any of R Y P S A F concatenated; "" = all statuses ticked
'   %%SAVE_PATH%%    LOG %PC save target, or "" (skip)
'
' Output (last line, parseable by the SKILL.md wrapper):
'   JOB: LISTED n=<k>
'   JOB: STATUS status=<rawtext> count=<c>
'   JOB: LOG lines=<k> saved=<path|NONE>
'   JOB: SPOOL spool=SEE_SP02 saved=NONE
'   JOB: CANCELLED count=<c>
'   JOB: DELETED count=<c>
'   JOB: NOT_FOUND job=<name> count=<c>
'   JOB: NEEDS_RECORDING step=<select|list|log|spool|cancel|delete> screen=<S>
'   ERROR: ...
' =============================================================================

Option Explicit

Const OP            = "%%OP%%"
Const JOBNAME       = "%%JOBNAME%%"
Const JOBCOUNT      = "%%JOBCOUNT%%"
Const JOB_USER      = "%%USER%%"
Const FROM_DATE     = "%%FROM_DATE%%"
Const TO_DATE       = "%%TO_DATE%%"
Const STATUS_FILTER = "%%STATUS_FILTER%%"
Const SAVE_PATH     = "%%SAVE_PATH%%"
Const SESSION_PATH  = "%%SESSION_PATH%%"
Const VKEY_ENTER    = 0
Const VKEY_F8_EXEC  = 8

' Include shared attach helper (Tier-3 parallel-safe session attach).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

' ------ 1. Open SM37 and fill the job-selection screen ----------------------
oSession.findById("wnd[0]").maximize
oSession.StartTransaction "SM37"
WScript.Sleep 1200

Dim oJn : Set oJn = Nothing
On Error Resume Next
Set oJn = oSession.findById("wnd[0]/usr/txtBTCH2170-JOBNAME")
On Error GoTo 0
If oJn Is Nothing Then
    WScript.Echo "JOB: NEEDS_RECORDING step=select screen=" & InfoScreen(oSession)
    WScript.Quit 0
End If

' Job name: exact when given, else wildcard so every job is in scope.
If JOBNAME <> "" Then oJn.Text = JOBNAME Else oJn.Text = "*"
' Scheduling user: given, else wildcard.
SetTextIf oSession, "wnd[0]/usr/txtBTCH2170-USERNAME", PickUser()
' Date window (optional; display format as the field expects).
If FROM_DATE <> "" Then SetTextIf oSession, "wnd[0]/usr/ctxtBTCH2170-FROM_DATE", FROM_DATE
If TO_DATE   <> "" Then SetTextIf oSession, "wnd[0]/usr/ctxtBTCH2170-TO_DATE",   TO_DATE
' Status checkboxes: tick the requested set, or ALL when no filter given.
TickStatuses oSession

' ------ 2. F8 to the job list (classic list SAPMSSY0/120) -------------------
oSession.findById("wnd[0]").sendVKey VKEY_F8_EXEC
WScript.Sleep 1500

Dim sbT : sbT = SbarType(oSession)
If sbT = "E" Or sbT = "A" Then
    WScript.Echo "ERROR: SM37 selection failed -- [" & sbT & "] " & SbarText(oSession)
    WScript.Quit 1
End If

' ------ 3. Dispatch on the operation ----------------------------------------
Select Case UCase(OP)
    Case "LIST"   : DoList oSession
    Case "STATUS" : DoRowOp oSession, "status"
    Case "LOG"    : DoRowOp oSession, "log"
    Case "SPOOL"  : DoRowOp oSession, "spool"
    Case "CANCEL" : DoRowOp oSession, "cancel"
    Case "DELETE" : DoRowOp oSession, "delete"
    Case Else
        WScript.Echo "ERROR: unknown OP '" & OP & "'"
        WScript.Quit 1
End Select

WScript.Quit 0

' ===========================================================================
' LIST -- best-effort count of rows for the selected job name. The classic list
' mixes header + data labels, so counting is exact only when a specific job name
' was given (count labels whose Text = that name). RFC list is the precise path.
Sub DoList(oSess)
    If JOBNAME = "" Or JOBNAME = "*" Then
        WScript.Echo "JOB: LISTED n=? note=gui_list_best_effort_use_rfc_for_exact"
        Exit Sub
    End If
    Dim n : n = CountLabels(oSess, JOBNAME)
    WScript.Echo "JOB: LISTED n=" & CStr(n)
End Sub

' ---------------------------------------------------------------------------
' Row op: locate the target job's name label, setFocus it (positions the classic
' list cursor on that row -- verified live), then invoke the op. GUI ops target
' by job NAME; the first matching row is used (JOBCOUNT is not shown in the list).
Sub DoRowOp(oSess, kind)
    If JOBNAME = "" Then
        WScript.Echo "ERROR: SM37 " & kind & " needs a job name"
        WScript.Quit 1
    End If
    Dim lblId : lblId = FindJobLabelId(oSess, JOBNAME)
    If lblId = "" Then
        WScript.Echo "JOB: NOT_FOUND job=" & JOBNAME & " count=" & JOBCOUNT
        WScript.Quit 1
    End If
    On Error Resume Next
    oSess.findById(lblId).setFocus
    On Error GoTo 0
    WScript.Sleep 300

    Select Case kind
        Case "status" : OpStatus oSess, lblId
        Case "log"    : OpJobLog oSess
        Case "spool"  : OpSpool  oSess
        Case "cancel" : OpCancel oSess
        Case "delete" : OpDelete oSess
    End Select
End Sub

' ---- STATUS: read the status cell on the focused row (raw, localized text) --
Sub OpStatus(oSess, lblId)
    ' The status column sits to the right of the name on the same row. Read the
    ' row's status label best-effort; RFC status returns the machine code.
    Dim row : row = RowOf(lblId)
    Dim st : st = LabelText(oSess, "wnd[0]/usr/lbl[64," & row & "]")
    If st = "" Then st = "SEE_RFC"
    WScript.Echo "JOB: STATUS status=" & st & " count=" & JOBCOUNT
End Sub

' ---- LOG: Job log toolbar button (verified: tbar[1]/btn[47]) ----------------
Sub OpJobLog(oSess)
    On Error Resume Next
    Err.Clear
    oSess.findById("wnd[0]/tbar[1]/btn[47]").press
    WScript.Sleep 1200
    If Err.Number <> 0 Then
        On Error GoTo 0
        WScript.Echo "JOB: NEEDS_RECORDING step=log screen=" & InfoScreen(oSess)
        WScript.Quit 0
    End If
    On Error GoTo 0
    Dim saved : saved = "NONE"
    If SAVE_PATH <> "" Then saved = SaveClassicList(oSess, SAVE_PATH)
    WScript.Echo "JOB: LOG lines=? saved=" & saved
End Sub

' ---- SPOOL: Spool toolbar button (tbar[1]/btn[44]) -------------------------
Sub OpSpool(oSess)
    On Error Resume Next
    Err.Clear
    oSess.findById("wnd[0]/tbar[1]/btn[44]").press
    WScript.Sleep 1200
    If Err.Number <> 0 Then
        On Error GoTo 0
        WScript.Echo "JOB: NEEDS_RECORDING step=spool screen=" & InfoScreen(oSess)
        WScript.Quit 0
    End If
    On Error GoTo 0
    ' The spool overview lists the request; the reliable text capture is
    ' /sap-sp02 <LISTIDENT> (RFC path returns the id from TBTCP).
    WScript.Echo "JOB: SPOOL spool=SEE_SP02 saved=NONE"
End Sub

' ---- CANCEL: Job menu > Cancel active job (mbar/menu[0]/menu[1]) ------------
Sub OpCancel(oSess)
    If Not SelectMenu(oSess, "wnd[0]/mbar/menu[0]/menu[1]") Then
        WScript.Echo "JOB: NEEDS_RECORDING step=cancel screen=" & InfoScreen(oSess)
        WScript.Quit 0
    End If
    ConfirmPopup oSess
    Dim t : t = SbarType(oSess)
    If t = "E" Or t = "A" Then
        WScript.Echo "ERROR: SM37 cancel failed -- [" & t & "] " & SbarText(oSess)
        WScript.Quit 1
    End If
    WScript.Echo "JOB: CANCELLED count=" & JOBCOUNT
End Sub

' ---- DELETE: Shift+F2 (sendVKey 14) on the focused job row -----------------
' Language- AND release-independent (verified S4G S/4HANA EN + EC2 ECC 7.31 JA):
' both open the SAPLSPO1 "Delete selection?" confirm. The Job-menu index for
' Delete differs across releases (menu[0]/menu[9] on S/4HANA is NOT Delete on ECC
' 7.31), so the VKey is used instead of the menu.
Sub OpDelete(oSess)
    On Error Resume Next
    Err.Clear
    oSess.findById("wnd[0]").sendVKey 14
    WScript.Sleep 1000
    On Error GoTo 0
    ConfirmPopup oSess
    Dim t : t = SbarType(oSess)
    If t = "E" Or t = "A" Then
        WScript.Echo "ERROR: SM37 delete failed -- [" & t & "] " & SbarText(oSess)
        WScript.Quit 1
    End If
    ' Verify the job actually left the list. A classic-list "Delete selection?"
    ' with nothing selected is a silent no-op -- never report a false DELETED.
    WScript.Sleep 600
    If FindJobLabelId(oSess, JOBNAME) <> "" Then
        WScript.Echo "JOB: NEEDS_RECORDING step=delete_not_removed screen=" & InfoScreen(oSess)
        WScript.Quit 0
    End If
    WScript.Echo "JOB: DELETED count=" & JOBCOUNT
End Sub

' ===========================================================================
' Find the DATA-ROW GuiLabel under wnd[0]/usr whose Text = the job name; return
' its id (for setFocus). CRITICAL: the classic list echoes the selection criteria
' ("Selected job names: <name>") as a label in the HEADER at a high column (~29),
' while the actual job rows carry the name in the left DATA column (col <= 12 --
' col 4 on S4G + EC2). Match only the data column, or a Delete would focus the
' header echo and act on an EMPTY selection (silent no-op -> false success).
Function FindJobLabelId(oSess, jn)
    FindJobLabelId = ""
    Dim usr : Set usr = Nothing
    On Error Resume Next
    Set usr = oSess.findById("wnd[0]/usr")
    On Error GoTo 0
    If usr Is Nothing Then Exit Function
    Dim ch : Set ch = Nothing
    On Error Resume Next
    Set ch = usr.Children
    On Error GoTo 0
    If ch Is Nothing Then Exit Function
    Dim i, kid, t, tx
    For i = 0 To ch.Count - 1
        Set kid = Nothing
        On Error Resume Next
        Set kid = ch.ElementAt(i)
        On Error GoTo 0
        If Not (kid Is Nothing) Then
            t = "" : tx = ""
            On Error Resume Next
            t = kid.Type : tx = kid.Text
            On Error GoTo 0
            If t = "GuiLabel" And ColOf(kid.Id) <= 12 And UCase(Trim(tx)) = UCase(Trim(jn)) Then
                FindJobLabelId = kid.Id
                Exit Function
            End If
        End If
    Next
End Function

' Count DATA-ROW GuiLabels under usr whose Text = jn (rows for a specific job).
' Same data-column filter as FindJobLabelId (excludes the header selection echo).
Function CountLabels(oSess, jn)
    CountLabels = 0
    Dim usr : Set usr = Nothing
    On Error Resume Next
    Set usr = oSess.findById("wnd[0]/usr")
    On Error GoTo 0
    If usr Is Nothing Then Exit Function
    Dim ch : Set ch = Nothing
    On Error Resume Next
    Set ch = usr.Children
    On Error GoTo 0
    If ch Is Nothing Then Exit Function
    Dim i, kid, t, tx, c : c = 0
    For i = 0 To ch.Count - 1
        Set kid = Nothing
        On Error Resume Next
        Set kid = ch.ElementAt(i)
        On Error GoTo 0
        If Not (kid Is Nothing) Then
            t = "" : tx = ""
            On Error Resume Next
            t = kid.Type : tx = kid.Text
            On Error GoTo 0
            If t = "GuiLabel" And ColOf(kid.Id) <= 12 And UCase(Trim(tx)) = UCase(Trim(jn)) Then c = c + 1
        End If
    Next
    CountLabels = c
End Function

' Parse the column from a classic-list label id "...lbl[col,row]". Returns a
' large sentinel when the id is not an lbl[c,r] (so non-data labels are excluded).
Function ColOf(id)
    ColOf = 9999
    Dim p, s, q
    p = InStr(id, "lbl[")
    If p = 0 Then Exit Function
    s = Mid(id, p + 4)
    q = InStr(s, ",")
    If q > 0 Then ColOf = CInt(Left(s, q - 1))
End Function

' Extract the row number from a classic-list label id "...lbl[col,row]".
Function RowOf(id)
    RowOf = 0
    Dim p, q
    p = InStrRev(id, ",")
    q = InStrRev(id, "]")
    If p > 0 And q > p Then RowOf = CInt(Mid(id, p + 1, q - p - 1))
End Function

Function LabelText(oSess, id)
    LabelText = ""
    Dim o : Set o = Nothing
    On Error Resume Next
    Set o = oSess.findById(id)
    If Not (o Is Nothing) Then LabelText = Trim(o.Text)
    On Error GoTo 0
End Function

Function SelectMenu(oSess, id)
    SelectMenu = False
    On Error Resume Next
    Err.Clear
    oSess.findById(id).select
    If Err.Number = 0 Then SelectMenu = True
    On Error GoTo 0
    WScript.Sleep 1000
End Function

' Dismiss a confirm popup (SPOP Yes, or Enter) if one appeared.
Sub ConfirmPopup(oSess)
    If InStr(oSess.ActiveWindow.Id, "wnd[1]") = 0 Then Exit Sub
    Dim oYes : Set oYes = Nothing
    On Error Resume Next
    Set oYes = oSess.findById("wnd[1]/usr/btnSPOP-OPTION1")
    On Error GoTo 0
    If Not (oYes Is Nothing) Then
        oYes.press
    Else
        oSess.ActiveWindow.sendVKey VKEY_ENTER
    End If
    WScript.Sleep 1000
End Sub

' ------ selection-screen helpers --------------------------------------------
Sub SetTextIf(oSess, id, val)
    If val = "" Then Exit Sub
    Dim o : Set o = Nothing
    On Error Resume Next
    Set o = oSess.findById(id)
    If Not (o Is Nothing) Then o.Text = val
    On Error GoTo 0
End Sub

Function PickUser()
    If JOB_USER = "" Then PickUser = "*" Else PickUser = JOB_USER
End Function

Sub TickStatuses(oSess)
    Dim wantAll : wantAll = (STATUS_FILTER = "")
    CheckIf oSess, "wnd[0]/usr/chkBTCH2170-PRELIM",   wantAll Or InStr(STATUS_FILTER, "P") > 0  ' scheduled
    CheckIf oSess, "wnd[0]/usr/chkBTCH2170-SCHEDUL",  wantAll Or InStr(STATUS_FILTER, "S") > 0  ' released
    CheckIf oSess, "wnd[0]/usr/chkBTCH2170-READY",    wantAll Or InStr(STATUS_FILTER, "Y") > 0  ' ready
    CheckIf oSess, "wnd[0]/usr/chkBTCH2170-RUNNING",  wantAll Or InStr(STATUS_FILTER, "R") > 0  ' active
    CheckIf oSess, "wnd[0]/usr/chkBTCH2170-FINISHED", wantAll Or InStr(STATUS_FILTER, "F") > 0  ' finished
    CheckIf oSess, "wnd[0]/usr/chkBTCH2170-ABORTED",  wantAll Or InStr(STATUS_FILTER, "A") > 0  ' cancelled
End Sub

Sub CheckIf(oSess, id, wantOn)
    Dim o : Set o = Nothing
    On Error Resume Next
    Set o = oSess.findById(id)
    If Not (o Is Nothing) Then o.Selected = wantOn
    On Error GoTo 0
End Sub

' Best-effort classic-list %PC download (job log). Returns path or "NONE".
Function SaveClassicList(oSess, sPath)
    SaveClassicList = "NONE"
    Dim dir, fn, p
    p = InStrRev(sPath, "\")
    If p = 0 Then Exit Function
    dir = Left(sPath, p) : fn = Mid(sPath, p + 1)
    On Error Resume Next
    Err.Clear
    oSess.findById("wnd[0]/tbar[0]/okcd").Text = "%PC"
    oSess.findById("wnd[0]").sendVKey VKEY_ENTER
    WScript.Sleep 900
    If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then oSess.ActiveWindow.sendVKey VKEY_ENTER : WScript.Sleep 700
    oSess.findById("wnd[1]/usr/ctxtDY_PATH").Text = dir
    oSess.findById("wnd[1]/usr/ctxtDY_FILENAME").Text = fn
    oSess.findById("wnd[1]").sendVKey VKEY_ENTER
    WScript.Sleep 1000
    If Err.Number = 0 Then SaveClassicList = sPath
    Err.Clear
    On Error GoTo 0
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
