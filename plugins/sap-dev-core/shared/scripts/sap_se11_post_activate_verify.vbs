' =============================================================================
' sap_se11_post_activate_verify.vbs
' -----------------------------------------------------------------------------
' Shared VBS helper for sap-se11 create/update templates (Phase 4.3).
'
' Include via:
'   ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
'       .OpenTextFile("%%POST_ACTIVATE_VERIFY_VBS%%", 1).ReadAll()
'
' Then call AFTER the Activate (Ctrl+F3) step but BEFORE printing "SUCCESS:":
'   PostActivateVerifyOrFail "%%POST_ACTIVATE_VERIFY_PS1%%", "DOMAIN", OBJECT_NAME
'
' The Sub shells out to sap_se11_post_activate_verify.ps1 (which reads the
' AI-session''s pinned connection from connections.json and runs an
' RFC_READ_TABLE against the appropriate DDIC catalog table). Behavior on
' each verify outcome:
'
'   ACTIVE   -> continue (Sub returns silently)
'   INACTIVE -> echo ERROR + WScript.Quit 1 (object stayed in inactive workspace)
'   MISSING  -> echo ERROR + WScript.Quit 1 (silent half-deploy; TADIR may persist)
'   ERROR    -> echo "WARNING: POST_ACTIVATE_VERIFY_UNAVAILABLE - <reason>"
'               and continue (verify unavailable - RFC creds missing, endpoint
'               unreachable, or NCo not installed; SAP GUI status bar still
'               applies as primary signal). The distinctive marker line lets
'               the calling skill report SUCCESS_UNVERIFIED instead of SUCCESS.
'   SKIP     -> verify helper path not configured (token unsubstituted); the
'               caller''s VBS isn''t in a context where the verify is wired
'               (e.g. first-pass tests). Continue silently.
'
' The token sentinel uses Chr(37) so that a global wrapper-side
' Replace("%%POST_ACTIVATE_VERIFY_PS1%%", ...) cannot accidentally corrupt
' the comparison. (Same idiom as sap_attach_lib.vbs.)
'
' ASCII ONLY: this file is included via OpenTextFile(..., 1) which reads as
' ANSI; non-ASCII characters (em-dashes, smart quotes, arrows) corrupt the
' parse. Keep all comments and strings in 7-bit ASCII.
' =============================================================================

Function PaVerifySentinelPs1()
    PaVerifySentinelPs1 = Chr(37) & Chr(37) & "POST_ACTIVATE_VERIFY_PS1" & Chr(37) & Chr(37)
End Function

Function RunPostActivateVerify(sPs1Path, sObjType, sObjName)
    Dim sCmd, oShell, oExec, sOut, sLine, sLastLine, aLines, i
    If sPs1Path = "" Then RunPostActivateVerify = "SKIP" : Exit Function
    If sPs1Path = PaVerifySentinelPs1() Then RunPostActivateVerify = "SKIP" : Exit Function

    ' NCo 3.1 is registered ONLY in the 32-bit GAC, so the verify PS1 MUST run
    ' under 32-bit PowerShell. A bare "powershell.exe" inherits the launching
    ' cscript's bitness via WOW64 redirection: under a 64-bit cscript it spawns
    ' 64-bit PowerShell, where Add-Type on the 32-bit sapnco.dll throws
    ' BadImageFormatException, Connect-SapRfc returns no destination, and the
    ' generic "no destination" masks the real cause (verified 2026-06-19 on
    ' S/4HANA 754). Pin the literal SysWOW64 (32-bit) PowerShell -- the literal
    ' path is NOT WOW64-redirected, so it resolves to 32-bit from either parent
    ' bitness. Fall back to bare powershell.exe only on a 32-bit-only Windows
    ' (no SysWOW64), where System32 PowerShell is already 32-bit.
    Dim oFsoPs, sPsExe
    Set oFsoPs = CreateObject("Scripting.FileSystemObject")
    sPsExe = oFsoPs.BuildPath(oFsoPs.GetSpecialFolder(0), "SysWOW64\WindowsPowerShell\v1.0\powershell.exe")
    If Not oFsoPs.FileExists(sPsExe) Then sPsExe = "powershell.exe"
    sCmd = """" & sPsExe & """ -ExecutionPolicy Bypass -NoProfile -File """ & _
           sPs1Path & """ -ObjectType " & sObjType & _
           " -ObjectName """ & UCase(sObjName) & """"
    Set oShell = CreateObject("WScript.Shell")
    On Error Resume Next
    Set oExec = oShell.Exec(sCmd)
    If Err.Number <> 0 Then
        RunPostActivateVerify = "ERROR: failed to launch verify helper (" & Err.Description & ")"
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

    ' Last non-empty line is the contract.
    aLines = Split(sOut, vbCrLf)
    sLastLine = ""
    For i = UBound(aLines) To 0 Step -1
        If Trim(aLines(i)) <> "" Then
            sLastLine = Trim(aLines(i))
            Exit For
        End If
    Next
    If sLastLine = "" Then
        sLastLine = "ERROR: verify helper produced no output (exit=" & oExec.ExitCode & ")"
    End If
    RunPostActivateVerify = sLastLine
End Function

Sub PostActivateVerifyOrFail(sPs1Path, sObjType, sObjName)
    Dim sResult
    sResult = RunPostActivateVerify(sPs1Path, sObjType, sObjName)
    If sResult = "SKIP" Then
        WScript.Echo "INFO: Post-activate RFC verify skipped (helper path not configured)."
        Exit Sub
    End If
    WScript.Echo "INFO: Post-activate RFC verify: " & sResult
    If sResult = "ACTIVE" Then
        Exit Sub
    ElseIf sResult = "INACTIVE" Then
        WScript.Echo "ERROR: " & UCase(sObjType) & " " & UCase(sObjName) & _
            " is INACTIVE in DDIC after activation - activation did not complete."
        WScript.Quit 1
    ElseIf sResult = "MISSING" Then
        WScript.Echo "ERROR: " & UCase(sObjType) & " " & UCase(sObjName) & _
            " is MISSING from the DDIC catalog after a reported SUCCESS - silent half-deploy."
        WScript.Echo "INFO: TADIR may still reference the object; clean via SE03 (or RS_DD_DELETE_OBJ) before retrying."
        WScript.Quit 1
    Else
        ' Treat as soft warning - verify could not run for an operational reason
        ' (no RFC creds, NCo missing, endpoint unreachable). Do not block, but
        ' emit the distinctive marker line so the calling skill downgrades its
        ' report to SUCCESS_UNVERIFIED (never plain SUCCESS). Some helpers
        ' (se37) already emit the marker themselves - do not double-prefix.
        If InStr(sResult, "POST_ACTIVATE_VERIFY_UNAVAILABLE") > 0 Then
            WScript.Echo sResult
        Else
            WScript.Echo "WARNING: POST_ACTIVATE_VERIFY_UNAVAILABLE - " & sResult
        End If
    End If
End Sub
