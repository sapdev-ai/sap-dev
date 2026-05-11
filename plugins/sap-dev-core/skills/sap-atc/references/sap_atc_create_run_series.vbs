' =============================================================================
' sap_atc_create_run_series.vbs  -  Stage 2: Create + execute an ATC Run Series
'
' Drives transaction /nATC, navigates to tree node "12" (Schedule Runs / Manage
' Series), creates a new Run Series bound to a previously-created SCI Object
' Set, configures it, saves, and triggers EXECUTE_SERIE. The run is async —
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
'        Enter, Save (btn[11])
'   6. Find the new row in the result grid by APP_CONFIG_NAME column (NAME
'      on older releases — multi-candidate lookup), select it,
'      pressToolbarButton "EXECUTE_SERIE", confirm via tbar[1]/btn[8].
'
' Tokens:
'   %%RUN_SERIES_NAME%%   Unique run-series identifier (e.g. RUN_20260509_104500).
'                          Max ~30 chars; should not collide with existing
'                          series in the system.
'   %%OBJECT_SET_NAME%%   Name of the SCI Object Set created in Stage 1.
'   %%SESSION_LOCK_VBS%%  Path to sap_session_lock.vbs.
'
' Output (last line):
'   SUCCESS: Run series <NAME> scheduled (object set <SET>).
'   ERROR: ...
'
' After SUCCESS, the run is async — call sap_atc_check_run_status.vbs in a
' polling loop until State = COMPLETED.
' =============================================================================

Option Explicit

Const RUN_SERIES_NAME = "%%RUN_SERIES_NAME%%"
Const OBJECT_SET_NAME = "%%OBJECT_SET_NAME%%"

Const VKEY_ENTER    = 0
Const VKEY_F8       = 8
Const VKEY_F11_SAVE = 11

ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

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
    WScript.Echo "       Tree node IDs vary by ATC version. Re-record via /sap-gui-record."
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

oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 800

' Save (Ctrl+S = btn[11] = F11)
WScript.Echo "INFO: Saving run series config..."
On Error Resume Next
oSess.findById("wnd[0]").sendVKey VKEY_F11_SAVE
WScript.Sleep 2000
On Error GoTo 0

' --- 5b. Diagnose any post-Save popup BEFORE walking the grid ----------------
' Save can raise a modal at wnd[1] (most commonly "Save inconsistent data"
' when the underlying SCI Object Set is Local-only — ATC Run Series binding
' requires a Global set). If we don't detect this, the subsequent grid
' lookup runs against a frozen / wrong screen, the column match silently
' falls through to the last-row heuristic, and EXECUTE_SERIE selects the
' wrong row (or fails silently). Dump the popup details and abort with a
' clear diagnostic so the operator sees the real cause instead of a
' downstream "could not match column" warning.
On Error Resume Next
Dim sPopupId, sPopupTitle, sPopupSbar
sPopupId    = ""
sPopupTitle = ""
sPopupSbar  = ""
sPopupId = oSess.ActiveWindow.Id
If Err.Number <> 0 Then Err.Clear
On Error GoTo 0

If Right(sPopupId, 6) <> "wnd[0]" Then
    On Error Resume Next
    sPopupTitle = oSess.ActiveWindow.Text
    Err.Clear
    sPopupSbar  = oSess.findById("wnd[0]/sbar").Text
    Err.Clear
    On Error GoTo 0
    WScript.Echo "ERROR: Post-Save popup detected at " & sPopupId & ": " & sPopupTitle
    WScript.Echo "       Status bar: " & sPopupSbar
    WScript.Echo "       The most common cause is a Local-only SCI Object Set."
    WScript.Echo "       ATC Run Series binding requires a GLOBAL object set; check that"
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

' Try common column-id candidates for the Run Series name column. The Run
' Series management grid actually exposes it as APP_CONFIG_NAME on
' S/4HANA 1909 (verified — same column id as the Run Monitor grid in
' sap_atc_check_run_status.vbs). Older releases may use NAME or
' RUN_SERIES_NAME. The lookup must mirror the multi-candidate approach so
' the row match doesn't silently fall through to the last-row heuristic
' (which can pick a stale series when SAP did not append the new one at
' the bottom).
Dim seriesCols : seriesCols = Array("APP_CONFIG_NAME", "RUN_SERIES_NAME", "RUN_SERIES", "SERIE_NAME", "NAME")
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
            Exit For   ' column id doesn't exist on this grid — try next candidate
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
    ' Fallback: last-row heuristic (the recording's literal row 4 generalised).
    ' Only safe when SAP appends new series at the bottom of the grid, which
    ' is not guaranteed across releases. Emit a clear warning so an operator
    ' watching the log can spot a wrong-row execution.
    If totalRows > 0 Then
        foundRow = totalRows - 1
        WScript.Echo "WARN: Could not match by any known column id (" & Join(seriesCols, ", ") & "); falling back to last row " & foundRow & "."
    Else
        WScript.Echo "ERROR: Run Series grid is empty or unreadable - cannot select for EXECUTE_SERIE."
        ReleaseSession oSess, wasLocked
        WScript.Quit 1
    End If
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

' Recording also presses tbar[1]/btn[8] after EXECUTE_SERIE — likely the
' "Confirm execution" button. If a popup appeared, drive it; if not,
' send F8 from the main window as the recording does.
If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then
    oSess.findById("wnd[1]/tbar[0]/btn[0]").press
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
WScript.Echo "SUCCESS: Run series " & UCase(RUN_SERIES_NAME) & " scheduled (object set " & UCase(OBJECT_SET_NAME) & ")."
WScript.Quit 0
