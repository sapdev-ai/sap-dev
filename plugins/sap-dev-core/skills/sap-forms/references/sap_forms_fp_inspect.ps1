# =============================================================================
# sap_forms_fp_inspect.ps1  -  Adobe form inspect for /sap-forms (READ-ONLY, RFC)
#
# Reads Adobe form/interface METADATA over RFC_READ_TABLE (FPINTERFACE / FPCONTEXT
# / FPLAYOUT metadata columns only - the XDP layout blob is a RAWSTRING RFC cannot
# return, and SFP layout export needs Adobe LiveCycle Designer, so v1 is
# inspect-only by design). Joins TADIR + a TNAPR usage note. Emits FP: lines the
# SKILL renders into adobe_<NAME>_inspect.md.
# Exit 0 ran, 1 FORMS_NOT_FOUND, 2 connect.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Name = '',
    [string] $OutFile = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch {} }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Name=$Name }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }
function Sq { param([string]$s) return (("$s") -replace "'", "''") }

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Name) { Write-Host "STATUS: INPUT_ERROR reason=name_required"; exit 2 }
    $nm = $Name.ToUpper()
    $g = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_FP"
    if (-not $g) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
    function HasRows { param($x) return ($null -ne $x -and @($x).Count -gt 0 -and $null -ne @($x)[0]) }
    try {
        # LIVE-PROVEN (S4D 2026-07-11): FPLAYOUT/FPINTERFACE/FPCONTEXT are NOT RFC-readable
        # (RAWSTRING columns -> RFC_READ_TABLE dies "ASSIGN CASTING in SAPLSDTX", like /UI2
        # tables) even for narrow fields. So existence/package come from TADIR (readable) and
        # the FP* interface/context metadata is honestly COULD_NOT_CHECK, not a false empty.
        $tad = $null
        try { $tad = Read-SapTableRows -Destination $g -Table 'TADIR' -Where "PGMID EQ 'R3TR' AND OBJECT EQ 'SFPF' AND OBJ_NAME EQ '$(Sq $nm)'" -Fields @('OBJ_NAME','DEVCLASS','AUTHOR') -RowCount 1 } catch {}
        if (-not (HasRows $tad)) { Write-Host "STATUS: FORMS_NOT_FOUND name=$nm detail=no_adobe_form_in_TADIR"; try { Disconnect-SapRfc } catch {}; exit 1 }
        $pkg = "$($tad[0].DEVCLASS)"; $author = "$($tad[0].AUTHOR)"
        Write-Host "FP: name=$nm package=$pkg author=$author"
        Write-Host "FP: interface=COULD_NOT_CHECK context=COULD_NOT_CHECK layout=COULD_NOT_CHECK reason=FPINTERFACE/FPCONTEXT/FPLAYOUT_not_RFC_readable_RAWSTRING_SAPLSDTX (use SFP GUI / ADT); no XDP extraction in v1"
        # usage note (TNAPR SFORM referencing this Adobe form) - TNAPR IS readable
        $used=0; try { $tn = Read-SapTableRows -Destination $g -Table 'TNAPR' -Where "SFORM EQ '$(Sq $nm)'" -Fields @('KSCHL','KAPPL','NACHA') -RowCount 50; $used=@($tn | Where-Object { $_ }).Count } catch {}
        Write-Host "FP: tnapr_assignments=$used note=inspect_only"
        if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, "name`tpackage`tauthor`ttnapr_assignments`tmetadata_coverage`r`n$nm`t$pkg`t$author`t$used`tCOULD_NOT_CHECK`r`n", (New-Object System.Text.UTF8Encoding($true))) }
        Write-Host "STATUS: OK"
        try { Disconnect-SapRfc } catch {}
        exit 0
    } catch { Write-Host ("STATUS: RFC_ERROR detail=" + (("$($_.Exception.Message)") -replace "[`t`r`n]",' ')); try { Disconnect-SapRfc } catch {}; exit 2 }
}
