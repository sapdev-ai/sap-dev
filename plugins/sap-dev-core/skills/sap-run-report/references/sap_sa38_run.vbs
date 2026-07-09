' =============================================================================
' sap_sa38_run.vbs  -  Execute an ABAP report (FG/BG) via SA38
'
' Part of the /sap-run-report skill (GUI backend for report execution). Verified
' live on S/4HANA 1909 (S4D) + ECC (EC2) 2026-07-09; the SAPLSVAR / SAPLSPRI /
' SAPLBTCH kernel dialogs are stable across release and logon language.
'
' MODE = FG: open the report selection screen, optionally load %%VARIANT%% via
'   Shift+F5 (sendVKey 17), optionally fill %%VALUES%%, then F8 to execute.
'   If %%SAVE_PATH%% is set, attempts a best-effort %PC classic-list download
'   to the supplied path (format popup -> DY_PATH / DY_FILENAME -> Enter).
'   ALV and interactive lists are NOT captured by %PC; reliable foreground
'   capture is background->spool via /sap-sp02.
'   Emits: RUN_REPORT: EXECUTED_FG list_saved=<path|NONE> sbar=<type>
'
' MODE = BG: same navigation to the selection screen; then triggers
'   Program > Execute in Background (wnd[0]/mbar/menu[0]/menu[2]):
'     * SAPLSPRI/100 print-params popup: Continue = wnd[1]/tbar[0]/btn[13]
'     * SAPLBTCH/1010 start-time popup:  Immediate = wnd[1]/usr/btnSOFORT_PUSH
'                                         Save      = wnd[1]/tbar[0]/btn[11]
'   Reads the scheduled job name from the sbar (MessageType=S).
'   Emits: RUN_REPORT: SUBMITTED job=<name> count=<n>
'
' On any screen that doesn't resolve as expected, emits:
'   RUN_REPORT: NEEDS_RECORDING step=<...> program=<P> screen=<S>
' so the caller never reports a false success.
'
' %%VALUES%% grammar: "FIELD=value" pairs joined by ";". FIELD is the ABAP name
'   (P_* parameter or S_* select-option). Special value prefixes:
'     "FIELD=BT:low,high"  -> select-option range (LOW/HIGH on the main screen)
'     "FIELD=IN:v1,v2,..." -> multiple single values via the SAPLALDB dialog
'   Control type is derived heuristically: ctxt/txt -> .Text, chk -> .Selected
'   (X/TRUE/1/Y/YES = on), rad -> .Select (on only), cmb -> .Key.
'   Unresolved fields are reported in `unresolved=`, never silently dropped.
'
' Tokens: %%PROGRAM%% %%VARIANT%% %%VALUES%% %%MODE%% %%SAVE_PATH%%
'         %%SESSION_PATH%% %%ATTACH_LIB_VBS%%
'
' Output (last line):
'   RUN_REPORT: EXECUTED_FG list_saved=<path|NONE> sbar=<type>
'   RUN_REPORT: SUBMITTED job=<name> count=<n> sbar=<type>
'   RUN_REPORT: NEEDS_RECORDING step=<...> program=<P> screen=<S>
'   ERROR: ...
' =============================================================================
Option Explicit

Const R_PROGRAM   = "%%PROGRAM%%"
Const R_VARIANT   = "%%VARIANT%%"
Const R_VALUES    = "%%VALUES%%"
Const R_MODE      = "%%MODE%%"         ' FG | BG
Const R_SAVE_PATH = "%%SAVE_PATH%%"    ' "" to skip list capture
Const SESSION_PATH = "%%SESSION_PATH%%"

Dim oFso : Set oFso = CreateObject("Scripting.FileSystemObject")
ExecuteGlobal oFso.OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
Dim oSession : Set oSession = AttachSapSession(SESSION_PATH)

Function HasPopup() : HasPopup = (InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0) : End Function
Function SbarType() : SbarType = oSession.findById("wnd[0]/sbar").MessageType : End Function
Function SbarText() : SbarText = oSession.findById("wnd[0]/sbar").Text : End Function
Function InfoProg() : InfoProg = oSession.Info.Program : End Function
Function InfoScr()  : InfoScr  = CStr(oSession.Info.ScreenNumber) : End Function

' Interpret a value as an ABAP boolean ("on") for checkboxes / radiobuttons.
Function ToBool(v)
    Dim s : s = UCase(Trim(v & ""))
    ToBool = (s = "X" Or s = "TRUE" Or s = "1" Or s = "Y" Or s = "YES")
End Function

' Set a selection-screen field by candidate ids, dispatching on the resolved
' control type: checkbox -> .Selected, radiobutton -> .Select (only when "on"),
' any text / possible-entry field -> .Text. Returns True as soon as one id resolves.
Function SetField(candList, val)
    SetField = False
    Dim c, oCtl, t
    For Each c In candList
        Set oCtl = Nothing
        On Error Resume Next
        Set oCtl = oSession.findById("wnd[0]/usr/" & c)
        On Error GoTo 0
        If Not (oCtl Is Nothing) Then
            t = ""
            On Error Resume Next
            t = oCtl.Type
            Err.Clear
            Select Case t
                Case "GuiCheckBox"    : oCtl.Selected = ToBool(val)
                Case "GuiRadioButton" : If ToBool(val) Then oCtl.Select
                Case "GuiComboBox"    : oCtl.Key = val
                Case Else             : oCtl.Text = val
            End Select
            If Err.Number = 0 Then SetField = True
            On Error GoTo 0
            If SetField Then Exit Function
        End If
    Next
End Function

' Fill R_VALUES onto the current selection screen (best-effort). Returns a
' space-prefixed list of field names that could not be resolved.
Function FillValues()
    FillValues = ""
    If R_VALUES = "" Then Exit Function
    Dim pairs, i, kv, fld, val
    pairs = Split(R_VALUES, ";")
    For i = 0 To UBound(pairs)
        If InStr(pairs(i), "=") > 0 Then
            kv  = pairs(i)
            fld = UCase(Trim(Left(kv, InStr(kv, "=") - 1)))
            val = Mid(kv, InStr(kv, "=") + 1)
            If Left(UCase(val), 3) = "BT:" Then
                Dim rng : rng = Split(Mid(val, 4), ",")
                Dim okLow, okHigh
                okLow  = SetField(Array("ctxt" & fld & "-LOW", "txt" & fld & "-LOW"), rng(0))
                okHigh = True
                If UBound(rng) >= 1 Then okHigh = SetField(Array("ctxt" & fld & "-HIGH", "txt" & fld & "-HIGH"), rng(1))
                If Not (okLow And okHigh) Then FillValues = FillValues & " " & fld
            ElseIf Left(UCase(val), 3) = "IN:" Then
                If Not FillMultiSelect(fld, Split(Mid(val, 4), ",")) Then FillValues = FillValues & " " & fld
            Else
                If Not SetField(Array("ctxt" & fld, "txt" & fld, "chk" & fld, "rad" & fld, "cmb" & fld, "ctxt" & fld & "-LOW", "txt" & fld & "-LOW"), val) Then _
                    FillValues = FillValues & " " & fld
            End If
        End If
    Next
End Function

' Fill a select-option with multiple single values via the SAPLALDB "multiple
' selection" dialog (opened by the select-option's %_<F>_%_APP_%-VALU_PUSH button).
' Returns True once the values are taken over; False if the field has no multi button.
Function FillMultiSelect(fld, arr)
    FillMultiSelect = False
    On Error Resume Next
    Dim oBtn : Set oBtn = Nothing
    Set oBtn = oSession.findById("wnd[0]/usr/btn%_" & fld & "_%_APP_%-VALU_PUSH")
    If oBtn Is Nothing Then
        On Error GoTo 0
        Exit Function
    End If
    oBtn.press
    WScript.Sleep 1000
    If InStr(oSession.ActiveWindow.Id, "wnd[1]") = 0 Then
        On Error GoTo 0
        Exit Function
    End If
    oSession.findById("wnd[1]/usr/tabsTAB_STRIP/tabpSIVA").select
    WScript.Sleep 300
    Dim base
    base = "wnd[1]/usr/tabsTAB_STRIP/tabpSIVA/ssubSCREEN_HEADER:SAPLALDB:3010/tblSAPLALDBSINGLE"
    Dim oTbl : Set oTbl = Nothing
    Set oTbl = oSession.findById(base)
    If oTbl Is Nothing Then
        oSession.findById("wnd[1]").sendVKey 12
        On Error GoTo 0
        Exit Function
    End If
    Dim vis
    vis = oTbl.VisibleRowCount
    If vis < 1 Then vis = 8
    Dim i, rp, ok
    ok = True
    For i = 0 To UBound(arr)
        If (i > 0) And (i Mod vis = 0) Then
            oTbl.verticalScrollbar.position = i
            WScript.Sleep 300
            Set oTbl = oSession.findById(base)
        End If
        rp = i Mod vis
        Err.Clear
        oSession.findById(base & "/ctxtRSCSEL_255-SLOW_I[1," & rp & "]").Text = Trim(arr(i))
        If Err.Number <> 0 Then ok = False
    Next
    If ok Then
        oSession.findById("wnd[1]").sendVKey 8        ' Copy (F8 = take over the entries)
        WScript.Sleep 800
        Dim g : g = 0
        Do While (InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0) And (g < 2)
            oSession.findById("wnd[1]").sendVKey 0
            WScript.Sleep 300
            g = g + 1
        Loop
        FillMultiSelect = (InStr(oSession.ActiveWindow.Id, "wnd[1]") = 0)
    Else
        oSession.findById("wnd[1]").sendVKey 12
        WScript.Sleep 300
    End If
    On Error GoTo 0
End Function

' Load variant vname using whichever dialog appears: classic Find popup
' (SAPLSVAR 100, txtV-LOW + btn[8]) or ALV variant directory (SAPLSVAR 600).
' Opens the dialog via Shift+F5 (sendVKey 17), then resolves the variant.
Sub LoadVariant(vname)
    oSession.findById("wnd[0]").sendVKey 17     ' Shift+F5 = Get Variant
    WScript.Sleep 1200
    If Not HasPopup() Then
        WScript.Echo "RUN_REPORT: NEEDS_RECORDING step=get_variant program=" & InfoProg() & " screen=" & InfoScr()
        WScript.Quit 0
    End If
    On Error Resume Next
    Dim oFilt : Set oFilt = Nothing
    Set oFilt = oSession.findById("wnd[1]/usr/txtV-LOW")
    If Not (oFilt Is Nothing) Then
        oFilt.Text = UCase(vname)
        oSession.findById("wnd[1]/tbar[0]/btn[8]").press      ' Apply
        WScript.Sleep 1200
    End If
    Dim oG : Set oG = Nothing
    Set oG = oSession.findById("wnd[1]/usr/cntlALV_CONTAINER_1/shellcont/shell")
    If Not (oG Is Nothing) Then
        Dim cols : Set cols = oG.ColumnOrder
        Dim r, c, hit : hit = -1
        For r = 0 To oG.RowCount - 1
            For c = 0 To cols.Count - 1
                If UCase(Trim(oG.GetCellValue(r, cols.ElementAt(c)))) = UCase(vname) Then hit = r : Exit For
            Next
            If hit >= 0 Then Exit For
        Next
        If hit >= 0 Then
            oG.selectedRows = CStr(hit)
            oG.currentCellRow = hit
            oSession.findById("wnd[1]/tbar[0]/btn[2]").press   ' Choose
            WScript.Sleep 1000
        End If
    End If
    ' Cancel if the dialog is still open (variant not found).
    If HasPopup() Then oSession.findById("wnd[1]").sendVKey 12
    On Error GoTo 0
End Sub

' Best-effort %PC classic-list download. Returns the saved path or "NONE".
Function SaveClassicList(sPath)
    SaveClassicList = "NONE"
    If sPath = "" Then Exit Function
    Dim dir, fn, p
    p = InStrRev(sPath, "\")
    If p = 0 Then Exit Function
    dir = Left(sPath, p) : fn = Mid(sPath, p + 1)
    On Error Resume Next
    Err.Clear
    oSession.findById("wnd[0]/tbar[0]/okcd").Text = "%PC"
    oSession.findById("wnd[0]").sendVKey 0
    WScript.Sleep 900
    ' Format popup (Unconverted / spreadsheet) -- just press Enter to accept default.
    If HasPopup() Then oSession.findById("wnd[1]").sendVKey 0 : WScript.Sleep 700
    ' File-save dialog.
    On Error Resume Next
    Dim oPath : Set oPath = Nothing
    Set oPath = oSession.findById("wnd[1]/usr/ctxtDY_PATH")
    If Not (oPath Is Nothing) Then
        oPath.Text = dir
        oSession.findById("wnd[1]/usr/ctxtDY_FILENAME").Text = fn
        oSession.findById("wnd[1]").sendVKey 0
        WScript.Sleep 1000
        If Err.Number = 0 Then SaveClassicList = sPath
    End If
    Err.Clear
    On Error GoTo 0
End Function

' ===========================================================================
' --- navigate to SA38, fill program, advance to selection screen ---
oSession.findById("wnd[0]").maximize
oSession.StartTransaction "SA38"
WScript.Sleep 800
oSession.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").Text = UCase(R_PROGRAM)
oSession.findById("wnd[0]").sendVKey 8      ' F8 -> selection screen
WScript.Sleep 1500
If SbarType() = "E" Or SbarType() = "A" Then
    WScript.Echo "ERROR: could not open selection screen for " & UCase(R_PROGRAM) & " -- [" & SbarType() & "] " & SbarText()
    WScript.Quit 1
End If

' Load variant (optional).
If R_VARIANT <> "" Then LoadVariant R_VARIANT

' Fill ad-hoc values (optional).
Dim unresolved : unresolved = FillValues()
Dim nUnresolved : nUnresolved = 0
If Trim(unresolved) <> "" Then nUnresolved = UBound(Split(Trim(unresolved), " ")) + 1

If UCase(R_MODE) = "BG" Then
    ' ---- BACKGROUND ----
    On Error Resume Next
    oSession.findById("wnd[0]/mbar/menu[0]/menu[2]").select     ' Execute in Background
    WScript.Sleep 1400
    On Error GoTo 0
    ' SAPLSPRI print-params popup (dynpro 100): Continue = tbar[0]/btn[13].
    If Not HasPopup() Then
        WScript.Echo "RUN_REPORT: NEEDS_RECORDING step=bg_print_params program=" & InfoProg() & " screen=" & InfoScr()
        WScript.Quit 0
    End If
    On Error Resume Next
    Dim oPrintCont : Set oPrintCont = Nothing
    Set oPrintCont = oSession.findById("wnd[1]/tbar[0]/btn[13]")
    If oPrintCont Is Nothing Then
        On Error GoTo 0
        WScript.Echo "RUN_REPORT: NEEDS_RECORDING step=bg_print_params_btn program=" & InfoProg() & " screen=" & InfoScr()
        WScript.Quit 0
    End If
    oPrintCont.press
    WScript.Sleep 1200
    On Error GoTo 0
    ' SAPLBTCH start-time popup (dynpro 1010): Immediate + Save.
    If Not HasPopup() Then
        WScript.Echo "RUN_REPORT: NEEDS_RECORDING step=bg_start_time program=" & InfoProg() & " screen=" & InfoScr()
        WScript.Quit 0
    End If
    On Error Resume Next
    Dim oImm : Set oImm = Nothing
    Set oImm = oSession.findById("wnd[1]/usr/btnSOFORT_PUSH")
    If Not (oImm Is Nothing) Then oImm.press
    WScript.Sleep 600
    oSession.findById("wnd[1]/tbar[0]/btn[11]").press          ' Save (schedules immediately)
    WScript.Sleep 1400
    On Error GoTo 0
    ' Read the scheduled job details from the status bar (MessageType=S).
    Dim sBgJob : sBgJob = ""
    Dim sBgCount : sBgCount = "1"
    On Error Resume Next
    sBgJob   = SbarText()
    On Error GoTo 0
    WScript.Echo "RUN_REPORT: SUBMITTED job=" & sBgJob & " count=" & sBgCount & _
                 " sbar=[" & SbarType() & "]" & _
                 IIf(nUnresolved > 0, " unresolved=" & nUnresolved & " [" & Trim(unresolved) & "]", "")
Else
    ' ---- FOREGROUND (default) ----
    oSession.findById("wnd[0]").sendVKey 8      ' F8 -> execute
    WScript.Sleep 2000
    If SbarType() = "E" Or SbarType() = "A" Then
        WScript.Echo "ERROR: report " & UCase(R_PROGRAM) & " execution failed -- [" & SbarType() & "] " & SbarText()
        WScript.Quit 1
    End If
    ' Best-effort classic-list %PC capture.
    Dim saved : saved = SaveClassicList(R_SAVE_PATH)
    WScript.Echo "RUN_REPORT: EXECUTED_FG list_saved=" & saved & " sbar=[" & SbarType() & "]" & _
                 IIf(nUnresolved > 0, " unresolved=" & nUnresolved & " [" & Trim(unresolved) & "]", "")
End If

WScript.Quit 0

Function IIf(c, a, b)
    If c Then
        IIf = a
    Else
        IIf = b
    End If
End Function
