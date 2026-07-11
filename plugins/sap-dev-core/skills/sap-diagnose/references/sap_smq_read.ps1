# =============================================================================
# sap_smq_read.ps1  -  /sap-diagnose reader: tRFC + qRFC (SM58 / SMQ1 / SMQ2)
#
# Three legs, all read-only via RFC_READ_TABLE (through Invoke-DiagReadTable's
# forbidden-table guard + ROWCOUNT cap):
#   * tRFC   ARFCSSTATE  (SM58) -- failed/pending tRFC LUWs. One event per LUW.
#       NARROW field select is MANDATORY: ARFCSSTATE has a 255-char ARFCRESERV +
#       RAW HASH, so SELECT * throws DATA_BUFFER_EXCEEDED (>512B row) even at
#       ROWCOUNT 0 (verified S4D+EC2 2026-07-11). Real column names differ from
#       the qRFC tables: ARFCDEST / ARFCFNAM / ARFCSTATE / ARFCMSG.
#   * qRFC   TRFCQOUT    (SMQ1) -- outbound queues, AGGREGATED per queue.
#   * qRFC   TRFCQIN     (SMQ2) -- inbound  queues, AGGREGATED per queue.
#
# tRFC is window-filtered (SM58 rows are timestamped failures). qRFC is NOT
# window-filtered: a queue entry's presence == current pending/stuck state, so a
# queue stuck since long before the anchor window is still a now-problem; each
# event instead carries the queue's oldest-entry age. user / destination filters
# apply to all legs. All three tables verified identical on S/4HANA 1909 + ECC 6.
#
# Emits the standard evidence contract (source=SMQ). A leg that errors is recorded
# as a per-leg note and the others still run; only an RFC-connect failure skips.
#
# Tokens: %%RFC_LIB_PS1%% %%DIAG_READER_LIB_PS1%% %%SAP_SERVER%% %%SAP_SYSNR%%
#   %%SAP_CLIENT%% %%SAP_USER%% %%SAP_PASSWORD%% %%SAP_LANGUAGE%%
# Params: -AnchorJson <path> -OutFile <path> [-TopN 200]
# =============================================================================
param([Parameter(Mandatory = $true)][string]$AnchorJson, [Parameter(Mandatory = $true)][string]$OutFile, [int]$TopN = 200)
$ErrorActionPreference = 'Stop'
. "%%RFC_LIB_PS1%%"
. "%%DIAG_READER_LIB_PS1%%"

$a = Read-DiagAnchor $AnchorJson
$dest = Connect-SapRfc -Server "%%SAP_SERVER%%" -Sysnr "%%SAP_SYSNR%%" -Client "%%SAP_CLIENT%%" `
                       -User "%%SAP_USER%%" -Password "%%SAP_PASSWORD%%" -Language "%%SAP_LANGUAGE%%" -DestName "DIAG_SMQ"
if (-not $dest) { Write-DiagEvidence 'SMQ' 'skipped' 'rfc_connect_failed' @() $false 0 $OutFile; exit 0 }

# destination filter (optional) from the anchor object_keys (DEST/DESTINATION/QNAME)
function _AnchorKey([string[]]$names) {
    if (-not $a.objectKeys) { return '' }
    foreach ($n in $names) { $v = "$($a.objectKeys.$n)"; if ($v) { return $v.Trim() } }
    return ''
}
$destFilter = _AnchorKey @('DEST', 'DESTINATION', 'RFCDEST')
$qnameFilter = _AnchorKey @('QNAME', 'QUEUE')
function _Like([string]$val, [string]$pat) {
    if (-not $pat) { return $true }
    $rx = '^' + [Regex]::Escape($pat).Replace('\*', '.*').Replace('\?', '.') + '$'
    return ($val -match $rx)
}
# a qRFC/tRFC state counts as an ERROR (vs a plain backlog / in-progress) only
# when it matches a known failure pattern. Denylist, not allowlist: benign states
# vary across releases (READY, READ, RUNNING, EXECUTED, NOSEND, WAITSTOP, ...) and
# an unknown one must NOT be reported as an error (the 'READ' false-W, S4D
# 2026-07-11). SYSFAIL / MSGFAIL / CPICERR and any *ERR* / *FAIL* -> error.
function _IsErrState([string]$s) {
    $s = $s.Trim().ToUpper()
    if ($s -eq '') { return $false }
    return ($s -match 'FAIL|ERR|CPIC')
}
function _Sev([string]$s) { if (_IsErrState $s) { return 'W' } return 'I' }

$events = @(); $grandTotal = 0; $anyTrunc = $false; $notes = @(); $legsOk = 0
$idx = 0

# ---- leg 1: tRFC (ARFCSSTATE), window-filtered, one event per LUW ------------
try {
    $where = @("ARFCDATUM >= '$($a.fromDate)'", "AND ARFCDATUM <= '$($a.toDate)'")
    $r = Invoke-DiagReadTable $dest 'ARFCSSTATE' $where `
        @('ARFCIPID', 'ARFCPID', 'ARFCTIME', 'ARFCTIDCNT', 'ARFCDEST', 'ARFCSTATE', 'ARFCFNAM', 'ARFCDATUM', 'ARFCUZEIT', 'ARFCUSER', 'ARFCTCODE', 'ARFCMSG') $TopN
    $grandTotal += $r.total; $anyTrunc = $anyTrunc -or $r.truncated
    foreach ($row in $r.rows) {
        if ($a.user -and ($row['ARFCUSER'] -ne $a.user)) { continue }
        if (-not (_Like $row['ARFCDEST'] $destFilter)) { continue }
        if (-not (Test-InWindow $row['ARFCDATUM'] $row['ARFCUZEIT'] $a.fromTs $a.toTs)) { continue }
        $tid = ($row['ARFCIPID'] + $row['ARFCPID'] + $row['ARFCTIME'] + $row['ARFCTIDCNT'])
        $stt = if ($row['ARFCUZEIT']) { ($row['ARFCUZEIT'] + '000000').Substring(0, 6) } else { '000000' }
        $idx++
        $events += New-DiagEvent -Id "SMQ-T$idx" -Source 'SMQ' -Ts ($row['ARFCDATUM'] + $stt) -Severity (_Sev $row['ARFCSTATE']) `
            -Client $a.client -User $row['ARFCUSER'] -Tcode $row['ARFCTCODE'] `
            -ObjectKeys @{ TID = $tid; DEST = $row['ARFCDEST'].Trim() } `
            -MsgText ("tRFC " + $(if (_IsErrState $row['ARFCSTATE']) { 'FAILED' } else { 'pending' }) + " to " + $row['ARFCDEST'].Trim() + " calling " + $row['ARFCFNAM'].Trim() + $(if ($row['ARFCMSG'].Trim()) { ' -- ' + $row['ARFCMSG'].Trim() })) `
            -Tech @{ leg = 'tRFC'; state = $row['ARFCSTATE'].Trim(); dest = $row['ARFCDEST'].Trim(); fm = $row['ARFCFNAM'].Trim(); tid = $tid } `
            -Drilldown ("SM58 -> " + $row['ARFCDEST'].Trim() + " -> " + $row['ARFCFNAM'].Trim())
    }
    $legsOk++
} catch { $notes += "tRFC(ARFCSSTATE):$($_.Exception.Message)" }

# ---- legs 2+3: qRFC out/in, aggregated per queue (current state) -------------
function Read-QrfcLeg([string]$table, [string]$dir, [string]$drillTcode) {
    $r = Invoke-DiagReadTable $dest $table '' `
        @('QNAME', 'DEST', 'QSTATE', 'QRFCFNAM', 'QRFCUSER', 'QRFCDATUM', 'QRFCUZEIT', 'ERRMESS') $TopN
    $script:grandTotal += $r.total; $script:anyTrunc = $script:anyTrunc -or $r.truncated
    $agg = @{}  # key = QNAME|DEST -> aggregate
    foreach ($row in $r.rows) {
        if ($a.user -and ($row['QRFCUSER'] -ne $a.user)) { continue }
        if (-not (_Like $row['DEST'] $destFilter)) { continue }
        if (-not (_Like $row['QNAME'] $qnameFilter)) { continue }
        $t = if ($row['QRFCUZEIT']) { ($row['QRFCUZEIT'] + '000000').Substring(0, 6) } else { '000000' }
        $ts = $row['QRFCDATUM'] + $t
        $key = $row['QNAME'] + '|' + $row['DEST']
        if (-not $agg.ContainsKey($key)) {
            $agg[$key] = @{ qname = $row['QNAME'].Trim(); dest = $row['DEST'].Trim(); depth = 0
                oldest = '99999999999999'; err = $false; worst = ''; user = $row['QRFCUSER'].Trim()
                fm = $row['QRFCFNAM'].Trim(); errmess = '' }
        }
        $g = $agg[$key]; $g.depth++
        if ($ts -lt $g.oldest) { $g.oldest = $ts }
        if (_IsErrState $row['QSTATE']) { $g.err = $true; $g.worst = $row['QSTATE'].Trim(); if ($row['ERRMESS'].Trim()) { $g.errmess = $row['ERRMESS'].Trim() } }
        elseif (-not $g.worst) { $g.worst = $row['QSTATE'].Trim() }
    }
    foreach ($g in $agg.Values) {
        $script:idx++
        $sev = if ($g.err) { 'W' } else { 'I' }
        $script:events += New-DiagEvent -Id "SMQ-Q$($script:idx)" -Source 'SMQ' -Ts $g.oldest -Severity $sev `
            -Client $a.client -User $g.user `
            -ObjectKeys @{ QNAME = $g.qname; DEST = $g.dest } `
            -MsgText ("qRFC $dir queue " + $g.qname + " (dest " + $g.dest + "): " + $g.depth + " entr(ies), state " + $g.worst + ", oldest " + $g.oldest + $(if ($g.errmess) { ' -- ' + $g.errmess })) `
            -Tech @{ leg = "qRFC-$dir"; queue = $g.qname; dest = $g.dest; depth = $g.depth; state = $g.worst; fm = $g.fm; errmess = $g.errmess } `
            -Drilldown ("$drillTcode -> " + $g.qname)
    }
}
try { Read-QrfcLeg 'TRFCQOUT' 'OUT' 'SMQ1'; $legsOk++ } catch { $notes += "qRFC-out(TRFCQOUT):$($_.Exception.Message)" }
try { Read-QrfcLeg 'TRFCQIN'  'IN'  'SMQ2'; $legsOk++ } catch { $notes += "qRFC-in(TRFCQIN):$($_.Exception.Message)" }

Disconnect-SapRfc
$status = if ($legsOk -eq 0) { 'skipped' } else { 'ok' }
$reason = if ($notes.Count) { "events=$($events.Count); leg_errors: " + ($notes -join '; ') } else { "events=$($events.Count) legs_ok=$legsOk" }
Write-DiagEvidence 'SMQ' $status $reason $events $anyTrunc $grandTotal $OutFile
