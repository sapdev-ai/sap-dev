' =============================================================================
' sap_se41_ops.vbs  -  SAP GUI Scripting: SE41 Menu Painter subobject operations
'
' Attaches to an existing SAP GUI session and performs ONE operation on a
' PF-STATUS (GUI status) subobject of an interface (program / function pool)
' via SE41.
'
' Supported operations (token %%OPERATION%%):
'   CHECK       Report EXIST / NOT_EXIST for the status (no UI change)
'   DISPLAY     Open the status in display mode (read-only)
'   CREATE      Create a new status from a definition file
'   UPDATE      Open an existing status in change mode and re-apply definitions
'   DELETE      Delete the status (with confirmation), then activate to commit
'   ACTIVATE    Activate the interface / status
'   DEACTIVATE  Not supported by SE41 - reports NOT_SUPPORTED
'   COPY        Copy the status to a target program/status (same subobjects)
'
' Tokens replaced at run time:
'   %%OPERATION%%       One of the operations above
'   %%PROGRAM%%         Program / interface name      e.g. "ZHKTESTSE51002"
'   %%STATUS%%          PF-STATUS name                e.g. "ZTEST01"
'   %%STATUS_TYPE%%     CREATE only: DIAL | POPUP | CONTEXT
'   %%SHORT_TEXT%%      CREATE only: short description (<=70 chars)
'   %%DEF_FILE%%        CREATE/UPDATE: absolute path to the .def file
'   %%TARGET_PROGRAM%%  COPY only: target interface name
'   %%TARGET_STATUS%%   COPY only: target status name
'   %%SESSION_PATH%%    Optional explicit session path; empty = auto-resolve
'   %%ATTACH_LIB_VBS%%  Absolute path to sap_attach_lib.vbs
'
' Definition file format (pipe-delimited, one entry per line):
'   STD|position|code|text     Standard toolbar slot (1-13)
'   FK|keyname|code|text       Function key (F2,F5-F9,Shift-F1,Shift-F2,etc.)
'
' Component IDs recorded from SAP GUI 7.60 on S/4HANA 1909.
' =============================================================================

Option Explicit

Const OPERATION      = "%%OPERATION%%"
Const PROGRAM_NAME   = "%%PROGRAM%%"
Const STATUS_NAME    = "%%STATUS%%"
Const STATUS_TYPE    = "%%STATUS_TYPE%%"
Const SHORT_TEXT     = "%%SHORT_TEXT%%"
Const DEF_FILE       = "%%DEF_FILE%%"
Const TARGET_PROGRAM = "%%TARGET_PROGRAM%%"
Const TARGET_STATUS  = "%%TARGET_STATUS%%"
Const SESSION_PATH   = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER    = 0
Const VKEY_F2       = 2
Const VKEY_F11_SAVE = 11
Const VKEY_CANCEL   = 12

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

' ---- Function code storage arrays (max 30 entries) ----
Dim arrType(29), arrPos(29), arrCode(29), arrText(29)
Dim iDefCount

' ---- Function key name to grid row mapping ----
Function FKRow(sKey)
    Select Case UCase(sKey)
        Case "F2"        : FKRow = 14
        Case "F9"        : FKRow = 15
        Case "SHIFT-F2"  : FKRow = 16
        Case "SHIFT-F4"  : FKRow = 17
        Case "SHIFT-F5"  : FKRow = 18
        Case "F5"        : FKRow = 21
        Case "F6"        : FKRow = 22
        Case "F7"        : FKRow = 23
        Case "F8"        : FKRow = 24
        Case "SHIFT-F1"  : FKRow = 25
        Case "SHIFT-F6"  : FKRow = 26
        Case "SHIFT-F7"  : FKRow = 27
        Case "SHIFT-F8"  : FKRow = 28
        Case "SHIFT-F9"  : FKRow = 29
        Case "SHIFT-F11" : FKRow = 30
        Case "SHIFT-F12" : FKRow = 31
        Case Else : FKRow = -1
    End Select
End Function

' ---- Standard toolbar position to column mapping ----
Function STBCol(iPos)
    STBCol = 1 + (CInt(iPos) - 1) * 11
End Function

' ---- Lookup function code text from definitions ----
Function LookupText(sCode)
    Dim i
    For i = 0 To iDefCount - 1
        If UCase(arrCode(i)) = UCase(sCode) Then
            LookupText = arrText(i)
            Exit Function
        End If
    Next
    LookupText = sCode
End Function

' ---- Does a control id exist? (language independent) ----
Function CtrlExists(sId)
    Dim o
    On Error Resume Next
    Set o = oSession.findById(sId)
    CtrlExists = (Err.Number = 0)
    Err.Clear
    On Error GoTo 0
End Function

' ---- Dismiss the "logon language differs from original language" popup ----
' When the logon language differs from the object's master/original language
' SAP prompts before letting you maintain the object. Component IDs are
' language independent: btnPUSH1 = maintain in original language (the safe
' default - keeps the master language untouched), btnPUSH2 = change original
' language, btnPUSH_TEXT_3 = cancel. Identify the popup by the unique pair
' btnPUSH1 + btnPUSH_TEXT_3 so we never mistake another dialog for it.
Sub HandleMasterLangPopup()
    If CtrlExists("wnd[1]/usr/btnPUSH1") And CtrlExists("wnd[1]/usr/btnPUSH_TEXT_3") Then
        oSession.findById("wnd[1]/usr/btnPUSH1").Press
        WScript.Sleep 800
        WScript.Echo "INFO: Logon language differs from original language - maintaining in original language."
    End If
End Sub

' ---- Read the pipe-delimited definition file into arrays ----
Sub ReadDefFile()
    Dim oFSO, oFile, sLine, aParts
    Set oFSO = CreateObject("Scripting.FileSystemObject")
    If Not oFSO.FileExists(DEF_FILE) Then
        WScript.Echo "ERROR: Definition file not found: " & DEF_FILE
        WScript.Quit 1
    End If
    iDefCount = 0
    Set oFile = oFSO.OpenTextFile(DEF_FILE, 1)
    Do While Not oFile.AtEndOfStream
        sLine = Trim(oFile.ReadLine)
        If sLine <> "" And Left(sLine, 1) <> "#" Then
            aParts = Split(sLine, "|")
            If UBound(aParts) >= 3 Then
                arrType(iDefCount) = UCase(Trim(aParts(0)))
                arrPos(iDefCount)  = Trim(aParts(1))
                arrCode(iDefCount) = Trim(aParts(2))
                arrText(iDefCount) = Trim(aParts(3))
                iDefCount = iDefCount + 1
            End If
        End If
    Loop
    oFile.Close
    WScript.Echo "INFO: Read " & iDefCount & " definitions from " & DEF_FILE
End Sub

' ---- Navigate to a fresh SE41 initial screen ----
Sub GotoSE41Initial()
    oSession.findById("wnd[0]").maximize
    oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE41"
    oSession.findById("wnd[0]").sendVKey VKEY_ENTER
    WScript.Sleep 1000
End Sub

' ---- Fill program + Status radio + status on the initial screen ----
Sub FillInitial(sProg, sStat)
    oSession.findById("wnd[0]/usr/radRSMPE-B_STATUS").Select
    oSession.findById("wnd[0]/usr/ctxtRSMPE-PROGRAM").Text = UCase(sProg)
    oSession.findById("wnd[0]/usr/ctxtRSMPE-STATUS").Text  = UCase(sStat)
End Sub

' ---- Apply the loaded definitions into the open editor grid ----
Sub ApplyDefinitions()
    Dim i, iRow, iCol, sId
    oSession.findById("wnd[0]/usr/lbl[0,6]").SetFocus
    WScript.Sleep 200
    oSession.findById("wnd[0]").sendVKey VKEY_F2
    WScript.Sleep 500
    WScript.Echo "INFO: Expanded Function Keys detail view."
    For i = 0 To iDefCount - 1
        If arrType(i) = "STD" Then
            iCol = STBCol(arrPos(i))
            sId = "wnd[0]/usr/txt[" & iCol & ",9]"
            On Error Resume Next
            oSession.findById(sId).Text = arrCode(i)
            If Err.Number <> 0 Then
                WScript.Echo "WARNING: Could not set STD slot " & arrPos(i) & ": " & Err.Description
                Err.Clear
            Else
                WScript.Echo "INFO: STD slot " & arrPos(i) & " = " & arrCode(i) & " (" & arrText(i) & ")"
            End If
            On Error GoTo 0
        ElseIf arrType(i) = "FK" Then
            iRow = FKRow(arrPos(i))
            If iRow < 0 Then
                WScript.Echo "WARNING: Unknown function key: " & arrPos(i)
            Else
                On Error Resume Next
                oSession.findById("wnd[0]/usr/txt[32," & iRow & "]").Text = arrCode(i)
                oSession.findById("wnd[0]/usr/txt[43," & iRow & "]").Text = arrText(i)
                If Err.Number <> 0 Then
                    WScript.Echo "WARNING: Could not set FK " & arrPos(i) & ": " & Err.Description
                    Err.Clear
                Else
                    WScript.Echo "INFO: FK " & arrPos(i) & " = " & arrCode(i) & " (" & arrText(i) & ")"
                End If
                On Error GoTo 0
            End If
        End If
    Next
End Sub

' ---- Save the open editor, handling "Enter Function Text" popups ----
Sub SaveEditor()
    WScript.Echo "INFO: Saving..."
    oSession.findById("wnd[0]").sendVKey VKEY_F11_SAVE
    WScript.Sleep 1500
    Dim sPopup, sFuncCode, sFuncText, bHasRadio, iPopLoop
    iPopLoop = 0
    Do
        On Error Resume Next
        sPopup = ""
        sPopup = oSession.findById("wnd[1]").Text
        If Err.Number <> 0 Or sPopup = "" Then
            Err.Clear
            On Error GoTo 0
            Exit Do
        End If
        Err.Clear
        On Error GoTo 0
        iPopLoop = iPopLoop + 1
        If iPopLoop > 30 Then
            WScript.Echo "ERROR: Too many popups during save. Aborting."
            WScript.Quit 1
        End If
        bHasRadio = False
        On Error Resume Next
        oSession.findById("wnd[1]/usr/radRSMPE-B_TXT_STAT").Text
        If Err.Number = 0 Then bHasRadio = True
        Err.Clear
        On Error GoTo 0
        If bHasRadio Then
            oSession.findById("wnd[1]/usr/radRSMPE-B_TXT_STAT").Select
            oSession.findById("wnd[1]").sendVKey VKEY_ENTER
            WScript.Sleep 500
        Else
            On Error Resume Next
            sFuncCode = oSession.findById("wnd[1]/usr/txtRSMPE-FUNC").Text
            Err.Clear
            On Error GoTo 0
            sFuncText = LookupText(sFuncCode)
            WScript.Echo "INFO: Setting function text for " & sFuncCode & " = " & sFuncText
            On Error Resume Next
            oSession.findById("wnd[1]/usr/txtRSMPE-MENU").Text = sFuncText
            Err.Clear
            On Error GoTo 0
            oSession.findById("wnd[1]").sendVKey VKEY_ENTER
            WScript.Sleep 500
        End If
    Loop
    Dim sSaveType
    On Error Resume Next
    sSaveType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    If sSaveType = "E" Then
        WScript.Echo "ERROR: Save failed - " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    WScript.Echo "INFO: " & oSession.findById("wnd[0]/sbar").Text
End Sub

' ---- Activate the interface (Ctrl+F3), handling activation popups ----
Sub ActivateInterface()
    WScript.Echo "INFO: Activating..."
    On Error Resume Next
    oSession.findById("wnd[0]/tbar[1]/btn[27]").Press
    WScript.Sleep 3000
    HandleMasterLangPopup
    If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
        WScript.Echo "INFO: Inactive objects list - confirming activation..."
        oSession.findById("wnd[1]").sendVKey VKEY_ENTER
        WScript.Sleep 3000
    End If
    If InStr(oSession.ActiveWindow.Id, "wnd[2]") > 0 Then
        WScript.Echo "WARNING: Activation errors - pressing Activate anyway..."
        oSession.findById("wnd[2]/usr/btnBUTTON_1").Press
        WScript.Sleep 3000
    End If
    If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
        oSession.findById("wnd[1]").sendVKey VKEY_CANCEL
        WScript.Sleep 1000
    End If
    Err.Clear
    On Error GoTo 0
End Sub

' ============================================================================
'  MAIN
' ============================================================================
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

Dim sFinalMsg, sFinalType

Select Case UCase(OPERATION)

' --------------------------------------------------------------------------
Case "CHECK"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    oSession.findById("wnd[0]/usr/btn%#AUTOTEXT003").Press   ' Display
    WScript.Sleep 800
    HandleMasterLangPopup
    ' Still on the initial screen (program field present) => not created.
    If CtrlExists("wnd[0]/usr/ctxtRSMPE-PROGRAM") Then
        WScript.Echo "INFO: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Echo "NOT_EXIST"
    Else
        WScript.Echo "EXIST"
    End If
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "DISPLAY"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    oSession.findById("wnd[0]/usr/btn%#AUTOTEXT003").Press   ' Display
    WScript.Sleep 800
    HandleMasterLangPopup
    If CtrlExists("wnd[0]/usr/ctxtRSMPE-PROGRAM") Then
        WScript.Echo "ERROR: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " does not exist - " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    WScript.Echo "INFO: Displaying " & oSession.findById("wnd[0]").Text
    WScript.Echo "SUCCESS: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " is displayed."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "CREATE"
    ReadDefFile
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    WScript.Echo "INFO: Creating status: " & UCase(PROGRAM_NAME) & " / " & UCase(STATUS_NAME)
    oSession.findById("wnd[0]/usr/btn%#AUTOTEXT005").Press   ' Create
    WScript.Sleep 1000
    HandleMasterLangPopup
    If Not CtrlExists("wnd[1]/usr/txtRSMPE-MENUDOC") Then
        WScript.Echo "ERROR: Create Status popup did not appear. Status may already exist."
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    Select Case UCase(STATUS_TYPE)
        Case "DIAL"    : oSession.findById("wnd[1]/usr/radRSMPE-B_DIAL").Select
        Case "POPUP"   : oSession.findById("wnd[1]/usr/radRSMPE-B_POPUP").Select
        Case "CONTEXT" : oSession.findById("wnd[1]/usr/radRSMPE-B_CONTEXT").Select
        Case Else
            WScript.Echo "ERROR: Invalid STATUS_TYPE: " & STATUS_TYPE & ". Use DIAL, POPUP, or CONTEXT."
            WScript.Quit 1
    End Select
    oSession.findById("wnd[1]/usr/txtRSMPE-MENUDOC").Text = SHORT_TEXT
    oSession.findById("wnd[1]").sendVKey VKEY_ENTER
    WScript.Sleep 1000
    If Not CtrlExists("wnd[0]/usr/lbl[0,6]") Then
        WScript.Echo "ERROR: Did not reach editor. Title: " & oSession.findById("wnd[0]").Text
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    WScript.Echo "INFO: In editor: " & oSession.findById("wnd[0]").Text
    ApplyDefinitions
    SaveEditor
    ActivateInterface
    On Error Resume Next
    sFinalMsg  = oSession.findById("wnd[0]/sbar").Text
    sFinalType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    ' Same E/A gate as the ACTIVATE op: sbar E/A means the status was NOT
    ' activated -- fail loudly instead of WARNING + unconditional SUCCESS.
    If sFinalType = "E" Or sFinalType = "A" Then
        WScript.Echo "ERROR: Activation failed - " & sFinalMsg
        WScript.Quit 1
    End If
    WScript.Echo "INFO: SAP status: " & sFinalMsg
    WScript.Echo "SUCCESS: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " created and activated in SAP."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "UPDATE"
    ReadDefFile
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    WScript.Echo "INFO: Opening status for change: " & UCase(PROGRAM_NAME) & " / " & UCase(STATUS_NAME)
    oSession.findById("wnd[0]/usr/btn%#AUTOTEXT004").Press   ' Change
    WScript.Sleep 1000
    HandleMasterLangPopup
    If Not CtrlExists("wnd[0]/usr/lbl[0,6]") Then
        WScript.Echo "ERROR: Could not open status for change. Title: " & oSession.findById("wnd[0]").Text
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    WScript.Echo "INFO: In editor: " & oSession.findById("wnd[0]").Text
    ApplyDefinitions
    SaveEditor
    ActivateInterface
    On Error Resume Next
    sFinalMsg  = oSession.findById("wnd[0]/sbar").Text
    sFinalType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    ' Same E/A gate as the ACTIVATE op: sbar E/A means the status was NOT
    ' activated -- fail loudly instead of WARNING + unconditional SUCCESS.
    If sFinalType = "E" Or sFinalType = "A" Then
        WScript.Echo "ERROR: Activation failed - " & sFinalMsg
        WScript.Quit 1
    End If
    WScript.Echo "INFO: SAP status: " & sFinalMsg
    WScript.Echo "SUCCESS: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " updated and activated in SAP."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "DELETE"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    WScript.Echo "INFO: Deleting status: " & UCase(PROGRAM_NAME) & " / " & UCase(STATUS_NAME)
    oSession.findById("wnd[0]/tbar[1]/btn[24]").Press   ' Delete status (Shift+F12)
    WScript.Sleep 1000
    HandleMasterLangPopup
    If Not CtrlExists("wnd[1]/usr/btn%#AUTOTEXT002") Then
        WScript.Echo "ERROR: Delete confirmation popup did not appear. Status may not exist."
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    oSession.findById("wnd[1]/usr/btn%#AUTOTEXT002").Press   ' Yes
    WScript.Sleep 1200
    On Error Resume Next
    WScript.Echo "INFO: " & oSession.findById("wnd[0]/sbar").Text
    On Error GoTo 0
    ' The delete removes the inactive version; an existing active version is
    ' only dropped when the interface is regenerated. Activate to commit.
    ActivateInterface
    WScript.Echo "SUCCESS: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " deleted."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "ACTIVATE"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    ActivateInterface
    On Error Resume Next
    sFinalMsg  = oSession.findById("wnd[0]/sbar").Text
    sFinalType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    If sFinalType = "E" Or sFinalType = "A" Then
        WScript.Echo "ERROR: Activation failed - " & sFinalMsg
        WScript.Quit 1
    End If
    WScript.Echo "INFO: SAP status: " & sFinalMsg
    WScript.Echo "SUCCESS: Interface " & UCase(PROGRAM_NAME) & " activated."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "DEACTIVATE"
    WScript.Echo "INFO: SE41 Menu Painter has no native deactivate function for a GUI"
    WScript.Echo "      status. A status is a static repository object; to remove it"
    WScript.Echo "      from runtime use DELETE, or change the program that references"
    WScript.Echo "      it. There is no Deactivate entry in any SE41 menu."
    WScript.Echo "NOT_SUPPORTED: DEACTIVATE is not available for SE41 PF-STATUS."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "COPY"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    WScript.Echo "INFO: Copying status " & UCase(PROGRAM_NAME) & "/" & UCase(STATUS_NAME) _
        & " -> " & UCase(TARGET_PROGRAM) & "/" & UCase(TARGET_STATUS)
    oSession.findById("wnd[0]/tbar[1]/btn[30]").Press   ' Copy status (Ctrl+F6)
    WScript.Sleep 1000
    HandleMasterLangPopup
    If Not CtrlExists("wnd[1]/usr/ctxtRSMPE-CP_PROGRAM") Then
        WScript.Echo "ERROR: Copy Status popup did not appear. Source status may not exist."
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    oSession.findById("wnd[1]/usr/ctxtRSMPE-CP_PROGRAM").Text = UCase(TARGET_PROGRAM)
    oSession.findById("wnd[1]/usr/txtRSMPE-CP_STATUS").Text   = UCase(TARGET_STATUS)
    oSession.findById("wnd[1]/tbar[0]/btn[0]").Press          ' Copy
    WScript.Sleep 1000
    ' Subsequent popups: subobjects choice (keep "same subobjects" default) and
    ' the "objects will be recreated" confirmation. Press Copy (btn[0]) on the
    ' top-most popup until none remain. Guard against an infinite loop.
    Dim iGuard
    iGuard = 0
    Do While iGuard < 6
        Dim iHi, k
        iHi = 0
        For k = 4 To 1 Step -1
            If CtrlExists("wnd[" & k & "]") Then
                iHi = k
                Exit For
            End If
        Next
        If iHi = 0 Then Exit Do
        On Error Resume Next
        oSession.findById("wnd[" & iHi & "]/tbar[0]/btn[0]").Press
        If Err.Number <> 0 Then
            Err.Clear
            oSession.findById("wnd[" & iHi & "]").sendVKey VKEY_ENTER
        End If
        On Error GoTo 0
        WScript.Sleep 900
        iGuard = iGuard + 1
    Loop
    On Error Resume Next
    sFinalMsg  = oSession.findById("wnd[0]/sbar").Text
    sFinalType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    If sFinalType = "E" Then
        WScript.Echo "ERROR: Copy failed - " & sFinalMsg
        WScript.Quit 1
    End If
    WScript.Echo "INFO: " & sFinalMsg
    WScript.Echo "SUCCESS: Status copied to " & UCase(TARGET_PROGRAM) & "/" & UCase(TARGET_STATUS) & "."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case Else
    WScript.Echo "ERROR: Unknown OPERATION '" & OPERATION & "'. Use CHECK/DISPLAY/CREATE/UPDATE/DELETE/ACTIVATE/DEACTIVATE/COPY."
    WScript.Quit 1

End Select
