' =============================================================================
' sap_log_lib.vbs  -  Shared JSONL logging helpers for sap-dev VBScript skills
'
' Include this file via the standard VBS include trick:
'
'   ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
'       .OpenTextFile("<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_lib.vbs", 1).ReadAll()
'
' Or have the PS1 wrapper inject the file path via a token (%%LOG_LIB_VBS%%)
' and dot-include it the same way.
'
' Usage:
'
'   Dim runId : runId = LogStart("sap-se11", Array("object_type","DOMAIN","object_name","ZHKDM_X"))
'   LogStep runId, "INFO", "create", "Saving..."
'   LogEnd  runId, "SUCCESS", 0, ""
'
' Records are appended one JSON object per line, UTF-8 (no BOM), to:
'   {log_dir}\{log_file_pattern}     (defaults: {work_dir}\logs\sap-dev-{YYYYMMDD}.log)
'
' Settings consumed from sap-dev-core/settings.json (userConfig):
'   log_enabled, log_level, log_dir, log_file_pattern
' =============================================================================

Dim g_LogCfg, g_LogRuns, g_LogLevels
Set g_LogRuns = CreateObject("Scripting.Dictionary")
Set g_LogLevels = CreateObject("Scripting.Dictionary")
g_LogLevels.Add "DEBUG", 10
g_LogLevels.Add "INFO",  20
g_LogLevels.Add "WARN",  30
g_LogLevels.Add "ERROR", 40
g_LogLevels.Add "OFF",   99

Function LogGetSettings()
    If Not IsEmpty(g_LogCfg) Then
        Set LogGetSettings = g_LogCfg
        Exit Function
    End If

    Dim cfg : Set cfg = CreateObject("Scripting.Dictionary")
    cfg("Enabled")     = True
    cfg("LevelNum")    = 20
    cfg("Dir")         = "C:\sap_dev_work\logs"
    cfg("Pattern")     = "sap-dev-{YYYYMMDD}.log"
    cfg("Format")      = "JSONL"
    cfg("ConsoleEcho") = False
    cfg("MaxSizeMB")   = 10
    cfg("MaxBackups")  = 5
    cfg("RedactKeys")  = "sap_password,password,passwd,pwd,token,secret,api_key"

    ' Locate sap-dev-core/settings.json + settings.local.json. This script
    ' lives at <root>\plugins\sap-dev-core\shared\scripts\sap_log_lib.vbs.
    ' Concatenation order = local FIRST, main second, so the LogJsonValue
    ' extractor (which returns the first match) naturally picks up local
    ' overrides on a per-key basis.
    Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
    Dim sScriptPath
    On Error Resume Next
    sScriptPath = WScript.ScriptFullName
    On Error GoTo 0
    Dim sSettings : sSettings = ""
    Dim sLocalSettings : sLocalSettings = ""
    If Len(sScriptPath) > 0 Then
        ' Walk up two levels (shared\scripts -> shared -> sap-dev-core)
        Dim sDir : sDir = oFSO.GetParentFolderName(oFSO.GetParentFolderName(oFSO.GetParentFolderName(sScriptPath)))
        ' sDir might already be sap-dev-core if included from another path.
        ' Try a couple of sensible candidates.
        Dim aCandidates : aCandidates = Array( _
            sDir & "\settings.json", _
            oFSO.GetParentFolderName(sDir) & "\sap-dev-core\settings.json")
        Dim c
        For Each c In aCandidates
            If oFSO.FileExists(c) Then sSettings = c : Exit For
        Next
        Dim aLocalCandidates : aLocalCandidates = Array( _
            sDir & "\settings.local.json", _
            oFSO.GetParentFolderName(sDir) & "\sap-dev-core\settings.local.json")
        Dim cl
        For Each cl In aLocalCandidates
            If oFSO.FileExists(cl) Then sLocalSettings = cl : Exit For
        Next
    End If

    If sSettings <> "" Then
        Dim sJson, oFile, sLocalJson
        sLocalJson = ""
        If sLocalSettings <> "" Then
            Set oFile = oFSO.OpenTextFile(sLocalSettings, 1, False, -1)
            sLocalJson = oFile.ReadAll
            oFile.Close
        End If
        Set oFile = oFSO.OpenTextFile(sSettings, 1, False, -1)  ' read as Unicode/auto
        sJson = sLocalJson & vbCrLf & oFile.ReadAll
        oFile.Close

        Dim sWork  : sWork  = LogJsonValue(sJson, "work_dir")
        If sWork = "" Then sWork = "C:\sap_dev_work"

        Dim sEna   : sEna   = LogJsonValue(sJson, "log_enabled")
        If sEna <> "" Then cfg("Enabled") = (LCase(sEna) = "true")

        Dim sLvl   : sLvl   = UCase(LogJsonValue(sJson, "log_level"))
        If sLvl <> "" And g_LogLevels.Exists(sLvl) Then cfg("LevelNum") = g_LogLevels(sLvl)

        Dim sDirC  : sDirC  = LogJsonValue(sJson, "log_dir")
        If sDirC <> "" Then
            cfg("Dir") = sDirC
        Else
            cfg("Dir") = sWork & "\logs"
        End If

        Dim sPat   : sPat   = LogJsonValue(sJson, "log_file_pattern")
        If sPat <> "" Then cfg("Pattern") = sPat

        Dim sFmt   : sFmt   = UCase(LogJsonValue(sJson, "log_format"))
        If sFmt = "JSONL" Or sFmt = "TSV" Or sFmt = "TEXT" Then cfg("Format") = sFmt

        Dim sEcho  : sEcho  = LogJsonValue(sJson, "log_console_echo")
        If sEcho <> "" Then cfg("ConsoleEcho") = (LCase(sEcho) = "true")

        Dim sMax   : sMax   = LogJsonValue(sJson, "log_max_size_mb")
        If IsNumeric(sMax) Then cfg("MaxSizeMB") = CLng(sMax)

        Dim sBak   : sBak   = LogJsonValue(sJson, "log_max_backups")
        If IsNumeric(sBak) Then cfg("MaxBackups") = CLng(sBak)

        Dim sRed   : sRed   = LogJsonValue(sJson, "log_redact_keys")
        If sRed <> "" Then cfg("RedactKeys") = sRed
    End If

    If Not oFSO.FolderExists(cfg("Dir")) Then
        On Error Resume Next
        oFSO.CreateFolder cfg("Dir")
        On Error GoTo 0
    End If

    Set g_LogCfg = cfg
    Set LogGetSettings = cfg
End Function

' Crude JSON value extractor for the shape produced by Save-CCSettings:
'   "key":  { "description": "...", "value":  "VAL" }
' Returns the VAL string or "" if not found / no value.
Function LogJsonValue(sJson, sKey)
    Dim sNeedle : sNeedle = """" & sKey & """"
    Dim p : p = InStr(1, sJson, sNeedle, 1)
    If p = 0 Then LogJsonValue = "" : Exit Function
    Dim valTag : valTag = """value"""
    Dim q : q = InStr(p, sJson, valTag, 1)
    If q = 0 Then LogJsonValue = "" : Exit Function
    ' Make sure the next "key": doesn't appear before "value"
    Dim nextKey : nextKey = InStr(p + Len(sNeedle), sJson, """", 1)
    ' Find the colon after value
    Dim colon : colon = InStr(q, sJson, ":")
    If colon = 0 Then LogJsonValue = "" : Exit Function
    ' Find first quote after colon
    Dim openQ : openQ = InStr(colon, sJson, """")
    If openQ = 0 Then LogJsonValue = "" : Exit Function
    Dim closeQ : closeQ = InStr(openQ + 1, sJson, """")
    If closeQ = 0 Then LogJsonValue = "" : Exit Function
    LogJsonValue = Mid(sJson, openQ + 1, closeQ - openQ - 1)
End Function

Function LogResolvePath(sSkill, sRunId)
    Dim cfg : Set cfg = LogGetSettings()
    Dim sName : sName = cfg("Pattern")
    sName = Replace(sName, "{YYYYMMDD}", Year(Now) & Right("0" & Month(Now),2) & Right("0" & Day(Now),2))
    sName = Replace(sName, "{YYYYMM}",   Year(Now) & Right("0" & Month(Now),2))
    ' {HHMMSS} / {HHMM} for per-invocation uniqueness, {RUN_ID} for
    ' guaranteed uniqueness even across same-second invocations.
    sName = Replace(sName, "{HHMMSS}",   Right("0" & Hour(Now),2) & Right("0" & Minute(Now),2) & Right("0" & Second(Now),2))
    sName = Replace(sName, "{HHMM}",     Right("0" & Hour(Now),2) & Right("0" & Minute(Now),2))
    sName = Replace(sName, "{RUN_ID}",   LogSanitize(sRunId))
    sName = Replace(sName, "{SKILL}",    LogSanitize(sSkill))
    Dim oWsh : Set oWsh = CreateObject("WScript.Shell")
    sName = Replace(sName, "{USER}",     LogSanitize(oWsh.ExpandEnvironmentStrings("%USERNAME%")))
    sName = Replace(sName, "{SYSTEM}",   LogSanitize(oWsh.ExpandEnvironmentStrings("%COMPUTERNAME%")))
    LogResolvePath = cfg("Dir") & "\" & sName
End Function

Function LogSanitize(s)
    Dim r : r = ""
    Dim i, ch
    For i = 1 To Len(s)
        ch = Mid(s, i, 1)
        If (ch >= "A" And ch <= "Z") Or (ch >= "a" And ch <= "z") Or (ch >= "0" And ch <= "9") Or ch = "_" Or ch = "-" Then
            r = r & ch
        Else
            r = r & "_"
        End If
    Next
    LogSanitize = r
End Function

Function LogIsoNow()
    Dim n : n = Now
    Dim ms : ms = Right("00" & ((Timer * 1000) Mod 1000), 3)
    LogIsoNow = Year(n) & "-" & Right("0" & Month(n),2) & "-" & Right("0" & Day(n),2) & _
                "T" & Right("0" & Hour(n),2) & ":" & Right("0" & Minute(n),2) & ":" & Right("0" & Second(n),2) & "." & ms
End Function

Function LogJsonEscape(s)
    Dim r : r = s
    r = Replace(r, "\", "\\")
    r = Replace(r, """", "\""")
    r = Replace(r, vbCr, "\r")
    r = Replace(r, vbLf, "\n")
    r = Replace(r, vbTab, "\t")

    ' Escape any non-ASCII character to \uXXXX. This lets the appender write
    ' via FSO ForAppending (mode 8) at the local codepage without corrupting
    ' Japanese / Chinese / Korean / German content — the on-disk bytes for
    ' \uXXXX are 7-bit ASCII and survive any codepage round-trip. JSON spec
    ' explicitly allows \uXXXX for any character. The PS appender continues
    ' to write raw UTF-8 bytes; readers parse both forms identically.
    Dim i, ch, code, hx, buf
    buf = ""
    For i = 1 To Len(r)
        ch = Mid(r, i, 1)
        code = AscW(ch)
        If code < 0 Then code = code + 65536  ' AscW returns signed
        If code >= 32 And code < 127 Then
            buf = buf & ch
        ElseIf code < 32 Then
            ' Control characters other than the four above (already escaped).
            hx = Right("0000" & Hex(code), 4)
            buf = buf & "\u" & hx
        Else
            ' Non-ASCII >= 127 — emit \uXXXX so the bytes on disk are pure ASCII.
            hx = Right("0000" & Hex(code), 4)
            buf = buf & "\u" & hx
        End If
    Next
    LogJsonEscape = buf
End Function

' --- Format / redact / rotate / echo helpers ----------------------------------

' Apply redaction in place to a key/value pair array (Array("k","v","k2","v2",...))
Function LogRedactPairs(vPairs)
    If IsEmpty(vPairs) Or Not IsArray(vPairs) Then LogRedactPairs = vPairs : Exit Function
    Dim ub : ub = UBound(vPairs)
    If ub < 1 Then LogRedactPairs = vPairs : Exit Function

    Dim cfg : Set cfg = LogGetSettings()
    Dim sList : sList = LCase(cfg("RedactKeys"))
    If sList = "" Then LogRedactPairs = vPairs : Exit Function
    Dim aRedact : aRedact = Split(sList, ",")

    Dim i, j, k
    For i = 0 To ub - 1 Step 2
        k = LCase(Trim(CStr(vPairs(i))))
        For j = 0 To UBound(aRedact)
            If k = Trim(aRedact(j)) Then
                If Len(CStr(vPairs(i+1))) > 0 Then vPairs(i+1) = "***" Else vPairs(i+1) = ""
                Exit For
            End If
        Next
    Next
    LogRedactPairs = vPairs
End Function

' Render a record dictionary as JSON (single line). Order is whatever the dict iterates.
Function LogRenderJson(oRec)
    Dim s : s = "{"
    Dim sep : sep = ""
    Dim k, v, vTxt, isRaw
    For Each k In oRec.Keys
        v = oRec(k)
        isRaw = (Left(k, 1) = "~")  ' ~key means already-formatted JSON value (e.g. params object, numbers)
        Dim outKey : outKey = k
        If isRaw Then outKey = Mid(k, 2)
        If isRaw Then
            s = s & sep & """" & outKey & """:" & v
        Else
            s = s & sep & """" & outKey & """:""" & LogJsonEscape(CStr(v)) & """"
        End If
        sep = ","
    Next
    s = s & "}"
    LogRenderJson = s
End Function

Function LogTsvHeader()
    LogTsvHeader = "ts" & vbTab & "run_id" & vbTab & "parent_run_id" & vbTab & "skill" & vbTab & _
                   "phase" & vbTab & "level" & vbTab & "status" & vbTab & "step" & vbTab & _
                   "exit_code" & vbTab & "duration_ms" & vbTab & "error_class" & vbTab & _
                   "msg" & vbTab & "error_msg" & vbTab & "params"
End Function

Function LogTsvCell(oRec, sKey)
    Dim v
    If oRec.Exists(sKey) Then
        v = oRec(sKey)
    ElseIf oRec.Exists("~" & sKey) Then
        v = oRec("~" & sKey)
    Else
        LogTsvCell = "" : Exit Function
    End If
    Dim s : s = CStr(v)
    s = Replace(s, vbTab, " ")
    s = Replace(s, vbCr, " ")
    s = Replace(s, vbLf, " ")
    LogTsvCell = s
End Function

Function LogRenderTsv(oRec)
    LogRenderTsv = LogTsvCell(oRec, "ts") & vbTab & LogTsvCell(oRec, "run_id") & vbTab & _
                   LogTsvCell(oRec, "parent_run_id") & vbTab & LogTsvCell(oRec, "skill") & vbTab & _
                   LogTsvCell(oRec, "phase") & vbTab & LogTsvCell(oRec, "level") & vbTab & _
                   LogTsvCell(oRec, "status") & vbTab & LogTsvCell(oRec, "step") & vbTab & _
                   LogTsvCell(oRec, "exit_code") & vbTab & LogTsvCell(oRec, "duration_ms") & vbTab & _
                   LogTsvCell(oRec, "error_class") & vbTab & LogTsvCell(oRec, "msg") & vbTab & _
                   LogTsvCell(oRec, "error_msg") & vbTab & LogTsvCell(oRec, "~params")
End Function

Function LogRecGet(oRec, sKey)
    If oRec.Exists(sKey) Then LogRecGet = oRec(sKey) : Exit Function
    If oRec.Exists("~" & sKey) Then LogRecGet = oRec("~" & sKey) : Exit Function
    LogRecGet = ""
End Function

Function LogRenderText(oRec)
    Dim phase : phase = oRec("phase")
    Dim tail : tail = ""
    If phase = "start" Then
        Dim p : p = "{}"
        If oRec.Exists("~params") Then p = oRec("~params")
        tail = "START params=" & p
    ElseIf phase = "step" Then
        tail = "[" & oRec("step") & "] " & oRec("msg")
    ElseIf phase = "end" Then
        tail = "END status=" & oRec("status") & " exit=" & LogRecGet(oRec, "exit_code") & " duration_ms=" & LogRecGet(oRec, "duration_ms")
        If oRec.Exists("error_class") Then tail = tail & " error_class=" & oRec("error_class")
        If oRec.Exists("error_msg") Then tail = tail & " error_msg=" & Replace(Replace(oRec("error_msg"), vbCrLf, " / "), vbLf, " / ")
    End If
    LogRenderText = oRec("ts") & " " & Left(oRec("level") & "     ", 5) & " " & oRec("skill") & "[" & oRec("run_id") & "] " & tail
End Function

' Rotate file if size >= MaxSizeMB. Shifts .N-1 -> .N etc.
Sub LogRotateIfNeeded(sPath)
    Dim cfg : Set cfg = LogGetSettings()
    Dim maxMB : maxMB = cfg("MaxSizeMB")
    If maxMB <= 0 Then Exit Sub
    Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
    If Not oFSO.FileExists(sPath) Then Exit Sub
    Dim sz : sz = oFSO.GetFile(sPath).Size
    If sz < maxMB * 1024 * 1024 Then Exit Sub

    Dim n : n = cfg("MaxBackups")
    Dim i, src, dst
    On Error Resume Next
    For i = n To 1 Step -1
        If i = 1 Then
            src = sPath
        Else
            src = sPath & "." & (i - 1)
        End If
        dst = sPath & "." & i
        If oFSO.FileExists(src) Then
            If i = n And oFSO.FileExists(dst) Then oFSO.DeleteFile dst, True
            oFSO.MoveFile src, dst
        End If
    Next
    On Error GoTo 0
End Sub

Sub LogConsoleEcho(sLine, sLevel)
    Dim cfg : Set cfg = LogGetSettings()
    If Not cfg("ConsoleEcho") Then Exit Sub
    On Error Resume Next
    If sLevel = "ERROR" Or sLevel = "WARN" Then
        WScript.StdErr.WriteLine sLine
    Else
        WScript.StdOut.WriteLine sLine
    End If
    On Error GoTo 0
End Sub

' Append a single line to the log file using FSO ForAppending (mode 8).
'
' Why atomic-append matters: the prior implementation did a read-modify-write
' (LoadFromFile -> ReadText -> WriteText with full prior content + new line
' -> SaveToFile overwrite). When two writers raced -- e.g. a PS skill and a
' VBS skill emitting concurrently to the same daily file, or two VBS skills
' launched back-to-back -- the second writer's read happened BEFORE the
' first writer's save, then its save overwrote with stale content. Net
' result: only the latest writer's records survived. User observed
' 2026-05-11: "only the newest one is remained".
'
' FSO ForAppending opens the file with the OS's native append semantics
' (FILE_APPEND_DATA / OPEN_ALWAYS) so concurrent appenders interleave
' record-by-record instead of clobbering each other.
'
' Encoding: FSO writes at the system default codepage (format=0). The
' content is pure 7-bit ASCII because LogJsonEscape now escapes every
' character >= 127 as \uXXXX -- so the on-disk bytes match exactly what
' the PS-side appender (UTF-8 no-BOM) would write for the same content.
' Both paths produce a byte-identical, parseable JSONL stream.
'
' Writes a TSV header automatically when format=TSV and the file is new.
Sub LogAppendLine(sPath, sLine)
    Dim cfg : Set cfg = LogGetSettings()
    LogRotateIfNeeded sPath

    Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
    Dim bIsNew : bIsNew = Not oFSO.FileExists(sPath)

    On Error Resume Next
    Dim oTS : Set oTS = oFSO.OpenTextFile(sPath, 8, True, 0)
    If Err.Number <> 0 Or oTS Is Nothing Then
        ' If the directory doesn't exist yet, create it and retry once.
        Err.Clear
        Dim sDir : sDir = oFSO.GetParentFolderName(sPath)
        If sDir <> "" And Not oFSO.FolderExists(sDir) Then
            oFSO.CreateFolder sDir
        End If
        Set oTS = oFSO.OpenTextFile(sPath, 8, True, 0)
        If Err.Number <> 0 Or oTS Is Nothing Then
            ' Logging is best-effort -- silently swallow on retry failure.
            Err.Clear
            Exit Sub
        End If
    End If

    If bIsNew And cfg("Format") = "TSV" Then
        oTS.WriteLine LogTsvHeader()
    End If
    oTS.WriteLine sLine
    oTS.Close
    Err.Clear
    On Error GoTo 0
End Sub

' Render a record dictionary using the configured format and append it.
Sub LogEmit(sPath, oRec, sLevel)
    Dim cfg : Set cfg = LogGetSettings()
    Dim sLine
    Select Case cfg("Format")
        Case "TSV"  : sLine = LogRenderTsv(oRec)
        Case "TEXT" : sLine = LogRenderText(oRec)
        Case Else   : sLine = LogRenderJson(oRec)
    End Select
    LogAppendLine sPath, sLine
    LogConsoleEcho sLine, sLevel
End Sub

' Returns runId string. sParamPairs is an Array("k","v","k2","v2",...) (may be Empty).
Function LogStart(sSkill, vParamPairs)
    Dim cfg : Set cfg = LogGetSettings()
    Dim oWsh : Set oWsh = CreateObject("WScript.Shell")

    Dim parentId : parentId = oWsh.ExpandEnvironmentStrings("%SAPDEV_RUN_ID%")
    If parentId = "%SAPDEV_RUN_ID%" Then parentId = ""

    Dim runId : runId = LogNewRunId()
    Dim path  : path  = LogResolvePath(sSkill, runId)

    Dim run : Set run = CreateObject("Scripting.Dictionary")
    run("Skill")    = sSkill
    run("RunId")    = runId
    run("Parent")   = parentId
    run("Path")     = path
    run("Start")    = Timer
    run("Enabled")  = cfg("Enabled")
    run("LevelNum") = cfg("LevelNum")
    g_LogRuns.Add runId, run

    On Error Resume Next
    oWsh.Environment("Process").Item("SAPDEV_PARENT_RUN_ID") = parentId
    oWsh.Environment("Process").Item("SAPDEV_RUN_ID")        = runId
    On Error GoTo 0

    LogStart = runId
    If Not cfg("Enabled") Then Exit Function
    If g_LogLevels("INFO") < cfg("LevelNum") Then Exit Function

    Dim vRedacted : vRedacted = LogRedactPairs(vParamPairs)
    Dim sParams : sParams = LogPairsToJson(vRedacted)

    Dim rec : Set rec = CreateObject("Scripting.Dictionary")
    rec("ts")            = LogIsoNow()
    rec("run_id")        = runId
    rec("parent_run_id") = parentId
    rec("skill")         = sSkill
    rec("phase")         = "start"
    rec("level")         = "INFO"
    rec("host")          = oWsh.ExpandEnvironmentStrings("%COMPUTERNAME%")
    rec("os_user")       = oWsh.ExpandEnvironmentStrings("%USERNAME%")
    rec("~params")       = sParams   ' raw JSON (already an object)
    LogEmit path, rec, "INFO"
End Function

Sub LogStep(sRunId, sLevel, sStep, sMsg)
    If Not g_LogRuns.Exists(sRunId) Then Exit Sub
    Dim run : Set run = g_LogRuns(sRunId)
    If Not run("Enabled") Then Exit Sub
    sLevel = UCase(sLevel)
    If Not g_LogLevels.Exists(sLevel) Then sLevel = "INFO"
    If g_LogLevels(sLevel) < run("LevelNum") Then Exit Sub

    Dim rec : Set rec = CreateObject("Scripting.Dictionary")
    rec("ts")            = LogIsoNow()
    rec("run_id")        = sRunId
    rec("parent_run_id") = run("Parent")
    rec("skill")         = run("Skill")
    rec("phase")         = "step"
    rec("level")         = sLevel
    rec("step")          = sStep
    rec("msg")           = sMsg
    LogEmit run("Path"), rec, sLevel
End Sub

Sub LogEnd(sRunId, sStatus, iExitCode, sErrorMsg)
    If Not g_LogRuns.Exists(sRunId) Then Exit Sub
    Dim run : Set run = g_LogRuns(sRunId)

    Dim oWsh : Set oWsh = CreateObject("WScript.Shell")
    On Error Resume Next
    If oWsh.Environment("Process").Item("SAPDEV_RUN_ID") = sRunId Then
        oWsh.Environment("Process").Item("SAPDEV_RUN_ID") = run("Parent")
    End If
    On Error GoTo 0

    If Not run("Enabled") Then
        g_LogRuns.Remove sRunId
        Exit Sub
    End If

    sStatus = UCase(sStatus)
    Dim sLevel : sLevel = "INFO"
    If sStatus = "FAILED" Or sStatus = "ABANDONED" Then sLevel = "ERROR"
    If g_LogLevels(sLevel) < run("LevelNum") Then
        g_LogRuns.Remove sRunId
        Exit Sub
    End If

    Dim durMs : durMs = CLng((Timer - run("Start")) * 1000)
    If durMs < 0 Then durMs = durMs + 86400000

    Dim rec : Set rec = CreateObject("Scripting.Dictionary")
    rec("ts")            = LogIsoNow()
    rec("run_id")        = sRunId
    rec("parent_run_id") = run("Parent")
    rec("skill")         = run("Skill")
    rec("phase")         = "end"
    rec("level")         = sLevel
    rec("status")        = sStatus
    rec("~exit_code")    = CStr(iExitCode)   ' raw number
    rec("~duration_ms")  = CStr(durMs)       ' raw number
    If Len(sErrorMsg) > 0 Then rec("error_msg") = sErrorMsg

    LogEmit run("Path"), rec, sLevel
    g_LogRuns.Remove sRunId
End Sub

Function LogNewRunId()
    Dim r : r = ""
    Dim i
    Randomize
    For i = 1 To 8
        r = r & Hex(Int(Rnd * 16))
    Next
    LogNewRunId = LCase(r)
End Function

Function LogPairsToJson(v)
    If IsEmpty(v) Then LogPairsToJson = "{}" : Exit Function
    If Not IsArray(v) Then LogPairsToJson = "{}" : Exit Function
    Dim ub : ub = UBound(v)
    If ub < 1 Then LogPairsToJson = "{}" : Exit Function
    Dim s : s = "{"
    Dim i, sep : sep = ""
    For i = 0 To ub - 1 Step 2
        s = s & sep & """" & LogJsonEscape(CStr(v(i))) & """:""" & LogJsonEscape(CStr(v(i+1))) & """"
        sep = ","
    Next
    s = s & "}"
    LogPairsToJson = s
End Function
