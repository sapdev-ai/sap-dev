# =============================================================================
# sap_auth_extract.ps1  -  offline ABAP authorization-surface extractor (/sap-auth-requirements)
#
# Reads ABAP source file(s) and extracts the EXPLICIT AUTHORITY-CHECK surface plus the
# IMPLICIT surface (CALL TRANSACTION, SUBMIT, OPEN/DELETE DATASET/TRANSFER, CALL FUNCTION
# DESTINATION, DDIC table writes) into a required-auth row list. Pure offline (no RFC) so it
# is unit-testable; the RFC validation pass (sap_auth_requirements_rfc.ps1) enriches/validates.
#
# Each value is classified CONFIRMED (quoted literal) or INFERRED (variable / dynamic / computed)
# with a single-pass in-source backward trace of the variable to its nearest literal assignment.
# Static analysis cannot resolve dynamic values -> those rows are INFERRED, never CONFIRMED.
#
#   -SourceFiles "a.txt,b.txt"  [-ObjectName ZFOO]  -OutJson <path>
#
# stdout: AUTHROW: seq=<n> source=<EXPLICIT|IMPLICIT> stmt=<kind> object=<o> field=<f>
#         value=<v> status=<CONFIRMED|INFERRED> note=<..>   +   STATUS: OK rows=<n>. Exit 0/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $SourceFiles = '',
    [string] $ObjectName  = '',
    [string] $OutJson     = '',
    [string] $RunId       = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function JEsc { param([string]$s) return (("$s") -replace '\\','\\' -replace '"','\"' -replace "`t",' ' -replace "`r",' ' -replace "`n",' ') }

# --- read + normalize source into a statement list ---------------------------
# Strip full-line (*) + inline (") comments respecting string literals, then split into
# statements on '.' (period) that is not inside a quote. Keep an approximate source line.
function Get-Statements { param([string[]]$files)
    $stmts = @()   # {text; line}
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        $lines = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) -split "`r`n|`n"
        $buf = ''; $startLine = 0; $ln = 0
        foreach ($raw in $lines) {
            $ln++
            $line = $raw
            if ($line -match '^\s*\*') { continue }                      # full-line comment
            # strip inline comment (a " not inside a string literal)
            $clean = ''; $inStr = $false
            for ($i=0; $i -lt $line.Length; $i++) {
                $ch = $line[$i]
                if ($ch -eq "'") { $inStr = -not $inStr; $clean += $ch; continue }
                if ($ch -eq '"' -and -not $inStr) { break }              # rest is comment
                $clean += $ch
            }
            if ($clean.Trim() -eq '') { continue }
            if ($buf -eq '') { $startLine = $ln }
            $buf += ' ' + $clean
            # split on periods not inside a string
            while ($true) {
                $inS = $false; $pos = -1
                for ($i=0; $i -lt $buf.Length; $i++) { $c=$buf[$i]; if ($c -eq "'") { $inS = -not $inS } elseif ($c -eq '.' -and -not $inS) { $pos=$i; break } }
                if ($pos -lt 0) { break }
                $stmt = $buf.Substring(0,$pos).Trim()
                if ($stmt) { $stmts += ,([pscustomobject]@{ text=$stmt; line=$startLine }) }
                $buf = $buf.Substring($pos+1); $startLine = $ln
            }
        }
    }
    return $stmts
}

# backward trace a variable to a literal in prior statements (single pass, same scope-ish)
function Trace-Value { param([object[]]$stmts,[int]$upto,[string]$var)
    $v = $var.Trim()
    if ($v -match "^'(.*)'$") { return @{ value=$matches[1]; status='CONFIRMED'; note='literal' } }
    for ($i=$upto-1; $i -ge 0 -and $i -ge ($upto-60); $i--) {
        $t = $stmts[$i].text
        # <var> = 'LIT'.   /   MOVE 'LIT' TO <var>.   /   CONSTANTS <var> ... VALUE 'LIT'.
        if ($t -match "(?i)^\s*$([regex]::Escape($v))\s*=\s*'([^']*)'\s*$") { return @{ value=$matches[1]; status='CONFIRMED'; note="traced: $v = literal (line $($stmts[$i].line))" } }
        if ($t -match "(?i)^\s*MOVE\s+'([^']*)'\s+TO\s+$([regex]::Escape($v))\s*$") { return @{ value=$matches[1]; status='CONFIRMED'; note="traced: MOVE literal TO $v" } }
        if ($t -match "(?i)\b(CONSTANTS|DATA)\s+$([regex]::Escape($v))\b.*\bVALUE\s+'([^']*)'") { return @{ value=$matches[2]; status='CONFIRMED'; note="traced: $v VALUE literal" } }
    }
    return @{ value="<$v>"; status='INFERRED'; note="value from variable $v (not traced to a literal)" }
}

$rows = @()
function Add-Row { param($src,$stmt,$obj,$fld,$val,$status,$note)
    $script:rows += ,([pscustomobject]@{ seq=($script:rows.Count+1); source=$src; stmt=$stmt; object=$obj; field=$fld; value=$val; status=$status; note=$note })
}

if ($MyInvocation.InvocationName -eq '.') { return }
$files = @($SourceFiles -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($files.Count -eq 0) { Write-Host 'STATUS: AUTHREQ_INPUT no_source'; exit 2 }
$stmts = @(Get-Statements $files)

for ($si=0; $si -lt $stmts.Count; $si++) {
    $t = $stmts[$si].text

    # --- EXPLICIT: AUTHORITY-CHECK OBJECT '<o>' [FOR USER u] ID '<f>' FIELD <v> [ID..FIELD..] ---
    if ($t -match "(?i)^\s*AUTHORITY-CHECK\s+OBJECT\s+('?)([\w/]+)\1") {
        $objTok = $matches[2]
        $obj = if ($objTok -match "^[A-Z]") { $objTok } else { "<$objTok>" }
        $objStatus = if ($t -match "(?i)AUTHORITY-CHECK\s+OBJECT\s+'") { 'CONFIRMED' } else { 'INFERRED' }
        # iterate ID '<fld>' FIELD <val|DUMMY>
        $rx = [regex]::Matches($t, "(?i)ID\s+('?)([\w/]+)\1\s+(FIELD\s+('?)([^'\s.]+)\4|DUMMY)")
        if ($rx.Count -eq 0) { Add-Row 'EXPLICIT' 'AUTHORITY-CHECK' $obj '' '' $objStatus "object $(if($objStatus -eq 'INFERRED'){'from variable '})$objTok; no ID clause parsed" }
        foreach ($m in $rx) {
            $fld = $m.Groups[2].Value
            if ($m.Groups[3].Value -match '(?i)DUMMY') { Add-Row 'EXPLICIT' 'AUTHORITY-CHECK' $obj $fld 'DUMMY' 'CONFIRMED' 'field not checked (DUMMY)' }
            elseif ($m.Groups[4].Value -eq "'") { Add-Row 'EXPLICIT' 'AUTHORITY-CHECK' $obj $fld $m.Groups[5].Value 'CONFIRMED' 'literal' }
            else {
                $tr = Trace-Value $stmts $si $m.Groups[5].Value
                Add-Row 'EXPLICIT' 'AUTHORITY-CHECK' $obj $fld $tr.value $tr.status $tr.note
            }
        }
        continue
    }
    # --- IMPLICIT: CALL TRANSACTION '<T>' -> S_TCODE ---
    if ($t -match "(?i)^\s*CALL\s+TRANSACTION\s+('?)([\w/]+)\1") {
        $tok=$matches[2]; $tr = Trace-Value $stmts $si $(if($t -match "(?i)CALL\s+TRANSACTION\s+'"){"'$tok'"}else{$tok})
        $wac = if ($t -match "(?i)WITH(OUT)?\s+AUTHORITY-CHECK") { '; 7.40 WITH(OUT) AUTHORITY-CHECK present' } else { '' }
        Add-Row 'IMPLICIT' 'CALL TRANSACTION' 'S_TCODE' 'TCD' $tr.value $tr.status "target transaction$wac; also needs the target's TSTCA start-auth values" ; continue
    }
    # --- IMPLICIT: SUBMIT <prog> -> S_PROGRAM ---
    if ($t -match "(?i)^\s*SUBMIT\s+('?)([\w/]+)\1") {
        $tok=$matches[2]; $isLit = ($matches[1] -eq "'")
        $st = if ($isLit) { 'CONFIRMED' } else { 'INFERRED' }
        $val = if ($isLit) { $tok } else { "<$tok>" }
        Add-Row 'IMPLICIT' 'SUBMIT' 'S_PROGRAM' 'P_ACTION' 'SUBMIT' 'CONFIRMED' "submits report $val; P_GROUP from target TRDIR-SECU (blank=UNPROTECTED_TARGET)"
        Add-Row 'IMPLICIT' 'SUBMIT' 'S_PROGRAM' 'P_GROUP' $val $st 'report authorization group (resolve via TRDIR-SECU)' ; continue
    }
    # --- IMPLICIT: OPEN/DELETE DATASET / TRANSFER -> S_DATASET ---
    if ($t -match "(?i)^\s*(OPEN\s+DATASET|DELETE\s+DATASET|TRANSFER)\b") {
        Add-Row 'IMPLICIT' 'DATASET' 'S_DATASET' 'PROGRAM' ($ObjectName) 'CONFIRMED' 'file access; ACTVT + FILENAME depend on the operation/target' ; continue
    }
    # --- IMPLICIT: CALL FUNCTION '<fm>' DESTINATION '<d>' -> S_RFC ---
    if ($t -match "(?i)^\s*CALL\s+FUNCTION\s+('?)([\w/]+)\1.*DESTINATION") {
        $fm=$matches[2]; $isLit=($matches[1] -eq "'")
        Add-Row 'IMPLICIT' 'CALL FUNCTION DESTINATION' 'S_RFC' 'RFC_NAME' $(if($isLit){$fm}else{"<$fm>"}) $(if($isLit){'CONFIRMED'}else{'INFERRED'}) 'remote call; RFC_NAME can be the FM or its function group (auth/rfc_authority_check decides)' ; continue
    }
    # --- IMPLICIT: DYNAMIC DDIC write (MODIFY (var) FROM ...) -> S_TABU, INFERRED ---
    if ($t -match "(?i)^\s*(UPDATE|MODIFY|INSERT|DELETE)\s+\((\w+)\)") {
        $op=$matches[1].ToUpper(); $var=$matches[2]
        Add-Row 'IMPLICIT' "$op (dynamic DDIC write)" 'S_TABU_DIS' 'DICBERCLS' "<dynamic table in $var>" 'INFERRED' "dynamic table name (variable $var); DICBERCLS cannot be resolved statically -- review at runtime (also consider S_TABU_NAM)"
        Add-Row 'IMPLICIT' "$op (dynamic DDIC write)" 'S_TABU_DIS' 'ACTVT' '02' 'CONFIRMED' "activity 02 (change) for dynamic $op" ; continue
    }
    # --- IMPLICIT: DDIC table writes -> S_TABU_DIS / S_TABU_NAM ---
    if ($t -match "(?i)^\s*(UPDATE|MODIFY|INSERT|DELETE)\s+(?:FROM\s+)?([a-zA-Z][\w/]*)\b" -and $t -notmatch "(?i)\b(INTO\s+TABLE|FROM\s+TABLE)\b" -and $t -notmatch "(?i)^\s*DELETE\s+(ADJACENT|TABLE)\b") {
        $op=$matches[1].ToUpper(); $tab=$matches[2].ToUpper()
        # skip internal-table ops (itab name prefixes) -- S_TABU is only for DDIC tables
        if ($tab -match '^(LT_|LS_|GT_|GS_|IT_|ITAB|WA_|LW_|LO_|MT_|MS_|<)') { continue }
        Add-Row 'IMPLICIT' "$op (DDIC write)" 'S_TABU_DIS' 'DICBERCLS' "<from TDDAT-CCLASS of $tab>" 'INFERRED' "table $tab written; DICBERCLS from TDDAT (no TDDAT row -> S_TABU_NAM TABLE=$tab)"
        Add-Row 'IMPLICIT' "$op (DDIC write)" 'S_TABU_DIS' 'ACTVT' '02' 'CONFIRMED' "activity 02 (change) for $op on $tab" ; continue
    }
}

foreach ($r in $rows) { Write-Host ("AUTHROW: seq={0} source={1} stmt={2} object={3} field={4} value={5} status={6} note=`"{7}`"" -f $r.seq,$r.source,$r.stmt,$r.object,$r.field,$r.value,$r.status,(San $r.note)) }

if ($OutJson) {
    $items = $rows | ForEach-Object { "{`"seq`":$($_.seq),`"source`":`"$(JEsc $_.source)`",`"stmt`":`"$(JEsc $_.stmt)`",`"object`":`"$(JEsc $_.object)`",`"field`":`"$(JEsc $_.field)`",`"value`":`"$(JEsc $_.value)`",`"status`":`"$(JEsc $_.status)`",`"note`":`"$(JEsc $_.note)`"}" }
    $json = "{`"object`":`"$(JEsc $ObjectName)`",`"rows`":[" + ($items -join ',') + "]}"
    [IO.File]::WriteAllText($OutJson, $json, (New-Object Text.UTF8Encoding($false)))
}
Write-Host ("STATUS: OK rows={0} confirmed={1} inferred={2}" -f $rows.Count,@($rows|Where-Object{$_.status -eq 'CONFIRMED'}).Count,@($rows|Where-Object{$_.status -eq 'INFERRED'}).Count)
exit 0
