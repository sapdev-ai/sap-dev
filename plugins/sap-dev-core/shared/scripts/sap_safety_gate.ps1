<#
.SYNOPSIS
    Rule 0 safety gate -- environment guard for every write-capable sap-dev
    skill. Contract: shared/rules/safety_policy.md (the highest-priority rule
    file in the suite).

.DESCRIPTION
    Three actions:

    assert   (pure-local; any PowerShell bitness)
             Resolve the AI session's pinned connection profile and decide
             whether a SAP-mutating step may proceed. Fail closed: no
             profile, blank environment, unknown environment value, or an
             internal error all refuse. PRD verdicts follow
             userConfig.prod_write_policy (BLOCK default / TYPED_CONFIRM)
             and userConfig.prod_access (FULL default / NONE). There is
             deliberately NO bypass flag for a BLOCK refusal.

    classify (RFC via NCo 3.1 -- run under 32-bit Windows PowerShell)
             Read T000 (CCCATEGORY / CCCORACTIV / CCNOCLIIND) for the pinned
             profile's client and print a proposed environment.
             CCCATEGORY='P' prints locked=true: the client IS production and
             an operator answer cannot downgrade it.

    set      (pure-local write to {work_dir}\runtime\connections.json)
             Persist -Environment (+ -Source) on the pinned profile (or
             -ProfileId). Setting a NON-PRD value triggers a live T000
             re-verify via a 32-bit classify subprocess: if the system says
             CCCATEGORY='P' the set is REFUSED -- the live system outranks
             any conversational claim. If T000 is unreadable the value is
             accepted with Source=USER and a WARN (operator attestation).

    Stdout contract (last line) / exit codes -- see safety_policy.md 0.4:
      SAFETY: ALLOW ...                    exit 0
      SAFETY: ALLOW_CONFIRMED ...          exit 0
      SAFETY: TYPED_CONFIRM_REQUIRED ...   exit 3
      SAFETY: REFUSED class=<SAFETY_*> ... exit 1
      SAFETY: ERROR <msg>                  exit 2   (treat as refusal)
      CLASSIFY: ... / CLASSIFY: UNAVAILABLE reason=<r> (exit 4)
      SET: ... / SET: REFUSED ...

    The gate does not log; the calling skill records the verdict via
    sap_log_helper.ps1 (-Action step) and, on refusal, ends its run with
    -ErrorClass SAFETY_PROD_REFUSED / SAFETY_UNCLASSIFIED_REFUSED /
    SAFETY_CONFIRM_MISMATCH (see shared/rules/error_classes.md).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('assert', 'classify', 'set')]
    [string]$Action,

    # assert: calling skill name (echoed in output for the audit trail).
    [string]$Skill = '',

    # assert (TYPED_CONFIRM only): the operator's VERBATIM typed answer.
    # Claude never composes this value -- it is what the user typed.
    [string]$ConfirmationText = '',

    # set:
    [string]$Environment = '',
    [ValidateSet('T000', 'USER', '')]
    [string]$Source = 'USER',
    [string]$ProfileId = '',

    # Optional {WORK_TEMP} passthrough (wrapper convention); blank = derive
    # work_dir via the standard settings chain.
    [string]$WorkTemp = ''
)

$ErrorActionPreference = 'Stop'

$script:VALID_ENVS = @('DEV', 'QAS', 'SBX', 'PRD')

function _FailErr([string]$msg) {
    Write-Output "SAFETY: ERROR $msg"
    exit 2
}

# --- load sibling libs -------------------------------------------------------
try {
    $libDir = $PSScriptRoot
    . (Join-Path $libDir 'sap_settings_lib.ps1')
    . (Join-Path $libDir 'sap_connection_lib.ps1')
} catch {
    _FailErr "shared lib load failed: $($_.Exception.Message)"
}

function _ResolveProfile {
    param([string]$Id = '')
    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        return (Find-SapConnectionById -Id $Id)
    }
    # Same resolution as Connect-SapRfc (the write-hazard path): pin ->
    # GUI-active preference -> default -> single-profile auto-bootstrap.
    if ([string]::IsNullOrWhiteSpace($WorkTemp)) {
        return (Get-SapCurrentConnectionProfile -PreferGuiActive)
    }
    return (Get-SapCurrentConnectionProfile -WorkTemp $WorkTemp -PreferGuiActive)
}

function _ProdSystemIds {
    $raw = ''
    try { $raw = Get-SapSettingValue 'prod_system_ids' '' } catch { $raw = '' }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw.Split(',') | ForEach-Object { "$_".Trim().ToUpperInvariant() } | Where-Object { $_ })
}

function _MapCategory([string]$cat) {
    switch ("$cat".Trim().ToUpperInvariant()) {
        'P' { return 'PRD' }
        'C' { return 'DEV' }
        'T' { return 'QAS' }
        'D' { return 'SBX' }
        'E' { return 'SBX' }
        'S' { return 'SBX' }
        default { return 'UNKNOWN' }
    }
}

function _Ps32Path {
    $p = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $p) { return $p }
    # 32-bit OS fallback -- System32 PowerShell IS 32-bit there.
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

# =============================================================================
# assert
# =============================================================================
function Invoke-SafetyAssert {
    $prof = $null
    try { $prof = _ResolveProfile } catch { $prof = $null }
    if (-not $prof) {
        Write-Output "INFO: no connection profile resolves for this AI session (no pin, no default, no single-profile bootstrap)."
        Write-Output "INFO: remediation: run /sap-login to connect, pin, and classify a system."
        Write-Output "SAFETY: REFUSED class=SAFETY_UNCLASSIFIED_REFUSED reason=no_profile skill=$Skill"
        exit 1
    }

    $sid    = "$($prof.system_name)".Trim().ToUpperInvariant()
    $client = "$($prof.client)".Trim()
    $env    = "$($prof.environment)".Trim().ToUpperInvariant()
    $desc   = "$($prof.description)"
    Write-Output "INFO: pinned profile '$desc' sid=$sid client=$client environment='$env'"

    if ([string]::IsNullOrWhiteSpace($sid)) {
        Write-Output "INFO: profile carries no system_name (legacy pre-capture profile); cannot classify -- fail closed."
        Write-Output "INFO: remediation: re-run /sap-login so the capture step fills the identity, then classify."
        Write-Output "SAFETY: REFUSED class=SAFETY_UNCLASSIFIED_REFUSED reason=no_system_name skill=$Skill"
        exit 1
    }

    # prod_system_ids supplement -- stricter wins over a softer stored value.
    if ((_ProdSystemIds) -contains $sid -and $env -ne 'PRD') {
        Write-Output "INFO: sid=$sid is listed in userConfig.prod_system_ids -- treating as PRD (stricter wins over stored '$env')."
        $env = 'PRD'
    }

    if ([string]::IsNullOrWhiteSpace($env)) {
        Write-Output "INFO: connection is NOT environment-classified -- fail closed (treated as PRD per safety_policy.md 0.1)."
        Write-Output "INFO: remediation: run /sap-login --reclassify (or sap_safety_gate.ps1 -Action classify, then -Action set) to classify $sid/$client."
        Write-Output "SAFETY: REFUSED class=SAFETY_UNCLASSIFIED_REFUSED reason=unclassified sid=$sid client=$client skill=$Skill"
        exit 1
    }

    if ($env -ne 'PRD' -and ($script:VALID_ENVS -notcontains $env)) {
        Write-Output "INFO: unknown environment value '$env' -- fail closed, treated as PRD (safety_policy.md 0.1)."
        $env = 'PRD'
    }

    if ($env -ne 'PRD') {
        Write-Output "SAFETY: ALLOW env=$env sid=$sid client=$client skill=$Skill"
        exit 0
    }

    # --- PRD path ------------------------------------------------------------
    $access = ''
    try { $access = (Get-SapSettingValue 'prod_access' '').Trim().ToUpperInvariant() } catch { $access = '' }
    if ($access -eq 'NONE') {
        Write-Output "INFO: userConfig.prod_access=NONE -- production connections are barred entirely."
        Write-Output "SAFETY: REFUSED class=SAFETY_PROD_REFUSED reason=prod_access_none sid=$sid client=$client skill=$Skill"
        exit 1
    }

    $policy = ''
    try { $policy = (Get-SapSettingValue 'prod_write_policy' '').Trim().ToUpperInvariant() } catch { $policy = '' }
    if ([string]::IsNullOrWhiteSpace($policy)) { $policy = 'BLOCK' }

    if ($policy -ne 'TYPED_CONFIRM') {
        # BLOCK (default) -- and any unrecognized policy value fails closed here.
        Write-Output "INFO: prod_write_policy=BLOCK (default): writes to production are refused with no override flag."
        Write-Output "INFO: legitimate change path: edit prod_write_policy in {work_dir}\runtime\userconfig.json OUTSIDE this session, or perform the action manually in SAP GUI."
        Write-Output "SAFETY: REFUSED class=SAFETY_PROD_REFUSED reason=prod_write_policy_block sid=$sid client=$client skill=$Skill"
        exit 1
    }

    $expect = "PROD $sid/$client"
    if ([string]::IsNullOrWhiteSpace($ConfirmationText)) {
        Write-Output "SAFETY: TYPED_CONFIRM_REQUIRED env=PRD sid=$sid client=$client expect=`"$expect`" skill=$Skill"
        exit 3
    }
    # Verbatim operator text: trim + collapse inner whitespace, compare
    # case-insensitively against the exact expected token.
    $got = ($ConfirmationText -replace '\s+', ' ').Trim()
    if ($got -ieq $expect) {
        Write-Output "INFO: typed confirmation validated: '$got'"
        Write-Output "SAFETY: ALLOW_CONFIRMED env=PRD sid=$sid client=$client skill=$Skill"
        exit 0
    }
    Write-Output "INFO: typed confirmation mismatch: expected `"$expect`", got `"$got`" -- refusing."
    Write-Output "SAFETY: REFUSED class=SAFETY_CONFIRM_MISMATCH sid=$sid client=$client skill=$Skill"
    exit 1
}

# =============================================================================
# classify
# =============================================================================
function Invoke-SafetyClassify {
    $prof = $null
    try { $prof = _ResolveProfile } catch { $prof = $null }
    if (-not $prof) {
        Write-Output "CLASSIFY: UNAVAILABLE reason=no_profile"
        exit 4
    }
    $sid    = "$($prof.system_name)".Trim().ToUpperInvariant()
    $client = "$($prof.client)".Trim()
    if ([string]::IsNullOrWhiteSpace($client)) {
        Write-Output "CLASSIFY: UNAVAILABLE reason=no_client_on_profile"
        exit 4
    }

    $dest = $null
    try {
        . (Join-Path $PSScriptRoot 'sap_rfc_lib.ps1')
        # No endpoint args: Connect-SapRfc falls back to the pinned profile
        # (DPAPI-decrypted password) -- the same target assert judges.
        $dest = Connect-SapRfc
        if (-not $dest) {
            throw "RFC connect returned no destination (pinned profile lacks endpoint or saved RFC password)"
        }
        $fn = New-RfcReadTable -Destination $dest -Table 'T000' -Delimiter '|'
        Add-RfcOption $fn "MANDT EQ '$client'"
        Add-RfcField  $fn 'MANDT'
        Add-RfcField  $fn 'CCCATEGORY'
        Add-RfcField  $fn 'CCCORACTIV'
        Add-RfcField  $fn 'CCNOCLIIND'
        $fn.Invoke($dest)
        $rows = $fn.GetTable('DATA')
        if ([int]$rows.RowCount -lt 1) {
            Write-Output "CLASSIFY: UNAVAILABLE reason=t000_row_not_found client=$client"
            exit 4
        }
        $rows.CurrentIndex = 0
        $parts = ("$($rows.GetString('WA'))").Split('|')
        $cat   = if ($parts.Count -gt 1) { "$($parts[1])".Trim() } else { '' }
        $corr  = if ($parts.Count -gt 2) { "$($parts[2])".Trim() } else { '' }
        $noCli = if ($parts.Count -gt 3) { "$($parts[3])".Trim() } else { '' }
        $proposed = _MapCategory $cat
        $locked = if ($proposed -eq 'PRD') { 'true' } else { 'false' }
        Write-Output "CLASSIFY: sid=$sid client=$client cccategory=$cat cccoractiv=$corr ccnocliind=$noCli proposed=$proposed locked=$locked"
        exit 0
    } catch {
        $m = "$($_.Exception.Message)" -replace '\s+', ' '
        Write-Output "CLASSIFY: UNAVAILABLE reason=rfc_error detail=$m"
        exit 4
    } finally {
        if ($dest) { try { Disconnect-SapRfc } catch { } }
    }
}

# =============================================================================
# set
# =============================================================================
function Invoke-SafetySet {
    $envReq = "$Environment".Trim().ToUpperInvariant()
    if ($script:VALID_ENVS -notcontains $envReq) {
        Write-Output "SET: REFUSED reason=invalid_environment value='$Environment' (allowed: DEV QAS SBX PRD)"
        exit 1
    }
    $prof = $null
    try { $prof = _ResolveProfile -Id $ProfileId } catch { $prof = $null }
    if (-not $prof) {
        Write-Output "SET: REFUSED reason=no_profile"
        exit 1
    }
    $pid2   = "$($prof.id)"
    $sid    = "$($prof.system_name)".Trim().ToUpperInvariant()
    $client = "$($prof.client)".Trim()
    $srcOut = if ([string]::IsNullOrWhiteSpace($Source)) { 'USER' } else { $Source }

    # Downgrade guard: any NON-PRD value must survive a live T000 re-verify
    # when the system is reachable. The live system outranks any claim --
    # this closes the "set DEV mid-session to slip past the gate" hole.
    if ($envReq -ne 'PRD') {
        $verifyOut = @()
        $verifyRc  = -1
        try {
            $ps32 = _Ps32Path
            $verifyOut = @(& $ps32 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Action classify 2>$null)
            $verifyRc  = $LASTEXITCODE
        } catch { $verifyRc = -1 }
        $classifyLine = @($verifyOut | Where-Object { "$_" -match '^CLASSIFY: ' }) | Select-Object -Last 1
        if ($verifyRc -eq 0 -and "$classifyLine" -match 'proposed=PRD') {
            Write-Output "INFO: live T000 says CCCATEGORY='P' -- this client IS production; a non-PRD classification is refused."
            Write-Output "SET: REFUSED reason=t000_says_production sid=$sid client=$client requested=$envReq"
            exit 1
        }
        if ($verifyRc -ne 0) {
            Write-Output "WARN: live T000 verify unavailable ($classifyLine); accepting '$envReq' as operator attestation (source=USER)."
            $srcOut = 'USER'
        }
    }

    try {
        $saved = Update-SapConnectionStore {
            param($store)
            $hit = $null
            foreach ($c in $store.connections) {
                if ("$($c.id)" -eq $pid2) { $hit = $c; break }
            }
            if (-not $hit) { return $null }
            $hit['environment']             = $envReq
            $hit['environment_source']      = $srcOut
            $hit['environment_verified_at'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
            return $hit
        }
        if (-not $saved) {
            Write-Output "SET: REFUSED reason=profile_vanished id=$pid2"
            exit 1
        }
        Write-Output "SET: OK id=$pid2 sid=$sid client=$client environment=$envReq source=$srcOut"
        exit 0
    } catch {
        _FailErr "store update failed: $($_.Exception.Message)"
    }
}

switch ($Action) {
    'assert'   { Invoke-SafetyAssert }
    'classify' { Invoke-SafetyClassify }
    'set'      { Invoke-SafetySet }
}
