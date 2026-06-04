' =============================================================================
' sap_change_package_se11.vbs
'   Change the package of any DDIC object via SE11 > Goto > Object Directory.
'
' Tokens: %%OBJECT_NAME%%, %%OBJECT_TYPE%%, %%NEW_PACKAGE%%, %%TRANSPORT%%,
'         %%TR_DESCRIPTION%%
' Output: INFO / STATUS_TYPE / STATUS_TEXT / DONE | ERROR
' =============================================================================

Option Explicit

Const OBJECT_NAME    = "%%OBJECT_NAME%%"
Const OBJECT_TYPE    = "%%OBJECT_TYPE%%"
Const NEW_PACKAGE    = "%%NEW_PACKAGE%%"
Const TRANSPORT      = "%%TRANSPORT%%"
Const TR_DESCRIPTION = "%%TR_DESCRIPTION%%"
Const SESSION_PATH   = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

' SE11 Display screen: Goto > Object Directory Entry
Const MENU_OBJECT_DIR = "wnd[0]/mbar/menu[2]/menu[0]"

Const VKEY_ENTER         = 0
Const VKEY_F3_BACK       = 3
Const VKEY_SHIFT_F3_EXIT = 15

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim sName, sPkg, sType, sRadio, sNameField

sName = UCase(Trim(OBJECT_NAME))
sType = UCase(Trim(OBJECT_TYPE))
sPkg  = UCase(Trim(NEW_PACKAGE))
If sName = "" Then : WScript.Echo "ERROR: OBJECT_NAME is empty." : WScript.Quit 1 : End If
If sType = "" Then : WScript.Echo "ERROR: OBJECT_TYPE is empty." : WScript.Quit 1 : End If
If sPkg  = "" Then : WScript.Echo "ERROR: NEW_PACKAGE is empty." : WScript.Quit 1 : End If

' Map OBJECT_TYPE -> SE11 radio + name field (same mapping as sap_activate_se11.vbs)
Select Case sType
    Case "TABLE", "TABL"
        sRadio     = "wnd[0]/usr/radRSRD1-TBMA"
        sNameField = "wnd[0]/usr/ctxtRSRD1-TBMA_VAL"
    Case "VIEW", "VIMA"
        sRadio     = "wnd[0]/usr/radRSRD1-VIMA"
        sNameField = "wnd[0]/usr/ctxtRSRD1-VIMA_VAL"
    Case "DTEL", "DATAELEMENT", "STRUCTURE", "STRU", "TABLETYPE", "TTYP", "DDTYPE"
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

' ------ Attach to session (via shared attach helper) -------------------------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Session acquired. Changing " & sType & " " & sName & " package -> " & sPkg

' Navigate to SE11 + select radio + enter name
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nse11"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000

On Error Resume Next
oSess.findById(sRadio).select
WScript.Sleep 200
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not select SE11 radio " & sRadio & ": " & Err.Description
    WScript.Quit 1
End If
Err.Clear
oSess.findById(sNameField).Text = sName
WScript.Sleep 200
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not enter name into " & sNameField & ": " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' Note: Goto > Object Directory Entry works directly from the SE11 initial
' screen with the radio + name set; no need to open the object first.

ChangePackageFlow

WScript.Quit 0


Sub ChangePackageFlow
    Dim sStatusType, sStatusText, oCtrl

    WScript.Echo "INFO: Opening Goto > Object Directory Entry..."
    On Error Resume Next
    oSess.findById(MENU_OBJECT_DIR).select
    WScript.Sleep 1500
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Menu " & MENU_OBJECT_DIR & " not found: " & Err.Description
        WScript.Quit 1
    End If
    Err.Clear
    On Error GoTo 0

    On Error Resume Next
    oSess.findById("wnd[1]/tbar[0]/btn[6]").press
    WScript.Sleep 1000
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Could not press Change: " & Err.Description
        WScript.Quit 1
    End If
    Err.Clear
    On Error GoTo 0

    On Error Resume Next
    oSess.findById("wnd[1]/usr/ctxtKO007-L_DEVCLASS").Text = sPkg
    WScript.Sleep 200
    If Err.Number <> 0 Then : WScript.Echo "ERROR: Package field not found." : WScript.Quit 1 : End If
    Err.Clear
    oSess.findById("wnd[1]/tbar[0]/btn[0]").press
    WScript.Sleep 1500
    Err.Clear
    On Error GoTo 0

    HandlePopupChain

    If Left(sPkg, 1) = "$" Then
        On Error Resume Next
        If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
            Set oCtrl = oSess.findById("wnd[1]/tbar[0]/btn[12]")
            If Err.Number = 0 Then
                If Not (oCtrl Is Nothing) Then
                    WScript.Echo "INFO: Pressing 'Local object' (btn[12])."
                    oCtrl.press
                    WScript.Sleep 1500
                End If
            End If
            Err.Clear
        End If
        Err.Clear
        On Error GoTo 0
    Else
        On Error Resume Next
        If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
            Set oCtrl = Nothing
            Set oCtrl = oSess.findById("wnd[1]/usr/ctxtKO008-TRKORR")
            If Err.Number = 0 And Not (oCtrl Is Nothing) Then
                If TRANSPORT <> "" Then
                    WScript.Echo "INFO: Entering existing TR: " & TRANSPORT
                    oCtrl.Text = TRANSPORT
                    oSess.findById("wnd[1]/tbar[0]/btn[0]").press
                    WScript.Sleep 1500
                    HandlePopupChain
                Else
                    Err.Clear
                    WScript.Echo "INFO: No TRANSPORT —pressing Create Request (btn[8])."
                    oSess.findById("wnd[1]/tbar[0]/btn[8]").press
                    WScript.Sleep 1500
                    HandlePopupChain
                End If
            Else
                Err.Clear
                Set oCtrl = Nothing
                Set oCtrl = oSess.findById("wnd[1]/tbar[0]/btn[8]")
                If Err.Number = 0 And Not (oCtrl Is Nothing) Then
                    WScript.Echo "INFO: Pressing 'Create Request' (btn[8]) defensively."
                    oCtrl.press
                    WScript.Sleep 1500
                    HandlePopupChain
                End If
                Err.Clear
            End If
        End If
        Err.Clear
        On Error GoTo 0

        On Error Resume Next
        If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
            oSess.findById("wnd[1]/tbar[0]/btn[0]").press
            WScript.Sleep 1000
        End If
        Err.Clear
        On Error GoTo 0
    End If

    On Error Resume Next
    sStatusType = oSess.findById("wnd[0]/sbar").MessageType
    sStatusText = oSess.findById("wnd[0]/sbar").Text
    Err.Clear
    On Error GoTo 0

    WScript.Echo "STATUS_TYPE: " & sStatusType
    WScript.Echo "STATUS_TEXT: " & sStatusText

    On Error Resume Next
    oSess.findById("wnd[0]").sendVKey VKEY_SHIFT_F3_EXIT
    WScript.Sleep 500
    Err.Clear
    On Error GoTo 0

    If sStatusType = "E" Or sStatusType = "A" Then
        WScript.Echo "ERROR: Change package reported [" & sStatusType & "] " & sStatusText
        WScript.Quit 1
    End If

    WScript.Echo "DONE"
    WScript.Quit 0
End Sub

Sub HandlePopupChain
    Dim iLoop, oDescFld, sTitle, oM1, oM2, sM1, sM2
    For iLoop = 1 To 3
        On Error Resume Next
        If InStr(oSess.ActiveWindow.Id, "wnd[2]") > 0 Then
            sTitle = oSess.ActiveWindow.Text
            ' --- Detect Error popup (e.g., "Object directory entry ... locked for request/task ...")
            If LCase(sTitle) = "error" Or LCase(sTitle) = "information" Then
                Set oM1 = Nothing : Set oM1 = oSess.findById("wnd[2]/usr/txtMESSTXT1")
                Err.Clear
                Set oM2 = Nothing : Set oM2 = oSess.findById("wnd[2]/usr/txtMESSTXT2")
                Err.Clear
                sM1 = "" : If Not (oM1 Is Nothing) Then sM1 = oM1.Text
                sM2 = "" : If Not (oM2 Is Nothing) Then sM2 = oM2.Text
                If InStr(LCase(sM1 & " " & sM2), "locked") > 0 Or LCase(sTitle) = "error" Then
                    WScript.Echo "ERROR: SAP popup [" & sTitle & "] " & Trim(sM1 & " " & sM2)
                    ' Close popup with Cancel (btn[1]) if present, else btn[0]
                    On Error Resume Next
                    oSess.findById("wnd[2]/tbar[0]/btn[1]").press
                    If Err.Number <> 0 Then : Err.Clear : oSess.findById("wnd[2]/tbar[0]/btn[0]").press : End If
                    Err.Clear
                    On Error GoTo 0
                    WScript.Quit 1
                End If
            End If
            Err.Clear
            ' --- Normal "Create Request"/"Create Task" confirmation popup
            Set oDescFld = Nothing
            Set oDescFld = oSess.findById("wnd[2]/usr/txtKO013-AS4TEXT")
            If Err.Number = 0 Then
                If Not (oDescFld Is Nothing) Then
                    Dim sDesc
                    sDesc = TR_DESCRIPTION
                    If sDesc = "" Then sDesc = OBJECT_NAME & "_pkg_" & NEW_PACKAGE
                    If Len(sDesc) > 60 Then sDesc = Left(sDesc, 60)
                    oDescFld.Text = sDesc
                    WScript.Echo "INFO: Filled new-TR description: " & sDesc
                End If
            End If
            Err.Clear
            oSess.findById("wnd[2]/tbar[0]/btn[0]").press
            WScript.Sleep 1500
            Err.Clear
        Else
            Err.Clear
            On Error GoTo 0
            Exit For
        End If
        On Error GoTo 0
    Next
End Sub
