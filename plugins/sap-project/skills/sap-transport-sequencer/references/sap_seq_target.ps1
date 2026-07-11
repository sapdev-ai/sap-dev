# =============================================================================
# sap_seq_target.ps1  -  target-system cross-check for /sap-transport-sequencer (RFC)
#
# With `sequence --target <profile>`, connects the named TARGET profile (read-only,
# the /sap-login second-profile pattern) and answers two questions the source system
# can't:
#   1. Predecessor candidates (external released TRs touching a listed object) -- is
#      each already IMPORTED in the target? E070 row present = imported; absent =
#      UNIMPORTED_PREDECESSOR (HIGH).
#   2. Listed R3TR objects -- do they already exist in the target (TADIR)? Absent =
#      FIRST_TIME_DELIVERY (informational, feeds the narrative).
#
# READ-ONLY (E070 + TADIR, FMODE=R). Never imports.
#
#   -Against <profile-hint> -ObjectsTsv <path> -OverlapsTsv <path> -OutDir <dir>
#
# stdout:
#   TARGET: sid=<..> client=<..>
#   PRED: tr=<..> imported=<Y|N>
#   STATUS: OK | SEQ_TARGET_UNREACHABLE | RFC_ERROR
# Exit: 0 OK | 2 target unreachable / RFC failure.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Against     = '',
    [string] $ObjectsTsv  = '',
    [string] $OverlapsTsv = '',
    [string] $OutDir      = '',
    [string] $SharedDir   = '',
    [string] $RunId       = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }
function Read-Tsv { param([string]$p)
    if (-not (Test-Path $p)) { return @() }
    $txt = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    $lines = $txt -split "`r`n|`n|`r" | Where-Object { $_ -ne '' }
    if ($lines.Count -lt 1) { return @() }
    $head = $lines[0] -split "`t"; $rows = @()
    for ($i=1; $i -lt $lines.Count; $i++) { $c = $lines[$i] -split "`t"; $r = [ordered]@{}; for ($j=0;$j -lt $head.Count;$j++){ $r[$head[$j]] = if ($j -lt $c.Count) { $c[$j] } else { '' } }; $rows += ,([pscustomobject]$r) }
    return $rows
}
function Write-Tsv { param([string]$Path,[string]$Header,[object[]]$Lines)
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}
# batched OR-chunked read (RFC_READ_TABLE has no IN)
function Read-InSet { param($d,[string]$table,[string]$keyField,[string[]]$keys,[string[]]$fields)
    $out = @()
    for ($i=0; $i -lt $keys.Count; $i += 30) {
        $chunk = $keys[$i..([Math]::Min($i+29,$keys.Count-1))]
        $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; [void]$fn.SetValue('ROWCOUNT',20000)
        $line = ''
        for ($k=0; $k -lt $chunk.Count; $k++) { $pred="$keyField = '"+($chunk[$k] -replace "'","''")+"'"; $piece= if($k -eq 0){$pred}else{"OR $pred"}; if($line -eq ''){$line=$piece}elseif(($line.Length+1+$piece.Length)-le 72){$line="$line $piece"}else{Add-RfcOption $fn $line;$line=$piece} }
        if ($line) { Add-RfcOption $fn $line }
        foreach ($f in $fields) { Add-RfcField $fn $f }
        if (-not (Invoke-Rfc $fn $d)) { continue }
        $fm = $fn.GetTable('FIELDS'); $off=@{}; $len=@{}; for ($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
        $dt = $fn.GetTable('DATA'); for ($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).TrimEnd()}else{''}};$out+=,([pscustomobject]$rec)}
    }
    return $out
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Against -or -not $OutDir) { Write-Host 'STATUS: RFC_ERROR bad_args'; exit 2 }

$cands = @(Resolve-SapProfileHint -Hint $Against)
if ($cands.Count -ne 1) { Write-Host "STATUS: SEQ_TARGET_UNREACHABLE against=$Against ambiguous_or_missing"; exit 2 }
$t = $cands[0]
$pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($t.password_dpapi)" 2>$null) -as [string]
$tgt = $null; try { $tgt = Connect-SapRfc -Server $t.application_server -Sysnr $t.system_number -MessageServer $t.message_server -LogonGroup $t.logon_group -SystemID $t.system_id -Client $t.client -User $t.user -Password $pw -Language $t.language -DestName 'SEQ_TGT' } catch { }
if (-not $tgt) { Write-Host "STATUS: SEQ_TARGET_UNREACHABLE against=$Against"; exit 2 }

try {
    $sid=''; try { $fn=$tgt.Repository.CreateFunction('RFC_SYSTEM_INFO'); $fn.Invoke($tgt); $sid=(San $fn.GetStructure('RFCSI_EXPORT').GetValue('RFCSYSID')) } catch { }
    Write-Host ("TARGET: sid=$sid client=$($t.client)")

    # predecessor candidates from overlaps.tsv (external released TRs)
    $ov = @(Read-Tsv $OverlapsTsv)
    $preds = @($ov | Where-Object { $_.ext_status -eq 'R' -or $_.ext_status -eq 'O' } | ForEach-Object { $_.ext_trkorr } | Sort-Object -Unique)
    $lines = @()
    if ($preds.Count) {
        $present = @{}; $hit = Read-InSet $tgt 'E070' 'TRKORR' $preds @('TRKORR','TRSTATUS'); foreach ($h in @($hit)) { $present[(San $h.TRKORR)] = $true }
        foreach ($p in $preds) { $imp = $present.ContainsKey($p); Write-Host ("PRED: tr=$p imported=$(if($imp){'Y'}else{'N'})"); $lines += ("predecessor`t$p`t$(if($imp){'IMPORTED'}else{'UNIMPORTED'})`t") }
    }

    # first-time delivery: listed R3TR objects absent from target TADIR
    $objs = @(Read-Tsv $ObjectsTsv)
    $r3 = @($objs | Where-Object { $_.orig_pgmid -eq 'R3TR' } | ForEach-Object { "$($_.orig_object)|$($_.orig_name)" } | Sort-Object -Unique)
    $ftCount = 0
    if ($r3.Count) {
        # probe TADIR per distinct object name (batched by OBJ_NAME)
        $names = @($r3 | ForEach-Object { ($_ -split '\|',2)[1] } | Sort-Object -Unique)
        $present = @{}; $hit = Read-InSet $tgt 'TADIR' 'OBJ_NAME' $names @('OBJECT','OBJ_NAME'); foreach ($h in @($hit)) { $present["$(San $h.OBJECT)|$(San $h.OBJ_NAME)"] = $true }
        foreach ($k in $r3) { if (-not $present.ContainsKey($k)) { $ftCount++; $lines += ("first_time`t$k`tNOT_IN_TARGET`t") } }
    }
    Write-Tsv (Join-Path $OutDir 'target_check.tsv') "kind`tsubject`tstatus`tnote" $lines
    $unimp = @($lines | Where-Object { $_ -match 'UNIMPORTED' }).Count
    Write-Host ("STATUS: OK target=$sid predecessors=$($preds.Count) unimported=$unimp first_time=$ftCount")
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
