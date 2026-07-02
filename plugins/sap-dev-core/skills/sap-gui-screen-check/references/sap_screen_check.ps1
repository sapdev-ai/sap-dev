# =============================================================================
# sap_screen_check.ps1
# -----------------------------------------------------------------------------
# Deterministic orchestrator for /sap-gui-screen-check (live half of the
# golden-screen regression harness; contract: contributing/golden_screen_baselines.md,
# schema sapdev.screenbaseline/1).
#
# Discovers screen baselines (references/<stem>.screens.json), and for each
# checkpoint generates + runs the read-only probe references/sap_screen_check_probe.vbs
# via 32-bit cscript, compares the live screen identity (program + dynpro,
# dynpro Pad4-normalized) and required control-ID presence against the
# baseline, and rolls the results up into a verdict.
#
# Args:
#   -All                    check every baseline under <plugins-root>\*\skills\*\references\
#   -Skill <name>           check one skill's baselines
#   -BaselinePath <file>    check exactly one baseline file
#   -ProbeVbs <file>        path to sap_screen_check_probe.vbs (required)
#   -WorkTemp <dir>         base temp dir; a unique per-run scratch subdir is
#                           minted under it for the generated probe copies
#   -SessionPath <path>     optional explicit /app/con[N]/ses[M] target
#   -Capture                emit CAPTURE: lines for pending_live checkpoints
#                           (the SKILL.md flow applies them via the Edit tool
#                           under --update-baseline; this script NEVER writes
#                           a baseline file)
#
# Stdout contract (parsed by the SKILL.md flow):
#   CHECK: <stem>/<cp> | RESULT: PASS|DRIFT|PENDING|COULD_NOT_CHECK | IDS: <n>/<m> | IDENTITY: <pgm>/<scr> [| BASELINE: <pgm>/<scr> | SEVERITY: BLOCKER] | DETAIL: <text>
#     MISSING_ID: <path>                      (one per missing required control)
#   CAPTURE: <baseline-path> | <cp.id> | program=<pgm> | dynpro=<scr>
#   SCREENCHECK: <OK|DRIFT|DEGRADED> baselines=<N> checkpoints=<M> PASS=.. DRIFT=.. CNC=.. PENDING=..
#
# Verdict:
#   OK        every captured checkpoint verified (identity + all required IDs)
#   DRIFT     one or more captured checkpoints drifted (BLOCKER)
#   DEGRADED  nothing gated: only pending_live / COULD_NOT_CHECK results (or a
#             captured checkpoint could not be checked)
#
# Exit codes: 1 = any checkpoint DRIFTed; 2 = hard input error (probe template
# missing, no baselines in scope, malformed baseline JSON) with no drift;
# 0 = otherwise. Probe exit 2 (SAP unreachable) / 3 (refused: busy/ambiguous)
# are per-checkpoint COULD_NOT_CHECK results, not drift.
#
# Plain Windows PowerShell 5.1 compatible. Read-only against SAP (the probe
# only navigates and restores /n). ASCII-only source.
# =============================================================================
[CmdletBinding()]
param(
    [switch]$All,
    [string]$Skill = '',
    [string]$BaselinePath = '',
    [string]$ProbeVbs = '',
    [string]$WorkTemp = '',
    [string]$SessionPath = '',
    [switch]$Capture
)

# No Set-StrictMode / global EAP=Stop on purpose: a slightly-off baseline must
# produce a clean ERROR line (not a raw PS exception), and PS 5.1 turns
# redirected native stderr (cscript 2>&1) into terminating errors under
# EAP=Stop. Failure paths are handled explicitly below.
$ErrorActionPreference = 'Continue'

function Pad4([object]$v) {
    $s = ('' + $v).Trim()
    if ($s -match '^[0-9]+$') { return $s.PadLeft(4, '0') }
    return $s
}

function NormProgram([object]$v) {
    return ('' + $v).Trim().ToUpperInvariant()
}

# ---------------------------------------------------------------------------
# Validate inputs / resolve scope
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ProbeVbs) -or -not (Test-Path -LiteralPath $ProbeVbs)) {
    Write-Output ("ERROR: probe template not found: " + $ProbeVbs)
    exit 2
}

$cscript = 'C:\Windows\SysWOW64\cscript.exe'
if (-not (Test-Path -LiteralPath $cscript)) {
    # 32-bit Windows: System32 hosts the (32-bit) cscript.
    $cscript = Join-Path $env:windir 'System32\cscript.exe'
}

# plugins root = 4 levels up from references\ (references -> skill -> skills -> plugin -> plugins root)
$pluginsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))

$baselineFiles = @()
if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) {
    if (-not (Test-Path -LiteralPath $BaselinePath)) {
        Write-Output ("ERROR: baseline not found: " + $BaselinePath)
        exit 2
    }
    $baselineFiles = @((Get-Item -LiteralPath $BaselinePath))
} elseif (-not [string]::IsNullOrWhiteSpace($Skill)) {
    $baselineFiles = @(Get-ChildItem -Path (Join-Path $pluginsRoot ('*\skills\' + $Skill + '\references\*.screens.json')) -File -ErrorAction SilentlyContinue | Sort-Object FullName)
} elseif ($All) {
    $baselineFiles = @(Get-ChildItem -Path (Join-Path $pluginsRoot '*\skills\*\references\*.screens.json') -File -ErrorAction SilentlyContinue | Sort-Object FullName)
} else {
    Write-Output "ERROR: specify a scope: -All, -Skill <name>, or -BaselinePath <file>."
    exit 2
}

if ($baselineFiles.Count -eq 0) {
    Write-Output "ERROR: no *.screens.json baselines matched the requested scope."
    exit 2
}

# Per-run scratch for the generated probe copies (unique name = parallel-safe;
# -WorkTemp is only the base under which the run dir is minted).
if ([string]::IsNullOrWhiteSpace($WorkTemp)) { $WorkTemp = $env:TEMP }
$scratch = Join-Path $WorkTemp ('run_screencheck_' + (Get-Date -Format 'yyyyMMddHHmmss') + '_' + $PID)
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

$probeTemplate = [System.IO.File]::ReadAllText($ProbeVbs, [System.Text.Encoding]::UTF8)
$utf16 = New-Object System.Text.UnicodeEncoding($false, $true)

$captureText = 'off'
if ($Capture) { $captureText = 'on' }
Write-Output ("INFO: baselines=" + $baselineFiles.Count + " capture=" + $captureText + " probe=" + $ProbeVbs)

# ---------------------------------------------------------------------------
# Run every checkpoint of every baseline
# ---------------------------------------------------------------------------
$countPass = 0; $countDrift = 0; $countCnc = 0; $countPending = 0
$cncOnCaptured = 0
$checkpointTotal = 0
$hardErrors = 0
$probeSeq = 0

foreach ($bf in $baselineFiles) {
    $stem = $bf.Name -replace '\.screens\.json$', ''
    $baseline = $null
    try {
        $baseline = Get-Content -LiteralPath $bf.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Output ("ERROR: " + $bf.FullName + " is not valid JSON: " + $_.Exception.Message)
        $hardErrors++
        continue
    }
    $checkpoints = @()
    if ($null -ne $baseline -and $baseline.PSObject.Properties.Name -contains 'checkpoints' -and $null -ne $baseline.checkpoints) { $checkpoints = @($baseline.checkpoints) }
    if ($checkpoints.Count -eq 0) {
        Write-Output ("ERROR: " + $bf.FullName + " has no checkpoints (schema sapdev.screenbaseline/1 requires a non-empty array).")
        $hardErrors++
        continue
    }

    foreach ($cp in $checkpoints) {
        $checkpointTotal++
        $cpId = '' + $cp.id
        $status = '' + $cp.status
        $requiredIds = @()
        if ($cp.PSObject.Properties.Name -contains 'required_ids' -and $null -ne $cp.required_ids) { $requiredIds = @($cp.required_ids) }
        $basePgm = ''; $baseScr = ''
        if ($cp.PSObject.Properties.Name -contains 'identity' -and $null -ne $cp.identity) {
            $basePgm = '' + $cp.identity.program
            $baseScr = '' + $cp.identity.dynpro
        }
        $okcode = ''
        if ($cp.PSObject.Properties.Name -contains 'reach' -and $null -ne $cp.reach) {
            if ($cp.reach.PSObject.Properties.Name -contains 'okcode') { $okcode = ('' + $cp.reach.okcode).Trim() }
        }

        $result = ''; $detail = ''; $severitySeg = ''
        $livePgm = ''; $liveScr = ''
        $missingIds = @()
        $foundCount = 0
        $captureLine = $null

        if ([string]::IsNullOrWhiteSpace($okcode)) {
            # v1 navigates by reach.okcode only; step recipes are not replayed.
            $result = 'COULD_NOT_CHECK'
            $detail = 'no reach.okcode (v1 replays okcode checkpoints only)'
        } else {
            # Generate + run the probe for this checkpoint.
            $probeSeq++
            $runVbs = Join-Path $scratch ('probe_' + $probeSeq + '.vbs')
            $content = $probeTemplate.Replace('%%SESSION_PATH%%', $SessionPath)
            $content = $content.Replace('%%OKCODE%%', $okcode)
            $content = $content.Replace('%%REQUIRED_IDS%%', ($requiredIds -join '|'))
            [System.IO.File]::WriteAllText($runVbs, $content, $utf16)

            $out = @(& $cscript '//NoLogo' $runVbs 2>&1 | ForEach-Object { '' + $_ })
            $probeExit = $LASTEXITCODE
            Remove-Item -LiteralPath $runVbs -Force -ErrorAction SilentlyContinue

            $idState = @{}
            $navStatus = ''
            $probeError = ''
            $identitySeen = $false
            foreach ($line in $out) {
                if ($line -match '^IDENTITY:\s*program=(\S*)\s+dynpro=(\S*)') {
                    $livePgm = $Matches[1]; $liveScr = $Matches[2]; $identitySeen = $true
                } elseif ($line -match '^ID:\s*(.*?)\s*\|\s*(FOUND|MISSING)\s*$') {
                    $idState[$Matches[1]] = $Matches[2]
                } elseif ($line -match '^NAVSTATUS:\s*(\S+)') {
                    $navStatus = $Matches[1]
                } elseif ($line -match '^(ERROR|REFUSED):') {
                    if ($probeError -eq '') { $probeError = $line }
                }
            }

            if ($probeExit -eq 2) {
                $result = 'COULD_NOT_CHECK'
                $detail = 'UNREACHABLE: SAP not reachable (probe exit 2)'
                if ($probeError -ne '') { $detail = $detail + ' -- ' + $probeError }
            } elseif ($probeExit -eq 3) {
                $result = 'COULD_NOT_CHECK'
                $detail = 'BLOCKED: session busy or ambiguous (probe exit 3)'
                if ($probeError -ne '') { $detail = $detail + ' -- ' + $probeError }
            } elseif ($probeExit -ne 0) {
                $result = 'COULD_NOT_CHECK'
                $detail = 'probe exited ' + $probeExit
                if ($probeError -ne '') { $detail = $detail + ' -- ' + $probeError }
            } elseif (-not $identitySeen) {
                $result = 'COULD_NOT_CHECK'
                $detail = 'probe output had no IDENTITY line'
            } else {
                foreach ($rid in $requiredIds) {
                    $state = $idState['' + $rid]
                    if ($state -eq 'FOUND') { $foundCount++ } else { $missingIds += ('' + $rid) }
                }
                $navBad = ($navStatus -eq 'E' -or $navStatus -eq 'A')

                if ($status -eq 'captured') {
                    $identityOk = ((NormProgram $livePgm) -eq (NormProgram $basePgm)) -and ((Pad4 $liveScr) -eq (Pad4 $baseScr))
                    if (-not $identityOk -or $missingIds.Count -gt 0) {
                        $result = 'DRIFT'
                        $severitySeg = ' | BASELINE: ' + $basePgm + '/' + $baseScr + ' | SEVERITY: BLOCKER'
                        $parts = @()
                        if (-not $identityOk) { $parts += 'screen identity moved' }
                        if ($missingIds.Count -gt 0) { $parts += ('' + $missingIds.Count + ' required id(s) missing') }
                        $detail = ($parts -join '; ') + ' -- re-record ' + ('' + $baseline.vbs) + ' for this release'
                    } else {
                        $result = 'PASS'
                        $detail = 'identity + all required ids verified'
                    }
                } elseif ($status -eq 'pending_live') {
                    $result = 'PENDING'
                    if ($navBad) {
                        $detail = 'navigation rejected (sbar ' + $navStatus + '); identity not trustworthy -- no capture'
                    } elseif ($missingIds.Count -gt 0) {
                        $detail = '' + $missingIds.Count + ' required id(s) missing on the live screen -- capture suppressed (fix the id set or re-record first)'
                    } elseif ($Capture) {
                        $captureLine = 'CAPTURE: ' + $bf.FullName + ' | ' + $cpId + ' | program=' + $livePgm + ' | dynpro=' + (Pad4 $liveScr)
                        $detail = 'live identity captured -- apply the CAPTURE line to promote this checkpoint'
                    } else {
                        $detail = 'pending_live -- rerun with -Capture (--update-baseline) to capture the identity'
                    }
                } else {
                    $result = 'COULD_NOT_CHECK'
                    $detail = 'unknown checkpoint status "' + $status + '" (expected captured|pending_live)'
                }
            }
        }

        switch ($result) {
            'PASS'  { $countPass++ }
            'DRIFT' { $countDrift++ }
            'PENDING' { $countPending++ }
            default {
                $countCnc++
                if ($status -eq 'captured') { $cncOnCaptured++ }
            }
        }

        $idsTotal = $requiredIds.Count
        $identitySeg = '-/-'
        if ($livePgm -ne '' -or $liveScr -ne '') { $identitySeg = $livePgm + '/' + (Pad4 $liveScr) }
        Write-Output ('CHECK: ' + $stem + '/' + $cpId + ' | RESULT: ' + $result + ' | IDS: ' + $foundCount + '/' + $idsTotal + ' | IDENTITY: ' + $identitySeg + $severitySeg + ' | DETAIL: ' + $detail)
        foreach ($mid in $missingIds) {
            Write-Output ('  MISSING_ID: ' + $mid)
        }
        if ($null -ne $captureLine) { Write-Output $captureLine }
    }
}

# Best-effort scratch cleanup.
Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Verdict roll-up
# ---------------------------------------------------------------------------
$verdict = 'DEGRADED'
if ($countDrift -gt 0) {
    $verdict = 'DRIFT'
} elseif ($countPass -gt 0 -and $cncOnCaptured -eq 0) {
    # Every captured checkpoint that exists was verified clean.
    $verdict = 'OK'
}

Write-Output ('SCREENCHECK: ' + $verdict + ' baselines=' + $baselineFiles.Count + ' checkpoints=' + $checkpointTotal + ' PASS=' + $countPass + ' DRIFT=' + $countDrift + ' CNC=' + $countCnc + ' PENDING=' + $countPending)

if ($countDrift -gt 0) { exit 1 }
if ($hardErrors -gt 0) { exit 2 }
exit 0
