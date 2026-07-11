# =============================================================================
# sap_tcd_chain_rfc.ps1  -  Headless O2C document chain for /sap-tcd-chain (RFC)
#
# Actions: preflight | create-order | create-delivery | post-gi | create-billing
#          | verify-flow
#   Each write BAPI is followed by BAPI_TRANSACTION_COMMIT (WAIT='X'); any RETURN
#   type E/A -> BAPI_TRANSACTION_ROLLBACK + stop. Success is verified by an
#   authoritative VBFA / VBAK re-read (VBTYP_N J=delivery, R=GI, M=billing) - never
#   trusted from the BAPI echo. All v1 FMs probed FMODE=R on S4D + EC2.
#
#   create-order supports -TestRun X  (BAPI_SALESORDER_CREATEFROMDAT2 TESTRUN) for a
#   zero-persistence simulate - the same server-side validation /sap-fi-post's CHECK
#   gives, used by `--dry-run`.
#
# The scenario file is tab-delimited SECTION<TAB>FIELD<TAB>VALUE (ORDER_HEADER,
# ORDER_PARTNER, ORDER_ITEM_NN, DELIVERY, BILLING).
#
# VBUK is NEVER read (semantically dead on S/4 for new docs); VBFA is the single
# linkage-verification source, identical on both releases.
#
# Output (stdout): STEP: <name> <OK|FAILED> key=<doc> ...  +  BAPIRET: <t> <id>/<n> <msg>
#                  STATUS: OK | SCENARIO_INVALID | STEP_FAILED | VERIFY_FAILED | RFC_ERROR
# Exit: 0 = OK | 1 = scenario/step business failure | 2 = RFC/verify error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,
    [string] $Scenario = '',
    [string] $Order = '', [string] $Delivery = '',
    [string] $TestRun = '',
    [string] $SharedDir = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Action=$Action; Scenario=$Scenario; Order=$Order; Delivery=$Delivery; TestRun=$TestRun;
             Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

# ---- scenario parser (pure) ----------------------------------------------
function Import-Scenario {
    param([string] $Path)
    $s = @{ header=[ordered]@{}; partners=@(); items=@(); delivery=[ordered]@{}; billing=[ordered]@{} }
    foreach ($ln in [System.IO.File]::ReadAllLines($Path)) {
        if ($ln -match '^\s*#' -or $ln.Trim() -eq '') { continue }
        $c = $ln -split "`t"; if ($c.Count -lt 3) { continue }
        $sec = $c[0].Trim().ToUpper(); $fld = $c[1].Trim().ToUpper(); $val = $c[2].Trim()
        switch -Regex ($sec) {
            '^ORDER_HEADER$'  { $s.header[$fld] = $val }
            '^ORDER_PARTNER'  { $p = $s.partners | Where-Object { $_.sec -eq $sec } | Select-Object -First 1; if (-not $p) { $p = [ordered]@{ sec=$sec; role=''; number='' }; $s.partners += $p }; if ($fld -eq 'ROLE') { $p.role = $val.ToUpper() } elseif ($fld -eq 'NUMBER') { $p.number = $val } }
            '^ORDER_ITEM_(\w+)$' { $no = $Matches[1]; $it = $s.items | Where-Object { $_.no -eq $no } | Select-Object -First 1; if (-not $it) { $it = [ordered]@{ no=$no; material=''; qty='' }; $s.items += $it }; if ($fld -eq 'MATERIAL') { $it.material = $val } elseif ($fld -eq 'QTY') { $it.qty = $val } }
            '^DELIVERY$'      { $s.delivery[$fld] = $val }
            '^BILLING$'       { $s.billing[$fld] = $val }
        }
    }
    return $s
}
function Test-Scenario {
    param($S)
    $e = @()
    foreach ($r in @('DOC_TYPE','SALES_ORG','DISTR_CHAN','DIVISION')) { if (-not $S.header[$r]) { $e += "ORDER_HEADER.$r missing" } }
    if (@($S.partners | Where-Object { $_.role -eq 'AG' }).Count -lt 1) { $e += "an ORDER_PARTNER with ROLE=AG (sold-to) is required" }
    if ($S.items.Count -lt 1) { $e += "at least one ORDER_ITEM_NN is required" }
    foreach ($it in $S.items) { if (-not $it.material) { $e += "item $($it.no) has no MATERIAL" }; if (-not $it.qty) { $e += "item $($it.no) has no QTY" } }
    return $e
}
# ALPHA conversion: zero-pad numeric keys to 10; leave alphanumeric (e.g. J_KLYY) as-is.
function Convert-Alpha { param([string] $v) if ($v -match '^\d+$') { $p = "0000000000$v"; return $p.Substring($p.Length - 10) } else { return $v.ToUpper() } }
function Get-Bapiret2 { param($Fn) $out=@(); try { $rt=$Fn.GetTable('RETURN'); for($i=0;$i -lt $rt.RowCount;$i++){ $rt.CurrentIndex=$i; $out += [pscustomobject]@{ type="$($rt.GetValue('TYPE'))"; id="$($rt.GetValue('ID'))"; number="$($rt.GetValue('NUMBER'))"; message="$($rt.GetValue('MESSAGE'))" } } } catch {}; return $out }
function Test-Ret2Error { param([object[]] $R) return (@($R | Where-Object { "$($_.type)" -in @('E','A') }).Count -gt 0) }
function Write-Ret2 { param([object[]] $R) foreach ($m in $R) { Write-Host ("BAPIRET: {0} {1}/{2} {3}" -f $m.type,$m.id,$m.number,($m.message -replace "[`t`r`n]",' ')) } }
function Invoke-Commit { param($D) $c=$D.Repository.CreateFunction('BAPI_TRANSACTION_COMMIT'); $c.SetValue('WAIT','X'); $c.Invoke($D) }
function Invoke-Rollback { param($D) try { $r=$D.Repository.CreateFunction('BAPI_TRANSACTION_ROLLBACK'); $r.Invoke($D) } catch {} }
# VBFA linkage read with backoff (V2 update lag): successor doc of a given VBTYP_N.
function Get-Successor { param($D, [string] $Predec, [string] $Vbtyp)
    foreach ($wait in @(0,1,2,4)) { if ($wait) { Start-Sleep -Seconds $wait }
        $f = Read-SapTableRows -Destination $D -Table 'VBFA' -Where "VBELV EQ '$($Predec -replace "'","''")' AND VBTYP_N EQ '$Vbtyp'" -Fields @('VBELN','VBTYP_N') -RowCount 5
        $doc = @($f | ForEach-Object { "$($_.VBELN)" } | Where-Object { $_ } | Select-Object -Unique)
        if ($doc.Count) { return $doc[0] }
    }
    return ''
}

if ($MyInvocation.InvocationName -eq '.') { return }
$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_TCD"
if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

try {
    switch ($Action.ToLower()) {
        'preflight' {
            if (-not (Test-Path $Scenario)) { Write-Host "STATUS: SCENARIO_INVALID"; Disconnect-SapRfc; exit 1 }
            $s = Import-Scenario -Path $Scenario
            $errs = Test-Scenario -S $s
            if ($errs.Count) { foreach ($e in $errs) { Write-Host "STEP: scenario INVALID $e" }; Write-Host "STATUS: SCENARIO_INVALID"; Disconnect-SapRfc; exit 1 }
            $ag = ($s.partners | Where-Object { $_.role -eq 'AG' } | Select-Object -First 1).number
            $k = Read-SapTableRows -Destination $g_dest -Table 'KNA1' -Where "KUNNR EQ '$($ag -replace "'","''")'" -Fields @('KUNNR') -RowCount 1
            Write-Host ("STEP: preflight sold_to={0} exists={1}" -f $ag, $(if($k -and $k.Count){'YES'}else{'NO'}))
            foreach ($it in $s.items) { $m = Read-SapTableRows -Destination $g_dest -Table 'MARA' -Where "MATNR EQ '$($it.material -replace "'","''")'" -Fields @('MATNR') -RowCount 1; Write-Host ("STEP: preflight material={0} exists={1}" -f $it.material, $(if($m -and $m.Count){'YES'}else{'NO'})) }
            Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'create-order' {
            if (-not (Test-Path $Scenario)) { Write-Host "STATUS: SCENARIO_INVALID"; Disconnect-SapRfc; exit 1 }
            $s = Import-Scenario -Path $Scenario
            $errs = Test-Scenario -S $s
            if ($errs.Count) { foreach ($e in $errs) { Write-Host "STEP: scenario INVALID $e" }; Write-Host "STATUS: SCENARIO_INVALID"; Disconnect-SapRfc; exit 1 }
            $fn = $g_dest.Repository.CreateFunction('BAPI_SALESORDER_CREATEFROMDAT2')
            $h = $fn.GetStructure('ORDER_HEADER_IN')
            $h.SetValue('DOC_TYPE', "$($s.header['DOC_TYPE'])"); $h.SetValue('SALES_ORG', "$($s.header['SALES_ORG'])"); $h.SetValue('DISTR_CHAN', "$($s.header['DISTR_CHAN'])"); $h.SetValue('DIVISION', "$($s.header['DIVISION'])")
            if ($s.header['PURCH_NO_C']) { $h.SetValue('PURCH_NO_C', "$($s.header['PURCH_NO_C'])") }
            $tp = $fn.GetTable('ORDER_PARTNERS'); foreach ($p in $s.partners) { if ($p.role -and $p.number) { $tp.Append(); $tp.SetValue('PARTN_ROLE', $p.role); $tp.SetValue('PARTN_NUMB', (Convert-Alpha "$($p.number)")) } }
            $ti = $fn.GetTable('ORDER_ITEMS_IN'); $tsch = $fn.GetTable('ORDER_SCHEDULES_IN')
            foreach ($it in $s.items) { $itm = ("000000$($it.no)"); $itm = $itm.Substring($itm.Length-6); $ti.Append(); $ti.SetValue('ITM_NUMBER', $itm); $ti.SetValue('MATERIAL', $it.material); $tsch.Append(); $tsch.SetValue('ITM_NUMBER', $itm); $tsch.SetValue('SCHED_LINE','0001'); $tsch.SetValue('REQ_QTY', [decimal]$it.qty) }
            if ($TestRun) { $fn.SetValue('TESTRUN', 'X') }
            $fn.Invoke($g_dest); $ret = Get-Bapiret2 $fn; Write-Ret2 $ret
            if (Test-Ret2Error $ret) { Invoke-Rollback $g_dest; Write-Host "STEP: create-order FAILED"; Write-Host "STATUS: STEP_FAILED"; Disconnect-SapRfc; exit 1 }
            $doc = "$($fn.GetString('SALESDOCUMENT'))".TrimStart('0')
            if ($TestRun) { Write-Host ("STEP: create-order OK testrun=X verdict=CLEAN"); Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0 }
            Invoke-Commit $g_dest
            $v = Read-SapTableRows -Destination $g_dest -Table 'VBAK' -Where "VBELN EQ '$(("0000000000$doc").Substring(("0000000000$doc").Length-10))'" -Fields @('VBELN','AUART') -RowCount 1
            if (-not $v -or $v.Count -eq 0) { Write-Host "STEP: create-order VERIFY_FAILED (no VBAK row for $doc)"; Write-Host "STATUS: VERIFY_FAILED"; Disconnect-SapRfc; exit 2 }
            Write-Host ("STEP: create-order OK key={0}" -f $doc); Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'create-delivery' {
            if (-not $Order) { Write-Host "STATUS: SCENARIO_INVALID"; Disconnect-SapRfc; exit 1 }
            $s = if (Test-Path $Scenario) { Import-Scenario -Path $Scenario } else { @{ delivery=[ordered]@{} } }
            $fn = $g_dest.Repository.CreateFunction('BAPI_OUTB_DELIVERY_CREATE_SLS')
            $t = $fn.GetTable('SALES_ORDER_ITEMS'); $t.Append(); $t.SetValue('REF_DOC', ("0000000000$Order").Substring(("0000000000$Order").Length-10))
            if ($s.delivery['SHIP_POINT']) { try { $fn.SetValue('SHIP_POINT', "$($s.delivery['SHIP_POINT'])") } catch {} }
            $fn.Invoke($g_dest); $ret = Get-Bapiret2 $fn; Write-Ret2 $ret
            if (Test-Ret2Error $ret) { Invoke-Rollback $g_dest; Write-Host "STEP: create-delivery FAILED"; Write-Host "STATUS: STEP_FAILED"; Disconnect-SapRfc; exit 1 }
            Invoke-Commit $g_dest
            $dlv = Get-Successor -D $g_dest -Predec (("0000000000$Order").Substring(("0000000000$Order").Length-10)) -Vbtyp 'J'
            if (-not $dlv) { Write-Host "STEP: create-delivery VERIFY_FAILED (no VBFA J-successor)"; Write-Host "STATUS: VERIFY_FAILED"; Disconnect-SapRfc; exit 2 }
            Write-Host ("STEP: create-delivery OK key={0}" -f $dlv); Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'post-gi' {
            if (-not $Delivery) { Write-Host "STATUS: SCENARIO_INVALID"; Disconnect-SapRfc; exit 1 }
            $dl = ("0000000000$Delivery").Substring(("0000000000$Delivery").Length-10)
            $fn = $g_dest.Repository.CreateFunction('WS_DELIVERY_UPDATE')
            $vbkok = $fn.GetStructure('VBKOK_WA'); $vbkok.SetValue('VBELN_VL', $dl); $vbkok.SetValue('WABUC', 'X')
            try { $fn.SetValue('COMMIT', 'X') } catch {}; try { $fn.SetValue('DELIVERY', $dl) } catch {}
            $fn.Invoke($g_dest); $ret = Get-Bapiret2 $fn; Write-Ret2 $ret
            if (Test-Ret2Error $ret) { Invoke-Rollback $g_dest; Write-Host "STEP: post-gi FAILED"; Write-Host "STATUS: STEP_FAILED"; Disconnect-SapRfc; exit 1 }
            Invoke-Commit $g_dest
            $mat = Get-Successor -D $g_dest -Predec $dl -Vbtyp 'R'
            if (-not $mat) { Write-Host "STEP: post-gi VERIFY_FAILED (no VBFA R-successor)"; Write-Host "STATUS: VERIFY_FAILED"; Disconnect-SapRfc; exit 2 }
            Write-Host ("STEP: post-gi OK key={0}" -f $mat); Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'create-billing' {
            if (-not $Delivery) { Write-Host "STATUS: SCENARIO_INVALID"; Disconnect-SapRfc; exit 1 }
            $dl = ("0000000000$Delivery").Substring(("0000000000$Delivery").Length-10)
            $fn = $g_dest.Repository.CreateFunction('BAPI_BILLINGDOC_CREATEMULTIPLE')
            $t = $fn.GetTable('BILLINGDATAIN'); $t.Append(); $t.SetValue('REF_DOC', $dl); $t.SetValue('REF_DOC_CA', 'J')
            $fn.Invoke($g_dest); $ret = Get-Bapiret2 $fn; Write-Ret2 $ret
            if (Test-Ret2Error $ret) { Invoke-Rollback $g_dest; Write-Host "STEP: create-billing FAILED"; Write-Host "STATUS: STEP_FAILED"; Disconnect-SapRfc; exit 1 }
            Invoke-Commit $g_dest
            $bill = Get-Successor -D $g_dest -Predec $dl -Vbtyp 'M'
            if (-not $bill) { Write-Host "STEP: create-billing VERIFY_FAILED (no VBFA M-successor)"; Write-Host "STATUS: VERIFY_FAILED"; Disconnect-SapRfc; exit 2 }
            Write-Host ("STEP: create-billing OK key={0}" -f $bill); Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'verify-flow' {
            if (-not $Order) { Write-Host "STATUS: SCENARIO_INVALID"; Disconnect-SapRfc; exit 1 }
            $o = ("0000000000$Order").Substring(("0000000000$Order").Length-10)
            $va = Read-SapTableRows -Destination $g_dest -Table 'VBAK' -Where "VBELN EQ '$o'" -Fields @('VBELN','AUART') -RowCount 1
            Write-Host ("STEP: verify order={0} exists={1}" -f $Order, $(if($va -and $va.Count){'VERIFIED'}else{'GONE'}))
            foreach ($vt in @(@{v='J';n='delivery'},@{v='R';n='goods-issue'},@{v='M';n='billing'})) {
                $suc = Get-Successor -D $g_dest -Predec $o -Vbtyp $vt.v
                Write-Host ("STEP: verify {0}={1} status={2}" -f $vt.n, $(if($suc){$suc}else{'-'}), $(if($suc){'VERIFIED'}else{'MISSING'}))
            }
            Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        default { Write-Host "STEP: unknown_action=$Action"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2 }
    }
} catch {
    Write-Host "STEP: error=$($_.Exception.Message -replace '\s+',' ') [line $($_.InvocationInfo.ScriptLineNumber)]"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2
}
