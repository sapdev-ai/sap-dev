# =============================================================================
# sap_rfc_syntax_check.ps1  --  Headless compiler-level ABAP syntax check via RFC
#
# Runs the ABAP compiler syntax check on a SOURCE FILE *without* the object
# having to exist in the repository, and returns ALL errors + warnings (line,
# column, message) -- the offline/headless equivalent of the SE38/SE37/SE24
# GUI Ctrl+F2, catchable BEFORE the source is ever uploaded to SAP.
#
# MECHANISM
#   EDITOR_SYNTAX_CHECK is the Function Builder's own syntax checker but it is
#   NOT remote-enabled (TFDIR.FMODE blank). It is invoked here THROUGH the
#   dev-init dispatcher Z_GENERIC_RFC_WRAPPER_TBL (remote-enabled), which does
#   CALL FUNCTION ... PARAMETER-TABLE dynamically with asXML-serialized params.
#   No raw SQL, no writes -- a pure read-only compiler check (honours the skill
#   operating rules). Same bridge sap_tadir_delete.ps1 uses for TR_TADIR_INTERFACE.
#
#   Why EDITOR_SYNTAX_CHECK and not RS_SYNTAX_CHECK (tested 2026-07-01):
#     * I_TRDIR carries the program attributes (UCCHECK/FIXPT/SUBC) DIRECTLY,
#       so a non-existent program name checks in Unicode mode -- RS_SYNTAX_CHECK
#       derived Unicode from an EXISTING program and failed at line "-2" on a
#       fresh name.
#     * O_ERROR_TAB + O_WARNINGS_TAB + ALL_ERRORS='X' return EVERY finding in one
#       call -- RS_SYNTAX_CHECK returned only the first error.
#
#   EDITOR_SYNTAX_CHECK interface (verified live via FUPARAREF/DD03L, S/4HANA):
#     I_SOURCE   (T)  untyped source table            -> PTYPENAME ABAPTXT255_TAB
#                                                         rows <item><LINE>..</LINE></item>
#     I_TRDIR    (I)  TRDIR                            -> SUBC/FIXPT/UCCHECK/NAME
#     I_PROGRAM  (I)  SY-REPID (label)                 -> SYST-REPID
#     ALL_ERRORS (I)  untyped flag                     -> char1 'X'
#     O_ERROR_TAB    / O_WARNINGS_TAB (T) RSLINLMSG    -> PTYPENAME RSYNTMSGS
#                    (RSLINLMSG row: KIND, LINE(INT4), COL(INT4), KEYWORD,
#                     MESSAGE(TEXT240), INCNAME)
#     O_ERROR_LINE/OFFSET/SUBRC/MESSAGE/INCLUDE (E)    -> first-error scalars
#
# RUN WITH 32-BIT POWERSHELL -- SAP NCo 3.1 is 32-bit-only:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File <this> ...
#
# PARAMETERS
#   -SourceFile <path>    ABAP source to check (required)
#   -ProgramName <name>   name label / TRDIR-NAME (default Z_SYNTAX_SCRATCH)
#   -Subc <1|K|F|I|M>     TRDIR-SUBC: 1=report K=class-pool F=function-pool
#                         I=include M=module-pool (default 1)
#   -Uccheck <X| >        Unicode checks active (default X)
#   -Fixpt  <X| >         fixed-point arithmetic (default X)
#   -AllErrors <X| >      return every error, not just the first (default X)
#   -OutTsv <path>        also write a house-style *.check.tsv findings file
#   -Wrap                 fragment mode: wrap an FM (SUBC=F) or class pool
#                         (SUBC=K) as a self-contained SUBC=1 program so the
#                         method / FM BODY is syntax-checkable PRE-INSERT with
#                         zero persistence (Strategy A). Findings are line-mapped
#                         back to the ORIGINAL file; scaffold warnings dropped; a
#                         signature too complex to model degrades to
#                         STATUS: COULD_NOT_CHECK (never a false-fail). Proven
#                         live S4D 2026-07-04. Complements -- not replaces -- the
#                         authoritative in-context Ctrl+F2 after inactive insert.
#   -WrapperFm <NAME>     default Z_GENERIC_RFC_WRAPPER_TBL
#   Connection params (-Server/-Sysnr/-Client/-User/-Password/-Language, or
#   load-balanced -MessageServer/-LogonGroup/-SystemID) fall through to
#   Connect-SapRfc, which defaults to the AI-session's pinned profile when blank.
#
# OUTPUT (stdout, parseable)
#   One line per finding:
#     SYNTAX: ERROR LINE=<n> COL=<c> INC=<inc> MSG=<text>
#     SYNTAX: WARN  LINE=<n> COL=<c> INC=<inc> MSG=<text>
#   Then a summary:
#     STATUS: CLEAN errors=0 warnings=<w>
#     STATUS: FINDINGS errors=<e> warnings=<w>
#     STATUS: COULD_NOT_CHECK <reason>   (-Wrap only: signature too complex to
#                                         model -> caller degrades, never fails)
#     STATUS: RFC_ERROR <msg>
#     STATUS: INPUT_ERROR <msg>
#   Exit code: 0 = check RAN (clean or with findings -- gate on the counts);
#              1 = wrapper / FM call failed; 2 = connect / input failure.
# =============================================================================

[CmdletBinding()]
param(
    [string] $SourceFile  = '',
    [string] $ProgramName = 'Z_SYNTAX_SCRATCH',
    [string] $Subc        = '1',
    [string] $Uccheck     = 'X',
    [string] $Fixpt       = 'X',
    [string] $AllErrors   = 'X',
    [string] $OutTsv      = '',
    [switch] $Wrap,
    [string] $WrapperFm   = 'Z_GENERIC_RFC_WRAPPER_TBL',

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

# Snapshot connection params BEFORE dot-sourcing (dot-source param-clobber trap;
# keep the discipline uniform with the sibling shared scripts).
$connServer     = $Server
$connSysnr      = $Sysnr
$connMsgServer  = $MessageServer
$connLogonGroup = $LogonGroup
$connSystemID   = $SystemID
$connClient     = $Client
$connUser       = $User
$connPassword   = $Password
$connLanguage   = $Language

# --- read the source file up front (fail fast, before any RFC) --------------
if ([string]::IsNullOrWhiteSpace($SourceFile) -or -not (Test-Path -LiteralPath $SourceFile)) {
    Write-Output ("STATUS: INPUT_ERROR source file not found: " + $SourceFile); exit 2
}
$srcLines = @(Get-Content -LiteralPath $SourceFile -Encoding UTF8)
if ($srcLines.Count -eq 0) { $srcLines = @('') }   # empty file -> one blank line so the table isn't empty

# --- optional fragment wrapping (Strategy A) --------------------------------
# FM includes (SUBC=F) and class pools (SUBC=K) are NOT standalone-compilable, so
# a raw fragment fails with "FUNCTION not usable here" / "Missing REPORT". With
# -Wrap we re-present the fragment as a self-contained SUBC=1 program so the
# compiler checks the method / FM BODY pre-insert with zero persistence:
#   class -> strip the class-pool PUBLIC marker after DEFINITION (keep CREATE
#            PUBLIC), prepend REPORT -> checked as a LOCAL class.
#   FM    -> synthesize IMPORTING/EXPORTING/CHANGING/TABLES params as DATA decls,
#            body under START-OF-SELECTION.
# A line-map translates findings back to ORIGINAL line numbers; warnings on the
# synthesized scaffold are dropped; an ERROR on a scaffold line means the
# signature was too complex to model faithfully -> COULD_NOT_CHECK (degrade,
# never false-fail). Proven live on S4D 2026-07-04.
$script:wrapping  = $false
$script:wrapMap   = @{}   # wrapped 1-based line -> original 1-based line
$script:wrapSynth = @{}   # wrapped 1-based line -> $true (scaffold line)

function Build-AbapWrap([string[]] $orig, [string] $mode) {
    $r = @{ ok = $false; reason = ''; lines = @(); map = @{}; synth = @{} }
    if ($mode -eq 'K') {
        # ---- class / interface pool -> local class in a dummy report --------
        $stripped = @()
        foreach ($ln in $orig) {
            if ($ln -match '\b(CLASS|INTERFACE)\b' -and $ln -match '\bDEFINITION\b') {
                $stripped += ($ln -replace '(\bDEFINITION\b)\s+PUBLIC\b', '$1')
            } else { $stripped += $ln }
        }
        $lines = @('REPORT zsynwrap.') + $stripped
        $map = @{}
        for ($i = 0; $i -lt $stripped.Count; $i++) { $map[$i + 2] = $i + 1 }   # REPORT is wrapped line 1
        $r.ok = $true; $r.lines = $lines; $r.map = $map; $r.synth = @{ 1 = $true }
        return $r
    }
    if ($mode -eq 'F') {
        # ---- function module include -> body in a dummy report --------------
        $funcIdx = -1; $endIdx = -1
        for ($i = 0; $i -lt $orig.Count; $i++) {
            $t = $orig[$i].Trim().ToUpperInvariant()
            if ($funcIdx -lt 0 -and $t -match '^FUNCTION(\s|$)') { $funcIdx = $i }
            if ($t -match '^ENDFUNCTION\b') { $endIdx = $i }
        }
        if ($funcIdx -lt 0 -or $endIdx -lt 0 -or $endIdx -le $funcIdx) {
            $r.reason = 'no FUNCTION/ENDFUNCTION block found'; return $r
        }
        # interface comment block = consecutive *"-lines right after FUNCTION
        $bodyStart = $funcIdx + 1
        $iface = New-Object System.Collections.ArrayList
        for ($i = $funcIdx + 1; $i -lt $endIdx; $i++) {
            if ($orig[$i].Trim().StartsWith('*"')) { [void]$iface.Add($orig[$i]); $bodyStart = $i + 1 }
            else { break }
        }
        # parse the interface -> local DATA declarations
        $decls = New-Object System.Collections.ArrayList
        $section = ''
        foreach ($rawL in $iface) {
            $s = $rawL.Trim()
            $s = $s.Substring(2).Trim()                       # drop the leading *"
            if ($s -eq '' -or $s -match '^-+$') { continue }  # blank / separator
            if ($s -match '(?i)Local Interface') { continue }
            $u = $s.ToUpperInvariant()
            if ($u -match '^(IMPORTING|EXPORTING|CHANGING|TABLES|EXCEPTIONS|RAISING)$') { $section = $u; continue }
            if ($section -eq '' -or $section -in @('EXCEPTIONS', 'RAISING')) { continue }
            $p = $s -replace '(?i)\s+OPTIONAL\s*$', '' -replace '(?i)\s+DEFAULT\s+.*$', ''
            $name = ''
            if ($p -match '(?i)^(?:VALUE|REFERENCE)\(\s*([A-Za-z0-9_]+)\s*\)') { $name = $Matches[1] }
            elseif ($p -match '^([A-Za-z0-9_]+)') { $name = $Matches[1] }
            if ($name -eq '') { continue }
            $rest = $p -replace '(?i)^(?:VALUE|REFERENCE)\(\s*[A-Za-z0-9_]+\s*\)', ''
            $pat  = '(?i)^\s*' + [regex]::Escape($name) + '\b'
            $rest = ($rest -replace $pat, '').Trim()
            if ($section -eq 'TABLES') {
                if     ($rest -match '(?i)^STRUCTURE\s+([A-Za-z0-9_/]+)') { [void]$decls.Add('  DATA ' + $name + ' TYPE STANDARD TABLE OF ' + $Matches[1] + '.') }
                elseif ($rest -match '(?i)^TYPE\s+(.+)$')                 { [void]$decls.Add('  DATA ' + $name + ' TYPE STANDARD TABLE OF ' + ($Matches[1].Trim()) + '.') }
                elseif ($rest -match '(?i)^LIKE\s+(.+)$')                 { [void]$decls.Add('  DATA ' + $name + ' LIKE STANDARD TABLE OF ' + ($Matches[1].Trim()) + '.') }
                else { $r.reason = 'untyped TABLES parameter ' + $name; return $r }
            } else {
                if     ($rest -match '(?i)^TYPE\s+REF\s+TO\s+(.+)$') { [void]$decls.Add('  DATA ' + $name + ' TYPE REF TO ' + ($Matches[1].Trim()) + '.') }
                elseif ($rest -match '(?i)^TYPE\s+(.+)$')            { [void]$decls.Add('  DATA ' + $name + ' TYPE ' + ($Matches[1].Trim()) + '.') }
                elseif ($rest -match '(?i)^LIKE\s+(.+)$')            { [void]$decls.Add('  DATA ' + $name + ' LIKE ' + ($Matches[1].Trim()) + '.') }
                else { $r.reason = 'untyped/generic parameter ' + $name + ' (cannot synthesize a local declaration)'; return $r }
            }
        }
        $pre  = @('REPORT zsynwrap.') + @($decls.ToArray()) + @('START-OF-SELECTION.')
        $body = @()
        if (($endIdx - 1) -ge $bodyStart) { $body = @($orig[$bodyStart..($endIdx - 1)]) }
        $lines = @($pre) + @($body)
        $synth = @{}; for ($k = 1; $k -le $pre.Count; $k++) { $synth[$k] = $true }
        $map = @{}
        for ($j = 0; $j -lt $body.Count; $j++) { $map[$pre.Count + $j + 1] = ($bodyStart + $j) + 1 }
        $r.ok = $true; $r.lines = $lines; $r.map = $map; $r.synth = $synth
        return $r
    }
    $r.ok = $true; $r.lines = $orig; $r.map = @{}; $r.synth = @{}; $r.reason = 'noop'
    return $r
}

function Write-CncTsv([string] $reason) {
    if ($OutTsv -ne '') {
        try {
            $header = "Code`tSeverity`tLocation`tDetail`tFixAdvice"
            $row = "SYNTAX_COULD_NOT_CHECK`tINFO`t`t" + ($reason -replace "`t", ' ') + "`tCheck in-context (Ctrl+F2) after inactive insert"
            [System.IO.File]::WriteAllText($OutTsv, ($header + "`r`n" + $row + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
    }
}

if ($Wrap -and ($Subc -eq 'K' -or $Subc -eq 'F')) {
    $wrapRes = Build-AbapWrap $srcLines $Subc
    if (-not $wrapRes.ok) {
        Write-CncTsv $wrapRes.reason
        Write-Output ("STATUS: COULD_NOT_CHECK " + $wrapRes.reason + " -- check in-context after inactive insert"); exit 0
    }
    $srcLines         = @($wrapRes.lines)
    $script:wrapMap   = $wrapRes.map
    $script:wrapSynth = $wrapRes.synth
    $script:wrapping  = $true
    $Subc             = '1'          # the wrapped unit is a self-contained report
    $ProgramName      = 'ZSYNWRAP'
}

. (Join-Path $scriptDir 'sap_rfc_lib.ps1')

# --- asXML builders (no <?xml?> prolog -- CALL TRANSFORMATION id accepts the
#     bare asx:abap root, matching sap_tadir_delete.ps1) -----------------------
$ASX_HEAD = '<asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>'
$ASX_TAIL = '</DATA></asx:values></asx:abap>'
function Esc([string] $v) { [System.Security.SecurityElement]::Escape([string]$v) }

function New-AsxScalar([string] $v) { $ASX_HEAD + (Esc $v) + $ASX_TAIL }

# $pairs = array of @('FIELD', value) -- emitted in the given (structure) order.
function New-AsxStruct($pairs) {
    $inner = ''
    foreach ($p in $pairs) { $inner += '<' + $p[0] + '>' + (Esc $p[1]) + '</' + $p[0] + '>' }
    $ASX_HEAD + $inner + $ASX_TAIL
}

# elementary-row source table: one <item><LINE>..</LINE></item> per line.
function New-AsxSourceTable($lines) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($ASX_HEAD)
    foreach ($ln in $lines) { [void]$sb.Append('<item><LINE>'); [void]$sb.Append((Esc $ln)); [void]$sb.Append('</LINE></item>') }
    [void]$sb.Append($ASX_TAIL)
    $sb.ToString()
}

# Append one CT_PARAMS param, chunking a long PVALUE into 1333-char rows
# (classic RFC caps a flat CHAR component at 1333; the wrapper reassembles by
# PSEQ). Blank payload => a single placeholder row (E/T receivers).
$CHUNK = 1333
function Add-Param($tbl, [string]$pname, [string]$ptype, [string]$ptypename, [string]$payload) {
    if ([string]::IsNullOrEmpty($payload)) {
        [void]$tbl.Append()
        [void]$tbl.SetValue('PNAME', $pname); [void]$tbl.SetValue('PSEQ', 1)
        [void]$tbl.SetValue('PTYPE', $ptype); [void]$tbl.SetValue('PTYPENAME', $ptypename)
        return
    }
    $len = $payload.Length; $off = 0; $seq = 0
    while ($off -lt $len) {
        $seq++
        $take = [Math]::Min($CHUNK, $len - $off)
        [void]$tbl.Append()
        [void]$tbl.SetValue('PNAME', $pname); [void]$tbl.SetValue('PSEQ', $seq)
        [void]$tbl.SetValue('PTYPE', $ptype); [void]$tbl.SetValue('PTYPENAME', $ptypename)
        [void]$tbl.SetValue('PVALUE', $payload.Substring($off, $take))
        $off += $CHUNK
    }
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

try {
    # Verify the wrapper FM is present + remote-enabled (clear error if dev-init absent).
    $wrapFn = $null
    try {
        $wfn = $dest.Repository.CreateFunction('RFC_READ_TABLE')
        [void]$wfn.SetValue('QUERY_TABLE', 'TFDIR'); [void]$wfn.SetValue('DELIMITER', '|')
        Add-RfcOption $wfn ("FUNCNAME = '" + ($WrapperFm.ToUpperInvariant() -replace "'", "''") + "'")
        Add-RfcField  $wfn 'FUNCNAME'; Add-RfcField $wfn 'FMODE'
        $wfn.Invoke($dest); $wdt = $wfn.GetTable('DATA')
        if ($wdt.RowCount -ge 1) { $wdt.CurrentIndex = 0; $wrapFn = ($wdt.GetString('WA') -split '\|') }
    } catch { $wrapFn = $null }
    if ($null -eq $wrapFn) {
        Write-Output ("STATUS: RFC_ERROR wrapper FM " + $WrapperFm + " not found -- run /sap-dev-init to deploy it"); exit 2
    }
    if ($wrapFn[1].Trim() -ne 'R') {
        Write-Output ("STATUS: RFC_ERROR wrapper FM " + $WrapperFm + " is not remote-enabled (FMODE=" + $wrapFn[1].Trim() + ") -- /sap-dev-init Step 7b sets PROCESSING_TYPE=REMOTE"); exit 2
    }

    # --- build the wrapper call --------------------------------------------
    $fn  = $dest.Repository.CreateFunction($WrapperFm)
    [void]$fn.SetValue('IV_FUNCNAME', 'EDITOR_SYNTAX_CHECK')
    $tbl = $fn.GetTable('CT_PARAMS')

    # inputs -- I_TRDIR fields in structure (DD03L position) order.
    $trdirPairs = @( ,@('SUBC', $Subc) ) + @( ,@('FIXPT', $Fixpt) ) + @( ,@('UCCHECK', $Uccheck) ) + @( ,@('NAME', $ProgramName) )
    Add-Param $tbl 'I_SOURCE'   'T' 'ABAPTXT255_TAB'   (New-AsxSourceTable $srcLines)
    Add-Param $tbl 'I_TRDIR'    'I' 'TRDIR'            (New-AsxStruct $trdirPairs)
    Add-Param $tbl 'I_PROGRAM'  'I' 'SYST-REPID'       (New-AsxScalar $ProgramName)
    Add-Param $tbl 'ALL_ERRORS' 'I' 'TRPARI-S_CHECKED' (New-AsxScalar $AllErrors)
    # output receivers (blank PVALUE)
    Add-Param $tbl 'O_ERROR_TAB'    'T' 'RSYNTMSGS'  ''
    Add-Param $tbl 'O_WARNINGS_TAB' 'T' 'RSYNTMSGS'  ''
    Add-Param $tbl 'O_ERROR_LINE'   'E' 'SYST-INDEX' ''
    Add-Param $tbl 'O_ERROR_OFFSET' 'E' 'SYST-TABIX' ''
    Add-Param $tbl 'O_ERROR_SUBRC'  'E' 'SYST-SUBRC' ''
    Add-Param $tbl 'O_ERROR_MESSAGE' 'E' 'STRING'    ''
    Add-Param $tbl 'O_ERROR_INCLUDE' 'E' 'SYST-REPID' ''

    try {
        $fn.Invoke($dest)
    } catch {
        Write-Output ("STATUS: RFC_ERROR EDITOR_SYNTAX_CHECK via " + $WrapperFm + " raised: " + $_.Exception.Message); exit 1
    }

    # --- reassemble output chunks per PNAME (ordered by PSEQ) ---------------
    $out = @{}
    $tblOut = $fn.GetTable('CT_PARAMS')
    for ($i = 0; $i -lt $tblOut.RowCount; $i++) {
        $tblOut.CurrentIndex = $i
        $pn = $tblOut.GetString('PNAME').Trim()
        $pt = $tblOut.GetString('PTYPE').Trim()
        if ($pt -notin @('E', 'C', 'T')) { continue }
        $ps = 0; [void][int]::TryParse($tblOut.GetString('PSEQ'), [ref]$ps)
        $pv = $tblOut.GetString('PVALUE')
        if (-not $out.ContainsKey($pn)) { $out[$pn] = @{} }
        $out[$pn][$ps] = $pv
    }
    function Get-OutXml([string]$pname) {
        if (-not $out.ContainsKey($pname)) { return '' }
        $sb = New-Object System.Text.StringBuilder
        foreach ($k in ($out[$pname].Keys | Sort-Object)) { [void]$sb.Append($out[$pname][$k]) }
        $s = $sb.ToString()
        # The wrapper's CALL TRANSFORMATION id emits a leading BOM (U+FEFF) +
        # <?xml encoding="utf-16"?> prolog; [xml] on a .NET string throws on both
        # ("no Unicode byte order mark" / illegal char). Strip to the asx:abap root.
        $ix = $s.IndexOf('<asx:abap')
        if ($ix -ge 0) { return $s.Substring($ix) }
        return $s
    }
    function Get-OutScalar([string]$pname) {
        $xml = Get-OutXml $pname
        if ([string]::IsNullOrWhiteSpace($xml)) { return '' }
        try { $doc = [xml]$xml; $n = $doc.SelectSingleNode("//*[local-name()='DATA']"); if ($n) { return $n.InnerText } } catch {}
        return ''
    }
    # Parse an RSLINLMSG table param into finding hashtables. CALL TRANSFORMATION
    # id serializes each internal-table row with the ROW-STRUCTURE name as the
    # element (e.g. <RSLINLMSG>), NOT a generic <item> -- so iterate the direct
    # children of <DATA> and read each row's fields by local-name.
    function Get-Findings([string]$pname) {
        $res = New-Object System.Collections.ArrayList
        $xml = Get-OutXml $pname
        if ([string]::IsNullOrWhiteSpace($xml)) { return $res }
        try {
            $doc = [xml]$xml
            $dataNode = $doc.SelectSingleNode("//*[local-name()='DATA']")
            if ($null -ne $dataNode) {
                foreach ($row in $dataNode.ChildNodes) {
                    $h = @{ LINE = ''; COL = ''; MESSAGE = ''; INCNAME = ''; KIND = '' }
                    foreach ($c in $row.ChildNodes) {
                        switch ($c.LocalName) {
                            'LINE'    { $h.LINE    = $c.InnerText }
                            'COL'     { $h.COL     = $c.InnerText }
                            'MESSAGE' { $h.MESSAGE = $c.InnerText }
                            'INCNAME' { $h.INCNAME = $c.InnerText }
                            'KIND'    { $h.KIND    = $c.InnerText }
                        }
                    }
                    [void]$res.Add($h)
                }
            }
        } catch {}
        return $res
    }

    $errs  = @(Get-Findings 'O_ERROR_TAB')
    $warns = @(Get-Findings 'O_WARNINGS_TAB')
    $subrc = Get-OutScalar 'O_ERROR_SUBRC'

    # Fallback: table empty but the scalar reports an error (defensive -- should
    # not happen with ALL_ERRORS='X', but never silently drop a real error).
    if ($errs.Count -eq 0 -and $subrc -ne '' -and $subrc -ne '0') {
        $errs = @(@{ LINE = (Get-OutScalar 'O_ERROR_LINE'); COL = (Get-OutScalar 'O_ERROR_OFFSET');
                     MESSAGE = (Get-OutScalar 'O_ERROR_MESSAGE'); INCNAME = (Get-OutScalar 'O_ERROR_INCLUDE'); KIND = '' })
    }

    # --- wrap: translate wrapped-line findings back to original + degrade ----
    # An ERROR on a synthesized scaffold line = we mis-modelled the signature;
    # degrade the WHOLE result to COULD_NOT_CHECK (never mask it as a body error,
    # never let the scaffold false-fail). Warnings on scaffold lines (e.g. an
    # unused synthesized EXPORTING decl) are artifacts -> drop them silently.
    if ($script:wrapping) {
        $scaffoldBad = $false
        $mErrs = @()
        foreach ($e in $errs) {
            $L = 0; [void][int]::TryParse([string]$e.LINE, [ref]$L)
            if ($script:wrapSynth.ContainsKey($L)) { $scaffoldBad = $true; continue }
            if ($script:wrapMap.ContainsKey($L))   { $e.LINE = [string]$script:wrapMap[$L] }
            $mErrs += $e
        }
        $mWarns = @()
        foreach ($w in $warns) {
            $L = 0; [void][int]::TryParse([string]$w.LINE, [ref]$L)
            if ($script:wrapSynth.ContainsKey($L)) { continue }
            if ($script:wrapMap.ContainsKey($L))   { $w.LINE = [string]$script:wrapMap[$L] }
            $mWarns += $w
        }
        if ($scaffoldBad) {
            $reason = 'wrap scaffold did not compile (signature too complex to model)'
            Write-CncTsv $reason
            Write-Output ("STATUS: COULD_NOT_CHECK " + $reason + " -- check in-context after inactive insert"); exit 0
        }
        $errs = @($mErrs); $warns = @($mWarns)
    }

    # --- emit findings ------------------------------------------------------
    $tsvRows = @()
    foreach ($e in $errs) {
        $inc = if ($e.INCNAME) { $e.INCNAME } else { $ProgramName }
        Write-Output ("SYNTAX: ERROR LINE=" + $e.LINE + " COL=" + $e.COL + " INC=" + $inc + " MSG=" + $e.MESSAGE)
        $tsvRows += ("SYNTAX_ERROR`tERROR`t" + $e.LINE + ':' + $e.COL + "`t" + ($e.MESSAGE -replace "`t", ' ') + "`t")
    }
    foreach ($w in $warns) {
        $inc = if ($w.INCNAME) { $w.INCNAME } else { $ProgramName }
        Write-Output ("SYNTAX: WARN LINE=" + $w.LINE + " COL=" + $w.COL + " INC=" + $inc + " MSG=" + $w.MESSAGE)
        $tsvRows += ("SYNTAX_WARNING`tWARNING`t" + $w.LINE + ':' + $w.COL + "`t" + ($w.MESSAGE -replace "`t", ' ') + "`t")
    }

    if ($OutTsv -ne '') {
        try {
            $header = "Code`tSeverity`tLocation`tDetail`tFixAdvice"
            $all = @($header) + $tsvRows
            [System.IO.File]::WriteAllText($OutTsv, (($all -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
            Write-Output ("TSV: " + $OutTsv)
        } catch { Write-Output ("WARN: could not write TSV " + $OutTsv + ": " + $_.Exception.Message) }
    }

    if ($errs.Count -eq 0) {
        Write-Output ("STATUS: CLEAN errors=0 warnings=" + $warns.Count)
    } else {
        Write-Output ("STATUS: FINDINGS errors=" + $errs.Count + " warnings=" + $warns.Count)
    }
    exit 0

} catch {
    Write-Output ("STATUS: RFC_ERROR " + $_.Exception.Message); exit 1
} finally {
    if ($null -ne $dest) { try { Disconnect-SapRfc } catch {} }
}
