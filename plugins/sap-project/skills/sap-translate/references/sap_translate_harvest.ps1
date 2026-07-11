# =============================================================================
# sap_translate_harvest.ps1  -  translatable short-text harvester for /sap-translate (read-only)
#
# Collects every translatable short text for a scope in --from and --to language into a review
# TSV with the hard per-unit length limit, so Claude can propose length-checked translations for
# an operator to review BEFORE any write. Read-only (RFC_READ_TABLE FMODE=R + text-pool read).
#
# Types (probed identical S4D + EC2 2026-07-11):
#   msgclass  T100 (ARBGB=class, SPRSL in {from,to})                       -> MSG (max 73)
#   dtel      DD04T (DDTEXT/REPTEXT/SCRTEXT_S/M/L per ROLLNAME + DDLANGUAGE) -> DTEL_* limits
#   table     DD02T (table desc) + DD03T (direct-type field labels)         -> TABL/FIELD
#   domain    DD01T (domain desc) + DD07T (fixed-value texts)               -> DOMA/DD07
#   program   text pool via RS_TEXTPOOL_READ (v1.5 -- FMODE-blank, needs the wrapper)
#
#   -Object <name> -Type msgclass|dtel|table|domain  -To <LANG> [-From <LANG>]
#   [-LimitsFile <tsv>] [-Profile <hint>] -OutDir <dir>
#
# stdout: TR: obj=<o> unit=<u> key=<k> src="<..>" tgt="<..>" max=<n> status=<NEW|EXISTS> lines
#         + STATUS: OK units=<n>. Exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Object     = '',
    [string] $Type       = '',
    [string] $To         = '',
    [string] $From       = 'E',
    [string] $LimitsFile = '',
    [string] $Profile    = '',
    [string] $OutDir     = '',
    [string] $SharedDir  = '',
    [string] $RunId      = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }
function Add-Where { param($fn,[string]$where)
    if (-not $where) { return }
    $line=''
    foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }
    if ($line) { Add-RfcOption $fn $line }
}
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''
    if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where) { Add-Where $fn $where }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=(San $fm.GetString('FIELDNAME'));$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).TrimEnd()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out
}

# length limits
$limits = @{ MSG=73; DTEL_DDTEXT=60; DTEL_REPTEXT=55; DTEL_SCRTEXT_S=10; DTEL_SCRTEXT_M=20; DTEL_SCRTEXT_L=40; TABL_DDTEXT=60; FIELD_DDTEXT=60; DOMA_DDTEXT=60; DD07_DDTEXT=60 }
if (-not $LimitsFile) { $LimitsFile = Join-Path $PSScriptRoot 'translate_length_limits.tsv' }
if (Test-Path $LimitsFile) { foreach ($ln in ([IO.File]::ReadAllText($LimitsFile,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF) -split "`r`n|`n")) { if (-not $ln -or $ln.StartsWith('#') -or $ln.StartsWith('unit_type')) { continue }; $c=$ln -split "`t"; if ($c.Count -ge 3 -and ($c[2] -match '^\d+$')) { $limits[$c[0].Trim()]=[int]$c[2] } } }

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: TRANSLATE_INPUT no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
if (-not $Object -or -not $Type -or -not $To) { Write-Host 'STATUS: TRANSLATE_INPUT need_object_type_to'; exit 2 }
$obj=$Object.ToUpper(); $to=$To.ToUpper(); $from=$From.ToUpper()

$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile=$Profile"; exit 2 }
    $c = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("TRL_"+$c.system_name) } catch { }
} else { try { $d = Connect-SapRfc -DestName 'TRL' } catch { } }
if (-not $d) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
    $units=@()   # {obj_type;obj_name;unit_type;unit_key;src;tgt;max;status}
    function Add-Unit { param($ot,$on,$ut,$uk,$src,$tgt)
        $mx = if ($limits.ContainsKey($ut)) { $limits[$ut] } else { 60 }
        $st = if ($tgt) { 'EXISTS' } else { 'NEW' }
        $script:units += ,([pscustomobject]@{ obj_type=$ot; obj_name=$on; unit_type=$ut; unit_key=$uk; src=$src; tgt=$tgt; max=$mx; status=$st })
    }

    switch ($Type.ToLower()) {
        'msgclass' {
            $srcRows = @(Read-Rows $d 'T100' "SPRSL = '$from' AND ARBGB = '$obj'" @('MSGNR','TEXT') 2000)
            $tgtRows = @(Read-Rows $d 'T100' "SPRSL = '$to' AND ARBGB = '$obj'" @('MSGNR','TEXT') 2000)
            $tgtMap=@{}; foreach ($r in $tgtRows) { $tgtMap[$r.MSGNR]=$r.TEXT }
            foreach ($r in $srcRows) { Add-Unit 'MSGCLASS' $obj 'MSG' $r.MSGNR (San $r.TEXT) (San ($tgtMap[$r.MSGNR])) }
        }
        'dtel' {
            $srcRows = @(Read-Rows $d 'DD04T' "ROLLNAME = '$obj' AND DDLANGUAGE = '$from'" @('DDTEXT','REPTEXT','SCRTEXT_S','SCRTEXT_M','SCRTEXT_L') 5)
            $tgtRows = @(Read-Rows $d 'DD04T' "ROLLNAME = '$obj' AND DDLANGUAGE = '$to'" @('DDTEXT','REPTEXT','SCRTEXT_S','SCRTEXT_M','SCRTEXT_L') 5)
            $s = if ($srcRows.Count) { $srcRows[0] } else { $null }; $t = if ($tgtRows.Count) { $tgtRows[0] } else { $null }
            if ($s) { foreach ($f in @('DDTEXT','REPTEXT','SCRTEXT_S','SCRTEXT_M','SCRTEXT_L')) { $sv=San $s.$f; if ($sv) { Add-Unit 'DTEL' $obj "DTEL_$f" $f $sv (San $(if($t){$t.$f}else{''})) } } }
        }
        'table' {
            $s = @(Read-Rows $d 'DD02T' "TABNAME = '$obj' AND DDLANGUAGE = '$from'" @('DDTEXT') 1); $t = @(Read-Rows $d 'DD02T' "TABNAME = '$obj' AND DDLANGUAGE = '$to'" @('DDTEXT') 1)
            if ($s.Count) { Add-Unit 'TABLE' $obj 'TABL_DDTEXT' 'DDTEXT' (San $s[0].DDTEXT) (San $(if($t.Count){$t[0].DDTEXT}else{''})) }
            $fs = @(Read-Rows $d 'DD03T' "TABNAME = '$obj' AND DDLANGUAGE = '$from'" @('FIELDNAME','DDTEXT') 500); $ft = @(Read-Rows $d 'DD03T' "TABNAME = '$obj' AND DDLANGUAGE = '$to'" @('FIELDNAME','DDTEXT') 500)
            $ftMap=@{}; foreach ($r in $ft) { $ftMap[$r.FIELDNAME]=$r.DDTEXT }
            foreach ($r in $fs) { $sv=San $r.DDTEXT; if ($sv) { Add-Unit 'TABLE' $obj 'FIELD_DDTEXT' (San $r.FIELDNAME) $sv (San ($ftMap[$r.FIELDNAME])) } }
        }
        'domain' {
            $s = @(Read-Rows $d 'DD01T' "DOMNAME = '$obj' AND DDLANGUAGE = '$from'" @('DDTEXT') 1); $t = @(Read-Rows $d 'DD01T' "DOMNAME = '$obj' AND DDLANGUAGE = '$to'" @('DDTEXT') 1)
            if ($s.Count) { Add-Unit 'DOMAIN' $obj 'DOMA_DDTEXT' 'DDTEXT' (San $s[0].DDTEXT) (San $(if($t.Count){$t[0].DDTEXT}else{''})) }
            $vs = @(Read-Rows $d 'DD07T' "DOMNAME = '$obj' AND DDLANGUAGE = '$from'" @('DOMVALUE_L','DDTEXT') 200); $vt = @(Read-Rows $d 'DD07T' "DOMNAME = '$obj' AND DDLANGUAGE = '$to'" @('DOMVALUE_L','DDTEXT') 200)
            $vtMap=@{}; foreach ($r in $vt) { $vtMap[$r.DOMVALUE_L]=$r.DDTEXT }
            foreach ($r in $vs) { $sv=San $r.DDTEXT; if ($sv) { Add-Unit 'DOMAIN' $obj 'DD07_DDTEXT' (San $r.DOMVALUE_L) $sv (San ($vtMap[$r.DOMVALUE_L])) } }
        }
        default { Write-Host "STATUS: TRANSLATE_INPUT bad_type=$Type (v1: msgclass|dtel|table|domain; program text-pool is v1.5)"; Disconnect-SapRfc; exit 2 }
    }

    foreach ($u in $units) { Write-Host ("TR: obj=$($u.obj_name) unit=$($u.unit_type) key=$($u.unit_key) src=`"$($u.src)`" tgt=`"$($u.tgt)`" max=$($u.max) status=$($u.status)") }
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("seq`tobj_type`tobj_name`tunit_type`tunit_key`tsrc_lang`tsrc_text`ttgt_lang`tcurrent_tgt_text`tproposed_text`tmax_len`tstatus")
    $i=0; foreach ($u in $units) { $i++; [void]$sb.AppendLine((@($i,$u.obj_type,$u.obj_name,$u.unit_type,$u.unit_key,$from,$u.src,$to,$u.tgt,'',$u.max,$u.status) -join "`t")) }
    [IO.File]::WriteAllText((Join-Path $OutDir "translate_review.tsv"), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    Write-Host ("STATUS: OK units=$($units.Count) new=$(@($units|Where-Object{$_.status -eq 'NEW'}).Count) exists=$(@($units|Where-Object{$_.status -eq 'EXISTS'}).Count)")
    Disconnect-SapRfc; exit 0
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
