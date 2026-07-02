' =============================================================================
' sap_se01_remove_objects.vbs  -  Remove object entries from a TR (keep the TR)
'
' Unassigns objects from an UNRELEASED transport request via SE01 -- it deletes
' the E071 object entries (and the lock they hold) but leaves the request object
' itself ALIVE. This is the surgical complement to sap_se01_delete.vbs (which
' empties AND drops the whole request): here the request survives, only the named
' objects (or all objects) are removed from it.
'
' WHY THIS EXISTS. An object recorded in an unreleased request holds a lock on
' its name. If the object's definition is later deleted (e.g. /sap-se11 delete)
' but its E071 entry lingers in the old request, re-CREATING the object fails
' ("object is in request ...", "enter object only in original request", etc.).
' Removing the lingering E071 entry clears the lock so the name can be recreated.
' /sap-dev-clean calls this on teardown; /sap-dev-init calls it defensively
' before a create that a stale entry would otherwise block.
'
' Removing an E071 entry does NOT delete the repository object -- it only
' unassigns it from the request (the object, if it still exists, becomes a
' package orphan with no transport record). For objects whose definition is
' already gone (the lock-clearing case), there is nothing to orphan.
'
' Tokens replaced at run time:
'   %%TRANSPORT%%      TR number, e.g. "ER1K900234". Required, unreleased.
'   %%OBJECTS%%        Comma-separated OBJ_NAME list to remove (matched
'                      case-insensitively against the E071 OBJ_NAME column),
'                      e.g. "ZCMD_RFCVAL,ZCMDE_RFCVAL". EMPTY = remove ALL
'                      objects from the request (Select-All -- use only when the
'                      caller knows the request holds nothing worth keeping).
'   %%SESSION_PATH%%   Session path (empty = default).
'   %%ATTACH_LIB_VBS%% / %%SESSION_LOCK_VBS%% shared-script paths.
'
' Pitfalls handled:
'   - Objects of a Workbench request live in its TASKS, not the request header,
'     so the script walks the request + every task node (number-pattern matched,
'     locale-independent) and clears each.
'   - btnDB_DELETE is only active in CHANGE mode -> the node is switched to
'     change mode before delete.
'   - The object table is a classic GuiTableControl with empty input rows at the
'     bottom -> the targeted scan is bounded by txtDV_OBJECT_COUNT and skips
'     blank OBJ_NAME cells.
'   - A RELEASED/locked request cannot be edited -> the caller must gate on
'     E070-TRSTATUS; here a refused change-mode switch (sbar E/A), a failed
'     Save, or a post-delete re-read that still shows more objects than
'     expected exits with ERROR (both counts echoed) -- never a false
'     SUCCESS. The removed count is VERIFIED by re-reading the grid count
'     after Save (removed = before - after), not assumed from the number of
'     rows marked before Delete.
'   - Node rows / object names identified by id + DDIC field, never by localized
'     column text.
'
' Outputs (last line, parseable):
'   SUCCESS: Removed <N> object entr(ies) from <TR>.   <- N = verified (before - after)
'   ERROR:   ... (change-mode refused / save failed / count did not drop as
'            expected / count unreadable -- nothing is reported as removed)
' Per-removed-object diagnostic lines:
'   INFO:     - <PGMID> <OBJECT> <OBJ_NAME>
' =============================================================================

Option Explicit

Const TRANSPORT    = "%%TRANSPORT%%"
Const OBJECTS      = "%%OBJECTS%%"        ' comma-separated OBJ_NAME list; empty = ALL
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER   = 0
Const VKEY_F2      = 2
Const VKEY_F3_BACK = 3
Const VKEY_SAVE    = 11

Const TR_FIELD       = "wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/ctxtTRDYSE01SN-TR_TRKORR"
Const DISPLAY_BUTTON = "wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/btn%_AUTOTEXT028"
Const CHANGE_BUTTON  = "wnd[0]/tbar[1]/btn[25]"   ' Display <-> Change toggle in the task editor
Const DISPLAY_PROG   = "SAPMSSY0"                 ' program of the request-display screen
Const EDITOR_PROG    = "SAPLSCTSREQ"              ' program of the request/task object editor
Const OBJ_TAB        = "wnd[0]/usr/tabsREQ_TABSTRIP/tabpOBJECTS"
Const OBJ_BASE       = "wnd[0]/usr/tabsREQ_TABSTRIP/tabpOBJECTS/ssubSCREEN_HEADER:SAPLSCTS_OLE:0500/"
Const OBJ_TABLE      = "wnd[0]/usr/tabsREQ_TABSTRIP/tabpOBJECTS/ssubSCREEN_HEADER:SAPLSCTS_OLE:0500/tblSAPLSCTS_OLETC_OLE"

' Include shared helpers: attach + session-lock (no popup-walker -- the request
' is NOT deleted, so only the per-node object-delete confirm cascade is needed,
' handled inline below by control-id).
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

Dim sTR : sTR = UCase(Trim(TRANSPORT))
If sTR = "" Then
    WScript.Echo "ERROR: TRANSPORT is empty. Pass a TR number."
    WScript.Quit 1
End If

' Build the target-object set. Empty => remove ALL (Select-All).
Dim gTargets, gAll, sObjRaw, aObj, iObj, sOne
Set gTargets = CreateObject("Scripting.Dictionary")
gTargets.CompareMode = 1   ' vbTextCompare -- case-insensitive keys
sObjRaw = Trim(OBJECTS)
' Guard the unsubstituted-token case (Chr(37) so global substitution can't corrupt it).
If sObjRaw = Chr(37) & Chr(37) & "OBJECTS" & Chr(37) & Chr(37) Then sObjRaw = ""
If sObjRaw <> "" Then
    aObj = Split(sObjRaw, ",")
    For iObj = 0 To UBound(aObj)
        sOne = UCase(Trim(aObj(iObj)))
        If sOne <> "" Then
            If Not gTargets.Exists(sOne) Then gTargets.Add sOne, True
        End If
    Next
End If
gAll = (gTargets.Count = 0)

' ------ 1. Attach + display the request -------------------------------------
Dim oSess
Set oSess = AttachSapSession(SESSION_PATH)
If gAll Then
    WScript.Echo "INFO: Removing ALL object entries from transport request " & sTR & "..."
Else
    WScript.Echo "INFO: Removing " & gTargets.Count & " named object(s) from " & sTR & ": " & Join(gTargets.Keys, ", ")
End If
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

' ------ 2. Walk every node (request + tasks) and clear matching objects ------
Dim aNodes, iNode, sNode, nRemoved, nTotalRemoved
aNodes = CollectNodes(oSess, sTR)
WScript.Echo "INFO: Request nodes found: " & (UBound(aNodes) + 1) & " (request + tasks)"

Dim wasLocked : wasLocked = TryLockSession(oSess)

nTotalRemoved = 0
For iNode = 0 To UBound(aNodes)
    sNode = aNodes(iNode)
    If Not DisplayRequest(oSess, sTR) Then
        WScript.Echo "ERROR: Lost the request display while clearing objects."
        ReleaseSession oSess, wasLocked
        WScript.Quit 1
    End If
    nRemoved = ClearNodeObjects(oSess, sNode, gTargets, gAll)
    If nRemoved < 0 Then
        ' ClearNodeObjects already echoed the ERROR (change-mode refused,
        ' save failed, or the post-delete re-read left more objects than
        ' expected). Fail loud -- do NOT report a partial SUCCESS.
        ReleaseSession oSess, wasLocked
        WScript.Quit 1
    End If
    If nRemoved > 0 Then nTotalRemoved = nTotalRemoved + nRemoved
Next

ReleaseSession oSess, wasLocked

' Back to a clean SE01 main screen.
On Error Resume Next
oSess.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE01"
oSess.findById("wnd[0]").sendVKey VKEY_ENTER
On Error GoTo 0

If nTotalRemoved > 0 Then
    WScript.Echo "SUCCESS: Removed " & nTotalRemoved & " object entr(ies) from " & sTR & "."
Else
    If gAll Then
        WScript.Echo "SUCCESS: Removed 0 object entr(ies) from " & sTR & " (request was already empty)."
    Else
        WScript.Echo "SUCCESS: Removed 0 object entr(ies) from " & sTR & " (none of the named objects were in the request)."
    End If
End If
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
Function IsNodeNumber(sText, sReq)
    IsNodeNumber = False
    sText = Trim(sText)
    If Len(sText) <> Len(sReq) Then Exit Function
    If Len(sReq) < 5 Then Exit Function
    If UCase(Left(sText, 4)) <> UCase(Left(sReq, 4)) Then Exit Function
    If Not IsNumeric(Mid(sText, 5)) Then Exit Function
    IsNodeNumber = True
End Function

' Collect every node number (request + tasks) from the current display labels.
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

' Focus the GuiLabel whose text = sNode on the current display list.
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

' Remove matching object entries from ONE node (task or request). Assumes the
' request is freshly displayed. When bAll is True, removes every object
' (Select-All); otherwise removes only rows whose OBJ_NAME is in targets.
' Returns the VERIFIED count removed (before - after re-read of the grid
' count; 0 if empty / no match / not an editor), or -1 on a hard failure
' (change-mode refused, save rejected, count unreadable, or more objects
' remain than expected) -- the ERROR line is echoed here; the caller must
' Quit 1.
Function ClearNodeObjects(oS, sNode, targets, bAll)
    ClearNodeObjects = 0

    If Not FocusNode(oS, sNode) Then
        WScript.Echo "INFO:   node " & sNode & " not found on display; skip."
        Exit Function
    End If

    ' Drill in (F2).
    oS.findById("wnd[0]").sendVKey VKEY_F2
    WScript.Sleep 1200
    If oS.Info.Program <> EDITOR_PROG Then
        WScript.Echo "INFO:   node " & sNode & " did not open the object editor (PROG=" & _
                     oS.Info.Program & "); skip."
        Exit Function
    End If

    ' Switch to change mode so btnDB_DELETE is active. A released / locked
    ' request refuses the switch with a statusbar E/A message (MessageType is
    ' locale-independent) -- fail loud instead of pressing Delete in display
    ' mode and reporting a phantom removal.
    Dim sTogType, sTogText
    sTogType = "" : sTogText = ""
    On Error Resume Next
    oS.findById(CHANGE_BUTTON).press
    WScript.Sleep 800
    sTogType = oS.findById("wnd[0]/sbar").MessageType
    sTogText = oS.findById("wnd[0]/sbar").Text
    Err.Clear
    On Error GoTo 0
    If sTogType = "E" Or sTogType = "A" Then
        WScript.Echo "ERROR: Change-mode switch failed on node " & sNode & _
                     " (request released/locked?) - " & sTogText
        ClearNodeObjects = -1
        Exit Function
    End If

    ' Open the Objects tab so the table control materializes.
    On Error Resume Next
    oS.findById(OBJ_TAB).select
    WScript.Sleep 800
    Err.Clear
    On Error GoTo 0

    ' Object count (txtDV_OBJECT_COUNT). Empty / "0" -> nothing to do.
    Dim sCnt, nCnt : sCnt = ""
    On Error Resume Next
    sCnt = Trim(oS.findById(OBJ_BASE & "txtDV_OBJECT_COUNT").Text)
    Err.Clear
    On Error GoTo 0
    If sCnt = "" Or sCnt = "0" Then
        WScript.Echo "INFO:   node " & sNode & ": 0 objects."
        BackOutEditor oS
        Exit Function
    End If
    nCnt = 0
    If IsNumeric(sCnt) Then nCnt = CLng(sCnt)

    Dim nMarked
    If bAll Then
        WScript.Echo "INFO:   node " & sNode & ": " & sCnt & " object(s) -- removing all..."
        EchoObjects oS, nCnt, Nothing, True
        On Error Resume Next
        oS.findById(OBJ_BASE & "btnDB_SELECT_ALL").press
        WScript.Sleep 500
        Err.Clear
        On Error GoTo 0
        nMarked = nCnt
    Else
        nMarked = MarkTargetRows(oS, nCnt, targets)
        If nMarked = 0 Then
            WScript.Echo "INFO:   node " & sNode & ": none of the named objects present."
            BackOutEditor oS
            Exit Function
        End If
        WScript.Echo "INFO:   node " & sNode & ": removing " & nMarked & " matched object(s)..."
    End If

    ' Delete the selected rows.
    On Error Resume Next
    oS.findById(OBJ_BASE & "btnDB_DELETE").press
    WScript.Sleep 800
    Err.Clear
    On Error GoTo 0

    ' Confirm cascade: optional info popup (Continue) then "delete entries?" (Yes).
    ' Each branch gated by control id (locale-independent). Cap 8.
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

    ' Save (commits the unassignment) + dismiss any post-save popup.
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

    ' Gate on the save outcome (MessageType, locale-independent). An E/A here
    ' means the unassignment was NOT committed.
    Dim sSaveType, sSaveText
    sSaveType = "" : sSaveText = ""
    On Error Resume Next
    sSaveType = oS.findById("wnd[0]/sbar").MessageType
    sSaveText = oS.findById("wnd[0]/sbar").Text
    Err.Clear
    On Error GoTo 0
    If sSaveType = "E" Or sSaveType = "A" Then
        WScript.Echo "ERROR: Save failed on node " & sNode & " after removing " & _
                     nMarked & " object(s) - " & sSaveText
        ClearNodeObjects = -1
        Exit Function
    End If

    ' VERIFY: re-read the remaining object count. A Delete/Save on a released
    ' or locked request (or behind a mis-dismissed popup) is silently ignored
    ' by SAP, so the pre-delete count must never be reported as removed.
    Dim sCntAfter, nAfter, nExpectedAfter, bCntErr
    sCntAfter = "" : bCntErr = False
    On Error Resume Next
    sCntAfter = Trim(oS.findById(OBJ_BASE & "txtDV_OBJECT_COUNT").Text)
    If Err.Number <> 0 Then bCntErr = True
    Err.Clear
    On Error GoTo 0
    If bCntErr Then
        WScript.Echo "ERROR: Could not re-read the object count on node " & sNode & _
                     " after delete (before=" & nCnt & "). Removal NOT verified."
        ClearNodeObjects = -1
        Exit Function
    End If
    nAfter = 0
    If sCntAfter <> "" And IsNumeric(sCntAfter) Then nAfter = CLng(sCntAfter)
    If bAll Then
        nExpectedAfter = 0
    Else
        nExpectedAfter = nCnt - nMarked
    End If
    If nAfter > nExpectedAfter Then
        WScript.Echo "ERROR: node " & sNode & " still holds " & nAfter & " object(s) after " & _
                     "delete+save (before=" & nCnt & ", expected remaining=" & nExpectedAfter & "). " & _
                     "Request may be released/locked -- removal NOT verified."
        ClearNodeObjects = -1
        Exit Function
    End If

    ClearNodeObjects = nCnt - nAfter
End Function

' Scroll the object table and mark every row whose OBJ_NAME is in targets.
' Returns the number of rows marked. Uses GetAbsoluteRow(i).Selected so the
' selection survives scrolling; bounded by the object count nCnt.
Function MarkTargetRows(oS, nCnt, targets)
    Dim oTbl, nVis, top, r, absIdx, sName, sPg, sOb, marked
    marked = 0
    On Error Resume Next
    Set oTbl = oS.findById(OBJ_TABLE)
    If Err.Number <> 0 Or oTbl Is Nothing Then
        Err.Clear : On Error GoTo 0
        MarkTargetRows = 0
        Exit Function
    End If
    nVis = oTbl.VisibleRowCount
    If nVis < 1 Then nVis = 1
    On Error GoTo 0

    top = 0
    Do While top < nCnt
        On Error Resume Next
        Set oTbl = oS.findById(OBJ_TABLE)
        oTbl.VerticalScrollbar.Position = top
        WScript.Sleep 200
        Set oTbl = oS.findById(OBJ_TABLE)
        nVis = oTbl.VisibleRowCount
        On Error GoTo 0
        For r = 0 To nVis - 1
            absIdx = top + r
            If absIdx >= nCnt Then Exit For
            sName = "" : sPg = "" : sOb = ""
            On Error Resume Next
            sName = Trim(oS.findById(OBJ_TABLE & "/txtTRE071X-OBJ_NAME[3," & r & "]").Text)
            sPg   = Trim(oS.findById(OBJ_TABLE & "/ctxtTRE071X-PGMID[1," & r & "]").Text)
            sOb   = Trim(oS.findById(OBJ_TABLE & "/ctxtTRE071X-OBJECT[2," & r & "]").Text)
            On Error GoTo 0
            If sName <> "" Then
                If targets.Exists(UCase(sName)) Then
                    On Error Resume Next
                    oS.findById(OBJ_TABLE).GetAbsoluteRow(absIdx).Selected = True
                    If Err.Number = 0 Then
                        marked = marked + 1
                        WScript.Echo "INFO:     - " & sPg & " " & sOb & " " & sName
                    End If
                    Err.Clear
                    On Error GoTo 0
                End If
            End If
        Next
        top = top + nVis
    Loop
    MarkTargetRows = marked
End Function

' Best-effort echo of the visible object rows (used for the Select-All path so the
' operator still sees what was unassigned). The count is authoritative; this only
' records the first screenful.
Sub EchoObjects(oS, nCnt, targets, bAll)
    Dim oTbl, nVis, r, sPg, sOb, sNm
    On Error Resume Next
    Set oTbl = oS.findById(OBJ_TABLE)
    If Err.Number <> 0 Or oTbl Is Nothing Then Err.Clear : On Error GoTo 0 : Exit Sub
    nVis = oTbl.VisibleRowCount
    If nVis > 24 Then nVis = 24
    For r = 0 To nVis - 1
        sPg = "" : sOb = "" : sNm = ""
        sPg = Trim(oS.findById(OBJ_TABLE & "/ctxtTRE071X-PGMID[1," & r & "]").Text)
        sOb = Trim(oS.findById(OBJ_TABLE & "/ctxtTRE071X-OBJECT[2," & r & "]").Text)
        sNm = Trim(oS.findById(OBJ_TABLE & "/txtTRE071X-OBJ_NAME[3," & r & "]").Text)
        If sNm <> "" Then WScript.Echo "INFO:     - " & sPg & " " & sOb & " " & sNm
        Err.Clear
    Next
    On Error GoTo 0
End Sub

' Leave the change-mode editor without saving (no change was made) so the next
' DisplayRequest navigates cleanly. F3 backs out; dismiss any stray popup.
Sub BackOutEditor(oS)
    Dim k
    On Error Resume Next
    oS.findById("wnd[0]").sendVKey VKEY_F3_BACK
    WScript.Sleep 600
    For k = 1 To 3
        If InStr(oS.ActiveWindow.Id, "wnd[1]") > 0 Then
            ' "Data will be lost?" style -> No change was made, but answer to leave.
            If Not (oS.findById("wnd[1]/usr/btnSPOP-OPTION1", False) Is Nothing) Then
                oS.findById("wnd[1]/usr/btnSPOP-OPTION1").press
            Else
                oS.findById("wnd[1]").sendVKey VKEY_ENTER
            End If
            WScript.Sleep 300
        Else
            Exit For
        End If
    Next
    Err.Clear
    On Error GoTo 0
End Sub
