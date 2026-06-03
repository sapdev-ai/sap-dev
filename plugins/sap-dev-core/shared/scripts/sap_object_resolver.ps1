# =============================================================================
# sap_object_resolver.ps1  -  Canonical SAP object identity resolver (NCo 3.1)
#
# Phase-0 foundation for the delivery-assurance skills (impact-analysis,
# transport-readiness, evidence-pack, enhancement-advisor). See
# contributing/phase0_delivery_assurance_spec.md  SecA.
#
# Given a user token - with or without a leading KIND keyword - returns the
# canonical object identity in the TADIR vocabulary:
#   PROGRAM ZMMR001 | ZMMR001 | TCODE ME21N | TR DEVK900123 | PACKAGE ZMM_CORE
#       -> { pgmid, object, obj_name, kind, package, exists, active,
#            system, client, resolved_via, confidence, note }
#
# Two usage modes
# ---------------
#   (1) Dot-source (preferred - caller already holds an RFC destination):
#         . "<...>\sap_object_resolver.ps1"
#         $obj  = Resolve-SapObject -Destination $g_dest -Token "PROGRAM ZMMR001"
#         $objs = Resolve-SapObject -Destination $g_dest -Token "TR DEVK900123" -Expand
#
#   (2) CLI (connects itself; creds fall back to the pinned connection profile
#       via Connect-SapRfc, so -Token alone is enough on a logged-in session):
#         C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe `
#           -ExecutionPolicy Bypass -File sap_object_resolver.ps1 -Token "TCODE ME21N"
#
# Run with 32-bit PowerShell (SAP NCo 3.1 is 32-bit).
#
# Tables read (all RFC_READ_TABLE-safe - none on sap_rfc_lib.ps1's forbidden
# list; REPOSRC is never touched):
#   TADIR  TFDIR  ENLFDIR  TSTC  E070  E071  TDEVC  DWINACTIV (active probe only)
#
# CLI output (parseable):
#   OBJECT: pgmid=R3TR object=PROG name=ZMMR001 kind=PROGRAM package=ZMM_CORE exists=true active= via=TADIR confidence=HIGH note=
#   STATUS: RESOLVED | NOT_FOUND | AMBIGUOUS | UNKNOWN_TYPE | RFC_ERROR
# Exit: 0 resolved - 1 not found - 2 ambiguous / unknown type - 3 RFC failure.
# =============================================================================

[CmdletBinding()]
param(
    # Endpoint / creds - all optional. Empty values fall back to the pinned
    # connection profile inside Connect-SapRfc (sap_rfc_lib.ps1 Phase 4.3).
    [string] $Server        = '',
    [string] $Sysnr         = '',
    [string] $MessageServer = '',
    [string] $LogonGroup    = '',
    [string] $SystemID      = '',
    [string] $Client        = '',
    [string] $User          = '',
    [string] $Password      = '',
    [string] $Language      = '',

    # What to resolve. Non-mandatory so dot-sourcing never prompts; the CLI
    # body validates presence.
    [string] $Token         = '',
    [string] $TypeHint      = '',
    [switch] $Expand,
    [switch] $ProbeActive
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# Dot-source the RFC lib only if the caller hasn't already.
if (-not (Get-Command Connect-SapRfc -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'sap_rfc_lib.ps1')
}

# -----------------------------------------------------------------------------
# KIND keyword -> TADIR object code. `special` routes the non-TADIR lookups
# (FMs live in TFDIR, tcodes in TSTC, packages in TDEVC, TRs in E070/E071).
# -----------------------------------------------------------------------------
function Get-SapKindMap {
    param([string] $Keyword)
    switch -Regex ($Keyword.ToUpper().Trim()) {
        '^(PROGRAM|PROG|REPORT|PGM|INCLUDE)$'                 { return @{ kind='PROGRAM';        object='PROG'; pgmid='R3TR'; special='' } }
        '^(CLASS|CLAS)$'                                      { return @{ kind='CLASS';          object='CLAS'; pgmid='R3TR'; special='' } }
        '^(INTERFACE|INTF)$'                                  { return @{ kind='INTERFACE';      object='INTF'; pgmid='R3TR'; special='' } }
        '^(FUNCTION-?GROUP|FUGR|FG)$'                         { return @{ kind='FUNCTION_GROUP'; object='FUGR'; pgmid='R3TR'; special='' } }
        '^(FM|FUNCTION|FUNCTION-?MODULE|FUNC)$'               { return @{ kind='FUNCTION_MODULE';object='FUNC'; pgmid='LIMU'; special='FM' } }
        '^(TABLE|TABL|STRUCTURE|STRUCT)$'                     { return @{ kind='TABLE';          object='TABL'; pgmid='R3TR'; special='' } }
        '^(VIEW)$'                                            { return @{ kind='VIEW';           object='VIEW'; pgmid='R3TR'; special='' } }
        '^(DATA-?ELEMENT|DATAELEMENT|DTEL)$'                  { return @{ kind='DATA_ELEMENT';   object='DTEL'; pgmid='R3TR'; special='' } }
        '^(DOMAIN|DOMA)$'                                     { return @{ kind='DOMAIN';         object='DOMA'; pgmid='R3TR'; special='' } }
        '^(TABLE-?TYPE|TABLETYPE|TTYP)$'                      { return @{ kind='TABLE_TYPE';     object='TTYP'; pgmid='R3TR'; special='' } }
        '^(TYPE-?GROUP|TYPEGROUP|TYPE)$'                      { return @{ kind='TYPE_GROUP';     object='TYPE'; pgmid='R3TR'; special='' } }
        '^(SEARCH-?HELP|SEARCHHELP|SHLP)$'                    { return @{ kind='SEARCH_HELP';    object='SHLP'; pgmid='R3TR'; special='' } }
        '^(LOCK-?OBJECT|LOCKOBJECT|ENQU)$'                    { return @{ kind='LOCK_OBJECT';    object='ENQU'; pgmid='R3TR'; special='' } }
        '^(MESSAGE-?CLASS|MESSAGECLASS|MSAG)$'                { return @{ kind='MESSAGE_CLASS';  object='MSAG'; pgmid='R3TR'; special='' } }
        '^(TCODE|TRANSACTION|TRAN)$'                          { return @{ kind='TCODE';          object='TRAN'; pgmid='R3TR'; special='TCODE' } }
        '^(PACKAGE|DEVC|DEVCLASS)$'                           { return @{ kind='PACKAGE';        object='DEVC'; pgmid='R3TR'; special='PACKAGE' } }
        '^(TR|TRANSPORT|REQUEST|CR)$'                         { return @{ kind='TR';             object='';     pgmid='';     special='TR' } }
        default                                               { return $null }
    }
}

# RFC_READ_TABLE caps each OPTIONS row at 72 chars and concatenates the rows
# (space-joined by the kernel) into the dynamic WHERE. A single
# `field = '<=40-char value>'` clause fits, but `A AND B AND C` as ONE row
# overflows for long object names - so split at AND boundaries, one clause per
# OPTIONS row, re-prefixing `AND` on continuations.
function Add-RfcWhereClauses {
    param($Fn, [string] $Where)
    if ([string]::IsNullOrWhiteSpace($Where)) { return }
    $parts = [regex]::Split($Where, '\s+AND\s+')
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $clause = if ($i -eq 0) { $parts[$i].Trim() } else { 'AND ' + $parts[$i].Trim() }
        Add-RfcOption $Fn $clause
    }
}

# -----------------------------------------------------------------------------
# RFC_READ_TABLE -> array of PSCustomObjects keyed by the requested field names.
# Returns $null on RFC failure (auth denied / S_TABU_DIS / transient), which is
# DISTINCT from an empty array (0 rows). Callers rely on this:
#   $null -eq $rows -> COULD_NOT_CHECK ;  $rows.Count -eq 0 -> not present.
# -----------------------------------------------------------------------------
function Read-SapTableRows {
    param(
        [Parameter(Mandatory)] $Destination,
        [Parameter(Mandatory)] [string] $Table,
        [string] $Where = '',
        [Parameter(Mandatory)] [string[]] $Fields,
        [int] $RowCount = 0
    )
    try {
        $fn = New-RfcReadTable -Destination $Destination -Table $Table
        if ($RowCount -gt 0) { [void]$fn.SetValue("ROWCOUNT", $RowCount) }
        Add-RfcWhereClauses -Fn $fn -Where $Where
        foreach ($f in $Fields) { Add-RfcField $fn $f }
        $fn.Invoke($Destination)
    } catch {
        return $null
    }
    $data = $fn.GetTable("DATA")
    $rows = @()
    for ($i = 0; $i -lt $data.RowCount; $i++) {
        $data.CurrentIndex = $i
        $cells = ("$($data.GetString('WA'))") -split '\|'
        $rec = [ordered]@{}
        for ($j = 0; $j -lt $Fields.Count; $j++) {
            $rec[$Fields[$j]] = if ($j -lt $cells.Count) { $cells[$j].Trim() } else { '' }
        }
        $rows += ,([pscustomobject]$rec)
    }
    # Comma operator preserves array semantics on return (see sap_dev_artefacts.ps1).
    return ,$rows
}

# System SID, resolved once per process via RFC_SYSTEM_INFO and cached.
$script:_Resolver_SysId = $null
function Get-SapResolverSysId {
    param($Destination)
    if ($null -ne $script:_Resolver_SysId) { return $script:_Resolver_SysId }
    try {
        $fn = $Destination.Repository.CreateFunction('RFC_SYSTEM_INFO')
        $fn.Invoke($Destination)
        $si = $fn.GetStructure('RFCSI_EXPORT')
        $script:_Resolver_SysId = "$($si.GetValue('RFCSYSID'))".Trim()
    } catch {
        $script:_Resolver_SysId = ''
    }
    return $script:_Resolver_SysId
}

# Build one canonical identity record.
function New-SapObjectRecord {
    param(
        [string] $Pgmid, [string] $Object, [string] $ObjName, [string] $Kind,
        [string] $Package = '', [object] $Exists = $true, [object] $Active = $null,
        [string] $System = '', [string] $Client = '', [string] $ResolvedVia = '',
        [string] $Confidence = 'HIGH', [string] $Note = ''
    )
    [pscustomobject]@{
        pgmid        = $Pgmid
        object       = $Object
        obj_name     = $ObjName
        kind         = $Kind
        package      = $Package
        exists       = $Exists
        active       = $Active
        system       = $System
        client       = $Client
        resolved_via = $ResolvedVia
        confidence   = $Confidence
        note         = $Note
    }
}

# Best-effort DWINACTIV probe. DWINACTIV uses its own workbench object-type
# codes (REPS/PROG/CLAS/...) that do NOT line up 1:1 with TADIR OBJECT, so this
# matches on OBJ_NAME only and is opt-in (-ProbeActive). null = not probed.
function Test-SapObjectActive {
    param($Destination, [string] $ObjName)
    $rows = Read-SapTableRows -Destination $Destination -Table 'DWINACTIV' `
                -Where "OBJ_NAME EQ '$ObjName'" -Fields @('OBJECT','OBJ_NAME')
    if ($null -eq $rows) { return $null }       # could not check
    return ($rows.Count -eq 0)                  # no inactive worklist row -> active
}

# Resolve the package (TADIR-DEVCLASS) for an (object, name) pair.
function Get-SapObjectPackage {
    param($Destination, [string] $Object, [string] $ObjName)
    $rows = Read-SapTableRows -Destination $Destination -Table 'TADIR' `
                -Where "PGMID = 'R3TR' AND OBJECT = '$Object' AND OBJ_NAME = '$ObjName'" `
                -Fields @('DEVCLASS') -RowCount 1
    if ($rows -and $rows.Count -gt 0) { return $rows[0].DEVCLASS }
    return ''
}

# =============================================================================
# Resolve-SapObject - the public entry point.
# =============================================================================
function Resolve-SapObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Destination,
        [Parameter(Mandatory)] [string] $Token,
        [string] $TypeHint = '',
        [switch] $Expand,
        [switch] $ProbeActive,
        [string] $System = '',
        [string] $Client = ''
    )

    if (-not $System) { $System = Get-SapResolverSysId -Destination $Destination }

    # --- Split optional leading KIND keyword from the name -------------------
    $raw = $Token.Trim() -replace '\s+', ' '
    $kw  = ''
    $name = $raw
    if ($raw -match '^(\S+)\s+(\S.*)$') {
        $maybeKind = $matches[1]
        if (Get-SapKindMap $maybeKind) { $kw = $maybeKind; $name = $matches[2].Trim() }
    }
    if (-not $kw -and $TypeHint) { $kw = $TypeHint }
    $name = $name.ToUpper()

    $map = if ($kw) { Get-SapKindMap $kw } else { $null }
    if ($kw -and -not $map) {
        return (New-SapObjectRecord -ObjName $name -Kind $kw -Exists $false `
                    -System $System -Client $Client -ResolvedVia 'UNKNOWN_TYPE' `
                    -Confidence 'LOW' -Note "unknown KIND keyword '$kw'")
    }

    $special = if ($map) { $map.special } else { '' }

    switch ($special) {
        # --- TRANSPORT REQUEST -----------------------------------------------
        'TR' {
            $e070 = Read-SapTableRows -Destination $Destination -Table 'E070' `
                        -Where "TRKORR EQ '$name'" -Fields @('TRKORR','TRFUNCTION','TRSTATUS') -RowCount 1
            if ($null -eq $e070) { return (New-SapObjectRecord -ObjName $name -Kind 'TR' -Exists $false -System $System -Client $Client -ResolvedVia 'RFC_ERROR' -Confidence 'LOW' -Note 'E070 read failed') }
            if ($e070.Count -eq 0) { return (New-SapObjectRecord -ObjName $name -Kind 'TR' -Exists $false -System $System -Client $Client -ResolvedVia 'E070' -Confidence 'HIGH' -Note 'no E070 row') }
            $trNote = "trfunction=$($e070[0].TRFUNCTION) trstatus=$($e070[0].TRSTATUS)"
            if (-not $Expand) {
                return (New-SapObjectRecord -ObjName $name -Kind 'TR' -Exists $true -System $System -Client $Client -ResolvedVia 'E070' -Confidence 'HIGH' -Note $trNote)
            }
            # A request's objects usually live in its TASKS, not the request
            # header - so union E071 across the request AND every child task
            # (E070 STRKORR = request). Without this, expanding a request that
            # has tasks returns 0 objects, a false-clean for downstream gates.
            $trkorrs = New-Object System.Collections.Generic.List[string]
            $trkorrs.Add($name)
            $tasks = Read-SapTableRows -Destination $Destination -Table 'E070' `
                        -Where "STRKORR EQ '$name'" -Fields @('TRKORR')
            if ($tasks) { foreach ($t in $tasks) { if ("$($t.TRKORR)") { $trkorrs.Add("$($t.TRKORR)") } } }

            $out = @()
            $seen = @{}
            foreach ($tk in ($trkorrs | Select-Object -Unique)) {
                $e071 = Read-SapTableRows -Destination $Destination -Table 'E071' `
                            -Where "TRKORR EQ '$tk'" -Fields @('PGMID','OBJECT','OBJ_NAME')
                if ($null -eq $e071) { continue }
                foreach ($r in $e071) {
                    $key = "$($r.PGMID)|$($r.OBJECT)|$($r.OBJ_NAME)"
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $pkg = Get-SapObjectPackage -Destination $Destination -Object $r.OBJECT -ObjName $r.OBJ_NAME
                    $out += (New-SapObjectRecord -Pgmid $r.PGMID -Object $r.OBJECT -ObjName $r.OBJ_NAME -Kind $r.OBJECT `
                                -Package $pkg -Exists $true -System $System -Client $Client -ResolvedVia 'E071' -Confidence 'HIGH' -Note "in $name")
                }
            }
            return ,$out
        }

        # --- TRANSACTION CODE -------------------------------------------------
        'TCODE' {
            $tstc = Read-SapTableRows -Destination $Destination -Table 'TSTC' `
                        -Where "TCODE EQ '$name'" -Fields @('TCODE','PGMNA') -RowCount 1
            if ($null -eq $tstc) { return (New-SapObjectRecord -Object 'TRAN' -ObjName $name -Kind 'TCODE' -Exists $false -System $System -Client $Client -ResolvedVia 'RFC_ERROR' -Confidence 'LOW' -Note 'TSTC read failed') }
            if ($tstc.Count -eq 0) { return (New-SapObjectRecord -Object 'TRAN' -ObjName $name -Kind 'TCODE' -Exists $false -System $System -Client $Client -ResolvedVia 'TSTC' -Confidence 'HIGH' -Note 'no TSTC row') }
            $pgmna = $tstc[0].PGMNA
            $out = @()
            $tranPkg = Get-SapObjectPackage -Destination $Destination -Object 'TRAN' -ObjName $name
            $out += (New-SapObjectRecord -Pgmid 'R3TR' -Object 'TRAN' -ObjName $name -Kind 'TCODE' -Package $tranPkg `
                        -Exists $true -System $System -Client $Client -ResolvedVia 'TSTC' -Confidence 'HIGH' -Note "program=$pgmna")
            if ($pgmna) {
                $progPkg = Get-SapObjectPackage -Destination $Destination -Object 'PROG' -ObjName $pgmna
                $out += (New-SapObjectRecord -Pgmid 'R3TR' -Object 'PROG' -ObjName $pgmna -Kind 'PROGRAM' -Package $progPkg `
                            -Exists $true -System $System -Client $Client -ResolvedVia 'TSTC' -Confidence 'HIGH' -Note "behind tcode $name")
            }
            return ,$out
        }

        # --- PACKAGE ----------------------------------------------------------
        'PACKAGE' {
            $tdevc = Read-SapTableRows -Destination $Destination -Table 'TDEVC' `
                        -Where "DEVCLASS EQ '$name'" -Fields @('DEVCLASS','PARENTCL') -RowCount 1
            if ($null -eq $tdevc) { return (New-SapObjectRecord -Object 'DEVC' -ObjName $name -Kind 'PACKAGE' -Exists $false -System $System -Client $Client -ResolvedVia 'RFC_ERROR' -Confidence 'LOW' -Note 'TDEVC read failed') }
            if ($tdevc.Count -eq 0) { return (New-SapObjectRecord -Object 'DEVC' -ObjName $name -Kind 'PACKAGE' -Exists $false -System $System -Client $Client -ResolvedVia 'TDEVC' -Confidence 'HIGH' -Note 'no TDEVC row') }
            if (-not $Expand) {
                return (New-SapObjectRecord -Pgmid 'R3TR' -Object 'DEVC' -ObjName $name -Kind 'PACKAGE' -Package $name `
                            -Exists $true -System $System -Client $Client -ResolvedVia 'TDEVC' -Confidence 'HIGH' -Note "parent=$($tdevc[0].PARENTCL)")
            }
            $children = Read-SapTableRows -Destination $Destination -Table 'TADIR' `
                            -Where "DEVCLASS EQ '$name'" -Fields @('PGMID','OBJECT','OBJ_NAME')
            if ($null -eq $children) { return (New-SapObjectRecord -Object 'DEVC' -ObjName $name -Kind 'PACKAGE' -Exists $true -System $System -Client $Client -ResolvedVia 'TADIR' -Confidence 'LOW' -Note 'TADIR child read failed') }
            $out = @()
            foreach ($r in $children) {
                $out += (New-SapObjectRecord -Pgmid $r.PGMID -Object $r.OBJECT -ObjName $r.OBJ_NAME -Kind $r.OBJECT `
                            -Package $name -Exists $true -System $System -Client $Client -ResolvedVia 'TADIR' -Confidence 'HIGH' -Note "in package $name")
            }
            return ,$out
        }

        # --- FUNCTION MODULE (not a TADIR object) -----------------------------
        'FM' {
            $rec = Resolve-SapFunctionModule -Destination $Destination -Name $name -System $System -Client $Client
            if ($ProbeActive -and $rec.exists) { $rec.active = Test-SapObjectActive -Destination $Destination -ObjName $name }
            return $rec
        }

        # --- everything else: a TADIR object ----------------------------------
        default {
            if ($map) {
                # KIND given -> confirm that exact (OBJECT, name) exists.
                $rows = Read-SapTableRows -Destination $Destination -Table 'TADIR' `
                            -Where "PGMID = 'R3TR' AND OBJECT = '$($map.object)' AND OBJ_NAME = '$name'" `
                            -Fields @('DEVCLASS') -RowCount 1
                if ($null -eq $rows) { return (New-SapObjectRecord -Object $map.object -ObjName $name -Kind $map.kind -Exists $false -System $System -Client $Client -ResolvedVia 'RFC_ERROR' -Confidence 'LOW' -Note 'TADIR read failed') }
                if ($rows.Count -eq 0) {
                    # Not in TADIR under that type - it may still be an FM typed wrong.
                    return (New-SapObjectRecord -Object $map.object -ObjName $name -Kind $map.kind -Exists $false -System $System -Client $Client -ResolvedVia 'TADIR' -Confidence 'HIGH' -Note 'no TADIR row for that type')
                }
                $rec = New-SapObjectRecord -Pgmid 'R3TR' -Object $map.object -ObjName $name -Kind $map.kind `
                            -Package $rows[0].DEVCLASS -Exists $true -System $System -Client $Client -ResolvedVia 'TADIR' -Confidence 'HIGH'
                if ($ProbeActive) { $rec.active = Test-SapObjectActive -Destination $Destination -ObjName $name }
                return $rec
            }

            # No KIND - disambiguate by TADIR, then fall back to FM lookup.
            $rows = Read-SapTableRows -Destination $Destination -Table 'TADIR' `
                        -Where "PGMID = 'R3TR' AND OBJ_NAME = '$name'" -Fields @('PGMID','OBJECT','OBJ_NAME','DEVCLASS')
            if ($null -eq $rows) { return (New-SapObjectRecord -ObjName $name -Kind '' -Exists $false -System $System -Client $Client -ResolvedVia 'RFC_ERROR' -Confidence 'LOW' -Note 'TADIR read failed') }

            if ($rows.Count -eq 1) {
                $kmap = Get-SapKindMapByObject $rows[0].OBJECT
                $rec = New-SapObjectRecord -Pgmid 'R3TR' -Object $rows[0].OBJECT -ObjName $name -Kind $kmap `
                            -Package $rows[0].DEVCLASS -Exists $true -System $System -Client $Client -ResolvedVia 'TADIR' -Confidence 'HIGH'
                if ($ProbeActive) { $rec.active = Test-SapObjectActive -Destination $Destination -ObjName $name }
                return $rec
            }
            if ($rows.Count -gt 1) {
                # Ambiguous - same name across object types. Use TypeHint if it picks one.
                if ($TypeHint) {
                    $hint = Get-SapKindMap $TypeHint
                    if ($hint) {
                        $pick = $rows | Where-Object { $_.OBJECT -eq $hint.object } | Select-Object -First 1
                        if ($pick) {
                            return (New-SapObjectRecord -Pgmid 'R3TR' -Object $pick.OBJECT -ObjName $name -Kind $hint.kind `
                                        -Package $pick.DEVCLASS -Exists $true -System $System -Client $Client -ResolvedVia 'TYPE_HINT' -Confidence 'MEDIUM' -Note 'disambiguated by TypeHint')
                        }
                    }
                }
                $cands = ($rows | ForEach-Object { $_.OBJECT }) -join ','
                $rec = New-SapObjectRecord -ObjName $name -Kind '' -Exists $true -System $System -Client $Client -ResolvedVia 'AMBIGUOUS' -Confidence 'LOW' -Note "candidates=$cands"
                # Attach candidates so a CLI / caller can enumerate them.
                $rec | Add-Member -NotePropertyName candidates -NotePropertyValue $rows
                return $rec
            }

            # Zero TADIR rows -> maybe a function module.
            $fm = Resolve-SapFunctionModule -Destination $Destination -Name $name -System $System -Client $Client
            if ($fm.exists) {
                if ($ProbeActive) { $fm.active = Test-SapObjectActive -Destination $Destination -ObjName $name }
                return $fm
            }
            return (New-SapObjectRecord -ObjName $name -Kind '' -Exists $false -System $System -Client $Client -ResolvedVia 'TADIR' -Confidence 'HIGH' -Note 'not found in TADIR or TFDIR')
        }
    }
}

# TADIR OBJECT code -> user-facing kind (inverse of Get-SapKindMap, best-effort).
function Get-SapKindMapByObject {
    param([string] $Object)
    switch ($Object.ToUpper()) {
        'PROG' { 'PROGRAM' }        'CLAS' { 'CLASS' }          'INTF' { 'INTERFACE' }
        'FUGR' { 'FUNCTION_GROUP' } 'TABL' { 'TABLE' }          'VIEW' { 'VIEW' }
        'DTEL' { 'DATA_ELEMENT' }   'DOMA' { 'DOMAIN' }         'TTYP' { 'TABLE_TYPE' }
        'TYPE' { 'TYPE_GROUP' }     'SHLP' { 'SEARCH_HELP' }    'ENQU' { 'LOCK_OBJECT' }
        'MSAG' { 'MESSAGE_CLASS' }  'TRAN' { 'TCODE' }          'DEVC' { 'PACKAGE' }
        default { $Object.ToUpper() }
    }
}

# FM resolution: TFDIR (FUNCNAME -> PNAME/FMODE) + ENLFDIR (FUNCNAME -> AREA),
# package via the function group's TADIR (R3TR FUGR <AREA>).
function Resolve-SapFunctionModule {
    param($Destination, [string] $Name, [string] $System, [string] $Client)
    $tfdir = Read-SapTableRows -Destination $Destination -Table 'TFDIR' `
                -Where "FUNCNAME EQ '$Name'" -Fields @('FUNCNAME','PNAME','FMODE') -RowCount 1
    if ($null -eq $tfdir) { return (New-SapObjectRecord -Object 'FUNC' -ObjName $Name -Kind 'FUNCTION_MODULE' -Exists $false -System $System -Client $Client -ResolvedVia 'RFC_ERROR' -Confidence 'LOW' -Note 'TFDIR read failed') }
    if ($tfdir.Count -eq 0) { return (New-SapObjectRecord -Object 'FUNC' -ObjName $Name -Kind 'FUNCTION_MODULE' -Exists $false -System $System -Client $Client -ResolvedVia 'TFDIR' -Confidence 'HIGH' -Note 'no TFDIR row') }

    $area = ''
    $enl = Read-SapTableRows -Destination $Destination -Table 'ENLFDIR' `
                -Where "FUNCNAME EQ '$Name'" -Fields @('FUNCNAME','AREA') -RowCount 1
    if ($enl -and $enl.Count -gt 0) { $area = $enl[0].AREA }

    $pkg = if ($area) { Get-SapObjectPackage -Destination $Destination -Object 'FUGR' -ObjName $area } else { '' }
    $fmode = $tfdir[0].FMODE
    $note = "fugr=$area fmode=$fmode"
    if ($fmode -eq 'R') { $note += ' (RFC-enabled)' }
    return (New-SapObjectRecord -Pgmid 'LIMU' -Object 'FUNC' -ObjName $Name -Kind 'FUNCTION_MODULE' `
                -Package $pkg -Exists $true -System $System -Client $Client -ResolvedVia 'TFDIR' -Confidence 'HIGH' -Note $note)
}

# =============================================================================
# CLI body - skipped when the file is dot-sourced.
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    # Best-effort structured logging.
    $logRun = $null
    $logLib = Join-Path $PSScriptRoot 'sap_log_lib.ps1'
    if (Test-Path $logLib) {
        try { . $logLib; $logRun = Start-SapLog -Skill 'sap-object-resolver' -Params @{ token = $Token; type_hint = $TypeHint; expand = [bool]$Expand } } catch { $logRun = $null }
    }
    function Stop-ResolverLog([string]$status, [int]$code, [string]$errClass = '') {
        if ($null -ne $logRun) {
            try { if ($errClass) { Stop-SapLog -Run $logRun -Status $status -ExitCode $code -ErrorClass $errClass } else { Stop-SapLog -Run $logRun -Status $status -ExitCode $code } } catch {}
        }
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Host "ERROR: -Token is required (e.g. -Token 'PROGRAM ZMMR001' or -Token 'TCODE ME21N')."
        Write-Host "STATUS: UNKNOWN_TYPE"
        Stop-ResolverLog 'FAILED' 2 'NO_TOKEN'
        exit 2
    }

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $User -Password $Password -Language $Language `
                             -DestName "SAPDEV_RESOLVE"
    if (-not $g_dest) {
        Write-Host "STATUS: RFC_ERROR"
        Stop-ResolverLog 'FAILED' 3 'RFC_CONNECT_FAILED'
        exit 3
    }

    try {
        $effClient = if ($Client) { $Client } else { "$g_sapClient" }
        $result = Resolve-SapObject -Destination $g_dest -Token $Token -TypeHint $TypeHint -Expand:$Expand -ProbeActive:$ProbeActive -Client $effClient

        $records = @($result)
        foreach ($r in $records) {
            $activeStr = if ($null -eq $r.active) { '' } else { "$($r.active)".ToLower() }
            Write-Host ("OBJECT: pgmid={0} object={1} name={2} kind={3} package={4} exists={5} active={6} via={7} confidence={8} note={9}" -f `
                $r.pgmid, $r.object, $r.obj_name, $r.kind, $r.package, "$($r.exists)".ToLower(), $activeStr, $r.resolved_via, $r.confidence, $r.note)
        }

        # Determine STATUS + exit code from the (first) record.
        $first = $records[0]
        if ($first.resolved_via -eq 'RFC_ERROR') {
            Write-Host "STATUS: RFC_ERROR"; Stop-ResolverLog 'FAILED' 3 'RFC_READ_FAILED'; Disconnect-SapRfc; exit 3
        }
        if ($first.resolved_via -eq 'AMBIGUOUS') {
            Write-Host "STATUS: AMBIGUOUS"; Stop-ResolverLog 'FAILED' 2 'AMBIGUOUS'; Disconnect-SapRfc; exit 2
        }
        if ($first.resolved_via -eq 'UNKNOWN_TYPE') {
            Write-Host "STATUS: UNKNOWN_TYPE"; Stop-ResolverLog 'FAILED' 2 'UNKNOWN_TYPE'; Disconnect-SapRfc; exit 2
        }
        # exists=false on a single record -> NOT_FOUND.
        if ($records.Count -eq 1 -and -not $first.exists) {
            Write-Host "STATUS: NOT_FOUND"; Stop-ResolverLog 'EXISTED' 1; Disconnect-SapRfc; exit 1
        }
        Write-Host "STATUS: RESOLVED"
        Stop-ResolverLog 'SUCCESS' 0
        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        Write-Host "STATUS: RFC_ERROR"
        Stop-ResolverLog 'FAILED' 3 'RESOLVER_EXCEPTION'
        Disconnect-SapRfc
        exit 3
    }
}
