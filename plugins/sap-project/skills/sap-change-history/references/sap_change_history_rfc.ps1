# =============================================================================
# sap_change_history_rfc.ps1  -  RFC backend for /sap-change-history
#
# "Who changed this object / this data, and when" -- headless, field-level decode.
#
# Actions:
#   headers  -ObjectClass -ObjectId | -User -FromDate -ToDate [-Tcode]   CDHDR scan
#   decode   -ObjectClass -ObjectId [-ChangeNr]                          field-level old/new
#   classes  [-All]                                                      curated map vs TCDOB
#   imports  -FromDate -ToDate                                           E070/E071 window (--correlate)
#
# BACKENDS (all live-verified on S4D S/4HANA 1909):
#   * headers/classes/imports  = RFC_READ_TABLE on CDHDR / TCDOB(T) / E070 / E071
#     (all TRANSP/POOL, RFC-readable; CDHDR is the ONE change-doc table safe to read raw).
#   * decode = CHANGEDOCUMENT_READ (TFDIR.FMODE blank -> NOT remote-enabled) invoked THROUGH
#     the dev-init dispatcher Z_GENERIC_RFC_WRAPPER_TBL (remote-enabled), asXML PARAMETER-TABLE
#     -- the SAME bridge sap_rfc_syntax_check.ps1 / sap_tadir_delete.ps1 use. This returns the
#     fully DECODED CDRED rows (table/field/old/new) and sidesteps BOTH the CDPOS 512-byte
#     RFC_READ_TABLE limit AND the ECC-6 CDPOS CLUSTER storage. Read-only; no writes, no SQL.
#
# HARD-WON DECODE FACTS (2026-07-11, live):
#   * EDITPOS is a TABLES param typed CDRED -> PTYPENAME must be an instantiable TABLE TYPE
#     (TT_CDRED = STANDARD TABLE OF CDRED). A row STRUCTURE (CDRED) create-succeeds but dies
#     DYNAMIC_CALL_FAILED bound as tables.
#   * CHANGEDOCUMENT_READ keys on OBJECTCLASS+OBJECTID; CHANGENUMBER alone -> NO_POSITION_FOUND.
#   * asXML (CALL TRANSFORMATION id) renders DATS as ISO 'YYYY-MM-DD', TIMS as 'HH:MM:SS' --
#     NOT SAP-internal -- so date-range params must be ISO or the wrapper raises
#     DESERIALIZATION_FAILED.
#   * The wrapper's single OTHERS=1 exception collapses the FM's NO_POSITION_FOUND into
#     DYNAMIC_CALL_FAILED -> treated here as "no decodable positions" (fail-SOFT: CDH_NO_CHANGES
#     for that object), never a hard error.
#
# Output (stdout): CDH:<action> lines + STATUS: OK|CDH_NO_CHANGES|CDH_WRAPPER_MISSING|
#                  CDH_CLASS_UNKNOWN|INPUT_ERROR|RFC_ERROR ; exit 0=OK 1=business 2=RFC.
# Run with 32-bit PowerShell (NCo 3.1 is 32-bit).
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,
    [string] $ObjectClass = '',
    [string] $ObjectId    = '',
    [string] $ChangeNr    = '',
    [string] $User        = '',
    [string] $FromDate    = '',        # YYYYMMDD (SAP-internal; converted to ISO for the FM)
    [string] $ToDate      = '',
    [string] $Tcode       = '',
    [int]    $Max         = 200,
    [int]    $DecodeMax   = 25,
    [switch] $All,
    [string] $WrapperFm   = 'Z_GENERIC_RFC_WRAPPER_TBL',
    [string] $SharedDir   = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
# Snapshot ALL params: sap_object_resolver.ps1 declares -User/-Server/... -- dot-sourcing clobbers.
$__keep = @{ Action=$Action; ObjectClass=$ObjectClass; ObjectId=$ObjectId; ChangeNr=$ChangeNr; User=$User; FromDate=$FromDate; ToDate=$ToDate; Tcode=$Tcode; Max=$Max; DecodeMax=$DecodeMax; WrapperFm=$WrapperFm;
             Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

# ---- asXML helpers (bare asx:abap root; mirror sap_rfc_syntax_check.ps1) ----
$ASX_HEAD = '<asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>'
$ASX_TAIL = '</DATA></asx:values></asx:abap>'
function Esc([string]$v){ [System.Security.SecurityElement]::Escape([string]$v) }
function New-AsxScalar([string]$v){ $ASX_HEAD + (Esc $v) + $ASX_TAIL }
$CHUNK = 1333
function Add-Param($tbl,[string]$pn,[string]$pt,[string]$ptn,[string]$payload){
    if ([string]::IsNullOrEmpty($payload)) { [void]$tbl.Append(); $tbl.SetValue('PNAME',$pn); $tbl.SetValue('PSEQ',1); $tbl.SetValue('PTYPE',$pt); $tbl.SetValue('PTYPENAME',$ptn); return }
    $len=$payload.Length; $off=0; $seq=0
    while ($off -lt $len) { $seq++; $take=[Math]::Min($CHUNK,$len-$off); [void]$tbl.Append(); $tbl.SetValue('PNAME',$pn); $tbl.SetValue('PSEQ',$seq); $tbl.SetValue('PTYPE',$pt); $tbl.SetValue('PTYPENAME',$ptn); $tbl.SetValue('PVALUE',$payload.Substring($off,$take)); $off+=$CHUNK }
}
function Get-OutXml($fn,[string]$pname){
    $t=$fn.GetTable('CT_PARAMS'); $parts=@{}
    for ($i=0;$i -lt $t.RowCount;$i++){ $t.CurrentIndex=$i; if ("$($t.GetString('PNAME'))".Trim() -ne $pname){continue}
        $ps=0; [void][int]::TryParse($t.GetString('PSEQ'),[ref]$ps); $parts[$ps]="$($t.GetString('PVALUE'))" }
    if (-not $parts.Count){ return '' }
    $sb=New-Object System.Text.StringBuilder; foreach ($k in ($parts.Keys|Sort-Object)){ [void]$sb.Append($parts[$k]) }
    $s=$sb.ToString(); $ix=$s.IndexOf('<asx:abap'); if ($ix -ge 0){ return $s.Substring($ix) }; return $s
}
function ConvertTo-IsoDate([string]$yyyymmdd){ if ($yyyymmdd -and $yyyymmdd.Length -eq 8) { return ($yyyymmdd.Substring(0,4)+'-'+$yyyymmdd.Substring(4,2)+'-'+$yyyymmdd.Substring(6,2)) } return $yyyymmdd }

# ---- wrapper decode: CHANGEDOCUMENT_READ -> CDRED rows (fail-soft) ----------
function Invoke-CdRead {
    param($Dest, [string]$Class, [string]$Id, [string]$Nr)
    $rows = New-Object System.Collections.ArrayList
    try {
        $fn = $Dest.Repository.CreateFunction($WrapperFm); $fn.SetValue('IV_FUNCNAME','CHANGEDOCUMENT_READ')
        $tbl = $fn.GetTable('CT_PARAMS')
        Add-Param $tbl 'OBJECTCLASS' 'I' 'CDHDR-OBJECTCLAS' (New-AsxScalar $Class)
        Add-Param $tbl 'OBJECTID'    'I' 'CDHDR-OBJECTID'   (New-AsxScalar $Id)
        if ($Nr) { Add-Param $tbl 'CHANGENUMBER' 'I' 'CDHDR-CHANGENR' (New-AsxScalar $Nr) }
        Add-Param $tbl 'EDITPOS' 'T' 'TT_CDRED' ''
        $fn.Invoke($Dest)
        $xml = Get-OutXml $fn 'EDITPOS'
        if ($xml) {
            $doc=[xml]$xml; $data=$doc.SelectSingleNode("//*[local-name()='DATA']")
            if ($data) { foreach ($row in $data.ChildNodes) {
                $h=@{}; foreach ($c in $row.ChildNodes){ $h[$c.LocalName]="$($c.InnerText)" }
                [void]$rows.Add([pscustomobject]@{
                    changenr=("$($h['CHANGENR'])").Trim(); udate=("$($h['UDATE'])").Trim(); utime=("$($h['UTIME'])").Trim()
                    username=("$($h['USERNAME'])").Trim(); tcode=("$($h['TCODE'])").Trim()
                    tabname=("$($h['TABNAME'])").Trim(); fname=("$($h['FNAME'])").Trim(); chngind=("$($h['CHNGIND'])").Trim()
                    f_old=("$($h['F_OLD'])").TrimEnd(); f_new=("$($h['F_NEW'])").TrimEnd() }) } }
        }
        return @{ ok=$true; rows=$rows; soft='' }
    } catch {
        $m = $_.Exception.Message
        # NO_POSITION_FOUND surfaces as the wrapper's DYNAMIC_CALL_FAILED -> fail-soft.
        if ($m -match 'DYNAMIC_CALL_FAILED') { return @{ ok=$true; rows=$rows; soft='no_positions' } }
        return @{ ok=$false; rows=$rows; soft=($m -replace '\s+',' ') }
    }
}

# ---- best-effort field label (DD03L rollname -> DD04T text) -----------------
$script:lblCache = @{}
function Get-FieldLabel { param($Dest,[string]$Tab,[string]$Fld)
    $key = "$Tab|$Fld"; if ($script:lblCache.ContainsKey($key)) { return $script:lblCache[$key] }
    $label=''
    try {
        $d3 = Read-SapTableRows -Destination $Dest -Table 'DD03L' -Where "TABNAME EQ '$($Tab -replace "'","''")' AND FIELDNAME EQ '$($Fld -replace "'","''")'" -Fields @('ROLLNAME') -RowCount 1
        $roll = if (@($d3).Count) { "$($d3[0].ROLLNAME)".Trim() } else { '' }
        if ($roll) { $d4 = Read-SapTableRows -Destination $Dest -Table 'DD04T' -Where "ROLLNAME EQ '$($roll -replace "'","''")' AND DDLANGUAGE EQ 'E'" -Fields @('DDTEXT') -RowCount 1
            if (@($d4).Count) { $label = "$($d4[0].DDTEXT)".Trim() } }
    } catch {}
    $script:lblCache[$key] = $label; return $label
}

if ($MyInvocation.InvocationName -eq '.') { return }

$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_CDHIST"
if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

function Test-Wrapper { param($Dest)
    try { $r = Read-SapTableRows -Destination $Dest -Table 'TFDIR' -Where "FUNCNAME EQ '$($WrapperFm -replace "'","''")'" -Fields @('FUNCNAME','FMODE') -RowCount 1
        if (-not @($r).Count) { return @{ ok=$false; why="wrapper $WrapperFm not found" } }
        if ("$($r[0].FMODE)".Trim() -ne 'R') { return @{ ok=$false; why="wrapper $WrapperFm not remote-enabled (FMODE=$($r[0].FMODE))" } }
        return @{ ok=$true } } catch { return @{ ok=$false; why="wrapper probe failed: $($_.Exception.Message)" } }
}

try {
    switch ($Action.ToLower()) {

        'headers' {
            $where = ''
            if ($ObjectClass) {
                $where = "OBJECTCLAS EQ '$($ObjectClass.ToUpper() -replace "'","''")'"
                if ($ObjectId) { $where += " AND OBJECTID EQ '$($ObjectId -replace "'","''")'" }
            } elseif ($User) {
                $where = "USERNAME EQ '$($User.ToUpper() -replace "'","''")'"
                if ($FromDate) { $where += " AND UDATE GE '$FromDate'" }
                if ($ToDate)   { $where += " AND UDATE LE '$ToDate'" }
                if ($Tcode)    { $where += " AND TCODE EQ '$($Tcode.ToUpper() -replace "'","''")'" }
            } else { Write-Host "CDH:headers input_error (need -ObjectClass or -User)"; Write-Host "STATUS: INPUT_ERROR"; Disconnect-SapRfc $g_dest; exit 1 }
            $rows = Read-SapTableRows -Destination $g_dest -Table 'CDHDR' -Where $where -Fields @('OBJECTCLAS','OBJECTID','CHANGENR','UDATE','UTIME','USERNAME','TCODE','CHANGE_IND') -RowCount $Max
            $rows = @($rows)
            if ($rows.Count -eq 0) { Write-Host "CDH:headers count=0"; Write-Host "STATUS: CDH_NO_CHANGES"; Disconnect-SapRfc $g_dest; exit 1 }
            foreach ($r in $rows) { Write-Host ("CDH:header class={0} id={1} nr={2} date={3} time={4} user={5} tcode={6} ind={7}" -f "$($r.OBJECTCLAS)".Trim(),"$($r.OBJECTID)".Trim(),"$($r.CHANGENR)".Trim(),"$($r.UDATE)","$($r.UTIME)","$($r.USERNAME)".Trim(),"$($r.TCODE)".Trim(),"$($r.CHANGE_IND)".Trim()) }
            Write-Host ("CDH:headers count={0}" -f $rows.Count); Write-Host "STATUS: OK"; Disconnect-SapRfc $g_dest; exit 0
        }

        'decode' {
            if (-not $ObjectClass -or -not $ObjectId) { Write-Host "CDH:decode input_error (need -ObjectClass -ObjectId)"; Write-Host "STATUS: INPUT_ERROR"; Disconnect-SapRfc $g_dest; exit 1 }
            $w = Test-Wrapper -Dest $g_dest
            if (-not $w.ok) { Write-Host "CDH:decode $($w.why)"; Write-Host "STATUS: CDH_WRAPPER_MISSING"; Disconnect-SapRfc $g_dest; exit 1 }
            $res = Invoke-CdRead -Dest $g_dest -Class $ObjectClass.ToUpper() -Id $ObjectId -Nr $ChangeNr
            if (-not $res.ok) { Write-Host "CDH:decode error=$($res.soft)"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc $g_dest; exit 2 }
            $rows = @($res.rows)
            if ($rows.Count -eq 0) { $why = if ($res.soft -eq 'no_positions') { 'no decodable positions (object not change-doc-enabled, or archived)' } else { 'no change positions in scope' }
                Write-Host "CDH:decode count=0 ($why)"; Write-Host "STATUS: CDH_NO_CHANGES"; Disconnect-SapRfc $g_dest; exit 1 }
            foreach ($r in $rows) {
                $lbl = Get-FieldLabel -Dest $g_dest -Tab $r.tabname -Fld $r.fname
                Write-Host ("CDH:change nr={0} date={1} time={2} user={3} tcode={4} tab={5} field={6} label={7} ind={8} old={9} new={10}" -f `
                    $r.changenr,$r.udate,$r.utime,$r.username,$r.tcode,$r.tabname,$r.fname,$(if($lbl){$lbl}else{'-'}),$r.chngind,$(if($r.f_old -ne ''){$r.f_old}else{'-'}),$(if($r.f_new -ne ''){$r.f_new}else{'-'})) }
            Write-Host ("CDH:decode count={0} object={1}/{2}" -f $rows.Count,$ObjectClass.ToUpper(),$ObjectId); Write-Host "STATUS: OK"; Disconnect-SapRfc $g_dest; exit 0
        }

        'classes' {
            $rows = Read-SapTableRows -Destination $g_dest -Table 'TCDOB' -Where '' -Fields @('OBJECT','TABNAME') -RowCount $(if ($All) { 2000 } else { 400 })
            $rows = @($rows)
            $byObj = @{}; foreach ($r in $rows) { $o="$($r.OBJECT)".Trim(); if ($o) { if (-not $byObj.ContainsKey($o)) { $byObj[$o]=New-Object System.Collections.Generic.List[string] }; [void]$byObj[$o].Add("$($r.TABNAME)".Trim()) } }
            foreach ($o in ($byObj.Keys | Sort-Object)) {
                $txt=''; try { $t = Read-SapTableRows -Destination $g_dest -Table 'TCDOBT' -Where "SPRAS EQ 'E' AND OBJECT EQ '$($o -replace "'","''")'" -Fields @('OBTEXT') -RowCount 1; if (@($t).Count) { $txt="$($t[0].OBTEXT)".Trim() } } catch {}
                Write-Host ("CDH:class object={0} text={1} tables={2}" -f $o,$(if($txt){$txt}else{'-'}),(($byObj[$o] | Select-Object -First 6) -join ',')) }
            Write-Host ("CDH:classes count={0}" -f $byObj.Keys.Count); Write-Host "STATUS: OK"; Disconnect-SapRfc $g_dest; exit 0
        }

        'imports' {
            if (-not $FromDate) { Write-Host "CDH:imports input_error (need -FromDate)"; Write-Host "STATUS: INPUT_ERROR"; Disconnect-SapRfc $g_dest; exit 1 }
            $w = "AS4DATE GE '$FromDate'"; if ($ToDate) { $w += " AND AS4DATE LE '$ToDate'" }
            $e070 = Read-SapTableRows -Destination $g_dest -Table 'E070' -Where $w -Fields @('TRKORR','TRSTATUS','AS4USER','AS4DATE','AS4TIME') -RowCount $Max
            $e070 = @($e070)
            foreach ($r in $e070) { Write-Host ("CDH:import tr={0} status={1} user={2} date={3} time={4}" -f "$($r.TRKORR)".Trim(),"$($r.TRSTATUS)".Trim(),"$($r.AS4USER)".Trim(),"$($r.AS4DATE)","$($r.AS4TIME)") }
            Write-Host ("CDH:imports count={0}" -f $e070.Count); Write-Host "STATUS: OK"; Disconnect-SapRfc $g_dest; exit 0
        }

        default { Write-Host "CDH: unknown_action=$Action"; Write-Host "STATUS: INPUT_ERROR"; Disconnect-SapRfc $g_dest; exit 1 }
    }
} catch {
    Write-Host "CDH: error=$($_.Exception.Message -replace '\s+',' ')"; Write-Host "STATUS: RFC_ERROR"; try { Disconnect-SapRfc $g_dest } catch {}; exit 2
}
