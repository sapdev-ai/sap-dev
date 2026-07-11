# =============================================================================
# sap_interface_scan.ps1  -  Interface-surface enumerator for /sap-interface-inventory
#
# Reads the six confirmable interface sources over pure read-only RFC and writes
# one TSV per source. Claude then correlates the TSVs into interface_register.tsv.
#
#   1 rfc    RFCDES                          -> source_rfcdes.tsv
#   2 idoc   EDP13/EDP21/EDPP1/EDIFCT/TBD05  -> source_we20.tsv
#   3 zfm    TFDIR(FMODE=R,Z*/Y*)+ENLFDIR    -> source_zfm.tsv
#   4 odata  /IWFND/I_MED_SRH (S/4) | ICFSERVICE (ECC supplement) -> source_odata.tsv
#   5 proxy  SPROXHDR                        -> source_proxy.tsv
#   6 jobs   TBTCO+TBTCP (90d) classified    -> source_jobs.tsv
#
# READ-ONLY. RFC_READ_TABLE only (all sources probed FMODE=R / TRANSP on S4D+EC2);
# never mutates SAP; no GUI, no wrapper FM. Release divergence (S/4 OData hub,
# proxy framework) is handled by runtime existence probes, degrading a missing
# source to COULD_NOT_CHECK / NOT_APPLICABLE - never a silently thinner register.
#
# Output (stdout, parseable by SKILL.md):
#   SRC: <source> rows=<n|">cap"> coverage=<CHECKED|COULD_NOT_CHECK|NOT_APPLICABLE> file=<tsv>
#   STATUS: OK | PARTIAL | RFC_ERROR
# Exit: 0 = OK/PARTIAL | 2 = connect failure.
# =============================================================================

[CmdletBinding()]
param(
    [string]   $Sources = 'rfc,idoc,zfm,odata,proxy,jobs',
    [int]      $MaxRows = 5000,
    [string]   $Namespace = 'Z,Y',
    [int]      $JobWindowDays = 90,
    [string]   $SharedDir = '',
    [string]   $SkillDir = '',
    [string]   $CustomUrl = '',
    [string]   $OutputDir = '',
    [string]   $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) {
    try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' }
}
if (-not $SkillDir) { $SkillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$scripts = Join-Path $SharedDir 'scripts'

$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1','sap_artifact_lib.ps1') {
    $p = Join-Path $scripts $lib
    if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

# --- helpers ---------------------------------------------------------------

# UTF-8 BOM TSV writer.
function Write-Tsv {
    param([string] $Path, [string] $Header, [object[]] $Lines)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}
function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }

# Does a table exist + hold my required columns? (release-tolerance guard)
$script:colCache = @{}
function Get-TableCols {
    param($Destination, [string] $Table)
    if ($script:colCache.ContainsKey($Table)) { return $script:colCache[$Table] }
    $cols = @()
    try {
        $fn = $Destination.Repository.CreateFunction('DDIF_FIELDINFO_GET')
        $fn.SetValue('TABNAME', $Table); $fn.Invoke($Destination)
        $t = $fn.GetTable('DFIES_TAB')
        for ($i = 0; $i -lt $t.RowCount; $i++) { $t.CurrentIndex = $i; $cols += "$($t.GetValue('FIELDNAME'))" }
    } catch { $cols = @() }
    $script:colCache[$Table] = $cols
    return $cols
}
function Test-Cols { param([string[]] $Have, [string[]] $Need) foreach ($n in $Need) { if ($Have -notcontains $n) { return $false } }; return $true }

# Mask credential-shaped tokens in a raw config string (defensive; RFCOPTIONS
# normally holds no plaintext secret, but never echo one if present).
function Hide-Secrets { param([string] $s) return ((("$s") -replace '(?i)(pass(word)?|pwd|secret|token|key)\s*[=:]\s*[^,;\s]+', '$1=<redacted>')) }

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    $srcSet = @($Sources.ToLower() -split '[,; ]+' | Where-Object { $_ })

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $UserId -Password $Password -Language $Language `
                             -DestName "SAPDEV_IFACE"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

    # System-scoped artifact dir (SID_<SID>_<CLIENT>) when no explicit -OutputDir.
    $sid = ''; try { $sid = Get-SapResolverSysId -Destination $g_dest } catch { $sid = '' }
    $effClient = if ($Client) { $Client } else { "$g_sapClient" }
    $scopeKey = "SID_${sid}_${effClient}"
    if (-not $OutputDir) {
        try { $OutputDir = Get-SapArtifactDir -ScopeKey $scopeKey -Skill 'sap-interface-inventory' -RunId $RunId } catch { $OutputDir = (Get-Location).Path }
    }
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

    $anyChecked = $false; $anyDegraded = $false

    function Emit-Src { param([string] $Name, $Count, [string] $Coverage, [string] $File)
        $rowsStr = if ($Count -is [string]) { $Count } else { "$Count" }
        Write-Host ("SRC: {0} rows={1} coverage={2} file={3}" -f $Name, $rowsStr, $Coverage, $File)
        if ($Coverage -eq 'CHECKED') { $script:anyChecked = $true } else { $script:anyDegraded = $true }
        $rowsN = if ($Count -is [string]) { 0 } else { [int]$Count }
        try { Register-SapArtifact -Skill 'sap-interface-inventory' -ScopeKey $script:scopeKey -ScopeKind 'SYSTEM' -Kind 'interface_source' -Format 'tsv' -Path $File -Rows $rowsN -Coverage (& { if ($Coverage -eq 'CHECKED') { 'CHECKED_CLEAN' } elseif ($Coverage -eq 'NOT_APPLICABLE') { 'NOT_APPLICABLE' } else { 'COULD_NOT_CHECK' } }) -RunId $script:RunId -System $script:sid -Client $script:effClient | Out-Null } catch {}
    }
    # rows= ">cap" when a read filled the cap (honest "at least N").
    function RowsStr { param([int] $n) if ($n -ge $MaxRows) { return ">$MaxRows" } else { return "$n" } }

    try {
        $ns = @($Namespace.ToUpper() -split '[,; ]+' | Where-Object { $_ })

        # ---- 1. RFC destinations (RFCDES) ---------------------------------
        if ($srcSet -contains 'rfc') {
            $file = Join-Path $OutputDir 'source_rfcdes.tsv'
            $have = Get-TableCols $g_dest 'RFCDES'
            if (-not (Test-Cols $have @('RFCDEST','RFCTYPE'))) {
                Write-Tsv $file "rfcdest`trfctype`toptions_raw" @("# COULD_NOT_CHECK: RFCDES columns unavailable")
                Emit-Src 'rfc' 0 'COULD_NOT_CHECK' $file
            } else {
                $key = Read-SapTableRows -Destination $g_dest -Table 'RFCDES' -Fields @('RFCDEST','RFCTYPE') -RowCount $MaxRows
                $opt = @{}
                # RFCOPTIONS is long -> separate narrow projection, keyed by RFCDEST.
                if ($have -contains 'RFCOPTIONS') {
                    $o = Read-SapTableRows -Destination $g_dest -Table 'RFCDES' -Fields @('RFCDEST','RFCOPTIONS') -RowCount $MaxRows
                    foreach ($r in $o) { $opt["$($r.RFCDEST)"] = "$($r.RFCOPTIONS)" }
                }
                $lines = @()
                foreach ($r in $key) {
                    $raw = Hide-Secrets $opt["$($r.RFCDEST)"]
                    $lines += ("{0}`t{1}`t{2}" -f (San $r.RFCDEST), (San $r.RFCTYPE), (San $raw))
                }
                Write-Tsv $file "rfcdest`trfctype`toptions_raw" $lines
                Emit-Src 'rfc' (RowsStr $key.Count) 'CHECKED' $file
            }
        }

        # ---- 2. IDoc / ALE partner profiles -------------------------------
        if ($srcSet -contains 'idoc') {
            $file = Join-Path $OutputDir 'source_we20.tsv'
            $lines = @(); $n = 0; $cov = 'CHECKED'
            # inbound handler map: process code (EDIFCT.FCTNAM) -> OBJNAM
            $handler = @{}
            if ((Get-TableCols $g_dest 'EDIFCT') -contains 'FCTNAM') {
                $ef = Read-SapTableRows -Destination $g_dest -Table 'EDIFCT' -Fields @('FCTNAM','MESTYP','OBJNAM','DIRECT') -RowCount $MaxRows
                foreach ($r in $ef) { if ("$($r.FCTNAM)" -and -not $handler.ContainsKey("$($r.FCTNAM)")) { $handler["$($r.FCTNAM)"] = "$($r.OBJNAM)" } }
            }
            if ((Get-TableCols $g_dest 'EDP13') -contains 'MESTYP') {
                $ob = Read-SapTableRows -Destination $g_dest -Table 'EDP13' -Fields @('RCVPRN','RCVPRT','MESTYP','RCVPOR','IDOCTYP') -RowCount $MaxRows
                foreach ($r in $ob) { $n++; $lines += ("OUT`t{0}`t{1}`t{2}`t{3}`t{4}`t" -f (San $r.RCVPRN),(San $r.RCVPRT),(San $r.MESTYP),(San $r.RCVPOR),(San $r.IDOCTYP)) }
            } else { $cov = 'COULD_NOT_CHECK' }
            if ((Get-TableCols $g_dest 'EDP21') -contains 'MESTYP') {
                $ib = Read-SapTableRows -Destination $g_dest -Table 'EDP21' -Fields @('SNDPRN','SNDPRT','MESTYP','EVCODE') -RowCount $MaxRows
                foreach ($r in $ib) { $n++; $h = $handler["$($r.EVCODE)"]; $lines += ("IN`t{0}`t{1}`t{2}`t{3}`t`t{4}" -f (San $r.SNDPRN),(San $r.SNDPRT),(San $r.MESTYP),(San $r.EVCODE),(San $h)) }
            } else { $cov = 'COULD_NOT_CHECK' }
            # distribution model flows (TBD05) as MODEL rows
            if ((Get-TableCols $g_dest 'TBD05') -contains 'MESTYP') {
                $md = Read-SapTableRows -Destination $g_dest -Table 'TBD05' -Fields @('SNDSYSTEM','RCVSYSTEM','MESTYP') -RowCount $MaxRows
                foreach ($r in $md) { $n++; $lines += ("MODEL`t{0}`t`t{1}`t{2}`t`t" -f (San $r.RCVSYSTEM),(San $r.MESTYP),(San $r.SNDSYSTEM)) }
            }
            Write-Tsv $file "direction`tpartner`tpartner_type`tmestyp`tport_or_procode`tidoctype`thandler_or_sender" $lines
            Emit-Src 'idoc' (RowsStr $n) $cov $file
        }

        # ---- 3. Z/Y RFC-enabled FMs (TFDIR) -------------------------------
        if ($srcSet -contains 'zfm') {
            $file = Join-Path $OutputDir 'source_zfm.tsv'
            $have = Get-TableCols $g_dest 'TFDIR'
            if (-not (Test-Cols $have @('FUNCNAME','PNAME','FMODE'))) {
                Write-Tsv $file "funcname`tfunction_group`tpackage" @("# COULD_NOT_CHECK: TFDIR columns unavailable")
                Emit-Src 'zfm' 0 'COULD_NOT_CHECK' $file
            } else {
                $nsClause = ($ns | ForEach-Object { "FUNCNAME LIKE '$_%'" }) -join ' OR '
                $where = "FMODE EQ 'R' AND ( $nsClause )"
                $fms = Read-SapTableRows -Destination $g_dest -Table 'TFDIR' -Where $where -Fields @('FUNCNAME','PNAME') -RowCount $MaxRows
                $pkgCache = @{}
                $lines = @()
                foreach ($r in $fms) {
                    $pn = "$($r.PNAME)".Trim()
                    $fg = if ($pn.ToUpper().StartsWith('SAPL')) { $pn.Substring(4) } else { $pn }
                    $pkg = ''
                    if ($fg) {
                        if ($pkgCache.ContainsKey($fg)) { $pkg = $pkgCache[$fg] }
                        else {
                            $t = Read-SapTableRows -Destination $g_dest -Table 'TADIR' -Where "PGMID EQ 'R3TR' AND OBJECT EQ 'FUGR' AND OBJ_NAME EQ '$($fg -replace "'","''")'" -Fields @('DEVCLASS') -RowCount 1
                            $pkg = if ($t.Count) { "$($t[0].DEVCLASS)".Trim() } else { '' }
                            $pkgCache[$fg] = $pkg
                        }
                    }
                    $lines += ("{0}`t{1}`t{2}" -f (San $r.FUNCNAME),(San $fg),(San $pkg))
                }
                Write-Tsv $file "funcname`tfunction_group`tpackage" $lines
                Emit-Src 'zfm' (RowsStr $fms.Count) 'CHECKED' $file
            }
        }

        # ---- 4. OData services --------------------------------------------
        if ($srcSet -contains 'odata') {
            $file = Join-Path $OutputDir 'source_odata.tsv'
            $hubCols = Get-TableCols $g_dest '/IWFND/I_MED_SRH'
            if ($hubCols -contains 'SRV_IDENTIFIER') {
                $sv = Read-SapTableRows -Destination $g_dest -Table '/IWFND/I_MED_SRH' -Fields @('SERVICE_NAME','NAMESPACE','SRV_IDENTIFIER','IS_ACTIVE') -RowCount $MaxRows
                $lines = @(); foreach ($r in $sv) { $lines += ("ODATA`t{0}`t{1}`t{2}`t{3}" -f (San $r.SERVICE_NAME),(San $r.NAMESPACE),(San $r.SRV_IDENTIFIER),(San $r.IS_ACTIVE)) }
                Write-Tsv $file "technology`tservice`tnamespace`tidentifier`tactive" $lines
                Emit-Src 'odata' (RowsStr $sv.Count) 'CHECKED' $file
            } else {
                # ECC: Gateway hub not installed -> NOT_APPLICABLE + ICFSERVICE supplement
                $lines = @("# NOT_APPLICABLE: /IWFND/I_MED_SRH absent (GW_NOT_INSTALLED); ICFSERVICE supplement below (INFERRED HTTP)")
                if ((Get-TableCols $g_dest 'ICFSERVICE') -contains 'ICF_NAME') {
                    $icf = Read-SapTableRows -Destination $g_dest -Table 'ICFSERVICE' -Where "ICFNODFLAG NE ''" -Fields @('ICF_NAME','ORIG_NAME','ICF_TCODE') -RowCount $MaxRows
                    foreach ($r in $icf) { $lines += ("HTTP`t{0}`t{1}`t`t" -f (San $r.ORIG_NAME),(San $r.ICF_NAME)) }
                }
                Write-Tsv $file "technology`tservice`tnamespace`tidentifier`tactive" $lines
                Emit-Src 'odata' 0 'NOT_APPLICABLE' $file
            }
        }

        # ---- 5. ABAP proxies (SPROXHDR) -----------------------------------
        if ($srcSet -contains 'proxy') {
            $file = Join-Path $OutputDir 'source_proxy.tsv'
            $have = Get-TableCols $g_dest 'SPROXHDR'
            if (-not (Test-Cols $have @('OBJ_NAME','DIRECTION'))) {
                Write-Tsv $file "object`tobj_name`tifr_type`tdirection`tcategory" @("# COULD_NOT_CHECK: SPROXHDR absent (proxy framework not present)")
                Emit-Src 'proxy' 0 'COULD_NOT_CHECK' $file
            } else {
                $px = Read-SapTableRows -Destination $g_dest -Table 'SPROXHDR' -Fields @('OBJECT','OBJ_NAME','IFR_TYPE','DIRECTION','CATEGORY') -RowCount $MaxRows
                $lines = @(); foreach ($r in $px) { $lines += ("{0}`t{1}`t{2}`t{3}`t{4}" -f (San $r.OBJECT),(San $r.OBJ_NAME),(San $r.IFR_TYPE),(San $r.DIRECTION),(San $r.CATEGORY)) }
                Write-Tsv $file "object`tobj_name`tifr_type`tdirection`tcategory" $lines
                Emit-Src 'proxy' (RowsStr $px.Count) 'CHECKED' $file
            }
        }

        # ---- 6. Batch jobs (TBTCO + TBTCP) --------------------------------
        if ($srcSet -contains 'jobs') {
            $file = Join-Path $OutputDir 'source_jobs.tsv'
            $have = Get-TableCols $g_dest 'TBTCO'
            if (-not (Test-Cols $have @('JOBNAME','JOBCOUNT','STATUS'))) {
                Write-Tsv $file "jobname`tjobcount`tstatus`tprogname`tvariant`ttechnology`tdirection" @("# COULD_NOT_CHECK: TBTCO columns unavailable")
                Emit-Src 'jobs' 0 'COULD_NOT_CHECK' $file
            } else {
                # program map (default + optional customer override)
                $map = @{}
                $mapFiles = @(Join-Path $SkillDir 'references\interface_program_map.tsv')
                if ($CustomUrl) { $mapFiles += (Join-Path $CustomUrl 'interface_program_map.tsv') }
                foreach ($mf in $mapFiles) {
                    if ($mf -and (Test-Path $mf)) { foreach ($ln in [System.IO.File]::ReadAllLines($mf)) { if ($ln -match '^\s*#' -or $ln.Trim() -eq '') { continue }; $c = $ln -split "`t"; if ($c.Count -ge 3 -and $c[0].Trim() -ne 'program') { $map[$c[0].Trim().ToUpper()] = @{ tech=$c[1].Trim(); dir=$c[2].Trim() } } } }
                }
                $winStart = (Get-Date).AddDays(-1 * $JobWindowDays).ToString('yyyyMMdd')
                $jobs = Read-SapTableRows -Destination $g_dest -Table 'TBTCO' -Where "SDLDATE GE '$winStart' AND STATUS NE 'F' AND STATUS NE 'A'" -Fields @('JOBNAME','JOBCOUNT','STATUS') -RowCount $MaxRows
                $steps = Read-SapTableRows -Destination $g_dest -Table 'TBTCP' -Where "SDLDATE GE '$winStart'" -Fields @('JOBNAME','JOBCOUNT','PROGNAME','VARIANT') -RowCount ($MaxRows * 2)
                $stepBy = @{}
                foreach ($s in $steps) { $k = "$($s.JOBNAME)|$($s.JOBCOUNT)"; if (-not $stepBy.ContainsKey($k)) { $stepBy[$k] = @() }; $stepBy[$k] += $s }
                $lines = @(); $n = 0
                foreach ($j in $jobs) {
                    $k = "$($j.JOBNAME)|$($j.JOBCOUNT)"
                    $js = if ($stepBy.ContainsKey($k)) { $stepBy[$k] } else { @($null) }
                    foreach ($s in $js) {
                        $prog = if ($s) { "$($s.PROGNAME)".Trim() } else { '' }
                        $var  = if ($s) { "$($s.VARIANT)".Trim() } else { '' }
                        $m = $map["$($prog.ToUpper())"]
                        $isZ = ($j.JOBNAME -match '^[ZY]') -or ($prog -match '^[ZY]')
                        if (-not $m -and -not $isZ) { continue }   # only interface-relevant jobs
                        $tech = if ($m) { $m.tech } else { '' }
                        $dir  = if ($m) { $m.dir } else { '' }
                        $n++
                        $lines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f (San $j.JOBNAME),(San $j.JOBCOUNT),(San $j.STATUS),(San $prog),(San $var),$tech,$dir)
                    }
                }
                Write-Tsv $file "jobname`tjobcount`tstatus`tprogname`tvariant`ttechnology`tdirection" $lines
                # rows = interface-relevant jobs written; note if the raw job scan hit the cap.
                $jobCov = if ($jobs.Count -ge $MaxRows) { 'COULD_NOT_CHECK' } else { 'CHECKED' }
                Emit-Src 'jobs' $n $jobCov $file
            }
        }

        Write-Host "SCOPE_KEY: $scopeKey"
        Write-Host "ARTIFACT_DIR: $OutputDir"
        $status = if ($anyChecked -and -not $anyDegraded) { 'OK' } elseif ($anyChecked) { 'PARTIAL' } else { 'PARTIAL' }
        Write-Host "STATUS: $status"
        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        Write-Host "STATUS: RFC_ERROR"
        Disconnect-SapRfc
        exit 2
    }
}
