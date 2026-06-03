<#
  sap_compare_ddic.ps1  -  cross-system DDIC field diff for /sap-compare

  Invoked as a SUBPROCESS:
    powershell -NoProfile -ExecutionPolicy Bypass -File sap_compare_ddic.ps1 `
      -Object <name> -Type <table|structure|dataelement|domain|tabletype> `
      -Against <profile-hint> -OutDir <dir>

  Connects LEFT (pinned) + RIGHT (--against profile), fetches the DDIC
  definition on each over RFC, diffs them, and writes diff.json +
  left.def/right.def. Read-only. The DDIF/DD0xL fetch idioms are copied from the
  proven sap_rfc_lookup_ddic.ps1. Windows PowerShell 5.1-safe.

  NOTE: sap_dpapi.ps1 is invoked as a subprocess (&), never dot-sourced — a
  dot-sourced param() block would clobber this script's params.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Object,
    [Parameter(Mandatory)] [ValidateSet('table','structure','dataelement','domain','tabletype')] [string] $Type,
    [Parameter(Mandatory)] [string] $Against,
    [Parameter(Mandatory)] [string] $OutDir
)
$ErrorActionPreference = 'Stop'
$Object = $Object.ToUpper()

# Resolve shared\scripts (references -> sap-compare -> skills -> sap-dev-core -> shared\scripts).
$shared = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\shared\scripts')).Path
. (Join-Path $shared 'sap_connection_lib.ps1')
. (Join-Path $shared 'sap_rfc_lib.ps1')

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
function Fail($msg) { Write-Output "ERROR: $msg"; exit 2 }

# --- resolve RIGHT, refuse on ambiguity ------------------------------------
$cands = @(Resolve-SapProfileHint -Hint $Against)
if ($cands.Count -eq 0) { Fail "profile '$Against' not found" }
if ($cands.Count -gt 1) { Fail "'$Against' is ambiguous - qualify as <SID>/<CLIENT>/<USER>" }
$t  = $cands[0]
$pw = (& (Join-Path $shared 'sap_dpapi.ps1') -Action unprotect -Value "$($t.password_dpapi)" 2>$null) -as [string]

# --- connect both -----------------------------------------------------------
$left = Connect-SapRfc -DestName 'CMP_LEFT'
if (-not $left) { Fail 'LEFT not connected (run /sap-login)' }
$right = Connect-SapRfc -Server $t.application_server -Sysnr $t.system_number `
          -MessageServer $t.message_server -LogonGroup $t.logon_group -SystemID $t.system_id `
          -Client $t.client -User $t.user -Password $pw -Language $t.language -DestName 'CMP_RIGHT'
if (-not $right) { Fail "RIGHT '$Against' not connected (RFC creds / DPAPI / reachability)" }

$lp = $null; try { $lp = Get-SapCurrentConnectionProfile } catch {}

# --- read one row from a DDIC catalog table via guarded RFC_READ_TABLE ------
function Read-RowVia($dest, $table, $where, $fields) {
    try {
        $rt = New-RfcReadTable -Destination $dest -Table $table
        [void]$rt.SetValue("ROWCOUNT", 1)
        Add-RfcOption $rt $where
        foreach ($f in $fields) { Add-RfcField $rt $f }
        $null = $rt.Invoke($dest)
        $d = $rt.GetTable("DATA")
        if ([int]$d.RowCount -le 0) { return $null }
        $d.CurrentIndex = 0
        $parts = ([string]$d.GetString("WA")).Split('|')
        $out = @{}
        for ($i = 0; $i -lt $fields.Count; $i++) {
            $v = if ($i -lt $parts.Length) { $parts[$i].Trim() } else { '' }
            $out[$fields[$i]] = $v
        }
        return $out
    } catch { return $null }
}

# --- fetch a normalized field list on one destination ----------------------
# Returns @( [pscustomobject]{ name; datatype; len; dec; pos } ) or $null if absent.
# Scalar DDIC objects (DE/domain/table type) are modeled as a single "field"
# keyed by the object name so the diff classifies datatype/length changes.
# LANGU is fixed to 'E' — it only affects field TEXT, which we never read; the
# structural attributes (name/datatype/length/decimals) are language-independent.
function Get-DdicFields($dest, $name, $type) {
    switch ($type) {
        { $_ -in @('table','structure') } {
            try {
                $fn = $dest.Repository.CreateFunction("DDIF_FIELDINFO_GET")
                [void]$fn.SetValue("TABNAME", $name)
                [void]$fn.SetValue("LANGU",   "E")
                $null = $fn.Invoke($dest)
                $tab = $fn.GetTable("DFIES_TAB")
                if ([int]$tab.RowCount -le 0) { return $null }
                $fields = @()
                for ($r = 0; $r -lt [int]$tab.RowCount; $r++) {
                    $tab.CurrentIndex = $r
                    $fname = ([string]$tab.GetString("FIELDNAME")).Trim().ToUpper()
                    if ($fname -eq '' -or $fname -eq '.INCLUDE') { continue }
                    $pos = ''
                    try { $pos = ([string]$tab.GetString("POSITION")).Trim() } catch { $pos = '' }
                    $fields += [pscustomobject]@{
                        name     = $fname
                        datatype = ([string]$tab.GetString("DATATYPE")).Trim().ToUpper()
                        len      = ([string]$tab.GetString("LENG")).Trim()
                        dec      = ([string]$tab.GetString("DECIMALS")).Trim()
                        pos      = $pos
                    }
                }
                return ,$fields
            } catch { return $null }
        }
        'dataelement' {
            $row = Read-RowVia $dest 'DD04L' "ROLLNAME = '$name' AND AS4LOCAL = 'A'" @('DATATYPE','LENG','DECIMALS')
            if (-not $row) { return $null }
            return ,@([pscustomobject]@{ name = $name; datatype = ([string]$row['DATATYPE']).ToUpper(); len = $row['LENG']; dec = $row['DECIMALS']; pos = '1' })
        }
        'domain' {
            $row = Read-RowVia $dest 'DD01L' "DOMNAME = '$name' AND AS4LOCAL = 'A'" @('DATATYPE','LENG','DECIMALS')
            if (-not $row) { return $null }
            return ,@([pscustomobject]@{ name = $name; datatype = ([string]$row['DATATYPE']).ToUpper(); len = $row['LENG']; dec = $row['DECIMALS']; pos = '1' })
        }
        'tabletype' {
            $row = Read-RowVia $dest 'DD40L' "TYPENAME = '$name' AND AS4LOCAL = 'A'" @('ROWTYPE','ROWKIND')
            if (-not $row) { return $null }
            return ,@([pscustomobject]@{ name = $name; datatype = ([string]$row['ROWTYPE']).ToUpper(); len = $row['ROWKIND']; dec = ''; pos = '1' })
        }
    }
    return $null
}

$lf = Get-DdicFields $left  $Object $Type
$rf = Get-DdicFields $right $Object $Type

# --- structured diff (offline) ---------------------------------------------
function Diff-Fields($l, $r) {
    $li = @{}; if ($l) { foreach ($f in $l) { $li[$f.name] = $f } }
    $ri = @{}; if ($r) { foreach ($f in $r) { $ri[$f.name] = $f } }
    $added=@(); $removed=@(); $typeChanged=@(); $lenChanged=@()
    foreach ($k in $ri.Keys) { if (-not $li.ContainsKey($k)) { $x=$ri[$k]; $added   += [pscustomobject]@{ field=$x.name; datatype=$x.datatype; len=$x.len; dec=$x.dec } } }
    foreach ($k in $li.Keys) { if (-not $ri.ContainsKey($k)) { $x=$li[$k]; $removed += [pscustomobject]@{ field=$x.name; datatype=$x.datatype; len=$x.len; dec=$x.dec } } }
    foreach ($k in $li.Keys) {
        if ($ri.ContainsKey($k)) {
            $a = $li[$k]; $b = $ri[$k]
            if ($a.datatype -ne $b.datatype) {
                $typeChanged += [pscustomobject]@{ field=$k; left="$($a.datatype)"; right="$($b.datatype)" }
            }
            elseif ($a.len -ne $b.len -or $a.dec -ne $b.dec) {
                $lenChanged += [pscustomobject]@{ field=$k; left="$($a.len).$($a.dec)"; right="$($b.len).$($b.dec)" }
            }
        }
    }
    $reordered=@()
    if ($l -and $r -and -not $added -and -not $removed) {
        $lorder = ($l | Sort-Object pos | ForEach-Object { $_.name })
        $rorder = ($r | Sort-Object pos | ForEach-Object { $_.name })
        if (($lorder -join ',') -ne ($rorder -join ',')) { $reordered = $rorder }
    }
    return @{ added=$added; removed=$removed; type_changed=$typeChanged; length_changed=$lenChanged; reordered=$reordered }
}

$d = Diff-Fields $lf $rf
$identical = (-not $d.added) -and (-not $d.removed) -and (-not $d.type_changed) -and (-not $d.length_changed) -and (-not $d.reordered)

$leftSid = ''; if ($lp) { $leftSid = "$($lp.system_name)" }
$out = [ordered]@{
    object = $Object; type = $Type
    left   = [ordered]@{ sid = $leftSid; exists = ($null -ne $lf) }
    right  = [ordered]@{ sid = "$($t.system_name)"; release = "$($t.server_release_marker)"; exists = ($null -ne $rf) }
    identical      = $identical
    added          = @($d.added)
    removed        = @($d.removed)
    type_changed   = @($d.type_changed)
    length_changed = @($d.length_changed)
    reordered      = @($d.reordered)
}
$out | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'diff.json') -Encoding UTF8

if ($lf) { $lf | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.name,$_.datatype,$_.len,$_.dec } | Set-Content -LiteralPath (Join-Path $OutDir 'left.def')  -Encoding UTF8 }
if ($rf) { $rf | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.name,$_.datatype,$_.len,$_.dec } | Set-Content -LiteralPath (Join-Path $OutDir 'right.def') -Encoding UTF8 }

try { Disconnect-SapRfc } catch {}
if ($identical) { Write-Output "RESULT: IDENTICAL" } else { Write-Output "RESULT: DIFFERS" }
Write-Output ("DIFF_WRITTEN: " + (Join-Path $OutDir 'diff.json'))
