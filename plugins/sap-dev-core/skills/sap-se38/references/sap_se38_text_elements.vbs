' =============================================================================
' SAP SE38 – Update Text Elements (Selection Texts + Text Symbols) for Report Programs
' Template for sap-se38 skill (SAP GUI Scripting, VBScript)
' =============================================================================
' Placeholders:
'   %%PROGRAM_NAME%%    – ABAP program name (UPPERCASE)
'   %%SELECTION_TEXTS%% – Pipe-delimited list: PARAM_NAME=Text|PARAM_NAME=Text|...
'       Example: P_BUKRS=Company Code|P_WERKS=Plant|P_FILE=File path
'   %%TEXT_SYMBOLS%%    – Pipe-delimited list: NNN=Text|NNN=Text|...
'       Example: 001=Selection|002=Result Output|T01=Seq
'       Symbol IDs are 3-character codes (digits or letters); SAP T100A
'       stores them as CHAR3.
'   %%PACKAGE%%         – Package (blank = local)
'   %%TRANSPORT%%       – Transport request (blank = local)
' =============================================================================
Option Explicit

' ---- Constants ----
Const VKEY_ENTER = 0
Const VKEY_F3    = 3
Const VKEY_F11   = 11

Dim PROGRAM_NAME : PROGRAM_NAME = "%%PROGRAM_NAME%%"
Dim SELECTION_TEXTS_RAW : SELECTION_TEXTS_RAW = "%%SELECTION_TEXTS%%"
Dim TEXT_SYMBOLS_RAW : TEXT_SYMBOLS_RAW = "%%TEXT_SYMBOLS%%"
Dim PACKAGE_VAL  : PACKAGE_VAL  = "%%PACKAGE%%"
Dim TRANSPORT_VAL : TRANSPORT_VAL = "%%TRANSPORT%%"
Dim SESSION_PATH : SESSION_PATH = "%%SESSION_PATH%%"   ' empty = default

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

' =============================================================================
' Helper Subs — popup handlers shared by initial Change entry AND re-entry
' (for re-activation pass). Both flows can hit the same SAPLSETX original-
' language popup and the same KO008-TRKORR Workbench-request popup.
' =============================================================================
' VBScript pitfall: a Dim'd-but-unassigned object var is Empty, NOT Nothing.
' If findById() errors under On Error Resume Next, the Set leaves the var as
' Empty — and `Empty Is Nothing` raises "Object required". Every helper below
' explicitly inits its locals to Nothing before any findById call.

Sub HandleOrigLangPopup(oSess)
    Dim oW1, oMaster
    Set oW1     = Nothing
    Set oMaster = Nothing
    On Error Resume Next
    Set oW1     = oSess.findById("wnd[1]")
    Set oMaster = oSess.findById("wnd[1]/usr/ctxtRSETX-MASTERLANG")
    On Error GoTo 0
    If Not (oW1 Is Nothing) And Not (oMaster Is Nothing) Then
        On Error Resume Next
        oSess.findById("wnd[1]/usr/btnPUSH1").press   ' Maint. in orig. lang.
        WScript.Sleep 800
        On Error GoTo 0
        WScript.Echo "INFO: Handled SAPLSETX original-language popup."
    End If
End Sub

Sub HandleTrPopupIfAny(oSess, sTr)
    Dim oW1, oTrField
    Set oW1      = Nothing
    Set oTrField = Nothing
    On Error Resume Next
    Set oW1      = oSess.findById("wnd[1]")
    Set oTrField = oSess.findById("wnd[1]/usr/ctxtKO008-TRKORR")
    On Error GoTo 0
    If Not (oW1 Is Nothing) And Not (oTrField Is Nothing) Then
        If Len(sTr) = 0 Then
            WScript.Echo "ERROR: SAP prompted for TR but TRANSPORT is empty."
            WScript.Echo "TEXT_ELEMENTS: FAILED:TR_REQUIRED_BUT_EMPTY"
            WScript.Quit 1
        End If
        On Error Resume Next
        oSess.findById("wnd[1]/usr/ctxtKO008-TRKORR").Text = sTr
        oSess.findById("wnd[1]").sendVKey 0
        WScript.Sleep 800
        On Error GoTo 0
        WScript.Echo "INFO: Bound text-elements TEXTPOOL to TR " & sTr
    End If
End Sub

' Verify we are on the text-elements editor screen (tabsTX_TABSTR_CONTROL
' exists in usr area). Returns True / False — caller decides whether to
' abort. Used after pressing btnCHAP from the SE38 initial screen.
Function OnTextElementsEditor(oSess)
    Dim oTabStripCheck
    Set oTabStripCheck = Nothing
    On Error Resume Next
    Set oTabStripCheck = oSess.findById("wnd[0]/usr/tabsTX_TABSTR_CONTROL")
    On Error GoTo 0
    OnTextElementsEditor = Not (oTabStripCheck Is Nothing)
End Function

' ---- Parse selection texts into arrays ----
' Format: PARAM_NAME=Selection Text|PARAM_NAME=Text|...
Dim aTexts, nTextCount
If Len(SELECTION_TEXTS_RAW) > 0 Then
    aTexts = Split(SELECTION_TEXTS_RAW, "|")
    nTextCount = UBound(aTexts) + 1
Else
    nTextCount = 0
End If

' ---- Build dictionaries for param name -> text ----
Dim aParamNames(), aParamTexts()
If nTextCount > 0 Then
    ReDim aParamNames(nTextCount - 1)
    ReDim aParamTexts(nTextCount - 1)
    Dim ix, eqPos
    For ix = 0 To nTextCount - 1
        eqPos = InStr(aTexts(ix), "=")
        If eqPos > 0 Then
            aParamNames(ix) = UCase(Trim(Left(aTexts(ix), eqPos - 1)))
            aParamTexts(ix) = Trim(Mid(aTexts(ix), eqPos + 1))
        Else
            aParamNames(ix) = UCase(Trim(aTexts(ix)))
            aParamTexts(ix) = ""
        End If
    Next
End If

' ---- Attach to SAP GUI session (via shared attach helper) ----
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

' ---- Navigate to SE38 ----
oSession.StartTransaction "SE38"
WScript.Sleep 1000

' ---- Enter program name ----
On Error Resume Next
oSession.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").Text = PROGRAM_NAME
Err.Clear
On Error GoTo 0

' ---- Select "Text elements" radio button ----
On Error Resume Next
oSession.findById("wnd[0]/usr/radRS38M-FUNC_TEXT").select
oSession.findById("wnd[0]/usr/radRS38M-FUNC_TEXT").setFocus
Err.Clear
On Error GoTo 0

' ---- Press Change button ----
On Error Resume Next
oSession.findById("wnd[0]/usr/btnCHAP").press
WScript.Sleep 2000
Err.Clear
On Error GoTo 0

' ---- Handle conditional popups (orig-lang, TR) BEFORE asserting screen ----
Call HandleOrigLangPopup(oSession)
Call HandleTrPopupIfAny(oSession, TRANSPORT_VAL)

' ---- Verify we reached the text-elements editor ----
Dim sScreen
sScreen = CStr(oSession.Info.ScreenNumber)
WScript.Echo "INFO: Text Elements screen number: " & sScreen
If Not OnTextElementsEditor(oSession) Then
    WScript.Echo "ERROR: Did not reach text-elements editor after pressing Change."
    WScript.Echo "       ScreenNumber=" & sScreen & "  ActiveWindow=" & oSession.ActiveWindow.Name
    WScript.Echo "TEXT_ELEMENTS: FAILED:CHANGE_DID_NOT_OPEN_EDITOR"
    WScript.Quit 1
End If

' ---- Navigate to Selection Texts tab ----
On Error Resume Next
oSession.findById("wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpSSSS").select
WScript.Sleep 1000
Err.Clear
On Error GoTo 0

WScript.Echo "INFO: Navigated to Selection Texts tab."

' ---- Read the table to find parameter rows ----
' Table path varies by SAP release (sub-screen number after SAPLSETXP differs):
'   SAPLSETXP:1310 -> S/4HANA 1909 (verified)
'   SAPLSETXP:1320 / 1300 -> seen on other releases
' Columns (stable across releases):
'   txtRS38M-STEXTI[0,row] = Parameter name (read-only)
'   txtRS38M-STEXTT[1,row] = Selection text (editable)
'   chkRS38M-STEXTA[2,row] = Dictionary reference checkbox
Dim selBaseCands : selBaseCands = Array( _
    "wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpSSSS/ssubSCREEN_HEADER:SAPLSETXP:1310/tblSAPLSETXPSELPAR", _
    "wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpSSSS/ssubSCREEN_HEADER:SAPLSETXP:1320/tblSAPLSETXPSELPAR", _
    "wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpSSSS/ssubSCREEN_HEADER:SAPLSETXP:1300/tblSAPLSETXPSELPAR")
Dim sTblBase, oTable, iSelC, bFoundSelBase : bFoundSelBase = False
For iSelC = 0 To UBound(selBaseCands)
    sTblBase = selBaseCands(iSelC)
    Set oTable = Nothing
    On Error Resume Next
    Set oTable = oSession.findById(sTblBase)
    On Error GoTo 0
    If IsObject(oTable) And Not (oTable Is Nothing) Then
        bFoundSelBase = True
        WScript.Echo "INFO: Selection-text table at " & sTblBase
        Exit For
    End If
Next

If Not bFoundSelBase Then
    WScript.Echo "ERROR: Cannot find selection-text table on any candidate sub-screen path (tried " & (UBound(selBaseCands)+1) & ")."
    WScript.Echo "       Re-record via /sap-gui-record on SE38 -> Text Elements -> Selection Texts to capture the SAPLSETXP screen number for this release, then add it to selBaseCands."
    WScript.Echo "TEXT_ELEMENTS: FAILED:TABLE_BASE_UNKNOWN"
    WScript.Quit 1
End If

Dim nVisibleRows, nTotalRows
nVisibleRows = oTable.VisibleRowCount
' We need to scan all rows - scroll if needed
' First pass: count total rows by finding parameter names

WScript.Echo "INFO: Table visible rows = " & nVisibleRows

' ---- Set selection texts row by row ----
' We need to iterate through visible rows, check param name, set text if matched
' If there are more rows than visible, we scroll
Dim nRow, nScrollTop, bDone, nMatched, nProcessRow
nMatched = 0
nScrollTop = 0
bDone = False

Do While Not bDone
    ' Set scroll position
    On Error Resume Next
    oTable.VerticalScrollbar.Position = nScrollTop
    WScript.Sleep 500
    Err.Clear
    On Error GoTo 0

    Dim bFoundAny
    bFoundAny = False

    For nRow = 0 To nVisibleRows - 1
        nProcessRow = nRow
        ' Read parameter name from column 0
        Dim sParamId, sParamName, oParamCell
        sParamId = sTblBase & "/txtRS38M-STEXTI[0," & nProcessRow & "]"

        On Error Resume Next
        Set oParamCell = oSession.findById(sParamId)
        If Err.Number <> 0 Then
            Err.Clear
            On Error GoTo 0
            ' No more rows
            bDone = True
            Exit For
        End If
        sParamName = UCase(Trim(oParamCell.Text))
        Err.Clear
        On Error GoTo 0

        If Len(sParamName) = 0 Then
            ' Empty row = end of data
            bDone = True
            Exit For
        End If

        bFoundAny = True

        ' Check if this parameter is in our list
        Dim jj, bFound
        bFound = False
        For jj = 0 To nTextCount - 1
            If aParamNames(jj) = sParamName Then
                bFound = True

                ' Set the selection text
                Dim sTextId
                sTextId = sTblBase & "/txtRS38M-STEXTT[1," & nProcessRow & "]"
                On Error Resume Next
                oSession.findById(sTextId).Text = aParamTexts(jj)
                oSession.findById(sTextId).setFocus
                WScript.Sleep 200
                Err.Clear
                On Error GoTo 0

                WScript.Echo "INFO: Set text for " & sParamName & " = " & aParamTexts(jj)
                nMatched = nMatched + 1
                Exit For
            End If
        Next
    Next

    If Not bDone Then
        ' Check if we found any rows on this page
        If Not bFoundAny Then
            bDone = True
        Else
            ' Scroll down
            nScrollTop = nScrollTop + nVisibleRows
            ' Safety check: if we matched all, stop
            If nMatched >= nTextCount Then
                bDone = True
            End If
        End If
    End If
Loop

' Press Enter to confirm changes
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000

WScript.Echo "INFO: Matched " & nMatched & " of " & nTextCount & " selection texts."

' ---- Switch to Text Symbols tab and apply NNN=text entries ----
' Same TEXTPOOL — saving once persists both Selection Texts AND Text Symbols.
' Tab IDs vary by SAP release; try common candidates.
Dim aSymbols, nSymbolCount, aSymIds(), aSymTexts()
nSymbolCount = 0
If Len(TEXT_SYMBOLS_RAW) > 0 Then
    aSymbols = Split(TEXT_SYMBOLS_RAW, "|")
    nSymbolCount = UBound(aSymbols) + 1
    If nSymbolCount > 0 Then
        ReDim aSymIds(nSymbolCount - 1)
        ReDim aSymTexts(nSymbolCount - 1)
        Dim iy, eqPosY
        For iy = 0 To nSymbolCount - 1
            eqPosY = InStr(aSymbols(iy), "=")
            If eqPosY > 0 Then
                aSymIds(iy)   = UCase(Trim(Left(aSymbols(iy), eqPosY - 1)))
                aSymTexts(iy) = Trim(Mid(aSymbols(iy), eqPosY + 1))
            Else
                aSymIds(iy)   = UCase(Trim(aSymbols(iy)))
                aSymTexts(iy) = ""
            End If
        Next
    End If
End If

If nSymbolCount > 0 Then
    Dim symTabCands : symTabCands = Array( _
        "wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpIIII", _
        "wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpTSYM", _
        "wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpST", _
        "wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpSTSY")
    Dim sSymTab, iCand, bSymTabSet : bSymTabSet = False
    For iCand = 0 To UBound(symTabCands)
        sSymTab = symTabCands(iCand)
        On Error Resume Next
        oSession.findById(sSymTab).select
        WScript.Sleep 800
        If Err.Number = 0 Then
            bSymTabSet = True
            WScript.Echo "INFO: Navigated to Text Symbols tab via " & sSymTab
            Err.Clear
            On Error GoTo 0
            Exit For
        End If
        Err.Clear
        On Error GoTo 0
    Next

    If bSymTabSet Then
        ' Text Symbols table base. Sub-screens vary by SAP release:
        '   SAPLSETXP:1210/tblSAPLSETXPTSYMBOL  -> S/4HANA 1909 (verified) — columns INUM / ITEX132
        '   SAPLSETXP:1320/tblSAPLSETXPTEXTSYM  -> older release  — columns STEXTI / STEXTT
        '   SAPLSETXP:1330/tblSAPLSETXPTEXTSYM  -> alt
        '   SAPLSETXP:1320/tblSAPLSETXPSYMBOL   -> alt
        Dim symBaseCands : symBaseCands = Array( _
            sSymTab & "/ssubSCREEN_HEADER:SAPLSETXP:1210/tblSAPLSETXPTSYMBOL", _
            sSymTab & "/ssubSCREEN_HEADER:SAPLSETXP:1320/tblSAPLSETXPTEXTSYM", _
            sSymTab & "/ssubSCREEN_HEADER:SAPLSETXP:1330/tblSAPLSETXPTEXTSYM", _
            sSymTab & "/ssubSCREEN_HEADER:SAPLSETXP:1320/tblSAPLSETXPSYMBOL")
        Dim sSymBase, iSb, bSymBaseSet : bSymBaseSet = False
        Dim oSymTable
        For iSb = 0 To UBound(symBaseCands)
            sSymBase = symBaseCands(iSb)
            Set oSymTable = Nothing
            On Error Resume Next
            Set oSymTable = oSession.findById(sSymBase)
            On Error GoTo 0
            If IsObject(oSymTable) And Not (oSymTable Is Nothing) Then
                bSymBaseSet = True
                WScript.Echo "INFO: Text Symbols table at " & sSymBase
                Exit For
            End If
        Next

        If bSymBaseSet Then
            ' Column IDs differ by SAP release. Detect from table path.
            Dim sSymIdCol, sSymTextCol
            If InStr(sSymBase, "tblSAPLSETXPTSYMBOL") > 0 Then
                ' S/4HANA 1909
                sSymIdCol   = "txtRS38M-INUM"
                sSymTextCol = "txtRS38M-ITEX132"
            Else
                ' Older releases
                sSymIdCol   = "txtRS38M-STEXTI"
                sSymTextCol = "txtRS38M-STEXTT"
            End If
            WScript.Echo "INFO: Using column ids " & sSymIdCol & " / " & sSymTextCol
            ' Walk symbols. Each row has columns:
            '   <sSymIdCol>[0,row]   = symbol id (3 chars, editable)
            '   <sSymTextCol>[1,row] = symbol text (editable)
            ' We APPEND to the next empty row (one entry per symbol).
            Dim nSymVisible : nSymVisible = oSymTable.VisibleRowCount
            Dim nSymWritten : nSymWritten = 0
            Dim nSymRow, nSymScroll : nSymScroll = 0
            Dim iSym
            For iSym = 0 To nSymbolCount - 1
                If aSymIds(iSym) = "" Then
                    ' skip blank ids
                Else
                    ' Find the next empty row in the table
                    Dim bPlaced : bPlaced = False
                    Dim nFindAttempt
                    For nFindAttempt = 0 To 4
                        On Error Resume Next
                        oSymTable.VerticalScrollbar.Position = nSymScroll
                        WScript.Sleep 300
                        Err.Clear
                        On Error GoTo 0
                        Dim sIdCell, oIdCell, sExisting
                        For nSymRow = 0 To nSymVisible - 1
                            sIdCell = sSymBase & "/" & sSymIdCol & "[0," & nSymRow & "]"
                            sExisting = ""
                            On Error Resume Next
                            sExisting = Trim(oSession.findById(sIdCell).Text)
                            On Error GoTo 0
                            If sExisting = "" Then
                                On Error Resume Next
                                oSession.findById(sIdCell).Text = aSymIds(iSym)
                                oSession.findById(sSymBase & "/" & sSymTextCol & "[1," & nSymRow & "]").Text = aSymTexts(iSym)
                                If Err.Number = 0 Then
                                    nSymWritten = nSymWritten + 1
                                    bPlaced = True
                                    WScript.Echo "INFO: Set symbol " & aSymIds(iSym) & " = " & aSymTexts(iSym)
                                End If
                                Err.Clear
                                On Error GoTo 0
                                Exit For
                            ElseIf UCase(sExisting) = UCase(aSymIds(iSym)) Then
                                ' Existing row with this id — overwrite text only
                                On Error Resume Next
                                oSession.findById(sSymBase & "/" & sSymTextCol & "[1," & nSymRow & "]").Text = aSymTexts(iSym)
                                If Err.Number = 0 Then
                                    nSymWritten = nSymWritten + 1
                                    bPlaced = True
                                    WScript.Echo "INFO: Updated existing symbol " & aSymIds(iSym) & " = " & aSymTexts(iSym)
                                End If
                                Err.Clear
                                On Error GoTo 0
                                Exit For
                            End If
                        Next
                        If bPlaced Then Exit For
                        nSymScroll = nSymScroll + nSymVisible
                    Next
                    If Not bPlaced Then
                        WScript.Echo "WARN: Could not place symbol " & aSymIds(iSym) & " — table full or scroll exhausted."
                    End If
                End If
            Next

            ' Confirm with Enter
            On Error Resume Next
            oSession.findById("wnd[0]").sendVKey VKEY_ENTER
            WScript.Sleep 600
            Err.Clear
            On Error GoTo 0

            WScript.Echo "INFO: Wrote " & nSymWritten & " of " & nSymbolCount & " text symbols."
        Else
            WScript.Echo "WARN: Could not locate Text Symbols table on any candidate path. Symbols not applied."
            WScript.Echo "      Recovery: open SE38 manually, Goto > Text Elements > Text Symbols and add entries."
        End If
    Else
        WScript.Echo "WARN: Could not navigate to Text Symbols tab on this SAP build. Symbols not applied."
        WScript.Echo "      Re-record via /sap-gui-record on SE38 Text Elements -> Text Symbols, then add the tab id to symTabCands above."
    End If
End If

' ---- Save (Ctrl+S = btn[11]) ----
On Error Resume Next
oSession.findById("wnd[0]/tbar[0]/btn[11]").press
WScript.Sleep 2000
Err.Clear
On Error GoTo 0

' Handle transport dialog if it appears (wnd[1])
Dim sSaveScreen
On Error Resume Next
sSaveScreen = CStr(oSession.findById("wnd[1]").ScreenNumber)
Err.Clear
On Error GoTo 0

If Len(sSaveScreen) > 0 Then
    WScript.Echo "INFO: Transport dialog appeared on save."
    If Len(PACKAGE_VAL) > 0 And Len(TRANSPORT_VAL) > 0 Then
        ' Try transport field names in order
        Dim bTransportSet
        bTransportSet = False

        On Error Resume Next
        oSession.findById("wnd[1]/usr/ctxtKO008-TRKORR").Text = TRANSPORT_VAL
        If Err.Number = 0 Then bTransportSet = True
        Err.Clear

        If Not bTransportSet Then
            oSession.findById("wnd[1]/usr/ctxtKORR_TXT-REQ_NUM").Text = TRANSPORT_VAL
            If Err.Number = 0 Then bTransportSet = True
            Err.Clear
        End If

        If Not bTransportSet Then
            oSession.findById("wnd[1]/usr/ctxtKO007-L_REQ").Text = TRANSPORT_VAL
            If Err.Number = 0 Then bTransportSet = True
            Err.Clear
        End If
        On Error GoTo 0

        oSession.findById("wnd[1]").sendVKey VKEY_ENTER
        WScript.Sleep 1000
    Else
        ' Press Enter to accept (local object or auto-transport)
        oSession.findById("wnd[1]").sendVKey VKEY_ENTER
        WScript.Sleep 1000
    End If
End If

WScript.Echo "INFO: Text elements saved."

' ---- Re-enter Change mode for activation ----
' After save, text elements may revert to Display mode. Re-press Change button.
On Error Resume Next
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE38"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000
oSession.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").Text = PROGRAM_NAME
oSession.findById("wnd[0]/usr/radRS38M-FUNC_TEXT").select
oSession.findById("wnd[0]/usr/btnCHAP").press
WScript.Sleep 2000
Err.Clear
On Error GoTo 0

' Re-entry can trigger the same popups as first entry — handle them here too.
Call HandleOrigLangPopup(oSession)
Call HandleTrPopupIfAny(oSession, TRANSPORT_VAL)

' Verify before selecting the tab — if we're not on the editor, abort cleanly
' rather than activating the wrong object.
If Not OnTextElementsEditor(oSession) Then
    WScript.Echo "ERROR: Re-entry to text-elements editor failed before activation."
    WScript.Echo "       ScreenNumber=" & oSession.Info.ScreenNumber & "  ActiveWindow=" & oSession.ActiveWindow.Name
    WScript.Echo "TEXT_ELEMENTS: FAILED:REENTRY_DID_NOT_OPEN_EDITOR"
    WScript.Quit 1
End If

On Error Resume Next
oSession.findById("wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpSSSS").select
WScript.Sleep 1000
Err.Clear
On Error GoTo 0

' ---- Activate (btn[27] = Ctrl+F3) ----
On Error Resume Next
oSession.findById("wnd[0]/tbar[1]/btn[27]").press
WScript.Sleep 4000
Err.Clear
On Error GoTo 0

' Handle activation worklist/confirmation popup (wnd[1])
' May appear as SAPLSPO1, SAPLSEWORKINGAREA (Inactive Objects), or other dialog
Dim sActWnd1, oActW1
Set oActW1 = Nothing
On Error Resume Next
Set oActW1 = oSession.findById("wnd[1]")
On Error GoTo 0
If Not (oActW1 Is Nothing) Then
    sActWnd1 = ""
    On Error Resume Next
    sActWnd1 = oActW1.Text
    On Error GoTo 0
    WScript.Echo "INFO: Activation popup: " & sActWnd1
    ' Check if it has a tab strip (SAPLSEWORKINGAREA "Inactive Objects" dialog)
    ' Note: must reset oTabStrip to Nothing first — findById that fails leaves the
    ' variable with its previous value and Err.Number cannot be trusted on Set lines.
    Dim oTabStrip
    Set oTabStrip = Nothing
    On Error Resume Next
    Set oTabStrip = oSession.findById("wnd[1]/usr/tabsACT_TAB_STRIP")
    On Error GoTo 0
    If Not (oTabStrip Is Nothing) Then
        ' "Inactive Objects" dialog — press Enter to activate all
        WScript.Echo "INFO: Inactive Objects worklist — pressing Enter to activate."
        On Error Resume Next
        oSession.findById("wnd[1]").sendVKey 0
        WScript.Sleep 5000
        On Error GoTo 0
    Else
        ' May be SAPLSPO1 or simple confirmation — try Select All + Enter, fall back to Enter
        On Error Resume Next
        oSession.findById("wnd[1]").sendVKey 9   ' F9 Select All
        WScript.Sleep 500
        oSession.findById("wnd[1]").sendVKey 0   ' Enter
        WScript.Sleep 5000
        On Error GoTo 0
    End If
End If

' Handle any second popup after activation
On Error Resume Next
Dim sActWnd1b
sActWnd1b = CStr(oSession.findById("wnd[1]").ScreenNumber)
Err.Clear
On Error GoTo 0

If Len(sActWnd1b) > 0 Then
    On Error Resume Next
    oSession.findById("wnd[1]").sendVKey 0
    WScript.Sleep 1000
    Err.Clear
    On Error GoTo 0
End If

WScript.Echo "INFO: Text elements activated."

' ---- Navigate back to SE38 initial ----
oSession.findById("wnd[0]/tbar[0]/btn[15]").press
WScript.Sleep 500
oSession.findById("wnd[0]/tbar[0]/btn[15]").press
WScript.Sleep 500

On Error Resume Next
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE38"
oSession.findById("wnd[0]").sendVKey VKEY_ENTER
WScript.Sleep 1000
Err.Clear
On Error GoTo 0

' Emit parseable status line FIRST (callers parse this, not the SUCCESS line).
' Counts:
'   selection_texts = nMatched / nTextCount   (matched in SAP table / supplied)
'   symbols         = nSymWritten / nSymbolCount   (0/0 when symbols block was empty)
Dim nSymWrittenOut, nSymCountOut
If nSymbolCount > 0 Then
    nSymWrittenOut = nSymWritten
    nSymCountOut   = nSymbolCount
Else
    nSymWrittenOut = 0
    nSymCountOut   = 0
End If
WScript.Echo "TEXT_ELEMENTS: APPLIED selection_texts=" & nMatched & "/" & nTextCount & " symbols=" & nSymWrittenOut & "/" & nSymCountOut
WScript.Echo "SUCCESS: Text elements for " & UCase(PROGRAM_NAME) & " updated and activated."
WScript.Quit 0
