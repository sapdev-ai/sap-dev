# =============================================================================
# sap_output_walk.ps1  -  Stages 4-8 of /sap-output-diagnose (read-only RFC)
#
# When the expected NAST output row is absent (or to explain a determination),
# walks the classic condition technique for a document, read-only:
#   procedure (TVFK-KALSM for V3 / T683 for EF) -> steps T683S -> per output type
#   the access sequence T685-KOZGF -> accesses T682I (KOTABNR -> B<nnn>) -> access
#   key fields T682Z -> rebuild each access key FROM THE DOCUMENT -> probe B<nnn>.
# A full-key hit = a condition record exists (determination succeeds); a full miss
# with the exact rebuilt key = NO_RECORD; a requirement routine (T683S-KOBED != 0)
# is flagged (RV61B<nnn>, named never executed). BRF+ Output Management is probed
# on S/4 only (APOC_D_OR_ROOT existence = the release gate).
#
#   -App billing|po   -DocNo <VBELN|EBELN>   [-Kschl <type>]  [-OutJson <path>]
#
# READ-ONLY. RFC_READ_TABLE + DDIF_FIELDINFO_GET (FMODE=R, probed S4D + EC2
# 2026-07-11). Each B-table's real key fields are read via DDIF (they vary - B001
# has no validity fields); the WHERE is chunked at AND boundaries by the shared
# Read-SapTableRows (RFC_READ_TABLE caps OPTIONS rows at 72 chars).
#
# Output (stdout, parseable by SKILL.md):
#   PROC:  app=<..> kalsm=<procedure> steps=<n>
#   WALK:  kschl=<t> access=<B nnn> result=<RECORD_EXISTS|NO_RECORD|COULD_NOT_CHECK>
#          key="<field=val ...>" knumh=<n> nearmiss=<n>
#   FIND:  kschl=<t> verdict=<RECORD_EXISTS|NO_RECORD|REQUIREMENT_BLOCKED|MANUAL_ONLY|
#          NOT_IN_PROCEDURE|COULD_NOT_CHECK> detail="<...>"
#   BRFPLUS: managed=<Y|N|SKIPPED_ECC>
#   STATUS: OK types=<n> no_record=<n> exists=<n> requirement=<n> manual=<n> cnc=<n> | RFC_ERROR
# Exit: 0 = OK | 2 = connect failure.
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('billing','po')]
    [string]   $App = 'billing',
    [string]   $DocNo = '',
    [string]   $Kschl = '',
    [string]   $OutJson = '',
    [string]   $SharedDir = '',
    [string]   $SkillDir = '',
    [string]   $CustomUrl = '',
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

function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Qz  { param([string] $s) return ((San $s) -replace '"', "'") }

# DDIF: ordered key field names (excl. MANDT) + whether the table has a KNUMH col.
$script:ddicCache = @{}
function Get-TableKeys {
    param($Destination, [string] $Table)
    if ($script:ddicCache.ContainsKey($Table)) { return $script:ddicCache[$Table] }
    $keys = @(); $hasKnumh = $false
    try {
        $fn = $Destination.Repository.CreateFunction('DDIF_FIELDINFO_GET')
        $fn.SetValue('TABNAME', $Table); $fn.Invoke($Destination)
        $t = $fn.GetTable('DFIES_TAB')
        for ($i = 0; $i -lt $t.RowCount; $i++) {
            $t.CurrentIndex = $i
            $f = San $t.GetValue('FIELDNAME'); $k = San $t.GetValue('KEYFLAG')
            if ($f -eq 'KNUMH') { $hasKnumh = $true }
            if ($k -eq 'X' -and $f -ne 'MANDT') { $keys += $f }
        }
    } catch { }
    $res = @{ keys = $keys; hasKnumh = $hasKnumh }
    $script:ddicCache[$Table] = $res
    return $res
}

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    if (-not $DocNo) { Write-Host "STATUS: RFC_ERROR reason=no_docno"; exit 2 }
    $kappl = if ($App -eq 'po') { 'EF' } else { 'V3' }
    $doc = (San $DocNo); if ($doc -match '^\d+$') { $doc = $doc.PadLeft(10, '0') }
    $hdrTable = if ($App -eq 'po') { 'EKKO' } else { 'VBRK' }

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $UserId -Password $Password -Language $Language `
                             -DestName "SAPDEV_OUTWALK"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

    # ---- customer field-map override (comm-field -> header source field) ------
    $fieldMap = @{}   # "<KAPPL>|<QUFNA>" -> source header field
    foreach ($mf in @((Join-Path $SkillDir 'references\output_field_map.tsv'), $(if ($CustomUrl) { Join-Path $CustomUrl 'output_field_map.tsv' } else { '' }))) {
        if ($mf -and (Test-Path $mf)) {
            foreach ($ln in [System.IO.File]::ReadAllLines($mf)) {
                if ($ln -match '^\s*#' -or -not $ln.Trim()) { continue }
                $c = $ln -split "`t"; if ($c.Count -ge 4 -and $c[0].Trim() -ne 'kappl') { $fieldMap["$($c[0].Trim())|$($c[1].Trim())"] = $c[3].Trim() }
            }
        }
    }

    $hdrKeysInfo = Get-TableKeys $g_dest $hdrTable
    # header column set (key + any) via a second DDIF pass for direct-read test
    $hdrCols = @()
    try {
        $fn = $g_dest.Repository.CreateFunction('DDIF_FIELDINFO_GET'); $fn.SetValue('TABNAME', $hdrTable); $fn.Invoke($g_dest)
        $t = $fn.GetTable('DFIES_TAB'); for ($i = 0; $i -lt $t.RowCount; $i++) { $t.CurrentIndex = $i; $hdrCols += (San $t.GetValue('FIELDNAME')) }
    } catch { }

    $docFieldCache = @{}
    # Resolve a comm-structure field (QUFNA) to the document's value. Returns
    # $null when it cannot be resolved (=> COULD_NOT_CHECK, never a false miss).
    function Get-DocField {
        param([string] $qufna)
        if ($docFieldCache.ContainsKey($qufna)) { return $docFieldCache[$qufna] }
        $val = $null
        try {
            if ($App -eq 'billing' -and $qufna -match '^KUN(RE|WE|AG|RG)$') {
                $parvw = $qufna.Substring(3, 2)
                $vp = Read-SapTableRows -Destination $g_dest -Table 'VBPA' -Where "VBELN EQ '$doc' AND PARVW EQ '$parvw' AND POSNR EQ '000000'" -Fields @('KUNNR') -RowCount 1
                if (@($vp).Count -and (San $vp[0].KUNNR)) { $val = San $vp[0].KUNNR }
                if (-not $val) { $vk = Read-SapTableRows -Destination $g_dest -Table 'VBRK' -Where "VBELN EQ '$doc'" -Fields @('KUNRG') -RowCount 1; if (@($vk).Count) { $val = San $vk[0].KUNRG } }
            }
            elseif ($hdrCols -contains $qufna) {
                $key = if ($App -eq 'po') { 'EBELN' } else { 'VBELN' }
                $hr = Read-SapTableRows -Destination $g_dest -Table $hdrTable -Where "$key EQ '$doc'" -Fields @($qufna) -RowCount 1
                if (@($hr).Count) { $val = San $hr[0].$qufna }
            }
            elseif ($fieldMap.ContainsKey("$kappl|$qufna")) {
                $src = $fieldMap["$kappl|$qufna"]
                if ($hdrCols -contains $src) {
                    $key = if ($App -eq 'po') { 'EBELN' } else { 'VBELN' }
                    $hr = Read-SapTableRows -Destination $g_dest -Table $hdrTable -Where "$key EQ '$doc'" -Fields @($src) -RowCount 1
                    if (@($hr).Count) { $val = San $hr[0].$src }
                }
            }
        } catch { $val = $null }
        $docFieldCache[$qufna] = $val
        return $val
    }

    $findings = @()
    $cExists = 0; $cNoRec = 0; $cReqFlag = 0; $cManual = 0; $cCnc = 0

    try {
        # ---- Stage 4: resolve the output procedure -------------------------
        $kalsm = ''
        if ($App -eq 'billing') {
            $vb = Read-SapTableRows -Destination $g_dest -Table 'VBRK' -Where "VBELN EQ '$doc'" -Fields @('FKART') -RowCount 1
            if (@($vb).Count) { $fkart = San $vb[0].FKART; $tv = Read-SapTableRows -Destination $g_dest -Table 'TVFK' -Where "FKART EQ '$fkart'" -Fields @('KALSM') -RowCount 1; if (@($tv).Count) { $kalsm = San $tv[0].KALSM } }
        } else {
            $ps = Read-SapTableRows -Destination $g_dest -Table 'T683S' -Where "KVEWE EQ 'B' AND KAPPL EQ 'EF'" -Fields @('KALSM') -RowCount 200
            $distinct = @($ps | ForEach-Object { San $_.KALSM } | Sort-Object -Unique)
            if ($distinct.Count -ge 1) { $kalsm = $distinct[0]; if ($distinct.Count -gt 1) { Write-Host ("FIND: kschl=* verdict=INFO detail=`"{0} EF output procedures exist; walking {1} (pass --type to pin an output type)`"" -f $distinct.Count,$kalsm) } }
        }
        if (-not $kalsm) { Write-Host "FIND: kschl=* verdict=COULD_NOT_CHECK detail=`"output procedure not resolvable for this document type`""; Write-Host "STATUS: OK types=0 no_record=0 exists=0 requirement=0 manual=0 cnc=1"; Disconnect-SapRfc; exit 0 }

        $steps = Read-SapTableRows -Destination $g_dest -Table 'T683S' -Where "KVEWE EQ 'B' AND KAPPL EQ '$kappl' AND KALSM EQ '$kalsm'" -Fields @('STUNR','KSCHL','KOBED') -RowCount 60
        Write-Host ("PROC: app={0} kalsm={1} steps={2}" -f $App,$kalsm,@($steps).Count)

        $cands = if ($Kschl) { @([pscustomobject]@{ KSCHL=(San $Kschl); KOBED='' }) } else { @($steps | ForEach-Object { [pscustomobject]@{ KSCHL=(San $_.KSCHL); KOBED=(San $_.KOBED) } }) }

        foreach ($c in $cands) {
            $ks = $c.KSCHL; if (-not $ks) { continue }
            $req = ($c.KOBED -and $c.KOBED -ne '0000000' -and $c.KOBED -ne '000')

            $t685 = Read-SapTableRows -Destination $g_dest -Table 'T685' -Where "KVEWE EQ 'B' AND KAPPL EQ '$kappl' AND KSCHL EQ '$ks'" -Fields @('KOZGF') -RowCount 1
            $kozgf = if (@($t685).Count) { San $t685[0].KOZGF } else { '' }
            if (-not $kozgf) { Write-Host ("FIND: kschl={0} verdict=MANUAL_ONLY detail=`"no access sequence - output type is manual-only`"" -f $ks); $findings += @{ kschl=$ks; verdict='MANUAL_ONLY' }; $cManual++; continue }

            $acc = Read-SapTableRows -Destination $g_dest -Table 'T682I' -Where "KVEWE EQ 'B' AND KAPPL EQ '$kappl' AND KOZGF EQ '$kozgf'" -Fields @('KOLNR','KOTABNR') -RowCount 20
            $anyHit = $false; $anyCnc = $false; $lastKey = ''
            foreach ($a in @($acc)) {
                $kolnr = San $a.KOLNR; $kotabnr = San $a.KOTABNR
                $btab = 'B' + ([int]$kotabnr).ToString('000')
                $bk = Get-TableKeys $g_dest $btab
                if (-not $bk.keys.Count) { Write-Host ("WALK: kschl={0} access={1} result=COULD_NOT_CHECK key=`"table not readable`"" -f $ks,$btab); $anyCnc = $true; continue }

                # access field map (B-table field <- comm/source field)
                $zmap = @{}
                $zf = Read-SapTableRows -Destination $g_dest -Table 'T682Z' -Where "KVEWE EQ 'B' AND KAPPL EQ '$kappl' AND KOZGF EQ '$kozgf' AND KOLNR EQ '$kolnr'" -Fields @('ZIFNA','QUFNA') -RowCount 30
                foreach ($z in @($zf)) { $zmap[(San $z.ZIFNA)] = (San $z.QUFNA) }

                $clauses = @(); $keyDesc = @(); $cnc = $false
                foreach ($bf in $bk.keys) {
                    if ($bf -eq 'KAPPL') { $v = $kappl }
                    elseif ($bf -eq 'KSCHL') { $v = $ks }
                    else {
                        $qufna = if ($zmap.ContainsKey($bf) -and $zmap[$bf]) { $zmap[$bf] } else { $bf }
                        $v = Get-DocField $qufna
                        if ($null -eq $v) { $cnc = $true; $v = '?' }
                    }
                    $clauses += "$bf EQ '$($v -replace "'","''")'"
                    $keyDesc += "$bf=$v"
                }
                $lastKey = ($keyDesc -join ' ')
                if ($cnc) { Write-Host ("WALK: kschl={0} access={1} result=COULD_NOT_CHECK key=`"{2}`"" -f $ks,$btab,$lastKey); $anyCnc = $true; continue }

                $readFields = @($bk.keys); if ($bk.hasKnumh) { $readFields += 'KNUMH' }
                $rows = Read-SapTableRows -Destination $g_dest -Table $btab -Where ($clauses -join ' AND ') -Fields $readFields -RowCount 3
                if (@($rows).Count) {
                    $knumh = if ($bk.hasKnumh) { San $rows[0].KNUMH } else { '' }
                    Write-Host ("WALK: kschl={0} access={1} result=RECORD_EXISTS key=`"{2}`" knumh={3}" -f $ks,$btab,$lastKey,$knumh)
                    $anyHit = $true
                } else {
                    # near-miss: drop the last (most specific) non-KAPPL/KSCHL clause
                    $nm = 0
                    if ($clauses.Count -gt 1) {
                        $relaxed = $clauses[0..($clauses.Count - 2)]
                        try { $nmr = Read-SapTableRows -Destination $g_dest -Table $btab -Where ($relaxed -join ' AND ') -Fields $bk.keys -RowCount 10; $nm = @($nmr).Count } catch { }
                    }
                    Write-Host ("WALK: kschl={0} access={1} result=NO_RECORD key=`"{2}`" nearmiss={3}" -f $ks,$btab,$lastKey,$nm)
                }
            }

            # RECORD_EXISTS wins over the requirement flag: a matched record is the
            # primary fact; the requirement routine is a modifier. SKILL.md synthesizes
            # the true "REQUIREMENT_BLOCKED" verdict by combining this with the NAST
            # status (record exists + no output produced + requirement present).
            if ($anyHit) {
                $rd = if ($req) { "condition record exists AND requirement routine RV61B$($c.KOBED) gates it - if no output was produced despite the record, the requirement suppressed it" } else { "condition record exists - determination succeeds; check the NAST processing status" }
                Write-Host ("FIND: kschl={0} verdict=RECORD_EXISTS detail=`"{1}`"" -f $ks,$rd); $findings += @{ kschl=$ks; verdict='RECORD_EXISTS'; requirement=$req }; $cExists++
            }
            elseif ($anyCnc) { Write-Host ("FIND: kschl={0} verdict=COULD_NOT_CHECK detail=`"one or more access key fields could not be rebuilt from the document`"" -f $ks); $findings += @{ kschl=$ks; verdict='COULD_NOT_CHECK' }; $cCnc++ }
            else {
                $reqNote = if ($req) { " (this output type also carries requirement routine RV61B$($c.KOBED))" } else { '' }
                Write-Host ("FIND: kschl={0} verdict=NO_RECORD detail=`"no condition record for key: {1}{2}`"" -f $ks,$lastKey,$reqNote); $findings += @{ kschl=$ks; verdict='NO_RECORD'; key=$lastKey; requirement=$req }; $cNoRec++
            }
            if ($req) { $cReqFlag++ }
        }

        # ---- Stage 8: BRF+ Output Management (S/4 only) -------------------
        $brf = 'SKIPPED_ECC'
        $om = Read-SapTableRows -Destination $g_dest -Table 'DD02L' -Where "TABNAME EQ 'APOC_D_OR_ROOT'" -Fields @('TABNAME') -RowCount 1
        if (@($om).Count) {
            $brf = 'N'
            # best-effort per-document probe deferred: presence of the framework is
            # the disclosure; a per-doc link needs the OM key resolved live.
            Write-Host "BRFPLUS: managed=? detail=`"S/4 Output Management (BRF+) framework present - if this document is OM-managed the NAST verdict is not complete; check via BRF+/NACE-successor`""
        } else {
            Write-Host "BRFPLUS: managed=SKIPPED_ECC"
        }

        if ($OutJson) { try { @{ app=$App; docno=$doc; kalsm=$kalsm; findings=$findings } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutJson -Encoding UTF8 } catch { } }
        Write-Host ("STATUS: OK types=$($cands.Count) no_record=$cNoRec exists=$cExists manual=$cManual cnc=$cCnc req_flagged=$cReqFlag")
        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host ("ERROR: {0}" -f (San $_.Exception.Message))
        Write-Host "STATUS: RFC_ERROR"
        Disconnect-SapRfc
        exit 2
    }
}
