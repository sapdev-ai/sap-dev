' =============================================================================
' sap_gui_probe_action.vbs
' -----------------------------------------------------------------------------
' Action primitive for the sap-gui-probe skill. Reads a small JSON file
' describing one SAP GUI action and executes it against the currently active
' SAP GUI session.
'
' Usage:
'   cscript //NoLogo sap_gui_probe_action.vbs <action.json>
'
' Action JSON schema (flat, all optional except verb + target):
'   {
'     "verb":   "SET_TEXT" | "SEND_VKEY" | "PRESS" | "SELECT" | "SELECT_ROW" |
'               "DOUBLE_CLICK" | "SET_OKCD",
'     "target": "wnd[0]/usr/ctxtRMMG1-MATNR",
'     "value":  "ZHKAMATVer7001",   // SET_TEXT / SET_OKCD / SELECT (checkbox)
'     "vkey":   0,                   // SEND_VKEY
'     "row":    0,                   // SELECT_ROW (uses getAbsoluteRow(n))
'     "sleep":  800,                 // optional ms after action; default 800
'     "note":   "free text"          // ignored at runtime
'   }
'
' Verb notes:
'   PRESS    -- auto-dispatches by control type: GuiRadioButton -> .Select,
'               GuiCheckBox -> Selected=True, everything else -> .press.
'               Safe default when the caller does not know the type.
'   SELECT   -- explicit selection verb. Radios always select on; check
'               boxes honour "value" ("true"/"x"/"1"/"" = on, anything
'               else = off). Falls back to .press for unknown types.
'
' Output:
'   Last line is "DONE" on success or "ERROR: <text>" on failure.
'
' JSON parsing is intentionally minimal -- a regex extractor for the flat
' schema above. Embedded escaped quotes in string values are NOT supported;
' the caller (Claude via SKILL.md Step 2.3) is expected to emit clean values.
' =============================================================================
Option Explicit

If WScript.Arguments.Count < 1 Then
    WScript.Echo "ERROR: missing action.json path"
    WScript.Quit 1
End If

Dim sActionPath : sActionPath = WScript.Arguments(0)

Dim oFso : Set oFso = CreateObject("Scripting.FileSystemObject")
If Not oFso.FileExists(sActionPath) Then
    WScript.Echo "ERROR: action.json not found: " & sActionPath
    WScript.Quit 1
End If

' Read as UTF-8 via ADODB.Stream -- the orchestrator may write the JSON file
' via Write tool (no BOM, UTF-8) or via Set-Content -Encoding Unicode (with
' BOM). ADODB.Stream with Charset="utf-8" handles both: UTF-16 BOM-prefixed
' files are decoded correctly because ADODB sniffs the BOM, and BOM-less
' UTF-8 is the default path.
Function ReadJsonFile(sPath)
    Dim s : Set s = CreateObject("ADODB.Stream")
    s.Type    = 2   ' adTypeText
    s.Charset = "utf-8"
    s.Open
    s.LoadFromFile sPath
    ReadJsonFile = s.ReadText()
    s.Close
End Function

Dim sJson : sJson = ReadJsonFile(sActionPath)

' --- Flat-JSON regex extractors -------------------------------------------------
Function ExtractStr(json, key)
    Dim re : Set re = New RegExp
    re.Pattern   = """" & key & """\s*:\s*""([^""]*)"""
    re.Global    = False
    re.IgnoreCase = False
    Dim m : Set m = re.Execute(json)
    If m.Count > 0 Then
        ExtractStr = m(0).SubMatches(0)
    Else
        ExtractStr = ""
    End If
End Function

Function ExtractInt(json, key, defaultVal)
    Dim re : Set re = New RegExp
    re.Pattern   = """" & key & """\s*:\s*(-?\d+)"
    re.Global    = False
    re.IgnoreCase = False
    Dim m : Set m = re.Execute(json)
    If m.Count > 0 Then
        ExtractInt = CInt(m(0).SubMatches(0))
    Else
        ExtractInt = defaultVal
    End If
End Function

Dim sVerb    : sVerb    = UCase(ExtractStr(sJson, "verb"))
Dim sTarget  : sTarget  = ExtractStr(sJson, "target")
Dim sValue   : sValue   = ExtractStr(sJson, "value")
Dim nVkey    : nVkey    = ExtractInt(sJson, "vkey", -9999)
Dim nRow     : nRow     = ExtractInt(sJson, "row",  -9999)
Dim nSleep   : nSleep   = ExtractInt(sJson, "sleep", 800)
' Optional session path -- enables one cscript per session for parallel probes.
' Empty = default to first connection / first session (preserves single-session
' behaviour). Format: "/app/con[0]/ses[1]".
Dim sSession : sSession = ExtractStr(sJson, "session")

If sVerb = "" Then
    WScript.Echo "ERROR: action.json missing 'verb'"
    WScript.Quit 1
End If

' --- Attach to active SAP GUI session ------------------------------------------
Dim oSAP, oApp, oCon, oSess
On Error Resume Next
Set oSAP = GetObject("SAPGUI")
If Err.Number <> 0 Or oSAP Is Nothing Then
    WScript.Echo "ERROR: SAP GUI not running (GetObject(""SAPGUI"") failed)"
    WScript.Quit 2
End If
Set oApp = oSAP.GetScriptingEngine
If Err.Number <> 0 Or oApp Is Nothing Then
    WScript.Echo "ERROR: SAP GUI scripting engine unavailable"
    WScript.Quit 2
End If
On Error GoTo 0

If oApp.Children.Count = 0 Then
    WScript.Echo "ERROR: no SAP GUI connection (run /sap-login first)"
    WScript.Quit 2
End If

' Resolve target session. Priority:
'   1) action JSON's "session" field (explicit pin from parallel scaffolder)
'   2) default first connection / first session (backwards-compatible)
If Len(Trim(sSession)) > 0 Then
    On Error Resume Next
    Set oSess = oApp.findById(sSession, False)
    On Error GoTo 0
    If oSess Is Nothing Then
        WScript.Echo "ERROR: action 'session' path not found: " & sSession
        WScript.Quit 2
    End If
    ' Walk up to the connection from the session id.
    Dim partsS : partsS = Split(oSess.Id, "/")
    If UBound(partsS) >= 2 Then
        Set oCon = oApp.findById("/" & partsS(1) & "/" & partsS(2), False)
    Else
        Set oCon = oApp.Children(0)
    End If
Else
    Set oCon = oApp.Children(0)
    If oCon.Children.Count = 0 Then
        WScript.Echo "ERROR: SAP GUI connection has no session"
        WScript.Quit 2
    End If
    Set oSess = oCon.Children(0)
End If

' --- Dispatch -------------------------------------------------------------------
Dim sErr : sErr = ""

On Error Resume Next
Select Case sVerb

    Case "SET_TEXT"
        If sTarget = "" Then sErr = "SET_TEXT requires 'target'"
        If sErr = "" Then
            oSess.findById(sTarget).Text = sValue
            If Err.Number <> 0 Then sErr = "findById/Text failed: " & Err.Description
        End If

    Case "SET_OKCD"
        ' Convenience: target defaults to wnd[0]/tbar[0]/okcd
        If sTarget = "" Then sTarget = "wnd[0]/tbar[0]/okcd"
        oSess.findById(sTarget).Text = sValue
        If Err.Number <> 0 Then
            sErr = "set okcd failed: " & Err.Description
        Else
            oSess.findById("wnd[0]").sendVKey 0
            If Err.Number <> 0 Then sErr = "okcd Enter failed: " & Err.Description
        End If

    Case "SEND_VKEY"
        If nVkey = -9999 Then sErr = "SEND_VKEY requires 'vkey'"
        If sErr = "" Then
            ' target defaults to wnd[0]
            If sTarget = "" Then sTarget = "wnd[0]"
            oSess.findById(sTarget).sendVKey nVkey
            If Err.Number <> 0 Then sErr = "sendVKey " & nVkey & " failed: " & Err.Description
        End If

    Case "PRESS"
        If sTarget = "" Then sErr = "PRESS requires 'target'"
        If sErr = "" Then
            ' GuiRadioButton does not expose .press at the COM level -- the
            ' call raises "object doesn't support this property or method".
            ' Discriminate by control type so the caller's intent ("press
            ' this thing") works on radios without forcing them to a
            ' different verb. GuiCheckBox is treated as "tick" (Selected =
            ' True) -- caller can use the SELECT verb with an explicit
            ' value for nuance.
            Dim oCtrl, sCtrlType
            Err.Clear
            Set oCtrl = oSess.findById(sTarget)
            If Err.Number <> 0 Then
                sErr = "findById failed: " & Err.Description
            Else
                sCtrlType = ""
                Err.Clear
                sCtrlType = oCtrl.Type
                If Err.Number <> 0 Then
                    sCtrlType = ""
                    Err.Clear
                End If
                If sCtrlType = "GuiRadioButton" Then
                    oCtrl.Select
                    If Err.Number <> 0 Then sErr = "select (radio) failed: " & Err.Description
                ElseIf sCtrlType = "GuiCheckBox" Then
                    oCtrl.Selected = True
                    If Err.Number <> 0 Then sErr = "set (checkbox) failed: " & Err.Description
                Else
                    oCtrl.press
                    If Err.Number <> 0 Then sErr = "press failed: " & Err.Description
                End If
            End If
        End If

    Case "SELECT"
        ' Explicit selection verb -- prefer over PRESS when the target is
        ' known to be a radio / checkbox. Honours an optional "value" of
        ' "true" / "false" / "x" / "1" / "" for check boxes (default True).
        ' Radio buttons always select on; the framework does not surface a
        ' "deselect radio" operation.
        If sTarget = "" Then sErr = "SELECT requires 'target'"
        If sErr = "" Then
            Dim oSCtrl, sSCtrlType, sWant
            Err.Clear
            Set oSCtrl = oSess.findById(sTarget)
            If Err.Number <> 0 Then
                sErr = "findById failed: " & Err.Description
            Else
                sSCtrlType = ""
                Err.Clear
                sSCtrlType = oSCtrl.Type
                If Err.Number <> 0 Then
                    sSCtrlType = ""
                    Err.Clear
                End If
                If sSCtrlType = "GuiRadioButton" Then
                    oSCtrl.Select
                    If Err.Number <> 0 Then sErr = "select (radio) failed: " & Err.Description
                ElseIf sSCtrlType = "GuiCheckBox" Then
                    sWant = LCase(Trim(sValue))
                    If sWant = "" Or sWant = "true" Or sWant = "x" Or sWant = "1" Then
                        oSCtrl.Selected = True
                    Else
                        oSCtrl.Selected = False
                    End If
                    If Err.Number <> 0 Then sErr = "set (checkbox) failed: " & Err.Description
                Else
                    ' Unknown control type for SELECT -- fall back to .press
                    ' so the verb still has a defined behaviour.
                    oSCtrl.press
                    If Err.Number <> 0 Then sErr = "SELECT fallback press failed (type=" & sSCtrlType & "): " & Err.Description
                End If
            End If
        End If

    Case "SELECT_ROW"
        If sTarget = "" Then sErr = "SELECT_ROW requires 'target' (table control id)"
        If nRow = -9999 Then sErr = "SELECT_ROW requires 'row'"
        If sErr = "" Then
            oSess.findById(sTarget).getAbsoluteRow(nRow).Selected = True
            If Err.Number <> 0 Then sErr = "getAbsoluteRow(" & nRow & ").Selected failed: " & Err.Description
        End If

    Case "DOUBLE_CLICK"
        If sTarget = "" Then sErr = "DOUBLE_CLICK requires 'target'"
        If sErr = "" Then
            oSess.findById(sTarget).doubleClick
            If Err.Number <> 0 Then sErr = "doubleClick failed: " & Err.Description
        End If

    Case Else
        sErr = "unknown verb '" & sVerb & "'"

End Select
On Error GoTo 0

If sErr <> "" Then
    WScript.Echo "ERROR: " & sErr
    WScript.Quit 3
End If

If nSleep > 0 Then WScript.Sleep nSleep
WScript.Echo "DONE"
WScript.Quit 0
