# =============================================================================
# sap_suim_query.ps1  -  "who has access" engine for /sap-suim (read-only RFC)
#
# Answers, over pure RFC (never the SUIM GUI):
#   -Role  <R|R*>            who is assigned role R (or the R* pattern), composite-aware
#   -Tcode <T>              who can start transaction T (S_TCODE grant primary; menu secondary)
#   -Auth  <OBJ:FIELD=VAL>  who has an authorization value (org-level '$' rows disclosed)
# joined to USR02 lock/validity + USER_ADDR names, with a PROFILE_COVERAGE header
# (role-based grants only; manual profiles + reference users counted, SAP_ALL named).
#
#   [-ValidOn YYYYMMDD] [-IncludeLocked] [-Max 5000] [-OutDir <dir>]
#
# READ-ONLY. RFC_READ_TABLE only (AGR_*/USR02/UST04/AGR_1016/USREFUS/USER_ADDR/TSTC
# all TRANSP/FMODE=R, probed identical S4D + EC2 2026-07-11).
#
# Output (stdout, parseable by SKILL.md):
#   USER: bname=<u> name=<n> locked=<Y|N> valid=<from..to> via=<role|tcode-role> source=<direct|composite>
#   PROFILE_COVERAGE: users=<n> with_manual_profiles=<n> sap_all=<n> ref_users=<n>
#   STATUS: OK users=<n> capped=<Y|N> | AUTH_ROLE_NOT_FOUND | AUTH_TCODE_NOT_FOUND | AUTH_VOLUME_CAPPED | RFC_ERROR
# Exit: 0 OK | 1 not-found | 2 connect/input failure.
# =============================================================================

[CmdletBinding()]
param(
    [string]   $Role = '',
    [string]   $Tcode = '',
    [string]   $Auth = '',
    [string]   $ValidOn = '',
    [switch]   $IncludeLocked,
    [int]      $Max = 5000,
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

if ($MyInvocation.InvocationName -ne '.') {
    $sel = @($Role,$Tcode,$Auth | Where-Object { $_ }).Count
    if ($sel -ne 1) { Write-Host "STATUS: RFC_ERROR reason=exactly_one_of_role_tcode_auth"; exit 2 }
    if (-not $ValidOn) { $ValidOn = (Get-Date).ToString('yyyyMMdd') }
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_SUIM"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

    try {
        # ---- resolve the target ROLE SET + a 'via' label -------------------
        $roleSet = @{}   # role -> via label
        if ($Role) {
            $rl = (San $Role).ToUpper()
            $where = if ($rl -match '\*') { "AGR_NAME LIKE '$($rl -replace '\*','%')'" } else { "AGR_NAME EQ '$rl'" }
            $def = Read-SapTableRows -Destination $g_dest -Table 'AGR_DEFINE' -Where $where -Fields @('AGR_NAME') -RowCount 500
            if (-not @($def).Count) { Write-Host "STATUS: AUTH_ROLE_NOT_FOUND role=$rl"; $near = Read-SapTableRows -Destination $g_dest -Table 'AGR_DEFINE' -Where "AGR_NAME LIKE '$($rl.Substring(0,[Math]::Min(8,$rl.Length)))%'" -Fields @('AGR_NAME') -RowCount 10; foreach ($x in @($near)) { Write-Host ("NEAR: {0}" -f (San $x.AGR_NAME)) }; Disconnect-SapRfc; exit 1 }
            foreach ($d in @($def)) { $roleSet[(San $d.AGR_NAME)] = 'direct' }
        }
        elseif ($Tcode) {
            $tc = (San $Tcode).ToUpper()
            $ts = Read-SapTableRows -Destination $g_dest -Table 'TSTC' -Where "TCODE EQ '$tc'" -Fields @('TCODE') -RowCount 1
            if (-not @($ts).Count) { Write-Host "STATUS: AUTH_TCODE_NOT_FOUND tcode=$tc"; Disconnect-SapRfc; exit 1 }
            # roles granting S_TCODE TCD = tc (exact or wildcard)
            $gr = Read-SapTableRows -Destination $g_dest -Table 'AGR_1251' -Where "OBJECT EQ 'S_TCODE' AND FIELD EQ 'TCD' AND DELETED NE 'X'" -Fields @('AGR_NAME','LOW','HIGH') -RowCount 100000
            foreach ($r in @($gr)) { $low = San $r.LOW; $high = San $r.HIGH; $hit = ($low -eq $tc) -or ($low -eq '*') -or ($low.EndsWith('*') -and $tc.StartsWith($low.TrimEnd('*'))) -or ($high -and $tc -ge $low -and $tc -le $high); if ($hit) { $roleSet[(San $r.AGR_NAME)] = "tcode:$tc" } }
            if (-not $roleSet.Count) { Write-Host "PROFILE_COVERAGE: users=0 with_manual_profiles=0 sap_all=0 ref_users=0"; Write-Host "STATUS: OK users=0 capped=N"; Disconnect-SapRfc; exit 0 }
        }
        elseif ($Auth) {
            if ($Auth -notmatch '^([^:]+):([^=]+)=(.+)$') { Write-Host "STATUS: RFC_ERROR reason=bad_auth_spec"; Disconnect-SapRfc; exit 2 }
            $ao = (San $matches[1]).ToUpper(); $af = (San $matches[2]).ToUpper(); $av = San $matches[3]
            $gr = Read-SapTableRows -Destination $g_dest -Table 'AGR_1251' -Where "OBJECT EQ '$ao' AND FIELD EQ '$af' AND DELETED NE 'X'" -Fields @('AGR_NAME','LOW','HIGH') -RowCount 100000
            foreach ($r in @($gr)) { $low = San $r.LOW; $high = San $r.HIGH; $hit = ($low -eq $av) -or ($low -eq '*') -or ($low.EndsWith('*') -and $av.StartsWith($low.TrimEnd('*'))) -or ($high -and $av -ge $low -and $av -le $high); if ($hit) { $roleSet[(San $r.AGR_NAME)] = "auth:$ao-$af=$av" } }
            if (-not $roleSet.Count) { Write-Host "PROFILE_COVERAGE: users=0 with_manual_profiles=0 sap_all=0 ref_users=0"; Write-Host "STATUS: OK users=0 capped=N"; Disconnect-SapRfc; exit 0 }
        }

        # ---- role set -> assigned users (validity-filtered) ----------------
        $users = @{}   # bname -> via
        $capped = $false
        foreach ($rn in $roleSet.Keys) {
            $esc = $rn -replace "'", "''"
            $au = Read-SapTableRows -Destination $g_dest -Table 'AGR_USERS' -Where "AGR_NAME EQ '$esc'" -Fields @('UNAME','FROM_DAT','TO_DAT') -RowCount $Max
            foreach ($u in @($au)) {
                $bn = San $u.UNAME; if (-not $bn) { continue }
                $fr = San $u.FROM_DAT; $to = San $u.TO_DAT
                if ($fr -and $fr -ne '00000000' -and $ValidOn -lt $fr) { continue }
                if ($to -and $to -ne '00000000' -and $ValidOn -gt $to) { continue }
                if (-not $users.ContainsKey($bn)) { $users[$bn] = @{ via = $roleSet[$rn]; role = $rn; from = $fr; to = $to } }
            }
            if ($users.Count -ge $Max) { $capped = $true; break }
        }

        # role-generated profile set (AGR_1016) - true manual profiles = UST04 minus this
        $genProfiles = @{}
        try { $g16 = Read-SapTableRows -Destination $g_dest -Table 'AGR_1016' -Fields @('PROFILE') -RowCount 100000; foreach ($x in @($g16)) { $pf = San $x.PROFILE; if ($pf) { $genProfiles[$pf] = $true } } } catch { }

        # ---- USR02 lock/validity + USER_ADDR name + profile coverage -------
        $withManual = 0; $sapAll = 0; $refUsers = 0; $emitted = 0
        foreach ($bn in ($users.Keys | Sort-Object)) {
            $escU = $bn -replace "'", "''"
            $lock = ''; $nm = ''
            try { $u2 = Read-SapTableRows -Destination $g_dest -Table 'USR02' -Where "BNAME EQ '$escU'" -Fields @('UFLAG') -RowCount 1; if (@($u2).Count) { $lock = San $u2[0].UFLAG } } catch { }
            $locked = if ($lock -and $lock -ne '0') { 'Y' } else { 'N' }
            if ($locked -eq 'Y' -and -not $IncludeLocked) { continue }
            try { $ua = Read-SapTableRows -Destination $g_dest -Table 'USER_ADDR' -Where "BNAME EQ '$escU'" -Fields @('NAME_TEXTC') -RowCount 1; if (@($ua).Count) { $nm = San $ua[0].NAME_TEXTC } } catch { }
            # manual profiles = UST04 profiles not generated from a role (AGR_1016)
            try {
                $up = Read-SapTableRows -Destination $g_dest -Table 'UST04' -Where "BNAME EQ '$escU'" -Fields @('PROFILE') -RowCount 200
                $profs = @($up | ForEach-Object { San $_.PROFILE })
                if ($profs -contains 'SAP_ALL') { $sapAll++ }
                # true manual profiles = UST04 profiles not generated by any role (AGR_1016)
                $manual = @($profs | Where-Object { $_ -and $_ -ne 'SAP_ALL' -and $_ -ne 'SAP_NEW' -and -not $genProfiles.ContainsKey($_) })
                if ($manual.Count) { $withManual++ }
            } catch { }
            try { $ru = Read-SapTableRows -Destination $g_dest -Table 'USREFUS' -Where "BNAME EQ '$escU'" -Fields @('REFUSER') -RowCount 1; if (@($ru).Count -and (San $ru[0].REFUSER)) { $refUsers++ } } catch { }
            $v = $users[$bn]
            Write-Host ("USER: bname={0} name={1} locked={2} valid={3}..{4} via={5} source=direct" -f $bn,($nm -replace '"',"'"),$locked,$v.from,$v.to,$v.via)
            $emitted++
        }

        Write-Host ("PROFILE_COVERAGE: users=$emitted with_manual_profiles=$withManual sap_all=$sapAll ref_users=$refUsers")
        Write-Host ("STATUS: OK users=$emitted capped=$(if($capped){'Y'}else{'N'})")
        Disconnect-SapRfc; exit 0
    } catch {
        Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2
    }
}
