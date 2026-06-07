# =============================================================================
# sap_error_hints_lib.ps1  -  Engine for the frequently_errors feedback loop
#
# Dot-sourceable FUNCTIONS ONLY (no top-level param() -- safe to dot-source;
# see feedback_dot_source_param_clobber). The thin CLI lives in
# sap_error_hints.ps1 which dot-sources this file.
#
# The frequently_errors loop captures recurring FM / class-method / codegen
# mistakes + remedies so sap-gen-abap can steer away from them, and so deploy
# (se38/se37/se24) + ATC findings that relate to a FM or METHOD are recorded
# back to a TEAM-SHAREABLE store (NOT MEMORY files).
#
# THREE TIERS, highest precedence first (union otherwise; MUTE suppresses):
#   1. {custom_url}\frequently_errors.tsv          hand-authored team override
#   2. {custom_url}\frequently_errors\<OBJECT>.tsv per-object, auto-recorded + curated
#   3. <shared>\tables\frequently_errors.tsv       plugin seed (lowest)
#
# This file is ASCII-only (PowerShell 5.1 reads a BOM-less file as the host
# ANSI codepage; ASCII bytes are codepage-invariant). All TSV writes are
# UTF-8 WITHOUT BOM with REAL TAB separators.
# =============================================================================

# UTF-8 without BOM for every write (a BOM glues onto the first column when a
# downstream reader opens the file as plain ASCII).
$script:SapErrHint_Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Canonical column order. TIER 3 (seed) + TIER 1 (override) use the first 11.
# TIER 2 (per-object, auto-recorded) appends the 5 audit columns. Readers are
# HEADER-AWARE (map by column name), so a file may carry any subset/superset.
$script:SapErrHint_CoreCols  = @(
    'OBJECT_TYPE','OBJECT_NAME','CONTEXT','ERROR_CLASS','RELEASE',
    'WRONG_PATTERN','CORRECT_PATTERN','SEVERITY','RULE_REF','STATUS','NOTE'
)
$script:SapErrHint_AuditCols = @(
    'SOURCE','OCCURRENCES','FIRST_SEEN','LAST_SEEN','EXAMPLE'
)
$script:SapErrHint_AllCols   = $script:SapErrHint_CoreCols + $script:SapErrHint_AuditCols

function Get-SapErrHintAllColumns { return $script:SapErrHint_AllCols }

# --- TSV cell hygiene --------------------------------------------------------
# A field value must never contain a TAB or newline (it would break the row).
function ConvertTo-SapErrHintCell([string]$v) {
    if ($null -eq $v) { return '' }
    $v = $v -replace "`r", ' '
    $v = $v -replace "`n", ' '
    $v = $v -replace "`t", ' '
    return $v.Trim()
}

# --- Read a frequently_errors TSV, header-aware -----------------------------
# Returns an array of [ordered] hashtables keyed by UPPER-CASE column name.
# Skips blank lines and '#' comment lines. Tolerates extra/missing columns.
function Read-SapErrHintTsv([string]$path) {
    # NOTE: rows are OrderedDictionary objects. NEVER accumulate them with `+=`
    # on an array -- PowerShell either enumerates the dict into DictionaryEntry
    # items or does a hashtable-merge (dup-key throw). Use a List + .Add(), and
    # return with the unary comma so a 0/1-element result is never unwrapped.
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return ,$rows.ToArray() }
    $lines = Get-Content -LiteralPath $path -Encoding UTF8
    $header = $null
    foreach ($line in $lines) {
        if ($null -eq $line) { continue }
        $t = $line.Trim()
        if ($t -eq '') { continue }
        if ($t.StartsWith('#')) { continue }
        $cols = $line -split "`t"
        if ($null -eq $header) {
            $header = @()
            foreach ($c in $cols) { $header += $c.Trim().ToUpper() }
            continue
        }
        $row = [ordered]@{}
        for ($i = 0; $i -lt $header.Count; $i++) {
            $name = $header[$i]
            if ($name -eq '') { continue }
            if ($row.Contains($name)) { continue }   # tolerate a duplicate header column
            $val = ''
            if ($i -lt $cols.Count) { $val = $cols[$i] }
            $row[$name] = $val
        }
        # Ignore rows with no OBJECT_TYPE (malformed)
        if (-not $row.Contains('OBJECT_TYPE') -or ([string]$row['OBJECT_TYPE']).Trim() -eq '') { continue }
        $rows.Add($row)
    }
    return ,$rows.ToArray()
}

# --- Merge key for dedup / precedence ---------------------------------------
function Get-SapErrHintKey($row) {
    $tp = ([string]$row['OBJECT_TYPE']).Trim().ToUpper()
    $nm = ([string]$row['OBJECT_NAME']).Trim().ToUpper()
    $cx = ([string]$row['CONTEXT']).Trim().ToUpper()
    $cl = ([string]$row['ERROR_CLASS']).Trim().ToUpper()
    return ($tp + '|' + $nm + '|' + $cx + '|' + $cl)
}

# --- Sanitize an object name into a safe file stem --------------------------
# FM names, class names, namespaced /NS/FM, and CL=>METH all collapse to a
# filesystem-safe stem. The method (for class methods) lives in the CONTEXT
# column, NOT the filename -- one file per FM or per CLASS.
function Get-SapErrHintObjectStem([string]$objName) {
    $n = ([string]$objName).Trim().ToUpper()
    if ($n -eq '' -or $n -eq '*' -or $n -eq '?') { return '_UNATTRIBUTED' }
    # If a method token leaked in (CL=>METH / CL->METH), keep only the class part
    foreach ($sep in @('=>','->')) {
        $idx = $n.IndexOf($sep)
        if ($idx -gt 0) { $n = $n.Substring(0, $idx) }
    }
    $n = $n -replace '[^A-Z0-9_]', '_'
    $n = $n.Trim('_')
    if ($n -eq '') { return '_UNATTRIBUTED' }
    return $n
}

function Get-SapErrHintDir([string]$customUrl) {
    return (Join-Path $customUrl 'frequently_errors')
}

function Get-SapErrHintObjectFile([string]$customUrl, [string]$objName) {
    $dir  = Get-SapErrHintDir $customUrl
    $stem = Get-SapErrHintObjectStem $objName
    return (Join-Path $dir ($stem + '.tsv'))
}

# --- Today as YYYY-MM-DD (ISO) ----------------------------------------------
function Get-SapErrHintToday {
    return (Get-Date).ToString('yyyy-MM-dd')
}

# ============================================================================
# READ PATH  --  Resolve-SapErrorHints
# Merge the three tiers for the objects this spec references, apply precedence,
# filter to injectable statuses, return the matched rows for Step 1.5f.
# ============================================================================
function Resolve-SapErrorHints {
    param(
        [string[]] $Objects = @(),         # FM / class / auth-object names the spec uses
        [string]   $CustomUrl = '',
        [string]   $SharedTablesDir = '',  # ...\sap-dev-core\shared\tables
        [string[]] $InjectStatuses = @('CONFIRMED')
    )

    $wanted = @{}
    foreach ($o in $Objects) {
        $u = ([string]$o).Trim().ToUpper()
        if ($u -ne '') { $wanted[$u] = $true }
    }
    $injectUp = @{}
    foreach ($s in $InjectStatuses) { $injectUp[([string]$s).Trim().ToUpper()] = $true }

    # merged keyed by Get-SapErrHintKey; later tier overwrites earlier.
    $merged = [ordered]@{}

    function _Apply($rows) {
        foreach ($r in $rows) {
            $key = Get-SapErrHintKey $r
            $merged[$key] = $r
        }
    }

    # TIER 3 (seed) -- lowest
    if ($SharedTablesDir) {
        _Apply (Read-SapErrHintTsv (Join-Path $SharedTablesDir 'frequently_errors.tsv'))
    }
    # TIER 2 (per-object) -- only the files for objects we care about, plus the
    # general '_UNATTRIBUTED' and any STMT-wide files are NOT auto-loaded here
    # (general rules live in tier1/tier3). Load one file per requested object.
    if ($CustomUrl) {
        $dir = Get-SapErrHintDir $CustomUrl
        if (Test-Path -LiteralPath $dir) {
            $stems = @{}
            foreach ($o in $wanted.Keys) { $stems[(Get-SapErrHintObjectStem $o)] = $true }
            foreach ($stem in $stems.Keys) {
                $f = Join-Path $dir ($stem + '.tsv')
                _Apply (Read-SapErrHintTsv $f)
            }
        }
        # TIER 1 (single override file) -- highest
        _Apply (Read-SapErrHintTsv (Join-Path $CustomUrl 'frequently_errors.tsv'))
    }

    # Filter: status injectable + not MUTE; and object relevant to this spec.
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($key in $merged.Keys) {
        $r = $merged[$key]
        $status = ([string]$r['STATUS']).Trim().ToUpper()
        if ($status -eq 'MUTE') { continue }
        if ($status -eq '') { $status = 'CONFIRMED' }   # seed rows may omit
        if (-not $injectUp.ContainsKey($status)) { continue }

        $tp = ([string]$r['OBJECT_TYPE']).Trim().ToUpper()
        $nm = ([string]$r['OBJECT_NAME']).Trim().ToUpper()
        $relevant = $false
        if ($nm -eq '*' -or $nm -eq '') { $relevant = $true }        # general STMT rules
        elseif ($tp -eq 'AUTHZ') { $relevant = $true }                # authz hints are cheap + relevant
        elseif ($wanted.ContainsKey($nm)) { $relevant = $true }       # FM / class the spec uses
        if (-not $relevant) { continue }
        $out.Add($r)
    }
    return ,$out.ToArray()
}

# --- Write the resolved hints to the Step-1.5f result file -------------------
function Write-SapErrHintResult {
    param([object[]] $Rows, [string] $ResultFile)
    $cols = $script:SapErrHint_CoreCols
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(($cols -join "`t"))
    foreach ($r in $Rows) {
        $cells = @()
        foreach ($c in $cols) {
            $v = ''
            if ($r.Contains($c)) { $v = [string]$r[$c] }
            $cells += (ConvertTo-SapErrHintCell $v)
        }
        [void]$sb.AppendLine(($cells -join "`t"))
    }
    [System.IO.File]::WriteAllText($ResultFile, $sb.ToString(), $script:SapErrHint_Utf8NoBom)
    return $Rows.Count
}

# ============================================================================
# WRITE PATH  --  Add-SapErrorHint
# Upsert one observed error into the TIER-2 per-object file as CANDIDATE.
# Dedup by key: existing -> bump OCCURRENCES + LAST_SEEN (never downgrade
# STATUS); new -> append with STATUS=CANDIDATE, OCCURRENCES=1.
# Returns 'ADDED' | 'UPDATED'.
# ============================================================================
function Add-SapErrorHint {
    param(
        [string] $CustomUrl,
        [string] $ObjectType,        # FM | METHOD | BAPI | STMT | AUTHZ
        [string] $ObjectName,        # FM / class name, '?' if unattributed
        [string] $Context = '',      # parameter / method / clause
        [string] $ErrorClass = '',   # short trap code
        [string] $Message = '',      # raw error / finding text (becomes WRONG_PATTERN)
        [string] $Source = '',       # SE38 | SE37 | SE24 | ATC | USER
        [string] $Program = '',      # example object where it occurred
        [string] $Line = '',
        [string] $Severity = '',     # ACTIVATION | ATC_P1.. | RUNTIME
        [string] $Release = 'ALL'
    )
    if (-not $CustomUrl) { return 'SKIPPED' }
    $dir = Get-SapErrHintDir $CustomUrl
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $file = Get-SapErrHintObjectFile $CustomUrl $ObjectName
    # Use a List[object] -- see the +=/dict trap note in Read-SapErrHintTsv.
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in (Read-SapErrHintTsv $file)) { $rows.Add($r) }

    $newRow = [ordered]@{
        OBJECT_TYPE     = (ConvertTo-SapErrHintCell $ObjectType).ToUpper()
        OBJECT_NAME     = (ConvertTo-SapErrHintCell $ObjectName).ToUpper()
        CONTEXT         = (ConvertTo-SapErrHintCell $Context)
        ERROR_CLASS     = (ConvertTo-SapErrHintCell $ErrorClass).ToUpper()
        RELEASE         = (ConvertTo-SapErrHintCell $Release)
        WRONG_PATTERN   = (ConvertTo-SapErrHintCell $Message)
        CORRECT_PATTERN = ''      # to be filled by a human curator
        SEVERITY        = (ConvertTo-SapErrHintCell $Severity).ToUpper()
        RULE_REF        = ''
        STATUS          = 'CANDIDATE'
        NOTE            = ''
        SOURCE          = (ConvertTo-SapErrHintCell $Source).ToUpper()
        OCCURRENCES     = '1'
        FIRST_SEEN      = (Get-SapErrHintToday)
        LAST_SEEN       = (Get-SapErrHintToday)
        EXAMPLE         = (ConvertTo-SapErrHintCell ($Program + (&{ if ($Line) { ':' + $Line } else { '' } })))
    }
    $newKey = Get-SapErrHintKey $newRow

    $verdict = 'ADDED'
    $found = $false
    foreach ($r in $rows) {
        if ((Get-SapErrHintKey $r) -eq $newKey) {
            $found = $true
            $occ = 0
            if ($r.Contains('OCCURRENCES')) { [int]::TryParse(([string]$r['OCCURRENCES']), [ref]$occ) | Out-Null }
            if ($occ -lt 1) { $occ = 1 }
            $r['OCCURRENCES'] = [string]($occ + 1)
            $r['LAST_SEEN']   = Get-SapErrHintToday
            if (-not $r.Contains('SOURCE') -or ([string]$r['SOURCE']).Trim() -eq '') { $r['SOURCE'] = $newRow['SOURCE'] }
            $verdict = 'UPDATED'
            break
        }
    }
    if (-not $found) { $rows.Add($newRow) }

    # Write back with the full audit schema (union of all keys seen + audit cols).
    $cols = $script:SapErrHint_AllCols
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(($cols -join "`t"))
    foreach ($r in $rows) {
        $cells = @()
        foreach ($c in $cols) {
            $v = ''
            if ($r.Contains($c)) { $v = [string]$r[$c] }
            $cells += (ConvertTo-SapErrHintCell $v)
        }
        [void]$sb.AppendLine(($cells -join "`t"))
    }
    [System.IO.File]::WriteAllText($file, $sb.ToString(), $script:SapErrHint_Utf8NoBom)
    return $verdict
}

# ============================================================================
# ATTRIBUTION  --  Get-SapErrorAttribution
# Map a deploy/ATC error to a specific FM or class METHOD. The primary,
# LOCALE-INDEPENDENT signal is the source line number -> the enclosing
# CALL FUNCTION '<FM>' / method-call block. Secondary: scan the error TEXT
# for any UPPERCASE token that matches a known object (object names are not
# translated). Falls back to OBJECT_NAME='?' (the _UNATTRIBUTED bucket).
# Returns @{ ObjectType; ObjectName; Context }.
# ============================================================================
function Get-SapErrorAttribution {
    param(
        [string]   $SourceFile = '',
        [int]      $Line = 0,
        [string]   $Text = '',
        [string[]] $KnownObjects = @()
    )
    $result = [ordered]@{ ObjectType = '?'; ObjectName = '?'; Context = '' }

    # --- Primary: line -> enclosing call in the source ----------------------
    if ($SourceFile -and (Test-Path -LiteralPath $SourceFile) -and $Line -gt 0) {
        $src = Get-Content -LiteralPath $SourceFile -Encoding UTF8
        if ($Line -le $src.Count) {
            for ($i = $Line - 1; $i -ge 0; $i--) {
                $s = $src[$i]
                # CALL FUNCTION 'X'
                $m = [regex]::Match($s, "(?i)CALL\s+FUNCTION\s+'([^']+)'")
                if ($m.Success) {
                    $result.ObjectType = 'FM'
                    $result.ObjectName = $m.Groups[1].Value.ToUpper()
                    return $result
                }
                # functional method call:  obj=>meth(   obj->meth(   class=>meth(
                $m = [regex]::Match($s, "(?i)([A-Z_/][A-Z0-9_/]*)\s*(=>|->)\s*([A-Z_][A-Z0-9_]*)\s*\(")
                if ($m.Success) {
                    $result.ObjectType = 'METHOD'
                    $result.ObjectName = $m.Groups[1].Value.ToUpper()
                    $result.Context    = $m.Groups[3].Value.ToUpper()
                    return $result
                }
                # CALL METHOD obj->meth / class=>meth
                $m = [regex]::Match($s, "(?i)CALL\s+METHOD\s+([A-Z_/][A-Z0-9_/]*)\s*(=>|->)\s*([A-Z_][A-Z0-9_]*)")
                if ($m.Success) {
                    $result.ObjectType = 'METHOD'
                    $result.ObjectName = $m.Groups[1].Value.ToUpper()
                    $result.Context    = $m.Groups[3].Value.ToUpper()
                    return $result
                }
                # Stop scanning back at a statement-terminating period on a code
                # line, so we don't bleed into the previous statement's call.
                if ($s -match '\.\s*(".*)?$' -and $s.Trim() -ne '' -and -not ($s.Trim().StartsWith('*'))) {
                    # keep scanning a little; CALL FUNCTION spans many lines, so
                    # only break if we have moved >40 lines up (safety bound).
                }
                if (($Line - 1 - $i) -gt 40) { break }
            }
        }
    }

    # --- Secondary: known-object token in the (possibly localized) text -----
    if ($Text -and $KnownObjects.Count -gt 0) {
        $upText = $Text.ToUpper()
        foreach ($o in $KnownObjects) {
            $ou = ([string]$o).Trim().ToUpper()
            if ($ou -eq '') { continue }
            if ($upText -match ('(^|[^A-Z0-9_])' + [regex]::Escape($ou) + '([^A-Z0-9_]|$)')) {
                # Heuristic kind: BAPI_*/RFC_*/Z*_ that look like FMs vs CL_* classes
                if ($ou -like 'CL_*' -or $ou -like 'IF_*' -or $ou -like 'ZCL_*' -or $ou -like 'ZIF_*') {
                    $result.ObjectType = 'METHOD'
                } else {
                    $result.ObjectType = 'FM'
                }
                $result.ObjectName = $ou
                return $result
            }
        }
    }

    return $result
}
