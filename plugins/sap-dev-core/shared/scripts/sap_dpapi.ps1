# =============================================================================
# sap_dpapi.ps1  -  DPAPI (Data Protection API) helper for SAP credentials
#
# Encrypts / decrypts secret strings using Windows DPAPI under the
# CurrentUser scope. The ciphertext is base64-encoded and tagged with a
# "dpapi:" prefix so callers can tell encrypted from plaintext at a glance.
#
# Properties of CurrentUser DPAPI:
#
#   - Decryption requires the SAME Windows user account on the SAME
#     machine that performed the encryption. A copied settings.json is
#     useless on another machine — that's the desired property.
#   - No key management: Windows handles the key, rotated automatically
#     under the user's profile.
#   - Entropy parameter is unused in this v1 (no extra salt). Future
#     versions could bind ciphertext to the SAP server hostname to
#     protect against settings.json copies inside the same user account.
#
# USAGE FROM A SCRIPT (dot-source):
#
#     . "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1"
#     $stored = Protect-SapSecret -Plaintext "MyP@ssw0rd"
#     # → "dpapi:AQAAANCMnd8BFdERjHoAwE/Cl..."
#     $back   = Unprotect-SapSecret -StoredValue $stored
#     # → "MyP@ssw0rd"
#
# USAGE FROM A SKILL (CLI mode — single-shot invocation):
#
#     powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1" `
#         -Action protect -Value "MyP@ssw0rd"
#     # stdout: dpapi:AQAAANCMnd8BFdERjHoAwE/Cl...
#
#     powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1" `
#         -Action unprotect -Value "dpapi:AQAAANCMnd8B..."
#     # stdout: MyP@ssw0rd
#
# UNPROTECT BEHAVIOUR ON PLAINTEXT INPUT:
#
#     If the input has no "dpapi:" prefix, Unprotect-SapSecret returns
#     the value unchanged AND emits a single-line WARN on stderr. This is
#     the migration affordance: existing plaintext sap_password values
#     keep working, but operators see a warning prompting them to encrypt.
#
# EXIT CODES (CLI mode):
#   0 = success
#   1 = decrypt failure (wrong user / corrupted ciphertext / not Windows)
#   2 = bad arguments / unknown action
# =============================================================================

[CmdletBinding()]
param(
    [string]$Action,
    [string]$Value
)

$ErrorActionPreference = 'Stop'

# Lazy-load System.Security so this script works in environments where
# it's not auto-imported (some PowerShell hosts skip it by default).
function _Ensure-DPAPI {
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    } catch {
        # Already loaded or running in a host that pre-loads it; ignore.
    }
}

function Protect-SapSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Plaintext
    )

    if ([string]::IsNullOrEmpty($Plaintext)) {
        # Empty input → empty output. No "dpapi:" prefix because there's
        # nothing to protect, and we don't want a stored "dpapi:" with
        # no payload to look like valid ciphertext to readers.
        return ""
    }

    _Ensure-DPAPI

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plaintext)
    $enc   = [System.Security.Cryptography.ProtectedData]::Protect(
                $bytes, $null,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $b64   = [Convert]::ToBase64String($enc)
    return "dpapi:$b64"
}

function Unprotect-SapSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$StoredValue
    )

    if ([string]::IsNullOrEmpty($StoredValue)) {
        return ""
    }

    if (-not $StoredValue.StartsWith("dpapi:", [StringComparison]::Ordinal)) {
        # Migration affordance: pass plaintext through unchanged but
        # warn loudly so the operator sees they should re-save.
        [Console]::Error.WriteLine(
            "WARN: sap_dpapi: value is not DPAPI-encrypted (no 'dpapi:' prefix). " +
            "Returning plaintext as-is - re-save via sap-login to encrypt at rest.")
        return $StoredValue
    }

    _Ensure-DPAPI

    $b64 = $StoredValue.Substring(6)   # length of "dpapi:"
    if ([string]::IsNullOrWhiteSpace($b64)) {
        throw "sap_dpapi: 'dpapi:' prefix found but no ciphertext payload."
    }

    try {
        $enc   = [Convert]::FromBase64String($b64)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                    $enc, $null,
                    [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        throw "sap_dpapi: decrypt failed (wrong Windows user / different machine / " +
              "corrupted ciphertext): $($_.Exception.Message)"
    }
}

# --- CLI mode --------------------------------------------------------------
# When invoked via `powershell -File sap_dpapi.ps1 -Action <protect|unprotect>
# -Value <text>`, drive the matching function and emit one line on stdout.
if ($PSBoundParameters.ContainsKey('Action')) {
    switch ($Action.ToLowerInvariant()) {
        "protect" {
            try {
                Write-Host (Protect-SapSecret -Plaintext $Value)
                exit 0
            } catch {
                [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
                exit 1
            }
        }
        "unprotect" {
            try {
                Write-Host (Unprotect-SapSecret -StoredValue $Value)
                exit 0
            } catch {
                [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
                exit 1
            }
        }
        default {
            [Console]::Error.WriteLine(
                "ERROR: -Action must be 'protect' or 'unprotect'. Got: '$Action'.")
            exit 2
        }
    }
}
