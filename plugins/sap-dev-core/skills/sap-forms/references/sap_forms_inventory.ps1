# =============================================================================
# sap_forms_inventory.ps1  -  forms inventory for /sap-forms (READ-ONLY, RFC)
#
# Inventories SmartForms (STXFADM), SAPscript (TADIR OBJECT='FORM'), and Adobe
# (TADIR SFPF) with namespace/package filters, overlays TNAPR output-determination
# assignment (KAPPL/KSCHL/NACHA/driver/routine), and (optionally) NAST usage counts
# in a date window -> forms_inventory.tsv (feeds sap-cc scope). Pure RFC reads.
#
# TNAPR's form-name columns vary by release, so the field list is derived from
# DD03L first (no hardcoded SFORM). A NAST read that fails/caps -> the usage column
# is COULD_NOT_CHECK / '>=N (capped)', never rendered as "unused".
#
# Emits FORM: type=<..> name=<..> ... lines + the TSV. Exit 0 ran, 2 connect.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Type = 'all',            # all | smartforms | sapscript | adobe
    [string] $Namespace = 'Z,Y',       # comma list of leading chars/prefixes; '*'=all
    [switch] $All,
    [string] $Packages = '',           # comma list of package prefixes
    [int]    $UsageDays = 180,
    [switch] $NoUsage,
    [int]    $MaxUsageScan = 20000,
    [string] $OutFile = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\shared')).Path } catch { $SharedDir = '' } }
if (-not (Test-Path (Join-Path $SharedDir 'scripts'))) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch {} }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Type=$Type; Namespace=$Namespace; Packages=$Packages }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }
function Sq { param([string]$s) return (("$s") -replace "'", "''") }

$nsList = if ($All -or $Namespace -eq '*') { @() } else { @($Namespace -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }) }
$pkgList = @($Packages -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
function NsOk { param([string]$name) if ($nsList.Count -eq 0) { return $true }; foreach ($p in $nsList) { if ("$name".ToUpper().StartsWith($p)) { return $true } }; return $false }
function PkgOk { param([string]$pkg) if ($pkgList.Count -eq 0) { return $true }; foreach ($p in $pkgList) { if ("$pkg".ToUpper().StartsWith($p)) { return $true } }; return $false }

if ($MyInvocation.InvocationName -ne '.') {
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_FORMS_INV"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
    try {
        $forms = @()   # {type,name,package,master_lang,short_text}
        $doSF = ($Type -in @('all','smartforms')); $doSC = ($Type -in @('all','sapscript')); $doAD = ($Type -in @('all','adobe'))

        if ($doSF) {
            $sf = Read-SapTableRows -Destination $g_dest -Table 'STXFADM' -Where "" -Fields @('FORMNAME','MASTERLANG','DEVCLASS') -RowCount 20000
            foreach ($r in $sf) { $nm="$($r.FORMNAME)"; if (-not $nm) { continue }; if ((NsOk $nm) -and (PkgOk "$($r.DEVCLASS)")) { $forms += [pscustomobject]@{ type='smartform'; name=$nm; package="$($r.DEVCLASS)"; master_lang="$($r.MASTERLANG)"; short_text='' } } }
        }
        if ($doSC) {
            $sc = Read-SapTableRows -Destination $g_dest -Table 'TADIR' -Where "PGMID EQ 'R3TR' AND OBJECT EQ 'FORM'" -Fields @('OBJ_NAME','DEVCLASS') -RowCount 20000
            foreach ($r in $sc) { $nm="$($r.OBJ_NAME)"; if (-not $nm) { continue }; if ((NsOk $nm) -and (PkgOk "$($r.DEVCLASS)")) { $forms += [pscustomobject]@{ type='sapscript'; name=$nm; package="$($r.DEVCLASS)"; master_lang=''; short_text='' } } }
        }
        if ($doAD) {
            $ad = Read-SapTableRows -Destination $g_dest -Table 'TADIR' -Where "PGMID EQ 'R3TR' AND OBJECT EQ 'SFPF'" -Fields @('OBJ_NAME','DEVCLASS') -RowCount 20000
            foreach ($r in $ad) { $nm="$($r.OBJ_NAME)"; if (-not $nm) { continue }; if ((NsOk $nm) -and (PkgOk "$($r.DEVCLASS)")) { $forms += [pscustomobject]@{ type='adobe'; name=$nm; package="$($r.DEVCLASS)"; master_lang=''; short_text='' } } }
        }

        # ---- TNAPR overlay: form-name columns derived from DD03L ----
        $tnaprFormCols = @('FONAM','FONAM2','FONAM3','FONAM4','SFORM')
        $exist = @{}
        try { $dc = Read-SapTableRows -Destination $g_dest -Table 'DD03L' -Where "TABNAME EQ 'TNAPR' AND AS4LOCAL EQ 'A'" -Fields @('FIELDNAME') -RowCount 300; foreach ($x in $dc) { $exist["$($x.FIELDNAME)".ToUpper()]=$true } } catch {}
        $formCols = @($tnaprFormCols | Where-Object { $exist.ContainsKey($_) }); if ($formCols.Count -eq 0) { $formCols = @('FONAM') }
        $tnaprIdx = @{}   # formname(upper) -> list of {kappl,kschl,nacha,pgnam,ronam}
        try {
            $readCols = @('KAPPL','KSCHL','NACHA','PGNAM','RONAM') + $formCols
            $tn = Read-SapTableRows -Destination $g_dest -Table 'TNAPR' -Where "" -Fields $readCols -RowCount 50000
            foreach ($r in $tn) {
                foreach ($fc in $formCols) { $fn = "$($r.$fc)".Trim().ToUpper(); if ($fn) { if (-not $tnaprIdx.ContainsKey($fn)) { $tnaprIdx[$fn]=@() }; $tnaprIdx[$fn] += [pscustomobject]@{ kappl="$($r.KAPPL)"; kschl="$($r.KSCHL)"; nacha="$($r.NACHA)"; pgnam="$($r.PGNAM)"; ronam="$($r.RONAM)" } } }
            }
        } catch {}

        # ---- NAST usage (optional) ----
        $usageCov = 'CHECKED'
        $sinceDate = ''
        if (-not $NoUsage) {
            try { $sinceDate = (Get-Date).AddDays(-1 * $UsageDays).ToString('yyyyMMdd') } catch { $sinceDate = '' }
        }

        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("form_type`tname`tpackage`tmaster_lang`toutput_types`tchannels`tdriver_program`troutine`tusage_count`tcoverage")
        $emitted = 0
        foreach ($f in ($forms | Sort-Object type,name)) {
            $tnrows = if ($tnaprIdx.ContainsKey($f.name.ToUpper())) { $tnaprIdx[$f.name.ToUpper()] } else { @() }
            $otypes = (@($tnrows | ForEach-Object { "$($_.kappl)/$($_.kschl)" } | Select-Object -Unique) -join '|')
            $chan = (@($tnrows | ForEach-Object { "$($_.nacha)" } | Where-Object { $_ } | Select-Object -Unique) -join ',')
            $drv = (@($tnrows | ForEach-Object { "$($_.pgnam)" } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 1))
            $rou = (@($tnrows | ForEach-Object { "$($_.ronam)" } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 1))
            # usage: count NAST for the (kappl,kschl) pairs since window (per-pair, capped)
            $usage = ''; $cov = 'CHECKED'
            if (-not $NoUsage -and $tnrows.Count -gt 0 -and $sinceDate) {
                $total = 0; $capped = $false
                foreach ($pair in @($tnrows | ForEach-Object { "$($_.kappl)|$($_.kschl)" } | Select-Object -Unique)) {
                    $ka,$ks = $pair -split '\|'
                    try { $nr = Read-SapTableRows -Destination $g_dest -Table 'NAST' -Where "KAPPL EQ '$(Sq $ka)' AND KSCHL EQ '$(Sq $ks)' AND ERDAT GE '$sinceDate'" -Fields @('KAPPL') -RowCount $MaxUsageScan
                          $c = @($nr).Count; if ($null -eq $nr) { $cov='COULD_NOT_CHECK'; break }; if ($c -ge $MaxUsageScan) { $capped=$true }; $total += $c } catch { $cov='COULD_NOT_CHECK'; break }
                }
                if ($cov -eq 'CHECKED') { $usage = if ($capped) { ">=$total (capped)" } else { "$total" } }
            } elseif ($NoUsage) { $usage = '(--no-usage)' } elseif ($tnrows.Count -eq 0) { $usage = '0 (not in TNAPR)' }
            $out.Add("$($f.type)`t$($f.name)`t$($f.package)`t$($f.master_lang)`t$otypes`t$chan`t$drv`t$rou`t$usage`t$cov")
            Write-Host ("FORM: type=$($f.type) name=$($f.name) pkg=$($f.package) outputs=$($otypes.Length -gt 0) usage=$usage cov=$cov")
            $emitted++
            if ($emitted -ge 500) { Write-Host "INFO: output capped at 500 rows (narrow with --namespace/--packages)"; break }
        }
        if (-not $OutFile) { $OutFile = Join-Path (Get-Location).Path 'forms_inventory.tsv' }
        [System.IO.File]::WriteAllText($OutFile, ($out -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "INVENTORY_TSV: $OutFile"
        Write-Host ("INVENTORY: forms=$($forms.Count) emitted=$emitted smartforms=" + @($forms|Where-Object{$_.type -eq 'smartform'}).Count + " sapscript=" + @($forms|Where-Object{$_.type -eq 'sapscript'}).Count + " adobe=" + @($forms|Where-Object{$_.type -eq 'adobe'}).Count)
        Write-Host "STATUS: OK"
        try { Disconnect-SapRfc } catch {}
        exit 0
    } catch {
        Write-Host ("STATUS: RFC_ERROR detail=" + (("$($_.Exception.Message)") -replace "[`t`r`n]",' '))
        try { Disconnect-SapRfc } catch {}
        exit 2
    }
}
