# =============================================================================
# sap_sql_query_lowfi.ps1  -  Engine B (LOW-FIDELITY) for /sap-sql-query
#
# The no-deploy fallback when Z_SQL_QUERY_RO is absent AND the user declines `install`
# (PRD / security veto), or `--low-fidelity` is forced. Executes a single-table SELECT via
# RFC_READ_TABLE (its own built-in S_TABU_DIS authority check applies) with the parser's
# pushed-down field list + WHERE + row cap, and writes a TSV. Every output is banner-marked
# ENGINE=LOW_FIDELITY. Unsupported constructs (joins, aggregates, GROUP BY/HAVING) refuse
# LOUD (`SQLQ_LOWFI_UNSUPPORTED`) with a pointer to `install` Engine A -- never a silent wrong
# answer.
#
# Args: -Table <T> -Fields "<f1,f2|*>" [-Where "<clause>"] [-MaxRows 1000] [-OutTsv <path>]
# Output: SQLQ: engine=LOW_FIDELITY table=<T> rows=<n> truncated=<Y|N> ; STATUS: OK|
#         SQLQ_LOWFI_UNSUPPORTED|SQLQ_NAME_UNKNOWN|RFC_ERROR ; exit 0/1/2. 32-bit PS.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Table,
    [string] $Fields = '*',
    [string] $Where = '',
    [int]    $MaxRows = 1000,
    [string] $OutTsv = '',
    [string] $SharedDir = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { foreach ($rel in @('..\..\..\shared','..\..\..\..\sap-dev-core\shared')) { try { $c=(Resolve-Path (Join-Path $PSScriptRoot $rel) -ErrorAction Stop).Path; if ($c -and (Test-Path -LiteralPath $c)) { $SharedDir=$c; break } } catch {} } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Table=$Table; Fields=$Fields; Where=$Where; MaxRows=$MaxRows; OutTsv=$OutTsv; Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

# a lone table only: reject multi-table / aggregate / grouping loudly (Engine A territory)
if ($Table -match '[,\s]' -or $Table -match '~') { Write-Host "SQLQ: engine=LOW_FIDELITY unsupported=join (use install for Engine A)"; Write-Host "STATUS: SQLQ_LOWFI_UNSUPPORTED"; exit 1 }
if ($Fields -match '(?i)\b(COUNT|SUM|MIN|MAX|AVG)\s*\(') { Write-Host "SQLQ: engine=LOW_FIDELITY unsupported=aggregate (use install for Engine A)"; Write-Host "STATUS: SQLQ_LOWFI_UNSUPPORTED"; exit 1 }

$dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_SQLQLOWFI"
if (-not $dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

try {
    $tab = $Table.ToUpper()
    $fn = New-RfcReadTable -Destination $dest -Table $tab
    if ($MaxRows -gt 0) { [void]$fn.SetValue('ROWCOUNT', [Math]::Min($MaxRows,10000)) }
    if ($Where) { Add-RfcWhereClauses -Fn $fn -Where $Where }
    $fieldList = @()
    if ($Fields -and $Fields.Trim() -ne '*') { foreach ($f in ($Fields -split '[,\s]+' | Where-Object { $_ })) { $ff=($f -replace '.*~','').Trim().ToUpper(); if ($ff -and $ff -ne '*') { Add-RfcField $fn $ff; $fieldList += $ff } } }
    $fn.Invoke($dest)

    # resolve the emitted column order (FIELDS table) when '*' was used
    if (-not $fieldList.Count) { $ft=$fn.GetTable('FIELDS'); for ($i=0;$i -lt $ft.RowCount;$i++){ $ft.CurrentIndex=$i; $fieldList += "$($ft.GetString('FIELDNAME'))".Trim() } }
    $data = $fn.GetTable('DATA'); $rc = $data.RowCount
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# ENGINE=LOW_FIDELITY  table=$tab  where=$Where  rows=$rc")
    [void]$sb.AppendLine(($fieldList -join "`t"))
    for ($i=0;$i -lt $rc;$i++){ $data.CurrentIndex=$i; $cells = ("$($data.GetString('WA'))") -split '\|' | ForEach-Object { $_.Trim() }; [void]$sb.AppendLine(($cells -join "`t")) }
    $truncated = ($rc -ge [Math]::Min($MaxRows,10000))
    if ($OutTsv) { try { [System.IO.File]::WriteAllText($OutTsv, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true))) } catch {} }
    else { Write-Host ($sb.ToString()) }
    Write-Host ("SQLQ: engine=LOW_FIDELITY table={0} cols={1} rows={2} truncated={3}" -f $tab,$fieldList.Count,$rc,$(if($truncated){'Y'}else{'N'}))
    Write-Host "STATUS: OK"; Disconnect-SapRfc $dest; exit 0
} catch {
    $m = $_.Exception.Message
    if ($m -match 'TABLE_NOT_AVAILABLE|NOT_FOUND') { Write-Host "SQLQ: engine=LOW_FIDELITY table=$Table not_found"; Write-Host "STATUS: SQLQ_NAME_UNKNOWN"; try { Disconnect-SapRfc $dest } catch {}; exit 1 }
    Write-Host "SQLQ: error=$($m -replace '\s+',' ')"; Write-Host "STATUS: RFC_ERROR"; try { Disconnect-SapRfc $dest } catch {}; exit 2
}
