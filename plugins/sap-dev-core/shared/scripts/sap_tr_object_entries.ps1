# =============================================================================
# sap_tr_object_entries.ps1  --  Find which transport requests list given objects
#
# Reads E071 (transport object entries) joined to E070 (request header) via RFC
# (NCo 3.1) and reports every request that still lists one of the named objects,
# annotated with the request's release status. This is the "check E071 before
# you remove" pre-flight behind:
#   * /sap-dev-clean  -- after deleting an object's definition, find the
#                        unreleased request(s) whose lingering E071 entry still
#                        holds the name-lock, so it can be cleared via
#                        /sap-se01 remove-objects (re-create stays unblocked).
#   * /sap-dev-init   -- before creating an object, detect a stale entry in an
#                        old unreleased request that would otherwise block the
#                        create.
#
# It does NOT modify anything -- pure read. Removal is /sap-se01 remove-objects.
#
# RUN WITH 32-BIT POWERSHELL -- SAP NCo 3.1 is 32-bit-only. Invoke via
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File <this> ...
# 64-bit powershell fails with "Could not load ... sapnco.dll ... incorrect
# format" (the script surfaces that hint and exits 2).
#
# Two query modes:
#   * BY-OBJECT (-Objects given): report which request(s) list those object names.
#   * BY-TR (only -Trkorr given, no -Objects): list EVERY object in that request and
#     its child tasks -- the emptiness check behind /sap-dev-clean "delete the TR
#     when it is empty" (entries=0 => safe to delete; entries>0 => other work
#     remains, keep it). No release / orphan filtering in this mode.
#
# Parameters:
#   -Objects "<comma-separated OBJ_NAME list>"   BY-OBJECT mode (e.g. "ZCMD_RFCVAL,ZCMDE_RFCVAL")
#   -Trkorr  "<TR>"        BY-OBJECT: restrict the name search to this request.
#                          BY-TR (when -Objects is omitted): the request to list in full.
#   -IncludeReleased       optional switch -- also report released (R/O) requests
#                          (default: only modifiable D / L requests, which are
#                          the ones whose entries can be removed and the only
#                          ones that hold a re-create-blocking lock)
#   -OnlyOrphaned          optional switch -- emit an entry ONLY when the object's
#                          DEFINITION no longer exists (the precise "deleted but
#                          still locked in an old request" case that blocks
#                          re-create). Existence is checked against the type-
#                          appropriate DD/dir table keyed off the E071 OBJECT
#                          code (DOMA->DD01L, DTEL->DD04L, TABL->DD02L,
#                          TTYP->DD40L, VIEW->DD25L, SHLP->DD30L, FUNC->TFDIR,
#                          PROG/REPS->TRDIR, FUGR->TLIBG). Unmapped types are
#                          treated as "exists" (fail-safe: never reported as
#                          orphaned, so an entry is never cleared on a guess).
#                          Used by /sap-dev-init's pre-create hygiene sweep.
#   Connection params (-Server/-Sysnr/-Client/-User/-Password/-Language, or
#   load-balanced -MessageServer/-LogonGroup/-SystemID) all fall through to
#   Connect-SapRfc, which defaults to the AI-session's pinned profile when blank.
#
# Output (stdout, parseable):
#   One TAB-separated line per matching entry. OBJFUNC = the E071 object function:
#   'K' (normalised from blank) = create/change, 'D' = the entry RECORDS A
#   DELETION of the object. REQUEST = the top-level request (the entry's STRKORR
#   when its TRKORR is a task, else the TRKORR itself) -- still the TRAILING column:
#     ENTRY<TAB>TRKORR<TAB>TRSTATUS<TAB>TRFUNCTION<TAB>PGMID<TAB>OBJECT<TAB>OBJ_NAME<TAB>OBJFUNC<TAB>REQUEST
#   Then a summary line (deletions = how many of the entries are OBJFUNC='D'):
#     STATUS: OK entries=<n> deletions=<d> requests=<m> unreleased=<u>
#     STATUS: RFC_ERROR <msg>
#   Exit code: 0 = OK (including 0 entries), 2 = RFC / connect failure.
#
# Deletion entries (OBJFUNC='D') matter to callers: a TR holding ONLY 'D' entries
# is a record of already-deleted objects (no live content) -- deleting/emptying
# that TR un-records those deletions (they won't transport onward) even though the
# objects stay deleted locally. /sap-se01 delete surfaces this; see its D2.
#
# TRSTATUS legend: D Modifiable, L Locked, O Release started, R Released.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Objects = '',
    [string] $Trkorr = '',
    [switch] $IncludeReleased,
    [switch] $OnlyOrphaned,

    [string] $Server   = '',
    [string] $Sysnr    = '',
    [string] $MessageServer = '',
    [string] $LogonGroup    = '',
    [string] $SystemID      = '',
    [string] $Client   = '',
    [string] $User     = '',
    [string] $Password = '',
    [string] $Language = ''
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# IMPORTANT -- capture the connection params into private locals BEFORE dot-
# sourcing sap_object_resolver.ps1. That script is dual-use (dot-source OR CLI)
# and carries a top-level `[CmdletBinding()] param(...)` with the SAME names
# ($Server/$Sysnr/$Client/$User/$Password/$Language/...). Dot-sourcing runs that
# param block in THIS scope and resets every same-named var to '' -- the
# documented "dot-source param clobber" trap -- which would then make
# Connect-SapRfc fall back to the pinned profile instead of honouring the
# explicit endpoint the caller passed. Snapshot first, use the snapshot below.
$connServer     = $Server
$connSysnr      = $Sysnr
$connMsgServer  = $MessageServer
$connLogonGroup = $LogonGroup
$connSystemID   = $SystemID
$connClient     = $Client
$connUser       = $User
$connPassword   = $Password
$connLanguage   = $Language

# Shared RFC primitives + the generic table reader.
. (Join-Path $scriptDir 'sap_rfc_lib.ps1')
. (Join-Path $scriptDir 'sap_object_resolver.ps1')

# Parse + normalise the object name list (upper-case, de-duplicated, non-empty).
$names = @()
foreach ($n in ($Objects -split ',')) {
    $t = $n.Trim().ToUpperInvariant()
    if ($t -ne '' -and ($names -notcontains $t)) { $names += $t }
}
# Mode dispatch: BY-OBJECT (names given) vs BY-TR (only a request given).
$reqFilter = $Trkorr.Trim().ToUpperInvariant()
$byObjects = ($names.Count -gt 0)
$byTr      = (-not $byObjects) -and ($reqFilter -ne '')
if (-not $byObjects -and -not $byTr) {
    Write-Output 'STATUS: RFC_ERROR need -Objects or -Trkorr'
    exit 2
}

# RFC_READ_TABLE quotes a value literal with single quotes; an embedded quote is
# doubled. Object names are Z/Y identifiers so this is belt-and-suspenders.
function Quote-RfcLiteral([string] $v) { "'" + ($v -replace "'", "''") + "'" }

# Map an E071 OBJECT code to the (table, key-field) whose presence proves the
# repository object's DEFINITION still exists. DD0xL/DD25L/DD30L/DD40L are the
# definition tables (removed on delete) -- NOT TADIR (a directory row that can
# survive a delete as an orphan), so these are reliable existence signals.
function Get-SapDefLookup([string] $object) {
    switch ($object.ToUpperInvariant()) {
        'DOMA' { return @{ Table = 'DD01L'; Key = 'DOMNAME' } }
        'DTEL' { return @{ Table = 'DD04L'; Key = 'ROLLNAME' } }
        'TABL' { return @{ Table = 'DD02L'; Key = 'TABNAME' } }   # table or structure
        'TTYP' { return @{ Table = 'DD40L'; Key = 'TYPENAME' } }
        'VIEW' { return @{ Table = 'DD25L'; Key = 'VIEWNAME' } }
        'SHLP' { return @{ Table = 'DD30L'; Key = 'SHLPNAME' } }
        'FUNC' { return @{ Table = 'TFDIR'; Key = 'FUNCNAME' } }
        'FUGR' { return @{ Table = 'TLIBG'; Key = 'AREA' } }
        'PROG' { return @{ Table = 'TRDIR'; Key = 'NAME' } }
        'REPS' { return @{ Table = 'TRDIR'; Key = 'NAME' } }
        default { return $null }   # unmapped -> caller treats as "exists" (fail-safe)
    }
}

# Returns $true when the object's definition exists, $false when it is gone
# (orphaned lock), and $true (fail-safe) for unmapped types or a read failure --
# so a genuinely-present or unverifiable object is NEVER reported as orphaned.
function Test-SapObjectDefExists($dest, [string] $object, [string] $name) {
    $lk = Get-SapDefLookup $object
    if ($null -eq $lk) { return $true }
    $rows = Read-SapTableRows -Destination $dest -Table $lk.Table `
                -Where ($lk.Key + ' = ' + (Quote-RfcLiteral $name.ToUpperInvariant())) `
                -Fields @($lk.Key) -RowCount 1
    if ($null -eq $rows) { return $true }     # read failed -> assume exists (fail-safe)
    return ($rows.Count -ge 1)
}

$dest = $null
try {
    $dest = Connect-SapRfc -Server $connServer -Sysnr $connSysnr `
        -MessageServer $connMsgServer -LogonGroup $connLogonGroup -SystemID $connSystemID `
        -Client $connClient -User $connUser -Password $connPassword -Language $connLanguage
} catch {
    Write-Output ("STATUS: RFC_ERROR " + $_.Exception.Message)
    exit 2
}
if ($null -eq $dest) {
    Write-Output 'STATUS: RFC_ERROR could not connect (no pinned profile / bad credentials)'
    exit 2
}

try {
    # 1. Collect the E071 entries to consider.
    $entries = @()
    if ($byObjects) {
        # BY-OBJECT: one read per name (keeps each OPTIONS line under
        # RFC_READ_TABLE's 72-char limit, avoids OR-clause quoting fragility).
        foreach ($name in $names) {
            $where = "OBJ_NAME = " + (Quote-RfcLiteral $name)
            if ($reqFilter -ne '') { $where += " AND TRKORR = " + (Quote-RfcLiteral $reqFilter) }
            $rows = Read-SapTableRows -Destination $dest -Table 'E071' -Where $where `
                        -Fields @('TRKORR', 'PGMID', 'OBJECT', 'OBJ_NAME', 'OBJFUNC')
            if ($null -eq $rows) {
                Write-Output 'STATUS: RFC_ERROR RFC_READ_TABLE on E071 failed (auth S_TABU_DIS?)'
                exit 2
            }
            foreach ($r in $rows) { $entries += $r }
        }
    } else {
        # BY-TR: list EVERY object in the request AND its child tasks. Objects
        # usually live in the tasks (E071.TRKORR = task), so the request header
        # alone is not enough -- discover tasks via E070 STRKORR = request.
        $nodes = New-Object System.Collections.Generic.List[string]
        $nodes.Add($reqFilter) | Out-Null
        $taskRows = Read-SapTableRows -Destination $dest -Table 'E070' `
                        -Where ("STRKORR = " + (Quote-RfcLiteral $reqFilter)) -Fields @('TRKORR')
        if ($null -eq $taskRows) {
            Write-Output 'STATUS: RFC_ERROR RFC_READ_TABLE on E070 failed (auth S_TABU_DIS?)'
            exit 2
        }
        foreach ($t in $taskRows) {
            $tk = "$($t.TRKORR)".Trim()
            if ($tk -ne '' -and -not $nodes.Contains($tk)) { $nodes.Add($tk) | Out-Null }
        }
        foreach ($node in $nodes) {
            $rows = Read-SapTableRows -Destination $dest -Table 'E071' `
                        -Where ("TRKORR = " + (Quote-RfcLiteral $node)) `
                        -Fields @('TRKORR', 'PGMID', 'OBJECT', 'OBJ_NAME', 'OBJFUNC')
            if ($null -eq $rows) {
                Write-Output 'STATUS: RFC_ERROR RFC_READ_TABLE on E071 failed (auth S_TABU_DIS?)'
                exit 2
            }
            foreach ($r in $rows) { $entries += $r }
        }
    }

    # 2. Resolve each distinct request's status once (E070), cached.
    $statusByTr = @{}
    foreach ($e in $entries) {
        $tr = $e.TRKORR
        if ($statusByTr.ContainsKey($tr)) { continue }
        $hdr = Read-SapTableRows -Destination $dest -Table 'E070' `
                    -Where ("TRKORR = " + (Quote-RfcLiteral $tr)) `
                    -Fields @('TRKORR', 'TRSTATUS', 'TRFUNCTION', 'STRKORR') -RowCount 1
        if ($null -ne $hdr -and $hdr.Count -ge 1) {
            $statusByTr[$tr] = $hdr[0]
        } else {
            $statusByTr[$tr] = [pscustomobject]@{ TRKORR = $tr; TRSTATUS = '?'; TRFUNCTION = '?'; STRKORR = '' }
        }
    }

    # 3. With -OnlyOrphaned, pre-compute definition existence per distinct
    #    (OBJECT, OBJ_NAME) once (cached) so we can drop entries whose object
    #    still exists.
    $existsCache = @{}
    if ($OnlyOrphaned) {
        foreach ($e in $entries) {
            $k = "$($e.OBJECT)|$($e.OBJ_NAME)"
            if (-not $existsCache.ContainsKey($k)) {
                $existsCache[$k] = Test-SapObjectDefExists $dest $e.OBJECT $e.OBJ_NAME
            }
        }
    }

    # 4. Emit. BY-OBJECT applies the release / orphan filters; BY-TR lists every
    #    object unconditionally (the emptiness signal must be the TRUE count).
    #    REQUEST column = STRKORR when the entry's TRKORR is a task, else TRKORR.
    $emitted   = 0
    $delCount  = 0
    $reqSet    = @{}
    $unrelSet  = @{}
    foreach ($e in $entries) {
        $hdr      = $statusByTr[$e.TRKORR]
        $trstatus = "$($hdr.TRSTATUS)"
        $isUnrel  = ($trstatus -eq 'D' -or $trstatus -eq 'L')
        if ($byObjects) {
            if (-not $IncludeReleased -and -not $isUnrel) { continue }
            if ($OnlyOrphaned -and $existsCache["$($e.OBJECT)|$($e.OBJ_NAME)"]) { continue }
        }
        $strk    = "$($hdr.STRKORR)".Trim()
        $request = if ($strk -ne '') { $strk } else { "$($e.TRKORR)" }
        # OBJFUNC: '' (blank) = create/change, 'D' = the entry RECORDS A DELETION of
        # the object (P5/P6 -- such an entry is a record of an already-deleted
        # object; un-assigning it un-records the deletion, and a TR holding only
        # these is "effectively empty" of live content). Normalise blank -> 'K'.
        $objf = "$($e.OBJFUNC)".Trim().ToUpperInvariant()
        if ($objf -eq '') { $objf = 'K' }
        if ($objf -eq 'D') { $delCount++ }
        $reqSet[$request] = $true
        if ($isUnrel) { $unrelSet[$request] = $true }
        $line = "ENTRY`t$($e.TRKORR)`t$trstatus`t$($hdr.TRFUNCTION)`t$($e.PGMID)`t$($e.OBJECT)`t$($e.OBJ_NAME)`t$objf`t$request"
        Write-Output $line
        $emitted++
    }

    Write-Output ("STATUS: OK entries=$emitted deletions=$delCount requests=$($reqSet.Count) unreleased=$($unrelSet.Count)")
    exit 0
} catch {
    Write-Output ("STATUS: RFC_ERROR " + $_.Exception.Message)
    exit 2
} finally {
    if ($null -ne $dest) { try { Disconnect-SapRfc } catch {} }
}
