# =============================================================================
# sap_scratch_fm.ps1  -  call any function module + capture result + runtime, for
#                        /sap-scratch-run 'fm'.
#
# Routes by TFDIR.FMODE: 'R' (remote-enabled) -> direct NCo call; blank (classic non-RFC)
# -> Z_GENERIC_RFC_WRAPPER_TBL (asXML PARAMETER-TABLE, the proven bridge). Marshals scalar
# IMPORTING params from -Values "P=v;P2=v2"; captures EXPORTING scalars, CHANGING, and TABLES
# row counts; times the call with Measure-Command (wall-clock ms). Read-oriented probe -- an
# FM MAY still mutate/COMMIT, which the caller confirm-gates (this script does not judge that).
#
# Args: -Fm <NAME> [-Values "P=v;P2=v2"] [-SharedDir <dir>] + standard connection params.
# Output: FM:route ... / FM:export <name>=<val> / FM:table <name> rows=<n> / FM:timing ms=<n>
#         STATUS: OK | FM_NOT_FOUND | FM_PROBE_WRAPPER_FAILED | RFC_ERROR
# Exit: 0 ok | 1 business | 2 rfc.  32-bit PowerShell (NCo 3.1).
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Fm,
    [string] $Values = '',
    [string] $WrapperFm = 'Z_GENERIC_RFC_WRAPPER_TBL',
    [string] $SharedDir = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) {   # scratch-run lives INSIDE sap-dev-core (=> ..\..\..\shared); satellite plugins => ..\..\..\..\sap-dev-core\shared
    foreach ($rel in @('..\..\..\shared','..\..\..\..\sap-dev-core\shared')) {
        try { $c = (Resolve-Path (Join-Path $PSScriptRoot $rel) -ErrorAction Stop).Path; if ($c -and (Test-Path -LiteralPath $c)) { $SharedDir = $c; break } } catch {}
    }
}
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Fm=$Fm; Values=$Values; WrapperFm=$WrapperFm; Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

# ---- parse -Values "P=v;P2=v2" ----
$inputs = @{}
foreach ($pair in ($Values -split ';' | Where-Object { $_.Trim() })) { $kv = $pair -split '=', 2; if ($kv.Count -eq 2 -and $kv[0].Trim()) { $inputs[$kv[0].Trim().ToUpper()] = $kv[1] } }

# ---- asXML helpers (wrapper route) ----
$ASX_HEAD='<asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>'; $ASX_TAIL='</DATA></asx:values></asx:abap>'
function Esc([string]$v){ [System.Security.SecurityElement]::Escape([string]$v) }
function New-AsxScalar([string]$v){ $ASX_HEAD + (Esc $v) + $ASX_TAIL }
$CHUNK=1333
function Add-Param($tbl,[string]$pn,[string]$pt,[string]$ptn,[string]$payload){
    if ([string]::IsNullOrEmpty($payload)) { [void]$tbl.Append(); $tbl.SetValue('PNAME',$pn); $tbl.SetValue('PSEQ',1); $tbl.SetValue('PTYPE',$pt); $tbl.SetValue('PTYPENAME',$ptn); return }
    $len=$payload.Length; $off=0; $seq=0
    while ($off -lt $len) { $seq++; $take=[Math]::Min($CHUNK,$len-$off); [void]$tbl.Append(); $tbl.SetValue('PNAME',$pn); $tbl.SetValue('PSEQ',$seq); $tbl.SetValue('PTYPE',$pt); $tbl.SetValue('PTYPENAME',$ptn); $tbl.SetValue('PVALUE',$payload.Substring($off,$take)); $off+=$CHUNK }
}
function Get-OutScalar($fn,[string]$pname){
    $t=$fn.GetTable('CT_PARAMS'); $parts=@{}
    for ($i=0;$i -lt $t.RowCount;$i++){ $t.CurrentIndex=$i; if ("$($t.GetString('PNAME'))".Trim() -ne $pname){continue}
        $ps=0; [void][int]::TryParse($t.GetString('PSEQ'),[ref]$ps); $parts[$ps]="$($t.GetString('PVALUE'))" }
    if (-not $parts.Count){ return '' }
    $sb=New-Object System.Text.StringBuilder; foreach ($k in ($parts.Keys|Sort-Object)){ [void]$sb.Append($parts[$k]) }
    $s=$sb.ToString(); $ix=$s.IndexOf('<asx:abap'); if ($ix -lt 0){ return '' }
    try { $doc=[xml]$s.Substring($ix); $n=$doc.SelectSingleNode("//*[local-name()='DATA']"); if ($n){ return $n.InnerText } } catch {}
    return ''
}

$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_SCRATCHFM"
if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

try {
    $FMU = $Fm.ToUpper()
    # FMODE + existence
    $tf = Read-SapTableRows -Destination $g_dest -Table 'TFDIR' -Where "FUNCNAME EQ '$($FMU -replace "'","''")'" -Fields @('FUNCNAME','FMODE')
    if (-not @($tf).Count) { Write-Host "FM:probe $FMU not_found"; Write-Host "STATUS: FM_NOT_FOUND"; Disconnect-SapRfc $g_dest; exit 1 }
    $fmode = "$($tf[0].FMODE)".Trim()

    # signature (param kinds + types)
    $sig = $g_dest.Repository.CreateFunction('RPY_FUNCTIONMODULE_READ_NEW'); $sig.SetValue('FUNCTIONNAME',$FMU); $sig.Invoke($g_dest)
    function SafeGet($t,[string]$col){ try { return "$($t.GetString($col))".Trim() } catch { return '' } }
    function Read-Params([string]$tp){ $t=$sig.GetTable($tp); $o=@()
        for ($i=0;$i -lt $t.RowCount;$i++){ $t.CurrentIndex=$i; $o += [pscustomobject]@{ name=(SafeGet $t 'PARAMETER'); typ=(SafeGet $t 'TYP'); ref=(SafeGet $t 'REFERENCE'); dbs=(SafeGet $t 'DBSTRUCT') } }
        return $o }
    $imp = @(Read-Params 'IMPORT_PARAMETER'); $exp = @(Read-Params 'EXPORT_PARAMETER'); $tabs = @(Read-Params 'TABLES_PARAMETER')

    if ($fmode -eq 'R') {
        # ---- direct RFC ----
        Write-Host ("FM:route fm=$FMU fmode=R backend=direct")
        $fn = $g_dest.Repository.CreateFunction($FMU)
        foreach ($p in $imp) { if ($inputs.ContainsKey($p.name)) { try { $fn.SetValue($p.name, $inputs[$p.name]) } catch {} } }
        $ms = (Measure-Command { $fn.Invoke($g_dest) }).TotalMilliseconds
        foreach ($p in $exp) { $v=''; try { $v = "$($fn.GetString($p.name))".Trim() } catch { $v='<struct>' }
            Write-Host ("FM:export {0}={1}" -f $p.name, ($v -replace '\s+',' ')) }
        foreach ($p in $tabs) { $rc=0; try { $rc = $fn.GetTable($p.name).RowCount } catch {}
            Write-Host ("FM:table {0} rows={1}" -f $p.name, $rc) }
        Write-Host ("FM:timing ms={0:N0}" -f $ms); Write-Host "STATUS: OK"; Disconnect-SapRfc $g_dest; exit 0
    }
    else {
        # ---- wrapper (classic non-RFC) ----
        $wf = Read-SapTableRows -Destination $g_dest -Table 'TFDIR' -Where "FUNCNAME EQ '$($WrapperFm -replace "'","''")'" -Fields @('FUNCNAME','FMODE')
        if (-not @($wf).Count -or "$($wf[0].FMODE)".Trim() -ne 'R') { Write-Host "FM:probe wrapper $WrapperFm missing (run /sap-dev-init)"; Write-Host "STATUS: FM_PROBE_WRAPPER_FAILED"; Disconnect-SapRfc $g_dest; exit 1 }
        Write-Host ("FM:route fm=$FMU fmode=blank backend=wrapper")
        $fn = $g_dest.Repository.CreateFunction($WrapperFm); $fn.SetValue('IV_FUNCNAME',$FMU)
        $tbl = $fn.GetTable('CT_PARAMS')
        function PtypeOf($p){ if ($p.ref) { return $p.ref } elseif ($p.typ) { return $p.typ } elseif ($p.dbs) { return $p.dbs } else { return 'STRING' } }
        foreach ($p in $imp) { if ($inputs.ContainsKey($p.name)) { Add-Param $tbl $p.name 'I' (PtypeOf $p) (New-AsxScalar $inputs[$p.name]) } }
        foreach ($p in $exp) { Add-Param $tbl $p.name 'E' (PtypeOf $p) '' }        # receive scalars (best-effort)
        $ms = (Measure-Command { $fn.Invoke($g_dest) }).TotalMilliseconds
        foreach ($p in $exp) { $v = Get-OutScalar $fn $p.name; if ($v -ne '') { Write-Host ("FM:export {0}={1}" -f $p.name, ($v -replace '\s+',' ')) } }
        Write-Host ("FM:timing ms={0:N0}" -f $ms); Write-Host "STATUS: OK"; Disconnect-SapRfc $g_dest; exit 0
    }
} catch {
    Write-Host "FM: error=$($_.Exception.Message -replace '\s+',' ')"; Write-Host "STATUS: RFC_ERROR"; try { Disconnect-SapRfc $g_dest } catch {}; exit 2
}
