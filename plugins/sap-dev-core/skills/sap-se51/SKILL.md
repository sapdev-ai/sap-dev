---
name: sap-se51
description: |
  Maintains screens (dynpros) in a SAP system via SE51 using SAP GUI
  Scripting. Two modes:
  (a) FLOW LOGIC — create new screens or update an existing screen's flow
      logic (PROCESS BEFORE OUTPUT / PROCESS AFTER INPUT). Existence check
      (SE51 Display), flow logic paste via Windows clipboard, save, activate.
  (b) LAYOUT / ADD ELEMENT — add layout elements (static Text labels,
      Input/Output fields, checkboxes, pushbuttons, radio buttons) to an
      existing screen via the ALPHANUMERIC Screen Painter (Edit > Create
      Element). This is the only scriptable placement path: the graphical
      drag-and-drop Layout Editor is a non-scriptable ActiveX control the
      recorder cannot capture, and the element-list grid is read-only for
      placement. Requires the per-user "Graphical Layout Editor" setting OFF.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<program-name> <screen-number> [path-to-flow-logic | --add-element <element-file>]"
---

# SAP SE51 Screen Painter Deploy Skill

You maintain screens (dynpros) on a live SAP system via SE51 using SAP GUI
Scripting.

**Mode dispatch — decide first:**

| User intent | Mode | Where |
|---|---|---|
| "deploy/update flow logic", "set PBO/PAI", a `.txt`/`.abap` flow-logic file | **Flow Logic** | Steps 0–7 below |
| "add a field / text / checkbox / button to a screen", "add BUKRS and WERKS to the layout", "put an I/O field on the screen" | **Add Layout Element** | jump to **Mode: Add Layout Elements** (near the end) |

The flow-logic mode (Steps 0–7) checks if the screen exists, then creates or
updates its flow logic. The add-element mode drives the alphanumeric Screen
Painter to place new elements on an existing screen's layout.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` instead of asking for the TR itself |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_attach_lib.vbs` | Parallel-safe session attach (`%%ATTACH_LIB_VBS%%`) — every reference VBS includes it and calls `AttachSapSession(SESSION_PATH)` |

### Skill reference scripts (`./references/`)

| File | Mode | Purpose |
|---|---|---|
| `sap_se51_check.vbs` | Flow logic | Existence check — SE51 Display, detect Screen Painter editor |
| `sap_se51_create.vbs` | Flow logic | Create a new screen + paste flow logic (clipboard, `wscript`) |
| `sap_se51_update.vbs` | Flow logic | Update an existing screen's flow logic (clipboard, `wscript`) |
| `sap_se51_add_element.vbs` | Add layout element | **Append** loose layout elements (Text/IO/Checkbox/Pushbutton/Radio) from a tab-delimited element file via the alphanumeric Screen Painter. `NOT_ALPHANUMERIC` guard; `txt[0,row]` anchor fallback; 3× focus+menu retry. `cscript`. |
| `sap_se51_layout_rebuild.vbs` | Add layout element | **Rebuild** the work area into tidy "label + input field" lines from a tab-delimited line-spec, via gap-cell discovery. All-or-nothing (discards on any shortfall — live screen untouched). Use for *"make each field its own line with a label and input"*. `cscript`. |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
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

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_se51_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se51_run.json" -Skill sap-se51 -ParamsJson "{\"program\":\"<PROGRAM>\",\"screen\":\"<SCREEN>\"}"
```

---

## Step 1 — Collect Parameters

**Screen Details**

| Parameter | Description | Example |
|---|---|---|
| Program name | Main program or function pool (e.g. `SAPLZHKFG01`) | `SAPLZHKFG01` |
| Screen number | 4-digit screen number | `0100` |
| Short text | Short description, max 70 chars (only for new screens) | `Main selection screen` |
| Flow logic source | Either absolute path to a `.txt`/`.abap` file, OR paste the flow logic directly | |

---

## Step 2 — Prepare Flow Logic Source File

**Important:** The source file must contain the complete flow logic text — the
`PROCESS BEFORE OUTPUT.` and `PROCESS AFTER INPUT.` blocks with MODULE calls.

**If the user pasted flow logic directly:**

1. Write the source to: `{WORK_TEMP}\<PROGRAM_NAME>_<SCREEN_NUMBER>.txt`
   - Use the Write tool with the exact flow logic as content.
2. Confirm the file by reading back the first 5 lines.

**If the user provided a file path:**

- Use that path as-is. Verify it exists:
  ```bash
  cmd /c if exist "<path>" (echo EXISTS) else (echo NOT FOUND)
  ```

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Screen Exists

The check VBScript template is at `./references/sap_se51_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se51_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se51_check.vbs' -Raw
$content = $content -replace '%%PROGRAM_NAME%%','THE_PROGRAM_NAME'
$content = $content -replace '%%SCREEN_NUMBER%%','THE_SCREEN_NUMBER'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se51_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_PROGRAM_NAME` (UPPERCASE), `THE_SCREEN_NUMBER`, and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se51_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se51_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → screen exists → proceed to Step 5a (Update).
- `NOT_EXIST` → screen does not exist → proceed to Step 5b (Create).
- `ERROR:` → show full output and stop.

---

## Step 5a — Update Existing Screen

The update VBScript template is at `./references/sap_se51_update.vbs`.

**IMPORTANT — wscript.exe and clipboard approach:**
SE51's ABAP editor does not support file upload for flow logic text.
The update VBS uses `AppActivate` + `SendKeys` to paste flow logic from the
Windows clipboard. This requires:
1. PowerShell sets the clipboard content BEFORE running the VBS.
2. The VBS must be run with `wscript.exe` (not `cscript.exe`).
3. Output is written to a log file (not stdout).

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se51_update_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se51_update.vbs' -Raw
$content = $content -replace '%%PROGRAM_NAME%%','THE_PROGRAM_NAME'
$content = $content -replace '%%SCREEN_NUMBER%%','THE_SCREEN_NUMBER'
$content = $content -replace '%%LOG_FILE%%','{WORK_TEMP}\\sap_se51_update.log'
$content = $content -replace '%%FOREGROUND_GUARD_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_foreground_guard.ps1'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se51_update_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_PROGRAM_NAME` (UPPERCASE), `THE_SCREEN_NUMBER`, and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se51_update_run.ps1"
```

### Execute with clipboard paste

**This is a two-part command:** Set the clipboard, then run the VBS with `wscript.exe`.

```powershell
# Read flow logic into clipboard
$flowLogic = Get-Content '{WORK_TEMP}\THE_PROGRAM_THE_SCREEN.txt' -Raw
Set-Clipboard -Value $flowLogic

# Run the VBS with wscript.exe (GUI mode required for AppActivate)
Start-Process wscript.exe -ArgumentList '{WORK_TEMP}\sap_se51_update_run.vbs' -Wait

# Read the log file for results
Get-Content '{WORK_TEMP}\sap_se51_update.log'
```
Replace the flow logic file path with the actual path from Step 2.

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Screen

If this is a new screen, you need the Short Text in addition to the flow logic.
Ask the user if not already provided:
> "This is a new screen. Please provide a short description."

The create VBScript template is at `./references/sap_se51_create.vbs`.

**IMPORTANT — wscript.exe and clipboard approach:**
Same as Step 5a. The create VBS uses `AppActivate` + `SendKeys` to paste flow logic
from the Windows clipboard.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se51_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se51_create.vbs' -Raw
$content = $content -replace '%%PROGRAM_NAME%%','THE_PROGRAM_NAME'
$content = $content -replace '%%SCREEN_NUMBER%%','THE_SCREEN_NUMBER'
$content = $content -replace '%%SCREEN_SHORT_TEXT%%','THE_SHORT_TEXT'
$content = $content -replace '%%LOG_FILE%%','{WORK_TEMP}\\sap_se51_create.log'
$content = $content -replace '%%FOREGROUND_GUARD_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_foreground_guard.ps1'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se51_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se51_create_run.ps1"
```

### Execute with clipboard paste

```powershell
# Read flow logic into clipboard
$flowLogic = Get-Content '{WORK_TEMP}\THE_PROGRAM_THE_SCREEN.txt' -Raw
Set-Clipboard -Value $flowLogic

# Run the VBS with wscript.exe (GUI mode required for AppActivate)
Start-Process wscript.exe -ArgumentList '{WORK_TEMP}\sap_se51_create_run.vbs' -Wait

# Read the log file for results
Get-Content '{WORK_TEMP}\sap_se51_create.log'
```
Replace the flow logic file path with the actual path from Step 2.

Proceed to Step 6 to evaluate the result.

---

## Step 6 — Report Result

**On success** (log contains `SUCCESS:`):
- Tell the user the screen was deployed and activated.
- Show the full log output as a code block.

**On failure** (log contains `ERROR:`):
- Show the full log and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `SE51 program name field not found` | Component ID mismatch | Use SAP Scripting Recorder to find correct ID |
| `Could not reach Screen Painter editor after create` | Screen already exists or wrong program/number | Check name or use update flow |
| `Could not open screen in change mode` | Screen locked or no auth | Check locks (SM12) or authorization |
| `WARNING: Could not set short description` | Attributes field path differs | Check component IDs for this SAP release |
| `WARNING: Could not find flow logic editor` | Editor path differs by SAP version | Use Scripting Recorder to capture editor path |
| `WARNING: Activation errors` | Flow logic syntax errors | Show log, check flow logic content |

**Add Layout Element / Rebuild modes** (log files `sap_se51_add_element.log` /
`sap_se51_layout_rebuild.log`):

| Error message | Cause | Fix |
|---|---|---|
| `ERROR: NOT_ALPHANUMERIC …` | Graphical Layout Editor is ON; Change opened the non-scriptable canvas | SE51 → Utilities → Settings → uncheck **Graphical Layout Editor**, then re-run |
| `ERROR: not all elements created …` (rebuild) | An element's create dialog didn't open (often a non-existent cursor cell) | VBS already backed out **without saving** (screen unchanged); read the per-line `WARNING:`, fix the spec, re-run |
| `WARNING: create-element dialog did not open for '<x>'` | Cursor cell didn't exist / editor not ready after a prior Transfer | Already retried 3×; re-run with just the skipped rows. For precise label+input, use the rebuild reference (gap-cell discovery) |
| `ERROR: … prompted for a transport request but TRANSPORT is empty` | Transportable program, no TR supplied | Resolve a modifiable TR via `/sap-transport-request` and re-run |
| activation `[E]`/`[A]` in the log | Dict-bound `IO` field has no `TABLES` in the program (or other syntax error) | Add `TABLES: <tab>.` via `/sap-se38`, or use plain `TEXT`/CHAR fields; then re-run |

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_se51_check_run.vbs & del {WORK_TEMP}\sap_se51_check_run.ps1 & del {WORK_TEMP}\sap_se51_create_run.vbs & del {WORK_TEMP}\sap_se51_create_run.ps1 & del {WORK_TEMP}\sap_se51_update_run.vbs & del {WORK_TEMP}\sap_se51_update_run.ps1 & del {WORK_TEMP}\sap_se51_create.log & del {WORK_TEMP}\sap_se51_update.log
```

For the **Add Layout Element** mode, also delete:
```bash
cmd /c del {WORK_TEMP}\sap_se51_add_element_run.vbs & del {WORK_TEMP}\sap_se51_add_element_run.ps1 & del {WORK_TEMP}\sap_se51_add_element.log & del {WORK_TEMP}\se51_elements.txt & del {WORK_TEMP}\sap_se51_layout_rebuild_run.vbs & del {WORK_TEMP}\sap_se51_layout_rebuild_run.ps1 & del {WORK_TEMP}\sap_se51_layout_rebuild.log & del {WORK_TEMP}\se51_lines.txt
```

Also delete `{WORK_TEMP}\<PROGRAM_NAME>_<SCREEN_NUMBER>.txt` if the user pasted code (not a user-supplied file).

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se51_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se51_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE51_FAILED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).

The create and update VBS scripts MUST be run with `wscript.exe` (not `cscript.exe`).

**Why:** SE51's flow logic editor (GuiShell SubType AbapEditor) does not support
file upload for flow logic text. The "Upload/Download" menu in SE51 is for entire
dynpro binary format, not editable text. The only way to programmatically set
flow logic is via Windows clipboard paste (`Ctrl+A` then `Ctrl+V`).

`AppActivate` (used to give focus to the SAP GUI window before SendKeys) fails
when called from a console-mode process (`cscript.exe`). It only works from a
GUI-mode process (`wscript.exe`).

Because `wscript.exe` has no stdout, all output is written to a log file specified
by the `%%LOG_FILE%%` token. Read the log file after execution to check results.

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript`/`wscript` supports natively and preserves non-ASCII characters.
UTF-8 with BOM causes a script compile error.

---

## Troubleshooting Component IDs

If menu paths or component IDs fail on the user's system:
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorder outputs VBScript with exact IDs for their system
4. Update the relevant constants in the VBS template

---

## SE51 Component IDs Reference

**SE51 Initial Screen** — "Screen Painter: Initial Screen"

| Element | Component ID | Type |
|---|---|---|
| Program field | `wnd[0]/usr/ctxtRS37A-DYNPROG` | GuiCTextField |
| Screen number | `wnd[0]/usr/ctxtFELD-DYNNR` | GuiCTextField |
| Flow logic radio | `wnd[0]/usr/radRS37A-FUNLS` | GuiRadioButton |
| Element list radio | `wnd[0]/usr/radRS37A-FUNFL` | GuiRadioButton |
| Attributes radio | `wnd[0]/usr/radRS37A-FUNHD` | GuiRadioButton |
| Layout Editor radio | `wnd[0]/usr/radRS37A-FUNED` | GuiRadioButton |
| Create button | `wnd[0]/usr/btnANLEGEN` | GuiButton |
| Display button | `wnd[0]/usr/btnANZEIGEN` | GuiButton |
| Change button | `wnd[0]/usr/btnAENDERN` | GuiButton |

**Screen Painter Editor** — "Screen Painter: Change/Display Screen for ..."

| Element | Component ID | Notes |
|---|---|---|
| Tab strip | `wnd[0]/usr/tabsBS_TABSTR_CONTROL` | |
| Attributes tab | `tabpHD` | |
| Element list tab | `tabpFL` | |
| Flow logic tab | `tabpLS` | |
| Display↔Change toggle | `wnd[0]/tbar[1]/btn[25]` | |
| Syntax check (Ctrl+F2) | `wnd[0]/tbar[1]/btn[26]` | |
| Activate (Ctrl+F3) | `wnd[0]/tbar[1]/btn[27]` | |

**Attributes Tab Fields** (under `tabpHD/ssubBS_TABSTR_CONTROL_SUB:SAPLWBSCREEN:2150/`)

| Element | Field ID | Notes |
|---|---|---|
| Short Description | `txtRS37A-DTXT` | |
| Package | `ctxtRS37A-DEVCL` | Read-only |
| Dynpro Type: Normal | `radRS37A-HTYPN` | |
| Dynpro Type: Subscreen | `radRS37A-HTYPI` | |
| Dynpro Type: Modal | `radRS37A-HTYPM` | |
| Dynpro Type: Selection | `radRS37A-HTYPS` | |
| Next Dynpro | `ctxtRS37A-FNUM` | |
| Screen Group | `ctxtRS37A-DGRP` | |

**Flow Logic Editor** (under `tabpLS/ssubBS_TABSTR_CONTROL_SUB:SAPLWBSCREEN:2161/subEDITORSUBSCREEN:SAPLEDITOR_START:8430/cntlEDITOR/shellcont/shell`)

| Property | Value |
|---|---|
| Type | GuiShell |
| SubType | AbapEditor |
| Text manipulation | Windows clipboard paste only (Ctrl+A / Ctrl+V with wscript.exe) |

---

## Mode: Add Layout Elements

Use this mode when the user wants to **add elements to a screen's layout** —
static Text labels, Input/Output fields, checkboxes, pushbuttons, radio
buttons — e.g. *"add two text items BUKRS and WERKS to ZHKTESTSE51001 9001"*.

### Why a separate mechanism (read this first)

The screen **layout** cannot be edited the way flow logic is:

| Path | Scriptable? | Why |
|---|---|---|
| Graphical Layout Editor (drag-and-drop canvas) | ❌ No | Non-scriptable ActiveX control; the SAP GUI recorder captures nothing and `findById` cannot reach its widgets. **This is why "Layout can't record."** |
| Element-list grid (`tblSAPLWBSCREENFIELD170`) | ❌ No (for adding) | Edits attributes of existing elements only; empty rows are `Changeable=False` and `FELD-LINE`/`FELD-COLN` are read-only (writing them raises err 613). |
| `RPY_DYNPRO_READ` / `_INSERT` (RFC) | ⚠️ Not used | `RPY_DYNPRO_READ` is **not** remote-enabled ("cannot be used for 'remote' calls"). The `_NATIVE` variants exist but require deploying a transient ABAP helper. |
| **Alphanumeric Screen Painter** (Edit > Create Element) | ✅ **Yes** | Classic character-grid editor (program `SAPMSSY0`, dynpro 120). The recorder captures it and `findById` reaches the create-element dialog. **This mode uses this path.** |

### Prerequisite — turn OFF the Graphical Layout Editor (per-user)

The alphanumeric editor only appears when the user's SE51 setting **"Graphical
Layout Editor" is disabled**. Toggle it once per user:

> SE51 → **Utilities → Settings…** → uncheck **Graphical Layout Editor** →
> Continue. (Persisted in the user's parameters.)

The reference VBS detects the mode by program name and **aborts with
`NOT_ALPHANUMERIC`** if the Change button opened the graphical canvas instead
(`oSession.Info.Program <> "SAPMSSY0"`), telling the operator to flip the
setting. Detection is language-independent (keys on the program name, not menu
text).

### Step L1 — Resolve a transport request

Screen changes to a transportable program need a TR. Delegate to
`/sap-transport-request` (never prompt directly):

```
/sap-transport-request OBJECT_TYPE=PROG OBJECT_DESCRIPTION=<PROGRAM_NAME>
```

Use the returned TRKORR as `%%TRANSPORT%%`. Also look up the program's package
(`TADIR-DEVCLASS`, e.g. via `/sap-se16n`) and pass it as `%%PACKAGE%%` — the
Object Directory Entry popup is normally pre-filled with it, but the token is a
fallback when the field is empty. If the program is local (`$TMP`), leave both
empty.

### Step L2 — Write the element definition file

Tab-delimited, UTF-8, one element per line; lines starting with `#` are
ignored:

```
# TYPE	NAME	TEXT	LENGTH	LINE	COLUMN
TEXT	BUKRS	BUKRS	5	6	2
TEXT	WERKS	WERKS	5	8	2
```

| Column | Meaning |
|---|---|
| `TYPE` | `TEXT` \| `IO` \| `CHECKBOX` \| `PUSHBUTTON` \| `RADIO` (case-insensitive) |
| `NAME` | element/field name (for `IO`: a program or DDIC field, e.g. `T001-BUKRS`; for `TEXT` a name is optional) |
| `TEXT` | displayed text (label for `TEXT`/`PUSHBUTTON`/`CHECKBOX`; ignored for `IO`) |
| `LENGTH` | output / field length (characters) |
| `LINE` | dynpro line (1-based) |
| `COLUMN` | dynpro column (0-based — matches the work-area `txt[col,row]` grid) |

> **Dictionary-bound `IO` fields** (e.g. `T001-BUKRS`) require the program to
> declare the table (`TABLES: t001.`) or the screen will not activate. Add the
> `TABLES` statement first via `/sap-se38`. Plain `TEXT` labels need no program
> change — prefer them when the user just wants "text items".

### Step L3 — Generate and run the reference VBS

Template: `./references/sap_se51_add_element.vbs`. Write
`{WORK_TEMP}\sap_se51_add_element_run.ps1`:

```powershell
$ref    = '<SKILL_DIR>\references\sap_se51_add_element.vbs'
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$c = Get-Content $ref -Raw
$c = $c -replace '%%PROGRAM_NAME%%','THE_PROGRAM'
$c = $c -replace '%%SCREEN_NUMBER%%','THE_SCREEN'
$c = $c -replace '%%TRANSPORT%%','THE_TR'
$c = $c -replace '%%PACKAGE%%','THE_PACKAGE'
$c = $c -replace '%%ELEMENT_FILE%%','{WORK_TEMP}\se51_elements.txt'
$c = $c -replace '%%LOG_FILE%%','{WORK_TEMP}\sap_se51_add_element.log'
# SESSION_PATH: leave '' for the single-session case (the attach lib resolves
# via SAPDEV_SESSION_PATH below). If multiple sessions are open on the
# connection the lib refuses — pass an explicit '/app/con[0]/ses[0]' here.
$c = $c -replace '%%SESSION_PATH%%',''
$c = $c -replace '%%ATTACH_LIB_VBS%%',"$shared\sap_attach_lib.vbs"
. "$shared\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se51_add_element_run.vbs' $c -Encoding Unicode
Write-Host 'Done'
```

Run with **`cscript`** (this VBS writes to a log file, not the clipboard, so no
`wscript`/foreground guard is needed):

```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se51_add_element_run.ps1"
cscript //NoLogo {WORK_TEMP}\sap_se51_add_element_run.vbs
```

Read `{WORK_TEMP}\sap_se51_add_element.log`. Last line:
- `SUCCESS: <n> element(s) added to <PROG> <DYNNR>.` → proceed to verify.
  **Check `<n>` equals the number of element rows** — a per-element `WARNING:`
  means that element was skipped (re-run with just the skipped rows).
- `ERROR: NOT_ALPHANUMERIC …` → graphical editor is ON; flip the setting and re-run.
- `ERROR: …` → diagnose from the log.

### Step L4 — Verify (RFC, authoritative)

Confirm the screen is active and the change is in the TR:

- `DWINACTIV` filtered `OBJ_NAME LIKE '<PROG>%'` → **0 rows** = fully active.
- `E071` filtered `OBJ_NAME LIKE '<PROG>%'` → an `R3TR PROG <PROG>` (and/or
  `LIMU DYNP <PROG><DYNNR>`) row under the resolved TR.
- Optionally re-open SE51 **Element list** (Display) and confirm the new
  `FELD-NAME` rows with `FELD-GTYP = Text`/`I/O` appear.

### Save / popup chain (encoded in the reference VBS)

The first Save of a transportable screen raises a chain handled by the VBS's
`HandleSavePopups` (dispatched by DDIC field, language-independent):

1. **Create Object Directory Entry** (program `SAPLSTRD`, dynpro 300) — package
   `ctxtTADIR-DEVCLASS` is normally pre-filled; **Continue = `tbar[0]/btn[8]`**
   (not `btn[0]`; the toolbar also has `btn[28]`=Local Object, `btn[32]`=Own
   Requests, `btn[5]`=Cancel).
2. **Prompt for transportable change request** (`SAPLSTRD/300`) — fill
   `ctxtKO008-TRKORR` with the TR, Continue via `tbar[0]/btn[8]`.

### Component IDs — Add Element (recorded S/4HANA 1909, SAP GUI 7.70)

**Alphanumeric Screen Painter** (`SAPMSSY0` / screen 120, reached via SE51
Layout radio `radRS37A-FUNED` + Change `btnAENDERN` with graphical editor OFF):

| Element | ID |
|---|---|
| Work-area cell (cursor target) | `wnd[0]/usr/txt[<col>,<row>]` |
| Save | `wnd[0]/tbar[0]/btn[11]` |
| Activate (Ctrl+F3) | `wnd[0]/tbar[1]/btn[27]` |

**Edit > Create Element submenu** (`wnd[0]/mbar/menu[1]/menu[2]/menu[N]`):

| N | Element | N | Element |
|---|---|---|---|
| 0 | Text Field | 6 | Frames |
| 1 | Input/Output Field | 7 | Table Control |
| 2 | Radio Button | 8 | Custom Control |
| 3 | Checkbox | 9 | Tabstrip Control |
| 4 | Pushbutton | 10 | Subscreen |
| 5 | Pushbutton for Online Help | 11 | Splitter Control |

**Create-element dialog** ("Element Attributes Change", `wnd[1]`):

| Field | ID |
|---|---|
| Type (read-only) | `txtFELD-GTYP` |
| Name | `txtFELD-NAME` |
| Text | `txtFELD-STXT` |
| Line | `txtFELD-LINE` |
| Column | `txtFELD-COLN` |
| Length (DefLg) | `txtFELD-LENG` |
| Visible length | `txtFELD-VLENG` |
| Refresh / validate | `tbar[0]/btn[0]` |
| **Transfer (place element)** | `tbar[0]/btn[5]` |
| Cancel | `tbar[0]/btn[12]` |

Per-element sequence: place the cursor on the target cell (`txt[col,row]`), open
Edit > Create Element > `<type>`, fill the dialog, press Refresh (`btn[0]`) then
Transfer (`btn[5]`). After a Transfer the editor needs a beat before the next
menu opens, so the reference retries the focus+menu up to 3× per element (a
batch of >1 element otherwise occasionally skipped element #2).

### Placement reality (READ THIS before scripting precise layouts)

The character-grid editor has two non-obvious rules that defeat naive scripts:

1. **Work-area cells `txt[col,row]` exist only at element boundaries — not at
   every column.** `txt[0,row]` (column 0) always exists, but an arbitrary
   column like `txt[9,row]` usually does **not**. `setFocus` on a non-existent
   cell raises err 619, and the subsequent Create-Element menu then silently
   opens nothing (the element is dropped). Always anchor on `txt[0,row]` or a
   cell you've confirmed exists.
2. **An element lands at the CURSOR cell.** The create dialog's `FELD-LINE` /
   `FELD-COLN` fields are advisory and are **rejected for I/O fields** (err
   613) — you cannot position an input field by typing coordinates. Position is
   determined solely by which cell has the cursor.
3. **Gap-cell discovery for "label + input" pairs.** After you create a Text
   label at `txt[0,row]`, a NEW editable cell appears immediately to its right
   at `txt[<labellen+1>,row]` (e.g. label `BUKRS` → `txt[6,2]`). To put the
   input field next to the label you must re-scan the row, find that new
   `txt[col>0,row]` cell, and create the I/O field with the cursor on it.

`sap_se51_add_element.vbs` handles (1) by falling back to the `txt[0,row]`
anchor, but it does not do gap-cell discovery — it is for **appending loose
elements**, where exact label+input alignment doesn't matter.

### Restructuring into "label + input" lines — use sap_se51_layout_rebuild.vbs

When the user wants each field on its own line with a label and an input field
(*"make these two lines, each a label and an input field"*), use the
**`./references/sap_se51_layout_rebuild.vbs`** reference. It:

- clears the work area (Edit > Edit Rows > Delete Line per element — note Delete
  Line shifts lower rows up, which is why a full rebuild is more predictable
  than nudging),
- rebuilds one **Text label (col 0) + I/O field (gap cell)** pair per line using
  gap-cell discovery,
- is **all-or-nothing**: it Saves+Activates only if every planned element was
  created; on any shortfall it backs out WITHOUT saving, leaving the live
  screen unchanged.

> ⚠️ A full rebuild **recreates every element on the screen** from the line
> spec. Any element you don't list is dropped. So FIRST read the current
> element list (SE51 Element list / Display, or via the add-element verify
> path) and CONFIRM with the user which existing fields to keep — then include
> those in the line spec alongside the new ones.

#### Step R1 — Resolve a transport request

Same as the add-element mode's Step L1 — delegate to `/sap-transport-request`
and look up the program's package (`TADIR-DEVCLASS`). Use the results as
`%%TRANSPORT%%` / `%%PACKAGE%%` (both empty for a local `$TMP` program).

#### Step R2 — Write the line-spec file

Tab-delimited, UTF-8, `#` comments; one "label + input" pair per line. Lines are
placed on consecutive dynpro rows starting at row 2 unless a 4th `ROW` column
overrides. Write to `{WORK_TEMP}\se51_lines.txt`:

```
# LABEL	FIELDNAME	FIELDLEN	[ROW]
BUKRS	BUKRS	4
WERKS	WERKS	4
test	MYNAME	18
```

| Column | Meaning |
|---|---|
| `LABEL` | displayed label text, placed at column 0 |
| `FIELDNAME` | I/O field name, placed in the gap cell to the label's right |
| `FIELDLEN` | I/O field length (characters) |
| `ROW` (optional) | explicit dynpro row; default = 2, 3, 4, … in file order |

#### Step R3 — Generate and run the reference VBS

Template: `./references/sap_se51_layout_rebuild.vbs`. Write
`{WORK_TEMP}\sap_se51_layout_rebuild_run.ps1`:

```powershell
$ref    = '<SKILL_DIR>\references\sap_se51_layout_rebuild.vbs'
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$c = Get-Content $ref -Raw
$c = $c -replace '%%PROGRAM_NAME%%','THE_PROGRAM'
$c = $c -replace '%%SCREEN_NUMBER%%','THE_SCREEN'
$c = $c -replace '%%TRANSPORT%%','THE_TR'
$c = $c -replace '%%PACKAGE%%','THE_PACKAGE'
$c = $c -replace '%%LINESPEC_FILE%%','{WORK_TEMP}\se51_lines.txt'
$c = $c -replace '%%LOG_FILE%%','{WORK_TEMP}\sap_se51_layout_rebuild.log'
# SESSION_PATH: leave '' for the single-session case (the attach lib resolves
# via SAPDEV_SESSION_PATH below). If multiple sessions are open on the
# connection the lib refuses — pass an explicit '/app/con[0]/ses[0]' here.
$c = $c -replace '%%SESSION_PATH%%',''
$c = $c -replace '%%ATTACH_LIB_VBS%%',"$shared\sap_attach_lib.vbs"
. "$shared\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se51_layout_rebuild_run.vbs' $c -Encoding Unicode
Write-Host 'Done'
```

Run with **`cscript`** (writes to a log file; no clipboard/foreground guard
needed):

```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se51_layout_rebuild_run.ps1"
cscript //NoLogo {WORK_TEMP}\sap_se51_layout_rebuild_run.vbs
```

Read `{WORK_TEMP}\sap_se51_layout_rebuild.log`. Last line:
- `SUCCESS: rebuilt <PROG> <DYNNR> with <n> line(s).` → proceed to verify (Step L4).
- `ERROR: NOT_ALPHANUMERIC …` → graphical editor is ON; flip the setting and re-run.
- `ERROR: not all elements created …` → the VBS already backed out **without
  saving** (live screen unchanged); inspect the log's per-line `WARNING:` lines,
  fix the spec, and re-run.
- `ERROR: …` → diagnose from the log.

#### Step R4 — Verify

Same as the add-element mode's Step L4 (RFC `DWINACTIV` = 0, `E071` shows the
TR entry, optionally re-open the SE51 Element list).

---
