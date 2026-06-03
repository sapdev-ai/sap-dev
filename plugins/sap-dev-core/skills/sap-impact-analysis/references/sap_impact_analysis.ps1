# =============================================================================
# sap_impact_analysis.ps1  -  Dependency / impact engine for /sap-impact-analysis
#
# "If I change this object, what else might break?" - answered from SAP's
# system-maintained CROSS-REFERENCE INDEX, never by parsing source (REPOSRC is
# blocked) and never by driving the GUI where-used (slow, serial, reverse-only).
# See contributing/phase0_delivery_assurance_spec.md  Appendix P1.
#
# Index tables read (all RFC_READ_TABLE-safe, narrow rows):
#   D010TAB   program <-> table usage   (TABNAME, MASTER)        - both directions
#   D010INC   program <-> include       (MASTER, INCLUDE)        - include->program resolve
#   WBCROSSGT global-symbol usage        (OTYPE, NAME, INCLUDE)   - both directions
#   CROSS     classic refs (FORM/FM/MSG) (TYPE, NAME, INCLUDE)
#   DD04L     domain -> data elements    (DOMNAME, ROLLNAME)
#   DD03L     data element -> fields     (ROLLNAME, TABNAME)      - best-effort (wide table)
#   TSTC/TBTCP/VARID  runtime entry points;  E071/E070  transport history
#
# CONFIDENCE: index-derived edges are HIGH. The cross-reference index is blind to
# DYNAMIC dispatch (CALL FUNCTION lv_name, dynamic SELECT, SUBMIT (rep)) - every
# report says so explicitly (honesty contract). It can also be stale (rebuilt on
# save/activate / SGEN); read failures degrade to COULD_NOT_CHECK, never silent.
#
# Reuses Phase-0 primitives: sap_object_resolver, sap_finding_lib, sap_artifact_lib.
# Read-only. Run under 32-bit PowerShell (NCo 3.1). Creds fall back to the pinned
# profile via Connect-SapRfc.
#
# Output (stdout):
#   IMPACT: object=<O:N> risk=<LOW|MEDIUM|HIGH> reverse=<n> forward=<n> runtime=<n> trs=<n>
#   REPORT_MD / REVERSE_TSV / FORWARD_TSV / RUNTIME_TSV / TRANSPORT_TSV / RISK_TSV / RISK_JSON: <path>
# Exit: 0 ok | 1 object not found | 2 RFC failure.
#
# Index-table field names follow S/4HANA 1909; re-confirm on first live run if a
# release differs (OTYPE / CROSS.TYPE code *values* especially vary - this engine
# does not hardcode them, it reads and reports whatever is there).
# =============================================================================

[CmdletBinding()]
param(
    [string] $Token = '',
    [string] $TypeHint = '',
    [string] $SharedDir = '',
    [string] $OutputDir = '',
    [int] $Depth = 1,
    [int] $MaxIncludeResolve = 300,   # cap include->program lookups; logs if exceeded
    [int] $HighFanout = 50,
    [int] $MedFanout = 10,
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $User = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $SharedDir) {
    try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\shared')).Path } catch { $SharedDir = '' }
}
$scripts = Join-Path $SharedDir 'scripts'
# sap_object_resolver.ps1 has its OWN param() block (Token/TypeHint/Server/...).
# Dot-sourcing it executes that block in our scope and RESETS our identically
# named params to defaults (the dot-source param-clobber gotcha). Snapshot the
# colliding params, dot-source, then restore.
$__keep = @{ Token=$Token; TypeHint=$TypeHint; Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; User=$User; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1','sap_finding_lib.ps1','sap_artifact_lib.ps1') {
    $p = Join-Path $scripts $lib
    if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

# =============================================================================
# PURE functions - plain data in, records/findings out. Offline-testable.
# =============================================================================

function New-SapRelation {
    param([string]$From, [string]$To, [string]$RelType, [string]$Direction, [string]$Confidence = 'HIGH', [string]$Source = '')
    return [pscustomobject][ordered]@{
        from = $From; to = $To; rel_type = $RelType; direction = $Direction
        confidence = $Confidence; source = $Source
    }
}

function Get-SapObjLabel {
    param($Object)
    if ($Object -and "$($Object.obj_name)") {
        if ("$($Object.object)") { return "$($Object.object):$($Object.obj_name)" }
        return "$($Object.obj_name)"
    }
    return ''
}

# include -> program(s) map from D010INC rows (MASTER, INCLUDE).
function Build-SapIncludeProgramMap {
    param([object[]] $Rows = @())
    $m = @{}
    foreach ($r in $Rows) {
        $inc = "$($r.INCLUDE)"
        if (-not $inc) { continue }
        if (-not $m.ContainsKey($inc)) { $m[$inc] = New-Object System.Collections.Generic.List[string] }
        $mas = "$($r.MASTER)"
        if ($mas -and -not $m[$inc].Contains($mas)) { $m[$inc].Add($mas) }
    }
    return $m
}

# Resolve a using-include to its owning program(s); fall back to the include name.
function Resolve-SapIncludeProgram {
    param([string] $Include, [hashtable] $Map)
    if ($Map -and $Map.ContainsKey($Include) -and $Map[$Include].Count -gt 0) { return @($Map[$Include]) }
    return @($Include)   # unresolved -> report the include itself (lower resolution)
}

# Map a WBCROSSGT OTYPE code to a human label (best-effort; codes vary by release).
function Get-SapOtypeLabel {
    param([string] $Otype)
    switch ("$Otype".ToUpper()) {
        'TY' { 'type' } 'ME' { 'method' } 'DA' { 'data' } 'EV' { 'event' }
        'AT' { 'attribute' } 'IA' { 'interface' } default { "otype-$Otype" }
    }
}

function Get-SapImpactBand {
    param([object[]] $Findings = @())
    $rank = 0
    foreach ($f in $Findings) {
        if ("$($f.category)" -eq 'DYNAMIC_DISPATCH_BLINDSPOT') { continue }
        $r = Get-SapSeverityRank $f.severity
        if ($r -gt $rank) { $rank = $r }
    }
    if ($rank -ge (Get-SapSeverityRank 'MEDIUM')) {
        if ($rank -ge (Get-SapSeverityRank 'HIGH')) { return 'HIGH' }
        return 'MEDIUM'
    }
    return 'LOW'
}

# Thin, transparent risk findings. Impact analysis is advisory - INFO/LOW/MEDIUM
# only, never a gate. Thresholds are stated in the finding text.
function Get-SapImpactRiskFindings {
    param(
        [int] $ReverseCount, [int] $ForwardCount, [int] $RuntimeCount,
        [bool] $IsStandard, $Object, [int] $HighFanout = 50, [int] $MedFanout = 10,
        [string[]] $CouldNotCheck = @()
    )
    $out = @()
    $sev = if ($ReverseCount -ge $HighFanout) { 'HIGH' } elseif ($ReverseCount -ge $MedFanout) { 'MEDIUM' } elseif ($ReverseCount -gt 0) { 'LOW' } else { 'INFO' }
    $out += (New-SapFinding -Severity $sev -Category IMPACT_FANOUT -Object $Object -Source WBCROSSGT -Confidence HIGH `
                -Detail "$ReverseCount object(s) reference this (where-used). Bands: >=$HighFanout HIGH, >=$MedFanout MEDIUM, >0 LOW, else INFO." `
                -Remediation "Regression-test the $ReverseCount dependents before changing this object.")
    if ($IsStandard) {
        $out += (New-SapFinding -Severity MEDIUM -Category STANDARD_OBJECT -Object $Object -Source TADIR `
                    -Detail "This is a standard (non-Z/Y) object - modification carries upgrade risk." `
                    -Remediation "Prefer an enhancement (BAdI / exit) over modifying standard - see /sap-enhancement-advisor.")
    }
    foreach ($c in ($CouldNotCheck | Select-Object -Unique)) {
        $out += (New-SapFinding -Severity MEDIUM -Category IMPACT_PARTIAL -Object $Object -Coverage COULD_NOT_CHECK -Source $c `
                    -Detail "Could not read $c (auth / RFC) - impact for that dimension is INCOMPLETE." `
                    -Remediation "Re-run with table-read authorization for $c.")
    }
    # Always disclose the dynamic-dispatch blind spot.
    $out += (New-SapFinding -Severity INFO -Category DYNAMIC_DISPATCH_BLINDSPOT -Object $Object -Source STATIC_SCAN -Confidence LOW `
                -Detail "Dynamic calls (CALL FUNCTION lv_name, dynamic SELECT, SUBMIT (rep)) are invisible to the cross-reference index and are NOT counted here." `
                -Remediation "Manually scan for dynamic usage of this object.")
    return $out
}

function Build-SapImpactMarkdown {
    param(
        $Object, [string] $Band, [object[]] $Reverse = @(), [object[]] $Forward = @(),
        [object[]] $Runtime = @(), [object[]] $Transports = @(), [object[]] $Findings = @(),
        [string[]] $CouldNotCheck = @()
    )
    $label = Get-SapObjLabel $Object
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Impact analysis - $label")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Risk band: $Band**  |  package $($Object.package)  |  system $($Object.system)")
    [void]$sb.AppendLine("Reverse (where-used): $($Reverse.Count)  |  Forward (uses): $($Forward.Count)  |  Runtime entry points: $($Runtime.Count)  |  Transports: $($Transports.Count)")
    [void]$sb.AppendLine("")
    if ($CouldNotCheck.Count) {
        [void]$sb.AppendLine("> **Incomplete:** could not read $(( $CouldNotCheck | Select-Object -Unique ) -join ', ') - those dimensions are NOT certified complete.")
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("> Note: Dynamic dispatch (CALL FUNCTION lv_name, dynamic SELECT, SUBMIT (rep)) is invisible to the cross-reference index and is not included below.")
    [void]$sb.AppendLine("")
    $notable = @($Findings | Where-Object { "$($_.category)" -ne 'DYNAMIC_DISPATCH_BLINDSPOT' -and "$($_.severity)" -ne 'INFO' })
    if ($notable.Count) {
        [void]$sb.AppendLine("## Risk findings")
        foreach ($f in $notable) { [void]$sb.AppendLine("- **[$($f.severity)] $($f.category)** - $($f.detail)  _-> $($f.remediation)_") }
        [void]$sb.AppendLine("")
    }
    if ($Runtime.Count) {
        [void]$sb.AppendLine("## Runtime entry points ($($Runtime.Count))")
        foreach ($r in $Runtime) { [void]$sb.AppendLine("- $($r.rel_type): $($r.to)") }
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("## Reverse dependencies - what uses $label ($($Reverse.Count))")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| using object | relation | source | confidence |")
    [void]$sb.AppendLine("|---|---|---|---|")
    foreach ($e in ($Reverse | Select-Object -First 100)) { [void]$sb.AppendLine("| $($e.from) | $($e.rel_type) | $($e.source) | $($e.confidence) |") }
    if ($Reverse.Count -gt 100) { [void]$sb.AppendLine("") ; [void]$sb.AppendLine("_... $($Reverse.Count - 100) more (see reverse_dependencies.tsv)_") }
    [void]$sb.AppendLine("")
    if ($Transports.Count) {
        [void]$sb.AppendLine("## Transport history ($($Transports.Count))")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| TR | owner | date | status |")
        [void]$sb.AppendLine("|---|---|---|---|")
        foreach ($t in ($Transports | Select-Object -First 30)) { [void]$sb.AppendLine("| $($t.trkorr) | $($t.owner) | $($t.date) | $($t.status) |") }
    }
    return $sb.ToString()
}

function Write-SapRelTsv {
    param([object[]] $Rels = @(), [string] $Path)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("from`tto`trel_type`tdirection`tsource`tconfidence")
    foreach ($e in $Rels) { [void]$sb.AppendLine("$($e.from)`t$($e.to)`t$($e.rel_type)`t$($e.direction)`t$($e.source)`t$($e.confidence)") }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $Path
}

# =============================================================================
# RFC gather layer - feeds the pure builders. Each read is graceful: $null
# (read failure) is collected into $script:CouldNot, never silently dropped.
# Returns PLAIN arrays (return $out - NOT ,$out - so @() consumers flatten).
# =============================================================================
$script:CouldNot = @()

function _ImpactRead {
    param($Destination, [string] $Table, [string] $Where, [string[]] $Fields)
    $rows = Read-SapTableRows -Destination $Destination -Table $Table -Where $Where -Fields $Fields
    if ($null -eq $rows) { $script:CouldNot += $Table }
    return $rows
}

# Reverse where-used for the resolved object.
function Get-SapReverseDeps {
    param($Destination, $Object, [hashtable] $IncMapRef)
    $name = "$($Object.obj_name)"
    $type = "$($Object.object)"
    $label = Get-SapObjLabel $Object
    $out = @()

    # DDIC table / structure: D010TAB (programs) + WBCROSSGT (type usages).
    if ($type -in @('TABL','VIEW')) {
        $rows = _ImpactRead -Destination $Destination -Table 'D010TAB' -Where "TABNAME EQ '$name'" -Fields @('TABNAME','MASTER')
        foreach ($r in @($rows)) { if ("$($r.MASTER)") { $out += (New-SapRelation -From "PROG:$($r.MASTER)" -To $label -RelType 'USES_TABLE' -Direction REVERSE -Source D010TAB) } }
    }

    # Global symbols (TABL/DTEL/CLAS/INTF/TTYP/...): WBCROSSGT NAME -> using includes.
    $wb = _ImpactRead -Destination $Destination -Table 'WBCROSSGT' -Where "NAME EQ '$name'" -Fields @('OTYPE','NAME','INCLUDE')
    $includes = @(@($wb) | ForEach-Object { "$($_.INCLUDE)" } | Where-Object { $_ } | Select-Object -Unique)
    # FM / FORM / message: CROSS NAME -> using includes.
    $cr = _ImpactRead -Destination $Destination -Table 'CROSS' -Where "NAME EQ '$name'" -Fields @('TYPE','NAME','INCLUDE')
    $includes += @(@($cr) | ForEach-Object { "$($_.INCLUDE)" } | Where-Object { $_ } | Select-Object -Unique)
    $includes = @($includes | Select-Object -Unique)

    if ($includes.Count -gt $MaxIncludeResolve) {
        Write-Host "WARN: $($includes.Count) using-includes exceed -MaxIncludeResolve ($MaxIncludeResolve); resolving the first $MaxIncludeResolve, reporting the rest as includes."
    }
    $i = 0
    foreach ($inc in $includes) {
        $progs = if ($i -lt $MaxIncludeResolve) {
            $d = _ImpactRead -Destination $Destination -Table 'D010INC' -Where "INCLUDE EQ '$inc'" -Fields @('MASTER','INCLUDE')
            $map = Build-SapIncludeProgramMap -Rows @($d)
            Resolve-SapIncludeProgram -Include $inc -Map $map
        } else { @($inc) }
        foreach ($p in @($progs)) { $out += (New-SapRelation -From "PROG:$p" -To $label -RelType 'REFERENCES' -Direction REVERSE -Source WBCROSSGT/CROSS) }
        $i++
    }

    # DDIC: domain -> data elements; data element -> table fields.
    if ($type -eq 'DOMA') {
        $de = _ImpactRead -Destination $Destination -Table 'DD04L' -Where "DOMNAME EQ '$name'" -Fields @('ROLLNAME','DOMNAME')
        foreach ($r in @($de)) { if ("$($r.ROLLNAME)") { $out += (New-SapRelation -From "DTEL:$($r.ROLLNAME)" -To $label -RelType 'USES_DOMAIN' -Direction REVERSE -Source DD04L) } }
    }
    if ($type -eq 'DTEL') {
        $tf = _ImpactRead -Destination $Destination -Table 'DD03L' -Where "ROLLNAME EQ '$name'" -Fields @('TABNAME','ROLLNAME')
        foreach ($r in @($tf)) { $tn = "$($r.TABNAME)"; if ($tn -and -not $tn.StartsWith('*')) { $out += (New-SapRelation -From "TABL:$tn" -To $label -RelType 'USES_DTEL' -Direction REVERSE -Source DD03L) } }
    }

    # Dedup.
    $seen = @{}; $dedup = @()
    foreach ($e in $out) { $k = "$($e.from)|$($e.rel_type)"; if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $dedup += $e } }
    return $dedup
}

# Forward uses (PROGRAM only for MVP): tables + global symbols.
function Get-SapForwardDeps {
    param($Destination, $Object)
    $name = "$($Object.obj_name)"
    $type = "$($Object.object)"
    $label = Get-SapObjLabel $Object
    $out = @()
    if ($type -ne 'PROG') { return $out }   # MVP: forward only for programs

    $t = _ImpactRead -Destination $Destination -Table 'D010TAB' -Where "MASTER EQ '$name'" -Fields @('TABNAME','MASTER')
    foreach ($r in @($t)) { $tn = "$($r.TABNAME)"; if ($tn -and -not $tn.StartsWith('*')) { $out += (New-SapRelation -From $label -To "TABL:$tn" -RelType 'USES_TABLE' -Direction FORWARD -Source D010TAB) } }

    # Program's own includes, then symbols referenced from those includes.
    $inc = _ImpactRead -Destination $Destination -Table 'D010INC' -Where "MASTER EQ '$name'" -Fields @('MASTER','INCLUDE')
    $myIncludes = @(@($inc) | ForEach-Object { "$($_.INCLUDE)" } | Where-Object { $_ } | Select-Object -Unique)
    $myIncludes += $name   # the main program is itself an include key in WBCROSSGT
    $i = 0
    foreach ($ic in (@($myIncludes) | Select-Object -Unique)) {
        if ($i -ge $MaxIncludeResolve) { break }
        $wb = _ImpactRead -Destination $Destination -Table 'WBCROSSGT' -Where "INCLUDE EQ '$ic'" -Fields @('OTYPE','NAME','INCLUDE')
        foreach ($r in @($wb)) { $sym = "$($r.NAME)"; if ($sym) { $out += (New-SapRelation -From $label -To "$(Get-SapOtypeLabel $r.OTYPE):$sym" -RelType 'REFERENCES' -Direction FORWARD -Source WBCROSSGT) } }
        $i++
    }
    $seen = @{}; $dedup = @()
    foreach ($e in $out) { $k = "$($e.to)|$($e.rel_type)"; if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $dedup += $e } }
    return $dedup
}

function Get-SapRuntimeEntryPoints {
    param($Destination, $Object)
    $name = "$($Object.obj_name)"
    $type = "$($Object.object)"
    $label = Get-SapObjLabel $Object
    $out = @()
    if ($type -eq 'PROG') {
        $tc = _ImpactRead -Destination $Destination -Table 'TSTC' -Where "PGMNA EQ '$name'" -Fields @('TCODE','PGMNA')
        foreach ($r in @($tc)) { if ("$($r.TCODE)") { $out += (New-SapRelation -From "TRAN:$($r.TCODE)" -To $label -RelType 'TCODE' -Direction REVERSE -Source TSTC) } }
        $vr = _ImpactRead -Destination $Destination -Table 'VARID' -Where "REPORT EQ '$name'" -Fields @('REPORT','VARIANT')
        foreach ($r in @($vr)) { if ("$($r.VARIANT)") { $out += (New-SapRelation -From "VARIANT:$($r.VARIANT)" -To $label -RelType 'VARIANT' -Direction REVERSE -Source VARID) } }
        $jb = _ImpactRead -Destination $Destination -Table 'TBTCP' -Where "PROGNAME EQ '$name'" -Fields @('JOBNAME','PROGNAME')
        $jobs = @(@($jb) | ForEach-Object { "$($_.JOBNAME)" } | Where-Object { $_ } | Select-Object -Unique)
        foreach ($j in $jobs) { $out += (New-SapRelation -From "JOB:$j" -To $label -RelType 'JOB_STEP' -Direction REVERSE -Source TBTCP) }
    }
    if ($type -eq 'FUNC') {
        $tf = _ImpactRead -Destination $Destination -Table 'TFDIR' -Where "FUNCNAME EQ '$name'" -Fields @('FUNCNAME','FMODE')
        foreach ($r in @($tf)) { if ("$($r.FMODE)" -eq 'R') { $out += (New-SapRelation -From "RFC:$name" -To $label -RelType 'RFC_ENABLED' -Direction REVERSE -Source TFDIR) } }
    }
    return $out
}

function Get-SapTransportHistory {
    param($Destination, $Object)
    $name = "$($Object.obj_name)"
    $obj  = "$($Object.object)"
    $rows = _ImpactRead -Destination $Destination -Table 'E071' -Where "OBJECT EQ '$obj' AND OBJ_NAME EQ '$name'" -Fields @('TRKORR','PGMID','OBJECT','OBJ_NAME')
    $trs = @(@($rows) | ForEach-Object { "$($_.TRKORR)" } | Where-Object { $_ } | Select-Object -Unique)
    $out = @()
    foreach ($tr in $trs) {
        $h = _ImpactRead -Destination $Destination -Table 'E070' -Where "TRKORR EQ '$tr'" -Fields @('TRKORR','TRSTATUS','AS4USER','AS4DATE')
        $r0 = @($h)[0]
        if ($r0) {
            $out += [pscustomobject]@{ trkorr = $tr; owner = "$($r0.AS4USER)"; date = "$($r0.AS4DATE)"; status = "$($r0.TRSTATUS)" }
        } else {
            $out += [pscustomobject]@{ trkorr = $tr; owner = ''; date = ''; status = '' }
        }
    }
    return $out
}

# =============================================================================
# Main - guarded so the pure functions above are dot-source testable.
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Host "ERROR: -Token is required (e.g. -Token 'PROGRAM ZMMR001' or -Token 'TABLE ZMM_ORDER')."
        Write-Host "IMPACT: object= risk=ERROR reverse=0 forward=0 runtime=0 trs=0"
        exit 1
    }
    if ($Depth -gt 1) { Write-Host "WARN: -Depth $Depth requested; MVP computes depth 1 (direct dependencies). Transitive is Phase 2." }

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $User -Password $Password -Language $Language `
                             -DestName "SAPDEV_IMPACT"
    if (-not $g_dest) { Write-Host "IMPACT: object= risk=ERROR reverse=0 forward=0 runtime=0 trs=0"; exit 2 }

    try {
        $effClient = if ($Client) { $Client } else { "$g_sapClient" }
        $obj = Resolve-SapObject -Destination $g_dest -Token $Token -TypeHint $TypeHint -Client $effClient

        # TCODE -> analyse the underlying program.
        if ($obj -is [array]) {
            $prog = $obj | Where-Object { "$($_.object)" -eq 'PROG' } | Select-Object -First 1
            $obj = if ($prog) { $prog } else { $obj[0] }
        }
        if (-not $obj -or -not $obj.exists) {
            Write-Host "ERROR: object not resolved / not found for token '$Token'."
            Write-Host "IMPACT: object=$(Get-SapObjLabel $obj) risk=ERROR reverse=0 forward=0 runtime=0 trs=0"
            Disconnect-SapRfc; exit 1
        }
        if ("$($obj.resolved_via)" -eq 'AMBIGUOUS') {
            Write-Host "ERROR: '$Token' is ambiguous ($($obj.note)); pass a type, e.g. -TypeHint TABLE."
            Disconnect-SapRfc; exit 1
        }

        $script:CouldNot = @()
        $reverse  = @(Get-SapReverseDeps -Destination $g_dest -Object $obj)
        $forward  = @(Get-SapForwardDeps -Destination $g_dest -Object $obj)
        $runtime  = @(Get-SapRuntimeEntryPoints -Destination $g_dest -Object $obj)
        $transports = @(Get-SapTransportHistory -Destination $g_dest -Object $obj)
        $couldNot = @($script:CouldNot | Select-Object -Unique)

        $pkg = "$($obj.package)"
        $isStandard = -not ($obj.obj_name -match '^[ZY]' -or $pkg -match '^[ZY$]')

        $findings = @(Get-SapImpactRiskFindings -ReverseCount $reverse.Count -ForwardCount $forward.Count `
                        -RuntimeCount $runtime.Count -IsStandard $isStandard -Object $obj `
                        -HighFanout $HighFanout -MedFanout $MedFanout -CouldNotCheck $couldNot)
        $band = Get-SapImpactBand -Findings $findings

        # --- Outputs + artifact registration ---------------------------------
        $scope = New-SapScopeKey -Resolved $obj
        if ($OutputDir) {
            if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
            $dir = $OutputDir
        } else {
            $dir = Get-SapArtifactDir -ScopeKey $scope -Skill 'sap-impact-analysis' -RunId $RunId
        }
        $nm = "$($obj.obj_name)" -replace '[^A-Za-z0-9_]', '_'

        $revTsv = Write-SapRelTsv -Rels $reverse  -Path (Join-Path $dir "${nm}_reverse_dependencies.tsv")
        $fwdTsv = Write-SapRelTsv -Rels $forward  -Path (Join-Path $dir "${nm}_dependencies.tsv")
        $rtTsv  = Write-SapRelTsv -Rels $runtime  -Path (Join-Path $dir "${nm}_runtime_entrypoints.tsv")
        # transport tsv
        $tsb = New-Object System.Text.StringBuilder
        [void]$tsb.AppendLine("trkorr`towner`tdate`tstatus")
        foreach ($t in $transports) { [void]$tsb.AppendLine("$($t.trkorr)`t$($t.owner)`t$($t.date)`t$($t.status)") }
        [System.IO.File]::WriteAllText((Join-Path $dir "${nm}_transport_history.tsv"), $tsb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        $trTsv = (Join-Path $dir "${nm}_transport_history.tsv")

        $riskTsv  = Export-SapFindingsTsv  -Findings $findings -Path (Join-Path $dir "${nm}_risk_findings.tsv")  -Scope $scope -Status 'CHECKED_FINDINGS'
        $riskJson = Export-SapFindingsJson -Findings $findings -Path (Join-Path $dir "${nm}_risk_findings.json") -Scope $scope -Status 'CHECKED_FINDINGS'

        $md = Build-SapImpactMarkdown -Object $obj -Band $band -Reverse $reverse -Forward $forward -Runtime $runtime -Transports $transports -Findings $findings -CouldNotCheck $couldNot
        $reportMd = Join-Path $dir "${nm}_impact.md"
        [System.IO.File]::WriteAllText($reportMd, $md, (New-Object System.Text.UTF8Encoding($false)))

        $cov = if ($couldNot.Count) { 'COULD_NOT_CHECK' } else { 'CHECKED_FINDINGS' }
        Register-SapArtifact -Skill 'sap-impact-analysis' -ScopeKey $scope -Object $obj -Kind 'impact_report'         -Format 'md'   -Path $reportMd -Coverage $cov -RunId $RunId -System "$($obj.system)" -Client $effClient | Out-Null
        Register-SapArtifact -Skill 'sap-impact-analysis' -ScopeKey $scope -Object $obj -Kind 'reverse_dependencies'  -Format 'tsv'  -Path $revTsv -Rows $reverse.Count -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-impact-analysis' -ScopeKey $scope -Object $obj -Kind 'dependencies'          -Format 'tsv'  -Path $fwdTsv -Rows $forward.Count -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-impact-analysis' -ScopeKey $scope -Object $obj -Kind 'runtime_entrypoints'   -Format 'tsv'  -Path $rtTsv  -Rows $runtime.Count -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-impact-analysis' -ScopeKey $scope -Object $obj -Kind 'transport_history'     -Format 'tsv'  -Path $trTsv  -Rows $transports.Count -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-impact-analysis' -ScopeKey $scope -Object $obj -Kind 'risk_findings'         -Format 'tsv'  -Path $riskTsv -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-impact-analysis' -ScopeKey $scope -Object $obj -Kind 'risk_findings'         -Format 'json' -Path $riskJson -RunId $RunId | Out-Null

        Write-Host ("IMPACT: object={0} risk={1} reverse={2} forward={3} runtime={4} trs={5}" -f (Get-SapObjLabel $obj), $band, $reverse.Count, $forward.Count, $runtime.Count, $transports.Count)
        if ($couldNot.Count) { Write-Host "PARTIAL: could_not_check=$(( $couldNot ) -join ',')" }
        Write-Host "REPORT_MD: $reportMd"
        Write-Host "REVERSE_TSV: $revTsv"
        Write-Host "FORWARD_TSV: $fwdTsv"
        Write-Host "RUNTIME_TSV: $rtTsv"
        Write-Host "TRANSPORT_TSV: $trTsv"
        Write-Host "RISK_TSV: $riskTsv"
        Write-Host "RISK_JSON: $riskJson"

        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        Write-Host "IMPACT: object=$Token risk=ERROR reverse=0 forward=0 runtime=0 trs=0"
        Disconnect-SapRfc
        exit 2
    }
}
