# =============================================================================
# sap_exit_read.ps1  -  analyze reader for /sap-exit-modernize (READ-ONLY)
#
# Resolves a classic CMOD function-exit's identity and reads its source over RFC,
# so the skill can translate it to a BAdI. RFC-only (NCo 3.1, 32-bit PS); no writes.
#
# Resolve chain (verified S4D 2026-07-11):
#   input EXIT_FM (or ZX-include) -> MODSAP (TYP='E', MEMBER=fm) -> enhancement NAME
#   -> MODACT (MEMBER=enh) -> CMOD project(s) -> MODATTR (project STATUS: A=active)
#   -> ENLFDIR (fm -> function group X*). Exit body = the ZX* customer INCLUDE.
#
# Active check: an exit is effectively active when a containing CMOD project is
# activated (MODATTR.STATUS='A'). This is the reliable RFC signal;
# MODX_FUNCTION_ACTIVE_CHECK (not remote-enabled) via the wrapper is a v1.5
# precise-check (its exception-based result collapses through the wrapper's single
# OTHERS handler) -> reported COULD_NOT_CHECK when the precise check is unavailable.
#
# Emits: EXIT: fm=.. enh=.. fg=.. projects=.. active=<YES|NO|COULD_NOT_CHECK> ...
#        SRC: kind=fm|zxinclude name=.. status=.. lines=.. file=..
#        STATUS: OK | EXIT_RESOLVE_FAILED | RFC_ERROR ; exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Exit = '',                # EXIT_* FM name, or a ZX* include
    [string] $OutDir = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Exit=$Exit }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1','sap_rfc_read_source.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }
if (-not $OutDir) { $OutDir = (Get-Location).Path }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$srcDir = Join-Path $OutDir 'exit_source'; if (-not (Test-Path $srcDir)) { New-Item -ItemType Directory -Force -Path $srcDir | Out-Null }

function Sq { param([string]$s) return (("$s") -replace "'", "''") }

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Exit) { Write-Host "STATUS: EXIT_RESOLVE_FAILED reason=no_input"; exit 1 }
    $inp = $Exit.ToUpper()
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -DestName "SAPDEV_EXIT"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR detail=connect"; exit 2 }
    try {
        # ---- resolve exit FM (accept EXIT_ FM directly, or a ZX include -> find its FM) ----
        $fm = ''; $enh = ''
        if ($inp -like 'EXIT_*') {
            $fm = $inp
            $ms = @(); try { $ms = Read-SapTableRows -Destination $g_dest -Table 'MODSAP' -Where "MEMBER EQ '$(Sq $fm)' AND TYP EQ 'E'" -Fields @('NAME','MEMBER') -RowCount 3 } catch {}
            if (@($ms).Count) { $enh = "$($ms[0].NAME)" }
        } else {
            # ZX include -> the EXIT FM whose body includes it: scan MODSAP TYP=E, resolve via ENLFDIR/source is costly;
            # accept only when the include maps 1:1 by naming (ZX<fg-suffix>) - else fail loud.
            Write-Host "STATUS: EXIT_RESOLVE_FAILED reason=zx_include_input_needs_exit_fm (pass the EXIT_* FM name in v1)"; try { Disconnect-SapRfc } catch {}; exit 1
        }
        if (-not $enh) { Write-Host "STATUS: EXIT_RESOLVE_FAILED reason=not_a_function_exit fm=$fm"; try { Disconnect-SapRfc } catch {}; exit 1 }

        # ---- function group (ENLFDIR) ----
        $fg = ''; try { $en = Read-SapTableRows -Destination $g_dest -Table 'ENLFDIR' -Where "FUNCNAME EQ '$(Sq $fm)'" -Fields @('FUNCNAME','AREA') -RowCount 1; if (@($en).Count) { $fg = "$($en[0].AREA)" } } catch {}

        # ---- projects (MODACT) + active status (MODATTR) ----
        $projects = @(); try { $ma = Read-SapTableRows -Destination $g_dest -Table 'MODACT' -Where "MEMBER EQ '$(Sq $enh)'" -Fields @('NAME','MEMBER') -RowCount 20; $projects = @($ma | ForEach-Object { "$($_.NAME)" } | Where-Object { $_ } | Select-Object -Unique) } catch {}
        $active = 'NO'; $activeProj = ''
        if ($projects.Count) {
            foreach ($p in $projects) {
                $at = @(); try { $at = Read-SapTableRows -Destination $g_dest -Table 'MODATTR' -Where "NAME EQ '$(Sq $p)'" -Fields @('NAME','STATUS') -RowCount 1 } catch {}
                if (@($at).Count -and "$($at[0].STATUS)" -eq 'A') { $active='YES'; $activeProj=$p; break }
            }
        } else { $active = 'NO' }   # in no CMOD project => not implemented

        # ---- source: EXIT FM + its ZX include ----
        $fmSrcFile=''; $fmLines=0; $zxInc=''; $zxStatus='NONE'; $zxLines=0
        $res = Read-SapAbapSource -Name $fm -Type 'fm' -OutDir $srcDir -Dest $g_dest
        if ($res.Status -eq 'OK' -and $res.SourceFile -and (Test-Path $res.SourceFile)) {
            $fmSrcFile = Join-Path $srcDir ($fm.ToLower()+'.abap'); Copy-Item $res.SourceFile $fmSrcFile -Force; $fmLines=$res.Lines
            # find the INCLUDE ZX... line
            foreach ($ln in [System.IO.File]::ReadAllLines($fmSrcFile)) {
                if ($ln -match '(?i)^\s*INCLUDE\s+(ZX\w+)') { $zxInc = $matches[1].ToUpper(); break }
            }
            Write-Host "SRC: kind=fm name=$fm status=OK lines=$fmLines file=$fmSrcFile"
        } else { Write-Host "SRC: kind=fm name=$fm status=COULD_NOT_CHECK lines=0" }
        if ($zxInc) {
            $zr = Read-SapAbapSource -Name $zxInc -Type 'include' -OutDir $srcDir -Dest $g_dest
            if ($zr.Status -eq 'OK' -and $zr.SourceFile -and (Test-Path $zr.SourceFile)) {
                $zf = Join-Path $srcDir ($zxInc.ToLower()+'.abap'); Copy-Item $zr.SourceFile $zf -Force; $zxStatus='OK'; $zxLines=$zr.Lines
                Write-Host "SRC: kind=zxinclude name=$zxInc status=OK lines=$zxLines file=$zf"
            } else { $zxStatus='EMPTY_OR_MISSING'; Write-Host "SRC: kind=zxinclude name=$zxInc status=EMPTY_OR_MISSING lines=0 (no customer implementation)" }
        }

        Write-Host ("EXIT: fm=$fm enh=$enh fg=$fg projects=" + (($projects | Select-Object -First 8) -join ',') + " active=$active active_project=$activeProj zxinclude=$zxInc zxstatus=$zxStatus fm_lines=$fmLines")
        Write-Host "STATUS: OK"
        try { Disconnect-SapRfc } catch {}
        exit 0
    } catch {
        Write-Host ("STATUS: RFC_ERROR detail=" + (($_.Exception.Message) -replace "[`t`r`n]",' '))
        try { Disconnect-SapRfc } catch {}
        exit 2
    }
}
