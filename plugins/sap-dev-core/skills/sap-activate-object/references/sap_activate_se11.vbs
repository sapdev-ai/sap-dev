' =============================================================================
' sap_activate_se11.vbs  -  Activate any DDIC object via SE11
'
' Tokens replaced at run time:
'   %%OBJECT_NAME%%   DDIC object name (e.g. "ZHKDM_AMT9")
'   %%OBJECT_TYPE%%   One of:
'                       TABLE, VIEW, DTEL, STRUCTURE, TABLETYPE, TYPEGROUP,
'                       DOMAIN, SEARCHHELP, LOCKOBJECT
'                     (case-insensitive; aliases below.)
'
' Flow (from C:\Temp\Record_SE11_03_ActiveteDM.vbs):
'   1. /nse11
'   2. Select the radio for the object's category
'   3. Enter the name into the matching ctxtRSRD1-<key>_VAL field
'   4. sendVKey 0 (Enter -> opens object in display mode)
'   5. sendVKey 27 (Ctrl+F3 = Activate)
'   6. If wnd[1] inactive worklist popup: btn[9] Select All, btn[0] Continue
'   7. Read sbar; expect "Object(s) activated"
'   8. F3 back twice to leave the object and return to SE11 main
'
' Output: STATUS_TYPE / STATUS_TEXT / DONE | ERROR
' =============================================================================

Option Explicit

Const OBJECT_NAME = "%%OBJECT_NAME%%"
Const OBJECT_TYPE = "%%OBJECT_TYPE%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER         = 0
Const VKEY_F3_BACK       = 3
Const VKEY_SHIFT_F3_EXIT = 15
Const VKEY_CTRL_F3_ACT   = 27

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

' Include shared activation-log capture (CaptureActivationLog /
' ExtractTopActivationError). Used after Activate when sbar.MessageType is
' E or A to write the activation log to a file so the operator sees the
' specific failure (e.g. which field is missing a reference table) instead
' of just the generic "refer to log" status message.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ACTIVATION_LOG_VBS%%", 1).ReadAll()

Dim sName, sType, sRadio, sNameField

sName = UCase(Trim(OBJECT_NAME))
sType = UCase(Trim(OBJECT_TYPE))
If sName = "" Then
    WScript.Echo "ERROR: OBJECT_NAME is empty."
    WScript.Quit 1
End If
If sType = "" Then
    WScript.Echo "ERROR: OBJECT_TYPE is empty."
    WScript.Quit 1
End If

' Map OBJECT_TYPE -> SE11 radio + name field
Select Case sType
    Case "TABLE", "TABL"
        sRadio     = "wnd[0]/usr/radRSRD1-TBMA"
        sNameField = "wnd[0]/usr/ctxtRSRD1-TBMA_VAL"
    Case "VIEW", "VIMA"
        sRadio     = "wnd[0]/usr/radRSRD1-VIMA"
        sNameField = "wnd[0]/usr/ctxtRSRD1-VIMA_VAL"
    Case "DTEL", "DATAELEMENT", "STRUCTURE", "STRU", "TABLETYPE", "TTYP", "DDTYPE"
        ' Data element / Structure / Table type all live under "Data type"
        sRadio     = "wnd[0]/usr/radRSRD1-DDTYPE"
        sNameField = "wnd[0]/usr/ctxtRSRD1-DDTYPE_VAL"
    Case "TYPEGROUP", "TYPE", "TYMA"
        sRadio     = "wnd[0]/usr/radRSRD1-TYMA"
        sNameField = "wnd[0]/usr/ctxtRSRD1-TYMA_VAL"
    Case "DOMAIN", "DOMA"
        sRadio     = "wnd[0]/usr/radRSRD1-DOMA"
        sNameField = "wnd[0]/usr/ctxtRSRD1-DOMA_VAL"
    Case "SEARCHHELP", "SHLP", "SHMA"
        sRadio     = "wnd[0]/usr/radRSRD1-SHMA"
        sNameField = "wnd[0]/usr/ctxtRSRD1-SHMA_VAL"
    Case "LOCKOBJECT", "ENQU"
        sRadio     = "wnd[0]/usr/radRSRD1-ENQU"
        sNameField = "wnd[0]/usr/ctxtRSRD1-ENQU_VAL"
    Case Else
        WScript.Echo "ERROR: Unknown OBJECT_TYPE '" & sType & "' for SE11. " & _
                     "Allowed: TABLE, VIEW, DTEL, STRUCTURE, TABLETYPE, TYPEGROUP, DOMAIN, SEARCHHELP, LOCKOBJECT."
        WScript.Quit 1
End Select

' ------ 1. Attach to existing SAP GUI session (via shared attach helper) -----
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Session acquired. Activating " & sType & " " & sName & " via SE11..."

' ------ 2. Navigate to SE11 ---------------------------------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nse11"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000

' ------ 3. Select radio + enter name -----------------------------------------
On Error Resume Next
oSess.findById(sRadio).select
WScript.Sleep 200
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not select SE11 radio " & sRadio & " - " & Err.Description
    WScript.Quit 1
End If
Err.Clear
oSess.findById(sNameField).Text = sName
WScript.Sleep 200
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not enter name into " & sNameField & " - " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' ------ 4. Open in display (Enter) -------------------------------------------
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500

' ------ 5. Send Activate (Ctrl+F3) -------------------------------------------
WScript.Echo "INFO: Sending Activate (Ctrl+F3)..."
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_CTRL_F3_ACT
WScript.Sleep 2500
Err.Clear
On Error GoTo 0

' ------ 6. Handle worklist popup ----------------------------------------------
HandleWorklistPopup

' ------ 7. Read status bar ----------------------------------------------------
Dim sStatusType, sStatusText
On Error Resume Next
sStatusType = oSess.findById("wnd[0]/sbar").MessageType
sStatusText = oSess.findById("wnd[0]/sbar").Text
Err.Clear
On Error GoTo 0

WScript.Echo "STATUS_TYPE: " & sStatusType
WScript.Echo "STATUS_TEXT: " & sStatusText

' ------ 7b. On failure, capture the activation log BEFORE backing out -------
' We have to do this before pressing Shift+F3 (Exit) — once we leave the
' object we lose the in-context "Utilities > Activation Log" entry.
If sStatusType = "E" Or sStatusType = "A" Then
    Dim sLogPath, sTopErr
    sLogPath = CaptureActivationLog(oSess, sName, "%%TEMP_DIR%%", _
                                    VKEY_ENTER, VKEY_F3_BACK)
    If Len(sLogPath) > 0 Then
        WScript.Echo "ACTIVATION_LOG: " & sLogPath
        sTopErr = ExtractTopActivationError(sLogPath)
        If Len(sTopErr) > 0 Then
            WScript.Echo "ACTIVATION_ERROR: " & sTopErr
        End If
    Else
        WScript.Echo "INFO: Activation log could not be captured automatically — open SE11 and use Utilities > Activation Log."
    End If
End If

' ------ 8. Back out (twice — first leaves object, second returns to SE11 main)
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_SHIFT_F3_EXIT
WScript.Sleep 500
oSess.findById("wnd[0]").sendVKey VKEY_SHIFT_F3_EXIT
WScript.Sleep 500
Err.Clear
On Error GoTo 0

If sStatusType = "E" Or sStatusType = "A" Then
    WScript.Echo "ERROR: SE11 activation reported [" & sStatusType & "] " & sStatusText
    WScript.Quit 1
End If

WScript.Echo "DONE"
WScript.Quit 0


Sub HandleWorklistPopup
    ' Top-down z-order sweep. SAP can stack multiple modals after Activate:
    ' on S/4HANA 1909, Activate sometimes shows wnd[2] "Information: Errors
    ' Occurred when Activating" ON TOP of wnd[1] "Inactive Objects" worklist
    ' (and the "Display activation log?" warning often appears at wnd[3] or
    ' wnd[4] when the inactive worklist itself raised activation warnings).
    ' Checking only ActiveWindow == wnd[1] misses these cases; iterate
    ' wnd[9]..wnd[1] top-down so blocking popups go first, then the
    ' worklist underneath becomes interactable. Repeat the sweep up to 3
    ' times to catch chained popups that appear AFTER a dismissal.
    '
    ' Each popup is classified by DDIC component IDs (locale-independent
    ' per language_independence_rules.md):
    '
    '   (a) Inactive-objects worklist: has wnd[N]/tbar[0]/btn[9] (Select All)
    '       → press btn[9] + btn[0] to activate all listed objects.
    '
    '   (b) "Warning during activation — display activation log?" popup:
    '       3 SPOP buttons (OPTION1=Yes, OPTION2=No, OPTION3=Cancel).
    '       Detect via btnSPOP-OPTION2 + btnSPOP-OPTION3 both existing.
    '       Press OPTION2 (No) to skip the log viewer and continue —
    '       answering Yes opens a log sub-window and the deploy hangs
    '       waiting for the operator to close it. The activation log is
    '       still captured by sap_activation_log.vbs after this Sub
    '       returns when sbar.MessageType is E/A, so we don't lose the
    '       failure diagnostic by saying No here.
    '
    '   (c) Generic SPOP 2-button popup (OPTION1 + OPTION2, no OPTION3):
    '       Press OPTION1 (Yes) — the affirmative action for
    '       "activate inconsistent changes?" / "save before activation?"
    '       style prompts.
    '
    '   (d) Information / single-action popup (no SPOP-OPTION buttons):
    '       Send VKey 0 (ENTER) — universal OK / Continue key.
    '
    ' Refined 2026-05-11 after the operator screenshots showed
    ' "Warning during activation" popups at wnd[3]/wnd[4] during
    ' ZMMFIXEDVALS32 and ZCMST_RFC_PARAM activation.
    Dim iSweep, i, sId, oWnd, oBtn, bAnyDismissed
    Dim oOpt2, oOpt3, oOpt1
    On Error Resume Next
    For iSweep = 1 To 3
        bAnyDismissed = False
        For i = 9 To 1 Step -1
            sId = "wnd[" & i & "]"
            Set oWnd = Nothing
            Set oWnd = oSess.findById(sId)
            If Err.Number = 0 And Not (oWnd Is Nothing) Then
                Err.Clear
                ' (a) Probe for the worklist toolbar (Select All = btn[9]).
                Set oBtn = Nothing
                Set oBtn = oSess.findById(sId & "/tbar[0]/btn[9]")
                If Err.Number = 0 And Not (oBtn Is Nothing) Then
                    oBtn.press
                    WScript.Sleep 500
                    WScript.Echo "INFO: " & sId & " - Select All pressed."
                    Err.Clear
                    Set oBtn = Nothing
                    Set oBtn = oSess.findById(sId & "/tbar[0]/btn[0]")
                    If Err.Number = 0 And Not (oBtn Is Nothing) Then
                        oBtn.press
                        WScript.Sleep 1200
                        WScript.Echo "INFO: " & sId & " - Continue pressed."
                    End If
                    bAnyDismissed = True
                Else
                    Err.Clear
                    ' (b) Probe for 3-button SPOP popup (Yes/No/Cancel).
                    Set oOpt2 = Nothing
                    Set oOpt3 = Nothing
                    Set oOpt2 = oSess.findById(sId & "/usr/btnSPOP-OPTION2")
                    Set oOpt3 = oSess.findById(sId & "/usr/btnSPOP-OPTION3")
                    If Err.Number = 0 And Not (oOpt2 Is Nothing) And Not (oOpt3 Is Nothing) Then
                        oOpt2.press
                        WScript.Sleep 800
                        WScript.Echo "INFO: " & sId & " - 3-button SPOP popup; pressed OPTION2 (No) to skip activation log."
                        bAnyDismissed = True
                    Else
                        Err.Clear
                        ' (c) Probe for 2-button SPOP popup (Yes/No).
                        Set oOpt1 = Nothing
                        Set oOpt1 = oSess.findById(sId & "/usr/btnSPOP-OPTION1")
                        If Err.Number = 0 And Not (oOpt1 Is Nothing) Then
                            oOpt1.press
                            WScript.Sleep 800
                            WScript.Echo "INFO: " & sId & " - 2-button SPOP popup; pressed OPTION1 (Yes)."
                            bAnyDismissed = True
                        Else
                            Err.Clear
                            ' (d) Info / error popup. VKey 0 = Enter.
                            oWnd.sendVKey 0
                            WScript.Sleep 700
                            WScript.Echo "INFO: " & sId & " - Enter sent (info/error popup)."
                            bAnyDismissed = True
                        End If
                    End If
                End If
                Err.Clear
            Else
                Err.Clear
            End If
        Next
        If Not bAnyDismissed Then Exit For
    Next
    On Error GoTo 0
End Sub
