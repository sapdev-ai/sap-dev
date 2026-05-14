---
name: sap-se54
description: |
  Generates a table maintenance dialog in SAP via SE54 using SAP GUI Scripting.
  Checks if the maintenance dialog already exists, then generates it with
  authorization group, function group, maintenance type, and screen number.
  Existence check and generation flow.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<table-name> [function-group]"
---

# SAP SE54 Table Maintenance Dialog Skill

You generate a table maintenance dialog in a live SAP system via SE54
using SAP GUI Scripting. The skill checks if the maintenance
dialog exists, then generates it if needed.

Task: $ARGUMENTS

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

Start a structured log run. State file: `{WORK_TEMP}\sap_se54_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se54_run.json" -Skill sap-se54 -ParamsJson "{\"table\":\"<TABLE>\"}"
```

---

## Step 1 — Collect Parameters

**Table Maintenance Details**

| Parameter | Description | Example |
|---|---|---|
| Table name | Z/Y custom table or view name | `ZHKTBTEST005` |
| Authorization group | Auth group for SM30 access (use `&NC&` for no check) — **required** | `&NC&` |
| Function group | FG where generated code is stored — **required** | `ZHKT05` |
| Maintenance type | `1` = one step, `2` = two step (default: `1`) | `1` |
| Overview screen | Screen number for the overview screen (default: `0010`) | `0010` |

---

## Step 2 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 3 — Check if Maintenance Dialog Exists

The check VBScript template is at `./references/sap_se54_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se54_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se54_check.vbs' -Raw
$content = $content -replace '%%TABLE_NAME%%','THE_TABLE_NAME'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se54_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_TABLE_NAME` with the actual table name (UPPERCASE) and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se54_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se54_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → maintenance dialog already exists → tell the user and stop. No generation needed.
- `NOT_EXIST` → no maintenance dialog → proceed to Step 4 (Generate).
- `ERROR:` → show full output and stop.

---

## Step 4 — Generate Table Maintenance Dialog

The generate VBScript template is at `./references/sap_se54_generate.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se54_generate_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se54_generate.vbs' -Raw
$content = $content -replace '%%TABLE_NAME%%','THE_TABLE_NAME'
$content = $content -replace '%%AUTH_GROUP%%','THE_AUTH_GROUP'
$content = $content -replace '%%FUNC_GROUP%%','THE_FUNC_GROUP'
$content = $content -replace '%%MAINT_TYPE%%','THE_MAINT_TYPE'
$content = $content -replace '%%OVERVIEW_SCREEN%%','THE_OVERVIEW_SCREEN'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se54_generate_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se54_generate_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se54_generate_run.vbs
```

Proceed to Step 5 to evaluate the result.

---

## Step 5 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user the table maintenance dialog was generated.
- Show the full script output as a code block.
- Mention: "You can now maintain table data via SM30 or SE16."

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `Not on Generation Environment screen` | SE54 navigation failed | Check table name is valid |
| `Unexpected popup` | Unhandled SAP dialog | Use Scripting Recorder to identify popup |
| `Enter an authorization group` | Auth group field left empty | Provide auth group (use `&NC&` for no check) |
| `Generation failed` | SAP rejected the generation | Check status bar message for details |
| `Object Directory Entry` stuck | Transport assignment issue | Check package/transport settings |
| `Function group XXX does not exist` | FG not created yet | Create function group first (SE37 or SE80) |
| `Table/View XXX does not exist` | Invalid table name | Check table exists in SE11 |

---

## Step 6 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_se54_check_run.vbs & del {WORK_TEMP}\sap_se54_check_run.ps1 & del {WORK_TEMP}\sap_se54_generate_run.vbs & del {WORK_TEMP}\sap_se54_generate_run.ps1
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se54_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se54_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE54_FAILED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 6).

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters.
UTF-8 with BOM causes a cscript compile error.

---

## SE54 Component IDs Reference

### Initial Screen — "Generate Table Maintenance Dialog: Initial Table/View Screen"

| Element | Component ID | Type | Notes |
|---|---|---|---|
| Table/View field | `txtVIMDYNFLDS-VIEWNAME` | GuiTextField | Enter table name |
| Generated Objects radio | `radVIMDYNFLDS-ELEM_GEN` | GuiRadioButton | Select this |
| Create/Change button | `btnVIMDYNFLDS-PUSH_GMNT` | GuiButton | Press to proceed |
| Display button | `btnVIMDYNFLDS-PUSH_SHOW` | GuiButton | |
| Delete button | `btnVIMDYNFLDS-PUSH_DELE` | GuiButton | |
| ABAP Dictionary radio | `radVIMDYNFLDS-STRUCT_MNT` | GuiRadioButton | |
| Auth Groups radio | `radVIMDYNFLDS-AUTH_MNT` | GuiRadioButton | |
| Events radio | `radVIMDYNFLDS-EVNTS` | GuiRadioButton | |

### "Create maintenance module" Popup (wnd[1])

Appears when no maintenance dialog exists for the table.

| Element | Component ID | Notes |
|---|---|---|
| Yes button | `wnd[1]/usr/btnSPOP-OPTION1` | Press to proceed to generation |
| No button | `wnd[1]/usr/btnSPOP-OPTION2` | |
| Cancel button | `wnd[1]/usr/btnSPOP-OPTION_CAN` | |

### Generation Environment Screen

| Element | Component ID | Type | Notes |
|---|---|---|---|
| Authorization Group | `ctxtTDDAT-CCLASS` | GuiCTextField | Required |
| Function Group | `ctxtTVDIR-AREA` | GuiCTextField | Required |
| Package | `ctxtTVDIR-DEVCLASS` | GuiCTextField | Auto-filled |
| One step radio | `radVIMDYNFLDS-MTYPE1` | GuiRadioButton | |
| Two step radio | `radVIMDYNFLDS-MTYPE2` | GuiRadioButton | |
| Overview screen | `txtTVDIR-LISTE` | GuiTextField | e.g. 0010 |
| Single Screen | `txtTVDIR-DETAIL` | GuiTextField | For two step only |
| Standard recording | `radVIMDYNFLDS-CORR_CON_S` | GuiRadioButton | |
| Create (F6) | `tbar[1]/btn[6]` | GuiButton | Triggers generation |

### Object Directory Entry Popup (wnd[1])

Appears for each generated object (FUGR, TOBJ).

| Element | Component ID | Notes |
|---|---|---|
| Object name | `wnd[1]/usr/txtKO007-L_OBJ_NAME` | Read-only |
| Package | `wnd[1]/usr/ctxtKO007-L_DEVCLASS` | Default $TMP |
| Save button | `wnd[1]/tbar[0]/btn[0]` | Press to save |

---

## Troubleshooting Component IDs

If component IDs fail on the user's system:
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs
