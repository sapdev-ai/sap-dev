# =============================================================================
# sap_flp_extract_rfc.ps1  -  RFC extractor for /sap-fiori-flp-audit (READ-ONLY)
#
# Audits classic FLP content from the RFC-READABLE angle: user -> roles (BAPI +
# AGR_*) -> role-menu FLP references (AGR_HIER/AGR_HIERT/AGR_BUFFI: catalog/group
# providers, OData services, Web Dynpro, and classic transaction targets) +
# TSTC validation of transaction targets.
#
# LIVE-PROVEN LIMITATION (S4D 2026-07-11): RFC_READ_TABLE CANNOT read the /UI2
# Page Builder persistence (/UI2/PB_C_PAGE/CHIP, /UI2/CHIP_CHDR, /UI2/PB_C_TM) -
# they contain STRING columns and RFC_READ_TABLE dies with "ASSIGN ... CASTING in
# SAPLSDTX" / DATA_BUFFER_EXCEEDED even for explicit narrow non-string FIELDS. So
# the catalog/chip/TM PERSISTENCE-integrity checks (BROKEN_CHIP_REF,
# ROLE_REFERENCES_MISSING_CATALOG, EMPTY_ASSIGNED_CATALOG, UNASSIGNED_CATALOG) are
# reported COULD_NOT_CHECK with that reason - they need the wrapper route (v1.5)
# or an SE16N GUI read. The role-menu-content audit below is fully RFC-readable.
#
# STATUS: OK | PARTIAL | FLP_NOT_PRESENT | FLP_USER_NOT_FOUND | RFC_ERROR ; exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Mode = 'user',            # user | broken-tm | unassigned | full
    [string] $User = '',
    [string] $CatalogPattern = '',
    [switch] $IncludeSap,
    [string] $Lang = 'E',
    [int]    $MaxRows = 50000,
    [string] $OutDir = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
# snapshot BEFORE dot-sourcing: object_resolver.ps1 redeclares -User/-Server/etc via its
# own param() block, which would clobber our -User (FLP user) + RFC creds on dot-source.
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; User=$User; Mode=$Mode; Lang=$Lang; CatalogPattern=$CatalogPattern }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }
if (-not $OutDir) { $OutDir = (Get-Location).Path }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$Lang = if ($Lang) { $Lang.Substring(0,[Math]::Min(1,$Lang.Length)).ToUpper() } else { 'E' }

function Sq { param([string]$s) return (("$s") -replace "'", "''") }
function Section { param([string]$Area,[int]$Rows,[string]$Cov,[string]$Reason='') Write-Host "SECTION: $Area rows=$Rows coverage=$Cov reason=$Reason" }

if ($MyInvocation.InvocationName -ne '.') {
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_FLP"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
    $partial = $false

    # ---- presence + RFC-readability probe of the /UI2 persistence ----
    $classic = $false; $rfcReadable = $false
    try { $pp = Read-SapTableRows -Destination $g_dest -Table 'DD02L' -Where "TABNAME EQ '/UI2/PB_C_PAGE' AND AS4LOCAL EQ 'A'" -Fields @('TABNAME') -RowCount 1; $classic = (@($pp).Count -gt 0) } catch {}
    if (-not $classic) { Write-Host "STATUS: FLP_NOT_PRESENT"; Write-Host "INFO: /UI2/PB_C_PAGE not present - not an FLP-enabled system (or spaces-only)"; try { Disconnect-SapRfc } catch {}; exit 1 }
    try {
        $fn = $g_dest.Repository.CreateFunction('RFC_READ_TABLE'); $fn.SetValue('QUERY_TABLE','/UI2/PB_C_PAGE'); $fn.SetValue('ROWCOUNT',1)
        $ff = $fn.GetTable('FIELDS'); $ff.Append(); $ff.SetValue('FIELDNAME','ID'); $fn.Invoke($g_dest); $rfcReadable = $true
    } catch { $rfcReadable = $false }
    Write-Host ("FLP_PERSISTENCE: classic=YES spaces=NO rfc_readable=" + ($(if ($rfcReadable) {'YES'} else {'NO'})) + " reason=" + ($(if ($rfcReadable) {''} else {'RFC_READ_TABLE_SAPLSDTX_CASTING_on_/UI2_STRING_columns'})))

    $findings = New-Object System.Collections.Generic.List[string]
    $findings.Add("finding_class`tseverity`tobject`tdetail`tcoverage")
    function AddFinding { param($cls,$sev,$obj,$det,$cov='CHECKED') $findings.Add("$cls`t$sev`t$obj`t$det`t$cov") }

    # ---- persistence-integrity checks: COULD_NOT_CHECK when /UI2 unreadable ----
    if (-not $rfcReadable) {
        foreach ($c in 'BROKEN_CHIP_REF','ROLE_REFERENCES_MISSING_CATALOG','EMPTY_ASSIGNED_CATALOG','UNASSIGNED_CATALOG') {
            AddFinding $c 'INFO' '(persistence)' 'RFC_READ_TABLE cannot read /UI2/PB_C_* (STRING columns -> SAPLSDTX CASTING); needs the wrapper route (v1.5) or SE16N' 'COULD_NOT_CHECK'
        }
        $partial = $true
        Section 'persistence' 0 'COULD_NOT_CHECK' 'ui2_tables_not_rfc_readable'
    }

    # ---- user mode: resolve user -> roles -> role-menu FLP content ----
    if ($Mode -in @('user','full')) {
        if (-not $User) { Write-Host "STATUS: RFC_ERROR detail=user_required_for_user_mode"; try { Disconnect-SapRfc } catch {}; exit 2 }
        $U = $User.ToUpper()
        # existence
        $exists = $false
        try { $ec = $g_dest.Repository.CreateFunction('BAPI_USER_EXISTENCE_CHECK'); $ec.SetValue('USERNAME',$U); $ec.Invoke($g_dest); $ret=$ec.GetStructure('RETURN'); $exists = ("$($ret.GetString('TYPE'))" -ne 'E') } catch {}
        if (-not $exists) {
            # AGR_USERS fallback existence
            $au = @(); try { $au = Read-SapTableRows -Destination $g_dest -Table 'USR02' -Where "BNAME EQ '$(Sq $U)'" -Fields @('BNAME') -RowCount 1 } catch {}
            if (@($au).Count -eq 0) { Write-Host "STATUS: FLP_USER_NOT_FOUND user=$U"; try { Disconnect-SapRfc } catch {}; exit 1 }
        }
        # user validity/lock
        $uv = @(); try { $uv = Read-SapTableRows -Destination $g_dest -Table 'USR02' -Where "BNAME EQ '$(Sq $U)'" -Fields @('BNAME','UFLAG','GLTGV','GLTGB','USTYP') -RowCount 1 } catch {}
        $ulock=''; $uvto=''
        if (@($uv).Count) { $uf=0; [int]::TryParse("$($uv[0].UFLAG)".Trim(),[ref]$uf)|Out-Null; $ulock = if ((($uf -band 32)-ne 0)-or(($uf -band 64)-ne 0)) {'LOCKED'} else {'active'}; $uvto="$($uv[0].GLTGB)" }

        # direct roles via AGR_USERS (with validity)
        $direct = @(); try { $direct = Read-SapTableRows -Destination $g_dest -Table 'AGR_USERS' -Where "UNAME EQ '$(Sq $U)'" -Fields @('AGR_NAME','FROM_DAT','TO_DAT') -RowCount $MaxRows } catch {}
        $roleRows = New-Object System.Collections.Generic.List[string]
        $roleRows.Add("user`trole`tvalid_from`tvalid_to`tsource")
        $allRoles = @{}
        foreach ($r in $direct) { $rn="$($r.AGR_NAME)"; if(-not $rn){continue}; $allRoles[$rn]='direct'; $roleRows.Add("$U`t$rn`t$($r.FROM_DAT)`t$($r.TO_DAT)`tdirect") }
        # composite expansion (one level) via AGR_AGRS
        foreach ($rn in @($allRoles.Keys | Where-Object { $allRoles[$_] -eq 'direct' })) {
            $kids = @(); try { $kids = Read-SapTableRows -Destination $g_dest -Table 'AGR_AGRS' -Where "AGR_NAME EQ '$(Sq $rn)'" -Fields @('CHILD_AGR') -RowCount 500 } catch {}
            foreach ($k in $kids) { $cn="$($k.CHILD_AGR)"; if($cn -and -not $allRoles.ContainsKey($cn)){ $allRoles[$cn]="composite:$rn"; $roleRows.Add("$U`t$cn`t`t`tcomposite($rn)") } }
        }
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'flp_user_roles.tsv'), ($roleRows -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Section 'user_roles' $allRoles.Count 'CHECKED'

        # role-menu FLP content
        $content = New-Object System.Collections.Generic.List[string]
        $content.Add("role`tobject_id`tref_type`tref_value`ttext`ttcode_exists")
        $tcodeCache = @{}
        function TcodeExists([string]$tc) { if (-not $tc) { return '-' }; if ($tcodeCache.ContainsKey($tc)) { return $tcodeCache[$tc] }; $e='N'; try { $x=Read-SapTableRows -Destination $g_dest -Table 'TSTC' -Where "TCODE EQ '$(Sq $tc)'" -Fields @('TCODE') -RowCount 1; if(@($x).Count){$e='Y'} } catch { $e='-' }; $tcodeCache[$tc]=$e; return $e }
        foreach ($rn in ($allRoles.Keys | Sort-Object)) {
            $hier=@(); try { $hier = Read-SapTableRows -Destination $g_dest -Table 'AGR_HIER' -Where "AGR_NAME EQ '$(Sq $rn)'" -Fields @('OBJECT_ID','REPORTTYPE','REPORT') -RowCount 2000 } catch {}
            $texts=@{}; try { $ht = Read-SapTableRows -Destination $g_dest -Table 'AGR_HIERT' -Where "AGR_NAME EQ '$(Sq $rn)' AND SPRSL EQ '$Lang'" -Fields @('OBJECT_ID','TEXT') -RowCount 2000; foreach($t in $ht){$texts["$($t.OBJECT_ID)"]="$($t.TEXT)"} } catch {}
            $buffi=@{}; try { $bf = Read-SapTableRows -Destination $g_dest -Table 'AGR_BUFFI' -Where "AGR_NAME EQ '$(Sq $rn)'" -Fields @('OBJECT_ID','URL') -RowCount 2000; foreach($b in $bf){$buffi["$($b.OBJECT_ID)"]="$($b.URL)"} } catch {}
            foreach ($n in $hier) {
                $oid="$($n.OBJECT_ID)"; $rt="$($n.REPORTTYPE)".Trim(); $rep="$($n.REPORT)".Trim()
                $refType='OTHER'; $refVal=''; $tce='-'
                switch -Regex ($rep) {
                    '^CAT_PROVIDER'   { $refType='CATALOG'; $refVal=$buffi[$oid] }
                    '^GROUP_PROVIDER' { $refType='GROUP';   $refVal=$buffi[$oid] }
                    '^SERVICE'        { $refType='SERVICE'; $refVal=$buffi[$oid] }
                    '^WDY'            { $refType='WEBDYNPRO'; $refVal=$rep }
                    default { if ($rt -eq 'TR') { $refType='TCODE'; $refVal=$rep; $tce=(TcodeExists $rep) } }
                }
                $rv = ("$refVal" -replace "[`t`r`n]",' '); if ($rv.Length -gt 120) { $rv=$rv.Substring(0,120) }
                $content.Add("$rn`t$oid`t$refType`t$rv`t$($texts[$oid])`t$tce")
                if ($refType -eq 'TCODE' -and $tce -eq 'N') { AddFinding 'TM_TARGET_TCODE_MISSING' 'HIGH' "$rn/$rep" "role menu launches transaction $rep which is absent from TSTC" 'CHECKED' }
            }
        }
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'flp_role_content.tsv'), ($content -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Section 'role_content' ($content.Count-1) 'CHECKED'
        Write-Host ("USER: user=$U lock=$ulock valid_to=$uvto roles=$($allRoles.Count) menu_nodes=$($content.Count-1)")
    }

    # ---- broken-tm / unassigned: readable part = role-menu dead tcodes (done above in full);
    #      persistence part already COULD_NOT_CHECK when unreadable ----
    if ($Mode -in @('broken-tm','unassigned')) {
        # readable structural check we CAN do: dead transaction targets across ALL Z roles' menus
        if ($Mode -eq 'broken-tm') {
            $roles = @(); try { $roles = Read-SapTableRows -Destination $g_dest -Table 'AGR_DEFINE' -Where "AGR_NAME LIKE 'Z%'" -Fields @('AGR_NAME') -RowCount 2000 } catch {}
            $tcodeCache=@{}; $checked=0
            $content = New-Object System.Collections.Generic.List[string]; $content.Add("role`treport`ttcode_exists")
            foreach ($rr in @($roles | Select-Object -First 500)) {
                $rn="$($rr.AGR_NAME)"; $hier=@(); try { $hier = Read-SapTableRows -Destination $g_dest -Table 'AGR_HIER' -Where "AGR_NAME EQ '$(Sq $rn)' AND REPORTTYPE EQ 'TR'" -Fields @('REPORT') -RowCount 500 } catch {}
                foreach ($n in $hier) { $tc="$($n.REPORT)".Trim(); if(-not $tc){continue}; $checked++; $e=$tcodeCache[$tc]; if(-not $e){ $e='N'; try{$x=Read-SapTableRows -Destination $g_dest -Table 'TSTC' -Where "TCODE EQ '$(Sq $tc)'" -Fields @('TCODE') -RowCount 1; if(@($x).Count){$e='Y'}}catch{$e='-'}; $tcodeCache[$tc]=$e }; $content.Add("$rn`t$tc`t$e"); if($e -eq 'N'){ AddFinding 'TM_TARGET_TCODE_MISSING' 'HIGH' "$rn/$tc" "Z role menu launches transaction $tc which is absent from TSTC" } }
            }
            [System.IO.File]::WriteAllText((Join-Path $OutDir 'flp_role_tcodes.tsv'), ($content -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
            Section 'role_tcodes' ($content.Count-1) 'CHECKED'
        } else {
            AddFinding 'UNASSIGNED_CATALOG' 'INFO' '(persistence)' 'unassigned-catalog detection needs /UI2/PB_C_PAGE which is not RFC-readable (see FLP_PERSISTENCE)' 'COULD_NOT_CHECK'
            $partial = $true
        }
    }

    [System.IO.File]::WriteAllText((Join-Path $OutDir 'flp_findings.tsv'), ($findings -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
    $findCount = $findings.Count - 1
    Write-Host ("FLP: mode=$Mode findings=$findCount coverage=" + ($(if ($partial) {'PARTIAL'} else {'CHECKED'})))
    Write-Host ($(if ($partial) { "STATUS: PARTIAL" } else { "STATUS: OK" }))
    try { Disconnect-SapRfc } catch {}
    exit 0
}
