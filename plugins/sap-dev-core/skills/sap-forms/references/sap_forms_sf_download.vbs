' ============================================================================
' sap_forms_sf_download.vbs  -  SmartForm XML download for /sap-forms
'
' There is NO FM route (SSF_DOWNLOAD_FORM = NO on both releases), so the ONLY way
' to export a SmartForm's XML is the SMARTFORMS Utilities->Download GUI menu. This
' driver opens SMARTFORMS on the form, then reaches the download menu by POSITION
' (never text) and saves to %%SAVE_PATH%%. The menu path is release-specific and
' is captured with /sap-gui-probe --record; until a baseline for THIS release is
' present, the menu step emits FORMS: NEEDS_RECORDING rather than guessing.
'
' Tokens: %%SESSION_PATH%% %%ATTACH_LIB_VBS%% %%FORMNAME%% %%SAVE_PATH%% %%MENU_PATH%%
'   (%%MENU_PATH%% = the recorded findById of the Utilities->Download menu entry,
'    substituted by the SKILL from the golden-screen baseline; empty => NEEDS_RECORDING)
' 32-bit cscript. GUI file IO: the SKILL pre-arms the security sidecar.
' ============================================================================
Option Explicit
Const SESSION_PATH = "%%SESSION_PATH%%"
Const FORMNAME     = "%%FORMNAME%%"
Const SAVE_PATH    = "%%SAVE_PATH%%"
Const MENU_PATH    = "%%MENU_PATH%%"

Dim oFso : Set oFso = CreateObject("Scripting.FileSystemObject")
ExecuteGlobal oFso.OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
Dim oSession : Set oSession = AttachSapSession(SESSION_PATH)
If oSession Is Nothing Then WScript.Echo "FORMS: result=ERROR detail=no_session" : WScript.Quit 2

On Error Resume Next
' open SMARTFORMS on the form
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSMARTFORMS"
oSession.findById("wnd[0]").sendVKey 0
If Err.Number <> 0 Then WScript.Echo "FORMS: result=ERROR detail=cannot_open_smartforms " & Err.Description : On Error Goto 0 : WScript.Quit 2
' select "Form" radio + fill name (SSFSCREEN-FNAME per probe; guard if absent)
Dim oName : Set oName = Nothing : Set oName = oSession.findById("wnd[0]/usr/ctxtSSFSCREEN-FNAME")
If oName Is Nothing Then
    WScript.Echo "FORMS: NEEDS_RECORDING step=formname_field detail=SSFSCREEN-FNAME not found - record SMARTFORMS initial screen via /sap-gui-probe --record"
    On Error Goto 0 : WScript.Quit 3
End If
oName.Text = FORMNAME
On Error Goto 0

' the Utilities->Download menu path is release-specific: use the recorded findById.
If MENU_PATH = "" Or InStr(MENU_PATH, Chr(37) & Chr(37)) > 0 Then
    WScript.Echo "FORMS: NEEDS_RECORDING step=download_menu detail=no golden-screen baseline for this release; record SMARTFORMS Utilities->Download via /sap-gui-probe --record, then set %%MENU_PATH%%"
    WScript.Quit 3
End If

On Error Resume Next
oSession.findById(MENU_PATH).Select
If Err.Number <> 0 Then WScript.Echo "FORMS: NEEDS_RECORDING step=download_menu detail=recorded menu id stale: " & Err.Description : On Error Goto 0 : WScript.Quit 3
' file-save dialog: type the path + save (ids from the recording)
Dim oDlg : Set oDlg = Nothing : Set oDlg = oSession.findById("wnd[1]")
If Not oDlg Is Nothing Then
    ' the actual dialog control ids come from the recording; guarded
    oSession.findById("wnd[1]/usr/ctxtDY_PATH").Text = oFso.GetParentFolderName(SAVE_PATH)
    oSession.findById("wnd[1]/usr/ctxtDY_FILENAME").Text = oFso.GetFileName(SAVE_PATH)
    oSession.findById("wnd[1]/tbar[0]/btn[0]").press
End If
On Error Goto 0

If oFso.FileExists(SAVE_PATH) Then
    WScript.Echo "FORMS: result=DOWNLOADED file=" & SAVE_PATH
    WScript.Quit 0
Else
    WScript.Echo "FORMS: result=ERROR detail=file_not_written " & SAVE_PATH
    WScript.Quit 2
End If
