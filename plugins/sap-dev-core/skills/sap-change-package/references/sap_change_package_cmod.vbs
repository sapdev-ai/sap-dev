' =============================================================================
' sap_change_package_cmod.vbs
'   Change the package (TADIR-DEVCLASS) of a CMOD enhancement project via
'   CMOD > Goto > Object Directory Entry. The Object-Directory-Entry dialog
'   (KO007) and its popup chain are identical to the SE38/SE37/... siblings;
'   only the navigation (CMOD + MOD0-NAME) differs.
'
' Tokens:
'   %%OBJECT_NAME%%      Enhancement project name (max 8, e.g. "ZHKPJ001")
'   %%NEW_PACKAGE%%      Target package — "$TMP" (or any $*) for local,
'                        "Z*" / "Y*" for transportable.
'   %%TRANSPORT%%        Pre-resolved TR (TMP_TO_TRANSPORT mode); empty otherwise.
'   %%TR_DESCRIPTION%%   Description for the "Create Request" popup if it appears.
'
' Recording reference: C:\Temp\Record_CMOD_ChangeProjectPackage.vbs (S/4HANA 1909).
'
' Output contract:
'   INFO: ... progress
'   STATUS_TYPE: <S|W|E|A|I>
'   STATUS_TEXT: <text>
'   DONE | ERROR: ...
' =============================================================================

Option Explicit

Const OBJECT_NAME    = "%%OBJECT_NAME%%"
Const NEW_PACKAGE    = "%%NEW_PACKAGE%%"
Const TRANSPORT      = "%%TRANSPORT%%"
Const TR_DESCRIPTION = "%%TR_DESCRIPTION%%"
Const SESSION_PATH   = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

' CMOD menu path: Goto > Object Directory Entry (same index as SE38).
Const MENU_OBJECT_DIR = "wnd[0]/mbar/menu[2]/menu[3]"

Const VKEY_ENTER         = 0
Const VKEY_F3_BACK       = 3
Const VKEY_SHIFT_F3_EXIT = 15

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim sName, sPkg

sName = UCase(Trim(OBJECT_NAME))
sPkg  = UCase(Trim(NEW_PACKAGE))
If sName = "" Then : WScript.Echo "ERROR: OBJECT_NAME is empty." : WScript.Quit 1 : End If
If sPkg  = "" Then : WScript.Echo "ERROR: NEW_PACKAGE is empty." : WScript.Quit 1 : End If

' ------ Attach to session (via shared attach helper) -------------------------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Session acquired. Changing CMOD project " & sName & " package -> " & sPkg

' ------ Navigate to CMOD + enter project name --------------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/ncmod"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000

On Error Resume Next
oSess.findById("wnd[0]/usr/ctxtMOD0-NAME").Text = sName
WScript.Sleep 200
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Project name field not found (ctxtMOD0-NAME)."
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0
oSess.findById("wnd[0]").sendVKey VKEY_ENTER   ' select the project
WScript.Sleep 500

' ------ Run the shared change-package flow ------------------------------------
ChangePackageFlow

' Should not reach here — ChangePackageFlow exits.
WScript.Quit 0


' ============================================================================
' Shared flow (same body as the other sap_change_package_*.vbs templates).
' ============================================================================
Sub ChangePackageFlow
    Dim sStatusType, sStatusText
    Dim oCtrl

    ' --- 1. Open Goto > Object Directory Entry --------------------------------
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

    ' --- 2. Press Change (display -> edit) ------------------------------------
    On Error Resume Next
    oSess.findById("wnd[1]/tbar[0]/btn[6]").press
    WScript.Sleep 1000
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Could not press Change (wnd[1]/tbar[0]/btn[6]): " & Err.Description
        WScript.Quit 1
    End If
    Err.Clear
    On Error GoTo 0

    ' --- 3. Enter new package -------------------------------------------------
    On Error Resume Next
    oSess.findById("wnd[1]/usr/ctxtKO007-L_DEVCLASS").Text = sPkg
    WScript.Sleep 200
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Package field not found (ctxtKO007-L_DEVCLASS): " & Err.Description
        WScript.Quit 1
    End If
    Err.Clear
    On Error GoTo 0

    ' --- 4. Press Enter (validates the package) -------------------------------
    On Error Resume Next
    oSess.findById("wnd[1]/tbar[0]/btn[0]").press
    WScript.Sleep 1500
    Err.Clear
    On Error GoTo 0

    ' --- 5. Handle wnd[2] popup if present ------------------------------------
    HandlePopupChain

    ' --- 6. Locality-specific finishing --------------------------------------
    If Left(sPkg, 1) = "$" Then
        ' --- 6a. Going to LOCAL — press Local object button ------------------
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
        ' --- 6b. Going to TRANSPORTABLE — handle TR assignment ---------------
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
                    WScript.Echo "INFO: No TRANSPORT supplied — pressing 'Create Request' (btn[8])."
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

        ' Final confirmation on wnd[1] if still present
        On Error Resume Next
        If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
            oSess.findById("wnd[1]/tbar[0]/btn[0]").press
            WScript.Sleep 1000
        End If
        Err.Clear
        On Error GoTo 0
    End If

    ' --- 7. Read status bar ---------------------------------------------------
    On Error Resume Next
    sStatusType = oSess.findById("wnd[0]/sbar").MessageType
    sStatusText = oSess.findById("wnd[0]/sbar").Text
    Err.Clear
    On Error GoTo 0

    WScript.Echo "STATUS_TYPE: " & sStatusType
    WScript.Echo "STATUS_TEXT: " & sStatusText

    ' --- 8. Back to initial screen --------------------------------------------
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

' ============================================================================
' Handle wnd[2] popups: TR-description prompt OR plain confirmation.
' Loops up to 3 times because some flows show a confirm followed by a desc.
' ============================================================================
Sub HandlePopupChain
    Dim iLoop, oDescFld, sTitle, oM1, oM2, sM1, sM2
    For iLoop = 1 To 3
        On Error Resume Next
        If InStr(oSess.ActiveWindow.Id, "wnd[2]") > 0 Then
            sTitle = oSess.ActiveWindow.Text
            If LCase(sTitle) = "error" Or LCase(sTitle) = "information" Then
                Set oM1 = Nothing : Set oM1 = oSess.findById("wnd[2]/usr/txtMESSTXT1")
                Err.Clear
                Set oM2 = Nothing : Set oM2 = oSess.findById("wnd[2]/usr/txtMESSTXT2")
                Err.Clear
                sM1 = "" : If Not (oM1 Is Nothing) Then sM1 = oM1.Text
                sM2 = "" : If Not (oM2 Is Nothing) Then sM2 = oM2.Text
                If InStr(LCase(sM1 & " " & sM2), "locked") > 0 Or LCase(sTitle) = "error" Then
                    WScript.Echo "ERROR: SAP popup [" & sTitle & "] " & Trim(sM1 & " " & sM2)
                    On Error Resume Next
                    oSess.findById("wnd[2]/tbar[0]/btn[1]").press
                    If Err.Number <> 0 Then : Err.Clear : oSess.findById("wnd[2]/tbar[0]/btn[0]").press : End If
                    Err.Clear
                    On Error GoTo 0
                    WScript.Quit 1
                End If
            End If
            Err.Clear
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
