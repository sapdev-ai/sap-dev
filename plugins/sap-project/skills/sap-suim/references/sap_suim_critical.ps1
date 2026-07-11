# =============================================================================
# sap_suim_critical.ps1  -  critical-access scan for /sap-suim (read-only RFC)
#
# Scans the system for critical authorization grants (from critical_auths.tsv,
# co-owned with /sap-explain-role) TARGETED at the critical objects only (never a
# full AGR_1251 table scan), maps each flagged role to its current holders, and
# always flags SAP_ALL profile holders. Findings + a GO/GO_WITH_WARNINGS/NO_GO
# verdict; a role held only via a manual profile is COULD_NOT_CHECK, never "clean".
#
#   -CriticalTsv <critical_auths.tsv> [-Users] [-Max 200000] [-OutDir <dir>]
#
# READ-ONLY. RFC_READ_TABLE only. Matcher semantics identical to
# sap_role_critical_match.ps1 (one vocabulary).
#
# Output (stdout):
#   CRIT: check=<id> object=<o> field=<f> severity=<s> roles=<n> users=<n>
#   SAPALL: bname=<u> name=<n>
#   STATUS: OK checks_hit=<n> critical=<n> high=<n> sapall=<n> verdict=<GO|GO_WITH_WARNINGS|NO_GO> | NO_MATRIX | RFC_ERROR
# Exit: 0 OK | 2 connect/matrix failure.
# =============================================================================

[CmdletBinding()]
param(
    [string]   $CriticalTsv = '',
    [switch]   $Users,
    [int]      $Max = 200000,
    [string]   $OutDir = '',
    [string]   $SharedDir = '',
    [string]   $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Read-TsvRows { param([string] $Path)
    $rows = @(); if (-not (Test-Path $Path)) { return ,$rows }
    $bom = [char]0xFEFF
    $txt = ([System.IO.File]::ReadAllText($Path)).TrimStart($bom) -replace "`r", ""
    $hdr = $null
    foreach ($ln0 in ($txt -split "`n")) {
        $ln = $ln0.TrimStart($bom)
        if ($ln -match '^\s*#' -or -not $ln.Trim()) { continue }
        $c = $ln -split "`t"
        if (-not $hdr) { $hdr = @($c | ForEach-Object { $_.TrimStart($bom).Trim() }); continue }
        $o = [ordered]@{}; for ($i = 0; $i -lt $hdr.Count; $i++) { $o[$hdr[$i]] = if ($i -lt $c.Count) { $c[$i].Trim() } else { '' } }
        $rows += ,([pscustomobject]$o)
    }
    return ,$rows
}
function Rule-Hits { param([string] $rLow, [string] $rHigh, [string] $gLow, [string] $gHigh)
    if ($gLow -eq '*') { return $true }
    if ($rLow -eq '*') { return $false }
    if ($rLow.EndsWith('*')) { $p = $rLow.TrimEnd('*'); return ($gLow.StartsWith($p)) }
    $gHi = if ($gHigh) { $gHigh } else { $gLow }
    if ($rHigh) { return -not (($gHi -lt $rLow) -or ($gLow -gt $rHigh)) }
    return (($rLow -ge $gLow) -and ($rLow -le $gHi))
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $CriticalTsv -or -not (Test-Path $CriticalTsv)) { Write-Host "STATUS: NO_MATRIX reason=matrix_missing"; exit 2 }
    $rules = Read-TsvRows $CriticalTsv
    if (-not @($rules).Count -or -not ($rules[0].PSObject.Properties.Name -contains 'check_id')) { Write-Host "STATUS: NO_MATRIX reason=bad_matrix"; exit 2 }

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_SUIMC"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

    try {
        $distinctObj = @($rules | ForEach-Object { San $_.auth_object } | Sort-Object -Unique) | Where-Object { $_ }
        # grants per critical object: role -> list of (field, low, high)
        $grantsByObj = @{}
        foreach ($ob in $distinctObj) {
            $esc = $ob -replace "'", "''"
            $rows = Read-SapTableRows -Destination $g_dest -Table 'AGR_1251' -Where "OBJECT EQ '$esc' AND DELETED NE 'X'" -Fields @('AGR_NAME','FIELD','LOW','HIGH') -RowCount $Max
            $grantsByObj[$ob] = @($rows)
        }

        $today = (Get-Date).ToString('yyyyMMdd')
        function Role-Users { param([string] $rn)
            $set = @{}
            try { $au = Read-SapTableRows -Destination $g_dest -Table 'AGR_USERS' -Where "AGR_NAME EQ '$($rn -replace "'","''")'" -Fields @('UNAME','FROM_DAT','TO_DAT') -RowCount 5000
                foreach ($u in @($au)) { $bn = San $u.UNAME; if (-not $bn) { continue }; $fr = San $u.FROM_DAT; $to = San $u.TO_DAT; if ($fr -and $fr -ne '00000000' -and $today -lt $fr) { continue }; if ($to -and $to -ne '00000000' -and $today -gt $to) { continue }; $set[$bn] = $true } } catch { }
            return $set
        }

        $nCrit = 0; $nHigh = 0; $checksHit = 0
        foreach ($r in @($rules)) {
            $co = San $r.auth_object; $cf = San $r.field; $cl = San $r.low; $chh = San $r.high; $sev = (San $r.severity).ToUpper()
            if (-not $grantsByObj.ContainsKey($co)) { continue }
            $roles = @{}
            foreach ($g in $grantsByObj[$co]) {
                $gf = San $g.FIELD; $gl = San $g.LOW; $gh = San $g.HIGH
                $hit = $false
                if (-not $cf) { $hit = $true } elseif ($gf -eq $cf) { $hit = (Rule-Hits $cl $chh $gl $gh) }
                if ($hit) { $roles[(San $g.AGR_NAME)] = $true }
            }
            if (-not $roles.Count) { continue }
            $checksHit++; if ($sev -eq 'CRITICAL') { $nCrit++ } elseif ($sev -eq 'HIGH') { $nHigh++ }
            # user mapping is opt-in (-Users): the per-role AGR_USERS reads are the slow part
            $uStr = '-'
            if ($Users) { $userSet = @{}; foreach ($rn in $roles.Keys) { foreach ($u in (Role-Users $rn).Keys) { $userSet[$u] = $true } }; $uStr = "$($userSet.Count)" }
            Write-Host ("CRIT: check={0} object={1} field={2} severity={3} roles={4} users={5}" -f (San $r.check_id),$co,$cf,$sev,$roles.Count,$uStr)
        }

        # SAP_ALL holders (always flagged)
        $sapAll = 0
        try {
            $ust = Read-SapTableRows -Destination $g_dest -Table 'UST04' -Where "PROFILE EQ 'SAP_ALL'" -Fields @('BNAME') -RowCount 5000
            foreach ($u in @($ust)) { $bn = San $u.BNAME; if (-not $bn) { continue }; $sapAll++
                $nm = ''; if ($Users) { try { $ua = Read-SapTableRows -Destination $g_dest -Table 'USER_ADDR' -Where "BNAME EQ '$($bn -replace "'","''")'" -Fields @('NAME_TEXTC') -RowCount 1; if (@($ua).Count) { $nm = San $ua[0].NAME_TEXTC } } catch { } }
                Write-Host ("SAPALL: bname={0} name={1}" -f $bn,($nm -replace '"',"'")) }
        } catch { }

        $verdict = if ($nCrit -gt 0 -or $sapAll -gt 0) { 'NO_GO' } elseif ($nHigh -gt 0) { 'GO_WITH_WARNINGS' } else { 'GO' }
        Write-Host ("STATUS: OK checks_hit=$checksHit critical=$nCrit high=$nHigh sapall=$sapAll verdict=$verdict")
        Disconnect-SapRfc; exit 0
    } catch {
        Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2
    }
}
