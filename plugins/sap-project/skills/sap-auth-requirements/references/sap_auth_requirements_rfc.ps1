# =============================================================================
# sap_auth_requirements_rfc.ps1  -  RFC backend for /sap-auth-requirements
#
# Two read-only RFC modes (all FMs FMODE=R on S4D + EC2, probed 2026-07-11):
#   derive       read a program/FM source over RFC (RPY_PROGRAM_READ via sap_rfc_read_source),
#                run the offline extractor (sap_auth_extract.ps1), then VALIDATE each auth row
#                against the live catalog: object exists in TOBJ, field is one of the object's
#                TOBJ FIEL1..FIEL0, ACTVT value allowed per TACTZ. Emits a matrix TSV + SU24
#                proposal draft. Class/interface source is not RFC-readable -> pass -SourceFiles
#                (SE24 GUI download) or accept COULD_NOT_CHECK.
#   su24-audit   TSTC Z/Y tcodes vs USOBX_C (check flags) + USOBT_C (value proposals): classify
#                each tcode NO_PROPOSAL / CHECK_DISABLED / ONLY_S_TCODE / PROPOSAL_PRESENT and
#                report the newest MODDATE (staleness signal).
#
#   -Mode derive     (-Object <n> -Type program|fm | -SourceFiles "a,b")  [-Profile <hint>] -OutDir <dir>
#   -Mode su24-audit [-Tcodes "Z*"|"ZA,ZB"]  [-Profile <hint>] -OutDir <dir>
#
# stdout: AUTHREQ:/AUTHVAL:/SU24: lines + STATUS: OK|NOT_FOUND|COULD_NOT_CHECK|RFC_*. Exit 0/1/2.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Mode        = 'derive',
    [string] $Object      = '',
    [string] $Type        = 'auto',
    [string] $SourceFiles = '',
    [string] $Tcodes      = 'Z*',
    [string] $Profile     = '',
    [int]    $MaxTcodes   = 300,
    [string] $OutDir      = '',
    [string] $SharedDir   = '',
    [string] $RunId       = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
foreach ($lib in 'sap_connection_lib.ps1','sap_rfc_lib.ps1','sap_rfc_read_source.ps1') { $pp = Join-Path $scripts $lib; if (Test-Path $pp) { . $pp } }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

function San { param([string]$s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Invoke-Rfc { param($fn,$d) try { $fn.Invoke($d); return $true } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return $false } else { throw } } }
function Add-Where { param($fn,[string]$where)
    if (-not $where) { return }
    $line=''
    foreach ($cl in ($where -split '\s+AND\s+')) { $piece = if ($line -eq '') { $cl } else { "AND $cl" }; if ($line -eq '') { $line=$piece } elseif (($line.Length+1+$piece.Length) -le 72) { $line="$line $piece" } else { Add-RfcOption $fn $line; $line=$piece } }
    if ($line) { Add-RfcOption $fn $line }
}
function Read-Rows { param($d,[string]$table,[string]$where,[string[]]$fields,[int]$max)
    $fn = New-RfcReadTable -Destination $d -Table $table -Delimiter ''
    if ($max -gt 0) { [void]$fn.SetValue('ROWCOUNT',$max) }
    if ($where) { Add-Where $fn $where }
    foreach ($f in $fields) { Add-RfcField $fn $f }
    if (-not (Invoke-Rfc $fn $d)) { return @() }
    $fm=$fn.GetTable('FIELDS');$off=@{};$len=@{};for($x=0;$x -lt $fm.RowCount;$x++){$fm.CurrentIndex=$x;$nm=(San $fm.GetString('FIELDNAME'));$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
    $dt=$fn.GetTable('DATA');$out=@();for($x=0;$x -lt $dt.RowCount;$x++){$dt.CurrentIndex=$x;$wa="$($dt.GetString('WA'))";$rec=[ordered]@{};foreach($f in $fields){$o=$off[$f];$l=$len[$f];$rec[$f]=if($o -lt $wa.Length){$wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim()}else{''}};$out+=,([pscustomobject]$rec)}
    return $out
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $OutDir) { Write-Host 'STATUS: AUTHREQ_INPUT no_outdir'; exit 2 }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# ---- connect -----------------------------------------------------------------
$d = $null
if ($Profile) {
    $cands = @(Resolve-SapProfileHint -Hint $Profile)
    if ($cands.Count -ne 1) { Write-Host "STATUS: RFC_LOGON_FAILED profile=$Profile"; exit 2 }
    $c = $cands[0]; $pw = (& (Join-Path $scripts 'sap_dpapi.ps1') -Action unprotect -Value "$($c.password_dpapi)" 2>$null) -as [string]
    try { $d = Connect-SapRfc -Server $c.application_server -Sysnr $c.system_number -MessageServer $c.message_server -LogonGroup $c.logon_group -SystemID $c.system_id -Client $c.client -User $c.user -Password $pw -Language $c.language -DestName ("AR_"+$c.system_name) } catch { }
} else { try { $d = Connect-SapRfc -DestName 'AR' } catch { } }
if (-not $d) { Write-Host 'STATUS: RFC_LOGON_FAILED'; exit 2 }

try {
# =============================================================================
if ($Mode -eq 'su24-audit') {
    $where = if ($Tcodes -match '[*%]') { "TCODE LIKE '$($Tcodes -replace '\*','%')'" } else { '' }
    $tlist = @()
    if ($where) { $tlist = @(Read-Rows $d 'TSTC' $where @('TCODE','PGMNA') $MaxTcodes | ForEach-Object { $_.TCODE }) }
    else { $tlist = @($Tcodes -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }) }
    Write-Host ("SU24SEL: tcodes=$($tlist.Count) filter=`"$Tcodes`"")
    $lines = @(); $noProp=0
    foreach ($tc in $tlist) {
        $xr = @(Read-Rows $d 'USOBX_C' "NAME = '$tc' AND TYPE = 'TR'" @('OBJECT','OKFLAG','MODDATE') 200)
        $tr = @(Read-Rows $d 'USOBT_C' "NAME = '$tc' AND TYPE = 'TR'" @('OBJECT','FIELD','LOW','MODDATE') 500)
        $checked = @($xr | Where-Object { (San $_.OKFLAG) -in @('X','Y') })
        $objs = @($xr | ForEach-Object { San $_.OBJECT } | Sort-Object -Unique)
        $newest = ''
        foreach ($r in ($xr + $tr)) { $m=San $r.MODDATE; if ($m -and $m -gt $newest) { $newest=$m } }
        $verdict = if ($xr.Count -eq 0) { $noProp++; 'NO_PROPOSAL' }
                   elseif ($checked.Count -eq 0) { 'CHECK_DISABLED' }
                   elseif ($objs.Count -eq 1 -and $objs[0] -eq 'S_TCODE') { 'ONLY_S_TCODE' }
                   else { 'PROPOSAL_PRESENT' }
        Write-Host ("SU24: tcode=$tc objects=$($objs.Count) checked=$($checked.Count) values=$($tr.Count) newest=$newest verdict=$verdict")
        $lines += (@($tc,$objs.Count,$checked.Count,$tr.Count,$newest,$verdict,($objs -join ';')) -join "`t")
    }
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine("tcode`tobjects`tchecked`tvalue_rows`tnewest_moddate`tverdict`tobject_list")
    foreach ($l in $lines) { [void]$sb.AppendLine($l) }
    [IO.File]::WriteAllText((Join-Path $OutDir 'su24_audit.tsv'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    Write-Host ("STATUS: OK tcodes=$($tlist.Count) no_proposal=$noProp")
    Disconnect-SapRfc; exit 0
}
# =============================================================================
elseif ($Mode -eq 'derive') {
    # --- acquire source --------------------------------------------------------
    $srcDir = Join-Path $OutDir 'src'
    if (-not (Test-Path $srcDir)) { New-Item -ItemType Directory -Force -Path $srcDir | Out-Null }
    $files = @()
    if ($SourceFiles) { $files = @($SourceFiles -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    else {
        if (-not $Object) { Write-Host 'STATUS: AUTHREQ_INPUT no_object'; Disconnect-SapRfc; exit 2 }
        $rt = if ($Type -in @('program','fm','include')) { $Type } else { 'program' }
        if ($Type -in @('class','interface')) { Write-Host "STATUS: COULD_NOT_CHECK class_source_needs_gui_download (pass -SourceFiles)"; Disconnect-SapRfc; exit 1 }
        try {
            $res = Read-SapAbapSource -Name $Object -Type $rt -OutDir $srcDir -WithIncludes -Dest $d
            $files = @(Get-ChildItem -Path $srcDir -Filter *.txt -File | ForEach-Object { $_.FullName })
        } catch { Write-Host ("STATUS: AUTHREQ_SOURCE_UNREADABLE " + (San $_.Exception.Message)); Disconnect-SapRfc; exit 1 }
    }
    if ($files.Count -eq 0) { Write-Host 'STATUS: AUTHREQ_SOURCE_UNREADABLE no_files'; Disconnect-SapRfc; exit 1 }
    # --- run offline extractor -------------------------------------------------
    $rowsJson = Join-Path $OutDir 'auth_rows.json'
    $ext = Join-Path $PSScriptRoot 'sap_auth_extract.ps1'
    & $ext -SourceFiles ($files -join ',') -ObjectName $Object -OutJson $rowsJson | Out-Null
    if (-not (Test-Path $rowsJson)) { Write-Host 'STATUS: AUTHREQ_EXTRACT_FAILED'; Disconnect-SapRfc; exit 2 }
    $data = Get-Content -Raw $rowsJson | ConvertFrom-Json
    $rows = @($data.rows)
    # --- validate objects against TOBJ / TACTZ ---------------------------------
    $objSet = @($rows | ForEach-Object { $_.object } | Where-Object { $_ -and $_ -notmatch '^<' } | Sort-Object -Unique)
    $fieldMap = @{}; $actMap = @{}
    foreach ($o in $objSet) {
        $to = @(Read-Rows $d 'TOBJ' "OBJCT = '$o'" @('OBJCT','FIEL1','FIEL2','FIEL3','FIEL4','FIEL5','FIEL6','FIEL7','FIEL8','FIEL9','FIEL0') 1)
        if ($to.Count) { $flds=@(); foreach ($fn in @('FIEL1','FIEL2','FIEL3','FIEL4','FIEL5','FIEL6','FIEL7','FIEL8','FIEL9','FIEL0')) { $v=San $to[0].$fn; if ($v) { $flds += $v } }; $fieldMap[$o]=$flds }
        $ta = @(Read-Rows $d 'TACTZ' "BROBJ = '$o'" @('ACTVT') 200); $actMap[$o]=@($ta | ForEach-Object { San $_.ACTVT })
    }
    $matrix = @()
    foreach ($r in $rows) {
        $val='OBJECT_UNKNOWN'
        $o=$r.object
        if ($o -match '^<') { $val='OBJECT_FROM_VARIABLE' }
        elseif ($fieldMap.ContainsKey($o)) {
            $val='OBJECT_OK'
            if ($r.field -and $r.field -ne 'DUMMY' -and $r.field -notmatch '^<') { if ($fieldMap[$o] -notcontains $r.field) { $val='FIELD_UNKNOWN' } }
            if ($val -eq 'OBJECT_OK' -and $r.field -eq 'ACTVT' -and $r.status -eq 'CONFIRMED' -and $r.value -match '^\d+$') { if ($actMap[$o].Count -and $actMap[$o] -notcontains $r.value) { $val='ACTVT_NOT_ALLOWED' } }
        }
        Write-Host ("AUTHVAL: seq=$($r.seq) object=$o field=$($r.field) value=$($r.value) status=$($r.status) validation=$val")
        $matrix += (@($r.seq,$r.source,$r.stmt,$o,$r.field,$r.value,$r.status,$val,(San $r.note)) -join "`t")
    }
    $sb = New-Object System.Text.StringBuilder; [void]$sb.AppendLine("seq`tsource`tstatement`tauth_object`tfield`tvalue`tstatus`tvalidation`ttrace_note")
    foreach ($l in $matrix) { [void]$sb.AppendLine($l) }
    [IO.File]::WriteAllText((Join-Path $OutDir 'auth_requirements.tsv'), $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    # --- SU24 proposal draft (checked objects, unique) -------------------------
    $prop = @($rows | Where-Object { $_.object -notmatch '^<' } | ForEach-Object { $_.object } | Sort-Object -Unique)
    $sbp = New-Object System.Text.StringBuilder; [void]$sbp.AppendLine("auth_object`tproposed_check`tsource_note")
    foreach ($o in $prop) { [void]$sbp.AppendLine((@($o,'X (check)',"derived from $Object source") -join "`t")) }
    [IO.File]::WriteAllText((Join-Path $OutDir 'su24_proposal_draft.tsv'), $sbp.ToString(), (New-Object Text.UTF8Encoding($true)))
    $conf=@($rows|Where-Object{$_.status -eq 'CONFIRMED'}).Count; $inf=@($rows|Where-Object{$_.status -eq 'INFERRED'}).Count
    $unk=@($matrix | Where-Object { $_ -match "OBJECT_UNKNOWN|FIELD_UNKNOWN|ACTVT_NOT_ALLOWED" }).Count
    Write-Host ("AUTHREQ: object=$Object rows=$($rows.Count) confirmed=$conf inferred=$inf objects=$($objSet.Count) validation_issues=$unk")
    Write-Host ("STATUS: OK object=$Object rows=$($rows.Count)")
    Disconnect-SapRfc; exit 0
}
else { Write-Host "STATUS: AUTHREQ_INPUT bad_mode=$Mode"; Disconnect-SapRfc; exit 2 }
} catch {
    Write-Host ("ERROR: {0}" -f (San $_.Exception.Message)); Write-Host 'STATUS: RFC_ERROR'; try { Disconnect-SapRfc } catch { }; exit 2
}
