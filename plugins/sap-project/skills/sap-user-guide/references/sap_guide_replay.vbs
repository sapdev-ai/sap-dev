' ============================================================================
' sap_guide_replay.vbs  -  single-action replay executor for /sap-user-guide
'
' Executes ONE recorded action (by findById + verb) from a probe run folder, then
' VERIFIES the live (program,dynpro) against the recorded step_NN_post.json - a
' mismatch => REPLAY_DIVERGED (stop, keep partial captures, honesty note in the
' guide, never a wrong-screen action). The SKILL delegates /sap-gui-inspect for the
' screenshot after each successful action. House rule: this ships its OWN thin
' executor (never runs another skill's reference VBS directly). Language-independent
' (control IDs + VKeys only). 32-bit cscript.
'
' Tokens: %%SESSION_PATH%% %%ATTACH_LIB_VBS%% %%RUN_FOLDER%% %%STEP_INDEX%%
' Output: REPLAY: step=<n> result=<PASS|REPLAY_DIVERGED|ACTION_FAILED> detail=..
' ============================================================================
Option Explicit
Const SESSION_PATH = "%%SESSION_PATH%%"
Const RUN_FOLDER   = "%%RUN_FOLDER%%"
Const STEP_INDEX   = "%%STEP_INDEX%%"

Dim oFso : Set oFso = CreateObject("Scripting.FileSystemObject")
ExecuteGlobal oFso.OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

Dim oSession : Set oSession = AttachSapSession(SESSION_PATH)
If oSession Is Nothing Then WScript.Echo "REPLAY: step=" & STEP_INDEX & " result=ACTION_FAILED detail=no_session" : WScript.Quit 2

Dim sN : sN = Right("00" & STEP_INDEX, 2)
Dim sAction : sAction = oFso.BuildPath(RUN_FOLDER, "step_" & sN & "_action.json")
Dim sPost   : sPost   = oFso.BuildPath(RUN_FOLDER, "step_" & sN & "_post.json")
If Not oFso.FileExists(sAction) Then WScript.Echo "REPLAY: step=" & STEP_INDEX & " result=ACTION_FAILED detail=no_action_json" : WScript.Quit 2

Dim jAction : jAction = oFso.OpenTextFile(sAction, 1).ReadAll()
Dim sVerb : sVerb = LCase(JsonVal(jAction, "verb"))
Dim sId   : sId   = JsonVal(jAction, "target")
Dim sVal  : sVal  = JsonVal(jAction, "value")

On Error Resume Next
Err.Clear
Select Case sVerb
    Case "set"      : oSession.findById(sId).Text = sVal
    Case "select"   : oSession.findById(sId).Select
    Case "press"    : oSession.findById(sId).press
    Case "sendvkey" : oSession.findById("wnd[0]").sendVKey CInt("0" & sVal)
    Case Else       : oSession.findById(sId).press
End Select
If Err.Number <> 0 Then
    WScript.Echo "REPLAY: step=" & STEP_INDEX & " result=ACTION_FAILED detail=" & Replace(Err.Description, vbTab, " ")
    On Error Goto 0 : WScript.Quit 2
End If
On Error Goto 0

' verify live screen identity vs recorded post sidecar
Dim recProg, recDyn : recProg = "" : recDyn = ""
If oFso.FileExists(sPost) Then
    Dim jPost : jPost = oFso.OpenTextFile(sPost, 1).ReadAll()
    recProg = UCase(JsonVal(jPost, "program")) : recDyn = JsonVal(jPost, "dynpro")
End If

Dim liveProg, liveDyn : liveProg = "" : liveDyn = ""
On Error Resume Next
liveProg = UCase(Trim(oSession.Info.Program)) : liveDyn = oSession.Info.ScreenNumber
On Error Goto 0

If recProg <> "" Then
    If recProg = liveProg And CStr(CInt("0" & recDyn)) = CStr(CInt("0" & liveDyn)) Then
        WScript.Echo "REPLAY: step=" & STEP_INDEX & " result=PASS detail=identity_ok prog=" & liveProg & " dynpro=" & liveDyn
    Else
        WScript.Echo "REPLAY: step=" & STEP_INDEX & " result=REPLAY_DIVERGED detail=recorded " & recProg & "/" & recDyn & " live " & liveProg & "/" & liveDyn
        WScript.Quit 3
    End If
Else
    WScript.Echo "REPLAY: step=" & STEP_INDEX & " result=PASS detail=action_done_no_sidecar prog=" & liveProg & " dynpro=" & liveDyn
End If
WScript.Quit 0

' --- tiny JSON value reader (flat objects only; probe sidecars are flat) ---
Function JsonVal(sJson, sKey)
    Dim p, q, r, s
    p = InStr(sJson, """" & sKey & """")
    If p = 0 Then JsonVal = "" : Exit Function
    p = InStr(p, sJson, ":") : If p = 0 Then JsonVal = "" : Exit Function
    q = InStr(p, sJson, """")
    If q > 0 And Trim(Mid(sJson, p+1, q-p-1)) = "" Then
        r = InStr(q+1, sJson, """")
        JsonVal = Mid(sJson, q+1, r-q-1)
    Else
        ' unquoted (number/bool) up to , or }
        s = Mid(sJson, p+1)
        r = 1 : Do While r <= Len(s) And InStr(",}", Mid(s,r,1)) = 0 : r = r + 1 : Loop
        JsonVal = Trim(Left(s, r-1))
    End If
End Function
