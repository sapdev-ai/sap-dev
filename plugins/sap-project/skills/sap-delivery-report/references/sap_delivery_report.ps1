# =============================================================================
# sap_delivery_report.ps1  -  Delivery status engine for /sap-delivery-report
#
# Offline-first weekly status: aggregates the artifact index (ATC / check-abap /
# abap-unit / transport-readiness / impact verdicts), build KPIs, and one live
# E071->E070/E07T RFC read for TR pipeline position, derives a DETERMINISTIC RAG
# from a shipped rules table, and persists a snapshot for week-over-week diffing.
# Writes report_data.json (structured) for the SKILL.md to render report.md from.
#
# READ-ONLY: the only SAP touch is RFC_READ_TABLE (skipped entirely with -Offline).
# All other inputs are local machine-readable files. No GUI, no wrapper FM.
#
# Reuses Phase-0 primitives: sap_artifact_lib (Find-SapArtifacts, New-SapScopeKey,
# Get-SapArtifactDir, Register-SapArtifact), sap_object_resolver (Resolve-SapObject,
# Read-SapTableRows), sap_rfc_lib (Connect-SapRfc).
#
# Output (stdout): REPORT_DATA: <path>  SNAPSHOT: <path>  ARTIFACT_DIR: <path>
#                  RAG: GREEN=<n> AMBER=<n> RED=<n>  SCOPE_KEY: <key>
#                  STATUS: OK | SCOPE_EMPTY | NO_INDEX | RFC_ERROR
# Exit: 0 = OK (incl. NO_INDEX degraded report) | 1 = SCOPE_EMPTY | 2 = RFC_ERROR.
# =============================================================================

[CmdletBinding()]
param(
    [string]   $Action = 'generate',   # generate | snapshots | diff
    [string]   $Scope = '',            # PACKAGE <pkg> | TR <trkorr> | <TYPE> <NAME> | a scope-key
    [string]   $Ticket = '',
    [string]   $Since = '',            # '' | last | YYYY-MM-DD | <snapshot-file>
    [string]   $Title = '',
    [switch]   $Offline,
    [int]      $MaxTrObjects = 100,    # cap objects for the TR-position read
    [int]      $SnapshotKeep = 26,
    [string]   $SharedDir = '',
    [string]   $CustomUrl = '',
    [string]   $SkillDir = '',
    [string]   $OutputDir = '',
    [string]   $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) {
    try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' }
}
if (-not $SkillDir) { $SkillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1','sap_artifact_lib.ps1','sap_finding_lib.ps1') {
    $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

# --- RAG engine (pure) -----------------------------------------------------
$RAG_ORDER = @{ GREEN = 0; AMBER = 1; RED = 2 }

function Import-RagRules {
    param([string] $SkillDir, [string] $CustomUrl)
    $rules = @{ verdict=@{}; coverage=@{}; finding=@{} }
    $files = @(Join-Path $SkillDir 'references\sap_delivery_rag_rules.tsv')
    if ($CustomUrl) { $files += (Join-Path $CustomUrl 'sap_delivery_rag_rules.tsv') }
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        foreach ($ln in [System.IO.File]::ReadAllLines($f)) {
            if ($ln -match '^\s*#' -or $ln.Trim() -eq '') { continue }
            $c = $ln -split "`t"; if ($c.Count -lt 3) { continue }
            $st = $c[0].Trim().ToLower(); if ($st -eq 'signal_type') { continue }
            if ($rules.ContainsKey($st)) { $rules[$st][$c[1].Trim().ToUpper()] = $c[2].Trim().ToUpper() }
        }
    }
    return $rules
}
function Worse-Rag { param([string] $A, [string] $B) if (-not $A) { return $B }; if (-not $B) { return $A }; if ($RAG_ORDER[$B] -gt $RAG_ORDER[$A]) { return $B } else { return $A } }

# RAG contribution of one artifact record (verdict + coverage). Hard floor:
# COULD_NOT_CHECK never GREEN.
function Get-ArtifactRag {
    param($Rules, $Artifact)
    $rag = ''
    $v = "$($Artifact.verdict)".ToUpper(); $cov = "$($Artifact.coverage)".ToUpper()
    if ($v -and $Rules.verdict.ContainsKey($v)) { $rag = Worse-Rag $rag $Rules.verdict[$v] }
    if ($cov -and $Rules.coverage.ContainsKey($cov)) { $rag = Worse-Rag $rag $Rules.coverage[$cov] }
    if ($cov -eq 'COULD_NOT_CHECK') { $rag = Worse-Rag $rag 'AMBER' }   # hard floor
    if (-not $rag) { $rag = 'GREEN' }   # a registered artifact with neither verdict nor coverage is neutral
    return $rag
}

# --- helpers ---------------------------------------------------------------
function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Is-ScopeKey { param([string] $t) return ($t -match '^(PROG|CLAS|INTF|FUGR|FUNC|TABL|VIEW|DTEL|DOMA|DEVC|PKG|TR|TRSET|SID|TICKET)_') }

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    $rules = Import-RagRules -SkillDir $SkillDir -CustomUrl $CustomUrl

    # ---- artifact_dir resolution ----
    $artRoot = if ($env:SAPDEV_ARTIFACT_DIR) { $env:SAPDEV_ARTIFACT_DIR } else {
        try { Join-Path (Get-SapWorkDir) 'artifacts' } catch { Join-Path (Get-Location).Path 'artifacts' }
    }
    $indexPath = Join-Path $artRoot 'index.jsonl'

    # ---- connect (unless offline or a scope-key/ticket makes RFC unnecessary) ----
    $needRfc = (-not $Offline) -and (-not (Is-ScopeKey $Scope)) -and (-not $Ticket -or $Scope)
    $g_dest = $null; $sid = ''; $effClient = $Client
    if (-not $Offline) {
        $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_DELIVERY"
        if ($g_dest) { try { $sid = Get-SapResolverSysId -Destination $g_dest } catch {}; if (-not $effClient) { $effClient = "$g_sapClient" } }
    }

    # ---- resolve scope -> scope key + object list ----
    $scopeKey = ''; $objects = @()
    if ($Ticket -and -not $Scope) {
        $scopeKey = "TICKET_" + ($Ticket.ToUpper() -replace '[^A-Z0-9_]','_')
    } elseif (Is-ScopeKey $Scope) {
        $scopeKey = $Scope
    } elseif ($Scope) {
        if ($g_dest) {
            # resolve the primary object (scope key) without expand, then expand
            # containers (package/TR) into member objects.
            $primary = @(Resolve-SapObject -Destination $g_dest -Token $Scope | Where-Object { $_ -and $_.obj_name }) | Select-Object -First 1
            if ($primary) {
                $scopeKey = New-SapScopeKey -Resolved $primary
                $pk = "$($primary.kind)".ToUpper()
                if ($pk -in @('PACKAGE','DEVC')) {
                    # expand a package via a direct TADIR read (resolver -Expand proved unreliable here)
                    $pname = "$($primary.obj_name)"
                    $td = Read-SapTableRows -Destination $g_dest -Table 'TADIR' -Where "DEVCLASS EQ '$($pname -replace "'","''")' AND PGMID EQ 'R3TR'" -Fields @('PGMID','OBJECT','OBJ_NAME') -RowCount 2000
                    $objects = @($td | Where-Object { $_.OBJ_NAME } | ForEach-Object { [pscustomobject]@{ pgmid="$($_.PGMID)"; object="$($_.OBJECT)"; obj_name="$($_.OBJ_NAME)"; kind="$($_.OBJECT)"; package=$pname } })
                } elseif ($pk -in @('TR','REQUEST','TRANSPORT')) {
                    $tr = "$($primary.obj_name)"
                    $e = Read-SapTableRows -Destination $g_dest -Table 'E071' -Where "TRKORR EQ '$($tr -replace "'","''")' AND PGMID EQ 'R3TR'" -Fields @('PGMID','OBJECT','OBJ_NAME') -RowCount 2000
                    $objects = @($e | Where-Object { $_.OBJ_NAME } | ForEach-Object { [pscustomobject]@{ pgmid="$($_.PGMID)"; object="$($_.OBJECT)"; obj_name="$($_.OBJ_NAME)"; kind="$($_.OBJECT)"; package='' } })
                } else {
                    $objects = @($primary)
                }
            }
        }
        if (-not $scopeKey) { $scopeKey = $Scope.ToUpper() -replace '[^A-Z0-9_]','_' }
    }

    if (-not $scopeKey -and -not $Ticket) {
        Write-Host "STATUS: SCOPE_EMPTY"; Write-Host "RAG: GREEN=0 AMBER=0 RED=0"
        if ($g_dest) { Disconnect-SapRfc }; exit 1
    }

    # ---- Action: snapshots (list) ----
    $snapDir = Join-Path (Join-Path $artRoot 'delivery-report') (Join-Path $scopeKey 'snapshots')
    if ($Action -eq 'snapshots') {
        if (Test-Path $snapDir) {
            foreach ($f in (Get-ChildItem $snapDir -Filter '*.json' | Sort-Object Name -Descending)) {
                try { $s = Get-Content $f.FullName -Raw | ConvertFrom-Json; Write-Host ("SNAP: id={0} ts={1} green={2} amber={3} red={4}" -f $f.BaseName, $s.ts, $s.rag_counts.GREEN, $s.rag_counts.AMBER, $s.rag_counts.RED) } catch {}
            }
        }
        Write-Host "STATUS: OK"; if ($g_dest) { Disconnect-SapRfc }; exit 0
    }

    # ---- collect artifacts (index) ----
    $indexPresent = Test-Path $indexPath
    $allArtifacts = @()
    if ($indexPresent) {
        $keys = @($scopeKey) + @($objects | ForEach-Object { try { New-SapScopeKey -Resolved $_ } catch { '' } })
        $keys = @($keys | Where-Object { $_ } | Select-Object -Unique)
        foreach ($k in $keys) {
            $found = @(Find-SapArtifacts -ScopeKey $k)
            foreach ($a in $found) { $allArtifacts += $a }
        }
        if ($Ticket) { foreach ($a in @(Find-SapArtifacts -Ticket $Ticket)) { $allArtifacts += $a } }
    }
    # dedup by id
    $allArtifacts = @($allArtifacts | Group-Object id | ForEach-Object { $_.Group[0] })

    # ---- per-object rows + workstream RAG ----
    # group artifacts by their scope key (object)
    $byScope = @{}
    foreach ($a in $allArtifacts) {
        $k = "$($a.scope.key)"; if (-not $byScope.ContainsKey($k)) { $byScope[$k] = @() }; $byScope[$k] += $a
    }
    $rows = @()
    $scopeKeysForRows = if ($objects.Count) { @($objects | ForEach-Object { try { New-SapScopeKey -Resolved $_ } catch { '' } }) } else { @($scopeKey) }
    $scopeKeysForRows = @($scopeKeysForRows | Where-Object { $_ } | Select-Object -Unique)
    if (-not $scopeKeysForRows.Count) { $scopeKeysForRows = @($byScope.Keys) }
    foreach ($k in $scopeKeysForRows) {
        $arts = if ($byScope.ContainsKey($k)) { $byScope[$k] } else { @() }
        $gates = @{}
        $rowRag = ''
        foreach ($a in $arts) {
            $r = Get-ArtifactRag -Rules $rules -Artifact $a.artifact
            # override with the record-level verdict/coverage which live at the top of the artifact record
            $r = Get-ArtifactRag -Rules $rules -Artifact ([pscustomobject]@{ verdict = $a.verdict; coverage = $a.coverage })
            $rowRag = Worse-Rag $rowRag $r
            $gates["$($a.artifact.kind)"] = [ordered]@{ verdict = "$($a.verdict)"; coverage = "$($a.coverage)"; artifact_id = "$($a.id)"; rag = $r }
        }
        if (-not $arts.Count) { $rowRag = 'AMBER' }   # no evidence => AMBER floor
        $rows += [pscustomobject]@{ scope_key = $k; artifacts = $arts.Count; gates = $gates; tr = ''; trstatus = ''; tr_text = ''; rag = $rowRag }
    }

    # ---- TR position (the one live read) ----
    if ($g_dest -and $objects.Count) {
        $probe = @($objects | Select-Object -First $MaxTrObjects)
        foreach ($o in $probe) {
            try {
                $e071 = Read-SapTableRows -Destination $g_dest -Table 'E071' -Where "OBJ_NAME EQ '$("$($o.obj_name)" -replace "'","''")'" -Fields @('TRKORR','OBJ_NAME') -RowCount 20
                $trs = @($e071 | ForEach-Object { "$($_.TRKORR)" } | Where-Object { $_ } | Select-Object -Unique)
                if ($trs.Count) {
                    $tr = ($trs | Sort-Object -Descending)[0]
                    $hdr = Read-SapTableRows -Destination $g_dest -Table 'E070' -Where "TRKORR EQ '$tr'" -Fields @('TRKORR','TRSTATUS','AS4USER') -RowCount 1
                    $txt = Read-SapTableRows -Destination $g_dest -Table 'E07T' -Where "TRKORR EQ '$tr'" -Fields @('TRKORR','AS4TEXT') -RowCount 1
                    $k = try { New-SapScopeKey -Resolved $o } catch { '' }
                    $row = $rows | Where-Object { $_.scope_key -eq $k } | Select-Object -First 1
                    if ($row) { $row.tr = $tr; $row.trstatus = if ($hdr.Count) { "$($hdr[0].TRSTATUS)" } else { '' }; $row.tr_text = if ($txt.Count) { "$($txt[0].AS4TEXT)" } else { '' } }
                }
            } catch {}
        }
    }

    # ---- workstream RAG rollup ----
    $counts = @{ GREEN = 0; AMBER = 0; RED = 0 }
    foreach ($r in $rows) { if ($counts.ContainsKey($r.rag)) { $counts[$r.rag]++ } }
    $workstreamRag = 'GREEN'
    foreach ($r in $rows) { $workstreamRag = Worse-Rag $workstreamRag $r.rag }
    if (-not $rows.Count) { $workstreamRag = 'AMBER' }

    # ---- build KPIs (best-effort) ----
    $kpi = $null
    try { $kpiPath = Join-Path (Get-SapWorkDir) 'metrics\build_kpi.jsonl'; if (Test-Path $kpiPath) { $kpi = @(Get-Content $kpiPath | Select-Object -Last 1 | ForEach-Object { $_ | ConvertFrom-Json }) } } catch {}

    # ---- output dir ----
    if (-not $OutputDir) { try { $OutputDir = Get-SapArtifactDir -ScopeKey $scopeKey -Skill 'sap-delivery-report' -RunId $RunId } catch { $OutputDir = (Get-Location).Path } }
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

    # ---- --since diff ----
    $diff = $null
    if ($Since) {
        $prior = $null
        if (Test-Path $snapDir) {
            $snaps = @(Get-ChildItem $snapDir -Filter '*.json' | Sort-Object Name -Descending)
            if ($Since -eq 'last') { if ($snaps.Count) { $prior = $snaps[0].FullName } }
            elseif (Test-Path $Since) { $prior = $Since }
            else { $cand = $snaps | Where-Object { $_.BaseName -like "*$Since*" } | Select-Object -First 1; if ($cand) { $prior = $cand.FullName } }
        }
        if ($prior) {
            try {
                $ps = Get-Content $prior -Raw | ConvertFrom-Json
                $priorByKey = @{}; foreach ($pr in $ps.rows) { $priorByKey["$($pr.scope_key)"] = "$($pr.rag)" }
                $transitions = @{}; $newObjects = @()
                foreach ($r in $rows) {
                    $was = $priorByKey["$($r.scope_key)"]
                    if (-not $was) { $newObjects += $r.scope_key }
                    elseif ($was -ne $r.rag) { $t = "$was->$($r.rag)"; if (-not $transitions.ContainsKey($t)) { $transitions[$t]=0 }; $transitions[$t]++ }
                }
                $diff = [ordered]@{ prior = (Split-Path $prior -Leaf); transitions = $transitions; new_objects = $newObjects }
            } catch { $diff = [ordered]@{ error = 'DR_SNAPSHOT_CORRUPT' } }
        } else { $diff = [ordered]@{ note = 'first report for this scope' } }
    }

    # ---- report_data.json ----
    $data = [ordered]@{
        schema = 'sapdev.deliverydata/1'
        title = $Title
        scope_key = $scopeKey
        ticket = $Ticket
        system = @{ sid = $sid; client = $effClient }
        offline = [bool]$Offline
        index_present = $indexPresent
        workstream_rag = $workstreamRag
        rag_counts = $counts
        rows = $rows
        kpi = $kpi
        diff = $diff
        object_count = $rows.Count
    }
    $dataPath = Join-Path $OutputDir 'report_data.json'
    [System.IO.File]::WriteAllText($dataPath, ($data | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

    # ---- snapshot ----
    if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Force -Path $snapDir | Out-Null }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $snap = [ordered]@{ schema='sapdev.deliverysnapshot/1'; scope_key=$scopeKey; system=@{sid=$sid;client=$effClient}; ts=$ts; rag_counts=$counts; workstream_rag=$workstreamRag; rows=@($rows | ForEach-Object { [ordered]@{ scope_key=$_.scope_key; tr=$_.tr; trstatus=$_.trstatus; rag=$_.rag } }) }
    $snapPath = Join-Path $snapDir "$ts.json"
    [System.IO.File]::WriteAllText($snapPath, ($snap | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    # retention
    $snaps = @(Get-ChildItem $snapDir -Filter '*.json' | Sort-Object Name -Descending)
    if ($snaps.Count -gt $SnapshotKeep) { $snaps | Select-Object -Skip $SnapshotKeep | ForEach-Object { Remove-Item $_.FullName -Force } }

    # ---- trend TSVs (append) ----
    $trendDir = Join-Path (Join-Path $artRoot 'delivery-report') $scopeKey
    $gatesTrend = Join-Path $trendDir 'trend_gates.tsv'
    if (-not (Test-Path $gatesTrend)) { [System.IO.File]::WriteAllText($gatesTrend, "ts`tgreen`tamber`tred`tworkstream_rag`r`n", (New-Object System.Text.UTF8Encoding($true))) }
    [System.IO.File]::AppendAllText($gatesTrend, ("{0}`t{1}`t{2}`t{3}`t{4}`r`n" -f $ts,$counts.GREEN,$counts.AMBER,$counts.RED,$workstreamRag), (New-Object System.Text.UTF8Encoding($false)))

    # ---- register + emit ----
    try { Register-SapArtifact -Skill 'sap-delivery-report' -ScopeKey $scopeKey -Kind 'delivery_data' -Format 'json' -Path $dataPath -Verdict $workstreamRag -Coverage (& { if (-not $indexPresent) { 'COULD_NOT_CHECK' } elseif ($counts.RED -or $counts.AMBER) { 'CHECKED_FINDINGS' } else { 'CHECKED_CLEAN' } }) -Ticket $Ticket -RunId $RunId -System $sid -Client $effClient | Out-Null } catch {}

    Write-Host "REPORT_DATA: $dataPath"
    Write-Host "SNAPSHOT: $snapPath"
    Write-Host "ARTIFACT_DIR: $OutputDir"
    Write-Host ("RAG: GREEN={0} AMBER={1} RED={2}" -f $counts.GREEN, $counts.AMBER, $counts.RED)
    Write-Host "SCOPE_KEY: $scopeKey"
    if (-not $indexPresent) { Write-Host "STATUS: NO_INDEX" } else { Write-Host "STATUS: OK" }
    if ($g_dest) { Disconnect-SapRfc }
    exit 0
}
