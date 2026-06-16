' =============================================================================
' sap_syntax_check_lib.vbs
'
' Shared helpers for parsing the SAP syntax-check ALV grid that Ctrl+F2 (and
' Ctrl+F3 pre-activate) produces in SE38 / SE37 / SE24. The grid emits its
' MSGTYPE column as an icon-coded string of the form
'
'     "@<HEX-ID>\Q<localized-label>@"
'
' where the HEX-ID is locale-independent and the label is in the user's
' logon language. Matching only the English literal "ERROR" against MSGTYPE
' (the pre-2026-05-27 behaviour) silently dropped real errors on ZH / JA /
' KO logons — the script reported SYNTAX_ERRORS=0, proceeded to Activate,
' the "Activate anyway?" popup got blind-dismissed, and the verify
' heuristic declared SUCCESS while PROGDIR still showed STATE='I'.
'
' This file centralises the two-tier classifier so every caller stays
' consistent. Included by each caller via:
'
'     ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
'         .OpenTextFile("%%SYNTAX_CHECK_LIB_VBS%%", 1).ReadAll()
'
' Encoding: this source itself is ASCII — non-Latin labels are emitted via
' ChrW() so the file survives re-saving in non-UTF tooling.
' =============================================================================

' -----------------------------------------------------------------------------
' GetSyntaxErrorWord(sLang)
'   Returns the localized word SAP puts in the MSGTYPE icon-string's
'   "\Q<word>@" tail for *errors*, given a SAP logon-language code.
'
'   Inputs: accepts BOTH forms SAP can return from oSession.Info.Language:
'     - 1-char SAP code: E, D, F, S, I, P, 1, M, J, 3, R
'     - 2-char ISO code: EN, DE, FR, ES, IT, PT, ZH, ZF, JA, KO, RU
'   Output: the localized word, or "" when the language is unknown (caller
'           then falls back to the icon-ID match alone).
' -----------------------------------------------------------------------------
Function GetSyntaxErrorWord(sLang)
    Select Case UCase(sLang)
        Case "E", "EN" : GetSyntaxErrorWord = "Error"
        Case "D", "DE" : GetSyntaxErrorWord = "Fehler"
        Case "F", "FR" : GetSyntaxErrorWord = "Erreur"
        Case "S", "ES" : GetSyntaxErrorWord = "Error"
        Case "I", "IT" : GetSyntaxErrorWord = "Errore"
        Case "P", "PT" : GetSyntaxErrorWord = "Erro"
        Case "1", "ZH" : GetSyntaxErrorWord = ChrW(&H9519) & ChrW(&H8BEF)                ' 错误 (zh-CN)
        Case "M", "ZF" : GetSyntaxErrorWord = ChrW(&H932F) & ChrW(&H8AA4)                ' 錯誤 (zh-TW)
        Case "J", "JA" : GetSyntaxErrorWord = ChrW(&H30A8) & ChrW(&H30E9) & ChrW(&H30FC) ' エラー (ja)
        Case "3", "KO" : GetSyntaxErrorWord = ChrW(&HC624) & ChrW(&HB958)                ' 오류 (ko)
        Case "R", "RU" : GetSyntaxErrorWord = ChrW(&H041E) & ChrW(&H0448) & _
                                              ChrW(&H0438) & ChrW(&H0431) & _
                                              ChrW(&H043A) & ChrW(&H0430)                ' Ошибка (ru)
        Case Else      : GetSyntaxErrorWord = ""
    End Select
End Function

' -----------------------------------------------------------------------------
' ExtractIconId(sCell)
'   Parses an icon-coded SAP grid cell of the form "@<HEX-ID>\Q<label>@"
'   and returns the UCase <HEX-ID>. Returns empty string when the cell
'   doesn't carry the SAP icon-string convention.
'
'   Examples:
'     "@5C\Q错误@"   -> "5C"
'     "@03\QError@"  -> "03"
'     "E"            -> ""
'     ""             -> ""
' -----------------------------------------------------------------------------
Function ExtractIconId(sCell)
    ExtractIconId = ""
    If Len(sCell) < 4 Then Exit Function
    If Left(sCell, 1) <> "@" Then Exit Function
    Dim iEnd
    iEnd = InStr(sCell, "\")
    If iEnd = 0 Then iEnd = InStr(2, sCell, "@")
    If iEnd > 2 Then ExtractIconId = UCase(Mid(sCell, 2, iEnd - 2))
End Function

' -----------------------------------------------------------------------------
' IsErrorMsgType(sCell, sLogonLang)
'   True iff a syntax-check grid MSGTYPE cell represents an ERROR (vs a
'   warning / info / continuation row). Two-tier classification:
'
'     1. Legacy ASCII literals "1" / "E" — for grids that surface a
'        bare type letter rather than an icon-string.
'     2. Localized-word match — InStr the cell against
'        GetSyntaxErrorWord(sLogonLang). Primary path on non-EN logons.
'     3. Icon-ID match — extract <HEX-ID> from "@<HEX-ID>\Q...@" and
'        check against {03 ICON_FAILURE, 0A legacy, 5C ICON_LED_RED on
'        S/4HANA 1909, AT / AY ICON_MESSAGE_ERROR}. Locale-independent
'        fallback for icon sets we have not added a localized word for
'        yet.
'
'   Empty cell -> False (continuation/child rows are skipped by design;
'   the parent row already counted).
' -----------------------------------------------------------------------------
Function IsErrorMsgType(sCell, sLogonLang)
    IsErrorMsgType = False
    If sCell = "" Then Exit Function
    If sCell = "1" Or UCase(sCell) = "E" Then IsErrorMsgType = True : Exit Function

    Dim sLocErr : sLocErr = GetSyntaxErrorWord(sLogonLang)
    If Len(sLocErr) > 0 And InStr(sCell, sLocErr) > 0 Then
        IsErrorMsgType = True : Exit Function
    End If

    Dim sIconId : sIconId = ExtractIconId(sCell)
    Select Case sIconId
        Case "03", "0A", "5C", "AT", "AY"
            IsErrorMsgType = True
    End Select
End Function

' -----------------------------------------------------------------------------
' FindSyntaxErrorGrid(oSess)
'   Locate the ABAP-editor syntax-check / activation result grid: a GuiShell
'   with SubType "GridView" that carries a MSGTYPE column. The container PATH
'   is release/build-specific, so callers must NOT hardcode it:
'     - S/4HANA 1909 : wnd[0]/shellcont/shell/shellcont[1]/shell
'     - ECC 6.0      : wnd[0]/shellcont/shell/shellcont[2]/shell/shellcont[0]/shell
'   A hardcoded path silently misses errors on the other release because the
'   wrong container resolves to an empty/different grid -> RowCount 0 -> false
'   "no findings" -> Activate -> false SUCCESS while the program stays INACTIVE
'   (the 2026-06-16 EC6/ER1 incident). This walks the wnd[0]/shellcont subtree
'   and returns the first matching grid, or Nothing. Callers then read
'   getCellValue(row,"MSGTYPE"/"LINE"/"TEXT") and classify MSGTYPE via
'   IsErrorMsgType (above).
' -----------------------------------------------------------------------------
Function FindSyntaxErrorGrid(oSess)
    Set FindSyntaxErrorGrid = Nothing
    On Error Resume Next
    Dim oRoot
    Set oRoot = oSess.findById("wnd[0]/shellcont")
    If Err.Number <> 0 Or oRoot Is Nothing Then
        Err.Clear : On Error GoTo 0 : Exit Function
    End If
    Set FindSyntaxErrorGrid = SyntaxGridWalk_(oRoot, 0)
    Err.Clear
    On Error GoTo 0
End Function

' Depth-first walk; returns the first GridView carrying a MSGTYPE column.
Function SyntaxGridWalk_(oNode, depth)
    Set SyntaxGridWalk_ = Nothing
    On Error Resume Next
    If oNode Is Nothing Then Exit Function
    If depth > 12 Then Exit Function
    If oNode.Type = "GuiShell" Then
        If oNode.SubType = "GridView" Then
            If GridHasColumn_(oNode, "MSGTYPE") Then
                Set SyntaxGridWalk_ = oNode
                Exit Function
            End If
        End If
    End If
    ' Cache the children collection ONCE. Re-reading oNode.Children for the
    ' .Count and then again per index (.Children(k)) invalidates the COM
    ' enumerator on these editor shell containers and throws err 618, so the
    ' walk never descends. Bind it to oKids and index that (.ElementAt).
    Dim oKids, n, k, oChild, oFound
    Set oKids = oNode.Children
    If Err.Number <> 0 Or oKids Is Nothing Then Err.Clear : Exit Function
    n = oKids.Count
    For k = 0 To n - 1
        Set oChild = oKids.ElementAt(k)
        If Err.Number = 0 And Not (oChild Is Nothing) Then
            Set oFound = SyntaxGridWalk_(oChild, depth + 1)
            If Not (oFound Is Nothing) Then
                Set SyntaxGridWalk_ = oFound : Exit Function
            End If
        End If
        Err.Clear
    Next
End Function

' True iff an ALV GridView exposes a column whose technical id = sCol.
Function GridHasColumn_(oGrid, sCol)
    GridHasColumn_ = False
    On Error Resume Next
    Dim oCols, i
    Set oCols = oGrid.ColumnOrder
    If Err.Number <> 0 Or oCols Is Nothing Then Err.Clear : Exit Function
    For i = 0 To oCols.Count - 1
        If UCase(CStr(oCols.ElementAt(i))) = UCase(sCol) Then
            GridHasColumn_ = True : Exit Function
        End If
    Next
    Err.Clear
End Function
