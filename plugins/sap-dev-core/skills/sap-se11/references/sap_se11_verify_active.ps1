# =============================================================================
# sap_se11_verify_active.ps1  -  Post-deploy verification for SE11 objects
#
# Confirms a DDIC object exists in the ACTIVE workspace via RFC_READ_TABLE.
# Use after /sap-se11 create/update to detect the silent-failure case where
# the GUI script reports SUCCESS but DD02L / DD04L / DD01L / DD40L are
# empty (e.g. because a Check Structure popup was force-dismissed by the
# session-lock pre-unlock sweep, or the operator's TR was closed).
#
# Tokens replaced at run time:
#   %%SAP_SERVER%%   %%SAP_SYSNR%%   %%SAP_CLIENT%%
#   %%SAP_USER%%     %%SAP_PASSWORD%%   %%SAP_LANGUAGE%%
#   %%RFC_LIB_PS1%%  absolute path to sap_rfc_lib.ps1
#   %%OBJECT_TYPE%%  one of TABLE STRUCTURE DATAELEMENT DOMAIN
#                    TABLETYPE VIEW SEARCHHELP LOCKOBJECT TYPEGROUP
#   %%OBJECT_NAME%%  uppercase DDIC name
#
# Stdout contract (last line):
#   ACTIVE     -> active version found  (exit 0)
#   INACTIVE   -> only inactive version (exit 2)
#   MISSING    -> no row in DDIC catalog (exit 3)
#   ERROR:...  -> RFC failure           (exit 1)
# =============================================================================

. "%%RFC_LIB_PS1%%"

$type = "%%OBJECT_TYPE%%".ToUpperInvariant()
$name = "%%OBJECT_NAME%%".ToUpperInvariant()

# Map user-facing type to DDIC catalog table + key column.
$catalog = switch ($type) {
    "TABLE"        { @{ Tab="DD02L"; Key="TABNAME"   } }
    "STRUCTURE"    { @{ Tab="DD02L"; Key="TABNAME"   } }
    "DATAELEMENT"  { @{ Tab="DD04L"; Key="ROLLNAME"  } }
    "DOMAIN"       { @{ Tab="DD01L"; Key="DOMNAME"   } }
    "TABLETYPE"    { @{ Tab="DD40L"; Key="TYPENAME"  } }
    "VIEW"         { @{ Tab="DD25L"; Key="VIEWNAME"  } }
    "SEARCHHELP"   { @{ Tab="DD30L"; Key="SHLPNAME"  } }
    "LOCKOBJECT"   { @{ Tab="DD25L"; Key="VIEWNAME"  } }
    "TYPEGROUP"    { @{ Tab="DD40L"; Key="TYPENAME"  } }
    default        { $null }
}
if (-not $catalog) {
    Write-Host "ERROR: Unknown OBJECT_TYPE '$type'."
    exit 1
}

$g_dest = Connect-SapRfc -Server   "%%SAP_SERVER%%"   `
                         -Sysnr    "%%SAP_SYSNR%%"    `
                         -Client   "%%SAP_CLIENT%%"   `
                         -User     "%%SAP_USER%%"     `
                         -Password "%%SAP_PASSWORD%%" `
                         -Language "%%SAP_LANGUAGE%%" `
                         -DestName "SE11_VERIFY"
if (-not $g_dest) { exit 1 }

try {
    $fn = $g_dest.Repository.CreateFunction("RFC_READ_TABLE")
    $fn.SetValue("QUERY_TABLE", $catalog.Tab)
    $fn.SetValue("DELIMITER", "|")
    Add-RfcOption $fn ("{0} = '{1}'" -f $catalog.Key, $name)
    Add-RfcField  $fn $catalog.Key
    Add-RfcField  $fn "AS4LOCAL"
    $fn.Invoke($g_dest)
    $data = $fn.GetTable("DATA")

    $hasActive = $false
    $hasInactive = $false
    for ($i = 0; $i -lt $data.RowCount; $i++) {
        $data.CurrentIndex = $i
        $row = $data.GetString("WA")
        $cols = $row.Split('|') | ForEach-Object { $_.Trim() }
        if ($cols.Count -ge 2) {
            $loc = $cols[1].Trim()
            if ($loc -eq "A") { $hasActive   = $true }
            if ($loc -eq "N") { $hasInactive = $true }
        }
    }

    if ($hasActive) {
        Write-Host "ACTIVE"
        exit 0
    }
    elseif ($hasInactive) {
        Write-Host "INACTIVE"
        exit 2
    }
    else {
        Write-Host "MISSING"
        exit 3
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}
finally {
    Disconnect-SapRfc
}
