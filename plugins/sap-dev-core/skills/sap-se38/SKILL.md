---
name: sap-se38
description: |
  Deploys ABAP source to a SAP system via SE38 (SAP GUI Scripting) — creates or
  updates programs: existence check, source upload (file path or pasted code),
  syntax check, save, activate, and (for Report type 1) selection-text update.
  Also three secondary modes on an existing program: check-and-fix ("fix PGM" /
  "check and fix PGM" with no source file — syntax-check, download, fix errors,
  re-upload, activate); change-attributes (Title / Status / Type / header fields
  via Goto → Attributes, then Save + Activate so it persists); delete ("delete
  program <X>" — irreversible, asks for explicit confirmation, verifies removal).
  Handles the SAPLSETX original-language popup and the Workbench-request popup per
  /sap-transport-request.
  Prerequisites: active SAP GUI session (/sap-login first).
argument-hint: "<program-name> [path-to-source]"
---

# SAP SE38 Deploy Skill

You deploy ABAP source code to a live SAP system via SE38 using SAP GUI Scripting.
The skill checks if the program exists, then creates or updates it.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` (Step 1b) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — deployed program source must follow modern syntax, OOP scaffolds, no literal MESSAGE strings, perf-band-appropriate SQL. Run `/sap-check-abap` before deploy when the source isn't generator-emitted. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_lib.ps1` | Structured logger. Driven via the shared `sap_log_helper.ps1` wrapper that persists `run_id` between skill steps. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | Shared start/step/end wrapper around `sap_log_lib.ps1`. Persists run state to `{RUN_TEMP}\sap_se38_run.json` so this skill's discrete bash blocks share one logical run. Logging is best-effort and never breaks the skill. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_error_hints.ps1` | frequently_errors recorder. Step 6b feeds deploy syntax/activation errors (`-Action record -Source SE38 -RawOutputFile ...`) so FM/METHOD-related failures are captured to the team store. Best-effort; never changes the verdict. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_syntax_check.ps1` | Headless compiler syntax pre-check (Step 4.6) — runs `EDITOR_SYNTAX_CHECK` via the dev-init wrapper before the GUI deploy so a syntax error is caught pre-upload. Program type `1` only (self-contained); degrades to the Step 5 Ctrl+F2 when RFC/wrapper is unavailable. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/sap_gui_security_handling.md` | SAP GUI Security dialog handling — the check-and-fix **source download** (Step A) is SAP-GUI-side file IO, so it can raise the modal "SAP GUI Security" dialog (which suspends the Scripting API and hangs cscript). Pre-check + OS-level watcher wrap that download. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_precheck.ps1` | Read-only allow-list pre-check (`saprules.xml`) — `ALLOWED` (exit 0) / `NOT_COVERED` (exit 1). Used by Step A before the source download. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_sidecar.ps1` | OS-level (Win32) watcher that auto-dismisses the SAP GUI Security dialog (ticks Remember + clicks Allow). Launched as a background process before the Step A download. |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the `RUN_TEMP=` value printed above — a fresh per-run scratch
directory `{work_dir}\temp\run_<id>`, already created by `Get-SapRunTemp`.
Resolve it **once here** and reuse the same value for the rest of this
invocation; it isolates this run's generated wrappers / state / scratch files so
concurrent runs (parallel sub-agents, multi-connection deploys) never collide.
**`{WORK_TEMP}` stays the base temp dir** and is used ONLY for
`Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'` (the session-attach plumbing
derives `{work_dir}\runtime` from its parent, so it must see the base path, not
the run dir). Everything the skill writes itself goes under `{RUN_TEMP}`.

---

## Step 0.5 — Start Logging

Start a structured log run for this skill invocation. The helper persists
the `run_id` to a state file so subsequent steps and Step 7 can append to
the same run. Logging is best-effort: if `userConfig.log_enabled` is
`false` or the lib can't load, the helper silently no-ops.

State file: `{RUN_TEMP}\sap_se38_run.json`

Build a JSON params object with the values gathered in Step 1 (omit any
that are blank). Always include `program`. Include `mode` (`create` /
`update` / `fix` / `change_attrs`), and optionally `package`, `transport`,
`source_path`. **Never** include passwords or other secrets — the log lib
will mask known-sensitive keys, but don't add them in the first place.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_se38_run.json" -Skill sap-se38 -ParamsJson "{\"program\":\"<PROGRAM_NAME>\",\"mode\":\"<MODE>\",\"package\":\"<PACKAGE>\",\"transport\":\"<TRANSPORT>\"}"
```

(Replace `<PACKAGE>` / `<TRANSPORT>` with empty strings if not yet known — 
Step 1b will log the resolved TR separately.)

---

## Step 1 — Collect Parameters

**Program Details**

| Parameter | Description | Example |
|---|---|---|
| Program name | ABAP name (Z/Y namespace, max 40 chars) | `ZMYREPORT` |
| Program type | Type code (only for new programs): `1`=Executable, `I`=Include, `M`=Module Pool, `F`=Function Group, `K`=Class, `S`=Subroutine Pool | `1` |
| Program title | Short description, max 70 chars (only for new programs) | `My Hello World Report` |
| Source | Either: absolute path to an existing `.abap` file, OR paste the ABAP code directly | |
| Package | SAP package for transport (optional; blank = local object $TMP) | `ZHKA001` |
| Transport | Transport request number (optional; resolved by `/sap-transport-request` per `way_to_get_transport_request` if not supplied) | `S4DK940992` |

**Mode selection:**

| Task | Source provided? | Flow |
|---|---|---|
| Deploy new or updated code | Yes (file path or pasted) | Steps 2 → 3 → 4 → 4.6 → 4.7 → 5a/5b → [5c] → 6 → 7 (Step 4.7 RFC-inserts a NEW text-element-free program and **skips 5a/5b** on success; otherwise falls through to the GUI upload) |
| Fix / check existing program | No | Steps 3 → A → B → C → 6 → 7 |
| Change program **attributes** (Title / Status / Type / …) | No | Steps 1b → 3 → 5d → 6 → 7 |
| **Delete** program | No | Steps 1b → 3 → 5e → 6 → 7 |

If the user says **"fix `<PGM>`"**, **"check `<PGM>`"**, or **"check and fix `<PGM>`"** and provides no source code, skip directly to **Step A**.

If the user says **"change attributes of `<PGM>`"**, **"set title/status/type of `<PGM>`"**, or otherwise asks to modify program header fields (no source involved), skip directly to **Step 5d**.

If the user says **"delete program `<PGM>`"**, **"drop report `<PGM>`"**, or **"remove pgm `<PGM>`"**, skip directly to **Step 5e**. Deletion is **irreversible** — the skill MUST confirm with the user before running the VBS.

---

## Step 1b — Resolve Transport Request

If `Package` is empty or starts with `$` (e.g. `$TMP`), this is a local
object; **skip this step** (`%%TRANSPORT%%` will be empty).

Otherwise a TR is needed. **Do NOT prompt the user directly and do NOT call
`/sap-se01`.** Delegate to `/sap-transport-request`:

```
/sap-transport-request [<TR-from-args-if-any>] OBJECT_TYPE=REPORT OBJECT_DESCRIPTION=<PROGRAM_NAME>
```

Use the returned modifiable TRKORR as the `%%TRANSPORT%%` token value in all
subsequent VBS templates. If `/sap-transport-request` reports `ERROR`, stop
and surface it to the user.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action step -StateFile "{RUN_TEMP}\sap_se38_run.json" -Step "transport" -Message "resolved TR=<TRKORR>"
```

If the TR resolution failed, end the log run with FAILED before stopping:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se38_run.json" -Status FAILED -ExitCode 2 -ErrorClass TR_RESOLUTION_FAILED -ErrorMsg "<short error>"
```

See `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for the full policy.

---

## Step 2 — Prepare ABAP Source File

**If the user pasted source code directly:**

1. Write the source to: `{RUN_TEMP}\<PROGRAM_NAME>.abap`
   - Use the Write tool with the exact ABAP source as content.
2. Confirm the file by reading back the first 5 lines.

**If the user provided a file path:**

- Use that path as-is. Verify it exists:
  ```bash
  cmd /c if exist "<path>" (echo EXISTS) else (echo NOT FOUND)
  ```

**Extract Program Name from source if not provided:**

Look for the `REPORT` or `PROGRAM` statement in the first few lines of the ABAP source:
```
REPORT ZMYREPORT.
```
or
```
PROGRAM ZMYREPORT.
```
Use the identifier after `REPORT`/`PROGRAM` as the program name (force UPPERCASE).

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Program Exists

The check VBScript template is at `./references/sap_se38_check.vbs`.

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se38_check_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se38_check.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%PROGRAM_NAME%%','THE_PROGRAM_NAME'
# Phase 4.2 session-attach plumbing. SESSION_PATH empty -> attach lib falls
# through to SAPDEV_SESSION_PATH (set below) -> sole-connection -> refuse.
# Pass --session for explicit targeting in parallel/multi-connection contexts.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se38_check_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_PROGRAM_NAME` with the actual program name (UPPERCASE) and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se38_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {RUN_TEMP}\sap_se38_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → program exists → proceed to Step 5a (Update).
- `NOT_EXIST` → program does not exist → proceed to Step 5b (Create).
- `ERROR:` → show full output and stop.

Log the result:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action step -StateFile "{RUN_TEMP}\sap_se38_run.json" -Step "check" -Message "<EXIST|NOT_EXIST>"
```

If the check returned `ERROR:`, end the run with FAILED:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se38_run.json" -Status FAILED -ExitCode 1 -ErrorClass SE38_CHECK_FAILED -ErrorMsg "<short error>"
```

---

## Step 4.5 — Naming Pre-Check

Validate the program name against `sap_object_naming_rules.tsv` (custom override → default) **before** launching any create / update flow:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType PROGRAM -ObjectName THE_PROGRAM_NAME -CustomUrl "{custom_url}"
```

Behaviour:
- Exit `0` (`OK ...`) → silently continue.
- Exit `1` (`VIOLATION ...`) → show the violation line to the user and ask:
  *"The program name does not match the configured naming rule. Proceed anyway, or abort?"*
  - **Abort** → end the run with `Status SKIPPED`, `ErrorClass OBJECT_NAMING_VIOLATION`.
  - **Proceed** → continue (the customer's project may legitimately diverge mid-stream; record the choice via `sap_log_helper.ps1 -Action step`).
- Exit `2` (`UNKNOWN_TYPE` / `RULES_NOT_FOUND`) → log a step note and continue.

To customise the rule, the user edits `{custom_url}\sap_object_naming_rules.tsv`.

---

## Step 4.6 — Headless Syntax Pre-Check (RFC)

**Deploy flow only** (source was provided). Skip for fix / change-attributes / delete modes.

Run a headless, compiler-level ABAP syntax check on the source *before* the GUI
deploy — the offline equivalent of Ctrl+F2, so a syntax error is caught before any
upload round-trip. Uses the shared engine
`<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_syntax_check.ps1` (calls
`EDITOR_SYNTAX_CHECK` through the dev-init wrapper `Z_GENERIC_RFC_WRAPPER_TBL`;
read-only, no writes).

**Applicability — only self-contained programs check standalone.** Look at the
first non-comment statement of the source:
- `REPORT` / `PROGRAM` (program type `1`) → run the check with `-Subc 1`.
- An **include** (`I`), **module pool** (`M`), or any other fragment/pool → **skip**
  this step with an INFO note. Those are not standalone-compilable; they are
  syntax-checked in-context by the Ctrl+F2 in Step 5 after upload.

Let `SOURCE_FILE` = the source path from Step 2 (the user's file, or the staged
`{RUN_TEMP}\<PROGRAM_NAME>.abap`). Run under **32-bit** PowerShell (NCo 3.1):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_syntax_check.ps1" -SourceFile "<SOURCE_FILE>" -ProgramName "<PROGRAM_NAME>" -Subc "1" -OutTsv "{RUN_TEMP}\<PROGRAM_NAME>.syntax.tsv"
```

Parse the `STATUS:` line:

| Result | Action |
|---|---|
| `STATUS: CLEAN` | Silently continue to Step 5. |
| `STATUS: FINDINGS errors=<e> …` with `e > 0` | **Gate.** Show each `SYNTAX: ERROR LINE=.. COL=.. MSG=..` line. Ask the user to fix the source and re-run, or to proceed anyway (the Step 5 Ctrl+F2 will re-check). Do **not** deploy known-broken source without explicit confirmation. Log `syntax_precheck errors=<e>`. |
| `STATUS: FINDINGS` with `e = 0` (warnings only) | Show the `SYNTAX: WARN` lines and continue. |
| `STATUS: RFC_ERROR …` / `INPUT_ERROR …` / wrapper not found | **Degrade — never block.** The headless pre-check is unavailable (RFC off, wrapper not deployed via `/sap-dev-init`, or bad source path). Log an INFO note `syntax_precheck unavailable: <reason>` and continue — the Step 5 Ctrl+F2 remains the syntax gate. |

This is a *pre-flight*; it never replaces the in-editor Ctrl+F2 that Steps 5a/5b
run after upload. On RFC-capable systems it just moves the catch earlier, before
any GUI work.

---

## Step 4.7 — RFC Source Insert (preferred deploy path for a NEW program)

**Deploy flow only.** Skip for fix / change-attributes / delete modes.

When RFC is available, deploying a **new** program via `RPY_PROGRAM_INSERT` is preferred over the
GUI upload: it inserts the source and **generates it active in one headless call**, sidestepping
the clipboard-paste focus fragility and the GUI inactive-objects worklist (the dead end on a user
with a big inactive backlog). It is **create-only** and deploys **source only** — so it applies
to a subset; every other case falls through to the GUI Step 5.

**Applicability gate — use the RFC path only when ALL hold** (else go straight to Step 5a/5b):
1. Step 4 returned **`NOT_EXIST`** (a NEW program). An existing program updates via the GUI Step 5a
   (`RPY_PROGRAM_UPDATE` is not remote-enabled — user-confirmed create=RFC / update=GUI split).
2. The user did **not** force GUI (`--gui` argument absent, and `sap_dev_mode` is not explicitly `GUI`).
3. The source has **no text elements** — scan it: NO `PARAMETERS`, NO `SELECT-OPTIONS`, NO `TEXT-NNN`.
   A text-bearing report needs the Step 5c selection/text-element handling that the RFC insert does
   not do, so it deploys via the GUI Step 5b instead (avoids a source-active-but-texts-missing state).

If any gate fails → proceed to Step 5a/5b (GUI) as today.

**Resolve the deploy target** (the RFC insert needs these up front, unlike the interactive GUI dialogs):
- **Package** — the user-specified package, else the `sap_dev_package` dev default; a local object uses `$TMP`.
- **Transport** — for a transportable package, resolve a modifiable TR via `/sap-transport-request`
  (per `shared/rules/tr_resolution.md`); for `$TMP`, none.

Run the shared helper (32-bit PS; NCo 3.1):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_rfc_program_insert.ps1" -SourceFile "<SOURCE_FILE>" -ProgramName "<PROGRAM_NAME>" -Package "<PACKAGE>" -Transport "<TR>"
```

Parse the `STATUS:` line:

| Result | Action |
|---|---|
| `STATUS: INSERTED_ACTIVE …` | **Deployed via RFC.** Source is inserted + active. **Skip Step 5a/5b/5c** and go to **Step 6** — its post-activate verify (`sap_se38_post_activate_verify.ps1`) confirms PROGDIR STATE=A / DWINACTIV empty. Log `rfc_deploy inserted_active`. |
| `STATUS: EXISTS …` | The program actually exists → **fall through to Step 5a (GUI update)**. |
| `STATUS: NOT_ACTIVE …` | Inserted but did not generate active (e.g. a syntax error the precheck missed). **Fall through to Step 5b (GUI)** so the in-editor Ctrl+F2 surfaces it; log the reason. |
| `STATUS: RFC_ERROR …` / `STATUS: INSERT_FAILED …` | **Degrade — never block.** RFC unavailable / FMODE≠R / insert exception. Log `rfc_deploy unavailable: <reason>` and **fall through to Step 5b (GUI)**. |

The helper's first line `INFO: HAS_TEXTPOOL=1` is a safety backstop for gate 3 — if you see it after the
insert, the program has text-bearing constructs; ensure Step 5c still runs (or prefer the GUI path).

This never replaces the GUI path — it is a headless fast-path that, when it succeeds, removes the GUI
round-trip entirely; on any gap it silently hands back to Step 5.

---

## Step 5a — Update Existing Program

The update VBScript template is at `./references/sap_se38_update.vbs`.

**Update flow (Original-language popup handling):** The template inspects
`wnd[1]` immediately after pressing the Change button (`btnCHAP`). If the
popup is the SAPLSETX "Different original and logon languages" dialog
(fingerprint: `wnd[1]/usr/ctxtRSETX-MASTERLANG` is present), the template
presses `wnd[1]/usr/btnPUSH1` ("Maint. in orig. lang.") — the safe choice
that lets us edit translations without overwriting `TADIR-MASTERLANG`. This
popup appears when `sap_language` differs from the object's MASTERLANG.

**Update flow (TR popup handling):** The template now sends `Ctrl+S` immediately
after entering change mode (before uploading any source) to provoke the
"Prompt for local Workbench request" popup. If `wnd[1]` shows a TR field
(`ctxtKO008-TRKORR`), the template fills `SAP_TRANSPORT` and presses Enter,
locking the object to that TR. If no popup appears, the object is local
(`$TMP`) or already locked to a modifiable TR — proceed without prompting.
If the popup appears but `SAP_TRANSPORT` is empty, the VBS aborts; the caller
must run `/sap-transport-request` (Step 1b) first. Diagnostics on unexpected
behaviour: query `TADIR` for `DEVCLASS` (starts with `$` → local), `E071`
for object →TR linkage, `E070-TRSTATUS` for TR modifiable state.

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se38_update_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se38_update.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%PROGRAM_NAME%%','THE_PROGRAM_NAME'
# Program type: 'I' for an Include program (skips the F8 run-test verify, since
# includes are NOT executable), otherwise empty/'1' for a normal report.
$content = $content -replace '%%PROGRAM_TYPE%%','THE_PROGRAM_TYPE'
$content = $content -replace '%%ABAP_SOURCE_FILE%%','THE_SOURCE_PATH'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
$content = $content -replace '%%FOREGROUND_GUARD_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_foreground_guard.ps1'
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
# Locale-aware syntax-check classifier (Ctrl+F2 grid MSGTYPE match for ZH/JA/DE logons).
$content = $content -replace '%%SYNTAX_CHECK_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_syntax_check_lib.vbs'
# Post-activate RFC verify: reuse the generic SE11 VBS invoker; SE38-specific PS1
# queries PROGDIR.STATE. Closes the 2026-05-27 screen-101 false-success path.
$content = $content -replace '%%POST_ACTIVATE_VERIFY_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_se11_post_activate_verify.vbs'
$content = $content -replace '%%POST_ACTIVATE_VERIFY_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_se38_post_activate_verify.ps1'
# Post-activate CONTENT verify (2026-07-02): reads the active source back via RPY_PROGRAM_READ
# and compares it to the deployed file. Closes the EC2 clipboard-paste false-success where a
# silently-failed paste leaves the OLD source active and PROGDIR/F8 still pass.
$content = $content -replace '%%CONTENT_VERIFY_VBS%%','<SKILL_DIR>\references\sap_se38_content_verify.vbs'
$content = $content -replace '%%CONTENT_VERIFY_PS1%%','<SKILL_DIR>\references\sap_se38_content_verify.ps1'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se38_update_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_PROGRAM_NAME` (UPPERCASE), `THE_PROGRAM_TYPE` (`I` when updating an **Include** program — e.g. a function-exit `ZX…` include — so the verify skips the F8 run-test; otherwise empty or `1`), `THE_SOURCE_PATH` (absolute path with backslashes), `THE_PACKAGE` (SAP package or empty string), `THE_TRANSPORT` (transport number or empty string), `<SKILL_DIR>`, and `<SAP_DEV_CORE_SHARED_DIR>` (absolute path to `plugins/sap-dev-core/shared/`).

> **Include programs are not executable.** When updating (or creating) an Include (`SUBC = I`) — such as customer function-exit includes (`ZX…`) — pass `PROGRAM_TYPE = I`. The skill then verifies activation via the RFC `PROGDIR.STATE` check and does **not** attempt to run it via SA38/F8 (which would error and look like a false activation failure).

**Package/Transport behavior:**
- If both `%%PACKAGE%%` and `%%TRANSPORT%%` are non-empty: saves to that package with the transport request
- If either is empty: saves as Local Object ($TMP)

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se38_update_run.ps1"
```

### Execute

```bash
# SE38 stages ABAP source on the Windows clipboard + SendKeys ^v behind an OS
# foreground guard -- both machine-global singletons that a per-run folder cannot
# isolate. Serialize the paste across concurrent runs with a global named mutex.
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_run_with_lock.ps1" -MutexName SapDevGuiPaste_v1 -TimeoutMs 180000 -Command "cscript //NoLogo {RUN_TEMP}\sap_se38_update_run.vbs"
```

Proceed to Step 6 to evaluate the result.

> **Clipboard-free upload — investigated, deferred (2026-07-02).** SE38 is the
> only deploy skill still bound to the Windows clipboard (`Set-Clipboard` +
> SendKeys `^v`), a machine-global singleton the `SapDevGuiPaste_v1` mutex only
> serialises across runs that go **through this skill**. A file-based upload
> (SAP dialog `ctxtDY_FILENAME`, as `/sap-se24` update uses) was considered to
> remove that shared-clipboard dependency, but it is **not** a drop-in for SE38:
> the front-end `AbapEditor.1` control's *Utilities → Upload* opens a **native
> Windows file-picker** (not scriptable — see the comment in
> `sap_se38_create.vbs` step 6), unlike SE24's source-view which yields a
> scriptable SAP dialog; and `/sap-se37` found the Upload menu **absent on
> NW 7.31 / ECC6** (the 2026-06-22 EC2 blocker) — the exact release family where
> this false-success occurred. So a clipboard-free SE38 path needs live
> verification on a real SE38 editor (S/4 **and** ECC6) before it can be trusted,
> and is deferred. **This does not leave a correctness hole:** the content
> verify (Step 7.6) makes a failed paste fail LOUD (`CONTENT_VERIFY: MISMATCH`),
> so a clipboard-free upload is a *prevention* optimisation, not the fix.

---

## Step 5b — Create New Program

If this is a new program, you need Program Type and Program Title in addition to
the source file. Ask the user if not already provided:
> "This is a new program. Please provide the program type and title."

Program type codes: `1`=Executable, `I`=Include, `M`=Module Pool, `F`=Function Group, `K`=Class, `S`=Subroutine Pool.

The create VBScript template is at `./references/sap_se38_create.vbs`.

**Title encoding (mandatory).** Write the program title to
`{RUN_TEMP}\se38_title.txt` as **UTF-8 (no BOM)** using the Write tool — never
embed a ZH/JA/non-ASCII title as a PowerShell literal in the generator below.
PowerShell 5.1 reads a BOM-less `.ps1` as the system ANSI codepage (cp932 on a
JP box) and mojibakes the title before it reaches the VBS (this corrupted the
ZH title on the 2026-06-07 `ZMMRMAT057R01` build). The generator reads the title
back via `[IO.File]::ReadAllText(...,UTF8)`, so the `.ps1` itself stays ASCII.

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se38_create_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se38_create.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%PROGRAM_NAME%%','THE_PROGRAM_NAME'
$content = $content -replace '%%PROGRAM_TYPE%%','THE_PROGRAM_TYPE'
# Title: read from a UTF-8 (no-BOM) file so a non-ASCII title is NEVER a PS literal
# (a BOM-less .ps1 is read as the system ANSI codepage by PS 5.1 -> cp932 mojibake;
# the *57 ZMMRMAT057R01 title bug, 2026-06-07). Literal .Replace; double any " for
# the VBS string literal.
$title   = if (Test-Path '{RUN_TEMP}\se38_title.txt') { ([System.IO.File]::ReadAllText('{RUN_TEMP}\se38_title.txt', [System.Text.Encoding]::UTF8)).Trim() } else { '' }
$content = $content.Replace('%%PROGRAM_TITLE%%', $title.Replace('"','""'))
$content = $content -replace '%%ABAP_SOURCE_FILE%%','THE_SOURCE_PATH'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
$content = $content -replace '%%FOREGROUND_GUARD_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_foreground_guard.ps1'
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
# Locale-aware syntax-check classifier (Ctrl+F2 grid MSGTYPE match for ZH/JA/DE logons).
$content = $content -replace '%%SYNTAX_CHECK_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_syntax_check_lib.vbs'
# Post-activate RFC verify: reuse the generic SE11 VBS invoker; SE38-specific PS1
# queries PROGDIR.STATE. Closes the 2026-05-27 screen-101 false-success path.
$content = $content -replace '%%POST_ACTIVATE_VERIFY_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_se11_post_activate_verify.vbs'
$content = $content -replace '%%POST_ACTIVATE_VERIFY_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_se38_post_activate_verify.ps1'
# Post-activate CONTENT verify (2026-07-02): reads the active source back via RPY_PROGRAM_READ
# and compares it to the deployed file. Closes the EC2 clipboard-paste false-success where a
# silently-failed paste leaves the OLD source active and PROGDIR/F8 still pass.
$content = $content -replace '%%CONTENT_VERIFY_VBS%%','<SKILL_DIR>\references\sap_se38_content_verify.vbs'
$content = $content -replace '%%CONTENT_VERIFY_PS1%%','<SKILL_DIR>\references\sap_se38_content_verify.ps1'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se38_create_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`. `THE_PACKAGE` and `THE_TRANSPORT` follow the same rules as Step 5a.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se38_create_run.ps1"
```

### Execute

```bash
# SE38 stages ABAP source on the Windows clipboard + SendKeys ^v behind an OS
# foreground guard -- both machine-global singletons that a per-run folder cannot
# isolate. Serialize the paste across concurrent runs with a global named mutex.
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_run_with_lock.ps1" -MutexName SapDevGuiPaste_v1 -TimeoutMs 180000 -Command "cscript //NoLogo {RUN_TEMP}\sap_se38_create_run.vbs"
```

Proceed to Step 6 to evaluate the result.

---

## Step 5c — Update Text Elements (Report Programs Only)

Reached only after **successful activation** (Step 5a or 5b printed `SUCCESS:`
with exit code 0). If activation failed — including on a syntax-error retry
path where the first attempt aborted — Step 5c never runs on that attempt;
it only runs on the attempt that actually activates the program. This is by
design (you can't update text elements on an inactive program), and it is
**not** the case that the recovery flow "forgets" Step 5c — when the
recovery attempt succeeds, control returns here.

### Run-or-skip decision

Evaluate the conditions below in order. The decision is binary: **RUN** or
**SKIP-WITH-NOTE**. There is no implicit "silently skip" — if a text
source is missing but the program structure says texts are expected,
the operator MUST log the explicit skip reason so it is visible in Step 6.

| Condition | Decision |
|---|---|
| Program type ≠ `1` (Include, Module Pool, Subroutine Pool, Class, FuGr) | **SKIP** — text elements do not apply. No note required. |
| Program type = `1` AND a text source resolves (Source 1 sibling, OR Source 2 inline-comment / design-doc extraction) | **RUN** with the resolved source. |
| Program type = `1` AND source contains `PARAMETERS` / `SELECT-OPTIONS` / `TEXT-NNN` AND NO text source resolves | **SKIP-WITH-NOTE** — the program declares text-bearing constructs but no usable text data is available. Emit a clear note in Step 6's report (e.g. `WARN: Step 5c skipped — program declares PARAMETERS/TEXT-NNN but no .text_elements.txt sibling, no inline comments, and no design-doc context.`). |
| Program type = `1` AND source has NO `PARAMETERS`, NO `SELECT-OPTIONS`, NO `TEXT-NNN`, NO sibling | **SKIP** — nothing to set. No note required. |

The **SKIP-WITH-NOTE** row is the case that silently bit the
`ZMMRMAT037R02` deploy on 2026-05-25: source had `PARAMETERS` + `TEXT-s01`
but no sibling text file, so the operator must either supply a text
source (preferred — ask the user, look for design doc, scrape inline
comments) or emit the explicit WARN note. A silent skip is a bug.

### Source-resolution order (used to populate the "text source resolves" check above)

1. **Source 1 (preferred)** — `{source_dir}\<PROGRAM_NAME>.text_elements.txt` sibling file emitted by `/sap-gen-abap` (per `abap_code_quality_rules.md` §21).
2. **Source 2 (fallback)** — extract `PARAM=text` pairs from inline `*"` comments adjacent to each `PARAMETERS:` / `SELECT-OPTIONS:` line, or from the design-doc workbook referenced in the file header.
3. **Source 3 (last resort)** — ASK the user for a pipe-delimited list (`P_BUKRS=Company|P_WERKS=Plant|…`).

If none of 1–3 resolves, the **SKIP-WITH-NOTE** decision applies.

### Source 1 (preferred) — read `<PROGRAM_NAME>.text_elements.txt`

`/sap-gen-abap` emits this sibling file alongside the `.abap` source per
`abap_code_quality_rules.md` §21. Format (tab-separated, two blocks):

```
[SELECTION_TEXTS]
P_BUKRS	Company Code
P_WERKS	Plant
P_MATNR	Material
P_FILE	Input file path

[TEXT_SYMBOLS]
001	Selection
002	Result Output
T01	Seq
T02	Type
```

When converting to the VBS tokens:

- `[SELECTION_TEXTS]` → `%%SELECTION_TEXTS%%`: each line `<PARAM>\t<text>`
  becomes `PARAM=text`, joined with `|`.
- `[TEXT_SYMBOLS]` → `%%TEXT_SYMBOLS%%`: each line `<NNN>\t<text>` becomes
  `NNN=text`, joined with `|`. Symbol IDs may be all-digit or mixed
  (`T01`, `S01`); SAP T100A is CHAR3.

When the sibling file exists, USE IT as the canonical source — do NOT
extract from inline comments. The sibling file already covers both
Selection Texts and Text Symbols; the VBS now applies both in one save.

### Source 2 (fallback) — extract Selection Texts from the ABAP source

Used only when no `.text_elements.txt` sibling exists. Walk the ABAP
source for every `PARAMETERS:` / `SELECT-OPTIONS:` line, build the
`PARAM=text` pairs from inline comments or the design doc. Set
`%%TEXT_SYMBOLS%%` to empty in this case.

### Collect Selection Texts (legacy path — used only by Source 2)

Extract selection text definitions from the ABAP source or design document:
- Each PARAMETERS/SELECT-OPTIONS field can have a descriptive text
- Format: `PARAM_NAME=Selection Text` separated by `|`
- Example: `P_BUKRS=Company Code|P_WERKS=Plant|P_MATNR=Material|P_FILE=Input file path`

**Parameter name rules:**
- Use the ABAP parameter name as declared (e.g., `P_BUKRS`, `S_MATNR`)
- UPPERCASE
- For SELECT-OPTIONS, the param name in the text table shows without the `S_` being changed

The text element VBScript template is at `./references/sap_se38_text_elements.vbs`.

### Generate the filled-in VBScript

Write the selection texts to a separate UTF-8 file first (avoids encoding issues when the
PowerShell script itself contains multibyte characters like Japanese):

Write `{RUN_TEMP}\sap_se38_textelm_seltexts.txt` with just the pipe-delimited selection texts:
```
PARAM1=Text1|PARAM2=Text2
```

If the source `.text_elements.txt` had a `[TEXT_SYMBOLS]` block, also write
`{RUN_TEMP}\sap_se38_textelm_symbols.txt` with the pipe-delimited symbols:
```
001=Selection|002=Result Output|T01=Seq
```

The symbols file is OPTIONAL — when absent, the VBS still applies Selection
Texts as before. Both files use UTF-8 (no BOM).

Write `{RUN_TEMP}\sap_se38_textelm_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se38_text_elements.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%PROGRAM_NAME%%','THE_PROGRAM_NAME')
$selTexts = [System.IO.File]::ReadAllText('{RUN_TEMP}\sap_se38_textelm_seltexts.txt', [System.Text.Encoding]::UTF8).Trim()
$content = $content.Replace('%%SELECTION_TEXTS%%', $selTexts)
$txtSyms = ''
if (Test-Path '{RUN_TEMP}\sap_se38_textelm_symbols.txt') {
    $txtSyms = [System.IO.File]::ReadAllText('{RUN_TEMP}\sap_se38_textelm_symbols.txt', [System.Text.Encoding]::UTF8).Trim()
}
$content = $content.Replace('%%TEXT_SYMBOLS%%', $txtSyms)
$content = $content.Replace('%%PACKAGE%%','THE_PACKAGE')
$content = $content.Replace('%%TRANSPORT%%','THE_TRANSPORT')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se38_textelm_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_PROGRAM_NAME` (UPPERCASE), `THE_PACKAGE`, `THE_TRANSPORT`, and `<SKILL_DIR>`.

**Important:**
- Use `.Replace()` method (not `-replace` operator) because `|` is a regex metacharacter.
- The selection texts **must** be in a separate text file (written by the Write tool as UTF-8).
  Embedding multibyte characters directly in the `.ps1` script causes encoding corruption.
- Use `[System.IO.File]::ReadAllText/WriteAllText` with explicit encoding — `Get-Content -Raw`
  + `Set-Content -Encoding Unicode` double-encodes the file.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se38_textelm_run.ps1"
```

### Execute

```bash
cscript //NoLogo {RUN_TEMP}\sap_se38_textelm_run.vbs
```

**On success** (output contains `SUCCESS:`): proceed to Step 5c.1. The VBS template now handles
activation internally — after saving, it re-enters Change mode (with SAPLSETX original-language
and KO008 Workbench-request popup handling), navigates to the Selection Texts tab, and presses
Activate (Ctrl+F3), including SAPLSPO1 worklist handling.
**On failure** (output contains `ERROR:`): proceed to Step 5c.1 to parse the failure mode; do not
silently swallow.

### Step 5c.1 — Parse & record TEXT_ELEMENTS status (MANDATORY)

After cscript exits, scan the output for a line matching `^TEXT_ELEMENTS:`.
This line is **mandatory** — its presence proves Step 5c VBS reached a
clean exit point, regardless of success/failure. Silently dropping a
missing/failed status is a contract violation (see `abap-developer.md`
Boundaries table entry on this).

| Line pattern | Status | Action |
|---|---|---|
| `TEXT_ELEMENTS: APPLIED selection_texts=N/M symbols=A/B` | OK | Continue to Step 6. Record counts in transcript via `sap_log_helper.ps1 -Action step -Step text_elements -Message "APPLIED N/M sym=A/B"`. |
| `TEXT_ELEMENTS: FAILED:<reason>` | FAIL | Emit a Step 6 WARN line: `Step 5c FAILED:<reason>` and SUGGEST the INITIALIZATION-injection fallback (see "Alternative" block above). Do NOT mark the overall deploy as FAILED — the source code is active. But the failure MUST appear in the Step 6 report (top-level, not in a footnote), so the caller (and `abap-developer` agent) can surface it. |
| (line absent) | UNKNOWN | Treat as `FAILED:NO_STATUS_EMITTED` — VBS crashed mid-flight before reaching the final emit. Same Step 6 WARN flow as above. |

Logging:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action step -StateFile "{RUN_TEMP}\sap_se38_run.json" -Step "text_elements" -Message "<APPLIED N/M sym=A/B | FAILED:reason | UNKNOWN>"
```

**Known FAILED reasons (emit-side contract — sap_se38_text_elements.vbs):**

| `FAILED:<reason>` | Cause | Remediation |
|---|---|---|
| `CHANGE_DID_NOT_OPEN_EDITOR` | btnCHAP from SE38 initial screen did not transition to text-elements editor. Usually because TR/orig-lang popup was unhandled, or logon language differs from MASTERLANG and SAPLSETX intercepted in an unrecognised form. | Check logon lang vs `TADIR-MASTERLANG`; manually try the operation in SE38; if it works manually, re-record `/sap-gui-probe --record` to capture the new popup variant. Fallback: apply INITIALIZATION-injection. |
| `REENTRY_DID_NOT_OPEN_EDITOR` | After Save, the re-entry to Change mode (for the Activate step) failed the same screen-state check. | Same as above. The TEXTPOOL was saved but is still inactive — open SE38 manually, navigate to Goto -> Text Elements, and press Activate (Ctrl+F3). |
| `TABLE_BASE_UNKNOWN` | None of the candidate sub-screen paths (SAPLSETXP:1310 / 1320 / 1300) resolved. The SAP release uses a different sub-screen number for the selection-text table. | Run `/sap-gui-probe --record` on SE38 -> Text Elements -> Selection Texts to capture the actual `ssubSCREEN_HEADER:SAPLSETXP:NNNN/tblSAPLSETXPSELPAR` path, then add it to the `selBaseCands` array in `sap_se38_text_elements.vbs`. |
| `TR_REQUIRED_BUT_EMPTY` | SAP prompted for a Workbench request (`ctxtKO008-TRKORR`) but `%%TRANSPORT%%` was empty. | Resolve a modifiable TR via `/sap-transport-request` and re-run Step 5c. The text elements need their own TR entry (separate from the source code's entry). |
| `SYMBOL_TAB_UNKNOWN` | Text symbols were supplied but none of the candidate Text Symbols tab ids resolved on this SAP build (pre-fix this was a WARN and the run still ended `APPLIED` with zero symbols written). | Run `/sap-gui-probe --record` on SE38 Text Elements -> Text Symbols; add the tab id to `symTabCands` in `sap_se38_text_elements.vbs`. |
| `SYMBOL_TABLE_BASE_UNKNOWN` | Text Symbols tab opened but none of the candidate table paths resolved (same pre-fix false-success as above). | Same recording flow; add the table path to `symBaseCands` in `sap_se38_text_elements.vbs`. |
| `SAVE_SBAR_E` / `SAVE_SBAR_A` | Save ended with status-bar MessageType `E`/`A` -- the TEXTPOOL was NOT written (pre-fix there was no sbar gate anywhere in this VBS). | Read the `ERROR: Save failed - <sbar text>` line above the status; fix the cause (lock, auth, TR) and re-run Step 5c. |
| `ACTIVATE_SBAR_E` / `ACTIVATE_SBAR_A` | Activation (Ctrl+F3) ended with status-bar `E`/`A` -- TEXTPOOL saved but NOT activated. | Open SE38 -> Goto -> Text Elements and activate manually, or re-run Step 5c after fixing the reported error. |
| `NO_STATUS_EMITTED` | VBS crashed before reaching the final `TEXT_ELEMENTS:` emit. | Inspect full cscript output for `ERROR:` lines; the trace before the crash names the operation. Common causes: SAP GUI Security dialog blocked the script, session was killed, COM exception in attach lib. |

### Text Elements Activation (Handled by VBS Template)

Text elements are a **separate object** from the source code. After saving selection texts
via the VBS template, they exist as an **inactive version**. Without activation, the SAP
runtime shows an "Inactive objects exist" dialog every time the program is executed via F8.

**The VBS template now handles activation automatically** by:
1. Saving the text elements (Ctrl+S)
2. Re-navigating to SE38 > Text Elements > Change > Selection Texts tab
3. Pressing Activate (Ctrl+F3 = `tbar[1]/btn[27]`)
4. Handling SAPLSPO1 activation worklist (Select All F9 + Enter)

This resolves the issue where text elements remained "Inactive" after save because the
screen reverted to Display mode and the Activate button was disabled.

**Why separate activation is needed:**
- The VBS template saves text elements (Step 5c) but does NOT activate them
- Source code activation (Step 5a/5b) does NOT activate text elements
- Text elements must be activated via the text elements editor's own Activate button

**VBS activation sequence:**
```vbs
' Navigate to SE38 > Text Elements > Change > Selection Texts tab
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE38"
oSession.findById("wnd[0]").sendVKey 0
oSession.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").Text = "PROGRAM_NAME"
oSession.findById("wnd[0]/usr/radRS38M-FUNC_TEXT").select
oSession.findById("wnd[0]/usr/btnCHAP").press
WScript.Sleep 2000
oSession.findById("wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpSSSS").select
WScript.Sleep 1000

' Press Activate (Ctrl+F3) = tbar[1]/btn[27]
oSession.findById("wnd[0]/tbar[1]/btn[27]").press
WScript.Sleep 4000

' Handle activation worklist (appears as wnd[1] with ALV grid)
' Must Select All (F9) then Continue (Enter)
Dim oW1
Set oW1 = oSession.findById("wnd[1]")
If Not oW1 Is Nothing Then
    oW1.sendVKey 9      ' F9 = Select All
    WScript.Sleep 500
    oW1.sendVKey 0      ' Enter = Continue/Activate
    WScript.Sleep 5000
End If
' Handle any post-activation dialog
Set oW1 = oSession.findById("wnd[1]")
If Not oW1 Is Nothing Then oW1.sendVKey 0
```

**Worklist buttons (wnd[1]):**
| Button | VKey | Action |
|---|---|---|
| `tbar[0]/btn[0]` | Enter (0) | Continue — activate selected objects |
| `tbar[0]/btn[9]` | F9 (9) | Select All — check all objects in the list |
| `tbar[0]/btn[12]` | F12 (12) | Cancel |

**ALV grid path:** `wnd[1]/usr/cntlGRID1/shellcont/shell`
(Note: grid RowCount/ColumnCount may appear empty via cscript — use sendVKey instead of grid API)

**Status bar after successful activation:** `Active object generated`
(May be empty due to AbapEditor status bar swallowing — see Known Limitations)

**Alternative: `%_xxx_%_app_%-text` in INITIALIZATION (no activation needed)**

If text element activation proves problematic, selection texts can be set via code:
```abap
INITIALIZATION.
  %_p_bukrs_%_app_%-text = 'Company Code'.
  %_rb_up_%_app_%-text   = 'Upload'.
```
These dynpro text variables (`%_<param>_%_app_%-text`) override selection texts at runtime.
Frame titles use `FRAME TITLE gv_xxx` + `gv_xxx = '...'` in INITIALIZATION (auto-declared).

### Text Elements Table Structure

The SE38 text elements screen uses tab control `tabsTX_TABSTR_CONTROL`:
- **Text Symbols tab** (`tabpSSST`) — `TEXT-001`, `TEXT-002`, etc.
- **Selection Texts tab** (`tabpSSSS`) — selection screen parameter texts

Selection texts table (`tblSAPLSETXPSELPAR`) columns:
| Column | ID pattern | Description |
|---|---|---|
| Parameter name | `txtRS38M-STEXTI[0,row]` | Read-only, shows ABAP param name |
| Selection text | `txtRS38M-STEXTT[1,row]` | Editable text field |
| Dict. reference | `chkRS38M-STEXTA[2,row]` | Checkbox for data element text |

**Note:** Row indices are 0-based and relative to the visible viewport. If there are
more parameters than visible rows, the template scrolls using `VerticalScrollbar.Position`.

---

## Step 5d — Change Program Attributes (Title / Status / Type)

**When to run:** The user wants to modify a program's header attributes
(Title, Status, Type, …) **without** uploading source. Examples:

- "Change the title of `ZHKTEST003` to '…'"
- "Set status of `ZMYREPORT` to K (Customer Production)"
- "Change `ZMYREPORT` type to Module Pool"

The change-attributes VBScript template is at `./references/sap_se38_change_attrs.vbs`.

**How it persists (fixed 2026-06-07):** the VBS opens the program in the SOURCE
editor (`FUNC_EDIT` + Change), edits attributes via **Goto -> Attributes**
(`wnd[0]/mbar/menu[2]/menu[0]`), Continues back to the editor, then **Saves
(`sendVKey 11`) and Activates (`sendVKey 27`)**. The older "Attributes radio
(`FUNC_HEAD`) + Change -> dialog -> Continue" path was a false success — its
Continue returns to the SE38 *initial* screen where Save is disabled, so the
change was staged but never written (confirmed on S/4HANA 1909 for both ZH and
ASCII titles). The Goto-menu index is positional and language-neutral; re-record
via `/sap-gui-probe --record` if a release moves it.

### Collect Inputs

| Token | Description | Allowed values | Empty? |
|---|---|---|---|
| `%%PROGRAM_NAME%%` | Program (UPPERCASE) | `ZMYREPORT` | required |
| `%%TITLE%%` | New title (max 70 chars) | any text | empty = leave unchanged |
| `%%STATUS%%` | `TRDIR-RSTAT` code | `P`=SAP Standard, `K`=Customer Production, `S`=System, `T`=Test, `X`=SAP Example | empty = leave unchanged |
| `%%TYPE%%` | `TRDIR-SUBC` code | `1`=Executable, `I`=Include, `M`=Module Pool, `F`=Function Group, `K`=Class, `S`=Subroutine Pool, `J`=Interface Pool | empty = leave unchanged |
| `%%TRANSPORT%%` | TR for the post-save popup | TR number | empty when local (`$TMP`) or already locked to a modifiable TR |

If `Package` (look up in `TADIR-DEVCLASS`) is transportable (does not start
with `$`), resolve a TR via Step 1b before generating the VBS. Pass the
returned TRKORR as `%%TRANSPORT%%`. If the object is local or already
locked to an open TR, `%%TRANSPORT%%` may be empty — the VBS will only
abort if SAP actually prompts.

If only the program name is supplied and all three of `TITLE`, `STATUS`,
`TYPE` are empty, ask the user which attribute to change. Do not run the
VBS with no values (it will exit `DONE: NO_CHANGE`).

### Generate the filled-in VBScript

**Title encoding (mandatory when changing the title).** Write the new title to
`{RUN_TEMP}\se38_title.txt` as **UTF-8 (no BOM)** via the Write tool — never
embed a non-ASCII title as a PowerShell literal (a BOM-less `.ps1` is read as the
system ANSI codepage by PS 5.1 → cp932 mojibake). The generator reads it back via
`[IO.File]::ReadAllText(...,UTF8)`. Leave the file absent (or empty) to leave the
title unchanged.

Write `{RUN_TEMP}\sap_se38_change_attrs_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se38_change_attrs.vbs"
$content  = [System.IO.File]::ReadAllText($tpl, [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%PROGRAM_NAME%%','THE_PROGRAM_NAME')
# Title: read from a UTF-8 (no-BOM) file (never a PS literal -> BOM-less .ps1 is read as
# the system ANSI codepage by PS 5.1 -> cp932 mojibake of ZH/JA titles). Absent/empty
# file -> empty token (= leave the title unchanged). Double any " for the VBS literal.
$title    = if (Test-Path '{RUN_TEMP}\se38_title.txt') { ([System.IO.File]::ReadAllText('{RUN_TEMP}\se38_title.txt', [System.Text.Encoding]::UTF8)).Trim() } else { '' }
$content  = $content.Replace('%%TITLE%%', $title.Replace('"','""'))
$content  = $content.Replace('%%STATUS%%',      'THE_STATUS')
$content  = $content.Replace('%%TYPE%%',        'THE_TYPE')
$content  = $content.Replace('%%TRANSPORT%%',   'THE_TRANSPORT')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se38_change_attrs_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Use `.Replace()` (literal) — title/status texts may contain regex
metacharacters. Replace `<SKILL_DIR>` and the `THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se38_change_attrs_run.ps1"
```

### Execute

```bash
cscript //NoLogo {RUN_TEMP}\sap_se38_change_attrs_run.vbs
```

### Behaviour Notes

- The Attributes screen is opened by selecting the **Attributes** radio
  (`radRS38M-FUNC_HEAD`) on the SE38 initial screen, then pressing
  **Change** (`btnCHAP`). This opens a modal dialog (`wnd[1]`) with the
  attribute fields.
- **Original-language popup is conditional.** SAPLSETX
  ("Different original and logon languages", fingerprint
  `wnd[1]/usr/ctxtRSETX-MASTERLANG`) only appears when the logon language
  differs from the program's `TADIR-MASTERLANG`. The VBS detects it by
  fingerprint and presses `wnd[1]/usr/btnPUSH1`
  ("Maint. in orig. lang.") so `MASTERLANG` is preserved. If logon
  language matches `MASTERLANG`, this popup is silently skipped.
- **Field IDs in the Attributes dialog (wnd[1]):**
  | Field | ID |
  |---|---|
  | Title | `wnd[1]/usr/txtRS38M-REPTI` |
  | Status | `wnd[1]/usr/cmbTRDIR-RSTAT` (set via `.Key`) |
  | Type | `wnd[1]/usr/cmbTRDIR-SUBC` (set via `.Key`) |
  | Save | `wnd[1]/tbar[0]/btn[0]` |
  | Cancel | `wnd[1]` `sendVKey 12` |
- **Post-save TR popup.** After Save, SAP may prompt for a Workbench
  request via `wnd[1]/usr/ctxtKO008-TRKORR`. The VBS fills it with
  `%%TRANSPORT%%` and presses Enter. If the popup appears but
  `%%TRANSPORT%%` is empty, the VBS aborts with `ERROR: SAP prompted for
  a transport request but TRANSPORT is empty` — resolve a TR via
  `/sap-transport-request` and re-run.
- **Lock-error popup.** If the object is locked by another modifiable
  task, SAP shows an Error popup (`txtMESSTXT1`/`txtMESSTXT2` containing
  `locked`). The VBS detects this and exits 1 with
  `ERROR: SAP popup [Error] …`.
- **No-change path.** If all of TITLE / STATUS / TYPE are empty, the VBS
  cancels the dialog and exits 0 with `DONE: NO_CHANGE`.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Attributes updated for <PGM>.` | Save succeeded. Status bar message also echoed. |
| `DONE: NO_CHANGE` | No values supplied; dialog cancelled. |
| `ERROR: …` | Dialog couldn't open, invalid status/type code, lock error, or missing TR. Show full output. |

After success, proceed to Step 7 (cleanup). Skip Step 6 — no source-code
status table applies.

---

## Step 5e — Delete Program

**When to run:** The user wants to delete a program. Examples:

- "Delete program `ZHKCM008R01`"
- "Drop report `ZMYREPORT`"
- "Remove pgm `Z_OBSOLETE`"

**Deletion is irreversible.** Before generating the VBS, confirm with the
user explicitly: state the program name, look up `TADIR-DEVCLASS` for
the locality (transportable vs `$TMP`), and ask "Are you sure you want
to delete this program? (yes/no)". Do not proceed without an explicit
yes.

The delete VBScript template is at `./references/sap_se38_delete.vbs`.

### Preconditions

- The program must already exist (run Step 4 check first; if `NOT_EXIST`,
  tell the user and stop — nothing to delete).
- If the program is in a transportable package, resolve a TR via Step 1b
  and pass it as `%%TRANSPORT%%`. SAP's post-delete TR popup needs it.
  If the program is local (`$TMP`) or already locked to a modifiable TR,
  leave it empty — the VBS only aborts if SAP actually prompts.

### Collect Inputs

| Token | Description | Empty? |
|---|---|---|
| `%%PROGRAM_NAME%%` | Program name (UPPERCASE) | required |
| `%%TRANSPORT%%` | TR for the post-delete prompt | empty when local or already locked |
| `%%SESSION_LOCK_VBS%%` | path to `sap_session_lock.vbs` | required |

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se38_delete_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se38_delete.vbs"
$content  = [System.IO.File]::ReadAllText($tpl, [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%PROGRAM_NAME%%',    'THE_PROGRAM_NAME')
$content  = $content.Replace('%%TRANSPORT%%',       'THE_TRANSPORT')
# Optional ECC6 "Create Object Directory Entry" orphan-fill (default '' =>
# accept pre-filled package / Local Object; /sap-dev-clean passes sap_dev_package).
# THE_OBJDIR_LANG default '' => the VBS uses 'E'.
$content  = $content.Replace('%%PACKAGE%%',         'THE_OBJDIR_PACKAGE')
$content  = $content.Replace('%%ORIG_LANG%%',       'THE_OBJDIR_LANG')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se38_delete_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `<SKILL_DIR>` and the `THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se38_delete_run.ps1"
```

### Execute

```bash
cscript //NoLogo {RUN_TEMP}\sap_se38_delete_run.vbs
```

### Behaviour Notes

- **Delete is invoked from the SE38 initial screen.** The script does
  NOT open the program editor first; it fills the program-name field
  (`ctxtRS38M-PROGRAMM`) and sends Shift+F2 (`sendVKey 14`) directly.
- **Generic popup walker.** After Delete, the VBS loops on
  `oSession.ActiveWindow` (up to 8 iterations) and dispatches each
  modal by component ID — handles any combination of confirmation
  popups, dependent-object lists, and post-delete TR prompts in any
  order. For each popup it tries (in order):
  1. `<wnd>/usr/ctxtKO008-TRKORR` — fill `%%TRANSPORT%%` + Enter.
     If `%%TRANSPORT%%` is empty, abort with
     `ERROR: SAP prompted for a transport request but TRANSPORT is empty`.
  2. `<wnd>/usr/btnSPOP-OPTION1` (Yes) — for Yes/No SPOPs.
  3. `<wnd>/tbar[0]/btn[0]` (Continue) — for SAP info-style popups
     with a Continue button on the popup's own toolbar (this is what
     function-group deletion uses; the recording shows
     `wnd[1]/tbar[0]/btn[0]` then `wnd[2]/tbar[0]/btn[0]`).
  4. `sendVKey 0` (Enter) on the active window — last resort.
- **Function-group main programs.** The program name `SAPL<FUGR>` is
  the function group's main include — deleting it removes the entire
  function group (all FMs, screens, GUI statuses, etc.). The recording
  for this case shows two stacked popups (`wnd[1]` listing dependents
  while `wnd[2]` asks for confirmation); the popup walker handles both
  via `tbar[0]/btn[0]`. See `/sap-function-group` Step 3e for the FG-delete
  entry point that calls this skill with `SAPL<FUGR>`.
- **Verification.** After deletion the script re-fills the program
  name and presses Display (`btnSHOP`). If the editor opens (the
  program-name field on the initial screen disappears), the program
  still exists and the VBS reports `ERROR: Program still exists after
  delete`.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Program <NAME> deleted.` | Program is gone — sbar status echoed above. |
| `ERROR: …` | Deletion did not complete — see full output. Common causes: program locked by another user (SM12), supplied TR is released, dependent objects refused deletion, or the operator aborted by pressing No. |

### Post-delete RFC verification (recommended)

Query `TRDIR` via `/sap-se16n` filtered by `NAME = <PGM>`; expect zero
rows. Also check `TADIR` (`OBJECT = 'PROG' AND OBJ_NAME = <PGM>`); a
row left there with no TRDIR entry indicates a half-deletion and the
object directory needs manual cleanup via SE03.

After success, proceed to Step 7 (cleanup). Skip Step 6 — no
create/update reporting applies.

---

## Step 6 — Report Result

The create / update VBS emits **four parseable lines** in addition to the
human-readable `INFO:` / `ERROR:` echoes. Callers should rely on these
lines, not on substring-grepping the per-finding text:

| Line | Meaning |
|---|---|
| `SYNTAX_ERRORS: <N>` | Count of real syntax errors found after Ctrl+F2 (excludes warnings). Always emitted. `0` = clean. |
| `CONTENT_VERIFY: <MATCH\|MISMATCH\|UNAVAILABLE\|SKIP>` | Result of the post-activate **content-integrity** gate: reads the active source back via RFC `RPY_PROGRAM_READ` and compares it line-for-line to the deployed file. `MATCH` = the deployed source is what's active. `MISMATCH` = the upload did NOT take (stale source stayed active — the clipboard-paste false-success) → VBS exits 1. `UNAVAILABLE` = RFC couldn't run the check (creds/endpoint/NCo/RFC-off) → report **SUCCESS_UNVERIFIED**, never plain SUCCESS. `SKIP` = helper not wired (offline test). |
| `SUCCESS: Program <NAME> created and activated in SAP.` (or `updated and activated`) | Final SUCCESS — emitted ONLY when the content verify did not fail AND post-activation verification reached an active SE38 screen (1000/120/200). Followed by `WScript.Quit 0`. |
| `ERROR: activation_uncertain — …` | The paste pipeline didn't error but verification didn't reach an active screen. Followed by `WScript.Quit 1`. The program is likely still INACTIVE — recovery: open SE38 manually + `/sap-activate-object`. |

**Important — never trust just the final SUCCESS line.** Earlier versions
of these scripts (pre-2026-05) printed `SUCCESS:` even when activation
verification emitted an "Unexpected screen" warning. The scripts now
fail-closed: anything other than a recognised-active verification screen
exits 1 with `ERROR: activation_uncertain`. Callers that pre-date this
fix should be updated to gate on the exit code, not on parsing the
SUCCESS line.

**Content-integrity gate (2026-07-02).** A clean `SUCCESS:` + exit 0 also
requires `CONTENT_VERIFY: MATCH` (or `SKIP`/`UNAVAILABLE`). This gate exists
because "activated" is not "deployed": on 2026-07-02 (EC2 / ECC6 7.31,
`ZMMRMAT0A1R01`) the GUI clipboard paste failed silently under parallel-session
contention, the editor kept the OLD source, and Ctrl+F2 / PROGDIR.STATE / F8 all
passed against it — SE38 reported `SUCCESS … Post-activate RFC verify: ACTIVE`
three times while the active source was UNCHANGED (recovered only via
`/sap-se38 delete` + recreate). The content verify reads the active source back
via RFC `RPY_PROGRAM_READ` and compares it to the deployed file, so a stale
paste now fails LOUD (`CONTENT_VERIFY: MISMATCH` → exit 1) instead of
false-succeeding. When the verify itself can't run (RFC off / no creds / NCo
missing) it emits `CONTENT_VERIFY: UNAVAILABLE` — report **SUCCESS_UNVERIFIED**,
never plain SUCCESS.

**On success** (output contains `SUCCESS:` AND exit code 0):
- Tell the user the program was deployed and activated.
- Show the full script output as a code block.
- Log the SUCCESS end record:
  ```bash
  powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se38_run.json" -Status SUCCESS -ExitCode 0 -MetricsJson '{"gate":"DEPLOY","verdict":"PASS","syntax_errors":0,"activated":true,"text_elements":"APPLIED"}'
  ```
  **Build-KPI enrichment (best-effort).** Populate `-MetricsJson` from this
  deploy: `syntax_errors` from the `SYNTAX_ERRORS:` marker, `activated` from the
  PROGDIR.STATE verify (`true` when active), and `text_elements` from the
  `TEXT_ELEMENTS:` marker (`APPLIED` / `FAILED` / `NA` for non-reports). The
  offline aggregator (`shared/rules/build_metrics.md`) fans the `DEPLOY` payload
  out into the SYNTAX, ACTIVATE, and TEXT build gates. Best-effort: omit if you
  cannot read the markers.

**On failure** (output contains `ERROR:` OR `SYNTAX_ERRORS:` > 0 OR exit code non-zero):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `SE38 program name field not found` | Component ID mismatch | Use SAP Scripting Recorder to find correct ID |
| `Could not open Upload menu` | Menu path differs by SAP version | Use Scripting Recorder to record correct menu path |
| `Upload dialog interaction failed` | Upload dialog IDs differ | Re-record the upload step |
| `Syntax check failed` / `SYNTAX_ERRORS: <N>` (N > 0) | ABAP syntax errors | Show error message, ask user to fix code |
| `Source file not found` | Wrong path or file not written | Verify path, re-run Step 2 |
| `Could not reach ABAP source editor` | Create dialogs failed | Check SAP status bar for details |
| `Could not open program in change mode` | Program locked or no auth | Check locks (SM12) or authorization |
| `Program is still INACTIVE` | Activation silently failed | Check SE38 manually; AbapEditor may have swallowed the error. Common causes: missing dictionary types, missing message class, syntax errors in local classes |
| `ERROR: activation_uncertain` | Post-activation verification did not reach an active SE38 screen (1000/120/200) | Open SE38 for the program manually, inspect the activation log, then run `/sap-activate-object PROGRAM <NAME>` |
| `CONTENT_VERIFY: MISMATCH` (+ `ERROR: … source does NOT match the file that was deployed`) | The program is ACTIVE but its active source ≠ the file you uploaded — the paste did not take (usually clipboard contention with another SAP GUI automation running concurrently; SE38 re-activated the OLD source). **Not a success.** | Re-run the deploy, serialising concurrent SE38 automation (the paste is guarded by the `SapDevGuiPaste_v1` mutex — ensure every concurrent driver holds it). If the paste keeps failing, `/sap-se38 delete` + recreate (the create-path paste often succeeds). ErrorClass=`SE38_CONTENT_MISMATCH`. |
| `CONTENT_VERIFY: UNAVAILABLE` | The content gate could not run (RFC off — e.g. EC6/ER1 — / no saved creds / NCo 3.1 32-bit missing). Deploy is NOT failed, but content is unverified. | Report **SUCCESS_UNVERIFIED**. To enable the gate: re-run `/sap-login` (save the RFC password) and confirm NCo 3.1 is in the 32-bit GAC. |
| `Status bar empty (AbapEditor swallows messages)` | Front-end editor limitation | This is expected behavior; activation is verified by test-executing the program |
| `TEXT_ELEMENTS: FAILED:CHANGE_DID_NOT_OPEN_EDITOR` | Step 5c: btnCHAP did not transition to text-elements editor (orig-lang or TR popup not handled by current VBS variants). Source is active; only text elements are missing. | See Step 5c.1 table. Fallback: INITIALIZATION-injection. ErrorClass=`SE38_TEXTELM_CHANGE_FAIL` |
| `TEXT_ELEMENTS: FAILED:REENTRY_DID_NOT_OPEN_EDITOR` | Step 5c: text elements were saved but re-entry to Change for Activate failed; TEXTPOOL is saved-but-inactive. | Open SE38 manually -> Goto -> Text Elements -> Activate (Ctrl+F3). ErrorClass=`SE38_TEXTELM_REENTRY_FAIL` |
| `TEXT_ELEMENTS: FAILED:TABLE_BASE_UNKNOWN` | Step 5c: sub-screen path SAPLSETXP:NNNN unknown on this SAP release. | Run `/sap-gui-probe --record` to capture the correct path; add to `selBaseCands` in `sap_se38_text_elements.vbs`. ErrorClass=`SE38_TEXTELM_TBL_UNKNOWN` |
| `TEXT_ELEMENTS: FAILED:TR_REQUIRED_BUT_EMPTY` | Step 5c: SAP prompted for TR but `%%TRANSPORT%%` was empty. | Resolve TR via `/sap-transport-request`; re-run Step 5c. ErrorClass=`SE38_TEXTELM_TR_MISSING` |
| `TEXT_ELEMENTS: FAILED:SYMBOL_TAB_UNKNOWN` / `FAILED:SYMBOL_TABLE_BASE_UNKNOWN` | Step 5c: Text Symbols tab / table ids unknown on this SAP build; symbols NOT applied (VBS exits 1 -- no longer a WARN + `APPLIED`). | Run `/sap-gui-probe --record`; add the id to `symTabCands` / `symBaseCands` in `sap_se38_text_elements.vbs`. ErrorClass=`SE38_TEXTELM_TBL_UNKNOWN` |
| `TEXT_ELEMENTS: FAILED:SAVE_SBAR_<E\|A>` | Step 5c: Save ended with sbar `E`/`A` -- TEXTPOOL not written. | See the `ERROR: Save failed -` line; fix cause (lock/auth/TR) and re-run Step 5c. ErrorClass=`SE38_TEXTELM_SAVE_FAIL` |
| `TEXT_ELEMENTS: FAILED:ACTIVATE_SBAR_<E\|A>` | Step 5c: activation ended with sbar `E`/`A` -- TEXTPOOL saved but inactive. | Activate manually via SE38 -> Goto -> Text Elements (Ctrl+F3) or re-run Step 5c. ErrorClass=`SE38_TEXTELM_ACTIVATE_FAIL` |
| `TEXT_ELEMENTS: line absent` | Step 5c VBS crashed before final emit. | Inspect cscript output for the last `INFO:` line; that's where it died. ErrorClass=`SE38_TEXTELM_NO_STATUS` |

Log the FAILED end record (pick `ErrorClass` from the matched row, e.g.
`SE38_SYNTAX`, `SE38_INACTIVE`, `SE38_CONTENT_MISMATCH`, `SE38_UPLOAD`,
`SE38_LOCKED`, `SE38_AUTH`, `SE38_GENERIC`, `SE38_TEXTELM_*`):
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se38_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<one-line message from script output>"
```

### Step 6b — Record FM/METHOD errors to frequently_errors (best-effort)

When the failure is a syntax/activation error **and** a source file was
deployed, feed the errors to the team frequently_errors store so the next
generation avoids them. The recorder attributes each error to the enclosing
`CALL FUNCTION '<FM>'` / class method **by source line number** (locale-
independent) and upserts a `CANDIDATE` row under
`{custom_url}\frequently_errors\<OBJECT>.tsv` — a TEAM-SHARED file, **not** a
MEMORY file. Errors it can't tie to a FM/method go to `_UNATTRIBUTED.tsv`.

This is best-effort and MUST NOT change the deploy verdict. **Skip** when
`userConfig.frequently_errors_enabled` or `frequently_errors_autorecord` is
`false`, or when no source file was deployed (fix-mode without source / delete
/ attribute-change).

1. Write the captured VBS stdout (the `[ERROR] Line N: <text>` lines you
   already see) verbatim to `{RUN_TEMP}\se38_output.txt`.
2. Run (CANDIDATE rows do not influence generation until `/sap-error-kb`
   promotes them):
   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_error_hints.ps1" -Action record -Source SE38 -CustomUrl "{custom_url}" -SourceFile "<DEPLOYED_ABAP_PATH>" -RawOutputFile "{RUN_TEMP}\se38_output.txt" -Program "<PROGRAM_NAME>"
   ```
   Parse `STATUS: RECORDED added=<n> updated=<n> skipped=<n>`; report it as
   an INFO note. A non-zero exit here is non-fatal — log and continue.

---

---

## Step A — Check Syntax and Download Source (Fix Mode)

Use this step when no source file was provided and the task is to check or fix an existing program.

The check-and-download VBScript template is at `./references/sap_se38_check_and_download.vbs`.

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se38_check_and_download_run.ps1`:
```powershell
$pgmName  = 'THE_PROGRAM_NAME'
$outFile  = 'THE_OUTPUT_FILE'
$skillDir = 'THE_SKILL_DIR'
$workTemp = 'THE_WORK_TEMP'    # base {WORK_TEMP} -- feeds Get-SapCurrentSessionPath only
$runTemp  = 'THE_RUN_TEMP'     # per-run scratch dir -- where the generated wrapper lands

$content = [System.IO.File]::ReadAllText("$skillDir\references\sap_se38_check_and_download.vbs", [System.Text.Encoding]::UTF8)
$content = $content -replace '%%PROGRAM_NAME%%', $pgmName
$content = $content -replace '%%OUTPUT_FILE%%',  $outFile
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%',   $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$content = $content -replace '%%SYNTAX_CHECK_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_syntax_check_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp $workTemp
[System.IO.File]::WriteAllText("$runTemp\sap_se38_check_and_download_run.vbs", $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

| Placeholder | Value |
|---|---|
| `THE_PROGRAM_NAME` | Program name (UPPERCASE) |
| `THE_OUTPUT_FILE` | `{RUN_TEMP}\<PROGRAM_NAME>_from_sap.txt` |
| `THE_SKILL_DIR` | Absolute path to this skill directory |
| `THE_WORK_TEMP` | `{WORK_TEMP}` resolved value (base — session-attach only) |
| `THE_RUN_TEMP` | `{RUN_TEMP}` resolved value (per-run scratch dir) |

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se38_check_and_download_run.ps1"
```

### Execute (with SAP GUI Security guard)

The check-and-download step makes SAP GUI write the program source to a local
file — **SAP-GUI-side file IO**, so it raises the modal **SAP GUI Security**
dialog when the output path isn't allow-listed (Default Action = Ask), and that
modal suspends the Scripting API, hanging the cscript. Per
`shared/rules/sap_gui_security_handling.md`, pre-check the rules and run the
OS-level watcher around the download. Run as one PowerShell block (the 32-bit
cscript is inside it). Substitute `THE_SID` / `THE_CLIENT` with the pinned
system / client:

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$out    = '{RUN_TEMP}\THE_PROGRAM_NAME_from_sap.txt'   # the path SAP GUI will write
# 1. Pre-check the allow-list (read-only; informational + lets us skip the watcher).
& "$shared\sap_gui_security_precheck.ps1" -Path $out -Access w -System 'THE_SID' -Client 'THE_CLIENT' -Transaction 'SE38' | Out-Host
$allowed = ($LASTEXITCODE -eq 0)
# 2. If not already allow-listed, launch the OS-level watcher BEFORE the
#    (blocking) download. It detects the #32770 dialog and clicks Remember+Allow,
#    which also persists a rule so subsequent runs pre-check ALLOWED.
$watcher = $null
if (-not $allowed) {
    $watcher = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','40')
    Start-Sleep -Milliseconds 800
}
# 3. Run the check + download (32-bit cscript). If the dialog appears it blocks
#    here until the watcher dismisses it; then the download completes.
& 'C:/Windows/SysWOW64/cscript.exe' //NoLogo '{RUN_TEMP}\sap_se38_check_and_download_run.vbs'
# 4. Reap the watcher.
if ($watcher) { $watcher | Wait-Process -Timeout 45 -ErrorAction SilentlyContinue }
```

**Parse the output:**

| Last output line | Meaning | Next step |
|---|---|---|
| `RESULT: SYNTAX_OK` | No syntax errors | Tell the user — skip to Step 7 |
| `RESULT: SYNTAX_ERRORS` | Errors found (shown above the RESULT line) | Proceed to Step B |
| `ERROR:` | Fatal failure | Show full output, stop |

---

## Step B — Analyze and Fix Source

The source was downloaded to `{RUN_TEMP}\<PROGRAM_NAME>_from_sap.txt` (UTF-16 LE).

> **CAVEAT — `_from_sap.txt` may differ structurally from the disk source.**
> The download uses `AbapEditor.GetLineText(i)` which reads what the editor
> *displays*, not what is stored. SAP applies pretty-printer formatting
> between storage and display. Verified divergence: TYPES declared inside
> a local class PUBLIC SECTION can appear at PROGRAM scope in the
> `_from_sap.txt` download (would break re-deploy if used as a basis).
>
> **Rule:** if a disk copy of the source exists (e.g. the original
> `<PROGRAM_NAME>.abap` from the spec/build pipeline), apply your fixes
> there instead and re-deploy. Use `_from_sap.txt` only as a *reference*
> for what the live system has — never as the deploy basis when a
> structurally-correct disk copy is available.
>
> A more robust download path via RFC `RPY_PROGRAM_READ` is on the
> roadmap; until then, prefer disk-copy editing.

**1. Read the file:**
```powershell
$srcFile = '{RUN_TEMP}\<PROGRAM_NAME>_from_sap.txt'
$bytes = [System.IO.File]::ReadAllBytes($srcFile)
$text  = [System.Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF)
Write-Host $text
```
Write this to a `.ps1` file and run it — do not pass inline to `powershell -Command` (quoting issues).

**2. Analyze each error:** Use the line numbers and `[T]` types from the Step A output to locate the bad code.

**3. Apply fixes and write fixed file:**
```powershell
$srcFile   = '{RUN_TEMP}\<PROGRAM_NAME>_from_sap.txt'
$fixedFile = '{RUN_TEMP}\<PROGRAM_NAME>_fixed.txt'
$bytes = [System.IO.File]::ReadAllBytes($srcFile)
$text  = [System.Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF)
# Apply fixes — example:
$text = $text -replace '(?i)bad_pattern', 'correct_replacement'
[System.IO.File]::WriteAllText($fixedFile, $text, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host "Fixed file written: $fixedFile"
```
Write this to a `.ps1` file and run it.

After all fixes are applied, proceed to Step C.

---

## Step C — Re-upload Fixed Source

Run the **Step 5a (Update)** flow with `{RUN_TEMP}\<PROGRAM_NAME>_fixed.txt` as `THE_SOURCE_PATH`.

The update VBS saves, activates, runs syntax check, and verifies activation via SA38 F8.

| Output | Action |
|---|---|
| `SUCCESS:` | Program is fixed and active — tell the user, proceed to Step 7 |
| `ERROR: Syntax errors found` | Errors remain — return to Step B and fix remaining errors |
| Other `ERROR:` | Diagnose using the Step 6 error table |

---

## Step 7 — Clean Up

If the log run hasn't already been ended (Step 6 success/failure path or
Step 1b TR-failure path), end it now as a safety net:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se38_run.json" -Status SUCCESS -ExitCode 0
```
(The helper deletes the state file on `end` and silently no-ops if the
file is already gone, so this is safe to call unconditionally.)

Delete this run's scratch directory — one shot removes every generated wrapper,
the log-state file, the pasted source, and any downloaded / fixed files:
```bash
cmd /c rmdir /s /q {RUN_TEMP}
```

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters
(e.g. Japanese program titles). UTF-8 with BOM causes a cscript compile error.

### ABAP Source File Encoding (mojibake Fix)

The VBS templates automatically handle ABAP source file encoding:
- Claude's Write tool saves `.abap` files in **UTF-8**
- The templates detect whether the SAP system is **Unicode** using `oSession.Info.Codepage`
  - **Unicode SAP** (codepage 4110/4103): Upload the UTF-8 file **directly** — no conversion needed
  - **Non-Unicode SAP**: Convert UTF-8 to the **Windows system ANSI codepage** (e.g. Shift-JIS on Japanese Windows) via `ADODB.Stream`, then upload the converted `.upload.txt` file
- The temp `.upload.txt` file (non-Unicode path only) is automatically cleaned up after deployment

---

## Troubleshooting Component IDs / Stuck Screen

**FIRST RESORT — invoke `/sap-gui-inspect screenshot full`.** Captures every
visible window as one annotated PNG via the SAP GUI Scripting `HardCopy` API,
plus a structural dump of the topmost window. Read the PNG with the Read tool
to see what's on screen, then act based on both the visual and the structural
dump.

**SECOND RESORT — `/sap-gui-inspect tree` (structural only).** Use this when
the screenshot fails (SAP GUI minimised, HardCopy blocked) or when you only
need a quick structural confirmation. When a VBS step fails with `The control
could not be found by id`, an unexpected popup appears, or the script hangs
because the screen flow diverged from what was expected, do NOT guess. Call
`/sap-gui-inspect` immediately to discover the actual component layout in the
current SAP GUI session, then fix the VBS or dismiss the popup based on the dump.

Recommended diagnostic sequence:

| Step | Mode | Filter | Purpose |
|---|---|---|---|
| 1 | `tree` | (none) | List every open window (`wnd[0]`, `wnd[1]`, …) and their titles — confirms whether an unexpected popup is open |
| 2 | `wnd` | `1` (or `2`) | Full component tree of the unexpected popup — shows its OK/Cancel buttons |
| 3 | `id` | `wnd[0]/sbar` | Status-bar message (type/id/number/text). NOTE: AbapEditor swallows status messages — fall back to the syntax-check grid (see Limitations) |
| 4 | `type` | `GuiButton` | List every button with text + tooltip when you don't know which to press |
| 5 | `id` | `wnd[0]/usr/cntlEDITOR/shellcont/shell` | Inspect AbapEditor `SubType`, `LineCount`, `FirstVisibleLine` |

After the dump, decide:
- Unexpected popup (e.g. "Inactive objects", "Save changes?") → press its dismiss button (`wnd[N]/tbar[0]/btn[0]` or `btn[12]`) and retry.
- Component ID changed between SAP releases → update the VBS template with the discovered ID.
- AbapEditor stuck silent → use the syntax-check error grid pattern documented below.

**Last resort (only if `/sap-gui-inspect` cannot help):**
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs

---

## Known Limitations: AbapEditor Status Bar Swallowing

The new front-end ABAP Editor (`cntlEDITOR/shellcont/shell`) **swallows ALL status bar
messages**. When the editor is active, `wnd[0]/sbar` always returns empty `.MessageType`
and `.Text`. This affects:

- **Save confirmation** — save may succeed but status bar appears empty
- **Activation result** — activation may silently fail with no error reported

### Syntax Check — Solved via Error Grid

Although the status bar is unreliable, **syntax check results ARE accessible** through the
error grid control at:

```
wnd[0]/shellcont/shell/shellcont[1]/shell
```

This is a GuiShell (ALV grid) with columns:
- `MSGTYPE` — error type (`1` or `E` = Error, `2` or `W` = Warning)
- `LINE` — source line number
- `TEXT` — error description

The VBS templates read errors using `getCellValue(row, column)` and `RowCount`. If the
grid has zero rows, syntax check passed. If any row has `MSGTYPE = "1"` (Error), deployment
is aborted with full error details.

Reference: SAP GUI Scripting API `doubleClickCurrentCell` can navigate to error lines.
Toolbar buttons on the grid: `WB_EDIT` (switch to edit mode), `WB_DISPLAY` (display mode).

### Impact

The VBS templates work around sbar swallowing by:
1. **Reading syntax errors from the grid control** (reliable — not affected by AbapEditor)
2. **Verifying activation** by navigating to SA38 and attempting to execute (F8)
   — if the selection screen (1000) appears, the program is confirmed active

### Workaround for Persistent Activation Failures

If activation keeps failing silently:
1. Open SE38 manually in SAP GUI
2. Enter the program name and press Check (Ctrl+F2) — the error grid shows details
3. Fix errors manually, then activate (Ctrl+F3)
4. If SAPLSPO1 screen 500 (activation worklist) appears, select all objects and press Enter

---

## Known Limitation: SAPLSPO1 Activation Worklist

When activating from the SE38 initial screen (Shift+F9 / btn[21]), SAP may navigate to
the SAPLSPO1 screen 500 (activation worklist). This screen lists inactive objects to activate.

**Problem:** All children in SAPLSPO1/500 have empty Id and Type, making it difficult to
interact with via SAP GUI Scripting.

**VBS template handling:** The templates detect SAPLSPO1 and press btn[0] (Continue/checkmark)
to confirm activation of all listed objects. If this fails, manual activation is needed.

**Activation worklist as wnd[1] dialog:** When the worklist appears as a dialog (wnd[1])
rather than a full screen — e.g., when activating text elements — it contains an ALV grid
and toolbar buttons:
- `tbar[0]/btn[9]` = Select All (F9) — must be pressed BEFORE Continue
- `tbar[0]/btn[0]` = Continue (Enter) — activates selected objects
- Use `oW1.sendVKey 9` then `oW1.sendVKey 0` (more reliable than button presses)
- The ALV grid's RowCount/ColumnCount may appear empty via cscript; use sendVKey instead

---

## Unit Test Execution

To run ABAP Unit Tests for the deployed program from SE38:

- **Menu path:** Program (menu[0]) > Execute (menu[9]) > Unit Tests (menu[2])
- **VBS:** `oSession.findById("wnd[0]/mbar/menu[0]/menu[9]/menu[2]").select`
- **Success indicator:** Status bar type `S`, message contains `Processed: N programs, N test classes, N test methods`

---

## Known Limitation: Reading Basic List Output via VBS

WRITE output displayed on the list screen (screen 120) produces 55+ `GuiLabel` children whose
`.Text` property returns **empty** when read via VBS (cscript). This means program output
cannot be reliably captured through SAP GUI Scripting.

**Workaround:** Always add `GUI_DOWNLOAD` in the ABAP code to export results to a local file
(e.g. `{RUN_TEMP}\<program>_result.txt`). Read the file after execution instead of attempting
to scrape the list screen.

---

## SE16N Check Script Behavior

The SE16N check script (`sap_se38_check.vbs`) queries table TRDIR for the program name.
Different SAP configurations may show results differently:

1. **Popup with count** — `wnd[1]/usr/txtGD-NUMBER` shows the result count (most common)
2. **Direct navigation** — No popup; SE16N navigates directly to the data browser (screen 200)
3. **Status bar message** — "no entries found" or "N entries selected" in status bar

The check script handles all three cases by checking popup first, then status bar, then screen number.

---

## Object Directory Entry Dialog (Package/Transport)

When creating a new program with a package and transport:

1. **Attributes dialog** (`wnd[1]`, SAPLSEDTATTR/200) — program type, title
2. **Object Directory Entry** (`wnd[2]`, SAPLSTRD/100) — appears AFTER the attributes dialog
   - Package field varies by SAP release:
     - S/4HANA 1909: `ctxtKO007-L_DEVCLASS`
     - Other systems: `ctxtSEUK-DEVCLASS`
   - The VBS templates try both field names as fallbacks
   - Press Enter → transport dialog at the same `wnd[2]` (SAPLSTRD/300)
3. **Transport dialog** (`wnd[2]`, SAPLSTRD/300) — may appear at same window
   - Transport field varies by SAP release:
     - S/4HANA 1909: `ctxtKO008-TRKORR` (may be pre-filled if package already has an open transport)
     - Other systems: `ctxtKORR_TXT-REQ_NUM` or `ctxtKO007-L_REQ`
   - The VBS templates try all three field names as fallbacks
   - If the transport is auto-assigned (package already has an open request), the dialog may close immediately after Enter on the package field — no explicit transport entry needed

When saving an existing program to a package, the transport dialog appears at `wnd[1]` (not `wnd[2]`), using the same field name fallbacks.

**Note:** Updating an existing $TMP object does NOT trigger the transport dialog — package
reassignment requires SE03 or manual intervention.

### SE38 Initial Screen Controls

| Button/Radio | ID | Description |
|---|---|---|
| Create | `btnNEW` | Creates a new program |
| Display | `btnSHOP` | Opens program in display mode |
| Change | `btnCHAP` | Opens program in change mode |
| Source Code | `radRS38M-FUNC_EDIT` | Source Code subobject radio |
| Attributes | `radRS38M-FUNC_HEAD` | Attributes subobject radio |
| Delete | `mbar/menu[0]/menu[12]` | Program > Delete... menu |

### SE38 Delete Flow

From the SE38 initial screen with program name entered:
1. Select `Program > Delete...` (`mbar/menu[0]/menu[12]`)
2. Confirmation dialog (`wnd[1]`, screen 201) shows checkboxes for Source, Text Elements, etc.
3. Press `btn[0]` (Delete) on the confirmation toolbar to confirm deletion

