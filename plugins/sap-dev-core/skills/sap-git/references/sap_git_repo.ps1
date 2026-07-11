# =============================================================================
# sap_git_repo.ps1  -  Local git plumbing for /sap-git (NO SAP, NO RFC)
#
# Wraps git.exe for the snapshot/diff/log/status flow. One repo per (SID,CLIENT)
# under {work_dir}\git (or -RepoDir). Never adds a remote, never pushes.
#
# Actions:
#   ensure  -RepoDir <dir> [-Sid -Client -SapUser]   git preflight + init + identity;
#            emits REPO: <dir>  HEAD: <sha|none>  DIRTY: <0|1>
#   commit  -RepoDir <dir> -MessageFile <path>       git add -A + commit; COMMIT: <sha>
#   diff    -RepoDir <dir> [-Stat] [-PathSpec <rel>] [-SaveTo <file>]
#            stage working tree, diff --cached HEAD, THEN reset --hard HEAD (safe: the
#            caller guaranteed a clean start at 'ensure'); emits DIFF_LINES: <n>
#   log     -RepoDir <dir> [-Max N] [-PathSpec <rel>]  git log --oneline
#   status  -RepoDir <dir>                            HEAD + dirty
#   reset   -RepoDir <dir>                            git reset --hard HEAD (explicit)
#
# Exit: 0 ok, 1 git op failed, 2 git missing / bad input.
# Error tokens: GIT_NOT_INSTALLED, GIT_REPO_DIRTY, GIT_COMMIT_FAILED.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Action = 'status',
    [string] $RepoDir = '',
    [string] $Sid = '', [string] $Client = '', [string] $SapUser = '',
    [string] $MessageFile = '',
    [string] $PathSpec = '',
    [string] $SaveTo = '',
    [int]    $Max = 20,
    [switch] $Stat
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

function Git-Run {
    param([string[]] $GitArgs)
    $out = & git -C $RepoDir @GitArgs 2>&1
    return @{ code = $LASTEXITCODE; out = ($out -join "`n") }
}
function Test-Git {
    try { $null = & git --version 2>&1; return ($LASTEXITCODE -eq 0) } catch { return $false }
}
function Repo-Head {
    $r = Git-Run @('rev-parse','--short','HEAD'); if ($r.code -eq 0) { return $r.out.Trim() } else { return 'none' }
}
function Repo-Dirty {
    $r = Git-Run @('status','--porcelain'); return ([bool]($r.out.Trim() -ne ''))
}

if (-not (Test-Git)) { Write-Host "STATUS: GIT_NOT_INSTALLED"; Write-Host "FIX: install Git (winget install Git.Git)"; exit 2 }
if (-not $RepoDir) { Write-Host "STATUS: INPUT_ERROR reason=repodir_required"; exit 2 }

switch ($Action.ToLower()) {
    'ensure' {
        if (-not (Test-Path $RepoDir)) { New-Item -ItemType Directory -Force -Path $RepoDir | Out-Null }
        $isRepo = (Test-Path (Join-Path $RepoDir '.git'))
        if (-not $isRepo) {
            $r = Git-Run @('init','-q'); if ($r.code -ne 0) { Write-Host "STATUS: GIT_INIT_FAILED detail=$($r.out)"; exit 1 }
            $email = "$SapUser@$Sid.$Client".ToLower(); if ($email -eq '@.') { $email = 'sap-git@localhost' }
            Git-Run @('config','user.name',"sap-git $SapUser") | Out-Null
            Git-Run @('config','user.email',$email) | Out-Null
            # keep CRLF out of the equation so snapshots are byte-stable across checkouts
            Git-Run @('config','core.autocrlf','false') | Out-Null
        }
        $marker = Join-Path $RepoDir '.sapgit.json'
        if (-not (Test-Path $marker)) {
            $m = [ordered]@{ schema='sapdev.sapgit/1'; sid=$Sid; client=$Client; layout_version=1; abapgit_import_compatible=$false; note='metadata JSON is OUR format, NOT abapGit-import-compatible; source can contain hardcoded credentials - do not push to an untrusted remote' }
            [System.IO.File]::WriteAllText($marker, ($m | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-Host "REPO: $RepoDir"
        Write-Host ("HEAD: " + (Repo-Head))
        Write-Host ("DIRTY: " + ($(if (Repo-Dirty) {'1'} else {'0'})))
        exit 0
    }
    'commit' {
        if (-not $MessageFile -or -not (Test-Path $MessageFile)) { Write-Host "STATUS: INPUT_ERROR reason=message_file"; exit 2 }
        Git-Run @('add','-A') | Out-Null
        $st = Git-Run @('status','--porcelain')
        if ($st.out.Trim() -eq '') { Write-Host "COMMIT: none reason=no_changes"; Write-Host "STATUS: OK"; exit 0 }
        $r = Git-Run @('commit','-q','-F',$MessageFile)
        if ($r.code -ne 0) { Write-Host "STATUS: GIT_COMMIT_FAILED detail=$($r.out)"; exit 1 }
        Write-Host ("COMMIT: " + (Repo-Head)); Write-Host "STATUS: OK"; exit 0
    }
    'diff' {
        Git-Run @('add','-A') | Out-Null
        $args = @('diff','--cached','HEAD'); if ($Stat) { $args += '--stat' }
        if ($PathSpec) { $args += @('--',$PathSpec) }
        $r = Git-Run $args
        $txt = $r.out
        if ($SaveTo) { [System.IO.File]::WriteAllText($SaveTo, $txt, (New-Object System.Text.UTF8Encoding($false))); Write-Host "DIFF_FILE: $SaveTo" }
        else { Write-Host $txt }
        $lines = if ($txt.Trim() -eq '') { 0 } else { ($txt -split "`n").Count }
        # restore the last committed state (safe: ensure guaranteed a clean start)
        Git-Run @('reset','-q','--hard','HEAD') | Out-Null
        Git-Run @('clean','-fdq') | Out-Null
        Write-Host ("DIFF_LINES: " + $lines); Write-Host "STATUS: OK"; exit 0
    }
    'log' {
        $args = @('log',"--max-count=$Max",'--pretty=format:%h %ad %s','--date=short')
        if ($PathSpec) { $args += @('--',$PathSpec) }
        $r = Git-Run $args; Write-Host $r.out; Write-Host "STATUS: OK"; exit 0
    }
    'reset' {
        Git-Run @('reset','-q','--hard','HEAD') | Out-Null; Git-Run @('clean','-fdq') | Out-Null
        Write-Host "STATUS: OK"; exit 0
    }
    default {
        Write-Host "REPO: $RepoDir"; Write-Host ("HEAD: " + (Repo-Head)); Write-Host ("DIRTY: " + ($(if (Repo-Dirty) {'1'} else {'0'}))); Write-Host "STATUS: OK"; exit 0
    }
}
