---
name: sap-login
description: |
  Opens a SAP GUI connection and logs in using SAP GUI Scripting.
  Multi-profile connection store (Phase 4): save multiple SAP connections
  (different SID / Client / User / endpoint) at `{work_dir}\runtime\connections.json`,
  with passwords DPAPI-encrypted at rest. Picks the right one for this
  AI session via a 4-step identity compare and an AI-session pin.
  Also verifies SAP NCo 3.1 RFC connectivity (direct or load-balanced via
  MessageServer + LogonGroup + SystemID).
  Supports three connection methods: SAP Logon pad entry name (OpenConnection),
  load-balanced /M/<msrv>/G/<grp>/S/<sid> string, and direct /H/<host>/S/<port>.
  Checks existing sessions first; reuses the active connection when it
  matches the saved default.
  Prerequisites: SAP GUI installed, SAP GUI Scripting enabled (client + server).
argument-hint: "[--list | --add | --switch <id> | --set-default <id> | --delete <id>]"
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
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `sap-dev-core/shared/scripts/sap_check_gui_login_status.vbs` | *(none — static)* | Check session status |
| `sap-dev-core/shared/scripts/sap_login.vbs` | *(template)* | SAP GUI login VBScript. Tokens: `%%SAP_LOGON_DESCRIPTION%%`, `%%SAP_APPLICATION_SERVER%%`, `%%SAP_SYSTEM_NUMBER%%`, `%%SAP_MESSAGE_SERVER%%`, `%%SAP_LOGON_GROUP%%`, `%%SAP_SYSTEM_ID%%`, `%%SAP_CLIENT%%`, `%%SAP_USER%%`, `%%SAP_PASSWORD%%`, `%%SAP_LANGUAGE%%`. |
| `sap-dev-core/shared/scripts/sap_rfc_connect.ps1` | *(template)* | SAP NCo 3.1 RFC connection PowerShell. Now supports load-balanced login via `MessageServer + LogonGroup + SystemID`. |
| `sap-dev-core/shared/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo helpers. `Connect-SapRfc` accepts either direct (`-Server` + `-Sysnr`) or load-balanced (`-MessageServer` + `-LogonGroup` + `-SystemID`). |
| `sap-dev-core/shared/scripts/sap_dpapi.ps1` | *(none — static)* | DPAPI encrypt/decrypt for passwords at rest. CLI mode: `-Action protect|unprotect -Value <text>`. |
| `sap-dev-core/shared/scripts/sap_connection_lib.ps1` | *(none — dot-source)* | **Multi-profile connection store**. 4-step identity compare, dedup-on-save, DPAPI password handling, legacy-settings migration. Storage: `{work_dir}\runtime\connections.json`. |
| `sap-dev-core/shared/scripts/sap_session_broker.ps1` | *(none — invoke)* | Broker. New Phase-4 actions: `pin`, `unpin`, `set-connection-id`, `stuck`. New flags: `-AiSessionId`, `-WasCreated`, `-ForceUnpin`. |
| `sap-dev-core/shared/scripts/sap_rfc_system_info.ps1` | *(none — direct invoke)* | RFC_SYSTEM_INFO + CVERS query. Step 6.2 calls this to capture `server_release_marker`, `software_components`. |
| `sap-dev-core/shared/tables/sap_release_markers.tsv` | *(none — read by sap_rfc_system_info.ps1)* | (component, release range) → canonical marker lookup. |
| `<SKILL_DIR>/sap_login_select.ps1` | *(none — direct invoke)* | **Selection driver**. Actions: `init`, `decide`, `list`, `set-default`, `switch`, `delete`, `finalize`. Emits structured signals (`RESOLVED:`, `ATTACH_ACTIVE:`, `CONNECT_PROFILE:`, `PICK_NEEDED:`, `ADD_NEEDED:`, `SUCCESS:`). |
| `<SKILL_DIR>/references/sap_login_capture_active_session.vbs` | *(none — static)* | GUI-side capture. Phase-4 fields: `system_name`, `client`, `user`, `language`, `application_server`, `system_number`, `message_server`, `logon_group`, `program`, `screen_number`, plus GUI version. Emits flat JSON or `MULTI:<array>`. |

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

## Argument Modes (Phase 4)

Branch on `$ARGUMENTS` before running anything below. Each mode is a single
PowerShell call to `sap_login_select.ps1`; the rest of this skill (Steps 1–6)
runs only for the **default mode** (connect-and-pin).

| Mode | Trigger phrase / arg | What runs |
|---|---|---|
| **list** | `--list`, "list connections", "show profiles" | `sap_login_select.ps1 -Action list` → emit `LIST: <json>`. Present a readable table to the user. **Done.** |
| **set-default** | `--set-default <id>` | `sap_login_select.ps1 -Action set-default -ProfileId <id>` → emit `SUCCESS: default_target_id=...`. **Done.** |
| **switch** | `--switch <id>`, "switch to X" | `sap_login_select.ps1 -Action switch -ProfileId <id>` → re-pins AI session, releases old claims. Then runs Step 2 (decide) for the new connection. |
| **delete** | `--delete <id>` | Ask user to confirm deletion (`AskUserQuestion`); on confirm, `sap_login_select.ps1 -Action delete -ProfileId <id>`. **Done.** |
| **add** | `--add` | Skip Step 2 (decide); jump to ADD_NEEDED handler in Step 2. Treat as user-initiated new-profile entry. |
| **(default)** | no flag / no relevant arg | Run Steps 0.5 → 6.5 as documented below. |

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

## Step 0.7 — Bootstrap (AI session + Migration)

Phase-4 selection state needs an AI-session id. The repo convention is to
wire a SessionStart hook that writes `{work_dir}\runtime\ai_session_id.txt`
once per Claude Code conversation; subagents inherit by reading the same
file. The wrapper falls back to deriving an id if the hook didn't run.

This step also performs a one-shot migration of the legacy single-connection
fields in `settings.json` into the new `connections.json` store (marking
them as the default).

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\sap_login_select.ps1" -Action init -WorkTemp "{WORK_TEMP}"
```

Stdout signals:
- `INFO: ai_session_id=...` → record this value (use as `SAPDEV_AI_SESSION_ID` in all subsequent broker calls and skill wrappers within this conversation).
- `INFO: migrated legacy connection id=...` (optional) → notify the user that the previous single-connection settings were imported as the default.
- `SUCCESS: init complete` → proceed.

---

## Step 0.8 — Selection (decide)

Run the selection driver to pick the target connection. Re-invoke with the
appropriate `-PickProfileId` / `-PickConnectionPath` after each user choice.

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\sap_login_select.ps1" -Action decide -WorkTemp "{WORK_TEMP}"
```

Interpret the **last** structured stdout line:

| Signal | Meaning | Action |
|---|---|---|
| `RESOLVED: path=<P> connection_id=<I> description='<D>'` | Existing AI-session pin already matches a live session. | Skip Steps 1–5; jump to Step 6 (capture) with this `path` and Step 6.5 with this `connection_id`. |
| `ATTACH_ACTIVE: path=<P> connection_id=<I> description='<D>'` | Pick is an already-open SAP connection. | Skip Steps 1–5; jump to Step 6 with this `path`. |
| `CONNECT_PROFILE: id=<I> description='<D>' source=<S>` | Pick is a saved profile. | Look up the profile in `connections.json` (`sap_connection_lib.ps1`), decrypt password (DPAPI), and proceed to Step 3 (Generate Login VBS) with the profile's fields. |
| `PICK_NEEDED: <json>` | User must choose. | Parse `options[]` (each has `kind=active|profile`, `description`, `system_name`, `client`, `user`, `endpoint_summary`, `is_default`). Present via `AskUserQuestion`. Re-invoke `sap_login_select.ps1 -Action decide -PickProfileId <id>` OR `-PickConnectionPath <path>`. |
| `ADD_NEEDED:` | No active connections, no saved profiles. | Prompt the user for a new connection (logon-pad entry, OR app server + system number, OR message server + logon group + system id) plus client/user/password/language. Proceed to Step 3 with the supplied values. After login succeeds, Step 6.5 saves it as a new profile. |

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

## Step 2 — Resolve Connection Parameters from the Pick

Only reached if Step 0.8 emitted `CONNECT_PROFILE`, `ADD_NEEDED`, or the user
needs credentials beyond what's stored. **`ATTACH_ACTIVE` and `RESOLVED` skip
this step entirely.**

### Step 2a — For `CONNECT_PROFILE: id=<I>`: load + decrypt

Dot-source the connection library and look up the profile:

```bash
powershell -ExecutionPolicy Bypass -Command @"
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1';
$p = Find-SapConnectionById -Id '<I>';
$p | ConvertTo-Json -Depth 4
"@
```

Use the returned fields directly as the `THE_*` substitutions in Step 3.
For `password_dpapi`, decrypt via `sap_dpapi.ps1`:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1" -Action unprotect -Value "<password_dpapi-value>"
```

Stdout = plaintext password (or the same value pass-through with a stderr
warning for legacy plaintext). Exit code 1 = decrypt failed (different
Windows user or machine) → prompt the user for the password fresh and
remember to re-encrypt + save it in Step 6.5.

### Step 2b — For `ADD_NEEDED:` or `--add`: collect new credentials

Ask the user via `AskUserQuestion` for whichever endpoint set they want to
configure:

- **SAP Logon pad entry** (simplest) — just the entry-name string. Then ask
  for client / user / password / language.
- **Direct connect** — app server hostname/IP, 2-digit system number, plus
  client / user / password / language.
- **Load-balanced** — message server, logon group (default `SPACE`),
  3-letter SystemID (R3NAME), plus client / user / password / language.

Optionally ask for a "Logon description" label (free text, max 60 chars);
if blank, `sap_login_select.ps1 -Action finalize` auto-derives it as
`<msrv|asrv>_<sid>_<client>_<user>`.

Encrypt the password BEFORE handing it to Step 3 if the user wants it
saved — pre-encrypt then pass `dpapi:...` to finalize. Otherwise Step 6.5
can re-encrypt:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1" -Action protect -Value "<plaintext>"
# stdout: dpapi:AQAAAN...
```

### Step 2c — Legacy reminder

The legacy single-connection keys (`sap_logon_description`, `sap_application_server`,
`sap_system_number`, `sap_client`, `sap_user`, `sap_password`, `sap_language`)
are kept in `settings.json` for back-compat ONLY. Step 0.7's `init` imports
them into `connections.json` once; subsequent runs ignore them. Do **not**
read or write these keys directly from this skill.

### Step 2-legacy-a — DPAPI background (informational)

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
$content = $content.Replace('%%SAP_MESSAGE_SERVER%%','THE_MSG_SERVER')
$content = $content.Replace('%%SAP_LOGON_GROUP%%','THE_LOGON_GROUP')
$content = $content.Replace('%%SAP_SYSTEM_ID%%','THE_SYSTEM_ID')
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

Token-fill rules (the VBS picks among three connection methods):
- For **SAP Logon pad** profiles: set `THE_LOGON_DESC` to the entry name; leave server/sysnr/msrv/grp/sid empty.
- For **direct** profiles: set `THE_SERVER` + `THE_SYSNR`; leave logon_desc/msrv/grp/sid empty.
- For **load-balanced** profiles: set `THE_MSG_SERVER` + `THE_LOGON_GROUP` (blank → VBS uses " ") + `THE_SYSTEM_ID`; leave logon_desc/server/sysnr empty.

If a field is unused in the chosen method, substitute the empty string `""`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_login_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_login_run.vbs
```

**The VBScript handles four scenarios** (first match wins):

1. **Login-screen session found** → Reuses existing connection, fills credentials.
2. **SAP Logon Description provided** → Opens connection via `OpenConnection(desc)`, fills login screen.
3. **MessageServer provided + ApplicationServer empty** → Opens load-balanced via `OpenConnectionByConnectionString("/M/<msrv>/G/<grp>/S/<sid>")` (LogonGroup defaults to one space when blank).
4. **ApplicationServer provided** → Opens direct via `OpenConnectionByConnectionString("/H/<server>/S/<port>")` where port = 3200 + SystemNumber.

**On success** (last line starts with `SUCCESS:`): tell the user login succeeded. Show full output.

**On failure** (any line starts with `ERROR:`): show full output and diagnose:

| Error | Cause | Fix |
|---|---|---|
| `SAP GUI is not running` | SAP Logon not open | Start SAP Logon |
| `Could not get SAP Scripting Engine` | Scripting disabled | SAP Logon > Options > Scripting > Enable |
| `Could not open connection` | Wrong entry name | Check exact name in SAP Logon pad |
| `Load-balanced login requires SAP_SYSTEM_ID` | Missing R3NAME on load-balanced profile | Set `system_id` on the profile (3-letter SID) |
| `No endpoint configured` | All three endpoint sets blank | Configure profile with one of: logon_pad_entry, message_server + system_id, or application_server + system_number |
| `Could not open connection with string` | Server unreachable or wrong server/port | Check server hostname and system number |
| `Could not open load-balanced connection` | Message server unreachable / wrong logon group / wrong SID | Check msrv hostname, logon group exists in RZ12, SID matches /sapmnt/<SID> |
| `Login failed` | Wrong credentials | Check client, username, and password in profile |
| `Login timed out` | No manual login within 5 min | Re-run and log in promptly |

---

## Step 4 — Verify RFC Connectivity (Optional)

**Run this step only when the user explicitly requests RFC verification**, or when
the calling skill needs RFC (e.g., sap-check-fm, sap-fix-fm, sap-check-abap).

The RFC connection template is at `sap-dev-core/shared/scripts/sap_rfc_connect.ps1`.

For load-balanced profiles, call `Connect-SapRfc` directly with the
`-MessageServer / -LogonGroup / -SystemID` parameter set rather than the
template (the template is direct-server only). Either path works for
verification — pick the one matching the profile's endpoint shape.

Direct-server path (write `{WORK_TEMP}\sap_rfc_test_run.ps1`):
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

Load-balanced path (inline):
```powershell
. "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1"
$dest = Connect-SapRfc `
    -MessageServer THE_MSG_SERVER `
    -LogonGroup    THE_LOGON_GROUP `
    -SystemID      THE_SYSTEM_ID `
    -Client        THE_CLIENT `
    -User          THE_USER `
    -Password      THE_PASSWORD `
    -Language      THE_LANGUAGE
if ($dest) { Write-Host 'RFC_OK' } else { Write-Host 'ERROR: RFC connect failed' }
```

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

## Step 6 — Active-Session Capture

Reached after `sap_login.vbs` succeeded **or** when Step 0.8 produced
`ATTACH_ACTIVE` / `RESOLVED` (the session already exists). The capture VBS
reads the **rich Phase-4 GuiSessionInfo set** — system / client / user /
language, MessageServer / Group / SystemNumber / ApplicationServer,
Program / ScreenNumber, plus GUI version — and emits a single-line JSON
record.

```bash
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo "<SKILL_DIR>\references\sap_login_capture_active_session.vbs" "<session-path-from-step-0.8-or-blank>"
```

Last line of stdout:
- `{"session_path":"/app/con[0]/ses[0]", ...}` — single-line JSON record. Save this to a variable for Step 6.5.
- `MULTI:[ {...}, ... ]` — only fires when the wrapper passed no hint AND multiple connections are attached AND Step 0.8 didn't already pick one. Should be rare after Phase 4 (Step 0.8 picks first). If it happens, present a picker via `AskUserQuestion`, then re-invoke the VBS with the chosen path.
- `ERROR: <text>` — skip Step 6.5 and warn; downstream skills still work via the broker's discovery path, just without an explicit pin.

### Step 6.2 — Optional RFC system info (deferred)

The legacy `sap_rfc_system_info.ps1` enrichment is no longer driven from
this skill by default. Run it on demand when a consumer skill needs
`server_release_marker` / `software_components`. See
`<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_system_info.ps1` for the call
convention.

---

## Step 6.5 — Finalize (save profile + pin AI session)

Hand the captured JSON to `sap_login_select.ps1 -Action finalize`. This is
the step that:

1. Saves (or merges via 4-step dedup) the profile in `{work_dir}\runtime\connections.json`.
2. Assigns the profile's UUID as `connection_id` on the live broker registry block (`broker set-connection-id`).
3. Pins the AI session to that `connection_id` (`broker pin`). On a switch, this releases stale claims from the old connection.
4. Writes `{work_dir}\runtime\sap_active_session.json` — the pin file every other skill's `sap_attach_lib.vbs` reads.

```powershell
$captured = '<single-line JSON from Step 6>'   # exact string
$newDesc  = '<user-supplied Logon description, or empty>'
$newPwd   = '<dpapi:... ciphertext, or empty>'

powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\sap_login_select.ps1" `
    -Action finalize `
    -WorkTemp "{WORK_TEMP}" `
    -CapturedJson $captured `
    -NewLogonDescription $newDesc `
    -NewPasswordDpapi $newPwd
```

Expected stdout:
- `INFO: profile saved id=<UUID> description='<auto-derived or user-supplied>'`
- `INFO: pin file at {work_dir}\runtime\sap_active_session.json`
- `SUCCESS: connection_id=<UUID> description='<...>' session_path=/app/con[N]/ses[M]`

Tell the user the connection is ready, including the description and
whether it became the new default.

### Step 6.6 — Switch-mode follow-up

If the user invoked `/sap-login --switch <id>`, the `switch` action
already re-pinned during Argument-Mode dispatch. Now Step 0.8's `decide`
runs, will either ATTACH_ACTIVE (target already open) or CONNECT_PROFILE
(open a new SAP GUI connection). Step 6.5 finalize re-affirms the pin.
The broker's `pin` action already released any claims this AI session
held on the OLD connection — those SAP sessions are now back at Easy
Access and free for the user or another AI session.

---

## Consumer-skill resolution contract (unchanged interface, Phase-4 enriched)

Every downstream skill resolves its target session like this:

1. Explicit `--session "<path>"` arg → use it.
2. Else `{work_dir}\runtime\sap_active_session.json` exists → use its `session_path`. *(Path moved from `{WORK_TEMP}` in Phase 4; the file is now under `runtime\` so it survives `sap-dev-clean` temp wipes.)*
3. Else exactly one connection attached → silent default `/app/con[0]/ses[0]`.
4. Else refuse with: *"multiple SAP GUI connections detected and no active session pinned; run `/sap-login` first to pick one."*

The broker (sap_session_broker.ps1) ALSO enforces AI-session pin: an
`acquire` for an AI session that's pinned to connection A will be refused
if it targets connection B. This is the safety net that prevents subagents
from "drifting" to a different SAP system.

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

## Recommended: SessionStart Hook for `SAPDEV_AI_SESSION_ID`

The Phase-4 AI-session pin scope is identified by the env var
`SAPDEV_AI_SESSION_ID`. Subagents inherit a shared working directory but
not env vars set inside a tool call, so the canonical mechanism is to
write the id to `{work_dir}\runtime\ai_session_id.txt` once per Claude
Code conversation, then read it from there in every skill wrapper.

If you have not wired the hook, `/sap-login` Step 0.7 still writes the
file as a fallback — but only on first invocation. Other skills (e.g.
`/sap-se16n`, `/sap-se38`) launched **before** the first `/sap-login`
would see no pin and could land on the wrong connection in a
multi-connection scenario.

Wire the hook via `/update-config` (recommended):

```
/update-config hooks.SessionStart += {
  "command": "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$d='C:\\sap_dev_work\\runtime'; New-Item -ItemType Directory -Force -Path $d | Out-Null; $f=Join-Path $d 'ai_session_id.txt'; if (-not (Test-Path $f)) { [guid]::NewGuid().ToString() | Set-Content -NoNewline $f }\""
}
```

Adjust the path if your `work_dir` is not `C:\sap_dev_work`. The hook is
idempotent (no-op if the file already exists), so it is safe to wire at
the user level.

To verify the hook is working, run `/sap-login --list` after a fresh
Claude Code restart and confirm `ai_session_id` matches the file content:

```bash
type "%work_dir%\runtime\ai_session_id.txt"
```

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
