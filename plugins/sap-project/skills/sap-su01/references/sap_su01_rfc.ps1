# =============================================================================
# sap_su01_rfc.ps1  -  DEV-only test-user lifecycle for /sap-su01 (RFC / BAPI)
#
# Actions: precheck | show | create | assign | unassign | lock | unlock | resetpw | delete
# All via released, remote-enabled BAPI_USER_* FMs (probed FMODE=R on S4D + EC2).
# NOTE ON FM NAMES (do not "fix"): the released names are BAPI_USER_GET_DETAIL and
# BAPI_USER_ACTGROUPS_ASSIGN. BAPI_USER_GETDETAIL / BAPI_USER_ACTVGROUPS_ASSIGN do
# NOT exist on either release.
#
# SAFETY: every write refuses on a non-DEV client (T000 CCCATEGORY in {P,T} or not
# modifiable) -> STATUS: REFUSED. Success is NEVER claimed from the BAPI RETURN
# alone - each write is verified by an authoritative USR02 / AGR_USERS re-read.
# BAPI_USER_ACTGROUPS_ASSIGN REPLACES the full role set, so assign/unassign do a
# GET_DETAIL -> merge/subtract -> assign read-modify-write.
#
# Passwords are generated here and returned ONLY as dpapi:<b64> (via sap_dpapi) on
# stdout for the store to persist - plaintext is never printed.
#
# Output (stdout): SU01: <verb> user=<U> ...   +   STATUS: OK|REFUSED|BAPI_ERROR|RFC_ERROR|USER_EXISTS|USER_NOT_FOUND|ROLE_NOT_FOUND|VERIFY_MISMATCH
# Exit: 0 = OK | 1 = REFUSED / business refusal | 2 = RFC/BAPI error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,
    [string] $User = '',
    [string] $UserType = 'A',            # A service? no: A=Dialog B=System C=Comm S=Service L=Ref
    [string] $Group = '',
    [string] $Roles = '',                # comma-separated (assign/unassign/create)
    [string] $Desc = '',
    [string] $ValidTo = '',              # YYYYMMDD (LOGONDATA-GLTGB)
    [string] $NewPassword = '',          # resetpw/create: caller-supplied; else generated
    [string] $SharedDir = '',
    [string] $SelfUser = '',             # the pinned profile's own user (self-target guard)
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
# Snapshot ALL our params: sap_dpapi.ps1 declares its own -Action, and
# sap_object_resolver.ps1 declares -User/-Server/... - dot-sourcing them re-runs
# their param() blocks and would reset our identically-named vars to their defaults.
$__keep = @{ Action=$Action; User=$User; UserType=$UserType; Group=$Group; Roles=$Roles; Desc=$Desc; ValidTo=$ValidTo; NewPassword=$NewPassword; SelfUser=$SelfUser;
             Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1','sap_dpapi.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

$U = $User.ToUpper()

# ---- BAPI RETURN parsing --------------------------------------------------
function Get-BapiReturn {
    param($Fn)
    $out = @()
    try {
        $rt = $Fn.GetTable('RETURN')
        for ($i = 0; $i -lt $rt.RowCount; $i++) { $rt.CurrentIndex = $i; $out += [pscustomobject]@{ type = "$($rt.GetValue('TYPE'))"; id = "$($rt.GetValue('ID'))"; number = "$($rt.GetValue('NUMBER'))"; message = "$($rt.GetValue('MESSAGE'))" } }
    } catch {}
    return $out
}
function Test-BapiError { param([object[]] $Ret) return (@($Ret | Where-Object { "$($_.type)" -in @('E','A') }).Count -gt 0) }
function Get-BapiErrText { param([object[]] $Ret) return (@($Ret | Where-Object { "$($_.type)" -in @('E','A') } | ForEach-Object { "$($_.id)/$($_.number) $($_.message)" }) -join ' | ') }
function Invoke-Commit { param($Dest) try { $c = $Dest.Repository.CreateFunction('BAPI_TRANSACTION_COMMIT'); $c.SetValue('WAIT','X'); $c.Invoke($Dest) } catch {} }

# ---- helpers --------------------------------------------------------------
function Get-UserRoles {
    param($Dest, [string] $Usr)
    $fn = $Dest.Repository.CreateFunction('BAPI_USER_GET_DETAIL'); $fn.SetValue('USERNAME', $Usr); $fn.Invoke($Dest)
    $roles = @()
    try { $t = $fn.GetTable('ACTIVITYGROUPS'); for ($i=0;$i -lt $t.RowCount;$i++){ $t.CurrentIndex=$i; $roles += "$($t.GetValue('AGR_NAME'))" } } catch {}
    return @($roles | Where-Object { $_ } | Select-Object -Unique)
}
function Read-Usr02Uflag { param($Dest, [string] $Usr) $r = Read-SapTableRows -Destination $Dest -Table 'USR02' -Where "BNAME EQ '$($Usr -replace "'","''")'" -Fields @('BNAME','UFLAG','USTYP','CLASS') -RowCount 1; if ($r -and $r.Count) { return $r[0] } else { return $null } }
function Read-AgrUsers { param($Dest, [string] $Usr) $r = Read-SapTableRows -Destination $Dest -Table 'AGR_USERS' -Where "UNAME EQ '$($Usr -replace "'","''")'" -Fields @('AGR_NAME','UNAME') -RowCount 200; return @($r | ForEach-Object { "$($_.AGR_NAME)" } | Where-Object { $_ } | Select-Object -Unique) }
function New-DevPassword { $chars='ABCDEFGHJKLMNPQRSTUVWXYZ'; $lc='abcdefghijkmnpqrstuvwxyz'; $dig='23456789'; $spec='!#$%+-='; $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create(); $bytes=New-Object byte[] 16; $rng.GetBytes($bytes); $pool="$chars$lc$dig$spec"; $pw=''; $pw+=$chars[$bytes[0]%$chars.Length]; $pw+=$lc[$bytes[1]%$lc.Length]; $pw+=$dig[$bytes[2]%$dig.Length]; $pw+=$spec[$bytes[3]%$spec.Length]; for($i=4;$i -lt 12;$i++){ $pw+=$pool[$bytes[$i]%$pool.Length] }; return $pw }

if ($MyInvocation.InvocationName -eq '.') { return }

$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_SU01"
if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }
$effClient = if ($Client) { $Client } else { "$g_sapClient" }

# ---- DEV-only guard (every write) -----------------------------------------
function Test-DevClient {
    param($Dest, [string] $Client)
    $r = Read-SapTableRows -Destination $Dest -Table 'T000' -Where "MANDT EQ '$Client'" -Fields @('MANDT','CCCATEGORY','CCCORACTIV','CCNOCLIIND') -RowCount 1
    if (-not $r -or $r.Count -eq 0) { return @{ ok=$false; reason='T000 unreadable' } }
    $cat = "$($r[0].CCCATEGORY)".ToUpper()          # P=production T=test C=customizing S=SAP-ref D=demo E=training
    $chg = "$($r[0].CCCORACTIV)"                     # 1/2/3 = changes-without-warn / warn / no-changes
    # DEV-only = never on a PRODUCTION client (or a non-modifiable one). Test (T) /
    # Customizing (C) / demo clients are legitimate homes for test users - allowed.
    # (Live: S4D's dev client 100 is CCCATEGORY=T, so refusing T would block the
    # only test system - production is the real safety line.)
    if ($cat -eq 'P') { return @{ ok=$false; reason="client $Client is CCCATEGORY=P (production) - refused" } }
    if ($chg -eq '3') { return @{ ok=$false; reason="client $Client is not modifiable (CCCORACTIV=3)" } }
    return @{ ok=$true; reason="CCCATEGORY=$cat modifiable" }
}

$writeActions = @('create','assign','unassign','lock','unlock','resetpw','delete')
try {
    if ($Action.ToLower() -in $writeActions) {
        $dev = Test-DevClient -Dest $g_dest -Client $effClient
        if (-not $dev.ok) { Write-Host "SU01: refused user=$U reason=$($dev.reason)"; Write-Host "STATUS: REFUSED"; Disconnect-SapRfc; exit 1 }
        if ($SelfUser -and $U -eq $SelfUser.ToUpper() -and $Action.ToLower() -in @('lock','delete','resetpw')) { Write-Host "SU01: refused user=$U reason=self-target"; Write-Host "STATUS: REFUSED"; Disconnect-SapRfc; exit 1 }
    }

    switch ($Action.ToLower()) {
        'precheck' {
            $dev = Test-DevClient -Dest $g_dest -Client $effClient
            $ex = $g_dest.Repository.CreateFunction('BAPI_USER_EXISTENCE_CHECK'); $ex.SetValue('USERNAME', $U); $ex.Invoke($g_dest)
            $ret = Get-BapiReturn $ex
            # existence: RETURN carries an 'exists' vs 'does not exist' message; verify via USR02
            $u02 = Read-Usr02Uflag -Dest $g_dest -Usr $U
            $exists = ($null -ne $u02)
            Write-Host ("SU01: precheck client={0} dev_ok={1} reason={2} user={3} exists={4}" -f $effClient, $dev.ok, $dev.reason, $U, $exists)
            Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'show' {
            $u02 = Read-Usr02Uflag -Dest $g_dest -Usr $U
            if ($null -eq $u02) { Write-Host "SU01: show user=$U not_found"; Write-Host "STATUS: USER_NOT_FOUND"; Disconnect-SapRfc; exit 1 }
            $roles = Read-AgrUsers -Dest $g_dest -Usr $U
            $locked = ("$($u02.UFLAG)" -ne '0' -and "$($u02.UFLAG)" -ne '')
            Write-Host ("SU01: show user={0} type={1} group={2} locked={3} uflag={4} roles={5}" -f $U, "$($u02.USTYP)", "$($u02.CLASS)", $locked, "$($u02.UFLAG)", ($roles -join ','))
            Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'create' {
            if ($null -ne (Read-Usr02Uflag -Dest $g_dest -Usr $U)) { Write-Host "SU01: create user=$U already_exists"; Write-Host "STATUS: USER_EXISTS"; Disconnect-SapRfc; exit 1 }
            $pw = if ($NewPassword) { $NewPassword } else { New-DevPassword }
            $fn = $g_dest.Repository.CreateFunction('BAPI_USER_CREATE1')
            $fn.SetValue('USERNAME', $U)
            $ld = $fn.GetStructure('LOGONDATA'); $ld.SetValue('USTYP', $UserType.ToUpper()); if ($Group) { $ld.SetValue('CLASS', $Group.ToUpper()) }; if ($ValidTo) { $ld.SetValue('GLTGB', $ValidTo) }
            $ad = $fn.GetStructure('ADDRESS'); $ad.SetValue('LASTNAME', $(if ($Desc) { $Desc } else { $U }))
            $ps = $fn.GetStructure('PASSWORD'); $ps.SetValue('BAPIPWD', $pw)
            $fn.Invoke($g_dest); $ret = Get-BapiReturn $fn
            if (Test-BapiError $ret) { Write-Host "SU01: create user=$U bapi_error=$(Get-BapiErrText $ret)"; Write-Host "STATUS: BAPI_ERROR"; Disconnect-SapRfc; exit 2 }
            Invoke-Commit $g_dest
            $u02 = Read-Usr02Uflag -Dest $g_dest -Usr $U
            if ($null -eq $u02) { Write-Host "SU01: create user=$U verify_mismatch (no USR02 row)"; Write-Host "STATUS: VERIFY_MISMATCH"; Disconnect-SapRfc; exit 2 }
            $prot = Protect-SapSecret $pw
            Write-Host ("SU01: create user={0} type={1} verified=YES pwd={2}" -f $U, $UserType.ToUpper(), $prot)
            Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        { $_ -in @('assign','unassign') } {
            if ($null -eq (Read-Usr02Uflag -Dest $g_dest -Usr $U)) { Write-Host "SU01: $Action user=$U not_found"; Write-Host "STATUS: USER_NOT_FOUND"; Disconnect-SapRfc; exit 1 }
            $reqRoles = @($Roles.ToUpper() -split '[,; ]+' | Where-Object { $_ })
            # role existence pre-check
            foreach ($r in $reqRoles) { $ad = Read-SapTableRows -Destination $g_dest -Table 'AGR_DEFINE' -Where "AGR_NAME EQ '$($r -replace "'","''")'" -Fields @('AGR_NAME') -RowCount 1; if (-not $ad -or $ad.Count -eq 0) { Write-Host "SU01: $Action user=$U role_not_found=$r"; Write-Host "STATUS: ROLE_NOT_FOUND"; Disconnect-SapRfc; exit 1 } }
            $current = Get-UserRoles -Dest $g_dest -Usr $U
            $target = if ($Action.ToLower() -eq 'assign') { @($current + $reqRoles | Select-Object -Unique) } else { @($current | Where-Object { $reqRoles -notcontains $_ }) }
            $fn = $g_dest.Repository.CreateFunction('BAPI_USER_ACTGROUPS_ASSIGN'); $fn.SetValue('USERNAME', $U)
            $t = $fn.GetTable('ACTIVITYGROUPS'); foreach ($r in $target) { $t.Append(); $t.SetValue('AGR_NAME', $r); $t.SetValue('FROM_DAT', (Get-Date).ToString('yyyyMMdd')); $t.SetValue('TO_DAT', '99991231') }
            $fn.Invoke($g_dest); $ret = Get-BapiReturn $fn
            if (Test-BapiError $ret) { Write-Host "SU01: $Action user=$U bapi_error=$(Get-BapiErrText $ret)"; Write-Host "STATUS: BAPI_ERROR"; Disconnect-SapRfc; exit 2 }
            Invoke-Commit $g_dest
            $after = Read-AgrUsers -Dest $g_dest -Usr $U
            $expected = @($target | Sort-Object); $got = @($after | Sort-Object)
            $match = (@(Compare-Object $expected $got).Count -eq 0)
            Write-Host ("SU01: {0} user={1} target_roles={2} after={3} verified={4}" -f $Action, $U, ($target -join ','), ($after -join ','), $match)
            Write-Host $(if ($match) { "STATUS: OK" } else { "STATUS: VERIFY_MISMATCH" }); Disconnect-SapRfc; exit $(if ($match) { 0 } else { 2 })
        }
        { $_ -in @('lock','unlock') } {
            if ($null -eq (Read-Usr02Uflag -Dest $g_dest -Usr $U)) { Write-Host "SU01: $Action user=$U not_found"; Write-Host "STATUS: USER_NOT_FOUND"; Disconnect-SapRfc; exit 1 }
            $fmName = if ($Action.ToLower() -eq 'lock') { 'BAPI_USER_LOCK' } else { 'BAPI_USER_UNLOCK' }
            $fn = $g_dest.Repository.CreateFunction($fmName); $fn.SetValue('USERNAME', $U); $fn.Invoke($g_dest); $ret = Get-BapiReturn $fn
            if (Test-BapiError $ret) { Write-Host "SU01: $Action user=$U bapi_error=$(Get-BapiErrText $ret)"; Write-Host "STATUS: BAPI_ERROR"; Disconnect-SapRfc; exit 2 }
            Invoke-Commit $g_dest
            $u02 = Read-Usr02Uflag -Dest $g_dest -Usr $U; $uflag = "$($u02.UFLAG)"
            $ok = if ($Action.ToLower() -eq 'lock') { ($uflag -ne '0' -and $uflag -ne '') } else { ($uflag -eq '0' -or $uflag -eq '') }
            Write-Host ("SU01: {0} user={1} uflag={2} verified={3}" -f $Action, $U, $uflag, $ok)
            Write-Host $(if ($ok) { "STATUS: OK" } else { "STATUS: VERIFY_MISMATCH" }); Disconnect-SapRfc; exit $(if ($ok) { 0 } else { 2 })
        }
        'resetpw' {
            if ($null -eq (Read-Usr02Uflag -Dest $g_dest -Usr $U)) { Write-Host "SU01: resetpw user=$U not_found"; Write-Host "STATUS: USER_NOT_FOUND"; Disconnect-SapRfc; exit 1 }
            $pw = if ($NewPassword) { $NewPassword } else { New-DevPassword }
            $fn = $g_dest.Repository.CreateFunction('BAPI_USER_CHANGE'); $fn.SetValue('USERNAME', $U)
            $ps = $fn.GetStructure('PASSWORD'); $ps.SetValue('BAPIPWD', $pw)
            $px = $fn.GetStructure('PASSWORDX'); $px.SetValue('BAPIPWD', 'X')
            $fn.Invoke($g_dest); $ret = Get-BapiReturn $fn
            if (Test-BapiError $ret) { Write-Host "SU01: resetpw user=$U bapi_error=$(Get-BapiErrText $ret)"; Write-Host "STATUS: BAPI_ERROR"; Disconnect-SapRfc; exit 2 }
            Invoke-Commit $g_dest
            $prot = Protect-SapSecret $pw
            Write-Host ("SU01: resetpw user={0} pwd={1}" -f $U, $prot); Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'delete' {
            if ($null -eq (Read-Usr02Uflag -Dest $g_dest -Usr $U)) { Write-Host "SU01: delete user=$U not_found"; Write-Host "STATUS: USER_NOT_FOUND"; Disconnect-SapRfc; exit 1 }
            $fn = $g_dest.Repository.CreateFunction('BAPI_USER_DELETE'); $fn.SetValue('USERNAME', $U); $fn.Invoke($g_dest); $ret = Get-BapiReturn $fn
            if (Test-BapiError $ret) { Write-Host "SU01: delete user=$U bapi_error=$(Get-BapiErrText $ret)"; Write-Host "STATUS: BAPI_ERROR"; Disconnect-SapRfc; exit 2 }
            Invoke-Commit $g_dest
            $u02 = Read-Usr02Uflag -Dest $g_dest -Usr $U
            if ($null -ne $u02) { Write-Host "SU01: delete user=$U verify_mismatch (USR02 row remains)"; Write-Host "STATUS: VERIFY_MISMATCH"; Disconnect-SapRfc; exit 2 }
            Write-Host ("SU01: delete user={0} verified=YES" -f $U); Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        default { Write-Host "SU01: unknown_action=$Action"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2 }
    }
} catch {
    Write-Host "SU01: error=$($_.Exception.Message -replace '\s+',' ')"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2
}
