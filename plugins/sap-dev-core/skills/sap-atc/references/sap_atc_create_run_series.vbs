' =============================================================================
' sap_atc_create_run_series.vbs  -  Stage 2: Create + execute an ATC Run Series
'
' Drives transaction /nATC, navigates to tree node "12" (Schedule Runs / Manage
' Series), creates a new Run Series bound to a previously-created SCI Object
' Set, configures it, saves, and triggers EXECUTE_SERIE. The run is async --
' Stage 3 (sap_atc_check_run_status.vbs) polls for completion.
'
' Flow per C:\Temp\Record_ATC_CreateRunSeries_01.vbs (S/4HANA 1909):
'
'   1. /nATC                                              -> ATC main tree
'   2. doubleClickNode "         12"                      -> Manage Run Series
'   3. pressToolbarButton "CREATE_SERIE" on the result grid
'   4. wnd[1]: ctxtSATC_CI_S_CFG_SERIE_UI_02-NAME = %%RUN_SERIES_NAME%%
'              tbar[0]/btn[0] (Continue)
'   5. Config screen:
'        chkG_DYNP_3000-BEHAVIOR-GENERATED_CODE-ANALYZE = true
'        chkG_DYNP_3000-BEHAVIOR-QUICKFIXES-GENERATE_QUICKFIXES = true
'        radG_DYNP_3000-CHOICE_OF_SELECTION-BY_SET (select)
'        ctxtP3B_OBVT = %%OBJECT_SET_NAME%%
'        (optional) check-variant field = %%CHECK_VARIANT%% when supplied
'        Enter, Save (btn[11])
'   5b. Post-Save: a LOCAL-object run (no remote object provider) raises a
'        benign "local objects will be checked" confirmation (SAPLSPO1 "Save
'        inconsistent data"). Confirm it via the DDIC control
'        wnd[1]/usr/btnBUTTON_1 (Yes; live-verified) and continue. Any OTHER
'        unhandled post-Save modal still aborts loud.
'   6. Find the new row in the result grid by NAME column (verified live on
'      S/4HANA 1909; multi-candidate lookup for other releases), select it,
'      pressToolbarButton "EXECUTE_SERIE", confirm via tbar[1]/btn[8].
'
' Tokens:
'   %%RUN_SERIES_NAME%%   Unique run-series identifier (e.g. RUN_20260509_104500).
'                          Max ~30 chars; should not collide with existing
'                          series in the system.
'   %%OBJECT_SET_NAME%%   Name of the SCI Object Set created in Stage 1.
'   %%CHECK_VARIANT%%     Optional global ATC check variant to run (e.g.
'                          S4HANA_READINESS). Empty / unsubstituted = leave the
'                          field untouched and run the system default variant.
'                          When supplied but the field id cannot be located on
'                          this release, the script FAILS LOUD rather than
'                          silently running the default (which would misreport
'                          non-readiness findings as readiness).
'   %%OBJECT_PROVIDER%%   Optional CENTRAL-ATC remote object provider id
'                          (DATA_SOURCE_ID). Empty / unsubstituted = LOCAL
'                          analysis. When supplied but no provider field is on
'                          the config screen (system not a configured hub), the
'                          script FAILS LOUD rather than running a local analysis
'                          mislabeled as remote. UNVERIFIED field id (no hub).
'   %%SESSION_LOCK_VBS%%  Path to sap_session_lock.vbs.
'
' Output (last line):
'   SUCCESS: Run series <NAME> scheduled (object set <SET>).
'   ERROR: ...
'
' After SUCCESS, the run is async -- call sap_atc_check_run_status.vbs in a
' polling loop until State = COMPLETED.
' =============================================================================

Option Explicit

Const RUN_SERIES_NAME = "%%RUN_SERIES_NAME%%"
Const OBJECT_SET_NAME = "%%OBJECT_SET_NAME%%"
Const CHECK_VARIANT   = "%%CHECK_VARIANT%%"   ' empty / unsubstituted = use system default variant
Const OBJECT_PROVIDER = "%%OBJECT_PROVIDER%%" ' empty / unsubstituted = LOCAL analysis (no remote provider)
Const SESSION_PATH    = "%%SESSION_PATH%%"    ' empty / unsubstituted = use default

' Runtime-built sentinels for the %%..%% tokens (Chr(37)=%). Built at runtime so
' the wrapper's blanket .Replace('%%TOKEN%%', ...) cannot corrupt these
' comparison literals. An unsubstituted token (left as "%%TOKEN%%") is treated
' as "not requested" (default behaviour).
Dim CHKV_TOKEN : CHKV_TOKEN = Chr(37) & Chr(37) & "CHECK_VARIANT" & Chr(37) & Chr(37)
Dim WANT_VARIANT : WANT_VARIANT = (Len(CHECK_VARIANT) > 0) And (CHECK_VARIANT <> CHKV_TOKEN)
Dim PROV_TOKEN : PROV_TOKEN = Chr(37) & Chr(37) & "OBJECT_PROVIDER" & Chr(37) & Chr(37)
Dim WANT_PROVIDER : WANT_PROVIDER = (Len(OBJECT_PROVIDER) > 0) And (OBJECT_PROVIDER <> PROV_TOKEN)

Const VKEY_ENTER    = 0
Const VKEY_F8       = 8
Const VKEY_F11_SAVE = 11

' Include shared helpers (attach first; session-lock's pre-unlock sweep
' reads from oSession).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

' ------ Attach to existing SAP GUI session (via shared attach helper) -------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Session acquired."

' --- 1. /nATC ------------------------------------------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nATC"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500

' --- 2. Tree node 12 (Manage Run Series) ---------------------------------
WScript.Echo "INFO: Opening tree node 12 (Manage Run Series)..."
On Error Resume Next
Dim oTree : Set oTree = oSess.findById("wnd[0]/shellcont/shell/shellcont[1]/shell")
oTree.topNode = "          1"
oTree.selectNode "         12"
oTree.doubleClickNode "         12"
WScript.Sleep 2000
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not navigate ATC tree to node 12: " & Err.Description
    WScript.Echo "       Tree node IDs vary by ATC version. Re-record via /sap-gui-probe --record."
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

Dim wasLocked : wasLocked = TryLockSession(oSess)

' --- 3. CREATE_SERIE on the result grid ----------------------------------
WScript.Echo "INFO: Pressing CREATE_SERIE..."
Dim oGrid
On Error Resume Next
Set oGrid = oSess.findById("wnd[0]/usr/shell/shellcont/shell")
oGrid.pressToolbarButton "CREATE_SERIE"
WScript.Sleep 1500
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not press CREATE_SERIE on Run Series grid: " & Err.Description
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' --- 4. Name popup --------------------------------------------------------
On Error Resume Next
If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
    oSess.findById("wnd[1]/usr/ctxtSATC_CI_S_CFG_SERIE_UI_02-NAME").Text = UCase(RUN_SERIES_NAME)
    oSess.findById("wnd[1]/usr/ctxtSATC_CI_S_CFG_SERIE_UI_02-NAME").caretPosition = Len(RUN_SERIES_NAME)
    oSess.findById("wnd[1]/tbar[0]/btn[0]").press
    WScript.Sleep 1500
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Run-series name popup failed: " & Err.Description
        ReleaseSession oSess, wasLocked
        WScript.Quit 1
    End If
End If
Err.Clear
On Error GoTo 0

' --- 5. Config screen -----------------------------------------------------
Dim sCfgBase
sCfgBase = "wnd[0]/usr/tabsTABSTRIP_OBJECTS/tabpTAB_OWN/" & _
           "ssubTAB_OBJ_SUB_OWN:SAPLSATC_CI_CFG_SERIE_DIALOG:3010"

WScript.Echo "INFO: Configuring run series (BY_SET = " & UCase(OBJECT_SET_NAME) & ")..."
On Error Resume Next

' Behaviour flags (recorded as enabled).
oSess.findById("wnd[0]/usr/chkG_DYNP_3000-BEHAVIOR-GENERATED_CODE-ANALYZE").selected = True
oSess.findById("wnd[0]/usr/chkG_DYNP_3000-BEHAVIOR-QUICKFIXES-GENERATE_QUICKFIXES").selected = True
Err.Clear

' Selection mode: by Object Set.
oSess.findById(sCfgBase & "/radG_DYNP_3000-CHOICE_OF_SELECTION-BY_SET").select
Err.Clear

' Object Set name.
Dim sObjFld
sObjFld = sCfgBase & "/subDYNP_3000_SUBSCR_OBJSEL_CI:SAPLSATC_CI_CFG_SERIE_DIALOG:3200/ctxtP3B_OBVT"
oSess.findById(sObjFld).Text = UCase(OBJECT_SET_NAME)
oSess.findById(sObjFld).setFocus
oSess.findById(sObjFld).caretPosition = Len(OBJECT_SET_NAME)
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not configure run series fields: " & Err.Description
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

' --- 5a. Check Variant (optional) ----------------------------------------
' When CHECK_VARIANT is supplied, override the run-series check variant so the
' run executes a SPECIFIC variant (e.g. S4HANA_READINESS) instead of the
' system default. When empty, the field is left untouched and SAP runs its
' configured default variant -- preserving the prior behaviour exactly.
'
' The check-variant field id is VERIFIED on S/4HANA 1909 (live probe
' 2026-06-03): wnd[0]/usr/ctxtSATC_CI_S_CFG_SERIE_UI_01-CHECK_VARIANT
' (a GuiCTextField sitting directly under wnd[0]/usr, next to the TITLE field).
' It was never captured in the original recording (that run used the default),
' so other releases may rename it -- we still try a candidate list and FAIL
' LOUD if none resolve. Silently running the default variant while the caller
' explicitly asked for a named one is the exact "looks-like-readiness-but-isn't"
' misreport this flag exists to prevent.
Dim variantApplied : variantApplied = False
If WANT_VARIANT Then
    WScript.Echo "INFO: Setting check variant = " & UCase(CHECK_VARIANT) & " ..."
    Dim chkvCands, vi, sVarFld, oVarFld, sVarType
    chkvCands = Array( _
        "wnd[0]/usr/ctxtSATC_CI_S_CFG_SERIE_UI_01-CHECK_VARIANT", _
        "wnd[0]/usr/cmbSATC_CI_S_CFG_SERIE_UI_01-CHECK_VARIANT", _
        "wnd[0]/usr/ctxtG_DYNP_3000-CHECK_VARIANT", _
        "wnd[0]/usr/ctxtG_DYNP_3000-CI_CHK_VARIANT", _
        "wnd[0]/usr/ctxtG_DYNP_3000-CHKV", _
        "wnd[0]/usr/ctxtG_DYNP_3000-VARIANT", _
        "wnd[0]/usr/cmbG_DYNP_3000-CHECK_VARIANT", _
        "wnd[0]/usr/ctxtP3B_CHKV", _
        sCfgBase & "/ctxtG_DYNP_3000-CHECK_VARIANT")
    For vi = 0 To UBound(chkvCands)
        sVarFld = chkvCands(vi)
        On Error Resume Next
        Set oVarFld = Nothing
        Set oVarFld = oSess.findById(sVarFld)
        If Err.Number = 0 And Not (oVarFld Is Nothing) Then
            sVarType = oVarFld.Type
            If sVarType = "GuiComboBox" Then
                oVarFld.key = UCase(CHECK_VARIANT)         ' dropdown variant
            Else
                oVarFld.Text = UCase(CHECK_VARIANT)        ' input field
                oVarFld.setFocus
                oVarFld.caretPosition = Len(CHECK_VARIANT)
            End If
            If Err.Number = 0 Then
                variantApplied = True
                WScript.Echo "INFO: Check variant field matched: " & sVarFld & " (" & sVarType & ")"
            End If
        End If
        Err.Clear
        On Error GoTo 0
        If variantApplied Then Exit For
    Next
    If Not variantApplied Then
        WScript.Echo "ERROR: --variant=" & UCase(CHECK_VARIANT) & " was requested but the run-series check-variant input field could not be located on this release."
        WScript.Echo "       Candidates tried: " & Join(chkvCands, ", ")
        WScript.Echo "       Re-record the ATC run-series config screen via /sap-gui-probe (or /sap-gui-probe --record), then add the real field id to chkvCands in sap_atc_create_run_series.vbs."
        WScript.Echo "       Refusing to fall back to the system DEFAULT variant under a named-variant request (that would misreport non-readiness findings as readiness)."
        ReleaseSession oSess, wasLocked
        WScript.Quit 1
    End If
End If

' --- 5a-prov. Remote object provider (CENTRAL ATC, optional) -------------
' For a CENTRAL ATC hub that analyzes a REMOTE satellite, the run series is
' bound to a registered object provider (DATA_SOURCE_ID /
' SCA_DS_OBJECT_PROVIDER_ID; registered via tx ATC "Manage System Groupings",
' table SATC_AC_OSY_ATTR + an RFC destination to the satellite; the hub's check
' content must be >= the satellite's target release). This selector only appears
' on the config screen once object providers are registered, so the field id is
' UNVERIFIED (no configured hub was available to record against). When
' --object-provider is requested but no candidate resolves, FAIL LOUD rather
' than silently running a LOCAL analysis mislabeled as a remote one.
Dim providerApplied : providerApplied = False
If WANT_PROVIDER Then
    WScript.Echo "INFO: Setting remote object provider = " & OBJECT_PROVIDER & " ..."
    Dim provCands, pj, sProvFld, oProvFld, sProvType
    provCands = Array( _
        "wnd[0]/usr/ctxtG_DYNP_3000-DATA_SOURCE_ID", _
        "wnd[0]/usr/cmbG_DYNP_3000-DATA_SOURCE_ID", _
        "wnd[0]/usr/ctxtG_DYNP_3000-OBJECT_PROVIDER", _
        "wnd[0]/usr/cmbG_DYNP_3000-OBJECT_PROVIDER", _
        "wnd[0]/usr/ctxtSATC_CI_S_CFG_SERIE_UI_01-DATA_SOURCE_ID", _
        "wnd[0]/usr/cmbSATC_CI_S_CFG_SERIE_UI_01-DATA_SOURCE_ID")
    For pj = 0 To UBound(provCands)
        sProvFld = provCands(pj)
        On Error Resume Next
        Set oProvFld = Nothing
        Set oProvFld = oSess.findById(sProvFld)
        If Err.Number = 0 And Not (oProvFld Is Nothing) Then
            sProvType = oProvFld.Type
            If sProvType = "GuiComboBox" Then
                oProvFld.key = OBJECT_PROVIDER
            Else
                oProvFld.Text = OBJECT_PROVIDER
                oProvFld.setFocus
            End If
            If Err.Number = 0 Then
                providerApplied = True
                WScript.Echo "INFO: Object-provider field matched: " & sProvFld & " (" & sProvType & ")"
            End If
        End If
        Err.Clear
        On Error GoTo 0
        If providerApplied Then Exit For
    Next
    If Not providerApplied Then
        WScript.Echo "ERROR: --object-provider=" & OBJECT_PROVIDER & " was requested but no remote object-provider field was found on the run-series config screen."
        WScript.Echo "       This system likely has NO registered ATC object providers. Central ATC requires: tx ATC > Manage System Groupings (a registered provider for the satellite), an SM59 RFC destination to it, and the hub's check content >= the satellite's target release."
        WScript.Echo "       If this IS a configured central hub, the field id differs by release -- record the config screen via /sap-gui-probe and add it to provCands in sap_atc_create_run_series.vbs."
        WScript.Echo "       Refusing to run a LOCAL analysis under a --object-provider (remote) request."
        ReleaseSession oSess, wasLocked
        WScript.Quit 1
    End If
End If

oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 800

' --- 5a.1 Surface (do NOT abort on) any post-ENTER status-bar message --------
' Live finding (S/4HANA 1909, 2026-06-03): ENTER validates the WHOLE config
' screen, so a status-bar Error here can come from an unrelated field (e.g.
' "Package criteria must not be initial" when object selection isn't filled),
' NOT necessarily from the variant. We therefore only WARN here and let the
' existing Save / EXECUTE_SERIE E/A checks below be the hard gate -- aborting
' here would risk a false failure on the happy path. The variant itself is
' already proven applied: 5a set it on the verified field and would have
' failed loud if the field were missing.
If variantApplied Or providerApplied Then
    On Error Resume Next
    Dim sVarSbarType, sVarSbar
    sVarSbarType = oSess.findById("wnd[0]/sbar").MessageType
    sVarSbar     = oSess.findById("wnd[0]/sbar").Text
    On Error GoTo 0
    If sVarSbarType = "E" Or sVarSbarType = "A" Then
        WScript.Echo "WARN: status bar after ENTER: [" & sVarSbarType & "] " & sVarSbar
        WScript.Echo "      If this names the check variant, verify '" & UCase(CHECK_VARIANT) & "' EXISTS and is GLOBAL on this system (e.g. S4HANA_READINESS needs the readiness / Simplification Database content). Otherwise it is likely an object-selection message resolved by the object-set step. The Save / EXECUTE_SERIE checks below are the hard gate."
    End If
End If

' Save (Ctrl+S = btn[11] = F11)
WScript.Echo "INFO: Saving run series config..."
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_F11_SAVE
WScript.Sleep 2000
On Error GoTo 0

' --- 5b. Triage any post-Save popup BEFORE walking the grid ------------------
' Save can raise a modal at wnd[1]. Two cases, handled in order below:
'   5b.0  Benign: a LOCAL-object run raises an informational "local objects
'         will be checked" confirm (Yes = wnd[1]/usr/btnBUTTON_1). Confirm
'         and continue -- this is the normal local-run path, not an error.
'   5b.1  Unhandled: any OTHER modal still standing (e.g. a Local-only SCI
'         Object Set that cannot bind to a Run Series). If we don't abort, the
'         subsequent grid lookup runs against a frozen / wrong screen and the
'         column match dies with RUN_SERIES_NOT_FOUND (or fails silently).
'         Dump the popup details and abort with a clear diagnostic.
On Error Resume Next
Dim sPopupId, sPopupTitle, sPopupSbar
sPopupId    = ""
sPopupTitle = ""
sPopupSbar  = ""
sPopupId = oSess.ActiveWindow.Id
If Err.Number <> 0 Then Err.Clear
On Error GoTo 0

' --- 5b.0 Confirm-and-continue the benign "local objects will be checked" popup
' For a LOCAL-object run (a $TMP / local Z-object, no remote object provider)
' Save raises an informational confirmation -- the SAPLSPO1 "Save inconsistent
' data / local objects will be checked" modal -- whose Yes button is the DDIC
' control wnd[1]/usr/btnBUTTON_1 (VERIFIED live on S/4HANA 1909, 2026-06-26:
' GuiModalWindow SAPLSPO1/0502, btnBUTTON_1 text=' Yes', btnBUTTON_2 text=' No').
' This is NOT an error: pressing Yes proceeds to the run-series grid so
' EXECUTE_SERIE can fire. Detect it by control id ONLY (locale-independent; we
' never branch on the translated modal title, per language_independence_rules.md).
' The original code aborted on ANY post-Save wnd[1] popup, which killed every
' local-object ATC run before EXECUTE_SERIE (field bug, S/4HANA 1909, 2026-06-26).
' The downstream row-match + final status-bar E/A gate remain the hard guards,
' so confirming a genuinely inconsistent save here cannot mask a real failure.
' (The field report named the button "btnSPOP-BUTTON_1"; the live-verified id is
' btnBUTTON_1 -- we try the verified id first, then the SPOP variant as a
' release/dialog-class fallback.)
If Right(sPopupId, 6) <> "wnd[0]" Then
    Dim oSpopYes : Set oSpopYes = Nothing
    Dim yesCands : yesCands = Array(sPopupId & "/usr/btnBUTTON_1", sPopupId & "/usr/btnSPOP-BUTTON_1")
    Dim yi, sYesId
    sYesId = ""
    For yi = 0 To UBound(yesCands)
        On Error Resume Next
        Set oSpopYes = Nothing
        Set oSpopYes = oSess.findById(yesCands(yi))
        On Error GoTo 0
        If Not (oSpopYes Is Nothing) Then
            sYesId = yesCands(yi)
            Exit For
        End If
    Next
    If Not (oSpopYes Is Nothing) Then
        WScript.Echo "INFO: Post-Save confirm popup at " & sPopupId & " (" & sYesId & ") -- pressing Yes (local objects will be checked / confirm save)."
        On Error Resume Next
        oSpopYes.press
        WScript.Sleep 1500
        ' Re-read the active window: Yes should return us to wnd[0] (the grid).
        sPopupId = oSess.ActiveWindow.Id
        If Err.Number <> 0 Then
            Err.Clear
            sPopupId = ""   ' force the abort diagnostic below if we can't re-read
        End If
        On Error GoTo 0
    End If
End If

If Right(sPopupId, 6) <> "wnd[0]" Then
    On Error Resume Next
    sPopupTitle = oSess.ActiveWindow.Text
    Err.Clear
    sPopupSbar  = oSess.findById("wnd[0]/sbar").Text
    Err.Clear
    On Error GoTo 0
    WScript.Echo "ERROR: Unhandled post-Save popup at " & sPopupId & ": " & sPopupTitle
    WScript.Echo "       Status bar: " & sPopupSbar
    WScript.Echo "       (The benign 'local objects will be checked' confirm is auto-pressed"
    WScript.Echo "       via btnBUTTON_1; this popup exposes no such Yes control, so it is a"
    WScript.Echo "       different, unhandled modal.)"
    WScript.Echo "       A common cause is a Local-only SCI Object Set -- ATC Run Series"
    WScript.Echo "       binding requires a GLOBAL object set; check that"
    WScript.Echo "       sap_sci_create_object_set.vbs created the set with the Global flag."
    WScript.Echo "       Aborting Stage 2 to avoid silent EXECUTE_SERIE on the wrong row."
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If

' --- 6. Find the new row, select it, EXECUTE_SERIE -----------------------
'
' After Save, we're back on the Run Series management grid. The recording
' picked row 4 hardcoded; we generalise: walk the grid and match by NAME.
WScript.Echo "INFO: Locating row for " & UCase(RUN_SERIES_NAME) & " in the Run Series grid..."
On Error Resume Next
Set oGrid = oSess.findById("wnd[0]/usr/shell/shellcont/shell")
On Error GoTo 0

' Try common column-id candidates for the Run Series name column. The node-12
' Run Series MANAGEMENT grid (program SAPLSATC_CI_CFG_SERIES_CATALOG) exposes
' it as NAME (title "Series Name") on S/4HANA 1909 -- verified live 2026-06-26
' on S4D by dumping ColumnOrder at ATC node 12. NOTE: this is a DIFFERENT grid
' from the Stage-3 Run Monitor (node 13), which uses APP_CONFIG_NAME; an
' earlier comment here wrongly assumed the two grids shared that id. NAME is
' listed FIRST so the correct column is matched without relying on the invalid
' candidates below raising an error first (GetCellValue on an unknown column id
' raises -2147024809 on the tested kernel, but that generic E_FAIL behaviour is
' not guaranteed across releases/locales -- a build that returns "" instead
' would never error out, so the real id must lead). The remaining ids are kept
' as best-effort fallbacks for other releases. When no candidate matches, the
' script fails LOUD with RUN_SERIES_NOT_FOUND instead of executing a heuristic
' row (the pre-2026-07-02 last-row fallback could fire EXECUTE_SERIE on
' another team's series).
Dim seriesCols : seriesCols = Array("NAME", "APP_CONFIG_NAME", "RUN_SERIES_NAME", "RUN_SERIES", "SERIE_NAME")
Dim r, sRowName, foundRow, sMatchedCol
foundRow = -1
sMatchedCol = ""
Dim totalRows : totalRows = 0
On Error Resume Next
totalRows = oGrid.RowCount
On Error GoTo 0

Dim ci, sCol, sCellTry
For ci = 0 To UBound(seriesCols)
    sCol = seriesCols(ci)
    For r = 0 To totalRows - 1
        sCellTry = ""
        On Error Resume Next
        sCellTry = UCase(Trim(oGrid.GetCellValue(r, sCol)))
        If Err.Number <> 0 Then
            Err.Clear
            Exit For   ' column id doesn't exist on this grid -- try next candidate
        End If
        On Error GoTo 0
        If sCellTry = UCase(Trim(RUN_SERIES_NAME)) Then
            foundRow = r
            sMatchedCol = sCol
            Exit For
        End If
    Next
    If foundRow >= 0 Then Exit For
Next

If foundRow >= 0 Then
    WScript.Echo "INFO: Matched run series '" & UCase(RUN_SERIES_NAME) & "' on row " & foundRow & " via column " & sMatchedCol & "."
Else
    ' Fail LOUD -- never execute a heuristic row. The pre-2026-07-02 fallback
    ' selected the LAST grid row when no column id matched, which fired
    ' EXECUTE_SERIE on an arbitrary (someone else's) run series on this
    ' system-wide grid.
    If totalRows > 0 Then
        WScript.Echo "ERROR: RUN_SERIES_NOT_FOUND - series " & UCase(RUN_SERIES_NAME) & " not matched by any known column id (" & Join(seriesCols, ", ") & ") across " & totalRows & " grid rows."
        WScript.Echo "       Refusing to execute a fallback row (that could EXECUTE_SERIE another team's series)."
        WScript.Echo "       Re-record the node-12 grid via /sap-gui-probe --record and prepend the real name-column id to seriesCols in sap_atc_create_run_series.vbs."
    Else
        WScript.Echo "ERROR: RUN_SERIES_NOT_FOUND - Run Series grid is empty or unreadable; cannot select for EXECUTE_SERIE."
    End If
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If

WScript.Echo "INFO: Selecting row " & foundRow & " and pressing EXECUTE_SERIE..."
On Error Resume Next
oGrid.setCurrentCell foundRow, ""
oGrid.selectedRows = CStr(foundRow)
oGrid.pressToolbarButton "EXECUTE_SERIE"
WScript.Sleep 1500
If Err.Number <> 0 Then
    WScript.Echo "ERROR: EXECUTE_SERIE press failed: " & Err.Description
    ReleaseSession oSess, wasLocked
    WScript.Quit 1
End If
Err.Clear

' Recording also presses tbar[1]/btn[8] after EXECUTE_SERIE -- likely the
' "Confirm execution" button. If a popup appeared, drive it; if not,
' send F8 from the main window as the recording does. A LOCAL-object run can
' raise the same "local objects will be checked" confirm here too, so prefer its
' DDIC Yes control (btnBUTTON_1, live-verified; btnSPOP-BUTTON_1 as fallback)
' when present (locale-independent), then fall back to the recorded tbar[0]/btn[0].
If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
    Dim oExecYes : Set oExecYes = Nothing
    Set oExecYes = oSess.findById("wnd[1]/usr/btnBUTTON_1")
    If oExecYes Is Nothing Then
        Err.Clear
        Set oExecYes = oSess.findById("wnd[1]/usr/btnSPOP-BUTTON_1")
    End If
    If Not (oExecYes Is Nothing) Then
        oExecYes.press
    Else
        Err.Clear
        oSess.findById("wnd[1]/tbar[0]/btn[0]").press
    End If
    WScript.Sleep 1000
Else
    oSess.findById("wnd[0]/tbar[1]/btn[8]").press
    WScript.Sleep 1500
End If
Err.Clear
On Error GoTo 0

Dim sFinalMsg, sFinalType
On Error Resume Next
sFinalMsg  = oSess.findById("wnd[0]/sbar").Text
sFinalType = oSess.findById("wnd[0]/sbar").MessageType
On Error GoTo 0

ReleaseSession oSess, wasLocked

If sFinalType = "E" Or sFinalType = "A" Then
    WScript.Echo "ERROR: EXECUTE_SERIE returned [" & sFinalType & "] " & sFinalMsg
    WScript.Quit 1
End If

WScript.Echo "INFO: SAP status: [" & sFinalType & "] " & sFinalMsg
Dim sVariantId
If variantApplied Then
    sVariantId = UCase(CHECK_VARIANT)
Else
    sVariantId = "SYSTEM_DEFAULT"
End If
WScript.Echo "VARIANT: " & sVariantId
Dim sProvId
If providerApplied Then sProvId = OBJECT_PROVIDER Else sProvId = "LOCAL"
WScript.Echo "PROVIDER: " & sProvId
WScript.Echo "SUCCESS: Run series " & UCase(RUN_SERIES_NAME) & " scheduled (object set " & UCase(OBJECT_SET_NAME) & ", variant " & sVariantId & ", provider " & sProvId & ")."
WScript.Quit 0
