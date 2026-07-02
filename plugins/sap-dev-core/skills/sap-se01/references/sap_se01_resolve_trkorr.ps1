# sap_se01_resolve_trkorr.ps1
# Authoritative RFC resolution of a just-created transport request's TRKORR.
#
# WHY: sap_se01_create.vbs creates the request via SE01 GUI, but on some
# releases/locales (confirmed S/4HANA 1909 ZH, 2026-07-02 finding F-1) the
# "Request <TR> created" message never lands in wnd[0]/sbar, and the SE16N-GUI
# fallback is fragile (field-table + result-grid layout varies). RFC_READ_TABLE
# on E07T/E070 is locale-independent and reliable. The VBS emits
# `INFO: AS4TEXT=<desc>` + `INFO: AS4USER=<user>`; the SKILL.md wrapper feeds
# them here to get the authoritative TRKORR.
#
# Resolution (no date filter -> immune to workstation/server TZ skew):
#   Step A: E07T (request short texts) WHERE AS4TEXT = <description>
#           -> candidate TRKORR set (the description lives in E07T, not E070).
#   Step B: E070 WHERE AS4USER = <user> AND TRSTATUS = 'D' (modifiable) AND
#           TRFUNCTION in (K,W) (top-level requests, not tasks) -> keep rows
#           whose TRKORR is in the candidate set; the HIGHEST TRKORR is newest
#           (numbering is monotonic, strings are same length).
#
# Usage (creds fall back to the pinned profile via Connect-SapRfc):
#   powershell -File sap_se01_resolve_trkorr.ps1 -Description "<AS4TEXT>" -User "<AS4USER>"
# Stdout last line: `RESULT_TR: <trkorr>` (+ `TRFUNCTION: <K|W>`) on success,
#   else `TR_RESOLUTION_FAILED: <reason>`. Exit 0 resolved / 1 not-found / 2 RFC error.
# MUST run under 32-bit PowerShell (SAP NCo 3.1 lives in GAC_32).

param(
    [Parameter(Mandatory=$true)][string]$Description,
    [string]$User = '',
    [string]$RfcLib = ''
)

$ErrorActionPreference = 'Stop'

# Resolve the shared RFC lib: explicit -RfcLib, else sibling shared\scripts.
if (-not $RfcLib -or -not (Test-Path $RfcLib)) {
    $guess = Join-Path $PSScriptRoot '..\..\..\shared\scripts\sap_rfc_lib.ps1'
    if (Test-Path $guess) { $RfcLib = (Resolve-Path $guess).Path }
}
if (-not $RfcLib -or -not (Test-Path $RfcLib)) {
    Write-Output "TR_RESOLUTION_FAILED: sap_rfc_lib.ps1 not found"; exit 2
}
. $RfcLib

function Split-WhereClause($whereText) {
    # RFC_READ_TABLE OPTIONS rows are capped at 72 chars each and are
    # concatenated server-side. Break the WHERE into <=72-char rows at word
    # boundaries so a long clause (AS4USER + TRSTATUS + TRFUNCTION) does not
    # raise "An error has occurred while parsing a dynamic entry."
    $rows = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($tok in ($whereText -split ' ')) {
        if ($tok -eq '') { continue }
        if ($cur -eq '') { $cur = $tok }
        elseif (($cur.Length + 1 + $tok.Length) -le 72) { $cur = "$cur $tok" }
        else { $rows.Add($cur); $cur = $tok }
    }
    if ($cur -ne '') { $rows.Add($cur) }
    return $rows
}

function Read-TrkorrColumn($dest, $table, $whereText) {
    # Single-field RFC_READ_TABLE on TRKORR -> array of trimmed values.
    $fn = $dest.Repository.CreateFunction('RFC_READ_TABLE')
    $fn.SetValue('QUERY_TABLE', $table)
    $fn.SetValue('DELIMITER', '|')
    $opt = $fn.GetTable('OPTIONS')
    foreach ($line in (Split-WhereClause $whereText)) { $opt.Append(); $opt.SetValue('TEXT', $line) }
    $fld = $fn.GetTable('FIELDS'); $fld.Append(); $fld.SetValue('FIELDNAME', 'TRKORR')
    $fn.Invoke($dest)
    $data = $fn.GetTable('DATA')
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $data.RowCount; $i++) {
        $data.CurrentIndex = $i
        $v = ([string]$data.GetString('WA')).Trim()
        if ($v) { $out.Add($v.ToUpper()) }
    }
    return $out
}

# SQL-escape single quotes in the description for the OPTIONS WHERE clause.
$descEsc = $Description -replace "'", "''"

$dest = $null
try { $dest = Connect-SapRfc } catch { $dest = $null }
if (-not $dest) { Write-Output "TR_RESOLUTION_FAILED: RFC connect failed"; exit 2 }

try {
    $cand = @{}
    foreach ($t in (Read-TrkorrColumn $dest 'E07T' "AS4TEXT = '$descEsc'")) { $cand[$t] = $true }
    Write-Output ("INFO: E07T candidates with matching AS4TEXT: " + $cand.Count)
    if ($cand.Count -eq 0) {
        Write-Output "TR_RESOLUTION_FAILED: no E07T row with that AS4TEXT (request may not have been created)"; exit 1
    }

    $userClause = ''
    if ($User) { $userClause = "AS4USER = '$($User -replace "'","''")' AND " }
    $where = "$userClause" + "TRSTATUS = 'D' AND ( TRFUNCTION = 'K' OR TRFUNCTION = 'W' )"

    $best = ''
    foreach ($tr in (Read-TrkorrColumn $dest 'E070' $where)) {
        if ($cand.ContainsKey($tr) -and $tr -gt $best) { $best = $tr }
    }

    if (-not $best) {
        Write-Output "TR_RESOLUTION_FAILED: candidate(s) not modifiable/owned by user (verify in SE01)"; exit 1
    }
    Write-Output ("INFO: TRKORR=" + $best)
    Write-Output ("RESULT_TR: " + $best)
    exit 0
}
catch {
    Write-Output ("TR_RESOLUTION_FAILED: " + $_.Exception.Message); exit 2
}
finally {
    try { if ($dest) { Disconnect-SapRfc $dest } } catch {}
}
