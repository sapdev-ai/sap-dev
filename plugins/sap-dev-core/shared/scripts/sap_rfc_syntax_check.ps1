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
