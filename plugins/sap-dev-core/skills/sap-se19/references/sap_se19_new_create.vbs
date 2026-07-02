' =============================================================================
' sap_se19_new_create.vbs  -  Create a NEW (Enhancement Framework) BAdI
'                             implementation via SE19.
'
' Creates the Enhancement Implementation (container), one BAdI Implementation
' (element) bound to a BAdI definition, the implementing class (empty shell),
' assigns package + transport (or Local Object), then activates.
'
' The implementing-class METHOD SOURCE is NOT deployed here -- the sap-se19
' skill delegates that to /sap-se24 (class operations belong to SE24).
'
' Probed live against S/4HANA 1909 (S4D), SAP GUI 7.60, EN logon, 2026-05-30.
' Programs: SAPLSEXO(120) -> SAPLSEEF_BASE(3000) -> SAPLSTRD(100/300)
'           -> SAPLENH_BADI_POPUPS(1000) -> SAPLENH_EDT_BADI(1000)
'           -> SAPLENHANCEMENT_EDITOR(6000) -> SAPLSEWORKINGAREA worklist.
'
' Tokens (substituted by SKILL.md PS wrapper):
'   %%ENH_SPOT%%        Enhancement Spot name (BAdI definition's spot)
'   %%ENH_IMPL_NAME%%   Enhancement Implementation (container) name
'   %%ENH_IMPL_TEXT%%   Enhancement Implementation short text
'   %%BADI_DEFINITION%% BAdI definition name (combo key in the create popup)
'   %%BADI_IMPL_NAME%%  BAdI Implementation (element) name
'   %%IMPL_CLASS%%      Implementing class name
'   %%BADI_IMPL_TEXT%%  BAdI implementation short text (best-effort)
'   %%DEVCLASS%%        Package; empty => Local Object ($TMP)
'   %%TRKORR%%          Transport request; honoured when DEVCLASS is set
'   %%SESSION_PATH%%    Parallel-safe attach target (empty = sole session)
' =============================================================================
Option Explicit

Const ENH_SPOT        = "%%ENH_SPOT%%"
Const ENH_IMPL_NAME   = "%%ENH_IMPL_NAME%%"
Const ENH_IMPL_TEXT   = "%%ENH_IMPL_TEXT%%"
Const BADI_DEFINITION = "%%BADI_DEFINITION%%"
Const BADI_IMPL_NAME  = "%%BADI_IMPL_NAME%%"
Const IMPL_CLASS      = "%%IMPL_CLASS%%"
Const BADI_IMPL_TEXT  = "%%BADI_IMPL_TEXT%%"
Const DEVCLASS        = "%%DEVCLASS%%"
Const TRKORR          = "%%TRKORR%%"
Const SESSION_PATH    = "%%SESSION_PATH%%"

Const VKEY_ENTER = 0
Const VKEY_SAVE  = 11
Const VKEY_CANCEL = 12

ExecuteGlobal CreateObject("Scripting.FileSystemObject").OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

' ---- helpers ---------------------------------------------------------------
Function CtrlExists(sId)
    Dim o : CtrlExists = False
    On Error Resume Next
    Set o = oSession.findById(sId, False)
    If Err.Number = 0 And Not (o Is Nothing) Then CtrlExists = True
    On Error GoTo 0
End Function

Function TopWin()
    Dim i, sId
    TopWin = ""
    For i = 8 To 1 Step -1
        If CtrlExists("wnd[" & i & "]") Then TopWin = "wnd[" & i & "]" : Exit Function
    Next
End Function

Sub SetText(sId, sVal)
    On Error Resume Next
    oSession.findById(sId).Text = sVal
    On Error GoTo 0
End Sub

Sub PressIf(sId)
    On Error Resume Next
    oSession.findById(sId).Press
    On Error GoTo 0
End Sub

' Handle the standard SAPLSTRD object-directory + transport popups, wherever
' they appear (wnd[1] or wnd[2]). Identifies by DDIC field id, not by title.
Dim gAbortEmptyTr : gAbortEmptyTr = False
Sub HandleTransport()
    Dim pass, w
    For pass = 1 To 6
        w = TopWin()
        If w = "wnd[0]" Or w = "" Then Exit Sub
        If CtrlExists(w & "/usr/ctxtKO007-L_DEVCLASS") Or CtrlExists(w & "/usr/txtKO007-L_DEVCLASS") Then
            ' Object Directory Entry popup
            If DEVCLASS <> "" Then
                If CtrlExists(w & "/usr/ctxtKO007-L_DEVCLASS") Then SetText w & "/usr/ctxtKO007-L_DEVCLASS", DEVCLASS
                If CtrlExists(w & "/usr/txtKO007-L_DEVCLASS")  Then SetText w & "/usr/txtKO007-L_DEVCLASS", DEVCLASS
                PressIf w & "/tbar[0]/btn[0]"     ' Save
            Else
                PressIf w & "/tbar[0]/btn[7]"     ' Local Object
            End If
            WScript.Sleep 1500
        ElseIf CtrlExists(w & "/usr/ctxtKO008-TRKORR") Then
            ' Prompt for transportable workbench request. Empty TR must ABORT loud,
            ' never blind-Continue (which silently falls back to Local Object).
            If TRKORR = "" Then
                gAbortEmptyTr = True
                Exit Sub
            End If
            SetText w & "/usr/ctxtKO008-TRKORR", TRKORR
            PressIf w & "/tbar[0]/btn[0]"         ' Continue
            WScript.Sleep 1500
        Else
            Exit Sub
        End If
    Next
End Sub

' ---- 1. SE19 initial: create section, New BAdI -----------------------------
WScript.Echo "INFO: SE19 -> create New BAdI enhancement implementation " & UCase(ENH_IMPL_NAME)
oSession.findById("wnd[0]").Maximize
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE19"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1200

oSession.findById("wnd[0]/usr/radG_IS_NEW_2").Select
oSession.findById("wnd[0]/usr/ctxtG_ENHSPOTNAME").Text = UCase(ENH_SPOT)
oSession.findById("wnd[0]/usr/btnPUSHBUTTON_IMPLEMENT_TEXT").Press
WScript.Sleep 2000

' ---- 2. Create Enhancement Implementation popup ----------------------------
If Not CtrlExists("wnd[1]/usr/txtG_ENHSTRU-ENHNAME") Then
    WScript.Echo "ERROR: Create Enhancement Implementation popup did not appear. Status: " & _
                 oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If
oSession.findById("wnd[1]/usr/txtG_ENHSTRU-ENHNAME").Text = UCase(ENH_IMPL_NAME)
oSession.findById("wnd[1]/usr/txtG_ENHSTRU-SHORTTEXT").Text = ENH_IMPL_TEXT
oSession.findById("wnd[1]/tbar[0]/btn[0]").Press
WScript.Sleep 2000

' Object directory + TR for the enhancement implementation
HandleTransport
WScript.Sleep 1000
If gAbortEmptyTr Then
    WScript.Echo "ERROR: ABORT_EMPTY_TR -- SAP prompted for a transport request but TRKORR is empty."
    WScript.Echo "       Resolve a TR via /sap-transport-request and re-run the create."
    WScript.Quit 1
End If

' ---- 3. Create BAdI Implementations popup (table control) ------------------
Dim sTbl
sTbl = "wnd[1]/usr/tblSAPLENH_BADI_POPUPSG_BADI_TABLE"
If Not CtrlExists(sTbl & "/txtG_BADI-IMPL_NAME[0,0]") Then
    WScript.Echo "ERROR: Create BAdI Implementations popup did not appear. Status: " & _
                 oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If
oSession.findById(sTbl & "/txtG_BADI-IMPL_NAME[0,0]").Text  = UCase(BADI_IMPL_NAME)
oSession.findById(sTbl & "/txtG_BADI-CLASS_NAME[1,0]").Text = UCase(IMPL_CLASS)
' BAdI definition is a combo box -> set by .Key (Text is read-only)
On Error Resume Next
oSession.findById(sTbl & "/cmbG_BADI-BADI_NAME[2,0]").Key = UCase(BADI_DEFINITION)
On Error GoTo 0
' short text (best-effort; cell may reject if the row isn't scrolled)
On Error Resume Next
oSession.findById(sTbl & "/txtG_BADI-BADI_SHORTTEXT[3,0]").Text = BADI_IMPL_TEXT
On Error GoTo 0
oSession.findById("wnd[1]/tbar[0]/btn[0]").Press
WScript.Sleep 2000

' ---- 4. Create Implementation Class popup -> Empty Class --------------------
If CtrlExists("wnd[1]/tbar[0]/btn[2]") Then
    oSession.findById("wnd[1]/tbar[0]/btn[2]").Press   ' Create Empty Class (F2)
    WScript.Sleep 2000
End If

' Object directory + TR for the implementing class
HandleTransport
WScript.Sleep 1000
If gAbortEmptyTr Then
    WScript.Echo "ERROR: ABORT_EMPTY_TR -- SAP prompted for a transport request but TRKORR is empty."
    WScript.Echo "       Resolve a TR via /sap-transport-request and re-run the create."
    WScript.Quit 1
End If

' Some releases re-show a confirmation popup; press Continue if present
If CtrlExists("wnd[1]/tbar[0]/btn[0]") And Not CtrlExists("wnd[1]/usr/ctxtKO008-TRKORR") Then
    PressIf "wnd[1]/tbar[0]/btn[0]"
    WScript.Sleep 1500
End If

' ---- 5. Verify we reached the enhancement-implementation detail screen ------
If Not CtrlExists("wnd[0]/usr/txtENH_EDT_LAYOUT-OBJECT1") Then
    WScript.Echo "ERROR: Did not reach the enhancement implementation editor. Status: " & _
                 oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If
WScript.Echo "INFO: Enhancement implementation created: " & _
             oSession.findById("wnd[0]/sbar").Text

' ---- 6. Activate (Ctrl+F3) -------------------------------------------------
oSession.findById("wnd[0]/tbar[1]/btn[27]").Press
WScript.Sleep 3000

' Inactive-objects worklist popup -> Continue (activate the worklist)
If CtrlExists("wnd[1]/tbar[0]/btn[0]") Then
    oSession.findById("wnd[1]/tbar[0]/btn[0]").Press
    WScript.Sleep 4000
End If

' ---- 7. Final status -------------------------------------------------------
Dim sType, sMsg
sType = oSession.findById("wnd[0]/sbar").MessageType
sMsg  = oSession.findById("wnd[0]/sbar").Text
If sType = "E" Or sType = "A" Then
    WScript.Echo "ERROR: Activation failed: " & sMsg
    WScript.Quit 1
End If
Dim sVer : sVer = ""
If CtrlExists("wnd[0]/usr/txtENH_EDT_LAYOUT-VERSION_TX") Then sVer = oSession.findById("wnd[0]/usr/txtENH_EDT_LAYOUT-VERSION_TX").Text
WScript.Echo "INFO: Status=" & sMsg & "  Version=" & sVer
WScript.Echo "SUCCESS: New BAdI implementation " & UCase(BADI_IMPL_NAME) & _
             " created in enhancement implementation " & UCase(ENH_IMPL_NAME) & _
             " (class " & UCase(IMPL_CLASS) & ")."
WScript.Quit 0
