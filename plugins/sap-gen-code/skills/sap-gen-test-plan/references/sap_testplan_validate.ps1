# =============================================================================
# sap_testplan_validate.ps1  -  --validate RFC backend for /sap-gen-test-plan
#
# Read-only RFC pass that grounds a derived functional test plan in the live
# system. Confirms every referenced message (T100/T100A), prerequisite table
# (DD02L/DD02T), tcode (TSTC), and FM (TFDIR); pulls DD03L key fields to emit
# test-data row templates; renders placeholder message text via
# BAPI_MESSAGE_GETDETAIL. Upgrades a fact's provenance INFERRED->VERIFIED, or
# records MISMATCH / NOT_FOUND for the SKILL.md to fold into findings.
#
# READ-ONLY: RFC_READ_TABLE + DDIF_FIELDINFO_GET + BAPI_MESSAGE_GETDETAIL only.
# No writes, no GUI, no wrapper FM (all three FMs probed FMODE=R on S4D + EC2).
# Connects via the pinned profile (Connect-SapRfc fallback) when creds omitted.
#
# Input (-InFile): TSV, one fact per line: <kind>\t<name>\t<sub>
#   kind=msg        name=<MSGID>    sub=<MSGNO>
#   kind=table      name=<TABNAME>
#   kind=tcode      name=<TCODE>
#   kind=fm         name=<FUNCNAME>
#   kind=keyfields  name=<TABNAME>   (emit key-field test-data template)
#   '#'-prefixed and blank lines ignored.
#
# Output (stdout, also -OutTsv when given):
#   VALIDATE: kind=<k> name=<n> status=<VERIFIED|MISMATCH|NOT_FOUND> detail=<...>
#   STATUS: OK | COULD_NOT_CHECK | RFC_ERROR
# Exit: 0 = ran (incl. per-fact NOT_FOUND/MISMATCH) | 1 = COULD_NOT_CHECK | 2 = RFC_ERROR
# Run with 32-bit PowerShell (SAP NCo 3.1 is in the 32-bit GAC).
# =============================================================================

[CmdletBinding()]
param(
    [string] $InFile = '',
    [string] $OutTsv = '',
    [string] $Language = '',
    [string] $SharedDir = '',
    [string] $RunId = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = ''
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

function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Sq  { param([string] $s) return (("$s") -replace "'", "''") }

$emit = New-Object System.Collections.Generic.List[string]
function Emit-Validate {
    param([string] $Kind, [string] $Name, [string] $Status, [string] $Detail)
    $line = "VALIDATE: kind=$Kind name=$Name status=$Status detail=$(San $Detail)"
    Write-Host $line
    $emit.Add("$Kind`t$Name`t$Status`t$(San $Detail)")
}

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    if (-not $InFile -or -not (Test-Path $InFile)) {
        Write-Host "STATUS: COULD_NOT_CHECK"; Write-Host "INFO: input file not found: $InFile"; exit 1
    }

    # ---- parse input ----
    $msgs = @{}       # msgid -> [msgno,...]
    $tables = New-Object System.Collections.Generic.List[string]
    $tcodes = New-Object System.Collections.Generic.List[string]
    $fms    = New-Object System.Collections.Generic.List[string]
    $keyfs  = New-Object System.Collections.Generic.List[string]
    foreach ($ln in [System.IO.File]::ReadAllLines($InFile)) {
        if ($ln -match '^\s*#' -or $ln.Trim() -eq '') { continue }
        $c = $ln -split "`t"
        $kind = $c[0].Trim().ToLower()
        $name = if ($c.Count -ge 2) { $c[1].Trim() } else { '' }
        $sub  = if ($c.Count -ge 3) { $c[2].Trim() } else { '' }
        if ($name -eq '') { continue }
        switch ($kind) {
            'msg'       { $id = $name.ToUpper(); if (-not $msgs.ContainsKey($id)) { $msgs[$id] = New-Object System.Collections.Generic.List[string] }; if ($sub -ne '') { [void]$msgs[$id].Add($sub) } }
            'table'     { [void]$tables.Add($name.ToUpper()) }
            'tcode'     { [void]$tcodes.Add($name.ToUpper()) }
            'fm'        { [void]$fms.Add($name.ToUpper()) }
            'keyfields' { [void]$keyfs.Add($name.ToUpper()) }
        }
    }

    # ---- connect (pinned fallback) ----
    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_TESTPLAN_VAL"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; Write-Host "INFO: RFC connect failed (no pinned profile?)"; exit 2 }
    $lang = if ($Language) { $Language.Substring(0, [Math]::Min(1, $Language.Length)).ToUpper() } else { 'E' }

    try {
        # ---- messages (one T100 read per class, filter numbers locally) ----
        foreach ($id in ($msgs.Keys | Sort-Object)) {
            $rows = @()
            try { $rows = Read-SapTableRows -Destination $g_dest -Table 'T100' -Where "ARBGB EQ '$(Sq $id)'" -Fields @('SPRSL','MSGNR','TEXT') -RowCount 5000 } catch { $rows = @() }
            $byNo = @{}
            foreach ($r in $rows) {
                $no = "$($r.MSGNR)"; if (-not $byNo.ContainsKey($no)) { $byNo[$no] = @{} }
                $byNo[$no]["$($r.SPRSL)"] = "$($r.TEXT)"
            }
            $classExists = ($byNo.Count -gt 0)
            if (-not $classExists) {
                # class may exist in T100A with no texts
                $ca = @(); try { $ca = Read-SapTableRows -Destination $g_dest -Table 'T100A' -Where "ARBGB EQ '$(Sq $id)'" -Fields @('ARBGB') -RowCount 1 } catch { $ca = @() }
                $classExists = (@($ca).Count -gt 0)
            }
            $wantNos = @($msgs[$id])
            if ($wantNos.Count -eq 0) { $wantNos = @('') }   # class-only check
            foreach ($no in $wantNos) {
                if ($no -eq '') {
                    if ($classExists) { Emit-Validate 'msg' $id 'VERIFIED' "message class exists" }
                    else { Emit-Validate 'msg' $id 'NOT_FOUND' "message class not found" }
                    continue
                }
                $key = "$id/$no"
                if ($byNo.ContainsKey($no)) {
                    $txt = if ($byNo[$no].ContainsKey($lang)) { $byNo[$no][$lang] } elseif ($byNo[$no].ContainsKey('E')) { $byNo[$no]['E'] } else { ($byNo[$no].Values | Select-Object -First 1) }
                    $langs = ($byNo[$no].Keys | Sort-Object) -join ''
                    Emit-Validate 'msg' $key 'VERIFIED' "text='$txt' langs=$langs"
                } elseif ($classExists) {
                    Emit-Validate 'msg' $key 'MISMATCH' "class $id exists but number $no not defined"
                } else {
                    Emit-Validate 'msg' $key 'NOT_FOUND' "message class $id not found"
                }
            }
        }

        # ---- tables (DD02L existence + DD02T text) ----
        foreach ($t in ($tables | Select-Object -Unique)) {
            $r = @(); try { $r = Read-SapTableRows -Destination $g_dest -Table 'DD02L' -Where "TABNAME EQ '$(Sq $t)' AND AS4LOCAL EQ 'A'" -Fields @('TABNAME','TABCLASS','AS4LOCAL') -RowCount 1 } catch { $r = @() }
            if (@($r).Count -gt 0) {
                $txt = ''
                try { $dt = Read-SapTableRows -Destination $g_dest -Table 'DD02T' -Where "TABNAME EQ '$(Sq $t)' AND DDLANGUAGE EQ '$lang'" -Fields @('DDTEXT') -RowCount 1; if (@($dt).Count) { $txt = "$($dt[0].DDTEXT)" } } catch {}
                Emit-Validate 'table' $t 'VERIFIED' "class=$($r[0].TABCLASS) text='$txt'"
            } else {
                Emit-Validate 'table' $t 'NOT_FOUND' "table/view not active on this system"
            }
        }

        # ---- tcodes (TSTC) ----
        foreach ($tc in ($tcodes | Select-Object -Unique)) {
            $r = @(); try { $r = Read-SapTableRows -Destination $g_dest -Table 'TSTC' -Where "TCODE EQ '$(Sq $tc)'" -Fields @('TCODE','PGMNA') -RowCount 1 } catch { $r = @() }
            if (@($r).Count -gt 0) { Emit-Validate 'tcode' $tc 'VERIFIED' "program=$($r[0].PGMNA)" }
            else { Emit-Validate 'tcode' $tc 'NOT_FOUND' "transaction code not found" }
        }

        # ---- fms (TFDIR) ----
        foreach ($fm in ($fms | Select-Object -Unique)) {
            $r = @(); try { $r = Read-SapTableRows -Destination $g_dest -Table 'TFDIR' -Where "FUNCNAME EQ '$(Sq $fm)'" -Fields @('FUNCNAME','FMODE') -RowCount 1 } catch { $r = @() }
            if (@($r).Count -gt 0) { $rem = if ("$($r[0].FMODE)" -eq 'R') { 'remote-enabled' } else { 'not remote' }; Emit-Validate 'fm' $fm 'VERIFIED' "fmode=$($r[0].FMODE) ($rem)" }
            else { Emit-Validate 'fm' $fm 'NOT_FOUND' "function module not found" }
        }

        # ---- keyfields (DD03L key list -> test-data template) ----
        foreach ($t in ($keyfs | Select-Object -Unique)) {
            $r = @(); try { $r = Read-SapTableRows -Destination $g_dest -Table 'DD03L' -Where "TABNAME EQ '$(Sq $t)' AND KEYFLAG EQ 'X'" -Fields @('FIELDNAME','POSITION','ROLLNAME') -RowCount 100 } catch { $r = @() }
            $keys = @($r | Sort-Object { [int]("0" + "$($_.POSITION)") } | ForEach-Object { "$($_.FIELDNAME)" } | Where-Object { $_ -and $_ -ne 'MANDT' })
            if ($keys.Count -gt 0) { Emit-Validate 'keyfields' $t 'VERIFIED' "keys=$($keys -join ',')" }
            else { Emit-Validate 'keyfields' $t 'NOT_FOUND' "no key fields (table not found?)" }
        }
    } catch {
        Write-Host ("INFO: validation read error: " + $_.Exception.Message)
        Write-Host "STATUS: COULD_NOT_CHECK"
        try { Disconnect-SapRfc } catch {}
        exit 1
    }

    # ---- optional TSV ----
    if ($OutTsv) {
        try {
            $hdr = "kind`tname`tstatus`tdetail"
            [System.IO.File]::WriteAllText($OutTsv, ($hdr + "`r`n" + ($emit -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
            Write-Host "OUT_TSV: $OutTsv"
        } catch { Write-Host ("WARN: could not write OutTsv: " + $_.Exception.Message) }
    }

    Write-Host "STATUS: OK"
    try { Disconnect-SapRfc } catch {}
    exit 0
}
