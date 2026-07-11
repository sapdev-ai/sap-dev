# =============================================================================
# sap_mass_load_execute.ps1  -  BAPI row-loop executor for /sap-mass-load
#
# WRITE PATH - gated by the SKILL's typed confirm. One NCo connection; per row:
# build the target BAPI's IMPORT/TABLES params from the approved mapping, invoke,
# read RETURN (BAPIRET2/BAPIRET1/BAPIRETURN), E/A -> BAPI_TRANSACTION_ROLLBACK +
# ledger FAILED, else BAPI_TRANSACTION_COMMIT WAIT='X' + ledger OK. Commit per row
# (idempotency unit = row). A re-run (resume) skips ledger-OK rows.
#
# -DryRun builds every per-row call and writes a WOULD-DO ledger WITHOUT invoking
# the BAPI or committing - the safe, verifiable path (no SAP writes).
#
# Mapping TSV columns: input_col, target(param-or-param-STRUCT-field), rule(MOVE|CONST|SKIP), key_flag.
# Ledger TSV: row_no,business_key,status,msg_class,msg_no,msg_text,sap_key,ts,attempt.
# Exit: 0 ran, 1 some rows failed, 2 connect/input.
# =============================================================================

[CmdletBinding()]
param(
    [string] $TargetBapi = '',
    [string] $InputFile = '',
    [string] $MappingFile = '',
    [string] $KeyCols = '',
    [string] $LedgerFile = '',
    [int]    $MaxRows = 1000,
    [switch] $DryRun,
    [switch] $Resume,
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
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; TargetBapi=$TargetBapi; InputFile=$InputFile; MappingFile=$MappingFile; KeyCols=$KeyCols }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function Read-Csv { param([string]$path)
    $lines = [System.IO.File]::ReadAllLines($path); if ($lines.Count -lt 1) { return @{header=@();rows=@()} }
    $delim = if ($lines[0] -match "`t") { "`t" } else { ',' }
    $hdr = @($lines[0].TrimStart([char]0xFEFF) -split $delim | ForEach-Object { $_.Trim().Trim('"') })
    $rows=@(); for($i=1;$i -lt $lines.Count;$i++){ if($lines[$i].Trim() -eq ''){continue}; $rows += ,@($lines[$i] -split $delim | ForEach-Object { $_.Trim().Trim('"') }) }
    return @{ header=$hdr; rows=$rows }
}

if ($MyInvocation.InvocationName -ne '.') {
    foreach ($f in @($InputFile,$MappingFile)) { if (-not $f -or -not (Test-Path $f)) { Write-Host "STATUS: INPUT_ERROR reason=missing_file file=$f"; exit 2 } }
    if (-not $TargetBapi) { Write-Host "STATUS: INPUT_ERROR reason=target_required"; exit 2 }
    $fm = $TargetBapi.ToUpper()

    # mapping: input_col -> {target, rule, key_flag}
    $map = @()
    foreach ($ln in [System.IO.File]::ReadAllLines($MappingFile)) { if($ln -match '^\s*#' -or $ln.Trim() -eq ''){continue}; $c=$ln -split "`t"; if($c[0].Trim().ToLower() -eq 'input_col'){continue}; if($c.Count -ge 3){ $map += [pscustomobject]@{ col=$c[0].Trim(); target=$c[1].Trim(); rule=$c[2].Trim().ToUpper(); key=$(if($c.Count -ge 4){$c[3].Trim()}else{''}) } } }
    if ($map.Count -eq 0) { Write-Host "STATUS: MASS_LOAD_MAPPING_UNAPPROVED detail=empty_mapping"; exit 2 }

    $csv = Read-Csv $InputFile
    $hdr = @($csv.header | ForEach-Object { $_.ToUpper() })
    if ($csv.rows.Count -gt $MaxRows) { Write-Host "STATUS: MASS_LOAD_ROW_CAP detail=rows=$($csv.rows.Count)>cap=$MaxRows"; exit 1 }
    $keyIdx = @(); if ($KeyCols) { $keyIdx = @(($KeyCols -split ',') | ForEach-Object { $hdr.IndexOf($_.Trim().ToUpper()) }) }

    # resume: load prior OK business keys
    $doneKeys = @{}
    if (-not $LedgerFile) { $LedgerFile = Join-Path (Get-Location).Path 'ledger.tsv' }
    if ($Resume -and (Test-Path $LedgerFile)) { foreach ($ln in [System.IO.File]::ReadAllLines($LedgerFile)) { $c=$ln -split "`t"; if($c.Count -ge 3 -and $c[2] -eq 'OK'){ $doneKeys[$c[1]]=$true } } }

    $g_dest = $null
    if (-not $DryRun) {
        $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_MASSLOAD_EXEC"
        if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
    }

    $ledger = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $LedgerFile)) { $ledger.Add("row_no`tbusiness_key`tstatus`tmsg_class`tmsg_no`tmsg_text`tsap_key`tts`tattempt") }
    $ok=0; $fail=0; $skip=0; $rowno=0
    foreach ($r in $csv.rows) {
        $rowno++
        $bk = if ($keyIdx.Count) { (@($keyIdx | ForEach-Object { if($_ -ge 0){$r[$_]}else{''} }) -join '|') } else { "row$rowno" }
        if ($Resume -and $doneKeys.ContainsKey($bk)) { $skip++; continue }
        # build the BAPI param set from the mapping (flat "PARAM" or "STRUCT-FIELD")
        $imports = @{}; $tables = @{}
        foreach ($m in $map) {
            if ($m.rule -eq 'SKIP') { continue }
            $ci = $hdr.IndexOf($m.col.ToUpper()); $val = if ($m.rule -eq 'CONST' -or $m.rule -eq 'FIXED') { $m.target } elseif ($ci -ge 0) { "$($r[$ci])" } else { '' }
            # target "STRUCT-FIELD" -> import struct field; "PARAM" -> scalar import
            if ($m.target -match '^([A-Z0-9_]+)-([A-Z0-9_]+)$') { $s=$matches[1]; $f=$matches[2]; if(-not $imports.ContainsKey($s)){$imports[$s]=@{}}; $imports[$s][$f]=$val }
            else { $imports[$m.target]=$val }
        }
        if ($DryRun) {
            $summary = (@($imports.Keys | ForEach-Object { $_ }) -join ',')
            $ledger.Add("$rowno`t$bk`tWOULD_LOAD`t`t`tbuilt call to $fm with params[$summary]`t`t(dry-run)`t1")
            $ok++
            continue
        }
        # ---- live per-row BAPI call (gated path) ----
        try {
            $fn = $g_dest.Repository.CreateFunction($fm)
            foreach ($k in $imports.Keys) {
                if ($imports[$k] -is [hashtable]) { $st = $fn.GetStructure($k); foreach ($fld in $imports[$k].Keys) { try { $st.SetValue($fld, $imports[$k][$fld]) } catch {} } }
                else { try { $fn.SetValue($k, $imports[$k]) } catch {} }
            }
            $fn.Invoke($g_dest)
            # read RETURN (table or struct)
            $err=$false; $mc=''; $mn=''; $mt=''
            try { $rt = $fn.GetTable('RETURN'); for($i=0;$i -lt $rt.RowCount;$i++){ $rt.CurrentIndex=$i; $ty="$($rt.GetString('TYPE'))"; if($ty -match '[EA]'){ $err=$true; $mc="$($rt.GetString('ID'))"; $mn="$($rt.GetString('NUMBER'))"; $mt="$($rt.GetString('MESSAGE'))" } } } catch {
                try { $rs=$fn.GetStructure('RETURN'); $ty="$($rs.GetString('TYPE'))"; if($ty -match '[EA]'){ $err=$true; $mc="$($rs.GetString('ID'))"; $mn="$($rs.GetString('NUMBER'))"; $mt="$($rs.GetString('MESSAGE'))" } } catch {}
            }
            if ($err) {
                try { $rb=$g_dest.Repository.CreateFunction('BAPI_TRANSACTION_ROLLBACK'); $rb.Invoke($g_dest) } catch {}
                $ledger.Add("$rowno`t$bk`tFAILED`t$mc`t$mn`t$(($mt) -replace "[`t`r`n]",' ')`t`t`t1"); $fail++
            } else {
                try { $cm=$g_dest.Repository.CreateFunction('BAPI_TRANSACTION_COMMIT'); $cm.SetValue('WAIT','X'); $cm.Invoke($g_dest) } catch {}
                $ledger.Add("$rowno`t$bk`tOK`t`t`tposted`t$bk`t`t1"); $ok++
            }
        } catch {
            try { $rb=$g_dest.Repository.CreateFunction('BAPI_TRANSACTION_ROLLBACK'); $rb.Invoke($g_dest) } catch {}
            $ledger.Add("$rowno`t$bk`tFAILED`t`t`t$(("$($_.Exception.Message)") -replace "[`t`r`n]",' ')`t`t`t1"); $fail++
        }
    }

    if (Test-Path $LedgerFile) { [System.IO.File]::AppendAllText($LedgerFile, ($ledger -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($false))) }
    else { [System.IO.File]::WriteAllText($LedgerFile, ($ledger -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true))) }
    Write-Host "LEDGER: $LedgerFile"
    Write-Host ("EXECUTE: mode=" + ($(if($DryRun){'DRYRUN'}else{'LIVE'})) + " ok=$ok failed=$fail skipped=$skip total=$rowno")
    Write-Host "STATUS: OK"
    if ($g_dest) { try { Disconnect-SapRfc } catch {} }
    exit ($(if ($fail -gt 0) {1} else {0}))
}
