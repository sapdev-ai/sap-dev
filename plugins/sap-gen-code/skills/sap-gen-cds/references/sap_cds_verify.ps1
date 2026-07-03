# sap_cds_verify.ps1 -- RFC verification that a CDS view is deployed + active.
# Checks TADIR(DDLS) + the generated SQL view (TADIR VIEW / DD02L / DD25L).
# DDDDLSRC is intentionally NOT read (its SOURCE string column dumps
# RFC_READ_TABLE with ASSIGN CASTING in SAPLSDTX, same class as REPOSRC).
# 32-bit PowerShell.
param(
  [Parameter(Mandatory)][string]$SharedScripts,
  [Parameter(Mandatory)][string]$DdlName,
  [string]$SqlView = ''          # classic-view SQL view name; blank for view entities (7.55+)
)
$ErrorActionPreference = 'Stop'
. (Join-Path $SharedScripts 'sap_settings_lib.ps1')
. (Join-Path $SharedScripts 'sap_connection_lib.ps1')
. (Join-Path $SharedScripts 'sap_rfc_lib.ps1')
$dest = Connect-SapRfc
if (-not $dest) { Write-Output 'VERIFY: ERROR no RFC destination (run /sap-login)'; exit 2 }
function Rows($tbl, [string[]]$fields, $where) {
  $fn = New-RfcReadTable -Destination $dest -Table $tbl -Delimiter '|'
  # RFC_READ_TABLE caps each OPTIONS row at 72 chars, so `A AND B AND C` as one
  # row overflows for long DDL names (>=21 chars -> SAPSQL_PARSE_ERROR). Split at
  # AND boundaries, one clause per OPTIONS row (shared Add-RfcWhereClauses rule).
  $parts = [regex]::Split($where, '\s+AND\s+')
  for ($k = 0; $k -lt $parts.Count; $k++) {
    $clause = if ($k -eq 0) { $parts[$k].Trim() } else { 'AND ' + $parts[$k].Trim() }
    Add-RfcOption $fn $clause
  }
  foreach ($f in $fields) { Add-RfcField $fn $f }
  $fn.Invoke($dest)
  $out = @(); foreach ($r in $fn.GetTable('DATA')) { $out += $r.GetString('WA').TrimEnd() }
  return ,$out
}
$n = $DdlName.ToUpper(); $v = $SqlView.ToUpper()
$ddls = Rows 'TADIR' @('OBJ_NAME','DEVCLASS') "PGMID = 'R3TR' AND OBJECT = 'DDLS' AND OBJ_NAME = '$n'"
Write-Output ("DDLS_TADIR=" + $ddls.Count + " " + ($ddls -join ' ; '))
if ($v -ne '') {
  # Classic view: the generated SQL view must be active (AS4LOCAL='A'), checked
  # per row -- never on a concatenation whose tail depends on server row order.
  $dd02 = Rows 'DD02L' @('TABNAME','TABCLASS','AS4LOCAL') "TABNAME = '$v'"
  $dd25 = Rows 'DD25L' @('VIEWNAME','AS4LOCAL')            "VIEWNAME = '$v'"
  Write-Output ("SQLVIEW_DD02L=" + $dd02.Count + " " + ($dd02 -join ' ; '))
  Write-Output ("SQLVIEW_DD25L=" + $dd25.Count + " " + ($dd25 -join ' ; '))
  $viewActive = $false
  foreach ($row in $dd02) { $c = $row -split '\|'; if ($c.Count -gt 2 -and $c[2].Trim() -eq 'A') { $viewActive = $true } }
} else {
  # View entity (7.55+): no generated SQL view exists to probe. Verify activation
  # via DWINACTIV (inactive-objects worklist) keyed on the DDL name -- a row means
  # still inactive. DWINACTIV object-type codes don't line up with TADIR, so match
  # on OBJ_NAME only (the sap_object_resolver Test-SapObjectActive convention).
  $inact = Rows 'DWINACTIV' @('OBJECT','OBJ_NAME') "OBJ_NAME = '$n'"
  Write-Output ("DWINACTIV=" + $inact.Count + " " + ($inact -join ' ; '))
  $viewActive = ($inact.Count -eq 0)
}
Disconnect-SapRfc $dest 2>$null
if ($ddls.Count -ge 1 -and $viewActive) { Write-Output "VERIFY: ACTIVE $DdlName"; exit 0 }
elseif ($ddls.Count -ge 1)              { Write-Output "VERIFY: PARTIAL $DdlName (DDLS present, view not active)"; exit 1 }
else                                     { Write-Output "VERIFY: MISSING $DdlName"; exit 1 }
