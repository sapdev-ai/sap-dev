# =============================================================================
# sap_gen_rap_package.ps1  -  Build an abapGit-layout zip of a RAP file set
# -----------------------------------------------------------------------------
# PURE LOCAL (no SAP). Reads the files sap_gen_rap_generate.ps1 wrote into a work
# folder and re-lays them as an abapGit repository (STARTING_FOLDER /src/,
# FOLDER_LOGIC PREFIX) named by object, so ZABAPGIT_STANDALONE (verified present
# on S4D) can import them with no ADT. SRVB has no stable text serialization ->
# shipped as instructions only (srvb_spec.md carried into the zip root).
#
# Params: -WorkDir <generated set> -Stem <STEM> [-OutZip <path>]
# Output: RAPPKG: <file> lines + STATUS: OK files=<n> zip=<path> | STATUS: ERROR
# Exit: 0 ok | 2 error (missing input)
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$Stem,
    [string]$OutZip = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
function Fail([string]$m) { Write-Output "STATUS: ERROR msg=$m"; exit 2 }
if (-not (Test-Path -LiteralPath $WorkDir)) { Fail "work dir not found: $WorkDir" }
$Stem = ($Stem -replace '[^A-Za-z0-9_]', '').ToUpper(); $sl = $Stem.ToLower()
if (-not $OutZip) { $OutZip = Join-Path $WorkDir ("{0}_rap_abapgit.zip" -f $sl) }
function WNoBom([string]$p, [string]$t) { $enc = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllText($p, $t, $enc) }

# generated-file -> abapGit object-named file
$moves = @(
    @{ Src = "${sl}_zi.ddls.asddls"; Dst = "src/zi_${sl}.ddls.asddls" }
    @{ Src = "${sl}_zc.ddls.asddls"; Dst = "src/zc_${sl}.ddls.asddls" }
    @{ Src = "${sl}_zi.bdef.asbdef"; Dst = "src/zi_${sl}.bdef.asbdef" }
    @{ Src = "${sl}_zc.bdef.asbdef"; Dst = "src/zc_${sl}.bdef.asbdef" }
    @{ Src = "zbp_${sl}.clas.abap";  Dst = "src/zbp_${sl}.clas.abap" }
    @{ Src = "zui_${sl}.srvd.assrvd"; Dst = "src/zui_${sl}.srvd.assrvd" }
)

# staging dir under the work folder
$stage = Join-Path $WorkDir ("_abapgit_" + $sl)
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
[void][System.IO.Directory]::CreateDirectory((Join-Path $stage 'src'))

$abapgitXml = @"
<?xml version="1.0" encoding="utf-8"?>
<abapGit version="v1.0.0" serializer="LCL_OBJECT_DOT_ABAPGIT" serializer_version="v1.0.0">
 <asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0">
  <asx:values>
   <DATA>
    <MASTER_LANGUAGE>E</MASTER_LANGUAGE>
    <STARTING_FOLDER>/src/</STARTING_FOLDER>
    <FOLDER_LOGIC>PREFIX</FOLDER_LOGIC>
   </DATA>
  </asx:values>
 </asx:abap>
</abapGit>
"@
WNoBom (Join-Path $stage '.abapgit.xml') $abapgitXml

$n = 0
foreach ($m in $moves) {
    $s = Join-Path $WorkDir $m.Src
    if (-not (Test-Path -LiteralPath $s)) { Write-Output "RAPPKG: SKIP $($m.Src) (not generated)"; continue }
    $d = Join-Path $stage ($m.Dst -replace '/', '\')
    Copy-Item -LiteralPath $s -Destination $d -Force
    Write-Output "RAPPKG: $($m.Dst)"; $n++
}
# behavior class needs a .clas.xml metadata companion for abapGit
$clasXml = @"
<?xml version="1.0" encoding="utf-8"?>
<abapGit version="v1.0.0" serializer="LCL_OBJECT_CLAS" serializer_version="v1.0.0">
 <asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0">
  <asx:values>
   <VSEOCLASS>
    <CLSNAME>ZBP_$Stem</CLSNAME>
    <LANGU>E</LANGU>
    <DESCRIPT>RAP behavior pool $Stem</DESCRIPT>
    <STATE>1</STATE>
    <CLSCCINCL>X</CLSCCINCL>
    <FIXPT>X</FIXPT>
    <UNICODE>X</UNICODE>
   </VSEOCLASS>
  </asx:values>
 </asx:abap>
</abapGit>
"@
if (Test-Path (Join-Path $stage "src\zbp_${sl}.clas.abap")) { WNoBom (Join-Path $stage "src\zbp_${sl}.clas.xml") $clasXml; Write-Output "RAPPKG: src/zbp_${sl}.clas.xml"; $n++ }
# carry the SRVB spec + manual steps into the zip root (SRVB is not serializable)
foreach ($extra in @('srvb_spec.md', 'MANUAL_STEPS.md')) {
    $s = Join-Path $WorkDir $extra
    if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $stage $extra) -Force; Write-Output "RAPPKG: $extra"; $n++ }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $OutZip) { Remove-Item -LiteralPath $OutZip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $OutZip)
Remove-Item -Recurse -Force $stage
Write-Output "STATUS: OK files=$n zip=$OutZip"
exit 0
