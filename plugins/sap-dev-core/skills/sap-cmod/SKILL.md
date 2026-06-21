---
name: sap-cmod
description: |
  Manages the full lifecycle of SAP Enhancement Projects (classic
  modifications) via CMOD using SAP GUI Scripting, plus read-only RFC
  lookups. Operations: check / status, create, change short text,
  activate, deactivate, delete the project; add and remove SAP enhancement
  assignments (position-aware — finds the right row by value, never a fixed
  index); change the project's package (delegates to /sap-change-package);
  and route "edit an enhancement component" to the correct workbench skill
  by component type (E function exit -> /sap-se38, S screen -> /sap-se51,
  T table -> /sap-se11, C GUI code -> /sap-se41).
  Prerequisites: Active SAP GUI session (use /sap-login first); SAP NCo 3.1
  (32-bit, .NET 4.0) in GAC for the RFC lookups.
argument-hint: "<operation> <project> [enhancements | short-text | package]"
---

# SAP CMOD Enhancement Project Skill

You manage SAP Enhancement Projects (transaction CMOD) end to end. Project
metadata is read read-only via RFC (`MODATTR` / `MODACT` / `MODSAP` /
`MODTEXT` / `TADIR`); every mutation is driven through SAP GUI Scripting.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules (no direct SQL writes on standard tables; no unsolicited deploys) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution — this skill delegates to `/sap-transport-request`; never asks for a TR itself |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI scripting works under any logon language — identify by component ID + DDIC field name, status via `MessageType` (S/W/E/I/A), VKey not menu-text, no branching on `.Text`/titles |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_attach_lib.vbs` | Session-attach primitive — token `%%ATTACH_LIB_VBS%%` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_session_lock.vbs` | Session-lock for the write critical section — token `%%SESSION_LOCK_VBS%%` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | RFC connect/read helpers — dot-sourced by `references/sap_cmod_query.ps1` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_connection_lib.ps1` | `Get-SapCurrentSessionPath` for the session-attach env var |

The reads touch only SAP-standard tables via `RFC_READ_TABLE` (SELECT only) —
allowed under `skill_operating_rules.md`. All mutations go through CMOD's own
SAP-supplied dialogs (never raw SQL).

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge
per-key on `.value` (env var → `settings.local.json` → `userconfig.json` →
`settings.json`); non-per-connection writes go to `userconfig.json`. Resolve
sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then
read `custom_url`, `way_to_get_transport_request`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` / `*_run.vbs`) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_cmod_run.json" -Skill sap-cmod -ParamsJson "{\"project\":\"<PROJECT>\",\"op\":\"<OPERATION>\"}"
```

---

## Step 1 — Determine the Operation

Pick **one** operation from the user's request. CMOD project names are
**max 8 characters** (Z-namespace). Enhancement names are SMOD enhancements
(e.g. `CNEX0001`).

| Operation | Trigger phrases | Flow |
|---|---|---|
| **check / status** | "check CMOD project X", "does X exist", "is X active", "what enhancements are on X" | Step 3 (RFC only) |
| **create** | "create CMOD project X", "create enhancement project X [with CNEX0001\|CNEX0002]" | Step 4 (+ Step 5 if enhancements given) |
| **add assignments** | "assign CNEX0001 to X", "add enhancements … to X" | Step 5 |
| **remove assignments** | "remove CNEX0002 from X", "unassign … from X" | Step 6 |
| **change description** | "change description / short text of X to '…'" | Step 7 |
| **activate** | "activate CMOD project X" | Step 8 |
| **deactivate** | "deactivate CMOD project X" | Step 9 |
| **delete project** | "delete / drop CMOD project X" | Step 10 (**irreversible — confirm first**) |
| **change package** | "change package of X to ZPKG", "move X to package …" | Step 11 (delegates to `/sap-change-package`) |
| **edit component** | "edit / change the function exit / screen / table / GUI of enhancement E (on X)" | Step 12 (routes to the right workbench skill) |

Always run **Step 3 (check)** first for any write operation — it tells you
whether the project exists, its `STATUS`, its `DEVCLASS` (package), and its
current assignments. This drives TR resolution and position-aware editing.

---

## Step 2 — Ensure SAP GUI Login

Mutations need an active SAP GUI session; the RFC reads need NCo 3.1. If not
logged in, run `/sap-login` first, then return.

---

## Step T — Resolve a Transport Request (only for transportable projects)

A write operation needs a TR **only when the project's package is
transportable** (`DEVCLASS` does NOT start with `$`). For `$TMP`/local
projects, leave `%%TRANSPORT%%` empty — no popup appears.

When a TR is needed, **delegate to `/sap-transport-request`** (never ask the
user directly, never call `/sap-se01`):

```
/sap-transport-request OBJECT_TYPE=CMOD OBJECT_DESCRIPTION=<PROJECT>
```

Use the returned modifiable TRKORR as the `%%TRANSPORT%%` token. See
`tr_resolution.md`.

---

## Running a reference VBS (shared wrapper)

Every GUI operation uses the same token-substitution + execute pattern. Write
`{RUN_TEMP}\<TEMPLATE>_run.ps1`, then run it, then run the generated `.vbs`
with **32-bit** cscript.

```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\<TEMPLATE>.vbs', [System.Text.Encoding]::UTF8)
# --- mode-specific tokens (see each step) ---
$content = $content -replace '%%PROJECT_NAME%%','THE_PROJECT'
# ... e.g. %%ENHANCEMENTS%% / %%SHORT_TEXT%% / %%PACKAGE%% / %%TRANSPORT%% ...
# --- session-attach plumbing (always) ---
$content = $content -replace '%%SESSION_PATH%%', ''
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\<TEMPLATE>_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\<TEMPLATE>_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\<TEMPLATE>_run.vbs
```

> **Encoding:** always `-Encoding Unicode` (UTF-16 LE) — what `cscript`
> compiles natively. UTF-8-BOM causes a compile error.
> **32-bit cscript:** use `C:/Windows/SysWOW64/cscript.exe`; bare `cscript`
> can pick the 64-bit binary, which cannot bind the SAP GUI Scripting COM.

Each VBS prints `INFO:` progress, then `STATUS_TYPE: <S|W|E|I|A>` +
`STATUS_TEXT: <text>`, then a final `SUCCESS: …` or `ERROR: …` line. Parse the
final line.

---

## Step 3 — Check / Status (RFC, read-only)

Run the query helper with **32-bit PowerShell** (NCo is 32-bit). Connection
params resolve from `runtime/connections.json` automatically when omitted:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cmod_query.ps1" -Project <PROJECT> -Action check
```

Parse the output lines:
- `EXISTS: YES|NO` — project header present in `MODATTR`.
- `STATUS: A` + `STATUS_LABEL: ACTIVE|INACTIVE` — `A` = activated.
- `DEVCLASS: <pkg>` — `$TMP` = local; else transportable (drives Step T).
- `SHORTTEXT[<lang>]: <text>` — short text per language (`MODTEXT`).
- `ASSIGNMENT: <enh>` (one per line) + `COUNT: <n>` — assigned enhancements (`MODACT`).
- `TADIR_ORPHAN: <pkg>` (only when `EXISTS: NO`) — a leftover directory entry
  from a prior delete. Warn the user: a fresh create may re-attach to `<pkg>`.

Other actions: `-Action status` (MODATTR only), `-Action assignments`
(MODACT), `-Action components -Enhancement <ENH>` (MODSAP — used by Step 12),
`-Action exit-include -Fm <EXIT_FM>` (resolves a function exit's customer
include from the FM source — used by Step 12 `E`-type routing),
`-Action find-project -Enhancement <ENH>` (reverse MODACT lookup → the CMOD
project(s) the enhancement is assigned to + each project's active status — used
by Step 12 to activate the enclosing project after editing a component).

---

## Step 4 — Create Project

Template: `sap_cmod_create.vbs`. Tokens:

| Token | Value |
|---|---|
| `%%PROJECT_NAME%%` | project (UPPERCASE, ≤8) |
| `%%SHORT_TEXT%%` | short description |
| `%%PACKAGE%%` | target package; blank or `$*` → Local object (`$TMP`) |
| `%%TRANSPORT%%` | TR from Step T (only when `%%PACKAGE%%` is transportable) |

This creates the project **header + short text** only. If the user also asked
to assign enhancements, **chain Step 5** (add assignments) afterwards — the
assign path is shared and position-aware. After create+assign the project is
inactive; chain **Step 8** if the user wants it active.

Pre-check (Step 3): if `EXISTS: YES`, do not create — report it. If
`TADIR_ORPHAN` is present, warn before creating.

---

## Step 5 — Add Enhancement Assignments (position-aware)

Template: `sap_cmod_add_assignments.vbs`. Tokens: `%%PROJECT_NAME%%`,
`%%ENHANCEMENTS%%` (pipe-separated, e.g. `CNEX0001|CNEX0002`), `%%TRANSPORT%%`
(Step T if transportable).

The VBS scans the `EXITNAME` rows, **skips enhancements already assigned**,
and writes new ones into the **first empty row** — never a hardcoded index.
On success the project is left inactive (re-activate via Step 8 if desired).
Verify with Step 3 `-Action assignments`.

---

## Step 6 — Remove Enhancement Assignments (position-aware)

Template: `sap_cmod_delete_assignments.vbs`. Tokens: `%%PROJECT_NAME%%`,
`%%ENHANCEMENTS%%`, `%%TRANSPORT%%`.

The VBS **matches each target enhancement by value** across the rows, deletes
that row (Delete row / Ctrl+F9), and re-scans from the top for the next target
(rows shift up after each deletion). Enhancements not currently assigned are
skipped with a `WARN`. Verify with Step 3.

---

## Step 7 — Change Short Text

Template: `sap_cmod_change_description.vbs`. Tokens: `%%PROJECT_NAME%%`,
`%%SHORT_TEXT%%`, `%%TRANSPORT%%` (Step T if transportable). Verify by
re-reading `SHORTTEXT[…]` via Step 3.

---

## Step 8 — Activate Project

Template: `sap_cmod_activate.vbs`. Token: `%%PROJECT_NAME%%`. Verify
`STATUS_LABEL: ACTIVE` via Step 3 `-Action status`.

---

## Step 9 — Deactivate Project

Template: `sap_cmod_deactivate.vbs`. Token: `%%PROJECT_NAME%%`. Verify
`STATUS_LABEL: INACTIVE` via Step 3.

---

## Step 10 — Delete Project (irreversible)

**Confirm with the user first** — show the project name, package
(`DEVCLASS`), and assignment list from Step 3. Only proceed on explicit yes.

Template: `sap_cmod_delete.vbs`. Tokens: `%%PROJECT_NAME%%`, `%%TRANSPORT%%`
(Step T if transportable). The VBS presses Delete, confirms the popup
(`btnSPOP-OPTION1` = Yes), and handles the post-delete TR popup. Verify with
Step 3 (`EXISTS: NO`).

> Note: deleting a CMOD project can leave a `TADIR` directory-entry orphan
> (the `MODATTR`/`MODACT` rows go but the `R3TR CMOD` TADIR row may linger).
> Step 3 reports it as `TADIR_ORPHAN`. To fully clear it, move the orphan to
> `$TMP` (Step 11) or remove the TADIR entry via the standard tooling.

---

## Step 11 — Change Package (delegate)

CMOD enhancement projects are `R3TR CMOD <project>` in `TADIR`. Package
changes are handled by **`/sap-change-package`** (which now has a `CMOD`
route):

```
/sap-change-package CMOD <PROJECT> <NEW_PACKAGE>
```

That skill reads the current `DEVCLASS`, decides the locality flow
(`$TMP`→transport needs a TR via `/sap-transport-request`; transport→transport
checks the object isn't locked to a modifiable TR; →`$TMP` confirms and presses
Local object), drives CMOD's *Goto > Object Directory Entry* dialog, and
verifies via a `TADIR` re-query. Surface its `DONE` / `ERROR:` result.

---

## Step 12 — Edit an Enhancement Component (routing)

Enhancements are made of components. To edit one, look the components up in
`MODSAP` and route by **component type (`TYP`)** to the right workbench skill.

> This step is also the **delegation target from `/sap-check-fix`**: when that
> router sees an enhancement-component name (`EXIT_SAP*` FM, `ZX*` include,
> `CI_*` structure, or a `SAPLX*` screen) it resolves the owning enhancement
> (via `sap_cmod_query.ps1 -Action find-enhancement`) and hands the specific
> component here. In that case you edit **just that one component** in
> **check-and-fix mode** (no new source → the workbench skill runs its own
> check/fix/activate flow), then do step 3 below (activate the project).

1. **Find the enhancement(s).** If the user names an enhancement, use it. If a
   specific component object was given (from `/sap-check-fix`), resolve its
   enhancement with `-Action find-enhancement -Component <obj> [-Dynpro <n>]`
   and edit only that component. Otherwise list the project's assignments
   (Step 3 `-Action assignments`), then read components for the chosen
   enhancement:
   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cmod_query.ps1" -Enhancement <ENH> -Action components
   ```
   Output is `COMPONENT: <TYP>|<MEMBER>` per row.

2. **Route by `TYP`:**

   | TYP | Component | `MEMBER` example | How to edit |
   |---|---|---|---|
   | `E` | Function exit | `EXIT_SAPLCJWB_004` | Resolve the customer include with the helper (below), then `/sap-se38` to create/update it. |
   | `S` | Screen (dynpro) | `SAPLCJWB0215_CUSTSCR1_SAPLXCN10700` | Split `MEMBER` on `_CUSTSCR1_`. In the right token, the **last 4 chars = dynpro number**, the **rest = target program**. Example → program `SAPLXCN1`, dynpro `0700`. Call `/sap-se51 <program> <dynpro>`. |
   | `T` | Table / structure | append/`CI_` enhancement | Call `/sap-se11` on the target table or structure. |
   | `C` | GUI code (CUA) | `SAPLCJGR+CUE` | Split `MEMBER` on `+`; the left token is the target program (e.g. `SAPLCJGR`). Call `/sap-se41` for that program's GUI status/menu. |

   **`E` function exits — resolve the include automatically (do NOT guess it).**
   The customer include is named after the function **pool** + a sequence
   number, **not** after the FM. Verified live: `EXIT_SAPLCJWB_004` and
   `EXIT_SAPLCJWB_005` both live in pool `XCN1` yet use `ZXCN1U21` and
   `ZXCN1U22`. So the include cannot be derived from the FM name — it must be
   read from the FM source. The helper does this for you:

   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cmod_query.ps1" -Action exit-include -Fm <EXIT_FM>
   ```

   It reads the `SOURCE` table of `RPY_FUNCTIONMODULE_READ_NEW` and prints:
   - `CUSTOMER_INCLUDE: <ZXxxxUnn>` — the include to edit,
   - `INCLUDE_EXISTS: YES|NO` and `SE38_MODE: create|update`,
   - `FUNCTION_POOL` / `SHORT_TEXT` for context.

   Then call `/sap-se38 <CUSTOMER_INCLUDE>` with the exit body source (the
   include body is just the statements that go between `FUNCTION`/`ENDFUNCTION`
   — e.g. `WRITE / SAP_PRPS_IMP-POSID.`). Two gotchas, both verified live:
   - **`INCLUDE_EXISTS: NO` (create):** SE38 creates it as program **type `I`
     (Include)** and raises a soft **Warning** "Program names ZX... are reserved
     for includes of exit function groups". This is not an error — `/sap-se38`
     presses **Enter** to acknowledge and continues (handled by
     `sap_se38_create.vbs`). It prompts for package/TR per `/sap-transport-request`.
   - **Source paste needs SAP GUI in the foreground.** `/sap-se38` uploads
     source via clipboard + SendKeys (the AbapEditor's `.Text` is read-only and
     the Utilities→Upload menu is a non-scriptable native dialog), so the SAP
     GUI window must be the OS-foreground window. If it is not, the foreground
     guard aborts the paste safely — focus the SAP GUI window and re-run. Do
     **not** hand-manipulate the editor (`insertText`) as a workaround.
   - **`INCLUDE_EXISTS: YES` (update):** `/sap-se38` update flow uploads the new
     body. **Pass program type `I`** so SE38 does NOT try to run the include
     (includes are not executable — the F8 run-test would false-fail on
     screen 101). Verify activation via RFC `PROGDIR.STATE = 'A'`.

3. **Activate the enclosing CMOD project — the exit only runs when its project
   is active.** Activating the include/component is **not** enough: a function
   exit fires at runtime only while the SMOD enhancement's CMOD project is
   active, and re-activating the project after a component change makes the
   enhancement framework pick it up (re-activating an already-active project is
   safe). Resolve which project(s) the enhancement belongs to:

   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cmod_query.ps1" -Action find-project -Enhancement <ENH>
   ```

   For each `PROJECT: <name>|<status>|<label>` returned, run **Step 8**
   (`/sap-cmod activate <name>`) and confirm `STATUS_LABEL: ACTIVE` via Step 3.
   If `COUNT: 0`, the enhancement isn't assigned to any project yet — assign it
   first (Step 5), then activate.

> Worked example (enhancement `CNEX0007`, verified live 2026-05-29):
> `C|SAPLCJGR+CUE` → `/sap-se41 SAPLCJGR`;
> `E|EXIT_SAPLCJWB_004` → helper resolves `ZXCN1U21` → `/sap-se38` (type `I`) create/update with the exit body;
> `S|SAPLCJWB0215_CUSTSCR1_SAPLXCN10700` → `/sap-se51 SAPLXCN1 0700`;
> then `find-project CNEX0007` → `ZHKPJ002` → `/sap-cmod activate ZHKPJ002` so the exit actually runs.

---

## Step 13 — Report

On success: state exactly what changed (created / assigned / removed / short
text / activated / deactivated / deleted / package moved), show the VBS
output (or RFC verification) as a code block, and the post-change Step 3
verification.

On failure: show the full output and diagnose:

| Symptom | Cause | Fix |
|---|---|---|
| `Did not reach the Attributes screen` | Project already exists (create) or Create button id differs | Run Step 3 first; re-pin `btn%#AUTOTEXT001` via `/sap-gui-object-details` |
| `Did not reach the enhancement-assignment screen` | Project does not exist, or `radMODF-CHAK`/`btnPAEND` differs | Verify with Step 3; re-record initial-screen ids |
| `No empty row … grid full` | >17 enhancements (needs scroll) | Edit assignments manually, or extend the VBS to page down |
| `SAP prompted for a transport request but TRANSPORT is empty` | Transportable project, no TR resolved | Run Step T (`/sap-transport-request`) and re-run |
| `Could not send Activate` / `btn[28]` not found | Activate/Deactivate id differs by release | Re-pin via `/sap-gui-object-details` |
| Enhancement validation `[E]` | Invalid enhancement name | Verify it exists in SMOD |

When a screen flow does not match (unexpected popup, control not found), use
`/sap-gui-object-details` (structural) and `/sap-gui-diagnose` (visual) on the
live session to discover the actual ids, then update the template.

---

## Step 14 — Clean Up

```bash
cmd /c del {RUN_TEMP}\sap_cmod_*_run.vbs & del {RUN_TEMP}\sap_cmod_*_run.ps1
```

---

## Final — Log End

On success:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_cmod_run.json" -Status SUCCESS -ExitCode 0
```
On failure (substitute `<CLASS>` + short message):
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_cmod_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```
Suggested `<CLASS>`: `CMOD_FAILED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`, `RFC_FAILED`.

---

## CMOD Tables (RFC, confirmed S/4HANA 1909 — 2026-05-29)

| Table | Key | Fields used |
|---|---|---|
| `MODATTR` | `NAME` (project, C8) | `STATUS` (`A`=active, ` `=inactive) |
| `MODACT` | `NAME` (project) | `MEMBER` (assigned enhancement; a blank-MEMBER header row also exists — ignore it) |
| `MODSAP` | `NAME` (enhancement) | `TYP` (E/S/T/C), `MEMBER` (component) |
| `MODTEXT` | `NAME` + `SPRSL` | `MODTEXT` (short text per language) |
| `TADIR` | `PGMID=R3TR OBJECT=CMOD OBJ_NAME=<project>` | `DEVCLASS` (package) |

---

## Component IDs Reference (SAP GUI 7.60 / S/4HANA 1909)

**CMOD initial screen** (`SAPMSMOD`)

| Element | Component ID |
|---|---|
| Project name | `wnd[0]/usr/ctxtMOD0-NAME` |
| Sub-object radios | `radMODF-HEAD` (Attributes), `radMODF-CHAK` (Enhancement assignments) |
| Display / Change / Create | `btnPANZ` / `btnPAEND` / `btn%#AUTOTEXT001` |
| Activate / Deactivate / Delete | `sendVKey 27` / `tbar[1]/btn[28]` / `tbar[1]/btn[14]` |
| Delete confirm (Yes) | `wnd[1]/usr/btnSPOP-OPTION1` |

**Attributes screen**: short text `wnd[0]/usr/txtMOD0-MODTEXT`.

**Enhancement assignment screen** (`SAPLSMOD` / 0100)

| Element | Component ID |
|---|---|
| Enhancement name, row *i* | `wnd[0]/usr/sub:SAPLSMOD:0100/ctxtMOD0-EXITNAME[i,0]` |
| Enhancement text, row *i* | `wnd[0]/usr/sub:SAPLSMOD:0100/txtMOD0-MEMTEXT[i,14]` |
| Delete row (Ctrl+F9) | `wnd[0]/tbar[1]/btn[33]` |
| Visible rows | `i = 0 … 16` |

**Package / TR popups**: create dialog Local object `wnd[1]/tbar[0]/btn[7]`,
package field `ctxtTADIR-DEVCLASS`; TR popup field `ctxtKO008-TRKORR`.
(Package *change* uses `/sap-change-package`'s KO007 dialog — see that skill.)

---

## Known Issues / Failure Modes

> Behaviours below were verified live on S/4HANA 1909 (SAP GUI 7.60), 2026-05-29.

- **CMOD project names are max 8 characters.** `MODATTR-NAME` (and the
  `MOD0-NAME` field) is `CHAR8` — a longer name is not a valid project.
  Validate the name length before create; do not pass 9–10 char names.
- **Some CMOD operations post no status-bar message** — notably the package
  move (Step 11) and the delete (Step 10) leave the status bar blank. The
  scripts treat a non-`E`/`A` status as success, so the **RFC re-query in
  Step 3 is the authoritative success gate** — always confirm the outcome
  there (`EXISTS`, `STATUS`, `DEVCLASS`, assignment list), never by sbar text.
- **TADIR orphan after delete** — deleting a project removes its
  `MODATTR`/`MODACT` rows but the `R3TR CMOD <project>` directory entry in
  `TADIR` can linger (observed on both `$TMP` and transportable projects).
  Step 3 reports it as `TADIR_ORPHAN: <pkg>`; warn the user, because a later
  re-create may silently re-attach to that stale package. To clear it, move
  the orphan to `$TMP` (Step 11) or remove the directory entry via standard
  tooling.
- **Session attach error** "explicit session path not found" / "SAPDEV_SESSION_PATH
  … doesn't resolve" / "cannot pick one safely" — the AI-session pin in
  `session_registry.json` is stale (e.g. it points at `ses[0]` while the live
  session is `ses[1]`). **Run `/sap-login` to re-pin the connection**, then
  retry. (Shared session infrastructure — affects all GUI skills, not just CMOD.)
- **Create button id** `btn%#AUTOTEXT001` is auto-generated and can differ by
  release; the VBS errors clearly if it's not found — re-pin with
  `/sap-gui-object-details`.
- **Adding/removing assignments deactivates the project** — re-run Step 8 to
  re-activate if the enhancement should be live.
- **>17 assigned enhancements** would need grid scrolling; the position-aware
  scripts cover the visible 17 rows and error out otherwise.
- **Activate of a project whose exits have no code** still activates the
  *project* (`STATUS=A`); coding the components is a separate Step 12 task.
- **A function exit's customer include is NOT derivable from the FM name** —
  it's named after the function pool + a sequence (e.g. `EXIT_SAPLCJWB_004`
  and `EXIT_SAPLCJWB_005` both in pool `XCN1` → `ZXCN1U21` / `ZXCN1U22`).
  Always resolve it from the FM source via `-Action exit-include` (Step 12);
  never guess from the FM name. The include often doesn't exist until the
  exit is first implemented, so `/sap-se38` runs in **create** mode.
