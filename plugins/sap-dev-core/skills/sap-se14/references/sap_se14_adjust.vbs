' =============================================================================
' sap_se14_adjust.vbs  -  SAP GUI Scripting: SE14 (DB Utility)
'                         "Activate and adjust database" on the SAVE-DATA path.
'
' Drives transaction SE14 for a stuck DDIC table and runs the data-preserving
' "Activate and adjust database" conversion. This is the SAVE-DATA-ONLY driver:
' the delete-data path is made structurally UNREACHABLE. No code path selects
' the delete-data radio (radRSGTB-DDATA); the save-data radio (radRSGTB-SDATA)
' is asserted present AND .Selected before the adjust is pressed, and the driver
' REFUSES (SE14_SDATA_NOT_DEFAULT) rather than pressing adjust if that invariant
' does not hold. radRSGTB-DDATA is only ever READ (to assert it is NOT selected),
' never .Select-ed. This is the whole safety design: destructive delete-data is
' unreachable, not merely un-pressed.
'
' Recorded + live-verified end-to-end on S4D (S/4HANA 1909, kernel 754)
' 2026-07-12 against a CONSISTENT scratch table (so the conversion was a no-op);
' every control id, the "Execute online" confirm popup, and the sbar-S success
' verdict are real. The control contract is state-independent -- the SE14 screens
' are identical whether the table is CONSISTENT or ADJUST_NEEDED.
'
' Language independence (per shared/rules/language_independence_rules.md):
'   controls are addressed by component ID + DDIC field name; the success/fail
'   verdict reads wnd[0]/sbar.MessageType (S/W/E/I/A), NEVER translated .Text /
'   .Tooltip / window titles. The confirm popup is detected by wnd[1] + the DDIC
'   button id btnBUTTON_1 (SAPLSPO1). Radio state uses the .Selected boolean.
'   Localised status text is echoed / stored for diagnostics only.
'
' Reference flow (SAPMSGTB, identical on S/4HANA 1909 and ECC6):
'   /nSE14 -> 100 SAPMSGTB: ctxtRSGTB-OBJNAME + radRSGTB-TAB -> btnBEARBEITEN
'          -> 400 SAPMSGTB: assert radRSGTB-SDATA .Selected, DDATA not selected
'          -> btnRSGTB-CNVTA -> 500 SAPLSPO1 confirm: btnBUTTON_1 (Yes)
'          -> back on 400, sbar MessageType S = ok.
'
' Tokens replaced at run time:
'   %%TABLE%%            DDIC table name (upper-cased at runtime)
'   %%OUTPUT_FILE%%      absolute path of the result JSON to write (UTF-8)
'   %%SESSION_PATH%%     /app/con[N]/ses[M] pin (empty = auto-resolve)
'   %%ATTACH_LIB_VBS%%   abs path to shared sap_attach_lib.vbs
'   %%SESSION_LOCK_VBS%% abs path to shared sap_session_lock.vbs
'
' Output JSON (UTF-8, no BOM):
'   {"table":..,"op":"adjust","save_data":true,
'    "status":"OK|SE14_ADJUST_FAILED|SE14_SDATA_NOT_DEFAULT|NEEDS_RECORDING",
'    "sbar":".."}
'
' Parseable stdout:
'   SE14: adjust table=<t> save_data=1        (known outcomes)
'   SE14: NEEDS_RECORDING step=<label>        (unknown screen/popup -> re-record)
'   STATUS: <status>
' Exit: 0 = OK, 1 = SE14_ADJUST_FAILED / SE14_SDATA_NOT_DEFAULT,
'       3 = NEEDS_RECORDING.
' =============================================================================

Option Explicit

Const TABLE        = "%%TABLE%%"
Const OUTPUT_FILE  = "%%OUTPUT_FILE%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER  = 0
Const VKEY_CANCEL = 12

' Include shared helpers. Order matters: attach FIRST (the session-lock lib's
' pre-unlock popup sweep reads from oSession), then the session-lock lib.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

Dim oSession
Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
Dim wasLocked : wasLocked = False

' Resolve the table name. Guard the unsubstituted-token case with a Chr(37)
' ("%") sentinel so the wrapper's global %%TOKEN%% replace cannot corrupt this
' comparison (same idiom as sap_pfcg_create.vbs / sap_se01_remove_objects.vbs).
Dim gTable : gTable = TABLE
If gTable = Chr(37) & Chr(37) & "TABLE" & Chr(37) & Chr(37) Then gTable = ""
gTable = UCase(Trim(gTable))
If gTable = "" Then
    WScript.Echo "ERROR: no table supplied (TABLE token empty)"
    FinishKnown "SE14_ADJUST_FAILED", "no table supplied", 1
End If

' ------ 1. Attach to the pinned SAP GUI session -----------------------------
Set oSession = AttachSapSession(SESSION_PATH)

On Error Resume Next
oSession.findById("wnd[0]").maximize
On Error GoTo 0
DismissModals   ' clear any stray modal so the OK-code field is reachable

' ------ 2. Navigate to SE14 + enter the object name (screen 100) -------------
Dim oOk : Set oOk = F("wnd[0]/tbar[0]/okcd")
If oOk Is Nothing Then FinishNeedsRecording "nav(okcd field missing)"
On Error Resume Next
oOk.Text = "/nSE14"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
On Error GoTo 0
WScript.Sleep 1000

Dim oObj : Set oObj = F("wnd[0]/usr/ctxtRSGTB-OBJNAME")
If oObj Is Nothing Then FinishNeedsRecording "se14_initial(ctxtRSGTB-OBJNAME missing)"
On Error Resume Next
oObj.Text = gTable
On Error GoTo 0

' Tables radio (default on SE14; select defensively). This is radRSGTB-TAB; the
' Views alternative radRSGTB-VIE is never touched by the table-adjust flow.
Dim oRadTab : Set oRadTab = F("wnd[0]/usr/radRSGTB-TAB")
If Not (oRadTab Is Nothing) Then
    On Error Resume Next
    oRadTab.Select
    On Error GoTo 0
End If

' Edit -> DB-utility screen 400.
Dim oEdit : Set oEdit = F("wnd[0]/usr/btnBEARBEITEN")
If oEdit Is Nothing Then FinishNeedsRecording "se14_initial(btnBEARBEITEN missing)"
On Error Resume Next
oEdit.press
On Error GoTo 0
WScript.Sleep 1200

' An unexpected modal after Edit (e.g. table locked by another user) is not the
' DB-utility screen -- refuse and ask for a re-record rather than guess a click.
If Not (F("wnd[1]") Is Nothing) Then FinishNeedsRecording "edit_to_dbutil(unexpected modal wnd[1])"

' ------ 3. Structural delete-data rail (screen 400) -------------------------
' Assert the SAVE-DATA radio is present AND selected. If we cannot POSITIVELY
' confirm the save-data rail, we REFUSE (never press adjust on an unknown rail).
Dim oSData : Set oSData = F("wnd[0]/usr/radRSGTB-SDATA")
If oSData Is Nothing Then FinishKnown "SE14_SDATA_NOT_DEFAULT", "save-data radio radRSGTB-SDATA not present on DB-utility screen 400", 1

Dim bSData : bSData = False
On Error Resume Next
bSData = oSData.Selected
On Error GoTo 0
If Not bSData Then FinishKnown "SE14_SDATA_NOT_DEFAULT", "save-data radio radRSGTB-SDATA is not selected by default", 1

' Read-only assertion that the DELETE-DATA radio is NOT selected. We READ it to
' prove the destructive path is inactive; we NEVER .Select it.
Dim oDData : Set oDData = F("wnd[0]/usr/radRSGTB-DDATA")
If Not (oDData Is Nothing) Then
    Dim bDData : bDData = False
    On Error Resume Next
    bDData = oDData.Selected
    On Error GoTo 0
    If bDData Then FinishKnown "SE14_SDATA_NOT_DEFAULT", "delete-data radio radRSGTB-DDATA is selected -- refusing (save-data invariant violated)", 1
End If

' Defensive re-select of the SAVE-DATA radio (idempotent; never touches DDATA).
On Error Resume Next
oSData.Select
On Error GoTo 0

' ------ 4. Critical section: press "Activate and adjust database" -----------
wasLocked = TryLockSession(oSession)

Dim oAdjust : Set oAdjust = F("wnd[0]/usr/btnRSGTB-CNVTA")
If oAdjust Is Nothing Then FinishNeedsRecording "dbutil(btnRSGTB-CNVTA missing)"
On Error Resume Next
oAdjust.press
On Error GoTo 0
WScript.Sleep 1200

' ------ 5. Confirm popup "Execute online:" (SAPLSPO1 screen 500) ------------
' Detect by wnd[1] + the DDIC button id btnBUTTON_1 (Yes). A different modal at
' this decision point -> NEEDS_RECORDING (never guess a click).
Dim oPop : Set oPop = F("wnd[1]")
If Not (oPop Is Nothing) Then
    Dim oYes : Set oYes = F("wnd[1]/usr/btnBUTTON_1")
    If oYes Is Nothing Then FinishNeedsRecording "exec_confirm(wnd[1] present but btnBUTTON_1 missing)"
    On Error Resume Next
    oYes.press
    On Error GoTo 0
    WScript.Sleep 1500
End If

' A modal still up after confirming is an unrecognized extra popup -> re-record.
If Not (F("wnd[1]") Is Nothing) Then FinishNeedsRecording "post_confirm(unexpected modal wnd[1])"

' ------ 6. Verdict from the status bar (MessageType, language-independent) ---
Dim sType : sType = SbarType()
Dim sText : sText = SbarText()
WScript.Echo "INFO: sbar [" & sType & "] " & sText

If sType = "E" Or sType = "A" Then
    FinishKnown "SE14_ADJUST_FAILED", sText, 1
End If

' S (and the benign W/I/empty) -> OK. The AUTHORITATIVE confirmation is the RFC
' re-read the SKILL performs afterwards; the sbar is only the first-pass signal.
FinishKnown "OK", sText, 0

' ============================ helper routines ===============================
' Every findById is funnelled through F() so a missing control returns Nothing
' instead of crashing. Callers check Is Nothing and route to a Finish* helper.
Function F(sId)
    Set F = Nothing
    On Error Resume Next
    Set F = oSession.findById(sId, False)
    On Error GoTo 0
End Function

Function SbarType()
    SbarType = ""
    Dim o : Set o = F("wnd[0]/sbar")
    If Not (o Is Nothing) Then
        On Error Resume Next
        SbarType = o.MessageType
        On Error GoTo 0
    End If
End Function

Function SbarText()
    SbarText = ""
    Dim o : Set o = F("wnd[0]/sbar")
    If Not (o Is Nothing) Then
        On Error Resume Next
        SbarText = o.Text
        On Error GoTo 0
    End If
End Function

' Sweep up to 3 chained modal popups from the session via F12 (Cancel). Used to
' clear stray modals before navigation and on the NEEDS_RECORDING abort path
' (F12 closes popups WITHOUT committing changes -- safest on abort). Independent
' of the session lock, so it also covers the pre-lock abort paths where
' ReleaseSession's own sweep does not run.
Sub DismissModals()
    If oSession Is Nothing Then Exit Sub
    Dim attempt, idx, oWnd, any
    For attempt = 1 To 3
        any = False
        For idx = 3 To 1 Step -1
            On Error Resume Next
            Set oWnd = Nothing
            Set oWnd = oSession.findById("wnd[" & idx & "]", False)
            If Not (oWnd Is Nothing) Then
                oWnd.sendVKey VKEY_CANCEL
                any = True
                WScript.Sleep 250
            End If
            Err.Clear
            On Error GoTo 0
        Next
        If Not any Then Exit For
    Next
End Sub

' Terminal state with a known status (OK / SE14_ADJUST_FAILED /
' SE14_SDATA_NOT_DEFAULT). Writes the result JSON, echoes the parseable lines,
' releases the session lock (idempotent), and quits with the mapped code.
Sub FinishKnown(status, sbarText, code)
    WriteResult status, sbarText
    WScript.Echo "SE14: adjust table=" & gTable & " save_data=1"
    WScript.Echo "STATUS: " & status
    ReleaseSession oSession, wasLocked
    WScript.Quit code
End Sub

' Unknown screen/popup at a decision point. Writes a NEEDS_RECORDING result,
' sweeps any stray modal (F12), releases the lock, and quits 3 so the SKILL asks
' for a /sap-gui-probe --record capture instead of guessing a click.
Sub FinishNeedsRecording(stepLabel)
    WriteResult "NEEDS_RECORDING", "unrecognized screen/popup at step " & stepLabel
    WScript.Echo "SE14: NEEDS_RECORDING step=" & stepLabel
    WScript.Echo "STATUS: NEEDS_RECORDING"
    DismissModals
    ReleaseSession oSession, wasLocked
    WScript.Quit 3
End Sub

Sub WriteResult(status, sbarText)
    Dim j
    j = "{" & _
        JKV("table", gTable) & "," & _
        JKV("op", "adjust") & "," & _
        """save_data"":true," & _
        JKV("status", status) & "," & _
        JKV("sbar", sbarText) & "}"
    WriteFileUtf8 OUTPUT_FILE, j
End Sub

Function JsonEsc(s)
    Dim t : t = s & ""
    t = Replace(t, "\", "\\")
    t = Replace(t, """", "\""")
    t = Replace(t, vbCr, " ")
    t = Replace(t, vbLf, " ")
    t = Replace(t, vbTab, " ")
    JsonEsc = t
End Function

Function JKV(k, v)
    JKV = """" & k & """:""" & JsonEsc(v) & """"
End Function

Sub WriteFileUtf8(sPath, sText)
    ' UTF-8 without BOM (repo convention for VBS-emitted data files, per
    ' sap_log_lib.vbs); falls back to an FSO Unicode write if ADODB.Stream is
    ' unavailable. Either path preserves non-ASCII status text.
    Dim st, bin, okStream
    okStream = False
    On Error Resume Next
    Set st = CreateObject("ADODB.Stream")
    st.Type = 2 : st.Charset = "utf-8" : st.Open
    st.WriteText sText
    st.Position = 3            ' skip the UTF-8 BOM (EF BB BF)
    Set bin = CreateObject("ADODB.Stream")
    bin.Type = 1 : bin.Open
    st.CopyTo bin
    st.Flush : st.Close
    bin.SaveToFile sPath, 2    ' adSaveCreateOverWrite
    bin.Flush : bin.Close
    If Err.Number = 0 Then okStream = True
    Err.Clear
    On Error GoTo 0
    If Not okStream Then
        On Error Resume Next
        Dim o
        Set o = oFSO.CreateTextFile(sPath, True, True)
        o.Write sText : o.Close
        On Error GoTo 0
    End If
End Sub
