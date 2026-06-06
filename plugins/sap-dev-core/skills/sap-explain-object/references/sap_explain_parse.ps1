<#
  sap_explain_parse.ps1  -  offline ABAP source -> structure/call map (map.json)

  Invoked as a SUBPROCESS (not dot-sourced):
    powershell -NoProfile -ExecutionPolicy Bypass -File sap_explain_parse.ps1 -SourceDir <dir> -OutFile <path>

  Pure offline string analysis - no SAP connection. Best-effort v1; macro- and
  generated-code constructs are approximated. Refine the regexes as needed.
  Windows PowerShell 5.1-safe (no ternary / null-coalescing).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceDir,
    [Parameter(Mandatory)] [string] $OutFile
)
$ErrorActionPreference = 'Stop'

$IC  = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
$ICM = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Multiline'

# --- collect source files (source.txt + inc_*.txt) -------------------------
$files = Get-ChildItem -Path $SourceDir -Filter '*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name
$raw = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
    foreach ($ln in (Get-Content -LiteralPath $f.FullName)) { $raw.Add([string]$ln) }
}

# --- strip full-line (*) and trailing (") comments (naive) -----------------
$clean = foreach ($ln in $raw) {
    if ($ln -match '^\s*\*') { continue }
    ($ln -replace '".*$', '')   # naive: ignores " inside string literals
}
$src = ($clean -join "`n")

function Get-Cap1($pattern, $opts) {
    if ($null -eq $opts) { $opts = $IC }
    [regex]::Matches($src, $pattern, $opts) | ForEach-Object { $_.Groups[1].Value.Trim() }
}

# --- units ------------------------------------------------------------------
$units = @()
foreach ($m in (Get-Cap1 '^\s*FORM\s+([A-Z0-9_]+)'      $ICM)) { $units += @{ kind='FORM';     name=$m } }
foreach ($m in (Get-Cap1 '^\s*FUNCTION\s+([A-Z0-9_/]+)' $ICM)) { $units += @{ kind='FUNCTION'; name=$m } }
foreach ($m in (Get-Cap1 '^\s*METHOD\s+([A-Z0-9_~]+)'   $ICM)) { $units += @{ kind='METHOD';   name=$m } }

# --- edges / externals ------------------------------------------------------
$perform = Get-Cap1 '\bPERFORM\s+([A-Z0-9_]+)'                $IC | Select-Object -Unique
$callfm  = Get-Cap1 "CALL\s+FUNCTION\s+'([A-Z0-9_/]+)'"       $IC | Select-Object -Unique
$submit  = Get-Cap1 '\bSUBMIT\s+([A-Z0-9_/]+)'                $IC | Select-Object -Unique
$tcode   = Get-Cap1 "CALL\s+TRANSACTION\s+'([A-Z0-9_/]+)'"    $IC | Select-Object -Unique

# --- db touches (best-effort) ----------------------------------------------
# Reads: SELECT is DB-only (internal reads use READ TABLE / LOOP AT).
$reads = Get-Cap1 '\bSELECT\b[\s\S]*?\bFROM\s+([A-Z0-9_/]+)' $IC
# Writes: anchored to statement start and matched only in DB-specific Open-SQL
# forms, so internal-table statements are excluded by construction --
# INSERT .. INTO TABLE, APPEND, COLLECT, MODIFY TABLE, MODIFY itab .. (TRANSPORTING|INDEX),
# DELETE itab (WHERE|INDEX), DELETE TABLE, DELETE ADJACENT DUPLICATES. UPDATE has
# no internal-table variant. Not detected: obsolete header-line short forms
# (INSERT dbtab. / DELETE dbtab FROM wa).
$writePatterns = @(
    '^\s*INSERT\s+INTO\s+([A-Z0-9_/]+)',                                       # INSERT INTO dbtab
    '^\s*INSERT\s+([A-Z0-9_/]+)\s+FROM\b',                                     # INSERT dbtab FROM [TABLE]
    '^\s*UPDATE\s+([A-Z0-9_/]+)',                                              # UPDATE dbtab (DB-only)
    '^\s*MODIFY\s+([A-Z0-9_/]+)\s+FROM\b(?![^\n]*\b(?:TRANSPORTING|INDEX)\b)', # MODIFY dbtab FROM [TABLE]
    '^\s*DELETE\s+FROM\s+([A-Z0-9_/]+)',                                       # DELETE FROM dbtab
    '^\s*DELETE\s+([A-Z0-9_/]+)\s+FROM\s+TABLE\b'                              # DELETE dbtab FROM TABLE itab
)
$writes = @()
foreach ($pat in $writePatterns) { $writes += Get-Cap1 $pat $ICM }
$reads  = @($reads  | Where-Object { $_ } | Select-Object -Unique)
# Drop ABAP keywords that can still slip through (e.g. UPDATE TASK, MODIFY TABLE).
$skipKw = @('TABLE','TASK')
$writes = @($writes | Where-Object { $_ -and ($skipKw -notcontains $_.ToUpper()) } | Select-Object -Unique)

# --- selection screen -------------------------------------------------------
$sel = @()
foreach ($m in (Get-Cap1 '^\s*PARAMETERS?\s*:?\s*([A-Z0-9_]+)'    $ICM)) { $sel += @{ name=$m; kind='PARAMETER' } }
foreach ($m in (Get-Cap1 '^\s*SELECT-OPTIONS\s*:?\s*([A-Z0-9_]+)' $ICM)) { $sel += @{ name=$m; kind='SELECT-OPTION' } }

# --- includes ---------------------------------------------------------------
$inc = Get-Cap1 '^\s*INCLUDE\s+([A-Z0-9_/]+)' $ICM | Select-Object -Unique

$map = [ordered]@{
    object   = (Split-Path $SourceDir -Leaf)
    type     = ''
    includes = @($inc)
    units    = @($units)
    externals = [ordered]@{
        function_modules = @($callfm)
        performs         = @($perform)
        submits          = @($submit)
        transactions     = @($tcode)
    }
    db_reads  = @($reads)
    db_writes = @($writes)
    selection_screen = @($sel)
}

$map | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Output ("MAP_WRITTEN: " + $OutFile)
