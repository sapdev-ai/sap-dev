# =============================================================================
# sap_release_notes_inventory.ps1  -  Change-inventory engine for /sap-release-notes
#
# Builds the raw material for a CAB pack: from an explicit TR list OR an E070
# date-range scope, it resolves each request's object entries (request + child
# tasks, unioned) and joins every entry to its package (TADIR) -> application
# component (TDEVC.COMPONENT -> DF14T) + package text (TDEVCT), grouping changes
# by a business-area label. Object-type codes are rendered human via a shipped,
# customer-overridable label map (raw code when unknown -- never invented text).
#
# READ-ONLY. Reads E070/E07T/E071/TADIR/TDEVC/TDEVCT/DF14T via RFC_READ_TABLE
# through the shared libs; never mutates SAP. The AI CAB pack is composed by the
# SKILL.md from the changes.tsv this script writes -- this script does NOT write
# prose and does NOT fold in readiness/impact verdicts (SKILL.md does that).
#
# Reuses Phase-0 primitives:
#   sap_rfc_lib.ps1        (Connect-SapRfc, Disconnect-SapRfc)
#   sap_object_resolver.ps1(Read-SapTableRows)
#   sap_artifact_lib.ps1   (New-SapScopeKey, Get-SapArtifactDir, Register-SapArtifact)
#
# Run with 32-bit PowerShell (SAP NCo 3.1 is 32-bit). Creds default to the pinned
# connection profile via Connect-SapRfc (so -Trs alone works when logged in).
#
# Output (stdout, parseable by SKILL.md):
#   INVENTORY: trs=<n> objects=<n> areas=<n> unresolved=<n> scope=<key>
#   CHANGES_TSV: <path>   INVENTORY_JSON: <path>   ARTIFACT_DIR: <path>   SCOPE_KEY: <key>
#   STATUS: OK | EMPTY_SCOPE | TOO_MANY_TRS | RFC_ERROR
# Exit: 0 = OK | 2 = RFC/connect error | 3 = EMPTY_SCOPE | 4 = TOO_MANY_TRS.
# =============================================================================

[CmdletBinding()]
param(
    [string]   $Trs = '',              # comma-separated explicit TR list (XOR date range)
    [string]   $FromDate = '',         # YYYYMMDD (E070 AS4DATE >=)   -- date-range scope
    [string]   $ToDate = '',           # YYYYMMDD (E070 AS4DATE <=)
    [string]   $User = '',             # AS4USER filter (date-range scope)
    [string]   $Prefix = '',           # TRKORR LIKE '<prefix>%' filter (date-range scope)
    [int]      $MaxTrs = 50,
    [string]   $Ticket = '',
    [string]   $SharedDir = '',
    [string]   $SkillDir = '',
    [string]   $CustomUrl = '',
    [string]   $OutputDir = '',
    [string]   $RunId = '',
    # Endpoint / creds - empty falls back to the pinned profile (sap_rfc_lib).
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

# sap_object_resolver.ps1 has its OWN param() block (Server/Sysnr/Client/...) -
# dot-sourcing it resets our identically named cred params (the param-clobber
# gotcha). Snapshot the creds, dot-source, then restore.
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1','sap_artifact_lib.ps1') {
    $p = Join-Path $scripts $lib
    if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

# =============================================================================
# PURE helpers - offline-testable (no RFC).
# =============================================================================

# Load the object-type label map: (pgmid,object)->label and (*,object)->label.
function Import-SapObjTypeMap {
    param([string] $SkillDir, [string] $CustomUrl)
    $map = @{}
    $files = @()
    # default shipped map first, then customer override on top (override wins).
    $def = Join-Path $SkillDir 'references\sap_release_object_types.tsv'
    if (Test-Path $def) { $files += $def }
    if ($CustomUrl) {
        $ovr = Join-Path $CustomUrl 'sap_release_object_types.tsv'
        if (Test-Path $ovr) { $files += $ovr }
    }
    foreach ($f in $files) {
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
            $c = $line -split "`t"
            if ($c.Count -lt 3) { continue }
            if ($c[0].Trim() -eq 'pgmid' -and $c[1].Trim() -eq 'object') { continue }  # header
            $pg = $c[0].Trim().ToUpper(); $ob = $c[1].Trim().ToUpper(); $lb = $c[2].Trim()
            $map["$pg|$ob"] = $lb
        }
    }
    return $map
}

function Get-SapObjTypeLabel {
    param([hashtable] $Map, [string] $Pgmid, [string] $Object)
    $pg = "$Pgmid".ToUpper(); $ob = "$Object".ToUpper()
    if ($Map.ContainsKey("$pg|$ob")) { return $Map["$pg|$ob"] }
    if ($Map.ContainsKey("R3TR|$ob")) { return $Map["R3TR|$ob"] }
    if ($Map.ContainsKey("LIMU|$ob")) { return $Map["LIMU|$ob"] }
    return $ob   # raw code - never an invented label
}

# Load an optional package-prefix -> business-area override: {custom_url}\release_area_map.tsv
# Format: prefix<TAB>area_name  (longest matching prefix wins).
function Import-SapAreaOverride {
    param([string] $CustomUrl)
    $rules = @()
    if (-not $CustomUrl) { return $rules }
    $f = Join-Path $CustomUrl 'release_area_map.tsv'
    if (-not (Test-Path $f)) { return $rules }
    foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
        $c = $line -split "`t"
        if ($c.Count -lt 2) { continue }
        if ($c[0].Trim().ToLower() -eq 'prefix') { continue }
        $rules += [pscustomobject]@{ prefix = $c[0].Trim().ToUpper(); area = $c[1].Trim() }
    }
    return ,($rules | Sort-Object { $_.prefix.Length } -Descending)
}

function Get-SapAreaOverride {
    param([object[]] $Rules, [string] $Package)
    $pk = "$Package".ToUpper()
    foreach ($r in $Rules) { if ($pk.StartsWith($r.prefix)) { return $r.area } }
    return ''
}

# Pick the best text row from a set of language-tagged rows: preferred lang -> E -> first non-blank.
function Select-SapText {
    param([object[]] $Rows, [string] $LangField, [string] $TextField, [string] $PreferLang = '')
    if (-not $Rows -or $Rows.Count -eq 0) { return '' }
    $pl = "$PreferLang".ToUpper()
    if ($pl) { foreach ($r in $Rows) { if ("$($r.$LangField)".ToUpper() -eq $pl -and "$($r.$TextField)".Trim()) { return "$($r.$TextField)".Trim() } } }
    foreach ($r in $Rows) { if ("$($r.$LangField)".ToUpper() -eq 'E' -and "$($r.$TextField)".Trim()) { return "$($r.$TextField)".Trim() } }
    foreach ($r in $Rows) { if ("$($r.$TextField)".Trim()) { return "$($r.$TextField)".Trim() } }
    return ''
}

# Business-area group label precedence: override -> app-component text -> package text -> package -> (unresolved).
function Resolve-SapGroupLabel {
    param([string] $Override, [string] $AreaText, [string] $PkgText, [string] $Package)
    if ($Override) { return $Override }
    if ($AreaText) { return $AreaText }
    if ($PkgText)  { return $PkgText }
    if ($Package -and $Package -ne '<none>') { return "Package $Package" }
    return '(unresolved)'
}

# =============================================================================
# Main - skipped when dot-sourced (pure helpers above stay testable).
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    $prefLang = if ($Language) { $Language } else { '' }
    $objMap   = Import-SapObjTypeMap -SkillDir $SkillDir -CustomUrl $CustomUrl
    $areaRules = Import-SapAreaOverride -CustomUrl $CustomUrl

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $UserId -Password $Password -Language $Language `
                             -DestName "SAPDEV_RELNOTES"
    if (-not $g_dest) {
        Write-Host "STATUS: RFC_ERROR"
        Write-Host "INVENTORY: trs=0 objects=0 areas=0 unresolved=0 scope="
        exit 2
    }

    try {
        $effClient = if ($Client) { $Client } else { "$g_sapClient" }
        $sid = ''
        try { $sid = Get-SapResolverSysId -Destination $g_dest } catch { $sid = '' }

        # ---- Resolve the TR scope ------------------------------------------
        $trList = @()
        if ($Trs.Trim()) {
            $trList = @($Trs.ToUpper() -split '[,; ]+' | Where-Object { $_.Trim() } | Select-Object -Unique)
        } else {
            # Date-range scope over E070 requests (K=workbench, W=customizing).
            $whereParts = @("( TRFUNCTION EQ 'K' OR TRFUNCTION EQ 'W' )")
            if ($FromDate) { $whereParts += "AS4DATE GE '$FromDate'" }
            if ($ToDate)   { $whereParts += "AS4DATE LE '$ToDate'" }
            if ($User)     { $whereParts += "AS4USER EQ '$($User.ToUpper())'" }
            if ($Prefix)   { $whereParts += "TRKORR LIKE '$($Prefix.ToUpper())%'" }
            $where = $whereParts -join ' AND '
            $rows = Read-SapTableRows -Destination $g_dest -Table 'E070' -Where $where `
                        -Fields @('TRKORR','TRFUNCTION','TRSTATUS','AS4USER','AS4DATE') -RowCount ($MaxTrs + 1)
            if ($null -eq $rows) {
                Write-Host "STATUS: RFC_ERROR"; Write-Host "INVENTORY: trs=0 objects=0 areas=0 unresolved=0 scope="; Disconnect-SapRfc; exit 2
            }
            $trList = @($rows | Sort-Object AS4DATE -Descending | ForEach-Object { $_.TRKORR })
        }

        if ($trList.Count -eq 0) {
            Write-Host "STATUS: EMPTY_SCOPE"; Write-Host "INVENTORY: trs=0 objects=0 areas=0 unresolved=0 scope="; Disconnect-SapRfc; exit 3
        }
        if ($trList.Count -gt $MaxTrs) {
            Write-Host "STATUS: TOO_MANY_TRS found=$($trList.Count) cap=$MaxTrs"
            Write-Host "INVENTORY: trs=$($trList.Count) objects=0 areas=0 unresolved=0 scope="
            Disconnect-SapRfc; exit 4
        }

        # ---- Caches --------------------------------------------------------
        $cacheTadir  = @{}   # 'OBJECT|OBJ_NAME' -> devclass ('' when none)
        $cachePkg    = @{}   # devclass -> @{ component=..; pkg_text=..; area_text=.. }

        function Get-SapPackageInfo {
            param([string] $Devclass)
            if ([string]::IsNullOrWhiteSpace($Devclass)) { return @{ component=''; pkg_text=''; area_text='' } }
            if ($cachePkg.ContainsKey($Devclass)) { return $cachePkg[$Devclass] }
            $component = ''; $pkgText = ''; $areaText = ''
            $td = Read-SapTableRows -Destination $g_dest -Table 'TDEVC' -Where "DEVCLASS EQ '$Devclass'" -Fields @('DEVCLASS','COMPONENT') -RowCount 1
            if ($td -and $td.Count) { $component = "$($td[0].COMPONENT)".Trim() }
            $tt = Read-SapTableRows -Destination $g_dest -Table 'TDEVCT' -Where "DEVCLASS EQ '$Devclass'" -Fields @('DEVCLASS','SPRAS','CTEXT') -RowCount 10
            $pkgText = Select-SapText -Rows $tt -LangField 'SPRAS' -TextField 'CTEXT' -PreferLang $prefLang
            if ($component) {
                $df = Read-SapTableRows -Destination $g_dest -Table 'DF14T' -Where "FCTR_ID EQ '$component' AND AS4LOCAL EQ 'A'" -Fields @('LANGU','FCTR_ID','NAME') -RowCount 12
                $areaText = Select-SapText -Rows $df -LangField 'LANGU' -TextField 'NAME' -PreferLang $prefLang
            }
            $info = @{ component=$component; pkg_text=$pkgText; area_text=$areaText }
            $cachePkg[$Devclass] = $info
            return $info
        }

        # Raw TADIR package lookup for an R3TR master (object, name).
        function Get-SapTadirDevclass {
            param([string] $Object, [string] $ObjName)
            if ([string]::IsNullOrWhiteSpace($ObjName)) { return '' }
            $t = Read-SapTableRows -Destination $g_dest -Table 'TADIR' `
                    -Where "PGMID EQ 'R3TR' AND OBJECT EQ '$Object' AND OBJ_NAME EQ '$($ObjName -replace "'","''")'" -Fields @('DEVCLASS') -RowCount 1
            if ($t -and $t.Count) { return "$($t[0].DEVCLASS)".Trim() }
            return ''
        }

        # Function group of an FM, via TFDIR.PNAME ('SAPL<group>').
        function Get-SapFuncGroup {
            param([string] $Fm)
            $t = Read-SapTableRows -Destination $g_dest -Table 'TFDIR' -Where "FUNCNAME EQ '$($Fm -replace "'","''")'" -Fields @('FUNCNAME','PNAME') -RowCount 1
            if ($t -and $t.Count) {
                $pn = "$($t[0].PNAME)".Trim()
                if ($pn.ToUpper().StartsWith('SAPL')) { return $pn.Substring(4) }
                return $pn
            }
            return ''
        }

        # Package for any E071 entry: R3TR direct; LIMU sub-objects resolved to their
        # R3TR master (best-effort, common types) then TADIR-looked-up. '' when not found.
        function Get-SapEntryDevclass {
            param([string] $Pgmid, [string] $Object, [string] $ObjName)
            $k = "$Pgmid|$Object|$ObjName"
            if ($cacheTadir.ContainsKey($k)) { return $cacheTadir[$k] }
            $pg = "$Pgmid".ToUpper(); $ob = "$Object".ToUpper(); $dc = ''
            if ($pg -eq 'R3TR') {
                $dc = Get-SapTadirDevclass -Object $ob -ObjName $ObjName
            } elseif ($pg -eq 'LIMU') {
                switch ($ob) {
                    { $_ -in @('REPS','REPT','CUAD','SCRP') } { $dc = Get-SapTadirDevclass -Object 'PROG' -ObjName $ObjName; break }
                    'FUNC' { $fg = Get-SapFuncGroup -Fm $ObjName; if ($fg) { $dc = Get-SapTadirDevclass -Object 'FUGR' -ObjName $fg }; break }
                    { $_ -in @('METH','CINC','CPUB','CPRI','CPRO','CLSD','CLSR','CDEF','CDES') } {
                        $cls = if ($ObjName.Length -gt 30) { $ObjName.Substring(0,30).Trim() } else { $ObjName.Trim() }
                        if ($cls) { $dc = Get-SapTadirDevclass -Object 'CLAS' -ObjName $cls }; break
                    }
                    default { $dc = '' }
                }
            }
            $cacheTadir[$k] = $dc
            return $dc
        }

        # ---- Walk each TR --------------------------------------------------
        $records = @()   # one row per (TR, object entry)
        $trMeta  = @()   # per-TR header info for inventory.json
        foreach ($tr in $trList) {
            $hdr = Read-SapTableRows -Destination $g_dest -Table 'E070' -Where "TRKORR EQ '$tr'" `
                        -Fields @('TRKORR','TRFUNCTION','TRSTATUS','AS4USER','AS4DATE') -RowCount 1
            if (-not $hdr -or $hdr.Count -eq 0) {
                $trMeta += [pscustomobject]@{ trkorr=$tr; found=$false; text=''; owner=''; date=''; status=''; trfunction=''; objects=0 }
                continue
            }
            $h = $hdr[0]
            $txtRows = Read-SapTableRows -Destination $g_dest -Table 'E07T' -Where "TRKORR EQ '$tr'" -Fields @('TRKORR','LANGU','AS4TEXT') -RowCount 10
            $trText  = Select-SapText -Rows $txtRows -LangField 'LANGU' -TextField 'AS4TEXT' -PreferLang $prefLang

            # request + child tasks -> union of E071 object entries
            $children = Read-SapTableRows -Destination $g_dest -Table 'E070' -Where "STRKORR EQ '$tr'" -Fields @('TRKORR','AS4USER') -RowCount 50
            $ownerOf = @{ "$tr" = "$($h.AS4USER)" }
            $srcTrs = @($tr)
            if ($children -and $children.Count) { foreach ($c in $children) { $srcTrs += "$($c.TRKORR)"; $ownerOf["$($c.TRKORR)"] = "$($c.AS4USER)" } }

            $seen = @{}
            $trObjCount = 0
            foreach ($stk in ($srcTrs | Select-Object -Unique)) {
                $ents = Read-SapTableRows -Destination $g_dest -Table 'E071' -Where "TRKORR EQ '$stk'" -Fields @('TRKORR','AS4POS','PGMID','OBJECT','OBJ_NAME') -RowCount 500
                if (-not $ents) { continue }
                foreach ($e in $ents) {
                    # CORR entries are transport-control records (release stamps / SYST), not
                    # content changes - never a CAB-pack line.
                    if ("$($e.PGMID)".ToUpper() -eq 'CORR') { continue }
                    $dedupKey = "$($e.PGMID)|$($e.OBJECT)|$($e.OBJ_NAME)"
                    if ($seen.ContainsKey($dedupKey)) { continue }
                    $seen[$dedupKey] = $true
                    $trObjCount++
                    $devclass = Get-SapEntryDevclass -Pgmid "$($e.PGMID)" -Object "$($e.OBJECT)" -ObjName "$($e.OBJ_NAME)"
                    $pinfo = Get-SapPackageInfo -Devclass $devclass
                    $override = Get-SapAreaOverride -Rules $areaRules -Package $devclass
                    $area = Resolve-SapGroupLabel -Override $override -AreaText $pinfo.area_text -PkgText $pinfo.pkg_text -Package $devclass
                    $records += [pscustomobject]@{
                        trkorr    = $tr
                        task      = if ($stk -eq $tr) { '' } else { $stk }
                        owner     = $ownerOf["$stk"]
                        date      = "$($h.AS4DATE)"
                        pgmid     = "$($e.PGMID)"
                        object    = "$($e.OBJECT)"
                        obj_name  = "$($e.OBJ_NAME)"
                        package   = if ($devclass) { $devclass } else { '' }
                        area      = $area
                        type_label= (Get-SapObjTypeLabel -Map $objMap -Pgmid "$($e.PGMID)" -Object "$($e.OBJECT)")
                        tr_text   = $trText
                    }
                }
            }
            $trMeta += [pscustomobject]@{ trkorr=$tr; found=$true; text=$trText; owner="$($h.AS4USER)"; date="$($h.AS4DATE)"; status="$($h.TRSTATUS)"; trfunction="$($h.TRFUNCTION)"; objects=$trObjCount }
        }

        # No content objects anywhere in scope (unknown TRs / empty requests) -> no pack.
        if ($records.Count -eq 0) {
            Write-Host "STATUS: EMPTY_SCOPE"
            Write-Host "INVENTORY: trs=$($trList.Count) objects=0 areas=0 unresolved=0 scope="
            Disconnect-SapRfc; exit 3
        }

        # ---- Scope key + output dir ----------------------------------------
        if ($trList.Count -eq 1) {
            $scope = New-SapScopeKey -Kind 'TR' -Name $trList[0]
        } elseif ($Ticket) {
            $scope = "TICKET_" + ($Ticket.ToUpper() -replace '[^A-Z0-9_]', '_')
        } else {
            $joined = ($trList | Sort-Object) -join ';'
            $sha = [System.Security.Cryptography.SHA1]::Create()
            $hash = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined)) | ForEach-Object { $_.ToString('x2') }) -join ''
            $stamp = if ($ToDate) { $ToDate } elseif ($FromDate) { $FromDate } else { 'range' }
            $scope = "TRSET_${stamp}_" + $hash.Substring(0, 8)
        }
        if ($OutputDir) {
            if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
            $dir = $OutputDir
        } else {
            $dir = Get-SapArtifactDir -ScopeKey $scope -Skill 'sap-release-notes' -RunId $RunId
        }

        # ---- Write changes.tsv (Excel-BOM) + inventory.json ----------------
        $changesTsv = Join-Path $dir 'changes.tsv'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine(("trkorr`ttask`towner`tdate`tpgmid`tobject`tobj_name`tpackage`tarea`ttype_label`ttr_text"))
        foreach ($r in $records) {
            [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}`t{10}" -f `
                $r.trkorr,$r.task,$r.owner,$r.date,$r.pgmid,$r.object,$r.obj_name,$r.package,$r.area,$r.type_label,($r.tr_text -replace "`t",' ')))
        }
        [System.IO.File]::WriteAllText($changesTsv, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

        $invJson = Join-Path $dir 'inventory.json'
        $areasDistinct = @($records | ForEach-Object { $_.area } | Select-Object -Unique)
        $unresolved = @($records | Where-Object { $_.area -eq '(unresolved)' }).Count
        $invObj = [pscustomobject]@{
            schema     = 'sapdev.release_inventory/1'
            scope_key  = $scope
            ticket     = $Ticket
            system     = $sid
            client     = $effClient
            generated_from = if ($Trs.Trim()) { 'tr_list' } else { 'date_range' }
            from_date  = $FromDate
            to_date    = $ToDate
            trs        = $trMeta
            areas      = $areasDistinct
            object_count = $records.Count
            unresolved_count = $unresolved
        }
        [System.IO.File]::WriteAllText($invJson, ($invObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

        # ---- Register the change inventory ---------------------------------
        $scopeKind = if ($trList.Count -eq 1) { 'TR' } else { 'TRSET' }
        Register-SapArtifact -Skill 'sap-release-notes' -ScopeKey $scope -ScopeKind $scopeKind -Kind 'change_inventory' `
            -Format 'tsv' -Path $changesTsv -Rows $records.Count -Ticket $Ticket -RunId $RunId -System $sid -Client $effClient | Out-Null

        Write-Host ("INVENTORY: trs={0} objects={1} areas={2} unresolved={3} scope={4}" -f $trList.Count, $records.Count, $areasDistinct.Count, $unresolved, $scope)
        Write-Host "CHANGES_TSV: $changesTsv"
        Write-Host "INVENTORY_JSON: $invJson"
        Write-Host "ARTIFACT_DIR: $dir"
        Write-Host "SCOPE_KEY: $scope"
        Write-Host "STATUS: OK"
        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        Write-Host "STATUS: RFC_ERROR"
        Write-Host "INVENTORY: trs=0 objects=0 areas=0 unresolved=0 scope="
        Disconnect-SapRfc
        exit 2
    }
}
