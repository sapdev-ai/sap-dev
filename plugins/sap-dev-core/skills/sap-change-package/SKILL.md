---
name: sap-change-package
description: |
  Changes the package (TADIR-DEVCLASS) assignment of an SAP repository object
  via the "Object Directory Entry" dialog (Goto > Object Directory Entry).
  Routes by object type to SE38 / SE37 / SE24 / SE11 / SE91 / CMOD (the last
  for enhancement projects — used by /sap-cmod). Handles three
  flows automatically based on current vs new package locality:
    (a) $TMP → transportable (Z*/Y*): resolves a modifiable TR via
        /sap-transport-request, then enters the new package + TR.
    (b) transportable A → transportable B: pre-checks E071/E070 to ensure
        the object is NOT linked to a modifiable TR (would block the move).
    (c) transportable → $TMP: confirms the move and presses "Local object".
  Verifies via TADIR re-query.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<OBJECT_TYPE> <OBJECT_NAME> <NEW_PACKAGE>"
---

# SAP Change Package Skill

You change the package assignment (`TADIR-DEVCLASS`) of an SAP repository
object via the standard "Object Directory Entry" dialog.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution policy — used when moving from `$TMP` to a transportable package |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `work_dir` and `sap_user`.

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{WORK_TEMP}\sap_change_package_run.json`) so subsequent steps and the
final log-end call append to the same run. Best-effort: silently no-ops
if `userConfig.log_enabled=false` or the lib can't load.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_change_package_run.json" -Skill sap-change-package -ParamsJson "{\"object_type\":\"<OBJECT_TYPE>\",\"object_name\":\"<OBJECT_NAME>\",\"new_package\":\"<NEW_PACKAGE>\"}"
```

---

## Step 1 — Parse Arguments

Required:

| Arg | Description | Example |
|---|---|---|
| `OBJECT_TYPE` | Object type (see routing table below) | `REPORT` |
| `OBJECT_NAME` | Object name | `ZHKTEST003` |
| `NEW_PACKAGE` | Target package — `$TMP` (or any `$*`) for local, `Z*` / `Y*` for transportable | `ZHKA011` |

If any argument is missing, ask:

> Provide `<OBJECT_TYPE> <OBJECT_NAME> <NEW_PACKAGE>` (e.g. `REPORT ZHKTEST003 ZHKA011`).

### Object type → transaction routing

| OBJECT_TYPE | Transaction | TADIR `OBJECT` |
|---|---|---|
| `REPORT` / `PROGRAM` / `FUGR` | SE38 | `PROG` / `FUGR` |
| `FM` (function module) | SE37 | `FUNC` |
| `CLASS` / `INTERFACE` | SE24 | `CLAS` / `INTF` |
| `TABLE` / `VIEW` / `DTEL` / `STRUCTURE` / `TABLETYPE` / `TYPEGROUP` / `DOMAIN` / `SEARCHHELP` / `LOCKOBJECT` | SE11 | matching DDIC type |
| `MSGCLASS` (message class) | SE91 | `MSAG` |
| `CMOD` / `ENHANCEMENTPROJECT` / `ENHPROJ` (enhancement project) | CMOD | `CMOD` |

---

## Step 2 — Read Current Package from TADIR

Query `TADIR` via `/sap-se16n`:

```
SELECT
PGMID
OBJECT
OBJ_NAME
DEVCLASS
FILTER
PGMID	EQ	R3TR
OBJECT	EQ	<TADIR_OBJECT_FROM_TABLE>
OBJ_NAME	EQ	<OBJECT_NAME>
```

Capture the row's `DEVCLASS` as `CURRENT_PACKAGE`. If TADIR has no row → the
object does not exist in the system; report and stop.

**Short-circuit:** if `CURRENT_PACKAGE = NEW_PACKAGE` (case-insensitive),
nothing to do — report "already in package <X>" and stop.

---

## Step 3 — Decide the Flow

Pick a `MODE` from the locality of `CURRENT_PACKAGE` and `NEW_PACKAGE`.
A package is **local** if it starts with `$` (e.g. `$TMP`, `$VOL`); otherwise
**transportable** (Z*/Y*/customer namespace).

| CURRENT | NEW | MODE | Notes |
|---|---|---|---|
| `$*` | `Z*` / `Y*` | `TMP_TO_TRANSPORT` | Need a modifiable TR. |
| `Z*` / `Y*` | `Z*` / `Y*` | `TRANSPORT_TO_TRANSPORT` | Object MUST NOT be on a modifiable TR (else SAP refuses with an Error popup: `Object directory entry R3TR <OBJ> <NAME> locked for request/task <TR>`). |
| `Z*` / `Y*` | `$*` | `TRANSPORT_TO_LOCAL` | Confirm popup + "Local object" button. **Object MUST NOT be on a modifiable TR** — SAP refuses the move with the same lock Error popup as `TRANSPORT_TO_TRANSPORT`. The previously-linked TR record itself is unaffected. |
| `$*` | `$*` | `LOCAL_TO_LOCAL` | Just enter new $* package + Enter. No TR. |

---

## Step 4 — Pre-checks per Mode

### `TRANSPORT_TO_TRANSPORT` and `TRANSPORT_TO_LOCAL`

Both modes require the object to NOT be linked to a modifiable task/TR.
Query `E071` via `/sap-se16n` to check if the object is currently in any
**open** task / TR:

```
SELECT
TRKORR
PGMID
OBJECT
OBJ_NAME
FILTER
PGMID	EQ	R3TR
OBJECT	EQ	<TADIR_OBJECT>
OBJ_NAME	EQ	<OBJECT_NAME>
```

For each `TRKORR` returned, query `E070` for `TRSTATUS`:

```
SELECT
TRKORR
TRFUNCTION
TRSTATUS
FILTER
TRKORR	EQ	<each-TR-from-E071>
```

If any `TRSTATUS = D` (Modifiable) **or** `L` (Locked, in test) — the move
will fail. Tell the user:

> "Object `<NAME>` is currently linked to modifiable TR `<TR>`. Release it
> first via `/sap-se01 release <TR>`, or move within the same TR's package
> scope. Aborting."

If the only linked TRs are `R` (Released), proceed.

The VBS templates also detect this condition at runtime: if SAP shows a
wnd[2] `Error` popup (`txtMESSTXT1` containing `locked`) after pressing
Enter on the package field, the script reports
`ERROR: SAP popup [Error] <message>` and exits 1.

### `TMP_TO_TRANSPORT`

Resolve a modifiable TR by delegating to `/sap-transport-request`:

```
/sap-transport-request OBJECT_TYPE=<TADIR_OBJECT> OBJECT_DESCRIPTION=<OBJECT_NAME>
```

Capture the returned TRKORR as `RESOLVED_TR`. This honours
`way_to_get_transport_request` (DEFAULT / ASK / CREATE_NEW). If
`/sap-transport-request` reports `ERROR`, stop and surface it.

Also build a TR description for the "Create Request" popup the dialog may
show: use `<OBJECT_TYPE>_<OBJECT_NAME>_pkg` truncated to 60 chars, or honour
`rule_of_tr_description` if set.

### `LOCAL_TO_LOCAL`

No TR resolution or lock check needed.

### Confirmation prompt for any `*_TO_LOCAL` move

After pre-checks pass, confirm with the user (one prompt):

> "Move `<NAME>` from `<CURRENT_PACKAGE>` to `<NEW_PACKAGE>` (local)?
> The object will no longer be transported. Proceed? (yes / no)"

Only proceed on `yes`.

---

## Step 5 — Ensure SAP GUI Login

Requires an active SAP GUI session. If not logged in, run `/sap-login`.

---

## Step 6 — Run the Appropriate Change-Package VBS

| Transaction | Template |
|---|---|
| SE38 | `./references/sap_change_package_se38.vbs` |
| SE37 | `./references/sap_change_package_se37.vbs` |
| SE24 | `./references/sap_change_package_se24.vbs` |
| SE11 | `./references/sap_change_package_se11.vbs` |
| SE91 | `./references/sap_change_package_se91.vbs` |
| CMOD | `./references/sap_change_package_cmod.vbs` |

Tokens:

| Token | Used by |
|---|---|
| `%%OBJECT_NAME%%` | all |
| `%%OBJECT_TYPE%%` | SE11 only (radio + name field selection) |
| `%%NEW_PACKAGE%%` | all |
| `%%TRANSPORT%%` | `TMP_TO_TRANSPORT` mode (pre-resolved TR); empty otherwise |
| `%%TR_DESCRIPTION%%` | `TMP_TO_TRANSPORT` mode (used if dialog asks for new-TR description) |

Token-replace into `{WORK_TEMP}\sap_change_package_<TXN>_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_change_package_<TXN>.vbs' -Raw
$content = $content -replace '%%OBJECT_NAME%%','THE_NAME'
$content = $content -replace '%%OBJECT_TYPE%%','THE_TYPE'   # SE11 only
$content = $content -replace '%%NEW_PACKAGE%%','THE_PKG'
$content = $content -replace '%%TRANSPORT%%','THE_TR'
$content = $content -replace '%%TR_DESCRIPTION%%','THE_TR_DESC'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_change_package_<TXN>_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```

Run via 32-bit cscript:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_change_package_<TXN>_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {WORK_TEMP}\sap_change_package_<TXN>_run.vbs
```

Each VBS emits a stable contract:
- `INFO: ...` progress lines
- `STATUS_TYPE: <S|W|E|A|I>` and `STATUS_TEXT: <text>` (final status bar)
- Final line: `DONE` (success) or `ERROR: ...` (failure)

---

## Step 7 — Verify

Re-query `TADIR` (Step 2 query). Expect `DEVCLASS = NEW_PACKAGE`.

If MODE was `TMP_TO_TRANSPORT`, also verify the object is now linked to
`RESOLVED_TR` via `E071` (one row with `TRKORR = RESOLVED_TR`).

---

## Step 8 — Report

```
Changed package of <OBJECT_TYPE> <OBJECT_NAME>:
  before : <CURRENT_PACKAGE>
  after  : <NEW_PACKAGE>
  mode   : <MODE>
  TR     : <RESOLVED_TR | n/a>
  sbar   : [<TYPE>] <TEXT>
  TADIR  : verified ✓ | mismatch ✗
```

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_change_package_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_change_package_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `CHANGE_PACKAGE_FAILED`, `OBJECT_LOCKED_IN_TR`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Component IDs (for reference)

### Common (Object Directory Entry dialog — opens at wnd[1])

| Element | ID |
|---|---|
| Change button (display→edit) | `wnd[1]/tbar[0]/btn[6]` |
| Package field | `wnd[1]/usr/ctxtKO007-L_DEVCLASS` |
| Enter / OK | `wnd[1]/tbar[0]/btn[0]` |
| Local object button | `wnd[1]/tbar[0]/btn[12]` |
| Create Request button | `wnd[1]/tbar[0]/btn[8]` |
| TR field (when entering existing TR) | `wnd[1]/usr/ctxtKO008-TRKORR` |
| Confirm popup (info) | `wnd[2]/tbar[0]/btn[0]` |
| New-TR description field | `wnd[2]/usr/txtKO013-AS4TEXT` |

### Per-transaction "Goto > Object Directory Entry" menu paths

| Transaction | Menu | Object name field |
|---|---|---|
| SE38 | `mbar/menu[2]/menu[3]` | `wnd[0]/usr/ctxtRS38M-PROGRAMM` |
| SE37 | `mbar/menu[2]/menu[5]` | `wnd[0]/usr/ctxtRS38L-NAME` |
| SE24 | `mbar/menu[2]/menu[4]` | `wnd[0]/usr/ctxtSEOCLASS-CLSNAME` |
| SE11 | `mbar/menu[2]/menu[0]` | `ctxtRSRD1-<key>_VAL` (radio-dependent) |
| SE91 | `mbar/menu[2]/menu[0]` | `wnd[0]/usr/ctxtRSDAG-ARBGB` (then `btnANZTASTE` Display first) |
| CMOD | `mbar/menu[2]/menu[3]` | `wnd[0]/usr/ctxtMOD0-NAME` (then `sendVKey 0` to select the project first) |

Menu indices are version-specific (SAP GUI 7.60 / S/4HANA 1909). If a future
release renumbers the Goto menu, update the `MENU_OBJECT_DIR` constant in
each VBS.

---

## TADIR / E070 / E071 Field Reference

| Table | Field | Meaning |
|---|---|---|
| `TADIR` | `PGMID` | `R3TR` for repository objects |
| `TADIR` | `OBJECT` | Object type (PROG / CLAS / TABL / DOMA / MSAG / FUNC / FUGR / CMOD …) |
| `TADIR` | `OBJ_NAME` | Object name |
| `TADIR` | `DEVCLASS` | **Package** — `$*` = local, otherwise transportable |
| `TADIR` | `MASTERLANG` | Original language of the object |
| `E071` | `TRKORR` | TR / task that contains this object |
| `E070` | `TRSTATUS` | `D` Modifiable, `L` Locked-in-test, `O` Release started, `R` Released |
| `E070` | `TRFUNCTION` | `K` Workbench, `W` Customizing |

---

## Limitations

- The "to-local" confirmation popup (wnd[2] btn[0]) shape can vary across
  S/4HANA releases; the VBS handles the common case from the recordings.
  If a different popup appears, the VBS will surface the sbar text.
- The current logic assumes the object exists in TADIR. For freshly-created
  $TMP objects that haven't been saved yet, run the relevant deploy skill
  (sap-se38/se37/se24/se11/se91) first.
- For `TRANSPORT_TO_TRANSPORT` moves where the user wants to release the
  blocking TR, suggest `/sap-se01 release <TR>` and re-run this skill.
