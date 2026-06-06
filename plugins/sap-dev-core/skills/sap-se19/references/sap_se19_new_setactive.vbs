' =============================================================================
' sap_se19_new_setactive.vbs  -  Activate or Deactivate (runtime) a NEW BAdI
'                                implementation via SE19.
'
' Toggles the "Implementation is active" runtime flag on the BAdI
' implementation element, then re-activates the enhancement implementation
' object so the change takes effect. Reversible -- the object is NOT deleted.
'
'   %%SET_ACTIVE%% = "X"  -> Activate   (runtime flag ON)
'   %%SET_ACTIVE%% = ""   -> Deactivate (runtime flag OFF)
'
' Flow: SE19 -> New BAdI edit -> Change -> Enh. Implementation Elements tab
'       -> set chkENH_BADI_IMPL_ADMIN_DATA-ACTIVE -> Save -> Activate (Ctrl+F3)
'       -> inactive-objects worklist Continue.
' Tokens: %%ENH_IMPL_NAME%%  %%SET_ACTIVE%%  %%TRKORR%%  %%SESSION_PATH%%
' Probed S/4HANA 1909 (S4D) 2026-05-30.
' =============================================================================
Option Explicit
Const ENH_IMPL_NAME = "%%ENH_IMPL_NAME%%"
Const SET_ACTIVE    = "%%SET_ACTIVE%%"   ' "X" = activate, "" = deactivate
Const TRKORR        = "%%TRKORR%%"
Const SESSION_PATH  = "%%SESSION_PATH%%"
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

Dim sChk
sChk = "wnd[0]/usr/tabsTS_ENHANCEMENTS/tabpTABS_5/ssubSUBS_5:SAPLENH_EDT_BADI:2100/" & _
       "splcSPLITTER:SAPLENH_EDT_BADI:2100/ssubENH_BADI_IMPL:SAPLENH_EDT_BADI:0102/" & _
       "chkENH_BADI_IMPL_ADMIN_DATA-ACTIVE"

oSession.findById("wnd[0]").Maximize
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE19"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1200

oSession.findById("wnd[0]/usr/radG_IS_NEW_1").Select
oSession.findById("wnd[0]/usr/ctxtG_ENHNAME").Text = UCase(ENH_IMPL_NAME)
oSession.findById("wnd[0]/usr/btnPUSHBUTTON_CHANGE_TEXT").Press
WScript.Sleep 2000

If Not CtrlExists("wnd[0]/usr/tabsTS_ENHANCEMENTS/tabpTABS_5") Then
    WScript.Echo "ERROR: Could not open " & UCase(ENH_IMPL_NAME) & " in change mode. Status: " & _
                 oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If
oSession.findById("wnd[0]/usr/tabsTS_ENHANCEMENTS/tabpTABS_5").Select
WScript.Sleep 1200

If Not CtrlExists(sChk) Then
    WScript.Echo "ERROR: 'Implementation is active' checkbox not found (no BAdI implementation selected)."
    WScript.Quit 1
End If
oSession.findById(sChk).Selected = (UCase(SET_ACTIVE) = "X")
WScript.Sleep 400

' Save
oSession.findById("wnd[0]").sendVKey VKEY_SAVE
WScript.Sleep 2000
' optional TR popup
If CtrlExists("wnd[1]/usr/ctxtKO008-TRKORR") Then
    If TRKORR <> "" Then oSession.findById("wnd[1]/usr/ctxtKO008-TRKORR").Text = TRKORR
    oSession.findById("wnd[1]/tbar[0]/btn[0]").Press
    WScript.Sleep 1500
End If

' Activate so the runtime change takes effect
oSession.findById("wnd[0]/tbar[1]/btn[27]").Press
WScript.Sleep 3000
If CtrlExists("wnd[1]/tbar[0]/btn[0]") Then
    oSession.findById("wnd[1]/tbar[0]/btn[0]").Press   ' inactive-objects worklist Continue
    WScript.Sleep 4000
End If

Dim sType, sMsg, sAct
sType = oSession.findById("wnd[0]/sbar").MessageType
sMsg  = oSession.findById("wnd[0]/sbar").Text
If sType = "E" Or sType = "A" Then
    WScript.Echo "ERROR: " & sMsg
    WScript.Quit 1
End If
If UCase(SET_ACTIVE) = "X" Then sAct = "activated" Else sAct = "deactivated"
WScript.Echo "INFO: Status=" & sMsg
WScript.Echo "SUCCESS: New BAdI implementation in " & UCase(ENH_IMPL_NAME) & " runtime " & sAct & "."
WScript.Quit 0
