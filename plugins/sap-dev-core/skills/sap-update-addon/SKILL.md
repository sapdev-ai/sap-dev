---
name: sap-update-addon
description: |
  Insert or update records in SAP add-on tables (Y/Z prefix); DELETE is not
  automated on any method path (refused before touching data — drive SM30
  manually for row deletion).
  Automatically detects the best method:
    1. SM30 — if a maintenance view exists
    2. SE16 — if DD02L-MAINFLAG = 'X' (direct table maintenance allowed)
    3. ZCMRUPDATE_ADDON_TABLE — fallback program for any add-on table
  Requires SAP GUI with an active session. Uses RFC for detection.
argument-hint: "<table-name> <data-file> [<operation>] [<sap-logon-description>]"
---

# SAP Update Add-on Table Skill

You maintain records in SAP add-on tables (Y/Z prefix) by detecting the best method and
executing the appropriate transaction.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — apply to ABAP this skill generates or checks. **Exception:** `references/ZCMRUPDATE_ADDON_TABLE.abap` is a deliberately **classic-syntax** bootstrap utility (it must activate on ECC 6.0 / NetWeaver ≤7.40 as well as S/4HANA) — do NOT modernize it. See "Classic-syntax exception" in Step 4c. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_sidecar.ps1` | OS-level (Win32) auto-dismiss for the "SAP GUI Security" dialog. Step 4c (PROG method) launches it in parallel: the program's `GUI_UPLOAD` (data-file read) and save-list `GUI_DOWNLOAD` (output write) are SAP-GUI-side file IO that trip the modal when `{work_dir}` isn't trusted — without the watcher, `cscript` hangs. |

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

Start a structured log run. State file: `{RUN_TEMP}\sap_update_addon_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_update_addon_run.json" -Skill sap-update-addon -ParamsJson "{\"table\":\"<TABLE>\"}"
```

---

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:
- **Table name** — required. Must start with Y or Z.
- **Data file path** — required. TAB-delimited text file, UTF-8, 1 header line.
  - Header: field names (uppercase), excluding MANDT
  - Data rows: values separated by TAB
- **Operation** — optional. `INSERT` (default), `UPDATE`, or `DELETE`.
  For the ZCMRUPDATE_ADDON_TABLE (PROG) method, INSERT and UPDATE both result in MODIFY (upsert).
  **DELETE is refused by all three method scripts** — SM30 flow: not implemented
  (`ERROR: SM30_DELETE_UNSUPPORTED`); SE16: stub on all releases
  (`ERROR: SE16_DELETE_UNSUPPORTED`); PROG: the utility has no DELETE mode
  (`ERROR: PROG method supports upsert (MODIFY) only`). Each exits 1 before
  touching any data. For deletes, drive SM30 manually or ask for a dedicated flow.
- **SAP Logon description** — optional. Used for credential lookup.

If the user provides inline data instead of a file, write it to `{RUN_TEMP}\<TABLE_NAME>_data.txt`
as a TAB-delimited file with header.

Verify the data file exists:
```bash
powershell -Command "if (Test-Path 'THE_FILE') { 'EXISTS' } else { 'NOT FOUND' }"
```

---

## Step 2 — Read SAP Connection Parameters

Read SAP connection parameters from the merged sap-dev-core settings (per `shared/rules/settings_lookup.md` — `settings.local.json` overrides `settings.json` per-key on the `.value` field):

| Setting key | Maps to | Example |
|---|---|---|
| `sap_application_server` | `%%SAP_SERVER%%` | `10.0.0.1` |
| `sap_system_number` | `%%SAP_SYSNR%%` | `00` |
| `sap_client` | `%%SAP_CLIENT%%` | `100` |
| `sap_user` | `%%SAP_USER%%` | `DEVELOPER` |
| `sap_password` | `%%SAP_PASSWORD%%` | *(masked)* |
| `sap_language` | `%%SAP_LANGUAGE%%` | `EN` |

**If settings are not configured**, ask the user to provide the values and suggest
they configure settings.json for future use.

### Ensure SAP GUI session is active

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 3 — Detect Best Method

The detection PowerShell template is at `./references/sap_update_addon_detect.ps1`.

Write `{RUN_TEMP}\sap_update_addon_detect_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_update_addon_detect.ps1', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_SERVER%%',   '')
$content = $content.Replace('%%SAP_SYSNR%%',    '')
$content = $content.Replace('%%SAP_CLIENT%%',   '')
$content = $content.Replace('%%SAP_USER%%',     '')
$content = $content.Replace('%%SAP_PASSWORD%%', '')
$content = $content.Replace('%%SAP_LANGUAGE%%', '')
$content = $content.Replace('%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$content = $content.Replace('%%TABLE_NAME%%',   'THE_TABLE_NAME')
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_update_addon_detect_run.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Execute via 32-bit PowerShell. The outer command resolves the AI session's
pinned SAP session (canonical `Get-SapCurrentSessionPath` wrapper line) and
bridges it into the child via `$env:SAPDEV_SESSION_PATH`, so detection runs
against the pinned session instead of grabbing the first session of the first
connection. The detect script resolves its target in attach-lib order:
explicit `-SessionPath` → `$env:SAPDEV_SESSION_PATH` → sole-connection +
sole-session default → refuse loud (exit 1, listing the attached connections
and telling the user to `/sap-login` pin).

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command '. "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1"; $env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp "{WORK_TEMP}"; & "C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_update_addon_detect_run.ps1"'
```

(The `-Command` string is single-quoted for the shell so `$env:` survives
git-bash verbatim.) If the user supplied an explicit `--session
/app/con[N]/ses[M]`, append `-SessionPath "/app/con[N]/ses[M]"` to the inner
`powershell.exe` invocation instead.

Parse the output lines:
- `RESULT_SM30:True` / `RESULT_SM30:False`
- `RESULT_MAINFLAG:X` / `RESULT_MAINFLAG:`
- `RESULT_PROG:True` / `RESULT_PROG:False`
- `RESULT_METHOD:SM30` / `SE16` / `PROG` / `NONE`

If `RESULT_METHOD:NONE`, tell the user no method is available and suggest deploying
ZCMRUPDATE_ADDON_TABLE first using the sap-se38 skill.

**Detection-attach failure (exit code 2):** On some Windows 11 + SAP GUI 760+
builds, `GetActiveObject("SAPGUI")` fails with `CO_E_CLASSSTRING` ("Invalid
class string") because the SAPGUI ProgID is not registered in the Running
Object Table for the calling process bitness. The detect script tries
`SAPGUI`, `SAPGUI.ScriptingCtrl.1`, and `SapGui.ScriptingCtrl.1` in turn; if
all fail it exits with code 2. When you see exit code 2, **skip detection
entirely and proceed directly to Step 4c (PROG method)** — the universal
ZCMRUPDATE_ADDON_TABLE program path uses VBS `GetObject("SAPGUI")` which is
not affected by the same registration issue.

---

## Step 4 — Execute Using Detected Method

### Step 4a — SM30 Method

Template: `./references/sap_update_addon_sm30.vbs`

Write `{RUN_TEMP}\sap_update_addon_sm30_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_update_addon_sm30.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%TABLE_NAME%%', 'THE_TABLE_NAME')
$content = $content.Replace('%%DATA_FILE%%',  'THE_DATA_FILE')
$content = $content.Replace('%%OPERATION%%',  'THE_OPERATION')
# Transport for the SM30 transport popup (probed by control id
# ctxtKO008-TRKORR). Resolve it via /sap-transport-request FIRST whenever the
# maintenance view can be transportable / recording-enabled. '' is allowed,
# but if SAP then prompts for a TR the VBS aborts with ABORT_EMPTY_TR -- it
# never blind-Enters the transport popup.
$content = $content.Replace('%%TRANSPORT%%',  'THE_TRANSPORT_OR_EMPTY')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_update_addon_sm30_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Execute (SAP GUI Scripting COM requires 32-bit cscript):
```bash
C:/Windows/SysWOW64/cscript.exe //NoLogo "{RUN_TEMP}\sap_update_addon_sm30_run.vbs"
```

**SM30 Notes:**
- **Single-record layouts only, exactly ONE data row per run.** The flow fills
  flat `ctxt<TABLE>-<FIELD>` / `txt<TABLE>-<FIELD>` fields and saves once; a
  multi-row data file is refused upfront (rows 2..N would overwrite the same
  fields before the Save). Table-control (list) maintenance dialogs are refused
  with `ERROR: SM30_LAYOUT_UNSUPPORTED (table control) - use the SE16 or PROG method`
  before anything is saved.
- **Transport popup is dispatched by control id** (`ctxtKO008-TRKORR` probe,
  same discriminator as `shared/scripts/sap_delete_popups.vbs`) — never
  blind-Enter'd. Present + `%%TRANSPORT%%` filled → fill + Enter; present +
  empty transport → the run echoes `ABORT_EMPTY_TR` and exits 1 (resolve a TR
  via `/sap-transport-request`, re-run). Non-TR info popups (e.g. the
  cross-client caution) are dismissed with Enter; a popup chain that survives
  5 dismissals fails loud.
- **DELETE is refused upfront** (`ERROR: SM30_DELETE_UNSUPPORTED`, exit 1).
- New Entries button is typically `tbar[1]/btn[14]`; Save via Ctrl+S (sendVKey 11).
- **Verdict gates:** status bar `MessageType` E/A after Enter or after Save →
  `ERROR: ...` + exit 1. `SUCCESS: SM30 maintenance completed for <TABLE>`
  prints only after every gate passes.

### Step 4b — SE16 Method

Template: `./references/sap_update_addon_se16.vbs`

Write `{RUN_TEMP}\sap_update_addon_se16_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_update_addon_se16.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%TABLE_NAME%%', 'THE_TABLE_NAME')
$content = $content.Replace('%%DATA_FILE%%',  'THE_DATA_FILE')
$content = $content.Replace('%%OPERATION%%',  'THE_OPERATION')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_update_addon_se16_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Execute (SAP GUI Scripting COM requires 32-bit cscript):
```bash
C:/Windows/SysWOW64/cscript.exe //NoLogo "{RUN_TEMP}\sap_update_addon_se16_run.vbs"
```

**SE16 Notes (INSERT / UPDATE):**
- Create Entries = **`tbar[1]/btn[5]`** (icon `B_CREA`) on the SE16 initial screen (`SAPLSETB`/230), pressed after entering the table name. Live-verified the **SAME on both ECC 6.0 (SID ER1) and S/4HANA 1909 (S4D)**, 2026-06-17. NB: `tbar[1]/btn[18]` is **not** Create Entries (it is Selection-Screen-Help / Info, icon `B_INFO`, and only exists on the post-Enter selection screen) — the original "S/4 = btn[18]" assumption was wrong; it's kept only as a legacy fallback.
- The VBS tries `btn[5]` → `btn[18]` (legacy) → the Edit menu, and **verifies it reached the Insert form** (probes the first non-MANDT field via `EntryFieldPresent`) before filling — a press that lands on the wrong screen never leads to saving an empty/wrong row; if none reach the form it fails loud.
- Insert-form fields (`/1BCDWB/DB<table>`/101): `txt<TABLE>-<FIELD>` (or `ctxt`); MANDT is read-only and skipped. Each record is saved with Ctrl+S → status "Database record successfully created".
- The data file is read as **UTF-8** (ADODB.Stream), aligned with the PROG path and the Step 1 contract — older revisions read UTF-16 and silently failed on UTF-8 files.
- **Live-verified end-to-end INSERT on BOTH ER1 (ECC 6.0) and S4D (S/4HANA 1909), 2026-06-17** — a row was created in a Z table on each via the `btn[5]` path.
- **DELETE via SE16 is refused upfront** (`ERROR: SE16_DELETE_UNSUPPORTED`, exit 1, before any row is touched) — the SE16 result is a non-grid classic `SAPMSSY0`/120 list with no Delete button on both ER1 and S4D. For deletes use SM30 (needs a maintenance view) or delete manually. INSERT/UPDATE is the supported SE16 path.
- **Per-row verdict:** a row whose save returns status-bar `MessageType` E/A counts as FAILED. A row where only SOME field IDs matched is **not saved** (saving it would commit silently-empty fields) — the VBS backs out with F12 (+ discard confirm) and counts it FAILED. Any failed row makes the final verdict `ERROR: <n> of <m> rows failed (rows: <list>)` + exit 1; only an all-rows-clean run ends `SUCCESS: SE16 maintenance completed. <n> of <m> rows saved.`

### Step 4c — ZCMRUPDATE_ADDON_TABLE Method

First, ensure the ZCMRUPDATE_ADDON_TABLE program is available. If not, tell the user to deploy it using the sap-se38 skill (or run `/sap-dev-init`).
The source code for ZCMRUPDATE_ADDON_TABLE is at `./references/ZCMRUPDATE_ADDON_TABLE.abap` for reference.

> **Classic-syntax exception — do not modernize `ZCMRUPDATE_ADDON_TABLE.abap`.**
> Unlike customer-facing ABAP (which follows the modern-syntax / OOP rules in
> `abap_code_quality_rules.md`), this bootstrap utility is written entirely in
> **classic, release-independent ABAP** so a SINGLE source activates on BOTH
> classic ECC 6.0 / NetWeaver ≤7.40 AND S/4HANA 1909+. The 7.40+ expression
> syntax a generator normally emits — inline `DATA(...)`, `VALUE`/`NEW`/`CONV`,
> string templates `|…{ }…|`, the `&&` operator, table types `WITH EMPTY KEY` —
> does **not** activate on ECC 6.0 (verified 2026-06-17 on SID ER1: the program
> deploys but will not activate and will not launch from SA38). If you edit this
> file keep it classic — explicit `DATA`, `CREATE OBJECT`, `CONCATENATE` / `WRITE`,
> `WITH DEFAULT KEY`. The file header repeats this rule. No release detection is
> needed: one file runs everywhere.

Template: `./references/sap_update_addon_prog.vbs`

Write `{RUN_TEMP}\sap_update_addon_prog_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_update_addon_prog.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%TABLE_NAME%%', 'THE_TABLE_NAME')
$content = $content.Replace('%%DATA_FILE%%',  'THE_DATA_FILE')
$content = $content.Replace('%%TEMP_DIR%%',   '{RUN_TEMP}')
# ZCMRUPDATE_ADDON_TABLE's only write path is MODIFY (upsert). The VBS
# refuses OPERATION=DELETE upfront with
# "ERROR: PROG method supports upsert (MODIFY) only" (exit 1).
$content = $content.Replace('%%OPERATION%%',  'THE_OPERATION')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_update_addon_prog_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

### Execute (with SAP GUI Security guard)

The PROG method does **SAP-GUI-side file IO** — the ABAP program's `GUI_UPLOAD`
reads the data file, and the save-list step writes `sap_update_addon_output.txt`.
Both can raise the modal **SAP GUI Security** dialog, which suspends the Scripting
API and **hangs `cscript`** unless `{work_dir}` is already trusted (so a plain
`cscript` run with no guard hangs — verified 2026-06-17 on SID ER1, where the
save-list dialog blocked the run). Launch the OS-level watcher
`sap_gui_security_sidecar.ps1` in parallel; it dismisses each dialog (clicks
Allow + ticks Remember, persisting the rule so later runs are clean). The timeout
is generous because on slower systems (e.g. classic ECC 6.0) the save-list dialog
can appear well after the upload.

```powershell
$shared  = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$watcher = Start-Process powershell -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput "{RUN_TEMP}\sap_update_addon_sidecar.out" `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
                    "$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','90')
Start-Sleep -Milliseconds 800
# cscript returns only after the program run + save-list complete (all dialogs handled).
& 'C:\Windows\SysWOW64\cscript.exe' //NoLogo "{RUN_TEMP}\sap_update_addon_prog_run.vbs"
if (-not $watcher.HasExited) { Stop-Process -Id $watcher.Id -Force -ErrorAction SilentlyContinue }
Get-Content "{RUN_TEMP}\sap_update_addon_sidecar.out" -Tail 1   # DISMISSED:WIN32 / TIMEOUT
```

**The VBS gates its own verdict** (SUCCESS only when every gate passes):

- Status bar `MessageType` E/A after F8, or still on selection screen 1000
  (= the program never ran) → `ERROR: ...` + exit 1.
- It saves the list output to `{RUN_TEMP}\sap_update_addon_output.txt` and
  parses the program's result-count block **locale-independently**: the line
  directly above the final all-`=` separator holds exactly two integers
  (success, error). The program's WRITE labels are Japanese and can render as
  `#` under a non-matching logon codepage — the digits and the `====` lines
  always survive, so the parse never depends on words. Echoes
  `RESULT_COUNTS: success=<n> error=<m>`.
- Parsed `error > 0`, `success = 0`, or a saved list WITHOUT the count block
  (= the program aborted early, e.g. column-count mismatch — first list lines
  are echoed as `LIST: ...`) → `ERROR: ...` + exit 1.
- If the list file could not be saved at all, the run ends
  `SUCCESS_UNVERIFIED: ...` (exit 0): the sbar gate passed but the counts are
  unread — treat as unconfirmed and verify via `/sap-se16n`.
- `SUCCESS: ZCMRUPDATE_ADDON_TABLE upserted <n> row(s) into <TABLE>.` prints
  only when the parsed error count is 0.

The saved list holds the per-row messages. The authoritative result is the
target table content — confirm via `/sap-se16n` (or RFC where available).

---

## Step 5 — Report Result

Show the user:
1. Which method was selected and why
2. The operation result (success/error counts)
3. Any errors encountered

Terminal script outcomes to relay verbatim:

| Line | Meaning | Exit |
|---|---|---|
| `SUCCESS: ...` | All gates passed (SM30 sbar gate / SE16 all rows saved / PROG parsed error count = 0) | 0 |
| `SUCCESS_UNVERIFIED: ...` (PROG only) | sbar gate passed but the result-count list could not be saved/read — verify via `/sap-se16n` before trusting | 0 |
| `ABORT_EMPTY_TR` (SM30) | Transport popup appeared with no TR resolved — nothing saved | 1 |
| `ERROR: SM30_LAYOUT_UNSUPPORTED (table control) - use the SE16 or PROG method` | Maintenance dialog is a table-control layout — nothing saved | 1 |
| `ERROR: <n> of <m> rows failed (rows: ...)` (SE16) | Per-row failures (sbar E/A, or partial field match — those rows were not saved) | 1 |
| `ERROR: SM30_DELETE_UNSUPPORTED` / `ERROR: SE16_DELETE_UNSUPPORTED` / `ERROR: PROG method supports upsert (MODIFY) only` | DELETE requested — refused before touching data | 1 |
| any other `ERROR: ...` | Gate failure (sbar E/A, program never ran, count block missing, ...) | 1 |

---

## Step 6 — Clean Up

```bash
cmd /c del {RUN_TEMP}\sap_update_addon_detect_run.ps1 {RUN_TEMP}\sap_update_addon_sm30_run.vbs {RUN_TEMP}\sap_update_addon_sm30_run.ps1 {RUN_TEMP}\sap_update_addon_se16_run.vbs {RUN_TEMP}\sap_update_addon_se16_run.ps1 {RUN_TEMP}\sap_update_addon_prog_run.vbs {RUN_TEMP}\sap_update_addon_prog_run.ps1 {RUN_TEMP}\sap_update_addon_output.txt {RUN_TEMP}\sap_update_addon_sidecar.out
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_update_addon_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_update_addon_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `UPDATE_ADDON_FAILED`, `RFC_LOGON_FAILED`.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `RESULT_METHOD:NONE` | No method available | Deploy ZCMRUPDATE_ADDON_TABLE first |
| `ERROR: N SAP connections attached; cannot pick one safely` (detect) | Multiple SAP connections and no pinned session | Run `/sap-login` to pin, or pass `-SessionPath` |
| `ABORT_EMPTY_TR` (SM30) | Save raised the transport popup (`ctxtKO008-TRKORR`) but no TR was resolved | Resolve a TR via `/sap-transport-request`, substitute it into `%%TRANSPORT%%`, re-run |
| `ERROR: SM30_LAYOUT_UNSUPPORTED (table control)` | The generated maintenance dialog is a table-control (list) layout, not single-record | Use the SE16 or PROG method |
| `ERROR: SM30 single-record flow supports exactly 1 data row per run` | Multi-row data file on the SM30 path | One run per row, or use the SE16 / PROG method |
| `ERROR: <n> of <m> rows failed` (SE16) | Row saves rejected (sbar E/A) or entry-form fields missing (partial rows are never saved) | Check the listed row numbers; fix the data or re-record the entry-form field IDs |
| `ERROR: *_DELETE_UNSUPPORTED` / `PROG method supports upsert (MODIFY) only` | DELETE requested — no script path implements it | Delete manually (or via SM30 maintenance dialog by hand) |
| `SUCCESS_UNVERIFIED` (PROG) | sbar gate passed but the saved list with the result counts could not be read | Verify the table content via `/sap-se16n` before trusting the run |
| `SE16 Create Entries not found` | MAINFLAG not set or editing blocked | Fall back to PROG method |
| `ZCMRUPDATE_ADDON_TABLE field mismatch` | Data file header doesn't match table | Check field names match table definition |
| `ERROR: Could not open the SE16 Create-Entries form` | Neither `btn[5]` (Create — verified ECC6 + S/4) nor `btn[18]` (legacy) nor the Edit menu reached the entry form on this release | Re-record the Create-Entries button for this release and add its ID to `sap_update_addon_se16.vbs`; or use the PROG / SM30 method |
| `ZCMRUPDATE_ADDON_TABLE` deploys but won't activate / won't launch on ECC 6.0 | Stale modern-syntax source (pre-2026-06-17) | Redeploy the current **classic-syntax** `ZCMRUPDATE_ADDON_TABLE.abap` via `/sap-se38` (or `/sap-dev-init`) |
| SE16/SM30 path: "must have header + data lines" on a valid file | Older VBS read the data file as UTF-16 | Fixed 2026-06-17 — both VBS now read UTF-8; ensure the data file is UTF-8, TAB-delimited |
