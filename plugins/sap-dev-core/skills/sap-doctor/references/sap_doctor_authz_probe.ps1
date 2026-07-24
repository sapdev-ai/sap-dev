# =============================================================================
# sap_doctor_authz_probe.ps1  -  probe the LOGGED-IN user's SAP authorizations
#
# Answers the #1 security-review question ("what does the AI's connection need,
# and does this user have it?") with a machine check instead of prose. Reads
# shared/tables/required_authorizations.tsv (the comprehensive per-capability
# probe set; a superset of the coarse summary in docs/security.md Sec.1)
# and, for the pinned RFC user, calls SUSR_USER_AUTH_FOR_OBJ_GET (RFC-enabled --
# no dev-init wrapper needed) once per authorization object, then evaluates each
# capability with faithful AUTHORITY-CHECK semantics: a capability PASSes only
# when a SINGLE authorization instance of each required object covers every
# required field value ('*' matches anything; VON..BIS ranges honoured).
#
# Honest by design: if the FM is unavailable (very old release) or the user's
# auth data cannot be read, it prints AUTH: NOT_PROBED and exits 2 -- never a
# fabricated PASS/FAIL.
#
# Run with 32-bit PowerShell (NCo 3.1 is a 32-bit GAC assembly):
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File ...
#
# Params (all optional; defaults resolve relative to this script):
#   -RulesFile <path>   required_authorizations.tsv
#   -UserName  <name>   user to probe (default: the pinned connection's user)
#   -RfcLib / -ConnLib  sap_rfc_lib.ps1 / sap_connection_lib.ps1
#
# Output grammar (parsed by /sap-doctor):
#   AUTH: PASS <capability> (<objs>) - <description>
#   AUTH: FAIL <capability> (missing <obj>) - <description>
#   AUTH: NOT_PROBED (<why>)
#   AUTH_SUMMARY: probed=<n> pass=<p> fail=<f> user=<u> fully_authorized_objects=<list>
# Exit: 0 all pass | 1 probed with >=1 FAIL | 2 could not probe (NOT_PROBED)
# =============================================================================

[CmdletBinding()]
param(
    [string]$RulesFile = '',
    [string]$UserName  = '',
    [string]$RfcLib    = '',
    [string]$ConnLib   = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# sap-dev-core root = 3 levels up from references\ (references -> sap-doctor -> skills -> sap-dev-core)
$core = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not $RfcLib)    { $RfcLib    = Join-Path $core 'shared\scripts\sap_rfc_lib.ps1' }
if (-not $ConnLib)   { $ConnLib   = Join-Path $core 'shared\scripts\sap_connection_lib.ps1' }
if (-not $RulesFile) { $RulesFile = Join-Path $core 'shared\tables\required_authorizations.tsv' }

function NotProbed([string]$why){
    Write-Output "AUTH: NOT_PROBED ($why)"
    Write-Output "AUTH_SUMMARY: probed=0 pass=0 fail=0 user=$UserName fully_authorized_objects=none"
    exit 2
}

if (-not (Test-Path -LiteralPath $RulesFile)) { NotProbed "rules file not found: $RulesFile" }
if (-not (Test-Path -LiteralPath $RfcLib))    { NotProbed "sap_rfc_lib.ps1 not found" }
. $RfcLib
if (Test-Path -LiteralPath $ConnLib) { . $ConnLib }

# Resolve the user to probe (default: the pinned connection's user).
if (-not $UserName -and (Get-Command Get-SapCurrentConnectionProfile -ErrorAction SilentlyContinue)) {
    try { $prof = Get-SapCurrentConnectionProfile; if ($prof) { $UserName = "$($prof.user)" } } catch {}
}

# ---- read the rules TSV (skip # comments + blanks) ----
$lines = @(Get-Content -LiteralPath $RulesFile | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() })
if ($lines.Count -lt 2) { NotProbed "rules file has no rows" }
$hdr = @($lines[0].Split("`t") | ForEach-Object { $_.Trim() })
$ix = @{}; for ($i=0;$i -lt $hdr.Count;$i++){ $ix[$hdr[$i]] = $i }
function C($f,$n){ if ($ix.ContainsKey($n) -and $ix[$n] -lt $f.Length) { return ([string]$f[$ix[$n]]).Trim() } else { return '' } }
$rules = @()
for ($i=1;$i -lt $lines.Count;$i++){
    $f = $lines[$i].Split("`t")
    $cap = (C $f 'capability'); $ob = (C $f 'auth_object')
    if (-not $cap -or -not $ob) { continue }
    $rules += [pscustomobject]@{ capability=$cap; auth_object=$ob; field=(C $f 'field'); values=(C $f 'values'); description=(C $f 'description') }
}
if ($rules.Count -eq 0) { NotProbed "rules file parsed to zero rows" }
$objects = @($rules | ForEach-Object { $_.auth_object } | Select-Object -Unique)

# ---- connect (pinned-profile fallback) ----
$dest = $null
try { $dest = Connect-SapRfc } catch { NotProbed "RFC connect failed: $($_.Exception.Message)" }
if (-not $dest) { NotProbed "RFC connect returned no destination" }
if (-not $UserName) { try { Disconnect-SapRfc $dest } catch {}; NotProbed "could not resolve the logged-in user" }

# ---- fetch the user's grants for each object ----
# grants[object] = @{ fully=<bool>; inst=@{ AUTH => @{ FIELD => @( @{von;bis}, ... ) } }; error=<msg> }
$grants = @{}
foreach ($obj in $objects) {
    try {
        $fn = $dest.Repository.CreateFunction('SUSR_USER_AUTH_FOR_OBJ_GET')
        $fn.SetValue('USER_NAME',$UserName)
        $fn.SetValue('SEL_OBJECT',$obj)
        $fn.Invoke($dest)
        $fully = $false; try { $fully = ((($fn.GetString('FULLY_AUTHORIZED')).Trim()) -eq 'X') } catch {}
        $inst = @{}
        $v = $fn.GetTable('VALUES')
        for ($r=0;$r -lt $v.RowCount;$r++){
            $v.CurrentIndex = $r
            $auth = ($v.GetString('AUTH')).Trim(); $fld = ($v.GetString('FIELD')).Trim()
            if (-not $fld) { continue }
            $von = ($v.GetString('VON')).Trim(); $bis = ($v.GetString('BIS')).Trim()
            if (-not $inst.ContainsKey($auth)) { $inst[$auth] = @{} }
            if (-not $inst[$auth].ContainsKey($fld)) { $inst[$auth][$fld] = New-Object System.Collections.Generic.List[object] }
            [void]$inst[$auth][$fld].Add(@{ von=$von; bis=$bis })
        }
        $grants[$obj] = @{ fully=$fully; inst=$inst; error='' }
    } catch {
        $grants[$obj] = @{ fully=$false; inst=@{}; error=$_.Exception.Message }
    }
}
try { Disconnect-SapRfc $dest } catch {}

# If EVERY object lookup failed, the probe cannot function (FM missing on this
# release, or the user's auth data is unreadable) -> honest NOT_PROBED.
$errCount = @($grants.Values | Where-Object { $_.error }).Count
if ($errCount -eq $objects.Count) {
    $first = @($grants.Values | Where-Object { $_.error } | Select-Object -First 1).error
    NotProbed "SUSR_USER_AUTH_FOR_OBJ_GET read failed: $first"
}

# ---- evaluation (faithful AUTHORITY-CHECK) ----
function Field-Satisfied($entries, [string]$reqValues){
    if ($null -eq $entries -or $entries.Count -eq 0) { return $false }
    foreach ($e in $entries) { if ($e.von -eq '*') { return $true } }           # user '*' covers anything
    if ([string]::IsNullOrWhiteSpace($reqValues)) { return $true }              # presence-only: field granted
    foreach ($rv in ($reqValues.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        foreach ($e in $entries) {
            if ($e.von -eq $rv) { return $true }
            if ($e.bis -and ([string]::CompareOrdinal($e.von,$rv) -le 0) -and ([string]::CompareOrdinal($rv,$e.bis) -le 0)) { return $true }
        }
    }
    return $false
}
function Object-Satisfied($grant, $fieldReqs){
    if ($grant.fully) { return $true }
    if (-not $grant.inst -or $grant.inst.Count -eq 0) { return $false }
    foreach ($authName in @($grant.inst.Keys)) {
        $ok = $true
        foreach ($fr in $fieldReqs) {
            $entries = $null
            if ($grant.inst[$authName].ContainsKey($fr.field)) { $entries = $grant.inst[$authName][$fr.field] }
            if (-not (Field-Satisfied $entries $fr.values)) { $ok = $false; break }
        }
        if ($ok) { return $true }
    }
    return $false
}

# ---- emit per capability ----
$caps = @($rules | ForEach-Object { $_.capability } | Select-Object -Unique)
$nPass=0; $nFail=0
$fullyList = @($objects | Where-Object { $grants[$_].fully })
foreach ($cap in $caps) {
    $capRows = @($rules | Where-Object { $_.capability -eq $cap })
    $descRow = @($capRows | Where-Object { $_.description }) | Select-Object -First 1
    $desc = if ($descRow) { $descRow.description } else { '' }
    $capObjs = @($capRows | ForEach-Object { $_.auth_object } | Select-Object -Unique)
    $capPass = $true; $failObj = ''
    foreach ($co in $capObjs) {
        $fieldReqs = @($capRows | Where-Object { $_.auth_object -eq $co -and $_.field } | ForEach-Object { @{ field=$_.field; values=$_.values } })
        if ($grants[$co].error) { $capPass = $false; $failObj = "$co (probe error)"; break }
        if (-not (Object-Satisfied $grants[$co] $fieldReqs)) { $capPass = $false; $failObj = $co; break }
    }
    if ($capPass) { $nPass++; Write-Output "AUTH: PASS $cap ($($capObjs -join '+')) - $desc" }
    else          { $nFail++; Write-Output "AUTH: FAIL $cap (missing $failObj) - $desc" }
}
$fullyStr = if ($fullyList.Count) { $fullyList -join ',' } else { 'none' }
Write-Output "AUTH_SUMMARY: probed=$($caps.Count) pass=$nPass fail=$nFail user=$UserName fully_authorized_objects=$fullyStr"
if ($nFail -gt 0) { exit 1 }
exit 0
