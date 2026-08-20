# =============================================================================
# sap_transport_list.ps1  -  Owner-scoped transport request listing via RFC
#
# Lists the top-level transport requests (E070 STRKORR = '') owned by one user,
# joined to their E07T short texts, newest first. Companion to the resolve /
# create flows of /sap-transport-request: this is the read that answers "which
# modifiable requests do I already have?" before anyone creates a new one.
#
# READ-ONLY. Reads E070 / E07T via RFC_READ_TABLE through the shared libs;
# never mutates SAP. No wrapper FM, no GUI.
#
# Reuses Phase-0 primitives:
#   sap_rfc_lib.ps1         (Connect-SapRfc, Disconnect-SapRfc)
#   sap_object_resolver.ps1 (Read-SapTableRows)
#
# Run with 32-bit PowerShell (SAP NCo 3.1 is 32-bit). Creds default to the
# pinned connection profile via Connect-SapRfc (so no arguments are needed
# when logged in). -Owner defaults to the resolved RFC user.
#
# WHERE-clause discipline: Add-RfcWhereClauses splits only on AND, so every
# individual clause must fit one 72-char OPTIONS row. Status filtering is done
# with one query per status letter (no parentheses, no IN), and the E07T text
# join batches TWO requests per OR clause (47 chars, safely under 72).
#
# Known WA-split limitation (house primitive): Read-SapTableRows splits the
# DATA rows on '|', so an AS4TEXT that itself contains '|' truncates at the
# first pipe. AS4TEXT is therefore always the LAST requested field.
#
# Output (stdout, machine-parseable):
#   TR: <TRKORR> | FUNC: <K|W|...> | STATUS: <D|L|R|O|N> | OWNER: <user> | DATE: <YYYYMMDD> | TEXT: <short text>
#   LISTED: owner=<user> count=<returned> matched=<total> type=<workbench|customizing|all> released_included=<true|false>
#   LIST_TSV: <path>            (only when -OutputDir was given)
#   STATUS: OK | NO_REQUESTS | RFC_ERROR
# Exit: 0 = OK or NO_REQUESTS (an empty list is a successful answer) | 2 = RFC/connect error.
# =============================================================================

[CmdletBinding()]
param(
    [string]   $Owner = '',            # AS4USER filter; '' = the resolved RFC user
    [string]   $RequestType = 'all',   # workbench | customizing | all
    [switch]   $IncludeReleased,       # also list R / O / N requests
    [int]      $MaxRows = 50,
    [string]   $SharedDir = '',
    [string]   $OutputDir = '',
    [string]   $RunId = '',
    # Endpoint / creds - empty falls back to the pinned profile (sap_rfc_lib).
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) {
    try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\shared')).Path } catch { $SharedDir = '' }
}
$scripts = Join-Path $SharedDir 'scripts'

# sap_object_resolver.ps1 has its OWN param() block (Server/Sysnr/Client/...) -
# dot-sourcing it resets our identically named cred params (the param-clobber
# gotcha). Snapshot the creds, dot-source, then restore.
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1') {
    $p = Join-Path $scripts $lib
    if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

# Normalise the type filter up-front so a typo fails loudly, not as 0 rows.
$typeNorm = "$RequestType".Trim().ToLowerInvariant()
if ($typeNorm -eq '') { $typeNorm = 'all' }
if ($typeNorm -notin @('workbench', 'customizing', 'all')) {
    Write-Host "ERROR: unknown -RequestType '$RequestType' (expected workbench | customizing | all)."
    Write-Host "STATUS: RFC_ERROR"
    exit 2
}

$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                         -LogonGroup $LogonGroup -SystemID $SystemID `
                         -Client $Client -User $UserId -Password $Password -Language $Language `
                         -DestName "SAPDEV_TRLIST"
if (-not $g_dest) {
    Write-Host "STATUS: RFC_ERROR"
    exit 2
}

try {
    $effOwner = "$Owner".Trim().ToUpperInvariant()
    if ($effOwner -eq '') { $effOwner = "$g_sapUser".Trim().ToUpperInvariant() }
    if ($effOwner -eq '') {
        Write-Host "ERROR: no owner given and the resolved connection reports no user."
        Write-Host "STATUS: RFC_ERROR"
        Disconnect-SapRfc
        exit 2
    }

    # One query per status letter keeps every clause parenthesis-free and under
    # the 72-char OPTIONS row limit. With -IncludeReleased the status filter is
    # dropped entirely (single query).
    $statusFilters = @('D', 'L')
    if ($IncludeReleased) { $statusFilters = @('') }

    $funcClause = ''
    if ($typeNorm -eq 'workbench')   { $funcClause = "TRFUNCTION EQ 'K'" }
    if ($typeNorm -eq 'customizing') { $funcClause = "TRFUNCTION EQ 'W'" }

    $all = @()
    foreach ($st in $statusFilters) {
        $clauses = @("AS4USER EQ '$effOwner'", "STRKORR EQ ''")
        if ($st -ne '') { $clauses += "TRSTATUS EQ '$st'" }
        if ($funcClause) { $clauses += $funcClause }
        $where = $clauses -join ' AND '
        $rows = Read-SapTableRows -Destination $g_dest -Table 'E070' -Where $where `
                    -Fields @('TRKORR', 'TRFUNCTION', 'TRSTATUS', 'AS4USER', 'AS4DATE', 'AS4TIME') -RowCount 500
        if ($null -eq $rows) {
            Write-Host "ERROR: E070 read failed (authorization or transient RFC error) for owner $effOwner."
            Write-Host "STATUS: RFC_ERROR"
            Disconnect-SapRfc
            exit 2
        }
        $all += @($rows)
    }

    $matched = @($all | Sort-Object -Property @{Expression='AS4DATE';Descending=$true}, @{Expression='AS4TIME';Descending=$true})
    $total = $matched.Count
    if ($MaxRows -gt 0 -and $matched.Count -gt $MaxRows) { $matched = @($matched | Select-Object -First $MaxRows) }

    if ($total -eq 0) {
        Write-Host ("LISTED: owner={0} count=0 matched=0 type={1} released_included={2}" -f $effOwner, $typeNorm, ([bool]$IncludeReleased).ToString().ToLowerInvariant())
        Write-Host "STATUS: NO_REQUESTS"
        Disconnect-SapRfc
        exit 0
    }

    # E07T short texts for the returned rows, two requests per OR clause so the
    # clause stays inside one 72-char OPTIONS row. Prefer English, else the
    # first language row found.
    $texts = @{}
    for ($i = 0; $i -lt $matched.Count; $i += 2) {
        $pair = @($matched[$i].TRKORR)
        if (($i + 1) -lt $matched.Count) { $pair += $matched[$i + 1].TRKORR }
        $whereT = (@($pair | ForEach-Object { "TRKORR EQ '$_'" }) -join ' OR ')
        $trows = Read-SapTableRows -Destination $g_dest -Table 'E07T' -Where $whereT `
                     -Fields @('TRKORR', 'LANGU', 'AS4TEXT') -RowCount 20
        if ($null -eq $trows) { continue }   # text join is best-effort; the list itself already stands
        foreach ($t in @($trows)) {
            $k = "$($t.TRKORR)".Trim()
            if (-not $texts.ContainsKey($k)) { $texts[$k] = "$($t.AS4TEXT)" }
            elseif ("$($t.LANGU)".Trim().ToUpperInvariant() -eq 'E') { $texts[$k] = "$($t.AS4TEXT)" }
        }
    }

    $tsvLines = @("TRKORR`tTRFUNCTION`tTRSTATUS`tAS4USER`tAS4DATE`tAS4TIME`tAS4TEXT")
    foreach ($r in $matched) {
        $k = "$($r.TRKORR)".Trim()
        $txt = ''
        if ($texts.ContainsKey($k)) { $txt = "$($texts[$k])".Trim() }
        Write-Host ("TR: {0} | FUNC: {1} | STATUS: {2} | OWNER: {3} | DATE: {4} | TEXT: {5}" -f `
            $k, "$($r.TRFUNCTION)".Trim(), "$($r.TRSTATUS)".Trim(), "$($r.AS4USER)".Trim(), "$($r.AS4DATE)".Trim(), $txt)
        $tsvLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f `
            $k, "$($r.TRFUNCTION)".Trim(), "$($r.TRSTATUS)".Trim(), "$($r.AS4USER)".Trim(), "$($r.AS4DATE)".Trim(), "$($r.AS4TIME)".Trim(), $txt)
    }

    if ($OutputDir) {
        if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
        $tsvPath = Join-Path $OutputDir 'transport_list.tsv'
        [System.IO.File]::WriteAllLines($tsvPath, [string[]]$tsvLines, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "LIST_TSV: $tsvPath"
    }

    Write-Host ("LISTED: owner={0} count={1} matched={2} type={3} released_included={4}" -f `
        $effOwner, $matched.Count, $total, $typeNorm, ([bool]$IncludeReleased).ToString().ToLowerInvariant())
    Write-Host "STATUS: OK"
    Disconnect-SapRfc
    exit 0
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host "STATUS: RFC_ERROR"
    Disconnect-SapRfc
    exit 2
}
