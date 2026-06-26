' =============================================================================
' sap_se01_delete.vbs  -  Delete an (unreleased) Transport Request via SE01
'
' Deletes the request OBJECT (not release -- releasing would transport the
' request's objects onward). Used by /sap-dev-clean --reset to drop the dev TR
' once Steps 3a-3e have removed every object it held. IRREVERSIBLE -- the caller
' MUST confirm (and check the E071 child list) before invoking this.
'
' TWO-PHASE DELETE (a request that still contains objects cannot be deleted --
' SAP keeps it alive; confirmed live on EC2/ERP 2026-06-22):
'   Phase 1 -- EMPTY THE REQUEST. For every node (request + each task) the
'             script drills in (F2), switches to change mode (tbar[1]/btn[25]),
'             opens the Objects tab, and if the object list is non-empty does
'             Select-All (btnDB_SELECT_ALL) + Delete (btnDB_DELETE) + confirm +
'             Save. This UNASSIGNS the objects from the request (it does NOT
'             delete the repository objects themselves -- they become orphaned,
'             package intact). In the /sap-dev-clean --reset flow Steps 3a-3e
'             have already deleted the objects, so Phase 1 normally finds an
'             empty list and is a no-op safety net. Each removed entry is echoed.
'   Phase 2 -- DELETE THE EMPTY NODES, bottom-up. Delete each TASK node first,
'             then the request itself: focus the node by its TR number, press
'             Delete (tbar[1]/btn[13] = Shift+F1), and let the shared
'             WalkDeletePopups answer the confirm (btnBUTTON_1 / Yes). The
'             request-delete does NOT reliably cascade to its tasks across
'             releases (and some releases refuse to delete a request that still
'             owns a task), so each node is deleted explicitly -- the node-by-node
'             flow from Record_EC2_SE01_DeleteTR001.vbs. Focusing by number (not
'             the recording's fixed lbl[col,row]) keeps it locale-independent.
'
' Tokens replaced at run time:
'   %%TRANSPORT%%   TR number to delete, e.g. "ER1K900234". Required, unreleased.
'   %%SESSION_PATH%% Session path (empty = default).
'   %%ATTACH_LIB_VBS%% / %%SESSION_LOCK_VBS%% shared-script paths.
'
' Pitfalls handled:
'   - A request with objects survives a plain Delete -> Phase 1 empties it first.
'   - A RELEASED request cannot be deleted (only reimported) -> surfaced (the
'     re-display verify catches it; caller should also gate on E070-TRSTATUS).
'   - Node rows identified by TR-number pattern (locale-independent), never by
'     localized column text. Verify by Info.Program, never the localized title.
'   - Delete confirm popups handled by id-gated cascades.
'
' Outputs (last line, parseable):
'   SUCCESS: Transport request <TR> deleted.
'   ERROR:   ...
' =============================================================================

Option Explicit

Const TRANSPORT    = "%%TRANSPORT%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER   = 0
Const VKEY_F2      = 2
Const VKEY_F3_BACK = 3
Const VKEY_SAVE    = 11

Const TR_FIELD       = "wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/ctxtTRDYSE01SN-TR_TRKORR"
Const DISPLAY_BUTTON = "wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/btn%_AUTOTEXT028"
Const DELETE_BUTTON  = "wnd[0]/tbar[1]/btn[13]"   ' Delete (Shift+F1) on the request-display screen
Const CHANGE_BUTTON  = "wnd[0]/tbar[1]/btn[25]"   ' Display <-> Change toggle in the task editor
Const DISPLAY_PROG   = "SAPMSSY0"                 ' program of the request-display screen
Const EDITOR_PROG    = "SAPLSCTSREQ"              ' program of the request/task object editor
Const OBJ_TAB        = "wnd[0]/usr/tabsREQ_TABSTRIP/tabpOBJECTS"
Const OBJ_BASE       = "wnd[0]/usr/tabsREQ_TABSTRIP/tabpOBJECTS/ssubSCREEN_HEADER:SAPLSCTS_OLE:0500/"

' Include shared helpers: attach + session-lock + the post-delete popup walker
' (the walker path is derived from the attach-lib dir; both live in shared/scripts).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()
Dim oDpFso, sDpDir
Set oDpFso = CreateObject("Scripting.FileSystemObject")
sDpDir = oDpFso.GetParentFolderName("%%ATTACH_LIB_VBS%%")
ExecuteGlobal oDpFso.OpenTextFile(oDpFso.BuildPath(sDpDir, "sap_delete_popups.vbs"), 1).ReadAll()

Dim sTR : sTR = UCase(Trim(TRANSPORT))
If sTR = "" Then
    WScript.Echo "ERROR: TRANSPORT is empty. Pass a TR number to delete."
    WScript.Quit 1
End If

' ------ 1. Attach + display the request -------------------------------------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
WScript.Echo "INFO: Deleting transport request " & sTR & "..."
oSess.findById("wnd[0]").maximize

If Not DisplayRequest(oSess, sTR) Then
    Dim sb0 : sb0 = ""
    On Error Resume Next
    sb0 = oSess.findById("wnd[0]/sbar").Text
    On Error GoTo 0
    WScript.Echo "ERROR: Request display did not open for " & sTR & " (it may not exist). PROG=" & _
                 oSess.Info.Program & " sbar=" & sb0
    WScript.Quit 1
End If

' ------ 2. Phase 1: empty the request of objects ----------------------------
' Collect every node (the request itself + each task) by TR-number pattern, then
' clear each one's object list. Re-display before each node so positions/state
' are always fresh (clearing objects does not remove tasks, but re-display keeps
' the walk robust against scroll/refresh).
Dim aNodes, iNode, sNode, nRemoved, nTotalRemoved
aNodes = CollectNodes(oSess, sTR)
WScript.Echo "INFO: Request nodes found: " & (UBound(aNodes) + 1) & " (request + tasks)"
nTotalRemoved = 0
For iNode = 0 To UBound(aNodes)
    sNode = aNodes(iNode)
    If Not DisplayRequest(oSess, sTR) Then
        WScript.Echo "ERROR: Lost the request display while clearing objects."
        WScript.Quit 1
    End If
    nRemoved = ClearNodeObjects(oSess, sTR, sNode)
    If nRemoved > 0 Then nTotalRemoved = nTotalRemoved + nRemoved
Next
If nTotalRemoved > 0 Then
    WScript.Echo "INFO: Phase 1 removed " & nTotalRemoved & " object entr(ies) from " & sTR & _
                 " (objects unassigned, not deleted)."
Else
    WScript.Echo "INFO: Phase 1: request already empty -- nothing to unassign."
End If

' ------ 3. Phase 2: delete nodes bottom-up (each task first, then the request) -
' The request-delete does NOT reliably cascade to its tasks across releases (and
' some releases refuse to delete a request that still owns tasks). So delete each
' TASK node explicitly first, then the request itself -- the node-by-node flow
' from the recorded SE01 empty-TR/task delete (Record_EC2_SE01_DeleteTR001.vbs).
' Nodes are focused by their TR number (locale-independent), never by the fixed
' lbl[col,row] positions of the raw recording, and the request is re-displayed
' fresh before each deletion so the (shifting) layout is always current.
If Not DisplayRequest(oSess, sTR) Then
    WScript.Echo "ERROR: Lost the request display before delete."
    WScript.Quit 1
End If
Dim aDelNodes : aDelNodes = CollectNodes(oSess, sTR)

Dim wasLocked : wasLocked = TryLockSession(oSess)
Dim idx, sNd, nDeleted
nDeleted = 0
' Tasks first (every collected node other than the request itself).
For idx = 0 To UBound(aDelNodes)
    sNd = aDelNodes(idx)
    If sNd <> sTR Then
        If DeleteNodeOnce(oSess, sTR, sNd, "task") Then nDeleted = nDeleted + 1
    End If
Next
' Then the request node last (now task-less).
If DeleteNodeOnce(oSess, sTR, sTR, "request") Then nDeleted = nDeleted + 1
ReleaseSession oSess, wasLocked
WScript.Echo "INFO: Phase 2 deleted " & nDeleted & " node(s) (tasks then request)."

' ------ 4. Verify: re-display; request screen should no longer open ----------
WScript.Echo "INFO: Verifying deletion (try Display again)..."
Dim bStillThere : bStillThere = DisplayRequest(oSess, sTR)

Dim sFinalSbar, sFinalType
sFinalSbar = "" : sFinalType = ""
On Error Resume Next
sFinalSbar = oSess.findById("wnd[0]/sbar").Text
sFinalType = oSess.findById("wnd[0]/sbar").MessageType
On Error GoTo 0

If bStillThere Then
    WScript.Echo "ERROR: TR " & sTR & " still exists after delete (display reopened). sbar=[" & _
                 sFinalType & "] " & sFinalSbar
    oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE01"
    oSess.findById("wnd[0]").sendVKey VKEY_ENTER
    WScript.Quit 1
End If

WScript.Echo "INFO: SAP status: [" & sFinalType & "] " & sFinalSbar
WScript.Echo "SUCCESS: Transport request " & sTR & " deleted."
WScript.Quit 0

' ===========================================================================
' Helpers
' ===========================================================================

' Navigate /nSE01 -> Transport Organizer tab -> enter TR -> Display.
' Returns True when the request-display screen (DISPLAY_PROG) actually opened.
Function DisplayRequest(oS, sReq)
    DisplayRequest = False
    On Error Resume Next
    oS.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE01"
    oS.findById("wnd[0]").sendVKey VKEY_ENTER
    WScript.Sleep 1200
    oS.findById("wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN").select
    WScript.Sleep 300
    oS.findById(TR_FIELD).Text = sReq
    oS.findById(DISPLAY_BUTTON).press
    WScript.Sleep 1500
    Err.Clear
    On Error GoTo 0
    DisplayRequest = (oS.Info.Program = DISPLAY_PROG)
End Function

' Is sText a request/task node number sharing sReq's prefix?
' Standard SAP numbering: <4-char-prefix><6 digits>, e.g. ERPK900033 / ERPK900034.
' Derived from sReq so it is SID-agnostic + locale-independent (digits only).
Function IsNodeNumber(sText, sReq)
    IsNodeNumber = False
    sText = Trim(sText)
    If Len(sText) <> Len(sReq) Then Exit Function
    If Len(sReq) < 5 Then Exit Function
    If UCase(Left(sText, 4)) <> UCase(Left(sReq, 4)) Then Exit Function
    If Not IsNumeric(Mid(sText, 5)) Then Exit Function
    IsNodeNumber = True
End Function

' Collect every node number (request + tasks) from the current request-display
' labels. Returns an array; the request sReq is always first if present.
Function CollectNodes(oS, sReq)
    Dim dict, oUsr, oC, t
    Set dict = CreateObject("Scripting.Dictionary")
    dict.Add sReq, True            ' request itself is always a node
    On Error Resume Next
    Set oUsr = oS.findById("wnd[0]/usr")
    If Not (oUsr Is Nothing) Then
        For Each oC In oUsr.Children
            If oC.Type = "GuiLabel" Then
                t = Trim(oC.Text)
                If IsNodeNumber(t, sReq) Then
                    If Not dict.Exists(t) Then dict.Add t, True
                End If
            End If
        Next
    End If
    Err.Clear
    On Error GoTo 0
    CollectNodes = dict.Keys
End Function

' Focus the GuiLabel whose text = sNode on the current request-display list.
Function FocusNode(oS, sNode)
    Dim oUsr, oC
    FocusNode = False
    On Error Resume Next
    Set oUsr = oS.findById("wnd[0]/usr")
    If Not (oUsr Is Nothing) Then
        For Each oC In oUsr.Children
            If oC.Type = "GuiLabel" Then
                If Trim(oC.Text) = sNode Then
                    oC.setFocus
                    FocusNode = True
                    Exit For
                End If
            End If
        Next
    End If
    Err.Clear
    On Error GoTo 0
End Function

' Clear every object entry from ONE node (task or request). Assumes the request
' is freshly displayed. Returns the count removed (0 if empty / not an editor).
Function ClearNodeObjects(oS, sReq, sNode)
    ClearNodeObjects = 0

    If Not FocusNode(oS, sNode) Then
        WScript.Echo "INFO:   node " & sNode & " not found on display; skip."
        Exit Function
    End If

    ' Drill in (F2 / double-click).
    oS.findById("wnd[0]").sendVKey VKEY_F2
    WScript.Sleep 1200
    If oS.Info.Program <> EDITOR_PROG Then
        WScript.Echo "INFO:   node " & sNode & " did not open the object editor (PROG=" & _
                     oS.Info.Program & "); skip."
        Exit Function
    End If

    ' Switch to change mode so btnDB_DELETE is active (request opened in display).
    On Error Resume Next
    oS.findById(CHANGE_BUTTON).press
    WScript.Sleep 800
    Err.Clear
    On Error GoTo 0

    ' Open the Objects tab so the table control materializes.
    On Error Resume Next
    oS.findById(OBJ_TAB).select
    WScript.Sleep 800
    Err.Clear
    On Error GoTo 0

    ' Object count (txtDV_OBJECT_COUNT). Empty / "0" -> nothing to do.
    Dim sCnt : sCnt = ""
    On Error Resume Next
    sCnt = Trim(oS.findById(OBJ_BASE & "txtDV_OBJECT_COUNT").Text)
    Err.Clear
    On Error GoTo 0
    If sCnt = "" Or sCnt = "0" Then
        WScript.Echo "INFO:   node " & sNode & ": 0 objects."
        Exit Function
    End If
    WScript.Echo "INFO:   node " & sNode & ": " & sCnt & " object(s) -- unassigning..."
    EchoVisibleObjects oS    ' record what is being orphaned (best-effort)

    ' Select all rows + delete.
    On Error Resume Next
    oS.findById(OBJ_BASE & "btnDB_SELECT_ALL").press
    WScript.Sleep 500
    oS.findById(OBJ_BASE & "btnDB_DELETE").press
    WScript.Sleep 800
    Err.Clear
    On Error GoTo 0

    ' Confirm cascade: an info popup (Continue) then a "delete entries?" confirm
    ' (Yes). Each branch gated by control id (locale-independent). Cap 8.
    Dim k
    For k = 1 To 8
        WScript.Sleep 400
        On Error Resume Next
        If InStr(oS.ActiveWindow.Id, "wnd[1]") > 0 Then
            If Not (oS.findById("wnd[1]/usr/btnSPOP-OPTION1", False) Is Nothing) Then
                oS.findById("wnd[1]/usr/btnSPOP-OPTION1").press
            ElseIf Not (oS.findById("wnd[1]/usr/btnBUTTON_1", False) Is Nothing) Then
                oS.findById("wnd[1]/usr/btnBUTTON_1").press
            ElseIf Not (oS.findById("wnd[1]/tbar[0]/btn[0]", False) Is Nothing) Then
                oS.findById("wnd[1]/tbar[0]/btn[0]").press
            Else
                oS.findById("wnd[1]").sendVKey VKEY_ENTER
            End If
            WScript.Sleep 400
            Err.Clear
        Else
            Err.Clear
            Exit For
        End If
        On Error GoTo 0
    Next

    ' Save (the confirm usually commits already; Save is the belt-and-suspenders).
    On Error Resume Next
    oS.findById("wnd[0]").sendVKey VKEY_SAVE
    WScript.Sleep 1200
    For k = 1 To 5
        If InStr(oS.ActiveWindow.Id, "wnd[1]") > 0 Then
            oS.findById("wnd[1]").sendVKey VKEY_ENTER
            WScript.Sleep 300
        Else
            Exit For
        End If
    Next
    Err.Clear
    On Error GoTo 0

    If IsNumeric(sCnt) Then ClearNodeObjects = CLng(sCnt)
End Function

' Echo the object names visible in the table (best-effort record of what is being
' unassigned). Reads the visible rows only; the count line above is authoritative.
Sub EchoVisibleObjects(oS)
    Dim oTbl, nVis, r, sPg, sOb, sNm
    On Error Resume Next
    Set oTbl = oS.findById(OBJ_BASE & "tblSAPLSCTS_OLETC_OLE")
    If Err.Number <> 0 Or oTbl Is Nothing Then Err.Clear : On Error GoTo 0 : Exit Sub
    nVis = oTbl.VisibleRowCount
    If nVis > 24 Then nVis = 24
    For r = 0 To nVis - 1
        sPg = "" : sOb = "" : sNm = ""
        sPg = Trim(oS.findById(OBJ_BASE & "tblSAPLSCTS_OLETC_OLE/ctxtTRE071X-PGMID[1," & r & "]").Text)
        sOb = Trim(oS.findById(OBJ_BASE & "tblSAPLSCTS_OLETC_OLE/ctxtTRE071X-OBJECT[2," & r & "]").Text)
        sNm = Trim(oS.findById(OBJ_BASE & "tblSAPLSCTS_OLETC_OLE/txtTRE071X-OBJ_NAME[3," & r & "]").Text)
        If sNm <> "" Then WScript.Echo "INFO:     - " & sPg & " " & sOb & " " & sNm
        Err.Clear
    Next
    On Error GoTo 0
End Sub

' Delete ONE node (task or request) of sReq. Re-displays the request fresh first
' (positions shift after each deletion), focuses the node by its TR number, presses
' Delete (Shift+F1 = tbar[1]/btn[13]), and answers the confirm chain via the shared
' popup walker (btnBUTTON_1 / btnSPOP-OPTION1 / Enter). Returns True if the node was
' deleted or was already absent; False only on a hard "lost the screen" failure.
Function DeleteNodeOnce(oS, sReq, sNode, sKind)
    DeleteNodeOnce = False
    If Not DisplayRequest(oS, sReq) Then
        ' The request screen no longer opens. For the request node that means it
        ' is already gone (success); for a task it means we lost the display.
        If sKind = "request" Then
            WScript.Echo "INFO:   request " & sReq & " no longer displays (already gone)."
            DeleteNodeOnce = True
        Else
            WScript.Echo "INFO:   could not re-display " & sReq & " to delete node " & sNode & "."
        End If
        Exit Function
    End If
    If Not FocusNode(oS, sNode) Then
        WScript.Echo "INFO:   " & sKind & " node " & sNode & " not present; skip (already deleted)."
        DeleteNodeOnce = True
        Exit Function
    End If
    WScript.Echo "INFO:   deleting " & sKind & " node " & sNode & " (Shift+F1)..."
    On Error Resume Next
    oS.findById(DELETE_BUTTON).press
    WScript.Sleep 1200
    Err.Clear
    On Error GoTo 0
    WalkDeletePopups oS, "", "", ""
    WScript.Sleep 400
    DeleteNodeOnce = True
End Function
