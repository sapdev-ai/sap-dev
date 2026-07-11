# =============================================================================
# sap_rfcdes_parse.ps1  -  SM59 destination register for /sap-rfc-monitor
#
# Read-only inventory of the RFC destinations (the SM59 register) over pure RFC,
# with a TOLERANT parser for the RFCDES options blob. Emits one auditable row per
# destination: type, target host, logon user (when present in the blob), trust
# flag, stored-credential PRESENCE flag, and description - plus the inbound
# trusted-system ACL (RFCSYSACL). A row whose options blob will not parse is
# marked COULD_NOT_PARSE and reported with its length only, never dropped.
#
#   -Type <3|G|H|T|I|L|...>   filter by RFCTYPE (blank = all)
#   -Max  <n>                 cap destinations (0 = all)
#   -OutTsv <path>            also write the register as a TSV
#
# SECURITY (hard rules, per the skill plan):
#   * RFCDESSECU is NEVER read. Stored credentials are detected ONLY as the
#     presence of the password marker key (v=) in the RFCOPTIONS blob - a flag,
#     never a value.
#   * The raw options blob is NEVER echoed (stdout or TSV) - only parsed fields
#     + the blob length. No password-shaped value can leave this script.
#
# RFCOPTIONS grammar (probed live S4D + EC2 2026-07-11): concatenated
#   <1-char-key>=<value>,   pairs. Load-bearing keys: H=host, I=port/gwserv,
#   S=sysnr, N=path/SID, l=X trust, v=<marker> stored logon. A value may itself
#   contain '=' (e.g. X=LB=ON) so we split on the FIRST '=' only.
#
# Output (stdout, parseable by SKILL.md):
#   DEST: name=<d> type=<t>(<label>) target=<...> user=<u|-> trusted=<Y|N|?>
#         stored_cred=<Y|?> desc="<...>" parse=<OK|PARTIAL|COULD_NOT_PARSE>
#   TRUST: trustsys=<sid> dest=<d|-> passwd_reqd=<Y|N> sectype=<s>
#   STATUS: OK n=<dests> trusted=<n> stored=<n> parse_fail=<n> acl=<n> | RFC_ERROR
# Exit: 0 = OK | 2 = connect failure.
# =============================================================================

[CmdletBinding()]
param(
    [string]   $Type = '',
    [int]      $Max = 0,
    [int]      $MaxRows = 5000,
    [string]   $SharedDir = '',
    [string]   $SkillDir = '',
    [string]   $OutTsv = '',
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
if (-not $SkillDir) { $SkillDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$scripts = Join-Path $SharedDir 'scripts'

$__keep = @{ Server=$Server; Sysnr=$Sysnr; MessageServer=$MessageServer; LogonGroup=$LogonGroup; SystemID=$SystemID; Client=$Client; UserId=$UserId; Password=$Password; Language=$Language }
foreach ($lib in 'sap_rfc_lib.ps1','sap_object_resolver.ps1','sap_artifact_lib.ps1') {
    $p = Join-Path $scripts $lib
    if (Test-Path $p) { . $p }
}
foreach ($__k in @($__keep.Keys)) { Set-Variable -Name $__k -Value $__keep[$__k] }
if ($RunId) { $env:SAPDEV_RUN_ID = $RunId }

# --- helpers ---------------------------------------------------------------
function San { param([string] $s) return (("$s") -replace "[`t`r`n]", ' ').Trim() }
function Qz  { param([string] $s) return ((San $s) -replace '"', "'") }

$TYPE_LABEL = @{
    '3'='ABAP_CONN'; 'I'='INTERNAL'; 'G'='HTTP_EXT'; 'H'='HTTP_ABAP'; 'T'='TCP_IP';
    'L'='LOGICAL'; 'X'='ABAP_DRIVER'; 'S'='R2_OBSOLETE'; 'M'='CMC_OBSOLETE'; '2'='R2_OBSOLETE'
}
$OBSOLETE = @('S','M','2','X')

# Tolerant RFCOPTIONS parser: returns @{ map=<hash>; status=OK|PARTIAL|COULD_NOT_PARSE }.
function Parse-RfcOptions {
    param([string] $blob)
    $map = @{}; $seen = 0; $bad = 0
    foreach ($pair in ("$blob" -split ',')) {
        if (-not $pair) { continue }
        $seen++
        $ix = $pair.IndexOf('=')
        if ($ix -lt 1) { $bad++; continue }
        $k = $pair.Substring(0, $ix); $v = $pair.Substring($ix + 1)
        if (-not $map.ContainsKey($k)) { $map[$k] = $v }
    }
    $status = 'OK'
    if ($seen -gt 0 -and $map.Count -eq 0) { $status = 'COULD_NOT_PARSE' }
    elseif ($bad -gt 0) { $status = 'PARTIAL' }
    return @{ map = $map; status = $status }
}

# Render the "target" column from parsed keys, per destination type.
function Build-Target {
    param([string] $type, [hashtable] $m)
    $h = "$($m['H'])"; $port = "$($m['I'])"; $path = "$($m['N'])"; $sysnr = "$($m['S'])"
    switch ($type) {
        { $_ -in @('G','H') } { $t = $h; if ($port) { $t += ":$port" }; if ($path) { $t += $path }; return $t }
        'T'                   { $t = $h; if ($path) { $t += " [$path]" }; return $t }
        'L'                   { if ($h) { return "(ref: $h)" } else { return '(logical)' } }
        default               { $t = $h; if ($sysnr) { $t += " sysnr $sysnr" } elseif ($port) { $t += " $port" }; return $t }
    }
}

function Write-Tsv {
    param([string] $Path, [string] $Header, [object[]] $Lines)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($Header)
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    $g_dest = Connect-SapRfc -Server $Server -Sysnr $Sysnr -MessageServer $MessageServer `
                             -LogonGroup $LogonGroup -SystemID $SystemID `
                             -Client $Client -User $UserId -Password $Password -Language $Language `
                             -DestName "SAPDEV_RFCDES"
    if (-not $g_dest) { Write-Host "STATUS: RFC_ERROR"; exit 2 }

    try {
        # ---- keys + type (narrow read, well under the RFC_READ_TABLE limit) ----
        $where = ''
        if ($Type) { $esc = ($Type -replace "'", "''"); $where = "RFCTYPE EQ '$esc'" }
        $keys = Read-SapTableRows -Destination $g_dest -Table 'RFCDES' -Where $where -Fields @('RFCDEST','RFCTYPE') -RowCount $MaxRows

        # ---- options blob (separate narrow projection, keyed by RFCDEST) -------
        $optMap = @{}
        $opts = Read-SapTableRows -Destination $g_dest -Table 'RFCDES' -Where $where -Fields @('RFCDEST','RFCOPTIONS') -RowCount $MaxRows
        foreach ($o in @($opts)) { $optMap["$(San $o.RFCDEST)"] = "$($o.RFCOPTIONS)" }

        # ---- descriptions (RFCDOC), first non-empty per dest ------------------
        $descMap = @{}
        try {
            $docs = Read-SapTableRows -Destination $g_dest -Table 'RFCDOC' -Fields @('RFCDEST','RFCDOC1') -RowCount $MaxRows
            foreach ($d in @($docs)) { $dn = "$(San $d.RFCDEST)"; $dt = "$(San $d.RFCDOC1)"; if ($dn -and $dt -and -not $descMap.ContainsKey($dn)) { $descMap[$dn] = $dt } }
        } catch { }

        # ---- inbound trusted-system ACL (RFCSYSACL) ---------------------------
        $aclDests = @{}; $aclLines = @(); $aclN = 0
        try {
            $acl = Read-SapTableRows -Destination $g_dest -Table 'RFCSYSACL' -Fields @('RFCSYSID','RFCTRUSTSY','RFCDEST','RFCPASSWD','RFCSECTYPE') -RowCount $MaxRows
            foreach ($a in @($acl)) {
                $aclN++
                $ad = "$(San $a.RFCDEST)"; if ($ad) { $aclDests[$ad] = $true }
                $pw = if ("$(San $a.RFCPASSWD)" -eq 'X') { 'Y' } else { 'N' }
                $aclLines += ("TRUST: trustsys={0} dest={1} passwd_reqd={2} sectype={3}" -f "$(San $a.RFCSYSID)",$(if($ad){$ad}else{'-'}),$pw,"$(San $a.RFCSECTYPE)")
            }
        } catch { }

        $tsvLines = @()
        $nTrusted = 0; $nStored = 0; $nParseFail = 0; $n = 0
        $rows = @($keys)
        if ($Max -gt 0 -and $rows.Count -gt $Max) { $rows = $rows | Select-Object -First $Max }

        foreach ($r in $rows) {
            $name = San $r.RFCDEST
            $type = San $r.RFCTYPE
            $label = if ($TYPE_LABEL.ContainsKey($type)) { $TYPE_LABEL[$type] } else { "TYPE_$type" }
            $blob = $optMap[$name]
            $pr = Parse-RfcOptions $blob
            $m = $pr.map; $parse = $pr.status
            if ($parse -eq 'COULD_NOT_PARSE') { $nParseFail++ }

            $target = Build-Target $type $m
            $user = if ($m.ContainsKey('u') -and "$($m['u'])") { "$($m['u'])" } else { '-' }

            # trust: RFCOPTIONS l=X  OR  a matching RFCSYSACL entry
            $trusted = if (("$($m['l'])" -eq 'X') -or $aclDests.ContainsKey($name)) { 'Y' }
                       elseif ($type -in @('3','H')) { 'N' } else { '?' }
            if ($trusted -eq 'Y') { $nTrusted++ }

            # stored credential: presence of the v= marker only (never RFCDESSECU).
            # Absence is '?' for types that CAN carry stored logon (can't disprove
            # without reading RFCDESSECU, which we refuse), 'N' for the rest.
            $stored = if ($m.ContainsKey('v')) { 'Y' } elseif ($type -in @('3','G','H','T')) { '?' } else { 'N' }
            if ($stored -eq 'Y') { $nStored++ }

            $desc = if ($descMap.ContainsKey($name)) { Qz $descMap[$name] } else { '' }
            $blobLen = if ($blob) { "$blob".Length } else { 0 }

            Write-Host ("DEST: name={0} type={1}({2}) target={3} user={4} trusted={5} stored_cred={6} desc=`"{7}`" parse={8}" -f $name,$type,$label,$target,$user,$trusted,$stored,$desc,$parse)
            $tsvLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}" -f $name,$type,$label,$target,$user,$trusted,$stored,$desc,$parse,$blobLen)
            $n++
        }

        foreach ($l in $aclLines) { Write-Host $l }

        if ($OutTsv) {
            try {
                Write-Tsv $OutTsv "rfcdest`trfctype`ttype_label`ttarget`tuser`ttrusted`tstored_cred`tdescription`tparse`toptions_len" $tsvLines
                Write-Host "OUT_TSV: $OutTsv"
            } catch { }
        }

        Write-Host ("STATUS: OK n=$n trusted=$nTrusted stored=$nStored parse_fail=$nParseFail acl=$aclN")
        Disconnect-SapRfc
        exit 0
    } catch {
        Write-Host ("ERROR: {0}" -f (San $_.Exception.Message))
        Write-Host "STATUS: RFC_ERROR"
        Disconnect-SapRfc
        exit 2
    }
}
