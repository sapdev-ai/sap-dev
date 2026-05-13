# =============================================================================
# sap_select_vbs_variant.ps1
# -----------------------------------------------------------------------------
# Version-aware VBS variant picker. Given a references/ directory and a base
# name like "sap_se38_update", returns the absolute path of the best-matching
# .vbs variant for the currently pinned SAP session (read from
# {WORK_TEMP}\sap_active_session.json).
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
#   exact (server, gui)      → 100
#   server-only match        → 50
#   gui-only match           → 10
#   default (no tag)         → 1
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
# 1. Discover the active-session pin (optional)
# ------------------------------------------------------------------------------
$pinFile = Join-Path $WorkTemp 'sap_active_session.json'
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

if (Test-Path $pinFile) {
    try {
        $pin = Get-Content -Path $pinFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $serverMarker = "$($pin.server_release_marker)".Trim()
        if (-not $serverMarker -or $serverMarker -eq 'UNKNOWN_NO_RFC') { $serverMarker = $null }
        $guiTag = Get-GuiTag -major $pin.gui_major -minor $pin.gui_minor
    } catch {
        Write-Warning "sap_active_session.json present but unparseable: $($_.Exception.Message)"
    }
} elseif ($RequirePin) {
    Write-Error "no active-session pin at $pinFile; run /sap-login first"
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

    # Score
    if ($hasServer -and $hasGui) {
        if ($serverPart -eq $server -and $guiPart -eq $gui) { return 100 }
        return -1
    }
    if ($hasServer) {
        if ($serverPart -eq $server) { return 50 }
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
