# =============================================================================
# sap_exit_markers.tests.ps1  -  Offline corpus for the MANUAL-marker classifier
#
# Asserts each marker kind fires once, a comment mentioning a keyword does NOT
# fire, and a write to a Z table is ALLOWED (not flagged). Run with any PowerShell.
# =============================================================================
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mk = Join-Path $here 'sap_exit_markers.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("exitmk_" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$src = @"
* This exit updates VBAK - a comment mentioning UPDATE VBAK must NOT fire
  TABLES vbak.
  DATA lv_flag TYPE c.
  lv_flag = 'X'.
  IF i_vbak-vbeln IS INITIAL.
    MESSAGE e001(zmsg) RAISING error_found.
  ENDIF.
  UPDATE vbak SET updkz = 'X' WHERE vbeln = i_vbak-vbeln.
  MODIFY zcust_tab FROM ls_row.
  SY-UCOMM = 'SAVE'.
  PERFORM my_form IN PROGRAM saplv45a.
  COMMIT WORK.
  c_do_check = 'X'.
"@
$sf = Join-Path $tmp 'zx.abap'; $of = Join-Path $tmp 'markers.tsv'
[System.IO.File]::WriteAllText($sf, $src)
& powershell -NoProfile -ExecutionPolicy Bypass -File $mk -SourceFile $sf -OutFile $of | Out-Null

$rows = @(); $lines = [System.IO.File]::ReadAllLines($of)
for ($i=1;$i -lt $lines.Count;$i++){ if($lines[$i].Trim()){ $c=$lines[$i] -split "`t"; $rows += [pscustomobject]@{ kind=$c[1]; line=$c[2] } } }
$kinds = @($rows | ForEach-Object { $_.kind })

$pass=0; $fail=0
function Check($cond,$desc){ if($cond){ $script:pass++; Write-Host "PASS  $desc" } else { $script:fail++; Write-Host "FAIL  $desc" } }
Check ($rows.Count -eq 6) "exactly 6 markers (got $($rows.Count))"
foreach ($k in 'FG_GLOBAL','MSG_RAISING','DB_WRITE','SY_WRITE','CALL_STD','COMMIT') { Check ($kinds -contains $k) "$k fired" }
Check (-not ($rows | Where-Object { $_.line -eq '1' })) "line 1 (comment 'UPDATE VBAK') NOT flagged"
Check (-not ($rows | Where-Object { $_.line -eq '9' })) "line 9 (MODIFY zcust_tab - Z table) NOT flagged"
$dbLines = @($rows | Where-Object { $_.kind -eq 'DB_WRITE' } | ForEach-Object { $_.line })
Check ($dbLines -contains '8' -and $dbLines.Count -eq 1) "DB_WRITE only on line 8 (standard UPDATE vbak), not the Z MODIFY"

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host "RESULT: pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
