# =============================================================================
# sap_retrofit_ledger.ps1  -  local retrofit workspace + ledger for /sap-retrofit
#
# LOCAL ONLY (no SAP). Manages {work_dir}\retrofit\<project>\ : project.json (profiles,
# packages, watermark) + ledger.tsv (one row per retrofit candidate object). Atomic rewrite,
# state-machine enforced (no APPLIED/VERIFIED without a GREEN/APPROVED classification).
#
#   init      -Workspace <dir> -MaintHint <h> [-Packages <p>] [-Since <YYYYMMDD>]
#   append    -Workspace <dir> -Pgmid <R3TR|LIMU> -Object <type> -ObjName <n> -MaintTr <tr> [-ReleasedOn <d>]
#   set-state -Workspace <dir> -Object <type> -ObjName <n> -State <S> [-Evidence <e>] [-DiffRef <p>] [-DraftRef <p>] [-AppliedTr <tr>] [-Verify <v>] [-Note <t>]
#   watermark -Workspace <dir> -Since <YYYYMMDD>
#   list      -Workspace <dir> [-State <S>] [-Rollup]
#
# stdout: RETRO_LEDGER: ... + STATUS: OK | RETRO_LEDGER_IO | RETRO_LEDGER_CONFLICT ; exit 0/1/2
# =============================================================================
[CmdletBinding()]
param(
    [ValidateSet('init','append','set-state','watermark','list')]
    [string] $Action    = 'list',
    [string] $Workspace = '',
    [string] $MaintHint = '',
    [string] $Packages  = '',
    [string] $Since     = '',
    [string] $Pgmid     = '',
    [string] $Object    = '',
    [string] $ObjName   = '',
    [string] $MaintTr   = '',
    [string] $ReleasedOn= '',
    [string] $State     = '',
    [string] $Evidence  = '',
    [string] $DiffRef   = '',
    [string] $DraftRef  = '',
    [string] $AppliedTr = '',
    [string] $Verify    = '',
    [string] $Note      = '',
    [switch] $Rollup
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$COLS = 'pgmid','object','obj_name','maint_trs','maint_tr_latest','released_on','state','evidence','diff_ref','draft_ref','applied_tr','verify','note'
$STATES = @('HARVESTED','IN_SYNC','GREEN','GREEN_MANUAL','YELLOW','RED','DRAFTED','APPROVED','APPLIED','VERIFIED','VERIFY_FAILED')
$APPLY_OK = @('GREEN','APPROVED')   # only these may transition to APPLIED

if (-not $Workspace) { Write-Host 'STATUS: RETRO_LEDGER_IO reason=no_workspace'; exit 2 }
if ($Action -ne 'init' -and -not (Test-Path (Join-Path $Workspace 'project.json'))) { Write-Host 'STATUS: RETRO_LEDGER_IO reason=workspace_not_initialized'; exit 1 }
$ledgerPath = Join-Path $Workspace 'ledger.tsv'

function Read-Ledger {
    if (-not (Test-Path $ledgerPath)) { return }
    $lines = [IO.File]::ReadAllText($ledgerPath,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF) -split "`r`n|`n"
    $first = $true
    foreach ($ln in $lines) {
        if ($null -eq $ln -or "$ln".Trim() -eq '' -or "$ln".StartsWith('#')) { continue }
        $c = @($ln -split "`t")
        if ($first) { $first = $false; if ($c[0] -eq 'pgmid') { continue } }
        $rec = [ordered]@{}
        for ($j = 0; $j -lt $COLS.Count; $j++) { $rec[$COLS[$j]] = if ($j -lt $c.Count) { $c[$j] } else { '' } }
        [pscustomobject]$rec
    }
}
function Write-Ledger { param($rows)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(($COLS -join "`t"))
    foreach ($r in $rows) { [void]$sb.AppendLine((($COLS | ForEach-Object { ("$($r.$_)") -replace "`t",' ' }) -join "`t")) }
    $tmp = "$ledgerPath.tmp"
    [IO.File]::WriteAllText($tmp, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    Move-Item -Force $tmp $ledgerPath
}
function Key { param($r) return ("$($r.object)|$($r.obj_name)") }

# =========================== init ===========================================
if ($Action -eq 'init') {
    if (-not $MaintHint) { Write-Host 'STATUS: RETRO_LEDGER_IO reason=no_maint_hint'; exit 2 }
    if (-not (Test-Path $Workspace)) { New-Item -ItemType Directory -Force -Path $Workspace | Out-Null }
    foreach ($sub in 'diffs','drafts','reports') { $p = Join-Path $Workspace $sub; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }
    $proj = [ordered]@{ maint_hint=$MaintHint; packages=$Packages; since=$Since; watermark=$Since; created_utc=((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) }
    [IO.File]::WriteAllText((Join-Path $Workspace 'project.json'), ($proj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    if (-not (Test-Path $ledgerPath)) { [IO.File]::WriteAllText($ledgerPath, (($COLS -join "`t") + "`r`n"), (New-Object Text.UTF8Encoding($true))) }
    Write-Host ("RETRO_LEDGER: initialized workspace={0} maint={1} since={2}" -f $Workspace,$MaintHint,$Since)
    Write-Host 'STATUS: OK action=init'
    exit 0
}

# =========================== append (harvest) ===============================
if ($Action -eq 'append') {
    if (-not $ObjName -or -not $Object) { Write-Host 'STATUS: RETRO_LEDGER_IO reason=no_object'; exit 2 }
    $rows = @(Read-Ledger)
    $newRec = [ordered]@{}; foreach ($col in $COLS) { $newRec[$col] = '' }
    $existing = $rows | Where-Object { (Key $_) -eq ("$Object|$ObjName") } | Select-Object -First 1
    if ($existing) {
        $trs = @("$($existing.maint_trs)" -split ',' | Where-Object { $_ })
        if ($MaintTr -and ($trs -notcontains $MaintTr)) { $trs += $MaintTr }
        $existing.maint_trs = ($trs -join ',')
        if ($MaintTr) { $existing.maint_tr_latest = $MaintTr }
        if ($ReleasedOn) { $existing.released_on = $ReleasedOn }
        # a re-harvest of an already-classified object resets it to HARVESTED (new maint change to re-assess)
        if ($existing.state -notin @('HARVESTED','APPLIED','VERIFIED')) { $existing.state = 'HARVESTED' }
        Write-Ledger $rows
        Write-Host ("RETRO_LEDGER: updated object={0} trs={1}" -f $ObjName,$existing.maint_trs)
    } else {
        $newRec.pgmid = $Pgmid; $newRec.object = $Object; $newRec.obj_name = $ObjName
        $newRec.maint_trs = $MaintTr; $newRec.maint_tr_latest = $MaintTr; $newRec.released_on = $ReleasedOn
        $newRec.state = 'HARVESTED'
        $all = @($rows) + @([pscustomobject]$newRec)
        Write-Ledger $all
        Write-Host ("RETRO_LEDGER: appended object={0} type={1} tr={2}" -f $ObjName,$Object,$MaintTr)
    }
    Write-Host 'STATUS: OK action=append'
    exit 0
}

# =========================== set-state (classify/draft/apply) ================
if ($Action -eq 'set-state') {
    if (-not ($STATES -contains $State)) { Write-Host ("STATUS: RETRO_LEDGER_CONFLICT reason=bad_state state={0}" -f $State); exit 1 }
    $rows = @(Read-Ledger)
    $row = $rows | Where-Object { (Key $_) -eq ("$Object|$ObjName") } | Select-Object -First 1
    if (-not $row) { Write-Host ("STATUS: RETRO_LEDGER_CONFLICT reason=unknown_object object={0}" -f $ObjName); exit 1 }
    # state-machine guard: APPLIED/VERIFIED requires the current state be GREEN/APPROVED (or already applied)
    if ($State -in @('APPLIED','VERIFIED','VERIFY_FAILED')) {
        if ($row.state -notin ($APPLY_OK + @('APPLIED','VERIFIED','VERIFY_FAILED'))) {
            Write-Host ("STATUS: RETRO_LEDGER_CONFLICT reason=apply_requires_green_or_approved object={0} current={1}" -f $ObjName,$row.state); exit 1
        }
    }
    $row.state = $State
    if ($PSBoundParameters.ContainsKey('Evidence')) { $row.evidence = $Evidence }
    if ($PSBoundParameters.ContainsKey('DiffRef'))  { $row.diff_ref = $DiffRef }
    if ($PSBoundParameters.ContainsKey('DraftRef')) { $row.draft_ref = $DraftRef }
    if ($PSBoundParameters.ContainsKey('AppliedTr')){ $row.applied_tr = $AppliedTr }
    if ($PSBoundParameters.ContainsKey('Verify'))   { $row.verify = $Verify }
    if ($PSBoundParameters.ContainsKey('Note'))     { $row.note = ($Note -replace "`t",' ') }
    Write-Ledger $rows
    Write-Host ("RETRO_LEDGER: set-state object={0} state={1}" -f $ObjName,$State)
    Write-Host 'STATUS: OK action=set-state'
    exit 0
}

# =========================== watermark ======================================
if ($Action -eq 'watermark') {
    $pjPath = Join-Path $Workspace 'project.json'
    $pj = Get-Content $pjPath -Raw | ConvertFrom-Json
    $pj.watermark = $Since
    [IO.File]::WriteAllText($pjPath, ($pj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Write-Host ("RETRO_LEDGER: watermark={0}" -f $Since)
    Write-Host 'STATUS: OK action=watermark'
    exit 0
}

# =========================== list / rollup ==================================
if ($Action -eq 'list') {
    $rows = @(Read-Ledger)
    if ($State) { $rows = @($rows | Where-Object { $_.state -eq $State }) }
    if ($Rollup) {
        $byState = $rows | Group-Object state | Sort-Object Name
        foreach ($g in $byState) { Write-Host ("RETRO_ROLLUP: state={0} count={1}" -f $g.Name,$g.Count) }
        $pending = @($rows | Where-Object { $_.state -in @('HARVESTED','YELLOW','RED','DRAFTED') })
        Write-Host ("STATUS: OK action=rollup total={0} pending={1}" -f $rows.Count,$pending.Count)
    } else {
        foreach ($r in $rows) { Write-Host ("RETRO_LEDGER: object={0} type={1} state={2} maint_tr={3} evidence={4} verify={5}" -f $r.obj_name,$r.object,$r.state,$r.maint_tr_latest,$r.evidence,$r.verify) }
        Write-Host ("STATUS: OK action=list rows={0}" -f $rows.Count)
    }
    exit 0
}
