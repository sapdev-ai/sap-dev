# =============================================================================
# sap_spau_classify.ps1  -  Offline deterministic SPAU/SPDD triage classifier
#
# NO RFC, NO SAP. Joins the evidence TSVs produced by sap_spau_rfc.ps1 and
# applies the fixed rule table below via a strict precedence, emitting
# spau_triage.tsv. The class / confidence / coverage of each entry is
# deterministic (never depends on LLM mood) -- Claude writes the per-entry
# rationale PROSE and (--deep) diff commentary on top of this baseline.
#
# Rule precedence (first match wins):
#   R1 reset-candidate HIGH  : versions evidence equal_source=Y (customer active
#                              source == newest standard version, SVRS hash match)
#   R2 reset-candidate LOW   : note-based mod AND note status = completed
#                              (semantics=ADVISORY -- never rests on note alone)
#   R6 unclear               : conflicting evidence (reset signal + fresh access key)
#   R3 adopt MEDIUM          : modification-assistant change, keep + re-apply
#      (adopt LOW            : note-based mod, reset signal unverified)
#   R4 re-implement MEDIUM   : exit-adjacent / enhancement-spot object (routed v1.5)
#   R5 unclear COULD_NOT_CHECK: no/unreadable version evidence, unknown type
#
# Inputs:
#   -WorklistTsv <path>   (required)  rows from sap_spau_rfc.ps1 -Action worklist
#   -NotesTsv <path>      (optional)  kind\tnum\tstatus (or the NOTE: lines parsed to tsv)
#   -VersionsTsv <path>   (optional)  obj_type\tobj_name\tequal_source(Y/N)\tnumbered
#   -OutFile <path>       (required)  spau_triage.tsv
# Exit: 0 = ran, 2 = input error.
# =============================================================================

[CmdletBinding()]
param(
    [string] $WorklistTsv = '',
    [string] $NotesTsv = '',
    [string] $VersionsTsv = '',
    [string] $OutFile = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Load-Tsv([string]$path) {
    $rows = @()
    if (-not $path -or -not (Test-Path $path)) { return $rows }
    $lines = [System.IO.File]::ReadAllLines($path)
    if ($lines.Count -lt 1) { return $rows }
    $hdr = $lines[0] -split "`t"
    for ($i=1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '') { continue }
        $c = $lines[$i] -split "`t"
        $h = [ordered]@{}; for ($k=0; $k -lt $hdr.Count; $k++) { $h[$hdr[$k]] = if ($k -lt $c.Count) { $c[$k] } else { '' } }
        $rows += [pscustomobject]$h
    }
    return $rows
}

# enhancement-relevant object types (R4 pre-signal, structural not semantic)
$ENHANCE_TYPES = @{ 'FUGR'=1; 'FUNC'=1 }   # function-exit-adjacent; refined by /sap-enhancement-advisor in route mode

function Get-EffortBand($objType, [int]$rows) {
    $t = "$objType".ToUpper()
    if ($t -in @('TABD','TABL','VIEW','DTEL','DOMA')) { return 'M' }   # DDIC/SPDD side
    if ($rows -gt 10) { return 'L' }
    if ($rows -ge 3)  { return 'M' }
    return 'S'
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $WorklistTsv -or -not (Test-Path $WorklistTsv)) { Write-Host "STATUS: INPUT_ERROR reason=worklist_required"; exit 2 }
    if (-not $OutFile) { Write-Host "STATUS: INPUT_ERROR reason=outfile_required"; exit 2 }

    $work = Load-Tsv $WorklistTsv
    $notes = Load-Tsv $NotesTsv
    $vers  = Load-Tsv $VersionsTsv

    # note status index: num -> status (completed/... )
    $noteStatus = @{}
    foreach ($n in $notes) { $num = "$($n.num)".TrimStart('0'); if ($num) { $noteStatus[$num] = "$($n.status)" } }
    # versions index: obj_name -> equal_source
    $verIdx = @{}
    foreach ($v in $vers) { if ("$($v.obj_name)") { $verIdx["$($v.obj_name)".ToUpper()] = "$($v.equal_source)".ToUpper() } }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("obj_type`tobj_name`tpackage`tsmodilog_rows`tlast_mod_user`tlast_mod_date`taccess_key`tversions`tnote_refs`tclass`tconfidence`teffort_band`tcoverage`trationale")
    $counts = @{ 'reset-candidate'=0; 'adopt'=0; 're-implement'=0; 'unclear'=0 }

    foreach ($w in $work) {
        $ot = "$($w.obj_type)".ToUpper(); $on = "$($w.obj_name)".ToUpper()
        $ops = "$($w.operations)".ToUpper()
        $rows = 0; [int]::TryParse("$($w.smodilog_rows)", [ref]$rows) | Out-Null
        $ak = "$($w.access_key)".Trim()
        $recentAk = ($ak -ne '')
        $isNote = ($ops -match 'NOTE')
        $equalSrc = if ($verIdx.ContainsKey($on)) { $verIdx[$on] } else { '' }
        $verKnown = ($equalSrc -ne '')
        # R2 needs a PRECISE per-object note linkage: only NOTE_<n> objects carry
        # their note number in the name. A note-modified CLAS cannot be tied to a
        # completed note from the worklist alone -> it stays adopt/COULD_NOT_CHECK.
        $objNoteNum = if ($on -match 'NOTE_0*(\d+)') { $matches[1] } else { '' }
        $objNoteDone = ($objNoteNum -and $noteStatus.ContainsKey($objNoteNum) -and $noteStatus[$objNoteNum] -match 'complete|COMPLET|done')

        $class=''; $conf=''; $cov='CHECKED'; $why=''
        # R6 conflict (checked BEFORE R1): a reset signal AND an access-key registration
        if ($equalSrc -eq 'Y' -and $recentAk) {
            $class='unclear'; $conf=''; $why='conflicting evidence: source-equal reset signal but an access-key registration exists - inspect manually before resetting'
        }
        # R1 clean reset
        elseif ($equalSrc -eq 'Y') {
            $class='reset-candidate'; $conf='HIGH'; $why='active customer source equals newest standard version (SVRS hash match) - the modification is redundant'
        }
        # R2 (this object's own note is completed)
        elseif ($isNote -and $objNoteDone) {
            $class='reset-candidate'; $conf='LOW'; $why="note $objNoteNum is completed in CWBNTCUST (semantics=ADVISORY; verify in SPAU before resetting)"
        }
        # R4 enhancement-adjacent
        elseif ($ENHANCE_TYPES.ContainsKey($ot)) {
            $class='re-implement'; $conf='MEDIUM'; $why='function-group object may expose an enhancement option; route to /sap-enhancement-advisor (v1.5) before adopting'
        }
        # R3 modification-assistant change / note-unverified adopt
        elseif ($isNote) {
            $class='adopt'; $conf='LOW'; $why='note-based modification; reset signal not verified (note status not downloaded) - adopt pending SPAU review'; if (-not $verKnown) { $cov='COULD_NOT_CHECK' }
        }
        elseif ($ops -ne '') {
            $class='adopt'; $conf='MEDIUM'; $why="modification-assistant change (operation=$ops); adopt and re-apply on the target release"
        }
        # R5 fallthrough
        else {
            $class='unclear'; $conf=''; $cov='COULD_NOT_CHECK'; $why='no version evidence and unrecognized operation - cannot classify without --deep'
        }

        if (-not $verKnown -and $class -eq 'reset-candidate' -and $conf -eq 'HIGH') { $cov='COULD_NOT_CHECK' }  # defensive: never HIGH reset without version proof
        if ($counts.ContainsKey($class)) { $counts[$class]++ }
        $verStr = if ($verKnown) { "equal_source=$equalSrc" } else { 'not-fetched' }
        $out.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}`t{10}`t{11}`t{12}`t{13}" -f `
            $ot, $on, "$($w.package)", $rows, "$($w.last_mod_user)", "$($w.last_mod_date)", $ak, $verStr, "$($w.trkorrs)", $class, $conf, (Get-EffortBand $ot $rows), $cov, $why))
    }

    [System.IO.File]::WriteAllText($OutFile, ($out -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "TRIAGE_TSV: $OutFile"
    Write-Host ("TRIAGE: reset=$($counts['reset-candidate']) adopt=$($counts['adopt']) reimplement=$($counts['re-implement']) unclear=$($counts['unclear'])")
    Write-Host "STATUS: OK"
    exit 0
}
