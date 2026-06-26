---
name: sap-se01
description: |
  Manages SAP transport requests via transaction SE01 using SAP GUI Scripting.
  Two modes:
    (a) CREATE — default. Creates a new TR. Defaults to Workbench (W); only
        creates Customizing (C) when the user explicitly asks. Description is
        rendered per userConfig.rule_of_tr_description (ASK/PATTERN/FIXED/
        RANDOM) and truncated to the 60-char SE01 limit. After creation the
        VBS itself resolves the new TRKORR via SE16N on E070 (filter by
        AS4USER + AS4DATE today, sort by AS4TIME desc, first row with
        TRFUNCTION K or W) and echoes `INFO: TRKORR=<...>`.
    (b) RELEASE — invoked as `/sap-se01 release <TR>`. Releases the TR (and
        any open tasks) via SE01 Transport Organizer (Display + F9 loop).
        Asks the user for explicit confirmation before releasing — release
        is irreversible.
    (c) DELETE -- invoked as `/sap-se01 delete <TR>`. Deletes an UNRELEASED
        request object (Display + Delete tbar[1]/btn[13], confirm via the
        shared popup walker) and verifies removal via E070. Asks for explicit
        confirmation; refuses a released TR or one holding non-dev objects.
        Used by /sap-dev-clean --reset to drop the dev TR.
    (d) REMOVE-OBJECTS -- invoked as `/sap-se01 remove-objects <TR>
        [OBJECTS=a,b,...]`. Unassigns object entries (E071) from an UNRELEASED
        request but KEEPS the request itself. With OBJECTS= it removes only the
        named objects (safe on a TR that holds other work); without it, removes
        ALL objects (Select-All). Clears the name-lock a lingering E071 entry
        holds, so a deleted object can be re-created -- the fix for "object is in
        request ..." / "enter object only in original request" on re-create.
        Verifies via E071. Used by /sap-dev-clean (teardown) and /sap-dev-init
        (defensive pre-create). Distinct from DELETE, which drops the whole TR.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "[create [W|C] [\"<desc>\"]] | [release <TR>] | [delete <TR>] | [remove-objects <TR> [OBJECTS=a,b]]"
---

# SAP SE01 — Transport Request Management Skill

You manage SAP transport requests via SE01 using SAP GUI Scripting. Four modes:
**CREATE** (default), **RELEASE**, **DELETE**, and **REMOVE-OBJECTS**.

Task: $ARGUMENTS

## Mode dispatch

Look at `$ARGUMENTS` to pick the mode:

| First token (case-insensitive) | Mode | Skip to |
|---|---|---|
| `release` followed by a TR (e.g. `release ER1K900234`) | RELEASE | "Release Mode" section below |
| `delete` followed by a TR (e.g. `delete ER1K900234`) | DELETE | "Delete Mode" section below |
| `remove-objects` / `remove-object` / `delobj` followed by a TR (e.g. `remove-objects ER1K900234 OBJECTS=ZCMD_RFCVAL`) | REMOVE-OBJECTS | "Remove-Objects Mode" section below |
| `create` (or no first-token keyword) | CREATE | continue with Step 1 |

Direct callers (`/sap-transport-request`) typically use the bare CREATE form.

---

# Create Mode (default)

Steps 0 – 7 below are the CREATE flow.

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules (no SQL writes on standard tables; no unsolicited deploys) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | Transport request resolution flow — defines `way_to_get_transport_request`, `rule_of_tr_description`, and the 60-char compression algorithm. This skill is a leaf called by `/sap-transport-request`; it implements the description rendering and request-type defaults. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |

---

## Step 0 — Resolve Work Directory and Settings

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`.

**Per-connection keys (Phase 4.4)**: `rule_of_tr_description` and `tr_description_template` are SAP-system-specific (customer naming conventions vary). Per `settings_lookup.md` § Per-connection exception, read them from `connections.json[pinned-profile].dev_defaults` FIRST (resolve the pin via `{work_dir}\runtime\session_registry.json` `ai_sessions[<id>]`); only fall back to the two-file merge when `dev_defaults` is empty.

Read:

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `sap_user` | (must be set; ask if blank) |
| `rule_of_tr_description` | `ASK` |
| `tr_description_template` | (blank) |

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

The logged-in SAP user (`sap_user`) is needed for the E070 lookup. If blank,
ask the user.

This skill MUST honour
`<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for description and type
defaults.

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{RUN_TEMP}\sap_se01_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_se01_run.json" -Skill sap-se01 -ParamsJson "{\"description\":\"<DESC>\",\"request_type\":\"W\"}"
```

---

## Step 1 — Parse Arguments and Resolve Inputs

Accepted argument forms (all optional):

| Parameter | Notes |
|---|---|
| `W` / `C` | Request type. **Default: `W` (Workbench)** — do NOT ask. Only treat as `C` when the user explicitly typed `C` / `customizing` / `cust` in the arguments or the conversation. |
| `"<short description>"` | If the caller passed a description, use it (still truncated to 60 chars in Step 3). |
| `OBJECT_TYPE=<...>` | Object type the caller is deploying (e.g. `REPORT`, `TABLE`, `FM`, `CLASS`, `MSGCLASS`). Used by `PATTERN`. |
| `OBJECT_DESCRIPTION=<...>` | Object name being deployed (e.g. `ZHKMARA`). Used by `PATTERN`. |

Mapping:
- `W` / `workbench` / `dev` → `radKO042-REQ_CONS_K`
- `C` / `customizing` / `cust` → `radKO042-REQ_CUST_W`

**Do NOT prompt the user for the request type.** A bare `/sap-se01` call
defaults to `W`.

---

## Step 2 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use
`/sap-login`, then return here.

---

## Step 3 — Build the Description (rule_of_tr_description)

If the caller passed an explicit `"<short description>"` argument **and** that
argument was provided by the human user (not by an upstream skill that just
forwarded a placeholder), use it as-is and skip to the truncation step.

Otherwise, render the description per `rule_of_tr_description`:

| Value | What to do |
|---|---|
| `ASK` | Prompt the user: "Short description for the new TR?" Use the answer. |
| `PATTERN` | Render `tr_description_template` with placeholder substitution (table below). If the template is blank, fall back to `{YYYYMMDD}_{OBJECT_TYPE}_{OBJECT_DESCRIPTION}`. |
| `FIXED` | Use `tr_description_template` literally. If blank, fall back to `ASK`. |
| `RANDOM` | Generate `TR_<8-hex-random>_<yyyyMMdd>` (e.g. `TR_4f8b2a91_20260426`). |

### Placeholders for `PATTERN`

| Placeholder | Source |
|---|---|
| `{YYYYMMDD}` | Workstation date (Get-Date format `yyyyMMdd`) |
| `{HHMMSS}` | Workstation time (Get-Date format `HHmmss`) |
| `{USER}` | `sap_user` from settings.json |
| `{OBJECT_TYPE}` | The `OBJECT_TYPE=...` argument; if absent, `OBJ` |
| `{OBJECT_DESCRIPTION}` | The `OBJECT_DESCRIPTION=...` argument; if absent, `UNKNOWN` |
| `{RANDOM4}` | 4-char alphanumeric (e.g. `7K2P`) — uniqueness suffix |

### Length constraint (60 chars max)

SE01 short description field accepts at most 60 characters. After rendering:

1. If length ≤ 60 → use as-is.
2. Otherwise compress in this order until ≤ 60:
   - Drop vowels (a/e/i/o/u, case-insensitive) from the rendered
     `{OBJECT_DESCRIPTION}` portion.
   - Drop vowels from `{OBJECT_TYPE}`.
   - Hard-truncate the entire string to 60 chars.

### Disambiguation for E070 lookup

The TRKORR lookup in Step 5 filters by AS4USER + AS4DATE (today) and sorts by
AS4TIME desc, taking the first top-level (TRFUNCTION K/W) row. The
description does not need to be unique for the lookup to work, but appending
`_<RANDOM4>` is still recommended so that the description distinguishes
parallel test runs in TR listings.

The VBS will echo back `INFO: AS4TEXT=<...>` and `INFO: AS4USER=<...>` for
diagnostics, plus `INFO: TRKORR=<...>` and `INFO: TRFUNCTION=<...>` once it
has resolved the new request.

---

## Step 4 — Run the SE01 Create VBS

Template: `./references/sap_se01_create.vbs`. Tokens: `%%REQUEST_TYPE%%`,
`%%DESCRIPTION%%`. The VBS performs both **create** and **lookup** in a
single run.

Write `{RUN_TEMP}\sap_se01_create_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se01_create.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%REQUEST_TYPE%%','THE_TYPE'
$content = $content -replace '%%DESCRIPTION%%','THE_DESC'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se01_create_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_TYPE` (W or C), `THE_DESC` (short text), and `<SKILL_DIR>` /
`{WORK_TEMP}` with absolute paths.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se01_create_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\sap_se01_create_run.vbs
```

**Expected last line of stdout:** `DONE`. If the VBS prints `ERROR:`, abort
and report.

Capture from the VBS stdout:
- `INFO: AS4TEXT=<...>` — the description as written
- `INFO: AS4USER=<...>` — the SAP login user
- `INFO: TRKORR=<...>`  — the resolved new transport request **(this is
  the answer; no further lookup is needed)**
- `INFO: TRFUNCTION=<...>` — `K` (Workbench) or `W` (Customizing)

---

## Step 5 — How the embedded TRKORR lookup works

The VBS, after creating the TR and echoing `AS4TEXT` / `AS4USER`, runs the
following lookup itself (no `/sap-se16n` call required):

1. Open `/nse16n`, set table = `E070`, press Enter to load the field
   selection table (`tblSAPLSE16NSELFIELDS_TC`).
2. Scan the field-selection table for rows whose **column 6 (Technical
   name)** equals `AS4USER` and `AS4DATE`. (Column 0 is the localised
   description and is unreliable across logon languages; column 6 is the
   technical field name and is locale-independent.)
3. Write `LOW` value (`ctxtGS_SELFIELDS-LOW[2,r]`) for the matched rows:
   - AS4USER row → `oSess.Info.User` (uppercased)
   - AS4DATE row → workstation today as 8-digit `YYYYMMDD` (locale-independent —
     SAP DATS fields accept it for any `USR01-DATFM`; a separator form like
     `YYYY.MM.DD` only works when it matches the user's date personalization)
4. Press F8 (`tbar[1]/btn[8]`) to execute. Dismiss any post-execute popup
   with Enter.
5. On the result grid (`wnd[0]/usr/cntlRESULT_LIST/shellcont/shell`):
   - `selectColumn "AS4TIME"`
   - `pressToolbarButton "&SORT_DSC"`
6. Walk rows top-down; the first row whose `TRFUNCTION` is `K` or `W` is the
   newly created top-level TR. Read `TRKORR` from that row.

**Why this approach (vs. AS4TEXT filter or download-to-file):**
- Locale-independent — works regardless of the user's logon language.
- Server-side timezone offsets are irrelevant (the lookup uses the table's
  own AS4DATE/AS4TIME, not workstation time-window comparisons).
- Single VBS run — no separate `/sap-se16n` invocation, no temp file parse.
- TRFUNCTION K/W naturally excludes task rows (which use `Q`/`S`/`X`).

---

## Step 6 — Parse the Result

Read the VBS stdout. Look for:

- `ERROR:` — abort and report. Common causes: SE16N field table did not
  load (check that E070 was set), grid empty (the create may have failed
  silently — re-check the SE01 sbar line above), or layout changed (the
  Technical-name column is no longer at index 6).
- `INFO: TRKORR=<TRKORR>` — that's the new transport request.
- `INFO: TRFUNCTION=<K|W>` — confirms it's a top-level Workbench (K) or
  Customizing (W) request.

---

## Step 7 — Report

Report the resolved transport request to the user:

```
Created <TYPE> request <TRKORR> ("<DESC>")
```

**Persistence is decided by the caller, not by `/sap-se01`.** Specifically:

- A direct `/sap-se01` invocation by the user does NOT update
  `sap_dev_transport_request`.
- When invoked via `/sap-transport-request` in `DEFAULT` mode, the caller
  persists the new TRKORR.
- When invoked via `/sap-transport-request` in `ASK` mode, the caller asks the
  user once whether to save it as default.
- When invoked via `/sap-transport-request` in `CREATE_NEW` mode, the caller
  does NOT persist.

See `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for the full flow.

---

# Release Mode

Use this section when `$ARGUMENTS` starts with `release` (e.g.
`/sap-se01 release ER1K900234`). Release marks the TR (and all of its tasks)
as `R` (Released) in `E070-TRSTATUS`. **Release is irreversible** — once
released, the TR cannot be modified again.

## R0 — Resolve work directory

Same as Step 0 above: resolve `work_dir`, set `{WORK_TEMP}`, ensure it exists.

## R1 — Parse the TR

Extract the TR number from `$ARGUMENTS` (the token after `release`). Validate
the format (`<SID>K<digits>`, e.g. `ER1K900234`). If missing or malformed:

> "Which transport request should I release? (e.g. `ER1K900234`)"

## R2 — Confirm with the user (mandatory)

Release is irreversible. Before invoking the VBS, ask:

> "About to release TR `<TR>` via SE01. This is irreversible — once released
> the TR cannot be modified. Proceed? (yes / no)"

Only proceed on explicit `yes`. Anything else → abort.

If `<TR>` matches `sap_dev_transport_request` in settings.json, also warn:

> "Note: this TR is currently your saved default
> (`sap_dev_transport_request`). After release I'll clear that setting so
> the next deploy creates / asks for a new TR."

If the user confirms, plan to call `/update-config` to clear
`sap_dev_transport_request` after a successful release.

## R3 — Verify the TR is in modifiable status

Optionally (recommended) query `E070` via `/sap-se16n` to ensure
`TRSTATUS = 'D'`. If it is already `R` (Released) or `O` (Release started),
report and stop:

> "TR `<TR>` is already `<STATUS>` — nothing to release."

## R4 — Ensure SAP GUI login

Same as Step 2: requires an active SAP GUI session.

## R5 — Run the SE01 release VBS

Template: `./references/sap_se01_release.vbs`. Token: `%%TRANSPORT%%`.

Write `{RUN_TEMP}\sap_se01_release_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se01_release.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%TRANSPORT%%','THE_TR'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se01_release_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se01_release_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\sap_se01_release_run.vbs
```

## R6 — Interpret VBS output

The VBS emits one line per release iteration plus a final `DONE` or
`WARNING` / `ERROR` line.

| Last line | Meaning |
|---|---|
| `DONE: TR <TR> release flow completed.` | Tasks + parent TR released. Verify via `E070-TRSTATUS = R`. |
| `WARNING: Release loop hit max ... iterations` | Indeterminate. Open SE01 manually and check. |
| `ERROR: Release failed at iteration N: [E] <message>` | A release step failed. Common causes: TR has unsaved objects, RDDIMPDP not running, permission missing. Show the SAP message to the user. |

## R7 — Post-release housekeeping

After `DONE`:

1. Verify status via `/sap-se16n E070` filtering `TRKORR EQ <TR>`. Expect
   `TRSTATUS = R`.
2. If R2 noted that the TR was the saved default, run `/update-config` to
   clear `sap_dev_transport_request` (set to empty).
3. Report to the user:

```
Released TR <TR>. Verified E070-TRSTATUS = R.
[sap_dev_transport_request cleared.]
```

## R8 — Component IDs (release flow, for reference)

| Element | ID |
|---|---|
| OK code | `wnd[0]/tbar[0]/okcd` |
| Transport Organizer tab | `wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN` |
| TR input field | `wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/ctxtTRDYSE01SN-TR_TRKORR` |
| Display button | `wnd[0]/usr/tabsMAINTABSTRIP/tabpTSSN/ssubCOMMONSUBSCREEN:RDDM0001:0210/btn%_AUTOTEXT028` (auto-name; falls back to F8) |
| Release Directly | `sendVKey 9` (F9) on `wnd[0]` after focusing a list row |
| Confirmation popup | `wnd[1]` — Enter to confirm |
| Status bar | `wnd[0]/sbar` |
| End-of-flow detector | `wnd[0]/usr/tabsMAINTABSTRIP` re-appears (back on SE01 main) |

The VBS scans `wnd[0]/usr.Children` for the first `GuiLabel` each iteration
instead of using fixed positions like `lbl[24,11]` — those positions in the
recording are list-layout dependent and break when the list reshuffles.

---

# Delete Mode

Use this section when `$ARGUMENTS` starts with `delete` (e.g.
`/sap-se01 delete ER1K900234`). Delete removes the **request object** itself --
NOT release (releasing would transport its objects onward). **Deletion is
irreversible**, and only an **unreleased** request can be deleted.

**Two-phase delete.** SAP will not delete a request that still contains objects
(the request silently survives -- confirmed live on EC2/ERP 2026-06-22). So the
VBS works in two phases:

- **Phase 1 -- empty the request.** For each node (the request + every task) it
  drills in (F2), switches to change mode (`tbar[1]/btn[25]`), opens the Objects
  tab, and if the list is non-empty does Select-All (`btnDB_SELECT_ALL`) +
  Delete (`btnDB_DELETE`) + confirm + Save. This **unassigns** the objects from
  the request -- it does NOT delete the repository objects, which remain in
  their package as orphans (no transport). Every removed entry is echoed.
- **Phase 2 -- delete the now-empty request** (`tbar[1]/btn[13]` + confirm walk).

This mode is the back end for `/sap-dev-clean --reset` Step 3f: by the time it
runs, the dev TR's objects have already been deleted by Steps 3a-3e, so Phase 1
finds an empty list and is a no-op safety net -- nothing is orphaned. Only a
**standalone** `/sap-se01 delete` on a TR that still holds live objects will
orphan them (see D2).

## D0 -- Resolve work directory

Same as Step 0 above: resolve `work_dir`, set `{WORK_TEMP}` and `{RUN_TEMP}`.

## D1 -- Parse the TR

Extract the TR number from `$ARGUMENTS` (the token after `delete`). Validate the
format (`<SID>K<digits>`, e.g. `ER1K900234`). If missing / malformed:

> "Which transport request should I delete? (e.g. `ER1K900234`)"

## D2 -- Inspect contents + confirm (mandatory)

Deletion is irreversible. Show the operator what's inside, then confirm:

1. Read the TR's object list -- `/sap-se16n E071` filtering `TRKORR EQ <TR>`
   (or RFC `RFC_READ_TABLE` on `E071`), one line per object; also read
   `E070-TRSTATUS`.
2. **Refuse a released TR.** If `TRSTATUS` is `R` (Released) or `O` (release
   started), stop: a released request cannot be deleted (only reimported).
3. **Refuse unrelated work.** If E071 holds objects that are NOT sap-dev-init
   artefacts and the caller did not explicitly authorize a full delete, stop
   and surface the list -- do not delete a TR holding the operator's own work.
   This matters more now that delete is two-phase: any object still in the TR
   gets **unassigned** (orphaned in its package, no transport) so the request
   can be dropped. The repository objects are not deleted, but they lose their
   transport record -- which for live work is almost never what the operator
   wants.
4. Ask (mention the unassign consequence whenever `<N>` > 0):
   > "About to DELETE transport request `<TR>` (status `<TRSTATUS>`, `<N>`
   > objects shown above) via SE01. The `<N>` object(s) will first be
   > **unassigned** from the request (orphaned in their package -- not deleted),
   > then the request is dropped. This is irreversible. Proceed? (yes / no)"

Only proceed on explicit `yes`. (When called from `/sap-dev-clean --reset`,
that skill has already shown the E071 list and confirmed -- it may pass the
confirmation through.)

## D3 -- Ensure SAP GUI login

Same as Step 2: requires an active SAP GUI session.

## D4 -- Run the SE01 delete VBS

Template: `./references/sap_se01_delete.vbs`. Token: `%%TRANSPORT%%`.

Write `{RUN_TEMP}\sap_se01_delete_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se01_delete.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%TRANSPORT%%','THE_TR'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se01_delete_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
The VBS derives the shared `sap_delete_popups.vbs` path from the substituted
`%%ATTACH_LIB_VBS%%` directory (same `shared/scripts` folder) -- no extra token.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se01_delete_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\sap_se01_delete_run.vbs
```

## D5 -- Interpret VBS output

Before the verdict the VBS echoes Phase-1 progress -- one
`INFO: Request nodes found: <N>` line, then per node either
`INFO:   node <TR/task>: 0 objects.` or `INFO:   node <task>: <N> object(s)
-- unassigning...` followed by one `INFO:     - <PGMID> <OBJECT> <NAME>` line
per unassigned entry, then `INFO: Phase 1 removed <N> object entr(ies)`. Surface
the unassigned-object lines to the operator -- they are the orphaned objects.

| Last line | Meaning |
|---|---|
| `SUCCESS: Transport request <TR> deleted.` | The request object is gone (the VBS re-displayed it and the request screen no longer opened). Verify authoritatively in D6. |
| `ERROR: Request display did not open ...` | The TR did not exist to begin with (already gone) -- treat as success once the D6 RFC check confirms absence. |
| `ERROR: TR <TR> still exists after delete ...` | Delete did not take (a confirm-popup style the walker didn't match, the TR was actually released, or Phase 1 could not empty a task). Show the SAP sbar line; recheck status and retry, or finish in SE01 manually. |

## D6 -- Verify + housekeeping

1. **RFC-verify** the TR is gone: `RFC_READ_TABLE` on `E070` filtering
   `TRKORR = '<TR>'` -> expect 0 rows. (The VBS's own verify is a
   language-independent `Info.Program` check; this RFC read is authoritative.)
2. Report: `Deleted TR <TR>. Verified E070 row absent.`
3. If the caller is `/sap-dev-clean --reset`, it clears the dev-default TR
   reference (its Step 4). A direct `/sap-se01 delete` does not touch settings.

## D7 -- Component IDs (delete flow, for reference)

| Element | ID |
|---|---|
| TR input field | `.../ssubCOMMONSUBSCREEN:RDDM0001:0210/ctxtTRDYSE01SN-TR_TRKORR` |
| Display button | `.../btn%_AUTOTEXT028` (auto-name) |
| Request-display program | `SAPMSSY0` (screen 120) |
| Node rows (request + tasks) | `wnd[0]/usr` GuiLabels; identified by TR-number pattern (same 4-char prefix + 6 digits as the request), never by column text |
| Drill into a node | focus its label + `sendVKey 2` (F2) -> object editor `SAPLSCTSREQ` screen 100 |
| Change-mode toggle (editor) | `wnd[0]/tbar[1]/btn[25]` |
| Objects tab | `wnd[0]/usr/tabsREQ_TABSTRIP/tabpOBJECTS` |
| Object subscreen base | `.../tabpOBJECTS/ssubSCREEN_HEADER:SAPLSCTS_OLE:0500/` |
| Object count field | `<base>txtDV_OBJECT_COUNT` |
| Select-all / Delete (Phase 1) | `<base>btnDB_SELECT_ALL` / `<base>btnDB_DELETE` |
| Object-delete confirm | `wnd[1]/usr/btnSPOP-OPTION1` / `wnd[1]/tbar[0]/btn[0]` / Enter (cascade) |
| Delete button (Phase 2) | `wnd[0]/tbar[1]/btn[13]` (Shift+F1 -- stable id; alt menu `mbar/menu[0]/menu[5]`) |
| Request-delete confirm popups | handled by the shared `sap_delete_popups.vbs` walker (`btnBUTTON_1` / `btnSPOP-OPTION1` / Enter) |
| Status bar | `wnd[0]/sbar` |

Live-verified 2026-06-22 (two-phase delete, multi-object TRs):
- **EC2/ERP (ECC6 7.31, JA)**: TR `ERPK900035` with 2 domains -> Phase 1
  unassigned both -> Phase 2 deleted -> RFC E070 ROWS=0.
- **S4D (S/4HANA 1909, ZH)**: TR `S4DK941297` with 2 domains -> same flow ->
  request-display re-open verify confirmed gone.
- (Empty-TR path also verified earlier: `ERPK900031`/`ERPK900033` ->
  `btnBUTTON_1` confirm -> RFC E070 ROWS=0.)

---

# Remove-Objects Mode

Use this section when `$ARGUMENTS` starts with `remove-objects` (aliases
`remove-object` / `delobj`), e.g. `/sap-se01 remove-objects ER1K900234
OBJECTS=ZCMD_RFCVAL,ZCMDE_RFCVAL`. This **unassigns object entries (E071) from
an unreleased request and keeps the request alive** — the surgical counterpart
to Delete Mode (which drops the whole request).

**Why this mode exists.** An object recorded in an unreleased request holds a
**name-lock**. When the object's definition is later deleted (e.g. `/sap-se11
delete`) but its `E071` entry lingers in the old request, **re-creating the
object fails** — SAP refuses with "object `<X>` is in request `<TR>`" / "enter
object only in original request". Removing the lingering `E071` entry releases
the lock so the name can be created again. This is the root-cause fix behind the
`/sap-dev-clean` teardown and the `/sap-dev-init` defensive pre-create.

**Removing an E071 entry is NOT a repository delete.** It only unassigns the
object from the request. If the object still exists it becomes a package orphan
(no transport record); if its definition is already gone (the lock-clearing
case) there is nothing to orphan. Releasing the lock is the whole point.

## X0 — Resolve work directory

Same as Step 0 above: resolve `work_dir`, set `{WORK_TEMP}` and `{RUN_TEMP}`.

## X1 — Parse the arguments

- TR = the token after `remove-objects` (validate `<SID>K<digits>`, e.g.
  `ER1K900234`). If missing / malformed:
  > "Which transport request should I remove objects from? (e.g. `ER1K900234`)"
- `OBJECTS=<comma-separated OBJ_NAME list>` — the objects to unassign (matched
  case-insensitively against the `E071` `OBJ_NAME` column). **If omitted, the
  mode removes ALL objects from the request** (Select-All). Callers that want
  surgical removal (`/sap-dev-clean`, `/sap-dev-init`) ALWAYS pass `OBJECTS=`.

## X2 — Inspect + confirm (mandatory)

1. Read the TR's object list — `/sap-se16n E071` filtering `TRKORR EQ <TR>`
   (or RFC `RFC_READ_TABLE` on `E071`), plus `E070-TRSTATUS`.
2. **Refuse a released TR.** If `TRSTATUS` is `R` (Released) or `O` (release
   started), stop — a released request cannot be edited (only reimported). The
   name-lock is already gone for a released TR, so there is nothing to clear.
3. Resolve the effective removal set: intersect `OBJECTS=` with the `E071` rows.
   Show the operator exactly which entries will be unassigned. **If `OBJECTS=`
   was omitted (remove-ALL), spell that out and list every entry** — removing
   all entries from a TR that holds other work would unassign that work too.
4. Confirm:
   > "About to remove `<N>` object entr(ies) from transport request `<TR>`
   > (status `<TRSTATUS>`): `<list>`. This unassigns them from the request
   > (clears their name-lock); it does NOT delete the repository objects. The
   > request `<TR>` itself is kept. Proceed? (yes / no)"

   Only proceed on explicit `yes`. When called from `/sap-dev-clean` /
   `/sap-dev-init`, those skills have already shown the list and confirmed — they
   may pass the confirmation through (each names a bounded `OBJECTS=` set of its
   own dev-init artefacts, never remove-ALL).

## X3 — Ensure SAP GUI login

Same as Step 2: requires an active SAP GUI session.

## X4 — Run the remove-objects VBS

Template: `./references/sap_se01_remove_objects.vbs`. Tokens: `%%TRANSPORT%%`,
`%%OBJECTS%%`.

Write `{RUN_TEMP}\sap_se01_remove_objects_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se01_remove_objects.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%TRANSPORT%%','THE_TR'
$content = $content -replace '%%OBJECTS%%','THE_OBJECTS'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se01_remove_objects_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_TR`, `THE_OBJECTS` (the comma-separated list, or empty for
remove-ALL), and `<SKILL_DIR>` / `{WORK_TEMP}` / `{RUN_TEMP}` with absolute
values. **Pass `OBJECTS=` from every automated caller** — leave `THE_OBJECTS`
empty only for a deliberate operator-confirmed remove-ALL.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se01_remove_objects_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\sap_se01_remove_objects_run.vbs
```

## X5 — Interpret VBS output

The VBS echoes one `INFO: Request nodes found: <N>` line, then per node either
`INFO:   node <TR/task>: 0 objects.` / `... none of the named objects present.`
or `INFO:   node <task>: removing <N> matched object(s)...` followed by one
`INFO:     - <PGMID> <OBJECT> <OBJ_NAME>` line per removed entry.

| Last line | Meaning |
|---|---|
| `SUCCESS: Removed <N> object entr(ies) from <TR>.` | `<N>` entries unassigned. Verify in X6. `<N>` = 0 with a "(none of the named objects were in the request)" tail means the lock was already clear — that is a clean success for the lock-clearing use case. |
| `ERROR: Request display did not open ...` | The TR did not exist (already gone). For the lock-clearing use case treat as success once X6 confirms `E071` has no row. |
| `ERROR: TRANSPORT is empty ...` | The `%%TRANSPORT%%` token was not substituted. Re-generate the VBS. |

## X6 — Verify + report

1. **RFC-verify** the named objects are gone from the TR: `RFC_READ_TABLE` on
   `E071` filtering `TRKORR = '<TR>'` (or `/sap-se16n E071`). Each removed
   `OBJ_NAME` should no longer appear under that `TRKORR`. (The request header
   `E070` row still exists — that is intended; only the object entries were
   removed.)
2. Report:
   ```
   Removed <N> object entr(ies) from <TR> (request kept).
   Verified E071 no longer lists: <objects>.
   ```
3. Persistence: this mode never touches settings — the caller decides.

## X7 — Component IDs (remove-objects flow, for reference)

| Element | ID |
|---|---|
| TR input field | `.../ssubCOMMONSUBSCREEN:RDDM0001:0210/ctxtTRDYSE01SN-TR_TRKORR` |
| Display button | `.../btn%_AUTOTEXT028` (auto-name) |
| Request-display program | `SAPMSSY0` |
| Object editor program | `SAPLSCTSREQ` |
| Node rows (request + tasks) | `wnd[0]/usr` GuiLabels; identified by TR-number pattern, never column text |
| Drill into a node | focus its label + `sendVKey 2` (F2) |
| Change-mode toggle (editor) | `wnd[0]/tbar[1]/btn[25]` |
| Objects tab | `wnd[0]/usr/tabsREQ_TABSTRIP/tabpOBJECTS` |
| Object subscreen base | `.../tabpOBJECTS/ssubSCREEN_HEADER:SAPLSCTS_OLE:0500/` |
| Object count field | `<base>txtDV_OBJECT_COUNT` |
| Object table control | `<base>tblSAPLSCTS_OLETC_OLE` (cells `ctxtTRE071X-PGMID[1,r]` / `ctxtTRE071X-OBJECT[2,r]` / `txtTRE071X-OBJ_NAME[3,r]`) |
| Select-all (remove-ALL path) | `<base>btnDB_SELECT_ALL` |
| Targeted row select | `<table>.GetAbsoluteRow(i).Selected = True` (scroll via `<table>.VerticalScrollbar.Position`) |
| Delete selected | `<base>btnDB_DELETE` |
| Object-delete confirm | `wnd[1]/usr/btnSPOP-OPTION1` / `btnBUTTON_1` / `tbar[0]/btn[0]` / Enter (cascade) |
| Save (commit unassign) | `sendVKey 11` |

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se01_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se01_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `TR_CREATE_FAILED`, `GUI_TIMEOUT`.

---

## Component IDs (for reference)

| Element | ID |
|---|---|
| OK code field | `wnd[0]/tbar[0]/okcd` |
| Create button (F6) | `wnd[0]/tbar[1]/btn[6]` |
| Workbench radio | `wnd[1]/usr/radKO042-REQ_CONS_K` |
| Customizing radio | `wnd[1]/usr/radKO042-REQ_CUST_W` |
| Confirm | `wnd[1]/tbar[0]/btn[0]` |
| Description field | `wnd[1]/usr/txtKO013-AS4TEXT` |
| Status bar | `wnd[0]/sbar` |

---

## E070 Field Reference (Transport Request Header)

| Field | Meaning |
|---|---|
| `TRKORR` | Transport request number (e.g. `S4DK900123`) |
| `TRFUNCTION` | `K` Workbench, `W` Customizing, `T` Task / Repair, `S` Development task |
| `TRSTATUS` | `D` Modifiable, `L` Locked, `O` Released started, `R` Released |
| `AS4USER` | Owner |
| `AS4DATE` | Last-changed date (`YYYYMMDD`) |
| `AS4TIME` | Last-changed time (`HHMMSS`) |
| `STRKORR` | Parent request (empty for top-level requests, populated for tasks) |
| `AS4TEXT` | Short description |

---

## Limitations

- The VBS does not handle the "Tasks owner" follow-up popup, which only appears
  on certain customising configurations. If the test target has it, extend the
  VBS to dismiss `wnd[1]` before backing out.
- `NB` (not between) on AS4TIME is not used here; we use `BT`.
