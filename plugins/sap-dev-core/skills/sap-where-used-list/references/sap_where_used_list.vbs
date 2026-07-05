' =============================================================================
' sap_where_used_list.vbs  -  Run "Where-Used List" for an ABAP repository
'                              object across SE11/SE38/SE37/SE24/SE91, with
'                              optional Print-to-Spool branch.
'
' Flow (matches both recordings):
'
'   1. Navigate to the right initial screen for OBJECT_TYPE.
'   2. Fill the object-name field; for SE11, also pick the sub-type radio.
'   3. Set cursor on the name field, send Ctrl+Shift+F3 (sendVKey 39)
'      = "Where-Used List" everywhere in the ABAP Workbench.
'   4. Scope-selection popup wnd[1]:
'        tbar[0]/btn[7]   -> "Select All" (tick every scope checkbox)
'        tbar[0]/btn[0]   -> Continue
'   5. Branch on the next state:
'        (a) wnd[1] popup with btnSPOP-OPTION1 -> "No usages" path.
'            Press OPTION1 to dismiss; report NOT_FOUND.
'        (b) list rendered on wnd[0] -> "Usages found" path.
'            If TO_SPOOL = X:
'              menu List > Print > Print (mbar/menu[0]/menu[7]/menu[0])
'              set cmbPRIPAR_DYN-PRIMM2 = "" (no immediate output)
'              press wnd[1]/tbar[0]/btn[13]
'              read sbar -> "Spool request <NUM> created"
'            else: just count the lines and report COUNT only.
'   6. Back out to a clean SE-initial screen.
'
' Tokens replaced at run time:
'   %%TXN%%             SE11 / SE38 / SE37 / SE24 / SE91 -- picks the right
'                       initial screen + name-field component ID.
'   %%OBJECT_TYPE%%     For TXN=SE11: TABLE / VIEW / DATAELEMENT / STRUCTURE /
'                       TABLETYPE / TYPEGROUP / DOMAIN / SEARCHHELP /
'                       LOCKOBJECT (drives the radio choice). Empty / ignored
'                       for the other transactions.
'   %%OBJECT_NAME%%     The repository object name (UPPERCASE).
'   %%TO_SPOOL%%        "X" to send the result list to a SAP spool (so a
'                       follow-up /sap-sp02 can download it). Anything else
'                       (empty / "0") = just report the count or NOT_FOUND.
'   %%SESSION_LOCK_VBS%% Path to sap_session_lock.vbs.
'
' Recording references:
'   C:\Temp\Record_WhereUsedList_NotExist_01.vbs   (no-usages path)
'   C:\Temp\Record_WhereUsedList_Exist_01.vbs      (usages + print-to-spool)
'
' Output (last line, parseable by the orchestrator):
'   NOT_FOUND: <OBJECT_TYPE> <NAME> has no usages in the selected scope.
'   FOUND_LIST: <OBJECT_TYPE> <NAME> has usages -- list shown on screen
'                (no spool requested).
'   SPOOL_CREATED: <SPOOL_NUM>  (use /sap-sp02 to download)
'   ERROR: ...
' =============================================================================

Option Explicit

Const TXN          = "%%TXN%%"
Const OBJECT_TYPE  = "%%OBJECT_TYPE%%"
Const OBJECT_NAME  = "%%OBJECT_NAME%%"
Const TO_SPOOL     = "%%TO_SPOOL%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER         = 0
Const VKEY_F3_BACK       = 3
Const VKEY_CTRL_SHIFT_F3 = 39   ' Where-Used List

' Include shared helpers (order matters: attach first so session-lock's
' pre-unlock popup sweep has a resolved oSession to read from).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

' --- Validate ---------------------------------------------------------------
Dim sTxn : sTxn = UCase(Trim(TXN))
Dim sType : sType = UCase(Trim(OBJECT_TYPE))
Dim sName : sName = UCase(Trim(OBJECT_NAME))
Dim bToSpool : bToSpool = (UCase(Trim(TO_SPOOL)) = "X")

If sName = "" Then
    WScript.Echo "ERROR: OBJECT_NAME is empty."
    WScript.Quit 1
End If

' --- Map TXN -> name-field, and (for SE11) the radio button ----------------
Dim sNameId, sRadioId
sRadioId = ""

Select Case sTxn
    Case "SE38"
        sNameId  = "wnd[0]/usr/ctxtRS38M-PROGRAMM"
    Case "SE37"
        sNameId  = "wnd[0]/usr/ctxtRS38L-NAME"
    Case "SE24"
        sNameId  = "wnd[0]/usr/ctxtSEOCLASS-CLSNAME"
    Case "SE91"
        sNameId  = "wnd[0]/usr/ctxtRSDAG-ARBGB"
    Case "SE11"
        Select Case sType
            Case "TABLE"
                sRadioId = "wnd[0]/usr/radRSRD1-TBMA"
                sNameId  = "wnd[0]/usr/ctxtRSRD1-TBMA_VAL"
            Case "VIEW"
                sRadioId = "wnd[0]/usr/radRSRD1-VIMA"
                sNameId  = "wnd[0]/usr/ctxtRSRD1-VIMA_VAL"
            Case "DATAELEMENT", "STRUCTURE", "TABLETYPE", "DATATYPE"
                sRadioId = "wnd[0]/usr/radRSRD1-DDTYPE"
                sNameId  = "wnd[0]/usr/ctxtRSRD1-DDTYPE_VAL"
            Case "TYPEGROUP"
                sRadioId = "wnd[0]/usr/radRSRD1-TYMA"
                sNameId  = "wnd[0]/usr/ctxtRSRD1-TYMA_VAL"
            Case "DOMAIN"
                sRadioId = "wnd[0]/usr/radRSRD1-DOMA"
                sNameId  = "wnd[0]/usr/ctxtRSRD1-DOMA_VAL"
            Case "SEARCHHELP"
                sRadioId = "wnd[0]/usr/radRSRD1-SHMA"
                sNameId  = "wnd[0]/usr/ctxtRSRD1-SHMA_VAL"
            Case "LOCKOBJECT"
                sRadioId = "wnd[0]/usr/radRSRD1-ENQU"
                sNameId  = "wnd[0]/usr/ctxtRSRD1-ENQU_VAL"
            Case Else
                WScript.Echo "ERROR: Unknown OBJECT_TYPE '" & sType & "' for TXN=SE11."
                WScript.Echo "       Allowed: TABLE / VIEW / DATAELEMENT / STRUCTURE / TABLETYPE /"
                WScript.Echo "                TYPEGROUP / DOMAIN / SEARCHHELP / LOCKOBJECT"
                WScript.Quit 1
        End Select
    Case Else
        WScript.Echo "ERROR: Unsupported TXN '" & sTxn & "'."
        WScript.Echo "       Allowed: SE11 / SE24 / SE37 / SE38 / SE91"
        WScript.Quit 1
End Select

' --- Attach to existing SAP GUI session (via shared attach helper) ---------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)

' --- 1. Navigate to TXN -----------------------------------------------------
WScript.Echo "INFO: Navigating to " & sTxn & "..."
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/n" & sTxn
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1200

' --- 2. SE11 sub-type radio (if applicable) -------------------------------
On Error Resume Next
If sRadioId <> "" Then
    oSess.findById(sRadioId).setFocus
    oSess.findById(sRadioId).select
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Could not select radio (" & sRadioId & "): " & Err.Description
        WScript.Quit 1
    End If
    Err.Clear
End If

' --- 3. Fill name field + set cursor on it --------------------------------
oSess.findById(sNameId).Text = sName
oSess.findById(sNameId).setFocus
oSess.findById(sNameId).caretPosition = Len(sName)
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not fill name field (" & sNameId & "): " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0
WScript.Sleep 300

' --- Lock session for the where-used + popup-handling critical section ---
Dim wasLocked : wasLocked = TryLockSession(oSess)
If wasLocked Then
    WScript.Echo "INFO: Session UI locked for the where-used + popup-handling critical section."
End If

' --- 4. Send Ctrl+Shift+F3 ------------------------------------------------
WScript.Echo "INFO: Sending Where-Used List (Ctrl+Shift+F3)..."
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_CTRL_SHIFT_F3
WScript.Sleep 2000
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not send Ctrl+Shift+F3: " & Err.Description
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' --- 5. Scope-selection popup ---------------------------------------------
'
' SAP shows "In which environment ...?" with a tree/list of scopes
' (Programs, Classes, Function modules, Database tables, etc.).
' tbar[0]/btn[7] = Select All; tbar[0]/btn[0] = Continue.
'
' The scope popup appearing is ALSO the confirmation that Where-Used actually
' started -- i.e. the object EXISTS. If the object does not exist, SAP raises an
' E-message on the initial screen and NO scope popup appears; we must NOT then
' fall through to "has usages".
Dim bScopePopup : bScopePopup = False
On Error Resume Next
If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
    ' Fingerprint the scope popup by its Select-All toolbar button.
    Dim oSelAll : Set oSelAll = Nothing
    Set oSelAll = oSess.findById("wnd[1]/tbar[0]/btn[7]")
    If Err.Number = 0 And Not (oSelAll Is Nothing) Then
        Err.Clear
        bScopePopup = True
        WScript.Echo "INFO: Scope popup -- Select All + Continue."
        oSelAll.press
        WScript.Sleep 600
        oSess.findById("wnd[1]/tbar[0]/btn[0]").press
        WScript.Sleep 2000
    End If
End If
Err.Clear
On Error GoTo 0

' --- 5a. Existence gate ----------------------------------------------------
' If NO scope popup appeared, either the object does not exist (Where-Used could
' not start) or the run went straight to a "no usages" popup / a rendered list.
' Read the initial-screen state + sbar to tell "nonexistent/error" from a valid
' immediate result. The name field only resolves while we are still on the
' initial screen (locale-proof, mirrors sap_se11_check.vbs).
If Not bScopePopup Then
    Dim bBackOnInitial
    On Error Resume Next
    Dim oInitProbe : Set oInitProbe = Nothing
    Set oInitProbe = oSess.findById(sNameId)
    bBackOnInitial = (Err.Number = 0 And Not (oInitProbe Is Nothing))
    Err.Clear
    Dim sGateType : sGateType = ""
    sGateType = oSess.findById("wnd[0]/sbar").MessageType
    Dim sGateText : sGateText = ""
    sGateText = oSess.findById("wnd[0]/sbar").Text
    Dim bAnyPopup : bAnyPopup = (InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0)
    On Error GoTo 0
    ' Still on the initial screen with no follow-up popup => Where-Used never ran.
    ' An E/A message here means the object does not exist (or is not readable).
    If bBackOnInitial And Not bAnyPopup Then
        WScript.Echo "INFO: SAP status: [" & sGateType & "] " & sGateText
        ReleaseSession oSess, wasLocked
        WScript.Echo "ERROR: Where-Used List did not start for " & sType & " " & sName & _
                     " -- the object may not exist (still on the initial screen)."
        WScript.Quit 1
    End If
End If

' --- 6. Branch: NOT_FOUND vs LIST_RENDERED --------------------------------
'
' If the active window is wnd[1] right now AND it carries btnSPOP-OPTION1,
' SAP is asking "<obj> not used. <something> ?" -> dismiss with OPTION1
' and report NOT_FOUND.
'
' Otherwise the list is on wnd[0] and we either print-to-spool or report
' FOUND_LIST.
Dim sActive
On Error Resume Next
sActive = oSess.ActiveWindow.Id
On Error GoTo 0

If InStr(sActive, "wnd[1]") > 0 Then
    ' Fingerprint the "no usages" popup: it is an SPOP information/confirm dialog
    ' carrying btnSPOP-OPTION1 but WITHOUT the scope popup's Select-All toolbar
    ' button (tbar[0]/btn[7]). A bare OPTION1 probe is too generic -- a re-shown
    ' scope popup or another modal also carries OPTION1, and dismissing it as
    ' "no usages" would emit a delete-safe verdict for an object that still has
    ' (or could not be checked for) usages.
    Dim oOpt : Set oOpt = Nothing
    Dim oScopeSel : Set oScopeSel = Nothing
    On Error Resume Next
    Set oOpt = oSess.findById("wnd[1]/usr/btnSPOP-OPTION1")
    Err.Clear
    Set oScopeSel = oSess.findById("wnd[1]/tbar[0]/btn[7]")
    Err.Clear
    On Error GoTo 0
    Dim bNoUsagesPopup : bNoUsagesPopup = (Not (oOpt Is Nothing)) And (oScopeSel Is Nothing)
    If bNoUsagesPopup Then
        WScript.Echo "INFO: 'No usages' popup (SPOP OPTION1, no scope toolbar) -- pressing OPTION1 to dismiss."
        oOpt.press
        WScript.Sleep 1200
        Dim sSb : sSb = "" : Dim sSt : sSt = ""
        On Error Resume Next
        sSb = oSess.findById("wnd[0]/sbar").Text
        sSt = oSess.findById("wnd[0]/sbar").MessageType
        On Error GoTo 0
        WScript.Echo "INFO: SAP status: [" & sSt & "] " & sSb
        ' Back out to leave operator on a clean SE-initial screen.
        On Error Resume Next
        oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/n" & sTxn
        oSess.findById("wnd[0]").sendVKey VKEY_ENTER
        On Error GoTo 0
        ReleaseSession oSess, wasLocked
        WScript.Echo "NOT_FOUND: " & sType & " " & sName & " has no usages in the selected scope."
        WScript.Quit 0
    ElseIf Not (oOpt Is Nothing) Then
        ' A popup with OPTION1 but ALSO the scope toolbar (or another unexpected
        ' modal) is not a confirmed "no usages" -- do NOT emit a delete-safe verdict.
        WScript.Echo "ERROR: Unexpected popup after scope selection (OPTION1 present with scope toolbar)."
        WScript.Echo "       Cannot confirm 'no usages' safely; re-run or inspect via /sap-gui-inspect."
        ReleaseSession oSess, wasLocked
        WScript.Quit 1
    End If
End If

' --- 7. List rendered: optionally print to spool ---------------------------
' Gate on sbar MessageType first: an E/A here means Where-Used errored (e.g. the
' object could not be read) rather than produced a usage list -- never report
' "has usages" on an error.
Dim sSb2, sSt2
On Error Resume Next
sSb2 = oSess.findById("wnd[0]/sbar").Text
sSt2 = oSess.findById("wnd[0]/sbar").MessageType
On Error GoTo 0
If sSt2 = "E" Or sSt2 = "A" Then
    WScript.Echo "INFO: SAP status: [" & sSt2 & "] " & sSb2
    ReleaseSession oSess, wasLocked
    WScript.Echo "ERROR: Where-Used List reported a " & sSt2 & "-message for " & sType & " " & sName & _
                 " -- cannot determine usages (object may not exist / not readable)."
    WScript.Quit 1
End If

If Not bToSpool Then
    WScript.Echo "INFO: SAP status: [" & sSt2 & "] " & sSb2
    WScript.Echo "INFO: Where-Used list is on screen; TO_SPOOL=X not set, leaving the list visible."
    ReleaseSession oSess, wasLocked
    WScript.Echo "FOUND_LIST: " & sType & " " & sName & " has usages -- list shown on screen (no spool requested)."
    WScript.Quit 0
End If

' --- 7a. Print menu: List > Print > Print ---------------------------------
WScript.Echo "INFO: Sending list to spool via List > Print > Print..."
On Error Resume Next
oSess.findById("wnd[0]/mbar/menu[0]/menu[7]/menu[0]").select
WScript.Sleep 1500
If Err.Number <> 0 Then
    Err.Clear
    ' Fallback: try toolbar Print button (Ctrl+P-equivalent).
    oSess.findById("wnd[0]/tbar[1]/btn[32]").press
    WScript.Sleep 1500
End If
Err.Clear
On Error GoTo 0

' --- 7b. Print parameters dialog (SAPLSPRI 0600) --------------------------
'
' Set immediate-output flag to "" (do NOT print immediately -- just create
' the spool request). Then press btn[13] to commit.
On Error Resume Next
If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
    Dim oPrimm : Set oPrimm = Nothing
    Set oPrimm = oSess.findById("wnd[1]/usr/subSUBSCREEN:SAPLSPRI:0600/cmbPRIPAR_DYN-PRIMM2")
    If Err.Number = 0 And Not (oPrimm Is Nothing) Then
        oPrimm.setFocus
        oPrimm.key = ""
        WScript.Sleep 300
    End If
    Err.Clear
    oSess.findById("wnd[1]/tbar[0]/btn[13]").press
    WScript.Sleep 2000
    If Err.Number <> 0 Then
        Err.Clear
        ' Fallback: Continue button at btn[0]
        oSess.findById("wnd[1]/tbar[0]/btn[0]").press
        WScript.Sleep 2000
    End If
End If
Err.Clear
On Error GoTo 0

' --- 7c. Read sbar for "Spool request <NUM> created" ----------------------
Dim sFinalMsg, sFinalType
On Error Resume Next
sFinalMsg  = oSess.findById("wnd[0]/sbar").Text
sFinalType = oSess.findById("wnd[0]/sbar").MessageType
On Error GoTo 0
WScript.Echo "INFO: SAP status: [" & sFinalType & "] " & sFinalMsg

' Back out to a clean state.
On Error Resume Next
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/n" & sTxn
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
On Error GoTo 0
ReleaseSession oSess, wasLocked

' Extract the spool number from the status bar message.
' Message text varies by language ("Spool request 397 created" / "Spoolauftrag 397 erstellt"),
' but the digits are always present and the only consecutive run of 4-12 digits in the message.
Dim sSpool : sSpool = ""
Dim i, ch, run
run = ""
For i = 1 To Len(sFinalMsg)
    ch = Mid(sFinalMsg, i, 1)
    If ch >= "0" And ch <= "9" Then
        run = run & ch
    Else
        If Len(run) >= 4 Then
            sSpool = run
            Exit For
        End If
        run = ""
    End If
Next
If sSpool = "" And Len(run) >= 4 Then sSpool = run

If sSpool = "" Then
    WScript.Echo "ERROR: Could not parse spool number from sbar: '" & sFinalMsg & "'"
    WScript.Echo "       Open SP02 manually to find the spool, or re-run with TO_SPOOL=X off."
    WScript.Quit 1
End If

WScript.Echo "SPOOL_CREATED: " & sSpool
WScript.Quit 0
