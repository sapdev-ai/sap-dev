# =============================================================================
# sap_transport_copies_rfc.ps1  -  RFC-first backend for /sap-transport-copies
#
# Builds + verifies Transports of Copies (ToC) headlessly over RFC. The plan's v1 was
# GUI-first (SE01 recording); this is the RFC path (plan's v2) brought forward because
# Z_GENERIC_RFC_WRAPPER_TBL is now a proven write bridge -- no golden-screen recording,
# one cross-release code path, authoritative E070/E071 re-reads.
#
# Actions:
#   create  -Text <desc> [-Target <SID>] [-Owner <U>]          make a type-T request
#   verify  -Toc <TOC> -Sources <TR1,TR2,...>                  E071 union check (READ)
#   list    [-User <U>] [-IncludeReleased]                     my modifiable ToCs (READ)
#   include -Toc <TOC> -Sources <TR1,TR2,...>                  copy sources' object lists in
#   release -Toc <TOC>                                         release the ToC (gated by SKILL)
#
# BACKENDS: reads (verify/list, source/task enumeration, all re-reads) = RFC_READ_TABLE on
#   E070/E07T/E071/E070C. Writes (create/include/release) = the non-remote CTS FMs
#   TR_INSERT_REQUEST_WITH_TASKS / TR_APPEND_TO_COMM_OBJS_KEYS / TR_RELEASE_REQUEST invoked
#   through Z_GENERIC_RFC_WRAPPER_TBL (asXML PARAMETER-TABLE, same bridge as change-history);
#   the RFC boundary's implicit COMMIT persists the CTS write.
# VERIFICATION (2026-07-11, live S4D): create PROVEN (made S4DK941332, E070 function=T status=D);
#   verify/list live-verified read-only. include/release wired from their verified signatures +
#   the proven wrapper write pattern -- a full end-to-end released run needs source TRs with
#   objects and writes real transports (mutation-gated), so it is user-approved, not autonomous.
#
# Output (stdout): TOC:<action> lines + STATUS: OK|TOC_CREATE_FAILED|TOC_INCLUDE_FAILED|
#   TOC_UNION_MISMATCH|TOC_NOT_FOUND|INPUT_ERROR|RFC_ERROR ; exit 0=OK 1=business 2=RFC.
# 32-bit PowerShell (NCo 3.1).
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,
    [string] $Toc = '',
    [string] $Sources = '',              # comma/space separated TR list
    [string] $Text = '',
    [string] $Target = '',
    [string] $Owner = '',
    [string] $User = '',
    [switch] $IncludeReleased,
    [string] $OutTsv = '',
    [string] $WrapperFm = 'Z_GENERIC_RFC_WRAPPER_TBL',
    [string] $SharedDir = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Action=$Action; Toc=$Toc; Sources=$Sources; Text=$Text; Target=$Target; Owner=$Owner; User=$User; OutTsv=$OutTsv; WrapperFm=$WrapperFm;
             Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

# ---- asXML wrapper helpers (mirror sap_rfc_syntax_check.ps1 / change-history) ----
$ASX_HEAD = '<asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>'
$ASX_TAIL = '</DATA></asx:values></asx:abap>'
function Esc([string]$v){ [System.Security.SecurityElement]::Escape([string]$v) }
function New-AsxScalar([string]$v){ $ASX_HEAD + (Esc $v) + $ASX_TAIL }
# table of flat structs: rows = array of ordered [ @(field,value), ... ]
function New-AsxTable($rows){
    $sb=New-Object System.Text.StringBuilder; [void]$sb.Append($ASX_HEAD)
    foreach ($r in $rows) { [void]$sb.Append('<item>'); foreach ($kv in $r) { [void]$sb.Append('<'+$kv[0]+'>'+(Esc $kv[1])+'</'+$kv[0]+'>') }; [void]$sb.Append('</item>') }
    [void]$sb.Append($ASX_TAIL); $sb.ToString()
}
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
function Get-OutNode($fn,[string]$pname,[string]$local){
    $xml=Get-OutXml $fn $pname; if (-not $xml){ return '' }
    try { $doc=[xml]$xml; $n=$doc.SelectSingleNode("//*[local-name()='$local']"); if ($n){ return $n.InnerText.Trim() } } catch {}
    return ''
}

# ---- read helpers ----------------------------------------------------------
function Split-List([string]$s){ return @($s -split '[,; ]+' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }) }
function Get-Tasks { param($Dest,[string]$Tr)   # child task TRKORRs of a request
    $r = Read-SapTableRows -Destination $Dest -Table 'E070' -Where "STRKORR EQ '$($Tr -replace "'","''")'" -Fields @('TRKORR') -RowCount 200
    return @($r | ForEach-Object { "$($_.TRKORR)".Trim() } | Where-Object { $_ })
}
function Get-E070 { param($Dest,[string]$Tr)
    $r = Read-SapTableRows -Destination $Dest -Table 'E070' -Where "TRKORR EQ '$($Tr -replace "'","''")'" -Fields @('TRKORR','TRFUNCTION','TRSTATUS','TARSYSTEM','AS4USER') -RowCount 1
    if (@($r).Count) { return $r[0] } else { return $null }
}
function Get-E071Keys { param($Dest,[string]$Tr)   # object triples (PGMID,OBJECT,OBJ_NAME) of one TR
    $r = Read-SapTableRows -Destination $Dest -Table 'E071' -Where "TRKORR EQ '$($Tr -replace "'","''")'" -Fields @('PGMID','OBJECT','OBJ_NAME') -RowCount 5000
    return @($r | ForEach-Object { [pscustomobject]@{ pgmid="$($_.PGMID)".Trim(); object="$($_.OBJECT)".Trim(); obj_name="$($_.OBJ_NAME)".Trim() } } | Where-Object { $_.pgmid })
}
function Expand-Sources { param($Dest,[string[]]$Srcs)   # each source + its tasks
    $all=@(); foreach ($s in $Srcs) { $all += $s; $all += (Get-Tasks -Dest $Dest -Tr $s) }
    return @($all | Select-Object -Unique)
}
function KeyStr($o){ "$($o.pgmid)|$($o.object)|$($o.obj_name)" }

if ($MyInvocation.InvocationName -eq '.') { return }

$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_TOC"
if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

function Test-Wrapper { param($Dest)
    try { $r = Read-SapTableRows -Destination $Dest -Table 'TFDIR' -Where "FUNCNAME EQ '$($WrapperFm -replace "'","''")'" -Fields @('FUNCNAME','FMODE') -RowCount 1
        if (-not @($r).Count) { return $false }; return ("$($r[0].FMODE)".Trim() -eq 'R') } catch { return $false }
}

try {
    switch ($Action.ToLower()) {

        'list' {
            $w = "TRFUNCTION EQ 'T'"
            if (-not $IncludeReleased) { $w += " AND TRSTATUS EQ 'D'" }
            $u = if ($User) { $User.ToUpper() } else { try { $p=Get-SapCurrentConnectionProfile; if ($p){ "$($p.user)".ToUpper() } else { '' } } catch { '' } }
            if ($u) { $w += " AND AS4USER EQ '$($u -replace "'","''")'" }
            $rows = Read-SapTableRows -Destination $g_dest -Table 'E070' -Where $w -Fields @('TRKORR','TRSTATUS','TARSYSTEM','AS4USER','AS4DATE') -RowCount 200
            foreach ($r in $rows) { $tr="$($r.TRKORR)".Trim()
                $txt=''; try { $t=Read-SapTableRows -Destination $g_dest -Table 'E07T' -Where "TRKORR EQ '$tr' AND LANGU EQ 'E'" -Fields @('AS4TEXT') -RowCount 1; if (@($t).Count){ $txt="$($t[0].AS4TEXT)".Trim() } } catch {}
                if (-not $txt) { try { $t=Read-SapTableRows -Destination $g_dest -Table 'E07T' -Where "TRKORR EQ '$tr'" -Fields @('AS4TEXT') -RowCount 1; if (@($t).Count){ $txt="$($t[0].AS4TEXT)".Trim() } } catch {} }
                $cnt=@(Get-E071Keys -Dest $g_dest -Tr $tr).Count
                Write-Host ("TOC:item toc={0} status={1} target={2} user={3} date={4} objects={5} text={6}" -f $tr,"$($r.TRSTATUS)".Trim(),"$($r.TARSYSTEM)".Trim(),"$($r.AS4USER)".Trim(),"$($r.AS4DATE)",$cnt,$(if($txt){$txt}else{'-'})) }
            Write-Host ("TOC:list count={0} user={1}" -f @($rows).Count,$(if($u){$u}else{'ALL'})); Write-Host "STATUS: OK"; Disconnect-SapRfc $g_dest; exit 0
        }

        'verify' {
            if (-not $Toc -or -not $Sources) { Write-Host "TOC:verify input_error (need -Toc -Sources)"; Write-Host "STATUS: INPUT_ERROR"; Disconnect-SapRfc $g_dest; exit 1 }
            $tocE = Get-E070 -Dest $g_dest -Tr $Toc.ToUpper()
            if (-not $tocE) { Write-Host "TOC:verify toc=$Toc not_found"; Write-Host "STATUS: TOC_NOT_FOUND"; Disconnect-SapRfc $g_dest; exit 1 }
            $srcs = Split-List $Sources
            $srcExpanded = @(Expand-Sources -Dest $g_dest -Srcs $srcs)
            $unionKeys = @{}; foreach ($s in $srcExpanded) { foreach ($o in (Get-E071Keys -Dest $g_dest -Tr $s)) { $unionKeys[(KeyStr $o)] = $o } }
            $tocKeys = @{}; foreach ($o in (Get-E071Keys -Dest $g_dest -Tr $Toc.ToUpper())) { $tocKeys[(KeyStr $o)] = $o }
            $missing = @($unionKeys.Keys | Where-Object { -not $tocKeys.ContainsKey($_) })
            $extra   = @($tocKeys.Keys | Where-Object { -not $unionKeys.ContainsKey($_) })
            foreach ($k in $missing) { $o=$unionKeys[$k]; Write-Host ("TOC:missing pgmid={0} object={1} name={2}" -f $o.pgmid,$o.object,$o.obj_name) }
            foreach ($k in $extra)   { $o=$tocKeys[$k];   Write-Host ("TOC:extra pgmid={0} object={1} name={2}" -f $o.pgmid,$o.object,$o.obj_name) }
            if ($OutTsv) { try { $sb=New-Object System.Text.StringBuilder; [void]$sb.AppendLine("row_class`tpgmid`tobject`tobj_name")
                foreach ($k in $missing){ $o=$unionKeys[$k]; [void]$sb.AppendLine("MISSING`t$($o.pgmid)`t$($o.object)`t$($o.obj_name)") }
                foreach ($k in $extra){ $o=$tocKeys[$k]; [void]$sb.AppendLine("EXTRA`t$($o.pgmid)`t$($o.object)`t$($o.obj_name)") }
                if (-not $missing.Count -and -not $extra.Count) { [void]$sb.AppendLine("UNION_OK`t`t`t") }
                [System.IO.File]::WriteAllText($OutTsv,$sb.ToString(),(New-Object System.Text.UTF8Encoding($true))) } catch {} }
            $verdict = if ($missing.Count) { 'MISSING' } elseif ($extra.Count) { 'EXTRA_ONLY' } else { 'UNION_OK' }
            Write-Host ("TOC:verify toc={0} sources={1} tasks_expanded={2} union={3} missing={4} extra={5} verdict={6}" -f $Toc.ToUpper(),$srcs.Count,$srcExpanded.Count,$unionKeys.Keys.Count,$missing.Count,$extra.Count,$verdict)
            Write-Host $(if ($missing.Count) { "STATUS: TOC_UNION_MISMATCH" } else { "STATUS: OK" }); Disconnect-SapRfc $g_dest; exit $(if ($missing.Count) { 1 } else { 0 })
        }

        'create' {
            if (-not $Text) { Write-Host "TOC:create input_error (need -Text)"; Write-Host "STATUS: INPUT_ERROR"; Disconnect-SapRfc $g_dest; exit 1 }
            if (-not (Test-Wrapper -Dest $g_dest)) { Write-Host "TOC:create wrapper $WrapperFm missing/not-remote (run /sap-dev-init)"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc $g_dest; exit 2 }
            $owner = if ($Owner) { $Owner.ToUpper() } else { try { $p=Get-SapCurrentConnectionProfile; "$($p.user)".ToUpper() } catch { '' } }
            $fn = $g_dest.Repository.CreateFunction($WrapperFm); $fn.SetValue('IV_FUNCNAME','TR_INSERT_REQUEST_WITH_TASKS')
            $tbl = $fn.GetTable('CT_PARAMS')
            Add-Param $tbl 'IV_TYPE' 'I' 'TRFUNCTION' (New-AsxScalar 'T')
            Add-Param $tbl 'IV_TEXT' 'I' 'AS4TEXT' (New-AsxScalar $Text)
            if ($Target) { Add-Param $tbl 'IV_TARGET' 'I' 'TR_TARGET' (New-AsxScalar $Target.ToUpper()) }
            if ($owner)  { Add-Param $tbl 'IV_OWNER' 'I' 'AS4USER' (New-AsxScalar $owner) }
            Add-Param $tbl 'ES_REQUEST_HEADER' 'E' 'TRWBO_REQUEST_HEADER' ''
            $fn.Invoke($g_dest)
            $trkorr = Get-OutNode $fn 'ES_REQUEST_HEADER' 'TRKORR'
            if (-not $trkorr) { Write-Host "TOC:create verify_failed (no TRKORR returned)"; Write-Host "STATUS: TOC_CREATE_FAILED"; Disconnect-SapRfc $g_dest; exit 1 }
            $e = Get-E070 -Dest $g_dest -Tr $trkorr
            if (-not $e -or "$($e.TRFUNCTION)".Trim() -ne 'T') { Write-Host "TOC:create toc=$trkorr verify_failed (E070 not T)"; Write-Host "STATUS: TOC_CREATE_FAILED"; Disconnect-SapRfc $g_dest; exit 1 }
            Write-Host ("TOC:create toc={0} function={1} status={2} target={3} verified=YES" -f $trkorr,"$($e.TRFUNCTION)".Trim(),"$($e.TRSTATUS)".Trim(),"$($e.TARSYSTEM)".Trim())
            Write-Host "STATUS: OK"; Disconnect-SapRfc $g_dest; exit 0
        }

        'include' {
            if (-not $Toc -or -not $Sources) { Write-Host "TOC:include input_error (need -Toc -Sources)"; Write-Host "STATUS: INPUT_ERROR"; Disconnect-SapRfc $g_dest; exit 1 }
            if (-not (Test-Wrapper -Dest $g_dest)) { Write-Host "TOC:include wrapper missing"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc $g_dest; exit 2 }
            $tocE = Get-E070 -Dest $g_dest -Tr $Toc.ToUpper()
            if (-not $tocE -or "$($tocE.TRFUNCTION)".Trim() -ne 'T') { Write-Host "TOC:include toc=$Toc not a modifiable ToC"; Write-Host "STATUS: TOC_NOT_FOUND"; Disconnect-SapRfc $g_dest; exit 1 }
            $before = @(Get-E071Keys -Dest $g_dest -Tr $Toc.ToUpper()).Count
            # copy each source's (and its tasks') full object list into the ToC via TR_COPY_COMM
            # (scalar TRKORR->TRKORR; copies the whole comm-object list, no E071 marshalling).
            $srcExpanded = @(Expand-Sources -Dest $g_dest -Srcs (Split-List $Sources))
            $copied=0; $failed=@()
            foreach ($s in $srcExpanded) {
                if (-not @(Get-E071Keys -Dest $g_dest -Tr $s).Count) { continue }   # nothing to copy from this (task) TR
                try {
                    $fn = $g_dest.Repository.CreateFunction($WrapperFm); $fn.SetValue('IV_FUNCNAME','TR_COPY_COMM')
                    $tbl = $fn.GetTable('CT_PARAMS')
                    Add-Param $tbl 'WI_TRKORR_FROM' 'I' 'TRKORR' (New-AsxScalar $s)
                    Add-Param $tbl 'WI_TRKORR_TO'   'I' 'TRKORR' (New-AsxScalar $Toc.ToUpper())
                    Add-Param $tbl 'WI_DIALOG'      'I' 'TRPARI-W_DIALOG' (New-AsxScalar ' ')
                    Add-Param $tbl 'WI_WITHOUT_DOCUMENTATION' 'I' 'TRPARI-W_DIALOG' (New-AsxScalar 'X')
                    $fn.Invoke($g_dest); $copied++
                } catch { $failed += $s }
            }
            $after = @(Get-E071Keys -Dest $g_dest -Tr $Toc.ToUpper()).Count
            Write-Host ("TOC:include toc={0} sources_copied={1} failed={2} toc_objects={3}->{4}" -f $Toc.ToUpper(),$copied,($failed -join ','),$before,$after)
            if ($failed.Count) { Write-Host "STATUS: TOC_INCLUDE_FAILED"; Disconnect-SapRfc $g_dest; exit 1 }
            Write-Host "STATUS: OK"; Disconnect-SapRfc $g_dest; exit 0
        }

        'release' {
            if (-not $Toc) { Write-Host "TOC:release input_error (need -Toc)"; Write-Host "STATUS: INPUT_ERROR"; Disconnect-SapRfc $g_dest; exit 1 }
            if (-not (Test-Wrapper -Dest $g_dest)) { Write-Host "TOC:release wrapper missing"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc $g_dest; exit 2 }
            $fn = $g_dest.Repository.CreateFunction($WrapperFm); $fn.SetValue('IV_FUNCNAME','TR_RELEASE_REQUEST')
            $tbl = $fn.GetTable('CT_PARAMS')
            Add-Param $tbl 'IV_TRKORR' 'I' 'TRKORR' (New-AsxScalar $Toc.ToUpper())
            Add-Param $tbl 'IV_DIALOG' 'I' 'TRBOOLEAN' (New-AsxScalar ' ')
            Add-Param $tbl 'IV_AS_BACKGROUND_JOB' 'I' 'TRBOOLEAN' (New-AsxScalar ' ')
            Add-Param $tbl 'IV_SUCCESS_MESSAGE' 'I' 'TRBOOLEAN' (New-AsxScalar ' ')
            Add-Param $tbl 'IV_DISPLAY_EXPORT_LOG' 'I' 'TRBOOLEAN' (New-AsxScalar ' ')
            $fn.Invoke($g_dest)
            Start-Sleep -Milliseconds 500
            $e = Get-E070 -Dest $g_dest -Tr $Toc.ToUpper()
            $st = if ($e) { "$($e.TRSTATUS)".Trim() } else { '?' }
            Write-Host ("TOC:release toc={0} status_after={1} (R/O=released)" -f $Toc.ToUpper(),$st)
            Write-Host $(if ($st -eq 'R' -or $st -eq 'O') { "STATUS: OK" } else { "STATUS: TOC_RELEASE_BLOCKED" }); Disconnect-SapRfc $g_dest; exit $(if ($st -eq 'R' -or $st -eq 'O') { 0 } else { 1 })
        }

        default { Write-Host "TOC: unknown_action=$Action"; Write-Host "STATUS: INPUT_ERROR"; Disconnect-SapRfc $g_dest; exit 1 }
    }
} catch {
    Write-Host "TOC: error=$($_.Exception.Message -replace '\s+',' ')"; Write-Host "STATUS: RFC_ERROR"; try { Disconnect-SapRfc $g_dest } catch {}; exit 2
}
