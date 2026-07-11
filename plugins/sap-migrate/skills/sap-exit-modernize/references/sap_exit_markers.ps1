# =============================================================================
# sap_exit_markers.ps1  -  Offline MANUAL-marker classifier for /sap-exit-modernize
#
# NO RFC, NO SAP. Scans exit source (the ZX* include body) for constructs that
# have NO clean BAdI counterpart and MUST become MANUAL blocks in the translated
# implementation class. The marker list is load-bearing: it seeds the translate
# step's TODO(MANUAL-n) blocks and gates deploy (marker_count>0 -> typed confirm).
#
# Flags (each -> one marker row):
#   FG_GLOBAL     TABLES work area / COMMON PART / a bare global not in the signature
#   SY_WRITE      assignment to SY-* (side effect on the system field, not portable)
#   DB_WRITE      UPDATE/MODIFY/INSERT/DELETE/COMMIT on a non-Z table (BAdI must not)
#   MSG_RAISING   MESSAGE ... RAISING (control flow via exception into the caller)
#   CALL_STD      PERFORM ... IN PROGRAM / PERFORM (dynamic) into the standard program
#   COMMIT        COMMIT WORK / ROLLBACK WORK (transactional control in an exit)
#
# Comments (* / ") and 'string' literals are stripped before matching so a keyword
# inside a comment/string never false-fires. Output TSV: id,kind,exit_line,reason,proposed_action.
# Exit: 0 ran (prints MARKERS: count=<n>), 2 input error.
# =============================================================================

[CmdletBinding()]
param(
    [string] $SourceFile = '',
    [string] $OutFile = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# Z/Y namespace (a write to a Z table is allowed; SAP-standard is not)
$Z = '(?:[YZ]|/\w+/)'

function Strip-Line {
    param([string]$line)
    $l = $line
    if ($l -match '^\s*\*') { return '' }                  # full-line comment
    $q = $l.IndexOf('"'); if ($q -ge 0) { $l = $l.Substring(0,$q) }   # trailing comment
    $l = [regex]::Replace($l, "'[^']*'", "''")             # string literals
    return $l
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $SourceFile -or -not (Test-Path $SourceFile)) { Write-Host "STATUS: INPUT_ERROR reason=source_missing"; exit 2 }
    $lines = [System.IO.File]::ReadAllLines($SourceFile)
    $markers = New-Object System.Collections.Generic.List[string]
    $markers.Add("id`tkind`texit_line`treason`tproposed_action")
    $n = 0
    for ($i=0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]; $s = (Strip-Line $raw).Trim(); if ($s -eq '') { continue }
        $u = $s.ToUpper()
        $kind=''; $reason=''; $action=''
        if ($u -match '^\s*TABLES\b') { $kind='FG_GLOBAL'; $reason='TABLES work area (function-group global) - no BAdI counterpart'; $action='pass the needed data explicitly via the BAdI method signature or a helper read' }
        elseif ($u -match '\bCOMMON\s+PART\b') { $kind='FG_GLOBAL'; $reason='COMMON PART shared data - not visible from a BAdI class'; $action='refactor the shared data into an explicit parameter or DB read' }
        elseif ($u -match '\bSY-\w+\s*=' -and $u -notmatch '\bSY-SUBRC\b\s*=\s*0') { $kind='SY_WRITE'; $reason='writes a SY-* system field - side effect the BAdI runtime will not honour'; $action='return the value through the method CHANGING/EXPORTING parameter instead' }
        elseif ($u -match "\b(UPDATE|MODIFY|INSERT|DELETE)\s+(?!$Z)[A-Z/]" -and $u -notmatch '\bINTO\b.*\bTABLE\b' -and $u -notmatch '\b(ITAB|LT_|GT_|LS_)') { $kind='DB_WRITE'; $reason='direct DB write on a (non-Z) standard table inside an exit'; $action='MANUAL: move the write behind a proper API/BAdI or keep as a reviewed exception' }
        elseif ($u -match '\bMESSAGE\b.*\bRAISING\b') { $kind='MSG_RAISING'; $reason='MESSAGE ... RAISING - control flow back into the standard caller'; $action='raise the BAdI method exception / return a result the caller checks' }
        elseif ($u -match '\bPERFORM\b.*\b(IN\s+PROGRAM|\()') { $kind='CALL_STD'; $reason='PERFORM into the standard/dynamic program - not reachable from a BAdI class'; $action='re-express the called logic, or keep the exit for this branch (hybrid)' }
        elseif ($u -match '\b(COMMIT|ROLLBACK)\s+WORK\b') { $kind='COMMIT'; $reason='transactional control (COMMIT/ROLLBACK) inside an exit'; $action='remove - the caller owns the LUW; never COMMIT inside a BAdI' }
        if ($kind) {
            $n++
            $markers.Add(("MANUAL-{0}`t{1}`t{2}`t{3}`t{4}" -f $n, $kind, ($i+1), $reason, $action))
        }
    }
    if (-not $OutFile) { $OutFile = 'manual_markers.tsv' }
    [System.IO.File]::WriteAllText($OutFile, ($markers -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "MARKERS_TSV: $OutFile"
    Write-Host ("MARKERS: count=$n")
    Write-Host "STATUS: OK"
    exit 0
}
