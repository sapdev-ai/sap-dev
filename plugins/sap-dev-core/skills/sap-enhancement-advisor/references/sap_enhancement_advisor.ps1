# =============================================================================
# sap_enhancement_advisor.ps1  -  Find the safest extension point (RFC, NCo 3.1)
#
# "Where should I implement this SAP behavior change?" Enumerates the enhancement
# options around a context, classifies each, detects existing customer
# implementations, scores them with a TRANSPARENT heuristic (released enhancement
# interface > BAdI > exit > implicit; avoid standard modification), and
# recommends the safest - producing a fact-based plan. Complements /sap-se19
# (which IMPLEMENTS a BAdI): this skill DECIDES which mechanism to use.
#
# Three modes (auto-detected from the token / resolver):
#   BADI <name>        inspect one BAdI / enhancement spot - classify
#                      classic/new/migrated + list implementations (reuses the
#                      sap-se19 table knowledge).
#   ENHANCEMENT <name> inspect one SMOD enhancement - components (MODSAP) +
#                      CMOD projects using it (MODACT/MODATTR).
#   PROGRAM/TCODE <x>  enumerate candidates for a program: enhancement spots /
#                      implementations in its package (TADIR ENHS/ENHO), BAdIs
#                      it references (cross-reference index), and user-exit
#                      includes (D010INC convention). BEST-EFFORT + honest about
#                      being non-exhaustive (SE84 is the exhaustive tool).
#
# Tables (all RFC_READ_TABLE-safe; REPOSRC never touched):
#   SXS_ATTR SXC_EXIT SXC_ATTR SXC_CLASS BADI_IMPL   (BAdIs)
#   MODSAP MODACT MODATTR MODTEXT                    (SMOD/CMOD)
#   TADIR(ENHS/ENHO) D010INC WBCROSSGT               (program enumeration)
#
# IMPORTANT - INTENT IS ADVISORY: the optional -Intent string is echoed but the
# ranking is STRUCTURAL/heuristic. It does NOT semantically match your intent to
# a method. Always verify the recommended interface's signature exposes the data
# you need. The dynamic-call + non-exhaustive caveats are disclosed in the report.
#
# Reuses Phase-0 primitives: sap_object_resolver, sap_finding_lib, sap_artifact_lib.
# Read-only. 32-bit PowerShell. Creds fall back to the pinned profile.
#
# Output (stdout):
#   ADVISOR: context=<O:N> mode=<BADI|SMOD|PROGRAM> candidates=<n> recommended=<name> rectype=<ctype>
#   REPORT_MD / CANDIDATES_TSV / IMPLEMENTATIONS_TSV / RISK_TSV / RISK_JSON: <path>
# Exit: 0 ok - 1 context not found - 2 RFC failure.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Token = '',
    [string] $Intent = '',
    [string] $TypeHint = '',
    [string] $SharedDir = '',
    [string] $OutputDir = '',
    [int] $MaxIncludeScan = 200,
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
# Dot-sourcing it resets our identically named params to defaults (the dot-source
# param-clobber gotcha). Snapshot the colliding params, dot-source, then restore.
$__keep = @{ Token=$Token; TypeHint=$TypeHint; Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; User=$User; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1','sap_finding_lib.ps1','sap_artifact_lib.ps1') {
    $p = Join-Path $scripts $lib
    if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

$script:AdvCouldNot = @()

# =============================================================================
# PURE functions - offline-testable.
# =============================================================================

# Transparent base score per candidate type. Higher = safer / more standard.
$script:SapCtypeScore = @{
    NEW_BADI = 100; CLASSIC_BADI = 80; ENH_SPOT = 70; ENH_IMPL = 60
    SMOD_EXIT = 50; SCREEN_EXIT = 45; USER_EXIT = 30; IMPLICIT = 20; STANDARD_MOD = 5
}

function New-SapCandidate {
    param(
        [string] $Name, [string] $Ctype, [int] $ExistingImpls = 0, [int] $ActiveImpls = 0,
        [string] $Detail = '', [string] $Source = '', [string] $Note = ''
    )
    $score = $script:SapCtypeScore["$Ctype".ToUpper()]
    if (-not $score) { $score = 10 }
    return [pscustomobject][ordered]@{
        name = $Name; ctype = "$Ctype".ToUpper(); existing_impls = $ExistingImpls; active_impls = $ActiveImpls
        score = $score; detail = $Detail; source = $Source; note = $Note
    }
}

# Pick the recommended candidate: highest score, NEW_BADI breaks ties.
function Get-SapRecommendation {
    param([object[]] $Candidates = @())
    if (-not $Candidates -or @($Candidates).Count -eq 0) { return $null }
    $sorted = @($Candidates | Sort-Object -Property `
        @{ Expression = { [int]$_.score }; Descending = $true }, `
        @{ Expression = { if ("$($_.ctype)" -eq 'NEW_BADI') { 1 } else { 0 } }; Descending = $true })
    return $sorted[0]
}

function Get-SapAdvisorRiskFindings {
    param([object[]] $Candidates = @(), $Recommended, $Context, [string[]] $CouldNotCheck = @())
    $out = @()
    if (-not $Recommended -or "$($Recommended.ctype)" -eq 'STANDARD_MOD') {
        $out += (New-SapFinding -Severity MEDIUM -Category STANDARD_MODIFICATION_RISK -Object $Context -Source TADIR `
                    -Detail "No clean enhancement point was found - the fallback is to modify / copy standard, which is high upgrade risk." `
                    -Remediation "Search SE84/SE81 for an enhancement option before modifying standard; consider an explicit enhancement point.")
    }
    foreach ($c in $Candidates) {
        if ([int]$c.active_impls -gt 1) {
            $out += (New-SapFinding -Severity MEDIUM -Category MULTIPLE_ACTIVE_IMPL -Source SXC_ATTR `
                        -Detail "$($c.name) has $($c.active_impls) active implementations - call order may be undefined." `
                        -Remediation "Confirm the implementations are filter-disjoint or ordered before adding another.")
        }
        if ("$($c.note)" -match 'migrated') {
            $out += (New-SapFinding -Severity INFO -Category OBSOLETE_MIGRATED -Source SXS_ATTR `
                        -Detail "$($c.name) is a migrated classic BAdI - a new-BAdI face exists." `
                        -Remediation "Prefer the new BAdI / enhancement spot over the classic face.")
        }
    }
    foreach ($t in ($CouldNotCheck | Select-Object -Unique)) {
        $out += (New-SapFinding -Severity MEDIUM -Category ADVISOR_PARTIAL -Object $Context -Coverage COULD_NOT_CHECK -Source $t `
                    -Detail "Could not read $t (auth / RFC) - candidate enumeration is INCOMPLETE." `
                    -Remediation "Re-run with table-read authorization for $t, or use SE84 for the exhaustive list.")
    }
    return $out
}

function Build-SapAdvisorMarkdown {
    param(
        $Context, [string] $Mode, [string] $Intent, [object[]] $Candidates = @(), $Recommended,
        [object[]] $Impls = @(), [object[]] $Findings = @(), [string[]] $CouldNotCheck = @()
    )
    $label = (& { if ("$($Context.obj_name)") { if ("$($Context.object)") { "$($Context.object):$($Context.obj_name)" } else { "$($Context.obj_name)" } } else { "$($Context)" } })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# Enhancement advisor - $label")
    [void]$sb.AppendLine("")
    if ($Intent) { [void]$sb.AppendLine("**Intent:** $Intent") }
    [void]$sb.AppendLine("**Mode:** $Mode  |  candidates: $($Candidates.Count)")
    [void]$sb.AppendLine("")
    if ($Recommended) {
        [void]$sb.AppendLine("## Recommended: $($Recommended.ctype) $($Recommended.name)")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("- score $($Recommended.score) (transparent base score by mechanism type)")
        if ($Recommended.detail) { [void]$sb.AppendLine("- $($Recommended.detail)") }
        if ([int]$Recommended.existing_impls -gt 0) {
            [void]$sb.AppendLine("- $($Recommended.existing_impls) existing implementation(s), $($Recommended.active_impls) active - decide EXTEND vs CREATE (ask the user; do NOT auto-suffix-bump a new name).")
        }
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("> NOTE: ranking is STRUCTURAL/heuristic. It does NOT semantically match your intent to a method signature - verify the recommended interface actually exposes the data you need.")
    if ($Mode -eq 'PROGRAM') {
        [void]$sb.AppendLine(">")
        [void]$sb.AppendLine("> NOTE: program-level enumeration is NOT exhaustive (SE84/SE81 is). Implicit enhancements and dynamically-called BAdIs are not listed.")
    }
    if ($CouldNotCheck.Count) {
        [void]$sb.AppendLine(">")
        [void]$sb.AppendLine("> Incomplete: could not read $(( $CouldNotCheck | Select-Object -Unique ) -join ', ').")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Candidates ($($Candidates.Count))")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| candidate | type | score | existing | active | source |")
    [void]$sb.AppendLine("|---|---|---|---|---|---|")
    foreach ($c in (@($Candidates) | Sort-Object -Property @{ Expression = { [int]$_.score }; Descending = $true })) {
        [void]$sb.AppendLine("| $($c.name) | $($c.ctype) | $($c.score) | $($c.existing_impls) | $($c.active_impls) | $($c.source) |")
    }
    [void]$sb.AppendLine("")
    if ($Impls.Count) {
        [void]$sb.AppendLine("## Existing implementations ($($Impls.Count))")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| of | impl | kind | class | active |")
        [void]$sb.AppendLine("|---|---|---|---|---|")
        foreach ($i in $Impls) { [void]$sb.AppendLine("| $($i.of) | $($i.impl) | $($i.kind) | $($i.class) | $($i.active) |") }
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("## Next steps")
    if ($Recommended) {
        switch -Wildcard ("$($Recommended.ctype)") {
            '*BADI*'  { [void]$sb.AppendLine("1. Confirm EXTEND an existing impl vs CREATE a new one (ask).") ; [void]$sb.AppendLine("2. ``/sap-se19`` to create/inspect the implementation.") }
            'SMOD_EXIT' { [void]$sb.AppendLine("1. ``/sap-cmod`` to assign + edit the SMOD enhancement, then activate the project.") }
            'USER_EXIT' { [void]$sb.AppendLine("1. Edit the customer include via ``/sap-se38`` (paste needs SAP GUI foreground).") }
            default     { [void]$sb.AppendLine("1. Review the candidate in SE84/SE18 before implementing.") }
        }
        [void]$sb.AppendLine("3. ``/sap-impact-analysis`` on any active implementation before changing behavior.")
    } else {
        [void]$sb.AppendLine("- No enhancement candidate found. Search SE84/SE81; avoid modifying standard.")
    }
    return $sb.ToString()
}

# =============================================================================
# RFC layer - graceful ($null read -> $script:AdvCouldNot). Plain returns.
# =============================================================================
function _AdvRead {
    param($Destination, [string] $Table, [string] $Where, [string[]] $Fields)
    $rows = Read-SapTableRows -Destination $Destination -Table $Table -Where $Where -Fields $Fields
    # Return @() (never $null) on failure so @($r).Count is a reliable 0 - otherwise
    # @($null).Count is 1 and a FAILED read looks like a found row.
    if ($null -eq $rows) { $script:AdvCouldNot += $Table; return @() }
    return $rows
}

# BAdI inspection: classify + list implementations.
function Get-SapBadiInfo {
    param($Destination, [string] $Name)
    $classicDef = $false; $newSpot = $false; $migrated = $false; $defClass = ''
    $r = _AdvRead $Destination 'SXS_ATTR' "EXIT_NAME EQ '$Name'" @('EXIT_NAME','MIG_ENHSPOTNAME','MIG_BADI_NAME','DEF_CLNAME')
    if (@($r).Count) {
        $defClass = "$(@($r)[0].DEF_CLNAME)"
        if ("$(@($r)[0].MIG_BADI_NAME)" -or "$(@($r)[0].MIG_ENHSPOTNAME)") { $migrated = $true } else { $classicDef = $true }
    }
    $r = _AdvRead $Destination 'TADIR' "PGMID = 'R3TR' AND OBJECT = 'ENHS' AND OBJ_NAME = '$Name'" @('OBJ_NAME')
    if (@($r).Count) { $newSpot = $true }

    $impls = @()
    $r = _AdvRead $Destination 'BADI_IMPL' "BADI_NAME EQ '$Name'" @('BADI_NAME','ENHNAME','BADI_IMPL','CLASS_NAME')
    foreach ($x in @($r)) { if ("$($x.BADI_IMPL)") { $impls += [pscustomobject]@{ of=$Name; impl="$($x.BADI_IMPL)"; kind='NEW'; class="$($x.CLASS_NAME)"; active='unknown' } } }
    # Classic implementations: SXC_CLASS keyed by the conventional BAdI interface
    # IF_EX_<name> (verified tables; only meaningful when there is a classic face).
    if ($classicDef -or $migrated) {
        $iface = "IF_EX_$Name"
        $cl = _AdvRead $Destination 'SXC_CLASS' "INTER_NAME EQ '$iface'" @('IMP_NAME','INTER_NAME','IMP_CLASS')
        foreach ($x in @($cl)) {
            $imp = "$($x.IMP_NAME)"; if (-not $imp) { continue }
            $a = _AdvRead $Destination 'SXC_ATTR' "IMP_NAME EQ '$imp'" @('IMP_NAME','ACTIVE')
            $act = if (@($a).Count) { if ("$(@($a)[0].ACTIVE)" -in @('X','A','1')) { 'active' } else { 'inactive' } } else { 'unknown' }
            $impls += [pscustomobject]@{ of=$Name; impl=$imp; kind='CLASSIC'; class="$($x.IMP_CLASS)"; active=$act }
        }
    }
    $type = if ($classicDef -and ($newSpot -or $migrated)) { 'AMBIGUOUS' } elseif ($classicDef) { 'CLASSIC' } elseif ($newSpot -or $migrated -or @($impls).Count) { 'NEW' } else { 'UNKNOWN' }
    return [pscustomobject]@{ name=$Name; type=$type; migrated=$migrated; def_class=$defClass; impls=@($impls) }
}

# SMOD enhancement inspection: components + CMOD projects.
function Get-SapSmodInfo {
    param($Destination, [string] $Name)
    $comps = @()
    $r = _AdvRead $Destination 'MODSAP' "NAME EQ '$Name'" @('NAME','TYP','MEMBER')
    foreach ($x in @($r)) { if ("$($x.MEMBER)") { $comps += [pscustomobject]@{ typ="$($x.TYP)"; member="$($x.MEMBER)" } } }
    $projects = @()
    $r = _AdvRead $Destination 'MODACT' "MEMBER LIKE '$Name%'" @('NAME','MEMBER')
    $pn = @(@($r) | ForEach-Object { "$($_.NAME)" } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($p in $pn) {
        $a = _AdvRead $Destination 'MODATTR' "NAME EQ '$p'" @('NAME','STATUS')
        $st = if (@($a).Count) { "$(@($a)[0].STATUS)" } else { '' }
        $projects += [pscustomobject]@{ project=$p; active=(& { if ($st -eq 'A') { 'active' } else { 'inactive' } }) }
    }
    return [pscustomobject]@{ name=$Name; components=@($comps); projects=@($projects) }
}

# Program enumeration (best-effort, non-exhaustive).
function Get-SapProgramCandidates {
    param($Destination, $Object, [int] $MaxScan = 200)
    $name = "$($Object.obj_name)"; $pkg = "$($Object.package)"
    $cands = @()

    # Enhancement spots / impls in the program's package.
    if ($pkg) {
        $r = _AdvRead $Destination 'TADIR' "PGMID = 'R3TR' AND OBJECT = 'ENHS' AND DEVCLASS = '$pkg'" @('OBJ_NAME','OBJECT')
        foreach ($x in @($r)) { if ("$($x.OBJ_NAME)") { $cands += (New-SapCandidate -Name "$($x.OBJ_NAME)" -Ctype ENH_SPOT -Detail "enhancement spot in package $pkg" -Source 'TADIR ENHS') } }
        $r = _AdvRead $Destination 'TADIR' "PGMID = 'R3TR' AND OBJECT = 'ENHO' AND DEVCLASS = '$pkg'" @('OBJ_NAME','OBJECT')
        foreach ($x in @($r)) { if ("$($x.OBJ_NAME)") { $cands += (New-SapCandidate -Name "$($x.OBJ_NAME)" -Ctype ENH_IMPL -ExistingImpls 1 -Detail "existing enhancement implementation in package $pkg" -Source 'TADIR ENHO') } }
    }

    # BAdIs the program references (cross-reference index), + user-exit includes.
    $inc = _AdvRead $Destination 'D010INC' "MASTER EQ '$name'" @('MASTER','INCLUDE')
    $includes = @(@($inc) | ForEach-Object { "$($_.INCLUDE)" } | Where-Object { $_ } | Select-Object -Unique)
    $includes += $name
    foreach ($ic in (@($includes) | Select-Object -Unique)) {
        if ($ic -eq $name) { continue }   # the program itself is not a user-exit include
        # user-exit / customer include conventions
        if ($ic -match '^[ZY]' -or $ic -match 'FZZ$' -or $ic -match 'EXIT') {
            $cands += (New-SapCandidate -Name $ic -Ctype USER_EXIT -Detail "customer / user-exit include in the program" -Source 'D010INC')
        }
    }
    $scanned = 0
    foreach ($ic in (@($includes) | Select-Object -Unique)) {
        if ($scanned -ge $MaxScan) { Write-Host "WARN: include scan capped at $MaxScan; BAdI-reference enumeration is partial."; break }
        $wb = _AdvRead $Destination 'WBCROSSGT' "INCLUDE EQ '$ic'" @('OTYPE','NAME','INCLUDE')
        foreach ($x in @($wb)) {
            $sym = "$($x.NAME)"; if (-not $sym) { continue }
            if ($sym -match '[\\:\s]') { continue }   # compound member ref (CLASS\DA:ATTR) - not a BAdI name
            # is the referenced symbol a BAdI definition?
            $sx = _AdvRead $Destination 'SXS_ATTR' "EXIT_NAME EQ '$sym'" @('EXIT_NAME')
            if (@($sx).Count) { $cands += (New-SapCandidate -Name $sym -Ctype CLASSIC_BADI -Detail "classic BAdI referenced by the program" -Source 'WBCROSSGT->SXS_ATTR'); continue }
            $ts = _AdvRead $Destination 'TADIR' "PGMID = 'R3TR' AND OBJECT = 'ENHS' AND OBJ_NAME = '$sym'" @('OBJ_NAME')
            if (@($ts).Count) { $cands += (New-SapCandidate -Name $sym -Ctype NEW_BADI -Detail "new BAdI / enhancement spot referenced by the program" -Source 'WBCROSSGT->TADIR ENHS') }
        }
        $scanned++
    }

    # de-dup by name+ctype
    $seen = @{}; $dedup = @()
    foreach ($c in $cands) { $k = "$($c.name)|$($c.ctype)"; if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $dedup += $c } }
    if ($dedup.Count -eq 0) { $dedup += (New-SapCandidate -Name $name -Ctype STANDARD_MOD -Detail "no enhancement option found via tables - SE84 recommended" -Source 'none') }
    return $dedup
}

# =============================================================================
# Main - guarded so pure functions are dot-source testable.
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Host "ERROR: -Token is required (e.g. -Token 'TCODE ME21N' or -Token 'BADI ME_PROCESS_PO_CUST')."
        Write-Host "ADVISOR: context= mode= candidates=0 recommended= rectype="
        exit 1
    }

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $User -Password $Password -Language $Language `
                             -DestName "SAPDEV_ADVISOR"
    if (-not $g_dest) { Write-Host "ADVISOR: context= mode= candidates=0 recommended= rectype="; exit 2 }

    try {
        $effClient = if ($Client) { $Client } else { "$g_sapClient" }
        $script:AdvCouldNot = @()

        # --- detect mode + context -------------------------------------------
        $raw = $Token.Trim() -replace '\s+', ' '
        $kw = ''; $nm = $raw
        if ($raw -match '^(\S+)\s+(\S.*)$') { $kw = $matches[1].ToUpper(); $nm = $matches[2].Trim() }
        $nm = $nm.ToUpper()

        $mode = ''; $context = $null; $candidates = @(); $impls = @(); $recommended = $null

        if ($kw -in @('BADI','ENHANCEMENT-SPOT','ENHSPOT','SPOT')) {
            $mode = 'BADI'
            $info = Get-SapBadiInfo -Destination $g_dest -Name $nm
            $context = [pscustomobject]@{ pgmid='R3TR'; object='ENHS'; obj_name=$nm; package=''; system=(Get-SapResolverSysId -Destination $g_dest); client=$effClient }
            $active = @($info.impls | Where-Object { "$($_.active)" -eq 'active' }).Count
            $ctype = if ($info.type -eq 'CLASSIC') { 'CLASSIC_BADI' } else { 'NEW_BADI' }
            $candidates = @( New-SapCandidate -Name $nm -Ctype $ctype -ExistingImpls @($info.impls).Count -ActiveImpls $active -Detail "$($info.type) BAdI$(if($info.migrated){' (migrated)'})" -Source 'SXS_ATTR/BADI_IMPL' -Note (& { if ($info.migrated) { 'migrated' } else { '' } }) )
            $impls = @($info.impls)
        }
        elseif ($kw -in @('ENHANCEMENT','SMOD','EXIT')) {
            $mode = 'SMOD'
            $info = Get-SapSmodInfo -Destination $g_dest -Name $nm
            $context = [pscustomobject]@{ pgmid='R3TR'; object='SMOD'; obj_name=$nm; package=''; system=(Get-SapResolverSysId -Destination $g_dest); client=$effClient }
            $activeProjects = @($info.projects | Where-Object { "$($_.active)" -eq 'active' }).Count
            $candidates = @( New-SapCandidate -Name $nm -Ctype SMOD_EXIT -ExistingImpls @($info.projects).Count -ActiveImpls $activeProjects -Detail "$(@($info.components).Count) component(s); used by $(@($info.projects).Count) CMOD project(s)" -Source 'MODSAP/MODACT' )
            foreach ($p in $info.projects) { $impls += [pscustomobject]@{ of=$nm; impl=$p.project; kind='CMOD_PROJECT'; class=''; active=$p.active } }
        }
        else {
            # PROGRAM / TCODE / bare -> resolve, then enumerate.
            $mode = 'PROGRAM'
            $resolved = Resolve-SapObject -Destination $g_dest -Token $Token -TypeHint $TypeHint -Client $effClient
            if ($resolved -is [array]) { $p = $resolved | Where-Object { "$($_.object)" -eq 'PROG' } | Select-Object -First 1; $resolved = if ($p) { $p } else { $resolved[0] } }
            if (-not $resolved -or -not $resolved.exists) {
                Write-Host "ERROR: context not resolved for token '$Token'."
                Write-Host "ADVISOR: context=$(if($resolved){$resolved.obj_name}) mode=PROGRAM candidates=0 recommended= rectype="
                Disconnect-SapRfc; exit 1
            }
            $context = $resolved
            $candidates = @(Get-SapProgramCandidates -Destination $g_dest -Object $resolved -MaxScan $MaxIncludeScan)
        }

        $recommended = Get-SapRecommendation -Candidates $candidates
        $couldNot = @($script:AdvCouldNot | Select-Object -Unique)
        $findings = @(Get-SapAdvisorRiskFindings -Candidates $candidates -Recommended $recommended -Context $context -CouldNotCheck $couldNot)

        # --- outputs + registration ------------------------------------------
        $scope = New-SapScopeKey -Resolved $context
        if ($OutputDir) { if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }; $dir = $OutputDir }
        else { $dir = Get-SapArtifactDir -ScopeKey $scope -Skill 'sap-enhancement-advisor' -RunId $RunId }
        $stem = "$($context.obj_name)" -replace '[^A-Za-z0-9_]', '_'

        # candidates tsv
        $csb = New-Object System.Text.StringBuilder
        [void]$csb.AppendLine("name`ttype`tscore`texisting_impls`tactive_impls`tsource`tdetail")
        foreach ($c in $candidates) { [void]$csb.AppendLine("$($c.name)`t$($c.ctype)`t$($c.score)`t$($c.existing_impls)`t$($c.active_impls)`t$($c.source)`t$($c.detail)") }
        $candTsv = Join-Path $dir "${stem}_candidates.tsv"
        [System.IO.File]::WriteAllText($candTsv, $csb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

        # implementations tsv
        $isb = New-Object System.Text.StringBuilder
        [void]$isb.AppendLine("of`timpl`tkind`tclass`tactive")
        foreach ($i in $impls) { [void]$isb.AppendLine("$($i.of)`t$($i.impl)`t$($i.kind)`t$($i.class)`t$($i.active)") }
        $implTsv = Join-Path $dir "${stem}_implementations.tsv"
        [System.IO.File]::WriteAllText($implTsv, $isb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

        $riskTsv  = Export-SapFindingsTsv  -Findings $findings -Path (Join-Path $dir "${stem}_risk_findings.tsv")  -Scope $scope -Status 'CHECKED_FINDINGS'
        $riskJson = Export-SapFindingsJson -Findings $findings -Path (Join-Path $dir "${stem}_risk_findings.json") -Scope $scope -Status 'CHECKED_FINDINGS'

        $md = Build-SapAdvisorMarkdown -Context $context -Mode $mode -Intent $Intent -Candidates $candidates -Recommended $recommended -Impls $impls -Findings $findings -CouldNotCheck $couldNot
        $reportMd = Join-Path $dir "${stem}_enhancement_advice.md"
        [System.IO.File]::WriteAllText($reportMd, $md, (New-Object System.Text.UTF8Encoding($false)))

        $cov = if ($couldNot.Count) { 'COULD_NOT_CHECK' } else { 'CHECKED_FINDINGS' }
        Register-SapArtifact -Skill 'sap-enhancement-advisor' -ScopeKey $scope -Object $context -Kind 'enhancement_advice' -Format 'md'   -Path $reportMd -Coverage $cov -RunId $RunId -System "$($context.system)" -Client $effClient | Out-Null
        Register-SapArtifact -Skill 'sap-enhancement-advisor' -ScopeKey $scope -Object $context -Kind 'candidates'         -Format 'tsv'  -Path $candTsv -Rows @($candidates).Count -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-enhancement-advisor' -ScopeKey $scope -Object $context -Kind 'existing_implementations' -Format 'tsv' -Path $implTsv -Rows @($impls).Count -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-enhancement-advisor' -ScopeKey $scope -Object $context -Kind 'risk_findings'      -Format 'tsv'  -Path $riskTsv -RunId $RunId | Out-Null
        Register-SapArtifact -Skill 'sap-enhancement-advisor' -ScopeKey $scope -Object $context -Kind 'risk_findings'      -Format 'json' -Path $riskJson -RunId $RunId | Out-Null

        $recName = if ($recommended) { $recommended.name } else { '' }
        $recType = if ($recommended) { $recommended.ctype } else { '' }
        Write-Host ("ADVISOR: context={0} mode={1} candidates={2} recommended={3} rectype={4}" -f (& { if ("$($context.object)") { "$($context.object):$($context.obj_name)" } else { "$($context.obj_name)" } }), $mode, @($candidates).Count, $recName, $recType)
        if ($couldNot.Count) { Write-Host "PARTIAL: could_not_check=$(( $couldNot ) -join ',')" }
        Write-Host "REPORT_MD: $reportMd"
        Write-Host "CANDIDATES_TSV: $candTsv"
        Write-Host "IMPLEMENTATIONS_TSV: $implTsv"
        Write-Host "RISK_TSV: $riskTsv"
        Write-Host "RISK_JSON: $riskJson"

        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        Write-Host "ADVISOR: context=$Token mode= candidates=0 recommended= rectype="
        Disconnect-SapRfc
        exit 2
    }
}
