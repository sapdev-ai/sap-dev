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
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "[create [W|C] [\"<desc>\"]] | [release <TR>]"
---

# SAP SE01 — Transport Request Management Skill

You manage SAP transport requests via SE01 using SAP GUI Scripting. Two modes:
**CREATE** (default) and **RELEASE**.

Task: $ARGUMENTS

## Mode dispatch

Look at `$ARGUMENTS` to pick the mode:

| First token (case-insensitive) | Mode | Skip to |
|---|---|---|
| `release` followed by a TR (e.g. `release ER1K900234`) | RELEASE | "Release Mode" section below |
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

---

## Step 0 — Resolve Work Directory and Settings

Read sap-dev-core's settings.json (go 2 levels up from `<SKILL_DIR>` to the
plugin root, then `settings.json`). Read:

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

The logged-in SAP user (`sap_user`) is needed for the E070 lookup. If blank,
ask the user.

This skill MUST honour
`<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for description and type
defaults.

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_se01_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se01_run.json" -Skill sap-se01 -ParamsJson "{\"description\":\"<DESC>\",\"request_type\":\"W\"}"
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

Write `{WORK_TEMP}\sap_se01_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se01_create.vbs' -Raw
$content = $content -replace '%%REQUEST_TYPE%%','THE_TYPE'
$content = $content -replace '%%DESCRIPTION%%','THE_DESC'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
Set-Content '{WORK_TEMP}\sap_se01_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_TYPE` (W or C), `THE_DESC` (short text), and `<SKILL_DIR>` /
`{WORK_TEMP}` with absolute paths.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se01_create_run.ps1"
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo {WORK_TEMP}\sap_se01_create_run.vbs
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
   - AS4DATE row → workstation today as `YYYY.MM.DD`
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

Same as Step 0 above: read `work_dir`, set `{WORK_TEMP}`, ensure it exists.

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

Write `{WORK_TEMP}\sap_se01_release_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se01_release.vbs' -Raw
$content = $content -replace '%%TRANSPORT%%','THE_TR'
Set-Content '{WORK_TEMP}\sap_se01_release_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se01_release_run.ps1"
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo {WORK_TEMP}\sap_se01_release_run.vbs
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

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se01_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se01_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
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
