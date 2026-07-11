# =============================================================================
# sap_sql_query_exec.ps1  -  Engine A caller + helper preflight for /sap-sql-query
#
# -Action status : probe Z_SQL_QUERY_RO (TFDIR FMODE=R) + version. Absent -> the skill
#                  offers `install` (consent-gated) or `--low-fidelity` (Engine B).
# -Action exec   : call the DEPLOYED, remote-enabled Z_SQL_QUERY_RO with the parser's clause
#                  SLOTS (never a raw statement), reassemble the ET_DATA chunks by (ROWNUM,SEQ)
#                  into TSV rows. E_STATUS: S=ok A=auth/validation E=sql error.
#
# The FM is Remote-Enabled -> a DIRECT NCo call (no wrapper). Clause values come from
# sap_sql_query_parse.ps1's decomposition; the caller passes I_PRIMARY_TABLE = tables[0].
#
# Args: -Action status|exec  [-Fields -From -Where -GroupBy -Having -OrderBy -PrimaryTable
#        -MaxRows -Distinct -OutTsv] + connection params.
# Output: SQLQ:status ... | SQLQ:result rows=.. truncated=.. elapsed_ms=.. + TSV ;
#         STATUS: OK|SQLQ_HELPER_MISSING|SQLQ_AUTH_REFUSED|SQLQ_EXEC_FAILED|RFC_ERROR ; exit 0/1/2.
# 32-bit PowerShell (NCo 3.1).
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,
    [string] $Fields = '', [string] $From = '', [string] $Where = '',
    [string] $GroupBy = '', [string] $Having = '', [string] $OrderBy = '',
    [string] $PrimaryTable = '', [int] $MaxRows = 1000, [string] $Distinct = '',
    [string] $OutTsv = '', [string] $HelperFm = 'Z_SQL_QUERY_RO',
    [string] $SharedDir = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { foreach ($rel in @('..\..\..\shared','..\..\..\..\sap-dev-core\shared')) { try { $c=(Resolve-Path (Join-Path $PSScriptRoot $rel) -ErrorAction Stop).Path; if ($c -and (Test-Path -LiteralPath $c)) { $SharedDir=$c; break } } catch {} } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Action=$Action; Fields=$Fields; From=$From; Where=$Where; GroupBy=$GroupBy; Having=$Having; OrderBy=$OrderBy; PrimaryTable=$PrimaryTable; MaxRows=$MaxRows; Distinct=$Distinct; OutTsv=$OutTsv; HelperFm=$HelperFm; Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

$dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_SQLQ"
if (-not $dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

try {
    $HF = $HelperFm.ToUpper()
    $tf = Read-SapTableRows -Destination $dest -Table 'TFDIR' -Where "FUNCNAME EQ '$($HF -replace "'","''")'" -Fields @('FUNCNAME','FMODE')
    $present = (@($tf).Count -gt 0); $remote = ($present -and "$($tf[0].FMODE)".Trim() -eq 'R')

    if ($Action.ToLower() -eq 'status') {
        Write-Host ("SQLQ:status helper={0} present={1} remote_enabled={2}" -f $HF,$present,$remote)
        if (-not $present) { Write-Host "SQLQ:status hint=run `/sap-sql-query install` to deploy Engine A, or use --low-fidelity"; Write-Host "STATUS: SQLQ_HELPER_MISSING"; Disconnect-SapRfc $dest; exit 1 }
        if (-not $remote)  { Write-Host "SQLQ:status hint=helper present but not remote-enabled (dev-init step 7b sets PROCESSING_TYPE=REMOTE)"; Write-Host "STATUS: SQLQ_HELPER_MISSING"; Disconnect-SapRfc $dest; exit 1 }
        Write-Host "STATUS: OK"; Disconnect-SapRfc $dest; exit 0
    }

    # exec
    if (-not $remote) { Write-Host "SQLQ:result helper missing/not-remote"; Write-Host "STATUS: SQLQ_HELPER_MISSING"; Disconnect-SapRfc $dest; exit 1 }
    if (-not $Fields -or -not $From -or -not $PrimaryTable) { Write-Host "SQLQ:result input_error (need -Fields -From -PrimaryTable)"; Write-Host "STATUS: SQLQ_EXEC_FAILED"; Disconnect-SapRfc $dest; exit 1 }
    $fn = $dest.Repository.CreateFunction($HF)
    $fn.SetValue('I_FIELDS',$Fields); $fn.SetValue('I_FROM',$From); $fn.SetValue('I_WHERE',$Where)
    $fn.SetValue('I_GROUPBY',$GroupBy); $fn.SetValue('I_HAVING',$Having); $fn.SetValue('I_ORDERBY',$OrderBy)
    $fn.SetValue('I_PRIMARY_TABLE',$PrimaryTable.ToUpper()); $fn.SetValue('I_MAX_ROWS',[Math]::Min($MaxRows,10000))
    if ($Distinct) { $fn.SetValue('I_DISTINCT','X') }
    $fn.Invoke($dest)
    $st = "$($fn.GetString('E_STATUS'))".Trim(); $msg = "$($fn.GetString('E_MSG'))".Trim()
    $rows = 0; [void][int]::TryParse("$($fn.GetString('E_ROWCOUNT'))",[ref]$rows)
    $trunc = "$($fn.GetString('E_TRUNCATED'))".Trim(); $ms = "$($fn.GetString('E_ELAPSED_MS'))".Trim(); $ver = "$($fn.GetString('E_VERSION'))".Trim()
    if ($st -eq 'A') { Write-Host "SQLQ:result refused msg=$msg"; Write-Host "STATUS: SQLQ_AUTH_REFUSED"; Disconnect-SapRfc $dest; exit 1 }
    if ($st -eq 'E') { Write-Host "SQLQ:result sql_error msg=$msg"; Write-Host "STATUS: SQLQ_EXEC_FAILED"; Disconnect-SapRfc $dest; exit 1 }
    # reassemble ET_DATA chunks by (ROWNUM, SEQ)
    $t = $fn.GetTable('ET_DATA'); $byRow = @{}
    for ($i=0;$i -lt $t.RowCount;$i++){ $t.CurrentIndex=$i; $rn=0;[void][int]::TryParse("$($t.GetString('ROWNUM'))",[ref]$rn); $sq=0;[void][int]::TryParse("$($t.GetString('SEQ'))",[ref]$sq)
        if (-not $byRow.ContainsKey($rn)) { $byRow[$rn]=@{} }; $byRow[$rn][$sq]="$($t.GetString('CHUNK'))" }
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine("# ENGINE=HELPER $ver  rows=$rows  truncated=$trunc  elapsed_ms=$ms")
    foreach ($rn in ($byRow.Keys | Sort-Object)) { $line=New-Object System.Text.StringBuilder; foreach ($sq in ($byRow[$rn].Keys | Sort-Object)) { [void]$line.Append($byRow[$rn][$sq]) }; [void]$sb.AppendLine($line.ToString().TrimEnd()) }
    if ($OutTsv) { try { [System.IO.File]::WriteAllText($OutTsv,$sb.ToString(),(New-Object System.Text.UTF8Encoding($true))) } catch {} } else { Write-Host ($sb.ToString()) }
    Write-Host ("SQLQ:result engine=HELPER rows={0} truncated={1} elapsed_ms={2} version={3}" -f $rows,$(if($trunc){'Y'}else{'N'}),$ms,$ver)
    Write-Host "STATUS: OK"; Disconnect-SapRfc $dest; exit 0
} catch {
    Write-Host "SQLQ: error=$($_.Exception.Message -replace '\s+',' ')"; Write-Host "STATUS: RFC_ERROR"; try { Disconnect-SapRfc $dest } catch {}; exit 2
}
