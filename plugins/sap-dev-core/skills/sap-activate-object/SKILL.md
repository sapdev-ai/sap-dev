---
name: sap-activate-object
description: |
  Activates an inactive SAP repository object via SAP GUI Scripting. Routes to
  the correct transaction by object type: SE38 for reports/programs/function-
  group main programs, SE37 for function modules, SE24 for classes/interfaces
  /methods, SE11 for DDIC objects (table, view, dataelement, structure,
  tabletype, typegroup, domain, searchhelp, lockobject). Handles the
  "inactive objects worklist" popup that SAP shows when there are multiple
  inactive objects of the same locality (transportable vs. local — SAP filters
  the popup by package locality of the triggering object). Verifies activation
  via PROGDIR (programs/FMs include) and DWINACTIV.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<OBJECT_TYPE> <OBJECT_NAME>"
---

# SAP Activate Object Skill

You activate an inactive SAP repository object via SAP GUI Scripting,
routing to the appropriate transaction based on the object type and verifying
the result via DDIC tables.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `sap_user`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

`sap_user` is needed for the DWINACTIV pre/post checks. If blank, ask the
user.

---

## Step 0.5 — Start Logging

Start a structured log run. The shared helper persists `run_id` to a state
file so subsequent steps and Step 7 can append to the same run. Logging is
best-effort — if `userConfig.log_enabled=false` or the lib can't load, the
helper silently no-ops.

`<SAP_DEV_CORE_SHARED_DIR>` resolves to `plugins/sap-dev-core/shared/`.

State file: `{WORK_TEMP}\sap_activate_object_run.json`

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_activate_object_run.json" -Skill sap-activate-object -ParamsJson "{\"object_type\":\"<TYPE>\",\"object_name\":\"<NAME>\"}"
```

---

## Step 1 — Parse Arguments

Required:

| Arg | Description | Example |
|---|---|---|
| `OBJECT_TYPE` | One of the keys below | `REPORT` |
| `OBJECT_NAME` | Object name in Z/Y namespace | `ZHKTEST003` |

If `$ARGUMENTS` is missing the type or name, ask:

> Which object should I activate? Provide `<OBJECT_TYPE> <OBJECT_NAME>` (e.g. `REPORT ZHKTEST003`).

### Object type → transaction routing

| OBJECT_TYPE | Transaction | DWINACTIV `OBJECT` value | TADIR `OBJECT` value |
|---|---|---|---|
| `REPORT` / `PROGRAM` | SE38 | `REPS` (source include) | `PROG` |
| `TEXT_ELEMENTS` | SE38 (Goto > Text elements) | `TEXT` | `PROG` |
| `FUGR` (function group main pgm) | SE38 | `REPS` | `FUGR` |
| `FM` (function module) | SE37 | `FUNC` | `FUGR` (registered under group) |
| `CLASS` | SE24 | `CLAS` | `CLAS` |
| `INTERFACE` | SE24 | `INTF` | `INTF` |
| `METHOD` | SE24 (open class) | `METH` | `CLAS` |
| `TABLE` | SE11 (radRSRD1-TBMA) | `TABL` | `TABL` |
| `VIEW` | SE11 (radRSRD1-VIMA) | `VIEW` | `VIEW` |
| `DTEL` (data element) | SE11 (radRSRD1-DDTYPE) | `DTEL` | `DTEL` |
| `STRUCTURE` | SE11 (radRSRD1-DDTYPE) | `TABL` (structures = TABL) | `TABL` |
| `TABLETYPE` | SE11 (radRSRD1-DDTYPE) | `TTYP` | `TTYP` |
| `TYPEGROUP` | SE11 (radRSRD1-TYMA) | `TYPE` | `TYPE` |
| `DOMAIN` | SE11 (radRSRD1-DOMA) | `DOMA` | `DOMA` |
| `SEARCHHELP` | SE11 (radRSRD1-SHMA) | `SHLP` | `SHLP` |
| `LOCKOBJECT` | SE11 (radRSRD1-ENQU) | `ENQU` | `ENQU` |

If the user supplies an unknown type → list the allowed values and ask.

---

## Step 2 — (Optional) Determine Local vs Transportable

Query `TADIR` via `/sap-se16n` to read `DEVCLASS` for the object:

```
SELECT
PGMID
OBJECT
OBJ_NAME
DEVCLASS
FILTER
PGMID	EQ	R3TR
OBJECT	EQ	<TADIR_OBJECT_FROM_TABLE_ABOVE>
OBJ_NAME	EQ	<OBJECT_NAME>
```

Read `DEVCLASS`:
- Starts with `$` (e.g. `$TMP`) → **local object** (no TR association).
- Otherwise → **transportable object**.

Store as `LOCALITY = LOCAL | TRANSPORT`. If TADIR has no row, the object does
not exist — report and stop.

This step is optional but recommended; LOCALITY is used to anticipate the
"inactive objects worklist" popup behaviour described in Step 3.

---

## Step 3 — Pre-check DWINACTIV (informational)

Query `DWINACTIV` via `/sap-se16n` filtering by the logged-in user:

```
SELECT
OBJECT
OBJ_NAME
UNAME
FILTER
UNAME	EQ	<sap_user>
```

This lists all inactive repository objects locked to this user. SAP's
"inactive objects worklist" popup appears on activate when there are multiple
inactive objects **of the same locality** as the object being activated:
- Activating a **transportable** object → popup includes the other
  transportable inactive objects from this user.
- Activating a **local** object → popup includes the other local inactive
  objects from this user.

Use this list to inform the user: "There are N other inactive objects under
your user; the activation popup will let you pick which to activate."

The VBS templates handle the popup automatically (Select All + Continue,
matching the recordings).

---

## Step 4 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, run
`/sap-login`.

---

## Step 5 — Run the Appropriate Activate VBS

Pick the template by transaction:

| Transaction | Template | Tokens |
|---|---|---|
| SE38 | `./references/sap_activate_se38.vbs` | `%%OBJECT_NAME%%` |
| SE37 | `./references/sap_activate_se37.vbs` | `%%OBJECT_NAME%%` |
| SE24 | `./references/sap_activate_se24.vbs` | `%%OBJECT_NAME%%` |
| SE11 | `./references/sap_activate_se11.vbs` | `%%OBJECT_NAME%%`, `%%OBJECT_TYPE%%`, `%%ACTIVATION_LOG_VBS%%`, `%%TEMP_DIR%%` |

Token-replace into `{WORK_TEMP}\sap_activate_<txn>_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_activate_<TXN>.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%OBJECT_NAME%%','THE_NAME'
$content = $content -replace '%%OBJECT_TYPE%%','THE_TYPE'   # SE11 only
$content = $content -replace '%%ACTIVATION_LOG_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_activation_log.vbs'   # SE11 only
$content = $content -replace '%%TEMP_DIR%%','{WORK_TEMP}'   # SE11 only
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_activate_<TXN>_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

> **Activation-log capture (SE11 only, by design)**: when SE11 activation
> reports an error (`STATUS_TYPE = E` or `A`), the helper writes
> `{WORK_TEMP}\<OBJECT>.activation_log.txt` and the script echoes
> `ACTIVATION_LOG: <path>` and `ACTIVATION_ERROR: <top error line>`. This
> turns the opaque "refer to log" SAP popup into actionable output.
>
> **Not applicable to SE38 / SE37 / SE24 / SE91.** The
> `Utilities > Activation Log` menu is a DDIC-worklist concept that exists
> only in SE11. Other transactions surface activation errors directly in
> the source-code editor (inline error markers + clickable error list) and
> in the status bar — the existing `STATUS_TYPE` / `STATUS_TEXT` capture in
> those VBS templates is the right surfacing mechanism. Do NOT propagate
> this helper to non-SE11 activate scripts.

Run via 32-bit cscript:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_activate_<TXN>_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {WORK_TEMP}\sap_activate_<TXN>_run.vbs
```

Each VBS emits:
- `INFO: ...` — progress
- `STATUS_TYPE: <S|W|E|A|I>` — final status bar message type
- `STATUS_TEXT: <text>` — final status bar message text
- Final line: `DONE` on success or `ERROR: ...` on failure.

---

## Step 6 — Verify Activation

### 6a. Status bar

The status bar text should be **`Object(s) activated`** (S-type message). If
the VBS reports an `E`/`A` status type, surface the text to the user and treat
as failure.

### 6b. PROGDIR check (SE38 / SE37 only)

For programs and FMs, query `PROGDIR` via `/sap-se16n`:

For **REPORT/PROGRAM/FUGR** (SE38):
```
SELECT
NAME
STATE
FILTER
NAME	EQ	<OBJECT_NAME>
STATE	EQ	A
```
Expect at least one row — `STATE = A` means the active version exists.

For **FM** (SE37):
1. First resolve the FM's include name: query `TFDIR` via `/sap-se16n`:
   ```
   SELECT
   FUNCNAME
   PNAME
   INCLUDE
   FILTER
   FUNCNAME	EQ	<OBJECT_NAME>
   ```
   Build the include name. PNAME is the function group main program; INCLUDE
   is the FM's source include number. The conventional include name format is
   `L<group>U<include>` where `<group>` = the 4-char part after `SAPL` of
   PNAME, and `<include>` = INCLUDE (zero-padded, with the literal letter
   prefix). Or simply: read `PNAME-INCLUDE` text directly if SAP returns it
   as a column.
2. Then query `PROGDIR` with `NAME EQ <include_name>` and check `STATE = A`.

### 6c. DWINACTIV check (always)

Re-query `DWINACTIV` filtering by user + the specific object:

```
SELECT
OBJECT
OBJ_NAME
UNAME
FILTER
UNAME	EQ	<sap_user>
OBJECT	EQ	<DWINACTIV_OBJECT_FROM_TABLE_ABOVE>
OBJ_NAME	EQ	<OBJECT_NAME>
```

Expect **NO rows**. Any row means the object is still inactive for this user
(activation failed or was skipped).

---

## Step 7 — Report

Report the result to the user:

```
Activated <OBJECT_TYPE> <OBJECT_NAME> via <TXN>.
Locality       : <LOCAL | TRANSPORT>
Status bar     : [<TYPE>] <TEXT>
PROGDIR check  : <STATE=A | n/a>
DWINACTIV      : <not found ✓ | still present ✗>
```

If the object still appears in DWINACTIV, recommend re-activating manually
or checking dependencies (inactive nested objects).

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_activate_object_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_activate_object_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `ACTIVATE_FAILED`, `GUI_TIMEOUT`.

---

## Component IDs (for reference)

### SE38 activate (from initial screen, no source open)
| Element | ID |
|---|---|
| OK code | `wnd[0]/tbar[0]/okcd` |
| Program name field | `wnd[0]/usr/ctxtRS38M-PROGRAMM` |
| Activate (initial screen) | `sendVKey 21` (Shift+F9) on `wnd[0]` |
| Inactive worklist popup | `wnd[1]` — Select All `tbar[0]/btn[9]`, Continue `tbar[0]/btn[0]` |

### SE37 activate
| Element | ID |
|---|---|
| FM name field | `wnd[0]/usr/ctxtRS38L-NAME` |
| Activate | `sendVKey 27` (Ctrl+F3) on `wnd[0]` |
| Inactive worklist popup | `wnd[1]` — Continue `tbar[0]/btn[0]` (FMs typically don't show Select All; the popup is for "activate dependent includes") |

### SE24 activate
| Element | ID |
|---|---|
| Class name field | `wnd[0]/usr/ctxtSEOCLASS-CLSNAME` |
| Display (Enter) | `sendVKey 0` |
| Activate | `sendVKey 27` (Ctrl+F3) on `wnd[0]` |
| Inactive worklist popup | `wnd[1]` — Select All `tbar[0]/btn[9]`, Continue `tbar[0]/btn[0]` |

### SE11 activate
| Element | ID |
|---|---|
| Object type radios | `radRSRD1-TBMA / VIMA / DDTYPE / TYMA / DOMA / SHMA / ENQU` |
| Name field | `ctxtRSRD1-<key>_VAL` (matching radio key) |
| Display (Enter) | `sendVKey 0` |
| Activate | `sendVKey 27` (Ctrl+F3) on `wnd[0]` |
| Inactive worklist popup | `wnd[1]` — Select All `tbar[0]/btn[9]`, Continue `tbar[0]/btn[0]` |

---

## DWINACTIV Field Reference

| Field | Meaning |
|---|---|
| `OBJECT` | DDIC object type code (e.g. `REPS`, `PROG`, `FUNC`, `CLAS`, `TABL`, `DOMA`) |
| `OBJ_NAME` | Object name |
| `UNAME` | User who locked the inactive version |

## TADIR Field Reference

| Field | Meaning |
|---|---|
| `PGMID` | `R3TR` for repository objects |
| `OBJECT` | TADIR object type (e.g. `PROG`, `CLAS`, `TABL`) |
| `OBJ_NAME` | Object name |
| `DEVCLASS` | Package — `$*` = local, otherwise transportable |

## PROGDIR Field Reference

| Field | Meaning |
|---|---|
| `NAME` | Program / include name |
| `STATE` | `A` = active, `S` = saved (inactive) |

---

## Known issue — Select-All worklist activates unrelated leftover objects

The current popup-handling presses Select All (`tbar[0]/btn[9]`) then Continue
(`tbar[0]/btn[0]`). When the worklist contains transportable inactive objects
that DID NOT come from the current activate call (leftover from prior failed
runs in the same user's namespace), Select-All activates them too. If any of
those leftover objects has a non-recoverable activation error, the worklist
re-appears in a loop and the activate never completes.

**Mitigation today**: before invoking this skill, query `DWINACTIV` filtered by
the logged-in user and delete or fix any leftover transportable inactive
objects unrelated to the current target. The `/sap-dev-clean` skill handles
the sap-dev-init artefacts; other leftovers must be cleaned manually.

**Proper fix (not yet implemented — needs a recording session per SAP release)**:
selectively uncheck rows in the worklist grid whose `OBJ_NAME` differs from
the current `OBJECT_NAME`, then press Continue. The pseudocode:

```vbs
' Find the worklist grid (S/4HANA 1909 commonly uses cntlGRID1 or similar)
Dim oGrid : Set oGrid = oSession.findById("wnd[1]/usr/cntlGRID1/shellcont/shell")
Dim r, sName
For r = 0 To oGrid.RowCount - 1
    sName = oGrid.GetCellValue(r, "OBJ_NAME")
    If UCase(sName) <> UCase(TARGET_OBJECT_NAME) Then
        oGrid.ModifyCheckbox r, "DEACTI", False    ' or whatever the select column is named
    End If
Next
oSession.findById("wnd[1]/tbar[0]/btn[0]").press   ' Continue
```

The grid path (`cntlGRID1`...) and select-column ID (`DEACTI`?) need to be
captured on the target SAP release via `/sap-gui-record`. The grid behaviour
differs between S/4HANA 1909, 2020, and 2023; the recording must be re-done
per system if needed.

Until then, the Select-All path remains the documented default — it works
cleanly on systems where the user's worklist contains only the current target.

## Other limitations
- TEXT_ELEMENTS activation requires opening the program in SE38, going to
  Goto > Text elements, then activating. The current SE38 VBS activates from
  the initial screen which covers source + text elements together. If a
  text-elements-only activation is needed, extend the VBS.
- METHOD-level activation: SE24 activates the entire class. There is no
  per-method activate; the popup may show methods if they are inactive
  individually after a class-level edit.
- The TFDIR-based PROGDIR lookup for FMs assumes a single include per FM.
  Function groups with shared / generated includes may need a broader query.
