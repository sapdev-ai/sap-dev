# =============================================================================
# sap_spau_rfc.ps1  -  Read-only RFC backend for /sap-spau-triage
#
# Three read-only actions (NCo 3.1, 32-bit PowerShell; no GUI, no wrapper FM):
#   worklist  - page SMODILOG, aggregate per modified object, join ADIRACCESS
#               access-key + resolve package via TADIR; apply --package/--user/
#               --since/--max filters. Emits spau_worklist_raw.tsv + WORKLIST:.
#   versions  - per object, SVRS_GET_VERSION_DIRECTORY_46 (+ optional before/after
#               source via SVRS_GET_REPS_FROM_OBJECT) -> VERSIONS: line + file pair.
#   notes     - batch CWBNTHEAD/CWBNTCUST for referenced note numbers (advisory).
#
# READ-ONLY. All SVRS_* FMs probed FMODE=R on S4D + EC2, so no Z_GENERIC_RFC_WRAPPER
# and no /sap-dev-init dependency. Connects via the pinned profile when creds omitted.
# Field layout verified live on S4D 2026-07-11: SMODILOG keys OBJ_TYPE/OBJ_NAME/
# SUB_*/INT_*/OPERATION + MOD_USER/MOD_DATE/TRKORR/UPGRADE/ACTIVE/SPAU/SPAU_CODE
# (no DEVCLASS column -> package resolved via TADIR); CWBNT* note number = NUMM.
#
# Exit: 0 = ran (incl. empty worklist), 1 = read failed mid-scan, 2 = connect/input.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Action = 'worklist',      # worklist | versions | notes
    [string] $PackageMask = '',
    [string] $UserMask = '',
    [string] $Since = '',               # YYYYMMDD
    [int]    $Max = 500,
    [string] $ObjType = '',             # versions: SVRS object type (REPS/FUNC/TABD/...)
    [string] $ObjName = '',             # versions: single object name
    [int]    $DeepMax = 0,              # versions: fetch source for this many newest pairs
    [string] $Notes = '',               # notes: comma-separated note numbers
    [string] $OutFile = '',
    [string] $OutDir = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) {
    try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' }
}
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_connection_lib.ps1','sap_object_resolver.ps1') {
    $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function Sq { param([string] $s) return (("$s") -replace "'", "''") }
function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }

# ADIRACCESS.OBJECT uses the TADIR OBJECT vocabulary; SMODILOG OBJ_TYPE is a
# version/repository type. We match ADIRACCESS on OBJ_NAME alone (unique enough
# for the access-key presence flag) to avoid a brittle type map.
$g_dest = $null
if ($MyInvocation.InvocationName -ne '.') {
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_SPAU"
    if (-not $g_dest) { Write-Host "STATUS: RFC_LOGON_FAILED"; exit 2 }
}

# ---------------------------------------------------------------------------
function Invoke-Worklist {
    $where = @()
    if ($Since -match '^\d{8}$') { $where += "MOD_DATE GE '$Since'" }
    if ($UserMask -and $UserMask -notmatch '[*%]') { $where += "MOD_USER EQ '$(Sq $UserMask.ToUpper())'" }
    $whereStr = ($where -join ' AND ')

    $rows = @()
    try {
        $rows = Read-SapTableRows -Destination $g_dest -Table 'SMODILOG' -Where $whereStr `
            -Fields @('OBJ_TYPE','OBJ_NAME','OPERATION','MOD_USER','MOD_DATE','TRKORR','UPGRADE','ACTIVE','SPAU','SPAU_CODE') -RowCount ([Math]::Max($Max,1) * 4)
    } catch {
        Write-Host ("STATUS: SPAU_WORKLIST_READ_FAILED detail=" + (San $_.Exception.Message)); return 1
    }
    # drop blank/technical rows
    $rows = @($rows | Where-Object { "$($_.OBJ_NAME)".Trim() -ne '' })

    # aggregate per (OBJ_TYPE,OBJ_NAME)
    $agg = @{}
    foreach ($r in $rows) {
        $k = "$($r.OBJ_TYPE)|$($r.OBJ_NAME)"
        if (-not $agg.ContainsKey($k)) {
            $agg[$k] = [ordered]@{ obj_type="$($r.OBJ_TYPE)"; obj_name="$($r.OBJ_NAME)"; rows=0; ops=@{}; last_user=''; last_date=''; trkorrs=@{}; upgrade='0'; spau_code='' }
        }
        $a = $agg[$k]; $a.rows++
        if ("$($r.OPERATION)".Trim()) { $a.ops["$($r.OPERATION)"] = $true }
        if ("$($r.TRKORR)".Trim())    { $a.trkorrs["$($r.TRKORR)"] = $true }
        if ("$($r.UPGRADE)".Trim() -eq 'X') { $a.upgrade = '1' }
        if ("$($r.SPAU_CODE)".Trim()) { $a.spau_code = "$($r.SPAU_CODE)" }
        $d = "$($r.MOD_DATE)".Trim()
        if ($d -gt $a.last_date) { $a.last_date = $d; $a.last_user = "$($r.MOD_USER)".Trim() }
    }

    # resolve package + access key per object; apply --package filter (post-read)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("obj_type`tobj_name`tpackage`tsmodilog_rows`toperations`tlast_mod_user`tlast_mod_date`taccess_key`ttrkorrs`tupgrade`tspau_code")
    $n = 0; $partial = ($rows.Count -ge ([Math]::Max($Max,1) * 4))
    foreach ($k in ($agg.Keys | Sort-Object)) {
        if ($n -ge $Max) { $partial = $true; break }
        $a = $agg[$k]
        # package via TADIR (best-effort)
        $pkg = ''
        try {
            $td = Read-SapTableRows -Destination $g_dest -Table 'TADIR' -Where "OBJ_NAME EQ '$(Sq $a.obj_name)'" -Fields @('DEVCLASS','OBJECT') -RowCount 1
            if (@($td).Count) { $pkg = "$($td[0].DEVCLASS)" }
        } catch {}
        if ($PackageMask) {
            $pm = $PackageMask.ToUpper().Replace('*','')
            if ($pkg.ToUpper() -notlike "$pm*") { continue }
        }
        # access-key presence (ADIRACCESS by name)
        $ak = ''
        try {
            $aa = Read-SapTableRows -Destination $g_dest -Table 'ADIRACCESS' -Where "OBJ_NAME EQ '$(Sq $a.obj_name)'" -Fields @('OBJ_NAME','ACCESSKEY') -RowCount 1
            if (@($aa).Count) { $ak = if ("$($aa[0].ACCESSKEY)".Trim()) { 'Y' } else { 'REGISTERED' } }
        } catch {}
        $out.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}`t{10}" -f `
            $a.obj_type, $a.obj_name, $pkg, $a.rows, (($a.ops.Keys | Sort-Object) -join '|'), $a.last_user, $a.last_date, $ak, (($a.trkorrs.Keys | Sort-Object) -join '|'), $a.upgrade, $a.spau_code))
        $n++
    }
    if (-not $OutFile) { $OutFile = Join-Path (Get-Location).Path 'spau_worklist_raw.tsv' }
    [System.IO.File]::WriteAllText($OutFile, ($out -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "WORKLIST_TSV: $OutFile"
    Write-Host ("WORKLIST: n=$n partial=" + ($(if ($partial) {'1'} else {'0'})))
    Write-Host "STATUS: OK"
    return 0
}

# ---------------------------------------------------------------------------
function Invoke-Versions {
    if (-not $ObjName) { Write-Host "STATUS: INPUT_ERROR reason=objname_required"; return 2 }
    $on = $ObjName.ToUpper(); $ot = if ($ObjType) { $ObjType.ToUpper() } else { 'REPS' }
    $rows = @()
    try {
        $fn = $g_dest.Repository.CreateFunction('SVRS_GET_VERSION_DIRECTORY_46')
        $fn.SetValue('OBJNAME', $on); $fn.SetValue('OBJTYPE', $ot); $fn.SetValue('DESTINATION', 'NONE')
        $fn.Invoke($g_dest)
        $vl = $fn.GetTable('VERSION_LIST')
        for ($i=0; $i -lt $vl.RowCount; $i++) {
            $vl.CurrentIndex = $i
            $rows += [pscustomobject]@{ VERSNO="$($vl.GetValue('VERSNO'))".Trim(); KORRNUM="$($vl.GetValue('KORRNUM'))".Trim(); AUTHOR="$($vl.GetValue('AUTHOR'))".Trim(); DATUM="$($vl.GetValue('DATUM'))".Trim(); LOEKZ="$($vl.GetValue('LOEKZ'))".Trim() }
        }
    } catch {
        Write-Host ("STATUS: SPAU_VERSION_READ_FAILED detail=" + (San $_.Exception.Message)); return 1
    }
    $rows = @($rows | Where-Object { $_.LOEKZ -ne 'X' })
    $numbered = @($rows | Where-Object { $_.VERSNO -ne '00000' } | Sort-Object { [int]$_.VERSNO } -Descending)
    Write-Host ("VERSIONS: obj=$on type=$ot n=" + $rows.Count + " numbered=" + $numbered.Count + " newest=" + $(if ($numbered.Count) { $numbered[0].VERSNO } else { 'none' }))
    if ($DeepMax -gt 0 -and $numbered.Count -gt 0 -and $OutDir) {
        if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
        # newest customer version (00000 active source) vs newest numbered version
        function Fetch-Src([string]$versno, [string]$tag) {
            try {
                $ff = $g_dest.Repository.CreateFunction('SVRS_GET_REPS_FROM_OBJECT')
                $ff.SetValue('OBJECT_NAME', $on); $ff.SetValue('OBJECT_TYPE', $ot); $ff.SetValue('VERSNO', ("{0:D8}" -f [int]$versno)); $ff.SetValue('DESTINATION','NONE')
                $ff.Invoke($g_dest)
                $rt = $ff.GetTable('REPOS_TAB'); $lines = New-Object System.Collections.Generic.List[string]
                for ($i=0; $i -lt $rt.RowCount; $i++) { $rt.CurrentIndex=$i; $lines.Add("$($rt.GetValue('LINE'))") }
                $fp = Join-Path $OutDir ("{0}_{1}.abap" -f ($on -replace '[^A-Za-z0-9_]','_'), $tag)
                [System.IO.File]::WriteAllLines($fp, $lines, (New-Object System.Text.UTF8Encoding($false)))
                Write-Host "VERSION_SRC: tag=$tag versno=$versno lines=$($rt.RowCount) file=$fp"
            } catch { Write-Host ("VERSION_SRC: tag=$tag versno=$versno ERROR " + (San $_.Exception.Message)) }
        }
        Fetch-Src '0' 'active'
        Fetch-Src $numbered[0].VERSNO 'newest'
    }
    Write-Host "STATUS: OK"
    return 0
}

# ---------------------------------------------------------------------------
function Invoke-Notes {
    $nums = @($Notes -split '[,; ]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($nums.Count -eq 0) { Write-Host "STATUS: OK"; Write-Host "INFO: no note numbers supplied"; return 0 }
    foreach ($num in ($nums | Select-Object -Unique)) {
        $numz = $num.PadLeft(10,'0')
        $h = @(); $c = @()
        try { $h = Read-SapTableRows -Destination $g_dest -Table 'CWBNTHEAD' -Where "NUMM EQ '$(Sq $numz)'" -Fields @('NUMM','VERSNO','INSTA') -RowCount 1 } catch {}
        try { $c = Read-SapTableRows -Destination $g_dest -Table 'CWBNTCUST' -Where "NUMM EQ '$(Sq $numz)'" -Fields @('NUMM','NTSTATUS','PRSTATUS','IMPL_PROGRESS') -RowCount 1 } catch {}
        if (@($h).Count -or @($c).Count) {
            $st = if (@($c).Count) { "$($c[0].NTSTATUS)/$($c[0].PRSTATUS) impl=$($c[0].IMPL_PROGRESS)" } else { 'no-cust-row' }
            Write-Host "NOTE: num=$num status=$st semantics=ADVISORY"
        } else {
            Write-Host "NOTE: num=$num status=NOT_DOWNLOADED semantics=ADVISORY"
        }
    }
    Write-Host "STATUS: OK"
    return 0
}

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    $rc = 0
    try {
        switch ($Action.ToLower()) {
            'worklist' { $rc = Invoke-Worklist }
            'versions' { $rc = Invoke-Versions }
            'notes'    { $rc = Invoke-Notes }
            default    { Write-Host "STATUS: INPUT_ERROR reason=unknown_action"; $rc = 2 }
        }
    } catch {
        Write-Host ("STATUS: SPAU_WORKLIST_READ_FAILED detail=" + (San $_.Exception.Message)); $rc = 1
    }
    try { Disconnect-SapRfc } catch {}
    exit $rc
}
