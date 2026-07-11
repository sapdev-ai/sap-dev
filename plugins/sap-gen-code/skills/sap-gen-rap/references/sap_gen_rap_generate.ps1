# =============================================================================
# sap_gen_rap_generate.ps1  -  Render a consistent managed-RAP file set
# -----------------------------------------------------------------------------
# Resolves the field list + keys of a base table (live DDIF_FIELDINFO_GET, or an
# offline -FieldsFile for golden-file tests) and renders the mutually-consistent
# RAP artifacts (root CDS, projection CDS, two BDEFs, behavior pool, SRVD,
# MANUAL_STEPS.md, srvb_spec.md) into a work folder. Deterministic + offline-
# testable; the only SAP touch is a read (DDIF_FIELDINFO_GET, FMODE=R). No writes.
#
# Scope: managed / OData V2 / root-only / non-draft. Dialect dispatch:
#   -Release 754  -> classic `define root view` + @AbapCatalog.sqlViewName
#   -Release 755  -> `define root view entity` (no SQL view), `strict ( 2 )`
#
# Params:
#   -Table <ZTABLE> -Stem <STEM> [-Package $TMP] -Release <754|755> -OutDir <dir>
#   [-Label "text"] [-FieldsFile <tsv: FIELDNAME<TAB>KEYFLAG>] [-TemplatesDir <dir>]
#   [-WorkDir <dir>]
# Output: the file set + `RAPGEN: <artifact> <name> file=<path>` lines +
#   `STATUS: OK fields=<n> keys=<n> release=<r> dir=<...>` | `STATUS: ERROR msg=<..>`
# Exit: 0 ok | 2 error (no fields / bad input / connect)
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Table,
    [Parameter(Mandatory)][string]$Stem,
    [Parameter(Mandatory)][ValidateSet('754','755')][string]$Release,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Package = '$TMP',
    [string]$Label = '',
    [string]$FieldsFile = '',
    [string]$TemplatesDir = '',
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if ($WorkDir) { $env:SAPDEV_AI_WORK_DIR = $WorkDir }
function Fail([string]$m) { Write-Output "STATUS: ERROR msg=$m"; exit 2 }

$Table = $Table.ToUpper(); $Stem = ($Stem -replace '[^A-Za-z0-9_]', '').ToUpper()
if (-not $Stem) { Fail 'CC_SCAN_BAD_INPUT empty stem' }
if (-not $TemplatesDir) { $TemplatesDir = Join-Path (Split-Path -Parent $PSCommandPath) 'templates' }
if (-not $Label) { $Label = "$Stem (generated)" }
if ($Label.Length -gt 60) { $Label = $Label.Substring(0, 60) }

function To-Pascal([string]$s) {
    ($s -split '_' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1).ToLower() }) -join ''
}
function Sub([string]$text, [hashtable]$map) { foreach ($k in $map.Keys) { $text = $text.Replace("%%$k%%", [string]$map[$k]) }; return $text }
function Write-NoBom([string]$p, [string]$t) { $enc = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllText($p, $t, $enc) }
function Load-Tpl([string]$name) { $p = Join-Path $TemplatesDir $name; if (-not (Test-Path $p)) { Fail "template not found: $name" }; return (Get-Content -LiteralPath $p -Raw) }

# ---- field list -------------------------------------------------------------
$fields = @()   # @{ Field; Key(bool) }
if ($FieldsFile) {
    if (-not (Test-Path -LiteralPath $FieldsFile)) { Fail "fields file not found: $FieldsFile" }
    $ln = @(Get-Content -LiteralPath $FieldsFile)
    $start = 0; if ($ln.Count -ge 1 -and $ln[0] -match '(?i)FIELDNAME') { $start = 1 }
    for ($i = $start; $i -lt $ln.Count; $i++) {
        if (-not $ln[$i].Trim()) { continue }
        $c = $ln[$i] -split "`t"
        $fn = $c[0].Trim().ToUpper(); if (-not $fn -or $fn -eq 'MANDT' -or $fn.StartsWith('.')) { continue }
        $kf = if ($c.Count -gt 1) { $c[1].Trim().ToUpper() -eq 'X' } else { $false }
        $fields += @{ Field = $fn; Key = $kf }
    }
} else {
    # cross-plugin: sap-gen-rap is in sap-gen-code, so 4 levels up (to plugins/) then sap-dev-core
    $shared = Join-Path (Split-Path -Parent $PSCommandPath) '..\..\..\..\sap-dev-core\shared\scripts'
    . (Join-Path $shared 'sap_rfc_lib.ps1')
    $dest = Connect-SapRfc -DestName 'RAPGEN'
    if (-not $dest) { Fail 'RFC_LOGON_FAILED' }
    try {
        $ff = $dest.Repository.CreateFunction('DDIF_FIELDINFO_GET'); $ff.SetValue('TABNAME', $Table); $ff.Invoke($dest)
        $t = $ff.GetTable('DFIES_TAB')
        for ($i = 0; $i -lt $t.RowCount; $i++) {
            $t.CurrentIndex = $i; $fn = ([string]$t.GetString('FIELDNAME')).Trim().ToUpper()
            if (-not $fn -or $fn -eq 'MANDT' -or $fn.StartsWith('.')) { continue }
            $fields += @{ Field = $fn; Key = (([string]$t.GetString('KEYFLAG')).Trim().ToUpper() -eq 'X') }
        }
    } finally { try { Disconnect-SapRfc -Destination $dest } catch {}; try { Disconnect-SapRfc } catch {} }
}
if ($fields.Count -eq 0) { Fail "no usable fields for table $Table (does it exist?)" }
$keys = @($fields | Where-Object { $_.Key })
if ($keys.Count -eq 0) { Fail "table $Table has no key fields (RAP needs a key)" }

# ---- names ------------------------------------------------------------------
$rootView = "ZI_$Stem"; $projView = "ZC_$Stem"; $bpClass = "ZBP_$Stem"
$svcDef = "ZUI_$Stem"; $svcBind = "ZUI_${Stem}_O2"
$sqlView = ('ZI' + $Stem); if ($sqlView.Length -gt 16) { $sqlView = $sqlView.Substring(0, 16) }
$alias = To-Pascal $Stem
$keyElem = To-Pascal $keys[0].Field
$stemLower = $Stem.ToLower()

# ---- field-block rendering --------------------------------------------------
$rootLines = @(); $projLines = @(); $mapLines = @()
for ($i = 0; $i -lt $fields.Count; $i++) {
    $f = $fields[$i]; $al = To-Pascal $f.Field; $comma = if ($i -lt $fields.Count - 1) { ',' } else { '' }
    if ($f.Key) {
        $rootLines += ("  key {0} as {1}{2}" -f $f.Field.ToLower(), $al, $comma)
        $projLines += ("  key {0}{1}" -f $al, $comma)
    } else {
        $rootLines += ("      {0} as {1}{2}" -f $f.Field.ToLower(), $al, $comma)
        $projLines += ("      {0}{1}" -f $al, $comma)
    }
    $mapLines += ("    {0} = {1};" -f $al, $f.Field.ToLower())
}
$rootFields = $rootLines -join "`r`n"; $projFields = $projLines -join "`r`n"; $bdefMap = $mapLines -join "`r`n"
$strict = if ($Release -eq '755') { "strict ( 2 );`r`n" } else { '' }

$map = @{
    STEM = $Stem; STEM_LOWER = $stemLower; TABLE = $Table.ToLower(); LABEL = $Label
    ROOT_VIEW = $rootView; PROJ_VIEW = $projView; BEHAVIOR_CLASS = $bpClass
    BEHAVIOR_CLASS_LOWER = $bpClass.ToLower(); SERVICE_DEF = $svcDef; SERVICE_BINDING = $svcBind
    SQL_VIEW = $sqlView; ALIAS = $alias; KEY_ELEMENT = $keyElem; STRICT = $strict
    ROOT_FIELDS = $rootFields; PROJ_FIELDS = $projFields; BDEF_MAPPING = $bdefMap
    RELEASE = $Release; WORKDIR = $OutDir
}

[void][System.IO.Directory]::CreateDirectory($OutDir)
$rootTpl = if ($Release -eq '754') { 'rap_root_view_754.ddl.tpl' } else { 'rap_root_view_755.ddl.tpl' }
$rootFile = "${stemLower}_zi.ddls.asddls"
$map['ROOT_FILE'] = $rootFile
$artifacts = @(
    @{ Tpl = $rootTpl;                     Out = $rootFile;                    Kind = 'root-cds' }
    @{ Tpl = 'rap_projection_view.ddl.tpl'; Out = "${stemLower}_zc.ddls.asddls";  Kind = 'projection-cds' }
    @{ Tpl = 'rap_bdef_managed.bdef.tpl';   Out = "${stemLower}_zi.bdef.asbdef";  Kind = 'interface-bdef' }
    @{ Tpl = 'rap_bdef_projection.bdef.tpl'; Out = "${stemLower}_zc.bdef.asbdef"; Kind = 'projection-bdef' }
    @{ Tpl = 'rap_behavior_pool.clas.abap.tpl'; Out = "zbp_${stemLower}.clas.abap"; Kind = 'behavior-pool' }
    @{ Tpl = 'rap_srvd.srvd.tpl';           Out = "zui_${stemLower}.srvd.assrvd"; Kind = 'service-def' }
    @{ Tpl = 'rap_manual_steps.md.tpl';     Out = 'MANUAL_STEPS.md';             Kind = 'manual-steps' }
)
foreach ($a in $artifacts) {
    $txt = Sub (Load-Tpl $a.Tpl) $map
    $p = Join-Path $OutDir $a.Out
    Write-NoBom $p $txt
    Write-Output ("RAPGEN: {0} file={1}" -f $a.Kind, $a.Out)
}
# SRVB spec (no stable text serialization -> instructions)
$srvbSpec = @"
# Service Binding $svcBind (create in ADT -- no text serialization)

Type: OData V2 - UI
Service Definition: $svcDef
Binding name: $svcBind

Steps: ADT > New > Service Binding > bind $svcDef as OData V2 - UI, name $svcBind,
Activate, then Publish (or tcode /IWFND/MAINT_SERVICE). Verify with: /sap-gen-rap verify.
"@
Write-NoBom (Join-Path $OutDir 'srvb_spec.md') $srvbSpec
Write-Output "RAPGEN: service-binding file=srvb_spec.md"

Write-Output ("STATUS: OK fields=$($fields.Count) keys=$($keys.Count) release=$Release root=$rootView proj=$projView dir=$OutDir")
exit 0
