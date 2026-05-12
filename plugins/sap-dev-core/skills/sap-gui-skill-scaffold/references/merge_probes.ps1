# =============================================================================
# merge_probes.ps1
# -----------------------------------------------------------------------------
# Cross-probe merge for sap-gui-skill-scaffold. Reads every step_NN_action.json
# in the supplied probe folders, classifies each unique (verb, target) control
# touchpoint as constant / parameter / mode-specific, detects popup transitions
# and emits _merge_report.json.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File merge_probes.ps1 `
#       -ProbeFolders <p1>,<p2>,... `        # one or more probe run folders
#       -ModeNames    <m1>,<m2>,... `        # parallel array of mode labels
#       -OutputFile   <abs-path>             # _merge_report.json target
#
# Mode-names must be 1:1 with -ProbeFolders. The order matters and is preserved
# in the report's "probes" array.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $ProbeFolders,

    [Parameter(Mandatory = $true)]
    [string[]] $ModeNames,

    [Parameter(Mandatory = $true)]
    [string] $OutputFile
)

if ($ProbeFolders.Count -lt 2) {
    Write-Error "need at least 2 probe folders; got $($ProbeFolders.Count) (single-probe scaffolding has no merge step -- use synthesized.vbs directly)"
    exit 2
}
if ($ProbeFolders.Count -ne $ModeNames.Count) {
    Write-Error "ProbeFolders count ($($ProbeFolders.Count)) != ModeNames count ($($ModeNames.Count))"
    exit 2
}

# ------------------------------------------------------------------------------
# Load every probe's actions in order, plus header info from the before-dumps.
# ------------------------------------------------------------------------------
function Get-ProbeHeader {
    param([string] $DumpPath)
    # First ~10 lines of a sap-gui-object-details dump carry Program / Transaction
    # / Screen / Title. We only need them to populate popups_observed.
    if (-not (Test-Path $DumpPath)) { return @{} }
    $lines = Get-Content -Path $DumpPath -Encoding Unicode -TotalCount 14
    $h = @{}
    foreach ($l in $lines) {
        if     ($l -match '^Program:\s+(\S+)')      { $h.program     = $matches[1] }
        elseif ($l -match '^Transaction:\s+(\S+)')  { $h.transaction = $matches[1] }
        elseif ($l -match '^Screen:\s+(\d+)')       { $h.screen      = $matches[1] }
        elseif ($l -match 'Title:\s+\[(.+)\]')      { $h.title       = $matches[1] }
    }
    # Was a popup window present in the dump?
    $hasPopup = (Get-Content -Path $DumpPath -Encoding Unicode |
                 Select-String -Pattern 'POPUP WINDOW wnd\[1\]').Count -gt 0
    $h.popup = $hasPopup
    return $h
}

$probes = @()
for ($i = 0; $i -lt $ProbeFolders.Count; $i++) {
    $folder = $ProbeFolders[$i]
    $mode   = $ModeNames[$i]
    if (-not (Test-Path $folder)) {
        Write-Error "probe folder not found: $folder"
        exit 3
    }
    $actionFiles = Get-ChildItem -Path $folder -Filter 'step_*_action.json' -File |
                   Sort-Object Name
    if (-not $actionFiles -or $actionFiles.Count -eq 0) {
        Write-Error "probe folder has no step_*_action.json files: $folder"
        exit 3
    }
    $actions = @()
    foreach ($f in $actionFiles) {
        try {
            $obj = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Warning "skipping unparsable JSON: $($f.FullName)"
            continue
        }
        $stepNum = $null
        if ($f.Name -match '^step_(\d+)_action\.json$') { $stepNum = [int]$matches[1] }

        $beforeDump = Join-Path $folder ("step_{0:D2}_before.txt" -f $stepNum)
        $afterDump  = Join-Path $folder ("step_{0:D2}_after.txt"  -f $stepNum)

        $actions += [pscustomobject]@{
            step   = $stepNum
            verb   = "$($obj.verb)".ToUpperInvariant()
            target = "$($obj.target)"
            value  = "$($obj.value)"
            vkey   = if ($null -ne $obj.vkey)  { [int]$obj.vkey } else { $null }
            row    = if ($null -ne $obj.row)   { [int]$obj.row  } else { $null }
            note   = "$($obj.note)"
            before = Get-ProbeHeader $beforeDump
            after  = Get-ProbeHeader $afterDump
        }
    }
    $probes += [pscustomobject]@{
        id      = "probe_$($i + 1)"
        folder  = $folder
        mode    = $mode
        actions = $actions
    }
}

# ------------------------------------------------------------------------------
# Build the touchpoint index. Key = "<verb>|<target>" (target may be empty for
# VKey-only navigations on wnd[0]; we keep them keyed by verb+target+vkey so
# Enter and F3 don't collide).
# ------------------------------------------------------------------------------
function Get-TouchpointKey {
    param($a)
    $tgt = if ($a.target) { $a.target } else { '' }
    if ($a.verb -eq 'SEND_VKEY') { return "$($a.verb)|$tgt|$($a.vkey)" }
    return "$($a.verb)|$tgt"
}

$touchpoints = @{}
foreach ($p in $probes) {
    foreach ($a in $p.actions) {
        $k = Get-TouchpointKey $a
        if (-not $touchpoints.ContainsKey($k)) {
            $touchpoints[$k] = [pscustomobject]@{
                verb   = $a.verb
                target = $a.target
                hits   = @()   # one entry per probe usage
            }
        }
        $touchpoints[$k].hits += [pscustomobject]@{
            probe_id = $p.id
            mode     = $p.mode
            step     = $a.step
            value    = $a.value
            vkey     = $a.vkey
            row      = $a.row
            note     = $a.note
        }
    }
}

# ------------------------------------------------------------------------------
# Classify each touchpoint: constant | parameter | mode-specific.
# Derive a parameter token name from the DDIC field tail when possible.
# ------------------------------------------------------------------------------
function Get-TokenFromTarget {
    param([string] $target, [int] $idx)
    # Find the last segment containing a "-" -- that's the DDIC field name in
    # SAP findById paths like wnd[0]/usr/ctxtRMMG1-MATNR.
    if ($target -match '([A-Z][A-Z0-9_/]*-[A-Z][A-Z0-9_]*)$') {
        $field = $matches[1]
        $tail = ($field -split '-')[-1]   # MATNR
        return "%%${tail}%%"
    }
    return "%%PARAM_{0:D2}%%" -f $idx
}

$probeIds = $probes | ForEach-Object { $_.id }
$probeIdSet = New-Object 'System.Collections.Generic.HashSet[string]' (,[string[]]$probeIds)
$paramIdx = 0
$tpReport = @()
foreach ($k in ($touchpoints.Keys | Sort-Object)) {
    $tp = $touchpoints[$k]
    $hitProbeIds = $tp.hits | ForEach-Object { $_.probe_id } | Sort-Object -Unique
    $allHit = ($hitProbeIds.Count -eq $probeIds.Count)

    if ($allHit) {
        # Collect the salient value per hit -- for SEND_VKEY the vkey is already
        # the key, so the only variance is target wnd. For SET_TEXT / SET_OKCD,
        # the value varies. For PRESS, value is empty.
        $verbCapture = $tp.verb
        $valuesSeen = $tp.hits | ForEach-Object {
            $hit = $_
            switch ($verbCapture) {
                'SET_TEXT'     { "$($hit.value)" }
                'SET_OKCD'     { "$($hit.value)" }
                'SELECT_ROW'   { "$($hit.row)"   }
                default        { '' }
            }
        } | Sort-Object -Unique

        $token = $null
        $perProbe = @{}
        if ($valuesSeen.Count -gt 1) {
            $paramIdx++
            $token = Get-TokenFromTarget $tp.target $paramIdx
            foreach ($h in $tp.hits) {
                $v = switch ($tp.verb) {
                    'SET_TEXT'   { "$($h.value)" }
                    'SET_OKCD'   { "$($h.value)" }
                    'SELECT_ROW' { "$($h.row)"   }
                    default      { ''            }
                }
                $perProbe[$h.probe_id] = $v
            }
            $class = 'parameter'
        } else {
            $class = 'constant'
        }

        $tpReport += [pscustomobject]@{
            verb              = $tp.verb
            target            = $tp.target
            class             = $class
            token             = $token
            per_probe_values  = $perProbe
            modes             = ($tp.hits | ForEach-Object { $_.mode } | Sort-Object -Unique)
        }
    } else {
        $tpReport += [pscustomobject]@{
            verb              = $tp.verb
            target            = $tp.target
            class             = 'mode-specific'
            token             = $null
            per_probe_values  = @{}
            modes             = ($tp.hits | ForEach-Object { $_.mode } | Sort-Object -Unique)
            note              = "appears in $($hitProbeIds.Count)/$($probeIds.Count) probes"
        }
    }
}

# ------------------------------------------------------------------------------
# Popup observations. A popup is "observed" at step N of probe P if its
# step_N_after.txt header reports popup=true. We record the probe + step so
# the emit phase can insert popup branches at the matching point in mode VBS.
# ------------------------------------------------------------------------------
$popups = @()
foreach ($p in $probes) {
    foreach ($a in $p.actions) {
        if ($a.after.popup) {
            $popups += [pscustomobject]@{
                probe_id = $p.id
                mode     = $p.mode
                step     = $a.step
                after    = $a.after
            }
        }
    }
}

# ------------------------------------------------------------------------------
# Emit _merge_report.json
# ------------------------------------------------------------------------------
$report = [pscustomobject]@{
    generated_at     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    probe_count      = $probes.Count
    probes           = $probes | ForEach-Object {
        [pscustomobject]@{
            id           = $_.id
            folder       = $_.folder
            mode         = $_.mode
            action_count = $_.actions.Count
            actions      = $_.actions | ForEach-Object {
                [pscustomobject]@{
                    step   = $_.step
                    verb   = $_.verb
                    target = $_.target
                    value  = $_.value
                    vkey   = $_.vkey
                    row    = $_.row
                    note   = $_.note
                }
            }
        }
    }
    touchpoints      = $tpReport
    popups_observed  = $popups
}

$outDir = Split-Path -Parent $OutputFile
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$report | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputFile -Encoding UTF8

$paramCount        = @($tpReport | Where-Object class -eq 'parameter').Count
$modeSpecificCount = @($tpReport | Where-Object class -eq 'mode-specific').Count
$constantCount     = @($tpReport | Where-Object class -eq 'constant').Count
Write-Output "MERGE OK: probes=$($probes.Count) touchpoints=$($tpReport.Count) parameters=$paramCount constants=$constantCount modeSpecific=$modeSpecificCount popups=$($popups.Count)"
Write-Output "REPORT: $OutputFile"
exit 0
