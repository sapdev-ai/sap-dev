' =============================================================================
' sap_se19_new_delete.vbs  -  Delete a NEW BAdI enhancement implementation.
'
' SAFETY: the sap-se19 skill MUST confirm the target was created by us
' (session ledger / TADIR author) BEFORE invoking this script. This script
' performs the deletion only.
'
' Deletes the enhancement implementation + its BAdI implementation element.
' The implementing CLASS is NOT removed by SE19 here (survives) -- the skill
' offers class cleanup via /sap-se24 afterwards.
'
' Flow: SE19 -> New BAdI edit -> Delete implementation (tbar[1]/btn[14])
'       -> confirm popup (SAPLSPO4) -> optional TR popup.
' Tokens: %%ENH_IMPL_NAME%%  %%TRKORR%%  %%SESSION_PATH%%
' Probed S/4HANA 1909 (S4D) 2026-05-30.
' =============================================================================
Option Explicit
Const ENH_IMPL_NAME = "%%ENH_IMPL_NAME%%"
Const TRKORR        = "%%TRKORR%%"
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
Function TopWin()
    Dim i : TopWin = ""
    For i = 8 To 1 Step -1
        If CtrlExists("wnd[" & i & "]") Then TopWin = "wnd[" & i & "]" : Exit Function
    Next
End Function

oSession.findById("wnd[0]").Maximize
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE19"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1200

oSession.findById("wnd[0]/usr/radG_IS_NEW_1").Select
oSession.findById("wnd[0]/usr/ctxtG_ENHNAME").Text = UCase(ENH_IMPL_NAME)
oSession.findById("wnd[0]/tbar[1]/btn[14]").Press   ' Delete implementation (Shift+F2)
WScript.Sleep 2000

' Confirmation popup (SAPLSPO4): Continue = tbar[0]/btn[0]
If CtrlExists("wnd[1]/tbar[0]/btn[0]") Then
    oSession.findById("wnd[1]/tbar[0]/btn[0]").Press
    WScript.Sleep 2000
End If

' Optional transport request popup for the transported deletion
Dim pass, w
For pass = 1 To 4
    w = TopWin()
    If w = "wnd[0]" Or w = "" Then Exit For
    If CtrlExists(w & "/usr/ctxtKO008-TRKORR") Then
        If TRKORR <> "" Then oSession.findById(w & "/usr/ctxtKO008-TRKORR").Text = TRKORR
        oSession.findById(w & "/tbar[0]/btn[0]").Press
        WScript.Sleep 1500
    ElseIf CtrlExists(w & "/usr/btnBUTTON_1") Then
        oSession.findById(w & "/usr/btnBUTTON_1").Press   ' any residual Yes
        WScript.Sleep 1500
    Else
        Exit For
    End If
Next

Dim sType, sMsg
sType = oSession.findById("wnd[0]/sbar").MessageType
sMsg  = oSession.findById("wnd[0]/sbar").Text
If sType = "E" Or sType = "A" Then
    WScript.Echo "ERROR: Delete failed: " & sMsg
    WScript.Quit 1
End If
WScript.Echo "INFO: Status=" & sMsg
WScript.Echo "SUCCESS: New BAdI enhancement implementation " & UCase(ENH_IMPL_NAME) & " deleted."
WScript.Quit 0
