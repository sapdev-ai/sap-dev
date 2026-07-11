# =============================================================================
# sap_cc_cloud_download.ps1  -  RFC source download for /sap-cc-cloud-readiness
# -----------------------------------------------------------------------------
# READ-ONLY. Downloads ABAP source for a scope of objects over RFC via the
# shared sanctioned reader (RPY_*, never REPOSRC), naming each file with the
# scanner's <TYPE>__<NAME>.abap convention and writing a coverage.tsv the
# offline scanner consumes. Runs under 32-bit PowerShell (NCo 3.1).
#
# Object-type -> reader mapping (v1):
#   PROG / REPS        -> program        (RPY_PROGRAM_READ)
#   INCL / INCLUDE     -> include        (RPY_PROGRAM_READ)
#   FUNC               -> fm             (TFDIR + RPY_PROGRAM_READ of the include)
#   CLAS / INTF        -> COULD_NOT_CHECK reason=CLASS_SOURCE_OVER_RFC_UNSUPPORTED
#   FUGR / DDIC / *    -> COULD_NOT_CHECK reason=TYPE_NOT_SOURCE_SCANNABLE_V1
# Classes degrade honestly (never silently skipped) -- the wrapper-bridged
# SEO_METHOD_GET_SOURCE class reader is the v1.5 upgrade (see SKILL.md).
#
# Scope file (TSV, header): object_type<TAB>object_name[<TAB>package]
# Output:
#   {CacheDir}\<TYPE>__<NAME>.abap  (one per readable object; # replaces / in NAME)
#   {CacheDir}\coverage.tsv         object_type/object_name/package/coverage/reason
# Grammar:
#   DL: <TYPE> <NAME> status=<OK|COULD_NOT_CHECK|NOT_FOUND> lines=<n>
#   STATUS: OK downloaded=<n> could_not_check=<c> not_found=<m> total=<t> file=<coverage>
#   STATUS: ERROR msg=<CC_SOURCE_READ_FAILED|RFC_LOGON_FAILED|CC_SCOPE_EMPTY|...>
# Exit: 0 ok | 1 empty scope | 2 error (connect / all-unreadable / bad input)
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScopeFile,
    [Parameter(Mandatory)][string]$CacheDir,
    [Parameter(Mandatory)][string]$SharedDir,
    [string]$WorkDir = '',
    [switch]$Refresh
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if ($WorkDir) { $env:SAPDEV_AI_WORK_DIR = $WorkDir }

function Fail([string]$msg) { Write-Output "STATUS: ERROR msg=$msg"; exit 2 }

if (-not (Test-Path -LiteralPath $ScopeFile)) { Fail "CC_SCAN_BAD_INPUT scope file not found: $ScopeFile" }
. (Join-Path $SharedDir 'sap_rfc_read_source.ps1')   # dot-sources sap_rfc_lib.ps1

# ---- parse scope ------------------------------------------------------------
$rows = @()
$lines = @(Get-Content -LiteralPath $ScopeFile)
if ($lines.Count -ge 1) {
    $h = @{}; $hdr = @($lines[0] -split "`t"); for ($i = 0; $i -lt $hdr.Count; $i++) { $h[$hdr[$i].Trim().ToLower()] = $i }
    if (-not $h.ContainsKey('object_type') -or -not $h.ContainsKey('object_name')) { Fail 'CC_SCAN_BAD_INPUT scope needs object_type + object_name columns' }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].Trim()) { continue }
        $c = $lines[$i] -split "`t"
        $ty = $c[$h['object_type']].Trim().ToUpper(); $nm = $c[$h['object_name']].Trim()
        if (-not $ty -or -not $nm) { continue }
        $pk = if ($h.ContainsKey('package')) { $c[$h['package']].Trim() } else { '' }
        $rows += @{ Type = $ty; Name = $nm; Package = $pk }
    }
}
if ($rows.Count -eq 0) { Write-Output 'STATUS: EMPTY'; exit 1 }

[void][System.IO.Directory]::CreateDirectory($CacheDir)

# ---- connect (pinned S/4 profile; Step 1.5 guarantees it is S/4) ------------
$dest = Connect-SapRfc -DestName 'CCDL'
if (-not $dest) { Fail 'RFC_LOGON_FAILED' }

$map = @{ 'PROG'='program'; 'REPS'='program'; 'INCL'='include'; 'INCLUDE'='include'; 'FUNC'='fm' }
$cov = @("object_type`tobject_name`tpackage`tcoverage`treason")
$dl = 0; $cnc = 0; $nf = 0
try {
    foreach ($r in $rows) {
        $safe = ($r.Name -replace '/', '#')
        $dst = Join-Path $CacheDir ("{0}__{1}.abap" -f $r.Type, $safe)
        if ((-not $Refresh) -and (Test-Path -LiteralPath $dst)) {
            Write-Output "DL: $($r.Type) $($r.Name) status=CACHED"
            $cov += ("{0}`t{1}`t{2}`tFULL`tCACHED" -f $r.Type, $r.Name, $r.Package); $dl++; continue
        }
        $rt = $map[$r.Type]
        if (-not $rt) {
            $reason = if ($r.Type -in @('CLAS','INTF')) { 'CLASS_SOURCE_OVER_RFC_UNSUPPORTED' } else { 'TYPE_NOT_SOURCE_SCANNABLE_V1' }
            Write-Output "DL: $($r.Type) $($r.Name) status=COULD_NOT_CHECK reason=$reason"
            $cov += ("{0}`t{1}`t{2}`tCOULD_NOT_CHECK`t{3}" -f $r.Type, $r.Name, $r.Package, $reason); $cnc++; continue
        }
        $res = Read-SapAbapSource -Name $r.Name -Type $rt -OutDir $CacheDir -Dest $dest
        if ($res.Status -eq 'OK' -and $res.SourceFile -and (Test-Path -LiteralPath $res.SourceFile)) {
            Copy-Item -LiteralPath $res.SourceFile -Destination $dst -Force
            # the shared reader reuses one scratch filename per OutDir; remove it so the next object can't inherit stale bytes
            if ((Split-Path -Leaf $res.SourceFile) -ne (Split-Path -Leaf $dst)) { Remove-Item -LiteralPath $res.SourceFile -Force -ErrorAction SilentlyContinue }
            Write-Output "DL: $($r.Type) $($r.Name) status=OK lines=$($res.Lines)"
            $cov += ("{0}`t{1}`t{2}`tFULL`t" -f $r.Type, $r.Name, $r.Package); $dl++
        } elseif ($res.Status -eq 'NOT_FOUND') {
            Write-Output "DL: $($r.Type) $($r.Name) status=NOT_FOUND"
            $cov += ("{0}`t{1}`t{2}`tCOULD_NOT_CHECK`tNOT_FOUND" -f $r.Type, $r.Name, $r.Package); $nf++
        } else {
            Write-Output "DL: $($r.Type) $($r.Name) status=COULD_NOT_CHECK reason=SOURCE_READ_$($res.Status)"
            $cov += ("{0}`t{1}`t{2}`tCOULD_NOT_CHECK`tSOURCE_READ_$($res.Status)" -f $r.Type, $r.Name, $r.Package); $cnc++
        }
    }
} finally { try { Disconnect-SapRfc -Destination $dest } catch {}; try { Disconnect-SapRfc } catch {} }

$enc = New-Object System.Text.UTF8Encoding($false)
$covPath = Join-Path $CacheDir 'coverage.tsv'
[System.IO.File]::WriteAllText($covPath, (($cov -join "`r`n") + "`r`n"), $enc)

# 100% unreadable is an infra error, not a clean "nothing cloud-relevant" result.
if ($dl -eq 0 -and ($cnc + $nf) -eq $rows.Count -and $rows.Count -gt 0) {
    $scannable = @($rows | Where-Object { $map.ContainsKey($_.Type) }).Count
    if ($scannable -gt 0) { Fail 'CC_SOURCE_READ_FAILED all scannable objects unreadable' }
}
Write-Output "STATUS: OK downloaded=$dl could_not_check=$cnc not_found=$nf total=$($rows.Count) file=$covPath"
exit 0
