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
argument-hint: "[--lang <CODE>] [--force] [--list | --add | --switch <id> | --set-default <id> | --delete <id>]"
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
| `sap-dev-core/shared/scripts/sap_login.vbs` | *(template)* | SAP GUI login VBScript. Tokens: `%%SAP_LOGON_DESCRIPTION%%`, `%%SAP_APPLICATION_SERVER%%`, `%%SAP_SYSTEM_NUMBER%%`, `%%SAP_MESSAGE_SERVER%%`, `%%SAP_LOGON_GROUP%%`, `%%SAP_SYSTEM_ID%%`, `%%SAP_SYSTEM_NAME%%`, `%%SAP_CLIENT%%`, `%%SAP_USER%%`, `%%SAP_PASSWORD%%`, `%%SAP_LANGUAGE%%`. |
| `sap-dev-core/shared/scripts/sap_rfc_connect.ps1` | *(template)* | SAP NCo 3.1 RFC connection PowerShell. Now supports load-balanced login via `MessageServer + LogonGroup + SystemID`. |
| `sap-dev-core/shared/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo helpers. `Connect-SapRfc` accepts either direct (`-Server` + `-Sysnr`) or load-balanced (`-MessageServer` + `-LogonGroup` + `-SystemID`). |
| `sap-dev-core/shared/scripts/sap_dpapi.ps1` | *(none — static)* | DPAPI encrypt/decrypt for passwords at rest. CLI mode: `-Action protect|unprotect -Value <text>`. |
| `sap-dev-core/shared/scripts/sap_connection_lib.ps1` | *(none — dot-source)* | **Multi-profile connection store**. 4-step identity compare, dedup-on-save, DPAPI password handling, legacy-settings migration. Storage: `{work_dir}\runtime\connections.json`. |
| `sap-dev-core/shared/scripts/sap_session_broker.ps1` | *(none — invoke)* | Broker. New Phase-4 actions: `pin`, `unpin`, `set-connection-id`, `stuck`. New flags: `-AiSessionId`, `-WasCreated`, `-ForceUnpin`. |
| `sap-dev-core/shared/scripts/sap_rfc_system_info.ps1` | *(none — direct invoke)* | RFC_SYSTEM_INFO + CVERS query. Step 6.2 calls this to capture `server_release_marker`, `software_components`. |
| `sap-dev-core/shared/tables/sap_release_markers.tsv` | *(none — read by sap_rfc_system_info.ps1)* | (component, release range) → canonical marker lookup. |
| `<SKILL_DIR>/sap_login_select.ps1` | *(none — direct invoke)* | **Selection driver**. Actions: `init`, `decide`, `list`, `set-default`, `switch`, `delete`, `finalize`, `check`, `landscape-entries`. Emits structured signals (`RESOLVED:`, `ATTACH_ACTIVE:`, `CONNECT_PROFILE:`, `PICK_NEEDED:`, `ADD_NEEDED:`, `SUCCESS:`, `AMBIGUOUS:`, `CONTINUE_TO_STEP1:`, `LANDSCAPE:`). |
| `<SKILL_DIR>/references/sap_login_capture_active_session.vbs` | *(none — static)* | GUI-side capture. Phase-4 fields: `system_name`, `client`, `user`, `language`, `application_server`, `system_number`, `message_server`, `logon_group`, `program`, `screen_number`, plus GUI version. Emits flat JSON or `MULTI:<array>`. |
| `<SKILL_DIR>/references/sap_close_connection.vbs` | *(none — static)* | Closes a SAP GUI connection by path (`/app/con[N]`, or a session path reduced to its connection). Used by **Step 0.9** to drop an active connection whose logon language differs from the requested one, so the login flow can reopen it fresh in the requested language. Verifies via connection-count decrease (renumber-proof). Emits `CLOSED: <path>` / `ERROR: <text>`. |

---

## Step 0 — Resolve Work Directory (with first-run onboarding)

`/sap-login` is an onboarding entry point — resolve `{work_dir}` per
**`<SAP_DEV_CORE_SHARED_DIR>\rules\work_dir_onboarding.md`** (probe → use the env
value / soft tip / first-run prompt + set / migrate-on-change). **Never read
`settings.json` directly for `work_dir`** — that ignores `SAPDEV_AI_WORK_DIR` +
`userconfig.json`. Probe:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_workdir_setup.ps1" -Action probe
```

Follow that doc to fix `{work_dir}` (set the env var / migrate when needed). Once
`{work_dir}` is known, apply the **current-session env bridge** (doc Step E):
prefix this run's PowerShell commands with `$env:SAPDEV_AI_WORK_DIR='{work_dir}';`
(escape the `$` as `\$` when the command runs through bash — see the example below).
Resolve `{custom_url}` (bridge applied):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command "\$env:SAPDEV_AI_WORK_DIR='{work_dir}'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Then set `{WORK_TEMP}` = `{work_dir}\temp` and ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir from `Get-SapRunTemp` (env bridge
applied). This call also sweeps stale `run_*` dirs from crashed prior runs
(`Remove-SapStaleRunTemp`, best-effort) — login is the natural GC point:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command "\$env:SAPDEV_AI_WORK_DIR='{work_dir}'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; [void](Remove-SapStaleRunTemp); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Login's OWN scratch — the generated `sap_login_run.vbs` / `sap_rfc_test_run.ps1`
(which hold **decrypted plaintext** credentials) and the `_run.json` state — goes
under `{RUN_TEMP}`, isolating concurrent logins and confining the plaintext to a
single short-lived per-run dir. **Keep `{WORK_TEMP}` (base)** for the
`-WorkTemp "{WORK_TEMP}"` calls to `sap_login_select.ps1` / the broker — those
write the DURABLE pin + registry under `{work_dir}\runtime`, derived from the
base path's parent.

---

## Argument Modes (Phase 4)

Branch on `$ARGUMENTS` before running anything below. Each mode is a single
PowerShell call to `sap_login_select.ps1`; the rest of this skill (Steps 1–6)
runs only for the **default mode** (connect-and-pin).

### Hint forms for `<ref>` (Phase 4.4)

`--switch`, `--set-default`, and `--delete` all accept a hint instead of a
raw UUID. The matcher tries these in order — first hit wins:

| Hint form | Meaning | Example |
|---|---|---|
| `<UUID>` | exact UUID (preserves legacy callers) | `df91fed6-8913-…` |
| `last` | profile with most recent `last_used_at` | `--switch last` |
| `default` | the configured default target | `--switch default` |
| `<SID>` | `system_name` exact match | `--switch S4D` |
| `<SID>/<CLIENT>` | SID + client filter (disambiguates same-SID profiles) | `--switch S4D/200` |
| `<SID>/<CLIENT>/<USER>` | SID + client + user | `--switch S4D/200/CONSULTANT` |
| `<description>` | exact, then substring on description OR system_name | `--switch dev-box` |

The slash form is recognised when the hint has 1 or 2 `/` AND every segment
is alphanumeric. Descriptions containing `/` still match via the description
rules below.

On match: action proceeds with the resolved UUID.
On **no match**: stdout `ERROR: no profile matches '<hint>'. Run /sap-login --list.` + exit 1.
On **multiple matches**: stdout `AMBIGUOUS: <json>` + exit 2. The JSON has an
`options[]` array of `{profile_id, description, system_name, client, user,
endpoint_summary}`. Run `AskUserQuestion`, then re-invoke with `-ProfileId <chosen-UUID>`.

### Modes

| Mode | Trigger phrase / arg | What runs |
|---|---|---|
| **list** | `--list`, "list connections", "show profiles" | `sap_login_select.ps1 -Action list` → emit `LIST: <json>`. Present a readable table to the user. **Done.** |
| **set-default** | `--set-default <ref>` | `sap_login_select.ps1 -Action set-default -ProfileId <ref>` → resolves via hint matcher → emit `SUCCESS: default_target_id=...`. **Done.** |
| **switch** | `--switch <ref>`, "switch to X" | `sap_login_select.ps1 -Action switch -ProfileId <ref>` → resolves via hint matcher → re-pins AI session, bumps `last_used_at`, releases old claims. Emits `CONTINUE_TO_STEP1:` and the skill **falls through to Step 1** (connect to the new system). Pass `-NoConnect` (or trigger `--switch <ref> --no-connect`) to re-pin only — `SUCCESS:` line appears without `CONTINUE_TO_STEP1:` and the skill is **Done.** |
| **delete** | `--delete <ref>` | Ask user to confirm deletion (`AskUserQuestion`); on confirm, `sap_login_select.ps1 -Action delete -ProfileId <ref>`. **Done.** |
| **check** | `--check`, "health-check connections", "doctor" | `sap_login_select.ps1 -Action check` → emit a per-profile health table covering DPAPI, DNS, RFC, and live GUI session. Read-only. **Done.** |
| **add** | `--add` | Skip Step 2 (decide); jump to ADD_NEEDED handler in Step 2. Treat as user-initiated new-profile entry. |
| **(default)** | no flag / no relevant arg | Run Steps 0.5 → 6.5 as documented below. |

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{RUN_TEMP}\sap_login_run.json`) so subsequent steps and the final
log-end call append to the same run. Best-effort: silently no-ops if
`userConfig.log_enabled=false` or the lib can't load. **Do not** include
the SAP password in `-ParamsJson` — only system / client / user.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_login_run.json" -Skill sap-login -ParamsJson "{\"system\":\"<SID>\",\"client\":\"<CLIENT>\",\"user\":\"<USER>\"}"
```

---

## Step 0.6 — Detect Requested Login Language (default mode)

Inspect `$ARGUMENTS` for an explicitly-requested logon language and capture two
values used by the rest of the skill:

- **`{REQUESTED_LANG}`** — the language the user asked to log on in, or empty
  when they didn't specify one. Recognise:
  - an explicit flag: `--lang <CODE>` / `--language <CODE>`, or
  - natural language: "log in in Japanese", "use EN", "logon language ZH", etc.

  Normalise the answer to a SAP language token (a 1-char SAP key like `E`/`J`/`1`
  or a 2-char ISO code like `EN`/`JA`/`ZH` are both fine — the driver
  canonicalises EN==E=="English" etc. via `Test-SapLanguageEqual`). If the user
  gave no language, leave `{REQUESTED_LANG}` **empty** — the skill then behaves
  exactly as before (no language gate, reuse the active session as-is).

- **`{FORCE_RELOGIN}`** — `true` if the user passed `--force` (or said "force" /
  "don't ask" / "without confirmation"), else `false`. Controls whether Step 0.9
  asks before closing a mismatched connection.

`{REQUESTED_LANG}` is threaded into **Step 0.8** (`-RequestedLanguage`) and, when
set, becomes the logon language in **Step 3** (overriding a profile's stored
language for this run).

---

## Step 0.7 — Bootstrap (AI session + Migration)

Resolves this conversation's AI-session id (automatic — see "AI-Session
Identity" section near the end of this file) and creates the per-PID
file at `{work_dir}\runtime\ai_session_by_pid\<owner_pid>.txt` if needed.

This step also performs a one-shot migration of the legacy single-connection
fields in `settings.json` into the new `connections.json` store (marking
them as the default). Idempotent.

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\sap_login_select.ps1" -Action init -WorkTemp "{WORK_TEMP}"
```

Stdout signals:
- `INFO: ai_session_id=...` → the conversation's id; broker auto-resolves the same value on subsequent calls.
- `INFO: migrated legacy connection id=...` (optional) → notify the user that the previous single-connection settings were imported as the default.
- `SUCCESS: init complete` → proceed.

---

## Step 0.8 — Selection (decide)

Run the selection driver to pick the target connection. Re-invoke with the
appropriate `-PickProfileId` / `-PickConnectionPath` after each user choice.
Pass `-RequestedLanguage "{REQUESTED_LANG}"` (from Step 0.6) on **every**
`decide` invocation — including the re-invocations after a picker — so the
language gate also applies to a connection the user picks. Omit it (or pass
empty) when no language was requested.

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\sap_login_select.ps1" -Action decide -WorkTemp "{WORK_TEMP}" -RequestedLanguage "{REQUESTED_LANG}"
```

Interpret the **last** structured stdout line:

| Signal | Meaning | Action |
|---|---|---|
| `RESOLVED: path=<P> connection_id=<I> description='<D>'` | Existing AI-session pin already matches a live session. | Skip Steps 1–5; jump to Step 6 (capture) with this `path` and Step 6.5 with this `connection_id`. |
| `ATTACH_ACTIVE: path=<P> connection_id=<I> description='<D>'` | Pick is an already-open SAP connection. | Skip Steps 1–5; jump to Step 6 with this `path`. |
| `CONNECT_PROFILE: id=<I> description='<D>' source=<S>` | Pick is a saved profile. | Look up the profile in `connections.json` (`sap_connection_lib.ps1`), decrypt password (DPAPI), and proceed to Step 3 (Generate Login VBS) with the profile's fields. |
| `PICK_NEEDED: <json>` | User must choose. | Parse `options[]` (each has `kind=active|profile`, `description`, `system_name`, `client`, `user`, `endpoint_summary`, `is_default`). Present via `AskUserQuestion`. Re-invoke `sap_login_select.ps1 -Action decide -PickProfileId <id>` OR `-PickConnectionPath <path>`. |
| `ADD_NEEDED:` | No active connections, no saved profiles. | Prompt the user for a new connection (logon-pad entry, OR app server + system number, OR message server + logon group + system id) plus client/user/password/language. Proceed to Step 3 with the supplied values. After login succeeds, Step 6.5 saves it as a new profile. |
| `RELOGIN_LANG_MISMATCH: <json>` | An active connection matches the target on identity, but its logon language differs from `{REQUESTED_LANG}`. | Handle per **Step 0.9 — Language-mismatch re-login** below (confirm → close → re-login in the requested language). Only ever emitted when `{REQUESTED_LANG}` is non-empty. |

---

## Step 0.9 — Language-mismatch Re-login (only after `RELOGIN_LANG_MISMATCH`)

Step 0.8 emits this signal only when a language was requested (Step 0.6) **and**
an active connection that would otherwise be reused is logged on in a different
language. Parse the JSON payload — key fields: `connection_path`,
`active_language`, `requested_language`, `connection_id` (the saved-profile
UUID, or empty for an ad-hoc connection with no saved profile), `description`,
plus the endpoint fields (`system_name`, `client`, `user`, `application_server`,
`system_number`, `message_server`, `logon_group`, `system_id`,
`logon_pad_entry`).

### Step 0.9a — Confirm (skipped when `{FORCE_RELOGIN}` is true)

Closing a connection drops **all** of its sessions; unsaved work in them is
lost. Unless `{FORCE_RELOGIN}` is true, ask the user via `AskUserQuestion`:

> The connection `<description>` (`<system_name>/<client>/<user>`) is currently
> logged on in **`<active_language>`**, but you asked for
> **`<requested_language>`**. Close it (losing any unsaved work in its sessions)
> and log back on in `<requested_language>`?
>
> - **Close and re-login** — proceed with Step 0.9b.
> - **Keep current session** — skip the re-login; attach to the existing session
>   as-is (jump to Step 6 with `connection_path` + `/ses[0]`). The session keeps
>   its current language.

If `{FORCE_RELOGIN}` is true, skip the prompt and proceed straight to Step 0.9b.

### Step 0.9b — Close the connection

```bash
C:/Windows/SysWOW64/cscript.exe //NoLogo "<SKILL_DIR>\references\sap_close_connection.vbs" "<connection_path>"
```

Expect `CLOSED: <connection_path>` on the last line. On `ERROR:` (e.g. a logoff
confirmation popup blocked the close), show the output and stop — do **not**
proceed to re-login against a half-closed connection.

### Step 0.9c — Re-login in the requested language

Now log in fresh, using `{REQUESTED_LANG}` as the logon language:

- **`connection_id` non-empty** (a saved profile exists): load + decrypt it per
  **Step 2a**, then run **Step 3** with the profile's endpoint fields and
  `THE_LANGUAGE = {REQUESTED_LANG}` (override the profile's stored language).
- **`connection_id` empty** (ad-hoc connection, no saved profile): use the
  endpoint fields from the JSON payload directly in **Step 3**, set
  `THE_LANGUAGE = {REQUESTED_LANG}`, and prompt the user for the **password**
  (it was never stored). After a successful login, Step 6.5 saves it as a new
  profile.

Then continue to **Step 6** (capture) and **Step 6.5** (finalize) as normal.

> **Caveat — duplicate connections to the same system.** Step 0.9b closes only
> the one `connection_path` reported. If the user has a *second* connection / tab
> still open to the same `system_name`/`client`/`user`, the login VBS's
> identity-based reuse (Step 3) may attach to that one and skip the language
> change. Close those too (re-run `/sap-login --lang <CODE>`) if it happens.

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
| `STATUS: LOGGED_IN` | Authenticated session found | Report session info (SYSTEM, CLIENT, USER, LANGUAGE, CODEPAGE from output). If `{REQUESTED_LANG}` (Step 0.6) is set **and** differs from the reported `LANGUAGE`, treat it as a language mismatch — go to **Step 0.9** (confirm → close → re-login) instead of finishing. Otherwise **Done — skip Steps 2-5.** |
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

**Step 2b-pre — Check the SAP Logon Pad landscape for known entries.**

Before asking the user to type endpoint values from scratch, enumerate the
entries they already have configured in SAP Logon (`SAPUILandscape.xml`,
`SAPUILandscapeGlobal.xml`, and legacy `saplogon.ini`):

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\sap_login_select.ps1" -Action landscape-entries -WorkTemp "{WORK_TEMP}"
```

Parse the **last** stdout line:

| Signal | Action |
|---|---|
| `LANDSCAPE: []` | No entries found. Skip to the manual flow below. |
| `LANDSCAPE: [<json>]` | Parse the array. Each element has `name`, `kind` (`direct`/`load_balanced`), `server`, `system_number`, `message_server`, `logon_group`, `system_id`, `description`, `source`. Present a picker via `AskUserQuestion` whose options are each entry (label = `<name> — <kind> — <endpoint summary>`) plus one extra "Manual entry…" option. **One question, multi-select=false.** |

On entry-pick: **use the SAP Logon Pad method** — set `THE_LOGON_DESC` to
the picked `name`, and use the picked `system_id` / `system_name` for the
profile's `system_name` field (so the new reuse-loop identity check from
Phase 4.4 works). Leave server / system_number / msrv / grp / sid token
fields empty in Step 3 — SAP GUI resolves them from the pad entry. Then
ask only for client / user / password / language. The user types four
fields instead of ten.

On "Manual entry": fall through to the manual prompt below.

**Step 2b-manual — Type endpoint values directly.**

Ask the user via `AskUserQuestion` for whichever endpoint set they want to
configure:

- **SAP Logon pad entry** (simplest) — just the entry-name string. Then ask
  for client / user / password / language.
- **Direct connect** — app server hostname/IP, 2-digit system number, plus
  client / user / password / language. **Remember the hostname the user
  typed** — pass it as `-UserAppServerHint` to Step 6.5 finalize so the
  resolver can replace any divergent value returned by `Info.ApplicationServer`.
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
in the generated `{RUN_TEMP}\sap_login_run.vbs` (which Step 5
deletes). Do NOT echo the decrypted value to your reply or to any
log.

---

## Step 3 — Generate and Run the Login VBScript

The VBScript template is at `sap-dev-core/shared/scripts/sap_login.vbs`.

Write `{RUN_TEMP}\sap_login_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_login.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_LOGON_DESCRIPTION%%','THE_LOGON_DESC')
$content = $content.Replace('%%SAP_APPLICATION_SERVER%%','THE_SERVER')
$content = $content.Replace('%%SAP_SYSTEM_NUMBER%%','THE_SYSNR')
$content = $content.Replace('%%SAP_MESSAGE_SERVER%%','THE_MSG_SERVER')
$content = $content.Replace('%%SAP_LOGON_GROUP%%','THE_LOGON_GROUP')
$content = $content.Replace('%%SAP_SYSTEM_ID%%','THE_SYSTEM_ID')
$content = $content.Replace('%%SAP_SYSTEM_NAME%%','THE_SYSTEM_NAME')
$content = $content.Replace('%%SAP_CLIENT%%','THE_CLIENT')
$content = $content.Replace('%%SAP_USER%%','THE_USER')
$content = $content.Replace('%%SAP_PASSWORD%%','THE_PASSWORD')
$content = $content.Replace('%%SAP_LANGUAGE%%','THE_LANGUAGE')
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_login_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
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
- `THE_SYSTEM_NAME` is **always** the profile's `system_name` (SID — e.g. `S4D`, `S4H`). Used by the VBS reuse-loop's identity match — independent of which of the three endpoint methods is chosen. Leave empty for legacy profiles with no SID; the VBS falls back to Client+User matching.
- `THE_LANGUAGE` is **`{REQUESTED_LANG}`** when the user requested a language (Step 0.6) — it overrides the profile's stored `language` for this login. Otherwise use the profile's `language` (CONNECT_PROFILE) or the value the user typed (ADD flow). This is what makes the Step 0.9 re-login actually land in the requested language.

If a field is unused in the chosen method, substitute the empty string `""`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_login_run.ps1"
```

### Execute

```bash
cscript //NoLogo {RUN_TEMP}\sap_login_run.vbs
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

Direct-server path (write `{RUN_TEMP}\sap_rfc_test_run.ps1`):
```powershell
$content = [System.IO.File]::ReadAllText('<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_connect.ps1', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_APPLICATION_SERVER%%','THE_SERVER')
$content = $content.Replace('%%SAP_SYSTEM_NUMBER%%','THE_SYSNR')
$content = $content.Replace('%%SAP_CLIENT%%','THE_CLIENT')
$content = $content.Replace('%%SAP_USER%%','THE_USER')
$content = $content.Replace('%%SAP_PASSWORD%%','THE_PASSWORD')
$content = $content.Replace('%%SAP_LANGUAGE%%','THE_LANGUAGE')
$content = $content.Replace('%%RFC_LIB_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_rfc_test_run.ps1', $content, [System.Text.Encoding]::UTF8)
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
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_rfc_test_run.ps1"
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
cmd /c del {RUN_TEMP}\sap_login_run.vbs & del {RUN_TEMP}\sap_login_run.ps1 & del {RUN_TEMP}\sap_rfc_test_run.ps1
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
C:/Windows/SysWOW64/cscript.exe //NoLogo "<SKILL_DIR>\references\sap_login_capture_active_session.vbs" "<session-path-from-step-0.8-or-blank>"
```

Last line of stdout:
- `{"session_path":"/app/con[0]/ses[0]", ...}` — single-line JSON record. Save this to a variable for Step 6.5.
- `MULTI:[ {...}, ... ]` — only fires when the wrapper passed no hint AND multiple connections are attached AND Step 0.8 didn't already pick one. Should be rare after Phase 4 (Step 0.8 picks first). If it happens, present a picker via `AskUserQuestion`, then re-invoke the VBS with **both** the chosen `session_path` **and** the `connection_string` field from the chosen entry as a second argument. SAP GUI can reorder connection indices between the two calls; the second argument lets the VBS recover by scanning for the connection by description when the path-based lookup returns the wrong session:
  ```bash
  C:/Windows/SysWOW64/cscript.exe //NoLogo "<SKILL_DIR>\references\sap_login_capture_active_session.vbs" "<chosen-session_path>" "<chosen-connection_string>"
  ```
- `WARN: SAP GUI reordered connections ...` — logged when the path hint matched a different connection than expected; the VBS scanned by description and recovered automatically.
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

1. **Reconciles `application_server`** via `Resolve-SapApplicationServer`. SAP GUI's `Info.ApplicationServer` returns the host's *internal* identity (e.g. `s4sapdev`), which is not DNS-resolvable from NAT / dynamic-DNS / reverse-proxy workstations. The resolver runs a three-step cascade: captured value → user hint (`-UserAppServerHint`) → SAP Logon Pad entry's `SAPUILandscape.xml` / `saplogon.ini` lookup. First DNS hit wins; on total failure the captured value is kept and a `WARN:` is emitted (SAP GUI keeps working; RFC will be the casualty).
2. Saves (or merges via 4-step dedup) the profile in `{work_dir}\runtime\connections.json`.
3. Assigns the profile's UUID as `connection_id` on the live broker registry block (`broker set-connection-id`).
4. Pins the AI session to that `connection_id` (`broker pin`). On a switch, this releases stale claims from the old connection.
5. Phase 4.2: the pin file `sap_active_session.json` is **removed entirely**. Consumer skills get the session path via `Get-SapCurrentSessionPath` (from `sap_connection_lib.ps1`) — which reads the broker's `session_registry.json` for the AI-session's pinned connection, finds a usable session there, and returns the path. Version info goes through `Get-SapCurrentConnectionProfile` (reads the profile in `connections.json` by `connection_id`).

```powershell
$captured = '<single-line JSON from Step 6>'   # exact string
$newDesc  = '<user-supplied Logon description, or empty>'
$newPwd   = '<dpapi:... ciphertext, or empty>'
$userHost = '<hostname the user typed in Step 2b ADD flow, or empty>'

powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\sap_login_select.ps1" `
    -Action finalize `
    -WorkTemp "{WORK_TEMP}" `
    -CapturedJson $captured `
    -NewLogonDescription $newDesc `
    -NewPasswordDpapi $newPwd `
    -UserAppServerHint $userHost
```

Pass `-UserAppServerHint` when the user typed the application-server hostname directly in Step 2b's ADD flow — it takes precedence over the SAPUILandscape lookup. For SAP-Logon-Pad-only flows (existing entry), leave it empty and the resolver auto-discovers from saplogon.

Expected stdout (one of):
- `INFO: application_server='<host>' (captured; DNS-resolvable)` — happy path; no rewrite.
- `INFO: application_server='<host>' (user hint resolves; replacing captured '<x>')`
- `INFO: application_server='<host>' (resolved via SAP Logon Pad entry '<entry>'; replacing captured '<x>')`
- `WARN: application_server='<x>' is NOT DNS-resolvable from this workstation. SAP GUI will work; RFC will not until you correct this value (edit connections.json or rerun /sap-login with -UserAppServerHint <hostname>).`

Then:
- `INFO: profile saved id=<UUID> description='<auto-derived or user-supplied>'`
- `INFO: ai_session=... pinned to connection_id=...` (no pin file in Phase 4.2)
- `SUCCESS: connection_id=<UUID> description='<...>' session_path=/app/con[N]/ses[M]`

If the `WARN:` fires AND the user expects RFC to work, **prompt for the correct hostname via `AskUserQuestion`** and rerun finalize with `-UserAppServerHint <answer>`. **Do NOT block the GUI flow** — RFC is optional for most SAP work; the profile is still saved with the captured value as a placeholder.

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

### Step 6.7 — Ensure a dedicated session (parallel-conversation isolation)

After the pin is set, claim a **dedicated SAP session** for this
conversation so two conversations logged into the **same** SAP connection
never drive the same `/app/con[N]/ses[M]` (without this,
`Get-SapCurrentSessionPath` hands both the connection's first session and
they trample each other). Best-effort — do **not** fail the login if this
step errors:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_broker.ps1" -Action ensure-own-session -WorkTemp "{WORK_TEMP}" -TtlSeconds 2592000 -OwnerSkill sap-login
```

The broker auto-resolves this conversation's AI-session id (from
`CLAUDE_CODE_SESSION_ID` when set — stable across a Claude host restart —
else a parent-PID walk; see "AI-Session Identity" below) and prints one of:

- `OWN_SESSION: … formalized=true` — **first / sole** conversation on the
  connection: it claims the session it already resolves to (usually
  `ses[0]`); no new window opens.
- `OWN_SESSION: … spawned=true` — **a second live conversation** is already
  on this connection: it opens a fresh `ses[1]` (resetting only that
  newcomer to Easy Access — the other conversation's session is never
  touched) and claims it. Tell the user a second SAP session window opened
  for this conversation.
- `NO_PIN: …` — nothing pinned yet (e.g. an RFC-only flow); nothing to
  isolate, continue.

The claim's `owner_pid` is this conversation's process, so the broker's
PID-death sweep releases it automatically when the conversation ends. From
here on `Get-SapCurrentSessionPath` returns this conversation's own session
and every downstream skill wrapper picks it up via
`$env:SAPDEV_SESSION_PATH` (see the resolution contract below).

---

## Consumer-skill resolution contract (unchanged interface, Phase-4 enriched)

Every downstream skill resolves its target session like this:

1. Explicit `--session "<path>"` arg → use it.
2. Else use `Get-SapCurrentSessionPath` (in `sap_connection_lib.ps1`): looks up `session_registry.json`'s `ai_sessions[<id>].connection_id` for this AI session, finds the matching connection block, and returns a usable session path on it. Falls back to sole-connection auto-default for the single-conn case.
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
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_login_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_login_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `LOGIN_FAILED`, `RFC_LOGON_FAILED`, `GUI_TIMEOUT`.

---

## AI-Session Identity (automatic; stable conversation id + liveness breadcrumb)

The Phase-4 AI-session pin scope is identified by `Get-SapAiSessionId` in
`sap_connection_lib.ps1`, which resolves the id from the most stable source
available:

1. `SAPDEV_AI_SESSION_ID` (env override) — tests / manual one-offs only.
2. **`CLAUDE_CODE_SESSION_ID`** (env, provided by the Claude Code host) — the
   normal production source. STABLE for the whole conversation and survives a
   Claude host-process restart (unlike a PID, which changes on restart).
3. **Parent-PID walk** (fallback for non-Claude-Code hosts) — walks up the
   process tree from the current PowerShell/cscript, skipping script-host
   processes (`powershell`, `pwsh`, `cscript`, `wscript`, `cmd`, `conhost`,
   `bash`, `sh`, …) to the first non-script-host ancestor (the conversation
   process), minting a GUID keyed to that owner PID.

In every case the function ALSO writes a **liveness breadcrumb** at
`{work_dir}\runtime\ai_session_by_pid\<owner_pid>.txt` (content = the id),
keyed to the long-lived conversation process. This is what lets the broker
tell parallel conversations apart: `ensure-own-session` reads that directory
(`Get-LiveAiSessionIds`) to see which conversations are still alive, and
reverse-maps an id to its owner PID (`Get-PidForAiSession`) so a claim's
`owner_pid` is the conversation's process and the PID-death sweep
auto-releases it. Opportunistic GC drops files for dead PIDs, so the
directory stays small. Subagents inherit the same id (shared env var, or
shared ancestor in the fallback); parallel conversations get different ids.

> Regression (fixed 2026-06-20): the `CLAUDE_CODE_SESSION_ID` path used to
> return the id WITHOUT writing the breadcrumb, leaving the directory empty —
> so the broker saw zero live conversations and every parallel conversation
> collapsed onto a shared `ses[0]`. The write is now unconditional; regression
> test at `sap-dev/scripts/test-ai-session-isolation.ps1`.

**No SessionStart hook needed.** Earlier drafts of Phase 4 used a write-
once-if-missing `ai_session_id.txt` file written by a hook, but that
silently shared one id across parallel conversations. The resolution above is
automatic, scoped correctly, and has no external setup requirement.

---

## Security Note

**At rest** — `sap_password` in `settings.json` is stored DPAPI-encrypted
(`dpapi:<base64>`) under the CurrentUser scope. Decryption is bound to
the Windows user account on the machine that performed the encryption;
a copied `settings.json` is useless on another machine. See Step 2a
(decrypt-on-read) and Step 5b (encrypt-on-save). Plaintext values are
still accepted for backward compatibility but trigger a warning that
prompts the operator to re-save.

**In flight** — `{RUN_TEMP}\sap_login_run.vbs` and
`{RUN_TEMP}\sap_rfc_test_run.ps1` contain the **decrypted plaintext**
during execution because SAP GUI / NCo need it that way. Step 5
deletes both files immediately after use. Never re-use these files
across runs and never copy them out of `{RUN_TEMP}`.

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
