# =============================================================================
# sap_sql_query_parse.ps1  -  whitelist SQL validator + clause decomposer for /sap-sql-query
#
# CONTAINMENT LAYER 1 (client side). Accepts ONLY a read-only Open-SQL SELECT and decomposes
# it into clause SLOTS the helper FM plugs into fixed dynamic positions, so a clause can never
# escape to chain a second statement. Deny-FIRST: any forbidden token / construct is rejected
# with the exact rule that fired BEFORE any structural parse. The helper FM re-validates
# server-side (defense in depth) -- this script is not the only guard.
#
# Accepted grammar (case-insensitive):
#   SELECT [SINGLE|DISTINCT] <fields> FROM <table> [ [INNER|LEFT OUTER] JOIN <table> ON <cond> ]*
#          [WHERE <cond>] [GROUP BY <fields>] [HAVING <cond>] [ORDER BY <fields> [ASC|DESC]]
#   identifiers [A-Z0-9_/~]+ ; aggregates COUNT SUM MIN MAX AVG ; operators = <> < > <= >=
#   LIKE IN BETWEEN AND OR NOT IS [NOT] NULL ; literals: quoted strings ('' escape) + numbers.
#
# Hard rejects: subquery '(' SELECT, UNION, INTO, UPDATE/INSERT/DELETE/MODIFY, DROP/CREATE/ALTER,
#   EXEC/CALL/PERFORM/SUBMIT, COMMIT/ROLLBACK, FOR ALL ENTRIES, CONNECTION, BYPASSING BUFFER,
#   CLIENT SPECIFIED, MANDT, comments (* -- /* "), semicolon, backquote, host '@', hex X'..',
#   a caller UP TO / OFFSET (the cap is the skill's).
#
# Args: -Sql "<SELECT ...>" [-OutJson <path>]
# Output: SQLQ: verdict=ACCEPT|REJECT [reason=<rule> token=<t>] ; SQLQ: tables=<a,b> fields=<..>
# Exit: 0 ACCEPT | 1 REJECT | 2 INPUT_ERROR.  Offline (no SAP).
# =============================================================================

[CmdletBinding()]
param(
    [string] $Sql = '',
    [string] $SqlFile = '',   # PREFERRED: a CLI -Sql string loses inner double-quotes in PS arg passing;
    [string] $OutJson = ''     # the skill writes the SELECT to a file and passes -SqlFile so " is preserved.
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Reject([string]$rule,[string]$token){ Write-Host ("SQLQ: verdict=REJECT reason={0} token={1}" -f $rule,($token -replace '\s+',' ')); exit 1 }

if ($SqlFile -and (Test-Path -LiteralPath $SqlFile)) { $Sql = [System.IO.File]::ReadAllText($SqlFile) }
$raw = $Sql
if ([string]::IsNullOrWhiteSpace($raw)) { Write-Host "SQLQ: verdict=REJECT reason=EMPTY"; exit 2 }

# ---- lexical pre-checks on the RAW text (before any normalization) --------------------------
if ($raw -match ';')        { Reject 'SEMICOLON' ';' }
if ($raw -match '`')        { Reject 'BACKQUOTE' '`' }
if ($raw -match '@')        { Reject 'HOST_VARIABLE' '@' }
if ($raw -match '--')       { Reject 'COMMENT' '--' }
if ($raw -match '/\*')      { Reject 'COMMENT' '/*' }
if ($raw -match '(?im)^\s*\*') { Reject 'COMMENT' '*' }
if ($raw -match "(?i)\bX'") { Reject 'HEX_LITERAL' "X'" }

# ---- blank out string literals so keyword scans don't false-match inside them ---------------
$sb = New-Object System.Text.StringBuilder; $inStr = $false
foreach ($ch in $raw.ToCharArray()) {
    if ($inStr) { if ($ch -eq "'") { $inStr = $false }; [void]$sb.Append(' '); continue }
    if ($ch -eq "'") { $inStr = $true; [void]$sb.Append(' '); continue }
    if ($ch -eq '"') { Reject 'COMMENT' '"' }          # a bare double-quote = ABAP comment start
    [void]$sb.Append($ch)
}
if ($inStr) { Reject 'UNBALANCED_QUOTE' "'" }
$norm = ($sb.ToString() -replace '\s+',' ').Trim()
$U = $norm.ToUpper()

# ---- forbidden tokens / constructs (word-boundary) -----------------------------------------
$deny = @(
    @{ rx='\bUNION\b'; r='UNION' }, @{ rx='\bINTO\b'; r='INTO' }, @{ rx='\bUPDATE\b'; r='UPDATE' },
    @{ rx='\bINSERT\b'; r='INSERT' }, @{ rx='\bDELETE\b'; r='DELETE' }, @{ rx='\bMODIFY\b'; r='MODIFY' },
    @{ rx='\b(DROP|CREATE|ALTER|TRUNCATE)\b'; r='DDL' }, @{ rx='\b(EXEC|PERFORM|SUBMIT|CALL)\b'; r='EXEC' },
    @{ rx='\b(COMMIT|ROLLBACK)\b'; r='TX' }, @{ rx='\bFOR\s+ALL\s+ENTRIES\b'; r='FOR_ALL_ENTRIES' },
    @{ rx='\bCONNECTION\b'; r='CONNECTION' }, @{ rx='\bBYPASSING\b'; r='BYPASSING_BUFFER' },
    @{ rx='\bCLIENT\s+SPECIFIED\b'; r='CLIENT_SPECIFIED' }, @{ rx='\bMANDT\b'; r='MANDT' },
    @{ rx='\bUP\s+TO\b'; r='CALLER_UP_TO' }, @{ rx='\bOFFSET\b'; r='CALLER_OFFSET' }
)
foreach ($d in $deny) { if ($U -match $d.rx) { Reject $d.r ([regex]::Match($U,$d.rx).Value) } }

# subquery: a '(' immediately followed (any ws) by SELECT
if ($U -match '\(\s*SELECT\b') { Reject 'SUBQUERY' '(SELECT' }

# ---- structural shape ----------------------------------------------------------------------
if ($U -notmatch '^\s*SELECT\b') { Reject 'NOT_SELECT' ($U.Substring(0,[Math]::Min(12,$U.Length))) }
if ($U -notmatch '\bFROM\b')     { Reject 'NO_FROM' '' }

# every identifier-ish token must be a keyword, an identifier [A-Z0-9_/~], a number, or an operator.
$allowedKw = 'SELECT|SINGLE|DISTINCT|FROM|INNER|LEFT|OUTER|JOIN|ON|WHERE|GROUP|BY|HAVING|ORDER|ASC|DESC|AND|OR|NOT|IN|IS|NULL|LIKE|BETWEEN|AS|COUNT|SUM|MIN|MAX|AVG|ESCAPE'
foreach ($tok in ($U -split '[\s,()]+' | Where-Object { $_ })) {
    if ($tok -match "^($allowedKw)$") { continue }
    if ($tok -match '^[A-Z0-9_/~\.\*]+$') { continue }          # identifier / tab~field / tab.field / *
    if ($tok -match '^-?\d+(\.\d+)?$') { continue }             # number
    if ($tok -match '^(=|<>|<|>|<=|>=)$') { continue }          # operator
    Reject 'BAD_TOKEN' $tok
}

# ---- clause extraction (top-level keywords; strings already blanked) ------------------------
function Slice([string]$s,[string]$startRx,[string[]]$stops){
    $m = [regex]::Match($s, $startRx); if (-not $m.Success) { return '' }
    $from = $m.Index + $m.Length; $end = $s.Length
    foreach ($st in $stops) { $sm = [regex]::Match($s.Substring($from), $st); if ($sm.Success) { $end = [Math]::Min($end, $from + $sm.Index) } }
    return $s.Substring($from, $end - $from).Trim()
}
$afterSelect = $U -replace '^\s*SELECT\s+(SINGLE\s+|DISTINCT\s+)?',''
$fields  = (Slice $afterSelect '^' @('\bFROM\b')).Trim()
$fromAll = Slice $U '\bFROM\b' @('\bWHERE\b','\bGROUP\s+BY\b','\bHAVING\b','\bORDER\s+BY\b')
$whereC  = Slice $U '\bWHERE\b' @('\bGROUP\s+BY\b','\bHAVING\b','\bORDER\s+BY\b')
$groupC  = Slice $U '\bGROUP\s+BY\b' @('\bHAVING\b','\bORDER\s+BY\b')
$havingC = Slice $U '\bHAVING\b' @('\bORDER\s+BY\b')
$orderC  = Slice $U '\bORDER\s+BY\b' @()

# tables = FROM table + each JOIN table (token after FROM/JOIN, strip alias)
$tables = New-Object System.Collections.Generic.List[string]
foreach ($m in [regex]::Matches($U, '\b(?:FROM|JOIN)\s+([A-Z0-9_/]+)')) { $t=$m.Groups[1].Value; if (-not $tables.Contains($t)) { [void]$tables.Add($t) } }
if (-not $tables.Count) { Reject 'NO_TABLE' '' }

if ($OutJson) {
    try {
        $esc = { param($x) ($x -replace '\\','\\' -replace '"','\"') }
        $tblJson = ($tables | ForEach-Object { '"' + (& $esc $_) + '"' }) -join ','
        $j = '{' + ('"fields":"{0}","from":"{1}","where":"{2}","groupby":"{3}","having":"{4}","orderby":"{5}","tables":[{6}]' -f (& $esc $fields),(& $esc $fromAll),(& $esc $whereC),(& $esc $groupC),(& $esc $havingC),(& $esc $orderC),$tblJson) + '}'
        [System.IO.File]::WriteAllText($OutJson, $j, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

Write-Host ("SQLQ: verdict=ACCEPT tables={0}" -f ($tables -join ','))
Write-Host ("SQLQ: fields={0} where={1} groupby={2} having={3} orderby={4}" -f $fields,$whereC,$groupC,$havingC,$orderC)
exit 0
