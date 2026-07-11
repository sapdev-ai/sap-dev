# =============================================================================
# sap_gen_rap_verify.ps1  -  Authoritative RFC verification of a RAP file set
# -----------------------------------------------------------------------------
# READ-ONLY. 32-bit PowerShell + NCo 3.1. Re-reads each RAP artifact over RFC and
# reports its real state -- never trusts a deploy tool's echo. Uses only the
# reads proven safe on 1909 (TADIR presence + DWINACTIV for activation); DDDDLSRC
# / SRVDSRC SOURCE columns are RFC-forbidden (string columns), and no BDEF/SRVB
# source table exists under any probed name, so:
#   - BDEF activation is ALWAYS COULD_NOT_CHECK (presence via TADIR R3TR BDEF only)
#   - SRVB published-state is COULD_NOT_CHECK (presence via TADIR R3TR SRVB only)
# never rendered as passed. This honesty is by design (see SKILL.md).
#
# Params (each a comma-list; the SKILL derives them from -Stem):
#   -Ddls "ZI_x,ZC_x"  -Bdef "ZI_x,ZC_x"  -Clas "ZBP_x"  -Srvd "ZUI_x"  -Srvb "ZUI_x_O2"
#   [-WorkDir <dir>]
# Output:
#   RAPOBJ: <type> <name> <ACTIVE|PRESENT|INACTIVE|MISSING|COULD_NOT_CHECK> [note]
#   STATUS: <COMPLETE|PARTIAL|ERROR> present=<p> active=<a> missing=<m> cnc=<c>
# Exit: 0 complete | 1 partial | 2 error (connect/input)
# =============================================================================

[CmdletBinding()]
param(
    [string]$Ddls = '', [string]$Bdef = '', [string]$Clas = '', [string]$Srvd = '', [string]$Srvb = '',
    [string]$WorkDir = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if ($WorkDir) { $env:SAPDEV_AI_WORK_DIR = $WorkDir }
function Fail([string]$m) { Write-Output "STATUS: ERROR msg=$m"; exit 2 }

$shared = Join-Path (Split-Path -Parent $PSCommandPath) '..\..\..\..\sap-dev-core\shared\scripts'
$rfcLib = Join-Path $shared 'sap_rfc_lib.ps1'
if (-not (Test-Path $rfcLib)) { Fail "sap_rfc_lib.ps1 not found ($rfcLib)" }
. $rfcLib
$script:Dest = Connect-SapRfc -DestName 'RAPVERIFY'
if (-not $script:Dest) { Fail 'RFC_LOGON_FAILED' }

# Add a WHERE as OPTIONS rows split at ' AND ' boundaries, each <= 72 chars
# (RFC_READ_TABLE hard-limits each OPTIONS row to 72; the kernel space-joins them).
function Add-Where($fn, $where) {
    if (-not $where) { return }
    $conds = $where -split ' AND '
    $rows = @(); $cur = ''
    for ($i = 0; $i -lt $conds.Count; $i++) {
        $piece = if ($i -eq 0) { $conds[$i] } else { 'AND ' + $conds[$i] }
        if (-not $cur) { $cur = $piece }
        elseif (($cur.Length + 1 + $piece.Length) -le 72) { $cur = "$cur $piece" }
        else { $rows += $cur; $cur = $piece }
    }
    if ($cur) { $rows += $cur }
    foreach ($r in $rows) { Add-RfcOption $fn $r }
}
# Returns the integer row count directly (avoids the ,$empty-array return that
# makes @(...).Count report 1 for a zero-row result).
function Count-Rows($table, $where, $field) {
    $fn = New-RfcReadTable -Destination $script:Dest -Table $table
    [void]$fn.SetValue('DELIMITER', '~'); [void]$fn.SetValue('ROWCOUNT', 1)
    Add-Where $fn $where
    if ($field) { Add-RfcField $fn $field }
    $ok = $true; try { $fn.Invoke($script:Dest) } catch { if ($_.Exception.Message -match 'TABLE_WITHOUT_DATA') { $ok = $false } else { throw } }
    if (-not $ok) { return 0 }
    return [int]$fn.GetTable('DATA').RowCount
}
function Tadir-Present($object, $name) { return ((Count-Rows 'TADIR' "PGMID = 'R3TR' AND OBJECT = '$object' AND OBJ_NAME = '$name'" 'OBJ_NAME') -gt 0) }
function Has-Inactive($name) { return ((Count-Rows 'DWINACTIV' "OBJ_NAME = '$name'" 'OBJ_NAME') -gt 0) }

$cnt = @{ present = 0; active = 0; missing = 0; cnc = 0 }
$partial = $false
function Split-List($s) { return @($s -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }) }

try {
    # DDLS + CLAS + SRVD: TADIR present -> DWINACTIV for active/inactive
    foreach ($grp in @(@{ T = 'DDLS'; L = $Ddls }, @{ T = 'CLAS'; L = $Clas }, @{ T = 'SRVD'; L = $Srvd })) {
        foreach ($n in (Split-List $grp.L)) {
            if (-not (Tadir-Present $grp.T $n)) { Write-Output "RAPOBJ: $($grp.T) $n MISSING"; $cnt.missing++; $partial = $true; continue }
            if (Has-Inactive $n) { Write-Output "RAPOBJ: $($grp.T) $n INACTIVE pending-in-DWINACTIV"; $cnt.present++; $partial = $true }
            else { Write-Output "RAPOBJ: $($grp.T) $n ACTIVE"; $cnt.present++; $cnt.active++ }
        }
    }
    # BDEF: presence only; activation COULD_NOT_CHECK (no source table on 1909)
    foreach ($n in (Split-List $Bdef)) {
        if (-not (Tadir-Present 'BDEF' $n)) { Write-Output "RAPOBJ: BDEF $n MISSING"; $cnt.missing++; $partial = $true }
        else { Write-Output "RAPOBJ: BDEF $n PRESENT activation=COULD_NOT_CHECK"; $cnt.present++; $cnt.cnc++ }
    }
    # SRVB: presence via TADIR; published-state COULD_NOT_CHECK (IWFND column map is v1.1)
    foreach ($n in (Split-List $Srvb)) {
        if (-not (Tadir-Present 'SRVB' $n)) { Write-Output "RAPOBJ: SRVB $n MISSING"; $cnt.missing++; $partial = $true }
        else { Write-Output "RAPOBJ: SRVB $n PRESENT published=COULD_NOT_CHECK"; $cnt.present++; $cnt.cnc++ }
    }
}
finally { try { Disconnect-SapRfc -Destination $script:Dest } catch {}; try { Disconnect-SapRfc } catch {} }

$verdict = if ($cnt.missing -gt 0 -or $partial) { 'PARTIAL' } else { 'COMPLETE' }
Write-Output "STATUS: $verdict present=$($cnt.present) active=$($cnt.active) missing=$($cnt.missing) cnc=$($cnt.cnc)"
if ($verdict -eq 'COMPLETE') { exit 0 } else { exit 1 }
