' =============================================================================
' sap_se19_classic_delete.vbs  -  Delete a CLASSIC BAdI implementation via SE19.
'
' SAFETY: the sap-se19 skill MUST confirm the target was created by us
' (session ledger) BEFORE invoking this script.
'
' Removes the classic BAdI implementation (SXC_* + SXCI). Up to two SAPLSPO1
' Yes/No confirmation popups are answered Yes to complete the deletion.
'
' NOTE (verified): SE19 does NOT reliably remove the implementing class -- it
' survives in SEOCLASS even after the second confirmation. The sap-se19 skill
' therefore cleans the class afterwards via /sap-se24 (Rule #4), the same as
' for New BAdIs. Do not assume this script deletes the class.
'
' Tokens: %%IMP_NAME%%  %%TRKORR%%  %%SESSION_PATH%%
' Probed S/4HANA 1909 (S4D) 2026-05-30.
' =============================================================================
Option Explicit
Const IMP_NAME     = "%%IMP_NAME%%"
Const TRKORR       = "%%TRKORR%%"
Const SESSION_PATH = "%%SESSION_PATH%%"
Const VKEY_ENTER = 0
' Optional fill for the ECC6 "Create Object Directory Entry" (SAPLSTRD) popup.
Dim OBJDIR_PKG  : OBJDIR_PKG  = "%%PACKAGE%%"
Dim OBJDIR_LANG : OBJDIR_LANG = "%%ORIG_LANG%%"
If Left(OBJDIR_PKG, 2)  = Chr(37) & Chr(37) Then OBJDIR_PKG  = ""
If Left(OBJDIR_LANG, 2) = Chr(37) & Chr(37) Then OBJDIR_LANG = ""
If OBJDIR_LANG = "" Then OBJDIR_LANG = "E"
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

oSession.findById("wnd[0]/usr/radG_IS_CLASSIC_1").Select
oSession.findById("wnd[0]/usr/ctxtRSEXSCRN-IMP_NAME").Text = UCase(IMP_NAME)
oSession.findById("wnd[0]/tbar[1]/btn[14]").Press   ' Delete implementation (Shift+F2)
WScript.Sleep 2000

' Popup 1 -- confirm delete implementation -> Yes
If CtrlExists("wnd[1]/usr/btnBUTTON_1") Then
    oSession.findById("wnd[1]/usr/btnBUTTON_1").Press
    WScript.Sleep 2000
End If

' Popup 2 -- second confirmation (also Yes) to complete the deletion
If CtrlExists("wnd[1]/usr/btnBUTTON_1") Then
    oSession.findById("wnd[1]/usr/btnBUTTON_1").Press
    WScript.Sleep 2000
End If

' Optional transport request popup
Dim pass, w
For pass = 1 To 4
    w = TopWin()
    If w = "wnd[0]" Or w = "" Then Exit For
    If CtrlExists(w & "/usr/ctxtKO008-TRKORR") Then
        If TRKORR <> "" Then oSession.findById(w & "/usr/ctxtKO008-TRKORR").Text = TRKORR
        oSession.findById(w & "/tbar[0]/btn[0]").Press
        WScript.Sleep 1500
    ElseIf CtrlExists(w & "/usr/btnBUTTON_1") Then
        oSession.findById(w & "/usr/btnBUTTON_1").Press
        WScript.Sleep 1500
    ElseIf CtrlExists(w & "/usr/ctxtRSETX-MASTERLANG") Then
        ' SAPLSETX original-vs-logon language popup (ECC6 / master<>logon).
        oSession.findById(w & "/usr/btnPUSH1").Press
        WScript.Sleep 1500
    ElseIf CtrlExists(w & "/usr/ctxtKO007-L_DEVCLASS") Then
        ' "Create Object Directory Entry" (SAPLSTRD) popup -- ECC6.
        If oSession.findById(w & "/usr/ctxtKO007-L_DEVCLASS").Text = "" And OBJDIR_PKG <> "" Then
            oSession.findById(w & "/usr/ctxtKO007-L_DEVCLASS").Text = OBJDIR_PKG
            If CtrlExists(w & "/usr/ctxtKO007-L_MSTLANG") Then
                If oSession.findById(w & "/usr/ctxtKO007-L_MSTLANG").Text = "" Then oSession.findById(w & "/usr/ctxtKO007-L_MSTLANG").Text = OBJDIR_LANG
            End If
            oSession.findById(w & "/tbar[0]/btn[0]").Press
        ElseIf oSession.findById(w & "/usr/ctxtKO007-L_DEVCLASS").Text = "" Then
            oSession.findById(w & "/tbar[0]/btn[7]").Press   ' Local Object
        Else
            oSession.findById(w & "/tbar[0]/btn[0]").Press
        End If
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
WScript.Echo "SUCCESS: Classic BAdI implementation " & UCase(IMP_NAME) & " deleted."
WScript.Quit 0
