# =============================================================================
# sap_guide_compose.ps1  -  harvest + compose for /sap-user-guide (LOCAL, no SAP)
#
# Stage 1 (harvest): parse a /sap-gui-probe run folder - step_NN_action.json
# (verb/target/value/note), step_NN_post.json (program/dynpro/sbar msgtype), and
# sap_gui_probe_run.json (tcode) - into a step table + the (table,field) token set
# extracted from the findById paths. Emits steps.tsv + fields_request.tsv (feed to
# sap_guide_ddic_texts.ps1).
#
# Stage 2 (compose): merge steps + guide_fields.tsv + screenshots into the guide.md
# SKELETON (header, per-step section with screenshot + field table). The
# business-language step PROSE is written by Claude on top - this assembles the
# skeleton + tables only. --uat additionally writes uat_<TXN>.tsv.
#
# -Action harvest | compose ; exit 0 ran, 1 GUIDE_INPUT_INVALID, 2 input error.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Action = 'harvest',
    [string] $RunFolder = '',
    [string] $FieldsTsv = '',       # guide_fields.tsv (compose)
    [string] $ScreensDir = '',      # screenshots dir (compose)
    [string] $Tcode = '',
    [string] $Lang = 'EN',
    [switch] $Uat,
    [string] $OutDir = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = (Get-Location).Path }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# (table,field) from a findById path like .../ctxtRMMG1-MATNR or .../txtVBAK-VBELN
function Extract-Field { param([string]$id)
    if ($id -match '(?:ctxt|txt|cmb|chk|rad)([A-Z0-9_/]+)-([A-Z0-9_]+)') { return @($matches[1].ToUpper(), $matches[2].ToUpper()) }
    return $null
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Action -eq 'harvest') {
        if (-not $RunFolder -or -not (Test-Path $RunFolder)) { Write-Host "STATUS: GUIDE_INPUT_INVALID detail=folder_missing"; exit 1 }
        $actionFiles = @(Get-ChildItem $RunFolder -Filter 'step_*_action.json' -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($actionFiles.Count -eq 0) { Write-Host "STATUS: GUIDE_INPUT_INVALID detail=no_step_action_json"; exit 1 }
        # tcode
        $tc = $Tcode
        $rj = Join-Path $RunFolder 'sap_gui_probe_run.json'
        if (-not $tc -and (Test-Path $rj)) { try { $j = Get-Content $rj -Raw | ConvertFrom-Json; if ($j.tcode) { $tc = "$($j.tcode)" } } catch {} }

        $steps = New-Object System.Collections.Generic.List[string]; $steps.Add("step`tverb`ttarget`tvalue`tnote`tprogram`tdynpro`tmsgtype")
        $fset = @{}
        $n=0
        foreach ($af in $actionFiles) {
            $n++
            $a=$null; try { $a = Get-Content $af.FullName -Raw | ConvertFrom-Json } catch {}
            $verb=''; $target=''; $value=''; $note=''
            if ($a) { $verb="$($a.verb)"; $target="$($a.target)"; $value="$($a.value)"; $note="$($a.note)" }
            $prog=''; $dyn=''; $mt=''
            $pf = $af.FullName -replace '_action\.json$','_post.json'
            if (Test-Path $pf) { try { $p = Get-Content $pf -Raw | ConvertFrom-Json; $prog="$($p.program)"; $dyn="$($p.dynpro)"; $mt="$($p.message_type)" } catch {} }
            $ff = Extract-Field $target; if ($ff) { $fset["$($ff[0])-$($ff[1])"]=$true }
            $steps.Add("$n`t$verb`t$target`t$($value -replace "[`t`r`n]",' ')`t$($note -replace "[`t`r`n]",' ')`t$prog`t$dyn`t$mt")
        }
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'steps.tsv'), ($steps -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'fields_request.tsv'), ("table`tfield`r`n" + (@($fset.Keys | Sort-Object | ForEach-Object { $_ -replace '-', "`t" }) -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ("HARVEST: tcode=$tc steps=$n fields=$($fset.Count)")
        Write-Host "STATUS: OK"; exit 0
    }
    elseif ($Action -eq 'compose') {
        $stepsFile = Join-Path $OutDir 'steps.tsv'
        if (-not (Test-Path $stepsFile)) { Write-Host "STATUS: GUIDE_INPUT_INVALID detail=run_harvest_first"; exit 1 }
        $steps = @(); $sl=[System.IO.File]::ReadAllLines($stepsFile); for($i=1;$i -lt $sl.Count;$i++){ if($sl[$i].Trim()){ $c=$sl[$i] -split "`t"; $steps += ,$c } }
        $fields = @{}; if ($FieldsTsv -and (Test-Path $FieldsTsv)) { $fl=[System.IO.File]::ReadAllLines($FieldsTsv); for($i=1;$i -lt $fl.Count;$i++){ if($fl[$i].Trim()){ $c=$fl[$i] -split "`t"; if($c.Count -ge 3){ $fields["$($c[0])-$($c[1])"]=$c[2] } } } }

        $md = New-Object System.Collections.Generic.List[string]
        $md.Add("# User Guide: $Tcode"); $md.Add(""); $md.Add("_Generated from a recorded walkthrough. Business-language step text: fill the TODO lines._"); $md.Add("")
        $uatRows = New-Object System.Collections.Generic.List[string]; if ($Uat) { $uatRows.Add("step`taction`texpected_result`tpass_fail`tsignoff") }
        foreach ($s in $steps) {
            $n=$s[0]; $verb=$s[1]; $target=$s[2]; $value=$s[3]; $note=$s[4]; $mt=if($s.Count -ge 8){$s[7]}else{''}
            $md.Add("## Step $n"); $md.Add("")
            $shot = if ($ScreensDir) { Join-Path $ScreensDir ("step_{0:D2}.png" -f [int]$n) } else { '' }
            if ($shot -and (Test-Path $shot)) { $md.Add("![step $n](screenshots/step_$('{0:D2}' -f [int]$n).png)"); $md.Add("") }
            $md.Add("- **Action:** TODO (business language) - recorded: ``$verb`` on ``$target``" + $(if($value){" = ``$value``"}else{""})); if($note){ $md.Add("- Note: $note") }
            $ff = Extract-Field $target
            if ($ff) { $key="$($ff[0])-$($ff[1])"; $lbl=if($fields.ContainsKey($key)){$fields[$key]}else{$ff[1]}; $bt=[char]96; $md.Add("- Field: **$lbl** ($bt$key$bt)") }
            $md.Add("")
            if ($Uat) { $exp = if ($mt -eq 'S') { 'success message' } elseif ($mt) { "message type $mt" } else { 'screen advances' }; $uatRows.Add("$n`t$verb $target`t$exp`t`t") }
        }
        [System.IO.File]::WriteAllText((Join-Path $OutDir "guide_$($Tcode)_$Lang.md"), ($md -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($false)))
        if ($Uat) { [System.IO.File]::WriteAllText((Join-Path $OutDir "uat_$Tcode.tsv"), ($uatRows -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true))) }
        Write-Host ("COMPOSE: guide=guide_$($Tcode)_$Lang.md steps=$($steps.Count)" + $(if($Uat){" uat=uat_$Tcode.tsv"}else{""}))
        Write-Host "STATUS: OK"; exit 0
    }
    else { Write-Host "STATUS: INPUT_ERROR reason=unknown_action"; exit 2 }
}
