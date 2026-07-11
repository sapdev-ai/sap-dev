# =============================================================================
# sap_guide_ddic_texts.ps1  -  DDIC text harvester for /sap-user-guide (READ-ONLY)
#
# Resolves the authoritative business texts a training guide needs, over RFC:
#   - tcode title from TSTCT
#   - per (table,field): label via DDIF_FIELDINFO_GET (FIELDTEXT/SCRTEXT_L, rollname)
#   - F1 long documentation via DOCU_GET (ID='DE', OBJECT=<rollname>) - FMODE=R on
#     BOTH releases, so NO RFC_READ_TABLE on DOKTL (CLUSTER on ECC6). DOKIL is the
#     cheap "does a doc exist / in which languages" index before the DOCU_GET call.
# --lang sets the DDLANGUAGE/LANGU with an EN-then-any fallback.
#
# Emits guide_fields.tsv (table,field,label,rollname,has_doc,doc_excerpt) +
# guide_meta.tsv (tcode,title,program,dynpro). A field whose text can't be fetched
# is coverage=COULD_NOT_CHECK, never silently dropped.
# Exit: 0 ran, 2 connect/input.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Tcode = '',
    [string] $Fields = '',          # "TAB-FLD,TAB2-FLD2" or a -FieldsFile
    [string] $FieldsFile = '',
    [string] $Lang = 'E',
    [int]    $MaxDocs = 50,
    [string] $OutDir = '',
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
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Tcode=$Tcode; Fields=$Fields; FieldsFile=$FieldsFile; Lang=$Lang }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }
if (-not $OutDir) { $OutDir = (Get-Location).Path }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
function Sq { param([string]$s) return (("$s") -replace "'", "''") }
$lang = if ($Lang) { $Lang.Substring(0,[Math]::Min(1,$Lang.Length)).ToUpper() } else { 'E' }
function G { param($t,$col) try { return ("$($t.GetString($col))").Trim() } catch { return '' } }

if ($MyInvocation.InvocationName -ne '.') {
    # field list
    $fieldPairs = @()
    if ($FieldsFile -and (Test-Path $FieldsFile)) { foreach ($ln in [System.IO.File]::ReadAllLines($FieldsFile)) { if($ln -match '^\s*#' -or $ln.Trim() -eq ''){continue}; $t=$ln.Trim(); if($t -match '^([A-Z0-9_/]+)[-\t]([A-Z0-9_]+)'){ $fieldPairs += ,@($matches[1],$matches[2]) } } }
    foreach ($p in @($Fields -split ',' | Where-Object { $_ -match '-' })) { $x=$p.Trim() -split '-',2; $fieldPairs += ,@($x[0].Trim().ToUpper(),$x[1].Trim().ToUpper()) }

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_GUIDE_DDIC"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
    try {
        # ---- meta: tcode title + program/dynpro ----
        $title=''; $prog=''; $dyn=''
        if ($Tcode) {
            $tt = @(); try { $tt = Read-SapTableRows -Destination $g_dest -Table 'TSTCT' -Where "SPRSL EQ '$lang' AND TCODE EQ '$(Sq $Tcode.ToUpper())'" -Fields @('TTEXT') -RowCount 1 } catch {}
            if (-not (@($tt).Count)) { try { $tt = Read-SapTableRows -Destination $g_dest -Table 'TSTCT' -Where "SPRSL EQ 'E' AND TCODE EQ '$(Sq $Tcode.ToUpper())'" -Fields @('TTEXT') -RowCount 1 } catch {} }
            if (@($tt).Count) { $title = "$($tt[0].TTEXT)" }
            $ts = @(); try { $ts = Read-SapTableRows -Destination $g_dest -Table 'TSTC' -Where "TCODE EQ '$(Sq $Tcode.ToUpper())'" -Fields @('PGMNA','DYPNO') -RowCount 1 } catch {}
            if (@($ts).Count) { $prog = "$($ts[0].PGMNA)"; $dyn = "$($ts[0].DYPNO)" }
        }
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'guide_meta.tsv'), "tcode`ttitle`tprogram`tdynpro`r`n$($Tcode.ToUpper())`t$title`t$prog`t$dyn`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ("META: tcode=$($Tcode.ToUpper()) title='$title' program=$prog dynpro=$dyn")

        # ---- per-field label + F1 doc ----
        $out = New-Object System.Collections.Generic.List[string]; $out.Add("table`tfield`tlabel`trollname`thas_doc`tcoverage`tdoc_excerpt")
        $docCount=0; $resolved=0; $cnc=0
        foreach ($fp in $fieldPairs) {
            $tab=$fp[0]; $fld=$fp[1]; $label=''; $roll=''; $ran=$true
            try { $fn=$g_dest.Repository.CreateFunction('DDIF_FIELDINFO_GET'); $fn.SetValue('TABNAME',$tab); $fn.SetValue('FIELDNAME',$fld); $fn.SetValue('LANGU',$lang); $fn.Invoke($g_dest)
                  $dt=$fn.GetTable('DFIES_TAB'); for($i=0;$i -lt $dt.RowCount;$i++){ $dt.CurrentIndex=$i; if((G $dt 'FIELDNAME') -eq $fld){ $label=(G $dt 'SCRTEXT_L'); if(-not $label){$label=(G $dt 'FIELDTEXT')}; $roll=(G $dt 'ROLLNAME'); break } } } catch { $ran=$false }
            $hasDoc='N'; $excerpt=''
            if ($ran -and $roll -and $docCount -lt $MaxDocs) {
                try {
                    $dk = @(); try { $dk = Read-SapTableRows -Destination $g_dest -Table 'DOKIL' -Where "ID EQ 'DE' AND OBJECT EQ '$(Sq $roll)'" -Fields @('OBJECT') -RowCount 1 } catch {}
                    if (@($dk).Count) {
                        $doc=$g_dest.Repository.CreateFunction('DOCU_GET'); $doc.SetValue('ID','DE'); $doc.SetValue('LANGU',$lang); $doc.SetValue('OBJECT',$roll); $doc.Invoke($g_dest)
                        $lt=$doc.GetTable('LINE'); $sb=New-Object System.Text.StringBuilder
                        for($i=0;$i -lt [Math]::Min(60,$lt.RowCount);$i++){ $lt.CurrentIndex=$i; $line=(G $lt 'TDLINE'); if($line){ [void]$sb.Append($line + ' ') } }
                        $excerpt = ($sb.ToString() -replace '<[^>]+>','' -replace '\s+',' ').Trim(); if($excerpt.Length -gt 300){ $excerpt=$excerpt.Substring(0,300) }
                        if ($excerpt) { $hasDoc='Y'; $docCount++ }
                    }
                } catch {}
            }
            $cov = if (-not $ran) { 'COULD_NOT_CHECK' } else { 'CHECKED' }
            if ($ran) { $resolved++ } else { $cnc++ }
            $out.Add("$tab`t$fld`t$label`t$roll`t$hasDoc`t$cov`t$($excerpt -replace "[`t`r`n]",' ')")
        }
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'guide_fields.tsv'), ($out -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "FIELDS_TSV: $(Join-Path $OutDir 'guide_fields.tsv')"
        Write-Host ("DDIC: fields=$($fieldPairs.Count) resolved=$resolved could_not_check=$cnc docs=$docCount")
        Write-Host "STATUS: OK"
        try { Disconnect-SapRfc } catch {}
        exit 0
    } catch {
        Write-Host ("STATUS: RFC_ERROR detail=" + (("$($_.Exception.Message)") -replace "[`t`r`n]",' '))
        try { Disconnect-SapRfc } catch {}
        exit 2
    }
}
