# =============================================================================
# sap_rfc_system_info.ps1
# -----------------------------------------------------------------------------
# Capture SAP server release info via RFC. Calls RFC_SYSTEM_INFO for kernel +
# host details, then RFC_READ_TABLE on CVERS to read software-component
# releases (SAP_BASIS, S4CORE, SAP_APPL, S4CEXT, SAP_HR). Resolves a canonical
# server_release_marker (e.g. S4HANA_2022, ECC6_EHP8) via
# shared/tables/sap_release_markers.tsv. Emits a JSON record to stdout that
# the caller writes to {WORK_TEMP}\sap_active_session.json.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sap_rfc_system_info.ps1 `
#       -Server   <hostname> `
#       -Sysnr    <00..99>   `
#       -Client   <000..999> `
#       -User     <username> `
#       -Password <password> `
#       -Language <EN|JA|ZH|...>
#
# Output: a single JSON object on stdout. Last line is JSON.
#         On failure: a line "ERROR: <text>" precedes any partial JSON.
# Exit codes: 0 success, 1 NCo missing, 2 RFC logon failed, 3 query failed.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Server,
    [Parameter(Mandatory = $true)] [string] $Sysnr,
    [Parameter(Mandatory = $true)] [string] $Client,
    [Parameter(Mandatory = $true)] [string] $User,
    [Parameter(Mandatory = $true)] [string] $Password,
    [Parameter(Mandatory = $true)] [string] $Language
)

$ErrorActionPreference = 'Stop'
$thisDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$markersFile = Join-Path $thisDir '..\tables\sap_release_markers.tsv'
if (-not (Test-Path $markersFile)) {
    Write-Host "ERROR: release markers table not found at $markersFile"
    exit 1
}

. "$thisDir\sap_rfc_lib.ps1"

# ------------------------------------------------------------------------------
# Step 1 — connect
# ------------------------------------------------------------------------------
$dest = Connect-SapRfc -Server   $Server `
                       -Sysnr    $Sysnr `
                       -Client   $Client `
                       -User     $User `
                       -Password $Password `
                       -Language $Language `
                       -DestName "SAPDEV_SYSINFO"
if (-not $dest) { exit 2 }

try {
    # ---------------------------------------------------------------------------
    # Step 2 — RFC_SYSTEM_INFO  (kernel, host, IP)
    # ---------------------------------------------------------------------------
    $sysInfoFn = $dest.Repository.CreateFunction('RFC_SYSTEM_INFO')
    $sysInfoFn.Invoke($dest)
    $rfcSi = $sysInfoFn.GetStructure('RFCSI_EXPORT')

    $kernelRelease = "$($rfcSi.GetValue('RFCSAPRL'))".Trim()
    $rfcHost       = "$($rfcSi.GetValue('RFCHOST'))".Trim()
    $rfcSysid      = "$($rfcSi.GetValue('RFCSYSID'))".Trim()
    $rfcDest       = "$($rfcSi.GetValue('RFCDEST'))".Trim()
    $rfcDbHost     = "$($rfcSi.GetValue('RFCDBHOST'))".Trim()
    $rfcDbSys      = "$($rfcSi.GetValue('RFCDBSYS'))".Trim()
    $rfcMachine    = "$($rfcSi.GetValue('RFCMACH'))".Trim()
    $rfcOpSys      = "$($rfcSi.GetValue('RFCOPSYS'))".Trim()

    # ---------------------------------------------------------------------------
    # Step 3 — CVERS  (software-component releases)
    # ---------------------------------------------------------------------------
    # Track per-component lookup outcomes so the caller can distinguish
    # "component not installed" (legitimately missing — e.g. S4CORE absent on
    # ECC, SAP_APPL absent on S/4HANA) from "RFC call failed" (auth missing
    # on CVERS / S_TABU_DIS, RFC_READ_TABLE blocked by S_RFC, transient NCo
    # error). The old empty catch made these two outcomes indistinguishable
    # which is why MICHAELLI's pin came back with software_components=[] and
    # the operator had no diagnostic trail to follow.
    $cvers     = @{}
    $cversErrs = @{}
    $components = @('SAP_BASIS','S4CORE','SAP_APPL','S4CEXT','SAP_HR')
    foreach ($comp in $components) {
        try {
            $fn = New-RfcReadTable -Destination $dest -Table 'CVERS'
            Add-RfcField  $fn 'COMPONENT'
            Add-RfcField  $fn 'RELEASE'
            Add-RfcField  $fn 'EXTRELEASE'
            Add-RfcOption $fn ("COMPONENT EQ '" + $comp + "'")
            $fn.Invoke($dest)
            $rows = $fn.GetTable('DATA')
            if ($rows.RowCount -gt 0) {
                # WA is the row content concatenated with the DELIMITER ('|')
                # between fields, each space-padded to its declared width
                # (CVERS: COMPONENT char30, RELEASE char10, EXTRELEASE char10).
                # Split on the delimiter — simpler and correct than the
                # previous off-by-one Substring math which left the '|'
                # separator inside the release value ('|104' instead of '104'),
                # causing the marker lookup to miss every S4CORE/SAP_BASIS row.
                $wa = "$($rows[0].GetValue('WA'))"
                $parts = $wa -split '\|'
                $compName = if ($parts.Count -ge 1) { $parts[0].TrimEnd() } else { '' }
                $release  = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
                $cvers[$comp] = [pscustomobject]@{
                    name    = $compName
                    release = $release
                }
            }
            # RowCount==0 is fine and silent — component genuinely not installed.
        } catch {
            # Surface the underlying error so the operator can tell the
            # difference between "CVERS auth missing" and "component absent".
            # Goes to Write-Host (host stream 6), NOT stdout, so the JSON
            # payload on stdout stays clean for the caller VBS to parse.
            $msg = $_.Exception.Message
            $cversErrs[$comp] = $msg
            Write-Host "WARN: CVERS lookup failed for ${comp}: $msg"
        }
    }
    if ($cversErrs.Count -gt 0 -and $cvers.Count -eq 0) {
        Write-Host ("WARN: every CVERS lookup raised an error; release-marker " +
                    "resolution will fall back to kernel only. Most likely " +
                    "cause: missing S_TABU_DIS for table-class SS, or missing " +
                    "S_RFC for function group SDTX (RFC_READ_TABLE).")
    }

    # ---------------------------------------------------------------------------
    # Step 4 — resolve server_release_marker via the lookup table
    # ---------------------------------------------------------------------------
    $markers = @()
    foreach ($line in Get-Content $markersFile -Encoding UTF8) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }
        $cols = $line -split "`t"
        if ($cols.Count -lt 6) { continue }
        if ($cols[0] -eq 'component') { continue }  # header row
        $markers += [pscustomobject]@{
            component  = $cols[0].Trim()
            release_lo = $cols[1].Trim()
            release_hi = $cols[2].Trim()
            family     = $cols[3].Trim()
            marker     = $cols[4].Trim()
            notes      = if ($cols.Count -ge 6) { $cols[5].Trim() } else { '' }
        }
    }

    function Try-ResolveMarker {
        param([string] $component, [string] $release)
        if (-not $release) { return $null }
        # Lookup by component; pick the first row whose release range matches.
        foreach ($m in $markers) {
            if ($m.component -ne $component) { continue }
            $relNum = 0
            $loNum  = 0
            $hiNum  = 0
            [void][int]::TryParse($release,     [ref] $relNum)
            [void][int]::TryParse($m.release_lo, [ref] $loNum)
            $hiOk = $true
            if ($m.release_hi) {
                [void][int]::TryParse($m.release_hi, [ref] $hiNum)
                if ($relNum -gt $hiNum) { $hiOk = $false }
            }
            if (($relNum -ge $loNum) -and $hiOk) {
                return [pscustomobject]@{
                    family = $m.family
                    marker = $m.marker
                }
            }
        }
        return $null
    }

    # Priority: S4CORE -> SAP_APPL -> SAP_BASIS (NW fallback).
    $resolved = $null
    foreach ($comp in @('S4CORE','SAP_APPL','SAP_BASIS')) {
        if ($cvers.ContainsKey($comp)) {
            $resolved = Try-ResolveMarker -component $comp -release $cvers[$comp].release
            if ($resolved) { break }
        }
    }

    # Kernel-only fallback: tried before the absolute UNKNOWN_KERNEL_<n>
    # bucket. The lookup table has synthetic KERNEL rows that map kernel
    # release ranges to ambiguous markers like S4HANA_1909_OR_NW754, which
    # preserves enough information for variant selectors to glob-match.
    # See shared/tables/sap_release_markers.tsv for the rationale.
    if (-not $resolved -and $kernelRelease) {
        $resolved = Try-ResolveMarker -component 'KERNEL' -release $kernelRelease
        if ($resolved) {
            Write-Host ("INFO: resolved via kernel fallback (kernel=" +
                        "$kernelRelease -> $($resolved.marker)) because CVERS " +
                        "returned no usable component rows.")
        }
    }

    # Last-ditch fallback: no CVERS rows AND no kernel match. Marker still
    # records the kernel so downstream selectors at least have a stable tag.
    if (-not $resolved) {
        $resolved = [pscustomobject]@{ family = 'UNKNOWN'; marker = "UNKNOWN_KERNEL_$kernelRelease" }
    }

    # ---------------------------------------------------------------------------
    # Step 5 — assemble the JSON record (server-side fields only -- GUI fields
    # are merged in by the caller VBS that has access to oApp.MajorVersion etc.)
    # ---------------------------------------------------------------------------
    $componentList = @()
    foreach ($k in $cvers.Keys) {
        $componentList += [pscustomobject]@{
            name    = $cvers[$k].name
            release = $cvers[$k].release
        }
    }

    # Record the resolution path so the operator can tell, just from the pin
    # file, whether they're on a confident S4CORE match or an ambiguous
    # kernel fallback. Variant selectors can branch on this if they need to.
    $resolvedVia = if ($cvers.ContainsKey('S4CORE')) {
        'S4CORE'
    } elseif ($cvers.ContainsKey('SAP_APPL')) {
        'SAP_APPL'
    } elseif ($cvers.ContainsKey('SAP_BASIS')) {
        'SAP_BASIS'
    } elseif ($resolved.family -ne 'UNKNOWN' -or $resolved.marker -notlike 'UNKNOWN_KERNEL_*') {
        'KERNEL_FALLBACK'
    } else {
        'NONE'
    }

    $cversErrList = @()
    foreach ($k in $cversErrs.Keys) {
        $cversErrList += [pscustomobject]@{
            component = $k
            error     = $cversErrs[$k]
        }
    }

    $record = [pscustomobject]@{
        rfc_host                 = $rfcHost
        rfc_sysid                = $rfcSysid
        rfc_destination          = $rfcDest
        rfc_db_host              = $rfcDbHost
        rfc_db_system            = $rfcDbSys
        rfc_machine_class        = $rfcMachine
        rfc_operating_system     = $rfcOpSys
        server_kernel_release    = $kernelRelease
        server_release_family    = $resolved.family
        server_release_marker    = $resolved.marker
        server_release_raw       = if ($cvers.ContainsKey('S4CORE')) {
                                       "S/4HANA (S4CORE $($cvers['S4CORE'].release))"
                                   } elseif ($cvers.ContainsKey('SAP_APPL')) {
                                       "ECC (SAP_APPL $($cvers['SAP_APPL'].release))"
                                   } else {
                                       "kernel $kernelRelease"
                                   }
        server_release_resolved_via = $resolvedVia
        software_components      = $componentList
        cvers_errors             = $cversErrList
        captured_at              = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    }

    $record | ConvertTo-Json -Depth 8 -Compress

} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Disconnect-SapRfc
    exit 3
} finally {
    Disconnect-SapRfc
}

exit 0
