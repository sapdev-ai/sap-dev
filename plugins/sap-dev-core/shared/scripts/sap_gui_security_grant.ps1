# =============================================================================
# sap_gui_security_grant.ps1
# -----------------------------------------------------------------------------
# Idempotently merge a well-formed "Allow" rule into the SAP GUI Security rule
# store (saprules.xml) so SAP GUI itself stops prompting for a given local
# path + access, for ANY context (system/client/transaction/dynpro).
#
# Why this exists (and why driving the dialog is NOT enough)
# ---------------------------------------------------------
# SAP's "Remember My Decision" persists a rule keyed on the CURRENT context:
# system + client + transaction + dynpro_name + dynpro_num. For a report run
# via SE38/SA38 that calls GUI_UPLOAD/GUI_DOWNLOAD, dynpro_name is the PROGRAM
# NAME (e.g. ZMMRMAT040R01) and dynpro_num is its screen (1000). So every newly
# generated program produces a brand-new context and trips a fresh dialog — a
# narrow Remember rule can never pre-cover the NEXT program. Worse, the Hardcopy
# warmup only ever does a WRITE, so it only persists 'w' rules; a GUI_UPLOAD is
# a READ ('r') and stays uncovered.
#
# The only thing that scales is a BROAD rule: a <directories> (prefix) rule with
# EMPTY context fields (empty = "any", exactly like the always-empty <network>
# field SAP writes) and combined permissions (e.g. 'rw'). The dialog mechanism
# cannot produce such a rule — it must be written directly. This script writes
# it in SAP's native serialization (forward-slash paths, rule-level + context-
# level <permissions> and <action>, action 0 = Allow), mirroring the structure
# of the working rules SAP itself emits.
#
# Safety
# ------
#   * MINIMAL textual insert before the final </rules> — the rest of the file is
#     preserved byte-for-byte (no [xml] reformat that could change SAP's exact
#     serialization).
#   * Writes UTF-8 WITHOUT BOM (SAP writes it BOM-less; a BOM can break parsing).
#   * Idempotent: a matching broad rule already present -> ALREADY (no-op).
#   * The CALLER is responsible for backing up saprules.xml first.
#
# Reload caveat: a running SAP Logon may cache the rule store from startup. After
# an external edit, the new rule is guaranteed to apply to SAP Logon processes
# started AFTER the edit; currently-running processes may need a restart (or a
# Security-config reload) to pick it up. Verify with a live file-IO before
# declaring victory.
#
# Usage:
#   powershell -File sap_gui_security_grant.ps1 `
#       -Path "C:\sap_dev_work\" -Access rw [-AsDirectory] `
#       [-System ''] [-Client ''] [-Transaction ''] [-DynproName ''] [-DynproNum ''] `
#       [-RulesFile <path>]
#
# Stdout last line / exit code:
#   GRANTED: id=<n> <dir|file>=<path> perms=<access>   exit 0  -> rule added
#   ALREADY: id=<n> ...                                exit 0  -> equivalent rule present
#   ERROR: <message>                                   exit 2  -> store unreadable/unwritable
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Path,
    [ValidatePattern('^[rwx]+$')] [string] $Access = 'rw',
    [switch] $AsDirectory,
    [string] $System = '',
    [string] $Client = '',
    [string] $Transaction = '',
    [string] $DynproName = '',
    [string] $DynproNum = '',
    [string] $RulesFile = ''
)

if (-not $RulesFile) { $RulesFile = Join-Path $env:APPDATA 'SAP\Common\saprules.xml' }

# --- Decide directory vs file -------------------------------------------------
# Directory if: -AsDirectory, OR the path ends with a separator, OR it resolves
# to an existing container on disk.
$isDir = [bool]$AsDirectory
if (-not $isDir) {
    if ($Path -match '[\\/]\s*$') { $isDir = $true }
    elseif (Test-Path -LiteralPath $Path -PathType Container) { $isDir = $true }
}

# Normalise to forward slashes (saprules.xml stores C:/...). Directories carry a
# trailing slash (SAP stores them that way; the precheck prefix-matches on it).
$np = ($Path -replace '\\','/')
if ($isDir -and -not $np.EndsWith('/')) { $np += '/' }

# Permissions string, de-duplicated and lower-cased, kept in r,w,x order.
$permChars = @()
foreach ($c in @('r','w','x')) { if ($Access.ToLower().Contains($c)) { $permChars += $c } }
$perms = -join $permChars
if (-not $perms) { Write-Output "ERROR: empty permission set"; exit 2 }

# --- Read the store (create a skeleton if missing) ----------------------------
if (Test-Path -LiteralPath $RulesFile) {
    try { $raw = [System.IO.File]::ReadAllText($RulesFile) }
    catch { Write-Output "ERROR: could not read $RulesFile : $($_.Exception.Message)"; exit 2 }
} else {
    # Minimal valid skeleton in SAP's shape; timestamp is cosmetic.
    $raw = '<?xml version="1.0" encoding="UTF-8"?><SAP><type>SAP object rules</type><version>1.1</version><rules></rules></SAP>'
}

if ($raw -notmatch '</rules>\s*</SAP>') {
    Write-Output "ERROR: $RulesFile has no </rules></SAP> tail; refusing to edit a non-standard store"
    exit 2
}

# --- Idempotency: is an equivalent broad Allow rule already present? ----------
# We treat a rule as equivalent if the SAME container/file element with the SAME
# rule-level permissions already exists. (The broad rules this script writes are
# self-identifying because the perms string is combined, e.g. 'rw', which SAP's
# single-op Remember never emits.)
$elem = if ($isDir) { 'directories' } else { 'files' }
$marker = "<$elem><name>$np</name></$elem><permissions>$perms</permissions>"
if ($raw.Contains($marker)) {
    $existingId = '?'
    $m = [regex]::Match($raw, 'id="(\d+)"[^>]*>(?:(?!</rule>).)*?' + [regex]::Escape($marker), 'Singleline')
    if ($m.Success) { $existingId = $m.Groups[1].Value }
    Write-Output "ALREADY: id=$existingId $elem=$np perms=$perms"
    exit 0
}

# --- Compute next rule id (max existing + 1) ---------------------------------
$ids = [regex]::Matches($raw, 'id="(\d+)"') | ForEach-Object { [int]$_.Groups[1].Value }
$nextId = if ($ids) { (($ids | Measure-Object -Maximum).Maximum + 1) } else { 1 }

# --- Build the new rule, mirroring SAP's own serialization --------------------
# Rule-level <action>3</action> + context-level <action>0</action> (Allow) is
# the exact shape SAP emits for an allowed rule (see any rule it wrote itself).
# Empty context fields = "any value", consistent with the always-empty <network>.
$newRule =
    "<rule id=`"$nextId`">" +
    "<$elem><name>$np</name></$elem>" +
    "<permissions>$perms</permissions><action>3</action>" +
    "<contexts><context>" +
    "<system>$System</system><network></network><client>$Client</client>" +
    "<transaction>$Transaction</transaction>" +
    "<dynpro_name>$DynproName</dynpro_name><dynpro_num>$DynproNum</dynpro_num>" +
    "<permissions>$perms</permissions><action>0</action>" +
    "</context></contexts></rule>"

# --- Minimal textual insert before the final </rules> ------------------------
# Use a literal .Replace on the unique tail so the rest of the file is untouched.
# Match the actual tail (there may be whitespace between </rules> and </SAP>).
$tailMatch = [regex]::Match($raw, '</rules>\s*</SAP>')
$tail = $tailMatch.Value
$updated = $raw.Replace($tail, $newRule + $tail)

if ($updated -eq $raw) {
    Write-Output "ERROR: insertion failed (tail not replaced)"
    exit 2
}

try {
    [System.IO.File]::WriteAllText($RulesFile, $updated, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Output "ERROR: could not write $RulesFile : $($_.Exception.Message)"
    exit 2
}

# --- Post-write sanity: file must still be well-formed XML --------------------
try {
    [void][xml]([System.IO.File]::ReadAllText($RulesFile))
} catch {
    Write-Output "ERROR: post-write XML is malformed: $($_.Exception.Message)"
    exit 2
}

Write-Output "GRANTED: id=$nextId $elem=$np perms=$perms (context: system='$System' client='$Client' txn='$Transaction' dynpro='$DynproName')"
exit 0
