' =============================================================================
' sap_se19_classic_display.vbs  -  Display a CLASSIC BAdI implementation.
' Read-only. SE19 -> edit section -> Classic BAdI -> Display.
' Tokens: %%IMP_NAME%%  %%SESSION_PATH%%
' Probed S/4HANA 1909 (S4D) 2026-05-30.
' =============================================================================
Option Explicit
Const IMP_NAME     = "%%IMP_NAME%%"
Const SESSION_PATH = "%%SESSION_PATH%%"
Const VKEY_ENTER = 0
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

oSession.findById("wnd[0]").Maximize
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE19"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1200

oSession.findById("wnd[0]/usr/radG_IS_CLASSIC_1").Select
oSession.findById("wnd[0]/usr/ctxtRSEXSCRN-IMP_NAME").Text = UCase(IMP_NAME)
oSession.findById("wnd[0]/usr/btnPUSHBUTTON_DISPLAY_TEXT").Press
WScript.Sleep 2000

If CtrlExists("wnd[0]/usr/txtRSEXSCRN-ACTIVE") Then
    WScript.Echo "INFO: State=" & oSession.findById("wnd[0]/usr/txtRSEXSCRN-ACTIVE").Text
    WScript.Echo "SUCCESS: Classic BAdI implementation " & UCase(IMP_NAME) & " displayed."
    WScript.Quit 0
Else
    WScript.Echo "ERROR: Could not open classic implementation " & UCase(IMP_NAME) & _
                 ". Status: " & oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If
