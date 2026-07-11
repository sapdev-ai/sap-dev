# =============================================================================
# sap_idoc_type_read.ps1  -  IDoc-type metadata reader for /sap-gen-idoc-handler
#
# Reads an IDoc basic type's segment tree via IDOCTYPE_READ_COMPLETE (FMODE=R
# direct, no wrapper) so the generator can build a typed segment-decode loop.
# RFC-only, read-only. Emits <name>_idoc_segments.tsv + SEGMENTS: lines.
#
# Signature (verified S4D 2026-07-11): IMPORTING PI_IDOCTYP [PI_CIMTYP];
#   TABLES PT_SEGMENTS(NR,SEGMENTTYP,SEGMENTDEF,QUALIFIER,PARSEG,MUSTFL,OCCMIN,
#   OCCMAX,HLEVEL,DESCRP), PT_FIELDS, PT_MESSAGES.
#
# STATUS: OK | IDOC_TYPE_NOT_FOUND | RFC_ERROR ; exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $IdocType = '',
    [string] $CimType = '',
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
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; IdocType=$IdocType; CimType=$CimType }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function G { param($t,$col) try { return ("$($t.GetString($col))").Trim() } catch { return '' } }

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $IdocType) { Write-Host "STATUS: RFC_ERROR detail=no_idoctype"; exit 2 }
    $it = $IdocType.ToUpper()
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_IDOCTYPE"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
    try {
        $fn = $g_dest.Repository.CreateFunction('IDOCTYPE_READ_COMPLETE')
        $fn.SetValue('PI_IDOCTYP', $it); if ($CimType) { $fn.SetValue('PI_CIMTYP', $CimType.ToUpper()) }
        try { $fn.Invoke($g_dest) } catch {
            $m = "$($_.Exception.Message)"
            if ($m -match 'OBJECT_UNKNOWN|not exist|unknown') { Write-Host "STATUS: IDOC_TYPE_NOT_FOUND idoctype=$it"; try { Disconnect-SapRfc } catch {}; exit 1 }
            throw
        }
        $seg = $fn.GetTable('PT_SEGMENTS')
        if ($seg.RowCount -eq 0) { Write-Host "STATUS: IDOC_TYPE_NOT_FOUND idoctype=$it detail=no_segments"; try { Disconnect-SapRfc } catch {}; exit 1 }
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("nr`tsegmenttyp`tsegmentdef`tparent`tlevel`tmandatory`toccmin`toccmax`tqualifier`tdescription")
        for ($i=0; $i -lt $seg.RowCount; $i++) {
            $seg.CurrentIndex = $i
            $out.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}" -f `
                (G $seg 'NR'), (G $seg 'SEGMENTTYP'), (G $seg 'SEGMENTDEF'), (G $seg 'PARSEG'), (G $seg 'HLEVEL'), (G $seg 'MUSTFL'), (G $seg 'OCCMIN'), (G $seg 'OCCMAX'), (G $seg 'QUALIFIER'), ((G $seg 'DESCRP') -replace "[`t`r`n]",' ')))
        }
        if (-not $OutFile) { $OutFile = Join-Path (Get-Location).Path ($it.ToLower()+'_idoc_segments.tsv') }
        [System.IO.File]::WriteAllText($OutFile, ($out -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
        $mand = 0; for ($i=0;$i -lt $seg.RowCount;$i++){ $seg.CurrentIndex=$i; if ((G $seg 'MUSTFL') -eq 'X') { $mand++ } }
        Write-Host "SEGMENTS_TSV: $OutFile"
        Write-Host ("SEGMENTS: idoctype=$it n=$($seg.RowCount) mandatory=$mand cimtype=$CimType")
        Write-Host "STATUS: OK"
        try { Disconnect-SapRfc } catch {}
        exit 0
    } catch {
        Write-Host ("STATUS: RFC_ERROR detail=" + (("$($_.Exception.Message)") -replace "[`t`r`n]",' '))
        try { Disconnect-SapRfc } catch {}
        exit 2
    }
}
