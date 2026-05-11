' =============================================================================
' sap_activate_se38.vbs  -  Activate a report/program/function-group main pgm
'                            via SE38 (initial screen, no source open).
'
' Tokens replaced at run time:
'   %%OBJECT_NAME%%   ABAP program / report name (e.g. "ZHKTEST003")
'
' Flow (from C:\Temp\Record_SE38_03_ActivetePGM.vbs):
'   1. /nse38
'   2. Enter program name into ctxtRS38M-PROGRAMM
'   3. sendVKey 21 (Shift+F9 = Activate from initial screen)
'   4. If wnd[1] (inactive worklist popup) appears:
'        - tbar[0]/btn[9] = Select All
'        - tbar[0]/btn[0] = Continue
'      The popup is filtered by the locality (transportable vs local) of the
'      triggering object — SAP shows only objects of the same locality.
'   5. Read sbar; expect "Object(s) activated" (S/I-type).
'   6. F3 back (btn[15] = Shift+F3 / Cancel back to clean state).
'
' Output (parsed by caller):
'   STATUS_TYPE: <S|W|E|A|I|empty>
'   STATUS_TEXT: <message text>
'   DONE | ERROR: ...
' =============================================================================

Option Explicit

Const OBJECT_NAME = "%%OBJECT_NAME%%"

Const VKEY_ENTER         = 0
Const VKEY_F3_BACK       = 3
Const VKEY_SHIFT_F3_EXIT = 15
Const VKEY_SHIFT_F9_ACT  = 21

Dim oSAPGUI, oApp, oSess, c, s
Dim sName

sName = UCase(Trim(OBJECT_NAME))
If sName = "" Then
    WScript.Echo "ERROR: OBJECT_NAME is empty."
    WScript.Quit 1
End If

' ------ 1. Attach to existing SAP GUI session ---------------------------------
On Error Resume Next
Set oSAPGUI = GetObject("SAPGUI")
If Err.Number <> 0 Or oSAPGUI Is Nothing Then
    WScript.Echo "ERROR: SAP GUI is not running."
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

Set oApp = oSAPGUI.GetScriptingEngine
Set oSess = Nothing
On Error Resume Next
For Each c In oApp.Children
    For Each s In c.Children
        Set oSess = s
        Exit For
    Next
    If Not (oSess Is Nothing) Then Exit For
Next
On Error GoTo 0

If oSess Is Nothing Then
    WScript.Echo "ERROR: No SAP GUI session found. Run /sap-login first."
    WScript.Quit 1
End If
WScript.Echo "INFO: Session acquired. Activating PROGRAM " & sName & " via SE38..."

' ------ 2. Navigate to SE38 ---------------------------------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nse38"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000

' ------ 3. Enter program name -------------------------------------------------
On Error Resume Next
Dim oNameField
Set oNameField = oSess.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM")
If Err.Number <> 0 Or oNameField Is Nothing Then
    WScript.Echo "ERROR: Program name field not found (wnd[0]/usr/ctxtRS38M-PROGRAMM)."
    WScript.Quit 1
End If
oNameField.Text = sName
WScript.Sleep 300
Err.Clear
On Error GoTo 0

' ------ 4. Send Activate (Shift+F9) -------------------------------------------
WScript.Echo "INFO: Sending Activate (Shift+F9)..."
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_SHIFT_F9_ACT
WScript.Sleep 2500
Err.Clear
On Error GoTo 0

' ------ 5. Handle inactive-objects worklist popup if present ------------------
HandleWorklistPopup

' ------ 6. Read status bar ----------------------------------------------------
Dim sStatusType, sStatusText
On Error Resume Next
sStatusType = oSess.findById("wnd[0]/sbar").MessageType
sStatusText = oSess.findById("wnd[0]/sbar").Text
Err.Clear
On Error GoTo 0

WScript.Echo "STATUS_TYPE: " & sStatusType
WScript.Echo "STATUS_TEXT: " & sStatusText

' ------ 7. Back out (Shift+F3 = Cancel/Exit) ----------------------------------
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_SHIFT_F3_EXIT
WScript.Sleep 500
Err.Clear
On Error GoTo 0

If sStatusType = "E" Or sStatusType = "A" Then
    WScript.Echo "ERROR: SE38 activation reported [" & sStatusType & "] " & sStatusText
    WScript.Quit 1
End If

WScript.Echo "DONE"
WScript.Quit 0


' ============================================================================
' Helper: handle stacked modal popups after Activate.
' Top-down z-order sweep — see sap_activate_se11.vbs for the full rationale.
' SAP can stack multiple modals (e.g. wnd[2] error popup ON TOP of wnd[1]
' worklist on S/4HANA 1909); checking only ActiveWindow == wnd[1] misses
' the higher-numbered window. Iterate wnd[9]..wnd[1] top-down so blocking
' popups go first. Repeat up to 3 times to catch chained popups.
' ============================================================================
Sub HandleWorklistPopup
    Dim iSweep, i, sId, oWnd, oBtn, bAnyDismissed
    On Error Resume Next
    For iSweep = 1 To 3
        bAnyDismissed = False
        For i = 9 To 1 Step -1
            sId = "wnd[" & i & "]"
            Set oWnd = Nothing
            Set oWnd = oSess.findById(sId)
            If Err.Number = 0 And Not (oWnd Is Nothing) Then
                Err.Clear
                ' Probe for the worklist toolbar (Select All = btn[9]).
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
                    ' Info / error / confirm popup (no worklist toolbar).
                    ' VKey 0 = Enter, the default OK action across popup types.
                    oWnd.sendVKey 0
                    WScript.Sleep 700
                    WScript.Echo "INFO: " & sId & " - Enter sent (info/error popup)."
                    bAnyDismissed = True
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
