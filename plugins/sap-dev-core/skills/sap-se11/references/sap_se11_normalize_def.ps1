# =============================================================================
# sap_se11_normalize_def.ps1  -  Sanity-check & auto-repair an SE11 .def file
#
# Why this script exists
# ----------------------
# All SE11 update/create VBS templates parse the definition file with
# `Split(sLine, vbTab)`, expecting actual TAB bytes (chr 9) as the column
# separator. When an LLM agent generates the .def content for the Write tool,
# it occasionally emits the two-character escape `\t` (backslash + 't')
# instead of a real TAB. The Write tool passes the bytes through verbatim,
# the VBS sees a single-column line, and the resulting DDIC object is
# silently corrupted (empty data elements, types, lengths) — the GUI status
# bar still reports SUCCESS, but the live table is unusable.
#
# This helper is run between Step 2 (write definition file) and Step 3
# (login + execute). It:
#
#   * Detects zero TAB chars combined with the literal escape sequences
#     `\t`, `\n`, or `\r` — strong signal of LLM-escape-leak corruption.
#   * Auto-repairs by replacing `\t` -> chr(9), `\n` -> chr(10),
#     `\r` -> chr(13) and rewriting the file IN PLACE (UTF-8, no BOM).
#   * Emits a single `WARNING: ...` line per fix so the operator sees
#     exactly what was repaired.
#   * Aborts with `ERROR: ...` if the file has multiple data lines but
#     contains zero TAB bytes AND zero recoverable escape sequences —
#     that means the upstream agent produced content the skill cannot
#     parse, and we refuse to feed it to SAP.
#
# Whitelist for legitimate single-column files (no validation needed):
#   * TYPEGROUP definitions are raw ABAP, not tab-delimited.
#   * Header-only files (1 line) are passed through.
#
# Tokens (replaced by SKILL.md Step 2.5):
#   %%DEFINITION_FILE%%   Absolute path to the .def file
#   %%OBJECT_TYPE%%       Upper-case user-facing type (TABLE/DOMAIN/...)
#
# Stdout contract (last line):
#   OK              -> file is parseable as-is              (exit 0)
#   REPAIRED:<N>    -> N escape sequences auto-fixed         (exit 0)
#   SKIPPED:<reason>-> file does not need TSV validation     (exit 0)
#   ERROR:<msg>     -> unrecoverable corruption              (exit 1)
# =============================================================================

$ErrorActionPreference = "Stop"

$path = "%%DEFINITION_FILE%%"
$type = "%%OBJECT_TYPE%%".ToUpperInvariant()

if (-not (Test-Path -LiteralPath $path)) {
    Write-Output "ERROR: Definition file not found: $path"
    exit 1
}

# TYPEGROUP is raw ABAP, not TSV — skip validation.
if ($type -eq "TYPEGROUP") {
    Write-Output "SKIPPED:typegroup-is-raw-abap"
    exit 0
}

# Read as bytes so we can detect BOM and preserve everything.
$bytes = [System.IO.File]::ReadAllBytes($path)
if ($bytes.Length -eq 0) {
    Write-Output "ERROR: Definition file is empty: $path"
    exit 1
}

# Decode using BOM-aware logic so the same charsets the VBS handles work here.
$text = $null
if     ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes, 3, $bytes.Length - 3) }
else { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }

# Normalise newlines for line counting only.
$linesAll = $text -split "`r`n|`r|`n"

# Trim trailing empty lines but keep blank lines inside (rare but valid in
# multi-section formats like view / search-help).
while ($linesAll.Length -gt 0 -and $linesAll[$linesAll.Length - 1] -eq "") {
    $linesAll = $linesAll[0..($linesAll.Length - 2)]
}
$lineCount = $linesAll.Length

# Single-line files are header-only — pass through, the VBS will fail loudly
# in a way that is easier to debug than a silent half-deploy.
if ($lineCount -le 1) {
    Write-Output "SKIPPED:single-line-file"
    exit 0
}

$tabCount = ([regex]::Matches($text, "`t")).Count
$litTab   = ([regex]::Matches($text, '\\t')).Count
$litLF    = ([regex]::Matches($text, '\\n')).Count
$litCR    = ([regex]::Matches($text, '\\r')).Count

# Common case 1: file already correct.
if ($tabCount -gt 0 -and $litTab -eq 0 -and $litLF -eq 0 -and $litCR -eq 0) {
    Write-Output "OK"
    exit 0
}

# Common case 2: file has zero real TABs but contains literal '\t' escapes —
# textbook LLM-escape-leak corruption. Auto-repair.
if ($tabCount -eq 0 -and $litTab -gt 0) {
    Write-Output "WARNING: Detected $litTab literal '\t' sequences and zero TAB bytes — auto-converting to real TABs."
    $text = $text -replace '\\t', "`t"
    if ($litLF -gt 0) {
        Write-Output "WARNING: Also auto-converting $litLF literal '\n' sequences to LF."
        $text = $text -replace '\\n', "`n"
    }
    if ($litCR -gt 0) {
        Write-Output "WARNING: Also auto-converting $litCR literal '\r' sequences to CR."
        $text = $text -replace '\\r', "`r"
    }

    # Write back as UTF-8 (no BOM) — the VBS EnsureUnicodeFile helper handles it.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)

    $repaired = $litTab + $litLF + $litCR
    Write-Output "REPAIRED:$repaired"
    exit 0
}

# Mixed corruption: the file has SOME real tabs but also literal '\t' / '\n' /
# '\r' escapes. Rare but possible if half the content was hand-typed and half
# came from an LLM. Repair the literal escapes; warn loudly so the operator
# can sanity-check the live result.
if ($litTab -gt 0 -or $litLF -gt 0 -or $litCR -gt 0) {
    Write-Output "WARNING: Mixed content — $tabCount real TABs plus $litTab '\t' / $litLF '\n' / $litCR '\r' literal escapes. Auto-converting literals; review the deployed object."
    if ($litTab -gt 0) { $text = $text -replace '\\t', "`t" }
    if ($litLF  -gt 0) { $text = $text -replace '\\n', "`n" }
    if ($litCR  -gt 0) { $text = $text -replace '\\r', "`r" }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)

    $repaired = $litTab + $litLF + $litCR
    Write-Output "REPAIRED:$repaired"
    exit 0
}

# Unrecoverable: multiple data lines, zero tabs, zero literal escapes. Some
# object types (search-help / view / lock-object) have section headers that
# are legitimately tab-free single-column lines. Allow if the body has tabs
# OR if the user-facing type is one of those multi-section formats.
$multiSection = @("VIEW", "SEARCHHELP", "LOCKOBJECT")
if ($multiSection -contains $type) {
    Write-Output "OK"
    exit 0
}

if ($tabCount -eq 0) {
    Write-Output "ERROR: Definition file has $lineCount lines but contains no TAB bytes and no '\t' literal escapes. The VBS cannot parse this file. Re-write with actual TAB characters between columns."
    exit 1
}

Write-Output "OK"
exit 0
