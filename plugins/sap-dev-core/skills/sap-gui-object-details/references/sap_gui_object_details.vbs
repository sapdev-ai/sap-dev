' =============================================================================
' sap_gui_object_details.vbs
' -----------------------------------------------------------------------------
' Inspect components in the currently active SAP GUI session and dump their IDs
' and properties. Multiple modes:
'
'   MODE=tree          Full component tree of the target window(s).
'   MODE=menu          Menu bar tree of the target window (mbar).
'   MODE=type          List only components whose Type matches FILTER (e.g.
'                      "GuiButton", "GuiStatusbar", "GuiShell", "GuiTableControl",
'                      "GuiMenu", "GuiToolbar", "GuiUserArea").
'   MODE=id            Full property dump of one component identified by FILTER
'                      (the absolute or wnd-relative findById path).
'   MODE=wnd           Full component tree of one window only (FILTER = window
'                      index, e.g. "0", "1").
'
' Common to every mode:
'   * The script enumerates wnd[0]..wnd[MAX_POPUP] (default 0..5) when no
'     window scope is specified.
'   * Output is written to OUTPUT_FILE (UTF-16LE / Unicode, with BOM) so
'     non-ASCII screen labels survive round-tripping.
'   * Last line of stdout is "DONE" on success or "ERROR: <text>" on failure.
'
' Tokens (replaced by the calling PowerShell wrapper):
'   %%MODE%%         one of tree | menu | type | id | wnd
'   %%FILTER%%       depends on MODE (see above); empty for tree/menu without
'                    a window scope
'   %%WINDOW%%       optional: window index (0..5) to scope tree/type/menu
'                    modes; empty = all windows
'   %%MAX_DEPTH%%    optional: recursion depth cap; default 10
'   %%OUTPUT_FILE%%  absolute path of the result file
' =============================================================================
Option Explicit

Const DEFAULT_MAX_DEPTH = 10

Dim MODE         : MODE         = "%%MODE%%"
Dim FILTER       : FILTER       = "%%FILTER%%"
Dim WINDOW_IDX   : WINDOW_IDX   = "%%WINDOW%%"
Dim MAX_DEPTH_S  : MAX_DEPTH_S  = "%%MAX_DEPTH%%"
Dim OUTPUT_FILE  : OUTPUT_FILE  = "%%OUTPUT_FILE%%"
Dim SESSION_PATH : SESSION_PATH = "%%SESSION_PATH%%"
' SESSION_PATH defaults to /app/con[0]/ses[0] when the calling wrapper does
' not substitute the token (preserves single-session callers).
If Trim(SESSION_PATH) = "" Or SESSION_PATH = "%%SESSION_PATH%%" Then
    SESSION_PATH = "/app/con[0]/ses[0]"
End If

If Trim(MODE) = "" Then MODE = "tree"
MODE = LCase(Trim(MODE))

Dim MAX_DEPTH
If IsNumeric(MAX_DEPTH_S) And Trim(MAX_DEPTH_S) <> "" Then
    MAX_DEPTH = CInt(MAX_DEPTH_S)
Else
    MAX_DEPTH = DEFAULT_MAX_DEPTH
End If

If Trim(OUTPUT_FILE) = "" Then
    WScript.Echo "ERROR: OUTPUT_FILE is empty."
    WScript.Quit 1
End If

' ---------------------------------------------------------------------------
' Attach to SAP GUI
' ---------------------------------------------------------------------------
Dim oSAPGUI, oApp, oCon, oSes
On Error Resume Next
Set oSAPGUI = GetObject("SAPGUI")
If Err.Number <> 0 Or oSAPGUI Is Nothing Then
    WScript.Echo "ERROR: SAP GUI is not running."
    WScript.Quit 1
End If
Err.Clear
Set oApp = oSAPGUI.GetScriptingEngine
If oApp Is Nothing Then
    WScript.Echo "ERROR: SAP Scripting engine not available (enable in RZ11 sapgui/user_scripting)."
    WScript.Quit 1
End If
' Resolve the target session via SESSION_PATH (e.g. "/app/con[0]/ses[0]").
' Falls back to Children(0).Children(0) only if findById returned Nothing AND
' the path was the default -- avoids silently retargeting when a caller asks
' for a specific session that no longer exists.
On Error Resume Next
Set oSes = oApp.findById(SESSION_PATH, False)
On Error GoTo 0
If oSes Is Nothing Then
    If SESSION_PATH = "/app/con[0]/ses[0]" And oApp.Children.Count > 0 Then
        Set oCon = oApp.Children(0)
        If oCon.Children.Count > 0 Then Set oSes = oCon.Children(0)
    End If
End If
If oSes Is Nothing Then
    WScript.Echo "ERROR: No active SAP GUI session at " & SESSION_PATH
    WScript.Quit 1
End If
' Recover the parent connection from the resolved session id.
Dim sParts : sParts = Split(oSes.Id, "/")
If UBound(sParts) >= 2 Then
    Set oCon = oApp.findById("/" & sParts(1) & "/" & sParts(2), False)
Else
    Set oCon = oApp.Children(0)
End If
On Error GoTo 0

' ---------------------------------------------------------------------------
' Output file (Unicode with BOM so labels in any codepage survive)
' ---------------------------------------------------------------------------
Dim oStream
Set oStream = CreateObject("ADODB.Stream")
oStream.Type = 2          ' adTypeText
oStream.Charset = "Unicode"
oStream.Open

Sub Out(sLine)
    oStream.WriteText sLine, 1   ' adWriteLine (CRLF)
End Sub

' ---------------------------------------------------------------------------
' Header
' ---------------------------------------------------------------------------
Dim sPgm, sTcd, sScr, sUsr, sCli, sSys
On Error Resume Next
sPgm = oSes.Info.Program       : If Err.Number <> 0 Then sPgm = "" : Err.Clear
sTcd = oSes.Info.Transaction   : If Err.Number <> 0 Then sTcd = "" : Err.Clear
sScr = oSes.Info.ScreenNumber  : If Err.Number <> 0 Then sScr = "" : Err.Clear
sUsr = oSes.Info.User          : If Err.Number <> 0 Then sUsr = "" : Err.Clear
sCli = oSes.Info.Client        : If Err.Number <> 0 Then sCli = "" : Err.Clear
sSys = oSes.Info.SystemName    : If Err.Number <> 0 Then sSys = "" : Err.Clear
On Error GoTo 0
Out "SAP GUI Object Details"
Out "Date:        " & Now()
Out "Mode:        " & MODE & "   Filter: [" & FILTER & "]   Window: [" & WINDOW_IDX & "]   MaxDepth: " & MAX_DEPTH
Out "Program:     " & sPgm
Out "Transaction: " & sTcd
Out "Screen:      " & sScr
Out "User:        " & sUsr & "   Client: " & sCli & "   System: " & sSys
Out String(70, "=")

' ---------------------------------------------------------------------------
' Dispatch
' ---------------------------------------------------------------------------
Dim ok : ok = True
Select Case MODE
    Case "tree"
        ForEachWindow GetCallback("DumpTreeForWindow")
    Case "menu"
        ForEachWindow GetCallback("DumpMenuForWindow")
    Case "type"
        If Trim(FILTER) = "" Then
            Out "ERROR: type mode requires a FILTER (e.g. GuiButton)"
            ok = False
        Else
            ForEachWindow GetCallback("DumpTypeForWindow")
        End If
    Case "id"
        If Trim(FILTER) = "" Then
            Out "ERROR: id mode requires a FILTER (the component path)"
            ok = False
        Else
            DumpById FILTER
        End If
    Case "wnd"
        If Trim(WINDOW_IDX) = "" Then WINDOW_IDX = FILTER
        If Trim(WINDOW_IDX) = "" Then
            Out "ERROR: wnd mode requires WINDOW (or FILTER) = window index"
            ok = False
        Else
            DumpTreeForWindow CInt(WINDOW_IDX)
        End If
    Case Else
        Out "ERROR: Unknown MODE '" & MODE & "'. Use tree | menu | type | id | wnd."
        ok = False
End Select

' ---------------------------------------------------------------------------
' Save and exit
' ---------------------------------------------------------------------------
oStream.SaveToFile OUTPUT_FILE, 2   ' adSaveCreateOverWrite
oStream.Close

WScript.Echo "INFO: Output written to " & OUTPUT_FILE
If ok Then
    WScript.Echo "DONE"
Else
    WScript.Quit 1
End If

' =============================================================================
' Window iteration helper (poor-man's first-class function)
' =============================================================================
Function GetCallback(sName)
    GetCallback = sName
End Function

Sub ForEachWindow(sCallbackName)
    ' If a specific window is requested, dump only that one.
    If Trim(WINDOW_IDX) <> "" Then
        InvokeWindowCallback sCallbackName, CInt(WINDOW_IDX)
        Exit Sub
    End If

    ' Otherwise enumerate ALL top-level windows of the session
    ' (oSes.Children gives every wnd[*] currently open — main + popups +
    '  message windows — without us guessing an upper bound).
    Dim oWnd, sId, idx
    On Error Resume Next
    For Each oWnd In oSes.Children
        sId = oWnd.Id
        ' sId looks like ".../wnd[N]" — extract N
        idx = -1
        Dim p1, p2
        p1 = InStrRev(sId, "wnd[")
        If p1 > 0 Then
            p2 = InStr(p1, sId, "]")
            If p2 > p1 Then idx = CInt(Mid(sId, p1 + 4, p2 - p1 - 4))
        End If
        If idx >= 0 Then InvokeWindowCallback sCallbackName, idx
        Err.Clear
    Next
    On Error GoTo 0
End Sub

Sub InvokeWindowCallback(sCallbackName, idx)
    Select Case sCallbackName
        Case "DumpTreeForWindow" : DumpTreeForWindow idx
        Case "DumpMenuForWindow" : DumpMenuForWindow idx
        Case "DumpTypeForWindow" : DumpTypeForWindow idx
    End Select
End Sub

' =============================================================================
' Mode: tree
' =============================================================================
Sub DumpTreeForWindow(iWnd)
    Dim oWnd
    On Error Resume Next
    Set oWnd = oSes.FindById("wnd[" & iWnd & "]")
    If Err.Number <> 0 Or oWnd Is Nothing Then Err.Clear : On Error GoTo 0 : Exit Sub
    On Error GoTo 0
    Out ""
    If iWnd = 0 Then
        Out String(70, "-") & vbCrLf & "MAIN WINDOW wnd[0]   Title: [" & SafeText(oWnd) & "]" & vbCrLf & String(70, "-")
    Else
        Out String(70, "-") & vbCrLf & "POPUP WINDOW wnd[" & iWnd & "]   Title: [" & SafeText(oWnd) & "]" & vbCrLf & String(70, "-")
    End If
    Out FormatNode(oWnd, 0)
    DumpChildren oWnd, 1
End Sub

Sub DumpChildren(oParent, depth)
    If depth > MAX_DEPTH Then Exit Sub
    Dim oChild
    On Error Resume Next
    For Each oChild In oParent.Children
        Out FormatNode(oChild, depth)
        Dim n : n = 0
        n = oChild.Children.Count
        If Err.Number <> 0 Then n = 0 : Err.Clear
        If n > 0 Then DumpChildren oChild, depth + 1
    Next
    On Error GoTo 0
End Sub

' =============================================================================
' Mode: menu
' =============================================================================
Sub DumpMenuForWindow(iWnd)
    Dim oMbar
    On Error Resume Next
    Set oMbar = oSes.FindById("wnd[" & iWnd & "]/mbar")
    If Err.Number <> 0 Or oMbar Is Nothing Then
        Err.Clear : On Error GoTo 0 : Exit Sub
    End If
    On Error GoTo 0
    Out ""
    Out String(70, "-") & vbCrLf & "MENU BAR wnd[" & iWnd & "]/mbar" & vbCrLf & String(70, "-")
    DumpMenuNode oMbar, 0
End Sub

Sub DumpMenuNode(oNode, depth)
    If depth > MAX_DEPTH Then Exit Sub
    Dim oChild
    On Error Resume Next
    For Each oChild In oNode.Children
        Dim sType : sType = oChild.Type
        Dim sText : sText = oChild.Text
        Dim sId   : sId   = oChild.Id
        Dim sShort : sShort = ShortenId(sId)
        Out String(depth * 2, " ") & "[" & sText & "]   " & sType & "   " & sShort
        Dim n : n = 0
        n = oChild.Children.Count
        If Err.Number <> 0 Then n = 0 : Err.Clear
        If n > 0 Then DumpMenuNode oChild, depth + 1
    Next
    On Error GoTo 0
End Sub

' =============================================================================
' Mode: type
' =============================================================================
Sub DumpTypeForWindow(iWnd)
    Dim oWnd
    On Error Resume Next
    Set oWnd = oSes.FindById("wnd[" & iWnd & "]")
    If Err.Number <> 0 Or oWnd Is Nothing Then Err.Clear : On Error GoTo 0 : Exit Sub
    On Error GoTo 0
    Out ""
    Out String(70, "-") & vbCrLf & "MATCHES Type=" & FILTER & " in wnd[" & iWnd & "]" & vbCrLf & String(70, "-")
    Dim cnt : cnt = 0
    cnt = WalkAndMatch(oWnd, 0, cnt)
    Out "TOTAL matches in wnd[" & iWnd & "]: " & cnt
End Sub

Function WalkAndMatch(oParent, depth, runningCount)
    WalkAndMatch = runningCount
    If depth > MAX_DEPTH Then Exit Function
    Dim oChild
    On Error Resume Next
    For Each oChild In oParent.Children
        Dim sType : sType = oChild.Type
        If Err.Number = 0 Then
            If LCase(sType) = LCase(FILTER) Then
                runningCount = runningCount + 1
                Out String(70, ".")
                DumpProperties oChild, "  "
            End If
            Dim n : n = 0
            n = oChild.Children.Count
            If Err.Number <> 0 Then n = 0 : Err.Clear
            If n > 0 Then runningCount = WalkAndMatch(oChild, depth + 1, runningCount)
        End If
        Err.Clear
    Next
    On Error GoTo 0
    WalkAndMatch = runningCount
End Function

' =============================================================================
' Mode: id
' =============================================================================
Sub DumpById(sId)
    Dim oCtrl
    On Error Resume Next
    Set oCtrl = oSes.FindById(sId)
    If Err.Number <> 0 Or oCtrl Is Nothing Then
        Out "ERROR: Component not found: " & sId
        Err.Clear : On Error GoTo 0 : Exit Sub
    End If
    On Error GoTo 0
    Out ""
    Out String(70, "-") & vbCrLf & "COMPONENT " & sId & vbCrLf & String(70, "-")
    DumpProperties oCtrl, ""
    Dim n : n = 0
    On Error Resume Next
    n = oCtrl.Children.Count
    If Err.Number <> 0 Then n = 0 : Err.Clear
    On Error GoTo 0
    If n > 0 Then
        Out ""
        Out "--- Children (" & n & ") ---"
        DumpChildren oCtrl, 1
    End If
End Sub

' =============================================================================
' Property dump — common to type and id modes
' =============================================================================
Sub DumpProperties(oCtrl, sIndent)
    Dim sType, sSub, sId
    sType = SafeProp(oCtrl, "Type")
    sId   = SafeProp(oCtrl, "Id")
    sSub  = SafeProp(oCtrl, "SubType")
    Out sIndent & "Id           = " & sId
    Out sIndent & "Type         = " & sType
    If sSub <> "" Then Out sIndent & "SubType      = " & sSub
    Out sIndent & "Name         = " & SafeProp(oCtrl, "Name")
    Out sIndent & "Text         = " & SafeProp(oCtrl, "Text")
    Out sIndent & "Tooltip      = " & SafeProp(oCtrl, "Tooltip")
    Out sIndent & "Changeable   = " & SafeProp(oCtrl, "Changeable")
    Out sIndent & "IconName     = " & SafeProp(oCtrl, "IconName")

    Select Case sType
        Case "GuiTextField", "GuiCTextField", "GuiPasswordField", "GuiComboBox"
            Out sIndent & "Value        = " & SafeProp(oCtrl, "Value")
            Out sIndent & "MaxLength    = " & SafeProp(oCtrl, "MaxLength")
            Out sIndent & "Required     = " & SafeProp(oCtrl, "Required")
        Case "GuiCheckBox", "GuiRadioButton"
            Out sIndent & "Selected     = " & SafeProp(oCtrl, "Selected")
        Case "GuiButton", "GuiTab", "GuiLabel", "GuiTitlebar"
            ' Already covered above
        Case "GuiStatusbar"
            Out sIndent & "MessageType    = " & SafeProp(oCtrl, "MessageType")
            Out sIndent & "MessageId      = " & SafeProp(oCtrl, "MessageId")
            Out sIndent & "MessageNumber  = " & SafeProp(oCtrl, "MessageNumber")
            Out sIndent & "MessageParam   = " & SafeProp(oCtrl, "MessageParameter")
            Out sIndent & "MessageAsPopup = " & SafeProp(oCtrl, "MessageAsPopup")
            DumpChildList oCtrl, sIndent & "  "
        Case "GuiToolbar", "GuiUserArea", "GuiContainer", "GuiMenubar", "GuiMenu", "GuiSplitterContainer", "GuiSimpleContainer", "GuiTabStrip", "GuiTab", "GuiSubScreen"
            DumpChildList oCtrl, sIndent & "  "
        Case "GuiTableControl"
            Out sIndent & "RowCount        = " & SafeProp(oCtrl, "RowCount")
            Out sIndent & "VisibleRowCount = " & SafeProp(oCtrl, "VisibleRowCount")
            Dim sScrPos, sScrMax
            sScrPos = "" : sScrMax = ""
            On Error Resume Next
            sScrPos = oCtrl.VerticalScrollbar.Position
            If Err.Number <> 0 Then sScrPos = "" : Err.Clear
            sScrMax = oCtrl.VerticalScrollbar.Maximum
            If Err.Number <> 0 Then sScrMax = "" : Err.Clear
            On Error GoTo 0
            Out sIndent & "VerticalScroll  = pos=" & sScrPos & " max=" & sScrMax
            DumpTableColumnHeaders oCtrl, sIndent & "  "
        Case "GuiShell"
            Out sIndent & "Handle       = " & SafeProp(oCtrl, "Handle")
            Out sIndent & "ContType     = " & SafeProp(oCtrl, "ContainerType")
            Select Case sSub
                Case "GridView"
                    Out sIndent & "RowCount       = " & SafeProp(oCtrl, "RowCount")
                    Out sIndent & "ColumnCount    = " & SafeProp(oCtrl, "ColumnCount")
                    Out sIndent & "VisibleRows    = " & SafeProp(oCtrl, "VisibleRowCount")
                    Out sIndent & "Title          = " & SafeProp(oCtrl, "Title")
                    DumpGridColumns oCtrl, sIndent & "  "
                Case "TextEdit", "AbapEditor"
                    Out sIndent & "FirstVisibleLine = " & SafeProp(oCtrl, "FirstVisibleLine")
                    Out sIndent & "LineCount        = " & SafeProp(oCtrl, "LineCount")
                Case "Tree", "ColumnTreeControl", "SimpleTree"
                    DumpTreeNodes oCtrl, sIndent & "  "
            End Select
    End Select
End Sub

Sub DumpChildList(oCtrl, sIndent)
    Dim n : n = 0
    On Error Resume Next
    n = oCtrl.Children.Count
    If Err.Number <> 0 Then n = 0 : Err.Clear
    If n = 0 Then Exit Sub
    Out sIndent & "--- Children (" & n & ") ---"
    Dim i
    For i = 0 To n - 1
        Dim oCh : Set oCh = oCtrl.Children(i)
        If Err.Number = 0 Then
            Out sIndent & "[" & i & "] " & SafeProp(oCh, "Type") & " " & ShortenId(SafeProp(oCh, "Id")) & " text=[" & SafeProp(oCh, "Text") & "]"
        End If
        Err.Clear
    Next
    On Error GoTo 0
End Sub

Sub DumpTableColumnHeaders(oTbl, sIndent)
    Dim n : n = 0
    On Error Resume Next
    n = oTbl.Columns.Count
    If Err.Number <> 0 Then n = 0 : Err.Clear
    If n = 0 Then Exit Sub
    Out sIndent & "--- Columns (" & n & ") ---"
    Dim i
    For i = 0 To n - 1
        Dim sName : sName = oTbl.Columns(i).Name
        If Err.Number <> 0 Then sName = "?" : Err.Clear
        Out sIndent & "[" & i & "] " & sName
    Next
    On Error GoTo 0
End Sub

Sub DumpGridColumns(oGrid, sIndent)
    Dim aCols
    On Error Resume Next
    aCols = oGrid.ColumnOrder
    If Err.Number <> 0 Or Not IsArray(aCols) Then Err.Clear : Exit Sub
    Out sIndent & "--- ColumnOrder (" & (UBound(aCols) + 1) & ") ---"
    Dim i
    For i = 0 To UBound(aCols)
        Dim sTit : sTit = ""
        sTit = oGrid.GetColumnTitles(CStr(aCols(i)))(0)
        If Err.Number <> 0 Then sTit = "" : Err.Clear
        Out sIndent & "[" & i & "] " & aCols(i) & "   title=[" & sTit & "]"
    Next
    On Error GoTo 0
End Sub

Sub DumpTreeNodes(oTree, sIndent)
    Dim aKeys
    On Error Resume Next
    aKeys = oTree.GetAllNodeKeys
    If Err.Number <> 0 Or Not IsArray(aKeys) Then Err.Clear : Exit Sub
    Out sIndent & "--- Tree Nodes (" & (UBound(aKeys) + 1) & ") ---"
    Dim i
    For i = 0 To UBound(aKeys)
        Dim sKey : sKey = aKeys(i)
        Dim sTx  : sTx  = ""
        sTx = oTree.GetNodeTextByKey(sKey)
        If Err.Number <> 0 Then sTx = "" : Err.Clear
        Out sIndent & "[" & sKey & "] " & sTx
    Next
    On Error GoTo 0
End Sub

' =============================================================================
' Common helpers
' =============================================================================
Function FormatNode(oCtrl, depth)
    Dim sPad : sPad = String(depth * 2, " ")
    Dim sType : sType = SafeProp(oCtrl, "Type")
    Dim sId   : sId   = ShortenId(SafeProp(oCtrl, "Id"))
    Dim sExtra : sExtra = NodeSummary(oCtrl, sType)
    If sExtra <> "" Then
        FormatNode = sPad & sType & " | " & sId & " | " & sExtra
    Else
        FormatNode = sPad & sType & " | " & sId
    End If
End Function

Function NodeSummary(oCtrl, sType)
    NodeSummary = ""
    Dim sText, sTip, sSub, sSel, sVal
    Select Case sType
        Case "GuiTextField", "GuiCTextField", "GuiPasswordField", "GuiLabel", "GuiTitlebar", "GuiTab"
            sText = SafeProp(oCtrl, "Text")
            If sText <> "" Then NodeSummary = "text=[" & sText & "]"
        Case "GuiButton"
            sText = SafeProp(oCtrl, "Text")
            sTip  = SafeProp(oCtrl, "Tooltip")
            If sText <> "" And sTip <> "" Then
                NodeSummary = "text=[" & sText & "] tooltip=[" & sTip & "]"
            ElseIf sText <> "" Then
                NodeSummary = "text=[" & sText & "]"
            ElseIf sTip <> "" Then
                NodeSummary = "tooltip=[" & sTip & "]"
            End If
        Case "GuiCheckBox", "GuiRadioButton"
            sSel = SafeProp(oCtrl, "Selected")
            sText = SafeProp(oCtrl, "Text")
            NodeSummary = "selected=" & sSel
            If sText <> "" Then NodeSummary = NodeSummary & " text=[" & sText & "]"
        Case "GuiComboBox"
            sVal = SafeProp(oCtrl, "Value")
            NodeSummary = "value=[" & sVal & "]"
        Case "GuiStatusbar"
            sText = SafeProp(oCtrl, "Text")
            NodeSummary = "msgType=[" & SafeProp(oCtrl, "MessageType") & "] text=[" & sText & "]"
        Case "GuiShell"
            sSub = SafeProp(oCtrl, "SubType")
            If sSub <> "" Then NodeSummary = "subType=[" & sSub & "]"
        Case "GuiMenu"
            sText = SafeProp(oCtrl, "Text")
            If sText <> "" Then NodeSummary = "text=[" & sText & "]"
    End Select
End Function

Function ShortenId(sId)
    ShortenId = sId
    Dim n : n = InStr(sId, "wnd[")
    If n > 1 Then ShortenId = Mid(sId, n)
End Function

Function SafeText(oCtrl)
    SafeText = SafeProp(oCtrl, "Text")
End Function

Function SafeProp(oCtrl, sName)
    SafeProp = ""
    If oCtrl Is Nothing Then Exit Function
    On Error Resume Next
    Dim v
    v = Eval2(oCtrl, sName)
    If Err.Number = 0 And Not IsObject(v) Then SafeProp = CStr(v)
    Err.Clear
    On Error GoTo 0
End Function

' Reflective property fetch via VBScript Eval — we use an embedded
' GetRef-style dispatch table for the small set of properties we touch.
Function Eval2(o, sName)
    On Error Resume Next
    Select Case sName
        Case "Type"             : Eval2 = o.Type
        Case "Id"               : Eval2 = o.Id
        Case "Name"             : Eval2 = o.Name
        Case "Text"             : Eval2 = o.Text
        Case "Tooltip"          : Eval2 = o.Tooltip
        Case "Changeable"       : Eval2 = o.Changeable
        Case "IconName"         : Eval2 = o.IconName
        Case "Value"            : Eval2 = o.Value
        Case "MaxLength"        : Eval2 = o.MaxLength
        Case "Required"         : Eval2 = o.Required
        Case "Selected"         : Eval2 = o.Selected
        Case "SubType"          : Eval2 = o.SubType
        Case "Handle"           : Eval2 = o.Handle
        Case "ContainerType"    : Eval2 = o.ContainerType
        Case "MessageType"      : Eval2 = o.MessageType
        Case "MessageId"        : Eval2 = o.MessageId
        Case "MessageNumber"    : Eval2 = o.MessageNumber
        Case "MessageParameter" : Eval2 = o.MessageParameter
        Case "MessageAsPopup"   : Eval2 = o.MessageAsPopup
        Case "RowCount"         : Eval2 = o.RowCount
        Case "ColumnCount"      : Eval2 = o.ColumnCount
        Case "VisibleRowCount"  : Eval2 = o.VisibleRowCount
        Case "FirstVisibleLine" : Eval2 = o.FirstVisibleLine
        Case "LineCount"        : Eval2 = o.LineCount
        Case "Title"            : Eval2 = o.Title
        Case "Position"         : Eval2 = o.Position
        Case "Maximum"          : Eval2 = o.Maximum
        Case "Info"             : Set Eval2 = o.Info
        Case "Program"          : Eval2 = o.Program
        Case "Transaction"      : Eval2 = o.Transaction
        Case "ScreenNumber"     : Eval2 = o.ScreenNumber
        Case "User"             : Eval2 = o.User
        Case "Client"           : Eval2 = o.Client
        Case "SystemName"       : Eval2 = o.SystemName
        Case "VerticalScrollbar" : Set Eval2 = o.VerticalScrollbar
        Case Else
            ' Unknown property — leave Eval2 empty
    End Select
End Function
