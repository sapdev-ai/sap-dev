# Offline injection/acceptance corpus for sap_sql_query_parse.ps1 (no SAP). Run:
#   powershell -File sap_sql_query_parse.tests.ps1
# Exit 0 = all pass, 1 = at least one mismatch.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$parser = Join-Path $PSScriptRoot 'sap_sql_query_parse.ps1'
$ps32 = 'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $ps32)) { $ps32 = 'powershell' }

$cases = @(
    # --- ACCEPT (valid read-only SELECT) ---
    @{ e='ACCEPT'; s="SELECT matnr mtart FROM mara WHERE mtart = 'FERT'" }
    @{ e='ACCEPT'; s="SELECT SINGLE mbrsh FROM mara WHERE matnr = 'M1'" }
    @{ e='ACCEPT'; s="SELECT a~vbeln b~posnr FROM vbak AS a INNER JOIN vbap AS b ON a~vbeln = b~vbeln WHERE a~vkorg = '1000'" }
    @{ e='ACCEPT'; s="SELECT COUNT(*) FROM vbap GROUP BY matnr" }
    @{ e='ACCEPT'; s="SELECT kunnr name1 FROM kna1 WHERE land1 IN ('DE','US') ORDER BY kunnr DESC" }
    @{ e='ACCEPT'; s="SELECT matnr FROM mara WHERE ernam = 'O''BRIEN'" }              # doubled-quote escape
    @{ e='ACCEPT'; s="SELECT DISTINCT werks FROM marc WHERE lvorm = ' '" }
    @{ e='ACCEPT'; s="SELECT matnr SUM( labst ) FROM mard GROUP BY matnr HAVING SUM( labst ) > 0" }
    # --- REJECT (injection / write / escape attempts) ---
    @{ e='REJECT'; s="SELECT * FROM mara; DELETE FROM mara" }                          # SEMICOLON
    @{ e='REJECT'; s="SELECT * FROM mara UNION SELECT * FROM marc" }                   # UNION
    @{ e='REJECT'; s="SELECT * FROM ( SELECT matnr FROM mara )" }                      # SUBQUERY
    @{ e='REJECT'; s="SELECT * FROM mara INTO TABLE lt_data" }                         # INTO
    @{ e='REJECT'; s="UPDATE mara SET pstat = 'X'" }                                   # UPDATE / NOT_SELECT
    @{ e='REJECT'; s="SELECT * FROM mara FOR ALL ENTRIES IN lt_keys WHERE matnr = lt_keys-matnr" } # FAE
    @{ e='REJECT'; s="SELECT * FROM mara CLIENT SPECIFIED" }                           # CLIENT SPECIFIED
    @{ e='REJECT'; s="SELECT * FROM mara WHERE mandt = '100'" }                        # MANDT
    @{ e='REJECT'; s="SELECT * FROM mara BYPASSING BUFFER" }                           # BYPASSING BUFFER
    @{ e='REJECT'; s="SELECT * FROM mara UP TO 100 ROWS" }                             # caller UP TO
    @{ e='REJECT'; s=("SELECT * FROM mara WHERE matnr = 'x' " + [char]96) }            # backquote
    @{ e='REJECT'; s="SELECT * FROM mara WHERE matnr = @lv_x" }                        # host variable
    @{ e='REJECT'; s="SELECT * FROM mara WHERE matnr = X'00A1'" }                      # hex literal
    @{ e='REJECT'; s="SELECT * FROM mara CONNECTION mycon" }                           # CONNECTION
    @{ e='REJECT'; s="DROP TABLE mara" }                                              # DDL / not select
    @{ e='REJECT'; s='SELECT * FROM mara WHERE x = 1 " sneaky' }                       # double-quote comment
    @{ e='REJECT'; s="SELECT matnr FROM mara WHERE ernam = 'unbalanced" }              # unbalanced quote
    @{ e='REJECT'; s="SELECT * FROM mara WHERE exists = 1 AND 1=1 OR ROLLBACK" }       # TX token
)

$tmp = Join-Path $env:TEMP ("sqlqcase_" + [System.Guid]::NewGuid().ToString('N') + ".sql")
$pass=0; $fail=0
foreach ($c in $cases) {
    [System.IO.File]::WriteAllText($tmp, $c.s, (New-Object System.Text.UTF8Encoding($false)))   # -SqlFile preserves " and `
    $out = & $ps32 -NoProfile -ExecutionPolicy Bypass -File $parser -SqlFile $tmp 2>&1
    $verdict = if (($out | Out-String) -match 'verdict=(ACCEPT|REJECT)') { $Matches[1] } else { 'ERROR' }
    if ($verdict -eq $c.e) { $pass++; Write-Host ("PASS  [{0}] {1}" -f $c.e, ($c.s.Substring(0,[Math]::Min(58,$c.s.Length)))) }
    else { $fail++; $reason = if (($out | Out-String) -match 'reason=(\S+)') { $Matches[1] } else { '' }
        Write-Host ("FAIL  want={0} got={1} ({2}) :: {3}" -f $c.e,$verdict,$reason,$c.s) }
}
Write-Host ("--- sql-query parser corpus: pass={0} fail={1} ---" -f $pass,$fail)
if ($fail -gt 0) { exit 1 }
