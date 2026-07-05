# =============================================================================
# sap_rfc_fm_insert.ps1  --  Headless RFC deploy of an ABAP function module
#
# Inserts an FM's source into its function group via RPY_FUNCTIONMODULE_INSERT --
# the RFC-preferred alternative to the SE37 GUI clipboard-paste + Ctrl+F3 deploy.
# RPY_FUNCTIONMODULE_INSERT *is* remote-enabled (FMODE=R): call it DIRECTLY via
# NCo 3.1 (no wrapper). It is CREATE-ONLY -- it raises FUNCTION_ALREADY_EXISTS on
# an existing FM (verified live S4G) -- so this helper guards existence and returns
# EXISTS (exit 3) for an existing FM; updating one stays on the GUI path.
#
# The FM `FUNCTION..ENDFUNCTION` fragment is split into:
#   * BODY ONLY  -> NEW_SOURCE table (untruncated; SAP regenerates the FUNCTION
#                   header, the *" interface comment block, and ENDFUNCTION).
#   * the *" interface -> IMPORT_PARAMETER (RSIMP) / EXPORT_PARAMETER (RSEXP) /
#                   CHANGING_PARAMETER (RSCHA) / TABLES_PARAMETER (RSTBL) /
#                   EXCEPTION_LIST (RSEXC) rows.
# Interface-field mapping (reflected + read-back-verified live on S4G 2026-07-05):
#   TYPE <t>       -> TYP=<t>,  TYPES='X'
#   TYPE REF TO <c>-> TYP=<c>,  REF_CLASS='X'
#   LIKE <ref>     -> DBFIELD=<ref>
#   VALUE(<n>)     -> REFERENCE=' ' (by value);  REFERENCE(<n>)/bare -> REFERENCE='X'
#   TABLES STRUCTURE <s> -> DBSTRUCT=<s>;  TABLES TYPE <t> -> TYP=<t>, TYPES='X'
#
# The function group MUST already exist (create it via /sap-function-group first);
# RPY_FUNCTIONMODULE_INSERT does not create the pool.
#
# RUN WITH 32-BIT POWERSHELL -- SAP NCo 3.1 is 32-bit-only.
#
# PARAMETERS
#   -SourceFile <path>    full FM include (FUNCTION..ENDFUNCTION) (required)
#   -FmName <name>        FUNCNAME (default: parsed from the FUNCTION line)
#   -FunctionGroup <fg>   FUNCTION_POOL -- the FG must exist (required)
#   -Transport <TRKORR>   CORRNUM -- when given, the FM is REGISTERED into this TR
#                         (sets SUPPRESS_CORR_CHECK=' '; the default 'X' SUPPRESSES the
#                         correction check and leaves the FM off-transport). Omit for a
#                         local / $TMP FG (SUPPRESS_CORR_CHECK='X', no transport entry).
#   -ShortText <text>     FM short text (default = FM name)
#   -Remote               REMOTE_CALL='R' (make the FM RFC-enabled); default normal
#   Connection params (-Server/-Sysnr/-Client/-User/-Password/-Language ...) ->
#   Connect-SapRfc (pinned-profile fallback when blank).
#
# OUTPUT (stdout, parseable)
#   STATUS: INSERTED_ACTIVE fm=<n> fgroup=<g>          (inserted + no inactive version)
#   STATUS: INSERTED_INACTIVE fm=<n> fgroup=<g>        (inserted but DWINACTIV row remains -> activate)
#   STATUS: EXISTS fm=<n>                              (create-only -> caller uses GUI update)
#   STATUS: FG_MISSING fgroup=<g>                      (create the FG first)
#   STATUS: INSERT_FAILED <exception/message>
#   STATUS: RFC_ERROR <msg>                            (connect / FMODE!=R)
#   STATUS: INPUT_ERROR <msg>
#   Exit: 0 = inserted (active); 1 = inserted-inactive (activate) / insert failed;
#         2 = connect / not-RFC-enabled / input / FG missing; 3 = already exists (GUI update).
# =============================================================================

[CmdletBinding()]
param(
    [string] $SourceFile    = '',
    [string] $FmName        = '',
    [string] $FunctionGroup = '',
    [string] $Transport     = '',
    [string] $ShortText     = '',
    [switch] $Remote,

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

$connServer=$Server; $connSysnr=$Sysnr; $connMsgServer=$MessageServer; $connLogonGroup=$LogonGroup
$connSystemID=$SystemID; $connClient=$Client; $connUser=$User; $connPassword=$Password; $connLanguage=$Language

if ([string]::IsNullOrWhiteSpace($FunctionGroup)) { Write-Output 'STATUS: INPUT_ERROR -FunctionGroup is required'; exit 2 }
if ([string]::IsNullOrWhiteSpace($SourceFile) -or -not (Test-Path -LiteralPath $SourceFile)) {
    Write-Output ("STATUS: INPUT_ERROR source file not found: " + $SourceFile); exit 2
}
$src = @(Get-Content -LiteralPath $SourceFile -Encoding UTF8)
if ($src.Count -eq 0) { Write-Output 'STATUS: INPUT_ERROR source file is empty'; exit 2 }

# --- parse the fragment: FUNCNAME, interface rows, body ---------------------
$funcIdx = -1; $endIdx = -1
for ($i=0; $i -lt $src.Count; $i++) {
    $t = $src[$i].Trim().ToUpperInvariant()
    if ($funcIdx -lt 0 -and $t -match '^FUNCTION(\s|$)') { $funcIdx = $i }
    if ($t -match '^ENDFUNCTION\b') { $endIdx = $i }
}
if ($funcIdx -lt 0 -or $endIdx -lt 0 -or $endIdx -le $funcIdx) { Write-Output 'STATUS: INPUT_ERROR no FUNCTION/ENDFUNCTION block'; exit 2 }
if ([string]::IsNullOrWhiteSpace($FmName)) {
    if ($src[$funcIdx] -match '(?i)^\s*FUNCTION\s+([A-Za-z0-9_/]+)') { $FmName = $Matches[1] }
}
if ([string]::IsNullOrWhiteSpace($FmName)) { Write-Output 'STATUS: INPUT_ERROR could not resolve FM name'; exit 2 }
$FmName = $FmName.ToUpperInvariant(); $FunctionGroup = $FunctionGroup.ToUpperInvariant()
if ([string]::IsNullOrWhiteSpace($ShortText)) { $ShortText = $FmName }

# interface comment block = consecutive *"-lines after FUNCTION; body follows.
$bodyStart = $funcIdx + 1
$iface = New-Object System.Collections.ArrayList
for ($i=$funcIdx+1; $i -lt $endIdx; $i++) {
    if ($src[$i].Trim().StartsWith('*"')) { [void]$iface.Add($src[$i]); $bodyStart = $i + 1 } else { break }
}
$body = @()
if (($endIdx-1) -ge $bodyStart) { $body = @($src[$bodyStart..($endIdx-1)]) }

# param model
$imp = New-Object System.Collections.ArrayList   # IMPORTING
$exp = New-Object System.Collections.ArrayList   # EXPORTING
$cha = New-Object System.Collections.ArrayList   # CHANGING
$tbl = New-Object System.Collections.ArrayList   # TABLES
$exc = New-Object System.Collections.ArrayList   # EXCEPTIONS
$section = ''
foreach ($rawL in $iface) {
    $s = $rawL.Trim(); $s = $s.Substring(2).Trim()
    if ($s -eq '' -or $s -match '^-+$') { continue }
    if ($s -match '(?i)Interface') { continue }        # "Local Interface:" header (any language marker after Substring)
    $u = $s.ToUpperInvariant()
    if ($u -match '^(IMPORTING|EXPORTING|CHANGING|TABLES|EXCEPTIONS|RAISING)$') { $section = $u; continue }
    if ($section -eq '') { continue }
    if ($section -eq 'EXCEPTIONS' -or $section -eq 'RAISING') {
        if ($s -match '^([A-Za-z0-9_]+)') { [void]$exc.Add($Matches[1]) }
        continue
    }
    # strip trailing OPTIONAL / DEFAULT
    $optional = ($s -match '(?i)\bOPTIONAL\b')
    $def = ''
    if ($s -match "(?i)\bDEFAULT\s+(.+?)(\s+OPTIONAL)?\s*$") { $def = $Matches[1].Trim() }
    $p = $s -replace '(?i)\s+OPTIONAL\s*$','' -replace '(?i)\s+DEFAULT\s+.*$',''
    $byValue = $false; $name = ''
    if ($p -match '(?i)^VALUE\(\s*([A-Za-z0-9_]+)\s*\)')     { $name=$Matches[1]; $byValue=$true }
    elseif ($p -match '(?i)^REFERENCE\(\s*([A-Za-z0-9_]+)\s*\)') { $name=$Matches[1]; $byValue=$false }
    elseif ($p -match '^([A-Za-z0-9_]+)')                    { $name=$Matches[1]; $byValue=$false }
    if ($name -eq '') { continue }
    $rest = $p -replace '(?i)^(?:VALUE|REFERENCE)\(\s*[A-Za-z0-9_]+\s*\)',''
    $rest = ($rest -replace ('(?i)^\s*'+[regex]::Escape($name)+'\b'),'').Trim()
    $kind=''; $ref=''
    if     ($rest -match '(?i)^TYPE\s+REF\s+TO\s+(.+)$') { $kind='REF';  $ref=$Matches[1].Trim() }
    elseif ($rest -match '(?i)^TYPE\s+(.+)$')            { $kind='TYPE'; $ref=$Matches[1].Trim() }
    elseif ($rest -match '(?i)^LIKE\s+(.+)$')            { $kind='LIKE'; $ref=$Matches[1].Trim() }
    elseif ($rest -match '(?i)^STRUCTURE\s+(.+)$')       { $kind='STRUCT'; $ref=$Matches[1].Trim() }
    $o = @{ name=$name; byValue=$byValue; optional=$optional; def=$def; kind=$kind; ref=$ref }
    switch ($section) {
        'IMPORTING' { [void]$imp.Add($o) }
        'EXPORTING' { [void]$exp.Add($o) }
        'CHANGING'  { [void]$cha.Add($o) }
        'TABLES'    { [void]$tbl.Add($o) }
    }
}

. ([System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\..\shared\scripts\sap_rfc_lib.ps1')))

$dest = $null
try {
    $dest = Connect-SapRfc -Server $connServer -Sysnr $connSysnr -MessageServer $connMsgServer `
        -LogonGroup $connLogonGroup -SystemID $connSystemID -Client $connClient -User $connUser `
        -Password $connPassword -Language $connLanguage
} catch { Write-Output ("STATUS: RFC_ERROR " + $_.Exception.Message); exit 2 }
if ($null -eq $dest) { Write-Output 'STATUS: RFC_ERROR could not connect'; exit 2 }

function SetTypeFields($row, $o) {
    # maps a parsed param onto RSIMP/RSEXP/RSCHA typing fields. Live-verified on
    # S4G: DBFIELD=LIKE ref; TYP=TYPE ref; TYPES='X' = "TYPE REF TO" (reference),
    # NOT a plain-TYPE marker -- so plain TYPE sets TYP only (TYPES blank).
    switch ($o.kind) {
        'TYPE'   { [void]$row.SetValue('TYP', $o.ref) }
        'REF'    { [void]$row.SetValue('TYP', $o.ref); [void]$row.SetValue('TYPES', 'X') }
        'LIKE'   { [void]$row.SetValue('DBFIELD', $o.ref) }
        default  { }
    }
    [void]$row.SetValue('REFERENCE', ($(if ($o.byValue) { ' ' } else { 'X' })))
}

try {
    # RPY_FUNCTIONMODULE_INSERT must be remote-enabled.
    $fmode = $null
    try {
        $chk=$dest.Repository.CreateFunction('RFC_READ_TABLE'); [void]$chk.SetValue('QUERY_TABLE','TFDIR'); [void]$chk.SetValue('DELIMITER','|')
        Add-RfcOption $chk "FUNCNAME = 'RPY_FUNCTIONMODULE_INSERT'"; Add-RfcField $chk 'FMODE'
        $chk.Invoke($dest); $d=$chk.GetTable('DATA'); if ($d.RowCount -ge 1){ $d.CurrentIndex=0; $fmode=($d.GetString('WA')).Trim() }
    } catch { $fmode=$null }
    if ($fmode -ne 'R') { Write-Output ("STATUS: RFC_ERROR RPY_FUNCTIONMODULE_INSERT not remote-enabled (FMODE=$fmode) -- use GUI"); exit 2 }

    # FG must exist (TLIBG).
    $fgOk=$false
    try {
        $fg=$dest.Repository.CreateFunction('RFC_READ_TABLE'); [void]$fg.SetValue('QUERY_TABLE','TLIBG'); [void]$fg.SetValue('DELIMITER','|')
        Add-RfcOption $fg ("AREA = '" + ($FunctionGroup -replace "'","''") + "'"); Add-RfcField $fg 'AREA'
        $fg.Invoke($dest); if ($fg.GetTable('DATA').RowCount -ge 1){ $fgOk=$true }
    } catch { $fgOk=$false }
    if (-not $fgOk) { Write-Output ("STATUS: FG_MISSING fgroup=" + $FunctionGroup + " -- create it first via /sap-function-group"); exit 2 }

    # Existence check -- create-only (RPY_FUNCTIONMODULE_INSERT raises
    # FUNCTION_ALREADY_EXISTS on an existing FM); an existing FM updates via GUI.
    $fmExists=$false
    try {
        $ck=$dest.Repository.CreateFunction('RFC_READ_TABLE'); [void]$ck.SetValue('QUERY_TABLE','TFDIR'); [void]$ck.SetValue('DELIMITER','|')
        Add-RfcOption $ck ("FUNCNAME = '" + ($FmName -replace "'","''") + "'"); Add-RfcField $ck 'FUNCNAME'
        $ck.Invoke($dest); if ($ck.GetTable('DATA').RowCount -ge 1){ $fmExists=$true }
    } catch { $fmExists=$false }
    if ($fmExists) { Write-Output ("STATUS: EXISTS fm=" + $FmName); exit 3 }

    # build the call
    $fn=$dest.Repository.CreateFunction('RPY_FUNCTIONMODULE_INSERT')
    [void]$fn.SetValue('FUNCNAME', $FmName)
    [void]$fn.SetValue('FUNCTION_POOL', $FunctionGroup)
    [void]$fn.SetValue('INTERFACE_GLOBAL', 'X')
    [void]$fn.SetValue('REMOTE_CALL', ($(if ($Remote) { 'R' } else { ' ' })))
    [void]$fn.SetValue('SHORT_TEXT', $ShortText)
    # Transport registration: with a TR, register the FM into it -- `SUPPRESS_CORR_CHECK=' '`
    # runs the correction check that records the object in CORRNUM. The param DEFAULTS to
    # 'X' (SUPPRESS), which silently leaves the FM OFF-transport (the 2026-07-05 finding);
    # setting it blank is what makes the deploy transport-complete. Without a TR -> local:
    # suppress (and never leave it blank without a CORRNUM, which would prompt -> hang over RFC).
    if (-not [string]::IsNullOrWhiteSpace($Transport)) {
        [void]$fn.SetValue('CORRNUM', $Transport.ToUpperInvariant())
        [void]$fn.SetValue('SUPPRESS_CORR_CHECK', ' ')
    } else {
        [void]$fn.SetValue('SUPPRESS_CORR_CHECK', 'X')
    }

    $tImp=$fn.GetTable('IMPORT_PARAMETER'); foreach($o in $imp){ [void]$tImp.Append(); [void]$tImp.SetValue('PARAMETER',$o.name); SetTypeFields $tImp $o; if($o.optional){[void]$tImp.SetValue('OPTIONAL','X')}; if($o.def -ne ''){[void]$tImp.SetValue('DEFAULT',$o.def)} }
    $tExp=$fn.GetTable('EXPORT_PARAMETER'); foreach($o in $exp){ [void]$tExp.Append(); [void]$tExp.SetValue('PARAMETER',$o.name); SetTypeFields $tExp $o }
    $tCha=$fn.GetTable('CHANGING_PARAMETER'); foreach($o in $cha){ [void]$tCha.Append(); [void]$tCha.SetValue('PARAMETER',$o.name); SetTypeFields $tCha $o; if($o.optional){[void]$tCha.SetValue('OPTIONAL','X')}; if($o.def -ne ''){[void]$tCha.SetValue('DEFAULT',$o.def)} }
    $tTbl=$fn.GetTable('TABLES_PARAMETER'); foreach($o in $tbl){ [void]$tTbl.Append(); [void]$tTbl.SetValue('PARAMETER',$o.name); if($o.kind -eq 'STRUCT'){[void]$tTbl.SetValue('DBSTRUCT',$o.ref)} elseif($o.kind -eq 'TYPE'){[void]$tTbl.SetValue('TYP',$o.ref)} elseif($o.kind -eq 'LIKE'){[void]$tTbl.SetValue('DBSTRUCT',$o.ref)}; if($o.optional){[void]$tTbl.SetValue('OPTIONAL','X')} }
    $tExc=$fn.GetTable('EXCEPTION_LIST'); foreach($e in $exc){ [void]$tExc.Append(); [void]$tExc.SetValue('EXCEPTION',$e) }

    # body -> NEW_SOURCE (untruncated; single unnamed field -> set by index 0)
    $tNs=$fn.GetTable('NEW_SOURCE'); foreach($ln in $body){ [void]$tNs.Append(); [void]$tNs.SetValue(0, $ln) }

    try { $fn.Invoke($dest) } catch { Write-Output ("STATUS: INSERT_FAILED " + $_.Exception.Message); exit 1 }

    # verify: DWINACTIV row present for this FM include => inactive.
    $inactive=$false
    try {
        $iv=$dest.Repository.CreateFunction('RFC_READ_TABLE'); [void]$iv.SetValue('QUERY_TABLE','DWINACTIV'); [void]$iv.SetValue('DELIMITER','|')
        Add-RfcOption $iv ("OBJECT = 'FUNC'"); Add-RfcOption $iv ("AND OBJ_NAME = '" + ($FmName -replace "'","''") + "'")
        Add-RfcField $iv 'OBJ_NAME'
        $iv.Invoke($dest); if ($iv.GetTable('DATA').RowCount -ge 1){ $inactive=$true }
    } catch { $inactive=$false }

    if ($inactive) {
        Write-Output ("STATUS: INSERTED_INACTIVE fm=" + $FmName + " fgroup=" + $FunctionGroup + " -- activate via /sap-activate-object"); exit 1
    } else {
        Write-Output ("STATUS: INSERTED_ACTIVE fm=" + $FmName + " fgroup=" + $FunctionGroup); exit 0
    }
} catch {
    Write-Output ("STATUS: RFC_ERROR " + $_.Exception.Message); exit 1
} finally {
    if ($null -ne $dest) { try { Disconnect-SapRfc } catch {} }
}
