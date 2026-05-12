# =============================================================================
# sap_gui_probe_classify_action.ps1
# -----------------------------------------------------------------------------
# Classify a probe action as READ (safe to auto-run) or WRITE (mutates SAP
# state; in mode=confirm the orchestrator must pause and ask the user).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sap_gui_probe_classify_action.ps1 `
#       -ActionPath <path-to-action.json>
#
# Output: a single line on stdout, either "READ" or "WRITE".
#         On parse error: "READ" with a warning to stderr (fail-safe -- a
#         malformed action will still be flagged WRITE by the verb default if
#         it carries one of the write VKey codes).
#
# Rules (deliberately conservative -- when in doubt, classify as WRITE):
#   * SEND_VKEY with vkey in 11 (Ctrl+S Save) / 14 (Shift+F2 Delete) /
#     27 (Ctrl+F3 Activate) / 28 (Ctrl+F4) / 33 (Ctrl+Shift+F5) -> WRITE
#   * PRESS on target whose 'note' contains (case-insensitive) any of:
#     Save, Activate, Delete, Create, Release, Transport, Confirm
#     -> WRITE.  (We classify by note rather than by tooltip because the
#     probe action JSON doesn't carry a tooltip; the orchestrator writes
#     a descriptive note for every action.)
#   * SET_OKCD with value matching ^/?n?(?!\s*$) (i.e. any okcd that isn't a
#     plain back-navigation "/n") is NOT a write by itself; but if value
#     starts with =SAVE / =BU / =ACTIVATE the verb is WRITE.
#   * Everything else (SET_TEXT, navigation VKeys, DOUBLE_CLICK, SELECT_ROW,
#     PRESS without write-keyword in note) -> READ.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ActionPath
)

if (-not (Test-Path $ActionPath)) {
    Write-Error "action.json not found: $ActionPath"
    Write-Output "READ"
    exit 1
}

try {
    $action = Get-Content -Path $ActionPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Warning "could not parse action.json as JSON: $($_.Exception.Message)"
    Write-Output "READ"
    exit 0
}

$verb = ($action.verb | ForEach-Object { "$_".ToUpperInvariant() })
$note = "$($action.note)"

$writeVkeys = @(11, 14, 27, 28, 33)
$writeKeywords = @('Save', 'Activate', 'Delete', 'Create', 'Release', 'Transport', 'Confirm')
$writeOkcdPrefixes = @('=SAVE', '=BU', '=ACTIVATE', '=DELE', '=LOEK')

switch ($verb) {
    'SEND_VKEY' {
        if ($writeVkeys -contains [int]$action.vkey) {
            Write-Output 'WRITE'
            exit 0
        }
    }
    'PRESS' {
        foreach ($kw in $writeKeywords) {
            if ($note -match "(?i)\b$kw\b") {
                Write-Output 'WRITE'
                exit 0
            }
        }
    }
    'SET_OKCD' {
        $val = "$($action.value)".ToUpperInvariant()
        foreach ($pfx in $writeOkcdPrefixes) {
            if ($val.StartsWith($pfx)) {
                Write-Output 'WRITE'
                exit 0
            }
        }
    }
}

Write-Output 'READ'
exit 0
