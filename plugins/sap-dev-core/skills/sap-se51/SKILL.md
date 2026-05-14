---
name: sap-se51
description: |
  Deploys screen (dynpro) flow logic to a SAP system via SE51 using
  SAP GUI Scripting. Creates new screens or updates existing ones.
  Existence check (SE51 Display), flow logic paste via
  Windows clipboard, save, and activation. Source is the flow logic text
  (PROCESS BEFORE OUTPUT / PROCESS AFTER INPUT blocks).
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<program-name> <screen-number> [path-to-flow-logic]"
---

# SAP SE51 Screen Painter Deploy Skill

You deploy screen (dynpro) flow logic to a live SAP system via SE51
using SAP GUI Scripting. The skill checks if the screen
exists, then creates or updates it.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `work_dir`, `custom_url`.

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
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
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
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
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
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
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

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_se51_check_run.vbs & del {WORK_TEMP}\sap_se51_check_run.ps1 & del {WORK_TEMP}\sap_se51_create_run.vbs & del {WORK_TEMP}\sap_se51_create_run.ps1 & del {WORK_TEMP}\sap_se51_update_run.vbs & del {WORK_TEMP}\sap_se51_update_run.ps1 & del {WORK_TEMP}\sap_se51_create.log & del {WORK_TEMP}\sap_se51_update.log
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
