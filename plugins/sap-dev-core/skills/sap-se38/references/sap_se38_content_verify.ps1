# =============================================================================
# sap_se38_content_verify.ps1
# -----------------------------------------------------------------------------
# Content-integrity post-verify for ABAP programs deployed via /sap-se38.
#
# Closes the SE38 deploy-time false-success identified 2026-07-02 on EC2
# (ZMMRMAT0A1R01, ECC6/7.31): under parallel-session clipboard contention the
# GUI clipboard paste failed silently, so the SE38 editor kept the OLD (valid)
# source. Every existing gate then passed against that old source -- Ctrl+F2
# syntax check clean, Ctrl+F3 re-activated it, PROGDIR.STATE went 'A', and the
# F8 run-test reached the selection screen -- and SE38 reported SUCCESS while
# the active source was UNCHANGED. Three consecutive updates false-succeeded.
#
# The PROGDIR.STATE post-activate verify (sap_se38_post_activate_verify.ps1)
# answers "is the program active?" -- NOT "is the program active WITH THE
# SOURCE WE JUST DEPLOYED?". This script answers the second question: it reads
# the ACTIVE source back over RFC via RPY_PROGRAM_READ (the sanctioned path --
# never RFC_READ_TABLE on REPOSRC, which raises ASSIGN CASTING and is blocked by
# Assert-RfcReadTableAllowed) and compares it, line for line, against the source
# file that was uploaded. A mismatch => the deploy did NOT take => FAIL-CLOSED.
#
# It also catches the partial-paste corruption class (new source interleaved
# with a leftover editor template) because that changes the line count / content
# too.
#
# Contract (last stdout line -- callers rely on this, not on grepping):
#   MATCH        active source == deployed source (normalized line-for-line)
#   MISMATCH     active source differs from deployed source (stale / failed paste)
#   ERROR: <msg> verify could not run (RFC unreachable / creds / read failure /
#                deployed file missing) -- caller SOFT-warns, never blocks
#
# Exit codes: 0 MATCH, 2 MISMATCH, 1 ERROR.
#
# Parameters:
#   -ObjectName <program>       deployed program name (any case; upper-cased here)
#   -ExpectedSourceFile <path>  the .abap file that was uploaded to SE38
#
# Normalization (mirrors /sap-compare Read-Norm): strip trailing whitespace per
# line + drop trailing blank lines on BOTH sides. RPY_PROGRAM_READ returns the
# STORED source (WITH_LOWERCASE='X' preserves case), not the pretty-printed
# display the GUI download returns, so a clean deploy matches and a stale one
# does not. Leading/inner content is compared verbatim.
#
# 32-bit note: like every NCo 3.1 RFC script this MUST run under 32-bit
# PowerShell (the VBS invoker pins SysWOW64 PowerShell -- see
# sap_se38_content_verify.vbs). Under 64-bit PS, Connect-SapRfc returns no
# destination and this would soft-warn UNAVAILABLE, silently disabling the gate.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ObjectName,
    [Parameter(Mandatory)][string]$ExpectedSourceFile
)

# sap_rfc_read_source.ps1 is a pure function library (no param() block, sets no
# script-scope prefs -- safe to dot-source) and itself dot-sources sap_rfc_lib.ps1,
# so this one include yields Connect-SapRfc / Disconnect-SapRfc / Read-SapAbapSource.
# It lives in sap-dev-core shared\scripts; this file sits in sap-se38\references
# (3 levels below the plugin root) since the 2026-07-03 single-consumer
# relocation -- a bare $PSScriptRoot sibling include no longer resolves, which
# silently disabled the gate (every deploy soft-warned CONTENT_VERIFY:
# UNAVAILABLE; caught live on S4D 2026-07-03). Fail LOUD if the lib moves again.
$readSourceLib = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\shared\scripts\sap_rfc_read_source.ps1'))
if (-not (Test-Path -LiteralPath $readSourceLib)) {
    Write-Host "ERROR: shared read-source lib not found: $readSourceLib (content verify unavailable)"
    exit 1
}
. $readSourceLib

$name = $ObjectName.ToUpperInvariant()

# ---- Normalize a string[] the same way both sides are compared ---------------
function Get-NormLines([string[]]$lines) {
    if ($null -eq $lines) { return ,@() }
    $trimmed = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) { $trimmed.Add(($l -replace '\s+$', '')) }
    # Drop trailing blank lines (SAP frequently omits a trailing newline / blank).
    $end = $trimmed.Count - 1
    while ($end -ge 0 -and $trimmed[$end] -eq '') { $end-- }
    if ($end -lt 0) { return ,@() }
    return ,@($trimmed.GetRange(0, $end + 1).ToArray())
}

# ---- Read the deployed (expected) source -------------------------------------
if (-not (Test-Path -LiteralPath $ExpectedSourceFile)) {
    Write-Host "ERROR: deployed source file not found for content verify: $ExpectedSourceFile"
    exit 1
}
$expLines = $null
try {
    # ReadAllLines auto-detects BOM (UTF-8 / UTF-16) and defaults to UTF-8 when
    # none -- keeps CJK comments intact (the EC2 build had 441 CJK lines).
    $expLines = Get-NormLines ([System.IO.File]::ReadAllLines($ExpectedSourceFile))
} catch {
    Write-Host "ERROR: could not read deployed source file: $($_.Exception.Message)"
    exit 1
}

# ---- Connect RFC (auto-resolves the AI-session's pinned profile) -------------
$dest = $null
try {
    $dest = Connect-SapRfc -DestName 'SE38_CONTENT_VERIFY'
} catch {
    Write-Host "ERROR: RFC connect failed (content verify unavailable): $($_.Exception.Message)"
    exit 1
}
if (-not $dest) {
    Write-Host "ERROR: RFC connect returned no destination (run /sap-login; check NCo 3.1 32-bit GAC)."
    exit 1
}

$tmpDir = $null
try {
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("se38cv_" + [System.Guid]::NewGuid().ToString('N'))

    # Read the ACTIVE stored source over RFC. -Type program routes through
    # RPY_PROGRAM_READ, which serves reports / module pools / includes /
    # subroutine pools / FUGR-main alike (existence pre-check is TRDIR-based).
    $read = Read-SapAbapSource -Name $name -Type program -OutDir $tmpDir -Dest $dest

    if ($read.Status -ne 'OK') {
        # NOT_FOUND / ERROR / UNSUPPORTED. Existence + activation are already the
        # PROGDIR gate's job (it fail-closes on MISSING/INACTIVE); a read hiccup
        # here must not hard-fail a good deploy -- soft-warn so the gate degrades
        # gracefully (RFC off, class pool, etc.).
        Write-Host "ERROR: could not read active source via RPY_PROGRAM_READ (status=$($read.Status); $($read.Error))"
        exit 1
    }

    $actLines = Get-NormLines ([System.IO.File]::ReadAllLines($read.SourceFile))

    $expCount = $expLines.Count
    $actCount = $actLines.Count
    Write-Host "INFO: content verify for $name -- deployed_lines=$expCount active_lines=$actCount"

    # Line-for-line normalized compare. Line count is the dominant, near-zero-
    # false-positive signal for the stale-source case (an old version almost
    # always differs in length from the update); the per-line compare also
    # catches a same-length content divergence.
    $match = ($expCount -eq $actCount)
    $firstDiff = -1
    if ($match) {
        for ($i = 0; $i -lt $expCount; $i++) {
            if ($expLines[$i] -cne $actLines[$i]) { $match = $false; $firstDiff = $i; break }
        }
    } else {
        # Report the first index where they diverge (or the point one side ran out).
        $min = [Math]::Min($expCount, $actCount)
        for ($i = 0; $i -lt $min; $i++) {
            if ($expLines[$i] -cne $actLines[$i]) { $firstDiff = $i; break }
        }
        if ($firstDiff -lt 0) { $firstDiff = $min }   # identical prefix, one side longer
    }

    if ($match) {
        Write-Host 'MATCH'
        exit 0
    }

    # Diagnostic: report the 1-based line and each side's length. Content preview
    # is best-effort (may render as '?' in a cp932 console for CJK) -- the line
    # number + lengths are the locale-safe signal.
    $ln = $firstDiff + 1
    $expHas = ($firstDiff -lt $expCount)
    $actHas = ($firstDiff -lt $actCount)
    $expLen = if ($expHas) { $expLines[$firstDiff].Length } else { 0 }
    $actLen = if ($actHas) { $actLines[$firstDiff].Length } else { 0 }
    $expPrev = if ($expHas) { $expLines[$firstDiff] } else { '<no line -- deployed source is shorter>' }
    $actPrev = if ($actHas) { $actLines[$firstDiff] } else { '<no line -- active source is shorter>' }
    if ($expPrev.Length -gt 80) { $expPrev = $expPrev.Substring(0, 80) + '...' }
    if ($actPrev.Length -gt 80) { $actPrev = $actPrev.Substring(0, 80) + '...' }
    # Lengths are locale-safe and make a read artifact self-evident: if 'active'
    # is a clean prefix of 'deployed' (active len < deployed len, same start),
    # suspect an RFC line-width read artifact rather than a real stale deploy --
    # RPY_PROGRAM_READ prefers SOURCE_EXTENDED (255) so this should not happen on
    # 7.0+ systems, but the lengths surface it if it ever does.
    Write-Host "INFO: first difference at line $ln (deployed len=$expLen, active len=$actLen)"
    Write-Host "INFO:   deployed[$ln]: $expPrev"
    Write-Host "INFO:   active  [$ln]: $actPrev"
    Write-Host 'MISMATCH'
    exit 2
}
catch {
    Write-Host "ERROR: content verify failed: $($_.Exception.Message)"
    exit 1
}
finally {
    try { Disconnect-SapRfc | Out-Null } catch {}
    if ($tmpDir -and (Test-Path -LiteralPath $tmpDir)) {
        try { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}
