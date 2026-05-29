# =============================================================================
# sap_cmod_query.ps1  -  Read-only CMOD enhancement-project lookups via RFC
#
# Used by the sap-cmod skill for the "check" / "status" / "assignments" /
# "components" operations. Reads SAP-standard tables via RFC_READ_TABLE
# (sap_rfc_lib.ps1) — pure SELECT, no writes (allowed under
# skill_operating_rules.md). If NCo / RFC is unavailable the skill falls
# back to /sap-se16n.
#
# Tables (S/4HANA 1909, confirmed live 2026-05-29):
#   MODATTR  NAME(C8) project | STATUS(C1) 'A'=active, ' '=inactive | + audit cols
#   MODACT   NAME(C8) project | MEMBER(C100) assigned enhancement (one row per;
#                              a header row with blank MEMBER also exists) | DEVCLASS
#   MODSAP   NAME(C8) enhancement | TYP(C1) E/S/T/C component kind | MEMBER(C100)
#   MODTEXT  SPRSL lang | NAME(C8) project | MODTEXT short text
#   TADIR    PGMID=R3TR OBJECT=CMOD OBJ_NAME=project | DEVCLASS package
#
# Actions:
#   check        MODATTR + MODACT + MODTEXT + TADIR for <Project>  (the default;
#                emits EXISTS / STATUS / DEVCLASS / SHORTTEXT / ASSIGNMENT* / COUNT)
#   status       MODATTR only           (EXISTS / STATUS / STATUS_LABEL)
#   assignments  MODACT only            (ASSIGNMENT:<enh> per row + COUNT)
#   components   MODSAP for <Enhancement> (COMPONENT:<TYP>|<MEMBER> per row + COUNT)
#   exit-include Resolve the customer INCLUDE of a function-exit FM (<Fm>) from
#                RPY_FUNCTIONMODULE_READ_NEW's SOURCE table. Emits
#                CUSTOMER_INCLUDE / INCLUDE_EXISTS / SE38_MODE. The include is
#                named after the function POOL (+seq), NOT the FM, so it cannot
#                be guessed — it is read from the source.
#   find-project Reverse lookup: which CMOD project(s) the enhancement (<Enhancement>)
#                is assigned to (MODACT) + each project's MODATTR status. Emits
#                PROJECT:<name>|<status>|<label>. Used to activate the enclosing
#                project after editing a component (the exit only runs when its
#                project is active).
#
# Output is line-oriented and parseable; final line is DONE or ERROR: <msg>.
# =============================================================================
[CmdletBinding()]
param(
    [string]$Project     = '',
    [string]$Enhancement = '',
    [string]$Fm          = '',   # function-exit FM, for -Action exit-include
    [ValidateSet('check','status','assignments','components','exit-include','find-project')]
    [string]$Action      = 'check',
    # Connection params are optional — when blank, Connect-SapRfc resolves the
    # default profile from runtime/connections.json (DPAPI-decrypted password).
    [string]$Server   = '',
    [string]$Sysnr    = '',
    [string]$Client   = '',
    [string]$User     = '',
    [string]$Password = '',
    [string]$Language = '',
    [string]$RfcLib   = ''
)

$ErrorActionPreference = 'Stop'

# ---- Resolve + dot-source the shared RFC library ---------------------------
if (-not $RfcLib) {
    $RfcLib = Join-Path $PSScriptRoot '..\..\..\shared\scripts\sap_rfc_lib.ps1'
}
if (-not (Test-Path $RfcLib)) { Write-Output "ERROR: sap_rfc_lib.ps1 not found at $RfcLib"; exit 2 }
. $RfcLib

$Project     = $Project.Trim().ToUpper()
$Enhancement = $Enhancement.Trim().ToUpper()
$Fm          = $Fm.Trim().ToUpper()

if (@('check','status','assignments') -contains $Action -and -not $Project) { Write-Output "ERROR: -Project is required for action '$Action'"; exit 2 }
if ($Action -eq 'components'   -and -not $Enhancement) { Write-Output "ERROR: -Enhancement is required for action 'components'"; exit 2 }
if ($Action -eq 'find-project' -and -not $Enhancement) { Write-Output "ERROR: -Enhancement is required for action 'find-project'"; exit 2 }
if ($Action -eq 'exit-include' -and -not $Fm)          { Write-Output "ERROR: -Fm is required for action 'exit-include'"; exit 2 }

# ---- Connect (profile fallback when params blank) --------------------------
$dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -Client $Client -User $User -Password $Password -Language $Language -DestName "CMOD_QUERY"
if (-not $dest) { Write-Output "ERROR: RFC connection failed"; exit 2 }

# Read a table; returns an array of pipe-joined WA strings, or $null on RFC error.
function Read-Tbl($table, $where, $fields) {
    $fn = New-RfcReadTable -Destination $dest -Table $table
    if ($where)  { Add-RfcOption $fn $where }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    try { $fn.Invoke($dest) } catch { return $null }
    $data = $fn.GetTable("DATA")
    $rows = @()
    for ($i = 0; $i -lt $data.RowCount; $i++) { $data.CurrentIndex = $i; $rows += ,$data.GetString("WA") }
    return ,$rows
}

try {
    switch ($Action) {

        'status' {
            $rows = Read-Tbl "MODATTR" "NAME = '$Project'" @("NAME","STATUS")
            if ($null -eq $rows)      { Write-Output "ERROR: RFC_READ_TABLE failed on MODATTR"; exit 2 }
            if ($rows.Count -eq 0)    { Write-Output "EXISTS: NO"; Write-Output "DONE"; break }
            $st = ($rows[0].Split('|')[1]).Trim()
            Write-Output "EXISTS: YES"
            Write-Output "STATUS: $st"
            Write-Output ("STATUS_LABEL: " + $(if ($st -eq 'A') { 'ACTIVE' } else { 'INACTIVE' }))
            Write-Output "DONE"
        }

        'assignments' {
            $rows = Read-Tbl "MODACT" "NAME = '$Project'" @("NAME","MEMBER")
            if ($null -eq $rows) { Write-Output "ERROR: RFC_READ_TABLE failed on MODACT"; exit 2 }
            $enh = @()
            foreach ($r in $rows) { $m = ($r.Split('|')[1]).Trim(); if ($m) { $enh += $m } }
            foreach ($e in $enh) { Write-Output "ASSIGNMENT: $e" }
            Write-Output ("COUNT: " + $enh.Count)
            Write-Output "DONE"
        }

        'exit-include' {
            # Resolve the customer INCLUDE for a function-exit FM (TYP=E) by
            # reading the FM source. The include name follows the function
            # POOL (e.g. XCN1 -> ZXCN1U21), NOT the FM name — it cannot be
            # guessed, it must be read from the source.
            $fn = $dest.Repository.CreateFunction("RPY_FUNCTIONMODULE_READ_NEW")
            $fn.SetValue("FUNCTIONNAME", $Fm)
            try { $fn.Invoke($dest) } catch { Write-Output "EXISTS: NO"; Write-Output "ERROR: FM $Fm not found or read failed: $($_.Exception.Message)"; exit 1 }
            Write-Output "EXISTS: YES"
            try { Write-Output ("FUNCTION_POOL: " + ([string]$fn.GetString("FUNCTION_POOL")).Trim()) } catch {}
            try { Write-Output ("SHORT_TEXT: "    + ([string]$fn.GetString("SHORT_TEXT")).Trim()) } catch {}
            $src = $fn.GetTable("SOURCE")
            $includes = @()
            for ($i = 0; $i -lt $src.RowCount; $i++) {
                $src.CurrentIndex = $i
                $line = [string]$src.GetString("LINE")
                if ($line -match '(?i)^\s*INCLUDE\s+([A-Za-z0-9_/]+)\s*\.') { $includes += $matches[1].ToUpper() }
            }
            # Customer include = the Z*/Y* one (function exits carry exactly one).
            $cust = $includes | Where-Object { $_ -match '^[ZY]' } | Select-Object -First 1
            foreach ($inc in $includes) { Write-Output "INCLUDE: $inc" }
            if ($cust) {
                Write-Output "CUSTOMER_INCLUDE: $cust"
                $tr = Read-Tbl "TRDIR" "NAME = '$cust'" @("NAME")
                $exists = ($tr -and $tr.Count -gt 0)
                Write-Output ("INCLUDE_EXISTS: " + $(if ($exists) { 'YES' } else { 'NO' }))
                Write-Output ("SE38_MODE: "      + $(if ($exists) { 'update' } else { 'create' }))
            } else {
                Write-Output "CUSTOMER_INCLUDE: (none found in source)"
            }
            Write-Output "DONE"
        }

        'find-project' {
            # Reverse lookup: which CMOD project(s) is this enhancement assigned
            # to (MODACT.MEMBER = enhancement -> NAME = project), and is each
            # active? Used after editing a component to activate the enclosing
            # project so the exit actually runs.
            $rows = Read-Tbl "MODACT" "MEMBER LIKE '$Enhancement%'" @("NAME","MEMBER")
            if ($null -eq $rows) { Write-Output "ERROR: RFC_READ_TABLE failed on MODACT"; exit 2 }
            $projs = @()
            foreach ($r in $rows) { $p = ($r.Split('|')[0]).Trim(); if ($p) { $projs += $p } }
            $projs = $projs | Select-Object -Unique
            foreach ($p in $projs) {
                $a = Read-Tbl "MODATTR" "NAME = '$p'" @("NAME","STATUS")
                $st = ''
                if ($a -and $a.Count -gt 0) { $st = ($a[0].Split('|')[1]).Trim() }
                $lbl = if ($st -eq 'A') { 'ACTIVE' } else { 'INACTIVE' }
                Write-Output "PROJECT: $p|$st|$lbl"
            }
            Write-Output ("COUNT: " + $projs.Count)
            Write-Output "DONE"
        }

        'components' {
            $rows = Read-Tbl "MODSAP" "NAME = '$Enhancement'" @("NAME","TYP","MEMBER")
            if ($null -eq $rows) { Write-Output "ERROR: RFC_READ_TABLE failed on MODSAP"; exit 2 }
            $n = 0
            foreach ($r in $rows) {
                $c = $r.Split('|')
                $typ = $c[1].Trim(); $mem = $c[2].Trim()
                if ($mem) { Write-Output ("COMPONENT: $typ|$mem"); $n++ }
            }
            Write-Output ("COUNT: $n")
            Write-Output "DONE"
        }

        default {   # 'check' — the full picture
            $attr = Read-Tbl "MODATTR" "NAME = '$Project'" @("NAME","STATUS")
            if ($null -eq $attr) { Write-Output "ERROR: RFC_READ_TABLE failed on MODATTR"; exit 2 }
            if ($attr.Count -eq 0) {
                Write-Output "EXISTS: NO"
                # MODATTR header gone, but a TADIR directory entry can linger
                # after a delete (orphan) — a fresh create would silently
                # re-attach to that stale package. Surface it.
                $orph = Read-Tbl "TADIR" "PGMID = 'R3TR' AND OBJECT = 'CMOD' AND OBJ_NAME = '$Project'" @("DEVCLASS")
                if ($orph -and $orph.Count -gt 0) { Write-Output ("TADIR_ORPHAN: " + ($orph[0].Split('|')[0]).Trim()) }
                Write-Output "DONE"; break
            }
            $st = ($attr[0].Split('|')[1]).Trim()
            Write-Output "EXISTS: YES"
            Write-Output "STATUS: $st"
            Write-Output ("STATUS_LABEL: " + $(if ($st -eq 'A') { 'ACTIVE' } else { 'INACTIVE' }))

            $tad = Read-Tbl "TADIR" "PGMID = 'R3TR' AND OBJECT = 'CMOD' AND OBJ_NAME = '$Project'" @("DEVCLASS")
            if ($tad -and $tad.Count -gt 0) { Write-Output ("DEVCLASS: " + ($tad[0].Split('|')[0]).Trim()) }

            $txt = Read-Tbl "MODTEXT" "NAME = '$Project'" @("SPRSL","MODTEXT")
            if ($txt -and $txt.Count -gt 0) {
                foreach ($r in $txt) { $c = $r.Split('|'); Write-Output ("SHORTTEXT[" + $c[0].Trim() + "]: " + $c[1].Trim()) }
            }

            $act = Read-Tbl "MODACT" "NAME = '$Project'" @("NAME","MEMBER")
            $enh = @()
            if ($act) { foreach ($r in $act) { $m = ($r.Split('|')[1]).Trim(); if ($m) { $enh += $m } } }
            foreach ($e in $enh) { Write-Output "ASSIGNMENT: $e" }
            Write-Output ("COUNT: " + $enh.Count)
            Write-Output "DONE"
        }
    }
}
finally {
    Disconnect-SapRfc
}