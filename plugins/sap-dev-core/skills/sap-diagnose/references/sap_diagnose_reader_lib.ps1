# =============================================================================
# sap_diagnose_reader_lib.ps1  -  Shared helpers for the /sap-diagnose RFC readers
#
# Dot-source AFTER sap_rfc_lib.ps1:
#   . "%%RFC_LIB_PS1%%"
#   . "%%DIAG_READER_LIB_PS1%%"
#
# Provides:
#   Read-DiagAnchor  $path                       -> anchor object (window + filters)
#   Invoke-DiagReadTable $dest $table $where $fields $topN
#                                                -> @{ rows=[ordered{}]; truncated; total }
#   New-DiagEvent ...                            -> normalized event (ordered hashtable)
#   Test-InWindow $date $time $fromTs $toTs      -> bool
#   Write-DiagEvidence $source $status $reason $events $truncated $total $outFile
#
# Evidence files conform to diagnose_evidence_schema.json. All timestamps are
# yyyyMMddHHmmss (server-local -- the anchor is resolved against the server clock
# by sap_diagnose_anchor_resolve.ps1 before any reader runs).
# =============================================================================

function Read-DiagAnchor([string]$path) {
    $o = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $from = "$($o.window.from_ts)"
    $to   = "$($o.window.to_ts)"
    if ($from.Length -lt 14) { $from = ($from + '00000000000000').Substring(0, 14) }
    if ($to.Length   -lt 14) { $to   = ($to   + '99999999999999').Substring(0, 14) }
    [pscustomobject]@{
        fromTs     = $from
        toTs       = $to
        fromDate   = $from.Substring(0, 8)
        toDate     = $to.Substring(0, 8)
        user       = "$($o.user)"
        client     = "$($o.client)"
        tcode      = "$($o.tcode)"
        program    = "$($o.program)"
        job        = "$($o.job)"
        objectKeys = $o.object_keys
    }
}

function Test-InWindow([string]$d, [string]$t, [string]$fromTs, [string]$toTs) {
    if ([string]::IsNullOrWhiteSpace($d)) { return $true }
    if ([string]::IsNullOrWhiteSpace($t)) { $t = '000000' }
    $t = ($t + '000000').Substring(0, 6)
    $stamp = $d + $t
    return (($stamp -ge $fromTs) -and ($stamp -le $toTs))
}

# RFC_READ_TABLE with the forbidden-table guard (New-RfcReadTable) + ROWCOUNT cap.
# Returns ordered-hashtable rows keyed by the requested field names, plus a
# truncated flag (true when more rows existed than the cap).
function Invoke-DiagReadTable($dest, [string]$table, $where, $fields, [int]$topN = 200) {
    $fields = @($fields)
    $fn = New-RfcReadTable -Destination $dest -Table $table -Delimiter '|'
    if ($topN -gt 0) { [void]$fn.SetValue("ROWCOUNT", [int]($topN + 1)) }
    foreach ($w in @($where)) { if (-not [string]::IsNullOrWhiteSpace("$w")) { Add-RfcOption $fn "$w" } }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    $fn.Invoke($dest)
    $d = $fn.GetTable("DATA")
    $cnt = $d.RowCount
    $lim = [Math]::Min($cnt, $topN)
    $rows = @()
    for ($i = 0; $i -lt $lim; $i++) {
        $d.CurrentIndex = $i
        $parts = ($d.GetString("WA") -split '\|')
        $row = [ordered]@{}
        for ($k = 0; $k -lt $fields.Count; $k++) {
            $row[$fields[$k]] = if ($k -lt $parts.Count) { $parts[$k].Trim() } else { '' }
        }
        $rows += , $row
    }
    return @{ rows = $rows; truncated = ($cnt -gt $topN); total = $cnt }
}

function New-DiagEvent {
    param(
        [string]$Id, [string]$Source, [string]$Ts, [string]$Severity = 'I',
        [string]$Client = '', [string]$User = '', [string]$Tcode = '',
        [string]$Program = '', [string]$Include = '', [string]$Line = '',
        $ObjectKeys = @{}, [string]$MsgId = '', [string]$MsgNo = '', [string]$MsgText = '',
        $Tech = @{}, [string]$Drilldown = '', $ExplicitLinks = @()
    )
    return [ordered]@{
        id             = $Id
        source         = $Source
        ts             = $Ts
        severity       = $Severity
        client         = $Client
        user           = $User
        tcode          = $Tcode
        program        = $Program
        include        = $Include
        line           = $Line
        object_keys    = $ObjectKeys
        msg_id         = $MsgId
        msg_no         = $MsgNo
        msg_text       = $MsgText
        tech           = $Tech
        drilldown      = $Drilldown
        explicit_links = @($ExplicitLinks)
    }
}

function Write-DiagEvidence([string]$source, [string]$status, [string]$reason, $events, [bool]$truncated, [int]$total, [string]$outFile) {
    $obj = [ordered]@{
        source      = $source
        status      = $status
        reason      = $reason
        truncated   = $truncated
        total_count = $total
        events      = @($events)
    }
    $dir = Split-Path -Parent $outFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outFile, ($obj | ConvertTo-Json -Depth 10), $enc)
    Write-Host ("EVIDENCE: source={0} status={1} events={2} truncated={3} file={4}" -f $source, $status, @($events).Count, $truncated, $outFile)
}
