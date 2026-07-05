' =============================================================================
' sap_atc_check_run_status.vbs  -  Stage 3: Read the State of a Run Series
'                                          on the ATC Run Monitor
'
' Drives /nATC, navigates to tree node "13" (Run Monitor -- see Screenshot 1),
' refreshes the grid, finds the row whose Run Series column matches
' %%RUN_SERIES_NAME%%, and reads its State + Phases-completed signals.
'
' Read-only: no Save / no toolbar writes / no popup dismissals. Safe to call
' in a polling loop from the SKILL.md orchestrator.
'
' Tokens:
'   %%RUN_SERIES_NAME%%   The series name supplied to Stage 2 (e.g. RUN_xxx).
'
' Flow per C:\Temp\Record_ATC_CheckRunStatus_01.vbs (S/4HANA 1909):
'   1. /nATC
'   2. doubleClickItem "         13","&Hierarchy"   -> Run Monitor
'   3. tbar[1]/btn[8] (F8 = Execute / refresh)
'   4. Walk the grid for the row whose RUN_SERIES_NAME matches.
'
' Output (last line, parseable):
'   STATE=<RUNNING | COMPLETED | FAILED | NOT_FOUND | UNKNOWN:<raw>>
'   ERROR: ...
'
' State decoding heuristic (the State column is icon-based; we read the
' tooltip / cell text where SAP exposes it):
'   - completion flag icon  = COMPLETED
'   - in-progress / clock   = RUNNING
'   - red-cross / abort     = FAILED
'   - empty cell or unknown = UNKNOWN:<raw>
' =============================================================================

Option Explicit

Const RUN_SERIES_NAME = "%%RUN_SERIES_NAME%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default
Const VKEY_ENTER = 0
Const VKEY_F8    = 8

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

' ------ Attach to existing SAP GUI session (via shared attach helper) -------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)

' --- /nATC + open Run Monitor (tree node 13) -----------------------------
oSess.findById("wnd[0]").maximize
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nATC"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1500

On Error Resume Next
Dim oTree : Set oTree = oSess.findById("wnd[0]/shellcont/shell/shellcont[1]/shell")
oTree.topNode = "          1"
oTree.selectItem "         13", "&Hierarchy"
oTree.ensureVisibleHorizontalItem "         13", "&Hierarchy"
oTree.doubleClickItem "         13", "&Hierarchy"
WScript.Sleep 2000
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Could not navigate ATC tree to Run Monitor (node 13): " & Err.Description
    WScript.Quit 1
End If
Err.Clear

' On S/4HANA 1909 the doubleClickItem on tree node 13 lands on the Run
' Monitor SELECTION SCREEN (Program=SATC_UI_RUN_MONITOR, ScreenNumber=1000),
' NOT directly on the result grid. The grid only appears AFTER F8 (Execute)
' advances to Program=SAPLSATC_UI_MONITOR ScreenNumber=200. Without this
' F8 hop the subsequent findById on wnd[0]/usr/shell/shellcont[0]/shell
' fails because the grid doesn't exist on screen 1000.
'
' We don't press a dedicated Refresh toolbar button -- the original recording
' used tbar[1]/btn[8] (F8 in application toolbar), but on modern S/4HANA
' builds the application toolbar is collapsed to btnvhmore. F8 sent to
' wnd[0] (sendVKey 8) advances the selection screen and works on every
' release we've observed.
On Error Resume Next
Dim sScrPgm : sScrPgm = oSess.Info.Program
Dim sScrNum : sScrNum = CStr(oSess.Info.ScreenNumber)
On Error GoTo 0
WScript.Echo "INFO: After tree node 13 doubleClick: Program=" & sScrPgm & " Screen=" & sScrNum
If sScrNum = "1000" Then
    WScript.Echo "INFO: Landed on selection screen -- pressing F8 to advance to result grid."
    On Error Resume Next
    oSess.findById("wnd[0]").sendVKey VKEY_F8
    WScript.Sleep 2000
    On Error GoTo 0
End If
WScript.Sleep 500
On Error GoTo 0

' --- Walk the monitor grid for our run series ---------------------------
' VBScript subtlety: when findById raises inside On Error Resume Next, the
' `Set oGrid = ...` assignment never completes. If we then reach an
' `If oGrid Is Nothing` check, VBScript raises "Object Required" on the
' `Is Nothing` operator because oGrid was never bound to an object -- it
' stays as Variant/Empty after Dim. The fix is to (a) explicitly bind
' oGrid to Nothing FIRST so it's a proper object reference, and
' (b) gate subsequent checks with IsObject() rather than `Is Nothing`,
' which is tolerant of Empty-state variables.
Dim oGrid : Set oGrid = Nothing
On Error Resume Next
Set oGrid = oSess.findById("wnd[0]/usr/shell/shellcont[0]/shell")
On Error GoTo 0

If Not IsObject(oGrid) Or oGrid Is Nothing Then
    Set oGrid = Nothing
    On Error Resume Next
    Set oGrid = oSess.findById("wnd[0]/usr/shell/shellcont/shell")
    On Error GoTo 0
End If

If Not IsObject(oGrid) Or oGrid Is Nothing Then
    WScript.Echo "ERROR: Could not locate Run Monitor grid (wnd[0]/usr/shell/shellcont[0]/shell)."
    WScript.Quit 1
End If

Dim totalRows : totalRows = 0
On Error Resume Next
totalRows = oGrid.RowCount
On Error GoTo 0

' Try common column-id candidates for the Run Series name. The Run Monitor
' grid actually exposes it as APP_CONFIG_NAME on S/4HANA 1909 (verified
' live via /sap-gui-probe --record probe); the other candidates are kept as
' release-portability fallbacks.
Dim seriesCols, sCol, foundRow, sRowName
seriesCols = Array("APP_CONFIG_NAME", "RUN_SERIES_NAME", "RUN_SERIES", "SERIE_NAME", "NAME")
foundRow = -1

Dim r, c2
For r = 0 To totalRows - 1
    For Each c2 In seriesCols
        sRowName = ""
        On Error Resume Next
        sRowName = UCase(Trim(oGrid.GetCellValue(r, c2)))
        On Error GoTo 0
        If sRowName = UCase(Trim(RUN_SERIES_NAME)) Then
            foundRow = r
            sCol = c2
            Exit For
        End If
    Next
    If foundRow >= 0 Then Exit For
Next

If foundRow < 0 Then
    WScript.Echo "INFO: Scanned " & totalRows & " rows; no match for series " & UCase(RUN_SERIES_NAME)
    WScript.Echo "STATE=NOT_FOUND"
    WScript.Quit 0
End If

WScript.Echo "INFO: Run Series " & UCase(RUN_SERIES_NAME) & " on row " & foundRow & " (column " & sCol & ")"

' --- Read the State column (icon-based; we read tooltip + raw cell) -----
'
' The State column header on this screen is "State". Underlying ID
' candidates: STATUS, STATE, STATUS_ICON. We read the cell value (the icon
' name like "@03\QFinished@") and the tooltip if exposed.
Dim stateCols : stateCols = Array("STATE_ICON", "STATUS_ICON", "STATUS", "STATE", "RUN_STATE")
Dim sStateRaw, sStateColUsed
sStateRaw = ""
For Each c2 In stateCols
    On Error Resume Next
    sStateRaw = oGrid.GetCellValue(foundRow, c2)
    If Err.Number = 0 And sStateRaw <> "" Then
        sStateColUsed = c2
        Err.Clear
        Exit For
    End If
    Err.Clear
    On Error GoTo 0
Next

WScript.Echo "INFO: State raw value (col=" & sStateColUsed & "): '" & sStateRaw & "'"

' Decode. SAP icons are encoded like "@03\QFinished@" / "@5B\QError@" /
' "@5C\QError@" / "@2F\QInProcess@". The literal text after \Q is the
' translatable tooltip - we treat the english stem as the canonical form.
Dim sStateLow : sStateLow = LCase(sStateRaw)
Dim sDecoded : sDecoded = "UNKNOWN:" & sStateRaw

' Localized SAP run-state words, assembled via ChrW() so the RUNTIME strings
' stay ASCII bytes on disk -- 32-bit cscript reads a BOM-less .vbs as the host
' ANSI codepage and would otherwise mojibake a non-ASCII literal (see
' contributing/source_encoding_policy.md). Same idiom as sap_syntax_check_lib.vbs.
' These SUPPLEMENT the locale-independent icon-ID + English checks below; they
' are never the sole match path. The glyph in each trailing comment documents
' what the ChrW() builds -- the runtime literal stays ASCII, only the comment
' carries the character. JA wording is live-observed. ZH: the COMPLETED word is
' live-verified on S4D 1909 -- STATE_ICON shows "zhuangtai: yi-wancheng" (icon @DF); the
' RUNNING / ERROR words are best-effort (those states were absent at capture
' time). The icon-ID prefixes stay authoritative for every logon language.
Dim JA_FINISHED : JA_FINISHED = ChrW(&H7D42) & ChrW(&H4E86)                ' shuuryou      = finished
Dim JA_COMPLETE : JA_COMPLETE = ChrW(&H5B8C) & ChrW(&H4E86)                ' kanryou       = complete
Dim JA_INPROC   : JA_INPROC   = ChrW(&H51E6) & ChrW(&H7406) & ChrW(&H4E2D) ' shori-chuu    = in process
Dim JA_RUNNING  : JA_RUNNING  = ChrW(&H5B9F) & ChrW(&H884C) & ChrW(&H4E2D) ' jikkou-chuu   = running
Dim JA_ERROR    : JA_ERROR    = ChrW(&H30A8) & ChrW(&H30E9) & ChrW(&H30FC) ' eraa          = error
Dim JA_FAILED   : JA_FAILED   = ChrW(&H5931) & ChrW(&H6557)                ' shippai       = failed
Dim JA_ABORTED  : JA_ABORTED  = ChrW(&H4E2D) & ChrW(&H6B62)                ' chuushi       = aborted
Dim ZH_FINISHED : ZH_FINISHED = ChrW(&H5DF2) & ChrW(&H5B8C) & ChrW(&H6210) ' yi-wancheng   = completed  (LIVE-VERIFIED S4D 1909 status text)
Dim ZH_COMPLETE : ZH_COMPLETE = ChrW(&H5B8C) & ChrW(&H6210)                ' wancheng      = complete   (LIVE-VERIFIED: substring of the completed-status text)
Dim ZH_INPROC   : ZH_INPROC   = ChrW(&H5904) & ChrW(&H7406) & ChrW(&H4E2D) ' chuli-zhong   = in process (best-effort; state not observed)
Dim ZH_RUNNING  : ZH_RUNNING  = ChrW(&H8FD0) & ChrW(&H884C) & ChrW(&H4E2D) ' yunxing-zhong = running    (best-effort; state not observed)
Dim ZH_ERROR    : ZH_ERROR    = ChrW(&H9519) & ChrW(&H8BEF)                ' cuowu         = error      (best-effort; state not observed)
Dim ZH_FAILED   : ZH_FAILED   = ChrW(&H5931) & ChrW(&H8D25)                ' shibai        = failed     (best-effort; state not observed)
Dim ZH_ABORTED  : ZH_ABORTED  = ChrW(&H5DF2) & ChrW(&H53D6) & ChrW(&H6D88) ' yi-quxiao     = cancelled  (best-effort; state not observed)

' Match against:
'   * SAP icon prefixes (locale-independent; @03/@DF/@AC = success-ish,
'     @2F/@BZ = in-process, @5B/@5C = error). S/4HANA 1909 returns @DF
'     for the green-flag "Finished" state -- verified live.
'   * Tooltip stems in EN / JA / ZH (ZH best-effort). The literal text after
'     \Q is the translatable tooltip.
If InStr(sStateLow, "finish") > 0 Or InStr(sStateLow, "compl") > 0 Or _
   InStr(sStateLow, "@03") > 0 Or InStr(sStateLow, "@df") > 0 Or _
   InStr(sStateLow, "@ac") > 0 Or InStr(sStateRaw, JA_FINISHED) > 0 Or _
   InStr(sStateRaw, JA_COMPLETE) > 0 Or InStr(sStateRaw, ZH_FINISHED) > 0 Or _
   InStr(sStateRaw, ZH_COMPLETE) > 0 Then
    sDecoded = "COMPLETED"
ElseIf InStr(sStateLow, "process") > 0 Or InStr(sStateLow, "running") > 0 Or _
       InStr(sStateLow, "@2f") > 0 Or InStr(sStateLow, "@bz") > 0 Or _
       InStr(sStateRaw, JA_INPROC) > 0 Or InStr(sStateRaw, JA_RUNNING) > 0 Or _
       InStr(sStateRaw, ZH_INPROC) > 0 Or InStr(sStateRaw, ZH_RUNNING) > 0 Then
    sDecoded = "RUNNING"
ElseIf InStr(sStateLow, "error") > 0 Or InStr(sStateLow, "fail") > 0 Or _
       InStr(sStateLow, "abort") > 0 Or InStr(sStateLow, "@5c") > 0 Or _
       InStr(sStateLow, "@5b") > 0 Or InStr(sStateRaw, JA_ERROR) > 0 Or _
       InStr(sStateRaw, JA_FAILED) > 0 Or InStr(sStateRaw, JA_ABORTED) > 0 Or _
       InStr(sStateRaw, ZH_ERROR) > 0 Or InStr(sStateRaw, ZH_FAILED) > 0 Or _
       InStr(sStateRaw, ZH_ABORTED) > 0 Then
    sDecoded = "FAILED"
ElseIf sStateRaw = "" Then
    sDecoded = "UNKNOWN:(empty)"
End If

WScript.Echo "STATE=" & sDecoded
WScript.Quit 0
