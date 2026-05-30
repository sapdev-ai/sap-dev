' =============================================================================
' sap_se19_new_display.vbs  -  Display a NEW BAdI enhancement implementation.
' Read-only. Opens SE19 -> edit section -> New BAdI -> Display.
' Tokens: %%ENH_IMPL_NAME%%  %%SESSION_PATH%%
' Probed S/4HANA 1909 (S4D) 2026-05-30.
' =============================================================================
Option Explicit
Const ENH_IMPL_NAME = "%%ENH_IMPL_NAME%%"
Const SESSION_PATH  = "%%SESSION_PATH%%"
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

oSession.findById("wnd[0]/usr/radG_IS_NEW_1").Select
oSession.findById("wnd[0]/usr/ctxtG_ENHNAME").Text = UCase(ENH_IMPL_NAME)
oSession.findById("wnd[0]/usr/btnPUSHBUTTON_DISPLAY_TEXT").Press
WScript.Sleep 2000

If CtrlExists("wnd[0]/usr/txtENH_EDT_LAYOUT-OBJECT1") Then
    Dim sVer : sVer = ""
    If CtrlExists("wnd[0]/usr/txtENH_EDT_LAYOUT-VERSION_TX") Then sVer = oSession.findById("wnd[0]/usr/txtENH_EDT_LAYOUT-VERSION_TX").Text
    WScript.Echo "INFO: Displaying enhancement implementation " & UCase(ENH_IMPL_NAME) & "  Version=" & sVer
    WScript.Echo "SUCCESS: New BAdI enhancement implementation " & UCase(ENH_IMPL_NAME) & " displayed."
    WScript.Quit 0
Else
    WScript.Echo "ERROR: Could not open enhancement implementation " & UCase(ENH_IMPL_NAME) & _
                 ". Status: " & oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If
