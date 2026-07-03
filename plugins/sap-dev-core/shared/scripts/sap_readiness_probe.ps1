# =============================================================================
# sap_readiness_probe.ps1  -  Can this system run an S/4-readiness ATC check?
#                            (read-only RFC preflight)
#
# EARLY warning before a readiness ATC run. Two things go wrong and waste a full
# run that reads as "clean" (0 findings):
#   A. The connected system has NO S4HANA_READINESS* check variants at all -- an
#      ECC/older system without the readiness add-on. It cannot scope or run the
#      check. RELIABLY pre-detectable here (variant count = 0) and the main value
#      of this probe.
#   B. Variants exist but the run PLAN-ERRORS (0 findings + planning errors).
#      The dominant cause is STRUCTURAL, not a variant-picking mistake: running
#      S4HANA_READINESS LOCALLY on an S/4 *target* system against that system's
#      own custom code has no source->target delta to analyze, so every check
#      class plan-errors. This is NOT reliably pre-detectable by any table/variant
#      probe -- the authoritative catch is the RUN's planning-error count, which
#      /sap-atc already gates as ATC_PLAN_ERRORS (COUNT_PLNERR > 0 -> FAIL, never
#      a clean PASS). This probe surfaces that as a caveat, not a verdict.
#
# History (2026-07-03, cc_harvest_attempt report) -- two disproven signals, do
# not resurrect either:
#   1. SYCM_* table family as "content present" -> FALSE. S4D (1909, plan-errors
#      live) has 167 SYCM_* tables; S4H (a working S/4HANA 2022) has NONE.
#      SYCM_DOWNLOAD_STA/_MESSAGE are source-side (ECC) download tables, absent on
#      S/4 targets. So this probe does NOT claim content present/absent.
#   2. Target-release variant RICHNESS (release-suffixed variants like _2022) as
#      "this run will produce findings" -> ALSO FALSE. The fixture harvest ran
#      LIVE on S4H (S/4HANA 2022) with 16 variants INCLUDING _2022/_2020 and STILL
#      returned 0 findings + 7 planning errors -- identical to S4D (1909). So
#      richness only tells you which target releases the variants NOMINALLY cover;
#      it does NOT predict a productive run. The ONLY reliable pre-signal is
#      COUNT == 0 (case A). The definitive signal is always the RUN's plan-error
#      count. Readiness findings come from the ECC *source* (readiness add-on
#      there) or a hub checking a source REMOTELY -- not a local S/4-target run.
#
# DUAL USE (mirrors sap_object_resolver.ps1):
#   * Dot-source -> Get-SapReadinessCapability -Dest $dest   (caller owns the
#     already-connected NCo destination; no reconnect -- used by /sap-doctor).
#   * CLI        -> connects via Connect-SapRfc (pinned-profile fallback when the
#     -Sap* params are empty) -- used by /sap-cc-analyze + standalone.
#
# Params (CLI): -Server -Sysnr -Client -User -Password -Language (all optional;
#   empty => Connect-SapRfc pinned-profile fallback), -RfcLib <path>.
#
# CLI stdout (last lines, STABLE grammar):
#   READINESS: verdict=<V> variants=<n> target_variants=<csv|none>
#   DETAIL: <one-line human summary>
#   FIX: <remediation or ->
# where <V> in { READINESS_CAPABLE | NO_READINESS_VARIANTS | RFC_ERROR }
# CLI exit: 0 probe ran (verdict on stdout) | 2 RFC/probe error
#   -- policy (warn vs block) is the CALLER's; exit only signals "did the probe run".
# =============================================================================

[CmdletBinding()]
param(
    [string]$Server   = '',
    [string]$Sysnr    = '',
    [string]$Client   = '',
    [string]$User     = '',
    [string]$Password = '',
    [string]$Language = '',
    [string]$RfcLib   = ''
)

# Self-contained RFC_READ_TABLE reader (no dependency on Add-RfcOption/Field so
# it works whether or not the caller dot-sourced sap_rfc_lib's helpers). Returns
# the WA string rows, or $null on RFC failure / TABLE_NOT_AVAILABLE.
function script:RtRows($dest, [string]$table, [string]$where, [string[]]$fields) {
    try {
        $fn = $dest.Repository.CreateFunction('RFC_READ_TABLE')
        $fn.SetValue('QUERY_TABLE', $table); $fn.SetValue('DELIMITER', '|')
        if ($where) { $o = $fn.GetTable('OPTIONS'); $r = $o.Metadata.LineType.CreateStructure(); $r.SetValue('TEXT', $where); $o.Append($r) }
        if ($fields) { $fl = $fn.GetTable('FIELDS'); foreach ($c in $fields) { $s = $fl.Metadata.LineType.CreateStructure(); $s.SetValue('FIELDNAME', $c); $fl.Append($s) } }
        $fn.Invoke($dest)
        $d = $fn.GetTable('DATA'); $out = @()
        for ($i = 0; $i -lt $d.Count; $i++) { $out += $d[$i].GetString('WA') }
        return ,$out
    } catch { return $null }
}

function Get-SapReadinessCapability {
    <#
      Can the connected system run an S/4-readiness ATC check? -Dest is an
      already-open RfcDestination. Returns { verdict, variants, target_variants,
      detail, fix }. Never throws on a probe miss.
    #>
    param([Parameter(Mandatory)]$Dest)

    $rows = script:RtRows $Dest 'SCICHKV_HD' "CHECKVNAME LIKE 'S4HANA_READINESS%'" @('CHECKVNAME')
    $names = @()
    if ($null -ne $rows) { foreach ($r in $rows) { $n = ($r -split '\|')[0].Trim(); if ($n) { $names += $n } } }
    $variants = $names.Count
    # "target" variants = release-suffixed ones (e.g. _1909/_2020/_2022). These
    # tell you which target releases the variants NOMINALLY cover -- they do NOT
    # predict a productive run (S4H had _2022/_2020 and still plan-errored; see
    # the header). Reported for context only, never as a go/no-go signal.
    $targets = @($names | Where-Object { $_ -match '_(15\d\d|16\d\d|17\d\d|18\d\d|19\d\d|20\d\d|21\d\d|22\d\d)(_|$)' })

    if ($variants -eq 0) {
        return [pscustomobject]@{
            verdict = 'NO_READINESS_VARIANTS'; variants = 0; target_variants = @()
            detail  = 'No S4HANA_READINESS* ATC check variants on this system -- it cannot scope or run an S/4-readiness check (an ECC/older system without the readiness add-on, or a non-ABAP-Platform system).'
            fix     = 'Run readiness on a system that carries the readiness variants (an S/4 check hub), or check this system remotely FROM such a hub (central ATC: SM59 + ATC > Manage System Groupings).'
        }
    }
    return [pscustomobject]@{
        verdict = 'READINESS_CAPABLE'; variants = $variants; target_variants = $targets
        detail  = ("{0} S4HANA_READINESS* variant(s) present{1} -- the variants exist, so a run is POSSIBLE, but this does NOT predict findings. A LOCAL run on an S/4 target commonly returns 0 findings + planning errors (no source->target delta; observed live on S/4HANA 1909 AND 2022) -- /sap-atc gates that as ATC_PLAN_ERRORS, not a clean pass. Readiness findings come from the ECC source or a hub checking a source remotely." -f $variants, $(if ($targets.Count) { " incl. target-release " + (($targets | Select-Object -First 4) -join ',') + " (nominal coverage only)" } else { " (header shells only; no release-suffixed target variant)" }))
        fix     = '-'
    }
}

# --- CLI mode (only when run directly, not dot-sourced) -------------------------
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($RfcLib)) { $RfcLib = Join-Path $PSScriptRoot 'sap_rfc_lib.ps1' }
    if (-not (Test-Path -LiteralPath $RfcLib)) { Write-Output 'READINESS: verdict=RFC_ERROR variants=0 target_variants=none'; Write-Output "DETAIL: sap_rfc_lib.ps1 not found at $RfcLib"; Write-Output 'FIX: pass -RfcLib <path> or run from shared/scripts'; exit 2 }
    . $RfcLib
    $dest = $null
    try { $dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -Client $Client -User $User -Password $Password -Language $Language -DestName 'SAP_READINESS_PROBE' } catch { $dest = $null }
    if (-not $dest) {
        Write-Output 'READINESS: verdict=RFC_ERROR variants=0 target_variants=none'
        Write-Output 'DETAIL: RFC connect failed (host/sysnr/client/user/password or a broken AI-session pin).'
        Write-Output 'FIX: verify the pinned profile: /sap-login --list ; re-pin with /sap-login --switch <id>'
        exit 2
    }
    $st = Get-SapReadinessCapability -Dest $dest
    try { Disconnect-SapRfc } catch {}
    $tv = if ($st.target_variants.Count) { ($st.target_variants -join ',') } else { 'none' }
    Write-Output ("READINESS: verdict={0} variants={1} target_variants={2}" -f $st.verdict, $st.variants, $tv)
    Write-Output ("DETAIL: {0}" -f $st.detail)
    Write-Output ("FIX: {0}" -f $st.fix)
    exit 0
}
