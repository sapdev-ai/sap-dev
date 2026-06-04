' =============================================================================
' sap_check_fm.vbs  -  Validate ABAP CALL FUNCTION parameter names and types
'
' Runs via standard cscript.exe. RFC FM-signature and DDIC type lookups are
' delegated to two PowerShell sidecar helpers (NCo 3.1 based):
'   %%FM_HELPER_PS1%%   -- sap_rfc_lookup_fm.ps1   (RPY_FUNCTIONMODULE_READ_NEW + cache, shared)
'   %%DDIC_HELPER_PS1%% -- sap_rfc_lookup_ddic.ps1 (DDIF_FIELDINFO_GET / DD04L)
' DO NOT commit the filled-in version -- it contains plaintext credentials.
'
' Phases:
'   1a. Parse CALL FUNCTION blocks from ABAP source
'   1b. Parse DATA/TYPES declarations to build variable-to-type map
'   2.  Fetch FM definitions via FM helper sidecar
'   2b. Resolve types via DDIC helper sidecar
'   3.  (Type resolution is now lookup-only against pre-loaded dictionaries)
'   4.  Compare parameter names and types; check compatibility
'   5.  Write tab-delimited result file
'
' Tokens replaced at run time by PowerShell [IO.File]::WriteAllText (UTF-16 LE):
'   %%SAP_SERVER%%     Application server host       e.g. "10.0.0.1"
'   %%SAP_SYSNR%%      2-digit system number         e.g. "00"
'   %%SAP_CLIENT%%     3-digit client number         e.g. "100"
'   %%SAP_USER%%       SAP username                  e.g. "DEVELOPER"
'   %%SAP_PASSWORD%%   SAP password
'   %%SAP_LANGUAGE%%   Logon language                e.g. "EN"
'   %%ABAP_FILE%%      Full path to ABAP source file e.g. "C:\src\ZPROGRAM.abap"
'   %%RESULT_FILE%%    Full path to write results    e.g. "{WORK_TEMP}\checkfm_result.txt"
' =============================================================================
Option Explicit

' --- Connection / file parameters ---
Dim SAP_SERVER   : SAP_SERVER   = "%%SAP_SERVER%%"
Dim SAP_SYSNR    : SAP_SYSNR    = "%%SAP_SYSNR%%"
Dim SAP_CLIENT   : SAP_CLIENT   = "%%SAP_CLIENT%%"
Dim SAP_USER     : SAP_USER     = "%%SAP_USER%%"
Dim SAP_PASSWORD : SAP_PASSWORD = "%%SAP_PASSWORD%%"
Dim SAP_LANGUAGE : SAP_LANGUAGE = "%%SAP_LANGUAGE%%"
Dim ABAP_FILE    : ABAP_FILE    = "%%ABAP_FILE%%"
Dim RESULT_FILE  : RESULT_FILE  = "%%RESULT_FILE%%"
Dim FM_HELPER_PS1     : FM_HELPER_PS1     = "%%FM_HELPER_PS1%%"
Dim FM_NAMES_FILE     : FM_NAMES_FILE     = "%%FM_NAMES_FILE%%"
Dim FM_RESULT_FILE    : FM_RESULT_FILE    = "%%FM_RESULT_FILE%%"
Dim DDIC_HELPER_PS1   : DDIC_HELPER_PS1   = "%%DDIC_HELPER_PS1%%"
Dim DDIC_REQUEST_FILE : DDIC_REQUEST_FILE = "%%DDIC_REQUEST_FILE%%"
Dim DDIC_RESULT_FILE  : DDIC_RESULT_FILE  = "%%DDIC_RESULT_FILE%%"

' --- Section index constants ---
Const SECT_EXP = 0   ' EXPORTING  ->  FM IMPORT_PARAMETER
Const SECT_IMP = 1   ' IMPORTING  ->  FM EXPORT_PARAMETER
Const SECT_CHG = 2   ' CHANGING   ->  FM CHANGING_PARAMETER
Const SECT_TBL = 3   ' TABLES     ->  FM TABLE_PARAMETER
Const SECT_EXC = 4   ' EXCEPTIONS ->  FM EXCEPTION

' --- Type kind constants ---
Const TK_STRUCT  = "STRUCT"
Const TK_DTEL    = "DTEL"
Const TK_BUILTIN = "BUILTIN"
Const TK_UNKNOWN = "UNKNOWN"

' =============================================================================
' Globals
' =============================================================================
Dim g_fso
Set g_fso = CreateObject("Scripting.FileSystemObject")

Dim g_results()
ReDim g_results(0)
g_results(0) = ""

Dim g_varTypes
Set g_varTypes = CreateObject("Scripting.Dictionary")
g_varTypes.CompareMode = 1

Dim g_typeKind
Dim g_typeFields
Dim g_typeDtel
Set g_typeKind   = CreateObject("Scripting.Dictionary")
Set g_typeFields = CreateObject("Scripting.Dictionary")
Set g_typeDtel   = CreateObject("Scripting.Dictionary")
g_typeKind.CompareMode   = 1
g_typeFields.CompareMode = 1
g_typeDtel.CompareMode   = 1

' (RFC calls are delegated to PowerShell sidecar helpers; no SAP.Functions COM object.)

' =============================================================================
' Helpers
' =============================================================================
Sub AddResult(s)
    Dim n : n = UBound(g_results)
    If n = 0 And g_results(0) = "" Then
        g_results(0) = s
    Else
        ReDim Preserve g_results(n + 1)
        g_results(n + 1) = s
    End If
End Sub

Sub WriteResults(statusLine)
    Dim f
    Set f = g_fso.CreateTextFile(RESULT_FILE, True)
    f.WriteLine statusLine
    f.WriteLine "ABAP_FILE" & vbTab & ABAP_FILE
    f.WriteLine "TIMESTAMP" & vbTab & Now()
    f.WriteLine ""
    Dim i
    For i = 0 To UBound(g_results)
        If g_results(i) <> "" Then f.WriteLine g_results(i)
    Next
    f.Close
    WScript.Echo statusLine
End Sub

Sub AbortError(msg)
    WriteResults "STATUS: ERROR: " & msg
    WScript.Quit 1
End Sub

Function UCT(s)
    UCT = UCase(Trim(s))
End Function

Function StripComment(s)
    Dim i, ch, inStr, result
    inStr  = False
    result = ""
    For i = 1 To Len(s)
        ch = Mid(s, i, 1)
        If inStr Then
            result = result & ch
            If ch = "'" Then inStr = False
        Else
            If ch = "'" Then
                inStr = True
                result = result & ch
            ElseIf ch = Chr(34) Then
                Exit For
            Else
                result = result & ch
            End If
        End If
    Next
    StripComment = result
End Function

Function ExtractQuoted(s)
    Dim p1, p2
    p1 = InStr(s, "'")
    If p1 = 0 Then ExtractQuoted = "" : Exit Function
    p2 = InStr(p1 + 1, s, "'")
    If p2 = 0 Then ExtractQuoted = "" : Exit Function
    ExtractQuoted = Mid(s, p1 + 1, p2 - p1 - 1)
End Function

' Returns section index (0-4) or -1
Function GetSectionKw(s)
    Select Case UCT(StripComment(s))
        Case "EXPORTING"  : GetSectionKw = SECT_EXP
        Case "IMPORTING"  : GetSectionKw = SECT_IMP
        Case "CHANGING"   : GetSectionKw = SECT_CHG
        Case "TABLES"     : GetSectionKw = SECT_TBL
        Case "EXCEPTIONS" : GetSectionKw = SECT_EXC
        Case Else         : GetSectionKw = -1
    End Select
End Function

Function FirstToken(s)
    Dim u, sp, tok
    u  = UCT(Trim(s))
    sp = InStr(u, " ")
    If sp > 0 Then tok = Left(u, sp - 1) Else tok = u
    If Right(tok, 1) = "." Then tok = Left(tok, Len(tok) - 1)
    If Right(tok, 1) = ":" Then tok = Left(tok, Len(tok) - 1)
    FirstToken = tok
End Function

Function IsBlockEnd(rawLine)
    Dim u, tok
    If Left(Trim(rawLine), 1) = "*" Then IsBlockEnd = False : Exit Function
    u = UCT(StripComment(rawLine))
    If u = "" Then IsBlockEnd = False : Exit Function
    If u = "." Then IsBlockEnd = True : Exit Function
    ' Lines with `=` (and not the type-comparison `=>` arrow) inside a
    ' CALL FUNCTION block are parameter assignments, never block ends —
    ' even when the parameter name collides with an ABAP keyword like
    ' RETURN, MESSAGE, CHECK, EXIT, or DATA. The most common collision
    ' is `RETURN = ls_return` for BAPI standard return structures.
    Dim eq : eq = InStr(rawLine, "=")
    If eq > 0 Then
        If Mid(rawLine, eq, 2) <> "=>" Then
            IsBlockEnd = False : Exit Function
        End If
    End If
    tok = FirstToken(u)
    Select Case tok
        Case "EXPORTING","IMPORTING","CHANGING","TABLES","EXCEPTIONS"
            IsBlockEnd = False
        Case "CALL","IF","ELSE","ELSEIF","ENDIF","LOOP","ENDLOOP", _
             "DO","ENDDO","WHILE","ENDWHILE","CASE","WHEN","ENDCASE", _
             "SELECT","ENDSELECT","MOVE","WRITE","PERFORM","FORM", _
             "ENDFORM","FUNCTION","ENDFUNCTION","MODULE","ENDMODULE", _
             "CLASS","ENDCLASS","METHOD","ENDMETHOD","DATA","TYPES", _
             "CONSTANTS","FIELD-SYMBOLS","ASSIGN","READ","APPEND", _
             "INSERT","DELETE","MODIFY","COLLECT","CHECK","EXIT", _
             "RETURN","RAISE","MESSAGE","COMMIT","ROLLBACK","SUBMIT", _
             "AUTHORITY-CHECK","CREATE","FREE","CLEAR","REFRESH", _
             "SORT","DESCRIBE","OPEN","CLOSE","TRANSFER","GET", _
             "SET","REPORT","PROGRAM","AT","ENDAT","CATCH","ENDTRY", _
             "TRY","CLEANUP","RESUME"
            IsBlockEnd = True
        Case Else
            IsBlockEnd = True
    End Select
End Function

Function IsDataDecl(tok)
    Select Case tok
        Case "DATA","TYPES","CONSTANTS","FIELD-SYMBOLS","CLASS-DATA","STATICS"
            IsDataDecl = True
        Case Else
            IsDataDecl = False
    End Select
End Function

Sub ParseDeclSegment(seg)
    Dim s : s = Trim(seg)
    If s = "" Then Exit Sub
    Do While Len(s) > 0 And (Right(s,1) = "." Or Right(s,1) = ",")
        s = Trim(Left(s, Len(s) - 1))
    Loop
    Dim sp1 : sp1 = InStr(s, " ")
    If sp1 = 0 Then Exit Sub
    Dim varName : varName = UCT(Left(s, sp1 - 1))
    varName = Replace(Replace(varName, "<", ""), ">", "")
    If varName = "" Then Exit Sub
    Dim rest : rest = UCT(Mid(s, sp1 + 1))
    Dim typePos : typePos = InStr(" " & rest & " ", " TYPE ")
    If typePos = 0 Then Exit Sub
    Dim typeRef : typeRef = Trim(Mid(rest, typePos + 5))
    Do While Len(typeRef) > 0 And (Right(typeRef,1) = "." Or Right(typeRef,1) = ",")
        typeRef = Trim(Left(typeRef, Len(typeRef) - 1))
    Loop
    If typeRef = "" Then Exit Sub
    Dim ftok : ftok = FirstToken(typeRef)
    If ftok = "C" Or ftok = "N" Or ftok = "X" Or ftok = "P" Then
        Dim lpos : lpos = InStr(UCT(typeRef), "LENGTH ")
        Dim lenVal : lenVal = ""
        If lpos > 0 Then lenVal = Trim(Mid(typeRef, lpos + 7))
        g_varTypes(varName) = "BUILTIN:" & ftok & ":" & lenVal
    ElseIf Left(UCT(typeRef), 9) = "TABLE OF " Then
        g_varTypes(varName) = UCT(typeRef)
    ElseIf Left(UCT(typeRef), 7) = "REF TO " Then
        g_varTypes(varName) = TK_UNKNOWN
    Else
        g_varTypes(varName) = UCT(ftok)
    End If
End Sub

' =============================================================================
' PHASE 1 -- Parse ABAP source
' =============================================================================
On Error Resume Next
If Not g_fso.FileExists(ABAP_FILE) Then
    AbortError "ABAP file not found: " & ABAP_FILE
End If

Dim ts
Set ts = g_fso.OpenTextFile(ABAP_FILE, 1)
Dim allLines()
Dim lineCount : lineCount = 0
ReDim allLines(0)
Do While Not ts.AtEndOfStream
    ReDim Preserve allLines(lineCount)
    allLines(lineCount) = ts.ReadLine
    lineCount = lineCount + 1
Loop
ts.Close
On Error GoTo 0

If lineCount = 0 Then AbortError "ABAP file is empty: " & ABAP_FILE

' ---- 1a. Parse CALL FUNCTION blocks ----
Dim cfFM(500)
Dim cfLine(500)
Dim cfPNames(500, 4)
Dim cfPVals(500, 4)
Dim cfCount : cfCount = 0

Dim li, rawLine, cleanLine, uLine
Dim inBlock  : inBlock  = False
Dim curFMIdx : curFMIdx = -1
Dim curSect  : curSect  = -1

For li = 0 To lineCount - 1
    rawLine = allLines(li)

    If Left(Trim(rawLine), 1) <> "*" Then
        cleanLine = StripComment(rawLine)
        uLine     = UCT(cleanLine)

        If inBlock Then
            Dim kw : kw = GetSectionKw(cleanLine)
            If kw >= 0 Then
                curSect = kw
            ElseIf IsBlockEnd(rawLine) Then
                inBlock = False
                curSect = -1
                ' Check if this block-ending line itself is a new CALL FUNCTION
                If Left(uLine, 13) = "CALL FUNCTION" Then
                    Dim fmN1 : fmN1 = UCT(ExtractQuoted(cleanLine))
                    If fmN1 <> "" And cfCount < 500 Then
                        cfFM(cfCount)   = fmN1
                        cfLine(cfCount) = li + 1
                        Dim si1
                        For si1 = 0 To 4
                            cfPNames(cfCount, si1) = ""
                            cfPVals(cfCount, si1)  = ""
                        Next
                        curFMIdx = cfCount
                        cfCount  = cfCount + 1
                        inBlock  = True
                        curSect  = -1
                    End If
                Else
                    curFMIdx = -1
                End If
            Else
                ' Parameter assignment
                If curSect >= 0 And InStr(cleanLine, "=") > 0 Then
                    Dim eqPos : eqPos = InStr(cleanLine, "=")
                    If Mid(cleanLine, eqPos, 2) <> "=>" Then
                        Dim pName : pName = UCT(Left(cleanLine, eqPos - 1))
                        Dim pVal  : pVal  = UCT(Trim(Mid(cleanLine, eqPos + 1)))
                        Do While Len(pVal) > 0 And (Right(pVal,1) = "." Or Right(pVal,1) = ",")
                            pVal = Trim(Left(pVal, Len(pVal) - 1))
                        Loop
                        If pName <> "" And curFMIdx >= 0 Then
                            If cfPNames(curFMIdx, curSect) = "" Then
                                cfPNames(curFMIdx, curSect) = pName
                                cfPVals(curFMIdx, curSect)  = pVal
                            Else
                                cfPNames(curFMIdx, curSect) = cfPNames(curFMIdx, curSect) & "|" & pName
                                cfPVals(curFMIdx, curSect)  = cfPVals(curFMIdx, curSect)  & "|" & pVal
                            End If
                        End If
                    End If
                End If

                ' A trailing period on a parameter-assignment line is the
                ' statement terminator for the entire CALL FUNCTION — close
                ' the block here. Without this guard the parser kept
                ' inBlock=True after lines like `et_return = lt_return.`
                ' and mis-attributed the following DATA(...), IF, and
                ' method-EXPORTING name= lines as bogus FM params. Bug
                ' surfaced 2026-05-11 PM (third regression run, agent
                ' a8a675bc31c82fdb5) on BAPI_MATERIAL_SAVEDATA — 6+ false
                ' positives. IsBlockEnd above intentionally returns False
                ' for lines containing `=` (to keep `RETURN = ls_return`
                ' style assignments inside the block), so we close the
                ' block here based on the trailing-period evidence.
                Dim trimmedEnd : trimmedEnd = Trim(cleanLine)
                If Len(trimmedEnd) > 0 And Right(trimmedEnd, 1) = "." Then
                    inBlock  = False
                    curSect  = -1
                    curFMIdx = -1
                End If
            End If
        Else
            ' Not in block -- check for CALL FUNCTION
            If Left(uLine, 13) = "CALL FUNCTION" Then
                Dim fmN2 : fmN2 = UCT(ExtractQuoted(cleanLine))
                If fmN2 <> "" And cfCount < 500 Then
                    cfFM(cfCount)   = fmN2
                    cfLine(cfCount) = li + 1
                    Dim si2
                    For si2 = 0 To 4
                        cfPNames(cfCount, si2) = ""
                        cfPVals(cfCount, si2)  = ""
                    Next
                    curFMIdx = cfCount
                    cfCount  = cfCount + 1
                    inBlock  = True
                    curSect  = -1
                End If
            End If
        End If
    End If
Next

If cfCount = 0 Then AbortError "No CALL FUNCTION statements found in: " & ABAP_FILE
WScript.Echo "INFO: Found " & cfCount & " CALL FUNCTION statement(s)."

' ---- 1b. Parse DATA/TYPES declarations ----
Dim inChain  : inChain  = False
Dim chainBuf : chainBuf = ""
Dim declCount : declCount = 0

For li = 0 To lineCount - 1
    rawLine   = allLines(li)
    cleanLine = Trim(StripComment(rawLine))
    If Left(cleanLine, 1) <> "*" And Left(cleanLine, 1) <> "!" Then
        If inChain Then
            chainBuf = chainBuf & " " & cleanLine
            If InStr(cleanLine, ".") > 0 Then
                inChain = False
                Dim cp1 : cp1 = InStr(chainBuf, ":")
                Dim db1 : db1 = ""
                If cp1 > 0 Then db1 = Mid(chainBuf, cp1 + 1) Else db1 = chainBuf
                Dim segs1 : segs1 = Split(db1, ",")
                Dim s1
                For Each s1 In segs1
                    ParseDeclSegment s1
                    declCount = declCount + 1
                Next
                chainBuf = ""
            End If
        Else
            Dim ftok2 : ftok2 = FirstToken(cleanLine)
            If IsDataDecl(ftok2) Then
                Dim hasColon  : hasColon  = InStr(cleanLine, ":")
                Dim hasPeriod : hasPeriod = InStr(cleanLine, ".")
                If hasColon > 0 And (hasPeriod = 0 Or hasPeriod < hasColon) Then
                    inChain  = True
                    chainBuf = cleanLine
                    If hasPeriod > 0 Then
                        inChain = False
                        Dim cp2 : cp2 = InStr(chainBuf, ":")
                        Dim db2 : db2 = ""
                        If cp2 > 0 Then db2 = Mid(chainBuf, cp2 + 1) Else db2 = chainBuf
                        Dim segs2 : segs2 = Split(db2, ",")
                        Dim s2
                        For Each s2 In segs2
                            ParseDeclSegment s2
                            declCount = declCount + 1
                        Next
                        chainBuf = ""
                    End If
                Else
                    Dim sp3 : sp3 = InStr(cleanLine, " ")
                    Dim bd3 : bd3 = ""
                    If sp3 > 0 Then bd3 = Mid(cleanLine, sp3 + 1)
                    ParseDeclSegment bd3
                    declCount = declCount + 1
                End If
            End If
        End If
    End If
Next

WScript.Echo "INFO: Found " & declCount & " declaration(s), " & g_varTypes.Count & " type entries."

' =============================================================================
' PHASE 2 -- Fetch FM definitions via sap_rfc_lookup_fm.ps1 sidecar (shared, cached)
' =============================================================================
' Collect unique FM names
Dim uniqFMs(500)
Dim uniqCount : uniqCount = 0
Dim fi, fj, fmSeen
For fi = 0 To cfCount - 1
    fmSeen = False
    For fj = 0 To uniqCount - 1
        If uniqFMs(fj) = cfFM(fi) Then fmSeen = True : Exit For
    Next
    If Not fmSeen Then
        uniqFMs(uniqCount) = cfFM(fi)
        uniqCount = uniqCount + 1
    End If
Next

If uniqCount = 0 Then
    AbortError "No CALL FUNCTION blocks parsed from " & ABAP_FILE
End If

' Write FM names file (helper reads this when its own %%FM_NAMES%% token is left blank)
Dim fmnf : Set fmnf = g_fso.CreateTextFile(FM_NAMES_FILE, True, False)
Dim fmni
For fmni = 0 To uniqCount - 1
    fmnf.WriteLine uniqFMs(fmni)
Next
fmnf.Close

WScript.Echo "INFO: Invoking FM helper for " & uniqCount & " unique FM(s): " & FM_HELPER_PS1
Dim wsh : Set wsh = CreateObject("WScript.Shell")
Dim fmCmd : fmCmd = "C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File """ & FM_HELPER_PS1 & """"
Dim fmRc : fmRc = wsh.Run(fmCmd, 0, True)
WScript.Echo "INFO: FM helper exit code = " & fmRc

If Not g_fso.FileExists(FM_RESULT_FILE) Then
    AbortError "FM helper produced no result file: " & FM_RESULT_FILE
End If

' =============================================================================
' Storage for FM definitions
' =============================================================================
Dim fmDefName(200)
Dim fmDefValid(200)
Dim fmDefParamNames(200, 4)
Dim fmDefParamOpt(200, 4)
Dim fmDefParamType(200, 4)
Dim fmDefCount : fmDefCount = 0

' Section name -> SECT_* index
Dim sectMap : Set sectMap = CreateObject("Scripting.Dictionary")
sectMap.CompareMode = 1
sectMap("EXPORTING")  = SECT_EXP
sectMap("IMPORTING")  = SECT_IMP
sectMap("CHANGING")   = SECT_CHG
sectMap("TABLES")     = SECT_TBL
sectMap("EXCEPTIONS") = SECT_EXC

' Pre-create slots for each unique FM
Dim ufIdx, ssi
For ufIdx = 0 To uniqCount - 1
    fmDefName(ufIdx)  = uniqFMs(ufIdx)
    fmDefValid(ufIdx) = False
    For ssi = 0 To 4
        fmDefParamNames(ufIdx, ssi) = ""
        fmDefParamOpt(ufIdx, ssi)   = ""
        fmDefParamType(ufIdx, ssi)  = ""
    Next
Next
fmDefCount = uniqCount

' Helper to find slot by FM name
Dim fmIdxMap : Set fmIdxMap = CreateObject("Scripting.Dictionary")
fmIdxMap.CompareMode = 1
For ufIdx = 0 To uniqCount - 1
    fmIdxMap(UCT(uniqFMs(ufIdx))) = ufIdx
Next

' Parse FM helper TSV: FM<TAB>SECTION<TAB>PARAM<TAB>OPTIONAL<TAB>TYPE_REF<TAB>TYPE_KIND
'
' Defensive BOM-strip: the helper script used to write cache files with
' [System.Text.Encoding]::UTF8 (BOM-emitting), and OpenTextFile with
' TristateFalse reads bytes 0xEF/0xBB/0xBF verbatim as characters. Glued
' to the start of the first column of every cache file, they made the FM
' name unmatchable and silently dropped the first row of each FM
' (typically HEADDATA on BAPI_*_SAVEDATA). The helper is now BOM-free,
' but legacy cache files in {fm_cache_dir} live until TTL; strip any
' leading BOM here so older caches don't keep biting.
Dim BOM_UTF8 : BOM_UTF8 = Chr(&HEF) & Chr(&HBB) & Chr(&HBF)
Dim fmFr : Set fmFr = g_fso.OpenTextFile(FM_RESULT_FILE, 1, False, 0)
Dim fmFirstLine : fmFirstLine = True
Do Until fmFr.AtEndOfStream
    Dim fmLine : fmLine = fmFr.ReadLine
    If fmFirstLine Then
        If Left(fmLine, 3) = BOM_UTF8 Then fmLine = Mid(fmLine, 4)
        fmFirstLine = False
    End If
    ' Cache files were concatenated in PHASE 2 — strip BOM mid-stream too
    ' in case a cache file was written individually with BOM and pasted
    ' into the result.
    If Len(fmLine) >= 3 Then
        If Left(fmLine, 3) = BOM_UTF8 Then fmLine = Mid(fmLine, 4)
    End If
    If fmLine <> "" Then
        Dim fmCols : fmCols = Split(fmLine, vbTab)
        If UBound(fmCols) >= 4 Then
            Dim fmNm   : fmNm   = UCT(Trim(fmCols(0)))
            Dim fmSect : fmSect = Trim(fmCols(1))
            Dim fmPnm  : fmPnm  = UCT(Trim(fmCols(2)))
            Dim fmOpt  : fmOpt  = fmCols(3)
            Dim fmTRef : fmTRef = UCT(Trim(fmCols(4)))
            Dim fmTKind : fmTKind = ""
            If UBound(fmCols) >= 5 Then fmTKind = UCT(Trim(fmCols(5)))

            If fmIdxMap.Exists(fmNm) And sectMap.Exists(fmSect) Then
                Dim slotIdx : slotIdx = fmIdxMap(fmNm)
                Dim sIdx    : sIdx    = sectMap(fmSect)
                ' Decorate type reference based on kind
                Dim pTypeRef : pTypeRef = ""
                If fmTKind = "TYP" And fmTRef <> "" Then
                    pTypeRef = "BUILTIN:" & fmTRef & ":"
                Else
                    pTypeRef = fmTRef ' TAB / TDEF / "" -> use as-is
                End If
                If fmDefParamNames(slotIdx, sIdx) = "" Then
                    fmDefParamNames(slotIdx, sIdx) = fmPnm
                    fmDefParamOpt(slotIdx, sIdx)   = fmOpt
                    fmDefParamType(slotIdx, sIdx)  = pTypeRef
                Else
                    fmDefParamNames(slotIdx, sIdx) = fmDefParamNames(slotIdx, sIdx) & "|" & fmPnm
                    fmDefParamOpt(slotIdx, sIdx)   = fmDefParamOpt(slotIdx, sIdx)   & "|" & fmOpt
                    fmDefParamType(slotIdx, sIdx)  = fmDefParamType(slotIdx, sIdx)  & "|" & pTypeRef
                End If
                fmDefValid(slotIdx) = True
            End If
        End If
    End If
Loop
fmFr.Close

' Mark FMs with no rows as invalid
For ufIdx = 0 To uniqCount - 1
    If Not fmDefValid(ufIdx) Then
        AddResult "FM_ERROR" & vbTab & fmDefName(ufIdx) & vbTab & "Not found via RPY_FUNCTIONMODULE_READ_NEW (helper sidecar)"
    End If
Next

' =============================================================================
' PHASE 2b -- Resolve all referenced types via DDIC sidecar
' =============================================================================
Dim ddicNames : Set ddicNames = CreateObject("Scripting.Dictionary")
ddicNames.CompareMode = 1

' Collect from FM parameter types
Dim ti, sj
For ti = 0 To fmDefCount - 1
    If fmDefValid(ti) Then
        For sj = 0 To 3
            If fmDefParamType(ti, sj) <> "" Then
                Dim tArr : tArr = Split(fmDefParamType(ti, sj), "|")
                Dim tE
                For Each tE In tArr
                    ' Skip empty, BUILTIN:*, TABLE OF *
                    If tE <> "" And Left(tE, 8) <> "BUILTIN:" And Left(tE, 9) <> "TABLE OF " Then
                        If Not ddicNames.Exists(tE) Then ddicNames(tE) = True
                    End If
                Next
            End If
        Next
    End If
Next

' Collect from variable type map
Dim vk
For Each vk In g_varTypes.Keys
    Dim vt : vt = UCT(g_varTypes(vk))
    If vt <> "" And Left(vt, 8) <> "BUILTIN:" And Left(vt, 9) <> "TABLE OF " Then
        If Not ddicNames.Exists(vt) Then ddicNames(vt) = True
    End If
Next

If ddicNames.Count > 0 And DDIC_HELPER_PS1 <> "" Then
    WScript.Echo "INFO: Invoking DDIC helper for " & ddicNames.Count & " type(s): " & DDIC_HELPER_PS1
    Dim fReq : Set fReq = g_fso.CreateTextFile(DDIC_REQUEST_FILE, True, False)
    Dim dn
    For Each dn In ddicNames.Keys
        fReq.WriteLine dn
    Next
    fReq.Close

    Dim ddicCmd : ddicCmd = "C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File """ & DDIC_HELPER_PS1 & """"
    Dim ddicRc : ddicRc = wsh.Run(ddicCmd, 0, True)
    WScript.Echo "INFO: DDIC helper exit code = " & ddicRc

    If g_fso.FileExists(DDIC_RESULT_FILE) Then
        Dim dFr : Set dFr = g_fso.OpenTextFile(DDIC_RESULT_FILE, 1, False, 0)
        Do Until dFr.AtEndOfStream
            Dim dLine : dLine = dFr.ReadLine
            If dLine <> "" Then
                Dim dCols : dCols = Split(dLine, vbTab)
                If UBound(dCols) >= 1 Then
                    Dim dNm : dNm = UCT(Trim(dCols(0)))
                    Dim dKd : dKd = Trim(dCols(1))
                    Dim dDat : dDat = ""
                    If UBound(dCols) >= 2 Then dDat = dCols(2)
                    If dKd = TK_STRUCT Then
                        g_typeKind(dNm)   = TK_STRUCT
                        g_typeFields(dNm) = dDat
                    ElseIf dKd = TK_DTEL Then
                        g_typeKind(dNm) = TK_DTEL
                        g_typeDtel(dNm) = dDat   ' "DT:LEN:DEC"
                    Else
                        g_typeKind(dNm) = TK_UNKNOWN
                    End If
                End If
            End If
        Loop
        dFr.Close
        WScript.Echo "INFO: DDIC lookup complete (" & g_typeKind.Count & " entries)."
    End If
End If

' =============================================================================
' PHASE 3 -- Type resolution (now lookup-only)
' =============================================================================
Sub ResolveType(typeName)
    If typeName = "" Or typeName = TK_UNKNOWN Then Exit Sub
    If g_typeKind.Exists(typeName) Then Exit Sub

    If Left(typeName, 8) = "BUILTIN:" Then
        g_typeKind(typeName) = TK_BUILTIN
        g_typeDtel(typeName) = typeName
        Exit Sub
    End If

    If Left(typeName, 9) = "TABLE OF " Then
        Dim innerType : innerType = UCT(Trim(Mid(typeName, 10)))
        ResolveType innerType
        If g_typeKind.Exists(innerType) Then
            g_typeKind(typeName) = g_typeKind(innerType)
            If g_typeFields.Exists(innerType) Then g_typeFields(typeName) = g_typeFields(innerType)
            If g_typeDtel.Exists(innerType)   Then g_typeDtel(typeName)   = g_typeDtel(innerType)
        Else
            g_typeKind(typeName) = TK_UNKNOWN
        End If
        Exit Sub
    End If

    ' Not pre-loaded by sidecar -> mark unknown
    g_typeKind(typeName) = TK_UNKNOWN
End Sub

' Resolve the type of a variable reference from the source
Function ResolveVarType(varRef)
    Dim v : v = UCT(Trim(varRef))
    If v = "" Or Left(v, 1) = "'" Then ResolveVarType = TK_UNKNOWN : Exit Function
    If Left(v, 3) = "SY-" Or Left(v, 5) = "SYST-" Then ResolveVarType = TK_UNKNOWN : Exit Function

    Dim dashPos : dashPos = InStr(v, "-")
    If dashPos > 0 Then
        ' Structure component: LS_EKKO-BUKRS
        Dim sVar : sVar  = Left(v, dashPos - 1)
        Dim comp : comp  = Mid(v, dashPos + 1)
        If Not g_varTypes.Exists(sVar) Then ResolveVarType = TK_UNKNOWN : Exit Function
        Dim sType : sType = g_varTypes(sVar)
        ResolveType sType
        If Not g_typeKind.Exists(sType) Or g_typeKind(sType) <> TK_STRUCT Then
            ResolveVarType = TK_UNKNOWN : Exit Function
        End If
        If Not g_typeFields.Exists(sType) Then ResolveVarType = TK_UNKNOWN : Exit Function
        Dim fArr : fArr = Split(g_typeFields(sType), "|")
        Dim fp
        For Each fp In fArr
            If fp <> "" Then
                Dim fpP : fpP = Split(fp, ":")
                If UCT(fpP(0)) = comp Then
                    If UBound(fpP) >= 1 And fpP(1) <> "" Then
                        ResolveVarType = "BUILTIN:" & fpP(1) & ":"
                        If UBound(fpP) >= 2 Then ResolveVarType = "BUILTIN:" & fpP(1) & ":" & fpP(2)
                    Else
                        ResolveVarType = TK_UNKNOWN
                    End If
                    Exit Function
                End If
            End If
        Next
        ResolveVarType = TK_UNKNOWN
        Exit Function
    End If

    If g_varTypes.Exists(v) Then
        ResolveVarType = g_varTypes(v)
    Else
        ResolveVarType = TK_UNKNOWN
    End If
End Function

Function GetSimpleDtel(typeName)
    Dim arr(2)
    arr(0) = "" : arr(1) = "" : arr(2) = ""
    GetSimpleDtel = arr
    If typeName = "" Or typeName = TK_UNKNOWN Then Exit Function
    If Left(typeName, 8) = "BUILTIN:" Then
        Dim bp : bp = Split(typeName, ":")
        If UBound(bp) >= 1 Then arr(0) = bp(1)
        If UBound(bp) >= 2 Then arr(1) = bp(2)
        GetSimpleDtel = arr : Exit Function
    End If
    If Not g_typeDtel.Exists(typeName) Then Exit Function
    Dim parts : parts = Split(g_typeDtel(typeName), ":")
    If UBound(parts) >= 0 Then arr(0) = parts(0)
    If UBound(parts) >= 1 Then arr(1) = parts(1)
    If UBound(parts) >= 2 Then arr(2) = parts(2)
    GetSimpleDtel = arr
End Function

Function TypeFamily(dt)
    Select Case UCT(dt)
        Case "CHAR","NUMC","LCHR","SSTRING","STRING","CLNT","LANG","VARC" : TypeFamily = "CHAR"
        Case "DEC","CURR","QUAN","FLTP","DECFLOAT16","DECFLOAT34" : TypeFamily = "NUM"
        Case "INT1","INT2","INT4","INT8" : TypeFamily = "INT"
        Case "DATS","DATN"   : TypeFamily = "DATE"
        Case "TIMS","TIMN"   : TypeFamily = "TIME"
        Case "RAW","RAWSTRING","LRAW" : TypeFamily = "RAW"
        Case Else            : TypeFamily = "OTHER"
    End Select
End Function

Function CompareSimpleTypes(fmTypeName, varTypeName)
    If UCT(fmTypeName) = UCT(varTypeName) Then CompareSimpleTypes = "MATCH" : Exit Function
    Dim fmDtel  : fmDtel  = GetSimpleDtel(fmTypeName)
    Dim varDtel : varDtel = GetSimpleDtel(varTypeName)
    Dim fmDT : fmDT = fmDtel(0) : Dim varDT : varDT = varDtel(0)
    Dim fmL  : fmL  = fmDtel(1) : Dim varL  : varL  = varDtel(1)
    If fmDT = "" Or varDT = "" Then CompareSimpleTypes = "COMPATIBLE" : Exit Function
    If fmDT = varDT Then
        If fmL = varL Or fmL = "" Or varL = "" Then
            CompareSimpleTypes = "MATCH"
        Else
            CompareSimpleTypes = "WARNING:length mismatch fm=" & fmL & " var=" & varL
        End If
        Exit Function
    End If
    Dim fmFam : fmFam = TypeFamily(fmDT) : Dim varFam : varFam = TypeFamily(varDT)
    If fmFam = varFam Then
        CompareSimpleTypes = "WARNING:different subtypes fm=" & fmDT & " var=" & varDT
    ElseIf (fmFam = "INT" And varFam = "NUM") Or (fmFam = "NUM" And varFam = "INT") Then
        CompareSimpleTypes = "WARNING:integer/decimal mix fm=" & fmDT & " var=" & varDT
    Else
        CompareSimpleTypes = "INCOMPATIBLE:fm=" & fmDT & " var=" & varDT
    End If
End Function

' =============================================================================
' (FM definitions and types are now pre-loaded above by sidecar PowerShell helpers.)
' =============================================================================

Function FindFMDef(nm)
    Dim k
    For k = 0 To fmDefCount - 1
        If fmDefName(k) = UCT(nm) Then FindFMDef = k : Exit Function
    Next
    FindFMDef = -1
End Function

Function FindParamIdx(defIdx, sectIdx, pnm)
    Dim lst : lst = fmDefParamNames(defIdx, sectIdx)
    If lst = "" Then FindParamIdx = -1 : Exit Function
    Dim arr : arr = Split(lst, "|")
    Dim k
    For k = 0 To UBound(arr)
        If UCT(arr(k)) = UCT(pnm) Then FindParamIdx = k : Exit Function
    Next
    FindParamIdx = -1
End Function

Function PipeGet(s, idx)
    If s = "" Then PipeGet = "" : Exit Function
    Dim arr : arr = Split(s, "|")
    If idx <= UBound(arr) Then PipeGet = arr(idx) Else PipeGet = ""
End Function

' =============================================================================
' PHASE 4 -- Compare and build report
' =============================================================================
Dim totalIssues : totalIssues = 0
Dim sectName(4)
sectName(SECT_EXP) = "EXPORTING"
sectName(SECT_IMP) = "IMPORTING"
sectName(SECT_CHG) = "CHANGING"
sectName(SECT_TBL) = "TABLES"
sectName(SECT_EXC) = "EXCEPTIONS"

Dim ci, defIdx2, thisFM, thisLine2
For ci = 0 To cfCount - 1
    thisFM    = cfFM(ci)
    thisLine2 = cfLine(ci)
    defIdx2   = FindFMDef(thisFM)

    AddResult ""
    AddResult "CALL_FUNCTION" & vbTab & thisFM & vbTab & "LINE:" & thisLine2

    If defIdx2 = -1 Or Not fmDefValid(defIdx2) Then
        AddResult "  FM_NOT_FOUND" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & vbTab & "see FM_ERROR above"
        totalIssues = totalIssues + 1
    Else
        Dim callIssues : callIssues = 0
        Dim usedSect, pArr, vArr, pki, usedPN, usedPV

        ' -- Check used parameters --
        For usedSect = 0 To 4
            If cfPNames(ci, usedSect) <> "" Then
                pArr = Split(cfPNames(ci, usedSect), "|")
                vArr = Split(cfPVals(ci, usedSect),  "|")
                For pki = 0 To UBound(pArr)
                    usedPN = UCT(pArr(pki))
                    If usedPN <> "" Then
                        If usedSect = SECT_EXC And usedPN = "OTHERS" Then
                            ' OTHERS is a special ABAP keyword, always valid in EXCEPTIONS - skip
                        Else
                        If pki <= UBound(vArr) Then usedPV = UCT(vArr(pki)) Else usedPV = ""
                        Dim foundIdx : foundIdx = FindParamIdx(defIdx2, usedSect, usedPN)
                        If foundIdx >= 0 Then
                            ' Correct section
                            Dim fmTypeRef : fmTypeRef = PipeGet(fmDefParamType(defIdx2, usedSect), foundIdx)
                            Dim varTypeName : varTypeName = ResolveVarType(usedPV)
                            If varTypeName <> TK_UNKNOWN Then ResolveType varTypeName

                            AddResult "  PARAM_NAME_OK" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                      vbTab & sectName(usedSect) & vbTab & usedPN

                            If usedSect = SECT_EXC Or fmTypeRef = "" Or varTypeName = TK_UNKNOWN Then
                                If usedSect <> SECT_EXC And varTypeName = TK_UNKNOWN Then
                                    AddResult "  TYPE_UNKNOWN" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                              vbTab & usedPN & vbTab & "var:" & usedPV & " (not in local declarations)"
                                End If
                            Else
                                Dim fmKind  : fmKind  = ""
                                Dim varKind : varKind = ""
                                If g_typeKind.Exists(fmTypeRef)   Then fmKind  = g_typeKind(fmTypeRef)
                                If g_typeKind.Exists(varTypeName) Then varKind = g_typeKind(varTypeName)

                                If UCT(fmTypeRef) = UCT(varTypeName) Then
                                    AddResult "  TYPE_MATCH" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                              vbTab & usedPN & vbTab & fmTypeRef
                                ElseIf fmKind = TK_STRUCT And varKind = TK_STRUCT Then
                                    ' Field-by-field comparison
                                    Dim structOk : structOk = True
                                    If g_typeFields.Exists(fmTypeRef) And g_typeFields.Exists(varTypeName) Then
                                        Dim fmFArr  : fmFArr  = Split(g_typeFields(fmTypeRef), "|")
                                        Dim varFlds : varFlds = g_typeFields(varTypeName)
                                        Dim fff
                                        For Each fff In fmFArr
                                            If fff <> "" Then
                                                Dim fffP : fffP = Split(fff, ":")
                                                Dim ffNm : ffNm = fffP(0)
                                                ' Find field in var structure
                                                Dim varFArr : varFArr = Split(varFlds, "|")
                                                Dim vff, fFound : fFound = False
                                                For Each vff In varFArr
                                                    If vff <> "" Then
                                                        Dim vffP : vffP = Split(vff, ":")
                                                        If UCT(vffP(0)) = UCT(ffNm) Then
                                                            fFound = True
                                                            Dim fmFDT : fmFDT = "" : Dim varFDT : varFDT = ""
                                                            Dim fmFL  : fmFL  = "" : Dim varFL  : varFL  = ""
                                                            If UBound(fffP) >= 1 Then fmFDT = fffP(1)
                                                            If UBound(fffP) >= 2 Then fmFL  = fffP(2)
                                                            If UBound(vffP) >= 1 Then varFDT = vffP(1)
                                                            If UBound(vffP) >= 2 Then varFL  = vffP(2)
                                                            If fmFDT <> varFDT Then
                                                                If TypeFamily(fmFDT) = TypeFamily(varFDT) Then
                                                                    AddResult "  TYPE_WARNING" & vbTab & thisFM & vbTab & _
                                                                        "LINE:" & thisLine2 & vbTab & usedPN & _
                                                                        vbTab & "field:" & ffNm & " fm:" & fmFDT & " var:" & varFDT
                                                                Else
                                                                    AddResult "  TYPE_INCOMPATIBLE" & vbTab & thisFM & vbTab & _
                                                                        "LINE:" & thisLine2 & vbTab & usedPN & _
                                                                        vbTab & "field:" & ffNm & " fm:" & fmFDT & " var:" & varFDT
                                                                    structOk = False
                                                                    totalIssues = totalIssues + 1
                                                                    callIssues  = callIssues + 1
                                                                End If
                                                            ElseIf fmFL <> varFL And fmFL <> "" And varFL <> "" Then
                                                                AddResult "  TYPE_WARNING" & vbTab & thisFM & vbTab & _
                                                                    "LINE:" & thisLine2 & vbTab & usedPN & _
                                                                    vbTab & "field:" & ffNm & " len fm:" & fmFL & " var:" & varFL
                                                            End If
                                                            Exit For
                                                        End If
                                                    End If
                                                Next
                                                If Not fFound Then
                                                    AddResult "  TYPE_INCOMPATIBLE" & vbTab & thisFM & vbTab & _
                                                        "LINE:" & thisLine2 & vbTab & usedPN & _
                                                        vbTab & "field:" & ffNm & " missing in " & varTypeName
                                                    structOk = False
                                                    totalIssues = totalIssues + 1
                                                    callIssues  = callIssues + 1
                                                End If
                                            End If
                                        Next
                                    End If
                                    If structOk Then
                                        AddResult "  TYPE_COMPATIBLE" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                                  vbTab & usedPN & vbTab & "fm:" & fmTypeRef & " var:" & varTypeName
                                    End If
                                ElseIf fmKind = TK_STRUCT And varKind <> TK_STRUCT Then
                                    AddResult "  TYPE_INCOMPATIBLE" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                              vbTab & usedPN & vbTab & "fm expects structure " & fmTypeRef & _
                                              " but " & usedPV & " is not a structure"
                                    totalIssues = totalIssues + 1 : callIssues = callIssues + 1
                                ElseIf fmKind <> TK_STRUCT And varKind = TK_STRUCT Then
                                    AddResult "  TYPE_INCOMPATIBLE" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                              vbTab & usedPN & vbTab & "fm expects simple type " & fmTypeRef & _
                                              " but " & usedPV & " is a structure"
                                    totalIssues = totalIssues + 1 : callIssues = callIssues + 1
                                Else
                                    Dim cmpR : cmpR = CompareSimpleTypes(fmTypeRef, varTypeName)
                                    If Left(cmpR, 5) = "MATCH" Then
                                        AddResult "  TYPE_MATCH" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                                  vbTab & usedPN & vbTab & fmTypeRef
                                    ElseIf Left(cmpR, 10) = "COMPATIBLE" Then
                                        AddResult "  TYPE_COMPATIBLE" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                                  vbTab & usedPN & vbTab & "fm:" & fmTypeRef & " var:" & varTypeName
                                    ElseIf Left(cmpR, 7) = "WARNING" Then
                                        AddResult "  TYPE_WARNING" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                                  vbTab & usedPN & vbTab & "fm:" & fmTypeRef & " var:" & varTypeName & _
                                                  vbTab & Mid(cmpR, 9)
                                    Else
                                        AddResult "  TYPE_INCOMPATIBLE" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                                  vbTab & usedPN & vbTab & "fm:" & fmTypeRef & " var:" & varTypeName & _
                                                  vbTab & Mid(cmpR, 13)
                                        totalIssues = totalIssues + 1 : callIssues = callIssues + 1
                                    End If
                                End If
                            End If
                        Else
                            ' Not in expected section -- check other sections
                            Dim foundOther : foundOther = False
                            Dim otherSect2
                            For otherSect2 = 0 To 4
                                If otherSect2 <> usedSect Then
                                    If FindParamIdx(defIdx2, otherSect2, usedPN) >= 0 Then
                                        AddResult "  WRONG_SECTION" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                                  vbTab & usedPN & vbTab & "used:" & sectName(usedSect) & _
                                                  " defined-in:" & sectName(otherSect2)
                                        totalIssues = totalIssues + 1 : callIssues = callIssues + 1
                                        foundOther = True
                                        Exit For
                                    End If
                                End If
                            Next
                            If Not foundOther Then
                                AddResult "  UNKNOWN_PARAM" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                          vbTab & sectName(usedSect) & vbTab & usedPN & " not in FM definition"
                                totalIssues = totalIssues + 1 : callIssues = callIssues + 1
                            End If
                        End If
                        End If
                    End If
                Next
            End If
        Next

        ' -- Check missing mandatory parameters --
        Dim usedAll : usedAll = "|"
        Dim us3
        For us3 = 0 To 4
            If cfPNames(ci, us3) <> "" Then
                usedAll = usedAll & cfPNames(ci, us3) & "|"
            End If
        Next
        Do While InStr(usedAll, "||") > 0
            usedAll = Replace(usedAll, "||", "|")
        Loop

        Dim mSect, mNArr, mOArr, mpi, mNm, mOp
        For mSect = 0 To 2  ' SECT_TBL excluded: TABLE params always optional in ABAP
            If fmDefParamNames(defIdx2, mSect) <> "" Then
                mNArr = Split(fmDefParamNames(defIdx2, mSect), "|")
                mOArr = Split(fmDefParamOpt(defIdx2, mSect),   "|")
                For mpi = 0 To UBound(mNArr)
                    mNm = UCT(mNArr(mpi))
                    If mpi <= UBound(mOArr) Then mOp = mOArr(mpi) Else mOp = "X"
                    If mOp = " " And mNm <> "" Then
                        If InStr(usedAll, "|" & mNm & "|") = 0 Then
                            AddResult "  MISSING_MANDATORY" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & _
                                      vbTab & sectName(mSect) & vbTab & mNm
                            totalIssues = totalIssues + 1 : callIssues = callIssues + 1
                        End If
                    End If
                Next
            End If
        Next

        If callIssues = 0 Then
            AddResult "  OK" & vbTab & thisFM & vbTab & "LINE:" & thisLine2 & vbTab & "No issues"
        End If
    End If
Next

On Error Resume Next
oConn.Logoff
On Error GoTo 0

' =============================================================================
' PHASE 5 -- Write result file
' =============================================================================
Dim finalStatus
If totalIssues = 0 Then
    finalStatus = "STATUS: SUCCESS: All " & cfCount & " CALL FUNCTION(s) valid."
Else
    finalStatus = "STATUS: SUCCESS_WITH_ISSUES: " & cfCount & " call(s), " & totalIssues & " issue(s)."
End If
WriteResults finalStatus
WScript.Quit 0
