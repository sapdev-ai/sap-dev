# =============================================================================
# sap_gm_manifest.ps1  -  Baseline manifest store for /sap-golden-master (LOCAL)
#
# Owns the local baseline store layout + manifest.json (schema sapdev.goldenmaster/1).
# No SAP access. Store: <StoreRoot>\<SID>_<CLIENT>\<ID>\  with manifest.json,
# golden\<leg>.raw.txt / .norm.txt, runs\<run_id>\...
#
#   create  -Id -Sid -Client [-CreatedBy]         create/ensure a baseline folder + manifest
#   addleg  -Id -LegJson '{...}'                  append a source leg to the manifest
#   sethash -Id -Leg <name> -Hash <sha1>          record a golden file hash
#   show    -Id                                   print the manifest JSON
#   list                                          list baseline IDs in the store
#   path    -Id                                   print the baseline dir
#   delete  -Id                                   remove the baseline folder
#
# Output (stdout): parseable <ACTION>: line + STATUS: OK | NOT_FOUND | ERROR
# Exit: 0 = OK | 1 = NOT_FOUND | 2 = error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,
    [string] $Id = '',
    [string] $StoreRoot = '',
    [string] $Sid = '', [string] $Client = '',
    [string] $CreatedBy = '',
    [string] $LegJson = '',
    [string] $LegFile = '',
    [string] $Leg = '', [string] $Hash = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $StoreRoot) { Write-Host "STATUS: ERROR"; Write-Host "ERROR: -StoreRoot required"; exit 2 }
$scopeDir = if ($Sid -or $Client) { Join-Path $StoreRoot "${Sid}_${Client}" } else { $StoreRoot }

Add-Type -AssemblyName System.Web.Extensions
$script:JSS = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:JSS.MaxJsonLength = [int]::MaxValue

# Self-contained recursive JSON encoder: dict/array handled structurally, scalars
# escaped via JSS (correct on plain string/number/bool; no PSObject reaches it).
# Sidesteps every PS 5.1 ConvertTo-Json / JSS-on-PSObject quirk.
function Write-JsonText {
    param($o, [int] $indent = 0)
    $pad = '    ' * $indent; $pad1 = '    ' * ($indent + 1)
    if ($null -eq $o) { return 'null' }
    if ($o -is [bool]) { return $(if ($o) { 'true' } else { 'false' }) }
    if ($o -is [int] -or $o -is [long] -or $o -is [double] -or $o -is [decimal]) { return "$o" }
    if ($o -is [System.Collections.IDictionary]) {
        $keys = @($o.Keys); if ($keys.Count -eq 0) { return '{}' }
        $items = foreach ($k in $keys) { $pad1 + ($script:JSS.Serialize("$k")) + ': ' + (Write-JsonText $o[$k] ($indent + 1)) }
        return "{`r`n" + ($items -join ",`r`n") + "`r`n$pad}"
    }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
        $arr = @($o); if ($arr.Count -eq 0) { return '[]' }
        $items = foreach ($e in $arr) { $pad1 + (Write-JsonText $e ($indent + 1)) }
        return "[`r`n" + ($items -join ",`r`n") + "`r`n$pad]"
    }
    return ($script:JSS.Serialize("$o"))
}
# Write-JsonText handles JSS's Dictionary/object[] directly (both IDictionary /
# IEnumerable), so no PSObject conversion is needed - and only strings ever reach
# JSS.Serialize, avoiding its PSObject circular-reference failure.
function Get-BaselineDir { param([string] $Id) return (Join-Path $scopeDir $Id) }
function Get-ManifestPath { param([string] $Id) return (Join-Path (Get-BaselineDir $Id) 'manifest.json') }
function Read-Manifest { param([string] $Path) return ($script:JSS.DeserializeObject((Get-Content $Path -Raw))) }
function New-JsonObj { param([string] $Json) return ($script:JSS.DeserializeObject($Json)) }
function Write-Manifest { param($Obj, [string] $Path) [System.IO.File]::WriteAllText($Path, (Write-JsonText $Obj), (New-Object System.Text.UTF8Encoding($false))) }

switch ($Action.ToLower()) {
    'create' {
        if (-not $Id) { Write-Host "STATUS: ERROR"; Write-Host "ERROR: -Id required"; exit 2 }
        $dir = Get-BaselineDir $Id
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'golden') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'runs') | Out-Null
        $mp = Get-ManifestPath $Id
        if (-not (Test-Path $mp)) {
            $m = [ordered]@{ schema='sapdev.goldenmaster/1'; id=$Id; system=@{ sid=$Sid; client=$Client }; created_by=$CreatedBy; created_on=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'); legs=@(); golden_hashes=@{}; normalization_rules=@() }
            Write-Manifest $m $mp
        }
        Write-Host "CREATED: $dir"; Write-Host "STATUS: OK"; exit 0
    }
    'sha1' {
        # SHA1 of a golden file (for the manifest golden_hashes, written by the SKILL.md).
        if (-not (Test-Path $LegFile)) { Write-Host "STATUS: NOT_FOUND"; exit 1 }
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $h = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($LegFile)) | ForEach-Object { $_.ToString('x2') }) -join ''
        Write-Host "SHA1: $h"; Write-Host "STATUS: OK"; exit 0
    }
    'show' {
        $mp = Get-ManifestPath $Id
        if (-not (Test-Path $mp)) { Write-Host "STATUS: NOT_FOUND"; exit 1 }
        Get-Content $mp -Raw | Write-Host
        Write-Host "STATUS: OK"; exit 0
    }
    'list' {
        if (Test-Path $scopeDir) {
            foreach ($d in (Get-ChildItem $scopeDir -Directory | Sort-Object Name)) {
                $mp = Join-Path $d.FullName 'manifest.json'
                if (Test-Path $mp) { try { $m = Read-Manifest $mp; Write-Host ("BASELINE: id={0} legs={1} created_on={2}" -f $m['id'], @($m['legs']).Count, $m['created_on']) } catch {} }
            }
        }
        Write-Host "STATUS: OK"; exit 0
    }
    'path' {
        $dir = Get-BaselineDir $Id
        if (-not (Test-Path $dir)) { Write-Host "STATUS: NOT_FOUND"; exit 1 }
        Write-Host "PATH: $dir"; Write-Host "STATUS: OK"; exit 0
    }
    'delete' {
        $dir = Get-BaselineDir $Id
        if (-not (Test-Path $dir)) { Write-Host "STATUS: NOT_FOUND"; exit 1 }
        Remove-Item $dir -Recurse -Force
        Write-Host "DELETED: $dir"; Write-Host "STATUS: OK"; exit 0
    }
    default { Write-Host "STATUS: ERROR"; Write-Host "ERROR: unknown action $Action"; exit 2 }
}
