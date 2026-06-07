# =============================================================================
# sap_error_hints.ps1  -  CLI for the frequently_errors feedback loop
#
# Thin dispatcher over sap_error_hints_lib.ps1 (the engine). Three actions:
#
#   resolve  READ path  (sap-gen-abap Step 1.5f). Merge the 3 tiers for the
#            objects this spec references and write the injectable hint set.
#     -Objects "BAPI_MATERIAL_SAVEDATA,CL_GUI_FRONTEND_SERVICES" | -ObjectsFile <p>
#     -CustomUrl <dir> -SharedTablesDir <...\sap-dev-core\shared\tables>
#     -ResultFile <...\_error_hints.txt> [-InjectStatuses CONFIRMED]
#
#   record   WRITE path (se38/se37/se24 post-deploy + sap-atc post-drill).
#            Attribute each error to a FM / METHOD and upsert it as CANDIDATE.
#     -CustomUrl <dir> -Source SE38|SE37|SE24|ATC [-SourceFile <abap>]
#     -ErrorsFile <tsv: [SEV] LINE TEXT>   (deploy syntax errors)  | OR
#     -FindingsFile <atc .findings.tsv>    (ATC drill output)
#     [-Program <object>] [-KnownObjectsFile <list>]
#
#   curate   list / promote / mute CANDIDATE entries (/sap-error-kb).
#     -Op list [-CustomUrl <dir>] [-IncludeConfirmed]
#     -Op promote|mute -CustomUrl <dir> -Object <stem|name> -Key "<TYPE|NAME|CTX|CLASS>"
#
# Stdout last line is a STATUS: line for the caller to parse. ASCII-only.
# =============================================================================

param(
    [Parameter(Mandatory=$true)] [ValidateSet('resolve','record','curate')] [string] $Action,

    # resolve
    [string]   $Objects = '',
    [string]   $ObjectsFile = '',
    [string]   $ResultFile = '',
    [string]   $InjectStatuses = 'CONFIRMED',

    # record
    [string]   $Source = '',
    [string]   $SourceFile = '',
    [string]   $ErrorsFile = '',       # structured TSV: [SEV] LINE TEXT
    [string]   $RawOutputFile = '',    # freeform deploy stdout (parsed for 'Line N: text')
    [string]   $FindingsFile = '',     # ATC .findings.tsv
    [string]   $Program = '',
    [string]   $KnownObjectsFile = '',

    # curate
    [string]   $Op = '',
    [string]   $Object = '',
    [string]   $Key = '',
    [switch]   $IncludeConfirmed,

    # shared
    [string]   $CustomUrl = '',
    [string]   $SharedTablesDir = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Load the engine ---------------------------------------------------------
$lib = Join-Path $PSScriptRoot 'sap_error_hints_lib.ps1'
if (-not (Test-Path -LiteralPath $lib)) {
    Write-Output "STATUS: ERROR lib-not-found $lib"
    exit 2
}
. $lib

# --- Best-effort logging -----------------------------------------------------
$logLib = Join-Path $PSScriptRoot 'sap_log_lib.ps1'
$logRun = $null
if (Test-Path -LiteralPath $logLib) {
    try { . $logLib; $logRun = Start-SapLog -Skill 'sap-error-hints' -Params @{ action = $Action } } catch { $logRun = $null }
}
function End-Log([string]$status, [int]$code) {
    if ($null -ne $logRun) { try { Stop-SapLog -Run $logRun -Status $status -ExitCode $code } catch {} }
}

# Default shared tables dir = sibling 'tables' of this scripts dir
if (-not $SharedTablesDir) {
    $cand = Join-Path (Split-Path -Parent $PSScriptRoot) 'tables'
    if (Test-Path -LiteralPath $cand) { $SharedTablesDir = $cand }
}

# --- Extract known FM / class names from a source file (for attribution) ----
function Get-KnownObjectsFromSource([string]$srcPath) {
    $names = @{}
    if ($srcPath -and (Test-Path -LiteralPath $srcPath)) {
        $txt = Get-Content -Raw -LiteralPath $srcPath -Encoding UTF8
        foreach ($m in [regex]::Matches($txt, "(?i)CALL\s+FUNCTION\s+'([^']+)'")) {
            $names[$m.Groups[1].Value.ToUpper()] = $true
        }
        foreach ($m in [regex]::Matches($txt, "(?i)([A-Z_/][A-Z0-9_/]*)\s*(=>|->)\s*[A-Z_][A-Z0-9_]*\s*\(")) {
            $names[$m.Groups[1].Value.ToUpper()] = $true
        }
    }
    return @($names.Keys)
}

try {
    switch ($Action) {

        # ===================================================================
        'resolve' {
            $objList = @()
            if ($Objects) { $objList += ($Objects -split '[,;]') }
            if ($ObjectsFile -and (Test-Path -LiteralPath $ObjectsFile)) {
                foreach ($l in Get-Content -LiteralPath $ObjectsFile -Encoding UTF8) {
                    $t = $l.Trim()
                    if ($t -ne '' -and -not $t.StartsWith('#')) { $objList += $t }
                }
            }
            $objList = $objList | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique
            if (-not $ResultFile) { Write-Output 'STATUS: ERROR resolve-needs-ResultFile'; End-Log 'FAILED' 2; exit 2 }

            $statuses = ($InjectStatuses -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            if ($statuses -contains 'ALL') { $statuses = @('CONFIRMED','CANDIDATE') }

            $rows = Resolve-SapErrorHints -Objects $objList -CustomUrl $CustomUrl -SharedTablesDir $SharedTablesDir -InjectStatuses $statuses
            $n = Write-SapErrHintResult -Rows $rows -ResultFile $ResultFile
            Write-Output ("INFO: resolved " + $n + " hint(s) for " + $objList.Count + " object(s) -> " + $ResultFile)
            Write-Output ("STATUS: RESOLVED hints=" + $n)
            End-Log 'SUCCESS' 0
            exit 0
        }

        # ===================================================================
        'record' {
            if (-not $CustomUrl) { Write-Output 'STATUS: ERROR record-needs-CustomUrl'; End-Log 'FAILED' 2; exit 2 }
            $known = @()
            if ($KnownObjectsFile -and (Test-Path -LiteralPath $KnownObjectsFile)) {
                foreach ($l in Get-Content -LiteralPath $KnownObjectsFile -Encoding UTF8) {
                    $t = $l.Trim(); if ($t -ne '' -and -not $t.StartsWith('#')) { $known += $t.ToUpper() }
                }
            }
            $known += (Get-KnownObjectsFromSource $SourceFile)
            $known = $known | Select-Object -Unique

            $added = 0; $updated = 0; $skipped = 0
            $src = $Source.ToUpper()

            # ---- deploy syntax errors --------------------------------------
            if ($ErrorsFile) {
                if (-not (Test-Path -LiteralPath $ErrorsFile)) { Write-Output "STATUS: ERROR errors-file-not-found $ErrorsFile"; End-Log 'FAILED' 2; exit 2 }
                foreach ($l in Get-Content -LiteralPath $ErrorsFile -Encoding UTF8) {
                    if ($null -eq $l) { continue }
                    $t = $l.Trim(); if ($t -eq '' -or $t.StartsWith('#')) { continue }
                    $c = $l -split "`t"
                    $lineNo = 0; $text = ''
                    if ($c.Count -ge 3)      { [int]::TryParse(($c[1].Trim()), [ref]$lineNo) | Out-Null; $text = $c[2] }
                    elseif ($c.Count -eq 2)  { [int]::TryParse(($c[0].Trim()), [ref]$lineNo) | Out-Null; $text = $c[1] }
                    else                     { $text = $c[0] }
                    $attr = Get-SapErrorAttribution -SourceFile $SourceFile -Line $lineNo -Text $text -KnownObjects $known
                    $v = Add-SapErrorHint -CustomUrl $CustomUrl -ObjectType $attr.ObjectType -ObjectName $attr.ObjectName `
                            -Context $attr.Context -ErrorClass 'DEPLOY_SYNTAX' -Message $text -Source $src `
                            -Program $Program -Line ([string]$lineNo) -Severity 'ACTIVATION'
                    if ($v -eq 'ADDED') { $added++ } elseif ($v -eq 'UPDATED') { $updated++ } else { $skipped++ }
                }
            }

            # ---- deploy stdout (freeform) ----------------------------------
            # Parse the captured VBS output for syntax/activation error lines.
            # Matches SE38 "[ERROR] Line 7: <text>" and SE37/SE24 per-row forms,
            # plus bare "Line N: <text>". Locale-independent on the line number;
            # object attribution is by source line -> enclosing call.
            if ($RawOutputFile) {
                if (-not (Test-Path -LiteralPath $RawOutputFile)) { Write-Output "STATUS: ERROR raw-output-file-not-found $RawOutputFile"; End-Log 'FAILED' 2; exit 2 }
                foreach ($l in Get-Content -LiteralPath $RawOutputFile -Encoding UTF8) {
                    if ($null -eq $l) { continue }
                    $m = [regex]::Match($l, '(?i)\bLine\s+(\d+)\s*:\s*(.+?)\s*$')
                    if (-not $m.Success) { continue }
                    $lineNo = 0; [int]::TryParse(($m.Groups[1].Value), [ref]$lineNo) | Out-Null
                    $text = $m.Groups[2].Value
                    if ($text -eq '') { continue }
                    $attr = Get-SapErrorAttribution -SourceFile $SourceFile -Line $lineNo -Text $text -KnownObjects $known
                    $v = Add-SapErrorHint -CustomUrl $CustomUrl -ObjectType $attr.ObjectType -ObjectName $attr.ObjectName `
                            -Context $attr.Context -ErrorClass 'DEPLOY_SYNTAX' -Message $text -Source $src `
                            -Program $Program -Line ([string]$lineNo) -Severity 'ACTIVATION'
                    if ($v -eq 'ADDED') { $added++ } elseif ($v -eq 'UPDATED') { $updated++ } else { $skipped++ }
                }
            }

            # ---- ATC findings ---------------------------------------------
            if ($FindingsFile) {
                if (-not (Test-Path -LiteralPath $FindingsFile)) { Write-Output "STATUS: ERROR findings-file-not-found $FindingsFile"; End-Log 'FAILED' 2; exit 2 }
                # ATC TSV has its own columns; read generically by header.
                # Accumulate in a List -- a hashtable in `+=` hits the dict trap.
                $atc = New-Object System.Collections.Generic.List[object]
                $lines = Get-Content -LiteralPath $FindingsFile -Encoding UTF8
                $hdr = $null
                foreach ($ln in $lines) {
                    if ($null -eq $ln) { continue }
                    $tt = $ln.Trim(); if ($tt -eq '' -or $tt.StartsWith('#')) { continue }
                    $cc = $ln -split "`t"
                    if ($null -eq $hdr) { $hdr = @(); foreach ($h in $cc) { $hdr += $h.Trim().ToUpper() }; continue }
                    $rec = @{}
                    for ($i=0; $i -lt $hdr.Count; $i++) { if ($i -lt $cc.Count -and -not $rec.ContainsKey($hdr[$i])) { $rec[$hdr[$i]] = $cc[$i] } }
                    $atc.Add($rec)
                }
                function _Col($rec, [string[]]$cands) {
                    foreach ($k in $cands) { if ($rec.ContainsKey($k) -and ([string]$rec[$k]).Trim() -ne '') { return [string]$rec[$k] } }
                    return ''
                }
                foreach ($rec in $atc) {
                    $prio  = _Col $rec @('PRIO','PRIORITY')
                    $chk   = _Col $rec @('CHECK_ID','CHECKID')
                    $msg   = _Col $rec @('MSG_TEXT','MESSAGE_TITLE','MSG')
                    $title = _Col $rec @('CHECK_TITLE','MESSAGE_TITLE','MSG_TEXT','MSG')
                    $objn  = _Col $rec @('OBJ_NAME','OBJECT','OBJECT_NAME')
                    $lineS = _Col $rec @('LINE')
                    $lineNo = 0; [int]::TryParse(($lineS.Trim()), [ref]$lineNo) | Out-Null
                    # Feed ALL text columns to attribution -- the FM/method name may
                    # be in MSG_TEXT, CHECK_TITLE, or embedded in CHECK_ID.
                    $attrText = ($title + ' ' + $msg + ' ' + $chk)
                    $attr = Get-SapErrorAttribution -SourceFile $SourceFile -Line $lineNo -Text $attrText -KnownObjects $known
                    if ($attr.ObjectName -eq '?' ) { $skipped++; continue }   # only FM/METHOD-attributable ATC findings
                    $sev = 'ATC_P3'
                    if ($prio -match '1') { $sev = 'ATC_P1' } elseif ($prio -match '2') { $sev = 'ATC_P2' } elseif ($prio -match '3') { $sev = 'ATC_P3' }
                    $ec = 'ATC'; if ($chk) { $ec = 'ATC_' + ($chk -replace '[^A-Z0-9_]','_').ToUpper() }
                    $recMsg = $msg; if (-not $recMsg) { $recMsg = $title }
                    $prog = $Program; if (-not $prog) { $prog = $objn }
                    $v = Add-SapErrorHint -CustomUrl $CustomUrl -ObjectType $attr.ObjectType -ObjectName $attr.ObjectName `
                            -Context $attr.Context -ErrorClass $ec -Message $recMsg -Source 'ATC' `
                            -Program $prog -Line ([string]$lineNo) -Severity $sev
                    if ($v -eq 'ADDED') { $added++ } elseif ($v -eq 'UPDATED') { $updated++ } else { $skipped++ }
                }
            }

            Write-Output ("INFO: record added=" + $added + " updated=" + $updated + " skipped=" + $skipped)
            Write-Output ("STATUS: RECORDED added=" + $added + " updated=" + $updated + " skipped=" + $skipped)
            End-Log 'SUCCESS' 0
            exit 0
        }

        # ===================================================================
        'curate' {
            if (-not $CustomUrl) { Write-Output 'STATUS: ERROR curate-needs-CustomUrl'; End-Log 'FAILED' 2; exit 2 }
            $dir = Get-SapErrHintDir $CustomUrl
            $op = $Op.ToLower()

            if ($op -eq 'list' -or $op -eq '') {
                if (-not (Test-Path -LiteralPath $dir)) { Write-Output 'INFO: no per-object store yet'; Write-Output 'STATUS: LISTED count=0'; End-Log 'SUCCESS' 0; exit 0 }
                $count = 0
                foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.tsv' -File)) {
                    $rows = Read-SapErrHintTsv $f.FullName
                    foreach ($r in $rows) {
                        $st = ([string]$r['STATUS']).Trim().ToUpper()
                        if (-not $IncludeConfirmed -and $st -ne 'CANDIDATE') { continue }
                        $count++
                        $k = Get-SapErrHintKey $r
                        $occ = ''; if ($r.Contains('OCCURRENCES')) { $occ = [string]$r['OCCURRENCES'] }
                        $ls  = ''; if ($r.Contains('LAST_SEEN'))   { $ls  = [string]$r['LAST_SEEN'] }
                        $wp  = ''; if ($r.Contains('WRONG_PATTERN')) { $wp = [string]$r['WRONG_PATTERN'] }
                        if ($wp.Length -gt 60) { $wp = $wp.Substring(0,57) + '...' }
                        Write-Output ("CAND`t" + $f.Name + "`t" + $st + "`tocc=" + $occ + "`tseen=" + $ls + "`t" + $k + "`t" + $wp)
                    }
                }
                Write-Output ("STATUS: LISTED count=" + $count)
                End-Log 'SUCCESS' 0
                exit 0
            }

            if ($op -eq 'promote' -or $op -eq 'mute') {
                if (-not $Object -or -not $Key) { Write-Output 'STATUS: ERROR curate-needs-Object-and-Key'; End-Log 'FAILED' 2; exit 2 }
                $stem = Get-SapErrHintObjectStem $Object
                $file = Join-Path $dir ($stem + '.tsv')
                if (-not (Test-Path -LiteralPath $file)) { Write-Output "STATUS: ERROR object-file-not-found $file"; End-Log 'FAILED' 2; exit 2 }
                $rows = Read-SapErrHintTsv $file
                $newStatus = if ($op -eq 'promote') { 'CONFIRMED' } else { 'MUTE' }
                $hit = $false
                foreach ($r in $rows) {
                    if ((Get-SapErrHintKey $r) -eq $Key.ToUpper()) { $r['STATUS'] = $newStatus; $hit = $true }
                }
                if (-not $hit) { Write-Output "STATUS: ERROR key-not-found $Key"; End-Log 'FAILED' 1; exit 1 }
                $cols = Get-SapErrHintAllColumns
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.AppendLine(($cols -join "`t"))
                foreach ($r in $rows) {
                    $cells = @()
                    foreach ($c in $cols) { $v=''; if ($r.Contains($c)) { $v=[string]$r[$c] }; $cells += (ConvertTo-SapErrHintCell $v) }
                    [void]$sb.AppendLine(($cells -join "`t"))
                }
                [System.IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
                Write-Output ("STATUS: " + $newStatus + " " + $Key)
                End-Log 'SUCCESS' 0
                exit 0
            }

            Write-Output "STATUS: ERROR unknown-op $Op"
            End-Log 'FAILED' 2
            exit 2
        }
    }
}
catch {
    Write-Output ("STATUS: ERROR " + $_.Exception.Message)
    End-Log 'FAILED' 2
    exit 2
}
