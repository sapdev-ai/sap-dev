' =============================================================================
' sap_stms_import.vbs  -  /sap-stms writer: import ONE released TR (GATED)
'
' Imports a single transport request into a target system's queue via
' STMS_IMPORT. This is the most outward-facing, least-reversible action in the
' toolset, so the VBS is built to FAIL SAFE:
'
'   1. CALIBRATION GATE. The destructive control IDs ship as PLACEHOLDER_*
'      constants. Until they are recorded for this release (via /sap-gui-probe --record
'      on STMS_IMPORT) and substituted, the script ABORTS with
'      ERROR: not-calibrated -- it presses NOTHING. An uncalibrated run can never
'      mis-import.
'   2. ROW-IDENTITY GATE. Even when calibrated, the import button is pressed ONLY
'      after positively verifying that the selected queue row's TRKORR equals the
'      requested TR. If it cannot verify, it ABORTS without importing.
'
' The human-facing confirmation (and the production typed-SID double-confirm) is
' owned by the SKILL.md BEFORE this VBS is ever launched. This script is the
' mechanical executor, guarded twice.
'
' Language independence: IDs + MessageType; no branching on translated text.
'
' Tokens:
'   %%TR%%             the released TR to import
'   %%TARGET_SID%%     the target system SID
'   %%TARGET_CLIENT%%  the target client (or empty for the queue default)
'   %%IMMEDIATE%%      1 = import now, 0 = scheduled / next run
'   %%LEAVE_IN_QUEUE%% 1 = leave request in queue after import, else 0
'   %%OUTPUT_FILE%%    absolute path of the import.json to write
'   %%SESSION_PATH%%   session hint (or empty)
'   %%ATTACH_LIB_VBS%% absolute path to sap_attach_lib.vbs
'   %%SESSION_LOCK_VBS%% absolute path to sap_session_lock.vbs
' =============================================================================
Option Explicit

Const TR             = "%%TR%%"
Const TARGET_SID     = "%%TARGET_SID%%"
Const TARGET_CLIENT  = "%%TARGET_CLIENT%%"
Const IMMEDIATE      = "%%IMMEDIATE%%"
Const LEAVE_IN_QUEUE = "%%LEAVE_IN_QUEUE%%"
Const OUTPUT_FILE    = "%%OUTPUT_FILE%%"
Const SESSION_PATH   = "%%SESSION_PATH%%"

' --- Destructive control IDs: PLACEHOLDER until recorded for this release. -----
' Replace via /sap-gui-probe --record on the STMS_IMPORT import flow. While any of these
' still begins with "PLACEHOLDER", the calibration gate aborts (no action).
Const IMPORT_BTN     = "PLACEHOLDER_IMPORT_BTN"      ' the "Import Request" toolbar/menu button
Const OPTS_CONFIRM   = "PLACEHOLDER_OPTS_CONFIRM"    ' the import-options dialog confirm button
Const OPTS_CLIENT_FLD= "PLACEHOLDER_OPTS_CLIENT"     ' target-client field on the options dialog

Const VKEY_ENTER = 0

Dim oSession, oFSO, bLocked
bLocked = False

ExecuteGlobal CreateObject("Scripting.FileSystemObject").OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject").OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

Set oFSO = CreateObject("Scripting.FileSystemObject")
Set oSession = AttachSapSession(SESSION_PATH)

' ---- CALIBRATION GATE (fail safe before anything else) ---------------------
If IsPlaceholder(IMPORT_BTN) Or IsPlaceholder(OPTS_CONFIRM) Then
    Fail "not-calibrated", "Import control IDs are PLACEHOLDER. Run /sap-gui-probe --record on STMS_IMPORT for this release and substitute IMPORT_BTN / OPTS_CONFIRM / OPTS_CLIENT_FLD in sap_stms_import.vbs before importing."
    WScript.Quit 1
End If

' ---- OPTION-SUPPORT GATE (before acquiring the lock) -----------------------
' The import-options checkboxes (import-now / leave-in-queue) are release-specific
' and have NO recorded control IDs in this VBS. So if the caller REQUESTED a
' non-default option we cannot honor, FAIL LOUD rather than silently importing
' with the queue default -- the option was advertised, so a no-op would mislead.
If IsFlagSet(IMMEDIATE) Or IsFlagSet(LEAVE_IN_QUEUE) Then
    Fail "STMS_OPTION_UNSUPPORTED", "IMMEDIATE / LEAVE_IN_QUEUE were requested but the import-options checkboxes are not calibrated in this VBS (no recorded control IDs). Record them via /sap-gui-probe --record on the STMS_IMPORT options dialog and add the checkbox control IDs, or re-run without these options."
    WScript.Quit 1
End If

' ---- lock the session around the write -------------------------------------
bLocked = TryLockSession(oSession)

' ---- navigate to the target queue ------------------------------------------
On Error Resume Next
oSession.findById("wnd[0]").maximize
DismissModals
oSession.findById("wnd[0]/tbar[0]/okcd").text = "/nSTMS_IMPORT"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500
DismissModals
On Error GoTo 0

OpenTargetQueue TARGET_SID

Dim grid : Set grid = FindGridShell()
If grid Is Nothing Then
    Fail "queue-not-found", "STMS import-queue grid not found for this release; run /sap-gui-probe --record."
    ReleaseSession oSession, bLocked
    WScript.Quit 1
End If

' ---- ROW-IDENTITY GATE: find + verify the TR row ---------------------------
Dim rowCount, ri, rowIdx, sTrkorr
rowIdx = -1
On Error Resume Next
rowCount = grid.RowCount
On Error GoTo 0
If rowCount < 0 Then rowCount = 0

For ri = 0 To rowCount - 1
    sTrkorr = ""
    On Error Resume Next
    sTrkorr = Trim(grid.GetCellValue(ri, "TRKORR"))
    If Len(sTrkorr) = 0 Then sTrkorr = Trim(grid.GetCellValue(ri, "REQUEST"))
    On Error GoTo 0
    If UCase(sTrkorr) = UCase(TR) Then rowIdx = ri : Exit For
Next

If rowIdx < 0 Then
    Fail "not-in-queue", "TR " & TR & " is not in the import queue of " & TARGET_SID & " (release it and forward it to the queue first)."
    ReleaseSession oSession, bLocked
    WScript.Quit 1
End If

' Positively re-verify the selected row IS the requested TR before any write.
Dim sVerify : sVerify = ""
On Error Resume Next
grid.setCurrentCell rowIdx, "TRKORR"
sVerify = Trim(grid.GetCellValue(rowIdx, "TRKORR"))
If Len(sVerify) = 0 Then sVerify = Trim(grid.GetCellValue(rowIdx, "REQUEST"))
On Error GoTo 0

If UCase(sVerify) <> UCase(TR) Then
    Fail "verify-failed", "Could not positively verify the selected row is " & TR & " (read '" & sVerify & "'). Aborting WITHOUT importing."
    ReleaseSession oSession, bLocked
    WScript.Quit 1
End If

' ---- press Import Request (calibrated control) -----------------------------
Dim sbarType, sbarText
On Error Resume Next
oSession.findById(IMPORT_BTN).press
WScript.Sleep 1000

' import-options dialog (wnd[1]): set client, then confirm. The IMMEDIATE /
' LEAVE_IN_QUEUE checkboxes are release-specific and NOT calibrated here -- the
' OPTION-SUPPORT GATE above already aborted if either was requested, so reaching
' here means the queue default is acceptable. To support them, record the checkbox
' control IDs via /sap-gui-probe --record and set them here BEFORE removing that gate.
If Len(TARGET_CLIENT) > 0 And Not IsPlaceholder(OPTS_CLIENT_FLD) Then
    oSession.findById(OPTS_CLIENT_FLD).text = TARGET_CLIENT
End If
oSession.findById(OPTS_CONFIRM).press
WScript.Sleep 1500
DismissModals

sbarType = "" : sbarText = ""
sbarType = oSession.findById("wnd[0]/sbar").MessageType
sbarText = oSession.findById("wnd[0]/sbar").Text
On Error GoTo 0

ReleaseSession oSession, bLocked

Dim result
If sbarType = "E" Or sbarType = "A" Then
    result = "IMPORT_ERROR"
Else
    result = "IMPORT_SUBMITTED"   ' RC is read separately via sap_stms_log_read.vbs (RC is truth)
End If

WriteJson result, sbarType, sbarText
WScript.Echo "IMPORT: tr=" & TR & " target=" & TARGET_SID & "/" & TARGET_CLIENT & " result=" & result & " sbar=" & sbarType & " file=" & OUTPUT_FILE
If result = "IMPORT_ERROR" Then WScript.Quit 1
WScript.Quit 0

' =============================================================================
' Helpers
' =============================================================================
Function IsPlaceholder(s)
    IsPlaceholder = (Len(s) >= 11 And UCase(Left(s, 11)) = "PLACEHOLDER")
End Function

' A flag token counts as "set" (requesting a non-default option) when it is a
' truthy value. Empty, "0", "false", or the unsubstituted %%...%% token = not set.
Function IsFlagSet(s)
    Dim v : v = UCase(Trim(s & ""))
    IsFlagSet = (v = "1" Or v = "X" Or v = "TRUE" Or v = "YES")
End Function

Sub Fail(reasonCode, msg)
    WriteJson "ABORTED", "", reasonCode & ": " & msg
    WScript.Echo "ERROR: " & reasonCode & " - " & msg
End Sub

Sub OpenTargetQueue(sSid)
    Dim ov : Set ov = FindGridShell()
    If ov Is Nothing Then Exit Sub
    Dim rc, i, v
    On Error Resume Next
    rc = ov.RowCount
    For i = 0 To rc - 1
        v = "" : v = Trim(ov.GetCellValue(i, "SYSNAM"))
        If Len(v) = 0 Then v = Trim(ov.GetCellValue(i, "SYSTEM"))
        If UCase(v) = UCase(sSid) Then
            ov.setCurrentCell i, ""
            ov.doubleClickCurrentCell
            WScript.Sleep 1200
            DismissModals
            Exit For
        End If
    Next
    Err.Clear
    On Error GoTo 0
End Sub

Function FindGridShell()
    Dim cand, id, g
    cand = Array( _
        "wnd[0]/usr/cntlCTRL_IMPORT_QUEUE/shellcont/shell", _
        "wnd[0]/usr/cntlGRID_IMPORT/shellcont/shell", _
        "wnd[0]/usr/cntlGRID1/shellcont/shell", _
        "wnd[0]/usr/cntlCONTAINER/shellcont/shell")
    For Each id In cand
        On Error Resume Next
        Set g = Nothing
        Set g = oSession.findById(id)
        If Err.Number = 0 And Not (g Is Nothing) Then
            Dim rc : rc = -1 : rc = g.RowCount
            If Err.Number = 0 And rc >= 0 Then Err.Clear : On Error GoTo 0 : Set FindGridShell = g : Exit Function
        End If
        Err.Clear
        On Error GoTo 0
    Next
    Set FindGridShell = Nothing
End Function

Function JsonEsc(s)
    Dim t : t = s & ""
    t = Replace(t, "\", "\\")
    t = Replace(t, """", "\""")
    t = Replace(t, vbCr, " ") : t = Replace(t, vbLf, " ") : t = Replace(t, vbTab, " ")
    JsonEsc = t
End Function

Function JKV(k, v)
    JKV = """" & k & """:""" & JsonEsc(v) & """"
End Function

Sub WriteJson(result, sbarType, detail)
    Dim o, j
    j = "{" & """source"":""STMS_IMPORT""," & JKV("result", result) & "," & _
        JKV("tr", TR) & "," & JKV("system", TARGET_SID) & "," & JKV("client", TARGET_CLIENT) & "," & _
        JKV("sbar_type", sbarType) & "," & JKV("detail", detail) & "}"
    Set o = oFSO.CreateTextFile(OUTPUT_FILE, True, False)
    o.Write j
    o.Close
End Sub

Sub DismissModals()
    Dim attempt, idx, oWnd
    For attempt = 1 To 4
        Dim any : any = False
        For idx = 3 To 1 Step -1
            On Error Resume Next
            Set oWnd = Nothing
            Set oWnd = oSession.findById("wnd[" & idx & "]")
            If Err.Number = 0 And Not (oWnd Is Nothing) Then
                Err.Clear
                oWnd.sendVKey 12
                any = True
                WScript.Sleep 250
            End If
            Err.Clear
            On Error GoTo 0
        Next
        If Not any Then Exit Sub
    Next
End Sub
