# =============================================================================
# sap_seq_vrsd.ps1  -  version-directory (VRSD) materiality helper (dot-source lib)
#
# Shared drill-down for /sap-transport-sequencer freeze materiality (and the v2 --deep
# downgrade compare). Pure RFC reads on VRSD -- proves an object really changed in a
# window and ties the change to its transport (KORRNUM). VRSD is TRANSP/FMODE=R on both
# ECC 6 and S/4HANA (probed 2026-07-10). No SVRS FM needed for v1 materiality.
#
# Dot-source, then:
#   $rows = Get-VrsdInWindow -Dest $d -From 20260101 -To 20260131 [-Max 20000]
#   -> rows: objtype, objname, versno, korrnum, author, datum
# =============================================================================

function Get-VrsdInWindow {
    param($Dest, [string]$From, [string]$To, [int]$Max = 20000)
    $rows = @()
    try {
        $fn = New-RfcReadTable -Destination $Dest -Table 'VRSD' -Delimiter ''
        [void]$fn.SetValue('ROWCOUNT', $Max)
        Add-RfcOption $fn "DATUM GE '$From' AND DATUM LE '$To'"
        foreach ($f in @('OBJTYPE','OBJNAME','VERSNO','KORRNUM','AUTHOR','DATUM')) { $t = $fn.GetTable('FIELDS'); [void]$t.Append(); [void]$t.SetValue('FIELDNAME',$f) }
        try { $fn.Invoke($Dest) } catch { if ("$($_.Exception.Message)" -match 'TABLE_WITHOUT_DATA') { return @() } else { throw } }
        $fm = $fn.GetTable('FIELDS'); $off=@{}; $len=@{}
        for ($i=0;$i -lt $fm.RowCount;$i++){$fm.CurrentIndex=$i;$nm=("$($fm.GetString('FIELDNAME'))").Trim();$off[$nm]=[int]$fm.GetString('OFFSET');$len[$nm]=[int]$fm.GetString('LENGTH')}
        $dt = $fn.GetTable('DATA')
        for ($i=0;$i -lt $dt.RowCount;$i++){
            $dt.CurrentIndex=$i; $wa="$($dt.GetString('WA'))"
            $rec = [ordered]@{}
            foreach ($f in @('OBJTYPE','OBJNAME','VERSNO','KORRNUM','AUTHOR','DATUM')) { $o=$off[$f];$l=$len[$f]; $rec[$f.ToLower()] = if ($o -lt $wa.Length) { $wa.Substring($o,[Math]::Min($l,$wa.Length-$o)).Trim() } else { '' } }
            $rows += ,([pscustomobject]$rec)
        }
    } catch { return @() }
    return $rows
}
