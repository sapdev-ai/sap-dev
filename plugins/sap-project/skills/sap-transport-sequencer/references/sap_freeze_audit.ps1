# =============================================================================
# sap_freeze_audit.ps1  -  code-freeze window audit for /sap-transport-sequencer (RFC)
#
# Detect-only (never enforces). One windowed E070 pass finds TRs released or changed
# inside a freeze window, minus policy exceptions (TRs / users / packages), with
# per-violation object inventory + VRSD materiality evidence. E070 stores no creation
# date, so AS4DATE is last-change/release date -- stated honestly; VRSD is the
# authoritative "the object really changed in-window" proof.
#
#   -From YYYYMMDD -To YYYYMMDD -PolicyJson <path|''> -OutDir <dir>
#
# stdout:
#   FREEZE: window=<from>..<to> released=<n> changed=<n> exempt=<n> violations=<n>
#   VIOLATION: tr=<..> kind=<RELEASED|CHANGED> user=<..> vrsd=<n>
#   STATUS: OK | FREEZE_WINDOW_UNBOUNDED | FREEZE_POLICY_INVALID | RFC_ERROR
# Exit: 0 OK | 1 policy/window refusal | 2 connect/RFC failure.
# =============================================================================

[CmdletBinding()]
param(
    [string] $From       = '',
    [string] $To         = '',
    [string] $PolicyJson = '',
    [string] $OutDir     = '',
    [string] $SharedDir  = '',
    [string] $SkillDir   = '',
    [string] $RunId      = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
if (-not $SkillDir) { $SkillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
. (Join-Path $PSScriptRoot 'sap_seq_vrsd.ps1')
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }
function Write-Tsv { param([string]$Path,[string]$Header,[object[]]$Lines)
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}
function Read-Where { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''; [void]$fn.SetValue('ROWCOUNT',$max)
    # split where at ' AND ' into <=72-char OPTIONS rows
    $line=''; foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }
    if ($line) { Add-RfcOption $fn $line }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).TrimEnd()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: RFC_ERROR no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# ---- resolve policy (CLI --from/--to override the policy window) --------------
$exTr = @(); $exUser = @(); $exPkg = @()
if ($PolicyJson -and (Test-Path $PolicyJson)) {
    try { $pol = Get-Content -Raw -Encoding UTF8 $PolicyJson | ConvertFrom-Json } catch { Write-Host 'STATUS: FREEZE_POLICY_INVALID parse'; exit 1 }
    if (-not $From -and $pol.window) { $From = "$($pol.window.from)" }
    if (-not $To -and $pol.window) { $To = "$($pol.window.to)" }
    if ($pol.exceptions) { $exTr=@($pol.exceptions.trkorr); $exUser=@($pol.exceptions.users | ForEach-Object { "$_".ToUpper() }); $exPkg=@($pol.exceptions.packages | ForEach-Object { "$_".ToUpper() }) }
}
if (-not $From -or -not $To) { Write-Host 'STATUS: FREEZE_WINDOW_UNBOUNDED both_bounds_required'; exit 1 }
if ($From -notmatch '^\d{8}$' -or $To -notmatch '^\d{8}$') { Write-Host 'STATUS: FREEZE_POLICY_INVALID date_format'; exit 1 }
try { $d1=[datetime]::ParseExact($From,'yyyyMMdd',$null); $d2=[datetime]::ParseExact($To,'yyyyMMdd',$null) } catch { Write-Host 'STATUS: FREEZE_POLICY_INVALID date'; exit 1 }
if (($d2-$d1).Days -gt 92 -or ($d2-$d1).Days -lt 0) { Write-Host "STATUS: FREEZE_WINDOW_UNBOUNDED days=$(($d2-$d1).Days) max=92"; exit 1 }

$dest = $null; try { $dest = Connect-SapRfc -DestName 'SEQ_FRZ' } catch { }
if (-not $dest) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    # windowed E070 by last-change date
    $rows = @(Read-Where $dest 'E070' "AS4DATE GE '$From' AND AS4DATE LE '$To'" @('TRKORR','TRFUNCTION','TRSTATUS','AS4USER','AS4DATE','AS4TIME') 20000)
    # VRSD materiality for the whole window, grouped by TR
    $vrsd = @(Get-VrsdInWindow -Dest $dest -From $From -To $To -Max 20000)
    $vByTr = @{}; foreach ($vr in $vrsd) { $k=$vr.korrnum; if ($k) { if (-not $vByTr.ContainsKey($k)) { $vByTr[$k]=0 }; $vByTr[$k]++ } }

    $rel=0; $chg=0; $exempt=0; $vLines=@(); $findings=@()
    foreach ($r in $rows) {
        $tr=San $r.TRKORR; $st=San $r.TRSTATUS; $usr=San $r.AS4USER
        $isRel = ($st -eq 'R' -or $st -eq 'O'); $isChg = ($st -eq 'D' -or $st -eq 'L')
        if (-not $isRel -and -not $isChg) { continue }
        if ($isRel) { $rel++ } else { $chg++ }
        # exceptions
        if ($exTr -contains $tr) { $exempt++; continue }
        if ($exUser -contains $usr.ToUpper()) { $exempt++; continue }
        if ($exPkg.Count) {
            $objs = @(Read-Where $dest 'E071' "TRKORR = '$tr' AND PGMID = 'R3TR'" @('OBJ_NAME') 200)
            $names = @($objs | ForEach-Object { San $_.OBJ_NAME } | Where-Object { $_ } | Sort-Object -Unique)
            if ($names.Count) {
                $pkgHit = $false
                foreach ($nm in $names) { $td = @(Read-Where $dest 'TADIR' "OBJ_NAME = '$nm'" @('DEVCLASS') 1); if (@($td).Count -and ($exPkg -contains (San $td[0].DEVCLASS).ToUpper())) { $pkgHit=$true; break } }
                if ($pkgHit) { $exempt++; continue }
            }
        }
        $vn = if ($vByTr.ContainsKey($tr)) { $vByTr[$tr] } else { 0 }
        $kind = if ($isRel) { 'RELEASED' } else { 'CHANGED' }
        $sev = if ($isRel) { 'HIGH' } else { 'MEDIUM' }
        $vLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $sev,$kind,$tr,$usr,(San $r.AS4DATE),(San $r.AS4TIME),$vn)
        Write-Host ("VIOLATION: tr=$tr kind=$kind user=$usr vrsd=$vn")
    }
    Write-Tsv (Join-Path $OutDir 'violations.tsv') "severity`tkind`ttrkorr`tuser`tas4date`tas4time`tvrsd_versions" $vLines
    Write-Host ("FREEZE: window=$From..$To released=$rel changed=$chg exempt=$exempt violations=$($vLines.Count)")
    Write-Host 'STATUS: OK'
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
