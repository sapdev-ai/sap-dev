# =============================================================================
# sap_artifact_lib.ps1  -  Artifact index for the delivery-assurance skills
#
# Phase-0 foundation primitive #2. See
# contributing/phase0_delivery_assurance_spec.md  §B.
#
# Every analytical skill (impact-analysis, transport-readiness, evidence-pack,
# enhancement-advisor) REGISTERS each file it writes into one append-only
# manifest so /sap-evidence-pack can collect everything by scope / ticket /
# date WITHOUT scraping the filesystem.
#
# Pure-local: file I/O + logic only. No SAP, no RFC, no NCo. Dot-source it:
#
#   . "<...>\sap_artifact_lib.ps1"
#   $scope = New-SapScopeKey -Resolved $obj            # "PROG_ZMMR001"
#   $dir   = Get-SapArtifactDir -ScopeKey $scope -Skill 'sap-transport-readiness'
#   # ... write $dir\DEVK900123_readiness.md ...
#   $id = Register-SapArtifact -Skill 'sap-transport-readiness' -ScopeKey $scope `
#             -Object $obj -Kind 'readiness_report' -Format 'md' `
#             -Path "$dir\DEVK900123_readiness.md" -Verdict 'NO_GO' -Coverage 'CHECKED_FINDINGS'
#   $records = Find-SapArtifacts -ScopeKey $scope       # newest-first, supersedes honored
#
# Storage (under {artifact_dir}, default {work_dir}\artifacts):
#   {artifact_dir}\index.jsonl                       append-only manifest (UTF-8, no BOM)
#   {artifact_dir}\<scope>\<skill>\<run_id>\<files>  per-run output folders
#
# artifact_dir resolution: $env:SAPDEV_ARTIFACT_DIR  >  userConfig.artifact_dir
#   >  {work_dir}\artifacts  (work_dir via Get-SapWorkDir, env-aware per Rule 7).
# The env var is the test / override hook.
#
# run_id reuses sap_log_lib's $env:SAPDEV_RUN_ID so a skill's log records and
# its artifacts share one id.
# =============================================================================

$script:_ArtifactRoot = $null

function Reset-SapArtifactRoot { $script:_ArtifactRoot = $null }   # mainly for tests

function Get-SapArtifactRoot {
    if ($script:_ArtifactRoot) { return $script:_ArtifactRoot }

    # 1) explicit env override (tests + callers that already resolved it)
    $artDir = "$env:SAPDEV_ARTIFACT_DIR"

    if ([string]::IsNullOrWhiteSpace($artDir)) {
        $workDir = ''
        try {
            $settingsLib = Join-Path $PSScriptRoot 'sap_settings_lib.ps1'
            $connLib     = Join-Path $PSScriptRoot 'sap_connection_lib.ps1'
            if (Test-Path $settingsLib) { . $settingsLib }
            if (Test-Path $connLib)     { . $connLib }
            # Prefer the env-aware resolver (Get-SapWorkDir honours SAPDEV_AI_WORK_DIR).
            if (Get-Command Get-SapWorkDir -ErrorAction SilentlyContinue) {
                $workDir = Get-SapWorkDir
            } elseif (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue) {
                $workDir = Get-SapSettingValue 'work_dir' ''
            }
            if (Get-Command Get-SapSettingValue -ErrorAction SilentlyContinue) {
                $artDir = Get-SapSettingValue 'artifact_dir' ''
            }
        } catch { }
        if ([string]::IsNullOrWhiteSpace($workDir)) { $workDir = 'C:\sap_dev_work' }
        if ([string]::IsNullOrWhiteSpace($artDir))  { $artDir = Join-Path $workDir 'artifacts' }
    }

    if (-not (Test-Path -LiteralPath $artDir)) {
        try { New-Item -ItemType Directory -Force -Path $artDir | Out-Null } catch { }
    }
    $script:_ArtifactRoot = $artDir
    return $artDir
}

# Short, unique-enough artifact id (matches sap_log_lib's 8-hex run-id style).
function New-SapArtifactId {
    return ('A-' + (-join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })))
}

function _Slug-SapArtifact {
    param([string] $Text)
    return (($Text -replace '[^A-Za-z0-9_]', '_').ToUpper())
}

# Root-relative, forward-slashed path (Path.GetRelativePath is unavailable on
# .NET Framework 4.x / Windows PowerShell 5.1, so do it by hand).
function ConvertTo-SapArtifactRelPath {
    param([string] $Path, [string] $Root)
    try {
        $full     = [System.IO.Path]::GetFullPath($Path)
        $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Substring($rootFull.Length).Replace('\', '/')
        }
        return $full.Replace('\', '/')
    } catch {
        return ($Path -replace '\\', '/')
    }
}

# Concurrency-safe append (multiple skills may register at once). Retry on the
# transient sharing IOException, then fall back to Add-Content.
function _Append-SapArtifactLine {
    param([string] $Path, [string] $Line)
    $enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8, no BOM
    for ($try = 0; $try -lt 10; $try++) {
        try {
            [System.IO.File]::AppendAllText($Path, $Line + "`r`n", $enc)
            return $true
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds (20 + ($try * 10))
        } catch {
            break
        }
    }
    try { Add-Content -LiteralPath $Path -Value $Line -Encoding UTF8 -ErrorAction Stop; return $true } catch { return $false }
}

# ---------------------------------------------------------------------------
# New-SapScopeKey — canonical scope slug. Pass a resolver record (-Resolved) or
# explicit -Kind/-Name/-Object. TR_<trkorr>, PKG_<pkg>, else <OBJECT>_<NAME>.
# ---------------------------------------------------------------------------
function New-SapScopeKey {
    param(
        $Resolved = $null,
        [string] $Kind = '',
        [string] $Name = '',
        [string] $Object = ''
    )
    if ($Resolved) {
        $Kind   = "$($Resolved.kind)"
        $Name   = "$($Resolved.obj_name)"
        $Object = "$($Resolved.object)"
    }
    $n = _Slug-SapArtifact $Name
    switch ($Kind.ToUpper()) {
        'TR'      { return "TR_$n" }
        'PACKAGE' { return "PKG_$n" }
        default {
            $o = if ($Object) { _Slug-SapArtifact $Object } else { 'OBJ' }
            return "${o}_$n"
        }
    }
}

# ---------------------------------------------------------------------------
# Get-SapArtifactDir — the canonical output folder for one (scope, skill, run),
# created on demand. Returns its absolute path.
# ---------------------------------------------------------------------------
function Get-SapArtifactDir {
    param(
        [Parameter(Mandatory)] [string] $ScopeKey,
        [Parameter(Mandatory)] [string] $Skill,
        [string] $RunId = ''
    )
    if (-not $RunId) {
        $RunId = if ($env:SAPDEV_RUN_ID) { "$env:SAPDEV_RUN_ID" } else { New-SapArtifactId }
    }
    $root      = Get-SapArtifactRoot
    $skillSafe = ($Skill   -replace '[^A-Za-z0-9_\-]', '_')
    $runSafe   = ($RunId   -replace '[^A-Za-z0-9_\-]', '_')
    $dir = Join-Path (Join-Path (Join-Path $root (_Slug-SapArtifact $ScopeKey)) $skillSafe) $runSafe
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { }
    }
    return $dir
}

# ---------------------------------------------------------------------------
# Register-SapArtifact — append one manifest record. Returns the artifact id
# (pass it to a later -Supersedes to mark this one replaced).
# ---------------------------------------------------------------------------
function Register-SapArtifact {
    param(
        [Parameter(Mandatory)] [string] $Skill,
        [Parameter(Mandatory)] [string] $ScopeKey,
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [string] $Format,
        [Parameter(Mandatory)] [string] $Path,
        $Object = $null,                 # resolver record, or $null
        [string] $ScopeKind = '',        # override scope.kind when no -Object
        [string] $Title = '',
        [string] $Coverage = '',         # CHECKED_CLEAN | CHECKED_FINDINGS | COULD_NOT_CHECK | NOT_APPLICABLE
        [string] $Verdict = '',          # GO | NO_GO | GO_WITH_WARNINGS | ''
        [string] $Ticket = '',
        $Rows = $null,
        [string] $RunId = '',
        [string] $Supersedes = '',
        [string] $System = '',
        [string] $Client = ''
    )
    $root = Get-SapArtifactRoot
    $id   = New-SapArtifactId
    if (-not $RunId) { $RunId = if ($env:SAPDEV_RUN_ID) { "$env:SAPDEV_RUN_ID" } else { '' } }
    $parentRun = if ($env:SAPDEV_PARENT_RUN_ID) { "$env:SAPDEV_PARENT_RUN_ID" } else { '' }

    $relPath = ConvertTo-SapArtifactRelPath -Path $Path -Root $root
    $bytes = $null
    try { if (Test-Path -LiteralPath $Path) { $bytes = (Get-Item -LiteralPath $Path).Length } } catch { }

    $scopeKindVal = if ($ScopeKind) { $ScopeKind } elseif ($Object) { "$($Object.kind)" } else { '' }
    $objRec = if ($Object) {
        [ordered]@{ pgmid = "$($Object.pgmid)"; object = "$($Object.object)"; obj_name = "$($Object.obj_name)" }
    } else {
        [ordered]@{ pgmid = ''; object = ''; obj_name = '' }
    }
    $sys = if ($System) { $System } elseif ($Object) { "$($Object.system)" } else { '' }
    $cli = if ($Client) { $Client } elseif ($Object) { "$($Object.client)" } else { '' }

    $rec = [ordered]@{
        schema        = 'sapdev.artifact/1'
        id            = $id
        ts            = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        run_id        = $RunId
        parent_run_id = $parentRun
        skill         = $Skill
        scope         = [ordered]@{
            kind   = $scopeKindVal
            key    = $ScopeKey
            system = $sys
            client = $cli
            object = $objRec
        }
        artifact      = [ordered]@{
            kind   = $Kind
            format = $Format
            path   = $relPath
            title  = $Title
            rows   = $Rows
            bytes  = $bytes
        }
        coverage      = $Coverage
        verdict       = $Verdict
        ticket        = $Ticket
        supersedes    = if ($Supersedes) { $Supersedes } else { $null }
    }

    $line = $rec | ConvertTo-Json -Compress -Depth 12
    [void](_Append-SapArtifactLine -Path (Join-Path $root 'index.jsonl') -Line $line)
    return $id
}

# ---------------------------------------------------------------------------
# Find-SapArtifacts — query the manifest. Newest-first. Records that another
# record explicitly supersedes are excluded unless -IncludeSuperseded.
# Bad / non-JSON lines are skipped silently.
# ---------------------------------------------------------------------------
function Find-SapArtifacts {
    param(
        [string] $ScopeKey = '',
        [string] $Since = '',
        [string] $Ticket = '',
        [string] $Kind = '',
        [string] $Skill = '',
        [switch] $IncludeSuperseded
    )
    $root      = Get-SapArtifactRoot
    $indexPath = Join-Path $root 'index.jsonl'
    if (-not (Test-Path -LiteralPath $indexPath)) { return @() }

    $sinceDt = $null
    if ($Since) {
        try { $sinceDt = [datetime]::Parse($Since, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $sinceDt = $null }
    }

    # Read once, tagging each record with its append sequence (line order). In
    # an append-only log, append order is the authoritative recency order — it
    # is the tie-breaker when wall-clock ts values collide (Windows DateTime.Now
    # resolves to ~15 ms, so artifacts registered in quick succession share a
    # millisecond). seq/ts are kept on a wrapper so they never leak into output.
    $entries = New-Object System.Collections.Generic.List[object]
    $seq = 0
    foreach ($line in [System.IO.File]::ReadAllLines($indexPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        $seq++
        $dt = [datetime]::MinValue
        try { $dt = [datetime]::Parse("$($obj.ts)", [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
        $entries.Add([pscustomobject]@{ rec = $obj; seq = $seq; ts = $dt })
    }

    # Ids that some record explicitly marks superseded.
    $superseded = @{}
    foreach ($e in $entries) {
        $s = $null
        try { $s = $e.rec.supersedes } catch { }
        if ($s) { $superseded["$s"] = $true }
    }

    $matched = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        $r   = $e.rec
        $rid = "$($r.id)"
        if (-not $IncludeSuperseded -and $rid -and $superseded.ContainsKey($rid)) { continue }
        if ($ScopeKey -and "$($r.scope.key)"     -ne $ScopeKey) { continue }
        if ($Skill    -and "$($r.skill)"         -ne $Skill)    { continue }
        if ($Ticket   -and "$($r.ticket)"        -ne $Ticket)   { continue }
        if ($Kind     -and "$($r.artifact.kind)" -ne $Kind)     { continue }
        if ($sinceDt -and $e.ts -lt $sinceDt) { continue }
        $matched.Add($e)
    }

    return @($matched |
        Sort-Object -Property @{ Expression = { $_.ts };  Descending = $true },
                              @{ Expression = { $_.seq }; Descending = $true } |
        ForEach-Object { $_.rec })
}
