# =============================================================================
# sap_mass_load_rfc.ps1  -  read-only RFC core for /sap-mass-load (plan + validate)
#
# Three read-only actions (NCo 3.1, 32-bit PS). NO writes on any path here - the
# BAPI row loop lives in sap_mass_load_execute.ps1 behind the typed confirm gate.
#
#   clientguard   T000 CCCATEGORY for the pinned client. 'P' -> MASS_LOAD_CLIENT_REFUSED
#                 (non-overridable). Read failure -> refuse (never assume non-prod).
#   interface     TFDIR FMODE gate on --target-bapi (blank -> MASS_LOAD_TARGET_UNSUPPORTED,
#                 v1.5 wrapper path) + RPY_FUNCTIONMODULE_READ_NEW param list.
#   validate      key-existence pre-check: for each -KeyChecks "COL=FIELD" pair, resolve
#                 FIELD -> (table,keyfield) from the check-tables map and confirm every
#                 distinct COL value exists; duplicate business-key detection; -> dry-run
#                 TSV + READY/BLOCKED verdict (a key lookup that can't run => BLOCKED).
#
# Exit: 0 ran, 1 refusal (client/target/blocked), 2 connect/input.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Action = 'clientguard',   # clientguard | interface | validate
    [string] $TargetBapi = '',
    [string] $InputFile = '',
    [string] $KeyCols = '',             # optional: business-key columns for dup detection (C1,C2)
    [string] $KeyChecks = '',           # "COL=FIELD,COL2=FIELD2" for existence checks
    [string] $CheckTablesFile = '',
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
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Action=$Action; TargetBapi=$TargetBapi; InputFile=$InputFile; KeyCols=$KeyCols; KeyChecks=$KeyChecks; CheckTablesFile=$CheckTablesFile }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }
function Sq { param([string]$s) return (("$s") -replace "'", "''") }

function Read-Csv {
    param([string]$path)
    $lines = [System.IO.File]::ReadAllLines($path)
    if ($lines.Count -lt 1) { return @{ header=@(); rows=@() } }
    $delim = if ($lines[0] -match "`t") { "`t" } else { ',' }
    $hdr = @($lines[0].TrimStart([char]0xFEFF) -split $delim | ForEach-Object { $_.Trim().Trim('"') })
    $rows = @()
    for ($i=1;$i -lt $lines.Count;$i++){ if($lines[$i].Trim() -eq ''){continue}; $c=@($lines[$i] -split $delim | ForEach-Object { $_.Trim().Trim('"') }); $rows += ,$c }
    return @{ header=$hdr; rows=$rows; delim=$delim }
}

if ($MyInvocation.InvocationName -ne '.') {
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_MASSLOAD"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
    $cli = if ($Client) { $Client } else { try { "$g_sapClient" } catch { '' } }
    try {
        switch ($Action.ToLower()) {
            'clientguard' {
                $t = @(); try { $t = Read-SapTableRows -Destination $g_dest -Table 'T000' -Where "MANDT EQ '$(Sq $cli)'" -Fields @('MANDT','MTEXT','CCCATEGORY') -RowCount 1 } catch {}
                if ($null -eq $t -or @($t).Count -eq 0) { Write-Host "STATUS: MASS_LOAD_CLIENT_REFUSED detail=T000_unreadable (refusing - never assume non-production)"; try { Disconnect-SapRfc } catch {}; exit 1 }
                $cat = "$($t[0].CCCATEGORY)".ToUpper()
                if ($cat -eq 'P') { Write-Host "CLIENT: mandt=$cli cat=P text=$($t[0].MTEXT)"; Write-Host "STATUS: MASS_LOAD_CLIENT_REFUSED detail=production_client (non-overridable)"; try { Disconnect-SapRfc } catch {}; exit 1 }
                Write-Host "CLIENT: mandt=$cli cat=$cat text=$($t[0].MTEXT)"; Write-Host "STATUS: OK"; try { Disconnect-SapRfc } catch {}; exit 0
            }
            'interface' {
                if (-not $TargetBapi) { Write-Host "STATUS: INPUT_ERROR reason=target_required"; try { Disconnect-SapRfc } catch {}; exit 2 }
                $fm = $TargetBapi.ToUpper()
                $tf = @(); try { $tf = Read-SapTableRows -Destination $g_dest -Table 'TFDIR' -Where "FUNCNAME EQ '$(Sq $fm)'" -Fields @('FUNCNAME','FMODE') -RowCount 1 } catch {}
                if ($null -eq $tf -or @($tf).Count -eq 0) { Write-Host "STATUS: MASS_LOAD_TARGET_UNSUPPORTED detail=fm_not_found fm=$fm"; try { Disconnect-SapRfc } catch {}; exit 1 }
                $fmode = "$($tf[0].FMODE)"
                if ($fmode -ne 'R') { Write-Host "INTERFACE: fm=$fm fmode='$fmode'"; Write-Host "STATUS: MASS_LOAD_TARGET_UNSUPPORTED detail=not_remote_enabled (v1.5 wrapper path); FMODE='$fmode'"; try { Disconnect-SapRfc } catch {}; exit 1 }
                # param list via RPY_FUNCTIONMODULE_READ_NEW
                $out = New-Object System.Collections.Generic.List[string]; $out.Add("param`tclass`ttypename`toptional`tdefault")
                try {
                    $rp = $g_dest.Repository.CreateFunction('RPY_FUNCTIONMODULE_READ_NEW'); $rp.SetValue('FUNCTIONNAME',$fm); $rp.Invoke($g_dest)
                    foreach ($tab in @(@{t='IMPORT_PARAMETER';c='I'},@{t='EXPORT_PARAMETER';c='E'},@{t='TABLES_PARAMETER';c='T'},@{t='CHANGING_PARAMETER';c='C'})) {
                        try { $pt = $rp.GetTable($tab.t); for($i=0;$i -lt $pt.RowCount;$i++){ $pt.CurrentIndex=$i; $pn=''; $tn=''; $opt=''; $df=''
                              try{$pn="$($pt.GetString('PARAMETER'))".Trim()}catch{}; foreach($tc in 'DBFIELD','REF_TYPE','STRUCTURE','TYP'){try{$v="$($pt.GetString($tc))".Trim(); if($v -and -not $tn){$tn=$v}}catch{}}
                              try{$opt="$($pt.GetString('OPTIONAL'))".Trim()}catch{}; try{$df="$($pt.GetString('DEFAULT_VALUE'))".Trim()}catch{}
                              if($pn){ $out.Add("$pn`t$($tab.c)`t$tn`t$opt`t$df") } } } catch {}
                    }
                } catch { Write-Host ("WARN: RPY read failed: " + (("$($_.Exception.Message)") -replace "[`t`r`n]",' ')) }
                if (-not $OutFile) { $OutFile = Join-Path (Get-Location).Path ($fm.ToLower()+'_interface.tsv') }
                [System.IO.File]::WriteAllText($OutFile, ($out -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
                Write-Host "INTERFACE_TSV: $OutFile"
                Write-Host ("INTERFACE: fm=$fm fmode=R params=$($out.Count-1)")
                Write-Host "STATUS: OK"; try { Disconnect-SapRfc } catch {}; exit 0
            }
            'validate' {
                if (-not $InputFile -or -not (Test-Path $InputFile)) { Write-Host "STATUS: INPUT_ERROR reason=input_missing"; try { Disconnect-SapRfc } catch {}; exit 2 }
                # check-tables map: FIELD -> TABLE,KEYFIELD
                $ctmap = @{}
                if ($CheckTablesFile -and (Test-Path $CheckTablesFile)) { foreach ($ln in [System.IO.File]::ReadAllLines($CheckTablesFile)) { if($ln -match '^\s*#' -or $ln.Trim() -eq ''){continue}; $c=$ln -split "`t"; if($c.Count -ge 3 -and $c[0].Trim().ToUpper() -ne 'FIELD'){ $ctmap[$c[0].Trim().ToUpper()] = @{ table=$c[1].Trim(); key=$c[2].Trim() } } } }
                $csv = Read-Csv $InputFile
                $hdr = @($csv.header | ForEach-Object { $_.ToUpper() })
                $findings = New-Object System.Collections.Generic.List[string]; $findings.Add("check`tresult`tdetail")
                $blocked = $false
                # duplicate business keys
                if ($KeyCols) {
                    $kc = @($KeyCols -split ',' | ForEach-Object { $_.Trim().ToUpper() })
                    $idx = @($kc | ForEach-Object { $hdr.IndexOf($_) })
                    if ($idx -contains -1) { $findings.Add("dup_keys`tCOULD_NOT_CHECK`tkey column not in header"); $blocked=$true }
                    else { $seen=@{}; $dups=0; foreach($r in $csv.rows){ $bk=($idx | ForEach-Object { $r[$_] }) -join '|'; if($seen.ContainsKey($bk)){$dups++}else{$seen[$bk]=$true} }
                           $findings.Add("dup_keys`t$(if($dups -gt 0){'BLOCKER'}else{'OK'})`t$dups duplicate business key(s)"); if($dups -gt 0){$blocked=$true} }
                }
                # key existence checks
                foreach ($pair in @($KeyChecks -split ',' | Where-Object { $_ -match '=' })) {
                    $col,$fld = $pair -split '=',2; $col=$col.Trim().ToUpper(); $fld=$fld.Trim().ToUpper()
                    $ci = $hdr.IndexOf($col)
                    if ($ci -lt 0) { $findings.Add("key_$col`tCOULD_NOT_CHECK`tcolumn not in input"); continue }
                    if (-not $ctmap.ContainsKey($fld)) { $findings.Add("key_$col`tCOULD_NOT_CHECK`tno check table for field $fld"); continue }
                    $tbl=$ctmap[$fld].table; $keyf=$ctmap[$fld].key
                    $vals = @($csv.rows | ForEach-Object { "$($_[$ci])".Trim() } | Where-Object { $_ } | Select-Object -Unique)
                    $missing = @()
                    foreach ($v in $vals) {
                        $r = $null; try { $r = Read-SapTableRows -Destination $g_dest -Table $tbl -Where "$keyf EQ '$(Sq $v)'" -Fields @($keyf) -RowCount 1 } catch { $r = $null }
                        if ($null -eq $r) { $findings.Add("key_$col`tCOULD_NOT_CHECK`t$tbl read failed (auth?) - dry-run BLOCKED"); $blocked=$true; $missing=@(); break }
                        if (@($r).Count -eq 0) { $missing += $v }
                    }
                    if ($missing.Count -gt 0) { $findings.Add("key_$col`tBLOCKER`t$($missing.Count) $col value(s) not in $tbl : $((@($missing)|Select-Object -First 8) -join ',')"); $blocked=$true }
                    elseif (@($findings | Where-Object { $_ -like "key_$col`t*" }).Count -eq 0) { $findings.Add("key_$col`tOK`tall $($vals.Count) distinct $col value(s) exist in $tbl") }
                }
                if (-not $OutFile) { $OutFile = Join-Path (Get-Location).Path 'dryrun_report.tsv' }
                [System.IO.File]::WriteAllText($OutFile, ($findings -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
                Write-Host "DRYRUN_TSV: $OutFile"
                Write-Host ("VALIDATE: rows=$($csv.rows.Count) verdict=" + ($(if ($blocked) {'BLOCKED'} else {'READY'})))
                Write-Host "STATUS: OK"; try { Disconnect-SapRfc } catch {}; exit ($(if ($blocked) {1} else {0}))
            }
            default { Write-Host "STATUS: INPUT_ERROR reason=unknown_action"; try { Disconnect-SapRfc } catch {}; exit 2 }
        }
    } catch {
        Write-Host ("STATUS: RFC_ERROR detail=" + (("$($_.Exception.Message)") -replace "[`t`r`n]",' '))
        try { Disconnect-SapRfc } catch {}; exit 2
    }
}
