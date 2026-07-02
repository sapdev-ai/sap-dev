' =============================================================================
' sap_se24_test_classes.vbs  -  Upload a class's LOCAL TEST CLASSES (CCAU include)
'
' Part of the /sap-se24 skill. Attaches to an existing SAP GUI session, opens an
' already-deployed class in source-code-based change mode, navigates to the
' "Local Test Classes" include (toolbar btn[35]), uploads the test-class source
' into that include, saves, activates, and runs a syntax check.
'
' The class's MAIN source must already exist + be active (deploy it first via
' sap_se24_create.vbs + sap_se24_update.vbs). The test source contains ONLY the
' local test classes, e.g.:
'   CLASS ltcl_test DEFINITION FOR TESTING DURATION SHORT RISK LEVEL HARMLESS.
'     PRIVATE SECTION.
'       METHODS test_xxx FOR TESTING.
'   ENDCLASS.
'   CLASS ltcl_test IMPLEMENTATION.
'     METHOD test_xxx. ... ENDMETHOD.
'   ENDCLASS.
'
' Tokens replaced at run time:
'   %%CLASS_NAME%%         class whose CCAU include receives the test classes
'   %%TEST_SOURCE_FILE%%   absolute path to the test-class .abap (local classes only)
'   %%TRANSPORT%%          TR for the post-save popup (blank = local $TMP)
'
' Output (last line, parseable):
'   SUCCESS: Local test classes uploaded and activated for <CLASS>.
'   ERROR: ...
'
' Verified live on S/4HANA 1909 (S4D) 2026-06-03: btn[35] navigates to the
' test-class editor (Program=SAPLSEO_CLEDITOR); the Upload menu then loads the
' file into THAT current editor (the CCAU include).
'
' Note: the upload reads a local file via SAP GUI, so it can raise the modal
' "SAP GUI Security" dialog when {work_dir} isn't allow-listed. The SKILL.md
' wraps this run with sap_gui_security_sidecar.ps1 (same pattern as the Step A
' download).
' =============================================================================

Option Explicit

Const CLASS_NAME       = "%%CLASS_NAME%%"
Const TEST_SOURCE_FILE = "%%TEST_SOURCE_FILE%%"
Const SAP_TRANSPORT    = "%%TRANSPORT%%"
Const SESSION_PATH     = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER      = 0
Const VKEY_F11_SAVE   = 11
Const VKEY_F12_CANCEL = 12

ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SYNTAX_CHECK_LIB_VBS%%", 1).ReadAll()

Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

Dim oFSO
Set oFSO = CreateObject("Scripting.FileSystemObject")
If Not oFSO.FileExists(TEST_SOURCE_FILE) Then
    WScript.Echo "ERROR: Test source file not found: " & TEST_SOURCE_FILE
    WScript.Quit 1
End If

' ------ 1. Open the class in source-code-based change mode -------------------
WScript.Echo "INFO: Navigating to SE24..."
oSession.findById("wnd[0]").maximize
oSession.StartTransaction "SE24"
WScript.Sleep 1000

On Error Resume Next
Dim oClsField : Set oClsField = oSession.findById("wnd[0]/usr/ctxtSEOCLASS-CLSNAME")
If Err.Number <> 0 Or oClsField Is Nothing Then
    WScript.Echo "ERROR: SE24 class name field not found (wnd[0]/usr/ctxtSEOCLASS-CLSNAME)."
    WScript.Quit 1
End If
On Error GoTo 0
oClsField.Text = UCase(CLASS_NAME)
WScript.Sleep 300
WScript.Echo "INFO: Opening class in change mode: " & UCase(CLASS_NAME)
oSession.findById("wnd[0]/usr/btnPUSH_CHANGE").press
WScript.Sleep 2000

' Original-language popup (SAPLSETX) -> "Maint. in orig. lang." (btnPUSH1).
On Error Resume Next
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
    Dim oML : Set oML = oSession.findById("wnd[1]/usr/ctxtRSETX-MASTERLANG")
    If Err.Number = 0 And Not (oML Is Nothing) Then
        Err.Clear
        oSession.findById("wnd[1]/usr/btnPUSH1").press
        WScript.Sleep 1500
    End If
End If
Err.Clear
On Error GoTo 0
On Error Resume Next
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then oSession.ActiveWindow.sendVKey VKEY_ENTER : WScript.Sleep 1000
Err.Clear
On Error GoTo 0

' Require source-code-based view (Upload is unavailable in form-based view).
On Error Resume Next
Dim oStat : Set oStat = oSession.findById("wnd[0]/usr/txtDY0400_STATUS")
Dim bSrc : bSrc = (Err.Number = 0 And Not (oStat Is Nothing))
Err.Clear
On Error GoTo 0
If Not bSrc Then
    WScript.Echo "ERROR: Class is in form-based view; source-code-based view is required." & vbCrLf & _
                 "       Switch via Utilities > Settings > 'Source Code-Based', then retry."
    WScript.Quit 1
End If
WScript.Echo "INFO: Class opened in source-code-based change mode."

' ------ 2. Encoding: Unicode SAP -> UTF-8 direct; else convert to ANSI -------
Dim sUploadFile, bUni : bUni = False
On Error Resume Next
Dim cp : cp = oSession.Info.Codepage
If Err.Number = 0 And (CStr(cp) = "4110" Or CStr(cp) = "4103") Then bUni = True
Err.Clear
On Error GoTo 0
If bUni Then
    sUploadFile = TEST_SOURCE_FILE
    WScript.Echo "INFO: Unicode SAP system (codepage " & cp & "); uploading UTF-8 directly."
Else
    sUploadFile = TEST_SOURCE_FILE & ".upload.txt"
    Dim sCP : sCP = "1252"
    On Error Resume Next
    Dim oWMI, colOS, oOS
    Set oWMI = GetObject("winmgmts:\\.\root\cimv2")
    Set colOS = oWMI.ExecQuery("SELECT CodeSet FROM Win32_OperatingSystem")
    For Each oOS In colOS : sCP = oOS.CodeSet : Next
    Err.Clear
    On Error GoTo 0
    Dim sCharset
    Select Case CStr(sCP)
        Case "932"  : sCharset = "shift_jis"
        Case "936"  : sCharset = "gb2312"
        Case "949"  : sCharset = "ks_c_5601-1987"
        Case "950"  : sCharset = "big5"
        Case "1251" : sCharset = "windows-1251"
        Case Else   : sCharset = "windows-1252"
    End Select
    Dim oIn, oOut
    Set oIn = CreateObject("ADODB.Stream") : oIn.Type = 2 : oIn.Charset = "utf-8" : oIn.Open : oIn.LoadFromFile TEST_SOURCE_FILE
    Set oOut = CreateObject("ADODB.Stream") : oOut.Type = 2 : oOut.Charset = sCharset : oOut.Open
    oOut.WriteText oIn.ReadText : oIn.Close : oOut.SaveToFile sUploadFile, 2 : oOut.Close
    WScript.Echo "INFO: Converted test source from UTF-8 to " & sCharset & " for upload."
End If

Dim wasLocked : wasLocked = TryLockSession(oSession)
If wasLocked Then WScript.Echo "INFO: Session UI locked for the test-class upload + save + activate critical section."

' ------ 3. Navigate to the Local Test Classes include (toolbar btn[35]) ------
On Error Resume Next
oSession.findById("wnd[0]/tbar[1]/btn[35]").press
If Err.Number <> 0 Then
    Err.Clear
    ' Fallback: Goto > Local Definitions/Implementations > Local Test Classes.
    oSession.findById("wnd[0]/mbar/menu[2]/menu[0]/menu[3]").select
End If
On Error GoTo 0
WScript.Sleep 1500
On Error Resume Next
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then oSession.ActiveWindow.sendVKey VKEY_ENTER : WScript.Sleep 800
Err.Clear
On Error GoTo 0

' GATE: confirm the LOCAL TEST-CLASS editor is actually active BEFORE any
' upload/save. btn[35] (Ctrl+F11) switches into the CCAU include, whose editor
' runs Program=SAPLSEO_CLEDITOR (verified S/4HANA 1909). If the navigation drifted
' (control moved on this release/locale) we would still be on the MAIN class
' source (DY0400) -- uploading + saving there would OVERWRITE the main include
' with test-only source. Never fall through to Upload in that case.
Dim sEdProg
On Error Resume Next
sEdProg = UCase(CStr(oSession.Info.Program))
Err.Clear
On Error GoTo 0
' Still on the main source-code screen? (DY0400 status field only exists there.)
Dim bStillMain
On Error Resume Next
Dim oMainProbe : Set oMainProbe = oSession.findById("wnd[0]/usr/txtDY0400_STATUS")
bStillMain = (Err.Number = 0 And Not (oMainProbe Is Nothing))
Err.Clear
On Error GoTo 0
If sEdProg <> "SAPLSEO_CLEDITOR" Or bStillMain Then
    WScript.Echo "ERROR: CCAU_EDITOR_NOT_REACHED -- the Local Test Classes editor did not open" & vbCrLf & _
                 "       (Program=" & sEdProg & "; still on main source=" & bStillMain & ")." & vbCrLf & _
                 "       Aborting so the test source is not saved over the main class include." & vbCrLf & _
                 "       Re-record the CCAU navigation (btn[35]/Ctrl+F11) via /sap-gui-record."
    ReleaseSession oSession, wasLocked
    WScript.Quit 1
End If
WScript.Echo "INFO: Local Test Classes include open (Program=" & sEdProg & ")."

' ------ 4. Upload the test source into the current (test-class) editor -------
WScript.Echo "INFO: Uploading test source: " & TEST_SOURCE_FILE
Dim bUp : bUp = False
Dim up
For Each up In Array("wnd[0]/mbar/menu[3]/menu[9]/menu[2]/menu[0]", "wnd[0]/mbar/menu[3]/menu[8]/menu[2]/menu[0]", "wnd[0]/mbar/menu[3]/menu[2]/menu[0]")
    On Error Resume Next
    oSession.findById(up).select
    If Err.Number = 0 Then bUp = True : WScript.Echo "INFO: Upload menu " & up
    Err.Clear
    On Error GoTo 0
    If bUp Then Exit For
Next
If Not bUp Then
    WScript.Echo "ERROR: Could not find the Upload menu in the test-class editor."
    ReleaseSession oSession, wasLocked
    WScript.Quit 1
End If
WScript.Sleep 2000

' "Save before upload?" -> No (btnBUTTON_2). Detect by control id (locale-proof),
' not by the translated popup title.
On Error Resume Next
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
    Dim oSaveNo : Set oSaveNo = oSession.findById("wnd[1]/usr/btnBUTTON_2")
    If Err.Number = 0 And Not (oSaveNo Is Nothing) Then
        Err.Clear
        oSaveNo.press
        WScript.Sleep 1500
    End If
End If
Err.Clear
On Error GoTo 0

' File-selection dialog (DY_PATH / DY_FILENAME).
On Error Resume Next
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
    Dim iSep, sDir, sFn
    iSep = InStrRev(sUploadFile, "\")
    sDir = Left(sUploadFile, iSep)
    sFn  = Mid(sUploadFile, iSep + 1)
    oSession.findById("wnd[1]/usr/ctxtDY_PATH").Text     = sDir
    oSession.findById("wnd[1]/usr/ctxtDY_FILENAME").Text = sFn
    WScript.Sleep 300
    oSession.findById("wnd[1]").sendVKey VKEY_ENTER
    WScript.Sleep 3000
Else
    WScript.Echo "ERROR: Upload file dialog did not appear (SAP GUI Security may be blocking;" & vbCrLf & _
                 "       the SKILL.md wraps this run with sap_gui_security_sidecar.ps1)."
    ReleaseSession oSession, wasLocked
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0
WScript.Echo "INFO: Test source uploaded into the CCAU include."

' ------ 5. Save -------------------------------------------------------------
oSession.findById("wnd[0]").sendVKey VKEY_F11_SAVE
WScript.Sleep 2000
On Error Resume Next
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
    Dim oTR : Set oTR = oSession.findById("wnd[1]/usr/ctxtKO008-TRKORR")
    If Err.Number = 0 And Not (oTR Is Nothing) Then
        Err.Clear
        ' TR popup: never blind-Enter with an empty TRANSPORT (that silently
        ' registers as Local Object / $TMP). Abort loud so /sap-transport-request
        ' can resolve a TR and the run is re-tried.
        If SAP_TRANSPORT = "" Then
            On Error GoTo 0
            WScript.Echo "ERROR: ABORT_EMPTY_TR -- SAP prompted for a transport request but TRANSPORT is empty."
            WScript.Echo "       Resolve a TR via /sap-transport-request and re-run."
            ReleaseSession oSession, wasLocked
            WScript.Quit 1
        End If
        oTR.Text = SAP_TRANSPORT
        oSession.findById("wnd[1]").sendVKey VKEY_ENTER
        WScript.Sleep 1000
    Else
        Err.Clear
        oSession.ActiveWindow.sendVKey VKEY_ENTER
        WScript.Sleep 800
    End If
End If
Err.Clear
On Error GoTo 0
WScript.Echo "INFO: Saved."

' ------ 6. Activate (Ctrl+F3) + worklist ------------------------------------
WScript.Echo "INFO: Activating..."
On Error Resume Next
oSession.findById("wnd[0]/tbar[1]/btn[27]").press
WScript.Sleep 3000
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
    oSession.findById("wnd[1]/tbar[0]/btn[0]").press
    WScript.Sleep 4000
End If
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then oSession.ActiveWindow.sendVKey VKEY_ENTER : WScript.Sleep 800
Err.Clear
On Error GoTo 0

' ------ 7. Syntax check (read the error grid; AbapEditor swallows the sbar) --
Dim bSyntaxOK : bSyntaxOK = True
On Error Resume Next
oSession.findById("wnd[0]/tbar[1]/btn[26]").press   ' Ctrl+F2
WScript.Sleep 2500
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then oSession.ActiveWindow.sendVKey VKEY_ENTER : WScript.Sleep 500
Err.Clear
On Error GoTo 0

' Locate the result grid via FindSyntaxErrorGrid (shared sap_syntax_check_lib.vbs):
' it WALKS wnd[0]/shellcont for the GridView carrying a MSGTYPE column, because
' the container PATH is release-specific (S/4 1909 = shellcont[1]/shell; ECC 6.0
' nests it deeper). A hardcoded path silently misses errors on the other release
' -> false SUCCESS. This runs AFTER Activate (Ctrl+F3 above) = post-activate gate.
Dim oGrid, nRows
On Error Resume Next
Set oGrid = FindSyntaxErrorGrid(oSession)
If Err.Number = 0 And Not (oGrid Is Nothing) Then
    nRows = oGrid.RowCount
    Err.Clear
    If nRows > 0 Then
        Dim sLang : sLang = UCase(CStr(oSession.Info.Language))
        If Len(sLang) = 0 Then sLang = "E"
        Dim nErr : nErr = 0
        Dim r
        For r = 0 To nRows - 1
            Dim mt, ln, tx
            mt = SafeGetCell(oGrid, r, "MSGTYPE")
            ln = SafeGetCell(oGrid, r, "LINE")
            tx = SafeGetCell(oGrid, r, "TEXT")
            If IsErrorMsgType(mt, sLang) Then
                nErr = nErr + 1
                WScript.Echo "  [ERROR] Line " & ln & ": " & tx
            End If
        Next
        If nErr > 0 Then bSyntaxOK = False
    End If
End If
Err.Clear
On Error GoTo 0

' ------ 8. Final status-bar gate (MessageType, locale-independent) -----------
' Read the sbar MessageType BEFORE releasing the session; an E/A there means the
' save/activate did not stick (locked object, TR error, activation failure).
Dim sBarText, sBarType
On Error Resume Next
sBarText = oSession.findById("wnd[0]/sbar").Text
sBarType = oSession.findById("wnd[0]/sbar").MessageType
Err.Clear
On Error GoTo 0

ReleaseSession oSession, wasLocked
If wasLocked Then WScript.Echo "INFO: Session UI lock released."

On Error Resume Next
If oFSO.FileExists(TEST_SOURCE_FILE & ".upload.txt") Then oFSO.DeleteFile TEST_SOURCE_FILE & ".upload.txt"
Err.Clear
On Error GoTo 0

WScript.Echo "INFO: SAP status: " & sBarText & " (MessageType=" & sBarType & ")"

If sBarType = "E" Or sBarType = "A" Then
    WScript.Echo "ERROR: SAP reported a " & sBarType & "-message on save/activate -- test classes NOT saved."
    WScript.Echo "       Status: " & sBarText
    WScript.Quit 1
End If

If bSyntaxOK Then
    WScript.Echo "SUCCESS: Local test classes uploaded and activated for " & UCase(CLASS_NAME) & "."
    WScript.Quit 0
Else
    WScript.Echo "ERROR: Syntax errors in the uploaded test classes (see above) -- fix and retry."
    WScript.Quit 1
End If
