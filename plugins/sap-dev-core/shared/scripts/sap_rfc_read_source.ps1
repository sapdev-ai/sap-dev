# =============================================================================
# sap_rfc_read_source.ps1  -  Read ABAP source over RFC (RPY, not REPOSRC)
# -----------------------------------------------------------------------------
# Reads ABAP source headlessly via the sanctioned RPY function modules, never
# via RFC_READ_TABLE on REPOSRC (LRAW -> ASSIGN CASTING; blocked by
# Assert-RfcReadTableAllowed in sap_rfc_lib.ps1). Shared by /sap-explain-object
# (include tree + headless source) and /sap-compare (cross-system source).
#
# DOT-SOURCE this file, then call the exposed functions. Do NOT run it as a
# param() CLI script: a dot-sourced param() block would clobber the caller's
# variables (see MEMORY: "PS dot-source param clobber"). This file is a pure
# function library and sets no script-scope preferences.
#
# Functions exposed:
#   Read-SapAbapSource  -> [pscustomobject] { Status; Object; Type; SourceFile;
#                                             Lines; Includes; Truncated; Error;
#                                             System; Client; Host }
#   Get-SapIncludeTree  -> string[] (include names)
#
# FIDELITY (verified live 2026-08-06, S4H/400 + S4D/100, Z_EXCEPTION_1):
#   RPY_PROGRAM_READ is AUTHORITATIVE. Byte-for-byte identical to what SE38
#   shows a developer -- 54/54 lines matched the SE38 AbapEditor download of
#   the same program on the same system, including inline comments and
#   multi-byte (Chinese) text. It is not a stale rendition and it does not
#   normalise or truncate the stored source.
#
#   The divergence originally reported against this reader was a CROSS-SYSTEM
#   read, not a rendition difference: the RFC leg followed the AI-session pin
#   (S4D/100) while the GUI leg attached to the only live SAP GUI window
#   (S4H/400). Both systems host an independently-maintained Z_EXCEPTION_1.
#   Hence System/Client/Host on the result + the source.meta.json sidecar:
#   ALWAYS reconcile provenance before attributing a text delta to a reader.
#
# Mechanics:
#   program / module pool / FUGR-main / include : RPY_PROGRAM_READ
#   function module                              : RPY_FUNCTIONMODULE_READ_NEW
#                                                  (SOURCE table; else its include)
#   class / interface                            : UNSUPPORTED (SE24 GUI / ADT)
#
# VERIFIED on S4D (S/4HANA, kernel 7xx) 2026-06-03:
#   RPY_PROGRAM_READ : IMPORTING PROGRAM_NAME, WITH_INCLUDELIST, WITH_LOWERCASE;
#                      TABLES SOURCE_EXTENDED (full width) -> SOURCE (fallback)
#                      -> INCLUDE_TAB. Read ZCMRUPDATE_ADDON_TABLE = 652 lines OK;
#                      SAPLZFGDEVAI include list (INCLUDE_TAB) = 3 OK.
#   FM SOURCE        : RPY_FUNCTIONMODULE_READ_NEW does NOT return source on read
#                      (its SOURCE table is empty; NEW_SOURCE is a write param).
#                      An FM body lives in include L<fg>U<TFDIR-INCLUDE>, so
#                      _ReadFmSource resolves it via TFDIR + RPY_PROGRAM_READ.
#   Column reads are by index 0, so a column-name change is tolerated; a missing
#   parameter/table surfaces as an RfcException this code reports cleanly.
# DDIF/DD0xL idioms used by /sap-compare live in sap_compare_ddic.ps1 (copied
# from the proven sap_rfc_lookup_ddic.ps1; DDIF_FIELDINFO_GET verified on MARA).
# =============================================================================

# Dependency: Connect-SapRfc / Disconnect-SapRfc / New-RfcReadTable / Add-Rfc*.
# $PSScriptRoot = shared\scripts (this file's dir) when dot-sourced.
. (Join-Path $PSScriptRoot 'sap_rfc_lib.ps1')

# ---- private helpers --------------------------------------------------------

function _ReadRfcTableFirstColumn($tab) {
    # Read the first column of every row as text. Source-line and include tables
    # expose a single char column whose NAME varies by release; reading by index
    # 0 avoids hard-coding it. Always returns a List[string] (never $null).
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -eq $tab) { return ,$lines }
    $rc = 0; try { $rc = [int]$tab.RowCount } catch { $rc = 0 }
    for ($i = 0; $i -lt $rc; $i++) {
        $tab.CurrentIndex = $i
        $val = ''
        try { $val = [string]$tab.GetString(0) }
        catch {
            try { $val = [string]$tab.GetString($tab.Metadata.LineType[0].Name) } catch { $val = '' }
        }
        $lines.Add([string]$val)
    }
    return ,$lines
}

function _RfcDestIdentity($dest) {
    # Which SAP system did this source actually come from? Read straight off
    # the live NCo destination -- never off the caller's intent. A source file
    # with no provenance is how the 2026-08-06 cross-system read stayed
    # invisible: the GUI leg had downloaded S4H/400's Z_EXCEPTION_1 while this
    # reader returned S4D/100's, and neither output named its system.
    # Read RfcDestination.SystemAttributes -- the identity NCo got back from the
    # live logon. NOT RfcDestination.SystemID: that is the configured R3NAME and
    # is EMPTY for a direct -Server/-Sysnr connection (verified S4H 2026-08-06),
    # which would silently produce a blank stamp. There is no .Attributes member
    # on RfcDestination at all.
    # Best-effort: an attribute read that fails degrades to blanks, never throws.
    $id = @{ System = ''; Client = ''; User = ''; Host = '' }
    try {
        $a = $dest.SystemAttributes
        if ($a) {
            try { $id.System = "$($a.SystemID)".Trim()   } catch { }
            try { $id.Client = "$($a.Client)".Trim()     } catch { }
            try { $id.User   = "$($a.User)".Trim()       } catch { }
            try { $id.Host   = "$($a.PartnerHost)".Trim() } catch { }
        }
    } catch { }
    # Fall back to the destination's own config for anything still blank.
    foreach ($pair in @(@('Client','Client'), @('User','User'), @('Host','AppServerHost'))) {
        if ([string]::IsNullOrWhiteSpace($id[$pair[0]])) {
            try { $id[$pair[0]] = "$($dest.($pair[1]))".Trim() } catch { }
        }
    }
    return $id
}

function _RfcRowExists($dest, $table, $where, $keyField) {
    # Cheap existence probe via RFC_READ_TABLE (guarded by New-RfcReadTable).
    try {
        $fn = New-RfcReadTable -Destination $dest -Table $table
        [void]$fn.SetValue("ROWCOUNT", 1)
        Add-RfcOption $fn $where
        if ($keyField) { Add-RfcField $fn $keyField }
        $null = $fn.Invoke($dest)
        $d = $fn.GetTable("DATA")
        return ([int]$d.RowCount -gt 0)
    } catch {
        # If the probe itself errors, don't block -- let the RPY read decide.
        return $true
    }
}

function _InvokeRpyProgramRead($dest, $progName, $withIncludes) {
    # Returns @{ Lines = List[string]; Includes = List[string] }. May throw
    # (RfcException) on a parameter/table-name mismatch -- caller classifies.
    $fn = $dest.Repository.CreateFunction("RPY_PROGRAM_READ")
    [void]$fn.SetValue("PROGRAM_NAME", $progName)
    [void]$fn.SetValue("WITH_INCLUDELIST", $(if ($withIncludes) { 'X' } else { ' ' }))
    [void]$fn.SetValue("WITH_LOWERCASE", 'X')
    $null = $fn.Invoke($dest)

    $src = $null
    try { $src = $fn.GetTable("SOURCE_EXTENDED") } catch { $src = $null }
    $lines = _ReadRfcTableFirstColumn $src
    if ($lines.Count -eq 0) {
        $src2 = $null
        try { $src2 = $fn.GetTable("SOURCE") } catch { $src2 = $null }
        $lines = _ReadRfcTableFirstColumn $src2
    }

    $inc = New-Object System.Collections.Generic.List[string]
    if ($withIncludes) {
        $itab = $null
        try { $itab = $fn.GetTable("INCLUDE_TAB") } catch { $itab = $null }
        $inc = _ReadRfcTableFirstColumn $itab
    }
    return @{ Lines = $lines; Includes = $inc }
}

function _ReadFmSource($dest, $fmName) {
    # An FM's body lives in include  L<funcgroup>U<TFDIR-INCLUDE>.  Resolve the
    # function pool (TFDIR-PNAME = 'SAPL'<fg>) + include number from TFDIR, then
    # read that include via RPY_PROGRAM_READ. Returns @{ Lines = List[string] }.
    # (RPY_FUNCTIONMODULE_READ_NEW does NOT return source on read -- verified S4D.)
    $pname = ''; $incno = ''
    try {
        $fn = New-RfcReadTable -Destination $dest -Table 'TFDIR'
        [void]$fn.SetValue('ROWCOUNT', 1)
        Add-RfcOption $fn "FUNCNAME = '$fmName'"
        Add-RfcField $fn 'PNAME'
        Add-RfcField $fn 'INCLUDE'
        $null = $fn.Invoke($dest)
        $d = $fn.GetTable('DATA')
        if ([int]$d.RowCount -gt 0) {
            $d.CurrentIndex = 0
            $parts = ([string]$d.GetString('WA')).Split('|')
            if ($parts.Length -ge 1) { $pname = $parts[0].Trim() }
            if ($parts.Length -ge 2) { $incno = $parts[1].Trim() }
        }
    } catch { }

    $lines = New-Object System.Collections.Generic.List[string]
    if ($pname -ne '' -and $incno -ne '') {
        $fg = $pname -replace '^SAPL', ''
        $incName = 'L' + $fg + 'U' + $incno
        $r = _InvokeRpyProgramRead $dest $incName $false
        $lines = $r.Lines
    }
    return @{ Lines = $lines }
}

# ---- public API -------------------------------------------------------------

function Read-SapAbapSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('program','include','fm','class','interface')] [string] $Type,
        [Parameter(Mandatory)] [string] $OutDir,
        [switch] $WithIncludes,
        [int]    $Depth = 3,
        [object] $Dest = $null,
        [string] $Language = ''
    )
    $ErrorActionPreference = 'Stop'   # function-local; never leaks to the caller
    # UTF-8 WITH BOM (ctor arg $true): the parser/diff read these files with
    # PS 5.1 Get-Content, which auto-detects encoding from the BOM (and matches
    # the UTF-16-BOM files the SE24 GUI-download class path produces). Without a
    # BOM, PS 5.1 would misread multibyte (e.g. Japanese) source as ANSI.
    $utf8NoBom = New-Object System.Text.UTF8Encoding $true

    # System/Client/Host record WHICH SAP system the source came from. Callers
    # that compare this reader against the GUI download leg (/sap-check-abap,
    # /sap-fix-abap, /sap-git serialize) must compare provenance before they
    # compare text -- see the sidecar written next to SourceFile below.
    $result = [pscustomobject]@{
        Status = 'ERROR'; Object = $Name.ToUpper(); Type = $Type
        SourceFile = ''; Lines = 0; Includes = @(); Truncated = $false; Error = ''
        System = ''; Client = ''; Host = ''
    }

    if ($Type -in @('class','interface')) {
        $result.Status = 'UNSUPPORTED'
        $result.Error  = 'class/interface source over RFC is not supported; use SE24 GUI download or ADT mode'
        return $result
    }

    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

    $openedHere = $false
    $dest = $Dest
    if (-not $dest) { $dest = Connect-SapRfc -DestName 'READ_SRC'; $openedHere = $true }
    if (-not $dest) { $result.Error = 'no RFC connection (run /sap-login)'; return $result }

    try {
        $obj = $result.Object

        $ident = _RfcDestIdentity $dest
        $result.System = $ident.System
        $result.Client = $ident.Client
        $result.Host   = $ident.Host

        # Existence pre-check -> clean NOT_FOUND (independent of RPY exceptions).
        if ($Type -eq 'fm') {
            if (-not (_RfcRowExists $dest 'TFDIR' "FUNCNAME = '$obj'" 'FUNCNAME')) { $result.Status = 'NOT_FOUND'; return $result }
        } else {
            if (-not (_RfcRowExists $dest 'TRDIR' "NAME = '$obj'" 'NAME')) { $result.Status = 'NOT_FOUND'; return $result }
        }

        if ($Type -eq 'fm') {
            $r = _ReadFmSource $dest $obj
            $allLines = $r.Lines
            $includes = @()
        } else {
            $r = _InvokeRpyProgramRead $dest $obj ([bool]$WithIncludes)
            $allLines = $r.Lines
            $includes = $r.Includes
        }
        if ($null -eq $allLines) { $allLines = New-Object System.Collections.Generic.List[string] }

        $srcFile = Join-Path $OutDir 'source.txt'
        [System.IO.File]::WriteAllLines($srcFile, [string[]]$allLines, $utf8NoBom)
        $result.SourceFile = $srcFile
        $result.Lines = @($allLines).Count

        # Provenance sidecar. Deliberately a SEPARATE file: a header comment
        # inside source.txt would corrupt the very thing callers re-upload.
        # Any consumer diffing this against a GUI download must check that the
        # two agree on system+client BEFORE treating a text delta as a real
        # change (2026-08-06 cross-system read).
        try {
            $meta = [ordered]@{
                schema      = 'sapdev.sourceread/1'
                reader      = 'RPY_PROGRAM_READ'
                object      = $obj
                type        = $Type
                system      = $result.System
                client      = $result.Client
                host        = $result.Host
                lines       = $result.Lines
                read_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            $metaFile = Join-Path $OutDir 'source.meta.json'
            [System.IO.File]::WriteAllText($metaFile, ($meta | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
        } catch { }

        $incOut = @()
        if ($WithIncludes -and $Type -ne 'fm' -and $includes -and @($includes).Count -gt 0) {
            $list = @($includes | Where-Object { $_ -and "$_".Trim() -ne '' } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
            $cap = $Depth; if ($cap -le 0) { $cap = 9999 }
            $take = $list
            if ($list.Count -gt $cap) { $take = $list[0..($cap - 1)]; $result.Truncated = $true }
            $n = 0
            foreach ($incName in $take) {
                $n++
                try {
                    $ri = _InvokeRpyProgramRead $dest $incName $false
                    $incFile = Join-Path $OutDir ("inc_{0:D2}_{1}.txt" -f $n, $incName)
                    [System.IO.File]::WriteAllLines($incFile, [string[]]$ri.Lines, $utf8NoBom)
                    $incOut += [pscustomobject]@{ Name = $incName; File = $incFile; Lines = @($ri.Lines).Count }
                } catch {
                    $incOut += [pscustomobject]@{ Name = $incName; File = ''; Lines = 0 }
                }
            }
        }
        $result.Includes = $incOut
        $result.Status = 'OK'
    }
    catch [SAP.Middleware.Connector.RfcAbapException] {
        $k = "$($_.Exception.Key)"
        if ($k -match 'NOT_FOUND|NOT_EXIST|NO_EXIST|CANCEL') { $result.Status = 'NOT_FOUND'; $result.Error = $k }
        else { $result.Status = 'ERROR'; $result.Error = "ABAP_EXC:${k}: $($_.Exception.Message)" }
    }
    catch {
        $result.Status = 'ERROR'; $result.Error = "$($_.Exception.Message)"
    }
    finally {
        if ($openedHere) { try { Disconnect-SapRfc } catch {} }   # only close what we opened
    }

    return $result
}

function Get-SapIncludeTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [object] $Dest,
        [int] $Depth = 3
    )
    $ErrorActionPreference = 'Stop'
    # WITH_INCLUDELIST='X' makes RPY_PROGRAM_READ resolve the full (nested)
    # include list in one call, so no manual BFS is needed; Depth caps the count.
    $r = _InvokeRpyProgramRead $Dest ($Name.ToUpper()) $true
    $list = @($r.Includes | Where-Object { $_ -and "$_".Trim() -ne '' } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
    if ($Depth -gt 0 -and $list.Count -gt $Depth) { $list = $list[0..($Depth - 1)] }
    return ,$list
}
