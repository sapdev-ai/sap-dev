' =============================================================================
' sap_sci_create_object_set.vbs  -  Stage 1: Create / refresh an SCI Object Set
'
' Drives transaction /nSCI to define a named Object Set (the *scope* of what
' the ATC quality gate will check). The Object Set survives across runs, so
' a CI loop can reuse the same set under a stable name. This script:
'
'   1. /nSCI                                                  -> SCI initial
'   2. btnSCI_DYNP-OBJS_GL                                    -> toggle Local→Global
'      (REQUIRED — ATC Run Series binding only consumes Global object sets.
'      A Local set saves successfully but Stage 2's Save raises a hidden
'      "Save inconsistent data" warning that silently invalidates the run.)
'   3. ctxtSCI_DYNP-OBJS = %%OBJECT_SET_NAME%% + btnOBJS_CREAT
'   4. On the Object Set screen:
'      - For OBJECT_TYPE=PROGRAM: keep REPO category, uncheck CLAS / FUGR /
'        WDYN, fill txtSO_REPO-LOW with the program name.
'      - Uncheck chkSCI_DYNP-X_O_SO_SAV (the auto-save-as-Local override).
'      - (CLASS / FM / FUGR variants documented; PROGRAM is the verified
'        path from C:\Temp\Record_SCI_CreateObjectSet_01.vbs +
'        Record_SCI_GlobalLocal_01.vbs.)
'   5. Enter to commit, Ctrl+S (btn[11]) to save, confirm popup, Back, Exit.
'
' Tokens:
'   %%OBJECT_SET_NAME%%   Z* customer-namespace identifier (e.g. ZGATESET003).
'                         Must already be 26 chars or less. The SCI initial
'                         screen also accepts existing set names — we trust
'                         the operator: re-running with the same name will
'                         either reopen for editing or fail loudly per the
'                         SAP system's existing-object policy.
'   %%OBJECT_TYPE%%       PROGRAM (verified) | CLASS | FM | FUGR | INTERFACE.
'                         For non-PROGRAM types the field IDs follow the same
'                         pattern (txtSO_<TYPE>-LOW) but were not in the
'                         recording — re-record on first failure.
'   %%OBJECT_NAME%%       The repository object name (UPPERCASE), e.g.
'                         ZMMRMAT017R01 or ZCL_HK_TEST001.
'   %%SESSION_LOCK_VBS%%  Path to sap_session_lock.vbs.
'
' Recording reference: C:\Temp\Record_SCI_CreateObjectSet_01.vbs (S/4HANA 1909).
'
' Output (last line):
'   SUCCESS: Object set <NAME> created/updated with <TYPE> <NAME>.
'   ERROR: ...
' =============================================================================

Option Explicit

Const OBJECT_SET_NAME = "%%OBJECT_SET_NAME%%"
Const OBJECT_TYPE     = "%%OBJECT_TYPE%%"
Const OBJECT_NAME     = "%%OBJECT_NAME%%"

Const VKEY_ENTER    = 0
Const VKEY_F3_BACK  = 3
Const VKEY_F11_SAVE = 11

ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

Dim sType : sType = UCase(Trim(OBJECT_TYPE))

' Map OBJECT_TYPE to the SCI Object-Categories checkbox to KEEP and the
' name field to fill. Categories not listed are unchecked.
'
' SCI Object Set categories on S/4HANA 1909 (verified live via
' /sap-gui-record probe of the SUBS_C:SAPLS_CODE_INSPECTOR:0013 subscreen):
'
'   XSO_CLAS  Class/Interface       SO_CLAS-LOW   (txt)
'   XSO_FUGR  Function Group        SO_FUGR-LOW   (txt)
'   XSO_REPO  Program               SO_REPO-LOW   (txt)
'   XSO_WDYN  Web Dynpro Component  SO_WDYN-LOW   (ctxt)
'   XSO_DDIC  Dictionary Type       SO_DDIC-LOW   (txt)
'   XSO_DDTY  Type Group            SO_DDTY-LOW   (txt)
'
' Note: NO per-FUNCTION-MODULE category exists. To check a single FM,
' the operator must scope at FUGR level (the function group containing
' it). OBJECT_TYPE=FM is therefore rejected with a helpful redirect.
Dim sKeepChk, sNameField, sFieldKind
sFieldKind = "txt"
Select Case sType
    Case "PROGRAM", "REPORT"
        sKeepChk   = "chkXSO_REPO"
        sNameField = "txtSO_REPO-LOW"
    Case "CLASS", "INTERFACE"
        ' SCI groups Class and Interface under one category.
        sKeepChk   = "chkXSO_CLAS"
        sNameField = "txtSO_CLAS-LOW"
    Case "FUGR", "FUNCTION_GROUP"
        sKeepChk   = "chkXSO_FUGR"
        sNameField = "txtSO_FUGR-LOW"
    Case "DDIC", "DICTIONARY"
        sKeepChk   = "chkXSO_DDIC"
        sNameField = "txtSO_DDIC-LOW"
    Case "TYPEGROUP"
        sKeepChk   = "chkXSO_DDTY"
        sNameField = "txtSO_DDTY-LOW"
    Case "WDYN", "WEB_DYNPRO"
        sKeepChk   = "chkXSO_WDYN"
        sNameField = "ctxtSO_WDYN-LOW"
        sFieldKind = "ctxt"
    Case "FM", "FUNCTION_MODULE"
        WScript.Echo "ERROR: SCI Object Sets have no per-FM category on this release."
        WScript.Echo "       To check a single function module, scope at function-group"
        WScript.Echo "       level: pass OBJECT_TYPE=FUGR with the FG name (e.g."
        WScript.Echo "       'FUGR ZFG018' to check every FM in ZFG018, including"
        WScript.Echo "       Z_GENERIC_RFC_WRAPPER_TBL)."
        WScript.Quit 1
    Case Else
        WScript.Echo "ERROR: Unsupported OBJECT_TYPE '" & OBJECT_TYPE & "'."
        WScript.Echo "       Allowed: PROGRAM / CLASS / INTERFACE / FUGR / DDIC / TYPEGROUP / WDYN"
        WScript.Quit 1
End Select

Dim oSAPGUI, oApp, oSess, c, s
On Error Resume Next
Set oSAPGUI = GetObject("SAPGUI")
If Err.Number <> 0 Or oSAPGUI Is Nothing Then
    WScript.Echo "ERROR: SAP GUI is not running."
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

Set oApp = oSAPGUI.GetScriptingEngine
Set oSess = Nothing
On Error Resume Next
For Each c In oApp.Children
    For Each s In c.Children
        Set oSess = s
        Exit For
    Next
    If Not (oSess Is Nothing) Then Exit For
Next
On Error GoTo 0

If oSess Is Nothing Then
    WScript.Echo "ERROR: No SAP GUI session found. Run /sap-login first."
    WScript.Quit 1
End If
WScript.Echo "INFO: Session acquired."

' --- 1. /nSCI -------------------------------------------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSCI"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500

' --- 2. Ensure Object Set scope is GLOBAL ---------------------------------
' On the SCI initial screen there's a small icon button next to the Object
' Set name field — `btnSCI_DYNP-OBJS_GL` — that toggles between Local and
' Global scope. ATC Run Series binding ONLY consumes Global object sets;
' a Local set saves successfully, but the subsequent ATC run-series Save
' raises a hidden "Save inconsistent data" warning that silently invalidates
' the run series.
'
' The toggle's STATE persists across SCI invocations within a session, so
' an unconditional press is non-idempotent — it can flip Global→Local on
' a session whose previous run already toggled to Global. The fix is to
' READ the button's state first and press only if currently Local.
'
' State detection uses IconName (language-independent per Rule 7):
'   F_USRM  → Local   (icon resembles a user/private folder)
'   USEGRO  → Global  (icon resembles a user group)
'   Tooltip is also distinct ("Local" / "Global") but is translated, so
'   we use it for diagnostic output only — never as a branching key.
'
' Captured live on S/4HANA 1909 via probe_sci_toggle.vbs (2026-05-10):
' three presses produced F_USRM → USEGRO → F_USRM IconName cycle, with
' Tooltip switching in lockstep. Both states were Changeable=True.
WScript.Echo "INFO: Reading current SCI Object Set scope from btnSCI_DYNP-OBJS_GL..."
Dim sToggleIcon, sToggleTip, bAlreadyGlobal
sToggleIcon = "" : sToggleTip = "" : bAlreadyGlobal = False
On Error Resume Next
sToggleIcon = oSess.findById("wnd[0]/usr/btnSCI_DYNP-OBJS_GL").IconName
sToggleTip  = oSess.findById("wnd[0]/usr/btnSCI_DYNP-OBJS_GL").Tooltip
On Error GoTo 0

If UCase(sToggleIcon) = "USEGRO" Then
    bAlreadyGlobal = True
    WScript.Echo "INFO: Scope already Global (IconName=USEGRO, Tooltip=""" & sToggleTip & """) - no toggle needed."
ElseIf UCase(sToggleIcon) = "F_USRM" Then
    bAlreadyGlobal = False
    WScript.Echo "INFO: Scope currently Local (IconName=F_USRM, Tooltip=""" & sToggleTip & """) - pressing toggle to switch to Global."
ElseIf sToggleIcon = "" Then
    WScript.Echo "WARN: Could not read btnSCI_DYNP-OBJS_GL.IconName (control absent or older SAP build). Falling back to unconditional single press; may produce wrong scope."
    bAlreadyGlobal = False
Else
    WScript.Echo "WARN: Unrecognised toggle IconName=""" & sToggleIcon & """ (Tooltip=""" & sToggleTip & """). Falling back to unconditional single press; may produce wrong scope."
    bAlreadyGlobal = False
End If

If Not bAlreadyGlobal Then
    On Error Resume Next
    oSess.findById("wnd[0]/usr/btnSCI_DYNP-OBJS_GL").press
    WScript.Sleep 500
    If Err.Number <> 0 Then
        WScript.Echo "WARN: Could not press btnSCI_DYNP-OBJS_GL toggle: " & Err.Description
        Err.Clear
    Else
        ' Verify the press took effect.
        Dim sIconAfter : sIconAfter = ""
        sIconAfter = oSess.findById("wnd[0]/usr/btnSCI_DYNP-OBJS_GL").IconName
        On Error GoTo 0
        If UCase(sIconAfter) = "USEGRO" Then
            WScript.Echo "INFO: Scope is now Global (IconName=USEGRO)."
        Else
            WScript.Echo "WARN: Toggle press did not produce Global state. IconName=" & sIconAfter & ". Saving may produce a Local set; Stage 2 will diagnose if so."
        End If
    End If
    On Error GoTo 0
End If

' --- 3. Fill Object Set name + Create -------------------------------------
On Error Resume Next
oSess.findById("wnd[0]/usr/ctxtSCI_DYNP-OBJS").Text = UCase(OBJECT_SET_NAME)
oSess.findById("wnd[0]/usr/ctxtSCI_DYNP-OBJS").caretPosition = Len(OBJECT_SET_NAME)
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not fill Object Set name field (ctxtSCI_DYNP-OBJS): " & Err.Description
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

Dim wasLocked : wasLocked = TryLockSession(oSess)

WScript.Echo "INFO: Pressing Create (btnOBJS_CREAT)..."
On Error Resume Next
oSess.findById("wnd[0]/usr/btnOBJS_CREAT").press
WScript.Sleep 1500
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not press Create: " & Err.Description
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' --- 4. Object Set definition screen --------------------------------------
'
' On the "Object Categories" subscreen, uncheck every category EXCEPT the
' one matching OBJECT_TYPE. The recording uncheck-list is CLAS, FUGR, WDYN
' (because target was a PROGRAM). For other types we generalise: uncheck
' all known categories then re-check the keep-one.
Dim sCatBase
sCatBase = "wnd[0]/usr/tabsTS_O/tabpTS_O_FC1/ssubSUBS_TS_O:SAPLS_CODE_INSPECTOR:0310/" & _
           "tabsTS_PC/tabpTS_PC_FC2/ssubSUBS_TS_PC:SAPLS_CODE_INSPECTOR:0312/" & _
           "subSUBS_C:SAPLS_CODE_INSPECTOR:0013"

Dim cat, allCats
allCats = Array("chkXSO_CLAS", "chkXSO_FUGR", "chkXSO_REPO", _
                "chkXSO_WDYN", "chkXSO_DDIC", "chkXSO_DDTY")

On Error Resume Next
For Each cat In allCats
    If cat <> sKeepChk Then
        oSess.findById(sCatBase & "/" & cat).selected = False
        Err.Clear   ' silently swallow missing checkboxes; SAP version drift
    End If
Next
' Make sure the keep-checkbox is on (some Object Set defaults flip).
oSess.findById(sCatBase & "/" & sKeepChk).selected = True
Err.Clear
On Error GoTo 0

' Optional: turn off "save object set" auto-checkbox if the recording
' shows it does. Recording disables chkSCI_DYNP-X_O_SO_SAV.
On Error Resume Next
oSess.findById( _
    "wnd[0]/usr/tabsTS_O/tabpTS_O_FC1/ssubSUBS_TS_O:SAPLS_CODE_INSPECTOR:0310/" & _
    "chkSCI_DYNP-X_O_SO_SAV").selected = False
Err.Clear
On Error GoTo 0

' Fill the chosen category's name field.
WScript.Echo "INFO: Filling " & sNameField & " = " & UCase(OBJECT_NAME)
On Error Resume Next
oSess.findById(sCatBase & "/" & sNameField).Text = UCase(OBJECT_NAME)
oSess.findById(sCatBase & "/" & sNameField).setFocus
oSess.findById(sCatBase & "/" & sNameField).caretPosition = Len(OBJECT_NAME)
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not fill name field (" & sNameField & "): " & Err.Description
    WScript.Echo "       Field IDs for " & sType & " may differ on this SAP release - re-record via /sap-gui-record."
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 800

' --- 5. Save (Ctrl+S = F11) -----------------------------------------------
WScript.Echo "INFO: Saving Object Set..."
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_F11_SAVE
WScript.Sleep 1500
On Error GoTo 0

' Confirmation popup (Save dialog) — press Continue (btn[0]).
On Error Resume Next
If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
    oSess.findById("wnd[1]/tbar[0]/btn[0]").press
    WScript.Sleep 1000
End If
Err.Clear
On Error GoTo 0

Dim sFinalMsg, sFinalType
On Error Resume Next
sFinalMsg  = oSess.findById("wnd[0]/sbar").Text
sFinalType = oSess.findById("wnd[0]/sbar").MessageType
On Error GoTo 0

ReleaseSession oSess, wasLocked

' Back to SCI initial screen — leave operator in a clean state.
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_F3_BACK
WScript.Sleep 500
On Error GoTo 0

If sFinalType = "E" Or sFinalType = "A" Then
    WScript.Echo "ERROR: Save returned [" & sFinalType & "] " & sFinalMsg
    WScript.Quit 1
End If

WScript.Echo "INFO: SAP status: [" & sFinalType & "] " & sFinalMsg
WScript.Echo "SUCCESS: Object set " & UCase(OBJECT_SET_NAME) & " created/updated with " & sType & " " & UCase(OBJECT_NAME) & "."
WScript.Quit 0
