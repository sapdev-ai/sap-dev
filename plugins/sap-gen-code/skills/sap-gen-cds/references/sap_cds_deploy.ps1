# sap_cds_deploy.ps1 -- deploy/delete a CDS DDL source via the installer FM
# Z_CDS_DDL_INSTALL (RFC). Fail-loud if the installer FM is absent or not
# Remote-Enabled. 32-bit PowerShell (NCo 3.1 GAC_32).
param(
  [Parameter(Mandatory)][string]$SharedScripts,  # abs path to sap-dev-core/shared/scripts
  [string]$Mode       = 'CREATE',                # CREATE | DELETE
  [Parameter(Mandatory)][string]$DdlName,
  [string]$DdlFile    = '',                       # UTF-8 DDL source file (CREATE)
  [string]$SourceType = 'V',                      # V=classic view, W=view entity
  [string]$Package    = '$TMP',
  [string]$Transport  = '',
  [string]$PutState   = 'N',                       # OBJSTATE for save (N=inactive); MUST be set over RFC
  [string]$Activate   = 'X'                        # IV_ACTIVATE: 'X'=activate after save; ''=stage inactive (--no-activate)
)
$ErrorActionPreference = 'Stop'
. (Join-Path $SharedScripts 'sap_settings_lib.ps1')
. (Join-Path $SharedScripts 'sap_connection_lib.ps1')
. (Join-Path $SharedScripts 'sap_rfc_lib.ps1')
$dest = Connect-SapRfc
if (-not $dest) { Write-Output 'DEPLOY: ERROR no RFC destination (run /sap-login)'; exit 2 }

# --- Pre-flight: installer FM present + Remote-Enabled (TFDIR.FMODE='R') ---
try {
  $chk = New-RfcReadTable -Destination $dest -Table 'TFDIR' -Delimiter '|'
  Add-RfcOption $chk "FUNCNAME = 'Z_CDS_DDL_INSTALL'"
  Add-RfcField  $chk 'FMODE'
  $chk.Invoke($dest)
  $fmode = $null
  foreach ($r in $chk.GetTable('DATA')) { $fmode = $r.GetString('WA').Trim() }
  if ($null -eq $fmode) {
    Write-Output 'DEPLOY: ERROR installer FM Z_CDS_DDL_INSTALL not found. Deploy it first (see /sap-gen-cds Step 3 bootstrap).'; exit 3
  }
  if ($fmode -ne 'R') {
    Write-Output "DEPLOY: ERROR Z_CDS_DDL_INSTALL exists but FMODE='$fmode' (not Remote-Enabled). Re-deploy it Remote-Enabled."; exit 3
  }
} catch { Write-Output ('DEPLOY: ERROR pre-flight TFDIR read failed: ' + $_.Exception.Message); exit 2 }

$src = ''
if ($Mode -eq 'CREATE') {
  if ($DdlFile -eq '' -or -not (Test-Path $DdlFile)) { Write-Output 'DEPLOY: ERROR CREATE needs -DdlFile'; exit 2 }
  $src = [System.IO.File]::ReadAllText($DdlFile, [System.Text.Encoding]::UTF8)
}

$fn = $dest.Repository.CreateFunction('Z_CDS_DDL_INSTALL')
[void]$fn.SetValue('IV_MODE',        $Mode)
[void]$fn.SetValue('IV_DDLNAME',     $DdlName)
[void]$fn.SetValue('IV_SOURCE',      $src)
[void]$fn.SetValue('IV_SOURCE_TYPE', $SourceType)
[void]$fn.SetValue('IV_PACKAGE',     $Package)
if ($Transport -ne '') { [void]$fn.SetValue('IV_TRANSPORT', $Transport) }
[void]$fn.SetValue('IV_ACTIVATE',    $Activate)
# ABAP interface DEFAULTs are NOT applied over RFC -- set IV_PUT_STATE explicitly
# or it arrives INITIAL and SAVE fails ("Invalid input value: PUT_STATE=").
[void]$fn.SetValue('IV_PUT_STATE',   $PutState)
$fn.Invoke($dest)
$rc    = [int]$fn.GetValue('EV_RC')
$state = "$($fn.GetValue('EV_STATE'))"
$msg   = "$($fn.GetValue('EV_MESSAGE'))"
Write-Output "EV_RC=$rc"; Write-Output "EV_STATE=$state"; Write-Output "EV_MESSAGE=$msg"
if ($rc -eq 0) { Write-Output "DEPLOY: OK $Mode $DdlName state=$state" }
else           { Write-Output "DEPLOY: FAILED $Mode $DdlName state=$state msg=$msg" }
Disconnect-SapRfc $dest 2>$null
exit $rc
