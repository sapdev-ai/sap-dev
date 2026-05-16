# =============================================================================
# sap_select_vbs_variant.ps1
# -----------------------------------------------------------------------------
# Version-aware VBS variant picker. Given a references/ directory and a base
# name like "sap_se38_update", returns the absolute path of the best-matching
# .vbs variant for the currently pinned SAP connection (Phase 4.2: version
# info comes from connections.json via Get-SapCurrentConnectionProfile, not
# from the now-removed sap_active_session.json pin file).
#
# Filename convention (see plan):
#   sap_<skill>_<action>.vbs                          # default, no tag
#   sap_<skill>_<action>.<server_marker>.vbs          # server-specific
#   sap_<skill>_<action>.<server_marker>_GUI<MN>.vbs  # server + GUI specific
#   sap_<skill>_<action>.GUI<MN>.vbs                  # GUI-only specific
#
# Where <server_marker> is e.g. S4HANA_2022 / ECC6_EHP8 and <MN> is the GUI
# major+minor concatenation (e.g. 77 for 7.7, 80 for 8.0).
#
# Scoring (highest wins, then lexicographic on filename):
#   exact (server, gui)              → 100
#   server-only match                → 50
#   kernel-fallback OR-alternative   → 25  (when pin marker is e.g.
#                                           "S4HANA_1909_OR_NW754" and the
#                                           VBS is tagged with either
#                                           constituent, e.g. "S4HANA_1909")
#   gui-only match                   → 10
#   default (no tag)                 → 1
#
# The OR-alternative branch lets variant authors tag files with the canonical
# release marker (S4HANA_1909) and still have them picked when the user's
# CVERS reads failed and the resolver fell back to the ambiguous compound
# marker S4HANA_1909_OR_NW754. Score 25 < exact 50, so a precise-pinned user
# always still wins over a fallback-pinned user looking at the same skill.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sap_select_vbs_variant.ps1 `
#       -ReferencesDir <abs-path>  `
#       -BaseName      <"sap_<skill>_<action>"> `
#       [-WorkTemp     <abs-path>]                 # default: $env:WORK_TEMP or C:\sap_dev_work\temp
#       [-RequirePin]                              # fail if no active-session pin
#
# Output: a single line on stdout, the absolute path of the selected file.
# Exit: 0 success, 1 default-missing (no .vbs at all), 2 require-pin failure.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ReferencesDir,
    [Parameter(Mandatory = $true)] [string] $BaseName,
    [string] $WorkTemp = '',
    [switch] $RequirePin
)

if (-not $WorkTemp) {
    if ($env:WORK_TEMP) { $WorkTemp = $env:WORK_TEMP }
    else                { $WorkTemp = 'C:\sap_dev_work\temp' }
}

# ------------------------------------------------------------------------------
# 1. Resolve version info from the active connection profile (optional)
# ------------------------------------------------------------------------------
$serverMarker = $null
$guiTag       = $null
# Normalise the raw oApp.MajorVersion / MinorVersion into a stable filename
# tag. Different SAP GUI builds report the same release differently:
#   - Legacy:  MajorVersion=7,    MinorVersion=70   (SAP GUI 7.70)
#   - Encoded: MajorVersion=7700, MinorVersion=257  (also SAP GUI 7.70 build 257)
# Both produce the same canonical tag "GUI77".
function Get-GuiTag {
    param($major, $minor)
    if ($null -eq $major) { return $null }
    $maj = [int]$major
    $min = if ($null -ne $minor) { [int]$minor } else { 0 }
    if ($maj -ge 1000) {
        # Encoded form: floor(major / 100) gives the human major number,
        # which already encodes the .NN (e.g. 7700 -> 77 -> human 7.70).
        return "GUI{0}" -f [math]::Floor($maj / 100)
    }
    if ($maj -ge 7) {
        # Legacy form: drop a trailing zero from the minor if applicable
        # (70 -> 7, 50 -> 5, 75 -> 75).
        $minDigit = if ($min -ge 10 -and ($min % 10) -eq 0) { [math]::Floor($min / 10) } else { $min }
        return "GUI{0}{1}" -f $maj, $minDigit
    }
    return "GUI{0}{1}" -f $maj, $min
}

# Phase 4.2: version info now lives in the connection profile (connections.json)
# keyed by the AI session's pinned connection_id. Look it up via the lib helper.
$libPath = Join-Path (Split-Path -Parent $PSCommandPath) 'sap_connection_lib.ps1'
if (Test-Path $libPath) { . $libPath }

$profile = $null
if (Get-Command Get-SapCurrentConnectionProfile -ErrorAction SilentlyContinue) {
    try { $profile = Get-SapCurrentConnectionProfile -WorkTemp $WorkTemp } catch {}
}

if ($profile) {
    $serverMarker = "$($profile.server_release_marker)".Trim()
    if (-not $serverMarker -or $serverMarker -eq 'UNKNOWN_NO_RFC') { $serverMarker = $null }
    $guiTag = Get-GuiTag -major $profile.gui_major -minor $profile.gui_minor
} elseif ($RequirePin) {
    Write-Error "no current SAP connection profile; run /sap-login first"
    exit 2
}

# ------------------------------------------------------------------------------
# 2. Enumerate candidate files matching the BaseName.
# ------------------------------------------------------------------------------
if (-not (Test-Path $ReferencesDir)) {
    Write-Error "references dir not found: $ReferencesDir"
    exit 1
}

$pattern = "$BaseName*.vbs"
$candidates = Get-ChildItem -Path $ReferencesDir -Filter $pattern -File | Sort-Object Name

if (-not $candidates -or $candidates.Count -eq 0) {
    Write-Error "no .vbs files matching $pattern in $ReferencesDir"
    exit 1
}

# ------------------------------------------------------------------------------
# 3. Score each candidate
# ------------------------------------------------------------------------------
function Get-Score {
    param([string] $filename, [string] $base, [string] $server, [string] $gui)
    # Strip prefix and .vbs suffix. What's left is either empty (default) or a
    # tag prefixed by ".".
    $stripped = $filename.Substring($base.Length)
    if (-not $stripped.ToLowerInvariant().EndsWith('.vbs')) { return -1 }
    $stripped = $stripped.Substring(0, $stripped.Length - 4)
    if ($stripped -eq '') { return 1 }   # default
    if ($stripped[0] -ne '.') { return -1 }
    $tag = $stripped.Substring(1)
    if (-not $tag) { return 1 }

    # Possible tags:
    #   <marker>
    #   <marker>_GUI<MN>
    #   GUI<MN>
    $hasServer = $false
    $hasGui    = $false
    $serverPart = $null
    $guiPart    = $null

    if ($tag -match '^(GUI\d+)$') {
        $hasGui = $true
        $guiPart = $matches[1]
    } elseif ($tag -match '^(.+?)_(GUI\d+)$') {
        $hasServer = $true
        $hasGui = $true
        $serverPart = $matches[1]
        $guiPart    = $matches[2]
    } else {
        $hasServer = $true
        $serverPart = $tag
    }

    # Build the set of acceptable server markers for the active pin. When
    # the pin holds a kernel-fallback compound marker like S4HANA_1909_OR_NW754
    # we accept the compound itself AND each underlying alternative
    # (S4HANA_1909, NW754) at a reduced score. A precise pin like
    # "S4HANA_1909" alone is not split — it has only one acceptable form.
    $serverAlternatives = @($server)
    if ($server -and $server -match '_OR_') {
        $serverAlternatives += ($server -split '_OR_') | Where-Object { $_ }
    }
    $serverIsExactMatch    = ($serverPart -eq $server)
    $serverIsAlternative   = (-not $serverIsExactMatch) -and ($serverAlternatives -contains $serverPart)

    # Score
    if ($hasServer -and $hasGui) {
        if ($serverIsExactMatch  -and $guiPart -eq $gui) { return 100 }
        if ($serverIsAlternative -and $guiPart -eq $gui) { return 75 }
        return -1
    }
    if ($hasServer) {
        if ($serverIsExactMatch)  { return 50 }
        if ($serverIsAlternative) { return 25 }
        return -1
    }
    if ($hasGui) {
        if ($guiPart -eq $gui) { return 10 }
        return -1
    }
    return 1
}

$best = $null
$bestScore = -1
foreach ($f in $candidates) {
    $score = Get-Score -filename $f.Name -base $BaseName -server $serverMarker -gui $guiTag
    if ($score -gt $bestScore) {
        $best = $f
        $bestScore = $score
    } elseif ($score -eq $bestScore -and $best -ne $null) {
        # Lexicographic tiebreak preserved by Sort-Object Name above.
        # No-op: keep $best.
    }
}

if (-not $best -or $bestScore -lt 0) {
    # The candidates exist but none scored positively. This means the scaffold
    # was produced on a different release than the current pin and no untagged
    # default was authored. Rename one of the tagged files to '<base>.vbs' to
    # make it the fallback for non-matching pins, or add a tagged variant for
    # the current pin.
    $candidateNames = ($candidates | ForEach-Object { $_.Name }) -join ', '
    $msg = "no VBS variant matches the current pin (server_marker='$serverMarker' gui='$guiTag'). " +
           "Available variants: $candidateNames. " +
           "Rename one to the untagged default (sap_<skill>_<action>.vbs) to make it the fallback."
    Write-Error $msg
    exit 1
}

Write-Output $best.FullName
exit 0
