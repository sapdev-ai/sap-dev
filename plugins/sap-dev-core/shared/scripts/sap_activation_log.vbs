' =============================================================================
' sap_activation_log.vbs  -  Capture an SAP DDIC / repository-object activation
'                            log when activation fails. Shared helper.
'
' WHY: After SE11 Activate (Ctrl+F3) on a DDIC object that was activated as
' part of a worklist (mass activation), SAP shows a popup like
'   "Errors Occurred when Activating -> Refer to Log"
' but the popup itself does not name the failing field or rule. The full
' detail is in the activation log (Utilities > Activation Log). Without that
' detail the operator has to manually re-open SE11, navigate the menu, and
' read the log -- losing the automation context. This helper captures the
' log to a local file inline so the calling skill can echo the path and the
' top error message in its own output.
'
' SCOPE: SE11 / DDIC ONLY. The "Utilities > Activation Log" menu is a DDIC-
' worklist concept and does NOT exist in SE38, SE37, SE24, or SE91 -- those
' transactions surface activation errors via the source-code editor's
' inline error markers + the status bar message text, captured by reading
' wnd[0]/sbar.Text directly (already done in those skills). Do not include
' this helper in non-SE11 scripts; it will silently no-op (CaptureActivationLog
' returns "" because the Utilities menu has no Activation Log entry there)
' but the wiring overhead is wasted.
'
' INCLUDE PATTERN (in the caller VBS, near the top, beside the
' sap_session_lock.vbs include):
'
'   ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
'       .OpenTextFile("%%ACTIVATION_LOG_VBS%%", 1).ReadAll()
'
' CALL PATTERN (after the activate step, when sbar.MessageType = "E" or "A"):
'
'   sLogFile = CaptureActivationLog(oSession, "ZMYTABLE", _
'                                   "C:\sap_dev_work\temp", VKEY_ENTER, _
'                                   VKEY_F3_BACK)
'   If Len(sLogFile) > 0 Then
'       WScript.Echo "INFO: Activation log saved: " & sLogFile
'   End If
'
' RECORDING REFERENCE: C:\Temp\Record_SE11_ActivateErrorLog_01.vbs (S/4HANA
' 1909). The recording captured Utilities > Activation Log -> Log > Save
' Local File -> DY_PATH / DY_FILENAME -> Enter -> Back twice. Menu indices
' below are derived from that recording and from /sap-gui-probe --record probes.
'
' MENU INDICES (SE11/SE38/SE37/SE24 main screen, S/4HANA 1909):
'   wnd[0]/mbar/menu[3]            = Utilities (Dienstprogramme)
'     menu[3]/menu[6]              = Activation Log
'
' MENU INDICES (Log Display screen):
'   wnd[0]/mbar/menu[0]            = Log
'     menu[0]/menu[1]              = Save Local File
'
' If your release moves the menus, re-record on the target system and patch
' the indices below. Indices are language-stable per the
' language_independence_rules.md contract -- only the displayed labels
' change across logon languages.
'
' RETURN VALUE:
'   "" (empty)  -> Activation log could not be opened or saved (caller
'                 should fall back to sbar.Text).
'   "<path>"    -> Absolute path of the saved local file.
'
' NEVER RAISES -- every step is wrapped in On Error Resume Next so a missing
' menu / changed layout degrades to "" rather than aborting the caller.
' =============================================================================

Function CaptureActivationLog(oSess, sObjectName, sOutDir, kEnter, kBack)
    Dim sFileName, sAbsPath
    Dim wndId, attempt
    CaptureActivationLog = ""

    sFileName = UCase(sObjectName) & ".activation_log.txt"
    ' Normalise sOutDir to end with "\"
    If Right(sOutDir, 1) <> "\" Then sOutDir = sOutDir & "\"
    sAbsPath = sOutDir & sFileName

    ' --- Step 1. Open Utilities > Activation Log (menu[3]/menu[6]) -----------
    On Error Resume Next
    oSess.findById("wnd[0]/mbar/menu[3]/menu[6]").select
    If Err.Number <> 0 Then
        Err.Clear
        On Error GoTo 0
        Exit Function
    End If
    WScript.Sleep 1000

    ' --- Step 2. Some releases pop a worklist-pick dialog. If wnd[1] exists
    '             with a list/log selection, take the most-recent (top row)
    '             by pressing Enter.
    For attempt = 1 To 3
        wndId = ""
        wndId = oSess.ActiveWindow.Id
        If InStr(wndId, "wnd[1]") > 0 Then
            oSess.findById("wnd[1]").sendVKey kEnter
            WScript.Sleep 400
        Else
            Exit For
        End If
    Next

    ' --- Step 3. On Log Display screen, open Log > Save Local File
    '             (menu[0]/menu[1]). Some releases require List > Save instead;
    '             try menu[0]/menu[1] first, then fall back to OK code %PC.
    oSess.findById("wnd[0]/mbar/menu[0]/menu[1]").select
    If Err.Number <> 0 Then
        Err.Clear
        ' Fallback: SAP universal "Save list to local file" OK code.
        oSess.findById("wnd[0]/tbar[0]/okcd").Text = "%PC"
        oSess.findById("wnd[0]").sendVKey kEnter
        If Err.Number <> 0 Then
            Err.Clear
            ' Could not open save dialog. Try to back out cleanly.
            oSess.findById("wnd[0]/tbar[0]/btn[15]").press
            WScript.Sleep 300
            On Error GoTo 0
            Exit Function
        End If
    End If
    WScript.Sleep 600

    ' --- Step 4. Encoding-format popup (if it appears) -- accept default. ----
    For attempt = 1 To 3
        wndId = ""
        wndId = oSess.ActiveWindow.Id
        If InStr(wndId, "wnd[1]") > 0 Then
            ' Probe for DY_PATH -- that is the destination dialog, not the
            ' encoding popup. If DY_PATH exists, break out to fill it.
            On Error Resume Next
            Dim hasDyPath : hasDyPath = False
            Dim dyEl
            Set dyEl = oSess.findById("wnd[1]/usr/ctxtDY_PATH")
            If Err.Number = 0 And Not (dyEl Is Nothing) Then hasDyPath = True
            Err.Clear
            If hasDyPath Then Exit For
            ' Otherwise it is the format dialog -- accept default with btn[0].
            oSess.findById("wnd[1]/tbar[0]/btn[0]").press
            WScript.Sleep 400
        Else
            Exit For
        End If
    Next

    ' --- Step 5. Destination popup -- fill DY_PATH + DY_FILENAME, Enter. -----
    wndId = oSess.ActiveWindow.Id
    If InStr(wndId, "wnd[1]") = 0 Then
        ' Destination dialog never appeared -- abort and back out.
        oSess.findById("wnd[0]/tbar[0]/btn[15]").press
        WScript.Sleep 300
        On Error GoTo 0
        Exit Function
    End If

    oSess.findById("wnd[1]/usr/ctxtDY_PATH").Text     = sOutDir
    oSess.findById("wnd[1]/usr/ctxtDY_FILENAME").Text = sFileName
    oSess.findById("wnd[1]").sendVKey kEnter
    WScript.Sleep 800

    ' --- Step 6. Back out of the Log display to return caller to SE11/etc. --
    oSess.findById("wnd[0]/tbar[0]/btn[15]").press
    WScript.Sleep 300
    Err.Clear
    On Error GoTo 0

    ' --- Step 7. Verify the file exists on disk before reporting success. ---
    Dim oFSO
    Set oFSO = CreateObject("Scripting.FileSystemObject")
    If oFSO.FileExists(sAbsPath) Then
        CaptureActivationLog = sAbsPath
    End If
End Function

' Convenience wrapper: extract the top ERROR line from a saved activation log
' so the caller can echo it without having to read the whole file. Returns
' "" if no recognisable error line is found. Treats lines starting with the
' SAP error icon literal "@5C@" or containing "(specify reference table" /
' "was not activated" as candidates -- these are the patterns observed in
' DDIC activation logs across S/4HANA 17xx-21xx.
Function ExtractTopActivationError(sLogPath)
    ExtractTopActivationError = ""
    Dim oFSO, oFile, sLine, sCand
    Set oFSO = CreateObject("Scripting.FileSystemObject")
    If Not oFSO.FileExists(sLogPath) Then Exit Function
    On Error Resume Next
    Set oFile = oFSO.OpenTextFile(sLogPath, 1, False, -2) ' default codepage
    If Err.Number <> 0 Then
        Err.Clear
        On Error GoTo 0
        Exit Function
    End If
    Do While Not oFile.AtEndOfStream
        sLine = oFile.ReadLine
        sCand = Trim(sLine)
        If Len(sCand) > 0 Then
            ' Skip the activation banner ("=====" lines and timestamps)
            If Left(sCand, 1) <> "=" And InStr(sCand, "Activation of worklist") = 0 _
               And InStr(sCand, "End of activation") = 0 _
               And InStr(sCand, "Technical log") = 0 _
               And InStr(sCand, "See log ") = 0 Then
                ' Heuristic: the first non-banner line that mentions
                ' "was not activated", "(specify ", "errors" or has the
                ' SAP error icon is the top error.
                If InStr(sCand, "was not activated") > 0 _
                   Or InStr(sCand, "(specify ") > 0 _
                   Or InStr(LCase(sCand), "error") > 0 _
                   Or InStr(sCand, "@5C@") > 0 Then
                    ExtractTopActivationError = sCand
                    Exit Do
                End If
            End If
        End If
    Loop
    oFile.Close
    On Error GoTo 0
End Function
