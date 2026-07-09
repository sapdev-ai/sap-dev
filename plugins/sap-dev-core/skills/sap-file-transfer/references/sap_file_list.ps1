# =============================================================================
# sap_file_list.ps1
# -----------------------------------------------------------------------------
# Headless application-server directory listing / file-existence probe for
# /sap-file-transfer's `list` and `exists` modes. Replaces any AL11 GUI
# scraping: EPS2_GET_DIRECTORY_LISTING is remote-enabled and locale-proof.
#
# FM strategy: try EPS2_GET_DIRECTORY_LISTING first (long filenames); fall back
# to the legacy EPS_GET_DIRECTORY_LISTING (40-char names, emits a WARN when a
# name hits the cap). Import/table parameter names differ per FM, so they are
# resolved from the FM metadata instead of being hard-coded.
#
# Usage (32-bit PowerShell -- SAP NCo 3.1 lives in the 32-bit GAC):
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass `
#       -File sap_file_list.ps1 -Action list   -DirName /tmp [-Mask 'sapdev*']
#   ... -Action exists -FilePath /tmp/foo.txt
#
# Connection: dot-sources shared sap_rfc_lib.ps1; Connect-SapRfc falls back to
# the AI session's pinned connection profile (DPAPI password) when no explicit
# endpoint parameters are supplied.
#
# Stdout: one `FILE: name=<n> size=<bytes>` line per entry, then
#   list:   `STATUS: OK count=<n> dir=<dir> fm=<FM used>`
#   exists: `STATUS: EXISTS|NOT_FOUND file=<path> fm=<FM used>`
# Errors:   `STATUS: RFC_ERROR <message>` (exit 2)
# Exit: 0 = OK / EXISTS, 1 = NOT_FOUND, 2 = RFC or input error.
# =============================================================================
[CmdletBinding()]
param(
    [ValidateSet('list','exists')] [string] $Action = 'list',
    [string] $DirName  = '',
    [string] $Mask     = '',
    [string] $FilePath = ''
)

$ErrorActionPreference = 'Stop'

# --- resolve shared scripts dir: references -> skill -> skills -> plugin root
$sharedScripts = Join-Path $PSScriptRoot '..\..\..\shared\scripts'
$rfcLib = Join-Path $sharedScripts 'sap_rfc_lib.ps1'
if (-not (Test-Path $rfcLib)) {
    Write-Output "STATUS: RFC_ERROR sap_rfc_lib.ps1 not found at $rfcLib"
    exit 2
}
. $rfcLib

if ($Action -eq 'exists') {
    if (-not $FilePath) { Write-Output 'STATUS: RFC_ERROR -FilePath is required for exists'; exit 2 }
    # Split on the LAST separator, tolerating both unix and windows app servers.
    $sepIdx = [Math]::Max($FilePath.LastIndexOf('/'), $FilePath.LastIndexOf('\'))
    if ($sepIdx -lt 1) { Write-Output "STATUS: RFC_ERROR cannot split '$FilePath' into dir + name"; exit 2 }
    $DirName  = $FilePath.Substring(0, $sepIdx)
    $wantName = $FilePath.Substring($sepIdx + 1)
} elseif (-not $DirName) {
    Write-Output 'STATUS: RFC_ERROR -DirName is required for list'
    exit 2
}

try {
    $dest = Connect-SapRfc
    if (-not $dest) { Write-Output 'STATUS: RFC_ERROR Connect-SapRfc returned no destination (run /sap-login first)'; exit 2 }
} catch {
    Write-Output "STATUS: RFC_ERROR $($_.Exception.Message)"
    exit 2
}

function Invoke-DirListing {
    param($dest, [string]$fmName, [string]$dir, [string]$mask)
    $fn = $dest.Repository.CreateFunction($fmName)   # throws FunctionNotFound if absent
    $meta = $fn.Metadata
    # Resolve the directory-name import parameter from metadata (EPS2 uses
    # IV_DIR_NAME, EPS uses DIR_NAME). Direction check is load-bearing: EPS2
    # ALSO has an EXPORT param named DIR_NAME -- matching it sets nothing and
    # the FM then lists an empty directory name (0 rows, false NOT_FOUND).
    $dirParam = $null; $maskParam = $null
    for ($i = 0; $i -lt $meta.ParameterCount; $i++) {
        $p = $meta[$i].Name
        if ("$($meta[$i].Direction)" -ne 'IMPORT') { continue }
        if ($p -in @('IV_DIR_NAME','DIR_NAME') -and -not $dirParam)   { $dirParam = $p }
        if ($p -in @('IV_FILE_MASK','FILE_MASK') -and -not $maskParam) { $maskParam = $p }
    }
    if (-not $dirParam) { throw "FM_INCOMPATIBLE:no directory-name import parameter on $fmName" }
    $fn.SetValue($dirParam, $dir)
    if ($mask -and $maskParam) { $fn.SetValue($maskParam, $mask) }
    try {
        $fn.Invoke($dest)
    } catch {
        # Unwrap PowerShell's MethodInvocationException down to the NCo exception,
        # then classify by the ABAP exception key (locale-independent).
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        $key = ''
        try { if ($ex.PSObject.Properties['Key']) { $key = "$($ex.Key)" } } catch {}
        if (-not $key) { $key = "$($ex.Message)" }
        # Dir exists but has no matching entries -> a clean empty result, NOT an error.
        if ($key -match 'EMPTY_DIRECTORY_LIST') { return @() }
        # Dir missing / not readable by the SAP process -> caller maps to a clear message.
        if ($key -match 'READ_DIRECTORY_FAILED|NO_AUTHORITY|AUTHORIZATION') { throw "DIR_UNREADABLE:$key" }
        throw   # anything else propagates unchanged
    }
    $tbl = $fn.GetTable('DIR_LIST')
    # Field names differ (EPS2FILI vs EPSFILI); resolve NAME/SIZE-ish columns.
    # NCo's RfcStructureMetadata is NOT IEnumerable -- iterate by FieldCount/index.
    $nameField = $null; $sizeField = $null; $mtimField = $null
    $lineType = $tbl.Metadata.LineType
    for ($fi = 0; $fi -lt $lineType.FieldCount; $fi++) {
        $fName = $lineType[$fi].Name
        if ($fName -match 'NAME' -and -not $nameField) { $nameField = $fName }
        if ($fName -match 'SIZE' -and -not $sizeField) { $sizeField = $fName }
        if ($fName -eq 'MTIM' -and -not $mtimField)    { $mtimField = $fName }
    }
    if (-not $nameField) { throw "no NAME-like field in $fmName DIR_LIST" }
    $rows = @()
    for ($r = 0; $r -lt $tbl.RowCount; $r++) {
        $tbl.CurrentIndex = $r
        $n = ($tbl.GetString($nameField)).Trim()
        $s = if ($sizeField) { ($tbl.GetString($sizeField)).Trim() } else { '' }
        $m = if ($mtimField) { ($tbl.GetString($mtimField)).Trim() } else { '' }
        if ($n) { $rows += [pscustomobject]@{ name = $n; size = $s; mtime = $m } }
    }
    return $rows
}

$fmUsed = 'EPS2_GET_DIRECTORY_LISTING'
try {
    try {
        $rows = Invoke-DirListing -dest $dest -fmName 'EPS2_GET_DIRECTORY_LISTING' -dir $DirName -mask $Mask
    } catch {
        $m = "$($_.Exception.Message)"
        # A directory that exists-but-unreadable or a business exception is NOT a
        # reason to try the legacy FM -- only a genuinely absent EPS2 is. Fall back
        # ONLY when the repository could not resolve EPS2 at all.
        if ($m -match 'DIR_UNREADABLE:') { throw }
        if ($m -notmatch 'not (found|exist)|FU_NOT_FOUND|metadata|FM_INCOMPATIBLE') { throw }
        $fmUsed = 'EPS_GET_DIRECTORY_LISTING'
        $rows = Invoke-DirListing -dest $dest -fmName 'EPS_GET_DIRECTORY_LISTING' -dir $DirName -mask $Mask
        foreach ($r in $rows) {
            if ($r.name.Length -ge 40) { Write-Output "WARN: name '$($r.name)' hits the 40-char EPS cap - upgrade path is EPS2" }
        }
    }
} catch {
    $msg = "$($_.Exception.Message)"
    if ($msg -match 'DIR_UNREADABLE:(.+)$') {
        # Missing / unreadable directory. For `exists` the file certainly isn't there.
        if ($Action -eq 'exists') { Write-Output "STATUS: NOT_FOUND file=$FilePath fm=$fmUsed (dir unreadable: $($Matches[1]))"; exit 1 }
        Write-Output "STATUS: DIR_UNREADABLE dir=$DirName fm=$fmUsed reason=$($Matches[1])"
        exit 1
    }
    Write-Output "STATUS: RFC_ERROR $msg"
    exit 2
}

if ($Action -eq 'exists') {
    $rows = @($rows)
    $hit = $rows | Where-Object { $_.name -ceq $wantName } | Select-Object -First 1
    if (-not $hit) { $hit = $rows | Where-Object { $_.name -ieq $wantName } | Select-Object -First 1 }
    if ($hit) {
        Write-Output "FILE: name=$($hit.name) size=$($hit.size) mtime=$($hit.mtime)"
        Write-Output "STATUS: EXISTS file=$FilePath fm=$fmUsed"
        exit 0
    }
    Write-Output "STATUS: NOT_FOUND file=$FilePath fm=$fmUsed"
    exit 1
}

# Force array context: a single returned row is not an array under Windows
# PowerShell 5.1, so @().Count is required for a correct count (not blank/1).
$rowArr = @($rows)
foreach ($r in $rowArr) { Write-Output "FILE: name=$($r.name) size=$($r.size) mtime=$($r.mtime)" }
Write-Output "STATUS: OK count=$($rowArr.Count) dir=$DirName fm=$fmUsed"
exit 0
