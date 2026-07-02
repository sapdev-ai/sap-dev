' =============================================================================
' sap_se38_content_verify.vbs
' -----------------------------------------------------------------------------
' Shared VBS helper for the sap-se38 create/update templates.
'
' Include via:
'   ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
'       .OpenTextFile("%%CONTENT_VERIFY_VBS%%", 1).ReadAll()
'
' Then call AFTER the PROGDIR post-activate verify (PostActivateVerifyOrFail)
' and BEFORE the F8 run-test / final "SUCCESS:" line:
'   ContentVerifyOrFail "%%CONTENT_VERIFY_PS1%%", PROGRAM_NAME, ABAP_SOURCE_FILE
'
' The Sub shells out to sap_se38_content_verify.ps1, which reads the ACTIVE
' source back over RFC (RPY_PROGRAM_READ) and compares it to the file that was
' just uploaded. This closes the clipboard-paste false-success: when the paste
' fails silently the editor keeps the OLD (valid) source, so the syntax check,
' PROGDIR.STATE verify, and F8 run-test all pass against stale content and SE38
' reports SUCCESS. Comparing deployed-vs-active content is the only gate that
' catches it.
'
' Behaviour on each verify outcome:
'   MATCH     -> continue (Sub returns silently after echoing the marker)
'   MISMATCH  -> echo ERROR + WScript.Quit 1 (the uploaded source did NOT become
'                the active source -- deploy did not take)
'   ERROR     -> echo "WARNING: CONTENT_VERIFY_UNAVAILABLE - <reason>" and
'                continue (verify could not run: RFC creds missing, endpoint
'                unreachable, NCo not installed, or RFC disabled -- e.g. the
'                EC6/ER1 case). The PROGDIR verify + GUI checks remain the
'                primary signals; the marker lets the caller report
'                SUCCESS_UNVERIFIED instead of plain SUCCESS.
'   SKIP      -> verify helper path not configured (token unsubstituted); the
'                caller is not in a wired context (offline test). Continue.
'
' In every case a single parseable marker line is echoed so Step 6 can report
' it without grepping prose:
'   CONTENT_VERIFY: <MATCH|MISMATCH|UNAVAILABLE|SKIP>
'
' The token sentinel uses Chr(37) so a global wrapper-side Replace of
' "%%CONTENT_VERIFY_PS1%%" cannot corrupt the comparison (same idiom as
' sap_attach_lib.vbs / sap_se11_post_activate_verify.vbs).
'
' ASCII ONLY: this file is included via OpenTextFile(..., 1) which reads as
' ANSI; non-ASCII characters (em-dashes, smart quotes, arrows) corrupt the
' parse. Keep all comments and strings in 7-bit ASCII.
' =============================================================================

Function CvSentinelPs1()
    CvSentinelPs1 = Chr(37) & Chr(37) & "CONTENT_VERIFY_PS1" & Chr(37) & Chr(37)
End Function

Function RunContentVerify(sPs1Path, sProgram, sExpectedFile)
    Dim sCmd, oShell, oExec, sOut, sLine, sLastLine, aLines, i
    If sPs1Path = "" Then RunContentVerify = "SKIP" : Exit Function
    If sPs1Path = CvSentinelPs1() Then RunContentVerify = "SKIP" : Exit Function
    If sExpectedFile = "" Then RunContentVerify = "SKIP" : Exit Function

    ' NCo 3.1 is registered ONLY in the 32-bit GAC, so the verify PS1 MUST run
    ' under 32-bit PowerShell. A bare "powershell.exe" inherits the launching
    ' cscript's bitness via WOW64 redirection: under a 64-bit cscript it spawns
    ' 64-bit PowerShell, where Connect-SapRfc returns no destination and the
    ' generic "no destination" masks the real cause -- content verify would then
    ' soft-warn UNAVAILABLE and the gate is silently disabled. Pin the literal
    ' SysWOW64 (32-bit) PowerShell -- the literal path is NOT WOW64-redirected,
    ' so it resolves to 32-bit from either parent bitness. Fall back to bare
    ' powershell.exe only on a 32-bit-only Windows (no SysWOW64).
    Dim oFsoPs, sPsExe
    Set oFsoPs = CreateObject("Scripting.FileSystemObject")
    sPsExe = oFsoPs.BuildPath(oFsoPs.GetSpecialFolder(0), "SysWOW64\WindowsPowerShell\v1.0\powershell.exe")
    If Not oFsoPs.FileExists(sPsExe) Then sPsExe = "powershell.exe"
    sCmd = """" & sPsExe & """ -ExecutionPolicy Bypass -NoProfile -File """ & _
           sPs1Path & """ -ObjectName """ & UCase(sProgram) & """" & _
           " -ExpectedSourceFile """ & sExpectedFile & """"
    Set oShell = CreateObject("WScript.Shell")
    On Error Resume Next
    Set oExec = oShell.Exec(sCmd)
    If Err.Number <> 0 Then
        RunContentVerify = "ERROR: failed to launch content-verify helper (" & Err.Description & ")"
        Err.Clear
        Exit Function
    End If
    On Error GoTo 0

    sOut = ""
    Do While oExec.Status = 0
        Do While Not oExec.StdOut.AtEndOfStream
            sLine = oExec.StdOut.ReadLine()
            sOut  = sOut & sLine & vbCrLf
        Loop
        WScript.Sleep 100
    Loop
    Do While Not oExec.StdOut.AtEndOfStream
        sLine = oExec.StdOut.ReadLine()
        sOut  = sOut & sLine & vbCrLf
    Loop

    ' Echo the helper's INFO/diagnostic lines so line-count / first-diff context
    ' is visible in the cscript output (not just the terminal verdict).
    aLines = Split(sOut, vbCrLf)
    For i = 0 To UBound(aLines)
        If Trim(aLines(i)) <> "" And Left(Trim(aLines(i)), 5) = "INFO:" Then
            WScript.Echo "  " & Trim(aLines(i))
        End If
    Next

    ' Last non-empty line is the contract.
    sLastLine = ""
    For i = UBound(aLines) To 0 Step -1
        If Trim(aLines(i)) <> "" Then
            sLastLine = Trim(aLines(i))
            Exit For
        End If
    Next
    If sLastLine = "" Then
        sLastLine = "ERROR: content-verify helper produced no output (exit=" & oExec.ExitCode & ")"
    End If
    RunContentVerify = sLastLine
End Function

Sub ContentVerifyOrFail(sPs1Path, sProgram, sExpectedFile)
    Dim sResult
    sResult = RunContentVerify(sPs1Path, sProgram, sExpectedFile)
    If sResult = "SKIP" Then
        WScript.Echo "INFO: Post-activate content verify skipped (helper path not configured)."
        WScript.Echo "CONTENT_VERIFY: SKIP"
        Exit Sub
    End If
    WScript.Echo "INFO: Post-activate content verify: " & sResult
    If sResult = "MATCH" Then
        WScript.Echo "CONTENT_VERIFY: MATCH"
        Exit Sub
    ElseIf sResult = "MISMATCH" Then
        WScript.Echo "CONTENT_VERIFY: MISMATCH"
        WScript.Echo "ERROR: Program " & UCase(sProgram) & " is ACTIVE but its source does NOT match the file that was deployed."
        WScript.Echo "       The upload did not take -- most likely the clipboard paste failed silently (e.g. clipboard"
        WScript.Echo "       contention with another SAP GUI automation running concurrently). SE38 re-activated the OLD"
        WScript.Echo "       source, so the syntax check / PROGDIR / F8 checks all passed against stale content."
        WScript.Echo "       Recovery: re-run the deploy (serialize concurrent SE38 automation), or /sap-se38 delete +"
        WScript.Echo "       recreate if the update keeps failing to paste. Do NOT treat this run as a successful deploy."
        WScript.Quit 1
    Else
        ' Soft warning -- verify could not run for an operational reason (no RFC
        ' creds, NCo missing, endpoint unreachable, RFC disabled). Do not block,
        ' but emit the distinctive marker so the calling skill downgrades its
        ' report to SUCCESS_UNVERIFIED (never plain SUCCESS).
        WScript.Echo "CONTENT_VERIFY: UNAVAILABLE"
        WScript.Echo "WARNING: CONTENT_VERIFY_UNAVAILABLE - " & sResult
    End If
End Sub
