' =============================================================================
' sap_se11_change_package.vbs  -  Change package assignment of SE11 objects
'
' Navigates to SE11, selects the object by type and name, then uses
' Goto > Object Directory Entry to change the package from $TMP (or any
' other package) to the target package with optional transport assignment.
'
' Supported object types:
'   TABL  - Database table / Structure
'   VIEW  - View
'   DTEL  - Data type (Data element)
'   TTYP  - Type Group
'   DOMA  - Domain
'   SHLP  - Search Help
'   ENQU  - Lock Object
'
' Tokens replaced at run time:
'   %%OBJECT_TYPE%%    One of: TABL, VIEW, DTEL, TTYP, DOMA, SHLP, ENQU
'   %%OBJECT_NAME%%    Object name (e.g. "ZHKTABLE01")
'   %%PACKAGE%%        Target package (e.g. "ZHKA003")
'   %%TRANSPORT%%      Transport number (empty = create new request)
'
' Component IDs recorded from SAP GUI 7.60 on S/4HANA 1909 (S4D).
' =============================================================================

Option Explicit

Const OBJECT_TYPE   = "%%OBJECT_TYPE%%"
Const OBJECT_NAME   = "%%OBJECT_NAME%%"
Const SAP_PACKAGE   = "%%PACKAGE%%"
Const SAP_TRANSPORT = "%%TRANSPORT%%"
Const SESSION_PATH  = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER = 0

' Include shared helpers (attach first; session-lock's pre-unlock sweep
' reads from oSession).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

' ------ 1. Attach to existing SAP GUI session (via shared attach helper) ----
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

' ------ 2. Navigate to SE11 -------------------------------------------------
WScript.Echo "INFO: Navigating to SE11..."
oSession.findById("wnd[0]").maximize
oSession.findById("wnd[0]/tbar[0]/okcd").text = "/nSE11"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000

' --- Lock the SAP session UI for the package reassignment + save critical section ---
' Defence in depth (Rule 7): AppActivate guards external focus stealing;
' LockSessionUI guards in-session input races. Released after activation.
Dim wasLocked : wasLocked = TryLockSession(oSession)
If wasLocked Then
    WScript.Echo "INFO: Session UI locked for the package reassignment + save critical section."
Else
    WScript.Echo "INFO: LockSessionUI not available on this SAP GUI build; continuing without lock."
End If

' ------ 3. Select object type and enter name --------------------------------
Dim sRadio, sField
Select Case UCase(OBJECT_TYPE)
    Case "TABL"
        sRadio = "wnd[0]/usr/radRSRD1-TBMA"
        sField = "wnd[0]/usr/ctxtRSRD1-TBMA_VAL"
    Case "VIEW"
        sRadio = "wnd[0]/usr/radRSRD1-VIMA"
        sField = "wnd[0]/usr/ctxtRSRD1-VIMA_VAL"
    Case "DTEL"
        sRadio = "wnd[0]/usr/radRSRD1-DDTYPE"
        sField = "wnd[0]/usr/ctxtRSRD1-DDTYPE_VAL"
    Case "TTYP"
        sRadio = "wnd[0]/usr/radRSRD1-TYMA"
        sField = "wnd[0]/usr/ctxtRSRD1-TYMA_VAL"
    Case "DOMA"
        sRadio = "wnd[0]/usr/radRSRD1-DOMA"
        sField = "wnd[0]/usr/ctxtRSRD1-DOMA_VAL"
    Case "SHLP"
        sRadio = "wnd[0]/usr/radRSRD1-SHMA"
        sField = "wnd[0]/usr/ctxtRSRD1-SHMA_VAL"
    Case "ENQU"
        sRadio = "wnd[0]/usr/radRSRD1-ENQU"
        sField = "wnd[0]/usr/ctxtRSRD1-ENQU_VAL"
    Case Else
        WScript.Echo "ERROR: Unsupported object type: " & OBJECT_TYPE
        ReleaseSession oSession, wasLocked
        WScript.Quit 1
End Select

WScript.Echo "INFO: Selecting " & UCase(OBJECT_TYPE) & " = " & UCase(OBJECT_NAME)
oSession.findById(sRadio).select
oSession.findById(sField).Text = UCase(OBJECT_NAME)
WScript.Sleep 300

' ------ 4. Open Object Directory Entry (Goto > Object Directory Entry) ------
' Menu path: Goto (menu[2]) > Object Directory Entry (menu[0])
WScript.Echo "INFO: Opening Object Directory Entry..."
oSession.findById("wnd[0]/mbar/menu[2]/menu[0]").select
WScript.Sleep 2000

' Check if a dialog appeared
On Error Resume Next
Dim oPopup
Set oPopup = oSession.findById("wnd[1]")
If Err.Number <> 0 Or oPopup Is Nothing Then
    WScript.Echo "ERROR: Object Directory Entry dialog did not appear. Object may not exist."
    ReleaseSession oSession, wasLocked
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' The dialog may show the current package in Display mode.
' Check if btn[6] exists (switch to Change mode / Continue)
On Error Resume Next
Dim oBtnChange
Set oBtnChange = oSession.findById("wnd[1]/tbar[0]/btn[6]")
If Err.Number = 0 And Not (oBtnChange Is Nothing) Then
    WScript.Echo "INFO: Switching to change mode..."
    oBtnChange.press
    WScript.Sleep 1000
End If
Err.Clear
On Error GoTo 0

' ------ 5. Set the new package ----------------------------------------------
On Error Resume Next
Dim oPkgField
Set oPkgField = oSession.findById("wnd[1]/usr/ctxtKO007-L_DEVCLASS")
If Err.Number <> 0 Or oPkgField Is Nothing Then
    Err.Clear
    ' Try alternative package field ID
    Set oPkgField = oSession.findById("wnd[1]/usr/ctxtTADIR-DEVCLASS")
    If Err.Number <> 0 Or oPkgField Is Nothing Then
        WScript.Echo "ERROR: Cannot find package field in dialog."
        ReleaseSession oSession, wasLocked
        WScript.Quit 1
    End If
End If
Err.Clear
On Error GoTo 0

Dim sOldPkg
sOldPkg = oPkgField.Text
WScript.Echo "INFO: Current package: " & sOldPkg & " -> New package: " & SAP_PACKAGE
oPkgField.Text = SAP_PACKAGE

' Press Enter to confirm package change
oSession.findById("wnd[1]/tbar[0]/btn[0]").press
WScript.Sleep 2000

' ------ 6. Handle transport request -----------------------------------------
' After changing package, a transport dialog may appear
On Error Resume Next
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
    If SAP_TRANSPORT <> "" Then
        ' Existing transport provided
        WScript.Echo "INFO: Assigning to transport " & SAP_TRANSPORT & "..."
        Dim oTrField
        Set oTrField = oSession.findById("wnd[1]/usr/ctxtKO008-TRKORR")
        If Err.Number = 0 And Not (oTrField Is Nothing) Then
            oTrField.Text = SAP_TRANSPORT
        End If
        Err.Clear
        oSession.findById("wnd[1]/tbar[0]/btn[0]").press
        WScript.Sleep 1000
    Else
        ' No transport — create new request
        WScript.Echo "INFO: Creating new transport request..."
        oSession.findById("wnd[1]/tbar[0]/btn[8]").press
        WScript.Sleep 1000
        ' Enter description for new request
        oSession.findById("wnd[2]/usr/txtKO013-AS4TEXT").Text = _
            "Change package: " & UCase(OBJECT_NAME)
        oSession.findById("wnd[2]/tbar[0]/btn[0]").press
        WScript.Sleep 1000
        ' Confirm the transport dialog
        oSession.findById("wnd[1]/tbar[0]/btn[0]").press
        WScript.Sleep 1000
    End If
End If
Err.Clear
On Error GoTo 0

' Handle any remaining popup
On Error Resume Next
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
    oSession.ActiveWindow.sendVKey VKEY_ENTER
    WScript.Sleep 1000
End If
Err.Clear
On Error GoTo 0

' --- Release the session UI lock; navigate-back + report is read-only ---
ReleaseSession oSession, wasLocked
If wasLocked Then WScript.Echo "INFO: Session UI lock released."

' ------ 7. Navigate back and report -----------------------------------------
' Press F15 (Back) or navigate away
oSession.findById("wnd[0]/tbar[0]/btn[15]").press
WScript.Sleep 500

Dim sStatus
sStatus = oSession.findById("wnd[0]/sbar").Text
WScript.Echo "INFO: Status: " & sStatus

WScript.Echo "SUCCESS: Package of " & UCase(OBJECT_TYPE) & " " & UCase(OBJECT_NAME) & _
             " changed from " & sOldPkg & " to " & SAP_PACKAGE & "."
WScript.Quit 0
