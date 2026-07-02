' =============================================================================
' sap_se19_classic_setactive.vbs  -  Activate or Deactivate a CLASSIC BAdI
'                                    implementation via SE19.
'
'   %%SET_ACTIVE%% = "X"  -> Activate   (toolbar btn[27], Ctrl+F3)
'   %%SET_ACTIVE%% = ""   -> Deactivate (toolbar btn[28], Ctrl+F4)
'
' Reversible -- the implementation object is NOT deleted.
' Flow: SE19 -> Classic BAdI edit -> Change -> Activate/Deactivate toolbar btn.
' Tokens: %%IMP_NAME%%  %%SET_ACTIVE%%  %%SESSION_PATH%%
' Probed S/4HANA 1909 (S4D) 2026-05-30.
' =============================================================================
Option Explicit
Const IMP_NAME     = "%%IMP_NAME%%"
Const SET_ACTIVE   = "%%SET_ACTIVE%%"
Const TRKORR       = "%%TRKORR%%"        ' TR for the activate popup (empty = none expected)
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
oSession.findById("wnd[0]/usr/btnPUSHBUTTON_CHANGE_TEXT").Press
WScript.Sleep 2000

If Not CtrlExists("wnd[0]/usr/txtRSEXSCRN-ACTIVE") Then
    WScript.Echo "ERROR: Could not open classic implementation " & UCase(IMP_NAME) & _
                 " in change mode. Status: " & oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If

Dim sBtn, sAct
If UCase(SET_ACTIVE) = "X" Then
    sBtn = "wnd[0]/tbar[1]/btn[27]" : sAct = "activated"   ' Activate (Ctrl+F3)
Else
    sBtn = "wnd[0]/tbar[1]/btn[28]" : sAct = "deactivated" ' Deactivate (Ctrl+F4)
End If
If Not CtrlExists(sBtn) Then
    WScript.Echo "ERROR: " & sAct & " toolbar button not available (already in that state?)."
    WScript.Quit 1
End If
oSession.findById(sBtn).Press
WScript.Sleep 2500

' Transport-request popup on activate of a transported implementation (SKILL Step 4
' promises "the VBS handles it"). Dispatch by control id (locale-independent): an
' empty TR must ABORT loud, never blind-accept (which would fall through to Local
' Object / an error) as the generic worklist-Continue below would.
If CtrlExists("wnd[1]/usr/ctxtKO008-TRKORR") Then
    If TRKORR = "" Then
        WScript.Echo "ERROR: ABORT_EMPTY_TR -- SAP prompted for a transport request but TRKORR is empty."
        WScript.Echo "       Resolve a TR via /sap-transport-request and re-run this operation."
        WScript.Quit 1
    End If
    oSession.findById("wnd[1]/usr/ctxtKO008-TRKORR").Text = TRKORR
    oSession.findById("wnd[1]/tbar[0]/btn[0]").Press
    WScript.Sleep 1500
End If

' optional inactive-objects worklist on activate
If CtrlExists("wnd[1]/tbar[0]/btn[0]") Then
    oSession.findById("wnd[1]/tbar[0]/btn[0]").Press
    WScript.Sleep 3000
End If

Dim sType, sMsg
sType = oSession.findById("wnd[0]/sbar").MessageType
sMsg  = oSession.findById("wnd[0]/sbar").Text
If sType = "E" Or sType = "A" Then
    WScript.Echo "ERROR: " & sMsg
    WScript.Quit 1
End If
WScript.Echo "INFO: Status=" & sMsg
WScript.Echo "SUCCESS: Classic BAdI implementation " & UCase(IMP_NAME) & " " & sAct & "."
WScript.Quit 0
