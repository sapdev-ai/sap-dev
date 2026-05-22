# =============================================================================
# sap_gui_security_precheck.ps1
# -----------------------------------------------------------------------------
# Read-only check of the SAP GUI Security rule store (saprules.xml) to decide
# whether a given local file path + access + context is ALREADY allow-listed.
#
# Why: SAP GUI raises a modal "SAP GUI Security" dialog whenever SAP GUI itself
# does local-file IO (download/upload/export/Hardcopy) on a path NOT covered by
# an Allow rule, when the Security Module's Default Action is "Ask". While that
# modal is up, the SAP GUI Scripting API is fully suspended, so a cscript-driven
# skill goes blind and hangs. Skills that do SAP-GUI file IO should:
#   1. precheck (this script) — if ALLOWED, no dialog will fire; proceed.
#   2. if NOT_COVERED, launch sap_gui_security_sidecar.ps1 as a background
#      watcher BEFORE the file-IO action, so the dialog is auto-dismissed
#      (ticking "Remember My Decision" persists a rule, so the NEXT precheck
#      for the same path/context returns ALLOWED).
# See shared/rules/sap_gui_security_handling.md for the canonical pattern.
#
# Rule store: %APPDATA%\SAP\Common\saprules.xml (per Windows user). Rules are
# context-specific: a <rule> has <files><name> (exact) and/or <directories>
# <name> (prefix) paths, a rule-level <permissions> (r/w/x chars), and one or
# more <contexts><context> each carrying <system>/<client>/<transaction>/
# <action>. Observed "Remember + Allow" rules carry context <action>0</action>
# (treated here as Allow). An empty context field matches any value.
#
# Usage:
#   powershell -File sap_gui_security_precheck.ps1 `
#       -Path "C:\sap_dev_work\temp\foo.txt" -Access w `
#       [-System S4D] [-Client 100] [-Transaction SE16N] [-RulesFile <path>]
#
# Stdout last line / exit code:
#   ALLOWED: <why>          exit 0   -> a matching Allow rule covers it
#   NOT_COVERED: <reason>   exit 1   -> no covering rule (dialog likely)
#   ERROR: <message>        exit 2   -> rules file unreadable
#
# NOTE: a NOT_COVERED result is advisory, not a guarantee a dialog WILL appear;
# and ALLOWED is best-effort (the action-code semantics are inferred). Treat the
# background watcher as the actual safety net — see the rule doc.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Path,
    [ValidateSet('r','w','x')] [string] $Access = 'w',
    [string] $System = '',
    [string] $Client = '',
    [string] $Transaction = '',
    [string] $RulesFile = ''
)

if (-not $RulesFile) { $RulesFile = Join-Path $env:APPDATA 'SAP\Common\saprules.xml' }
if (-not (Test-Path -LiteralPath $RulesFile)) {
    Write-Output "NOT_COVERED: no saprules.xml at $RulesFile (Default Action governs; dialog likely if Ask)"
    exit 1
}

# Normalise the query path to forward slashes (saprules.xml stores C:/...).
$np = ($Path -replace '\\','/')

try {
    [xml]$xml = Get-Content -LiteralPath $RulesFile -Raw -Encoding UTF8
} catch {
    Write-Output "ERROR: could not parse $RulesFile : $($_.Exception.Message)"
    exit 2
}

$rules = @()
if ($xml.SAP -and $xml.SAP.rules) { $rules = @($xml.SAP.rules.rule) }

foreach ($rule in $rules) {
    if (-not $rule) { continue }

    # --- path match: exact for <files>, prefix for <directories> ---
    $matchPath = $false
    if ($rule.files -and $rule.files.name) {
        foreach ($n in @($rule.files.name)) {
            if ($n -and ($np -ieq ("$n" -replace '\\','/'))) { $matchPath = $true; break }
        }
    }
    if (-not $matchPath -and $rule.directories -and $rule.directories.name) {
        foreach ($d in @($rule.directories.name)) {
            $dd = ("$d" -replace '\\','/')
            if ($dd -and -not $dd.EndsWith('/')) { $dd += '/' }
            if ($dd -and $np.StartsWith($dd, [System.StringComparison]::OrdinalIgnoreCase)) { $matchPath = $true; break }
        }
    }
    if (-not $matchPath) { continue }

    # --- permission must cover the requested access (r/w/x) ---
    $perm = "$($rule.permissions)"
    if ($perm -and ($perm.IndexOf($Access, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }

    # --- at least one context must match AND be an Allow (action 0) ---
    foreach ($c in @($rule.contexts.context)) {
        if (-not $c) { continue }
        $cs = "$($c.system)"; $cc = "$($c.client)"; $ct = "$($c.transaction)"; $ca = "$($c.action)"
        if ($cs -and $System      -and ($cs -ne $System))      { continue }
        if ($cc -and $Client      -and ($cc -ne $Client))      { continue }
        if ($ct -and $Transaction -and ($ct -ne $Transaction)) { continue }
        if ($ca -eq '0') {
            Write-Output "ALLOWED: rule id=$($rule.id) covers $Access on $np (system='$cs' client='$cc' txn='$ct')"
            exit 0
        }
    }
}

Write-Output "NOT_COVERED: no Allow rule for $Access on '$np' (system='$System' client='$Client' txn='$Transaction') — run the security watcher before the file IO"
exit 1
