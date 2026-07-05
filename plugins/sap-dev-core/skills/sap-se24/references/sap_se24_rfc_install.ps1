# =============================================================================
# sap_se24_rfc_install.ps1 -- headless class-source deploy via the installer FM
# Z_CLASS_SOURCE_INSTALL (RFC). The /sap-se24 RFC fallback (Step 4.7): preferred
# over the SE24 GUI upload when RFC is available AND the release supports the OO
# source API, because the GUI path fights the SAP GUI Security dialog + the
# inactive-objects worklist stall. Models sap-gen-cds/references/sap_cds_deploy.ps1
# (installer-FM caller) + sap-se37/references/sap_rfc_fm_insert.ps1 (FM deploy).
#
# SELF-HEALING + CAPABILITY-GATED: if Z_CLASS_SOURCE_INSTALL is absent, deploy it
# into ZFGDEVAI via sap_rfc_fm_insert.ps1 -- but ONLY when CL_OO_FACTORY exists.
# That OO source API ships on NW 7.31 EhP6+ (VERIFIED live on EC2/ERP 7.31 EhP6,
# ECC6 -- create/update/delete all green -- NOT just S/4), so this covers ECC6
# EhP6; only genuinely pre-7.31 stacks lack it. On any unsupported / unavailable
# condition it exits 3 = "degrade to GUI", so the caller falls through to Step
# 5a/5b and NEVER blocks.
#
# RUN WITH 32-BIT POWERSHELL (SAP NCo 3.1 is 32-bit-only).
#
# OUTPUT (stdout, parseable) + exit codes:
#   STATUS: DEPLOYED <mode> <cls> state=ACTIVATED|DELETED   exit 0  (done via RFC -> skip GUI)
#   STATUS: SAVED_INACTIVE <cls> ...                        exit 1  (source installed, activation FAILED = source defect)
#   STATUS: FAILED <mode> <cls> rc=.. state=.. msg=..       exit 1  (FM returned EV_RC<>0, e.g. delete failed)
#   STATUS: RELEASE_UNSUPPORTED ... / INSTALLER_ABSENT ...
#           / INSTALLER_DEPLOY_FAILED ...                   exit 3  (DEGRADE to GUI Step 5a/5b)
#   STATUS: RFC_ERROR ... / INPUT_ERROR ...                 exit 2  (connect / bad input)
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ClassName,
    [string] $Mode        = 'CREATE',   # CREATE | DELETE
    [string] $SourceFile  = '',          # full class source (CREATE); ignored for DELETE
    [string] $Description  = '',
    [string] $Package     = '$TMP',
    [string] $Transport   = '',
    [string] $Activate    = 'X',         # IV_ACTIVATE
    [string] $Overwrite   = 'X',         # IV_OVERWRITE
    [switch] $NoAutoDeploy,              # do NOT self-heal the installer FM if absent -> exit 3

    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '', [string] $LogonGroup = '',
    [string] $SystemID = '', [string] $Client = '', [string] $User = '', [string] $Password = '', [string] $Language = ''
)
$ErrorActionPreference = 'Stop'
$scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$INSTALLER_FM   = 'Z_CLASS_SOURCE_INSTALL'
$INSTALLER_FG   = 'ZFGDEVAI'
$INSTALLER_ABAP = Join-Path $scriptDir 'Z_CLASS_SOURCE_INSTALL.abap'
$FM_INSERT_PS1  = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\sap-se37\references\sap_rfc_fm_insert.ps1'))
$PS32           = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'

if ($Mode -ne 'CREATE' -and $Mode -ne 'DELETE') { Write-Output 'STATUS: INPUT_ERROR Mode must be CREATE|DELETE'; exit 2 }
$src = ''
if ($Mode -eq 'CREATE') {
    if ([string]::IsNullOrWhiteSpace($SourceFile) -or -not (Test-Path -LiteralPath $SourceFile)) {
        Write-Output ('STATUS: INPUT_ERROR CREATE needs -SourceFile (not found: ' + $SourceFile + ')'); exit 2
    }
    $src = [IO.File]::ReadAllText($SourceFile, [Text.Encoding]::UTF8)
}

. ([IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\..\shared\scripts\sap_rfc_lib.ps1')))

# unary comma keeps a single-row result an array (else PS unwraps it to a scalar
# string and $rows[0] indexes the first CHARACTER, not the row).
function Read-Col($dest, $table, $where, $field) {
    $fn = New-RfcReadTable -Destination $dest -Table $table -Delimiter '|'
    if ($where) { Add-RfcOption $fn $where }
    Add-RfcField $fn $field
    $fn.Invoke($dest)
    $o = @(); foreach ($r in $fn.GetTable('DATA')) { $o += $r.GetString('WA').Trim() }
    return , $o
}

$dest = $null
try {
    $dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup `
        -SystemID $SystemID -Client $Client -User $User -Password $Password -Language $Language
} catch { Write-Output ('STATUS: RFC_ERROR ' + $_.Exception.Message); exit 2 }
if (-not $dest) { Write-Output 'STATUS: RFC_ERROR could not connect (run /sap-login)'; exit 2 }

try {
    # --- 1) installer FM present + Remote-Enabled? (self-heal if absent) --------
    $fmode = $null
    $rows = Read-Col $dest 'TFDIR' "FUNCNAME = '$INSTALLER_FM'" 'FMODE'
    if ($rows.Count -ge 1) { $fmode = $rows[0] }

    if ($null -eq $fmode) {
        if ($NoAutoDeploy) {
            Write-Output "STATUS: INSTALLER_ABSENT $INSTALLER_FM not deployed (-NoAutoDeploy) -- use GUI"
            Disconnect-SapRfc -Destination $dest; exit 3
        }
        # Capability gate: the FM's source API needs CL_OO_FACTORY (present on NW
        # 7.31 EhP6+, incl. ECC6 EhP6 -- verified live on EC2/ERP). Only genuinely
        # pre-7.31 stacks lack it -> there the FM can't activate, so degrade.
        $cap = Read-Col $dest 'SEOCLASSDF' "CLSNAME = 'CL_OO_FACTORY' AND VERSION = '1'" 'CLSNAME'
        if ($cap.Count -eq 0) {
            Write-Output 'STATUS: RELEASE_UNSUPPORTED CL_OO_FACTORY absent (pre-7.31 OO source API) -- use GUI'
            Disconnect-SapRfc -Destination $dest; exit 3
        }
        if (-not (Test-Path -LiteralPath $INSTALLER_ABAP)) {
            Write-Output "STATUS: INSTALLER_DEPLOY_FAILED installer source not found: $INSTALLER_ABAP"
            Disconnect-SapRfc -Destination $dest; exit 3
        }
        Write-Output "STATUS: INSTALLER_DEPLOYING $INSTALLER_FM absent -> deploying into $INSTALLER_FG (release supports it)"
        # Run the FM-insert helper as a SUBPROCESS -- never dot-source a param() CLI
        # script (it clobbers our $Transport/$Mode/... ). Force 32-bit for NCo.
        $fmArgs = @('-ExecutionPolicy', 'Bypass', '-File', $FM_INSERT_PS1,
            '-SourceFile', $INSTALLER_ABAP, '-FunctionGroup', $INSTALLER_FG, '-Remote',
            '-ShortText', 'RFC installer: headless class source deploy (SE24 fallback)')
        if ($Transport -ne '') { $fmArgs += @('-Transport', $Transport) }
        $out = & $PS32 @fmArgs 2>&1
        $out | ForEach-Object { Write-Output ('  fm_insert> ' + $_) }
        $rows2 = Read-Col $dest 'TFDIR' "FUNCNAME = '$INSTALLER_FM'" 'FMODE'
        if ($rows2.Count -ge 1) { $fmode = $rows2[0] }
        if ($fmode -ne 'R') {
            Write-Output "STATUS: INSTALLER_DEPLOY_FAILED $INSTALLER_FM not Remote-Enabled/active after insert (FMODE=$fmode) -- use GUI"
            Disconnect-SapRfc -Destination $dest; exit 3
        }
        Write-Output "STATUS: INSTALLER_READY $INSTALLER_FM deployed FMODE=R"
    } elseif ($fmode -ne 'R') {
        Write-Output "STATUS: INSTALLER_DEPLOY_FAILED $INSTALLER_FM exists but FMODE='$fmode' (not Remote-Enabled) -- use GUI or re-deploy Remote-Enabled"
        Disconnect-SapRfc -Destination $dest; exit 3
    }

    # --- 2) call the installer FM (ALL IV_* explicit -- ABAP DEFAULTs are NOT ---
    #        applied over RFC; an omitted param arrives INITIAL) -----------------
    $fn = $dest.Repository.CreateFunction($INSTALLER_FM)
    [void]$fn.SetValue('IV_MODE',        $Mode)
    [void]$fn.SetValue('IV_CLSNAME',     $ClassName)
    [void]$fn.SetValue('IV_SOURCE',      $src)
    [void]$fn.SetValue('IV_DESCRIPTION', $Description)
    [void]$fn.SetValue('IV_PACKAGE',     $Package)
    [void]$fn.SetValue('IV_TRANSPORT',   $Transport)
    [void]$fn.SetValue('IV_ACTIVATE',    $Activate)
    [void]$fn.SetValue('IV_OVERWRITE',   $Overwrite)
    $fn.Invoke($dest)
    $rc    = [int]$fn.GetValue('EV_RC')
    $state = "$($fn.GetValue('EV_STATE'))"
    $inact = "$($fn.GetValue('EV_INACTIVE'))"
    $msg   = "$($fn.GetValue('EV_MESSAGE'))"
    Write-Output "EV_RC=$rc"; Write-Output "EV_STATE=$state"; Write-Output "EV_INACTIVE=$inact"; Write-Output "EV_MESSAGE=$msg"
    Disconnect-SapRfc -Destination $dest

    if ($rc -eq 0 -and ($state -eq 'ACTIVATED' -or $state -eq 'DELETED')) {
        Write-Output "STATUS: DEPLOYED $Mode $ClassName state=$state"; exit 0
    } elseif ($rc -eq 0 -and $state -eq 'SAVED_INACTIVE') {
        Write-Output "STATUS: SAVED_INACTIVE $ClassName source installed but activation FAILED (class-source defect?) -- fix source or activate via /sap-activate-object; EV_MESSAGE above"
        exit 1
    } else {
        Write-Output "STATUS: FAILED $Mode $ClassName rc=$rc state=$state msg=$msg"; exit 1
    }
} catch {
    Write-Output ('STATUS: FATAL ' + $_.Exception.Message)
    try { Disconnect-SapRfc -Destination $dest } catch {}
    exit 1
}
