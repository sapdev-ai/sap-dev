# =============================================================================
# sap_interface_doc.ps1  -  Per-interface spec extractor for /sap-interface-inventory
#
# Reverse-engineers a single interface into doc_input.json for Claude to render:
#   idoc  <IDOCTYP> [<CIMTYP>]  -> IDOCTYPE_READ_COMPLETE (segment tree + fields)
#   rfcfm <FUNCNAME>           -> RPY_FUNCTIONMODULE_READ (signature)
#   dest  <RFCDEST>            -> RFCDES row (type + parsed options)
#
# READ-ONLY. All three FMs probed FMODE=R on S4D+EC2 (no wrapper, no GUI). Output
# is DATA only; Claude writes the prose spec, marking each section CONFIRMED
# (read live) vs INFERRED (narration). When /sap-idoc is installed the SKILL.md
# delegates IDoc rendering to it; this reader is the dependency-free fallback.
#
# Generic dump: after Invoke, every TABLES-direction param is dumped with ALL its
# line columns (resolved at runtime via LineType) - no hardcoded layouts, so it is
# release-tolerant and works uniformly across the FMs above.
#
# Output (stdout): DOC: mode=<m> target=<t> tables=<n> rows=<n>  +  JSON: <path>
#                  STATUS: OK | NOT_FOUND | RFC_ERROR
# Exit: 0 = OK | 1 = NOT_FOUND | 2 = RFC/connect error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Mode,     # idoc | rfcfm | dest
    [string]   $Target = '',                    # IDOCTYP / FUNCNAME / RFCDEST
    [string]   $Cimtyp = '',                    # idoc: optional extension type
    [string]   $SharedDir = '',
    [string]   $OutputDir = '',
    [string]   $RunId = '',
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
foreach ($lib in 'sap_rfc_lib.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

# Dump every TABLES-direction param of an invoked FM: [{name, rows:[{col:val}]}].
function Get-FmTablesDump {
    param($Fn)
    $out = @()
    $md = $Fn.Metadata
    for ($i = 0; $i -lt $md.ParameterCount; $i++) {
        $pm = $md[$i]
        if ("$($pm.Direction)" -ne 'Tables') { continue }
        $tbl = $Fn.GetTable($pm.Name)
        $cols = @(); $lt = $tbl.Metadata.LineType
        for ($f = 0; $f -lt $lt.FieldCount; $f++) { $cols += "$($lt[$f].Name)" }
        $rows = @()
        for ($r = 0; $r -lt $tbl.RowCount; $r++) {
            $tbl.CurrentIndex = $r
            $rec = [ordered]@{}
            foreach ($c in $cols) { $rec[$c] = "$($tbl.GetValue($c))".TrimEnd() }
            $rows += $rec
        }
        $out += [pscustomobject]@{ name = "$($pm.Name)"; columns = $cols; rowcount = $tbl.RowCount; rows = $rows }
    }
    return $out
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Target) { Write-Host "STATUS: NOT_FOUND"; Write-Host "DOC: mode=$Mode target= tables=0 rows=0"; exit 1 }
    $Mode = $Mode.ToLower()

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_IFDOC"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; Write-Host "DOC: mode=$Mode target=$Target tables=0 rows=0"; exit 2 }

    if (-not $OutputDir) { $OutputDir = (Get-Location).Path }
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

    try {
        $doc = [ordered]@{ schema = 'sapdev.interface_doc/1'; mode = $Mode; target = $Target; system = ''; tables = @() }
        try { $doc.system = "$((& { $si = $g_dest.Repository.CreateFunction('RFC_SYSTEM_INFO'); $si.Invoke($g_dest); $si.GetStructure('RFCSI_EXPORT').GetString('RFCSYSID') }))" } catch {}

        switch ($Mode) {
            'idoc' {
                $fn = $g_dest.Repository.CreateFunction('IDOCTYPE_READ_COMPLETE')
                $fn.SetValue('PI_IDOCTYP', $Target.ToUpper())
                if ($Cimtyp) { $fn.SetValue('PI_CIMTYP', $Cimtyp.ToUpper()) }
                try { $fn.Invoke($g_dest) } catch {
                    Write-Host "STATUS: NOT_FOUND"; Write-Host "DOC: mode=idoc target=$Target tables=0 rows=0 note=$(( $_.Exception.Message -replace '\s+',' ').Substring(0,[Math]::Min(60,$_.Exception.Message.Length)))"
                    Disconnect-SapRfc; exit 1
                }
                $doc.tables = Get-FmTablesDump -Fn $fn
                # if the type has no segments, treat as not found
                $seg = @($doc.tables | Where-Object { $_.name -eq 'PT_SEGMENTS' })
                if ($seg.Count -and $seg[0].rowcount -eq 0) { Write-Host "STATUS: NOT_FOUND"; Write-Host "DOC: mode=idoc target=$Target tables=0 rows=0"; Disconnect-SapRfc; exit 1 }
            }
            'rfcfm' {
                $fn = $g_dest.Repository.CreateFunction('RPY_FUNCTIONMODULE_READ')
                $fn.SetValue('FUNCTIONNAME', $Target.ToUpper())
                try { $fn.Invoke($g_dest) } catch {
                    Write-Host "STATUS: NOT_FOUND"; Write-Host "DOC: mode=rfcfm target=$Target tables=0 rows=0"
                    Disconnect-SapRfc; exit 1
                }
                $doc.tables = Get-FmTablesDump -Fn $fn
                # capture short text if present
                try { $doc | Add-Member -NotePropertyName short_text -NotePropertyValue "$($fn.GetString('SHORT_TEXT'))" } catch {}
            }
            'dest' {
                $rd = $g_dest.Repository.CreateFunction('RFC_READ_TABLE')
                $rd.SetValue('QUERY_TABLE','RFCDES'); $rd.SetValue('DELIMITER','|')
                $o = $rd.GetTable('OPTIONS'); $o.Append(); $o.SetValue('TEXT',"RFCDEST EQ '$($Target.ToUpper() -replace "'","''")'")
                foreach ($f in @('RFCDEST','RFCTYPE','RFCOPTIONS')) { $ff=$rd.GetTable('FIELDS'); $ff.Append(); $ff.SetValue('FIELDNAME',$f) }
                $rd.Invoke($g_dest)
                $data = $rd.GetTable('DATA')
                if ($data.RowCount -eq 0) { Write-Host "STATUS: NOT_FOUND"; Write-Host "DOC: mode=dest target=$Target tables=0 rows=0"; Disconnect-SapRfc; exit 1 }
                $data.CurrentIndex = 0
                $cells = ("$($data.GetString('WA'))") -split '\|'
                $doc.tables = @([pscustomobject]@{ name='RFCDES'; columns=@('RFCDEST','RFCTYPE','RFCOPTIONS'); rowcount=1; rows=@([ordered]@{ RFCDEST=$cells[0].Trim(); RFCTYPE=$cells[1].Trim(); RFCOPTIONS=($cells[2] -replace '(?i)(pass(word)?|pwd|secret|token)\s*[=:]\s*[^,;\s]+','$1=<redacted>') }) })
            }
            default { Write-Host "STATUS: RFC_ERROR"; Write-Host "DOC: mode=$Mode target=$Target tables=0 rows=0 note=unknown_mode"; Disconnect-SapRfc; exit 2 }
        }

        $jsonPath = Join-Path $OutputDir ("iface_doc_" + ($Target -replace '[^A-Za-z0-9_]', '_') + ".json")
        [System.IO.File]::WriteAllText($jsonPath, ($doc | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        $totalRows = ($doc.tables | Measure-Object -Property rowcount -Sum).Sum
        Write-Host ("DOC: mode={0} target={1} tables={2} rows={3}" -f $Mode, $Target, $doc.tables.Count, $totalRows)
        Write-Host "JSON: $jsonPath"
        Write-Host "STATUS: OK"
        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        Write-Host "STATUS: RFC_ERROR"
        Write-Host "DOC: mode=$Mode target=$Target tables=0 rows=0"
        Disconnect-SapRfc
        exit 2
    }
}
