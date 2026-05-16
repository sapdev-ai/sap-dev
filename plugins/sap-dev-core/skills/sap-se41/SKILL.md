---
name: sap-se41
description: |
  Deploys PF-STATUS (GUI status) definitions to a SAP system via SE41 using
  SAP GUI Scripting. Creates new statuses or updates existing ones with
  standard toolbar codes, function key assignments, save, and activation.
  SE41 has no Upload/Download for status definitions — function codes are
  entered field by field via a pipe-delimited definition file.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<program-name> <status-name> [function-code-definitions]"
---

# SAP SE41 Menu Painter Deploy Skill

You deploy PF-STATUS (GUI status) definitions to a live SAP system via SE41
using SAP GUI Scripting. The skill checks if the status exists,
then creates or updates it with function code assignments.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` instead of asking for the TR itself |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |

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

Start a structured log run. State file: `{WORK_TEMP}\sap_se41_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se41_run.json" -Skill sap-se41 -ParamsJson "{\"program\":\"<PROGRAM>\",\"status\":\"<STATUS>\"}"
```

---

## Step 1 — Collect Parameters

**Status Details**

| Parameter | Description | Example |
|---|---|---|
| Program name | Program / function pool (interface) name | `SAPLZHKT05` |
| Status name | PF-STATUS name, Z/Y namespace | `ZTEST01` |
| Status type | Only for NEW statuses: `DIAL` (Normal Screen), `POPUP` (Dialog Box), or `CONTEXT` (Context Menu) | `DIAL` |
| Short text | Short description, max 70 chars (only for new statuses) | `Standard dialog status` |
| Function codes | Standard toolbar codes, function key assignments — see Step 2 for format | *(see Step 2)* |

---

## Step 2 — Prepare Status Definition File

SE41 has **no Upload/Download** for status definitions. Function code assignments
are entered field by field. The VBS reads definitions from a pipe-delimited text file.

### Definition File Format

Each line: `TYPE|POSITION|CODE|TEXT`

| Line type | Position | Code | Text |
|---|---|---|---|
| `STD` | Toolbar slot 1-13 | Function code | Function text |
| `FK` | Key name (F5, Shift-F1, etc.) | Function code | Function text |

Lines starting with `#` are comments. Empty lines are ignored.

### Standard Toolbar Positions

| Position | Standard Use | SAP Control |
|---|---|---|
| 1 | Enter / Execute | `txt[1,9]` |
| 2 | (varies) | `txt[12,9]` |
| 3 | Back | `txt[23,9]` |
| 4 | Exit | `txt[34,9]` |
| 5 | Cancel | `txt[45,9]` |
| 6 | Print | `txt[56,9]` |
| 7 | Find | `txt[67,9]` |
| 8 | Find Next | `txt[78,9]` |
| 9 | First Page | `txt[89,9]` |
| 10 | Previous Page | `txt[100,9]` |
| 11 | Next Page | `txt[111,9]` |
| 12 | Last Page | `txt[122,9]` |
| 13 | (custom) | `txt[133,9]` |

### Available Function Keys

**Recommended keys** (SAP suggests standard usage):

| Key name | Typical Use | Grid row |
|---|---|---|
| `F2` | Choose / Select | 14 |
| `F9` | Select | 15 |
| `Shift-F2` | Delete | 16 |
| `Shift-F4` | Save without check | 17 |
| `Shift-F5` | Other object | 18 |

**Freely assigned keys**:

| Key name | Grid row | Key name | Grid row |
|---|---|---|---|
| `F5` | 21 | `Shift-F1` | 25 |
| `F6` | 22 | `Shift-F6` | 26 |
| `F7` | 23 | `Shift-F7` | 27 |
| `F8` | 24 | `Shift-F8` | 28 |
| | | `Shift-F9` | 29 |
| | | `Shift-F11` | 30 |
| | | `Shift-F12` | 31 |

**System-reserved keys** (cannot be assigned): F1, F3, F4, F10, F11, F12, Shift-F3, Shift-F10

### Example Definition File

```
# Standard toolbar
STD|3|BACK|Back
STD|4|RW|Exit
STD|5|CANC|Cancel
# Function keys
FK|F5|ZEXEC|Execute Report
FK|F6|ZREFR|Refresh
FK|F8|ZPRINT|Print List
FK|Shift-F1|ZATTR|Attributes
```

### Create the Definition File

1. Write the definition file to: `{WORK_TEMP}\<STATUS_NAME>.def`
   - Use the Write tool with the pipe-delimited content.
2. Confirm by reading back the first few lines.

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Status Exists

The check VBScript template is at `./references/sap_se41_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se41_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se41_check.vbs' -Raw
$content = $content -replace '%%PROGRAM%%','THE_PROGRAM'
$content = $content -replace '%%STATUS%%','THE_STATUS'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se41_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_PROGRAM` and `THE_STATUS` (UPPERCASE) and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se41_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se41_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → status exists → proceed to Step 5a (Update).
- `NOT_EXIST` → status does not exist → proceed to Step 5b (Create).
- `ERROR:` → show full output and stop.

---

## Step 5a — Update Existing Status

The update VBScript template is at `./references/sap_se41_update.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se41_update_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se41_update.vbs' -Raw
$content = $content -replace '%%PROGRAM%%','THE_PROGRAM'
$content = $content -replace '%%STATUS%%','THE_STATUS'
$content = $content -replace '%%DEF_FILE%%','{WORK_TEMP}\THE_STATUS.def'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se41_update_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_PROGRAM`, `THE_STATUS` (UPPERCASE), and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se41_update_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se41_update_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Status

If this is a new status, you need Status Type and Short Text in addition to the
definition file. Ask the user if not already provided:
> "This is a new status. Please confirm the status type (DIAL/POPUP/CONTEXT) and short text."

The create VBScript template is at `./references/sap_se41_create.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se41_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se41_create.vbs' -Raw
$content = $content -replace '%%PROGRAM%%','THE_PROGRAM'
$content = $content -replace '%%STATUS%%','THE_STATUS'
$content = $content -replace '%%STATUS_TYPE%%','THE_STATUS_TYPE'
$content = $content -replace '%%SHORT_TEXT%%','THE_SHORT_TEXT'
$content = $content -replace '%%DEF_FILE%%','{WORK_TEMP}\THE_STATUS.def'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se41_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se41_create_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se41_create_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user the status was deployed and activated.
- Show the full script output as a code block.

**On failure** (output contains `ERROR:` or `WARNING:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `Create Status popup did not appear` | Status already exists or program name wrong | Check name or use update flow |
| `Did not reach editor` | Create popup handling failed | Check SAP status bar message |
| `Could not open status for change` | Status doesn't exist or is locked | Check existence or locks (SM12) |
| `Could not set STD slot` | Standard toolbar field ID mismatch | Verify toolbar positions with Scripting Recorder |
| `Could not set FK` | Function key field ID mismatch | Verify FK grid row mappings |
| `Too many popups during save` | Stuck in function text entry loop | Check definition file for missing text entries |
| `Save failed` | SAP save error | Check status bar message |
| `Activation may have errors` | Dependency or consistency errors | Check activation log in SE41 |
| `Definition file not found` | Wrong path or file not written | Verify path, re-run Step 2 |

### "Enter Function Text" Popup

During save, SAP may show an "Enter Function Text" popup for standard toolbar
function codes that need text. The VBS handles this automatically using the text
from the definition file. If a function code is not in the definition file,
the code name itself is used as the text.

The popup cycle per function code:
1. **Choose Text Type** popup → VBS selects "Static Text" and confirms
2. **Function text entry** popup → VBS fills in the text and confirms

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_se41_check_run.vbs & del {WORK_TEMP}\sap_se41_check_run.ps1 & del {WORK_TEMP}\sap_se41_create_run.vbs & del {WORK_TEMP}\sap_se41_create_run.ps1 & del {WORK_TEMP}\sap_se41_update_run.vbs & del {WORK_TEMP}\sap_se41_update_run.ps1
```

Also delete `{WORK_TEMP}\<STATUS_NAME>.def` (the definition file).

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se41_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se41_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE41_FAILED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters.
UTF-8 with BOM causes a cscript compile error.

---

## SE41 No Upload/Download Note

Unlike SE37/SE38 which support source upload from local files, **SE41 has no
Upload/Download functionality** for status definitions. The Utilities, Extras,
Edit, and Environment menus were exhaustively probed — no import/export option
exists. The VBS enters function codes field by field into the SE41 editor grid.

---

## SE41 Component IDs Reference

### Initial Screen — "Menu Painter: Initial Screen"

| Element | Component ID | Notes |
|---|---|---|
| Program field | `wnd[0]/usr/ctxtRSMPE-PROGRAM` | GuiCTextField |
| Status radio | `wnd[0]/usr/radRSMPE-B_STATUS` | |
| Status name field | `wnd[0]/usr/ctxtRSMPE-STATUS` | GuiCTextField |
| Display button | `wnd[0]/usr/btn%#AUTOTEXT003` | |
| Change button | `wnd[0]/usr/btn%#AUTOTEXT004` | |
| Create button | `wnd[0]/usr/btn%#AUTOTEXT005` | |
| Test button | `wnd[0]/usr/btn%#AUTOTEXT002` | |

### Create Status Popup — "Create Status"

| Element | Component ID | Notes |
|---|---|---|
| Program (pre-filled) | `wnd[1]/usr/ctxtRSMPE-PROGRAM` | |
| Status name | `wnd[1]/usr/txtRSMPE-STATUS` | |
| Short description | `wnd[1]/usr/txtRSMPE-MENUDOC` | |
| Normal Screen | `wnd[1]/usr/radRSMPE-B_DIAL` | |
| Dialog Box | `wnd[1]/usr/radRSMPE-B_POPUP` | |
| Context Menu | `wnd[1]/usr/radRSMPE-B_CONTEXT` | |

### Editor — "Edit Status XXXX of Interface YYYY"

| Element | Component ID | Notes |
|---|---|---|
| Menu Bar section | `lbl[0,2]` | Double-click to expand |
| Application Toolbar section | `lbl[0,4]` | Double-click to expand |
| Function Keys section | `lbl[0,6]` | Double-click to expand |
| Standard Toolbar code fields | `txt[col,9]` | col = 1 + (pos-1)*11, 13 slots |
| FK code field | `txt[32,row]` | See FK row mapping |
| FK text field | `txt[43,row]` | See FK row mapping |
| Activate (Ctrl+F3) | `tbar[1]/btn[27]` | |
| Check syntax (Ctrl+F2) | `tbar[1]/btn[26]` | |
| Display <-> Change | `tbar[1]/btn[25]` | Ctrl+F1 |

### "Enter Function Text" Popup

| Element | Component ID | Notes |
|---|---|---|
| Static Text radio | `wnd[1]/usr/radRSMPE-B_TXT_STAT` | Choose Text Type popup |
| Dynamic Text radio | `wnd[1]/usr/radRSMPE-B_TXT_DYN` | Choose Text Type popup |
| Function code | `wnd[1]/usr/txtRSMPE-FUNC` | Function text entry popup |
| Function text | `wnd[1]/usr/txtRSMPE-MENU` | Function text entry popup |
| Icon name | `wnd[1]/usr/ctxtRSMPE-ICON_NAME` | Function text entry popup |
| Information Text | `wnd[1]/usr/txtRSMPE-INFO_TEXT` | Function text entry popup |

### Existence Detection

| Condition | Title pattern | Status bar |
|---|---|---|
| EXISTS | `Display Status XXXX, Interface YYYY` | (empty) |
| NOT EXISTS | `Menu Painter: Initial Screen` | `Status XXXX of interface YYYY has not been created` (type=E) |

---

## Troubleshooting Component IDs

If menu paths or component IDs fail on the user's system:
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs
