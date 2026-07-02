# =============================================================================
# sap_se19_classify.ps1  -  Classify a SE19 BAdI name as Classic vs New and
#                           Definition vs Implementation, via RFC (NCo 3.1).
#
# Used by the sap-se19 skill to decide which SE19 flow (classic / new) to drive
# and to resolve dependent objects (implementing class, interface, enhancement
# spot, runtime ACTIVE flag, TADIR author/devclass) without driving the GUI.
#
# Tables (RFC_READ_TABLE, all read-only):
#   SXS_ATTR  classic BAdI definition   (EXIT_NAME key; MIG_* => migrated to new)
#   SXC_ATTR  classic BAdI impl attrs   (IMP_NAME key; ACTIVE, UNAME)
#   SXC_CLASS classic BAdI impl class   (IMP_NAME, INTER_NAME, IMP_CLASS)
#   BADI_IMPL new BAdI implementations  (BADI_NAME, ENHNAME, BADI_IMPL, CLASS_NAME)
#   TADIR     object directory          (OBJECT ENHS/ENHO/SXCI/SXSD, AUTHOR, DEVCLASS)
#
# Usage:
#   sap_se19_classify.ps1 -Name <NAME> [-Expect DEFINITION|IMPLEMENTATION|AUTO]
#
#   -Expect DEFINITION      => the name is a BAdI definition / enhancement spot
#                              (op = Create). Classifies the create target.
#   -Expect IMPLEMENTATION   => the name is a BAdI implementation
#                              (op = Display/Update/Delete/Activate/Deactivate).
#   -Expect AUTO (default)   => probe both; report what was found.
#
# Output: parseable KEY=VALUE lines, ending with a single RESULT line:
#   RESULT: TYPE=CLASSIC|NEW|AMBIGUOUS|UNKNOWN KIND=DEFINITION|IMPLEMENTATION|UNKNOWN
#
# Run with 32-bit PowerShell (NCo 3.1 lives in the 32-bit GAC):
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File ... -Name ZX
# =============================================================================

param(
    [Parameter(Mandatory = $true)] [string]$Name,
    [ValidateSet('DEFINITION', 'IMPLEMENTATION', 'AUTO')] [string]$Expect = 'AUTO',
    [string]$RfcLib = ''
)

$ErrorActionPreference = 'Stop'
$Name = $Name.Trim().ToUpperInvariant()

if (-not $RfcLib) {
    $RfcLib = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))) 'shared\scripts\sap_rfc_lib.ps1'
}
if (-not (Test-Path $RfcLib)) {
    Write-Output "ERROR: sap_rfc_lib.ps1 not found at $RfcLib"
    Write-Output "RESULT: TYPE=UNKNOWN KIND=UNKNOWN"
    exit 2
}
. $RfcLib

$dest = Connect-SapRfc -DestName "SE19_CLASSIFY"
if (-not $dest) {
    Write-Output "RESULT: TYPE=UNKNOWN KIND=UNKNOWN"
    exit 2
}

# --- helper: read one table, return array of WA strings (split on |) ----------
function Read-Rows($table, $where, $fields) {
    try {
        $fn = New-RfcReadTable -Destination $dest -Table $table -Delimiter '|'
        if ($where) { Add-RfcOption $fn $where }
        foreach ($f in $fields) { Add-RfcField $fn $f }
        $fn.Invoke($dest)
        $out = @()
        foreach ($r in $fn.GetTable("DATA")) {
            $cols = ($r.GetValue("WA") -split '\|') | ForEach-Object { $_.Trim() }
            $out += , $cols
        }
        return , $out
    } catch {
        Write-Output ("WARN: read $table failed: " + $_.Exception.Message)
        return , @()
    }
}

function Q([string]$v) { return "'" + ($v -replace "'", "''") + "'" }

# --- classic definition (SXS_ATTR) -------------------------------------------
$classicDef = $false; $migrated = $false; $migSpot = ''; $migBadi = ''; $defClass = ''
$rows = Read-Rows "SXS_ATTR" ("EXIT_NAME = " + (Q $Name)) @("EXIT_NAME", "MIG_ENHSPOTNAME", "MIG_BADI_NAME", "DEF_CLNAME", "INTERNAL", "MLTP_USE")
if ($rows.Count -gt 0) {
    $migSpot = $rows[0][1]; $migBadi = $rows[0][2]; $defClass = $rows[0][3]
    if ($migBadi -ne '' -or $migSpot -ne '') { $migrated = $true } else { $classicDef = $true }
}

# --- new definition: enhancement spot (TADIR ENHS) or referenced in BADI_IMPL -
$newSpot = $false; $newDefRef = $false
$rows = Read-Rows "TADIR" ("PGMID = 'R3TR' AND OBJECT = 'ENHS' AND OBJ_NAME = " + (Q $Name)) @("OBJ_NAME")
if ($rows.Count -gt 0) { $newSpot = $true }
$rows = Read-Rows "BADI_IMPL" ("BADI_NAME = " + (Q $Name)) @("BADI_NAME")
if ($rows.Count -gt 0) { $newDefRef = $true }

# --- classic implementation (SXC_CLASS / SXC_ATTR) ---------------------------
$classicImpl = $false; $ci_iface = ''; $ci_class = ''; $ci_active = ''; $ci_uname = ''
$rows = Read-Rows "SXC_CLASS" ("IMP_NAME = " + (Q $Name)) @("IMP_NAME", "INTER_NAME", "IMP_CLASS")
if ($rows.Count -gt 0) { $classicImpl = $true; $ci_iface = $rows[0][1]; $ci_class = $rows[0][2] }
$rows = Read-Rows "SXC_ATTR" ("IMP_NAME = " + (Q $Name)) @("IMP_NAME", "ACTIVE", "UNAME")
if ($rows.Count -gt 0) { $classicImpl = $true; $ci_active = $rows[0][1]; $ci_uname = $rows[0][2] }

# --- new implementation: TADIR ENHO or BADI_IMPL ENHNAME/BADI_IMPL ------------
$newImpl = $false; $ni_badi = ''; $ni_enh = ''; $ni_impl = ''; $ni_class = ''
$rows = Read-Rows "BADI_IMPL" ("ENHNAME = " + (Q $Name)) @("BADI_NAME", "ENHNAME", "BADI_IMPL", "CLASS_NAME")
if ($rows.Count -gt 0) { $newImpl = $true; $ni_badi = $rows[0][0]; $ni_enh = $rows[0][1]; $ni_impl = $rows[0][2]; $ni_class = $rows[0][3] }
if (-not $newImpl) {
    $rows = Read-Rows "BADI_IMPL" ("BADI_IMPL = " + (Q $Name)) @("BADI_NAME", "ENHNAME", "BADI_IMPL", "CLASS_NAME")
    if ($rows.Count -gt 0) { $newImpl = $true; $ni_badi = $rows[0][0]; $ni_enh = $rows[0][1]; $ni_impl = $rows[0][2]; $ni_class = $rows[0][3] }
}
$tadirEnho = $false
$rows = Read-Rows "TADIR" ("PGMID = 'R3TR' AND OBJECT = 'ENHO' AND OBJ_NAME = " + (Q $Name)) @("OBJ_NAME")
if ($rows.Count -gt 0) { $tadirEnho = $true; $newImpl = $true; if ($ni_enh -eq '') { $ni_enh = $Name } }

# --- TADIR author / devclass for the resolved object -------------------------
$tadir_author = ''; $tadir_devclass = ''; $tadir_object = ''
foreach ($obj in @('ENHO', 'SXCI', 'ENHS', 'SXSD')) {
    $rows = Read-Rows "TADIR" ("PGMID = 'R3TR' AND OBJECT = " + (Q $obj) + " AND OBJ_NAME = " + (Q $Name)) @("OBJECT", "AUTHOR", "DEVCLASS")
    if ($rows.Count -gt 0) { $tadir_object = $rows[0][0]; $tadir_author = $rows[0][1]; $tadir_devclass = $rows[0][2]; break }
}

Disconnect-SapRfc

# --- decide ------------------------------------------------------------------
$isClassic = $classicDef -or $classicImpl
$isNew = $newSpot -or $newDefRef -or $newImpl -or $migrated -or $tadirEnho

# KIND -- what the SYSTEM actually shows (from the discovered signals).
$hasDefSignal  = ($classicDef -or $newSpot -or $migrated)
$hasImplSignal = ($classicImpl -or $newImpl)
$discoveredKind = 'UNKNOWN'
if ($hasDefSignal)  { $discoveredKind = 'DEFINITION' }
if ($hasImplSignal) { $discoveredKind = 'IMPLEMENTATION' }  # impl wins when both (migrated def w/ impls)

# -Expect is a CHECK, NOT a silent override. Previously `$kind = $Expect`
# unconditionally forced the reported KIND to the caller's expectation, so a name
# that is ONLY a BAdI DEFINITION reported KIND=IMPLEMENTATION whenever the delete
# flow passed -Expect IMPLEMENTATION -- making the SKILL Step-6 "refuse delete if
# DEFINITION" guard unreachable. Now the reported KIND stays the discovered truth
# and a conflict is surfaced via EXPECT_MISMATCH so the caller can refuse.
$kind = $discoveredKind
$expectMismatch = $false
if ($Expect -ne 'AUTO' -and $discoveredKind -ne 'UNKNOWN' -and $discoveredKind -ne $Expect) {
    $expectMismatch = $true
}

# The TYPE disambiguation still uses the EXPECTED kind to scope its signals (that
# is -Expect's legitimate role: pick the definition-face vs implementation-face of
# a migrated BAdI). Fall back to the discovered kind under AUTO.
$typeKind = $kind
if ($Expect -ne 'AUTO') { $typeKind = $Expect }

# TYPE -- restrict signals to the expected KIND so a migrated definition that
# also has implementations isn't reported AMBIGUOUS for an implementation lookup.
$typeClassic = $false; $typeNew = $false
switch ($typeKind) {
    # A *migrated* BAdI keeps a classic face (you can still create classic
    # implementations of it -- e.g. ZZMB_MIGO_BADI on the migrated MB_MIGO_BADI)
    # AND a new face (it has an enhancement spot). Per req #1 that genuinely-
    # dual case must surface as AMBIGUOUS so the skill asks the user.
    'DEFINITION' { $typeClassic = ($classicDef -or $migrated); $typeNew = ($newSpot -or $migrated -or ($newDefRef -and -not $classicDef)) }
    'IMPLEMENTATION' { $typeClassic = $classicImpl; $typeNew = $newImpl }
    default { $typeClassic = $isClassic; $typeNew = $isNew }
}
$type = 'UNKNOWN'
if ($typeClassic -and $typeNew) { $type = 'AMBIGUOUS' }
elseif ($typeClassic) { $type = 'CLASSIC' }
elseif ($typeNew) { $type = 'NEW' }

# --- emit --------------------------------------------------------------------
Write-Output ("NAME=" + $Name)
Write-Output ("EXPECT=" + $Expect)
Write-Output ("CLASSIC_DEF=" + ($(if ($classicDef) { 'YES' } else { 'NO' })))
Write-Output ("MIGRATED=" + ($(if ($migrated) { 'YES' } else { 'NO' })))
Write-Output ("MIG_ENHSPOTNAME=" + $migSpot)
Write-Output ("MIG_BADI_NAME=" + $migBadi)
Write-Output ("DEF_CLASS=" + $defClass)
Write-Output ("NEW_SPOT=" + ($(if ($newSpot) { 'YES' } else { 'NO' })))
Write-Output ("NEW_DEF_REF=" + ($(if ($newDefRef) { 'YES' } else { 'NO' })))
Write-Output ("CLASSIC_IMPL=" + ($(if ($classicImpl) { 'YES' } else { 'NO' })))
Write-Output ("CLASSIC_IMPL_IFACE=" + $ci_iface)
Write-Output ("CLASSIC_IMPL_CLASS=" + $ci_class)
Write-Output ("CLASSIC_IMPL_ACTIVE=" + $ci_active)
Write-Output ("CLASSIC_IMPL_AUTHOR=" + $ci_uname)
Write-Output ("NEW_IMPL=" + ($(if ($newImpl) { 'YES' } else { 'NO' })))
Write-Output ("NEW_IMPL_BADI_NAME=" + $ni_badi)
Write-Output ("NEW_IMPL_ENHNAME=" + $ni_enh)
Write-Output ("NEW_IMPL_BADI_IMPL=" + $ni_impl)
Write-Output ("NEW_IMPL_CLASS=" + $ni_class)
Write-Output ("TADIR_OBJECT=" + $tadir_object)
Write-Output ("TADIR_AUTHOR=" + $tadir_author)
Write-Output ("TADIR_DEVCLASS=" + $tadir_devclass)
Write-Output ("DISCOVERED_KIND=" + $discoveredKind)
Write-Output ("EXPECT_MISMATCH=" + ($(if ($expectMismatch) { 'YES' } else { 'NO' })))
Write-Output ("RESULT: TYPE=" + $type + " KIND=" + $kind + " EXPECT_MISMATCH=" + ($(if ($expectMismatch) { 'YES' } else { 'NO' })))
exit 0
