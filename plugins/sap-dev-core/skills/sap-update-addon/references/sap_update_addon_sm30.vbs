' =============================================================================
' sap_update_addon_sm30.vbs -- Maintain add-on table records via SM30
'
' Opens SM30 in Maintain mode, reads a TAB-delimited data file, and inserts
' or updates ONE record using the generated maintenance dialog (single-record
' layout). Table-control (list) layouts are refused -- use SE16 or PROG.
'
' Verdict gates (SUCCESS prints only if ALL pass):
'   * operation is INSERT or UPDATE (DELETE is not implemented -> ERROR)
'   * exactly one data row (rows 2..N would re-fill = overwrite the same
'     single-record fields before one Save)
'   * every field resolves as ctxt/txt <TABLE>-<FIELD>; otherwise the dialog
'     is a table-control layout -> SM30_LAYOUT_UNSUPPORTED
'   * transport popup (ctxtKO008-TRKORR) is filled from %%TRANSPORT%%, or the
'     run aborts with ABORT_EMPTY_TR -- the TR popup is never blind-Enter'd
'   * status bar MessageType after Enter and after Save is not E/A
'
' Tokens:
'   %%TABLE_NAME%%     Table name (Y/Z prefix)
'   %%DATA_FILE%%      Absolute path to TAB-delimited data file
'   %%OPERATION%%      INSERT / UPDATE (DELETE refused)
'   %%TRANSPORT%%      TR for the transport popup (may be empty; the run then
'                      aborts with ABORT_EMPTY_TR if SAP prompts for one)
' =============================================================================
Option Explicit

Const TABLE_NAME = "%%TABLE_NAME%%"
Const DATA_FILE  = "%%DATA_FILE%%"
Const OPERATION  = "%%OPERATION%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

' Transport request for the KO008-TRKORR popup. Unsubstituted-token sentinel
' built via Chr(37) so the wrapper's global token substitution cannot corrupt
' the comparison (same idiom as sap_attach_lib.vbs).
Dim SAP_TRANSPORT
SAP_TRANSPORT = Trim("%%TRANSPORT%%")
If SAP_TRANSPORT = Chr(37) & Chr(37) & "TRANSPORT" & Chr(37) & Chr(37) Then SAP_TRANSPORT = ""

' --- 1. Validate operation (before touching the file or the GUI) -----------
Dim sOp
sOp = UCase(Trim(OPERATION))
If sOp = "DELETE" Then
    WScript.Echo "ERROR: SM30_DELETE_UNSUPPORTED -- DELETE via this SM30 flow is not implemented."
    WScript.Echo "       Delete the rows manually in SM30, or use a dedicated recorded flow."
    WScript.Quit 1
ElseIf sOp <> "INSERT" And sOp <> "UPDATE" Then
    WScript.Echo "ERROR: Unsupported operation '" & OPERATION & "' -- expected INSERT or UPDATE."
    WScript.Quit 1
End If

' --- 2. Read data file (UTF-8) -- before any GUI navigation ----------------
' The data-file contract (SKILL.md Step 1) and the PROG path (GUI_UPLOAD)
' are UTF-8. This was previously read via OpenTextFile(..., -1) = UTF-16,
' so a UTF-8 file silently failed. Use ADODB.Stream Charset=utf-8 (the house
' idiom, e.g. sap_se38_create.vbs) so PROG / SE16 / SM30 all agree on UTF-8.
Dim oFSO, aLines(), iLineCount, sLine
Set oFSO = CreateObject("Scripting.FileSystemObject")

If Not oFSO.FileExists(DATA_FILE) Then
    WScript.Echo "ERROR: Data file not found: " & DATA_FILE
    WScript.Quit 1
End If

Dim oStream, sAll, aRaw, iR
Set oStream = CreateObject("ADODB.Stream")
oStream.Type = 2            ' adTypeText
oStream.Charset = "utf-8"   ' strips a BOM if present; reads BOM-less UTF-8 too
oStream.Open
oStream.LoadFromFile DATA_FILE
sAll = oStream.ReadText
oStream.Close

' Normalize line endings, split, skip blank lines, build a 1-based array.
sAll = Replace(sAll, vbCrLf, vbLf)
sAll = Replace(sAll, vbCr, vbLf)
aRaw = Split(sAll, vbLf)
iLineCount = 0
ReDim aLines(0)
For iR = 0 To UBound(aRaw)
    sLine = aRaw(iR)
    If Trim(sLine) <> "" Then
        iLineCount = iLineCount + 1
        ReDim Preserve aLines(iLineCount)
        aLines(iLineCount) = sLine
    End If
Next

If iLineCount < 2 Then
    WScript.Echo "ERROR: Data file must have a header line and at least one data line."
    WScript.Quit 1
End If

' Single-record maintenance dialog: the flow fills ONE set of flat fields and
' saves once. Rows 2..N would re-fill (= overwrite) those same fields before
' the Save, silently losing all but the last row. Refuse multi-row input
' upfront, before anything is written.
If iLineCount > 2 Then
    WScript.Echo "ERROR: SM30 single-record flow supports exactly 1 data row per run; data file has " & (iLineCount - 1) & "."
    WScript.Echo "       Split the file (one run per row) or use the SE16 or PROG method."
    WScript.Quit 1
End If

' Parse header
Dim aHeader
aHeader = Split(aLines(1), vbTab)
WScript.Echo "INFO: Header fields: " & Join(aHeader, ", ")

' --- 3. Attach and navigate to SM30 in Maintain mode -----------------------
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSM30"
oSession.findById("wnd[0]").sendVKey 0
WScript.Sleep 500

oSession.findById("wnd[0]/usr/ctxtVIEWNAME").Text = TABLE_NAME

On Error Resume Next
oSession.findById("wnd[0]/usr/btnUPDATE_PUSH").Press ' Maintain button
WScript.Sleep 1500
If Err.Number <> 0 Then
    WScript.Echo "ERROR: Failed to open SM30 maintenance dialog."
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

WScript.Echo "INFO: SM30 screen after open: " & CStr(oSession.Info.ScreenNumber)

' Popups raised on opening maintenance (cross-client caution, or an immediate
' transport prompt on recording-enabled views): dispatch by control id --
' the TR popup is never blind-Enter'd.
HandleSm30Popups oSession

' --- 4. Fill the single record ----------------------------------------------
If sOp = "INSERT" Then
    ' Click "New Entries" button for INSERT
    On Error Resume Next
    oSession.findById("wnd[0]/tbar[1]/btn[14]").Press  ' New Entries
    WScript.Sleep 500
    If Err.Number <> 0 Then
        ' Try alternative -- menu Edit > New Entries
        Err.Clear
        oSession.findById("wnd[0]/mbar/menu[1]/menu[4]").Select
        WScript.Sleep 500
    End If
    Err.Clear
    On Error GoTo 0
End If

Dim j, aVals, sFldName, sFldVal, sFldId
aVals = Split(aLines(2), vbTab)

For j = 0 To UBound(aHeader)
    sFldName = UCase(Trim(aHeader(j)))
    If j <= UBound(aVals) Then
        sFldVal = aVals(j)
    Else
        sFldVal = ""
    End If

    ' Skip MANDT -- auto-filled by SAP
    If sFldName = "MANDT" Or sFldName = "CLIENT" Then
        ' skip
    Else
        On Error Resume Next

        ' Pattern 1: Direct field (ctxt<TABLE>-<FIELD>)
        sFldId = "wnd[0]/usr/ctxt" & UCase(TABLE_NAME) & "-" & sFldName
        oSession.findById(sFldId).Text = sFldVal
        If Err.Number <> 0 Then
            Err.Clear
            ' Pattern 2: txt prefix
            sFldId = "wnd[0]/usr/txt" & UCase(TABLE_NAME) & "-" & sFldName
            oSession.findById(sFldId).Text = sFldVal
            If Err.Number <> 0 Then
                Err.Clear
                On Error GoTo 0
                ' Neither flat-field pattern resolves: the generated dialog is
                ' a table-control (list) layout, which this flow cannot drive.
                ' Refuse loud instead of "processing" rows that never land.
                WScript.Echo "ERROR: SM30_LAYOUT_UNSUPPORTED (table control) - use the SE16 or PROG method"
                WScript.Echo "       Field " & UCase(TABLE_NAME) & "-" & sFldName & " was not found as a ctxt/txt flat field;"
                WScript.Echo "       the maintenance dialog is not a single-record layout. Nothing was saved."
                WScript.Quit 1
            End If
        End If
        Err.Clear
        On Error GoTo 0
    End If
Next

' Press Enter to confirm the row, then gate on the status bar.
oSession.findById("wnd[0]").sendVKey 0
WScript.Sleep 300
HandleSm30Popups oSession
CheckSbarGate oSession, "after Enter"

' --- 5. Save -----------------------------------------------------------------
WScript.Echo "INFO: Saving..."
oSession.findById("wnd[0]").sendVKey 11  ' Ctrl+S
WScript.Sleep 1000

' Save can raise the transport popup (and/or chained confirms) -- handled by
' control id; empty transport aborts with ABORT_EMPTY_TR.
HandleSm30Popups oSession

' Verdict gate: status bar after Save.
Dim sSaveType, sSaveMsg
On Error Resume Next
sSaveType = oSession.findById("wnd[0]/sbar").MessageType
sSaveMsg = oSession.findById("wnd[0]/sbar").Text
Err.Clear
On Error GoTo 0

WScript.Echo "INFO: Save status: [" & sSaveType & "] " & sSaveMsg
If sSaveType = "E" Or sSaveType = "A" Then
    WScript.Echo "ERROR: SM30 save failed (status-bar type " & sSaveType & "): " & sSaveMsg
    WScript.Quit 1
End If

WScript.Echo "INFO: Records processed: 1"
WScript.Echo "SUCCESS: SM30 maintenance completed for " & TABLE_NAME

' -----------------------------------------------------------------------------
' HandleSm30Popups -- dispatch chained wnd[1] modals by DDIC control id ONLY
' (locale-independent; mirrors shared/scripts/sap_delete_popups.vbs):
'   * transport prompt (ctxtKO008-TRKORR): fill SAP_TRANSPORT + Enter; when
'     SAP_TRANSPORT is empty -> echo ABORT_EMPTY_TR and Quit 1. The TR popup
'     is NEVER blind-Enter'd.
'   * any other popup: Enter (the benign SM30 info popups, e.g. the
'     cross-client caution). Cap 5, then fail loud if a modal persists.
' -----------------------------------------------------------------------------
Sub HandleSm30Popups(oSess)
    Dim iP, oWnd1, oTr
    For iP = 1 To 5
        Set oWnd1 = Nothing
        On Error Resume Next
        Set oWnd1 = oSess.findById("wnd[1]")
        Err.Clear
        On Error GoTo 0
        If oWnd1 Is Nothing Then Exit Sub

        Set oTr = Nothing
        On Error Resume Next
        Set oTr = oSess.findById("wnd[1]/usr/ctxtKO008-TRKORR")
        Err.Clear
        On Error GoTo 0
        If Not (oTr Is Nothing) Then
            If SAP_TRANSPORT = "" Then
                WScript.Echo "ABORT_EMPTY_TR"
                WScript.Echo "ERROR: SAP prompted for a transport request but TRANSPORT is empty."
                WScript.Echo "       Resolve a TR via /sap-transport-request and re-run."
                WScript.Quit 1
            End If
            oTr.Text = SAP_TRANSPORT
            oSess.findById("wnd[1]").sendVKey 0   ' Enter
            WScript.Echo "INFO: Filled transport " & SAP_TRANSPORT & " on wnd[1]."
        Else
            oSess.findById("wnd[1]").sendVKey 0   ' Enter -- non-TR info popup
            WScript.Echo "INFO: Dismissed non-TR popup " & iP & " on wnd[1] (Enter)."
        End If
        WScript.Sleep 800
    Next
    ' Still modal after 5 dismissals -> unknown popup chain; fail loud.
    Dim oStuck
    Set oStuck = Nothing
    On Error Resume Next
    Set oStuck = oSess.findById("wnd[1]")
    Err.Clear
    On Error GoTo 0
    If Not (oStuck Is Nothing) Then
        WScript.Echo "ERROR: A popup is still open after 5 dismiss attempts -- aborting."
        WScript.Quit 1
    End If
End Sub

' -----------------------------------------------------------------------------
' CheckSbarGate -- fail loud on status-bar MessageType E/A (locale-independent).
' -----------------------------------------------------------------------------
Sub CheckSbarGate(oSess, sWhere)
    Dim sT, sM
    On Error Resume Next
    sT = oSess.findById("wnd[0]/sbar").MessageType
    sM = oSess.findById("wnd[0]/sbar").Text
    Err.Clear
    On Error GoTo 0
    If sT = "E" Or sT = "A" Then
        WScript.Echo "ERROR: SM30 rejected the entry " & sWhere & " (status-bar type " & sT & "): " & sM
        WScript.Quit 1
    End If
End Sub
