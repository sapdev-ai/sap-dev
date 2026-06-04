' =============================================================================
' sap_check_abap.vbs  -  Validate ABAP variable types, naming, and usage
'
' Runs via standard cscript.exe. RFC type lookups are delegated to the
' sidecar PowerShell helper at %%DDIC_HELPER_PS1%% (NCo 3.1 based).
' DO NOT commit the filled-in version -- it contains plaintext credentials.
'
' Phases:
'   1.  Read naming rules TSV
'   2.  Parse ABAP source (declarations, scope, types, FORM params)
'  2b.  Parse SQL statements (SELECT, UPDATE, DELETE)
'   3.  Detect variable usage (unused variable check)
'   4.  Connect to SAP and validate types via DDIF FMs (optional)
'  4b.  Fetch SQL table field definitions via DDIF_FIELDINFO_GET (optional)
'   5.  Check naming conventions against rules
'  5d.  Validate SQL field references against table definitions
'   6.  Write tab-delimited result file
'
' Tokens replaced at run time by PowerShell [IO.File]::WriteAllText (UTF-16 LE):
'   %%SAP_SERVER%%     Application server host         (empty = offline mode)
'   %%SAP_SYSNR%%      2-digit system number
'   %%SAP_CLIENT%%     3-digit client number
'   %%SAP_USER%%       SAP username
'   %%SAP_PASSWORD%%   SAP password
'   %%SAP_LANGUAGE%%   Logon language
'   %%ABAP_FILE%%      Full path to ABAP source file
'   %%RESULT_FILE%%    Full path to write results
'   %%NAMING_RULES%%   Full path to naming rules TSV
' =============================================================================
Option Explicit

' --- Token parameters ---
Dim SAP_SERVER   : SAP_SERVER   = "%%SAP_SERVER%%"
Dim SAP_SYSNR    : SAP_SYSNR    = "%%SAP_SYSNR%%"
Dim SAP_CLIENT   : SAP_CLIENT   = "%%SAP_CLIENT%%"
Dim SAP_USER     : SAP_USER     = "%%SAP_USER%%"
Dim SAP_PASSWORD : SAP_PASSWORD = "%%SAP_PASSWORD%%"
Dim SAP_LANGUAGE : SAP_LANGUAGE = "%%SAP_LANGUAGE%%"
Dim ABAP_FILE    : ABAP_FILE    = "%%ABAP_FILE%%"
Dim RESULT_FILE  : RESULT_FILE  = "%%RESULT_FILE%%"
Dim NAMING_RULES : NAMING_RULES = "%%NAMING_RULES%%"
Dim DDIC_HELPER_PS1     : DDIC_HELPER_PS1     = "%%DDIC_HELPER_PS1%%"
Dim DDIC_REQUEST_FILE   : DDIC_REQUEST_FILE   = "%%DDIC_REQUEST_FILE%%"
Dim DDIC_RESULT_FILE    : DDIC_RESULT_FILE    = "%%DDIC_RESULT_FILE%%"

' --- Type kind constants ---
Const TK_STRUCT  = "STRUCT"
Const TK_DTEL    = "DTEL"
Const TK_BUILTIN = "BUILTIN"
Const TK_UNKNOWN = "UNKNOWN"

' --- Scope constants ---
Const SC_GLOBAL    = "GLOBAL"
Const SC_LOCAL     = "LOCAL"
Const SC_PARAM     = "PARAM"
Const SC_SELECTION = "SELECTION"

' --- Data kind constants ---
Const SC_MEMBER    = "MEMBER"

' --- Data kind constants ---
Const DK_VARIABLE    = "VARIABLE"
Const DK_STRUCTURE   = "STRUCTURE"
Const DK_TABLE       = "TABLE"
Const DK_CONSTANT    = "CONSTANT"
Const DK_OBJECT      = "OBJECT"
Const DK_REFERENCE   = "REFERENCE"

' =============================================================================
' Globals
' =============================================================================
Dim g_fso
Set g_fso = CreateObject("Scripting.FileSystemObject")

Dim g_results()
ReDim g_results(0)
g_results(0) = ""

' Type resolution caches
Dim g_typeKind, g_typeDtel
Set g_typeKind = CreateObject("Scripting.Dictionary")
Set g_typeDtel = CreateObject("Scripting.Dictionary")
g_typeKind.CompareMode = 1
g_typeDtel.CompareMode = 1

' Local TYPES declared in source
Dim g_localTypes
Set g_localTypes = CreateObject("Scripting.Dictionary")
g_localTypes.CompareMode = 1

' Local TYPES → data-kind map (DK_TABLE / DK_STRUCTURE / DK_VARIABLE / ...).
' Populated alongside g_localTypes so that variables typed by a local TYPE
' (e.g. `lt_x TYPE STANDARD TABLE OF ty_y` or `ls_x TYPE ty_struct`)
' can be re-classified from DK_VARIABLE to their true kind after the
' declaration parse. Without this, the naming-rule check looked them up
' as MEMBER+VARIABLE instead of MEMBER+TABLE / LOCAL+STRUCTURE and
' produced false NAMING warnings. Bug surfaced 2026-05-11.
Dim g_localTypeKind
Set g_localTypeKind = CreateObject("Scripting.Dictionary")
g_localTypeKind.CompareMode = 1

' Naming rules arrays
Dim g_nrScope(), g_nrKind(), g_nrPrefix()
Dim g_nrCount : g_nrCount = 0

' Declaration arrays
Dim g_dName(), g_dType(), g_dLine(), g_dScope(), g_dKind(), g_dParamDir()
Dim g_dCount : g_dCount = 0

' Usage tracking
Dim g_varUsed
Set g_varUsed = CreateObject("Scripting.Dictionary")
g_varUsed.CompareMode = 1

' ABAP source lines
Dim g_srcLines(), g_srcCount
g_srcCount = 0

' (RFC calls are delegated to the sap_rfc_lookup_ddic.ps1 sidecar.)

' Issue counter
Dim g_issueCount : g_issueCount = 0

' Built-in ABAP types
Dim g_builtinTypes
Set g_builtinTypes = CreateObject("Scripting.Dictionary")
g_builtinTypes.CompareMode = 1
Dim bti
For Each bti In Array("C","N","X","P","I","F","D","T","STRING","XSTRING", _
                      "DECFLOAT16","DECFLOAT34","INT8","B","S","INT1","INT2","INT4", _
                      "ABAP_BOOL","ABAP_TRUE","ABAP_FALSE","XFELD","FLAG", _
                      "SY","SYST","SYSUBRC","CHAR1","CHAR10","CHAR20","NUMC2","NUMC4")
    g_builtinTypes(bti) = True
Next

' Parser state (accessible by helper subs)
Dim g_curScope     : g_curScope     = SC_GLOBAL
Dim g_curParamDir  : g_curParamDir  = ""
Dim g_inChain      : g_inChain      = False
Dim g_chainKeyword : g_chainKeyword = ""
Dim g_chainScope   : g_chainScope   = SC_GLOBAL
Dim g_beginOfDepth : g_beginOfDepth = 0  ' track TYPES: BEGIN OF nesting

' SQL statement storage (Phase 2b)
Dim g_sqlKind(), g_sqlStartLine(), g_sqlText()
Dim g_sqlTables(), g_sqlAliases()
Dim g_sqlSelFields(), g_sqlWhFields(), g_sqlIsStar()
Dim g_sqlCount : g_sqlCount = 0

' Table field definition cache (Phase 4b)
Dim g_tblFieldCache   ' Dictionary: tableName -> "FLD1:DT:L:D|FLD2:DT:L:D|..."
Dim g_tblFieldValid   ' Dictionary: tableName -> True/False
Set g_tblFieldCache = CreateObject("Scripting.Dictionary")
Set g_tblFieldValid = CreateObject("Scripting.Dictionary")
g_tblFieldCache.CompareMode = 1
g_tblFieldValid.CompareMode = 1

' --- Class definition tracking ---
Dim g_inClassDef     : g_inClassDef     = False
Dim g_inClassImpl    : g_inClassImpl    = False
Dim g_curClassName   : g_curClassName   = ""
Dim g_curSection     : g_curSection     = ""
Dim g_inMethodsChain : g_inMethodsChain = False
Dim g_methodsBuf     : g_methodsBuf     = ""
Dim g_methodsBufLine : g_methodsBufLine = 0

' Class method signature storage (parallel arrays)
Dim g_cmClass(), g_cmMethod(), g_cmParam(), g_cmDir(), g_cmType()
Dim g_cmCount : g_cmCount = 0

' Class name -> True  (tracks defined classes)
Dim g_classDefined
Set g_classDefined = CreateObject("Scripting.Dictionary")
g_classDefined.CompareMode = 1

' Variable -> ClassName  (variable is instance of class)
Dim g_varClass
Set g_varClass = CreateObject("Scripting.Dictionary")
g_varClass.CompareMode = 1

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
    f.WriteLine "NAMING_RULES" & vbTab & NAMING_RULES
    f.WriteLine "TIMESTAMP" & vbTab & Now()
    f.WriteLine "TOTAL_DECLARATIONS" & vbTab & g_dCount
    f.WriteLine "TOTAL_SQL_STATEMENTS" & vbTab & g_sqlCount
    f.WriteLine "TOTAL_CLASS_METHOD_PARAMS" & vbTab & g_cmCount
    f.WriteLine "TOTAL_ISSUES" & vbTab & g_issueCount
    f.WriteLine ""
    f.WriteLine "CHECK_TYPE" & vbTab & "SEVERITY" & vbTab & "LINE" & vbTab & _
                "VARIABLE" & vbTab & "SCOPE" & vbTab & "DATA_KIND" & vbTab & _
                "DETAIL" & vbTab & "FIX_ADVICE"
    Dim i
    For i = 0 To UBound(g_results)
        If g_results(i) <> "" Then f.WriteLine g_results(i)
    Next
    f.Close
    WScript.Echo statusLine
End Sub

Sub AbortError(msg)
    WriteResults "STATUS:" & vbTab & "ERROR: " & msg
    WScript.Quit 1
End Sub

Function UCT(s)
    UCT = UCase(Trim(s))
End Function

Sub AddDecl(varName, typeRef, lineNum, scope, dataKind, paramDir)
    g_dCount = g_dCount + 1
    ReDim Preserve g_dName(g_dCount)
    ReDim Preserve g_dType(g_dCount)
    ReDim Preserve g_dLine(g_dCount)
    ReDim Preserve g_dScope(g_dCount)
    ReDim Preserve g_dKind(g_dCount)
    ReDim Preserve g_dParamDir(g_dCount)
    g_dName(g_dCount)     = UCT(varName)
    g_dType(g_dCount)     = UCT(typeRef)
    g_dLine(g_dCount)     = lineNum
    g_dScope(g_dCount)    = scope
    g_dKind(g_dCount)     = dataKind
    g_dParamDir(g_dCount) = paramDir
    g_varUsed(UCT(varName)) = False
    ' Track object->class mappings for method call checking
    If InStr(UCT(typeRef), "REF TO") > 0 Then
        Dim refCls : refCls = ExtractBaseType(typeRef)
        If g_classDefined.Exists(refCls) Then
            g_varClass(UCT(varName)) = refCls
        End If
    End If
End Sub

Sub AddIssue(checkType, severity, lineNum, varName, scope, dataKind, detail, fixAdvice)
    g_issueCount = g_issueCount + 1
    AddResult checkType & vbTab & severity & vbTab & lineNum & vbTab & _
              varName & vbTab & scope & vbTab & dataKind & vbTab & _
              detail & vbTab & fixAdvice
End Sub

Sub AddClassMethod(className, methodName, paramName, paramDir, paramType)
    g_cmCount = g_cmCount + 1
    ReDim Preserve g_cmClass(g_cmCount)
    ReDim Preserve g_cmMethod(g_cmCount)
    ReDim Preserve g_cmParam(g_cmCount)
    ReDim Preserve g_cmDir(g_cmCount)
    ReDim Preserve g_cmType(g_cmCount)
    g_cmClass(g_cmCount)  = UCT(className)
    g_cmMethod(g_cmCount) = UCT(methodName)
    g_cmParam(g_cmCount)  = UCT(paramName)
    g_cmDir(g_cmCount)    = UCT(paramDir)
    g_cmType(g_cmCount)   = UCT(paramType)
End Sub

Sub ParseMethodSignature(className, sigText, lineNum)
    Dim tokens : tokens = SplitTokens(UCT(sigText))
    If UBound(tokens) < 0 Then Exit Sub

    Dim methodName : methodName = StripTrailing(tokens(0))
    If methodName = "" Then Exit Sub

    Dim i : i = 1
    Dim curDir : curDir = ""

    Do While i <= UBound(tokens)
        Dim t : t = StripTrailing(tokens(i))

        ' Direction keywords
        If t = "IMPORTING" Or t = "EXPORTING" Or t = "CHANGING" Or t = "RETURNING" Then
            curDir = t
            i = i + 1
        ElseIf t = "VALUE" Or Left(t, 6) = "VALUE(" Then
            ' RETURNING VALUE(rv_name)
            Dim valParam : valParam = ""
            If Left(t, 6) = "VALUE(" Then
                valParam = Mid(t, 7)
                If Right(valParam, 1) = ")" Then valParam = Left(valParam, Len(valParam) - 1)
            ElseIf i + 1 <= UBound(tokens) Then
                i = i + 1
                valParam = StripTrailing(tokens(i))
                If Left(valParam, 1) = "(" Then valParam = Mid(valParam, 2)
                If Right(valParam, 1) = ")" Then valParam = Left(valParam, Len(valParam) - 1)
            End If
            Dim valType : valType = ""
            If i + 1 <= UBound(tokens) Then
                If StripTrailing(tokens(i + 1)) = "TYPE" And i + 2 <= UBound(tokens) Then
                    valType = ExtractType(tokens, i + 2)
                    Dim vtTokens : vtTokens = SplitTokens(valType)
                    i = i + 2 + UBound(vtTokens)
                End If
            End If
            If valParam <> "" Then
                AddClassMethod className, methodName, valParam, curDir, valType
                Dim valKind : valKind = GuessDataKind(valType, "DATA")
                AddDecl valParam, valType, lineNum, SC_PARAM, valKind, curDir
            End If
            i = i + 1
        ElseIf curDir <> "" And t <> "TYPE" And t <> "LIKE" And t <> "OPTIONAL" _
               And t <> "DEFAULT" And t <> "ABSTRACT" And t <> "FINAL" _
               And t <> "REDEFINITION" And t <> "FOR" And t <> "" Then
            ' This is a parameter name
            Dim pmsType : pmsType = ""
            If i + 1 <= UBound(tokens) Then
                If StripTrailing(tokens(i + 1)) = "TYPE" And i + 2 <= UBound(tokens) Then
                    pmsType = ExtractType(tokens, i + 2)
                    Dim ptTokens : ptTokens = SplitTokens(pmsType)
                    i = i + 2 + UBound(ptTokens)
                End If
            End If
            AddClassMethod className, methodName, t, curDir, pmsType
            Dim pmsKind : pmsKind = GuessDataKind(pmsType, "DATA")
            AddDecl t, pmsType, lineNum, SC_PARAM, pmsKind, curDir
            i = i + 1
        Else
            i = i + 1
        End If
    Loop
End Sub

Sub CheckMethodCallParams(codeLine, lineNum, className, methodName, startPos)
    ' Find opening paren
    Dim pStart : pStart = InStr(startPos, codeLine, "(")
    If pStart = 0 Then Exit Sub

    ' Find closing paren (single-line only)
    Dim pEnd : pEnd = InStr(pStart + 1, codeLine, ")")
    Dim paramSection : paramSection = ""
    If pEnd > 0 Then
        paramSection = Mid(codeLine, pStart + 1, pEnd - pStart - 1)
    Else
        Exit Sub  ' Multi-line call — skip for now
    End If

    paramSection = Trim(paramSection)
    If paramSection = "" Then Exit Sub

    ' Check for named parameters: "param = value" pattern
    Dim pTokens : pTokens = SplitTokens(paramSection)
    Dim pi
    For pi = 0 To UBound(pTokens)
        Dim pt : pt = StripTrailing(pTokens(pi))
        If pt = "" Then
            ' skip
        ElseIf pi + 1 <= UBound(pTokens) Then
            If StripTrailing(pTokens(pi + 1)) = "=" Then
                ' pt is a parameter name — check it exists
                Dim paramFound : paramFound = False
                Dim pci
                For pci = 1 To g_cmCount
                    If g_cmClass(pci) = UCT(className) And _
                       g_cmMethod(pci) = UCT(methodName) And _
                       g_cmParam(pci) = UCT(pt) Then
                        paramFound = True
                        Exit For
                    End If
                Next
                If Not paramFound Then
                    AddIssue "METHOD_PARAM_NOT_FOUND", "ERROR", lineNum, _
                             pt, SC_LOCAL, DK_VARIABLE, _
                             "parameter " & pt & " not in " & className & "->" & methodName & " signature", _
                             "Check parameter name in class definition"
                End If
            End If
        End If
    Next
End Sub

Function GuessDataKind(typeRef, declKeyword)
    Dim u : u = UCT(typeRef)
    If declKeyword = "CONSTANTS" Then
        GuessDataKind = DK_CONSTANT : Exit Function
    End If
    If InStr(u, "TABLE OF") > 0 Or InStr(u, "SORTED TABLE") > 0 Or _
       InStr(u, "HASHED TABLE") > 0 Or InStr(u, "STANDARD TABLE") > 0 Then
        GuessDataKind = DK_TABLE : Exit Function
    End If
    If InStr(u, "REF TO") > 0 Then
        If InStr(u, "REF TO DATA") > 0 Then
            GuessDataKind = DK_REFERENCE
        Else
            GuessDataKind = DK_OBJECT
        End If
        Exit Function
    End If
    GuessDataKind = DK_VARIABLE
End Function

Function ExtractType(tokens, startIdx)
    Dim result : result = ""
    Dim j
    For j = startIdx To UBound(tokens)
        Dim tk : tk = tokens(j)
        If tk = "" Or tk = "." Or tk = "," Or Left(tk, 1) = Chr(34) Then Exit For
        If tk = "VALUE" Or tk = "READ-ONLY" Or tk = "DEFAULT" Or tk = "OBLIGATORY" Then Exit For
        If tk = "AS" Or tk = "MEMORY" Or tk = "MODIF" Then Exit For
        ' Stop at TYPE-clause modifier keywords so the type token list doesn't
        ' get a trailing "WITH" appended (which then makes the type look
        ' invalid downstream): WITH (DEFAULT/UNIQUE/NON-UNIQUE/EMPTY KEY),
        ' INITIAL (SIZE n), OCCURS (n).
        If tk = "WITH" Or tk = "INITIAL" Or tk = "OCCURS" Then Exit For
        If result <> "" Then result = result & " "
        result = result & tk
    Next
    ExtractType = result
End Function

Function IsWordBoundary(ch)
    If ch = "" Then
        IsWordBoundary = True : Exit Function
    End If
    Dim code : code = Asc(UCase(ch))
    If code >= 65 And code <= 90 Then
        IsWordBoundary = False
    ElseIf code >= 48 And code <= 57 Then
        IsWordBoundary = False
    ElseIf ch = "_" Then
        IsWordBoundary = False
    Else
        IsWordBoundary = True
    End If
End Function

Function SplitTokens(sLine)
    Dim cleaned : cleaned = Replace(Replace(sLine, vbTab, " "), "  ", " ")
    Do While InStr(cleaned, "  ") > 0
        cleaned = Replace(cleaned, "  ", " ")
    Loop
    SplitTokens = Split(Trim(cleaned), " ")
End Function

Function StripTrailing(s)
    Dim r : r = s
    If Len(r) > 0 Then
        Dim last : last = Right(r, 1)
        If last = "." Or last = "," Or last = ":" Then r = Left(r, Len(r) - 1)
    End If
    StripTrailing = r
End Function

' Strip ABAP inline comment (starting with ") and return code part only
Function StripInlineComment(s)
    Dim inStr : inStr = False
    Dim i, ch
    For i = 1 To Len(s)
        ch = Mid(s, i, 1)
        If inStr Then
            If ch = "'" Then inStr = False
        Else
            If ch = "'" Then
                inStr = True
            ElseIf ch = Chr(34) Then
                ' Found comment start outside string literal
                StripInlineComment = Left(s, i - 1)
                Exit Function
            End If
        End If
    Next
    StripInlineComment = s
End Function

' Check if ABAP statement (ignoring comments) ends with period
Function EndsWithPeriod(rawLine)
    Dim code : code = Trim(StripInlineComment(rawLine))
    EndsWithPeriod = (Right(code, 1) = ".")
End Function

Function ExtractBaseType(typeRef)
    Dim b : b = typeRef
    If InStr(b, "TABLE OF") > 0 Then b = Trim(Mid(b, InStrRev(b, "TABLE OF") + 9))
    If InStr(b, "REF TO") > 0 Then b = Trim(Mid(b, InStr(b, "REF TO") + 7))
    Dim sp : sp = InStr(b, " ")
    If sp > 0 Then b = Left(b, sp - 1)
    b = StripTrailing(UCT(b))
    ExtractBaseType = b
End Function

' =============================================================================
' SQL Helpers
' =============================================================================

' Check if first token starts an SQL statement (not SELECT-OPTIONS, ENDSELECT, etc.)
Function IsSqlKeyword(tok0, tokens)
    IsSqlKeyword = False
    If tok0 = "SELECT" Then
        ' Exclude ENDSELECT (one token), SELECT-OPTIONS (one token with hyphen)
        IsSqlKeyword = True
        Exit Function
    End If
    If tok0 = "SELECT-OPTIONS" Or tok0 = "ENDSELECT" Then Exit Function
    If tok0 = "UPDATE" Then IsSqlKeyword = True : Exit Function
    If tok0 = "DELETE" Then
        ' Exclude DELETE ADJACENT DUPLICATES, DELETE INTERNAL TABLE variants
        If UBound(tokens) >= 1 Then
            Dim dt1 : dt1 = tokens(1)
            If dt1 = "ADJACENT" Or dt1 = "INTERNAL" Then Exit Function
        End If
        IsSqlKeyword = True
    End If
End Function

' Store a parsed SQL statement into g_sql* arrays
Sub AddSql(sqlKind, startLine, fullText, tables, aliases, selFields, whFields, isStar)
    g_sqlCount = g_sqlCount + 1
    ReDim Preserve g_sqlKind(g_sqlCount)
    ReDim Preserve g_sqlStartLine(g_sqlCount)
    ReDim Preserve g_sqlText(g_sqlCount)
    ReDim Preserve g_sqlTables(g_sqlCount)
    ReDim Preserve g_sqlAliases(g_sqlCount)
    ReDim Preserve g_sqlSelFields(g_sqlCount)
    ReDim Preserve g_sqlWhFields(g_sqlCount)
    ReDim Preserve g_sqlIsStar(g_sqlCount)
    g_sqlKind(g_sqlCount)      = sqlKind
    g_sqlStartLine(g_sqlCount) = startLine
    g_sqlText(g_sqlCount)      = fullText
    g_sqlTables(g_sqlCount)    = tables
    g_sqlAliases(g_sqlCount)   = aliases
    g_sqlSelFields(g_sqlCount) = selFields
    g_sqlWhFields(g_sqlCount)  = whFields
    g_sqlIsStar(g_sqlCount)    = isStar
End Sub

' Resolve a field reference: strip alias prefix "c~carrid" -> TABLE.FIELD
Function ResolveFieldRef(token, aliasMap, defaultTable)
    Dim tld : tld = InStr(token, "~")
    Dim fName, tblName
    If tld > 0 Then
        Dim aliasKey : aliasKey = Left(token, tld - 1)
        fName = Mid(token, tld + 1)
        If aliasMap.Exists(aliasKey) Then
            tblName = aliasMap(aliasKey)
        Else
            tblName = aliasKey  ' alias IS the table name (no AS)
        End If
    Else
        fName = token
        tblName = defaultTable
    End If
    fName = StripTrailing(fName)
    If fName = "" Or tblName = "" Then
        ResolveFieldRef = ""
    Else
        ResolveFieldRef = tblName & "." & fName
    End If
End Function

' Check if a token looks like a comparison operator
Function IsCompOp(t)
    IsCompOp = False
    If t = "=" Or t = "<>" Or t = "<" Or t = ">" Or t = "<=" Or t = ">=" Then IsCompOp = True : Exit Function
    If t = "EQ" Or t = "NE" Or t = "LT" Or t = "GT" Or t = "LE" Or t = "GE" Then IsCompOp = True : Exit Function
    If t = "LIKE" Or t = "IN" Or t = "BETWEEN" Or t = "IS" Then IsCompOp = True
End Function

' Check if a token is a SQL/logic keyword (not a field name)
Function IsSqlClauseWord(t)
    IsSqlClauseWord = False
    If t = "AND" Or t = "OR" Or t = "NOT" Or t = "(" Or t = ")" Then IsSqlClauseWord = True : Exit Function
    If t = "WHERE" Or t = "INTO" Or t = "FROM" Or t = "GROUP" Or t = "ORDER" Then IsSqlClauseWord = True : Exit Function
    If t = "HAVING" Or t = "UP" Or t = "APPENDING" Or t = "FOR" Or t = "UNION" Then IsSqlClauseWord = True : Exit Function
    If t = "INITIAL" Or t = "NULL" Or t = "SPACE" Then IsSqlClauseWord = True
End Function

' Extract field names from WHERE clause tokens
' Returns pipe-delimited TABLE.FIELD list
Function ExtractWhereFields(tokens, startIdx, aliasMap, defaultTable)
    Dim result : result = ""
    Dim wi : wi = startIdx
    Dim expectField : expectField = True
    Do While wi <= UBound(tokens)
        Dim wt : wt = StripTrailing(tokens(wi))
        If wt = "" Or wt = "." Then Exit Do
        ' Stop at non-WHERE clauses
        If wt = "INTO" Or wt = "GROUP" Or wt = "ORDER" Or wt = "HAVING" Or _
           wt = "UP" Or wt = "APPENDING" Or wt = "UNION" Then Exit Do

        If expectField Then
            If wt = "AND" Or wt = "OR" Or wt = "NOT" Or wt = "(" Or wt = ")" Then
                ' Skip logic keywords, stay in expectField
            ElseIf Left(wt, 1) = "'" Or Left(wt, 1) = "@" Then
                ' Value literal or host var — skip
            Else
                ' This is a field name
                Dim ref : ref = ResolveFieldRef(wt, aliasMap, defaultTable)
                If ref <> "" Then
                    If result <> "" Then result = result & "|"
                    result = result & ref
                End If
                expectField = False
            End If
        Else
            If IsCompOp(wt) Then
                ' After operator, skip value(s) until AND/OR
                wi = wi + 1
                ' Skip BETWEEN value AND value specially
                If wt = "BETWEEN" Then
                    Do While wi <= UBound(tokens)
                        Dim bt : bt = StripTrailing(tokens(wi))
                        If bt = "AND" Then wi = wi + 1 : Exit Do
                        If bt = "" Or bt = "." Then Exit Do
                        wi = wi + 1
                    Loop
                    ' Skip second value after AND
                    If wi <= UBound(tokens) Then wi = wi + 1
                Else
                    ' Skip value tokens
                    Do While wi <= UBound(tokens)
                        Dim vt : vt = StripTrailing(tokens(wi))
                        If vt = "AND" Or vt = "OR" Or vt = ")" Then Exit Do
                        If vt = "" Or vt = "." Then Exit Do
                        If vt = "INTO" Or vt = "GROUP" Or vt = "ORDER" Or vt = "HAVING" Then Exit Do
                        wi = wi + 1
                    Loop
                End If
                expectField = True
                wi = wi - 1  ' will be incremented below
            ElseIf wt = "AND" Or wt = "OR" Then
                expectField = True
            End If
        End If
        wi = wi + 1
    Loop
    ExtractWhereFields = result
End Function

' Parse a complete SELECT statement
Sub ParseSqlSelect(fullText, startLine)
    Dim tokens : tokens = SplitTokens(UCT(fullText))
    If UBound(tokens) < 2 Then Exit Sub

    Dim idx : idx = 1  ' skip "SELECT"
    ' Skip SINGLE / DISTINCT
    If tokens(idx) = "SINGLE" Then idx = idx + 1
    If idx <= UBound(tokens) And tokens(idx) = "DISTINCT" Then idx = idx + 1

    ' --- Pre-scan for strict-SQL evidence (any @host-var anywhere) ---
    ' New Open SQL (7.40 SP08+) requires commas between SELECT-list fields
    ' WHENEVER any clause uses an `@`-escaped host variable (INTO @x,
    ' WHERE k = @v, etc.). Space-separated field lists in this case raise
    ' SAP syntax error: "The elements in the 'SELECT LIST' list must be
    ' separated using commas." Detection: look for any token that starts
    ' with `@` (case-insensitive) in the full token stream.
    Dim hasAtVar : hasAtVar = False
    Dim scIdx
    For scIdx = 0 To UBound(tokens)
        If Len(tokens(scIdx)) > 0 And Left(tokens(scIdx), 1) = "@" Then
            hasAtVar = True
            Exit For
        End If
    Next

    ' --- Extract field list (until FROM) ---
    Dim selFields : selFields = ""
    Dim isStar : isStar = False
    ' Track raw field tokens between SELECT and FROM, before StripTrailing,
    ' so we can detect missing-comma pattern. Two parallel counters:
    Dim fieldCountRaw : fieldCountRaw = 0
    Dim commaCount    : commaCount    = 0
    Do While idx <= UBound(tokens)
        Dim rawTok : rawTok = tokens(idx)
        Dim ft : ft = StripTrailing(rawTok)
        If ft = "FROM" Then idx = idx + 1 : Exit Do
        If ft = "INTO" Then Exit Do  ' malformed but handle gracefully
        If ft = "" Or ft = "," Then
            If ft = "," Then commaCount = commaCount + 1
            idx = idx + 1
        ElseIf ft = "*" Then
            isStar = True
            idx = idx + 1
            fieldCountRaw = fieldCountRaw + 1
            If Right(rawTok, 1) = "," Then commaCount = commaCount + 1
        ElseIf Left(ft, 1) = "@" Then
            ' Host variable / boolean literal projection (e.g. SELECT @abap_true,
            ' SELECT @lv_const). Not a column of the SELECT FROM table — skip.
            idx = idx + 1
            If Right(rawTok, 1) = "," Then commaCount = commaCount + 1
        ElseIf InStr(ft, "(") > 0 Then
            ' Aggregate function like COUNT(*) — skip field checking
            isStar = True
            idx = idx + 1
            fieldCountRaw = fieldCountRaw + 1
            If Right(rawTok, 1) = "," Then commaCount = commaCount + 1
        Else
            If selFields <> "" Then selFields = selFields & "|"
            selFields = selFields & ft
            fieldCountRaw = fieldCountRaw + 1
            If Right(rawTok, 1) = "," Then commaCount = commaCount + 1
            idx = idx + 1
        End If
    Loop

    ' --- Strict-SQL comma check ---
    ' Required commas = fieldCountRaw - 1 (between each pair). If hasAtVar
    ' is true and the source supplies fewer commas, SAP will reject at
    ' compile time. Emit ERROR-severity finding so callers fix BEFORE
    ' deploy. Bug surfaced 2026-05-11 on ZMMRMAT031R01 line 178
    ' (`SELECT seq key1 val1 ... INTO ... @lt_rows WHERE ... @gc_pgm_id`).
    If hasAtVar And fieldCountRaw >= 2 And commaCount < fieldCountRaw - 1 Then
        AddIssue "SQL_STRICT_COMMA", "ERROR", startLine, "SELECT", "SQL", "STATEMENT", _
                 "Strict Open SQL: SELECT list with @-host-vars must be comma-separated (have " & _
                 commaCount & " comma(s), need " & (fieldCountRaw - 1) & " for " & _
                 fieldCountRaw & " fields)", _
                 "Insert commas between fields: SELECT a, b, c FROM ..."
    End If

    ' --- Parse FROM clause (tables, aliases, JOINs) ---
    Dim tables : tables = ""
    Dim aliasMap
    Set aliasMap = CreateObject("Scripting.Dictionary")
    aliasMap.CompareMode = 1
    Dim defaultTable : defaultTable = ""
    Dim inOnClause : inOnClause = False

    Do While idx <= UBound(tokens)
        Dim frt : frt = StripTrailing(tokens(idx))
        If frt = "" Or frt = "." Then Exit Do
        If frt = "WHERE" Or frt = "INTO" Or frt = "GROUP" Or frt = "ORDER" Or _
           frt = "HAVING" Or frt = "UP" Or frt = "APPENDING" Or frt = "FOR" Then Exit Do

        If inOnClause Then
            If frt = "INNER" Or frt = "LEFT" Or frt = "RIGHT" Or frt = "CROSS" Or _
               frt = "JOIN" Or frt = "WHERE" Or frt = "INTO" Then
                inOnClause = False
                ' Don't increment — reprocess this token
            Else
                idx = idx + 1
            End If
        ElseIf frt = "ON" Then
            inOnClause = True
            idx = idx + 1
        ElseIf frt = "INNER" Or frt = "LEFT" Or frt = "RIGHT" Or frt = "CROSS" Or frt = "OUTER" Then
            idx = idx + 1
        ElseIf frt = "JOIN" Then
            idx = idx + 1
        ElseIf frt = "AS" Then
            ' Next token is alias for the last table added
            idx = idx + 1
            If idx <= UBound(tokens) Then
                Dim aliasName : aliasName = StripTrailing(tokens(idx))
                If aliasName <> "" And tables <> "" Then
                    ' Last table in pipes
                    Dim tParts : tParts = Split(tables, "|")
                    Dim lastTbl : lastTbl = tParts(UBound(tParts))
                    aliasMap(aliasName) = lastTbl
                End If
                idx = idx + 1
            End If
        Else
            ' Table name
            If tables <> "" Then tables = tables & "|"
            tables = tables & frt
            If defaultTable = "" Then defaultTable = frt
            idx = idx + 1
        End If
    Loop

    ' --- Resolve field references using alias map ---
    Dim resolvedSel : resolvedSel = ""
    If Not isStar And selFields <> "" Then
        Dim sfArr : sfArr = Split(selFields, "|")
        Dim sfi
        For sfi = 0 To UBound(sfArr)
            Dim rr : rr = ResolveFieldRef(sfArr(sfi), aliasMap, defaultTable)
            If rr <> "" Then
                If resolvedSel <> "" Then resolvedSel = resolvedSel & "|"
                resolvedSel = resolvedSel & rr
            End If
        Next
    End If

    ' --- Extract WHERE fields ---
    Dim whFields : whFields = ""
    Dim wi
    For wi = idx To UBound(tokens)
        If StripTrailing(tokens(wi)) = "WHERE" Then
            whFields = ExtractWhereFields(tokens, wi + 1, aliasMap, defaultTable)
            Exit For
        End If
    Next

    ' Build alias string for storage
    Dim aliasStr : aliasStr = ""
    Dim aKey
    For Each aKey In aliasMap.Keys
        If aliasStr <> "" Then aliasStr = aliasStr & "|"
        aliasStr = aliasStr & aKey & ":" & aliasMap(aKey)
    Next

    AddSql "SELECT", startLine, fullText, tables, aliasStr, resolvedSel, whFields, isStar
End Sub

' Parse a complete UPDATE statement
Sub ParseSqlUpdate(fullText, startLine)
    Dim tokens : tokens = SplitTokens(UCT(fullText))
    If UBound(tokens) < 2 Then Exit Sub

    Dim tableName : tableName = StripTrailing(tokens(1))
    If tableName = "" Then Exit Sub

    Dim aliasMap
    Set aliasMap = CreateObject("Scripting.Dictionary")
    aliasMap.CompareMode = 1

    ' Find SET clause — extract fields before = signs
    Dim setFields : setFields = ""
    Dim idx : idx = 2
    Dim inSet : inSet = False
    Do While idx <= UBound(tokens)
        Dim ut : ut = StripTrailing(tokens(idx))
        If ut = "SET" Then
            inSet = True
            idx = idx + 1
        ElseIf ut = "WHERE" Then
            Exit Do
        ElseIf ut = "" Or ut = "." Then
            Exit Do
        ElseIf inSet Then
            ' Check if next token is "=" — if so, current is a field
            If idx + 1 <= UBound(tokens) Then
                If StripTrailing(tokens(idx + 1)) = "=" Then
                    Dim ref2 : ref2 = tableName & "." & ut
                    If setFields <> "" Then setFields = setFields & "|"
                    setFields = setFields & ref2
                End If
            End If
            idx = idx + 1
        Else
            idx = idx + 1
        End If
    Loop

    ' Extract WHERE fields
    Dim whFields : whFields = ""
    Dim uwi
    For uwi = idx To UBound(tokens)
        If StripTrailing(tokens(uwi)) = "WHERE" Then
            whFields = ExtractWhereFields(tokens, uwi + 1, aliasMap, tableName)
            Exit For
        End If
    Next

    AddSql "UPDATE", startLine, fullText, tableName, "", setFields, whFields, False
End Sub

' Parse a complete DELETE statement
Sub ParseSqlDelete(fullText, startLine)
    Dim tokens : tokens = SplitTokens(UCT(fullText))
    If UBound(tokens) < 1 Then Exit Sub

    Dim aliasMap
    Set aliasMap = CreateObject("Scripting.Dictionary")
    aliasMap.CompareMode = 1
    Dim tableName : tableName = ""
    Dim idx : idx = 1

    ' DELETE FROM table ... or DELETE table ...
    If StripTrailing(tokens(idx)) = "FROM" Then
        idx = idx + 1
        If idx <= UBound(tokens) Then
            tableName = StripTrailing(tokens(idx))
            idx = idx + 1
        End If
    Else
        tableName = StripTrailing(tokens(idx))
        idx = idx + 1
        ' Check for "FROM TABLE @itab" pattern (mass delete — no field check)
        If idx <= UBound(tokens) Then
            If StripTrailing(tokens(idx)) = "FROM" Then
                ' DELETE table FROM TABLE @itab — no SQL fields to check
                AddSql "DELETE", startLine, fullText, tableName, "", "", "", True
                Exit Sub
            End If
        End If
    End If

    If tableName = "" Then Exit Sub

    ' Extract WHERE fields
    Dim whFields : whFields = ""
    Dim dwi
    For dwi = idx To UBound(tokens)
        If StripTrailing(tokens(dwi)) = "WHERE" Then
            whFields = ExtractWhereFields(tokens, dwi + 1, aliasMap, tableName)
            Exit For
        End If
    Next

    AddSql "DELETE", startLine, fullText, tableName, "", "", whFields, False
End Sub

' Dispatcher: parse an accumulated SQL statement
Sub ParseSqlStatement(fullText, startLine)
    Dim tokens : tokens = SplitTokens(UCT(fullText))
    If UBound(tokens) < 0 Then Exit Sub
    Dim kw : kw = tokens(0)
    If kw = "SELECT" Then
        ParseSqlSelect fullText, startLine
    ElseIf kw = "UPDATE" Then
        ParseSqlUpdate fullText, startLine
    ElseIf kw = "DELETE" Then
        ParseSqlDelete fullText, startLine
    End If
End Sub

' Fetch table field definitions -- now a no-op; pre-populated by DDIC helper sidecar.
Sub FetchTableFields(tableName)
    If tableName = "" Then Exit Sub
    If Not g_tblFieldCache.Exists(tableName) Then
        g_tblFieldValid(tableName) = False
    End If
End Sub

' Check if a field exists in the cached table definition
Function HasTableField(tableName, fieldName)
    HasTableField = False
    If Not g_tblFieldCache.Exists(tableName) Then Exit Function
    Dim cached : cached = g_tblFieldCache(tableName)
    Dim entries : entries = Split(cached, "|")
    Dim ei
    Dim uField : uField = UCase(fieldName)
    For ei = 0 To UBound(entries)
        If Left(entries(ei), Len(uField) + 1) = uField & ":" Then
            HasTableField = True
            Exit Function
        End If
    Next
End Function

' Report an SQL field issue
Sub CheckSqlFieldRef(tableField, lineNum, sqlKind, clauseName)
    Dim dotPos : dotPos = InStr(tableField, ".")
    If dotPos = 0 Then Exit Sub
    Dim tblN : tblN = Left(tableField, dotPos - 1)
    Dim fldN : fldN = Mid(tableField, dotPos + 1)
    If tblN = "" Or fldN = "" Then Exit Sub
    If Not g_tblFieldCache.Exists(tblN) Then Exit Sub
    If Not HasTableField(tblN, fldN) Then
        AddIssue "SQL_FIELD_NOT_FOUND", "ERROR", lineNum, fldN, _
                 SC_GLOBAL, DK_VARIABLE, _
                 sqlKind & " " & clauseName & ": field " & fldN & " not in table " & tblN, _
                 "Check field name in SE11 table " & tblN
    End If
End Sub

' =============================================================================
' PHASE 1 -- Read Naming Rules TSV
' =============================================================================
If Not g_fso.FileExists(NAMING_RULES) Then
    AbortError "Naming rules file not found: " & NAMING_RULES
End If

Dim nrFile, nrLine, nrParts, nrIsHeader
Set nrFile = g_fso.OpenTextFile(NAMING_RULES, 1)
nrIsHeader = True
Do While Not nrFile.AtEndOfStream
    nrLine = nrFile.ReadLine
    If nrIsHeader Then
        nrIsHeader = False
    ElseIf Left(Trim(nrLine), 1) <> "#" And Trim(nrLine) <> "" Then
        nrParts = Split(nrLine, vbTab)
        If UBound(nrParts) >= 2 Then
            g_nrCount = g_nrCount + 1
            ReDim Preserve g_nrScope(g_nrCount)
            ReDim Preserve g_nrKind(g_nrCount)
            ReDim Preserve g_nrPrefix(g_nrCount)
            g_nrScope(g_nrCount)  = UCT(nrParts(0))
            g_nrKind(g_nrCount)   = UCT(nrParts(1))
            g_nrPrefix(g_nrCount) = LCase(nrParts(2))
        End If
    End If
Loop
nrFile.Close
WScript.Echo "INFO: Loaded " & g_nrCount & " naming rules."

' =============================================================================
' PHASE 2 -- Parse ABAP Source
' =============================================================================
If Not g_fso.FileExists(ABAP_FILE) Then
    AbortError "ABAP file not found: " & ABAP_FILE
End If

' Helper sub: parse a single declaration entry
Sub ParseDeclEntry(uTokens, lineNum, scope, declKW, paramDir)
    If UBound(uTokens) < 0 Then Exit Sub
    Dim vName : vName = StripTrailing(uTokens(0))
    If vName = "" Then Exit Sub
    ' Track BEGIN OF / END OF structure definitions (skip members)
    If vName = "BEGIN" Then
        g_beginOfDepth = g_beginOfDepth + 1
        ' Register the type name (token after "OF")
        If UBound(uTokens) >= 2 And uTokens(1) = "OF" Then
            Dim typName : typName = StripTrailing(uTokens(2))
            If typName <> "" Then
                g_localTypes(UCT(typName)) = True
                ' BEGIN OF always declares a structure type.
                g_localTypeKind(UCT(typName)) = DK_STRUCTURE
            End If
        End If
        Exit Sub
    End If
    If vName = "END" Then
        g_beginOfDepth = g_beginOfDepth - 1
        If g_beginOfDepth < 0 Then g_beginOfDepth = 0
        Exit Sub
    End If
    If g_beginOfDepth > 0 Then Exit Sub  ' skip members inside BEGIN/END
    ' Reject TYPE-clause continuation keywords that can appear at the start
    ' of a chain-continuation line. e.g.:
    '   DATA: lt_foo TYPE STANDARD TABLE OF foo
    '             WITH DEFAULT KEY,
    '         lv_c TYPE c.
    ' On line 2, the chain handler calls ParseDeclEntry with first token
    ' "WITH" — but WITH is a type-clause keyword, not a new variable.
    ' Without this guard the parser registers WITH as a variable and the
    ' downstream naming check flags it. Same logic applies to INITIAL SIZE,
    ' INHERITING FROM, READ-ONLY, etc.
    If vName = "WITH" Or vName = "INITIAL" Or vName = "INHERITING" Or _
       vName = "RANGE" Or vName = "READ-ONLY" Or vName = "PRESERVING" Or _
       vName = "OCCURS" Or vName = "VISIBLE" Or vName = "ABSTRACT" Then
        Exit Sub
    End If
    Dim vType : vType = ""
    If UBound(uTokens) >= 2 Then
        If uTokens(1) = "TYPE" Or uTokens(1) = "LIKE" Then
            vType = ExtractType(uTokens, 2)
        End If
    End If
    Dim vKind : vKind = GuessDataKind(vType, declKW)
    AddDecl vName, vType, lineNum, scope, vKind, paramDir
    If declKW = "TYPES" Then
        g_localTypes(UCT(vName)) = True
        ' Remember the kind so variables typed by this TYPES can be
        ' re-classified post-parse. E.g. `TYPES tt_x TYPE STANDARD TABLE
        ' OF ty_y` is DK_TABLE; a later `DATA lt_a TYPE tt_x` should
        ' inherit DK_TABLE so the naming check looks up "LOCAL+TABLE"
        ' (prefix lt_) instead of "LOCAL+VARIABLE" (prefix lv_).
        g_localTypeKind(UCT(vName)) = vKind
    End If
End Sub

' Helper sub: process one source line
Sub ProcessSourceLine(rawLine, lineNum)
    ' Skip comment lines
    If Left(Trim(rawLine), 1) = "*" Then Exit Sub

    Dim uLine : uLine = UCT(rawLine)
    If uLine = "" Then Exit Sub

    ' --- Detect inline declarations: DATA(name), FINAL(name) ---
    ' These appear in expression positions (READ TABLE ... INTO DATA(ls_row),
    ' LOOP AT ... INTO DATA(ls_row), SELECT ... INTO TABLE @DATA(lt_data),
    ' assignments lv_x = DATA(...), etc.). Without this scanner, the inline
    ' name has no AddDecl entry and downstream consumers flag it as an
    ' unknown / undeclared / naming violation.
    ' Scan ALL lines (not just declaration lines) — inline DATA() can sit
    ' inside any executable statement.
    On Error Resume Next
    Dim oReInline
    Set oReInline = New RegExp
    oReInline.Pattern = "@?\b(?:DATA|FINAL)\s*\(\s*([A-Z_][A-Z0-9_]*)\s*\)"
    oReInline.IgnoreCase = True
    oReInline.Global = True
    Dim mInline, mItem, sInlineName
    Set mInline = oReInline.Execute(uLine)
    For Each mItem In mInline
        If mItem.SubMatches.Count >= 1 Then
            sInlineName = UCT(mItem.SubMatches(0))
            If sInlineName <> "" Then
                ' Type is unknown for inline DATA() — emit empty so the type
                ' validator skips it rather than flagging a fake mismatch.
                ' Mark with paramDir="INLINE_DATA" so the PHASE 5 naming
                ' check can apply the lenient "any valid LOCAL prefix" rule
                ' instead of forcing DK_VARIABLE's expected "lv_" prefix on
                ' names like LS_ROW / LT_LOG / LO_GRID that are properly
                ' typed for their runtime kind (structure / table / object
                ' ref) but whose kind can't be inferred from the inline RHS.
                AddDecl sInlineName, "", lineNum, g_curScope, DK_VARIABLE, "INLINE_DATA"
                ' Mark as already-used. PHASE 3 scans for uses on lines
                ' OTHER than the declaration line, but for inline DATA()
                ' the declaration line IS the first use (the very same
                ' expression both declares and assigns). Without this
                ' the UNUSED check fires every time. Bug surfaced
                ' 2026-05-11.
                g_varUsed(UCase(sInlineName)) = True
            End If
        End If
    Next
    Err.Clear
    On Error GoTo 0

    Dim tokens : tokens = SplitTokens(uLine)
    If UBound(tokens) < 0 Then Exit Sub
    Dim tok0 : tok0 = tokens(0)

    ' Strip trailing colon from keyword (e.g. "DATA:" -> "DATA")
    If Right(tok0, 1) = ":" Then tok0 = Left(tok0, Len(tok0) - 1)
    ' Also strip trailing period for single-statement keywords (e.g. "ENDCLASS." -> "ENDCLASS")
    If Right(tok0, 1) = "." Then tok0 = Left(tok0, Len(tok0) - 1)

    ' --- Handle chain continuation ---
    If g_inChain Then
        Dim cLine : cLine = UCT(Trim(rawLine))
        If Left(cLine, 1) = "," Then cLine = Trim(Mid(cLine, 2))
        If cLine = "" Or cLine = "." Then
            g_inChain = False : Exit Sub
        End If
        Dim cTokens : cTokens = SplitTokens(cLine)
        If g_chainKeyword = "PARAMETERS" Then
            ' PARAMETERS chain: each member is a selection param
            If UBound(cTokens) >= 0 Then
                Dim cpName : cpName = StripTrailing(cTokens(0))
                Dim cpType : cpType = ""
                If UBound(cTokens) >= 2 And cTokens(1) = "TYPE" Then
                    cpType = ExtractType(cTokens, 2)
                End If
                AddDecl cpName, cpType, lineNum, SC_SELECTION, DK_VARIABLE, "PARAMETER"
            End If
        Else
            ParseDeclEntry cTokens, lineNum, g_chainScope, g_chainKeyword, ""
        End If
        If EndsWithPeriod(rawLine) Then g_inChain = False
        Exit Sub
    End If

    ' --- Track scope changes ---
    ' Skip SELECTION-SCREEN lines (not declarations)
    If tok0 = "SELECTION-SCREEN" Then Exit Sub

    ' --- CLASS DEFINITION / IMPLEMENTATION / ENDCLASS ---
    If tok0 = "CLASS" Then
        If UBound(tokens) >= 2 Then
            Dim clName : clName = StripTrailing(tokens(1))
            Dim clTok2 : clTok2 = StripTrailing(tokens(2))
            If clTok2 = "DEFINITION" Then
                g_inClassDef = True
                g_inClassImpl = False
                g_curClassName = clName
                g_curSection = ""
                g_classDefined(UCT(clName)) = True
                Exit Sub
            ElseIf clTok2 = "IMPLEMENTATION" Then
                g_inClassImpl = True
                g_inClassDef = False
                g_curClassName = clName
                Exit Sub
            End If
        End If
    End If

    If tok0 = "ENDCLASS" Then
        If g_inClassDef Then
            g_inClassDef = False
            g_curClassName = ""
            g_curSection = ""
            g_inMethodsChain = False
            g_methodsBuf = ""
        End If
        If g_inClassImpl Then
            g_inClassImpl = False
            g_curClassName = ""
        End If
        g_curScope = SC_GLOBAL
        Exit Sub
    End If

    ' --- Inside CLASS DEFINITION: parse sections, METHODS, DATA ---
    If g_inClassDef Then
        ' Track PUBLIC/PROTECTED/PRIVATE SECTION
        If UBound(tokens) >= 1 Then
            If tokens(1) = "SECTION." Or StripTrailing(tokens(1)) = "SECTION" Then
                If tok0 = "PUBLIC" Or tok0 = "PROTECTED" Or tok0 = "PRIVATE" Then
                    g_curSection = tok0
                    Exit Sub
                End If
            End If
        End If

        ' Handle METHODS chain continuation
        If g_inMethodsChain Then
            Dim mcLine2 : mcLine2 = UCT(Trim(StripInlineComment(rawLine)))
            If mcLine2 = "" Then Exit Sub
            ' Strip leading comma
            If Left(mcLine2, 1) = "," Then mcLine2 = Trim(Mid(mcLine2, 2))
            If mcLine2 = "" Or mcLine2 = "." Then
                If mcLine2 = "." Then
                    ' Parse any accumulated buffer
                    If g_methodsBuf <> "" Then
                        Dim mbFinal : mbFinal = g_methodsBuf
                        If Right(mbFinal, 1) = "." Or Right(mbFinal, 1) = "," Then
                            mbFinal = Trim(Left(mbFinal, Len(mbFinal) - 1))
                        End If
                        If mbFinal <> "" Then ParseMethodSignature g_curClassName, mbFinal, g_methodsBufLine
                    End If
                    g_inMethodsChain = False
                    g_methodsBuf = ""
                End If
                Exit Sub
            End If

            Dim mcEndsComma : mcEndsComma = (Right(Trim(mcLine2), 1) = ",")
            Dim mcEndsPeriod : mcEndsPeriod = (Right(Trim(mcLine2), 1) = ".")

            ' Accumulate
            If g_methodsBuf <> "" Then
                g_methodsBuf = g_methodsBuf & " " & mcLine2
            Else
                g_methodsBuf = mcLine2
                g_methodsBufLine = lineNum
            End If

            If mcEndsComma Or mcEndsPeriod Then
                Dim mbClean : mbClean = g_methodsBuf
                If Right(mbClean, 1) = "," Or Right(mbClean, 1) = "." Then
                    mbClean = Trim(Left(mbClean, Len(mbClean) - 1))
                End If
                If mbClean <> "" Then ParseMethodSignature g_curClassName, mbClean, g_methodsBufLine
                g_methodsBuf = ""
                g_methodsBufLine = lineNum
                If mcEndsPeriod Then g_inMethodsChain = False
            End If
            Exit Sub
        End If

        ' Parse METHODS declarations
        If tok0 = "METHODS" Then
            Dim methOrigTok : methOrigTok = tokens(0)
            Dim methHasColon : methHasColon = False
            Dim methRest : methRest = ""
            If Right(methOrigTok, 1) = ":" Then
                methHasColon = True
                methRest = Trim(Mid(Trim(rawLine), Len(methOrigTok) + 1))
            Else
                methRest = Trim(Mid(Trim(rawLine), Len(tok0) + 1))
                If Left(UCT(methRest), 1) = ":" Then
                    methHasColon = True
                    methRest = Trim(Mid(methRest, 2))
                End If
            End If

            If methHasColon Then
                g_inMethodsChain = True
            End If

            If methRest <> "" And methRest <> "." Then
                Dim methU : methU = UCT(Trim(StripInlineComment(methRest)))
                Dim methEndsComma : methEndsComma = (Right(Trim(methU), 1) = ",")
                Dim methEndsPeriod : methEndsPeriod = (Right(Trim(methU), 1) = ".")

                If methEndsComma Or methEndsPeriod Then
                    ' Complete single-method entry on this line
                    Dim msClean : msClean = methU
                    If Right(msClean, 1) = "," Or Right(msClean, 1) = "." Then
                        msClean = Trim(Left(msClean, Len(msClean) - 1))
                    End If
                    If msClean <> "" Then ParseMethodSignature g_curClassName, msClean, lineNum
                    If methEndsPeriod Then g_inMethodsChain = False
                Else
                    ' Multi-line: start accumulating
                    g_methodsBuf = methU
                    g_methodsBufLine = lineNum
                End If
            End If

            If EndsWithPeriod(rawLine) Then g_inMethodsChain = False
            Exit Sub
        End If

        ' For DATA/CLASS-DATA inside CLASS DEFINITION, fall through to
        ' declaration handler below — scope override happens there.
        ' Skip other class-definition-only keywords
        If tok0 = "ALIASES" Or tok0 = "EVENTS" Or tok0 = "INTERFACES" Then Exit Sub
    End If

    If tok0 = "FORM" Or tok0 = "METHOD" Or tok0 = "FUNCTION" Then
        g_curScope = SC_LOCAL
        ' Parse FORM parameters
        If tok0 = "FORM" Then
            Dim fi, fpDir, fpSkipUntil
            fpDir = ""
            fpSkipUntil = -1
            For fi = 2 To UBound(tokens)
                If fi <= fpSkipUntil Then
                    ' Skip tokens consumed as type annotation
                ElseIf tokens(fi) = "USING" Then
                    fpDir = "IMPORTING"
                ElseIf tokens(fi) = "CHANGING" Then
                    fpDir = "CHANGING"
                ElseIf tokens(fi) = "TABLES" Then
                    fpDir = "IMPORTING_TABLE"
                ElseIf tokens(fi) = "." Or StripTrailing(tokens(fi)) = "" Then
                    Exit For
                ElseIf fpDir <> "" And tokens(fi) <> "TYPE" And tokens(fi) <> "LIKE" And _
                       tokens(fi) <> "STRUCTURE" And Left(tokens(fi), 1) <> "(" Then
                    ' Parameter name
                    Dim fpName : fpName = StripTrailing(tokens(fi))
                    Dim fpType : fpType = ""
                    If fi + 1 <= UBound(tokens) Then
                        If tokens(fi + 1) = "TYPE" Or tokens(fi + 1) = "LIKE" Or tokens(fi + 1) = "STRUCTURE" Then
                            fpType = ExtractType(tokens, fi + 2)
                            ' Calculate how many tokens to skip
                            Dim fpTypeTokens : fpTypeTokens = SplitTokens(fpType)
                            fpSkipUntil = fi + 1 + UBound(fpTypeTokens) + 1
                        End If
                    End If
                    Dim fpKind : fpKind = DK_VARIABLE
                    If fpDir = "IMPORTING_TABLE" Then fpKind = DK_TABLE
                    Dim fpDirFull : fpDirFull = fpDir
                    If fpKind = DK_TABLE And fpDir <> "IMPORTING_TABLE" Then
                        fpDirFull = fpDir & "_TABLE"
                    End If
                    AddDecl fpName, fpType, lineNum, SC_PARAM, fpKind, fpDirFull
                End If
            Next
        End If
        Exit Sub
    End If

    If tok0 = "ENDFORM" Or tok0 = "ENDMETHOD" Or tok0 = "ENDFUNCTION" Then
        g_curScope = SC_GLOBAL : Exit Sub
    End If

    ' --- PARAMETERS (including chain form PARAMETERS:) ---
    If tok0 = "PARAMETERS" Or tok0 = "PARAMETER" Then
        ' Check for chain form: PARAMETERS: p1 TYPE t1, p2 TYPE t2.
        Dim pRestLine : pRestLine = Trim(Mid(Trim(rawLine), Len(tokens(0)) + 1))
        If Left(UCT(pRestLine), 1) = ":" Or Right(tok0 & Right(tokens(0), 1), 1) = ":" Then
            ' Chain PARAMETERS declaration
            g_inChain = True
            g_chainKeyword = "PARAMETERS"
            g_chainScope = SC_SELECTION
            If Left(UCT(pRestLine), 1) = ":" Then pRestLine = Trim(Mid(pRestLine, 2))
            If pRestLine <> "" And pRestLine <> "." Then
                Dim pChTokens : pChTokens = SplitTokens(UCT(pRestLine))
                If UBound(pChTokens) >= 0 Then
                    Dim pChName : pChName = StripTrailing(pChTokens(0))
                    Dim pChType : pChType = ""
                    If UBound(pChTokens) >= 2 And pChTokens(1) = "TYPE" Then
                        pChType = ExtractType(pChTokens, 2)
                    End If
                    AddDecl pChName, pChType, lineNum, SC_SELECTION, DK_VARIABLE, "PARAMETER"
                End If
            End If
            If EndsWithPeriod(rawLine) Then g_inChain = False
        Else
            ' Single PARAMETERS declaration
            If UBound(tokens) >= 1 Then
                Dim pName : pName = StripTrailing(tokens(1))
                Dim pType : pType = ""
                If UBound(tokens) >= 3 Then
                    If tokens(2) = "TYPE" Then pType = ExtractType(tokens, 3)
                End If
                AddDecl pName, pType, lineNum, SC_SELECTION, DK_VARIABLE, "PARAMETER"
            End If
        End If
        Exit Sub
    End If

    ' --- SELECT-OPTIONS ---
    If tok0 = "SELECT-OPTIONS" Then
        If UBound(tokens) >= 1 Then
            Dim soName : soName = StripTrailing(tokens(1))
            Dim soType : soType = ""
            Dim soIdx
            For soIdx = 2 To UBound(tokens)
                If tokens(soIdx) = "FOR" And soIdx + 1 <= UBound(tokens) Then
                    soType = tokens(soIdx + 1) : Exit For
                End If
            Next
            AddDecl soName, soType, lineNum, SC_SELECTION, DK_TABLE, "SELECT_OPTION"
        End If
        Exit Sub
    End If

    ' --- DATA / TYPES / CONSTANTS / FIELD-SYMBOLS / CLASS-DATA / STATICS ---
    Dim isDecl : isDecl = False
    Dim declKW : declKW = ""
    If tok0 = "DATA" Or tok0 = "CLASS-DATA" Or tok0 = "STATICS" Then
        isDecl = True : declKW = "DATA"
    ElseIf tok0 = "TYPES" Then
        isDecl = True : declKW = "TYPES"
    ElseIf tok0 = "CONSTANTS" Then
        isDecl = True : declKW = "CONSTANTS"
    ElseIf tok0 = "FIELD-SYMBOLS" Then
        isDecl = True : declKW = "FIELD-SYMBOLS"
    End If

    If Not isDecl Then Exit Sub

    ' Determine effective scope (override for CLASS DEFINITION members)
    Dim effectiveScope : effectiveScope = g_curScope
    If g_inClassDef Then
        If tok0 = "CLASS-DATA" Then
            effectiveScope = SC_GLOBAL   ' static attrs use gv_/gs_/gt_
        Else
            effectiveScope = SC_MEMBER   ' instance attrs use mv_/ms_/mt_
        End If
    End If

    ' Check for chain declaration (keyword followed by colon)
    ' Colon may be attached to keyword (DATA:) or separate (DATA :)
    Dim origTok0 : origTok0 = tokens(0)
    Dim hasColon : hasColon = False
    Dim restLine : restLine = ""

    If Right(origTok0, 1) = ":" Then
        ' Colon was attached to keyword (DATA:) — already stripped from tok0
        hasColon = True
        restLine = Trim(Mid(Trim(rawLine), Len(origTok0) + 1))
    Else
        restLine = Trim(Mid(Trim(rawLine), Len(tok0) + 1))
        If Left(UCT(restLine), 1) = ":" Then
            hasColon = True
            restLine = Trim(Mid(restLine, 2))
        End If
    End If

    If hasColon Then
        g_inChain = True
        g_chainKeyword = declKW
        g_chainScope = effectiveScope
        If restLine <> "" And restLine <> "." Then
            Dim chTokens : chTokens = SplitTokens(UCT(restLine))
            ParseDeclEntry chTokens, lineNum, effectiveScope, declKW, ""
        End If
        If EndsWithPeriod(rawLine) Then g_inChain = False
    Else
        ' Single declaration
        Dim sTokens : sTokens = SplitTokens(uLine)
        If UBound(sTokens) >= 1 Then
            Dim subArr()
            ReDim subArr(UBound(sTokens) - 1)
            Dim si
            For si = 1 To UBound(sTokens)
                subArr(si - 1) = sTokens(si)
            Next
            ParseDeclEntry subArr, lineNum, effectiveScope, declKW, ""
        End If
    End If
End Sub

' Main parsing loop
Dim srcFile, lineNum
Set srcFile = g_fso.OpenTextFile(ABAP_FILE, 1)
lineNum = 0
Do While Not srcFile.AtEndOfStream
    Dim rawLine : rawLine = srcFile.ReadLine
    lineNum = lineNum + 1
    g_srcCount = g_srcCount + 1
    ReDim Preserve g_srcLines(g_srcCount)
    g_srcLines(g_srcCount) = rawLine
    ProcessSourceLine rawLine, lineNum
Loop
srcFile.Close
WScript.Echo "INFO: Parsed " & g_dCount & " declaration(s) from " & lineNum & " lines."
If g_cmCount > 0 Then WScript.Echo "INFO: Parsed " & g_cmCount & " class method parameter(s) from " & g_classDefined.Count & " class(es)."

' =============================================================================
' PHASE 2b -- Parse SQL Statements
' =============================================================================
Dim sqlBuf     : sqlBuf = ""
Dim sqlBufLine : sqlBufLine = 0
Dim inSqlAccum : inSqlAccum = False
Dim sqli

For sqli = 1 To g_srcCount
    Dim sqlRaw : sqlRaw = g_srcLines(sqli)
    Dim sqlTrimmed : sqlTrimmed = Trim(sqlRaw)

    ' Skip full comment lines — but allow them inside accumulating block
    If Left(sqlTrimmed, 1) = "*" Then
        If Not inSqlAccum Then
            ' Not in accumulation — skip entirely
        End If
    Else
        Dim sqlCodePart : sqlCodePart = StripInlineComment(sqlRaw)
        Dim sqlU : sqlU = UCT(sqlCodePart)

        If inSqlAccum Then
            If sqlU <> "" Then sqlBuf = sqlBuf & " " & sqlU
            If EndsWithPeriod(sqlRaw) Then
                ParseSqlStatement sqlBuf, sqlBufLine
                inSqlAccum = False
                sqlBuf = ""
            End If
        Else
            If sqlU <> "" Then
                Dim sqlTokens : sqlTokens = SplitTokens(sqlU)
                If UBound(sqlTokens) >= 0 Then
                    Dim sqlTok0 : sqlTok0 = sqlTokens(0)
                    If Right(sqlTok0, 1) = ":" Then sqlTok0 = Left(sqlTok0, Len(sqlTok0) - 1)

                    If IsSqlKeyword(sqlTok0, sqlTokens) Then
                        sqlBuf = sqlU
                        sqlBufLine = sqli
                        If EndsWithPeriod(sqlRaw) Then
                            ParseSqlStatement sqlBuf, sqlBufLine
                            sqlBuf = ""
                        Else
                            inSqlAccum = True
                        End If
                    End If
                End If
            End If
        End If
    End If
Next
WScript.Echo "INFO: Parsed " & g_sqlCount & " SQL statement(s) from " & g_srcCount & " lines."

' =============================================================================
' PHASE 3 -- Detect Variable Usage
' =============================================================================
Dim di, li
For di = 1 To g_dCount
    Dim searchName : searchName = g_dName(di)
    If searchName = "" Then
        ' skip empty names
    Else
        Dim searchUpper : searchUpper = UCase(searchName)
        Dim declLineNum : declLineNum = g_dLine(di)
        Dim found : found = False

        For li = 1 To g_srcCount
            If li <> declLineNum And Not found Then
                Dim srcUpper : srcUpper = UCase(g_srcLines(li))
                If Left(Trim(srcUpper), 1) <> "*" Then
                    Dim pos : pos = InStr(srcUpper, searchUpper)
                    Do While pos > 0 And Not found
                        Dim chBefore : chBefore = ""
                        Dim chAfter  : chAfter  = ""
                        If pos > 1 Then chBefore = Mid(srcUpper, pos - 1, 1)
                        Dim endPos : endPos = pos + Len(searchUpper)
                        If endPos <= Len(srcUpper) Then chAfter = Mid(srcUpper, endPos, 1)
                        If IsWordBoundary(chBefore) And IsWordBoundary(chAfter) Then
                            g_varUsed(searchUpper) = True
                            found = True
                        Else
                            pos = InStr(pos + 1, srcUpper, searchUpper)
                        End If
                    Loop
                End If
            End If
        Next
    End If
Next
WScript.Echo "INFO: Variable usage scan complete."

' =============================================================================
' PHASE 4 / 4b -- DDIC Type & Table Field Validation via NCo 3.1 sidecar PS1
' =============================================================================
Dim sapConnected : sapConnected = False

If SAP_SERVER <> "" And DDIC_HELPER_PS1 <> "" Then
    ' --- Collect unique types and SQL tables into one batch lookup ---
    Dim batchNames
    Set batchNames = CreateObject("Scripting.Dictionary")
    batchNames.CompareMode = 1

    Dim ti
    For ti = 1 To g_dCount
        Dim tRef : tRef = g_dType(ti)
        If tRef <> "" Then
            Dim baseT : baseT = ExtractBaseType(tRef)
            If baseT <> "" Then
                ' Skip <table>-<field> type-of syntax — these are valid
                ' ABAP but not type names; sending them to the DDIC
                ' lookup pollutes the cache with UNKNOWN entries that
                ' then drive false TYPE_NOT_FOUND findings downstream.
                If InStr(baseT, "-") > 0 Then
                    ' skip
                ElseIf Not g_builtinTypes.Exists(baseT) And Not g_localTypes.Exists(baseT) Then
                    If Not batchNames.Exists(baseT) Then batchNames(baseT) = True
                End If
            End If
        End If
    Next

    Dim sti
    For sti = 1 To g_sqlCount
        If g_sqlTables(sti) <> "" Then
            Dim stArr : stArr = Split(g_sqlTables(sti), "|")
            Dim ste
            For Each ste In stArr
                If ste <> "" And Not batchNames.Exists(ste) Then batchNames(ste) = True
            Next
        End If
    Next

    WScript.Echo "INFO: DDIC sidecar batch: " & batchNames.Count & " name(s) to look up"

    If batchNames.Count > 0 Then
        ' --- Write request file (UTF-8 plain text, one name per line) ---
        Dim fReq : Set fReq = g_fso.CreateTextFile(DDIC_REQUEST_FILE, True, False)
        Dim bk
        For Each bk In batchNames.Keys
            fReq.WriteLine bk
        Next
        fReq.Close

        ' --- Run helper PS1 (32-bit PowerShell, hidden, wait) ---
        Dim wsh : Set wsh = CreateObject("WScript.Shell")
        Dim cmd
        cmd = "C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File """ & DDIC_HELPER_PS1 & """"
        WScript.Echo "INFO: Invoking DDIC helper: " & DDIC_HELPER_PS1
        Dim rc : rc = wsh.Run(cmd, 0, True)
        WScript.Echo "INFO: DDIC helper exit code = " & rc

        ' --- Parse result TSV ---
        If g_fso.FileExists(DDIC_RESULT_FILE) Then
            Dim fRes : Set fRes = g_fso.OpenTextFile(DDIC_RESULT_FILE, 1, False, 0) ' system default (UTF-8 OK for ASCII)
            Do Until fRes.AtEndOfStream
                Dim line : line = fRes.ReadLine
                If line <> "" Then
                    Dim parts : parts = Split(line, vbTab)
                    If UBound(parts) >= 1 Then
                        Dim nm : nm = UCase(Trim(parts(0)))
                        Dim kd : kd = Trim(parts(1))
                        Dim dat : dat = ""
                        If UBound(parts) >= 2 Then dat = parts(2)
                        If kd = TK_STRUCT Then
                            g_typeKind(nm) = TK_STRUCT
                            g_tblFieldCache(nm) = dat
                            g_tblFieldValid(nm) = True
                        ElseIf kd = TK_DTEL Then
                            g_typeKind(nm) = TK_DTEL
                            ' helper returns "DT:LEN:DEC"; preserve just DT for legacy g_typeDtel
                            Dim dp : dp = Split(dat, ":")
                            If UBound(dp) >= 0 Then g_typeDtel(nm) = dp(0)
                        Else
                            g_typeKind(nm) = TK_UNKNOWN
                            g_tblFieldValid(nm) = False
                        End If
                    End If
                End If
            Loop
            fRes.Close
            sapConnected = True
            WScript.Echo "INFO: DDIC lookup complete (" & g_typeKind.Count & " entries)."
        Else
            WScript.Echo "WARNING: DDIC helper produced no result file. Skipping type validation."
        End If
    End If

    ' Update data kinds based on type resolution
    If sapConnected Then
        Dim ui
        For ui = 1 To g_dCount
            If g_dKind(ui) = DK_VARIABLE Then
                Dim uBase : uBase = ExtractBaseType(g_dType(ui))
                If g_typeKind.Exists(uBase) Then
                    If g_typeKind(uBase) = TK_STRUCT Then g_dKind(ui) = DK_STRUCTURE
                End If
            End If
        Next
    End If
ElseIf SAP_SERVER <> "" Then
    WScript.Echo "WARNING: DDIC_HELPER_PS1 token not set. Skipping type validation."
End If

' Re-classify variables typed by LOCAL TYPES (runs regardless of RFC
' connection — local TYPES are parsed offline). Without this pass, a
' variable like `lt_a TYPE tt_y` parses as DK_VARIABLE because
' GuessDataKind only sees the bare type name, not its definition; the
' naming check then looks up "LOCAL+VARIABLE" (prefix lv_) and produces
' a false NAMING warning for the (correct) "lt_" prefix. After this pass
' lt_a inherits DK_TABLE from tt_y's declaration. Bug surfaced 2026-05-11.
Dim lui
For lui = 1 To g_dCount
    If g_dKind(lui) = DK_VARIABLE Then
        Dim luBase : luBase = ExtractBaseType(g_dType(lui))
        If luBase <> "" And g_localTypeKind.Exists(luBase) Then
            g_dKind(lui) = g_localTypeKind(luBase)
        End If
    End If
Next

' --- ResolveType subroutine -- now a no-op; pre-populated by DDIC helper sidecar.
Sub ResolveType(typeName)
    If typeName = "" Or typeName = TK_UNKNOWN Then Exit Sub
    If Not g_typeKind.Exists(typeName) Then g_typeKind(typeName) = TK_UNKNOWN
End Sub

' =============================================================================
' PHASE 5 -- Check Naming Conventions
' =============================================================================
Dim ni
For ni = 1 To g_dCount
    Dim nName   : nName   = g_dName(ni)
    Dim nScope  : nScope  = g_dScope(ni)
    Dim nKind   : nKind   = g_dKind(ni)
    Dim nDir    : nDir    = g_dParamDir(ni)
    Dim nLineN  : nLineN  = g_dLine(ni)

    ' Skip ABAP keywords that were erroneously parsed as declarations
    If InStr(nName, "-") > 0 And Left(UCT(nName), 9) = "SELECTION" Then
        ' Skip SELECTION-SCREEN
    ElseIf g_localTypes.Exists(UCT(nName)) Then
        ' Skip TYPES declarations. The naming rules table covers DATA
        ' declarations (variables) only. TYPES (table types, structure
        ' types) use a separate convention — `tt_*` for table types,
        ' `ty_*` for structure types — which is not in scope for this
        ' checker. Without this guard, a `TYPES: tt_rows TYPE STANDARD
        ' TABLE OF mara` is registered with DK_TABLE and the naming
        ' check incorrectly demands `gt_*` (the variable prefix).
        ' False positive observed 2026-05-11 on ZMMRMAT030R01 lines
        ' 40/49/51/53 (TT_ROWS / TT_LOG / TT_FIX / TT_2048).
    Else

    ' Determine lookup keys for naming rules
    Dim lookupScope : lookupScope = nScope
    Dim lookupKind  : lookupKind  = nKind

    If nScope = SC_PARAM Then
        lookupKind = nDir
        If nKind = DK_STRUCTURE And InStr(nDir, "_STRUCT") = 0 Then
            lookupKind = nDir & "_STRUCT"
        ElseIf nKind = DK_TABLE And InStr(nDir, "_TABLE") = 0 Then
            lookupKind = nDir & "_TABLE"
        End If
    End If

    If nScope = SC_SELECTION Then
        lookupKind = nDir
    End If

    ' Lookup expected prefix
    Dim expPrefix : expPrefix = ""
    Dim ri
    For ri = 1 To g_nrCount
        If g_nrScope(ri) = lookupScope And g_nrKind(ri) = lookupKind Then
            expPrefix = g_nrPrefix(ri)
            Exit For
        End If
    Next

    ' For PARAM/VARIABLE kind: if the actual variable prefix matches any valid
    ' PARAM rule (IMPORTING_STRUCT, IMPORTING_TABLE, EXPORTING_STRUCT, etc.),
    ' accept it. This handles cases where type inference returns VARIABLE but the
    ' parameter is actually a structure or table type.
    If expPrefix <> "" And nScope = SC_PARAM And nKind = DK_VARIABLE Then
        Dim lcPName : lcPName = LCase(nName)
        If Left(lcPName, Len(expPrefix)) <> expPrefix Then
            ' Check if it matches any other PARAM scope rule
            Dim altMatch : altMatch = False
            Dim ai
            For ai = 1 To g_nrCount
                If g_nrScope(ai) = SC_PARAM And g_nrPrefix(ai) <> "" Then
                    If Left(lcPName, Len(g_nrPrefix(ai))) = g_nrPrefix(ai) Then
                        altMatch = True
                        Exit For
                    End If
                End If
            Next
            If altMatch Then expPrefix = ""  ' skip issue — prefix valid for another PARAM kind
        End If
    End If

    ' Same trick for inline DATA(name) / FINAL(name) declarations: the
    ' RHS type isn't analyzed, so AddDecl registers them as DK_VARIABLE.
    ' Accept ANY valid LOCAL prefix (lv_/ls_/lt_/lo_/lr_/lc_) because we
    ' genuinely don't know the runtime kind. Marker `paramDir =
    ' "INLINE_DATA"` is set in the inline-detection block above.
    ' Without this, `DATA(ls_row)` from `READ TABLE ... INTO DATA(ls_row)`
    ' flags as "prefix ls_ expected lv_" — false positive observed
    ' 2026-05-11 on ZMMRMAT030R01 lines 120-152 (LO_MAIN / LT_LOG / LS_LOG
    ' / LT_FIX / LT_ROWS / LS_ROW / LS_V / LS_B).
    If expPrefix <> "" And nScope = SC_LOCAL And nDir = "INLINE_DATA" Then
        Dim lcIName : lcIName = LCase(nName)
        If Left(lcIName, Len(expPrefix)) <> expPrefix Then
            Dim inlineAltMatch : inlineAltMatch = False
            Dim ii
            For ii = 1 To g_nrCount
                If g_nrScope(ii) = SC_LOCAL And g_nrPrefix(ii) <> "" Then
                    If Left(lcIName, Len(g_nrPrefix(ii))) = g_nrPrefix(ii) Then
                        inlineAltMatch = True
                        Exit For
                    End If
                End If
            Next
            If inlineAltMatch Then expPrefix = ""  ' skip — prefix valid for another LOCAL kind
        End If
    End If

    ' MEMBER scope alt-match: accept BOTH conventional ABAP prefixes for
    ' class attributes — `g*` (g{v,s,t,c,o,r}_) and `m*` (m{v,s,t,c,o,r}_).
    ' The naming rules table ships with `g*` per the customer's preference
    ' ("Pattern B, use gt_*"), but generators that emit `m*` for local-class
    ' PRIVATE SECTION members (e.g. CLASS lcl_main DEFINITION ... PRIVATE
    ' SECTION DATA: mt_fixed TYPE ...) are equally valid and shouldn't be
    ' flagged. Both conventions are widespread in production ABAP code.
    ' False positive observed 2026-05-11 evening (third regression run,
    ' agent a8a675bc31c82fdb5) on ZMMRMAT031R01 lines 98-101 (MT_FIXED_WERKS
    ' / MT_FIXED_BUKRS / MT_FILE / MT_RESULTS).
    If expPrefix <> "" And nScope = SC_MEMBER Then
        Dim lcMName : lcMName = LCase(nName)
        If Left(lcMName, Len(expPrefix)) <> expPrefix Then
            ' Compute the "alt convention" prefix by swapping the first
            ' character between g and m. Examples: "gt_" <-> "mt_",
            ' "gv_" <-> "mv_", "go_" <-> "mo_". If the variable matches
            ' the alt prefix, accept it.
            Dim memberAlt : memberAlt = ""
            If Left(expPrefix, 1) = "g" Then
                memberAlt = "m" & Mid(expPrefix, 2)
            ElseIf Left(expPrefix, 1) = "m" Then
                memberAlt = "g" & Mid(expPrefix, 2)
            End If
            If memberAlt <> "" And Left(lcMName, Len(memberAlt)) = memberAlt Then
                expPrefix = ""  ' skip — alt convention is acceptable for MEMBER
            End If
        End If
    End If

    If expPrefix <> "" Then
        Dim lowerName : lowerName = LCase(nName)
        Dim prefixLen : prefixLen = Len(expPrefix)

        ' For field symbols with < prefix in rule
        If Left(expPrefix, 1) = "<" Then
            If Left(lowerName, 1) = "<" Then
                Dim innerLower : innerLower = Mid(lowerName, 2)
                Dim innerPrefix : innerPrefix = Mid(expPrefix, 2)
                If Left(innerLower, Len(innerPrefix)) <> innerPrefix Then
                    Dim fsSugInner : fsSugInner = nName
                    If Left(fsSugInner, 1) = "<" Then fsSugInner = Mid(fsSugInner, 2)
                    If Right(fsSugInner, 1) = ">" Then fsSugInner = Left(fsSugInner, Len(fsSugInner) - 1)
                    Dim fsUPos : fsUPos = InStr(fsSugInner, "_")
                    If fsUPos > 0 And fsUPos <= 4 Then fsSugInner = Mid(fsSugInner, fsUPos + 1)
                    Dim fsSug : fsSug = "<" & UCase(innerPrefix) & fsSugInner & ">"
                    AddIssue "NAMING", "WARNING", nLineN, nName, nScope, nKind, _
                             "prefix mismatch, expected """ & expPrefix & """", _
                             "Rename " & nName & " to " & fsSug
                End If
            End If
        Else
            If Left(lowerName, prefixLen) <> expPrefix Then
                ' Generate suggested new name
                Dim sugBase : sugBase = nName
                Dim sugUPos : sugUPos = InStr(sugBase, "_")
                If sugUPos > 0 And sugUPos <= 4 Then sugBase = Mid(sugBase, sugUPos + 1)
                Dim sugName : sugName = UCase(expPrefix) & sugBase
                AddIssue "NAMING", "WARNING", nLineN, nName, nScope, nKind, _
                         "prefix """ & LCase(Left(nName, prefixLen)) & """ expected """ & expPrefix & """", _
                         "Rename " & nName & " to " & sugName
            End If
        End If
    End If
    End If  ' End of SELECTION-SCREEN skip
Next
WScript.Echo "INFO: Naming convention check complete."

' =============================================================================
' PHASE 5b -- Check Type Validity
' =============================================================================
If sapConnected Then
    Dim tvi
    For tvi = 1 To g_dCount
        Dim tvType : tvType = g_dType(tvi)
        If tvType <> "" Then
            Dim tvBase : tvBase = ExtractBaseType(tvType)
            If tvBase <> "" Then
                ' Skip table-field type-of syntax: `TYPE mara-matnr`,
                ' `TYPE rlgrap-filename`, etc. These are valid ABAP
                ' ("type of this field on that table"); the DDIC lookup
                ' fails because <table>-<field> is not a type name, so
                ' the post-resolve check used to produce a false
                ' TYPE_NOT_FOUND. The full check (does <table> exist?
                ' does <field> exist on it?) would need a DD03L call —
                ' tracked as a future enhancement. For now, accept the
                ' syntax silently. Bug surfaced 2026-05-11.
                If InStr(tvBase, "-") > 0 Then
                    ' table-field syntax — skip TYPE_NOT_FOUND
                ElseIf Not g_builtinTypes.Exists(tvBase) And Not g_localTypes.Exists(tvBase) Then
                    If g_typeKind.Exists(tvBase) Then
                        If g_typeKind(tvBase) = TK_UNKNOWN Then
                            AddIssue "TYPE_NOT_FOUND", "ERROR", g_dLine(tvi), g_dName(tvi), _
                                     g_dScope(tvi), g_dKind(tvi), _
                                     "type " & tvBase & " not in source or SAP dictionary", _
                                     "Check type name or create in SE11"
                        Else
                            AddIssue "TYPE_RESOLVED", "INFO", g_dLine(tvi), g_dName(tvi), _
                                     g_dScope(tvi), g_dKind(tvi), _
                                     "type " & tvBase & " is " & g_typeKind(tvBase), ""
                        End If
                    End If
                End If
            End If
        End If
    Next
    WScript.Echo "INFO: Type validity check complete."
End If

' =============================================================================
' PHASE 5c -- Check Unused Variables
' =============================================================================
Dim uvi
For uvi = 1 To g_dCount
    Dim uvName : uvName = g_dName(uvi)
    Dim uvScope : uvScope = g_dScope(uvi)

    ' Skip selection screen params, TYPES, and FORM/METHOD params
    If uvScope <> SC_SELECTION And uvScope <> SC_PARAM Then
        If Not g_localTypes.Exists(uvName) Then
            If g_varUsed.Exists(UCase(uvName)) Then
                If Not g_varUsed(UCase(uvName)) Then
                    AddIssue "UNUSED", "WARNING", g_dLine(uvi), uvName, _
                             uvScope, g_dKind(uvi), _
                             "declared at line " & g_dLine(uvi) & ", never referenced", _
                             "Remove declaration or add usage"
                End If
            End If
        End If
    End If
Next
WScript.Echo "INFO: Unused variable check complete."

' =============================================================================
' PHASE 5d -- SQL Field Validation
' =============================================================================
If sapConnected And g_sqlCount > 0 Then
    Dim svi
    For svi = 1 To g_sqlCount
        ' Skip SELECT *
        If Not g_sqlIsStar(svi) Then
            ' Check tables exist
            Dim svAllOk : svAllOk = True
            If g_sqlTables(svi) <> "" Then
                Dim svTables : svTables = Split(g_sqlTables(svi), "|")
                Dim svt
                For Each svt In svTables
                    If svt <> "" Then
                        If g_tblFieldValid.Exists(svt) Then
                            If Not g_tblFieldValid(svt) Then
                                AddIssue "SQL_TABLE_NOT_FOUND", "ERROR", g_sqlStartLine(svi), _
                                         svt, SC_GLOBAL, DK_VARIABLE, _
                                         g_sqlKind(svi) & " references table " & svt & " not found in SAP dictionary", _
                                         "Check table name or create in SE11"
                                svAllOk = False
                            End If
                        End If
                    End If
                Next
            End If

            If svAllOk Then
                ' Check SELECT/SET fields
                If g_sqlSelFields(svi) <> "" Then
                    Dim sfCheckArr : sfCheckArr = Split(g_sqlSelFields(svi), "|")
                    Dim sfci
                    For sfci = 0 To UBound(sfCheckArr)
                        CheckSqlFieldRef sfCheckArr(sfci), g_sqlStartLine(svi), g_sqlKind(svi), "field list"
                    Next
                End If

                ' Check WHERE fields
                If g_sqlWhFields(svi) <> "" Then
                    Dim swCheckArr : swCheckArr = Split(g_sqlWhFields(svi), "|")
                    Dim swci
                    For swci = 0 To UBound(swCheckArr)
                        CheckSqlFieldRef swCheckArr(swci), g_sqlStartLine(svi), g_sqlKind(svi), "WHERE clause"
                    Next
                End If
            End If
        End If
    Next
    WScript.Echo "INFO: SQL field validation complete."
End If

' =============================================================================
' PHASE 5e -- Method Call Parameter Validation
' =============================================================================
If g_cmCount > 0 Then
    Dim mci
    For mci = 1 To g_srcCount
        Dim mcRaw : mcRaw = g_srcLines(mci)
        If Left(Trim(mcRaw), 1) <> "*" Then
            Dim mcCode : mcCode = UCT(StripInlineComment(mcRaw))
            Dim arrowPos : arrowPos = InStr(mcCode, "->")
            If arrowPos > 0 Then
                ' Extract variable name before ->
                Dim mcVarName : mcVarName = ""
                Dim mcp
                For mcp = arrowPos - 1 To 1 Step -1
                    Dim mch : mch = Mid(mcCode, mcp, 1)
                    If IsWordBoundary(mch) Then Exit For
                    mcVarName = mch & mcVarName
                Next
                mcVarName = UCT(Trim(mcVarName))

                ' Extract method name after ->
                Dim mcMethodName : mcMethodName = ""
                Dim afterArrow : afterArrow = Mid(mcCode, arrowPos + 2)
                Dim mcTokens : mcTokens = SplitTokens(afterArrow)
                If UBound(mcTokens) >= 0 Then
                    mcMethodName = mcTokens(0)
                    Dim mcParenPos : mcParenPos = InStr(mcMethodName, "(")
                    If mcParenPos > 0 Then mcMethodName = Left(mcMethodName, mcParenPos - 1)
                    mcMethodName = StripTrailing(mcMethodName)
                End If

                ' Look up the class of this variable
                Dim mcClassName : mcClassName = ""
                If mcVarName = "ME" Then
                    ' Self-reference inside class implementation
                    mcClassName = g_curClassName
                ElseIf g_varClass.Exists(mcVarName) Then
                    mcClassName = g_varClass(mcVarName)
                End If

                ' If we know the class, validate parameters
                If mcClassName <> "" And mcMethodName <> "" Then
                    CheckMethodCallParams mcCode, mci, mcClassName, mcMethodName, arrowPos
                End If
            End If
        End If
    Next
    WScript.Echo "INFO: Method call parameter check complete (" & g_cmCount & " method signature param(s) tracked)."
End If

' =============================================================================
' PHASE 6 -- Write Result File
' =============================================================================
Dim finalStatus
If g_issueCount = 0 Then
    finalStatus = "STATUS:" & vbTab & "SUCCESS: " & g_dCount & " declaration(s), " & g_sqlCount & " SQL statement(s), " & g_cmCount & " class method param(s), 0 issues."
Else
    finalStatus = "STATUS:" & vbTab & "SUCCESS_WITH_ISSUES: " & g_dCount & " declaration(s), " & g_sqlCount & " SQL statement(s), " & g_cmCount & " class method param(s), " & g_issueCount & " issue(s)."
End If
WriteResults finalStatus

WScript.Echo "INFO: Results written to " & RESULT_FILE
