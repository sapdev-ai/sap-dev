# =============================================================================
# sap_auth_diagnose_rfc.ps1  -  headless authorization diagnosis for /sap-auth-diagnose
#
# Answers "why can't user <U> do <X>" deterministically over RFC, with faithful
# AUTHORITY-CHECK semantics, and proposes the exact PFCG fix. No GUI, no Z objects.
#
# The PASS/FAIL decision rides on the AUTHORITATIVE user buffer:
#   SUSR_USER_AUTH_FOR_OBJ_GET (RFC-enabled, probed FMODE=R on S4D + EC2) returns
#   FULLY_AUTHORIZED + a VALUES table (AUTH, FIELD, VON, BIS) that IS what
#   AUTHORITY-CHECK evaluates at runtime (composite roles, profiles, SAP_ALL all
#   already compiled in) -- so it can never disagree with the real check the way a
#   hand-rolled AGR_1251/UST12 join can. Evaluation is per-instance: one AUTH
#   instance must satisfy EVERY required field ('*' matches anything, VON..BIS
#   ranges honoured) -- the same evaluator sap-doctor's authz probe ships.
#
# The AGR_* join is used ONLY to make the finding actionable (which of the user's
# roles is closest, what it currently grants) and to surface BUFFER_STALE: the
# role design DOES grant it but the buffer does not -> re-logon / user compare.
#
# Actions:
#   check   -Object <O> [-Values "F=V;F2=V2"]     single AUTHORITY-CHECK group
#   check   -InputFile <tsv>                       batch (checkid<TAB>object<TAB>field<TAB>value)
#
# Classifications: PASS | MISSING_OBJECT | MISSING_VALUE | BUFFER_STALE
#   (+ user-level USER_LOCKED / USER_EXPIRED / ROLE_EXPIRED surfaced separately).
#
# Output (stdout, parsed by SKILL.md):
#   USER: name=<U> exists=<Y|N> locked=<Y|N> uflag=<n> valid_from=<> valid_to=<> invalid=<Y|N>
#   ROLE: name=<r> from=<> to=<> expired=<Y|N> has_object=<Y|N> text=<...>       (relevant roles)
#   AUTHCHK: checkid=<id> object=<O> verdict=<PASS|MISSING_OBJECT|MISSING_VALUE|BUFFER_STALE>
#            fully=<X|-> req=<F=V,..> closest_role=<r|-> grants=<F:vals|-> otext=<..>
#   AUTHSUMMARY: checks=<n> pass=<p> fail=<f> user=<U> object_text_source=<TOBJT|none>
#   STATUS: OK | USER_NOT_FOUND | INPUT_INVALID | COULD_NOT_CHECK | RFC_ERROR
# Exit: 0 = ran (PASS or findings) | 1 = USER_NOT_FOUND / INPUT_INVALID | 2 = RFC/FM error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,
    [string] $User = '',
    [string] $Object = '',
    [string] $Values = '',          # "FIELD=VAL;FIELD2=VAL2"  (empty = presence check)
    [string] $InputFile = '',       # batch TSV: checkid<TAB>object<TAB>field<TAB>value
    [string] $Ticket = '',
    [string] $SharedDir = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
# Snapshot ALL our params: sap_object_resolver.ps1 declares -User/-Server/... and
# would reset our identically-named vars to their defaults when dot-sourced.
$__keep = @{ Action=$Action; User=$User; Object=$Object; Values=$Values; InputFile=$InputFile; Ticket=$Ticket;
             Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

# ---- authoritative buffer read -------------------------------------------
# Returns @{ fully=<bool>; inst=@{ AUTH => @{ FIELD => List[@{von;bis}] } }; rows=<n>; error=<msg> }
function Get-UserAuthForObj {
    param($Dest, [string] $Usr, [string] $Obj)
    try {
        $fn = $Dest.Repository.CreateFunction('SUSR_USER_AUTH_FOR_OBJ_GET')
        $fn.SetValue('USER_NAME', $Usr); $fn.SetValue('SEL_OBJECT', $Obj); $fn.Invoke($Dest)
        $fully = $false; try { $fully = ((($fn.GetString('FULLY_AUTHORIZED')).Trim()) -eq 'X') } catch {}
        $inst = @{}; $v = $fn.GetTable('VALUES'); $rows = $v.RowCount
        for ($r=0; $r -lt $rows; $r++){ $v.CurrentIndex=$r
            $auth=($v.GetString('AUTH')).Trim(); $fld=($v.GetString('FIELD')).Trim()
            if (-not $fld) { continue }
            $von=($v.GetString('VON')).Trim(); $bis=($v.GetString('BIS')).Trim()
            if (-not $inst.ContainsKey($auth)) { $inst[$auth]=@{} }
            if (-not $inst[$auth].ContainsKey($fld)) { $inst[$auth][$fld]=New-Object System.Collections.Generic.List[object] }
            [void]$inst[$auth][$fld].Add(@{ von=$von; bis=$bis })
        }
        return @{ fully=$fully; inst=$inst; rows=$rows; error='' }
    } catch { return @{ fully=$false; inst=@{}; rows=0; error=($_.Exception.Message -replace '\s+',' ') } }
}

# faithful AUTHORITY-CHECK (same semantics as sap_doctor_authz_probe.ps1)
function Test-FieldSatisfied {
    param($Entries, [string] $ReqValue)
    if ($null -eq $Entries -or $Entries.Count -eq 0) { return $false }
    foreach ($e in $Entries) { if ($e.von -eq '*') { return $true } }              # user '*' covers anything
    if ([string]::IsNullOrWhiteSpace($ReqValue)) { return $true }                   # presence-only
    foreach ($e in $Entries) {
        if ($e.von -eq $ReqValue) { return $true }
        if ($e.bis -and ([string]::CompareOrdinal($e.von,$ReqValue) -le 0) -and ([string]::CompareOrdinal($ReqValue,$e.bis) -le 0)) { return $true }
    }
    return $false
}
# $FieldReqs = @( @{field;value}, ... ) ; passes if ONE AUTH instance covers all
function Test-ObjectSatisfied {
    param($Grant, $FieldReqs)
    if ($Grant.fully) { return $true }
    if (-not $Grant.inst -or $Grant.inst.Count -eq 0) { return $false }
    foreach ($authName in @($Grant.inst.Keys)) {
        $ok = $true
        foreach ($fr in $FieldReqs) {
            $entries = $null
            if ($Grant.inst[$authName].ContainsKey($fr.field)) { $entries = $Grant.inst[$authName][$fr.field] }
            if (-not (Test-FieldSatisfied $entries $fr.value)) { $ok = $false; break }
        }
        if ($ok) { return $true }
    }
    return $false
}

# ---- correlation readers --------------------------------------------------
function Read-UserRoles {
    param($Dest, [string] $Usr)
    $r = Read-SapTableRows -Destination $Dest -Table 'AGR_USERS' -Where "UNAME EQ '$($Usr -replace "'","''")'" -Fields @('AGR_NAME','FROM_DAT','TO_DAT') -RowCount 500
    return @($r | ForEach-Object { [pscustomobject]@{ role="$($_.AGR_NAME)"; from="$($_.FROM_DAT)"; to="$($_.TO_DAT)" } } | Where-Object { $_.role })
}
function Read-RoleText {
    param($Dest, [string] $Role)
    try {
        $t = Read-SapTableRows -Destination $Dest -Table 'AGR_TEXTS' -Where "AGR_NAME EQ '$($Role -replace "'","''")' AND LINE EQ '00000'" -Fields @('TEXT','SPRAS','LINE') -RowCount 5
        $row = @($t | Where-Object { "$($_.TEXT)".Trim() } | Select-Object -First 1)
        if ($row) { return "$($row.TEXT)".Trim() }
    } catch {}
    return ''
}
# which of the given roles grant $Obj, and their LOW/HIGH per field (for the fix proposal)
function Read-RoleGrantsForObject {
    param($Dest, [string[]] $Roles, [string] $Obj)
    $out = @()
    foreach ($role in $Roles) {
        try {
            $rows = Read-SapTableRows -Destination $Dest -Table 'AGR_1251' -Where "AGR_NAME EQ '$($role -replace "'","''")' AND OBJECT EQ '$($Obj -replace "'","''")'" -Fields @('AUTH','FIELD','LOW','HIGH','DELETED') -RowCount 200
            $rows = @($rows | Where-Object { "$($_.DELETED)".Trim() -ne 'X' -and "$($_.FIELD)".Trim() })
            if ($rows.Count) {
                $byField = @{}
                foreach ($rw in $rows) {
                    $f="$($rw.FIELD)".Trim(); $lo="$($rw.LOW)".Trim(); $hi="$($rw.HIGH)".Trim()
                    $val = if ($hi) { "$lo-$hi" } else { $lo }
                    if (-not $byField.ContainsKey($f)) { $byField[$f]=New-Object System.Collections.Generic.List[string] }
                    if ($val -and -not $byField[$f].Contains($val)) { [void]$byField[$f].Add($val) }
                }
                $out += [pscustomobject]@{ role=$role; fields=$byField }
            }
        } catch {}
    }
    return $out
}
function Read-Usr02 {
    param($Dest, [string] $Usr)
    $r = Read-SapTableRows -Destination $Dest -Table 'USR02' -Where "BNAME EQ '$($Usr -replace "'","''")'" -Fields @('BNAME','UFLAG','GLTGV','GLTGB','USTYP','CLASS') -RowCount 1
    if ($r -and @($r).Count) { return $r[0] } else { return $null }
}
function Read-ObjectText {
    param($Dest, [string] $Obj)
    foreach ($lg in @('E','1')) {
        try { $t = Read-SapTableRows -Destination $Dest -Table 'TOBJT' -Where "OBJECT EQ '$($Obj -replace "'","''")' AND LANGU EQ '$lg'" -Fields @('TTEXT') -RowCount 1
              if ($t -and @($t).Count -and "$($t[0].TTEXT)".Trim()) { return "$($t[0].TTEXT)".Trim() } } catch {}
    }
    return ''
}

# ---- input parsing --------------------------------------------------------
# One "check" = @{ id; object; reqs=@(@{field;value},..) }
function Get-Checks {
    param([string] $Obj, [string] $Vals, [string] $File)
    $checks = @()
    if ($File) {
        if (-not (Test-Path -LiteralPath $File)) { throw "input file not found: $File" }
        $lines = @(Get-Content -LiteralPath $File | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() })
        $groups = @{}
        foreach ($ln in $lines) {
            $f = $ln.Split("`t")
            if ($f.Count -lt 2) { continue }
            $cid = "$($f[0])".Trim(); $ob = "$($f[1])".Trim()
            if ($cid -eq 'checkid' -and $ob -eq 'object') { continue }              # header
            if (-not $ob) { $ob = $cid; $cid = $ob }                                 # 1-col fallback
            $fld = if ($f.Count -ge 3) { "$($f[2])".Trim() } else { '' }
            $val = if ($f.Count -ge 4) { "$($f[3])".Trim() } else { '' }
            $key = if ($cid) { $cid } else { $ob }
            if (-not $groups.ContainsKey($key)) { $groups[$key] = [pscustomobject]@{ id=$key; object=$ob; reqs=(New-Object System.Collections.Generic.List[object]) } }
            if ($fld) { [void]$groups[$key].reqs.Add(@{ field=$fld.ToUpper(); value=$val }) }
        }
        $checks = @($groups.Values)
    } elseif ($Obj) {
        $reqs = New-Object System.Collections.Generic.List[object]
        foreach ($pair in ($Vals -split '[;,]' | Where-Object { $_.Trim() })) {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2 -and $kv[0].Trim()) { [void]$reqs.Add(@{ field=$kv[0].Trim().ToUpper(); value=$kv[1].Trim() }) }
        }
        $checks = @([pscustomobject]@{ id=$Obj; object=$Obj; reqs=$reqs })
    }
    return $checks
}

function Format-Reqs { param($Reqs) if (-not $Reqs -or $Reqs.Count -eq 0) { return '(presence)' } return (@($Reqs | ForEach-Object { if ($_.value) { "$($_.field)=$($_.value)" } else { "$($_.field)" } }) -join ',') }

if ($MyInvocation.InvocationName -eq '.') { return }

$U = $User.ToUpper()
if ($Action.ToLower() -ne 'check') { Write-Host "AUTH: unknown_action=$Action"; Write-Host "STATUS: INPUT_INVALID"; exit 1 }

# parse checks first (fail fast on bad input, before connecting)
try { $checks = @(Get-Checks -Obj $Object.ToUpper() -Vals $Values -File $InputFile) } catch { Write-Host "AUTH: input_error=$($_.Exception.Message)"; Write-Host "STATUS: INPUT_INVALID"; exit 1 }
if ($checks.Count -eq 0) { Write-Host "AUTH: no_checks (need -Object or -InputFile)"; Write-Host "STATUS: INPUT_INVALID"; exit 1 }

$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_AUTHDIAG"
if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

try {
    if (-not $U) { try { $prof = Get-SapCurrentConnectionProfile; if ($prof) { $U = "$($prof.user)".ToUpper() } } catch {} }
    if (-not $U) { Write-Host "AUTH: could not resolve user"; Write-Host "STATUS: USER_NOT_FOUND"; Disconnect-SapRfc $g_dest; exit 1 }

    # --- user context (lock / validity) ---
    $u02 = Read-Usr02 -Dest $g_dest -Usr $U
    if ($null -eq $u02) { Write-Host "USER: name=$U exists=N"; Write-Host "AUTH: user not found in USR02"; Write-Host "STATUS: USER_NOT_FOUND"; Disconnect-SapRfc $g_dest; exit 1 }
    $uflag = "$($u02.UFLAG)".Trim(); $locked = ($uflag -ne '0' -and $uflag -ne '')
    $gltgb = "$($u02.GLTGB)".Trim(); $gltgv = "$($u02.GLTGV)".Trim()
    $today = (Get-Date).ToString('yyyyMMdd')
    $expired = ($gltgb -and $gltgb -ne '00000000' -and $gltgb -lt $today)
    $notyet  = ($gltgv -and $gltgv -ne '00000000' -and $gltgv -gt $today)
    $userInvalid = ($locked -or $expired -or $notyet)
    Write-Host ("USER: name={0} exists=Y locked={1} uflag={2} valid_from={3} valid_to={4} invalid={5}" -f $U, $(if($locked){'Y'}else{'N'}), $uflag, $(if($gltgv){$gltgv}else{'-'}), $(if($gltgb){$gltgb}else{'-'}), $(if($userInvalid){'Y'}else{'N'}))

    # --- user's roles (shared across all checks) ---
    $roles = @(Read-UserRoles -Dest $g_dest -Usr $U)
    $roleNames = @($roles | ForEach-Object { $_.role } | Select-Object -Unique)
    $roleMeta = @{}; foreach ($ro in $roles) { if (-not $roleMeta.ContainsKey($ro.role)) { $roleMeta[$ro.role] = $ro } }
    $reportRoles = @{}   # role -> reason (only actionable roles are surfaced, not all 25)

    $objTextSource = 'none'
    $nPass=0; $nFail=0
    foreach ($chk in $checks) {
        $obj = "$($chk.object)".ToUpper()
        if (-not $obj) { continue }
        $grant = Get-UserAuthForObj -Dest $g_dest -Usr $U -Obj $obj
        if ($grant.error) { Write-Host ("AUTHCHK: checkid={0} object={1} verdict=COULD_NOT_CHECK req={2} err={3}" -f $chk.id,$obj,(Format-Reqs $chk.reqs),$grant.error); continue }

        $otext = Read-ObjectText -Dest $g_dest -Obj $obj
        if ($otext) { $objTextSource = 'TOBJT' }

        # which of the user's roles grant this object (for fix proposal + BUFFER_STALE)
        $roleGrants = @(Read-RoleGrantsForObject -Dest $g_dest -Roles $roleNames -Obj $obj)
        $closest = ''; $grantsStr = '-'
        if ($roleGrants.Count) {
            # closest role = the first that names the failing field; else first that has the object
            $failFields = @($chk.reqs | ForEach-Object { $_.field })
            $pick = @($roleGrants | Where-Object { $rg=$_; @($failFields | Where-Object { $rg.fields.ContainsKey($_) }).Count -gt 0 } | Select-Object -First 1)
            if (-not $pick) { $pick = @($roleGrants | Select-Object -First 1) }
            if ($pick) { $closest = $pick.role
                $grantsStr = (@($pick.fields.Keys | ForEach-Object { $k=$_; "${k}:$($pick.fields[$k] -join '/')" }) -join ' ') }
        }

        $satisfied = Test-ObjectSatisfied $grant $chk.reqs
        $verdict = if ($satisfied) { 'PASS' }
                   elseif ($grant.rows -eq 0 -and -not $grant.fully) {
                       # buffer has nothing; but does a role design grant it? -> stale buffer
                       if ($roleGrants.Count) { 'BUFFER_STALE' } else { 'MISSING_OBJECT' }
                   } else { 'MISSING_VALUE' }
        # a MISSING_VALUE where a role design already covers the value is also stale
        if ($verdict -eq 'MISSING_VALUE' -and $roleGrants.Count) {
            $roleCovers = $false
            foreach ($rg in $roleGrants) {
                $all=$true
                foreach ($fr in $chk.reqs) {
                    $vals=@(); if ($rg.fields.ContainsKey($fr.field)) { $vals=@($rg.fields[$fr.field]) }
                    $hit = ($vals -contains '*') -or (-not $fr.value) -or ($vals -contains $fr.value)
                    if (-not $hit) { $all=$false; break }
                }
                if ($all) { $roleCovers=$true; break }
            }
            if ($roleCovers) { $verdict = 'BUFFER_STALE' }
        }

        if ($verdict -eq 'PASS') { $nPass++ } else { $nFail++ }
        # collect the closest role of a FAILING check as the actionable fix target
        if ($verdict -ne 'PASS' -and $closest -and -not $reportRoles.ContainsKey($closest)) { $reportRoles[$closest] = "closest_for_$obj" }
        Write-Host ("AUTHCHK: checkid={0} object={1} verdict={2} fully={3} req={4} closest_role={5} grants={6} otext={7}" -f `
            $chk.id, $obj, $verdict, $(if($grant.fully){'X'}else{'-'}), (Format-Reqs $chk.reqs), $(if($closest){$closest}else{'-'}), $grantsStr, $(if($otext){$otext}else{'-'}))
    }

    # --- surface ONLY actionable roles: fix-target(s) of failing checks + any expired assignment ---
    foreach ($ro in $roles) {
        $exp = ("$($ro.to)".Trim() -and "$($ro.to)".Trim() -ne '00000000' -and "$($ro.to)".Trim() -lt $today)
        if ($exp -and -not $reportRoles.ContainsKey($ro.role)) { $reportRoles[$ro.role] = 'expired_assignment' }
    }
    foreach ($rn in @($reportRoles.Keys)) {
        $meta = $roleMeta[$rn]; $fromD = if ($meta){"$($meta.from)"}else{''}; $toD = if ($meta){"$($meta.to)"}else{''}
        $exp = ($toD.Trim() -and $toD.Trim() -ne '00000000' -and $toD.Trim() -lt $today)
        $rtext = Read-RoleText -Dest $g_dest -Role $rn
        Write-Host ("ROLE: name={0} from={1} to={2} expired={3} reason={4} text={5}" -f $rn, $fromD, $toD, $(if($exp){'Y'}else{'N'}), $reportRoles[$rn], $(if($rtext){$rtext}else{'-'}))
    }

    Write-Host ("AUTHSUMMARY: checks={0} pass={1} fail={2} user={3} object_text_source={4}" -f $checks.Count, $nPass, $nFail, $U, $objTextSource)
    Write-Host "STATUS: OK"
    Disconnect-SapRfc $g_dest
    exit 0
} catch {
    Write-Host "AUTH: error=$($_.Exception.Message -replace '\s+',' ')"; Write-Host "STATUS: RFC_ERROR"; try { Disconnect-SapRfc $g_dest } catch {}; exit 2
}
