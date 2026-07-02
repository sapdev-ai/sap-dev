' =============================================================================
' sap_activate_se37.vbs  -  Activate a function module via SE37
'
' Tokens replaced at run time:
'   %%OBJECT_NAME%%   Function module name (e.g. "Z_HKFM_TEST007")
'
' Flow (from C:\Temp\Record_SE37_03_ActiveteFM.vbs):
'   1. /nse37
'   2. Enter FM name into ctxtRS38L-NAME
'   3. sendVKey 27 (Ctrl+F3 = Activate)
'   4. If wnd[1] popup appears: tbar[0]/btn[0] = Continue (FM activate popup
'      typically lists includes/dependents to activate together).
'   5. Read sbar; expect "Object(s) activated".
'   6. F3 back.
'
' Output (parsed by caller):
'   STATUS_TYPE: <type>  /  STATUS_TEXT: <text>  /  DONE | ERROR: ...
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
WScript.Echo "INFO: Session acquired. Activating FM " & sName & " via SE37..."

' ------ 2. Navigate to SE37 ---------------------------------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nse37"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000

' ------ 3. Enter FM name ------------------------------------------------------
On Error Resume Next
Dim oNameField
Set oNameField = oSess.findById("wnd[0]/usr/ctxtRS38L-NAME")
If Err.Number <> 0 Or oNameField Is Nothing Then
    WScript.Echo "ERROR: FM name field not found (wnd[0]/usr/ctxtRS38L-NAME)."
    WScript.Quit 1
End If
oNameField.Text = sName
WScript.Sleep 300
Err.Clear
On Error GoTo 0

' ------ 4. Send Activate (Ctrl+F3) --------------------------------------------
WScript.Echo "INFO: Sending Activate (Ctrl+F3)..."
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_CTRL_F3_ACT
WScript.Sleep 2500
Err.Clear
On Error GoTo 0

' ------ 5. Handle popup if present --------------------------------------------
HandleActivatePopup

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
    WScript.Echo "ERROR: SE37 activation reported [" & sStatusType & "] " & sStatusText
    WScript.Quit 1
End If

WScript.Echo "DONE"
WScript.Quit 0


Sub HandleActivatePopup
    ' Top-down z-order sweep -- see sap_activate_se11.vbs for the full rationale.
    ' SAP can stack multiple modals after Activate (e.g. wnd[2] error popup ON
    ' TOP of wnd[1] confirm); checking only ActiveWindow == wnd[1] misses the
    ' higher-numbered window. Iterate wnd[9]..wnd[1] top-down. FMs typically
    ' show only a single Continue popup, but the loop handles worklist-style
    ' popups too (detected via btn[9], dismissed with Continue ONLY -- never
    ' Select All) and chained info/error popups.
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
