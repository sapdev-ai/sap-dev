# =============================================================================
# sap_check_object_name.ps1  -  Validate a SAP object name against naming rules
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sap_check_object_name.ps1 `
#       -ObjectType PROGRAM -ObjectName ZSDRMAT [-CustomUrl C:\sap_dev_work\custom] `
#       [-RulesFile <explicit path>]
#
# Resolution order for the rules file:
#   1. -RulesFile (explicit override, if provided)
#   2. {CustomUrl}\sap_object_naming_rules.tsv (per-customer override)
#   3. <SAP_DEV_CORE_SHARED_DIR>\tables\sap_object_naming_rules.tsv (default)
#
# Output:
#   stdout: "OK <type> <name>"  on match
#           "VIOLATION <type> <name> expected=<pattern> example=<example>" on mismatch
#           "UNKNOWN_TYPE <type>" if the OBJECT_TYPE is not in the rules file
#           "RULES_NOT_FOUND <path>" if no rules file is found
#   exit:   0 = OK, 1 = VIOLATION, 2 = UNKNOWN_TYPE / RULES_NOT_FOUND
# =============================================================================

param(
    [Parameter(Mandatory=$true)] [string] $ObjectType,
    [Parameter(Mandatory=$true)] [string] $ObjectName,
    [string] $CustomUrl = '',
    [string] $RulesFile = ''
)

$ErrorActionPreference = 'Stop'

# Best-effort: dot-source the structured logger so violations are recorded.
$logLib = Join-Path $PSScriptRoot 'sap_log_lib.ps1'
$logRun = $null
if (Test-Path $logLib) {
    try {
        . $logLib
        $logRun = Start-SapLog -Skill 'sap-check-object-name' -Params @{
            object_type = $ObjectType
            object_name = $ObjectName
        }
    } catch { $logRun = $null }
}

function End-Log([string]$status, [int]$code, [string]$errClass = '', [string]$errMsg = '') {
    if ($null -ne $logRun) {
        try {
            if ($errClass) {
                Stop-SapLog -Run $logRun -Status $status -ExitCode $code -ErrorClass $errClass
            } else {
                Stop-SapLog -Run $logRun -Status $status -ExitCode $code
            }
        } catch {}
    }
}

# 1. Resolve rules file
$resolved = ''
if ($RulesFile -and (Test-Path $RulesFile)) {
    $resolved = $RulesFile
} elseif ($CustomUrl) {
    $custom = Join-Path $CustomUrl 'sap_object_naming_rules.tsv'
    if (Test-Path $custom) { $resolved = $custom }
}
if (-not $resolved) {
    $defaultPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tables\sap_object_naming_rules.tsv'
    if (Test-Path $defaultPath) { $resolved = $defaultPath }
}
if (-not $resolved) {
    Write-Output "RULES_NOT_FOUND sap_object_naming_rules.tsv"
    End-Log 'FAILED' 2 'RULES_NOT_FOUND' 'rules file not found'
    exit 2
}

# 2. Load rules (TAB-delimited, header on first line)
$rules = @{}
$lines = Get-Content -LiteralPath $resolved -Encoding UTF8
$headerSeen = $false
foreach ($line in $lines) {
    if (-not $line.Trim()) { continue }
    if (-not $headerSeen) { $headerSeen = $true; continue }
    $cols = $line -split "`t"
    if ($cols.Count -lt 4) { continue }
    $rules[$cols[0].Trim().ToUpper()] = @{
        Pattern     = $cols[1]
        Example     = $cols[2]
        Description = $cols[3]
    }
}

# 3. Lookup
$key = $ObjectType.Trim().ToUpper()
if (-not $rules.ContainsKey($key)) {
    Write-Output "UNKNOWN_TYPE $ObjectType"
    End-Log 'SKIPPED' 2 'UNKNOWN_OBJECT_TYPE' "no rule for $ObjectType"
    exit 2
}

$rule = $rules[$key]
$pattern = $rule.Pattern

# 4. Match — case-insensitive (SAP names are case-insensitive on the wire,
#    upper-cased server-side). Anchored patterns assume upper-case in the rules.
if ($ObjectName.ToUpper() -match $pattern) {
    Write-Output "OK $ObjectType $ObjectName"
    End-Log 'SUCCESS' 0
    exit 0
} else {
    Write-Output ("VIOLATION {0} {1} expected={2} example={3}" -f $ObjectType, $ObjectName, $pattern, $rule.Example)
    End-Log 'SUCCESS' 1 'OBJECT_NAMING_VIOLATION' "$ObjectType $ObjectName"
    exit 1
}
