# =============================================================================
# sap_git_serialize.ps1  -  RFC serializer for /sap-git (READ-ONLY vs SAP)
#
# Resolves a PACKAGE / TR / object-list scope and serializes each object to an
# abapGit-ISH tree under <repo>\src\<pkg>\ + a manifest.tsv. Programs / FMs are
# FULL (RPY reads via sap_rfc_read_source.ps1); DDIC / MSAG / class are PARTIAL
# deterministic metadata JSON (direct DD0xL / SEO* reads, volatile fields stripped
# + rows sorted by key so snapshot-twice yields an empty diff). Full DDIC via
# Z_GENERIC_RFC_WRAPPER_TBL (DDIF_*_GET) is v1.5 -- v1 marks those PARTIAL, never
# a silent full claim. Metadata is OUR JSON, NOT abapGit-import-compatible.
#
# Emits one  GIT: <TYPE> <NAME> <FULL|PARTIAL|COULD_NOT_CHECK|SKIPPED_UNSUPPORTED>
# line per object + writes manifest.tsv. Connects via the pinned profile.
# Exit: 0 ran, 1 serialize failed, 2 connect/scope error.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Scope = '',            # "PACKAGE <p>" | "TR <trkorr>"
    [string] $ObjectsFile = '',      # newline/CSV list of "TYPE NAME" or names
    [switch] $Subpackages,
    [string] $RepoDir = '',
    [int]    $MaxObjects = 2000,
    [string] $ManifestFile = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1','sap_rfc_read_source.ps1') {
    $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function Sq { param([string]$s) return (("$s") -replace "'", "''") }
$VOLATILE = @('AS4DATE','AS4TIME','AS4USER','AS4LOCAL','UDAT','UTIME','CDAT','CTIME','CHANGED_ON','CREATED_ON','LASTUSER')

function Write-DetJson {
    param([string]$Path, $Obj)
    $json = $Obj | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
function Strip-Volatile {
    param($Row)   # hashtable/pscustomobject -> ordered hashtable minus volatile keys, keys sorted
    $o = [ordered]@{}
    if ($null -eq $Row) { return $o }
    $names = @($Row.PSObject.Properties.Name | Sort-Object)
    foreach ($n in $names) { if ($VOLATILE -notcontains $n.ToUpper()) { $o[$n] = "$($Row.$n)" } }
    return $o
}
function HasRows { param($x) return ($null -ne $x -and @($x).Count -gt 0 -and $null -ne @($x)[0]) }

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $RepoDir) { Write-Host "STATUS: INPUT_ERROR reason=repodir"; exit 2 }
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_GIT"
    if (-not $g_dest) { Write-Host "STATUS: RFC_LOGON_FAILED"; exit 2 }

    # ---- resolve scope -> object list [{object,obj_name,package}] ----
    $objects = @()
    if ($ObjectsFile -and (Test-Path $ObjectsFile)) {
        foreach ($ln in [System.IO.File]::ReadAllLines($ObjectsFile)) {
            $t = $ln.Trim(); if ($t -eq '' -or $t.StartsWith('#')) { continue }
            $parts = $t -split '[,\s]+'
            $r = Resolve-SapObject -Destination $g_dest -Token ($t) | Where-Object { $_ -and $_.obj_name } | Select-Object -First 1
            if ($r) { $objects += [pscustomobject]@{ object="$($r.object)"; obj_name="$($r.obj_name)"; package="$($r.package)" } }
        }
    } elseif ($Scope -match '^\s*PACKAGE\s+(\S+)') {
        $pkgs = @($matches[1].ToUpper())
        if ($Subpackages) {
            $seen = @{}; $queue = New-Object System.Collections.Queue; $queue.Enqueue($pkgs[0]); $seen[$pkgs[0]]=$true; $pkgs=@()
            while ($queue.Count -gt 0) {
                $cur = $queue.Dequeue(); $pkgs += $cur
                try { $kids = Read-SapTableRows -Destination $g_dest -Table 'TDEVC' -Where "PARENTCL EQ '$(Sq $cur)'" -Fields @('DEVCLASS') -RowCount 500 } catch { $kids=@() }
                foreach ($k in $kids) { $kn="$($k.DEVCLASS)"; if ($kn -and -not $seen.ContainsKey($kn)) { $seen[$kn]=$true; $queue.Enqueue($kn) } }
            }
        }
        foreach ($pkg in $pkgs) {
            $td = Read-SapTableRows -Destination $g_dest -Table 'TADIR' -Where "DEVCLASS EQ '$(Sq $pkg)' AND PGMID EQ 'R3TR'" -Fields @('OBJECT','OBJ_NAME') -RowCount 5000
            foreach ($o in $td) { if ("$($o.OBJ_NAME)") { $objects += [pscustomobject]@{ object="$($o.OBJECT)"; obj_name="$($o.OBJ_NAME)"; package=$pkg } } }
        }
    } elseif ($Scope -match '^\s*TR\s+(\S+)') {
        $tr = $matches[1].ToUpper()
        $e = Read-SapTableRows -Destination $g_dest -Table 'E071' -Where "TRKORR EQ '$(Sq $tr)' AND PGMID EQ 'R3TR'" -Fields @('OBJECT','OBJ_NAME') -RowCount 5000
        foreach ($o in $e) { if ("$($o.OBJ_NAME)") { $objects += [pscustomobject]@{ object="$($o.OBJECT)"; obj_name="$($o.OBJ_NAME)"; package='' } } }
    }
    $objects = @($objects | Where-Object { $_.object -ne 'DEVC' } | Sort-Object object,obj_name -Unique)
    if ($objects.Count -eq 0) { Write-Host "STATUS: SNAPSHOT_EMPTY_SCOPE"; try { Disconnect-SapRfc } catch {}; exit 1 }
    $partial = $false
    if ($objects.Count -gt $MaxObjects) { $objects = @($objects | Select-Object -First $MaxObjects); $partial = $true }

    $srcRoot = Join-Path $RepoDir 'src'
    $manifest = New-Object System.Collections.Generic.List[string]
    $manifest.Add("object`tobj_name`tpackage`tfidelity`tfiles")
    $counts = @{ FULL=0; PARTIAL=0; COULD_NOT_CHECK=0; SKIPPED_UNSUPPORTED=0 }

    function ObjDir($pkg) { $d = Join-Path $srcRoot ("$pkg".ToLower()); if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }; return $d }
    function Emit($obj,$name,$fid,$files) {
        Write-Host ("GIT: $obj $name $fid")
        $manifest.Add("$obj`t$name`t$fid`t$fid`t$files")   # (package folded into path)
        if ($counts.ContainsKey($fid)) { $counts[$fid]++ }
    }

    foreach ($o in $objects) {
        $ot = "$($o.object)".ToUpper(); $on = "$($o.obj_name)"; $pkg = if ($o.package) { $o.package } else { 'scope' }
        $dir = ObjDir $pkg; $base = Join-Path $dir ($on.ToLower() -replace '[^a-z0-9_]','_')
        try {
            switch ($ot) {
                'PROG' {
                    $tmp = Join-Path $dir '_tmp'; if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Force -Path $tmp | Out-Null }
                    $res = Read-SapAbapSource -Name $on -Type 'program' -OutDir $tmp -Dest $g_dest
                    if ($res.Status -eq 'OK' -and $res.SourceFile -and (Test-Path $res.SourceFile)) {
                        Copy-Item $res.SourceFile "$base.prog.abap" -Force
                        # deterministic metadata (TRDIR minus volatile)
                        $tr = Read-SapTableRows -Destination $g_dest -Table 'TRDIR' -Where "NAME EQ '$(Sq $on)'" -Fields @('NAME','SUBC','RLOAD','APPL','RSTAT','SECU','CNAM') -RowCount 1
                        if (@($tr).Count) { Write-DetJson "$base.prog.json" (Strip-Volatile $tr[0]) }
                        Emit $ot $on 'FULL' "$($on.ToLower()).prog.abap"
                    } else { Emit $ot $on 'COULD_NOT_CHECK' '' }
                    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
                }
                'FUGR' {
                    $fgdir = "$base.fugr"; if (-not (Test-Path $fgdir)) { New-Item -ItemType Directory -Force -Path $fgdir | Out-Null }
                    $fms = Read-SapTableRows -Destination $g_dest -Table 'TFDIR' -Where "PNAME EQ 'SAPL$(Sq $on.ToUpper())'" -Fields @('FUNCNAME') -RowCount 500
                    $n=0
                    foreach ($fm in $fms) {
                        $fn = "$($fm.FUNCNAME)"; if (-not $fn) { continue }
                        $res = Read-SapAbapSource -Name $fn -Type 'fm' -OutDir $fgdir -Dest $g_dest
                        if ($res.Status -eq 'OK' -and $res.SourceFile -and (Test-Path $res.SourceFile)) {
                            Copy-Item $res.SourceFile (Join-Path $fgdir ($fn.ToLower() + '.func.abap')) -Force; $n++
                        }
                    }
                    if ($n -gt 0) { Emit $ot $on 'FULL' "$($on.ToLower()).fugr/ ($n FMs)" } else { Emit $ot $on 'COULD_NOT_CHECK' '' }
                }
                'MSAG' {
                    $t100 = Read-SapTableRows -Destination $g_dest -Table 'T100' -Where "ARBGB EQ '$(Sq $on)' AND SPRSL EQ 'E'" -Fields @('MSGNR','TEXT') -RowCount 2000
                    $rows = @($t100 | Sort-Object { [int]("0"+"$($_.MSGNR)") } | ForEach-Object { [ordered]@{ msgnr="$($_.MSGNR)"; text="$($_.TEXT)" } })
                    Write-DetJson "$base.msag.json" ([ordered]@{ class=$on; messages=$rows })
                    Emit $ot $on 'FULL' "$($on.ToLower()).msag.json"
                }
                'TABL' {
                    $fl = @()
                    try {
                        $fn = $g_dest.Repository.CreateFunction('DDIF_FIELDINFO_GET'); $fn.SetValue('TABNAME',$on.ToUpper()); $fn.SetValue('LANGU','E'); $fn.Invoke($g_dest)
                        $t = $fn.GetTable('DFIES_TAB')
                        for ($i=0;$i -lt $t.RowCount;$i++){ $t.CurrentIndex=$i; $fl += [ordered]@{ pos="$($t.GetString('POSITION'))".Trim(); field="$($t.GetString('FIELDNAME'))".Trim(); key="$($t.GetString('KEYFLAG'))".Trim(); rollname="$($t.GetString('ROLLNAME'))".Trim(); datatype="$($t.GetString('DATATYPE'))".Trim(); leng="$($t.GetString('LENG'))".Trim() } }
                    } catch {}
                    if ($fl.Count) { $fl = @($fl | Sort-Object { [int]("0"+$_.pos) }); Write-DetJson "$base.tabl.json" ([ordered]@{ table=$on; fields=$fl }); Emit $ot $on 'PARTIAL' "$($on.ToLower()).tabl.json (fieldlist; full DDIF via wrapper=v1.5)" }
                    else { Emit $ot $on 'COULD_NOT_CHECK' '' }
                }
                'DOMA' {
                    $h = Read-SapTableRows -Destination $g_dest -Table 'DD01L' -Where "DOMNAME EQ '$(Sq $on)' AND AS4LOCAL EQ 'A'" -Fields @('DOMNAME','DATATYPE','LENG','DECIMALS','VALEXI','ENTITYTAB') -RowCount 1
                    $fv = Read-SapTableRows -Destination $g_dest -Table 'DD07L' -Where "DOMNAME EQ '$(Sq $on)' AND AS4LOCAL EQ 'A'" -Fields @('VALPOS','DOMVALUE_L','DOMVALUE_H') -RowCount 500
                    $vals = @($fv | Sort-Object { [int]("0"+"$($_.VALPOS)") } | ForEach-Object { [ordered]@{ pos="$($_.VALPOS)"; low="$($_.DOMVALUE_L)"; high="$($_.DOMVALUE_H)" } })
                    if (HasRows $h) { Write-DetJson "$base.doma.json" ([ordered]@{ domain=$on; header=(Strip-Volatile $h[0]); fixed_values=$vals }); Emit $ot $on 'PARTIAL' "$($on.ToLower()).doma.json" }
                    else { Emit $ot $on 'COULD_NOT_CHECK' '' }
                }
                'DTEL' {
                    $h = Read-SapTableRows -Destination $g_dest -Table 'DD04L' -Where "ROLLNAME EQ '$(Sq $on)' AND AS4LOCAL EQ 'A'" -Fields @('ROLLNAME','DOMNAME','DATATYPE','LENG','ROUTPUTLEN') -RowCount 1
                    if (HasRows $h) { Write-DetJson "$base.dtel.json" ([ordered]@{ data_element=$on; header=(Strip-Volatile $h[0]) }); Emit $ot $on 'PARTIAL' "$($on.ToLower()).dtel.json" }
                    else { Emit $ot $on 'COULD_NOT_CHECK' '' }
                }
                'TTYP' {
                    $h = Read-SapTableRows -Destination $g_dest -Table 'DD40L' -Where "TYPENAME EQ '$(Sq $on)' AND AS4LOCAL EQ 'A'" -Fields @('TYPENAME','ROWTYPE','ROWKIND','ACCESSMODE','KEYKIND') -RowCount 1
                    if (HasRows $h) { Write-DetJson "$base.ttyp.json" ([ordered]@{ table_type=$on; header=(Strip-Volatile $h[0]) }); Emit $ot $on 'PARTIAL' "$($on.ToLower()).ttyp.json" }
                    else { Emit $ot $on 'COULD_NOT_CHECK' '' }
                }
                'VIEW' {
                    $h = Read-SapTableRows -Destination $g_dest -Table 'DD25L' -Where "VIEWNAME EQ '$(Sq $on)' AND AS4LOCAL EQ 'A'" -Fields @('VIEWNAME','AGGTYPE','ROOTTAB') -RowCount 1
                    if (HasRows $h) { Write-DetJson "$base.view.json" ([ordered]@{ view=$on; header=(Strip-Volatile $h[0]) }); Emit $ot $on 'PARTIAL' "$($on.ToLower()).view.json" }
                    else { Emit $ot $on 'COULD_NOT_CHECK' '' }
                }
                { $_ -in @('CLAS','INTF') } {
                    # Class source over RFC is unsupported (SE24/ADT only) and SEOCLASS
                    # RFC_READ_TABLE is unreliable on some kernels -> always emit a
                    # deterministic metadata stub from the reliable identity we DO have.
                    $h = $null
                    try { $h = Read-SapTableRows -Destination $g_dest -Table 'SEOCLASS' -Where "CLSNAME EQ '$(Sq $on)'" -Fields @('CLSNAME','CLSTYPE') -RowCount 1 } catch {}
                    $methods = $null
                    try { $methods = Read-SapTableRows -Destination $g_dest -Table 'SEOCOMPO' -Where "CLSNAME EQ '$(Sq $on)'" -Fields @('CMPNAME','CMPTYPE') -RowCount 2000 } catch {}
                    $mlist = @()
                    if (HasRows $methods) { $mlist = @($methods | Sort-Object { "$($_.CMPNAME)" } | ForEach-Object { [ordered]@{ name="$($_.CMPNAME)"; type="$($_.CMPTYPE)" } }) }
                    $clstype = if (HasRows $h) { "$($h[0].CLSTYPE)" } else { '' }
                    Write-DetJson "$base.clas.stub.json" ([ordered]@{ class=$on; object_type=$ot; clstype=$clstype; package="$pkg"; components=$mlist; note='PARTIAL: class/interface source over RFC is not supported (use SE24 GUI download or ADT); this is a metadata stub' })
                    Emit $ot $on 'PARTIAL' "$($on.ToLower()).clas.stub.json (metadata stub - source needs SE24/ADT)"
                }
                default { Emit $ot $on 'SKIPPED_UNSUPPORTED' '' }
            }
        } catch {
            Write-Host ("GIT: $ot $on COULD_NOT_CHECK err=" + (($_.Exception.Message) -replace "[`t`r`n]",' ').Substring(0,[Math]::Min(60,($_.Exception.Message).Length)))
            $manifest.Add("$ot`t$on`tCOULD_NOT_CHECK`tCOULD_NOT_CHECK`t"); $counts['COULD_NOT_CHECK']++
        }
    }

    if (-not $ManifestFile) { $ManifestFile = Join-Path $RepoDir '.sapgit.manifest.tsv' }
    [System.IO.File]::WriteAllText($ManifestFile, ($manifest -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "MANIFEST: $ManifestFile"
    Write-Host ("SERIALIZE: total=$($objects.Count) full=$($counts.FULL) partial=$($counts.PARTIAL) cnc=$($counts.COULD_NOT_CHECK) skipped=$($counts.SKIPPED_UNSUPPORTED) partial_scope=" + ($(if ($partial){'1'}else{'0'})))
    Write-Host "STATUS: OK"
    try { Disconnect-SapRfc } catch {}
    exit 0
}
