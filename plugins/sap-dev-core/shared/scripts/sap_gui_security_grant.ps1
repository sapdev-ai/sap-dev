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
# generated program produces a brand-new context and trips a fresh dialog -- a
# narrow Remember rule can never pre-cover the NEXT program. Worse, the Hardcopy
# warmup only ever does a WRITE, so it only persists 'w' rules; a GUI_UPLOAD is
# a READ ('r') and stays uncovered.
#
# The only thing that scales is a BROAD rule: a <directories> (prefix) rule with
# EMPTY context fields (empty = "any", exactly like the always-empty <network>
# field SAP writes) and combined permissions (e.g. 'rw'). The dialog mechanism
# cannot produce such a rule -- it must be written directly. This script writes
# it in SAP's native serialization (forward-slash paths, rule-level + context-
# level <permissions> and <action>, action 0 = Allow), mirroring the structure
# of the working rules SAP itself emits.
#
# Self-heal (idempotency is context-AWARE)
# ----------------------------------------
# An equivalent rule is only one whose <directories>/<files> name is THIS exact
# path AND whose context discriminators are all empty ("any") AND whose rule-
# level permissions already cover the requested access. Such a rule -> ALREADY.
# If same-path rules exist but are MALFORMED (literal '*' contexts, backslash
# paths -- SAP stores forward slashes, so these match nothing yet silently
# satisfied the old path+perms-only idempotency check and shadowed the real
# grant) or NARROW (non-empty context, e.g. a per-program Remember rule), they
# are PURGED and the canonical any-context rule is written in their place ->
# HEALED. This is the fix for the "warmup done, flag set, still prompted"
# failure: a single stale '*' rule used to make this script return ALREADY
# forever without ever writing an effective rule. Only single-name elements for
# THIS exact path (forward- or backslash form) are touched; multi-name rules and
# rules for other paths are left byte-for-byte intact.
#
# Safety
# ------
#   * Only same-exact-path single-name rules are removed; everything else is
#     preserved verbatim (no [xml] reformat that could change serialization).
#   * Writes UTF-8 WITHOUT BOM (SAP writes it BOM-less; a BOM can break parsing).
#   * Idempotent: a matching canonical rule already present -> ALREADY (no-op).
#   * The CALLER is responsible for backing up saprules.xml first.
#
# Reload caveat: a running SAP Logon may cache the rule store from startup. After
# an external edit (GRANTED or HEALED), the new rule is guaranteed to apply to
# SAP Logon processes started AFTER the edit; currently-running processes must be
# restarted (or the Security config reloaded) to pick it up. Verify with a live
# file-IO before declaring victory.
#
# Usage:
#   powershell -File sap_gui_security_grant.ps1 `
#       -Path "C:\sap_dev_work\" -Access rw [-AsDirectory] `
#       [-System ''] [-Client ''] [-Transaction ''] [-DynproName ''] [-DynproNum ''] `
#       [-RulesFile <path>]
#
# Stdout last line / exit code:
#   GRANTED: id=<n> <dir|file>=<path> perms=<access>            exit 0  -> new rule added
#   HEALED:  id=<n> ... removed=<ids>                           exit 0  -> stale/narrow same-path rules purged + canonical written
#   ALREADY: id=<n> ...                                         exit 0  -> equivalent canonical rule present
#   ERROR: <message>                                            exit 2  -> store unreadable/unwritable
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
$npBack = ($np -replace '/','\')   # malformed-but-same-path variant SAP would ignore

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

$elem = if ($isDir) { 'directories' } else { 'files' }

# Single-name element markers for THIS exact path (forward + the dead backslash
# form). A multi-name element (e.g. two <name> children) won't contain either
# marker, so multi-name rules are never touched.
$nameMarkers = @(
    "<$elem><name>$np</name></$elem>",
    "<$elem><name>$npBack</name></$elem>"
)

# Helper: is a context block "any" (all five discriminators empty)?
function Test-CanonicalContext([string]$block) {
    $m = [regex]::Match($block,
        '<contexts><context><system>(.*?)</system><network>.*?</network><client>(.*?)</client><transaction>(.*?)</transaction><dynpro_name>(.*?)</dynpro_name><dynpro_num>(.*?)</dynpro_num>',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { return $false }
    foreach ($g in 1..5) { if ($m.Groups[$g].Value -ne '') { return $false } }
    return $true
}

# Helper: rule-level permissions of a block ('' if absent / malformed).
function Get-RulePerms([string]$block) {
    $m = [regex]::Match($block, "</$elem><permissions>(.*?)</permissions>")
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Helper: does 'have' cover every char of 'need'?
function Test-PermsSuperset([string]$have, [string]$need) {
    foreach ($c in $need.ToCharArray()) { if (-not $have.Contains([string]$c)) { return $false } }
    return $true
}

# --- Scan every rule block for THIS exact path -------------------------------
# Rules never nest, so a non-greedy <rule ...>...</rule> match is exact.
$blockRx = [regex]'(?s)<rule\b[^>]*>.*?</rule>'
$staleBlocks = @()
$staleIds    = @()
$canonicalId = $null
foreach ($bm in $blockRx.Matches($raw)) {
    $block = $bm.Value
    $isSamePath = $false
    foreach ($marker in $nameMarkers) { if ($block.Contains($marker)) { $isSamePath = $true; break } }
    if (-not $isSamePath) { continue }

    $idm = [regex]::Match($block, 'id="(\d+)"')
    $bid = if ($idm.Success) { $idm.Groups[1].Value } else { '?' }

    if ((Test-CanonicalContext $block) -and (Test-PermsSuperset (Get-RulePerms $block) $perms)) {
        if ($null -eq $canonicalId) { $canonicalId = $bid }   # effective rule already present
    } else {
        $staleBlocks += $block                                # malformed / narrow -> purge + replace
        $staleIds    += $bid
    }
}

# Already covered by an effective any-context rule with sufficient permissions?
if ($null -ne $canonicalId) {
    Write-Output "ALREADY: id=$canonicalId $elem=$np perms=$perms"
    exit 0
}

# --- Compute next rule id (max existing + 1, over the original store) ---------
$ids = [regex]::Matches($raw, 'id="(\d+)"') | ForEach-Object { [int]$_.Groups[1].Value }
$nextId = if ($ids) { (($ids | Measure-Object -Maximum).Maximum + 1) } else { 1 }

# --- Build the canonical rule, mirroring SAP's own serialization -------------
# Rule-level <action>3</action> + context-level <action>0</action> (Allow) is
# the exact shape SAP emits for an allowed rule. Empty context fields = "any
# value", consistent with the always-empty <network>.
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

# --- Purge stale same-path blocks (self-heal), then insert the canonical -----
$updated = $raw
foreach ($sb in $staleBlocks) { $updated = $updated.Replace($sb, '') }

$tailMatch = [regex]::Match($updated, '</rules>\s*</SAP>')
if (-not $tailMatch.Success) { Write-Output "ERROR: </rules></SAP> tail vanished after heal; aborting (no write)"; exit 2 }
$tail = $tailMatch.Value
$final = $updated.Replace($tail, $newRule + $tail)

if ($final -eq $updated) {
    Write-Output "ERROR: insertion failed (tail not replaced)"
    exit 2
}

try {
    [System.IO.File]::WriteAllText($RulesFile, $final, (New-Object System.Text.UTF8Encoding($false)))
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

if ($staleIds.Count -gt 0) {
    Write-Output ("HEALED: id=$nextId $elem=$np perms=$perms removed=" + ($staleIds -join ',') + " (context: any system/client/txn/program)")
} else {
    Write-Output "GRANTED: id=$nextId $elem=$np perms=$perms (context: system='$System' client='$Client' txn='$Transaction' dynpro='$DynproName')"
}
exit 0
