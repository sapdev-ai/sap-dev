# sap_cds_release_probe.ps1 -- print the SAP_BASIS release for the /sap-gen-cds
# release gate (>= 7.50). CVERS read via RFC. Fail-loud; never guesses a release.
# 32-bit PowerShell (NCo 3.1 GAC_32). Invoked with -File so no shell variable
# expansion (the old inline -Command one-liner had $vars eaten by the bash host).
param(
  [Parameter(Mandatory)][string]$SharedScripts   # abs path to sap-dev-core/shared/scripts
)
$ErrorActionPreference = 'Stop'
. (Join-Path $SharedScripts 'sap_settings_lib.ps1')
. (Join-Path $SharedScripts 'sap_connection_lib.ps1')
. (Join-Path $SharedScripts 'sap_rfc_lib.ps1')
$dest = Connect-SapRfc
if (-not $dest) { Write-Output 'RELEASE: ERROR no RFC destination (run /sap-login)'; exit 2 }
try {
  $fn = New-RfcReadTable -Destination $dest -Table 'CVERS' -Delimiter '|'
  Add-RfcOption $fn "COMPONENT = 'SAP_BASIS'"
  Add-RfcField  $fn 'RELEASE'
  $fn.Invoke($dest)
  $rel = ''
  foreach ($r in $fn.GetTable('DATA')) { $rel = $r.GetString('WA').Trim() }
  if ($rel -eq '') { Write-Output 'RELEASE: ERROR SAP_BASIS not found in CVERS'; exit 1 }
  Write-Output "SAP_BASIS=$rel"
  Write-Output "RELEASE: OK $rel"
  exit 0
} catch {
  Write-Output ('RELEASE: ERROR ' + $_.Exception.Message); exit 2
} finally {
  Disconnect-SapRfc $dest 2>$null
}
