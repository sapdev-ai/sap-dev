# =============================================================================
# sap_gui_diagnose_compose.ps1
#
# Reads the manifest produced by sap_gui_diagnose_capture.vbs and writes
# a single composite PNG that mimics what the operator sees on screen:
#
#   - wnd[0] (main) is painted at its ScreenLeft/Top
#   - wnd[1..N] (modal popups) are painted on top, at their ScreenLeft/Top
#     relative to the same origin
#
# Also produces a "topmost" PNG of the highest-numbered captured window,
# which is usually the popup the operator is stuck on. The orchestrator
# can choose to send only the topmost PNG when costs matter.
#
# Tokens (replaced by the calling skill):
#   %%MANIFEST%%      Absolute path to the TSV manifest from the VBS step.
#   %%COMPOSITE_PNG%% Output composite PNG path.
#   %%TOPMOST_PNG%%   Output topmost-window PNG path.
#
# Output (last line, parseable):
#   DONE: composite=<path>  topmost=<path>
#   ERROR: <text>
# =============================================================================
$ErrorActionPreference = 'Stop'

$manifest = '%%MANIFEST%%'
$compositePng = '%%COMPOSITE_PNG%%'
$topmostPng   = '%%TOPMOST_PNG%%'

if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host "ERROR: Manifest not found: $manifest"
    exit 1
}

Add-Type -AssemblyName System.Drawing

# Read manifest (UTF-16 LE w/BOM written by the VBS).
$bytes = [System.IO.File]::ReadAllBytes($manifest)
$text  = [System.Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF)
$lines = [System.Text.RegularExpressions.Regex]::Split($text, "\r\n|\r|\n") | Where-Object { $_ -ne '' }
if ($lines.Count -lt 2) {
    Write-Host "ERROR: Manifest has no data rows."
    exit 1
}

$header = $lines[0].Split("`t")
$rows = @()
for ($i = 1; $i -lt $lines.Count; $i++) {
    $cols = $lines[$i].Split("`t")
    if ($cols.Count -lt 7) { continue }
    $row = [pscustomobject]@{
        Wnd    = [int]$cols[0]
        Path   = $cols[1]
        Title  = $cols[2]
        Left   = [int]$cols[3]
        Top    = [int]$cols[4]
        Width  = [int]$cols[5]
        Height = [int]$cols[6]
    }
    $rows += $row
}

# Filter to rows whose BMP actually exists.
$valid = $rows | Where-Object { $_.Path -ne '' -and (Test-Path -LiteralPath $_.Path) }
if ($valid.Count -eq 0) {
    Write-Host "ERROR: No usable BMPs referenced in manifest."
    exit 1
}

# --- Topmost: the highest-numbered captured window ---------------------------
$top = $valid | Sort-Object -Property Wnd -Descending | Select-Object -First 1
try {
    $img = [System.Drawing.Image]::FromFile($top.Path)
    try {
        $img.Save($topmostPng, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $img.Dispose()
    }
    Write-Host "INFO: Topmost = wnd[$($top.Wnd)] '$($top.Title)' -> $topmostPng"
} catch {
    Write-Host "WARN: Could not write topmost PNG: $($_.Exception.Message)"
}

# --- Composite: paint wnd[0] (or the lowest-numbered) first, then stack ------
$ordered = @($valid | Sort-Object -Property Wnd)
$base = $ordered[0]

# Compute bounding rectangle in the same coordinate system the windows report.
# If ScreenLeft/Top is -1 (unreadable), fall back to (0,0) and assume each
# window starts at the canvas origin — produces a usable but stacked image.
$minLeft = ($ordered | Measure-Object -Property Left -Minimum).Minimum
$minTop  = ($ordered | Measure-Object -Property Top  -Minimum).Minimum
if ($minLeft -lt 0) { $minLeft = 0 }
if ($minTop  -lt 0) { $minTop  = 0 }

$maxRight  = 0
$maxBottom = 0
foreach ($r in $ordered) {
    # Image dimensions trump the reported Width/Height (which may be in dialog units).
    $img = [System.Drawing.Image]::FromFile($r.Path)
    try {
        $left = if ($r.Left -ge 0) { $r.Left } else { 0 }
        $top  = if ($r.Top  -ge 0) { $r.Top  } else { 0 }
        $right  = $left + $img.Width
        $bottom = $top  + $img.Height
        if ($right  -gt $maxRight)  { $maxRight  = $right  }
        if ($bottom -gt $maxBottom) { $maxBottom = $bottom }
    } finally {
        $img.Dispose()
    }
}

$canvasW = [Math]::Max($maxRight  - $minLeft, 100)
$canvasH = [Math]::Max($maxBottom - $minTop,  100)

$bmp = New-Object System.Drawing.Bitmap($canvasW, $canvasH)
try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::FromArgb(40, 40, 40))   # dark grey backdrop
        foreach ($r in $ordered) {
            $img = [System.Drawing.Image]::FromFile($r.Path)
            try {
                $left = if ($r.Left -ge 0) { $r.Left - $minLeft } else { 0 }
                $top  = if ($r.Top  -ge 0) { $r.Top  - $minTop  } else { 0 }
                $g.DrawImage($img, $left, $top)
                # Annotate each window with a small label for the AI reader.
                $font  = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
                $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Yellow)
                $bg    = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 0, 0, 0))
                $label = "wnd[$($r.Wnd)]: $($r.Title)"
                $size  = $g.MeasureString($label, $font)
                $g.FillRectangle($bg, $left, $top, $size.Width + 8, $size.Height + 4)
                $g.DrawString($label, $font, $brush, $left + 4, $top + 2)
                $font.Dispose(); $brush.Dispose(); $bg.Dispose()
            } finally {
                $img.Dispose()
            }
        }
    } finally {
        $g.Dispose()
    }
    $bmp.Save($compositePng, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $bmp.Dispose()
}

Write-Host "INFO: Composite ($($ordered.Count) windows, $($canvasW)x$($canvasH)) -> $compositePng"
Write-Host "DONE: composite=$compositePng  topmost=$topmostPng"
