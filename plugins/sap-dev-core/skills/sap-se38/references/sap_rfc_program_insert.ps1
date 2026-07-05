# =============================================================================
# sap_rfc_program_insert.ps1  --  Headless RFC deploy of an ABAP program (report)
#
# Inserts a REPORT/PROGRAM's source into the repository via RPY_PROGRAM_INSERT and
# generates it ACTIVE in one call -- the RFC-preferred alternative to the SE38 GUI
# clipboard-paste + Ctrl+F3 deploy. Sidesteps the GUI inactive-objects worklist
# entirely (the dead end on users with a big inactive backlog -- see the S4D
# 2026-06-20 finding) and is fully verifiable via PROGDIR.
#
# MECHANISM
#   RPY_PROGRAM_INSERT *is* remote-enabled (TFDIR.FMODE=R) -- unlike EDITOR_SYNTAX_CHECK
#   it needs NO wrapper: call it directly through NCo 3.1. Source goes in the
#   SOURCE_EXTENDED table (line type ABAPTXT255, field LINE -- Unicode-safe, preserves
#   Japanese + long lines; the plain SOURCE table is ABAPSOURCE CHAR72 and TRUNCATES
#   lines >72 chars). SAVE_INACTIVE=' ' writes the ACTIVE version directly (STATE=A),
#   so "insert then activate" collapses into one call.
#
#   CREATE-ONLY. RPY_PROGRAM_INSERT raises ALREADY_EXISTS on an existing program and
#   RPY_PROGRAM_UPDATE is not remote-enabled -- so this helper is for NEW programs;
#   updating an existing program stays on the GUI path (caller degrades on EXISTS).
#
#   TEXT ELEMENTS (selection texts / TEXT-NNN) are NOT written by RPY_PROGRAM_INSERT
#   -- this helper deploys SOURCE only. A report with selection texts needs a
#   follow-up (RPY_TEXTPOOL_INSERT / GUI Step 5c). The caller is told via
#   HAS_TEXTPOOL (best-effort scan) so it can handle texts.
#
# RUN WITH 32-BIT POWERSHELL -- SAP NCo 3.1 is 32-bit-only:
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File <this> ...
#
# PARAMETERS
#   -SourceFile <path>    ABAP report source to deploy (required; full source incl.
#                         the REPORT/PROGRAM statement)
#   -ProgramName <name>   program name / TRDIR-NAME (required)
#   -Package <devclass>   DEVELOPMENT_CLASS ('$TMP' = local, no transport) (required)
#   -Transport <TRKORR>   TRANSPORT_NUMBER -- must be a modifiable REQUEST (K), NOT a
#                         task: RPY_PROGRAM_INSERT raises PERMISSION_ERROR on a task
#                         (verified S4G 2026-07-05). The program is recorded in it
#                         (E071 R3TR PROG) -- transport-complete via TRANSPORT_NUMBER alone
#                         (no SUPPRESS_CORR_CHECK, unlike the FG/FM insert FMs). Omit for $TMP.
#   -Title <text>         TITLE_STRING (default = program name)
#   -NoActivate           save INACTIVE (SAVE_INACTIVE='X') instead of active
#   Connection params (-Server/-Sysnr/-Client/-User/-Password/-Language, or
#   load-balanced -MessageServer/-LogonGroup/-SystemID) fall through to
#   Connect-SapRfc (pinned-profile fallback when blank).
#
# OUTPUT (stdout, parseable)
#   INFO: HAS_TEXTPOOL=<0|1>            (selection texts / TEXT-NNN detected in source)
#   STATUS: INSERTED_ACTIVE program=<n> package=<p> transport=<t>
#   STATUS: INSERTED_INACTIVE program=<n> ...        (-NoActivate)
#   STATUS: EXISTS program=<n>                        (create-only -> caller uses GUI update)
#   STATUS: INSERT_FAILED <exception/message>
#   STATUS: NOT_ACTIVE program=<n> state=<s>          (inserted but PROGDIR not A)
#   STATUS: RFC_ERROR <msg>                           (connect / FMODE!=R)
#   STATUS: INPUT_ERROR <msg>
#   Exit: 0 = inserted (+active unless -NoActivate); 1 = insert/activation failed;
#         2 = connect / not-RFC-enabled / input; 3 = already exists (use GUI update).
# =============================================================================

[CmdletBinding()]
param(
    [string] $SourceFile  = '',
    [string] $ProgramName = '',
    [string] $Package     = '',
    [string] $Transport   = '',
    [string] $Title       = '',
    [switch] $NoActivate,

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

# Snapshot connection params BEFORE dot-sourcing (dot-source param-clobber trap).
$connServer     = $Server
$connSysnr      = $Sysnr
$connMsgServer  = $MessageServer
$connLogonGroup = $LogonGroup
$connSystemID   = $SystemID
$connClient     = $Client
$connUser       = $User
$connPassword   = $Password
$connLanguage   = $Language

# --- validate + read source (fail fast, before any RFC) ---------------------
if ([string]::IsNullOrWhiteSpace($ProgramName)) { Write-Output 'STATUS: INPUT_ERROR -ProgramName is required'; exit 2 }
if ([string]::IsNullOrWhiteSpace($Package))     { Write-Output 'STATUS: INPUT_ERROR -Package is required ($TMP for a local object)'; exit 2 }
if ([string]::IsNullOrWhiteSpace($SourceFile) -or -not (Test-Path -LiteralPath $SourceFile)) {
    Write-Output ("STATUS: INPUT_ERROR source file not found: " + $SourceFile); exit 2
}
$srcLines = @(Get-Content -LiteralPath $SourceFile -Encoding UTF8)
if ($srcLines.Count -eq 0) { Write-Output 'STATUS: INPUT_ERROR source file is empty'; exit 2 }
$ProgramName = $ProgramName.ToUpperInvariant()
if ([string]::IsNullOrWhiteSpace($Title)) { $Title = $ProgramName }

# Best-effort text-element detection so the caller knows selection texts / TEXT-NNN
# still need handling (RPY_PROGRAM_INSERT deploys SOURCE only).
$hasTextpool = 0
foreach ($ln in $srcLines) {
    if ($ln -match '(?i)\bTEXT-\w{3}\b' -or $ln -match '(?i)^\s*(PARAMETERS|SELECT-OPTIONS)\b') { $hasTextpool = 1; break }
}
Write-Output ("INFO: HAS_TEXTPOOL=" + $hasTextpool)

. ([System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\..\shared\scripts\sap_rfc_lib.ps1')))

# --- connect ---------------------------------------------------------------
$dest = $null
try {
    $dest = Connect-SapRfc -Server $connServer -Sysnr $connSysnr `
        -MessageServer $connMsgServer -LogonGroup $connLogonGroup -SystemID $connSystemID `
        -Client $connClient -User $connUser -Password $connPassword -Language $connLanguage
} catch {
    Write-Output ("STATUS: RFC_ERROR " + $_.Exception.Message); exit 2
}
if ($null -eq $dest) { Write-Output 'STATUS: RFC_ERROR could not connect (no pinned profile / bad credentials)'; exit 2 }

# guarded SetValue -- ignore a param the installed release does not expose
function TrySet($fn, [string]$name, $value) { try { [void]$fn.SetValue($name, $value) } catch {} }

try {
    # 1. RPY_PROGRAM_INSERT must be remote-enabled here.
    $fmode = $null
    try {
        $chk = $dest.Repository.CreateFunction('RFC_READ_TABLE')
        [void]$chk.SetValue('QUERY_TABLE', 'TFDIR'); [void]$chk.SetValue('DELIMITER', '|')
        Add-RfcOption $chk "FUNCNAME = 'RPY_PROGRAM_INSERT'"
        Add-RfcField  $chk 'FMODE'
        $chk.Invoke($dest); $cdt = $chk.GetTable('DATA')
        if ($cdt.RowCount -ge 1) { $cdt.CurrentIndex = 0; $fmode = ($cdt.GetString('WA')).Trim() }
    } catch { $fmode = $null }
    if ($fmode -ne 'R') {
        Write-Output ("STATUS: RFC_ERROR RPY_PROGRAM_INSERT is not remote-enabled here (FMODE=" + $fmode + ") -- use the GUI deploy path"); exit 2
    }

    # 2. Existence check (TRDIR) -- create-only; existing -> caller uses GUI update.
    $exists = $false
    try {
        $ex = $dest.Repository.CreateFunction('RFC_READ_TABLE')
        [void]$ex.SetValue('QUERY_TABLE', 'TRDIR'); [void]$ex.SetValue('DELIMITER', '|')
        Add-RfcOption $ex ("NAME = '" + ($ProgramName -replace "'", "''") + "'")
        Add-RfcField  $ex 'NAME'
        $ex.Invoke($dest); $edt = $ex.GetTable('DATA')
        if ($edt.RowCount -ge 1) { $exists = $true }
    } catch { $exists = $false }
    if ($exists) {
        Write-Output ("STATUS: EXISTS program=" + $ProgramName); exit 3
    }

    # 3. RPY_PROGRAM_INSERT (native RFC).
    $saveInactive = if ($NoActivate) { 'X' } else { ' ' }
    $fn = $dest.Repository.CreateFunction('RPY_PROGRAM_INSERT')
    [void]$fn.SetValue('PROGRAM_NAME', $ProgramName)
    [void]$fn.SetValue('DEVELOPMENT_CLASS', $Package)
    TrySet $fn 'PROGRAM_TYPE'    '1'
    TrySet $fn 'APPLICATION'     'S'
    TrySet $fn 'TITLE_STRING'    $Title
    TrySet $fn 'SAVE_INACTIVE'   $saveInactive
    TrySet $fn 'SUPPRESS_DIALOG' 'X'
    if (-not [string]::IsNullOrWhiteSpace($Transport)) { TrySet $fn 'TRANSPORT_NUMBER' $Transport.ToUpperInvariant() }

    # SOURCE_EXTENDED: one row per line, field LINE (ABAPTXT255, Unicode-safe).
    $tbl = $fn.GetTable('SOURCE_EXTENDED')
    foreach ($ln in $srcLines) { [void]$tbl.Append(); [void]$tbl.SetValue('LINE', $ln) }

    try {
        $fn.Invoke($dest)
    } catch {
        # classic EXCEPTIONS (ALREADY_EXISTS / CANCELLED / PERMISSION_ERROR / ...)
        # surface here as the message text.
        Write-Output ("STATUS: INSERT_FAILED " + $_.Exception.Message); exit 1
    }

    if ($NoActivate) {
        Write-Output ("STATUS: INSERTED_INACTIVE program=" + $ProgramName + " package=" + $Package + " transport=" + $Transport); exit 0
    }

    # 4. Verify active (SAVE_INACTIVE=' ' should have generated STATE=A).
    $state = ''
    try {
        $pv = $dest.Repository.CreateFunction('RFC_READ_TABLE')
        [void]$pv.SetValue('QUERY_TABLE', 'PROGDIR'); [void]$pv.SetValue('DELIMITER', '|')
        Add-RfcOption $pv ("NAME = '" + ($ProgramName -replace "'", "''") + "'")
        Add-RfcField  $pv 'STATE'
        $pv.Invoke($dest); $pvt = $pv.GetTable('DATA')
        for ($i = 0; $i -lt $pvt.RowCount; $i++) { $pvt.CurrentIndex = $i; $s = ($pvt.GetString('WA')).Trim(); if ($s -eq 'A') { $state = 'A' } elseif ($state -eq '') { $state = $s } }
    } catch { $state = '' }

    if ($state -eq 'A') {
        Write-Output ("STATUS: INSERTED_ACTIVE program=" + $ProgramName + " package=" + $Package + " transport=" + $Transport); exit 0
    } else {
        Write-Output ("STATUS: NOT_ACTIVE program=" + $ProgramName + " state=" + $state + " -- inserted but not active; activate via /sap-activate-object"); exit 1
    }

} catch {
    Write-Output ("STATUS: RFC_ERROR " + $_.Exception.Message); exit 1
} finally {
    if ($null -ne $dest) { try { Disconnect-SapRfc } catch {} }
}
