' =============================================================================
' sap_file_transfer_download.vbs
' -----------------------------------------------------------------------------
' Downloads a file from the SAP application server to the front end via CG3Y.
' Scaffolded 2026-07-09 by /sap-gui-skill-scaffold from a live CG3Y probe on
' S/4HANA 1909 (S4D), then hand-hardened. Mirror of the CG3Z upload driver;
' see sap_file_transfer_upload.vbs for the shared conventions.
'
' Probed behavior this script encodes (differences from upload):
'   * Dialog is SAPLC13Z dynpro 1010 on wnd[1]; execute button is
'     btn[13] (Download / Shift+F1), NOT btn[14].
'   * The overwrite Query concerns the LOCAL target file, and CG3Y raises it
'     BEFORE it even tries to read the app-server source - a missing source
'     surfaces only after the Query is answered Yes (or the local target is new).
'   * Missing/unreadable app-server source -> Information popup (SAPMSDYP/10)
'     with txtMESSTXT1 = "Cannot open file <path>", txtMESSTXT2 = the OS errno
'     text, e.g. "(No such file or directory)". The local target file is NOT
'     touched in that case (probed: size unchanged).
'
' Parameters (replaced by the PowerShell wrapper before cscript runs):
'   %%REMOTE_FILE%%    wnd[1]/usr/txtRCGFILETR-FTAPPL    source file on app server
'   %%LOCAL_FILE%%     wnd[1]/usr/ctxtRCGFILETR-FTFRONT  target file on front end
'   %%TRANSFER_MODE%%  wnd[1]/usr/ctxtRCGFILETR-FTFTYPE  ASC or BIN
'   %%OVERWRITE%%      wnd[1]/usr/chkRCGFILETR-IEFOW     X = overwrite local, empty = refuse
'
' Exit codes: 0 = transferred, 3 = SAP error / no success message,
'             4 = local target exists and overwrite not requested, 5 = source unreadable.
' Marker lines on stdout: FILE_TRANSFER: DOWNLOADED|TARGET_EXISTS|OPEN_ERROR ...
'
' Run via: 32-bit cscript //NoLogo (SAP GUI Scripting COM requires 32-bit).
' =============================================================================
Option Explicit

Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Dim gFSO : Set gFSO = CreateObject("Scripting.FileSystemObject")
ExecuteGlobal gFSO.OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal gFSO.OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

Dim oSess, gLocked
Set oSess = AttachSapSession(SESSION_PATH)
gLocked = TryLockSession(oSess)

' --- helpers -----------------------------------------------------------------
Function HasCtl(sess, sId)
    Dim o
    On Error Resume Next
    Set o = sess.findById(sId, False)
    On Error GoTo 0
    HasCtl = Not (o Is Nothing)
End Function

Function CtlText(sess, sId)
    Dim o
    CtlText = ""
    On Error Resume Next
    Set o = sess.findById(sId, False)
    If Not (o Is Nothing) Then CtlText = o.Text
    On Error GoTo 0
End Function

Function StatusBarType(sess)
    Dim s
    On Error Resume Next
    Set s = sess.findById("wnd[0]/sbar", False)
    On Error GoTo 0
    If s Is Nothing Then
        StatusBarType = ""
    Else
        StatusBarType = s.MessageType
    End If
End Function

Sub AbortRun(sMsg, nCode)
    WScript.Echo sMsg
    ReleaseSession oSess, gLocked   ' also sweeps orphan modals via F12
    WScript.Quit nCode
End Sub

' --- open CG3Y and wait for the parameter dialog (SAPLC13Z 1010, wnd[1]) -----
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nCG3Y"
oSess.findById("wnd[0]").sendVKey 0

Dim i, bDialog
bDialog = False
For i = 1 To 20
    If HasCtl(oSess, "wnd[1]/usr/txtRCGFILETR-FTAPPL") Then
        bDialog = True
        Exit For
    End If
    WScript.Sleep 250
Next
If Not bDialog Then
    AbortRun "ERROR: CG3Y parameter dialog did not appear (sbar type=" & _
        StatusBarType(oSess) & " text=" & CtlText(oSess, "wnd[0]/sbar") & _
        ") - transaction locked or authorization missing?", 3
End If

' --- fill the dialog ----------------------------------------------------------
oSess.findById("wnd[1]/usr/txtRCGFILETR-FTAPPL").Text   = "%%REMOTE_FILE%%"
oSess.findById("wnd[1]/usr/ctxtRCGFILETR-FTFRONT").Text = "%%LOCAL_FILE%%"
oSess.findById("wnd[1]/usr/ctxtRCGFILETR-FTFTYPE").Text = "%%TRANSFER_MODE%%"

' Overwrite checkbox (concerns the LOCAL target). Unsubstituted token or any
' value other than X leaves the box unticked = safe refuse-overwrite default.
Dim sOverwrite : sOverwrite = "%%OVERWRITE%%"
oSess.findById("wnd[1]/usr/chkRCGFILETR-IEFOW").Selected = (sOverwrite = "X")

' --- execute the transfer (Download = btn[13] / Shift+F1) ----------------------
oSess.findById("wnd[1]/tbar[0]/btn[13]").press
WScript.Sleep 800

' --- result popups on wnd[2], discriminated by control ID (locale-independent)
' Probed ordering: local-overwrite Query fires FIRST (before the source is
' read); Yes on the Query with a missing source then raises the Information
' popup - hence the loop handles both in sequence.
For i = 1 To 3
    If HasCtl(oSess, "wnd[2]/usr/btnSPOP-OPTION1") Then
        If sOverwrite = "X" Then
            ' Belt-and-braces: checkbox should have pre-empted this popup.
            oSess.findById("wnd[2]/usr/btnSPOP-OPTION1").press
            WScript.Sleep 800
        Else
            oSess.findById("wnd[2]/usr/btnSPOP-OPTION2").press
            WScript.Sleep 400
            WScript.Echo "FILE_TRANSFER: TARGET_EXISTS local=%%LOCAL_FILE%%"
            If HasCtl(oSess, "wnd[1]/tbar[0]/btn[12]") Then oSess.findById("wnd[1]/tbar[0]/btn[12]").press
            AbortRun "ERROR: local target file exists and overwrite was not requested", 4
        End If
    ElseIf HasCtl(oSess, "wnd[2]/usr/txtMESSTXT1") Then
        Dim sErrTxt
        sErrTxt = Trim(CtlText(oSess, "wnd[2]/usr/txtMESSTXT1") & " " & _
                       CtlText(oSess, "wnd[2]/usr/txtMESSTXT2"))
        oSess.findById("wnd[2]/tbar[0]/btn[0]").press
        WScript.Sleep 400
        WScript.Echo "FILE_TRANSFER: OPEN_ERROR msg=" & sErrTxt
        If HasCtl(oSess, "wnd[1]/tbar[0]/btn[12]") Then oSess.findById("wnd[1]/tbar[0]/btn[12]").press
        AbortRun "ERROR: SAP could not open a file: " & sErrTxt, 5
    ElseIf HasCtl(oSess, "wnd[2]") Then
        AbortRun "ERROR: unexpected popup wnd[2] after transfer - aborting for manual review", 3
    Else
        Exit For
    End If
Next

' --- success contract: sbar MessageType MUST be "S" ----------------------------
Dim sType : sType = StatusBarType(oSess)
If sType = "S" Then
    WScript.Echo "FILE_TRANSFER: DOWNLOADED remote=%%REMOTE_FILE%% local=%%LOCAL_FILE%% mode=%%TRANSFER_MODE%%"
ElseIf sType = "E" Or sType = "A" Then
    AbortRun "ERROR: transfer failed, status-bar MessageType=" & sType & _
        " text=" & CtlText(oSess, "wnd[0]/sbar"), 3
Else
    AbortRun "ERROR: no success message after transfer (MessageType='" & sType & "')", 3
End If

' --- close the parameter dialog (it stays open after a successful transfer) ---
If HasCtl(oSess, "wnd[1]/tbar[0]/btn[12]") Then
    oSess.findById("wnd[1]/tbar[0]/btn[12]").press
    WScript.Sleep 400
End If

ReleaseSession oSess, gLocked
WScript.Echo "DONE"
WScript.Quit 0
