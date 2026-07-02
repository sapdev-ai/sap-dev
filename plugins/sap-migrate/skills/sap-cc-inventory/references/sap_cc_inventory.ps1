# sap-cc-inventory helper -- enumerate custom (Z/Y) repository objects
#
# Two source modes:
#   RFC (default) -- READ-ONLY RFC against the campaign SOURCE system (NCo 3.1,
#                    32-bit PowerShell). Reads TADIR + TRDIR directly.
#   GUI           -- OFFLINE ingest of /sap-se16n exports of TADIR (+ optional
#                    TRDIR), for sites where RFC to the source is blocked. No
#                    NCo / no SAP here -- the GUI export is produced by
#                    /sap-se16n (the SKILL.md drives it); this helper just parses
#                    the TSV. Runs in any PowerShell.
#
# Both modes write {CampaignDir}\inventory.tsv and upsert {CampaignDir}\state.tsv
# as INVENTORIED (never altering objects already further along).
#
# Run RFC mode with 32-bit PowerShell (NCo 3.1 lives in GAC_32):
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File ...
#
# Params:
#   -CampaignDir <dir>    (required) the campaign workspace
#   -SourceMode <RFC|GUI> (default RFC)
#   -WorkDir <dir>        (RFC) anchors the connection store (sets SAPDEV_AI_WORK_DIR)
#   -SharedDir <dir>      (RFC) absolute path to sap-dev-core\shared\scripts
#   -SourceProfile <ref>  (RFC) connection profile; else campaign.json source_profile; else pinned
#   -TadirFile <path>     (GUI) /sap-se16n export of TADIR (required in GUI mode)
#   -TrdirFile <path>     (GUI) /sap-se16n export of TRDIR (optional; PROG sub_type enrichment)
#   -Namespace <list>     object-name prefixes (default from campaign.json scope, else 'Z,Y')
#   -Packages <list>      DEVCLASS patterns (overrides namespace enumeration)
#   -Types <list>         TADIR OBJECT values to keep (default: all)
#   -Exclude <list>       OBJ_NAME -like patterns to drop
#
# Output grammar (parseable; matches the sap-cc line style):
#   INVENTORY: total=<n> new=<n> existing=<n> file=<path>
#   TYPE: <OBJECT> | COUNT: <n>
#   STATUS: OK | STATUS: PARTIAL failed_slices=<k> | STATUS: EMPTY | STATUS: ERROR
# Exit: 0 ok | 1 empty (no objects in scope) | 2 error (bad workspace / RFC /
#       missing export; also when ALL namespace/package slices fail -- nothing
#       is written then) | 3 partial (RFC mode: <k> slice(s) failed, others
#       succeeded; inventory.tsv IS written but INCOMPLETE -- it must not
#       silently become the campaign scope)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CampaignDir,
    [ValidateSet('RFC','GUI')][string]$SourceMode = 'RFC',
    [string]$WorkDir = '',
    [string]$SharedDir = '',
    [string]$SourceProfile = '',
    [string]$TadirFile = '',
    [string]$TrdirFile = '',
    [string]$Namespace = '',
    [string]$Packages = '',
    [string]$Types = '',
    [string]$Exclude = ''
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Get-Content:Encoding'] = 'UTF8'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Text,$enc)
}
function Norm([string]$s){ return ($s -replace '[^A-Za-z0-9]','').ToLower() }
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

# Scope test shared by both modes (PowerShell -like). pkgPats wins over prefixes.
function Test-InScope([string]$objName,[string]$devclass,$prefixes,$pkgPats){
    if ($pkgPats.Count -gt 0) {
        foreach ($p in $pkgPats) { if ($devclass -like $p) { return $true } }
        return $false
    }
    if ($prefixes.Count -gt 0) {
        foreach ($pf in $prefixes) { $pp = $pf.TrimEnd('*'); if ($objName -like "$pp*") { return $true } }
        return $false
    }
    return $true
}

# Parse a /sap-se16n export (TAB-delimited; first line = technical field names).
# Returns @{ idx = @{normHeader -> colIndex}; rows = @(@(cells)) } or $null if absent.
function Parse-Se16nExport([string]$path){
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $out = @{ idx = @{}; rows = @() }
    $lines = @(Get-Content -LiteralPath $path)
    if ($lines.Count -lt 1) { return $out }
    if ($lines[0] -match '^NO_DATA') { return $out }   # SE16N "no values found" marker
    # SE16N read FAILURE marker (auth / lock / invalid table). Distinct from an
    # empty result: an unreadable export must NOT be parsed as an inventory.
    # Return the empty structure -> the header check downstream fails closed
    # (exit 2) rather than treating "QUERY_FAILED<TAB>msg" as a data header.
    if ($lines[0] -match '^QUERY_FAILED') { return $out }
    $hdr = @($lines[0].Split("`t") | ForEach-Object { $_.Trim() })
    for ($i = 0; $i -lt $hdr.Count; $i++){ if (-not $out.idx.ContainsKey((Norm $hdr[$i]))) { $out.idx[(Norm $hdr[$i])] = $i } }
    for ($i = 1; $i -lt $lines.Count; $i++){ if ($lines[$i].Trim()) { $out.rows += ,@($lines[$i].Split("`t")) } }
    return $out
}

# Shared emit: write inventory.tsv + upsert state.tsv + per-type counts.
# Returns the process exit code (0 ok / 1 empty / 3 partial). A non-zero
# $FailedSlices (RFC mode: per-WHERE RFC_READ_TABLE failures) downgrades an OK
# run to STATUS: PARTIAL -- the files are written, but the caller must treat
# the inventory as incomplete, never as the campaign scope.
function Emit-Inventory([string]$CampaignDir,$allRows,$subcMap,[int]$FailedSlices = 0){
    $invPath = Join-Path $CampaignDir 'inventory.tsv'
    if ($allRows.Count -eq 0) {
        Write-Utf8NoBom $invPath "obj_name`tobj_type`tsub_type`tpackage`tapp_component`tauthor`tcreated_on`tchanged_on`r`n"
        Write-Output "INVENTORY: total=0 new=0 existing=0 file=$invPath"
        Write-Output 'STATUS: EMPTY'
        return 1
    }
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("obj_name`tobj_type`tsub_type`tpackage`tapp_component`tauthor`tcreated_on`tchanged_on")
    foreach ($r in ($allRows | Sort-Object OBJECT, OBJ_NAME)) {
        $st = ''
        if ($r.OBJECT -eq 'PROG' -and $subcMap.ContainsKey($r.OBJ_NAME)) { $st = Map-Subc $subcMap[$r.OBJ_NAME] }
        $L.Add("$($r.OBJ_NAME)`t$($r.OBJECT)`t$st`t$($r.DEVCLASS)`t`t$($r.AUTHOR)`t`t")
    }
    Write-Utf8NoBom $invPath (($L -join "`r`n") + "`r`n")

    # Upsert state.tsv (owned by /sap-cc-campaign). Add INVENTORIED rows for new
    # objects only; never touch rows already further along.
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

    $byType = $allRows | Group-Object OBJECT | Sort-Object Name
    foreach ($g in $byType) { Write-Output "TYPE: $($g.Name) | COUNT: $($g.Count)" }
    Write-Output "INVENTORY: total=$($allRows.Count) new=$($newLines.Count) existing=$existingHit file=$invPath"
    if ($FailedSlices -gt 0) {
        Write-Output "STATUS: PARTIAL failed_slices=$FailedSlices"
        return 3
    }
    Write-Output 'STATUS: OK'
    return 0
}

# --- campaign.json (both modes) ----------------------------------------------
$cjson = Join-Path $CampaignDir 'campaign.json'
if (-not (Test-Path -LiteralPath $cjson)) { Write-Output "ERROR: campaign workspace not found at $CampaignDir (run /sap-cc-campaign init)"; Write-Output 'STATUS: ERROR'; exit 2 }
$camp = $null
try { $camp = Get-Content -LiteralPath $cjson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Output "ERROR: cannot parse campaign.json: $($_.Exception.Message)"; Write-Output 'STATUS: ERROR'; exit 2 }

# Resolve scope (prefixes vs package patterns) + post-filters, shared by both modes.
$prefixes = @()
$pkgPats = @()
if (-not [string]::IsNullOrWhiteSpace($Packages)) {
    $pkgPats = @($Packages -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} else {
    if (-not [string]::IsNullOrWhiteSpace($Namespace)) {
        $prefixes = @($Namespace -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } elseif ($camp.scope -and $camp.scope.in_scope_packages) {
        $prefixes = @($camp.scope.in_scope_packages | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    }
    if ($prefixes.Count -eq 0) { $prefixes = @('Z','Y') }
}
$tset = @{}
if (-not [string]::IsNullOrWhiteSpace($Types)) { foreach ($t in ($Types -split ',')) { $tt = $t.Trim().ToUpper(); if ($tt) { $tset[$tt] = $true } } }
$expat = @()
if (-not [string]::IsNullOrWhiteSpace($Exclude)) { $expat = @($Exclude -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Apply-Filters($rows){
    $r2 = @($rows)
    if ($tset.Count -gt 0) { $r2 = @($r2 | Where-Object { $tset.ContainsKey($_.OBJECT.ToUpper()) }) }
    if ($expat.Count -gt 0) {
        $r2 = @($r2 | Where-Object {
            $nm = $_.OBJ_NAME; $keep = $true
            foreach ($e in $expat) { if ($nm -like $e) { $keep = $false; break } }
            $keep
        })
    }
    return @($r2)
}

# =========================== GUI MODE (offline) ==============================
if ($SourceMode -eq 'GUI') {
    try {
        if ([string]::IsNullOrWhiteSpace($TadirFile)) { Write-Output 'ERROR: GUI mode requires -TadirFile (a /sap-se16n export of TADIR)'; Write-Output 'STATUS: ERROR'; exit 2 }
        $td = Parse-Se16nExport $TadirFile
        if ($null -eq $td) { Write-Output "ERROR: TADIR export not found: $TadirFile"; Write-Output 'STATUS: ERROR'; exit 2 }
        if (-not $td.idx.ContainsKey('objname')) { Write-Output "ERROR: TADIR export has no OBJ_NAME column (headers: $((@($td.idx.Keys)) -join ','))"; Write-Output 'STATUS: ERROR'; exit 2 }
        $iObj = if ($td.idx.ContainsKey('object'))   { $td.idx['object'] }   else { -1 }
        $iName = $td.idx['objname']
        $iDc  = if ($td.idx.ContainsKey('devclass')) { $td.idx['devclass'] } else { -1 }
        $iAu  = if ($td.idx.ContainsKey('author'))   { $td.idx['author'] }   else { -1 }
        $iPg  = if ($td.idx.ContainsKey('pgmid'))    { $td.idx['pgmid'] }    else { -1 }
        $acc = @{}
        foreach ($row in $td.rows){
            $nm = if ($iName -ge 0 -and $iName -lt $row.Length) { $row[$iName].Trim() } else { '' }
            if (-not $nm) { continue }
            if ($iPg -ge 0 -and $iPg -lt $row.Length) { $pg = $row[$iPg].Trim(); if ($pg -and $pg.ToUpper() -ne 'R3TR') { continue } }
            $obj = if ($iObj -ge 0 -and $iObj -lt $row.Length) { $row[$iObj].Trim() } else { '' }
            $dc  = if ($iDc  -ge 0 -and $iDc  -lt $row.Length) { $row[$iDc].Trim() }  else { '' }
            $au  = if ($iAu  -ge 0 -and $iAu  -lt $row.Length) { $row[$iAu].Trim() }  else { '' }
            if (-not (Test-InScope $nm $dc $prefixes $pkgPats)) { continue }
            $acc["$obj|$nm"] = [pscustomobject]@{ OBJECT = $obj; OBJ_NAME = $nm; DEVCLASS = $dc; AUTHOR = $au }
        }
        $allRows = Apply-Filters @($acc.Values)

        # Optional PROG sub_type enrichment from a TRDIR export.
        $subcMap = @{}
        if (-not [string]::IsNullOrWhiteSpace($TrdirFile)) {
            $tr = Parse-Se16nExport $TrdirFile
            if ($null -ne $tr -and $tr.idx.ContainsKey('name') -and $tr.idx.ContainsKey('subc')) {
                $jn = $tr.idx['name']; $js = $tr.idx['subc']
                foreach ($row in $tr.rows){
                    $nm = if ($jn -lt $row.Length) { $row[$jn].Trim() } else { '' }
                    $sc = if ($js -lt $row.Length) { $row[$js].Trim() } else { '' }
                    if ($nm) { $subcMap[$nm] = $sc }
                }
            }
        }
        exit (Emit-Inventory $CampaignDir $allRows $subcMap)
    }
    catch {
        Write-Output "ERROR: $($_.Exception.Message)"; Write-Output 'STATUS: ERROR'; exit 2
    }
}

# =========================== RFC MODE ========================================
# Anchor the connection store so Resolve-SapProfileHint resolves the right work_dir.
if (-not [string]::IsNullOrWhiteSpace($WorkDir)) { $env:SAPDEV_AI_WORK_DIR = $WorkDir }
if ([string]::IsNullOrWhiteSpace($SharedDir)) {
    $SharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) 'sap-dev-core\shared\scripts'
}
foreach ($lib in @('sap_rfc_lib.ps1','sap_settings_lib.ps1','sap_connection_lib.ps1')){
    $p = Join-Path $SharedDir $lib
    if (-not (Test-Path -LiteralPath $p)) { Write-Output "ERROR: shared lib not found: $p"; Write-Output 'STATUS: ERROR'; exit 2 }
    . $p
}

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

try {
    $srcProf = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile }
               elseif ($camp.systems) { "$($camp.systems.source_profile)" } else { '' }

    $dest = Resolve-SourceDest $srcProf
    if (-not $dest) { Write-Output 'STATUS: ERROR'; exit 2 }

    # Build the WHERE clauses: package enumeration (if -Packages) else name-prefix.
    $wheres = @()
    if ($pkgPats.Count -gt 0) {
        foreach ($pat in $pkgPats) {
            $pp = $pat.Replace("'", '').Replace('*', '%')
            if ($pp) { $wheres += "PGMID = 'R3TR' AND DEVCLASS LIKE '$pp'" }
        }
    } else {
        foreach ($pf in $prefixes) {
            $pp = $pf.Replace("'", '').TrimEnd('*')
            if ($pp) { $wheres += "PGMID = 'R3TR' AND OBJ_NAME LIKE '$pp%'" }
        }
    }

    # Fetch + dedupe on OBJECT|OBJ_NAME. Track failed slices: a namespace/
    # package WHERE that errors out silently missing from the inventory would
    # otherwise become the campaign scope.
    $acc = @{}
    $failedSlices = 0
    foreach ($w in $wheres) {
        $rows = @()
        try { $rows = @(Read-TadirRows $dest $w) }
        catch { $failedSlices++; Write-Output "ERROR: RFC_READ_TABLE TADIR failed for [$w]: $($_.Exception.Message)" }
        foreach ($r in $rows) { $acc["$($r.OBJECT)|$($r.OBJ_NAME)"] = $r }
    }
    $allRows = Apply-Filters @($acc.Values)

    # Any failure + nothing read (covers the all-slices-failed case) => hard
    # ERROR, and do NOT write inventory.tsv / state.tsv (an empty write would
    # clobber a previous good inventory with nothing).
    if ($failedSlices -gt 0 -and @($allRows).Count -eq 0) {
        Write-Output "ERROR: $failedSlices of $($wheres.Count) TADIR slice(s) failed and no rows were read -- inventory NOT written"
        Write-Output 'STATUS: ERROR'
        Disconnect-SapRfc
        exit 2
    }

    # sub_type enrichment (PROG only, namespace-enumeration path).
    $subcMap = @{}
    if ($pkgPats.Count -eq 0 -and $prefixes.Count -gt 0 -and @($allRows | Where-Object { $_.OBJECT -eq 'PROG' }).Count -gt 0) {
        foreach ($pf in $prefixes) {
            $pp = $pf.Replace("'", '').TrimEnd('*')
            if ($pp) {
                try { $m = Read-TrdirSubc $dest "NAME LIKE '$pp%'"; foreach ($k in $m.Keys) { $subcMap[$k] = $m[$k] } } catch {}
            }
        }
    }

    Disconnect-SapRfc
    exit (Emit-Inventory $CampaignDir $allRows $subcMap $failedSlices)
}
catch {
    try { Disconnect-SapRfc } catch {}
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output 'STATUS: ERROR'
    exit 2
}
