# sap-cc-inventory helper -- enumerate custom (Z/Y) repository objects (NCo 3.1)
#
# READ-ONLY RFC against the campaign's SOURCE system. No SAP GUI, no writes.
# Reads TADIR (object directory) + TRDIR (program sub-type), writes
# {CampaignDir}\inventory.tsv, and upserts each object into {CampaignDir}\state.tsv
# as INVENTORIED (never altering objects already further along).
#
# Run with 32-bit PowerShell (NCo 3.1 lives in GAC_32):
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File ...
#
# Params:
#   -CampaignDir <dir>   (required) the campaign workspace
#   -WorkDir <dir>       anchors the connection store (sets SAPDEV_AI_WORK_DIR)
#   -SharedDir <dir>     absolute path to sap-dev-core\shared\scripts
#   -SourceProfile <ref> connection profile to analyze; else campaign.json
#                        systems.source_profile; else the pinned connection
#   -Namespace <list>    object-name prefixes (default from campaign.json scope, else 'Z,Y')
#   -Packages <list>     DEVCLASS patterns (overrides namespace enumeration)
#   -Types <list>        TADIR OBJECT values to keep (default: all)
#   -Exclude <list>      OBJ_NAME -like patterns to drop
#
# Output grammar (parseable; matches the sap-cc line style):
#   INVENTORY: total=<n> new=<n> existing=<n> file=<path>
#   TYPE: <OBJECT> | COUNT: <n>
#   STATUS: OK | STATUS: EMPTY | STATUS: ERROR
# Exit: 0 ok | 1 empty (no objects in scope) | 2 error (bad workspace / RFC)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CampaignDir,
    [string]$WorkDir = '',
    [string]$SharedDir = '',
    [string]$SourceProfile = '',
    [string]$Namespace = '',
    [string]$Packages = '',
    [string]$Types = '',
    [string]$Exclude = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}

# Anchor the connection store so Resolve-SapProfileHint resolves the right work_dir.
if (-not [string]::IsNullOrWhiteSpace($WorkDir)) { $env:SAPDEV_AI_WORK_DIR = $WorkDir }

# Resolve the shared scripts dir (default: 4 levels up from this references/ dir).
if ([string]::IsNullOrWhiteSpace($SharedDir)) {
    $SharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) 'sap-dev-core\shared\scripts'
}
foreach ($lib in @('sap_rfc_lib.ps1','sap_settings_lib.ps1','sap_connection_lib.ps1')){
    $p = Join-Path $SharedDir $lib
    if (-not (Test-Path -LiteralPath $p)) { Write-Output "ERROR: shared lib not found: $p"; Write-Output 'STATUS: ERROR'; exit 2 }
    . $p
}

$cjson = Join-Path $CampaignDir 'campaign.json'
if (-not (Test-Path -LiteralPath $cjson)) { Write-Output "ERROR: campaign workspace not found at $CampaignDir (run /sap-cc-campaign init)"; Write-Output 'STATUS: ERROR'; exit 2 }
$camp = $null
try { $camp = Get-Content -LiteralPath $cjson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Output "ERROR: cannot parse campaign.json: $($_.Exception.Message)"; Write-Output 'STATUS: ERROR'; exit 2 }

# --- Resolve the source connection and connect (read-only) -------------------
function Resolve-SourceDest([string]$srcProfile){
    if ([string]::IsNullOrWhiteSpace($srcProfile)) {
        return (Connect-SapRfc -DestName 'CCINV')   # pinned-profile fallback
    }
    $m = @(Resolve-SapProfileHint -Hint $srcProfile)
    if ($m.Count -eq 0) { Write-Output "ERROR: source profile '$srcProfile' not found in the connection store (run /sap-login --list)"; return $null }
    if ($m.Count -gt 1) { Write-Output "ERROR: source profile '$srcProfile' is ambiguous ($($m.Count) matches); use a more specific ref (SID/CLIENT) or the UUID"; return $null }
    $p = $m[0]
    $pw = ''
    if (-not [string]::IsNullOrWhiteSpace("$($p.password_dpapi)")) {
        try {
            $pw = (& (Join-Path $SharedDir 'sap_dpapi.ps1') -Action unprotect -Value "$($p.password_dpapi)" 2>$null) -as [string]
            if ($pw) { $pw = $pw.Trim() }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($pw)) { Write-Output "ERROR: source profile '$($p.description)' has no decryptable password; run /sap-login to save it"; return $null }
    if (-not [string]::IsNullOrWhiteSpace("$($p.message_server)")) {
        return (Connect-SapRfc -MessageServer "$($p.message_server)" -LogonGroup "$($p.logon_group)" -SystemID "$($p.system_id)" `
                               -Client "$($p.client)" -User "$($p.user)" -Password $pw -Language "$($p.language)" -DestName 'CCINV')
    }
    return (Connect-SapRfc -Server "$($p.application_server)" -Sysnr "$($p.system_number)" `
                           -Client "$($p.client)" -User "$($p.user)" -Password $pw -Language "$($p.language)" -DestName 'CCINV')
}

# --- RFC_READ_TABLE helpers (via the guarded New-RfcReadTable entry point) ----
function Read-TadirRows($dest,[string]$where){
    $rows = @()
    $fn = New-RfcReadTable -Destination $dest -Table 'TADIR' -Delimiter '|'
    Add-RfcField $fn 'OBJECT'; Add-RfcField $fn 'OBJ_NAME'; Add-RfcField $fn 'DEVCLASS'; Add-RfcField $fn 'AUTHOR'
    Add-RfcOption $fn $where
    [void]$fn.Invoke($dest)
    $d = $fn.GetTable('DATA')
    for ($i = 0; $i -lt $d.RowCount; $i++){
        $d.CurrentIndex = $i
        $parts = ([string]$d.GetString('WA')).Split('|')
        $obj = if ($parts.Length -gt 0) { $parts[0].Trim() } else { '' }
        $nm  = if ($parts.Length -gt 1) { $parts[1].Trim() } else { '' }
        $dc  = if ($parts.Length -gt 2) { $parts[2].Trim() } else { '' }
        $au  = if ($parts.Length -gt 3) { $parts[3].Trim() } else { '' }
        if ($nm) { $rows += [pscustomobject]@{ OBJECT=$obj; OBJ_NAME=$nm; DEVCLASS=$dc; AUTHOR=$au } }
    }
    return $rows
}
function Read-TrdirSubc($dest,[string]$where){
    $h = @{}
    $fn = New-RfcReadTable -Destination $dest -Table 'TRDIR' -Delimiter '|'
    Add-RfcField $fn 'NAME'; Add-RfcField $fn 'SUBC'
    Add-RfcOption $fn $where
    [void]$fn.Invoke($dest)
    $d = $fn.GetTable('DATA')
    for ($i = 0; $i -lt $d.RowCount; $i++){
        $d.CurrentIndex = $i
        $parts = ([string]$d.GetString('WA')).Split('|')
        $nm = if ($parts.Length -gt 0) { $parts[0].Trim() } else { '' }
        $sc = if ($parts.Length -gt 1) { $parts[1].Trim() } else { '' }
        if ($nm) { $h[$nm] = $sc }
    }
    return $h
}
function Map-Subc([string]$subc){
    switch ($subc) {
        '1' { 'REPORT' }
        'M' { 'MODULE_POOL' }
        'I' { 'INCLUDE' }
        'S' { 'SUBROUTINE_POOL' }
        'F' { 'FUNCTION_POOL' }
        'K' { 'CLASS_POOL' }
        'J' { 'INTERFACE_POOL' }
        default { if ($subc) { "SUBC_$subc" } else { '' } }
    }
}

# --- Main --------------------------------------------------------------------
try {
    $srcProf = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile }
               elseif ($camp.systems) { "$($camp.systems.source_profile)" } else { '' }

    $dest = Resolve-SourceDest $srcProf
    if (-not $dest) { Write-Output 'STATUS: ERROR'; exit 2 }

    # Build the WHERE clauses: package enumeration (if -Packages) else name-prefix.
    $wheres = @()
    $prefixes = @()
    if (-not [string]::IsNullOrWhiteSpace($Packages)) {
        foreach ($pat in ($Packages -split ',')) {
            $pp = $pat.Trim().Replace("'", '').Replace('*', '%')
            if ($pp) { $wheres += "PGMID = 'R3TR' AND DEVCLASS LIKE '$pp'" }
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($Namespace)) {
            $prefixes = @($Namespace -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } elseif ($camp.scope -and $camp.scope.in_scope_packages) {
            $prefixes = @($camp.scope.in_scope_packages | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        }
        if ($prefixes.Count -eq 0) { $prefixes = @('Z','Y') }
        foreach ($pf in $prefixes) {
            $pp = $pf.Replace("'", '').TrimEnd('*')
            if ($pp) { $wheres += "PGMID = 'R3TR' AND OBJ_NAME LIKE '$pp%'" }
        }
    }

    # Fetch + dedupe on OBJECT|OBJ_NAME.
    $acc = @{}
    foreach ($w in $wheres) {
        $rows = @()
        try { $rows = @(Read-TadirRows $dest $w) }
        catch { Write-Output "ERROR: RFC_READ_TABLE TADIR failed for [$w]: $($_.Exception.Message)" }
        foreach ($r in $rows) { $acc["$($r.OBJECT)|$($r.OBJ_NAME)"] = $r }
    }
    $allRows = @($acc.Values)

    # Type filter.
    if (-not [string]::IsNullOrWhiteSpace($Types)) {
        $tset = @{}
        foreach ($t in ($Types -split ',')) { $tt = $t.Trim().ToUpper(); if ($tt) { $tset[$tt] = $true } }
        $allRows = @($allRows | Where-Object { $tset.ContainsKey($_.OBJECT.ToUpper()) })
    }
    # Exclude filter (OBJ_NAME -like patterns).
    if (-not [string]::IsNullOrWhiteSpace($Exclude)) {
        $expat = @($Exclude -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $allRows = @($allRows | Where-Object {
            $nm = $_.OBJ_NAME; $keep = $true
            foreach ($e in $expat) { if ($nm -like $e) { $keep = $false; break } }
            $keep
        })
    }

    # sub_type enrichment (PROG only, namespace-enumeration path).
    $subcMap = @{}
    if ([string]::IsNullOrWhiteSpace($Packages) -and $prefixes.Count -gt 0 -and @($allRows | Where-Object { $_.OBJECT -eq 'PROG' }).Count -gt 0) {
        foreach ($pf in $prefixes) {
            $pp = $pf.Replace("'", '').TrimEnd('*')
            if ($pp) {
                try { $m = Read-TrdirSubc $dest "NAME LIKE '$pp%'"; foreach ($k in $m.Keys) { $subcMap[$k] = $m[$k] } } catch {}
            }
        }
    }

    Disconnect-SapRfc

    if ($allRows.Count -eq 0) {
        $invPath = Join-Path $CampaignDir 'inventory.tsv'
        Write-Utf8NoBom $invPath "obj_name`tobj_type`tsub_type`tpackage`tapp_component`tauthor`tcreated_on`tchanged_on`r`n"
        Write-Output "INVENTORY: total=0 new=0 existing=0 file=$invPath"
        Write-Output 'STATUS: EMPTY'
        exit 1
    }

    # Write inventory.tsv (owner of this file).
    $invPath = Join-Path $CampaignDir 'inventory.tsv'
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("obj_name`tobj_type`tsub_type`tpackage`tapp_component`tauthor`tcreated_on`tchanged_on")
    foreach ($r in ($allRows | Sort-Object OBJECT, OBJ_NAME)) {
        $st = ''
        if ($r.OBJECT -eq 'PROG' -and $subcMap.ContainsKey($r.OBJ_NAME)) { $st = Map-Subc $subcMap[$r.OBJ_NAME] }
        # columns: obj_name, obj_type, sub_type, package, app_component(blank), author, created_on(blank), changed_on(blank)
        $L.Add("$($r.OBJ_NAME)`t$($r.OBJECT)`t$st`t$($r.DEVCLASS)`t`t$($r.AUTHOR)`t`t")
    }
    Write-Utf8NoBom $invPath (($L -join "`r`n") + "`r`n")

    # Upsert state.tsv (owned by /sap-cc-campaign; upserted here). Add INVENTORIED
    # rows for newly-discovered objects only; never touch rows already further along.
    $statePath = Join-Path $CampaignDir 'state.tsv'
    $header = "obj_name`tobj_type`tstate`ttier`tdecision`tupdated_on"
    $existingLines = @()
    $existingKeys = @{}
    if (Test-Path -LiteralPath $statePath) {
        $all = @(Get-Content -LiteralPath $statePath)
        if ($all.Count -ge 2) {
            $existingLines = @($all[1..($all.Count - 1)])
            foreach ($ln in $existingLines) {
                if ($ln.Trim()) { $f = $ln.Split("`t"); if ($f.Length -ge 2) { $existingKeys["$($f[0])|$($f[1])"] = $true } }
            }
        }
    }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $newLines = @()
    $existingHit = 0
    foreach ($r in ($allRows | Sort-Object OBJECT, OBJ_NAME)) {
        $key = "$($r.OBJ_NAME)|$($r.OBJECT)"
        if ($existingKeys.ContainsKey($key)) { $existingHit++; continue }
        $newLines += "$($r.OBJ_NAME)`t$($r.OBJECT)`tINVENTORIED`t-`t-`t$today"
    }
    $out = @($header) + $existingLines + $newLines
    Write-Utf8NoBom $statePath (($out -join "`r`n") + "`r`n")

    # Per-type counts (stable order).
    $byType = $allRows | Group-Object OBJECT | Sort-Object Name
    foreach ($g in $byType) { Write-Output "TYPE: $($g.Name) | COUNT: $($g.Count)" }
    Write-Output "INVENTORY: total=$($allRows.Count) new=$($newLines.Count) existing=$existingHit file=$invPath"
    Write-Output 'STATUS: OK'
    exit 0
}
catch {
    try { Disconnect-SapRfc } catch {}
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
