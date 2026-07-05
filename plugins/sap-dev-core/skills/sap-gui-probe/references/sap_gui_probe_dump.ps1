# =============================================================================
# sap_gui_probe_dump.ps1
# -----------------------------------------------------------------------------
# Token-substitutes the sap-gui-inspect VBS template and runs it via
# 32-bit cscript to dump the currently visible SAP GUI screen.
#
# This is a thin wrapper -- the dump engine lives in sap-gui-inspect.
# The probe skill reuses it verbatim rather than forking a copy.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sap_gui_probe_dump.ps1 `
#       -OutputFile <abs-path> `
#       [-Mode tree|menu|type|id|wnd] `        # default tree
#       [-Filter <text>] `                      # required for type/id/wnd
#       [-Window <0-5>] `                       # restrict to one window
#       [-MaxDepth <n>]                          # default 10
#
# Output: last line of stdout is "DONE" or "ERROR: <text>" (forwarded from
# the underlying VBS). The dump itself goes to -OutputFile (UTF-16LE).
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OutputFile,

    [ValidateSet('tree','menu','type','id','wnd')]
    [string] $Mode = 'tree',

    [string] $Filter = '',
    [string] $Window = '',
    [int]    $MaxDepth = 10,

    # Pinned SAP GUI session, e.g. "/app/con[0]/ses[1]". Default targets the
    # first connection's first session (preserves today's behaviour). If the
    # caller wants per-AI-session resolution they should call
    # Get-SapCurrentSessionPath (in sap_connection_lib.ps1) and pass the
    # result here.
    [string] $SessionPath = '/app/con[0]/ses[0]'
)

# Locate the sap-gui-inspect VBS template (sibling skill in the same plugin).
$thisDir   = Split-Path -Parent $MyInvocation.MyCommand.Path        # ...\sap-gui-probe\references
$skillsDir = Split-Path -Parent (Split-Path -Parent $thisDir)        # ...\skills
$templateVbs = Join-Path $skillsDir 'sap-gui-inspect\references\sap_gui_object_details.vbs'

if (-not (Test-Path $templateVbs)) {
    Write-Error "sap-gui-inspect VBS template not found at: $templateVbs"
    exit 1
}

# Emit the substituted VBS to a sibling temp file (one per dump so the caller
# can keep them for forensics if desired).
$outDir = Split-Path -Parent $OutputFile
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$stamp     = Get-Date -Format 'yyyyMMddHHmmssfff'
$runtimeVbs = Join-Path $outDir ("_dump_" + $stamp + ".vbs")

$content = [System.IO.File]::ReadAllText($templateVbs, [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%MODE%%',         $Mode)
$content = $content.Replace('%%FILTER%%',       $Filter)
$content = $content.Replace('%%WINDOW%%',       $Window)
$content = $content.Replace('%%MAX_DEPTH%%',    "$MaxDepth")
$content = $content.Replace('%%OUTPUT_FILE%%',  $OutputFile)

# %%SESSION_PATH%% is anchored to ONE specific assignment line. A naive
# global .Replace() would also rewrite any sentinel comparison line that
# refers to the same literal token (see the BUG NOTE inside the template
# VBS) and silently retarget the script to ses[0]. Anchored regex makes
# the substitution explicit and audit-friendly. Escape any literal $ in
# the replacement so PowerShell's -replace doesn't treat it as a back-ref.
$sessionPathLiteral = $SessionPath -replace '\$','$$$$'
$content = $content -replace `
    '(?m)^(\s*Dim\s+SESSION_PATH\s*:\s*SESSION_PATH\s*=\s*")%%SESSION_PATH%%(")', `
    ('${1}' + $sessionPathLiteral + '${2}')

[System.IO.File]::WriteAllText($runtimeVbs, $content, [System.Text.UnicodeEncoding]::new($false, $true))

# 32-bit cscript is required for SAP GUI Scripting COM bindings.
$cscript = 'C:\Windows\SysWOW64\cscript.exe'
& $cscript //NoLogo $runtimeVbs
$rc = $LASTEXITCODE

# Best-effort cleanup of the runtime VBS so the run folder stays scannable.
Remove-Item -Path $runtimeVbs -ErrorAction SilentlyContinue

exit $rc
