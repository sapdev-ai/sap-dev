---
name: sap-cmod
description: |
  Manages SAP Enhancement Projects via CMOD and edits exit includes via SE38
  using SAP GUI Scripting. Creates enhancement projects, assigns SAP
  enhancements (exits), and deploys ABAP source to exit includes.
  Existence check, project creation with enhancement
  assignment, and include source upload/activate.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<project-name> <enhancement> <include-name> [path-to-source]"
---

# SAP CMOD Enhancement Project Skill

You manage SAP Enhancement Projects via CMOD and edit exit includes via SE38
using SAP GUI Scripting. The skill checks if the project exists,
creates it with enhancement assignments if needed, and deploys ABAP source
to the exit include.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` instead of asking for the TR itself |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — uploaded exit-include source must follow modern syntax, no literal MESSAGE strings. Run `/sap-check-abap` before deploy when the source isn't generator-emitted. |

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

Start a structured log run. The helper persists `run_id` in a state file
(`{WORK_TEMP}\sap_cmod_run.json`) so subsequent steps and the final
log-end call append to the same run. Best-effort: silently no-ops if
`userConfig.log_enabled=false` or the lib can't load.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_cmod_run.json" -Skill sap-cmod -ParamsJson "{\"project\":\"<PROJECT>\"}"
```

---

## Step 1 — Collect Parameters

**CMOD Project Details**

| Parameter | Description | Example |
|---|---|---|
| Project name | Z-namespace project name, max 10 chars | `ZHKPJ001` |
| Short text | Project short description (only for new projects) | `Custom route determination` |
| Enhancements | Pipe-separated SAP enhancement names to assign | `0VRF0001` or `0VRF0001\|AMPL0001` |

**Exit Include Details** (optional — only if editing include source)

| Parameter | Description | Example |
|---|---|---|
| Include name | Exit include program name | `ZXV00U01` |
| Source | Include body: absolute path to `.abap` file, OR paste code directly | |

---

## Step 2 — Prepare ABAP Source File (if editing include)

Skip this step if the user only wants to create the project / assign enhancements
without changing include source.

**If the user pasted source code directly:**

1. Write the source to: `{WORK_TEMP}\<INCLUDE_NAME>.abap`
   - Use the Write tool with the exact ABAP source as content.
3. Confirm the file by reading back the first 5 lines.

**If the user provided a file path:**

- Use that path as-is. Verify it exists:
  ```bash
  cmd /c if exist "<path>" (echo EXISTS) else (echo NOT FOUND)
  ```

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Project Exists

The check VBScript template is at `./references/sap_cmod_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_cmod_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_cmod_check.vbs' -Raw
$content = $content -replace '%%PROJECT_NAME%%','THE_PROJECT_NAME'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_cmod_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_PROJECT_NAME` with the actual project name (UPPERCASE) and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_cmod_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_cmod_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → project already exists → skip to Step 5b (Change Include) if editing include, or report that project already exists.
- `NOT_EXIST` → project does not exist → proceed to Step 5a (Create Project).
- `ERROR:` → show full output and stop.

---

## Step 5a — Create Project and Assign Enhancements

If the project does not exist, create it and assign the specified enhancements.
You need the Project Name, Short Text, and Enhancements.

The create VBScript template is at `./references/sap_cmod_create.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_cmod_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_cmod_create.vbs' -Raw
$content = $content -replace '%%PROJECT_NAME%%','THE_PROJECT_NAME'
$content = $content -replace '%%SHORT_TEXT%%','THE_SHORT_TEXT'
$content = $content -replace '%%ENHANCEMENTS%%','THE_ENHANCEMENTS'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_cmod_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_PROJECT_NAME` (UPPERCASE), `THE_SHORT_TEXT`, and `THE_ENHANCEMENTS` (pipe-separated, e.g. `0VRF0001|AMPL0001`). Replace `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_cmod_create_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_cmod_create_run.vbs
```

**On success** (output contains `SUCCESS:`): proceed to Step 5b if editing an include, or Step 6 to report.

**On failure** (output contains `ERROR:`): show full output and diagnose:

| Error message | Cause | Fix |
|---|---|---|
| `Did not reach Attributes screen` | Project already exists or naming error | Use check step first, verify name |
| `Save failed` | Authorization or transport issue | Check S_DEVELOP auth, transport config |
| `Did not reach Enhancement assignments screen` | Button ID mismatch | Re-record with Scripting Recorder |
| `Enhancement assignment failed` | Invalid enhancement name | Verify enhancement name in SMOD |

---

## Step 5b — Change Exit Include Source

If the user wants to edit the exit include (e.g. ZXV00U01), deploy the ABAP source
via SE38 (ABAP Editor). This step uploads source from a local file, saves, runs
syntax check, and activates.

The change include VBScript template is at `./references/sap_cmod_change_include.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_cmod_change_include_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_cmod_change_include.vbs' -Raw
$content = $content -replace '%%INCLUDE_NAME%%','THE_INCLUDE_NAME'
$content = $content -replace '%%ABAP_SOURCE_FILE%%','THE_SOURCE_PATH'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_cmod_change_include_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_INCLUDE_NAME` (UPPERCASE), `THE_SOURCE_PATH` (absolute path with backslashes), and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_cmod_change_include_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_cmod_change_include_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user what was accomplished (project created, enhancements assigned, include deployed).
- Show the full script output as a code block.

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `Did not reach ABAP Editor` | Include doesn't exist or wrong name | Verify include name matches the exit function module |
| `Upload dialog not found` | SAP GUI Security blocking file access | SAP Logon > Options > Security > set "Open file" to Allow |
| `Syntax check failed` | ABAP syntax errors | Show error message, ask user to fix code |
| `Activation failed` | Dependency errors or locks | Check error message, resolve dependencies |
| `Transport dialog` | Object in transportable package | Use transport request or reassign to $TMP |
| `Project already exists` | Re-creation attempted | Use check step to detect, skip create |
| `Enhancement does not exist` | Wrong enhancement name | List available enhancements via SMOD |

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_cmod_check_run.vbs & del {WORK_TEMP}\sap_cmod_check_run.ps1 & del {WORK_TEMP}\sap_cmod_create_run.vbs & del {WORK_TEMP}\sap_cmod_create_run.ps1 & del {WORK_TEMP}\sap_cmod_change_include_run.vbs & del {WORK_TEMP}\sap_cmod_change_include_run.ps1
```

Also delete `{WORK_TEMP}\<INCLUDE_NAME>.abap` if the user pasted code (not a user-supplied file).

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_cmod_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_cmod_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `CMOD_FAILED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use.

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters.
UTF-8 with BOM causes a cscript compile error.

---

## Upload Menu Path Note

The source upload menu path (`menu[3]/menu[9]/menu[3]/menu[0]`) in the SE38 editor
was recorded on SAP GUI 7.60 / S/4HANA 1909. Menu indices **may differ** by SAP release
and logon language. If the upload step fails:
1. Open SE38 in your SAP system and open the include in Change mode
2. Use SAP Logon > Help > Scripting Recorder and Playback
3. Record the "Upload from local file" menu action (Utilities > More Utilities > Upload/Download > Upload)
4. Note the menu path from the recording and update the VBS template

---

## CMOD Component IDs Reference

**CMOD Initial Screen**

| Element | Component ID | Notes |
|---|---|---|
| Project name field | `wnd[0]/usr/ctxtMOD0-NAME` | GuiCTextField |
| Create button | `wnd[0]/usr/btn%#AUTOTEXT001` | |
| Display button | `wnd[0]/usr/btnPANZ` | |
| Change button | `wnd[0]/usr/btnPAEND` | |

**CMOD Attributes Screen**

| Element | Component ID | Notes |
|---|---|---|
| Project name | `wnd[0]/usr/txtMOD0-NAME` | Read-only |
| Short text | `wnd[0]/usr/txtMOD0-MODTEXT` | Changeable |
| Package | `wnd[0]/usr/ctxtMOD0-DEVCLASS` | Read-only after save |
| Enhancement assignments | `wnd[0]/tbar[1]/btn[23]` | App toolbar |
| Components | `wnd[0]/tbar[1]/btn[27]` | App toolbar |

**CMOD Enhancement Assignment Screen**

| Element | Component ID | Notes |
|---|---|---|
| Enhancement name (row N) | `wnd[0]/usr/sub:SAPLSMOD:0100/ctxtMOD0-EXITNAME[N,0]` | Row-indexed |
| Enhancement text (row N) | `wnd[0]/usr/sub:SAPLSMOD:0100/txtMOD0-MEMTEXT[N,14]` | Auto-fills on Enter |

**SE38 ABAP Editor**

| Element | Component ID | Notes |
|---|---|---|
| Program name field | `wnd[0]/usr/ctxtRS38M-PROGRAMM` | |
| Change button | `wnd[0]/usr/btnCHAP` | |
| Display button | `wnd[0]/usr/btnSHOP` | |
| Editor control | `wnd[0]/usr/cntlEDITOR/shellcont/shell` | AbapEditor |
| Upload menu | `wnd[0]/mbar/menu[3]/menu[9]/menu[3]/menu[0]` | Utilities > More Utilities > Upload/Download > Upload |
| Upload path | `wnd[1]/usr/ctxtDY_PATH` | Directory path |
| Upload filename | `wnd[1]/usr/ctxtDY_FILENAME` | File name |
| Check (Ctrl+F2) | `wnd[0]/tbar[1]/btn[26]` | Syntax check |
| Activate (Ctrl+F3) | `wnd[0]/tbar[1]/btn[27]` | |

**Transport Popup**

| Element | Component ID | Notes |
|---|---|---|
| Local Object button | `wnd[1]/tbar[0]/btn[7]` | Assigns to $TMP |

---

## Troubleshooting Component IDs

If menu paths or component IDs fail on the user's system:
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs
