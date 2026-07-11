# =============================================================================
# sap_gm_meta.ps1  -  RFC meta reads for /sap-golden-master (READ-ONLY)
#
#   identity              RFC_SYSTEM_INFO -> SID + client (baseline (SID,CLIENT) key)
#   fingerprint -Report -Variant   VARID  -> exists + change stamp (drift guard)
#   keys -Table           DD03L KEYFLAG='X' -> key columns (table-leg sort)
#   trtext -Tr            E070/E07T -> status + owner + text (triage input)
#
# All reads are RFC_READ_TABLE / RFC_SYSTEM_INFO (FMODE=R, both systems). Creds
# default to the pinned profile. Variant *contents* snapshot (RS_VARIANT_CONTENTS*
# via the wrapper) is a SKILL.md concern; this reader uses the wrapper-free VARID
# stamp so the drift guard works even without dev-init.
#
# Output (stdout, parseable): one <ACTION>: line + STATUS: OK|NOT_FOUND|RFC_ERROR
# Exit: 0 = OK | 1 = NOT_FOUND | 2 = RFC/connect error.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Action,   # identity | fingerprint | keys | trtext
    [string] $Report = '', [string] $Variant = '', [string] $Table = '', [string] $Tr = '',
    [string] $SharedDir = '',
    [string] $Server = '', [string] $Sysnr = '', [string] $MessageServer = '',
    [string] $LogonGroup = '', [string] $SystemID = '',
    [string] $Client = '', [string] $UserId = '', [string] $Password = '', [string] $Language = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $SharedDir) { try { $SharedDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\sap-dev-core\shared')).Path } catch { $SharedDir = '' } }
$scripts = Join-Path $SharedDir 'scripts'
$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1') { $p = Join-Path $scripts $lib; if (Test-Path $p) { . $p } }
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }

if ($MyInvocation.InvocationName -eq '.') { return }
$g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer -LogonGroup $LogonGroup -SystemID $SystemID -Client $Client -User $UserId -Password $Password -Language $Language -DestName "SAPDEV_GM_META"
if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

try {
    switch ($Action.ToLower()) {
        'identity' {
            $sid = Get-SapResolverSysId -Destination $g_dest
            $client = if ($Client) { $Client } else { "$g_sapClient" }
            Write-Host ("IDENTITY: sid={0} client={1}" -f $sid, $client)
            Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'fingerprint' {
            if (-not $Report -or -not $Variant) { Write-Host "STATUS: NOT_FOUND"; Write-Host "FINGERPRINT: exists=NO"; Disconnect-SapRfc; exit 1 }
            $rows = Read-SapTableRows -Destination $g_dest -Table 'VARID' -Where "REPORT EQ '$($Report.ToUpper() -replace "'","''")' AND VARIANT EQ '$($Variant.ToUpper() -replace "'","''")'" -Fields @('REPORT','VARIANT','VERSION','ENAME','EDAT','AENAME','AEDAT','AETIME') -RowCount 1
            if (-not $rows -or $rows.Count -eq 0) { Write-Host "FINGERPRINT: exists=NO report=$Report variant=$Variant"; Write-Host "STATUS: NOT_FOUND"; Disconnect-SapRfc; exit 1 }
            $r = $rows[0]
            Write-Host ("FINGERPRINT: exists=YES report={0} variant={1} version={2} changed_by={3} changed_on={4} changed_at={5}" -f $Report.ToUpper(), $Variant.ToUpper(), "$($r.VERSION)", "$($r.AENAME)", "$($r.AEDAT)", "$($r.AETIME)")
            Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'keys' {
            if (-not $Table) { Write-Host "STATUS: NOT_FOUND"; Write-Host "KEYS:"; Disconnect-SapRfc; exit 1 }
            $rows = Read-SapTableRows -Destination $g_dest -Table 'DD03L' -Where "TABNAME EQ '$($Table.ToUpper() -replace "'","''")' AND KEYFLAG EQ 'X'" -Fields @('FIELDNAME','POSITION') -RowCount 100
            $keys = @($rows | Where-Object { "$($_.FIELDNAME)" -notmatch '^\.' } | Sort-Object { [int]("0" + ("$($_.POSITION)" -replace '\D','')) } | ForEach-Object { "$($_.FIELDNAME)" })
            if (-not $keys.Count) { Write-Host "KEYS: table=$Table"; Write-Host "STATUS: NOT_FOUND"; Disconnect-SapRfc; exit 1 }
            Write-Host ("KEYS: table={0} cols={1}" -f $Table.ToUpper(), ($keys -join ','))
            Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        'trtext' {
            if (-not $Tr) { Write-Host "STATUS: NOT_FOUND"; Write-Host "TR:"; Disconnect-SapRfc; exit 1 }
            $hdr = Read-SapTableRows -Destination $g_dest -Table 'E070' -Where "TRKORR EQ '$($Tr.ToUpper() -replace "'","''")'" -Fields @('TRKORR','TRSTATUS','AS4USER') -RowCount 1
            if (-not $hdr -or $hdr.Count -eq 0) { Write-Host "TR: exists=NO trkorr=$Tr"; Write-Host "STATUS: NOT_FOUND"; Disconnect-SapRfc; exit 1 }
            $txt = Read-SapTableRows -Destination $g_dest -Table 'E07T' -Where "TRKORR EQ '$($Tr.ToUpper() -replace "'","''")'" -Fields @('TRKORR','LANGU','AS4TEXT') -RowCount 10
            $t = ''; if ($txt.Count) { $e = $txt | Where-Object { "$($_.LANGU)".ToUpper() -eq 'E' } | Select-Object -First 1; $t = if ($e) { "$($e.AS4TEXT)" } else { "$($txt[0].AS4TEXT)" } }
            Write-Host ("TR: exists=YES trkorr={0} status={1} owner={2} text={3}" -f $Tr.ToUpper(), "$($hdr[0].TRSTATUS)", "$($hdr[0].AS4USER)", ($t -replace "[`t`r`n]",' '))
            Write-Host "STATUS: OK"; Disconnect-SapRfc; exit 0
        }
        default { Write-Host "STATUS: RFC_ERROR"; Write-Host "ERROR: unknown action $Action"; Disconnect-SapRfc; exit 2 }
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"; Write-Host "STATUS: RFC_ERROR"; Disconnect-SapRfc; exit 2
}
