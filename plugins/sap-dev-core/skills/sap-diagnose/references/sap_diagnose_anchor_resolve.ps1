# =============================================================================
# sap_diagnose_anchor_resolve.ps1  -  Resolve a /sap-diagnose incident anchor to
#                                     an ABSOLUTE SERVER-TIME window.
#
# Why this exists: time-window correlation MUST be resolved against the SAP
# server clock, never the operator's workstation. A workstation/server timezone
# skew silently returns "no evidence" for a real incident (same failure class as
# the SE01-create timezone bug). We obtain the server timezone offset via RFC
# (RFC_SYSTEM_INFO -> RFCTZONE, seconds east of GMT) and project the workstation's
# UTC clock onto server-local time.
#
# Tokens replaced by the SKILL.md wrapper (same pattern as sap_dev_artefacts.ps1):
#   %%RFC_LIB_PS1%%  %%SAP_SERVER%%  %%SAP_SYSNR%%  %%SAP_CLIENT%%
#   %%SAP_USER%%     %%SAP_PASSWORD%%  %%SAP_LANGUAGE%%
#
# Runtime params:
#   -InputJson <path>  flags object: { date, time, window, from_ts, to_ts,
#                                       user, tcode, program, job, jobcount,
#                                       dump, object, client }
#   -OutFile   <path>  where to write anchor.json
#
# anchor.json shape:
#   { window:{from_ts,to_ts}, server_now, server_tz_offset_sec, tz_source,
#     client, user, tcode, program, job, jobcount, dump, object_keys, seed }
#
# stdout last lines:
#   ANCHOR_JSON=<path>
#   RESOLVED_WINDOW=<from>..<to> (server tz_offset_sec=<n> source=<rfc|workstation>)
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$InputJson,
    [Parameter(Mandatory = $true)][string]$OutFile
)

$ErrorActionPreference = 'Stop'

. "%%RFC_LIB_PS1%%"

# ---- read flags ----------------------------------------------------------
$flags = @{}
if (Test-Path $InputJson) {
    try { $flags = Get-Content $InputJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $flags = $null }
}
function F($name, $default = '') {
    if ($flags -and ($flags.PSObject.Properties.Name -contains $name)) {
        $v = "$($flags.$name)"
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $default
}

# ---- server timezone offset (seconds east of GMT) via RFC ----------------
$tzSec = 0
$tzSource = 'workstation'
$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%"   `
                         -Sysnr    "%%SAP_SYSNR%%"    `
                         -Client   "%%SAP_CLIENT%%"   `
                         -User     "%%SAP_USER%%"     `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "DIAGNOSE_ANCHOR"
if ($g_dest) {
    try {
        $fn = $g_dest.Repository.CreateFunction("RFC_SYSTEM_INFO")
        $fn.Invoke($g_dest)
        $si = $fn.GetStructure("RFCSI_EXPORT")
        $raw = "$($si.GetString('RFCTZONE'))".Trim()
        if ($raw -match '^-?\d+$') { $tzSec = [int]$raw; $tzSource = 'rfc' }
    } catch {
        Write-Host "WARN: RFC_SYSTEM_INFO failed ($($_.Exception.Message)); falling back to workstation time."
    }
    Disconnect-SapRfc
} else {
    Write-Host "WARN: RFC connect failed; falling back to workstation time (timezone skew possible -- verify RESOLVED_WINDOW)."
}

# server-local 'now' = UTC now + server tz offset
$serverNow = [DateTime]::UtcNow.AddSeconds($tzSec)

# ---- resolve the window --------------------------------------------------
$fromTs = F 'from_ts'
$toTs   = F 'to_ts'
$winMin = [int](F 'window' '15')

function ToStamp([datetime]$d) { return $d.ToString('yyyyMMddHHmmss') }

if ($fromTs -and $toTs) {
    # explicit absolute window -- pass through (already server-local by contract)
    $fromStamp = $fromTs
    $toStamp   = $toTs
} else {
    # base date
    $dateFlag = (F 'date' 'today').ToLowerInvariant()
    if ($dateFlag -eq 'today' -or $dateFlag -eq '') {
        $baseDate = $serverNow.Date
    } else {
        try { $baseDate = [datetime]::ParseExact($dateFlag, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture) }
        catch { $baseDate = $serverNow.Date }
    }
    # base time
    $timeFlag = F 'time'
    if ($timeFlag) {
        $tm = $timeFlag -replace '[^0-9:]', ''
        $hh = 0; $mm = 0
        if ($tm -match '^(\d{1,2}):?(\d{2})$') { $hh = [int]$Matches[1]; $mm = [int]$Matches[2] }
        elseif ($tm -match '^(\d{1,2})$')      { $hh = [int]$Matches[1] }
        $center = $baseDate.AddHours($hh).AddMinutes($mm)
    } elseif ($dateFlag -eq 'today' -or $dateFlag -eq '') {
        $center = $serverNow            # no time given on 'today' -> use server-now
    } else {
        # a past date with no time -> cover the whole day
        $center = $baseDate.AddHours(12); $winMin = [Math]::Max($winMin, 720)
    }
    $fromStamp = ToStamp ($center.AddMinutes(-$winMin))
    $toStamp   = ToStamp ($center.AddMinutes( $winMin))
}

# ---- object key (TYPE:KEY) ----------------------------------------------
$objectKeys = @{}
$objFlag = F 'object'
if ($objFlag -and $objFlag.Contains(':')) {
    $k, $v = $objFlag.Split(':', 2)
    if ($k -and $v) { $objectKeys[$k.ToUpperInvariant()] = $v }
}

$seed = $null
if (F 'dump') { $seed = @{ kind = 'dump'; key = (F 'dump') } }

$anchor = [pscustomobject]@{
    window               = @{ from_ts = $fromStamp; to_ts = $toStamp }
    server_now           = (ToStamp $serverNow)
    server_tz_offset_sec = $tzSec
    tz_source            = $tzSource
    client               = (F 'client')
    user                 = (F 'user')
    tcode                = (F 'tcode')
    program              = (F 'program')
    job                  = (F 'job')
    jobcount             = (F 'jobcount')
    object_keys          = $objectKeys
    seed                 = $seed
}

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutFile, ($anchor | ConvertTo-Json -Depth 8), $enc)

Write-Host "ANCHOR_JSON=$OutFile"
Write-Host ("RESOLVED_WINDOW={0}..{1} (server tz_offset_sec={2} source={3})" -f $fromStamp, $toStamp, $tzSec, $tzSource)
