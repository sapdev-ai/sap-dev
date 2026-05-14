---
name: sap-login
description: |
  Opens a SAP GUI connection and logs in using SAP GUI Scripting.
  Also verifies SAP NCo 3.1 RFC connectivity for RFC-based skills.
  Reads connection parameters from settings.json (sap-dev-core plugin).
  Supports two connection methods: SAP Logon pad entry name (OpenConnection)
  or direct connection string (OpenConnectionByConnectionString).
  Checks for existing sessions first without generating any VBS.
  Prerequisites: SAP GUI installed, SAP GUI Scripting enabled (client + server).
argument-hint: "[SAP Logon description override] [--remember]"
---

# SAP GUI Login Skill

You open a SAP GUI connection and log in via SAP GUI Scripting, and optionally
verify RFC connectivity via SAP NCo 3.1.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `sap-dev-core/shared/scripts/sap_check_gui_login_status.vbs` | *(none — static)* | Check session status |
| `sap-dev-core/shared/scripts/sap_login.vbs` | *(template)* | SAP GUI login VBScript |
| `sap-dev-core/shared/scripts/sap_rfc_connect.ps1` | *(template)* | SAP NCo 3.1 RFC connection PowerShell |
| `sap-dev-core/shared/scripts/sap_dpapi.ps1` | *(none — static)* | DPAPI encrypt/decrypt for `sap_password` at rest in `settings.json`. CLI mode: `-Action protect|unprotect -Value <text>`. |
| `sap-dev-core/shared/scripts/sap_rfc_system_info.ps1` | *(none — direct invoke)* | RFC_SYSTEM_INFO + CVERS query. Step 6.2 calls this to capture `server_release_marker`, `software_components`. |
| `sap-dev-core/shared/tables/sap_release_markers.tsv` | *(none — read by sap_rfc_system_info.ps1)* | (component, release range) → canonical marker lookup. |
| `<SKILL_DIR>/references/sap_login_capture_active_session.vbs` | *(none — static)* | GUI-side capture for Step 6.1. Emits a flat JSON record or `MULTI:<array>` when multiple connections are open. |

---

## Step 0 — Resolve Work Directory

Read sap-dev-core's settings.json (go 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json`). Read `work_dir`, `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{WORK_TEMP}\sap_login_run.json`) so subsequent steps and the final
log-end call append to the same run. Best-effort: silently no-ops if
`userConfig.log_enabled=false` or the lib can't load. **Do not** include
the SAP password in `-ParamsJson` — only system / client / user.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_login_run.json" -Skill sap-login -ParamsJson "{\"system\":\"<SID>\",\"client\":\"<CLIENT>\",\"user\":\"<USER>\"}"
```

---

## Step 1 — Check Existing Session

Run the static check script directly — no token replacement or generation needed:
```bash
cscript //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_gui_login_status.vbs"
```
Replace `<SAP_DEV_CORE_SHARED_DIR>` with the absolute path to sap-dev-core's `shared/` directory.
Resolve it by going 3 levels up from `<SKILL_DIR>` (skill → skills/ → plugin dir → plugins root),
then into `sap-dev-core\shared`.

**Parse output:**

| STATUS line | Meaning | Action |
|---|---|---|
| `STATUS: LOGGED_IN` | Authenticated session found | Report session info (SYSTEM, CLIENT, USER, LANGUAGE, CODEPAGE from output). **Done — skip Steps 2-5.** |
| `STATUS: LOGIN_SCREEN` | Connection exists, needs authentication | Proceed to Step 2. The login VBS will reuse this session. |
| `STATUS: NO_SESSION` | SAP GUI running, no sessions | Proceed to Step 2 |
| `STATUS: NO_GUI` | SAP GUI / SAP Logon not running | Proceed to Step 2. The login VBS will start SAP Logon. |
| `STATUS: NO_SCRIPTING` | Scripting engine unavailable | Tell user to enable scripting: SAP Logon > Options > Scripting > Enable Scripting |

---

## Step 2 — Read Connection Parameters

Only reached if Step 1 did not find an authenticated session.

Read SAP connection parameters from `$USER_CONFIG` (settings.json of sap-dev-core):

| Setting key | Description | Example |
|---|---|---|
| `sap_logon_description` | SAP Logon pad entry name (optional) | `DEV_100` |
| `sap_application_server` | Application server hostname or IP | `10.0.0.1` |
| `sap_system_number` | 2-digit system number | `00` |
| `sap_client` | 3-digit client | `100` |
| `sap_user` | SAP username | `DEVELOPER` |
| `sap_password` | SAP password — DPAPI-encrypted (preferred) or plaintext (legacy) | `dpapi:AQAAAN...` |
| `sap_language` | 2-letter logon language | `EN` |

If `$ARGUMENTS` provides a SAP Logon description, use it as override for `sap_logon_description`.

**If settings are not configured**, ask the user to provide the values and suggest
they configure settings.json for future use:
> "SAP connection settings are not configured. Please provide the connection details,
> or configure them in sap-dev-core settings.json for automatic use."

### Step 2a — Decrypt `sap_password` (DPAPI)

The stored `sap_password` value is one of three forms:

| Form | Example | Action |
|---|---|---|
| Empty | `""` | Skill will ask the operator to type it interactively. |
| DPAPI-encrypted | `dpapi:AQAAAN...` | Decrypt via `sap_dpapi.ps1` before injecting into the login VBS. |
| Plaintext (legacy) | `MyP@ssw0rd` | Pass through, but emit a one-line warning prompting re-save. |

Decrypt with:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1" -Action unprotect -Value "<stored-value>"
```

Stdout = the plaintext password (or pass-through). Stderr = the
re-save warning (only on plaintext). Exit code 0 on success, 1 on
decrypt failure (wrong Windows user / different machine / corrupted
ciphertext) — in that case, prompt the operator to type the password
fresh and offer to encrypt-and-save it after Step 3 succeeds.

The plaintext password lives only in memory of the calling skill and
in the generated `{WORK_TEMP}\sap_login_run.vbs` (which Step 5
deletes). Do NOT echo the decrypted value to your reply or to any
log.

---

## Step 3 — Generate and Run the Login VBScript

The VBScript template is at `sap-dev-core/shared/scripts/sap_login.vbs`.

Write `{WORK_TEMP}\sap_login_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_login.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_LOGON_DESCRIPTION%%','THE_LOGON_DESC')
$content = $content.Replace('%%SAP_APPLICATION_SERVER%%','THE_SERVER')
$content = $content.Replace('%%SAP_SYSTEM_NUMBER%%','THE_SYSNR')
$content = $content.Replace('%%SAP_CLIENT%%','THE_CLIENT')
$content = $content.Replace('%%SAP_USER%%','THE_USER')
$content = $content.Replace('%%SAP_PASSWORD%%','THE_PASSWORD')
$content = $content.Replace('%%SAP_LANGUAGE%%','THE_LANGUAGE')
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_login_run.vbs', $content, [System.Text.Encoding]::Unicode)
Write-Host 'Done'
```
Replace all `THE_*` placeholders with actual values from Step 2.
`THE_PASSWORD` is the **decrypted plaintext** from Step 2a (NOT the
`dpapi:` ciphertext — DPAPI is a storage-at-rest concern; SAP GUI
needs plaintext). Replace `<SAP_DEV_CORE_SHARED_DIR>` with the
resolved path.

If `sap_logon_description` is blank, set `THE_LOGON_DESC` to empty string `""`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_login_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_login_run.vbs
```

**The VBScript handles three scenarios:**

1. **Login-screen session found** → Reuses existing connection, fills credentials.
2. **SAP Logon Description provided** → Opens connection via `OpenConnection(desc)`, fills login screen.
3. **No SAP Logon Description** → Opens connection via `OpenConnectionByConnectionString("/H/<server>/S/<port>")` where port = 3200 + SystemNumber.

**On success** (last line starts with `SUCCESS:`): tell the user login succeeded. Show full output.

**On failure** (any line starts with `ERROR:`): show full output and diagnose:

| Error | Cause | Fix |
|---|---|---|
| `SAP GUI is not running` | SAP Logon not open | Start SAP Logon |
| `Could not get SAP Scripting Engine` | Scripting disabled | SAP Logon > Options > Scripting > Enable |
| `Could not open connection` | Wrong entry name | Check exact name in SAP Logon pad |
| `Neither SAP Logon description nor application server is configured` | Both are blank | Configure settings.json or provide arguments |
| `Could not open connection with string` | Server unreachable or wrong server/port | Check server hostname and system number |
| `Login failed` | Wrong credentials | Check client, username, and password in settings |
| `Login timed out` | No manual login within 5 min | Re-run and log in promptly |

---

## Step 4 — Verify RFC Connectivity (Optional)

**Run this step only when the user explicitly requests RFC verification**, or when
the calling skill needs RFC (e.g., sap-check-fm, sap-fix-fm, sap-check-abap).

The RFC connection template is at `sap-dev-core/shared/scripts/sap_rfc_connect.ps1`.

Write `{WORK_TEMP}\sap_rfc_test_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_connect.ps1', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_APPLICATION_SERVER%%','THE_SERVER')
$content = $content.Replace('%%SAP_SYSTEM_NUMBER%%','THE_SYSNR')
$content = $content.Replace('%%SAP_CLIENT%%','THE_CLIENT')
$content = $content.Replace('%%SAP_USER%%','THE_USER')
$content = $content.Replace('%%SAP_PASSWORD%%','THE_PASSWORD')
$content = $content.Replace('%%SAP_LANGUAGE%%','THE_LANGUAGE')
$content = $content.Replace('%%RFC_LIB_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_rfc_test_run.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```
Replace all `THE_*` placeholders.

Execute via **32-bit PowerShell** (SAP NCo 3.1 is registered in the 32-bit GAC):
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_rfc_test_run.ps1"
```

**On success** (output contains `RFC_OK`): tell user RFC connection verified.

**On failure** (output contains `ERROR:`): show full output and diagnose:

| Error | Cause | Fix |
|---|---|---|
| `NCo 3.1 not found in GAC_32` | SAP NCo 3.1 not installed for .NET 4.0 32-bit | Install SAP NCo 3.1 for .NET 4.0 (32-bit) per SAP Note |
| `RFC logon failed` | Wrong server/credentials or server unreachable | Check all connection parameters |

**RFC connection logic:**
- The PS1 template uses NCo `RfcDestinationManager` with the supplied parameters and pings the destination to verify connectivity.

---

## Step 5 — Clean Up

```bash
cmd /c del {WORK_TEMP}\sap_login_run.vbs & del {WORK_TEMP}\sap_login_run.ps1 & del {WORK_TEMP}\sap_rfc_test_run.ps1
```

---

## Step 5b — Optionally Encrypt and Save the Password (post-login, opt-in)

**Run only when at least one of these is true:**

- The password was just typed by the operator this turn (i.e. not
  read from `settings.json`).
- The stored `sap_password` is plaintext (Step 2a emitted the
  pass-through warning) and the operator wants to upgrade it.
- The stored value was DPAPI-encrypted but on a different user /
  machine, so Step 2a's decrypt failed, and the operator just typed
  the correct password.

**Ask the operator explicitly** before persisting — never auto-save:

> Save the password to `settings.json` (DPAPI-encrypted, bound to
> your Windows user account)? **yes** to save, anything else to skip.

If the operator says yes, encrypt and persist:

```bash
# 1. Encrypt the plaintext via the shared DPAPI helper.
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1" -Action protect -Value "<plaintext>"
#    → stdout: dpapi:AQAAAN...
```

Capture the `dpapi:` line and write it to `settings.json` via
`/update-config` (or by direct edit of the `userConfig.sap_password.value`
field). Both produce the same on-disk result; `/update-config` is the
preferred path because it preserves JSON formatting:

```
/update-config userConfig.sap_password = "dpapi:AQAAAN..."
```

**DO NOT** echo the plaintext back to the user, and do not write the
plaintext to any log. The shared `sap_log_lib.ps1` already redacts
`sap_password` by key name; with DPAPI in place, the value at rest is
no longer the secret either.

### What happens if I copy `settings.json` to another machine?

The `dpapi:` ciphertext is bound to the **Windows user account on
this machine**. On another machine (or another Windows account), the
decrypt step in 2a will fail with `sap_dpapi: decrypt failed (wrong
Windows user / different machine / corrupted ciphertext)`. The skill
will then prompt for the password fresh, and the operator can re-save
on that new machine. This is the desired property: a leaked
`settings.json` is useless without the matching Windows profile.

---

## Step 6 — Active-Session Capture (active-session pinning)

After login + RFC verification, capture metadata about the just-attached SAP
GUI session so downstream skills (`sap-gui-probe`, `sap-gui-object-details`,
`sap-gui-skill-scaffold`, future deploy skills) can pin to the correct
session and select version-appropriate VBS variants.

The captured record is written to `{WORK_TEMP}\sap_active_session.json` and
covers:

| Field | Source |
|---|---|
| `session_path`, `system_name`, `client`, `user`, `language`, `application_server` | `sap_login_capture_active_session.vbs` (GUI side) |
| `gui_version_raw`, `gui_major`, `gui_minor`, `gui_patch` | same VBS, via `oApp.MajorVersion` etc. |
| `connection_string`, `pin_reason` | same VBS |
| `server_kernel_release`, `server_release_family`, `server_release_marker`, `software_components` | `sap_rfc_system_info.ps1` (RFC side, via NCo) |
| `recorded_at`, `recorded_by_skill` | written by the orchestrator |

### 6.1 — Call the GUI-side capture VBS

```bash
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo "<SKILL_DIR>\references\sap_login_capture_active_session.vbs"
```

Last line of stdout:
- `{"session_path":"/app/con[0]/ses[0]", …}` — single connection auto-pinned, single-line JSON. Use directly.
- `MULTI:[ {…cand0…}, {…cand1…}, … ]` — multiple connections detected. Each candidate carries `session_path`, `system_name`, `client`, `user`. Present an AskUserQuestion listing them; user picks one. Then re-invoke the VBS with the chosen session id:
  ```bash
  cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo "<SKILL_DIR>\references\sap_login_capture_active_session.vbs" "/app/con[1]/ses[0]"
  ```
  to get the canonical record for the pick.
- `ERROR: <text>` — abort Step 6 (do not fail the whole login; skip Step 6 with a warning and let users continue without a pin).

### 6.2 — Call the RFC-side system info PS1

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_system_info.ps1" -Server "<server>" -Sysnr "<sysnr>" -Client "<client>" -User "<user>" -Password "<password>" -Language "<lang>"
```

Use the same credentials decrypted in Step 2. Last line is a JSON record containing the `server_*` and `software_components` fields. On error (NCo missing, RFC logon fail), warn and skip — the pin still works without server release info; the version-aware selector will fall back to default VBS.

### 6.3a — Optional persistence: `--remember`

If `$ARGUMENTS` contains `--remember` (case-insensitive, anywhere), persist
the captured `session_path` to `settings.local.json` so future AI sessions
can restore the pin without re-running `/sap-login`. Use the shared
`sap_settings_lib.ps1` per **Rule 7 — Settings Merge Helper** in CLAUDE.md
(writes ALWAYS go to `settings.local.json`, never to `settings.json`):

```bash
powershell -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; Set-SapUserSetting 'sap_pinned_session' '<session_path>'"
```

The persisted value is **only** the session path — not the full version
record. Version info (`server_release_marker`, `gui_version_raw`, etc.) is
re-captured on demand by consumer skills, because SAP can be patched between
AI sessions. The `sap_pinned_session` key is a hint; the per-AI-session
temp file (written in Step 6.3) remains the source of truth for
version-aware decisions.

Without `--remember`, do NOT write to `settings.local.json`. The pin lives
only in `{WORK_TEMP}\sap_active_session.json` and disappears when the temp
dir is cleaned (or, more typically, gets overwritten by the next
`/sap-login`).

If the user is on a system they want to make persistent, suggest:
> Run `/sap-login --remember` to save this connection as your default for
> future AI sessions. (You can clear it later with `Set-SapUserSetting
> sap_pinned_session ''`.)

### 6.3 — Merge and write

Combine the GUI record + the RFC record + `recorded_at` (ISO 8601) + `recorded_by_skill` (`"sap-login"`) into a single JSON object and write to `{WORK_TEMP}\sap_active_session.json` (UTF-8). Example merged shape:

```json
{
  "session_path": "/app/con[0]/ses[0]",
  "system_name": "S4D", "client": "100", "user": "MICHAELLI",
  "language": "EN", "application_server": "s4d.lan.example.com",
  "gui_version_raw": "7.70.0.123", "gui_major": 7, "gui_minor": 70, "gui_patch": 0,
  "server_kernel_release": "789",
  "server_release_family": "S4HANA",
  "server_release_marker": "S4HANA_2022",
  "server_release_raw": "S/4HANA (S4CORE 107)",
  "software_components": [
    {"name": "SAP_BASIS", "release": "758"},
    {"name": "S4CORE",    "release": "107"}
  ],
  "pin_reason": "auto-picked single connection",
  "recorded_at": "2026-05-13T10:23:00",
  "recorded_by_skill": "sap-login"
}
```

This file is the source of truth for the rest of the AI session. Consumer skills MUST follow this resolution order in their own Step 0:

1. Explicit `--session "<path>"` arg → use it.
2. Else `{WORK_TEMP}\sap_active_session.json` exists → use its `session_path`.
3. Else exactly one connection attached → silent default `/app/con[0]/ses[0]`.
4. Else refuse with: *"multiple SAP GUI connections detected and no active session pinned; run `/sap-login` first to pick one."*

### 6.4 — Failure modes (graceful degradation)

- **Step 6.1 ERROR**: skip Step 6 entirely, log a warning, do not write the pin file. Behaviour falls back to today's implicit `/app/con[0]/ses[0]`.
- **Step 6.2 ERROR**: still write the pin file with only the GUI fields populated. `server_release_marker` defaults to `UNKNOWN_NO_RFC`. The selector falls back to default VBS variants.
- **Both steps OK but stale pin** (user closes the pinned session later): consumer skills call `oApp.findById(<session_path>, False)`. If `Nothing`, the consumer treats the pin as missing and applies rule 3/4 above.

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_login_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_login_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `LOGIN_FAILED`, `RFC_LOGON_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

**At rest** — `sap_password` in `settings.json` is stored DPAPI-encrypted
(`dpapi:<base64>`) under the CurrentUser scope. Decryption is bound to
the Windows user account on the machine that performed the encryption;
a copied `settings.json` is useless on another machine. See Step 2a
(decrypt-on-read) and Step 5b (encrypt-on-save). Plaintext values are
still accepted for backward compatibility but trigger a warning that
prompts the operator to re-save.

**In flight** — `{WORK_TEMP}\sap_login_run.vbs` and
`{WORK_TEMP}\sap_rfc_test_run.ps1` contain the **decrypted plaintext**
during execution because SAP GUI / NCo need it that way. Step 5
deletes both files immediately after use. Never re-use these files
across runs and never copy them out of `{WORK_TEMP}`.

**In logs** — `sap_log_lib.ps1` / `sap_log_lib.vbs` redact `sap_password`
by key name (`log_redact_keys` setting). With DPAPI on top, the
on-disk `value` is also no longer the real secret.

The check script (`sap_check_gui_login_status.vbs`) never touches
credentials. The `sensitive: true` flag on `sap_password` masks the
value in the Claude Code UI display; it is independent of the DPAPI
storage layer.

---

## 32-bit Note

SAP GUI 7.70 and older is exclusively 32-bit. SAP NCo 3.1 is registered in the
32-bit GAC (`C:\Windows\Microsoft.NET\assembly\GAC_32`) when installed for .NET 4.0 32-bit.

- **Check script** (`sap_check_gui_login_status.vbs`): runs with standard `cscript`.
- **SAP GUI login VBS** (`sap_login.vbs`): runs with standard `cscript` (SAP GUI
  Scripting works with both 32-bit and 64-bit).
- **RFC connection PS1** (`sap_rfc_connect.ps1`): **must** use 32-bit PowerShell:
  `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`.

---

## Important: Encoding

When filling VBS templates, always write with **Unicode** (UTF-16 LE) encoding.
Use `[System.Text.Encoding]::Unicode` in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters.
UTF-8 with BOM causes a cscript compile error.

The check script is committed as UTF-8 and run directly — cscript handles ASCII-only VBS fine.
