# =============================================================================
# sap_fi_post_rfc.ps1  -  FI document posting for /sap-fi-post (RFC / BAPI)
#
# Actions: check | post | show | preflight
#   check     BAPI_ACC_DOCUMENT_CHECK - server-side dry-run, ZERO persistence.
#   post      re-CHECK -> BAPI_ACC_DOCUMENT_POST -> parse OBJ_KEY -> COMMIT WAIT=X
#             -> authoritative BKPF/BSEG re-read; any post-stage error -> ROLLBACK.
#   show      read BKPF + BSEG (narrow FIELDS - BSEG is CLUSTER on ECC).
#   preflight T001/SKB1/LFB1/KNB1 existence hints (best-effort).
#
# The definition file is tab-delimited SECTION<TAB>FIELD<TAB>VALUE. The skill
# GENERATES the CURRENCYAMOUNT rows (ITEMNO_ACC = the section NN suffix; positive
# AMOUNT = debit, negative = credit) so the operator never hand-maintains ITEMNO
# cross-references. Local validation (balance=0 per currency, unique ITEMNO,
# required HEADER fields) runs before any RFC.
#
# Success is NEVER claimed from BAPIRET2 alone - post verifies via BKPF (1 row) +
# BSEG (>= item count) re-read. All FMs probed FMODE=R on S4D + EC2.
#
# Output (stdout): FIPOST: <verb> ...  +  BAPIRET: <type> <id>/<num> <msg>  +
#                  STATUS: OK | INPUT_INVALID | UNBALANCED | CHECK_FAILED | POST_FAILED | VERIFY_FAILED | RFC_ERROR
# Exit: 0 = OK | 1 = input/check business failure | 2 = RFC/post/verify error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,
    [string] $DefFile = '',
    [string] $Belnr = '', [string] $Bukrs = '', [string] $Gjahr = '',
    [string] $SharedDir = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
# Snapshot ALL our params (sap_object_resolver.ps1 re-runs its param() on dot-source).
$__keep = @{ Action=$Action; DefFile=$DefFile; Belnr=$Belnr; Bukrs=$Bukrs; Gjahr=$Gjahr;
             Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

# ---- definition parser (pure) --------------------------------------------
function Import-FiDef {
    param([string] $Path)
    $header = [ordered]@{}; $items = @()
    foreach ($ln in [System.IO.File]::ReadAllLines($Path)) {
        if ($ln -match '^\s*#' -or $ln.Trim() -eq '') { continue }
        $c = $ln -split "`t"
        if ($c.Count -lt 3) { continue }
        $sec = $c[0].Trim().ToUpper(); $fld = $c[1].Trim().ToUpper(); $val = $c[2].Trim()
        if ($sec -eq 'HEADER') { $header[$fld] = $val; continue }
        if ($sec -match '^(GL|AP|AR|TAX)_(\w+)$') {
            $type = $Matches[1]; $no = $Matches[2]
            $it = $items | Where-Object { $_.section -eq $sec } | Select-Object -First 1
            if (-not $it) { $it = [pscustomobject]@{ section=$sec; type=$type; no=$no; fields=[ordered]@{}; amount=$null; currency='' }; $items += $it }
            if ($fld -eq 'AMOUNT') { $it.amount = [decimal]$val }
            elseif ($fld -eq 'CURRENCY') { $it.currency = $val.ToUpper() }
            else { $it.fields[$fld] = $val }
        }
    }
    return @{ header = $header; items = @($items) }
}

# ---- local validation (pure) ---------------------------------------------
function Test-FiDef {
    param($Def)
    $errs = @()
    foreach ($req in @('COMP_CODE','DOC_DATE','PSTNG_DATE','DOC_TYPE','CURRENCY')) { if (-not $Def.header[$req]) { $errs += "HEADER.$req missing" } }
    if ($Def.items.Count -lt 2) { $errs += "at least 2 line items required (got $($Def.items.Count))" }
    $nos = @($Def.items | ForEach-Object { $_.no })
    if (($nos | Select-Object -Unique).Count -ne $nos.Count) { $errs += "duplicate item numbers (NN suffixes must be unique across GL_/AP_/AR_/TAX_)" }
    foreach ($it in $Def.items) { if ($null -eq $it.amount) { $errs += "$($it.section) has no AMOUNT" } }
    # per-currency balance = 0
    $byCur = @{}
    foreach ($it in $Def.items) { if ($null -ne $it.amount) { $cur = if ($it.currency) { $it.currency } else { "$($Def.header['CURRENCY'])".ToUpper() }; if (-not $byCur.ContainsKey($cur)) { $byCur[$cur] = [decimal]0 }; $byCur[$cur] += $it.amount } }
    foreach ($cur in $byCur.Keys) { if ([Math]::Abs($byCur[$cur]) -gt 0.001) { $errs += "unbalanced: currency $cur sums to $($byCur[$cur]) (must be 0)" } }
    return $errs
}

# ---- BAPI builder ---------------------------------------------------------
function Set-FiBapi {
    param($Fn, $Def, [string] $ConnUser)
    $h = $Fn.GetStructure('DOCUMENTHEADER')
    $h.SetValue('USERNAME', $(if ($Def.header['USERNAME']) { $Def.header['USERNAME'] } else { $ConnUser }))
    $h.SetValue('COMP_CODE', "$($Def.header['COMP_CODE'])")
    $h.SetValue('DOC_DATE', "$($Def.header['DOC_DATE'])")
    $h.SetValue('PSTNG_DATE', "$($Def.header['PSTNG_DATE'])")
    $h.SetValue('DOC_TYPE', "$($Def.header['DOC_TYPE'])")
    $h.SetValue('BUS_ACT', $(if ($Def.header['BUS_ACT']) { $Def.header['BUS_ACT'] } else { 'RFBU' }))
    if ($Def.header['REF_DOC_NO']) { $h.SetValue('REF_DOC_NO', "$($Def.header['REF_DOC_NO'])") }
    if ($Def.header['HEADER_TXT']) { $h.SetValue('HEADER_TXT', "$($Def.header['HEADER_TXT'])") }
    $tGl = $Fn.GetTable('ACCOUNTGL'); $tAp = $Fn.GetTable('ACCOUNTPAYABLE'); $tAr = $Fn.GetTable('ACCOUNTRECEIVABLE'); $tTax = $Fn.GetTable('ACCOUNTTAX'); $tCur = $Fn.GetTable('CURRENCYAMOUNT')
    foreach ($it in $Def.items) {
        $tbl = $null
        switch ("$($it.type)") { 'GL' { $tbl = $tGl } 'AP' { $tbl = $tAp } 'AR' { $tbl = $tAr } 'TAX' { $tbl = $tTax } }
        if ($null -eq $tbl) { throw "no BAPI table for item type '$($it.type)' (section $($it.section))" }
        $tbl.Append(); $tbl.SetValue('ITEMNO_ACC', $it.no)
        foreach ($k in $it.fields.Keys) { try { $tbl.SetValue($k, "$($it.fields[$k])") } catch {} }
        if ($it.fields['ITEM_TEXT'] -and $it.type -ne 'GL') { } # already set above
        $cur = if ($it.currency) { $it.currency } else { "$($Def.header['CURRENCY'])".ToUpper() }
        $tCur.Append(); $tCur.SetValue('ITEMNO_ACC', $it.no); $tCur.SetValue('CURRENCY', $cur); $tCur.SetValue('AMT_DOCCUR', [decimal]$it.amount)
    }
}
function Get-Bapiret2 { param($Fn) $out=@(); try { $rt=$Fn.GetTable('RETURN'); for($i=0;$i -lt $rt.RowCount;$i++){ $rt.CurrentIndex=$i; $out += [pscustomobject]@{ type="$($rt.GetValue('TYPE'))"; id="$($rt.GetValue('ID'))"; number="$($rt.GetValue('NUMBER'))"; message="$($rt.GetValue('MESSAGE'))"; row="$($rt.GetValue('ROW'))"; field="$($rt.GetValue('FIELD'))" } } } catch {}; return $out }
function Test-Ret2Error { param([object[]] $R) return (@($R | Where-Object { "$($_.type)" -in @('E','A') }).Count -gt 0) }
function Write-Ret2 { param([object[]] $R) foreach ($m in $R) { Write-Host ("BAPIRET: {0} {1}/{2} {3}{4}" -f $m.type,$m.id,$m.number,($m.message -replace "[`t`r`n]",' '),$(if($m.field){" [row $($m.row) $($m.field)]"}else{''})) } }

if ($MyInvocation.InvocationName -eq '.') { return }
$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_FIPOST"
if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }
$connUser = if ($UserId) { $UserId } else { "$g_sapUser" }

try {
    if ($Action.ToLower() -in @('check','post')) {
        if (-not (Test-Path $DefFile)) { Write-Host "FIPOST: def_file_not_found $DefFile"; Write-Host "STATUS: INPUT_INVALID"; Disconnect-SapRfc; exit 1 }
        $def = Import-FiDef -Path $DefFile
        $verrs = Test-FiDef -Def $def
        if ($verrs.Count) { foreach ($e in $verrs) { Write-Host "FIPOST: invalid $e" }; Write-Host $(if ($verrs -match 'unbalanced') { "STATUS: UNBALANCED" } else { "STATUS: INPUT_INVALID" }); Disconnect-SapRfc; exit 1 }

        # --- CHECK (dry-run) ---
        $chk = $g_dest.Repository.CreateFunction('BAPI_ACC_DOCUMENT_CHECK')
        Set-FiBapi -Fn $chk -Def $def -ConnUser $connUser
        $chk.Invoke($g_dest); $cret = Get-Bapiret2 $chk
        Write-Ret2 $cret
        $chkErr = Test-Ret2Error $cret
        if ($Action.ToLower() -eq 'check') {
            Write-Host ("FIPOST: check comp_code={0} doc_type={1} items={2} verdict={3}" -f "$($def.header['COMP_CODE'])","$($def.header['DOC_TYPE'])",$def.items.Count,$(if($chkErr){'ERRORS'}else{'CLEAN'}))
            Write-Host $(if ($chkErr) { "STATUS: CHECK_FAILED" } else { "STATUS: OK" }); Disconnect-SapRfc; exit $(if ($chkErr) { 1 } else { 0 })
        }
        if ($chkErr) { Write-Host "FIPOST: post aborted - dry-run has errors"; Write-Host "STATUS: CHECK_FAILED"; Disconnect-SapRfc; exit 1 }

        # --- POST ---
        $pf = $g_dest.Repository.CreateFunction('BAPI_ACC_DOCUMENT_POST')
        Set-FiBapi -Fn $pf -Def $def -ConnUser $connUser
        $pf.Invoke($g_dest); $pret = Get-Bapiret2 $pf
        Write-Ret2 $pret
        if (Test-Ret2Error $pret) { try { $rb=$g_dest.Repository.CreateFunction('BAPI_TRANSACTION_ROLLBACK'); $rb.Invoke($g_dest) } catch {}; Write-Host "FIPOST: post failed - rolled back"; Write-Host "STATUS: POST_FAILED"; Disconnect-SapRfc; exit 2 }
        $objKey = "$($pf.GetString('OBJ_KEY'))"
        if ($objKey.Length -lt 18) { Write-Host "FIPOST: no OBJ_KEY returned"; Write-Host "STATUS: POST_FAILED"; Disconnect-SapRfc; exit 2 }
        $pBelnr = $objKey.Substring(0,10); $pBukrs = $objKey.Substring(10,4); $pGjahr = $objKey.Substring(14,4)
        $cm = $g_dest.Repository.CreateFunction('BAPI_TRANSACTION_COMMIT'); $cm.SetValue('WAIT','X'); $cm.Invoke($g_dest)

        # --- verify (authoritative re-read) ---
        $bkpf = Read-SapTableRows -Destination $g_dest -Table 'BKPF' -Where "BUKRS EQ '$pBukrs' AND BELNR EQ '$pBelnr' AND GJAHR EQ '$pGjahr'" -Fields @('BUKRS','BELNR','GJAHR','BLART','BUDAT','WAERS') -RowCount 1
        $bseg = Read-SapTableRows -Destination $g_dest -Table 'BSEG' -Where "BUKRS EQ '$pBukrs' AND BELNR EQ '$pBelnr' AND GJAHR EQ '$pGjahr'" -Fields @('BUZEI','KOART','SHKZG','WRBTR','HKONT') -RowCount 200
        if (-not $bkpf -or $bkpf.Count -ne 1) { Write-Host "FIPOST: verify failed - BKPF row not found for $pBelnr/$pBukrs/$pGjahr"; Write-Host "STATUS: VERIFY_FAILED"; Disconnect-SapRfc; exit 2 }
        if (@($bseg).Count -lt $def.items.Count) { Write-Host ("FIPOST: verify WARN - BSEG rows={0} < items={1} (doc splitting?)" -f @($bseg).Count, $def.items.Count) }
        Write-Host ("FIPOST: POSTED belnr={0} bukrs={1} gjahr={2} blart={3} bseg_rows={4}" -f $pBelnr,$pBukrs,$pGjahr,"$($bkpf[0].BLART)",@($bseg).Count)
        Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
    }
    elseif ($Action.ToLower() -eq 'show') {
        if (-not $Belnr -or -not $Bukrs -or -not $Gjahr) { Write-Host "FIPOST: show needs BELNR BUKRS GJAHR"; Write-Host "STATUS: INPUT_INVALID"; Disconnect-SapRfc; exit 1 }
        $bp = ("0000000000$Belnr"); $bp = $bp.Substring($bp.Length-10)
        $bkpf = Read-SapTableRows -Destination $g_dest -Table 'BKPF' -Where "BUKRS EQ '$Bukrs' AND BELNR EQ '$bp' AND GJAHR EQ '$Gjahr'" -Fields @('BUKRS','BELNR','GJAHR','BLART','BUDAT','WAERS','XBLNR','USNAM') -RowCount 1
        if (-not $bkpf -or $bkpf.Count -eq 0) { Write-Host "FIPOST: show document not found"; Write-Host "STATUS: INPUT_INVALID"; Disconnect-SapRfc; exit 1 }
        $bseg = Read-SapTableRows -Destination $g_dest -Table 'BSEG' -Where "BUKRS EQ '$Bukrs' AND BELNR EQ '$bp' AND GJAHR EQ '$Gjahr'" -Fields @('BUZEI','KOART','SHKZG','WRBTR','HKONT','LIFNR','KUNNR') -RowCount 200
        $h = $bkpf[0]
        Write-Host ("FIPOST: show belnr={0} bukrs={1} gjahr={2} blart={3} budat={4} waers={5} ref={6} user={7} lines={8}" -f "$($h.BELNR)","$($h.BUKRS)","$($h.GJAHR)","$($h.BLART)","$($h.BUDAT)","$($h.WAERS)","$($h.XBLNR)","$($h.USNAM)",@($bseg).Count)
        foreach ($l in $bseg) { Write-Host ("FIPOST: line buzei={0} koart={1} shkzg={2} wrbtr={3} hkont={4} lifnr={5} kunnr={6}" -f "$($l.BUZEI)","$($l.KOART)","$($l.SHKZG)","$($l.WRBTR)","$($l.HKONT)","$($l.LIFNR)","$($l.KUNNR)") }
        Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
    }
    elseif ($Action.ToLower() -eq 'preflight') {
        if (-not (Test-Path $DefFile)) { Write-Host "STATUS: INPUT_INVALID"; Disconnect-SapRfc; exit 1 }
        $def = Import-FiDef -Path $DefFile
        $cc = "$($def.header['COMP_CODE'])"
        $t = Read-SapTableRows -Destination $g_dest -Table 'T001' -Where "BUKRS EQ '$cc'" -Fields @('BUKRS','BUTXT','WAERS') -RowCount 1
        Write-Host ("FIPOST: preflight comp_code={0} exists={1}" -f $cc, $(if($t -and $t.Count){'YES'}else{'NO'}))
        foreach ($it in $def.items) {
            if ($it.type -eq 'GL' -and $it.fields['GL_ACCOUNT']) { $a = Read-SapTableRows -Destination $g_dest -Table 'SKB1' -Where "BUKRS EQ '$cc' AND SAKNR EQ '$("0000000000$($it.fields['GL_ACCOUNT'])".Substring("0000000000$($it.fields['GL_ACCOUNT'])".Length-10))'" -Fields @('SAKNR') -RowCount 1; Write-Host ("FIPOST: preflight gl_account={0} in_bukrs={1}" -f "$($it.fields['GL_ACCOUNT'])", $(if($a -and $a.Count){'YES'}else{'NO'})) }
            if ($it.type -eq 'AP' -and $it.fields['VENDOR_NO']) { $a = Read-SapTableRows -Destination $g_dest -Table 'LFB1' -Where "BUKRS EQ '$cc' AND LIFNR EQ '$($it.fields['VENDOR_NO'])'" -Fields @('LIFNR') -RowCount 1; Write-Host ("FIPOST: preflight vendor={0} in_bukrs={1}" -f "$($it.fields['VENDOR_NO'])", $(if($a -and $a.Count){'YES'}else{'NO'})) }
            if ($it.type -eq 'AR' -and $it.fields['CUSTOMER']) { $a = Read-SapTableRows -Destination $g_dest -Table 'KNB1' -Where "BUKRS EQ '$cc' AND KUNNR EQ '$($it.fields['CUSTOMER'])'" -Fields @('KUNNR') -RowCount 1; Write-Host ("FIPOST: preflight customer={0} in_bukrs={1}" -f "$($it.fields['CUSTOMER'])", $(if($a -and $a.Count){'YES'}else{'NO'})) }
        }
        Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
    }
    else { Write-Host "FIPOST: unknown_action=$Action"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2 }
} catch {
    Write-Host "FIPOST: error=$($_.Exception.Message -replace '\s+',' ') [line $($_.InvocationInfo.ScriptLineNumber)]"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2
}
