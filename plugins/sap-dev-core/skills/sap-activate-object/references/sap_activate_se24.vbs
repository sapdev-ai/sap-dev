' =============================================================================
' sap_activate_se24.vbs  -  Activate a class / interface (SE24)
'
' Tokens replaced at run time:
'   %%OBJECT_NAME%%   Class or interface name (e.g. "ZCL_HK_TEST001")
'
' The recording (C:\Temp\Record_SE24_03_ActiveteCL.vbs) only shows entering
' the class name + Enter; the actual activate keystroke is implied. We follow
' the same shape as SE37/SE38: enter name, send Ctrl+F3 to activate, handle
' the inactive-objects worklist popup (Continue ONLY -- the triggering object
' is pre-selected; Select All is never pressed because it would co-activate
' other developers' unrelated inactive objects on a shared DEV), read sbar.
'
' Output: STATUS_TYPE / STATUS_TEXT / DONE | ERROR
' =============================================================================

Option Explicit

Const OBJECT_NAME = "%%OBJECT_NAME%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER         = 0
Const VKEY_F3_BACK       = 3
Const VKEY_SHIFT_F3_EXIT = 15
Const VKEY_CTRL_F3_ACT   = 27

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim sName

sName = UCase(Trim(OBJECT_NAME))
If sName = "" Then
    WScript.Echo "ERROR: OBJECT_NAME is empty."
    WScript.Quit 1
End If

' ------ 1. Attach to existing SAP GUI session (via shared attach helper) -----
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Session acquired. Activating CLASS/INTERFACE " & sName & " via SE24..."

' ------ 2. Navigate to SE24 ---------------------------------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nse24"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000

' ------ 3. Enter class name ---------------------------------------------------
On Error Resume Next
Dim oNameField
Set oNameField = oSess.findById("wnd[0]/usr/ctxtSEOCLASS-CLSNAME")
If Err.Number <> 0 Or oNameField Is Nothing Then
    WScript.Echo "ERROR: SE24 class name field not found (wnd[0]/usr/ctxtSEOCLASS-CLSNAME)."
    WScript.Quit 1
End If
oNameField.Text = sName
WScript.Sleep 300
Err.Clear
On Error GoTo 0

' ------ 4. Send Activate (Ctrl+F3) directly from initial screen ---------------
WScript.Echo "INFO: Sending Activate (Ctrl+F3)..."
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_CTRL_F3_ACT
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

' ------ 7. Back out -----------------------------------------------------------
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_SHIFT_F3_EXIT
WScript.Sleep 500
Err.Clear
On Error GoTo 0

If sStatusType = "E" Or sStatusType = "A" Then
    WScript.Echo "ERROR: SE24 activation reported [" & sStatusType & "] " & sStatusText
    WScript.Quit 1
End If

WScript.Echo "DONE"
WScript.Quit 0


Sub HandleWorklistPopup
    ' Top-down z-order sweep -- see sap_activate_se11.vbs for the full rationale.
    ' SAP can stack multiple modals after Activate (e.g. wnd[2] error popup ON
    ' TOP of wnd[1] worklist on S/4HANA 1909); checking only ActiveWindow ==
    ' wnd[1] misses the higher-numbered window. Iterate wnd[9]..wnd[1]
    ' top-down so blocking popups go first. Repeat up to 3 times to catch
    ' chained popups.
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
                ' Inactive-objects worklist popup. Discriminator: it carries
                ' a Select All button at tbar[0]/btn[9]. DETECT via btn[9]
                ' but deliberately do NOT press it -- the triggering object
                ' (and its dependent includes) is already pre-selected, so
                ' Continue (btn[0]) activates exactly it. Select All would
                ' co-activate every UNRELATED inactive object on a shared DEV
                ' (EC2/DEV102: 500+). Never fall back to Select All if
                ' Continue doesn't clear it -- the post-activate DWINACTIV
                ' verify reports a still-inactive object as a real failure.
                Set oBtn = Nothing
                Set oBtn = oSess.findById(sId & "/tbar[0]/btn[9]")
                If Err.Number = 0 And Not (oBtn Is Nothing) Then
                    Err.Clear
                    Set oBtn = Nothing
                    Set oBtn = oSess.findById(sId & "/tbar[0]/btn[0]")
                    If Err.Number = 0 And Not (oBtn Is Nothing) Then
                        oBtn.press
                        WScript.Sleep 1200
                        WScript.Echo "INFO: " & sId & " - inactive-objects worklist; Continue pressed (pre-selected object only, no Select All)."
                    End If
                    bAnyDismissed = True
                Else
                    Err.Clear
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
