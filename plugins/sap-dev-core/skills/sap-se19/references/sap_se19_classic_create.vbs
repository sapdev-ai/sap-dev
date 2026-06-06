' =============================================================================
' sap_se19_classic_create.vbs  -  Create a CLASSIC BAdI implementation via SE19.
'
' The implementing class is AUTO-NAMED by SAP (ZCL_IM_<impl-name minus leading
' Z/Y>) and created on save -- classic BAdIs do not take a class-name argument.
' The class method source is deployed afterwards via /sap-se24 (skill delegates).
'
' Flow: SE19 -> create section -> Classic BAdI -> enter definition -> Create
'       -> Create Implementation popup (impl name) -> detail screen 150
'       -> short text -> Save -> object directory + TR -> Activate.
' Programs: SAPLSEXO(120/116/150) -> SAPLSTRD(100/300).
'
' Tokens: %%BADI_NAME%%  %%IMP_NAME%%  %%IMP_TEXT%%  %%DEVCLASS%%  %%TRKORR%%
'         %%SESSION_PATH%%   (DEVCLASS empty => Local Object)
' Probed S/4HANA 1909 (S4D) 2026-05-30.
' =============================================================================
Option Explicit
Const BADI_NAME    = "%%BADI_NAME%%"
Const IMP_NAME     = "%%IMP_NAME%%"
Const IMP_TEXT     = "%%IMP_TEXT%%"
Const DEVCLASS     = "%%DEVCLASS%%"
Const TRKORR       = "%%TRKORR%%"
Const SESSION_PATH = "%%SESSION_PATH%%"
Const VKEY_ENTER = 0
Const VKEY_SAVE  = 11
ExecuteGlobal CreateObject("Scripting.FileSystemObject").OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

Function CtrlExists(sId)
    Dim o : CtrlExists = False
    On Error Resume Next
    Set o = oSession.findById(sId, False)
    If Err.Number = 0 And Not (o Is Nothing) Then CtrlExists = True
    On Error GoTo 0
End Function
Function TopWin()
    Dim i : TopWin = ""
    For i = 8 To 1 Step -1
        If CtrlExists("wnd[" & i & "]") Then TopWin = "wnd[" & i & "]" : Exit Function
    Next
End Function
Sub HandleTransport()
    Dim pass, w
    For pass = 1 To 6
        w = TopWin()
        If w = "wnd[0]" Or w = "" Then Exit Sub
        If CtrlExists(w & "/usr/ctxtKO007-L_DEVCLASS") Or CtrlExists(w & "/usr/txtKO007-L_DEVCLASS") Then
            If DEVCLASS <> "" Then
                On Error Resume Next
                oSession.findById(w & "/usr/ctxtKO007-L_DEVCLASS").Text = DEVCLASS
                oSession.findById(w & "/usr/txtKO007-L_DEVCLASS").Text  = DEVCLASS
                On Error GoTo 0
                oSession.findById(w & "/tbar[0]/btn[0]").Press
            Else
                oSession.findById(w & "/tbar[0]/btn[7]").Press   ' Local Object
            End If
            WScript.Sleep 1500
        ElseIf CtrlExists(w & "/usr/ctxtKO008-TRKORR") Then
            If TRKORR <> "" Then oSession.findById(w & "/usr/ctxtKO008-TRKORR").Text = TRKORR
            oSession.findById(w & "/tbar[0]/btn[0]").Press
            WScript.Sleep 1500
        Else
            Exit Sub
        End If
    Next
End Sub

oSession.findById("wnd[0]").Maximize
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE19"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1200

oSession.findById("wnd[0]/usr/radG_IS_CLASSIC_2").Select
oSession.findById("wnd[0]/usr/ctxtRSEXSCRN-EXIT_NAME").Text = UCase(BADI_NAME)
oSession.findById("wnd[0]/usr/btnPUSHBUTTON_IMPLEMENT_TEXT").Press
WScript.Sleep 2000

' Create Implementation popup -> implementation name
If Not CtrlExists("wnd[1]/usr/ctxtRSEXSCRN-IMP_NAME") Then
    WScript.Echo "ERROR: Create Implementation popup did not appear. Status: " & _
                 oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If
oSession.findById("wnd[1]/usr/ctxtRSEXSCRN-IMP_NAME").Text = UCase(IMP_NAME)
oSession.findById("wnd[1]/tbar[0]/btn[0]").Press
WScript.Sleep 2000

' Detail screen 150 -> short text
If Not CtrlExists("wnd[0]/usr/txtRSEXSCRN-IMP_TEXT") Then
    WScript.Echo "ERROR: Did not reach the classic implementation detail screen. Status: " & _
                 oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If
oSession.findById("wnd[0]/usr/txtRSEXSCRN-IMP_TEXT").Text = IMP_TEXT
WScript.Sleep 400

' Save (Ctrl+S). Handle an optional Yes/No "save changes?" dialog (SAPLSPO1).
oSession.findById("wnd[0]").sendVKey VKEY_SAVE
WScript.Sleep 1500
If CtrlExists("wnd[1]/usr/btnBUTTON_1") Then
    oSession.findById("wnd[1]/usr/btnBUTTON_1").Press   ' Yes
    WScript.Sleep 1500
End If

' Object directory + transport request (auto-creates the implementing class)
HandleTransport
WScript.Sleep 1000

' Return to the implementation if SAP navigated into the interface view
If Not CtrlExists("wnd[0]/usr/txtRSEXSCRN-ACTIVE") Then
    oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE19"
    oSession.findById("wnd[0]").sendVKey VKEY_ENTER
    WScript.Sleep 1000
    oSession.findById("wnd[0]/usr/radG_IS_CLASSIC_1").Select
    oSession.findById("wnd[0]/usr/ctxtRSEXSCRN-IMP_NAME").Text = UCase(IMP_NAME)
    oSession.findById("wnd[0]/usr/btnPUSHBUTTON_CHANGE_TEXT").Press
    WScript.Sleep 2000
End If

' Activate (Ctrl+F3 / btn[27])
If CtrlExists("wnd[0]/tbar[1]/btn[27]") Then
    oSession.findById("wnd[0]/tbar[1]/btn[27]").Press
    WScript.Sleep 2500
    If CtrlExists("wnd[1]/tbar[0]/btn[0]") Then
        oSession.findById("wnd[1]/tbar[0]/btn[0]").Press   ' optional worklist
        WScript.Sleep 3000
    End If
End If

Dim sType, sMsg, sAct
sType = oSession.findById("wnd[0]/sbar").MessageType
sMsg  = oSession.findById("wnd[0]/sbar").Text
sAct  = ""
If CtrlExists("wnd[0]/usr/txtRSEXSCRN-ACTIVE") Then sAct = oSession.findById("wnd[0]/usr/txtRSEXSCRN-ACTIVE").Text
If sType = "E" Or sType = "A" Then
    WScript.Echo "ERROR: " & sMsg
    WScript.Quit 1
End If
WScript.Echo "INFO: Status=" & sMsg & "  State=" & sAct
WScript.Echo "SUCCESS: Classic BAdI implementation " & UCase(IMP_NAME) & _
             " created for definition " & UCase(BADI_NAME) & "."
WScript.Quit 0
