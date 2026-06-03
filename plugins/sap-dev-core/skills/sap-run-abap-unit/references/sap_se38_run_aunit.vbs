' =============================================================================
' sap_se38_run_aunit.vbs  -  Run ABAP Unit tests on a PROGRAM via SE38
'
' Part of the /sap-run-abap-unit skill (GUI backend). Attaches to an existing
' SAP GUI session, opens the program in SE38 display mode, runs ABAP Unit via the
' Program > Execute > Unit Tests menu, and reads the result. With %%WITH_COVERAGE%%
' it additionally runs Program > Execute > Unit Tests With > Coverage and reads
' the coverage percentage.
'
' Verified live on S/4HANA 1909 (S4D) 2026-06-03:
'   * Run trigger = menu mbar/menu[0]/menu[9]/menu[2] (Ctrl+Shift+F10 is SE80-only
'     and raises "virtual key is not enabled" on screen 500).
'   * Failures open Program=SAPLSAUNIT_RSLT_DSPLY* whose alert ALV RowCount is the
'     failed/errored method count; all-pass stays on the editor with sbar S;
'     no-tests stays on the editor with sbar W. The sbar summary carries the
'     method count on those branches.
'   * Coverage trigger = menu mbar/menu[0]/menu[9]/menu[3]/menu[0] -> the AUCV
'     multi-tab display (Program=SAPLSAUCV_DISPLAY_MULTI_TAB). The "Coverage
'     Metrics" tab (tabpFSCOV) holds a column tree whose root node PERCENTAGE is
'     the overall coverage. The AUCV display has NO sbar summary, so the method
'     counts come from a separate plain run (two-phase) -- the RFC backend
'     (Phase 2) does this in one shot.
'
' Tokens replaced at run time:
'   %%OBJECT_NAME%%      ABAP program holding the test classes
'   %%WITH_COVERAGE%%    "1" to also measure coverage, "" for results-only
'
' Output (last lines, parseable by the SKILL.md wrapper):
'   UNIT_TEST_RUN: EXECUTED methods=N passed=P failed=F errors=0 skipped=0 coverage=<pct|NA>
'   UNIT_TEST_RUN: SKIPPED:NO_TESTS
'   UNIT_TEST_RUN: NEEDS_RECORDING program=<P> screen=<S>
'   ALERT: <n> failed/errored test method(s) -- see the ABAP Unit result display
'   ERROR: ...
' =============================================================================

Option Explicit

Const OBJECT_NAME   = "%%OBJECT_NAME%%"
Const WITH_COVERAGE = "%%WITH_COVERAGE%%"   ' "1" = also measure coverage
Const SESSION_PATH  = "%%SESSION_PATH%%"    ' empty / unsubstituted = use default
Const VKEY_ENTER    = 0

' Globals set by ParseCounts / FindCovPct.
Dim gMethods, gFailed, gCovStr
gMethods = 0 : gFailed = 0 : gCovStr = ""

ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

' ------ Phase 1: open + plain run for the method counts ---------------------
OpenObject oSession
WScript.Echo "INFO: Triggering ABAP Unit run (Program > Execute > Unit Tests)..."
On Error Resume Next
oSession.findById("wnd[0]/mbar/menu[0]/menu[9]/menu[2]").select
WScript.Sleep 4000
Err.Clear
On Error GoTo 0
ParseCounts oSession   ' sets gMethods/gFailed; emits+quits on NO_TESTS / NEEDS_RECORDING

' ------ Phase 2 (optional): coverage ----------------------------------------
Dim covStr : covStr = "NA"
If WITH_COVERAGE = "1" Then
    OpenObject oSession
    covStr = ReadCoverage(oSession, "wnd[0]/mbar/menu[0]/menu[9]/menu[3]/menu[0]")
End If

Dim passed : passed = gMethods - gFailed
If passed < 0 Then passed = 0
WScript.Echo "UNIT_TEST_RUN: EXECUTED methods=" & gMethods & " passed=" & passed & _
             " failed=" & gFailed & " errors=0 skipped=0 coverage=" & covStr
WScript.Quit 0

' ---------------------------------------------------------------------------
Sub OpenObject(oSess)
    oSess.findById("wnd[0]").maximize
    oSess.StartTransaction "SE38"
    WScript.Sleep 1000
    On Error Resume Next
    Dim oF : Set oF = oSess.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM")
    If Err.Number <> 0 Or oF Is Nothing Then
        WScript.Echo "ERROR: SE38 program name field not found (wnd[0]/usr/ctxtRS38M-PROGRAMM)."
        WScript.Quit 1
    End If
    On Error GoTo 0
    oF.Text = UCase(OBJECT_NAME)
    On Error Resume Next
    oSess.findById("wnd[0]/usr/radRS38M-FUNC_EDIT").select
    Err.Clear
    On Error GoTo 0
    WScript.Sleep 300
    oSess.findById("wnd[0]/usr/btnSHOP").press
    WScript.Sleep 1500
    On Error Resume Next
    If InStr(oSess.ActiveWindow.Id, "wnd[1]") > 0 Then oSess.ActiveWindow.sendVKey VKEY_ENTER : WScript.Sleep 800
    Err.Clear
    On Error GoTo 0
    On Error Resume Next
    Dim oEd : Set oEd = Nothing
    Set oEd = oSess.findById("wnd[0]/usr/cntlEDITOR/shellcont/shell")
    On Error GoTo 0
    If Not IsObject(oEd) Or (oEd Is Nothing) Then
        WScript.Echo "ERROR: Could not open program " & UCase(OBJECT_NAME) & _
                     " (check it exists and you have S_DEVELOP authorization)."
        WScript.Quit 1
    End If
    WScript.Echo "INFO: Program " & UCase(OBJECT_NAME) & " opened in SE38 display mode."
End Sub

' Shared parse (identical in sap_se24_run_aunit.vbs). Sets gMethods/gFailed for
' the EXECUTED case; emits the terminal line + quits for NO_TESTS / NEEDS_RECORDING.
Sub ParseCounts(oSess)
    WScript.Sleep 800
    Dim prog, scr, sbT, sbX
    prog = "" : scr = "" : sbT = "" : sbX = ""
    On Error Resume Next
    prog = oSess.Info.Program
    scr  = CStr(oSess.Info.ScreenNumber)
    sbT  = oSess.findById("wnd[0]/sbar").MessageType
    sbX  = oSess.findById("wnd[0]/sbar").Text
    On Error GoTo 0
    WScript.Echo "INFO: After run: Program=" & prog & " Screen=" & scr & " sbar[" & sbT & "]"

    Dim isResult : isResult = (InStr(prog, "SAUNIT_RSLT") > 0)

    If (Not isResult) And (sbT = "W") Then
        WScript.Echo "UNIT_TEST_RUN: SKIPPED:NO_TESTS"
        WScript.Quit 0
    End If

    gMethods = LastInt(sbX)
    gFailed  = 0

    If isResult Then
        Dim gcands, gp, oGrid, trc, gotGrid
        gcands = Array( _
            "wnd[0]/usr/shell/shellcont/shell/shellcont[1]/shell/shellcont[0]/shell", _
            "wnd[0]/usr/shell/shellcont/shell/shellcont[1]/shell/shellcont[1]/shell", _
            "wnd[0]/usr/cntlGRID1/shellcont/shell", _
            "wnd[0]/shellcont/shell" )
        gotGrid = False
        For Each gp In gcands
            Set oGrid = Nothing
            On Error Resume Next
            Set oGrid = oSess.findById(gp)
            On Error GoTo 0
            If IsObject(oGrid) And Not (oGrid Is Nothing) Then
                trc = CountFailures(oGrid)
                If trc >= 0 Then gFailed = trc : gotGrid = True : Exit For
            End If
        Next
        If Not gotGrid Then
            WScript.Echo "UNIT_TEST_RUN: NEEDS_RECORDING program=" & prog & " screen=" & scr
            WScript.Quit 0
        End If
        If gFailed > 0 Then
            WScript.Echo "ALERT: " & gFailed & " failed/errored test method(s) -- open " & _
                         "Program > Execute > Unit Tests in SE38 for per-failure detail."
        End If
    ElseIf (sbT = "S") Or (sbT = "I") Then
        gFailed = 0
    Else
        WScript.Echo "UNIT_TEST_RUN: NEEDS_RECORDING program=" & prog & " screen=" & scr
        WScript.Quit 0
    End If

    If gMethods < gFailed Then gMethods = gFailed
End Sub

' Fires the coverage menu, opens the Coverage Metrics tab, returns the root
' node's coverage percentage as digits (e.g. "33.33"), or "NA" on any failure.
' Fires the coverage menu, opens the Coverage Metrics tab, and returns the root
' node's coverage percentage as digits (e.g. "33.33"), or "NA". The AUCV coverage
' tree's SAPLSAUCV_DISPLAY_COVERAGE:NNNN subscreen number is launch-variant, so we
' SEARCH the tab for a GuiShell subtype=Tree with a PERCENTAGE column rather than
' hardcoding the path (verified live on S/4HANA 1909 SE38).
Function ReadCoverage(oSess, covMenuPath)
    ReadCoverage = "NA"
    On Error Resume Next
    oSess.findById(covMenuPath).select
    On Error GoTo 0
    WScript.Sleep 9000
    If InStr(oSess.Info.Program, "SAUCV") = 0 Then Exit Function
    On Error Resume Next
    oSess.findById("wnd[0]/usr/tabsTAB_COMBI/tabpFSCOV", False).select
    On Error GoTo 0
    WScript.Sleep 4000
    gCovStr = ""
    FindCovPct oSess.findById("wnd[0]/usr", False)
    If gCovStr <> "" Then ReadCoverage = gCovStr
End Function

' Recursively find the coverage tree (GuiShell subtype=Tree with a PERCENTAGE
' column) and set gCovStr to its root node's percentage digits.
Sub FindCovPct(oParent)
    If gCovStr <> "" Then Exit Sub
    If oParent Is Nothing Then Exit Sub
    Dim oColl : Set oColl = Nothing
    On Error Resume Next
    Set oColl = oParent.Children
    On Error GoTo 0
    If oColl Is Nothing Then Exit Sub
    Dim i, oC, t, subt, cn, k, hasPct, nk, raw, j, ch, num
    For i = 0 To oColl.Count - 1
        Set oC = Nothing
        On Error Resume Next
        Set oC = oColl.ElementAt(i)
        On Error GoTo 0
        If Not (oC Is Nothing) Then
            t = "" : subt = ""
            On Error Resume Next
            t = oC.Type : subt = oC.SubType
            On Error GoTo 0
            If t = "GuiShell" And subt = "Tree" Then
                Set cn = Nothing
                On Error Resume Next
                Set cn = oC.GetColumnNames
                On Error GoTo 0
                hasPct = False
                If Not (cn Is Nothing) Then
                    For k = 0 To cn.Count - 1
                        If cn.ElementAt(k) = "PERCENTAGE" Then hasPct = True
                    Next
                End If
                If hasPct Then
                    Set nk = Nothing
                    On Error Resume Next
                    Set nk = oC.GetAllNodeKeys
                    On Error GoTo 0
                    If Not (nk Is Nothing) Then
                        If nk.Count > 0 Then
                            raw = ""
                            On Error Resume Next
                            raw = oC.GetItemText(nk.ElementAt(0), "PERCENTAGE")
                            On Error GoTo 0
                            num = ""
                            For j = 1 To Len(raw)
                                ch = Mid(raw, j, 1)
                                If (ch >= "0" And ch <= "9") Or ch = "." Then num = num & ch
                            Next
                            If num <> "" Then gCovStr = num : Exit Sub
                        End If
                    End If
                End If
            End If
            FindCovPct oC
        End If
    Next
End Sub

' Count failed/errored test methods in the ABAP Unit alert ALV via the ICON_LEVEL
' column: Tolerable alerts (@8R, e.g. "global test class has no test relation") are
' warnings, NOT failures; Critical (@8O) / Fatal are failures. Verified live on
' S/4HANA 1909. If ICON_LEVEL is absent on another release, conservatively counts
' every alert row (never misses a real failure). Returns -1 if RowCount unreadable.
Function CountFailures(oGrid)
    CountFailures = -1
    Dim nRows : nRows = -1
    On Error Resume Next
    nRows = oGrid.RowCount
    On Error GoTo 0
    If nRows < 0 Then Exit Function
    Dim co : Set co = Nothing
    On Error Resume Next
    Set co = oGrid.ColumnOrder
    On Error GoTo 0
    Dim hasLevel : hasLevel = False
    If Not (co Is Nothing) Then
        Dim k
        For k = 0 To co.Count - 1
            If co.ElementAt(k) = "ICON_LEVEL" Then hasLevel = True : Exit For
        Next
    End If
    If Not hasLevel Then
        CountFailures = nRows
        Exit Function
    End If
    Dim nf, r, lvl
    nf = 0
    For r = 0 To nRows - 1
        lvl = ""
        On Error Resume Next
        lvl = oGrid.GetCellValue(r, "ICON_LEVEL")
        On Error GoTo 0
        If lvl <> "" And InStr(lvl, "@8R") = 0 Then nf = nf + 1
    Next
    CountFailures = nf
End Function

Function LastInt(s)
    Dim i, ch, cur, lastv
    cur = "" : lastv = 0
    For i = 1 To Len(s)
        ch = Mid(s, i, 1)
        If ch >= "0" And ch <= "9" Then
            cur = cur & ch
        Else
            If cur <> "" Then lastv = CLng(cur) : cur = ""
        End If
    Next
    If cur <> "" Then lastv = CLng(cur)
    LastInt = lastv
End Function
