' =============================================================================
' sap_sa38_variant.vbs  -  Create/overwrite (SET) or DELETE a report variant via SA38
'
' Part of the /sap-run-report skill (GUI backend for variant maintenance). Verified
' live on S/4HANA 1909 (S4D) 2026-07-09; the underlying dialogs are the core SAPLSVAR
' variant kernel (SAPLSVAR 281 attributes, 322 delete-scope), stable across release and
' logon language (Get/Background flows also verified identical on ECC/EC2 under JA).
'
' MODE = SET: open the report selection screen, fill %%VALUES%% (best-effort field
'   derivation), then Save as Variant (Goto>Variants>Save as Variant):
'     name  -> wnd[0]/usr/ctxtRSVAR-VARIANT
'     text  -> wnd[0]/usr/txtRSVAR-VTEXT
'     bg    -> wnd[0]/usr/chkRSVAR-VBATCH   (when %%BG_ONLY%%=X)
'     save  -> wnd[0]/tbar[0]/btn[11]       (overwrite confirm handled)
' MODE = DELETE: Goto>Variants>Delete -> Find popup (txtV-LOW) -> apply (btn[8])
'     -> scope popup SAPLSVAR 322 Continue (tbar[0]/btn[5]) -> SPOP Yes (btnSPOP-OPTION1).
'
' %%VALUES%% grammar (SET): "FIELD=value" pairs joined by ";". FIELD is the ABAP name
'   (P_* parameter or S_* select-option). Special value prefixes:
'     "FIELD=BT:low,high"  -> a select-option range (LOW/HIGH on the main screen)
'     "FIELD=IN:v1,v2,..." -> multiple single values, entered via the SAPLALDB
'                             "multiple selection" dialog for the select-option
'   Otherwise the control id AND type are derived heuristically: a text / possible-entry
'   input (ctxt<F> / txt<F> / <F>-LOW[/-HIGH]) gets its .Text; a checkbox (chk<F>) has its
'   .Selected set from a boolean value (X/TRUE/1/Y/YES = on, empty/else = off); a
'   radiobutton (rad<F>) is .Select-ed when on; a dropdown/list box (cmb<F>) gets its
'   .Key. A field that does not resolve is reported in `unresolved=`, never silently dropped.
'
' Tokens: %%MODE%% %%PROGRAM%% %%VARIANT%% %%VDESC%% %%VALUES%% %%BG_ONLY%%
'         %%SESSION_PATH%% %%ATTACH_LIB_VBS%%
'
' Output (last line):
'   VARIANT: SET program=<P> variant=<V> unresolved=<n> [fields...]
'   VARIANT: DELETED program=<P> variant=<V>
'   VARIANT: NEEDS_RECORDING step=<...> program=<P> screen=<S>
'   ERROR: ...
' =============================================================================
Option Explicit

Const V_MODE    = "%%MODE%%"          ' SET | DELETE
Const V_PROGRAM = "%%PROGRAM%%"
Const V_VARIANT = "%%VARIANT%%"
Const V_VDESC   = "%%VDESC%%"
Const V_VALUES  = "%%VALUES%%"
Const V_BGONLY  = "%%BG_ONLY%%"       ' "X" to tick "Only for Background Processing"
Const SESSION_PATH = "%%SESSION_PATH%%"

Dim oFso : Set oFso = CreateObject("Scripting.FileSystemObject")
ExecuteGlobal oFso.OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
Dim oSession : Set oSession = AttachSapSession(SESSION_PATH)

Function HasPopup() : HasPopup = (InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0) : End Function
Function SbarType() : SbarType = oSession.findById("wnd[0]/sbar").MessageType : End Function
Function SbarText() : SbarText = oSession.findById("wnd[0]/sbar").Text : End Function
Function InfoProg() : InfoProg = oSession.Info.Program : End Function
Function InfoScr()  : InfoScr = CStr(oSession.Info.ScreenNumber) : End Function

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

' ---- open SA38 selection screen ----
oSession.findById("wnd[0]").maximize
oSession.StartTransaction "SA38"
WScript.Sleep 800
oSession.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").Text = UCase(V_PROGRAM)
oSession.findById("wnd[0]").sendVKey 8
WScript.Sleep 1500
If SbarType() = "E" Or SbarType() = "A" Then
    WScript.Echo "ERROR: could not open selection screen for " & UCase(V_PROGRAM) & " -- [" & SbarType() & "] " & SbarText()
    WScript.Quit 1
End If

If UCase(V_MODE) = "DELETE" Then
    DoDelete
Else
    DoSet
End If
WScript.Quit 0

' ===========================================================================
Sub DoSet()
    Dim unresolved : unresolved = FillValues()

    ' --- Save as Variant ---
    On Error Resume Next
    oSession.findById("wnd[0]/mbar/menu[2]/menu[0]/menu[3]").select
    WScript.Sleep 1400
    On Error GoTo 0
    If InfoProg() <> "SAPLSVAR" Then
        WScript.Echo "VARIANT: NEEDS_RECORDING step=save_as_variant program=" & InfoProg() & " screen=" & InfoScr()
        WScript.Quit 0
    End If
    oSession.findById("wnd[0]/usr/ctxtRSVAR-VARIANT").Text = UCase(V_VARIANT)
    On Error Resume Next
    oSession.findById("wnd[0]/usr/txtRSVAR-VTEXT").Text = V_VDESC
    If V_BGONLY = "X" Then oSession.findById("wnd[0]/usr/chkRSVAR-VBATCH").Selected = True
    Err.Clear
    On Error GoTo 0
    oSession.findById("wnd[0]/tbar[0]/btn[11]").press          ' Save
    WScript.Sleep 1400
    ' Overwrite / mandatory-values / info popups -> confirm (Yes / Enter).
    Dim g : g = 0
    Do While HasPopup() And g < 3
        On Error Resume Next
        oSession.findById("wnd[1]/usr/btnSPOP-OPTION1").press   ' Yes (overwrite)
        If Err.Number <> 0 Then Err.Clear : oSession.findById("wnd[1]").sendVKey 0
        On Error GoTo 0
        WScript.Sleep 600
        g = g + 1
    Loop

    Dim n : n = 0
    If Trim(unresolved) <> "" Then n = UBound(Split(Trim(unresolved), " ")) + 1
    WScript.Echo "VARIANT: SET program=" & UCase(V_PROGRAM) & " variant=" & UCase(V_VARIANT) & _
                 " unresolved=" & n & IIf(n > 0, " [" & Trim(unresolved) & "]", "") & " sbar=[" & SbarType() & "]"
End Sub

' ===========================================================================
Sub DoDelete()
    On Error Resume Next
    ' Fill provided values first -- a report with obligatory fields validates the
    ' selection screen when the Delete menu is chosen (else "fill required fields").
    Dim ign : ign = FillValues()
    oSession.findById("wnd[0]/mbar/menu[2]/menu[0]/menu[2]").select      ' Delete...
    WScript.Sleep 1300
    If Not HasPopup() Then
        On Error GoTo 0
        WScript.Echo "VARIANT: NEEDS_RECORDING step=delete_menu program=" & InfoProg() & " screen=" & InfoScr() & _
                     " sbar=[" & SbarType() & "] " & SbarText()
        WScript.Quit 0
    End If
    ' Select the variant in whichever dialog appears (classic Find 100 or ALV directory 600).
    SelectVariantInDialog UCase(V_VARIANT)
    ' Scope popup (SAPLSVAR 322): keep default (current client), Continue = btn[5]
    If HasPopup() Then
        oSession.findById("wnd[1]/tbar[0]/btn[5]").press
        WScript.Sleep 1200
    End If
    ' SPOP confirm: Yes
    If HasPopup() Then
        Err.Clear
        oSession.findById("wnd[1]/usr/btnSPOP-OPTION1").press
        If Err.Number <> 0 Then Err.Clear : oSession.findById("wnd[1]").sendVKey 0
        WScript.Sleep 1200
    End If
    Dim g : g = 0
    Do While HasPopup() And g < 4 : oSession.findById("wnd[1]").sendVKey 0 : WScript.Sleep 400 : g = g + 1 : Loop
    Err.Clear
    On Error GoTo 0
    ' Success shows sbar S "Variant <V> deleted"; if the variant was absent, sbar carries a W/E.
    If SbarType() = "S" Then
        WScript.Echo "VARIANT: DELETED program=" & UCase(V_PROGRAM) & " variant=" & UCase(V_VARIANT)
    Else
        WScript.Echo "VARIANT: DELETE_UNVERIFIED program=" & UCase(V_PROGRAM) & " variant=" & UCase(V_VARIANT) & _
                     " sbar=[" & SbarType() & "] " & SbarText()
    End If
End Sub

' Fill V_VALUES onto the current selection screen (best-effort). Returns a
' space-prefixed list of field names that could not be resolved.
Function FillValues()
    FillValues = ""
    If V_VALUES = "" Then Exit Function
    Dim pairs, i, kv, fld, val
    pairs = Split(V_VALUES, ";")
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
' Enters each value on the "Select Single Values" tab (tabpSIVA), scrolling the
' table when the value count exceeds the visible rows, then Copies (F8 = take over).
' Control ids verified IDENTICAL on S/4HANA 1909 (S4D) and ECC 7.31 (EC2), 2026-07-09
' (SAPLALDB is a release-stable kernel dialog). Returns True once the values are taken
' over (dialog closed); False (reported unresolved) if the field has no multi button.
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
    ' Ensure the "Select Single Values" (include) tab is active.
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

' Select vname in whichever variant dialog is open: classic Find popup (SAPLSVAR 100,
' txtV-LOW + btn[8]) or ALV variant directory (SAPLSVAR 600, matching row + Choose btn[2]).
Sub SelectVariantInDialog(vname)
    On Error Resume Next
    If InStr(oSession.ActiveWindow.Id, "wnd[1]") = 0 Then Exit Sub
    Dim oFilt : Set oFilt = Nothing
    Set oFilt = oSession.findById("wnd[1]/usr/txtV-LOW")
    If Not (oFilt Is Nothing) Then
        oFilt.Text = vname
        oSession.findById("wnd[1]/tbar[0]/btn[8]").press
        WScript.Sleep 1200
    End If
    Dim oG : Set oG = Nothing
    Set oG = oSession.findById("wnd[1]/usr/cntlALV_CONTAINER_1/shellcont/shell")
    If Not (oG Is Nothing) Then
        Dim cols : Set cols = oG.ColumnOrder
        Dim r, c, hit : hit = -1
        For r = 0 To oG.RowCount - 1
            For c = 0 To cols.Count - 1
                If UCase(Trim(oG.GetCellValue(r, cols.ElementAt(c)))) = vname Then hit = r : Exit For
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
    On Error GoTo 0
End Sub

Function IIf(c, a, b)
    If c Then
        IIf = a
    Else
        IIf = b
    End If
End Function
