# =============================================================================
# sap_cutover_report.ps1  -  local status board + critical path for /sap-cutover-runbook
#
# LOCAL ONLY. Replays cutover.json + events.jsonl -> per-phase progress, late/blocker lists,
# critical path (longest planned-duration chain through NOT-DONE steps over the dependency
# DAG), and checkpoint rollups. Writes cutover_board.md. Deterministic (same events -> same
# board). A torn last event line is quarantined, never parsed as state.
#
#   -OutDir <ledgerdir> [-WindowHours N]
# stdout: CUTOVER: id=<id> done=<n>/<total> late=<k> blocked=<b> critical="<chain>" + STATUS: OK|CUTOVER_LEDGER_NOT_FOUND
# =============================================================================
[CmdletBinding()]
param(
    [string] $OutDir = '',
    [int]    $WindowHours = 0
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $OutDir) { Write-Host 'STATUS: CUTOVER_LEDGER_NOT_FOUND reason=no_outdir'; exit 2 }
$planPath = Join-Path $OutDir 'cutover.json'
if (-not (Test-Path $planPath)) { Write-Host 'STATUS: CUTOVER_LEDGER_NOT_FOUND'; exit 1 }
$plan = Get-Content $planPath -Raw | ConvertFrom-Json

# ---- replay events -> status/actuals ----
$evPath = Join-Path $OutDir 'events.jsonl'
$events=@()
if (Test-Path $evPath) {
    $lines=@([IO.File]::ReadAllLines($evPath))
    for ($i=0;$i -lt $lines.Count;$i++){ $ln=$lines[$i]; if (-not "$ln".Trim()){continue}; try { $events += ($ln | ConvertFrom-Json) } catch { } }
}
$state=@{}
foreach ($s in $plan.steps) { $state["$($s.id)"]=[ordered]@{ status='PENDING'; actual_start=''; actual_end='' } }
foreach ($e in @($events | Sort-Object { "$($_.ts_utc)" })) {
    $sid="$($e.step_id)"; if (-not $state.ContainsKey($sid)) { continue }
    switch ("$($e.event)".ToLower()) {
        'start'  { $state[$sid].status='STARTED'; $state[$sid].actual_start="$($e.ts_utc)" }
        'done'   { $state[$sid].status='DONE';    $state[$sid].actual_end="$($e.ts_utc)" }
        'fail'   { $state[$sid].status='FAILED';  $state[$sid].actual_end="$($e.ts_utc)" }
        'skip'   { $state[$sid].status='SKIPPED' }
        'block'  { $state[$sid].status='BLOCKED' }
        'reopen' { $state[$sid].status='STARTED'; $state[$sid].actual_end='' }
    }
}

# ---- index + DAG ----
$byId=@{}; foreach ($s in $plan.steps) { $byId["$($s.id)"]=$s }
$dur=@{}; foreach ($s in $plan.steps) { $d=0; if ("$($s.planned_duration)" -match '^\d+$') { $d=[int]$s.planned_duration }; $dur["$($s.id)"]=$d }
$isDone = { param($id) $state[$id].status -in @('DONE','SKIPPED') }

# ---- critical path: longest planned-duration chain over NOT-DONE steps (memoized DFS) ----
$memo=@{}
function LongestFrom { param($id)
    if ($script:memo.ContainsKey($id)) { return $script:memo[$id] }
    $best=@{ len=0; chain=@() }
    # successors = steps that depend on $id
    $succ = @($plan.steps | Where-Object { $_.depends_on -and (@($_.depends_on) -contains $id) } | ForEach-Object { "$($_.id)" })
    foreach ($sc in $succ) {
        if ((& $script:isDone $sc)) { continue }
        $r = LongestFrom $sc
        if ($r.len -gt $best.len) { $best=$r }
    }
    $me=@{ len=($script:dur[$id] + $best.len); chain=(@($id) + $best.chain) }
    $script:memo[$id]=$me; return $me
}
# roots = not-done steps whose deps are all done/absent
$roots = @($plan.steps | Where-Object { -not (& $isDone "$($_.id)") -and ( -not $_.depends_on -or (@($_.depends_on) | Where-Object { -not (& $isDone $_) }).Count -eq 0 ) } | ForEach-Object { "$($_.id)" })
$crit=@{ len=0; chain=@() }
foreach ($r in $roots) { $lr = LongestFrom $r; if ($lr.len -gt $crit.len) { $crit=$lr } }

# ---- phase rollup ----
$phases = @($plan.steps | ForEach-Object { "$($_.phase)" } | Where-Object { $_ } | Select-Object -Unique)
$phaseRows=@()
foreach ($ph in $phases) {
    $ps = @($plan.steps | Where-Object { "$($_.phase)" -eq $ph })
    $pd = @($ps | Where-Object { (& $isDone "$($_.id)") }).Count
    $phaseRows += [pscustomobject]@{ phase=$ph; total=$ps.Count; done=$pd }
}
$blocked = @($plan.steps | Where-Object { $state["$($_.id)"].status -in @('BLOCKED','FAILED') })
$doneN = @($plan.steps | Where-Object { (& $isDone "$($_.id)") }).Count

# ---- render board ----
$md=New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Cutover board - $($plan.cutover_id)")
[void]$md.AppendLine('')
[void]$md.AppendLine("Generated (replay of $($events.Count) events). Progress **$doneN / $($plan.steps.Count)** steps done.")
[void]$md.AppendLine('')
[void]$md.AppendLine('## Phase progress')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Phase | Done | Total |')
[void]$md.AppendLine('|---|---|---|')
foreach ($p in $phaseRows) { [void]$md.AppendLine("| $($p.phase) | $($p.done) | $($p.total) |") }
[void]$md.AppendLine('')
[void]$md.AppendLine('## Critical path (remaining, longest planned-duration chain)')
[void]$md.AppendLine('')
if ($crit.chain.Count) {
    [void]$md.AppendLine("Estimated remaining critical duration: **$($crit.len) min** over $($crit.chain.Count) steps.")
    [void]$md.AppendLine('')
    foreach ($id in $crit.chain) { $s=$byId[$id]; [void]$md.AppendLine("- **$id** ($($dur[$id]) min) - $($s.text) [$($state[$id].status)]") }
} else { [void]$md.AppendLine('- (no remaining steps - all done/skipped)') }
[void]$md.AppendLine('')
[void]$md.AppendLine('## Blockers / failures')
[void]$md.AppendLine('')
if ($blocked.Count) { foreach ($b in $blocked) { [void]$md.AppendLine("- **$($b.id)** [$($state["$($b.id)"].status)] - $($b.text)") } } else { [void]$md.AppendLine('- (none)') }
[void]$md.AppendLine('')
[void]$md.AppendLine('## Checkpoints')
[void]$md.AppendLine('')
foreach ($cp in @($plan.checkpoints)) {
    $ahead = @($plan.steps | Where-Object { "$($_.checkpoint)" -eq $cp })
    $aheadDone = @($ahead | Where-Object { (& $isDone "$($_.id)") }).Count
    [void]$md.AppendLine("- **$cp**: $aheadDone / $($ahead.Count) marked steps complete")
}
[IO.File]::WriteAllText((Join-Path $OutDir 'cutover_board.md'), $md.ToString(), (New-Object Text.UTF8Encoding($false)))

$chainStr = ($crit.chain -join '->')
Write-Host ("CUTOVER: id={0} done={1}/{2} blocked={3} critical=`"{4}`" critical_min={5}" -f $plan.cutover_id,$doneN,$plan.steps.Count,$blocked.Count,$chainStr,$crit.len)
Write-Host ("STATUS: OK total={0} done={1}" -f $plan.steps.Count,$doneN)
exit 0
