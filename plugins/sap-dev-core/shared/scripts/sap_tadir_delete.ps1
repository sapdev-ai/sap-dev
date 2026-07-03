# =============================================================================
# sap_tadir_delete.ps1  --  Delete orphaned TADIR (object directory) entries
#
# Clears the object-directory row (TADIR) that an SE-delete commonly leaves
# behind after the object's DEFINITION is already gone (DD01L/DD04L/...). Such
# an orphan blocks the PACKAGE delete -- SE21 refuses a package whose TADIR
# still has children -- and silently re-attaches a later re-create to the old
# package. This is the programmatic remediation for that orphan (problem "P2"),
# replacing the manual SE03 -> Change Object Directory Entries (RSWBO052) step.
#
# MECHANISM
#   TR_TADIR_INTERFACE is the SAP-supplied write API for TADIR, but it is NOT
#   remote-enabled ("cannot be used for 'remote' calls"). It is invoked here
#   THROUGH the generic dispatcher Z_GENERIC_RFC_WRAPPER_TBL (deployed by
#   /sap-dev-init, remote-enabled), which does CALL FUNCTION ... PARAMETER-TABLE
#   dynamically. No raw SQL on the standard table TADIR -- this honours the
#   skill operating rules (a SAP write API is used; the wrapper is the sanctioned
#   bridge for non-RFC FMs).
#
#   Critical FM defaults (verified live on S/4HANA 2020, 7.54):
#     WI_TEST_MODUS         DEFAULT 'X'  -> dry-run! MUST be forced to ' ' to
#                                           actually delete.
#     WI_DELETE_TADIR_ENTRY DEFAULT ' '  -> set 'X' to delete.
#     WI_TADIR_PGMID/OBJECT/OBJ_NAME     -> mandatory keys (typed TADIR-*).
#
# SAFETY
#   Before deleting a row, unless -Force, this verifies the object's DEFINITION
#   is actually gone (DOMA->DD01L, DTEL->DD04L, TABL->DD02L, TTYP->DD40L,
#   VIEW->DD25L, SHLP->DD30L, FUNC->TFDIR, FUGR->TLIBG, PROG/REPS->TRDIR,
#   DEVC->TDEVC, CLAS/INTF->SEOCLASS, MSAG->T100A). If
#   the definition still EXISTS the row is NOT an orphan and the delete is
#   REFUSED -- deleting it would orphan a live object (the inverse foot-gun).
#   Unmapped OBJECT types are treated as "exists" (fail-safe) and refused unless
#   -Force. The authoritative success signal is a post-delete RFC re-read of
#   TADIR returning zero rows -- NOT the wrapper's "SUCCESS" echo (the wrapper
#   funnels every FM exception through one OTHERS handler, so its message alone
#   cannot be trusted; verify the state).
#
# RUN WITH 32-BIT POWERSHELL -- SAP NCo 3.1 is 32-bit-only:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File <this> ...
#
# PARAMETERS
#   -Object <CODE> -ObjName <NAME>   delete one entry (PGMID defaults R3TR)
#   -Entries "DOMA:ZCMD_X,DTEL:ZCMDE_Y[,R3TR:DOMA:ZX]"  batch; each item is
#                                    OBJECT:NAME or PGMID:OBJECT:NAME
#   -Pgmid <PGMID>                   default 'R3TR'
#   -WrapperFm <NAME>                default 'Z_GENERIC_RFC_WRAPPER_TBL'
#   -Force                           skip the def-gone safety check
#   -TestOnly                        dry-run (WI_TEST_MODUS='X'); nothing deleted
#   Connection params (-Server/-Sysnr/-Client/-User/-Password/-Language, or
#   load-balanced -MessageServer/-LogonGroup/-SystemID) fall through to
#   Connect-SapRfc, which defaults to the AI-session's pinned profile when blank.
#
# OUTPUT (stdout, parseable)
#   One line per requested entry:
#     TADIR: <DELETED|WOULD_DELETE|ALREADY_GONE|REFUSED_DEF_EXISTS|FAILED|REFUSED_UNMAPPED> <PGMID> <OBJECT> <OBJ_NAME> [note]
#   Then a summary:
#     STATUS: OK deleted=<n> would=<w> gone=<g> refused=<r> failed=<f>
#     STATUS: RFC_ERROR <msg>
#   Exit code: 0 = no failures and no refusals; 1 = at least one FAILED or
#   REFUSED; 2 = RFC / connect / wrapper-missing failure.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Object   = '',
    [string] $ObjName  = '',
    [string] $Entries  = '',
    [string] $Pgmid    = 'R3TR',
    [string] $WrapperFm = 'Z_GENERIC_RFC_WRAPPER_TBL',
    [switch] $Force,
    [switch] $TestOnly,

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

# Snapshot connection params BEFORE dot-sourcing (dot-source param clobber trap:
# sap_rfc_lib.ps1 has no param() but keep the discipline uniform with siblings).
$connServer     = $Server
$connSysnr      = $Sysnr
$connMsgServer  = $MessageServer
$connLogonGroup = $LogonGroup
$connSystemID   = $SystemID
$connClient     = $Client
$connUser       = $User
$connPassword   = $Password
$connLanguage   = $Language

. (Join-Path $scriptDir 'sap_rfc_lib.ps1')

# --- helpers ---------------------------------------------------------------
function Quote-RfcLiteral([string] $v) { "'" + ($v -replace "'", "''") + "'" }

function New-AsXml([string] $val) {
    '<asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>' +
        [System.Security.SecurityElement]::Escape($val) + '</DATA></asx:values></asx:abap>'
}

# Read rows via RFC_READ_TABLE, splitting the WA on the '|' delimiter and zipping
# with the requested field order. Returns an array of hashtables (field->value),
# or $null on read failure. Object/flag values never contain '|'.
function Read-Rows($dest, [string]$table, [string]$where, [string[]]$fields, [int]$rowcount = 0) {
    try {
        $fn = New-RfcReadTable -Destination $dest -Table $table
        # Split the WHERE at AND boundaries: RFC_READ_TABLE caps each OPTIONS row
        # at 72 chars, so a combined `A AND B AND C` overflows for long object
        # names (a >=21-char DDLS/CDS name makes the TADIR key clause 76+ chars ->
        # SAPSQL_PARSE_ERROR -> this read returns $null -> "TADIR read failed").
        if ($where) {
            $parts = [regex]::Split($where, '\s+AND\s+')
            for ($wi = 0; $wi -lt $parts.Count; $wi++) {
                $clause = if ($wi -eq 0) { $parts[$wi].Trim() } else { 'AND ' + $parts[$wi].Trim() }
                Add-RfcOption $fn $clause
            }
        }
        foreach ($f in $fields) { Add-RfcField $fn $f }
        if ($rowcount -gt 0) { [void]$fn.SetValue('ROWCOUNT', $rowcount) }
        $fn.Invoke($dest)
        $data = $fn.GetTable('DATA')
        $out = @()
        for ($i = 0; $i -lt $data.RowCount; $i++) {
            $data.CurrentIndex = $i
            $wa = $data.GetString('WA')
            $vals = $wa -split '\|'
            $h = @{}
            for ($c = 0; $c -lt $fields.Count; $c++) {
                $h[$fields[$c]] = if ($c -lt $vals.Count) { $vals[$c].Trim() } else { '' }
            }
            $out += $h
        }
        return ,$out
    } catch {
        return $null
    }
}

# OBJECT code -> (definition table, key field). Presence of a row proves the
# repository object's DEFINITION still exists. Mirrors sap_tr_object_entries.ps1.
function Get-DefLookup([string] $object) {
    switch ($object.ToUpperInvariant()) {
        'DOMA' { return @{ Table = 'DD01L'; Key = 'DOMNAME'  } }
        'DTEL' { return @{ Table = 'DD04L'; Key = 'ROLLNAME' } }
        'TABL' { return @{ Table = 'DD02L'; Key = 'TABNAME'  } }
        'TTYP' { return @{ Table = 'DD40L'; Key = 'TYPENAME' } }
        'VIEW' { return @{ Table = 'DD25L'; Key = 'VIEWNAME' } }
        'SHLP' { return @{ Table = 'DD30L'; Key = 'SHLPNAME' } }
        'FUNC' { return @{ Table = 'TFDIR'; Key = 'FUNCNAME' } }
        'FUGR' { return @{ Table = 'TLIBG'; Key = 'AREA'     } }
        'PROG' { return @{ Table = 'TRDIR'; Key = 'NAME'     } }
        'REPS' { return @{ Table = 'TRDIR'; Key = 'NAME'     } }
        'DEVC' { return @{ Table = 'TDEVC'; Key = 'DEVCLASS' } }   # package: a deleted pkg often leaves its own TADIR DEVC row
        'CLAS' { return @{ Table = 'SEOCLASS'; Key = 'CLSNAME' } }
        'INTF' { return @{ Table = 'SEOCLASS'; Key = 'CLSNAME' } }
        'MSAG' { return @{ Table = 'T100A'; Key = 'ARBGB'    } }
        default { return $null }
    }
}

# Returns: $true definition exists, $false gone, $null unmapped/unknown.
function Test-DefExists($dest, [string]$object, [string]$name) {
    $lk = Get-DefLookup $object
    if ($null -eq $lk) { return $null }
    $rows = Read-Rows $dest $lk.Table ($lk.Key + ' = ' + (Quote-RfcLiteral $name.ToUpperInvariant())) @($lk.Key) 1
    if ($null -eq $rows) { return $true }   # read failed -> assume exists (fail-safe)
    return ($rows.Count -ge 1)
}

function Test-TadirExists($dest, [string]$pgmid, [string]$object, [string]$name) {
    $where = "PGMID = " + (Quote-RfcLiteral $pgmid) + " AND OBJECT = " + (Quote-RfcLiteral $object) +
             " AND OBJ_NAME = " + (Quote-RfcLiteral $name)
    $rows = Read-Rows $dest 'TADIR' $where @('PGMID', 'OBJECT', 'OBJ_NAME') 1
    if ($null -eq $rows) { return $null }   # read failed
    return ($rows.Count -ge 1)
}

# A TADIR orphan whose object name is still listed in an UNRELEASED request
# (E071 name-lock) cannot be deleted by TR_TADIR_INTERFACE -- the FM raises and
# the row survives. Return the top-level REQUEST holding such a lock (to feed
# /sap-se01 remove-objects), or '' if none. Used only to make a FAILED delete
# actionable.
function Get-E071Lock($dest, [string]$object, [string]$name) {
    $rows = Read-Rows $dest 'E071' ("OBJ_NAME = " + (Quote-RfcLiteral $name) +
                " AND OBJECT = " + (Quote-RfcLiteral $object)) @('TRKORR', 'OBJECT', 'OBJ_NAME')
    if ($null -eq $rows) { return '' }
    foreach ($r in $rows) {
        $tr  = $r.TRKORR
        $hdr = Read-Rows $dest 'E070' ("TRKORR = " + (Quote-RfcLiteral $tr)) @('TRKORR', 'TRSTATUS', 'STRKORR') 1
        if ($hdr -and $hdr.Count -ge 1 -and ($hdr[0].TRSTATUS -eq 'D' -or $hdr[0].TRSTATUS -eq 'L')) {
            $req = $hdr[0].STRKORR
            if ([string]::IsNullOrWhiteSpace($req)) { $req = $tr }
            return $req
        }
    }
    return ''
}

# Invoke wrapper -> TR_TADIR_INTERFACE delete for one entry. Returns $true if
# the wrapper call returned without exception (NOT proof of deletion -- the
# caller re-reads TADIR to confirm). $false on wrapper exception.
function Invoke-TadirDelete($dest, [string]$wrapperFm, [string]$pgmid, [string]$object, [string]$name, [bool]$test) {
    $fn = $dest.Repository.CreateFunction($wrapperFm)
    $fn.SetValue('IV_FUNCNAME', 'TR_TADIR_INTERFACE')
    $tbl = $fn.GetTable('CT_PARAMS')
    # rows: @(PNAME, PTYPE, PTYPENAME, payload)  payload '' => blank passed
    $testVal = if ($test) { (New-AsXml 'X') } else { '' }   # '' => FM gets blank => real run
    $rows = @(
        @('WI_TADIR_PGMID',        'I', 'TADIR-PGMID',      (New-AsXml $pgmid)),
        @('WI_TADIR_OBJECT',       'I', 'TADIR-OBJECT',     (New-AsXml $object)),
        @('WI_TADIR_OBJ_NAME',     'I', 'TADIR-OBJ_NAME',   (New-AsXml $name)),
        @('WI_DELETE_TADIR_ENTRY', 'I', 'TRPARI-S_CHECKED', (New-AsXml 'X')),
        @('WI_TEST_MODUS',         'I', 'TRPARI-S_CHECKED', $testVal)
    )
    foreach ($r in $rows) {
        [void]$tbl.Append()
        [void]$tbl.SetValue('PNAME', $r[0]); [void]$tbl.SetValue('PSEQ', 1)
        [void]$tbl.SetValue('PTYPE', $r[1]); [void]$tbl.SetValue('PTYPENAME', $r[2])
        if (-not [string]::IsNullOrEmpty($r[3])) { [void]$tbl.SetValue('PVALUE', $r[3]) }
    }
    try { $fn.Invoke($dest); return $true } catch {
        Write-Host ("       wrapper exception: " + $_.Exception.Message)
        return $false
    }
}

# --- parse the requested entries -------------------------------------------
# Each becomes @{ Pgmid; Object; Name }.
$work = @()
function Add-Work([string]$pg, [string]$ob, [string]$nm) {
    $script:work += @{ Pgmid = $pg.Trim().ToUpperInvariant(); Object = $ob.Trim().ToUpperInvariant(); Name = $nm.Trim().ToUpperInvariant() }
}
if ($Entries.Trim() -ne '') {
    foreach ($item in ($Entries -split ',')) {
        $t = $item.Trim()
        if ($t -eq '') { continue }
        $parts = $t -split ':'
        if ($parts.Count -eq 3)      { Add-Work $parts[0] $parts[1] $parts[2] }
        elseif ($parts.Count -eq 2)  { Add-Work $Pgmid    $parts[0] $parts[1] }
        else { Write-Host ("WARN: ignoring malformed -Entries item '" + $t + "' (want OBJECT:NAME or PGMID:OBJECT:NAME)") }
    }
}
if ($Object.Trim() -ne '' -and $ObjName.Trim() -ne '') { Add-Work $Pgmid $Object $ObjName }

if ($work.Count -eq 0) {
    Write-Output 'STATUS: RFC_ERROR need -Object + -ObjName, or -Entries'
    exit 2
}

# --- connect ---------------------------------------------------------------
$dest = $null
try {
    $dest = Connect-SapRfc -Server $connServer -Sysnr $connSysnr `
        -MessageServer $connMsgServer -LogonGroup $connLogonGroup -SystemID $connSystemID `
        -Client $connClient -User $connUser -Password $connPassword -Language $connLanguage
} catch {
    Write-Output ("STATUS: RFC_ERROR " + $_.Exception.Message); exit 2
}
if ($null -eq $dest) {
    Write-Output 'STATUS: RFC_ERROR could not connect (no pinned profile / bad credentials)'; exit 2
}

# Verify the wrapper FM is present + remote-enabled (clear error if dev-init absent).
$wrapRows = Read-Rows $dest 'TFDIR' ("FUNCNAME = " + (Quote-RfcLiteral $WrapperFm.ToUpperInvariant())) @('FUNCNAME', 'FMODE') 1
if ($null -eq $wrapRows -or $wrapRows.Count -eq 0) {
    Write-Output ("STATUS: RFC_ERROR wrapper FM " + $WrapperFm + " not found -- run /sap-dev-init to deploy it")
    try { Disconnect-SapRfc } catch {}; exit 2
}
if ($wrapRows[0].FMODE -ne 'R') {
    Write-Output ("STATUS: RFC_ERROR wrapper FM " + $WrapperFm + " is not remote-enabled (FMODE=" + $wrapRows[0].FMODE + ") -- /sap-dev-init Step 7b sets PROCESSING_TYPE=REMOTE")
    try { Disconnect-SapRfc } catch {}; exit 2
}

# --- process ---------------------------------------------------------------
$nDel = 0; $nWould = 0; $nGone = 0; $nRef = 0; $nFail = 0
try {
    foreach ($w in $work) {
        $pg = $w.Pgmid; $ob = $w.Object; $nm = $w.Name
        $tag = "$pg $ob $nm"

        $tadir = Test-TadirExists $dest $pg $ob $nm
        if ($null -eq $tadir) { Write-Output ("TADIR: FAILED $tag (TADIR read failed)"); $nFail++; continue }
        if (-not $tadir)      { Write-Output ("TADIR: ALREADY_GONE $tag"); $nGone++; continue }

        if (-not $Force) {
            $defExists = Test-DefExists $dest $ob $nm
            if ($null -eq $defExists) {
                Write-Output ("TADIR: REFUSED_UNMAPPED $tag (no def-table mapping for $ob; re-run with -Force only if you are sure it is an orphan)")
                $nRef++; continue
            }
            if ($defExists) {
                Write-Output ("TADIR: REFUSED_DEF_EXISTS $tag (definition still present -- not an orphan; deleting TADIR would orphan a live object)")
                $nRef++; continue
            }
        }

        if ($TestOnly) {
            # Dry-run through the FM so the call path is exercised; nothing deleted.
            [void](Invoke-TadirDelete $dest $WrapperFm $pg $ob $nm $true)
            Write-Output ("TADIR: WOULD_DELETE $tag (TestOnly; definition gone, orphan confirmed)")
            $nWould++; continue
        }

        $called = Invoke-TadirDelete $dest $WrapperFm $pg $ob $nm $false
        $still = Test-TadirExists $dest $pg $ob $nm
        if ($still -eq $false) {
            Write-Output ("TADIR: DELETED $tag")
            $nDel++
        } else {
            $why = if (-not $called) { 'wrapper raised' } else { 'TADIR row still present after delete' }
            # Most common cause: the name is still locked by an unreleased E071
            # entry. Surface the request so the caller can clear it first.
            $lockTr = Get-E071Lock $dest $ob $nm
            if ($lockTr -ne '') {
                $why += "; still listed in unreleased request $lockTr (E071) -- clear it first via '/sap-se01 remove-objects $lockTr OBJECTS=$nm', then retry"
            }
            Write-Output ("TADIR: FAILED $tag ($why)")
            $nFail++
        }
    }

    Write-Output ("STATUS: OK deleted=$nDel would=$nWould gone=$nGone refused=$nRef failed=$nFail")
    if ($nFail -gt 0 -or $nRef -gt 0) { exit 1 } else { exit 0 }
} catch {
    Write-Output ("STATUS: RFC_ERROR " + $_.Exception.Message); exit 2
} finally {
    if ($null -ne $dest) { try { Disconnect-SapRfc } catch {} }
}
