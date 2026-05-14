---
name: sap-se19
description: |
  Creates BAdI implementations via SE19 (New BAdI / Enhancement Framework) and
  deploys method source to the implementing class via SE24 using SAP GUI
  Scripting. Two-level creation: Enhancement Implementation (container) then
  BAdI Implementation (element) with implementing class. Uploads full class
  source via SE24 source-code-based view Upload menu.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<enhancement-spot> <enhancement-impl-name> [path-to-source]"
---

# SAP SE19 BAdI Implementation Skill

You create BAdI implementations via SE19 (New BAdI / Enhancement Framework) and
deploy method source to the implementing class via SE24 using SAP GUI Scripting.
The skill checks if the Enhancement Implementation exists, creates it
with a BAdI Implementation if needed, and optionally uploads class source.

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

Start a structured log run. State file: `{WORK_TEMP}\sap_se19_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se19_run.json" -Skill sap-se19 -ParamsJson "{\"impl\":\"<IMPL>\",\"badi\":\"<BADI>\"}"
```

---

## Step 1 — Collect Parameters

**SE19 BAdI Details**

| Parameter | Description | Example |
|---|---|---|
| Enhancement Spot | SAP Enhancement Spot containing the BAdI definition | `ME_PROCESS_PO_CUST` |
| Enhancement Implementation | Z-namespace implementation name, max 30 chars | `ZHK_BADI_PO_001` |
| Enh Impl short text | Short description for the Enhancement Implementation | `PO processing enhancement` |
| BAdI Definition | BAdI definition name within the Enhancement Spot | `ME_PROCESS_PO_CUST` |
| BAdI Implementation | Z-namespace BAdI implementation name | `ZHK_IM_PO_001` |
| Implementing Class | Z-namespace class name for the BAdI implementation | `ZCL_IM_ZHK_PO_001` |
| BAdI Impl short text | Short description for the BAdI Implementation | `PO processing BAdI impl` |

**Method Source** (optional — only if deploying method code)

| Parameter | Description | Example |
|---|---|---|
| Source | Full class source: absolute path to `.abap` file, OR paste code directly. Must include complete CLASS DEFINITION and CLASS IMPLEMENTATION sections. | |

---

## Step 2 — Prepare ABAP Source File (if deploying method source)

Skip this step if the user only wants to create the Enhancement/BAdI Implementation
without changing method source.

**Important:** The source file must contain the **complete class source** including
`CLASS ... DEFINITION` and `CLASS ... IMPLEMENTATION` sections. SE24 source-code-based
view upload replaces the entire class source.

**If the user pasted source code directly:**

1. Write the source to: `{WORK_TEMP}\<IMPL_CLASS>.abap`
   - Use the Write tool with the exact ABAP source as content.
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

## Step 4 — Check if Enhancement Implementation Exists

The check VBScript template is at `./references/sap_se19_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se19_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se19_check.vbs' -Raw
$content = $content -replace '%%ENH_IMPL_NAME%%','THE_ENH_IMPL_NAME'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se19_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_ENH_IMPL_NAME` with the actual Enhancement Implementation name (UPPERCASE) and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se19_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se19_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → Enhancement Implementation already exists → skip to Step 5b (Update Method Source) if deploying source, or report that it already exists.
- `NOT_EXIST` → Enhancement Implementation does not exist → proceed to Step 5a (Create).
- `ERROR:` → show full output and stop.

---

## Step 5a — Create Enhancement Implementation + BAdI Implementation

If the Enhancement Implementation does not exist, create it along with a BAdI
Implementation and its implementing class. You need all SE19 parameters from Step 1.

The create VBScript template is at `./references/sap_se19_create.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se19_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se19_create.vbs' -Raw
$content = $content -replace '%%ENH_SPOT%%','THE_ENH_SPOT'
$content = $content -replace '%%ENH_IMPL_NAME%%','THE_ENH_IMPL_NAME'
$content = $content -replace '%%ENH_IMPL_TEXT%%','THE_ENH_IMPL_TEXT'
$content = $content -replace '%%BADI_DEFINITION%%','THE_BADI_DEFINITION'
$content = $content -replace '%%BADI_IMPL_NAME%%','THE_BADI_IMPL_NAME'
$content = $content -replace '%%IMPL_CLASS%%','THE_IMPL_CLASS'
$content = $content -replace '%%BADI_IMPL_TEXT%%','THE_BADI_IMPL_TEXT'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se19_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace all `THE_*` placeholders (UPPERCASE for names) and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se19_create_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se19_create_run.vbs
```

**On success** (output contains `SUCCESS:`): proceed to Step 5b if deploying source, or Step 6 to report.

**On failure** (output contains `ERROR:`): show full output and diagnose:

| Error message | Cause | Fix |
|---|---|---|
| `Create Enhancement Implementation popup did not appear` | Enhancement Spot not found or already implemented | Verify Enhancement Spot exists; check if implementation already exists |
| `Could not create Enhancement Implementation` | Name conflict or authorization | Check naming convention (Z-namespace), SAP authorization |
| `Could not press Create BAdI Implementation button` | Tree toolbar ID mismatch | Use SAP Scripting Recorder to find correct toolbar button |
| `Create BAdI Implementation popup did not appear` | Tab not selected or tree issue | Verify TABS_5 tab is active |
| `Class creation failed` | Class name conflict or authorization | Verify class name doesn't already exist (SE24) |
| `Transport dialog` | Object in transportable package | Use transport request or reassign to $TMP |

---

## Step 5b — Update Implementing Class Source (via SE24)

If deploying method source, upload the full class source to the implementing class
via SE24 (Class Builder) in source-code-based view.

**Important:** SE24 must be configured for source-code-based view (not form-based).
If the class opens in form-based view, the user must change SE24 settings first:
Utilities > Settings > Display tab > select "Source Code-Based".

The update method VBScript template is at `./references/sap_se19_update_method.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se19_update_method_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se19_update_method.vbs' -Raw
$content = $content -replace '%%IMPL_CLASS%%','THE_IMPL_CLASS'
$content = $content -replace '%%ABAP_SOURCE_FILE%%','THE_SOURCE_PATH'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se19_update_method_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_IMPL_CLASS` (UPPERCASE), `THE_SOURCE_PATH` (absolute path with backslashes), and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se19_update_method_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se19_update_method_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user what was accomplished (Enhancement Implementation created, BAdI Implementation added, class source deployed).
- Show the full script output as a code block.

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `SE24 class name field not found` | Component ID mismatch | Use SAP Scripting Recorder to find correct ID |
| `Could not open class in change mode` | Class locked or no authorization | Check locks (SM12) or authorization |
| `Class is in form-based view` | SE24 not configured for source-code view | SE24 > Utilities > Settings > Display > Source Code-Based |
| `Could not open Upload menu` | Menu path differs by SAP version | Use Scripting Recorder to record correct menu path |
| `Upload dialog interaction failed` | Upload dialog IDs differ | Re-record the upload step |
| `Upload may have failed` | File encoding or path issue | Check file path, ensure ABAP source is valid |
| `Source file not found` | Wrong path or file not written | Verify path, re-run Step 2 |
| `Activation errors` | ABAP syntax or dependency errors | Show error message, ask user to fix code |
| `Transport dialog` | Object in transportable package | Use transport request or reassign to $TMP |

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_se19_check_run.vbs & del {WORK_TEMP}\sap_se19_check_run.ps1 & del {WORK_TEMP}\sap_se19_create_run.vbs & del {WORK_TEMP}\sap_se19_create_run.ps1 & del {WORK_TEMP}\sap_se19_update_method_run.vbs & del {WORK_TEMP}\sap_se19_update_method_run.ps1
```

Also delete `{WORK_TEMP}\<IMPL_CLASS>.abap` if the user pasted code (not a user-supplied file).

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se19_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se19_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE19_FAILED`, `BADI_NOT_FOUND`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters.
UTF-8 with BOM causes a cscript compile error.

---

## Upload Menu Path Note

The source upload menu path in the SE24 Class Builder (`menu[3]/menu[9]/menu[2]/menu[0]`)
was recorded on SAP GUI 7.60 / S/4HANA 1909. Menu indices **may differ** by SAP release
and logon language. If the upload step fails:
1. Open SE24 in your SAP system and open the class in Change mode
2. Use SAP Logon > Help > Scripting Recorder and Playback
3. Record the "Upload from local file" menu action (Utilities > More Utilities > Upload/Download > Upload)
4. Note the menu path from the recording and update the VBS template

---

## SE19 Component IDs Reference

**SE19 Initial Screen** — `BAdI Builder: Initial Screen for Implementations`

| Element | Component ID | Notes |
|---|---|---|
| New BAdI radio (Edit) | `wnd[0]/usr/radG_IS_NEW_1` | Edit section |
| Enhancement Implementation | `wnd[0]/usr/ctxtG_ENHNAME` | Edit section |
| Display button | `wnd[0]/usr/btnPUSHBUTTON_DISPLAY_TEXT` | |
| Change button | `wnd[0]/usr/btnPUSHBUTTON_CHANGE_TEXT` | |
| New BAdI radio (Create) | `wnd[0]/usr/radG_IS_NEW_2` | Create section |
| Enhancement Spot | `wnd[0]/usr/ctxtG_ENHSPOTNAME` | Create section |
| Create button | `wnd[0]/usr/btnPUSHBUTTON_IMPLEMENT_TEXT` | |

**Create Enhancement Implementation Popup** (wnd[1])

| Element | Component ID | Notes |
|---|---|---|
| Enhancement Impl name | `wnd[1]/usr/txtG_ENHSTRU-ENHNAME` | |
| Short Text | `wnd[1]/usr/txtG_ENHSTRU-SHORTTEXT` | |
| Composite | `wnd[1]/usr/ctxtG_ENHSTRU-COMPOSITE` | Optional |
| Continue | `wnd[1]/tbar[0]/btn[0]` | Enter/Continue |

**Enhancement Implementation Detail Screen**

| Element | Component ID | Notes |
|---|---|---|
| Impl name | `txtENH_EDT_LAYOUT-OBJECT1` | Read-only |
| Status | `txtENH_EDT_LAYOUT-VERSION_TX` | e.g. "Inactive" |
| Tab strip | `tabsTS_ENHANCEMENTS` | |
| Properties tab | `tabpTABS_1` | |
| Enh Impl Elements tab | `tabpTABS_5` | |
| Check button | `tbar[1]/btn[26]` | Ctrl+F2 |
| Activate button | `tbar[1]/btn[27]` | Ctrl+F3 |

**TABS_5 Tree (Enh. Implementation Elements)**

| Element | Path | Notes |
|---|---|---|
| Tree base | `tabpTABS_5/ssubSUBS_5:SAPLENH_EDT_BADI:2100/splcSPLITTER:SAPLENH_EDT_BADI:2100/ssubBADI_TREE_LEFT:SAPLENH_EDT_BADI:0099/cntlBADI_IMPL_TREE/shellcont/shell/shellcont[1]` | |
| Toolbar | `...shellcont[1]/shell[0]` | GuiToolbarControl |
| Tree control | `...shellcont[1]/shell[1]` | GuiTree |
| Create BAdI Impl | `FC_CREATE_BADI_IMPL` | Toolbar button |
| Delete BAdI Impl | `FC_DELETE_BADI_IMPL` | Toolbar button |

**Create BAdI Implementation Popup** (wnd[1])

| Element | Component ID | Notes |
|---|---|---|
| Enhancement Spot | `wnd[1]/usr/ctxtENH_BADI_IMPL_CREATE-SPOT` | Read-only |
| BAdI Definition | `wnd[1]/usr/ctxtENH_BADI_IMPL_CREATE-BADI_DEFINITION` | |
| BAdI Implementation | `wnd[1]/usr/txtENH_BADI_IMPL_CREATE-BADI_IMPLEMENTATION` | |
| Implementing Class | `wnd[1]/usr/ctxtENH_BADI_IMPL_CREATE-IMPL_CLASS` | Must provide explicitly |
| Short Text | `wnd[1]/usr/txtENH_BADI_IMPL_CREATE-IMPL_SHORTTEXT` | |
| Continue | `wnd[1]/tbar[0]/btn[0]` | Needs TWO presses |

**Class Creation Chain** (wnd[2])

| Element | Component ID | Notes |
|---|---|---|
| "Class ..." Yes | `wnd[2]/usr/btnBUTTON_1` | Confirm class creation |
| Create Empty Class | `wnd[2]/tbar[0]/btn[2]` | F2 |
| Copy Sample | `wnd[2]/tbar[0]/btn[5]` | F5 |
| Inherit | `wnd[2]/tbar[0]/btn[6]` | F6 |
| Local Object | `wnd[2]/tbar[0]/btn[7]` | F7 (transport popup) |

**SE24 Class Builder** (for source upload)

| Element | Component ID | Notes |
|---|---|---|
| Class name | `wnd[0]/usr/ctxtSEOCLASS-CLSNAME` | |
| Change button | `wnd[0]/usr/btnPUSH_CHANGE` | |
| Source-code view indicator | `wnd[0]/usr/txtDY0400_STATUS` | Present in source view |
| Form-based tab strip | `wnd[0]/usr/tabsCTS` | Present in form view |
| Upload menu | `wnd[0]/mbar/menu[3]/menu[9]/menu[2]/menu[0]` | Utilities > More Utilities > Upload/Download > Upload |
| Upload path | `wnd[1]/usr/ctxtDY_PATH` | Directory path |
| Upload filename | `wnd[1]/usr/ctxtDY_FILENAME` | File name |

**Transport Popup**

| Element | Component ID | Notes |
|---|---|---|
| Local Object button | Various `/tbar[0]/btn[7]` | Assigns to $TMP |

---

## Troubleshooting Component IDs

If menu paths or component IDs fail on the user's system:
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs

---

## Two-Level Creation Note

SE19 New BAdI has a **two-level** structure:

1. **Enhancement Implementation** (outer container) — created via the "Create" section
   on the SE19 initial screen. This is the top-level object registered in the system.

2. **BAdI Implementation** (inner element) — added within the Enhancement Implementation
   via the tree toolbar button `FC_CREATE_BADI_IMPL` on the "Enh. Implementation Elements"
   tab (TABS_5).

The Create BAdI Implementation popup requires **two Enter presses**: the first submits the
fields, the popup re-displays with read-only fields for confirmation, and the second Enter
triggers the class creation chain (Yes/No → Create Empty Class → Local Object).

After class creation, wnd[1] may auto-close. If it remains, dismiss with F12 (Cancel).
