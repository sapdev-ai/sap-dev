<#
  sap_compare_diff.ps1  -  normalize + diff two source trees for /sap-compare

  Invoked as a SUBPROCESS:
    powershell -NoProfile -ExecutionPolicy Bypass -File sap_compare_diff.ps1 `
      -LeftDir <dir> -RightDir <dir> -OutFile <path>

  Pairs files by name (source.txt + inc_*.txt), normalizes formatting noise,
  and writes a readable diff report. Offline; no SAP connection.
  v1 uses Compare-Object (set/line diff); upgrade to true positional unified
  hunks later if needed. Windows PowerShell 5.1-safe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $LeftDir,
    [Parameter(Mandatory)] [string] $RightDir,
    [Parameter(Mandatory)] [string] $OutFile
)
$ErrorActionPreference = 'Stop'

function Read-Norm($path) {
    if (-not (Test-Path $path)) { return $null }
    $out = foreach ($l in (Get-Content -LiteralPath $path)) {
        ($l -replace '\s+$', '')        # trailing whitespace (extend: drop gen timestamps)
    }
    ,@($out)
}

$leftFiles  = @{}
Get-ChildItem -Path $LeftDir  -Filter '*.txt' -File -ErrorAction SilentlyContinue | ForEach-Object { $leftFiles[$_.Name]  = $_.FullName }
$rightFiles = @{}
Get-ChildItem -Path $RightDir -Filter '*.txt' -File -ErrorAction SilentlyContinue | ForEach-Object { $rightFiles[$_.Name] = $_.FullName }

$allNames = @(($leftFiles.Keys + $rightFiles.Keys) | Select-Object -Unique | Sort-Object)
$report = New-Object System.Collections.Generic.List[string]
$changed = 0; $onlyL = @(); $onlyR = @()

foreach ($name in $allNames) {
    $report.Add("==== $name ====")
    if (-not $rightFiles.ContainsKey($name)) { $report.Add("  (only on LEFT)");  $onlyL += $name; continue }
    if (-not $leftFiles.ContainsKey($name))  { $report.Add("  (only on RIGHT)"); $onlyR += $name; continue }
    $l = Read-Norm $leftFiles[$name]
    $r = Read-Norm $rightFiles[$name]
    $cmp = Compare-Object -ReferenceObject $l -DifferenceObject $r
    if (-not $cmp) { $report.Add("  identical"); continue }
    $changed++
    foreach ($c in $cmp) {
        $side = if ($c.SideIndicator -eq '<=') { 'LEFT ' } else { 'RIGHT' }
        $report.Add(("  [{0}] {1}" -f $side, $c.InputObject))
    }
}

$report | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Output ("DIFF_FILES_CHANGED: $changed")
if ($onlyL) { Write-Output ("ONLY_LEFT: "  + ($onlyL -join ',')) }
if ($onlyR) { Write-Output ("ONLY_RIGHT: " + ($onlyR -join ',')) }
Write-Output ("DIFF_WRITTEN: " + $OutFile)
