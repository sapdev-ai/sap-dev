---
name: sap-function-group
description: |
  Full lifecycle for SAP function groups: check existence, create,
  re-activate, query PROGDIR state, and delete. Mode-aware — picks the
  RFC fast-path (`RS_FUNCTION_POOL_INSERT`, `RFC_READ_TABLE` on TLIBG /
  TFDIR / TADIR / PROGDIR) when possible, falls through to GUI scripting
  (SE37 menus + SE38 delete) when no RFC equivalent exists.
  Honours `userConfig.sap_dev_mode` (GUI / RFC); the default chain for
  each operation is documented in the SKILL.md mode dispatch table.
  Replaces the now-removed `sap-se37-fugr` skill — call this skill for
  every function-group lifecycle step. Deletion is irreversible: the
  skill MUST confirm with the user before delegating to /sap-se38.
  Prerequisites: SAP NCo 3.1 (32-bit, .NET 4.0) in GAC for RFC paths;
  active SAP GUI session (use /sap-login first) for GUI paths.
argument-hint: "<FUGR_ID> [\"<short description>\"] [package] [transport] [--activate-only|--check-state|--delete]"
---

# SAP Function Group Skill

You manage SAP function-group lifecycle (check / create / activate /
check state / delete). The skill picks RFC vs GUI per operation and per
`userConfig.sap_dev_mode`; callers don't pick a transport.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` instead of asking for the TR itself |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |

---

## Operation × transport matrix

| Operation | RFC path | GUI path | Fallback chain (when `sap_dev_mode` unset) |
|---|---|---|---|
| **Check existence** | `RFC_READ_TABLE TLIBG` | implied by SE37 navigation | RFC → GUI |
| **Create + activate** | `RS_FUNCTION_POOL_INSERT` (creates active FG in one call) | SE37 *Goto > Function Groups > Create* + activate | RFC → GUI |
| **Activate only** | not supported via standard RFC | SE37 *Change Group* + Ctrl+F3 + Inactive-Objects worklist | GUI only |
| **Check PROGDIR state** | `RFC_READ_TABLE PROGDIR` for `SAPL<FG>` | n/a | RFC only |
| **Delete** | no clean RFC API | Step 3e — own VBS deletes `SAPL<FG>` via SE38 (Shift+F2) + shared walker | GUI only |

`--activate-only` and `--delete` always force the GUI path. Everything
else follows the **mode precedence in Step 2** — `sap_dev_mode` takes
priority over the fallback chain when set.

---

## Step 0 — Resolve Work Directory and Defaults

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `sap_dev_package`, `sap_dev_transport_request`, `sap_dev_mode`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `sap_dev_mode` | `GUI` (per CLAUDE.md fallback chains) |

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:

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

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_function_group_run.json" -Skill sap-function-group -ParamsJson "{\"function_group\":\"<FUGR>\",\"mode\":\"<MODE>\"}"
```

State file: `{RUN_TEMP}\sap_function_group_run.json`. Best-effort.

---

## Step 1 — Parse Arguments

| Parameter | Required for | Default |
|---|---|---|
| Function group ID | all operations | `userConfig.sap_dev_function_group`, fallback `ZZSAPDEVFMGAI` |
| Short description | create only | `"Function group <FG_NAME>"` |
| Package | create only (optional) | `userConfig.sap_dev_package` |
| Transport | create / delete (optional) | `userConfig.sap_dev_transport_request` (resolved via `/sap-transport-request` when mandatory and blank) |

Convert FG name to UPPERCASE.

**Validate:**

- FG name must start with `Y` or `Z` (customer namespace). On failure, tell
  the user `"Function group name must start with Y or Z (customer namespace). Got: '<name>'"` and stop.
- For create: description is required and must not be empty.
- For delete: description / package arguments are ignored.

**Mode dispatch table:**

| Trigger | Operation | Steps |
|---|---|---|
| Default (FG ID + description) | Create + activate | Step 2 → Step 3a (RFC) **or** Step 3b (GUI) |
| `--activate-only` or "(re-)activate function group `<FG>`" | Activate-only | Step 3c (GUI) |
| `--check-state` or "check state of function group `<FG>`" | PROGDIR state check | Step 3d (RFC) |
| `--delete`, "delete function group `<FG>`", "drop function group `<FG>`", "remove FUGR `<FG>`" | Delete | Step 3e (delegates to `/sap-se38`) |

**Deletion is irreversible** — the skill MUST confirm with the user
(state the FG ID, the SAP package, and the dependent-FM list from the
TFDIR pre-check) before delegating.

---

## Step 2 — Read SAP Connection / Resolve Mode

For RFC paths, read the standard SAP connection settings from
`$USER_CONFIG`:

| Setting key | Maps to token |
|---|---|
| `sap_application_server` | `%%SAP_SERVER%%` / `%%SAP_APPLICATION_SERVER%%` |
| `sap_system_number` | `%%SAP_SYSNR%%` / `%%SAP_SYSTEM_NUMBER%%` |
| `sap_client` | `%%SAP_CLIENT%%` |
| `sap_user` | `%%SAP_USER%%` |
| `sap_password` | `%%SAP_PASSWORD%%` |
| `sap_language` | `%%SAP_LANGUAGE%%` |
| `sap_dev_package` | `%%DEVCLASS%%` |
| `sap_dev_transport_request` | `%%CORRNUM%%` / `%%TRANSPORT%%` |

For GUI paths: ensure an SAP GUI session is open (`/sap-login`).

If neither RFC nor GUI is configured, ask the user to fix `settings.json`.

**Mode selection (precedence — highest first):**

1. **Operator override** (`--rfc` / `--gui` argument): use that path. If
   the operation has no implementation for the requested mode, **stop
   with an error** — do not silently fall back.
2. **`userConfig.sap_dev_mode` is `RFC` or `GUI`**: use that path if the
   operation has an implementation for it. If not (e.g. `GUI` requested
   for "Check PROGDIR state" which is RFC-only), fall through to the
   next available path in the fallback chain **and log the fallthrough**
   so the operator sees their preference was overridden.
3. **`sap_dev_mode` blank or unset**: use the fallback chain in the
   matrix above (typically RFC → GUI for read/check, GUI for things RFC
   can't do).

When honouring an explicit `sap_dev_mode`, do **NOT** also "try the
other path first as a default" — that defeats the purpose of the
setting.

---

## Step 3a — Create + Activate via RFC (RFC path)

Template: `<SKILL_DIR>/references/sap_function_group_rfc_create.ps1`.
Calls `RFC_READ_TABLE` on `TLIBG` to check existence; on miss, calls
`RS_FUNCTION_POOL_INSERT`. Returns active FG in one round-trip — no
separate activate step needed.

Generate `{RUN_TEMP}\sap_function_group_rfc_create_run.ps1`:

```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_function_group_rfc_create.ps1', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_APPLICATION_SERVER%%', '')
$content = $content.Replace('%%SAP_SYSTEM_NUMBER%%',      '')
$content = $content.Replace('%%SAP_CLIENT%%',             '')
$content = $content.Replace('%%SAP_USER%%',               '')
$content = $content.Replace('%%SAP_PASSWORD%%',           '')
$content = $content.Replace('%%SAP_LANGUAGE%%',           '')
$content = $content.Replace('%%RFC_LIB_PS1%%',            '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$content = $content.Replace('%%FUNCTION_GROUP%%',         'THE_FG_NAME')
$content = $content.Replace('%%SHORT_TEXT%%',             'THE_SHORT_TEXT')
$content = $content.Replace('%%DEVCLASS%%',               'THE_DEVCLASS')
$content = $content.Replace('%%CORRNUM%%',                'THE_CORRNUM')
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_function_group_rfc_create_run.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Execute via **32-bit PowerShell** (NCo 3.1 is in `GAC_32`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_function_group_rfc_create_run.ps1"
```

**Output (parseable):**

| Output line | Meaning |
|---|---|
| `RESULT_STATUS: EXISTS` | FG already exists; nothing to do |
| `RESULT_STATUS: CREATED` | FG was created (active) |
| `RESULT_STATUS: ERROR` | RFC call failed; see `ERROR:` lines |

If `ERROR: NCo 3.1 not found in GAC_32`, fall through to **Step 3b**
(GUI). Most other RFC errors are real and should be surfaced.

---

## Step 3b — Create + Activate via SE37 GUI (GUI path)

Template: `<SKILL_DIR>/references/sap_function_group_gui_create.vbs`.
Drives *Goto > Function Groups > Create Group*, fills the group ID and
short text, routes the package + transport dialogs (Local Object via
`btn[7]` when package is empty, or `KO007-L_DEVCLASS` + `KO008-TRKORR`
when supplied), then re-opens the FG via *Change Group* and activates
it via toolbar `btn[27]`, handling the Inactive Objects worklist popup
(Select All → Continue).

| Token | Replace with |
|---|---|
| `%%FUGR_ID%%` | Function group name (UPPERCASE) |
| `%%FUGR_DESC%%` | Short description (any case) |
| `%%PACKAGE%%` | Package name, or empty / `$TMP` for local |
| `%%TRANSPORT%%` | Transport request, or empty for local |

Generate `{RUN_TEMP}\sap_function_group_gui_create_run.ps1`:

```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_function_group_gui_create.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%FUGR_ID%%','THE_ID'
$content = $content -replace '%%FUGR_DESC%%','THE_DESC'
$content = $content -replace '%%PACKAGE%%','THE_PKG'
$content = $content -replace '%%TRANSPORT%%','THE_TR'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_function_group_gui_create_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run via cscript:

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_function_group_gui_create_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\sap_function_group_gui_create_run.vbs
```

**Output:** the VBS prints `INFO: sbar [...]` and `INFO: activate sbar
[...]` lines, ending with `DONE FUGR=<ID>` on success or `ERROR: ...`.

---

## Step 3c — Activate-only (GUI)

Template: `<SKILL_DIR>/references/sap_function_group_gui_activate.vbs`.

> **Recommended** after **any** `/sap-se37` (single-FM) create/update
> against an existing FG. SE37's FM-level activation only activates the
> FM itself; the function-pool program `SAPL<FUGR_ID>` may stay inactive
> (`PROGDIR.STATE='I'`), which blocks TR release with
> `Object REPS SAPLZxxx is inactive` on the consistency check screen.
> The activate-only path uses the Inactive Objects popup with Select
> All → Continue, which activates `SAPL<FUGR_ID>` together with the FMs.

| Token | Replace with |
|---|---|
| `%%FUGR_ID%%` | Function group name (UPPERCASE) |

Generate + run identically to Step 3b but using
`sap_function_group_gui_activate.vbs`.

---

## Step 3d — Check PROGDIR state via RFC

Template: `<SKILL_DIR>/references/sap_function_group_check_state.ps1`.
Reads PROGDIR over RFC where `NAME = 'SAPL' & FUGR_ID` and reports the
STATE values found (`A`=Active, `I`=Inactive, `S`=Saved). Requires SAP
RFC credentials.

| Token | Replace with |
|---|---|
| `%%FUGR_ID%%` | Function group name (UPPERCASE) |
| `%%SAP_SERVER%%` / `%%SAP_SYSNR%%` / `%%SAP_CLIENT%%` / `%%SAP_USER%%` / `%%SAP_PASSWORD%%` / `%%SAP_LANGUAGE%%` | from settings.json |

Run via 32-bit PowerShell. **Output (parseable):**

| Last line | Meaning |
|---|---|
| `STATE=A` | PROGDIR shows program is Active |
| `STATE=I` or `STATE=A,I` | Inactive version still present — needs re-activate (call Step 3c) |
| `NOT_FOUND` | No PROGDIR row — FG does not exist |
| `ERROR: …` | RFC failure |

---

## Step 3e — Delete (via SE38 `SAPL<FG>` pool-program delete)

**Mechanism (one path, all releases).** A function group is deleted by deleting
its **function-pool program `SAPL<FUGR>`** in SE38 (Shift+F2) + the shared
`sap_delete_popups.vbs` walker. Deleting `SAPL<FUGR>` cascades the whole
function group (the pool program with its FMs / includes / screens, plus the
`TLIBG` registration). Verified on **ECC 6.0 / NW 7.31 (EC2/ERP)** and
**S/4HANA 1909 (S4D)**, 2026-06-22.

There is no clean standard RFC API for FG deletion (`RS_FUNCTION_POOL_DELETE`
exists in some releases but is undocumented and dangerous), so GUI is the path.

> **Why not SE80 `WB_DELETE`?** Retired 2026-06-22. SE80's HTML type/name
> control is absent on ECC6 (classic navigator), and even on S/4 its hand-rolled
> inline popup walker looped on a `$TMP`/local FG and emitted a **false SUCCESS**
> on an empty status bar (S4D: `TLIBG`=1 yet "deleted"). The SE38 `SAPL<FG>`
> path + the shared DDIC-id-gated walker (SAPLSETX / KO007 / TR-prompt / confirm)
> is release- and locale-robust, so it is the single path now.

Still **invoke the skill** (this Step) rather than the VBS directly — it adds the
TR resolution + dependent-FM pre-check below and the mandatory RFC verification,
none of which the VBS does on its own.

**Pre-checks (do these BEFORE confirming with the user):**

1. **Confirm the FG exists.** `RFC_READ_TABLE` on `TLIBG` filtered by
   `AREA = <FUGR_ID>`. If zero rows, tell the user nothing to delete and
   stop.
2. **List the dependent FMs.** `RFC_READ_TABLE` on `TFDIR` filtered by
   `PNAME = 'SAPL' & FUGR_ID`; show the operator the list. Bail out if
   the list is large or the operator hesitates.
3. **Resolve the TR.** `RFC_READ_TABLE` on `TADIR` for
   `PGMID='R3TR' AND OBJECT='FUGR' AND OBJ_NAME=<FUGR_ID>`. If
   `DEVCLASS` starts with `$` it's local — TR not needed. Otherwise
   resolve a modifiable TR via `/sap-transport-request` and pass it on
   to the delete call.

**Confirmation prompt (mandatory):**

> Deleting function group `<FUGR_ID>` will also drop these function
> modules: `<list>`. Package: `<DEVCLASS>`. This is irreversible.
> Proceed? (yes/no)

Do not run the VBS without an explicit yes.

### Generate the filled-in VBScript

Template: `<SKILL_DIR>/references/sap_function_group_gui_delete.vbs`.

| Token | Replace with |
|---|---|
| `%%FUGR_ID%%` | Function group name (UPPERCASE) |
| `%%TRANSPORT%%` | TR for the post-delete prompt — empty when local (`$TMP`) or already locked to a modifiable TR |
| `%%PACKAGE%%` | FG `DEVCLASS` (pre-check 3) — fills the ECC6 KO007 "Create Object Directory Entry" popup so the deletion records on the TR. Empty = Local Object / accept pre-filled. Safe to leave empty. |
| `%%ORIG_LANG%%` | 1-char original language for an empty KO007 package field (default `E`). Usually left empty. |
| `%%SESSION_LOCK_VBS%%` | path to `sap_session_lock.vbs` |

Write `{RUN_TEMP}\sap_function_group_gui_delete_run.ps1`:

```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_function_group_gui_delete.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%FUGR_ID%%','THE_FG'
$content = $content -replace '%%TRANSPORT%%','THE_TR'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'   # FG DEVCLASS (pre-check 3); fills the ECC6 KO007 Object-Directory popup. Empty = Local Object.
$content = $content -replace '%%ORIG_LANG%%',''            # 1-char orig lang for an empty KO007 package; VBS defaults to E
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_function_group_gui_delete_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run:

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_function_group_gui_delete_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\sap_function_group_gui_delete_run.vbs
```

### Behaviour Notes

- The VBS opens `/nSE38`, fills `ctxtRS38M-PROGRAMM` = `SAPL<FUGR>`, and presses
  Delete (Shift+F2 = `sendVKey 14`) from the initial screen.
- The post-delete modal chain — a confirm, the dependents+confirm pair (the FG's
  FMs cascade with the pool program), the SAPLSETX "Different original and logon
  languages" popup (`ctxtRSETX-MASTERLANG` → `btnPUSH1`), the KO007 "Create
  Object Directory Entry" popup on ECC6 (`ctxtKO007-L_DEVCLASS`, filled from
  `%%PACKAGE%%` else Local Object), and a TR prompt for a transportable FG
  (`ctxtKO008-TRKORR`, filled from `%%TRANSPORT%%`; aborts if the prompt appears
  with TRANSPORT empty) — is dispatched entirely by the shared
  `sap_delete_popups.vbs` walker (DDIC-id-gated, locale-independent, walks
  stacked `wnd[1]`+`wnd[2]`).
- The VBS then does a quick **Display** re-check (`btnSHOP`): if the
  `ctxtRS38M-PROGRAMM` field survives we stayed on the initial screen →
  `SAPL<FG>` is gone → `SUCCESS`; if Display opened the editor it still exists →
  `ERROR`. This is a quick check only — the **mandatory RFC verification below is
  authoritative.**

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Function group <FUGR> deleted.` | sbar accepted — FG cascade complete. Always follow with the RFC verification below. |
| `ERROR: …` | Surface the message verbatim. |

### Post-delete RFC verification (mandatory)

The GUI status bar can lie when popups are force-dismissed. Always
follow the VBS with an RFC re-check, but distinguish runtime catalog
rows (failure) from a directory orphan (warning):

| Table check | Expectation | Verdict |
|---|---|---|
| `RFC_READ_TABLE TLIBG WHERE AREA='<FUGR>'` | zero rows | **FAIL** if rows return — the FG runtime row is still alive. |
| `RFC_READ_TABLE TFDIR WHERE PNAME='SAPL<FUGR>'` | zero rows | **FAIL** if rows return — dependent FMs not cascaded. |
| `RFC_READ_TABLE PROGDIR WHERE NAME='SAPL<FUGR>'` | zero rows | **FAIL** if rows return — function-pool program still exists. |
| `RFC_READ_TABLE TADIR WHERE PGMID='R3TR' AND OBJECT='FUGR' AND OBJ_NAME='<FUGR>'` | zero rows | **WARN-only** if rows return — TADIR orphan; SAP delete commonly leaves this when no TR-prompt-popup appeared (verified 2026-05-12 on S/4HANA 1909). The FG is functionally gone; the directory row is cosmetic until the operator cleans it via SE03 → Transport Organizer Tools → Object Directory, or assigns it to `$TMP` via `/sap-change-package FUGR <FUGR> $TMP`. |

Report the four checks side-by-side in the user-facing summary so the
operator can decide whether to leave the TADIR orphan or schedule SE03
cleanup.

## Step 4 — Interpret Results

| Last line of stdout | Meaning |
|---|---|
| `RESULT_STATUS: EXISTS` (Step 3a) | FG already exists; nothing to do |
| `RESULT_STATUS: CREATED` (Step 3a) | FG created (active) via RFC |
| `DONE FUGR=<ID>` (Step 3b/3c) | FG created+activated, or activated, via GUI |
| `STATE=A` / `STATE=I` / `STATE=A,I` / `NOT_FOUND` (Step 3d) | PROGDIR state |
| `SUCCESS: Function group <FUGR> deleted.` (Step 3e) | FG and dependents removed; **caller MUST re-verify TLIBG / TFDIR / TADIR are all zero** |
| `ERROR: …` | Failure — surface the message and consult the table below |

| Error | Cause | Fix |
|---|---|---|
| `ERROR: Activation failed: <sbar text>` (Step 3b/3c) | Activate (Ctrl+F3) ended with status-bar `E`/`A` -- the FG exists/was saved but is NOT active. Step 3b pre-fix echoed the sbar without checking it and always ended `DONE FUGR=`; both GUI flows now exit 1 on E/A. | Fix the reported cause (missing package, pool syntax error, lock), then re-run Step 3c (activate-only) and verify via Step 3d `STATE=A` |
| `NCo 3.1 not found in GAC_32` | NCo not installed for .NET 4.0 32-bit | Install NCo 3.1 (32-bit) per SAP Note, or fall through to GUI path |
| `RFC logon failed` | Bad credentials / unreachable server | Check sap-dev-core settings.json |
| `RFC_READ_TABLE call failed` | TLIBG / TFDIR / TADIR / PROGDIR access denied | Check RFC authorization |
| `RS_FUNCTION_POOL_INSERT call failed` | Missing S_DEVELOP auth or invalid package/TR | Review S_DEVELOP, package, transport |
| `ENQUEUE_FOREIGN_LOCK` | FG locked by another user | Wait and retry, or check SM12 |
| `FUNCTION_POOL_EXISTS` | Race condition on insert | FG exists, no action needed |
| `Object REPS SAPLZxxx is inactive` | FG main program inactive | Run Step 3c (activate-only) |
| Delete failed mid-flow | TR rejected, dependents refused, or operator pressed No on the SE38 popup | Surface the SE38 output; check `TADIR` for orphans |

---

## Step 5 — Report

For create / activate (Steps 3a, 3b, 3c):

- Operation taken (CREATED / EXISTS / ACTIVATED) and which path (RFC / GUI)
- Function group ID
- Package and transport used (or "Local Object" if `$TMP`)
- Status bar message (GUI path)

For check-state (Step 3d):

- The PROGDIR state(s) found
- Recommendation if `STATE=I` / `A,I` (run `--activate-only`)

For delete (Step 3e):

- The function group ID and the SAPL-prefixed program that was dropped
- The list of FMs that went away with it (from the TFDIR pre-check)
- Whether `TADIR` was clean after the delete or whether SE03 follow-up
  is required

---

## Step 6 — Clean Up

```bash
cmd /c del "{RUN_TEMP}\sap_function_group_rfc_create_run.ps1" "{RUN_TEMP}\sap_function_group_gui_create_run.ps1" "{RUN_TEMP}\sap_function_group_gui_create_run.vbs" "{RUN_TEMP}\sap_function_group_gui_activate_run.ps1" "{RUN_TEMP}\sap_function_group_gui_activate_run.vbs" "{RUN_TEMP}\sap_function_group_check_state_run.ps1"
```

(`del` ignores missing files; safe to run even when only some paths
were used.)

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_function_group_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_function_group_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `FUNCTION_GROUP_FAILED`, `FUNCTION_GROUP_DELETE_FAILED`,
`TR_RESOLUTION_FAILED`, `RFC_LOGON_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `*_run.ps1` and `*_run.vbs` files contain SAP credentials
(passwords for the RFC paths, user-visible TR / package values for the
GUI paths) — always delete after use (Step 6).

---

## Component IDs (GUI reference)

| Element | ID |
|---|---|
| OK code field | `wnd[0]/tbar[0]/okcd` |
| Goto > Function Groups > Create Group | `wnd[0]/mbar/menu[2]/menu[3]/menu[0]` |
| Goto > Function Groups > Change Group | `wnd[0]/mbar/menu[2]/menu[3]/menu[1]` |
| Create-popup group ID | `wnd[1]/usr/ctxtTLIBG-AREA` |
| Change-popup group ID | `wnd[1]/usr/ctxtRS38L-AREA` |
| Short text | `wnd[1]/usr/txtTLIBT-AREAT` |
| Save | `wnd[1]/tbar[0]/btn[0]` |
| Package field | `wnd[2]/usr/ctxtKO007-L_DEVCLASS` (sometimes `wnd[1]`) |
| Local Object button | `wnd[2]/tbar[0]/btn[7]` (sometimes `wnd[1]`) |
| Transport field | `wnd[2]/usr/ctxtKO008-TRKORR` (sometimes `wnd[1]`) |
| Activate (toolbar) | `wnd[0]/tbar[1]/btn[27]` |
| Inactive Objects: Select All | `wnd[1]/tbar[0]/btn[9]` |
| Inactive Objects: Continue | `wnd[1]/tbar[0]/btn[0]` |
| Activation errors popup | `wnd[2]/usr/btnSPOP-VAROPTION1` (or `btnBUTTON_1`) |
| Status bar | `wnd[0]/sbar` |

### PROGDIR fields read by Step 3d

| Field | Type | Meaning |
|---|---|---|
| `NAME` | CHAR40 | Program name; for FG it is `'SAPL' & FUGR_ID` |
| `STATE` | CHAR1 | `A`=Active, `I`=Inactive, `S`=Saved |

---

## 32-bit Note

SAP NCo 3.1 is registered in the 32-bit GAC
(`C:\Windows\Microsoft.NET\assembly\GAC_32`) when installed for .NET
4.0 32-bit. RFC PowerShell scripts (Steps 3a, 3d) MUST execute with:

```
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass
```

GUI VBS scripts (Steps 3b, 3c) run with the standard `cscript`.

---

## Encoding

- RFC PowerShell: UTF-8 (no BOM); NCo handles SAP unicode automatically.
- GUI VBS: UTF-16 LE w/BOM (`[System.IO.File]::WriteAllText(..., [System.Text.UnicodeEncoding]::new($false,$true))`).

---

## Limitations

- The GUI create flow does not handle the rare "Tasks owner" pop-up.
- Long text and embedded function-module creation are not supported —
  pure FG skeleton only.
- Window indexing for the package / transport dialog can shift between
  releases; the VBS tries `wnd[2]` first then falls back to `wnd[1]`.
- `--rfc` / `--gui` operator overrides are advisory; the dispatcher
  honours the matrix above and `userConfig.sap_dev_mode` but does not
  yet rewrite individual VBS templates to fail-fast in the wrong mode.

---

## History

- **2026-05-09**: Merged `sap-se37-fugr` into this skill. The old skill
  name has been removed; callers should invoke `/sap-function-group`
  for every FG operation. References renamed
  `sap_se37_fugr_*` → `sap_function_group_(rfc|gui)_*` /
  `sap_function_group_check_state.ps1`.
