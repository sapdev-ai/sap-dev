# =============================================================================
# sap_scratch_guard.ps1  -  read-only static guard for /sap-scratch-run 'run'
#
# The load-bearing safety gate: statically scans a generated $TMP ABAP report and REFUSES
# (never warns) on any construct that could write, commit, branch to a transaction, run
# external code, or touch the file system / locks. A hit => the report is NEVER deployed.
#
# Design: locale-independent, tokenized. First the source is CLEANED (full-line '*' comments,
# inline '"' comments, and '...' string literals stripped) so a keyword INSIDE a comment or
# string can never false-deny (the plan's #1 correctness test). Then it is split into ABAP
# statements on '.' and each statement's shape is matched against a DENY set. Writes to Z*/Y*
# tables ARE allowed (skill_operating_rules: customer namespace is writable); writes to any
# other DB table, and every dynamic '(lv)' write target, are denied. Internal-table ops
# (DELETE itab / DELETE TABLE / INSERT ... INTO TABLE / MODIFY TABLE) are allowed.
#
# Args: -SourceFile <path> [-OutTsv <path>]
# Output: GUARD: DENY line=<n> rule=<id> stmt=<text>   (one per hit)
#         STATUS: CLEAN | VIOLATION hits=<n> | INPUT_ERROR
# Exit: 0 = CLEAN | 1 = VIOLATION | 2 = INPUT_ERROR.  Offline (no SAP).
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceFile,
    [string] $OutTsv = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if (-not (Test-Path -LiteralPath $SourceFile)) { Write-Host "GUARD: input_error source not found: $SourceFile"; Write-Host "STATUS: INPUT_ERROR"; exit 2 }

$rawLines = @(Get-Content -LiteralPath $SourceFile)

# ---- clean: strip full-line comments, inline comments, and string literals -----------------
# We keep a per-statement approximate source line for reporting (first line of the statement).
$clean = New-Object System.Text.StringBuilder
foreach ($ln in $rawLines) {
    $l = $ln
    if ($l -match '^\s*\*') { [void]$clean.AppendLine(''); continue }   # full-line comment
    # remove inline " comment (not inside a string) + blank out '...' string literals
    $sb = New-Object System.Text.StringBuilder; $inStr = $false
    for ($i=0; $i -lt $l.Length; $i++) {
        $c = $l[$i]
        if ($inStr) { if ($c -eq "'") { $inStr = $false }; [void]$sb.Append(' '); continue }
        if ($c -eq "'") { $inStr = $true; [void]$sb.Append(' '); continue }
        if ($c -eq '"') { break }                                       # inline comment -> rest of line gone
        [void]$sb.Append($c)
    }
    [void]$clean.AppendLine($sb.ToString())
}
$cleanText = $clean.ToString()

# ---- split into statements on '.' (strings already blanked) --------------------------------
# track the source line number of each statement's start for reporting.
$stmts = @()
$curLine = 1; $stmtStartLine = 1; $acc = New-Object System.Text.StringBuilder
foreach ($ch in $cleanText.ToCharArray()) {
    if ($ch -eq "`n") { $curLine++; [void]$acc.Append(' '); continue }
    if ($ch -eq '.') {
        $t = ($acc.ToString() -replace '\s+',' ').Trim()
        if ($t) { $stmts += [pscustomobject]@{ line=$stmtStartLine; text=$t } }
        $acc = New-Object System.Text.StringBuilder; $stmtStartLine = $curLine; continue
    }
    [void]$acc.Append($ch)
}
$tail = ($acc.ToString() -replace '\s+',' ').Trim(); if ($tail) { $stmts += [pscustomobject]@{ line=$stmtStartLine; text=$tail } }

# ---- deny rules ----------------------------------------------------------------------------
$Z = '(?:[YZ]|/\w+/)'    # customer-namespace prefix (Z, Y, or /namespace/)
$denyRules = @(
    @{ id='UPDATE_DB';        rx="^UPDATE\s+(?!$Z)\(?\w";                                  desc='UPDATE on a non-Z/Y DB table' },
    @{ id='UPDATE_DYNAMIC';   rx="^UPDATE\s+\(";                                            desc='UPDATE with a dynamic (lv) target' },
    @{ id='DELETE_DB';        rx="^DELETE\s+FROM\s+(?!$Z)\w";                               desc='DELETE FROM a non-Z/Y DB table' },
    @{ id='DELETE_DYNAMIC';   rx="^DELETE\s+FROM\s+\(";                                     desc='DELETE FROM a dynamic (lv) target' },
    @{ id='INSERT_DB';        rx="^INSERT\s+(?:INTO\s+)?(?!$Z)\w+\s+(?:FROM|VALUES|CONNECTION)"; desc='INSERT into a non-Z/Y DB table' },
    @{ id='INSERT_DYNAMIC';   rx="^INSERT\s+\(";                                            desc='INSERT with a dynamic (lv) target' },
    @{ id='MODIFY_DB';        rx="^MODIFY\s+(?!$Z)(?!TABLE\b)(?!SCREEN\b)\w+\s+FROM";       desc='MODIFY a non-Z/Y DB table' },
    @{ id='MODIFY_DYNAMIC';   rx="^MODIFY\s+\(";                                            desc='MODIFY with a dynamic (lv) target' },
    @{ id='COMMIT';           rx="^COMMIT\s+WORK";                                          desc='COMMIT WORK' },
    @{ id='ROLLBACK';         rx="^ROLLBACK\s+WORK";                                        desc='ROLLBACK WORK' },
    @{ id='UPDATE_TASK';      rx="\bIN\s+UPDATE\s+TASK\b";                                  desc='... IN UPDATE TASK (async DB write)' },
    @{ id='CALL_TRANSACTION'; rx="^CALL\s+TRANSACTION\b";                                   desc='CALL TRANSACTION' },
    @{ id='LEAVE_TCODE';      rx="^LEAVE\s+TO\s+TRANSACTION\b";                             desc='LEAVE TO TRANSACTION' },
    @{ id='CALL_SCREEN';      rx="^(?:CALL|SET)\s+SCREEN\b";                                desc='CALL/SET SCREEN (dialog)' },
    @{ id='SUBMIT';           rx="^SUBMIT\b";                                               desc='SUBMIT (runs another report)' },
    @{ id='EXEC_SQL';         rx="^EXEC\s+SQL\b";                                           desc='native EXEC SQL' },
    @{ id='DATASET_OUT';      rx="^OPEN\s+DATASET\b.*\bFOR\s+(?:OUTPUT|APPENDING)\b";       desc='OPEN DATASET FOR OUTPUT/APPENDING' },
    @{ id='DATASET_TRANSFER'; rx="^TRANSFER\b";                                             desc='TRANSFER (app-server file write)' },
    @{ id='DATASET_DELETE';   rx="^DELETE\s+DATASET\b";                                     desc='DELETE DATASET' },
    @{ id='GEN_POOL';         rx="^GENERATE\s+(?:SUBROUTINE\s+POOL|REPORT)\b";              desc='GENERATE SUBROUTINE POOL/REPORT' },
    @{ id='INSERT_REPORT';    rx="^INSERT\s+REPORT\b";                                      desc='INSERT REPORT (deploy code)' },
    @{ id='EDITOR_CALL';      rx="^EDITOR-CALL\b";                                          desc='EDITOR-CALL' },
    @{ id='ENQUEUE';          rx="'(?:EN|DE)QUEUE_\w+'";                                    desc='ENQUEUE_/DEQUEUE_ lock FM' }
)

$hits = @()
foreach ($s in $stmts) {
    $u = $s.text.ToUpper()
    foreach ($r in $denyRules) {
        if ($u -match $r.rx) { $hits += [pscustomobject]@{ line=$s.line; rule=$r.id; desc=$r.desc; stmt=$s.text }; break }
    }
}

foreach ($h in $hits) { Write-Host ("GUARD: DENY line={0} rule={1} stmt={2}" -f $h.line,$h.rule,($h.stmt.Substring(0,[Math]::Min(90,$h.stmt.Length)))) }
if ($OutTsv) { try { $sb=New-Object System.Text.StringBuilder; [void]$sb.AppendLine("line`trule`tdescription`tstatement")
    foreach ($h in $hits) { [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}" -f $h.line,$h.rule,$h.desc,($h.stmt -replace "`t",' '))) }
    [System.IO.File]::WriteAllText($OutTsv,$sb.ToString(),(New-Object System.Text.UTF8Encoding($true))) } catch {} }

if ($hits.Count) { Write-Host ("STATUS: VIOLATION hits={0}" -f $hits.Count); exit 1 }
Write-Host "STATUS: CLEAN"; exit 0
