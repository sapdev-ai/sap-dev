# =============================================================================
# sap_idoc_wiring_check.ps1  -  verify-wiring reader for /sap-gen-idoc-handler
#
# Read-only RFC check: are the WE57/BD51/WE42/WE20 registration rows the generated
# handler needs actually present? Reads EDIFCT / TBD51 / TEDE2 / EDP21 (all probed
# on both releases) filtered by FM / idoc type / message type / process code /
# partner. RFC-only, no writes.
#
#   WIRING: <table> <PRESENT|MISSING|COULD_NOT_CHECK> key=<...>
#   VERDICT: WIRED | PARTIAL | UNWIRED | COULD_NOT_CHECK
# Exit: 0 ran, 2 connect/input.
# =============================================================================

[CmdletBinding()]
param(
    [string] $FmName = '',
    [string] $IdocType = '',
    [string] $MessageType = '',
    [string] $ProcessCode = '',
    [string] $Partner = '', [string] $PartnerType = '',
    [string] $OutFile = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; FmName=$FmName; IdocType=$IdocType; MessageType=$MessageType; ProcessCode=$ProcessCode; Partner=$Partner; PartnerType=$PartnerType }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }
function Sq { param([string]$s) return (("$s") -replace "'", "''") }

$script:rows = New-Object System.Collections.Generic.List[object]
function W { param($tbl,$status,$key) Write-Host "WIRING: $tbl $status key=$key"; $script:rows.Add([pscustomobject]@{ tbl=$tbl; status=$status }) }
# Read-SapTableRows returns $null on an RFC error (e.g. a bad field name) but an
# EMPTY array for a genuine 0-row result -> distinguish so an errored read is
# COULD_NOT_CHECK, never a false PRESENT (the @($null).Count==1 trap).
function ReadStatus {
    param([string]$Table,[string]$Where,[string[]]$Fields,[scriptblock]$Pred=$null)
    $r = $null
    try { $r = Read-SapTableRows -Destination $g_dest -Table $Table -Where $Where -Fields $Fields -RowCount 20 } catch { return 'COULD_NOT_CHECK' }
    if ($null -eq $r) { return 'COULD_NOT_CHECK' }
    $rows = @($r)
    if ($rows.Count -eq 0) { return 'MISSING' }
    if ($Pred) { foreach ($row in $rows) { if (& $Pred $row) { return 'PRESENT' } }; return 'MISSING' }
    return 'PRESENT'
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $FmName) { Write-Host "STATUS: INPUT_ERROR reason=fm_required"; exit 2 }
    $fm = $FmName.ToUpper()
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_IDOCWIRE"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
    try {
        # EDIFCT (WE57): FM registered for its IDoc type (idoctype an optional predicate)
        $pred = if ($IdocType) { { param($x) "$($x.IDOCTYP)".ToUpper() -eq $IdocType.ToUpper() } } else { $null }
        W 'EDIFCT' (ReadStatus 'EDIFCT' "OBJNAM EQ '$(Sq $fm)'" @('OBJNAM','IDOCTYP','MESTYP') $pred) "OBJNAM=$fm IDOCTYP=$IdocType (WE57)"

        # TBD51 (BD51): input-type characteristics for the FM
        W 'TBD51' (ReadStatus 'TBD51' "FUNCNAME EQ '$(Sq $fm)'" @('FUNCNAME')) "FUNCNAME=$fm (BD51)"

        # TEDE2 (WE42): inbound process code -> FM (the FM is TEDE2-EVENTN when EVENTT='F')
        if ($ProcessCode) {
            W 'TEDE2' (ReadStatus 'TEDE2' "EVCODE EQ '$(Sq $ProcessCode.ToUpper())'" @('EVCODE','EVENTT','EVENTN') { param($x) "$($x.EVENTN)".ToUpper() -eq $fm }) "EVCODE=$ProcessCode EVENTN=$fm (WE42)"
        } else {
            W 'TEDE2' (ReadStatus 'TEDE2' "EVENTN EQ '$(Sq $fm)'" @('EVCODE','EVENTT','EVENTN')) "EVENTN=$fm (WE42; any process code)"
        }

        # EDP21 (WE20): partner inbound - only when a partner is given
        if ($Partner) {
            $w2 = "SNDPRN EQ '$(Sq $Partner.ToUpper())'"; if ($PartnerType) { $w2 += " AND SNDPRT EQ '$(Sq $PartnerType.ToUpper())'" }; if ($MessageType) { $w2 += " AND MESTYP EQ '$(Sq $MessageType.ToUpper())'" }
            W 'EDP21' (ReadStatus 'EDP21' $w2 @('SNDPRN','MESTYP')) "SNDPRN=$Partner MESTYP=$MessageType (WE20)"
        }

        $present = @($script:rows | Where-Object { $_.status -eq 'PRESENT' }).Count
        $missing = @($script:rows | Where-Object { $_.status -eq 'MISSING' }).Count
        $cnc = @($script:rows | Where-Object { $_.status -eq 'COULD_NOT_CHECK' }).Count
        $core = @($script:rows | Where-Object { $_.tbl -in @('EDIFCT','TBD51','TEDE2') })
        $corePresent = @($core | Where-Object { $_.status -eq 'PRESENT' }).Count
        $verdict = if ($cnc -gt 0 -and $present -eq 0) { 'COULD_NOT_CHECK' } elseif ($corePresent -eq $core.Count -and $core.Count -gt 0) { 'WIRED' } elseif ($present -gt 0) { 'PARTIAL' } else { 'UNWIRED' }
        if ($OutFile) { $tsv = @("table`tstatus") + @($script:rows | ForEach-Object { "$($_.tbl)`t$($_.status)" }); [System.IO.File]::WriteAllText($OutFile, ($tsv -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true))) }
        Write-Host ("VERDICT: $verdict present=$present missing=$missing could_not_check=$cnc")
        Write-Host "STATUS: OK"
        try { Disconnect-SapRfc } catch {}
        exit 0
    } catch {
        Write-Host ("STATUS: RFC_ERROR detail=" + (("$($_.Exception.Message)") -replace "[`t`r`n]",' '))
        try { Disconnect-SapRfc } catch {}
        exit 2
    }
}
