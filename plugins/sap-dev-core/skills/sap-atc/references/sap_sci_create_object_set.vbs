' =============================================================================
' sap_sci_create_object_set.vbs  -  Stage 1: Create / refresh an SCI Object Set
'
' Drives transaction /nSCI to define a named Object Set (the *scope* of what
' the ATC quality gate will check). The Object Set survives across runs, so
' a CI loop can reuse the same set under a stable name.
'
' TWO INPUT MODES (mutually exclusive):
'
'   (a) SINGLE-OBJECT  (%%OBJECT_TYPE%% + %%OBJECT_NAME%%, list file empty)
'       The original, live-verified path: one object, filled straight into the
'       category's LOW select-option field. Behaviour is byte-identical to the
'       pre-A5 script.
'
'   (b) OBJECT-LIST  (%%OBJECT_LIST_FILE%% non-empty  -- the A5 batch path)
'       A file of "<ATC_TYPE> <OBJECT_NAME>" lines (whitespace- or tab-
'       separated; blank / '#'-comment lines ignored). Objects are grouped by
'       SCI category; for each category with >1 object the select-options
'       "Multiple Selection" dialog (SAPLALDB) is opened and every value is
'       inserted (row-by-row, scrolling the table control past its visible
'       window), then committed with Copy (F8). One object set -> one ATC run
'       -> one result TSV keyed by OBJ_NAME. Categories with exactly one object
'       take the fast single-field path; empty categories are unchecked.
'
' Flow (both modes):
'   1. /nSCI                                                  -> SCI initial
'   2. btnSCI_DYNP-OBJS_GL                                    -> ensure Global
'      (REQUIRED -- ATC Run Series binding only consumes Global object sets.)
'   3. ctxtSCI_DYNP-OBJS = %%OBJECT_SET_NAME%% + btnOBJS_CREAT
'   4. Object Set screen: for each of the 6 categories, check + fill the ones
'      that have objects, uncheck the rest. Uncheck chkSCI_DYNP-X_O_SO_SAV.
'   5. Enter to commit, Ctrl+S (F11) to save, confirm popup, Back, Exit.
'
' SCI Object Set categories on S/4HANA 1909 + 2022 (verified live via
' /sap-gui probe of the SUBS_C:SAPLS_CODE_INSPECTOR:0013 subscreen):
'
'   Cat   Category            Checkbox     Name field     Multi-select button
'   REPO  Program             chkXSO_REPO  txtSO_REPO-LOW btn%_SO_REPO_%_APP_%-VALU_PUSH
'   CLAS  Class/Interface     chkXSO_CLAS  txtSO_CLAS-LOW btn%_SO_CLAS_%_APP_%-VALU_PUSH
'   FUGR  Function Group      chkXSO_FUGR  txtSO_FUGR-LOW btn%_SO_FUGR_%_APP_%-VALU_PUSH
'   DDIC  Dictionary Type     chkXSO_DDIC  txtSO_DDIC-LOW btn%_SO_DDIC_%_APP_%-VALU_PUSH
'   DDTY  Type Group          chkXSO_DDTY  txtSO_DDTY-LOW btn%_SO_DDTY_%_APP_%-VALU_PUSH
'   WDYN  Web Dynpro          chkXSO_WDYN  ctxtSO_WDYN-LOW btn%_SO_WDYN_%_APP_%-VALU_PUSH
'
'   Note: NO per-FUNCTION-MODULE category exists. OBJECT_TYPE=FM is rejected
'   with a redirect to FUGR level.
'
'   Multiple-selection dialog (opened by any VALU_PUSH; program SAPLALDB screen
'   3010) -- verified live on S/4HANA 2022 (2026-07-03 probe):
'     Table control : wnd[1]/usr/tabsTAB_STRIP/tabpSIVA/ssubSCREEN_HEADER:SAPLALDB:3010/tblSAPLALDBSINGLE
'     Value cells    : <tbl>/txtRSCSEL_255-SLOW_I[1,<visible-row>]  (col 1, 8 rows visible)
'     Copy (commit)  : wnd[1]/tbar[0]/btn[8]   (F8)
'     Clear all      : wnd[1]/tbar[0]/btn[16]  (Shift+F4)
'
' Tokens:
'   %%OBJECT_SET_NAME%%   Z* customer-namespace identifier (<= 26 chars).
'   %%OBJECT_TYPE%%       PROGRAM | CLASS | INTERFACE | FUGR | DDIC | TYPEGROUP
'                         | WDYN  (single-object mode; ignored when a list file
'                         is supplied).
'   %%OBJECT_NAME%%       The repository object name (UPPERCASE) (single mode).
'   %%OBJECT_LIST_FILE%%  Absolute path to the object-list file (batch mode).
'                         Empty / unsubstituted = single-object mode.
'   %%SESSION_LOCK_VBS%%  Path to sap_session_lock.vbs.
'   %%ATTACH_LIB_VBS%%    Path to sap_attach_lib.vbs.
'   %%SESSION_PATH%%      /app/con[N]/ses[M] or empty for the sole-session default.
'
' Output (last line):
'   SUCCESS: Object set <NAME> created/updated with <n> object(s).
'   ERROR: ...
' =============================================================================

Option Explicit

Const OBJECT_SET_NAME  = "%%OBJECT_SET_NAME%%"
Const OBJECT_TYPE      = "%%OBJECT_TYPE%%"
Const OBJECT_NAME      = "%%OBJECT_NAME%%"
Const OBJECT_LIST_FILE = "%%OBJECT_LIST_FILE%%"   ' empty = single-object mode
Const SESSION_PATH     = "%%SESSION_PATH%%"        ' empty / unsubstituted = use default

Const VKEY_ENTER    = 0
Const VKEY_F3_BACK  = 3
Const VKEY_F8_COPY  = 8
Const VKEY_F11_SAVE = 11
Const VKEY_F12_CANCEL = 12

' All SCI object-set categories, in screen order.
Dim ALL_CATS
ALL_CATS = Array("CLAS", "FUGR", "REPO", "WDYN", "DDIC", "DDTY")

' Include shared helpers (attach first; session-lock's pre-unlock sweep
' reads from oSession).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

' -------------------------------------------------------------------------
' Map an /sap-atc OBJECT_TYPE token to its SCI category short code.
' Returns "" for an unsupported type; "FM" for the reject-with-redirect case.
' -------------------------------------------------------------------------
Function TypeToCat(sTypeRaw)
    Dim t : t = UCase(Trim(sTypeRaw))
    Select Case t
        Case "PROGRAM", "REPORT"          : TypeToCat = "REPO"
        Case "CLASS", "INTERFACE"         : TypeToCat = "CLAS"
        Case "FUGR", "FUNCTION_GROUP"     : TypeToCat = "FUGR"
        Case "DDIC", "DICTIONARY"         : TypeToCat = "DDIC"
        Case "TYPEGROUP"                  : TypeToCat = "DDTY"
        Case "WDYN", "WEB_DYNPRO"         : TypeToCat = "WDYN"
        Case "FM", "FUNCTION_MODULE"      : TypeToCat = "FM"    ' rejected below
        Case Else                         : TypeToCat = ""
    End Select
End Function

' Name-field id for a category (WDYN uses a ctxt field, the rest txt).
Function NameFieldId(cat)
    If cat = "WDYN" Then
        NameFieldId = "ctxtSO_" & cat & "-LOW"
    Else
        NameFieldId = "txtSO_" & cat & "-LOW"
    End If
End Function

' -------------------------------------------------------------------------
' Build the category -> names map from whichever input mode is active.
' Uses a Dictionary keyed by category code; value is a vbTab-joined name list.
' -------------------------------------------------------------------------
Dim catNames : Set catNames = CreateObject("Scripting.Dictionary")
Dim totalObjs : totalObjs = 0

Sub AddObj(sTypeRaw, sNameRaw)
    Dim nm : nm = UCase(Trim(sNameRaw))
    If Len(nm) = 0 Then Exit Sub
    Dim cat : cat = TypeToCat(sTypeRaw)
    If cat = "FM" Then
        WScript.Echo "ERROR: SCI Object Sets have no per-FM category. To check a"
        WScript.Echo "       function module, scope at function-group level"
        WScript.Echo "       (OBJECT_TYPE=FUGR with the FG name)."
        WScript.Quit 1
    End If
    If cat = "" Then
        WScript.Echo "ERROR: Unsupported OBJECT_TYPE '" & sTypeRaw & "' for object '" & nm & "'."
        WScript.Echo "       Allowed: PROGRAM / CLASS / INTERFACE / FUGR / DDIC / TYPEGROUP / WDYN"
        WScript.Quit 1
    End If
    Dim cur : cur = ""
    If catNames.Exists(cat) Then cur = catNames(cat)
    ' de-dup within a category (case-insensitive; names already uppercased)
    If InStr(vbTab & cur & vbTab, vbTab & nm & vbTab) = 0 Then
        If Len(cur) > 0 Then cur = cur & vbTab
        catNames(cat) = cur & nm
        totalObjs = totalObjs + 1
    End If
End Sub

Dim sListFile : sListFile = Trim(OBJECT_LIST_FILE)
' Guard against an unsubstituted token (build via Chr(37) so global %%..%%
' substitution can't corrupt this literal).
Dim sTokenSentinel : sTokenSentinel = Chr(37) & Chr(37) & "OBJECT_LIST_FILE" & Chr(37) & Chr(37)
If sListFile = sTokenSentinel Then sListFile = ""

If Len(sListFile) > 0 Then
    ' ---- OBJECT-LIST mode: read the file (UTF-8 via ADODB.Stream) ----
    Dim oFsoChk : Set oFsoChk = CreateObject("Scripting.FileSystemObject")
    If Not oFsoChk.FileExists(sListFile) Then
        WScript.Echo "ERROR: object-list file not found: " & sListFile
        WScript.Quit 1
    End If
    Dim oStream : Set oStream = CreateObject("ADODB.Stream")
    oStream.Type = 2 : oStream.Charset = "utf-8" : oStream.Open
    oStream.LoadFromFile sListFile
    Dim sAll : sAll = oStream.ReadText(-1)
    oStream.Close
    Dim lines, ln, parts, i2, sTy, sNm
    lines = Split(Replace(sAll, vbCrLf, vbLf), vbLf)
    For i2 = 0 To UBound(lines)
        ln = Trim(lines(i2))
        If Len(ln) > 0 And Left(ln, 1) <> "#" Then
            ' split on first run of whitespace/tab
            ln = Replace(ln, vbTab, " ")
            Do While InStr(ln, "  ") > 0 : ln = Replace(ln, "  ", " ") : Loop
            parts = Split(ln, " ")
            If UBound(parts) >= 1 Then
                sTy = parts(0) : sNm = parts(1)
                AddObj sTy, sNm
            ElseIf UBound(parts) = 0 Then
                WScript.Echo "WARN: skipping malformed list line (need '<TYPE> <NAME>'): " & ln
            End If
        End If
    Next
    If totalObjs = 0 Then
        WScript.Echo "ERROR: object-list file yielded 0 usable objects: " & sListFile
        WScript.Quit 1
    End If
Else
    ' ---- SINGLE-OBJECT mode ----
    AddObj OBJECT_TYPE, OBJECT_NAME
End If

WScript.Echo "INFO: object set will hold " & totalObjs & " object(s) across " & catNames.Count & " category(ies)."

' ------ Attach to existing SAP GUI session (via shared attach helper) -------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Session acquired."

' --- 1. /nSCI -------------------------------------------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSCI"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500

' --- 2. Ensure Object Set scope is GLOBAL ---------------------------------
' ATC Run Series binding ONLY consumes Global object sets. The toggle STATE
' persists across SCI invocations, so read IconName first and press only if
' currently Local (F_USRM). USEGRO = already Global.
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
Dim sCatBase
sCatBase = "wnd[0]/usr/tabsTS_O/tabpTS_O_FC1/ssubSUBS_TS_O:SAPLS_CODE_INSPECTOR:0310/" & _
           "tabsTS_PC/tabpTS_PC_FC2/ssubSUBS_TS_PC:SAPLS_CODE_INSPECTOR:0312/" & _
           "subSUBS_C:SAPLS_CODE_INSPECTOR:0013"

' Multiple-selection dialog table control (opened by a VALU_PUSH press).
Dim MULTI_TBL
MULTI_TBL = "wnd[1]/usr/tabsTAB_STRIP/tabpSIVA/ssubSCREEN_HEADER:SAPLALDB:3010/tblSAPLALDBSINGLE"

Dim cat, idx
For idx = 0 To UBound(ALL_CATS)
    cat = ALL_CATS(idx)
    Dim chkId : chkId = sCatBase & "/chkXSO_" & cat
    If catNames.Exists(cat) Then
        Dim names : names = Split(catNames(cat), vbTab)
        ' check the category
        On Error Resume Next
        oSess.findById(chkId).selected = True
        Err.Clear
        On Error GoTo 0
        If UBound(names) = 0 Then
            ' ---- single object: fast path, fill the LOW field directly ----
            Dim fld : fld = sCatBase & "/" & NameFieldId(cat)
            WScript.Echo "INFO: [" & cat & "] filling single object " & names(0)
            On Error Resume Next
            oSess.findById(fld).Text = names(0)
            oSess.findById(fld).setFocus
            oSess.findById(fld).caretPosition = Len(names(0))
            If Err.Number <> 0 Then
                WScript.Echo "ERROR: Could not fill name field (" & NameFieldId(cat) & "): " & Err.Description
                WScript.Echo "       Field IDs for " & cat & " may differ on this SAP release - re-record via /sap-gui-probe --record."
                ReleaseSession oSess, wasLocked
                WScript.Quit 1
            End If
            Err.Clear
            On Error GoTo 0
        Else
            ' ---- multiple objects: drive the SAPLALDB multi-select dialog ----
            WScript.Echo "INFO: [" & cat & "] opening Multiple Selection for " & (UBound(names)+1) & " objects."
            If Not FillMultiSelect(oSess, sCatBase, cat, names) Then
                ReleaseSession oSess, wasLocked
                WScript.Quit 1
            End If
        End If
    Else
        ' uncheck categories with no objects
        On Error Resume Next
        oSess.findById(chkId).selected = False
        Err.Clear
        On Error GoTo 0
    End If
Next

' Turn off the "Save Selections Only" auto-checkbox (recording disables it).
On Error Resume Next
oSess.findById( _
    "wnd[0]/usr/tabsTS_O/tabpTS_O_FC1/ssubSUBS_TS_O:SAPLS_CODE_INSPECTOR:0310/" & _
    "chkSCI_DYNP-X_O_SO_SAV").selected = False
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

' Confirmation popup (Save dialog) -- press Continue (btn[0]).
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

' Back to SCI initial screen -- leave operator in a clean state.
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_F3_BACK
WScript.Sleep 500
On Error GoTo 0

If sFinalType = "E" Or sFinalType = "A" Then
    WScript.Echo "ERROR: Save returned [" & sFinalType & "] " & sFinalMsg
    WScript.Quit 1
End If

WScript.Echo "INFO: SAP status: [" & sFinalType & "] " & sFinalMsg
WScript.Echo "SUCCESS: Object set " & UCase(OBJECT_SET_NAME) & " created/updated with " & totalObjs & " object(s)."
WScript.Quit 0

' =========================================================================
' FillMultiSelect -- open the select-options Multiple Selection dialog for a
' category, clear it, insert every value (scrolling the table control past
' its visible window), and commit with Copy (F8). Returns True on success.
' =========================================================================
Function FillMultiSelect(oSess, sCatBase, cat, names)
    FillMultiSelect = False
    Dim btnPush : btnPush = sCatBase & "/btn%_SO_" & cat & "_%_APP_%-VALU_PUSH"
    On Error Resume Next
    oSess.findById(btnPush).press
    WScript.Sleep 1000
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Could not open Multiple Selection for " & cat & " (" & btnPush & "): " & Err.Description
        On Error GoTo 0
        Exit Function
    End If
    Err.Clear
    On Error GoTo 0

    ' Make sure the Single-Values tab is active (default), then clear existing.
    On Error Resume Next
    oSess.findById("wnd[1]/usr/tabsTAB_STRIP/tabpSIVA").select
    On Error GoTo 0
    On Error Resume Next
    oSess.findById("wnd[1]/tbar[0]/btn[16]").press   ' Delete Entire Selection
    WScript.Sleep 400
    Err.Clear
    On Error GoTo 0

    Dim tbl
    On Error Resume Next
    Set tbl = oSess.findById(MULTI_TBL)
    On Error GoTo 0
    If tbl Is Nothing Then
        WScript.Echo "ERROR: Multiple Selection table control not found (" & MULTI_TBL & ")."
        Exit Function
    End If

    ' The SAPLALDB single-value table shows 8 VISIBLE rows. Only those 8 accept
    ' a .Text write -- findById resolves phantom rows past the visible window
    ' (it returned 11) and both VisibleRowCount and verticalScrollbar.pageSize
    ' OVERSTATE the writable count, so we do NOT trust them. Proven pattern
    ' (identical to sap-se16n's live-verified multi-select fill): fill the first
    ' PAGE rows at natural positions 0..PAGE-1, then for every extra value scroll
    ' DOWN one row so a fresh empty cell appears at the bottom (position LAST)
    ' and fill THERE. PAGE=8 is stable across the select-options popup on the
    ' verified S/4 releases; re-record if a release renders a different height.
    Const PAGE = 8
    Const LAST = 7   ' PAGE - 1
    Dim i, vis
    For i = 0 To UBound(names)
        If i < PAGE Then
            vis = i
        Else
            On Error Resume Next
            oSess.findById(MULTI_TBL).verticalScrollbar.position = i - LAST
            WScript.Sleep 80
            On Error GoTo 0
            vis = LAST
        End If
        On Error Resume Next
        oSess.findById(MULTI_TBL & "/txtRSCSEL_255-SLOW_I[1," & vis & "]").Text = names(i)
        If Err.Number <> 0 Then
            WScript.Echo "ERROR: Could not fill multi-select row " & i & " (visible " & vis & ") for " & cat & ": " & Err.Description
            On Error GoTo 0
            Exit Function
        End If
        Err.Clear
        On Error GoTo 0
    Next

    ' Copy (F8) commits the list and returns to the object-set screen.
    On Error Resume Next
    oSess.findById("wnd[1]/tbar[0]/btn[" & VKEY_F8_COPY & "]").press
    WScript.Sleep 800
    If Err.Number <> 0 Then
        WScript.Echo "WARN: Copy (btn[8]) press raised: " & Err.Description & " -- trying sendVKey 8."
        Err.Clear
        oSess.findById("wnd[1]").sendVKey VKEY_F8_COPY
        WScript.Sleep 800
    End If
    On Error GoTo 0

    ' If the dialog is still open (validation error), abort loud.
    On Error Resume Next
    Dim stillOpen : stillOpen = (InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0)
    On Error GoTo 0
    If stillOpen Then
        WScript.Echo "WARN: Multiple Selection dialog still open after Copy for " & cat & "; cancelling."
        On Error Resume Next
        oSess.findById("wnd[1]").sendVKey VKEY_F12_CANCEL
        WScript.Sleep 400
        On Error GoTo 0
        Exit Function
    End If

    WScript.Echo "INFO: [" & cat & "] inserted " & (UBound(names)+1) & " values via Multiple Selection."
    FillMultiSelect = True
End Function
