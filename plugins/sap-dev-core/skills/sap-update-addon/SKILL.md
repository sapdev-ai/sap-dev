---
name: sap-update-addon
description: |
  Insert, update, or delete records in SAP add-on tables (Y/Z prefix).
  Automatically detects the best method:
    1. SM30 — if a maintenance view exists
    2. SE16 — if DD02L-MAINFLAG = 'X' (direct table maintenance allowed)
    3. ZCMRUPDATE_ADDON_TABLE — fallback program for any add-on table
  Requires SAP GUI with an active session. Uses RFC for detection.
argument-hint: "<table-name> <data-file> [<operation>] [<sap-logon-description>]"
---

# SAP Update Add-on Table Skill

You maintain records in SAP add-on tables (Y/Z prefix) by detecting the best method and
executing the appropriate transaction.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — `ZCMRUPDATE_ADDON_TABLE` fallback path executes a deployed ABAP utility program; any change to that utility's source must follow modern-ABAP / OOP / message-class conventions |

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

Start a structured log run. State file: `{WORK_TEMP}\sap_update_addon_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_update_addon_run.json" -Skill sap-update-addon -ParamsJson "{\"table\":\"<TABLE>\"}"
```

---

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:
- **Table name** — required. Must start with Y or Z.
- **Data file path** — required. TAB-delimited text file, UTF-8, 1 header line.
  - Header: field names (uppercase), excluding MANDT
  - Data rows: values separated by TAB
- **Operation** — optional. `INSERT` (default), `UPDATE`, or `DELETE`.
  For ZCMRUPDATE_ADDON_TABLE method, INSERT and UPDATE both result in MODIFY (upsert).
- **SAP Logon description** — optional. Used for credential lookup.

If the user provides inline data instead of a file, write it to `{WORK_TEMP}\<TABLE_NAME>_data.txt`
as a TAB-delimited file with header.

Verify the data file exists:
```bash
powershell -Command "if (Test-Path 'THE_FILE') { 'EXISTS' } else { 'NOT FOUND' }"
```

---

## Step 2 — Read SAP Connection Parameters

Read SAP connection parameters from the merged sap-dev-core settings (per `shared/rules/settings_lookup.md` — `settings.local.json` overrides `settings.json` per-key on the `.value` field):

| Setting key | Maps to | Example |
|---|---|---|
| `sap_application_server` | `%%SAP_SERVER%%` | `10.0.0.1` |
| `sap_system_number` | `%%SAP_SYSNR%%` | `00` |
| `sap_client` | `%%SAP_CLIENT%%` | `100` |
| `sap_user` | `%%SAP_USER%%` | `DEVELOPER` |
| `sap_password` | `%%SAP_PASSWORD%%` | *(masked)* |
| `sap_language` | `%%SAP_LANGUAGE%%` | `EN` |

**If settings are not configured**, ask the user to provide the values and suggest
they configure settings.json for future use.

### Ensure SAP GUI session is active

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 3 — Detect Best Method

The detection PowerShell template is at `./references/sap_update_addon_detect.ps1`.

Write `{WORK_TEMP}\sap_update_addon_detect_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_update_addon_detect.ps1', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_SERVER%%',   'THE_SERVER')
$content = $content.Replace('%%SAP_SYSNR%%',    'THE_SYSNR')
$content = $content.Replace('%%SAP_CLIENT%%',   'THE_CLIENT')
$content = $content.Replace('%%SAP_USER%%',     'THE_USER')
$content = $content.Replace('%%SAP_PASSWORD%%', 'THE_PASSWORD')
$content = $content.Replace('%%SAP_LANGUAGE%%', 'THE_LANGUAGE')
$content = $content.Replace('%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$content = $content.Replace('%%TABLE_NAME%%',   'THE_TABLE_NAME')
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_update_addon_detect_run.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Execute via 32-bit PowerShell:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_update_addon_detect_run.ps1"
```

Parse the output lines:
- `RESULT_SM30:True` / `RESULT_SM30:False`
- `RESULT_MAINFLAG:X` / `RESULT_MAINFLAG:`
- `RESULT_PROG:True` / `RESULT_PROG:False`
- `RESULT_METHOD:SM30` / `SE16` / `PROG` / `NONE`

If `RESULT_METHOD:NONE`, tell the user no method is available and suggest deploying
ZCMRUPDATE_ADDON_TABLE first using the sap-se38 skill.

**Detection-attach failure (exit code 2):** On some Windows 11 + SAP GUI 760+
builds, `GetActiveObject("SAPGUI")` fails with `CO_E_CLASSSTRING` ("Invalid
class string") because the SAPGUI ProgID is not registered in the Running
Object Table for the calling process bitness. The detect script tries
`SAPGUI`, `SAPGUI.ScriptingCtrl.1`, and `SapGui.ScriptingCtrl.1` in turn; if
all fail it exits with code 2. When you see exit code 2, **skip detection
entirely and proceed directly to Step 4c (PROG method)** — the universal
ZCMRUPDATE_ADDON_TABLE program path uses VBS `GetObject("SAPGUI")` which is
not affected by the same registration issue.

---

## Step 4 — Execute Using Detected Method

### Step 4a — SM30 Method

Template: `./references/sap_update_addon_sm30.vbs`

Write `{WORK_TEMP}\sap_update_addon_sm30_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_update_addon_sm30.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%TABLE_NAME%%', 'THE_TABLE_NAME')
$content = $content.Replace('%%DATA_FILE%%',  'THE_DATA_FILE')
$content = $content.Replace('%%OPERATION%%',  'THE_OPERATION')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_update_addon_sm30_run.vbs', $content, [System.Text.Encoding]::Unicode)
Write-Host 'Done'
```

Execute:
```bash
powershell -Command "& cscript //NoLogo '{WORK_TEMP}\sap_update_addon_sm30_run.vbs'"
```

**SM30 Notes:**
- SM30 may show a transport request dialog — the VBS handles it
- Field IDs use pattern `ctxt<TABLE>-<FIELD>` or `txt<TABLE>-<FIELD>`
- New Entries button is typically `tbar[1]/btn[14]`
- Save via Ctrl+S (sendVKey 11)

### Step 4b — SE16 Method

Template: `./references/sap_update_addon_se16.vbs`

Write `{WORK_TEMP}\sap_update_addon_se16_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_update_addon_se16.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%TABLE_NAME%%', 'THE_TABLE_NAME')
$content = $content.Replace('%%DATA_FILE%%',  'THE_DATA_FILE')
$content = $content.Replace('%%OPERATION%%',  'THE_OPERATION')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_update_addon_se16_run.vbs', $content, [System.Text.Encoding]::Unicode)
Write-Host 'Done'
```

Execute:
```bash
powershell -Command "& cscript //NoLogo '{WORK_TEMP}\sap_update_addon_se16_run.vbs'"
```

**SE16 Notes:**
- SE16 Create Entries button: `tbar[1]/btn[18]` or menu `Table > Create Entry`
- Fields on the entry form: `ctxt<TABLE>-<FIELD>` or `txt<TABLE>-<FIELD>`
- Each record is saved individually with Ctrl+S

### Step 4c — ZCMRUPDATE_ADDON_TABLE Method

First, ensure the ZCMRUPDATE_ADDON_TABLE program is available. If not, tell the user to deploy it using the sap-se38 skill.
The source code for ZCMRUPDATE_ADDON_TABLE is at `./references/ZCMRUPDATE_ADDON_TABLE.abap` for reference.

Template: `./references/sap_update_addon_prog.vbs`

Write `{WORK_TEMP}\sap_update_addon_prog_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_update_addon_prog.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%TABLE_NAME%%', 'THE_TABLE_NAME')
$content = $content.Replace('%%DATA_FILE%%',  'THE_DATA_FILE')
$content = $content.Replace('%%TEMP_DIR%%',   '{WORK_TEMP}')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_update_addon_prog_run.vbs', $content, [System.Text.Encoding]::Unicode)
Write-Host 'Done'
```

Execute:
```bash
powershell -Command "& cscript //NoLogo '{WORK_TEMP}\sap_update_addon_prog_run.vbs'"
```

If output file was saved, read `{WORK_TEMP}\sap_update_addon_output.txt` for results.

---

## Step 5 — Report Result

Show the user:
1. Which method was selected and why
2. The operation result (success/error counts)
3. Any errors encountered

---

## Step 6 — Clean Up

```bash
cmd /c del {WORK_TEMP}\sap_update_addon_detect_run.ps1 {WORK_TEMP}\sap_update_addon_sm30_run.vbs {WORK_TEMP}\sap_update_addon_sm30_run.ps1 {WORK_TEMP}\sap_update_addon_se16_run.vbs {WORK_TEMP}\sap_update_addon_se16_run.ps1 {WORK_TEMP}\sap_update_addon_prog_run.vbs {WORK_TEMP}\sap_update_addon_prog_run.ps1 {WORK_TEMP}\sap_update_addon_output.txt
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_update_addon_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_update_addon_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `UPDATE_ADDON_FAILED`, `RFC_LOGON_FAILED`.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `RESULT_METHOD:NONE` | No method available | Deploy ZCMRUPDATE_ADDON_TABLE first |
| `SM30 transport dialog` | Table in transportable package | Enter transport or Cancel |
| `SE16 Create Entries not found` | MAINFLAG not set or editing blocked | Fall back to PROG method |
| `ZCMRUPDATE_ADDON_TABLE field mismatch` | Data file header doesn't match table | Check field names match table definition |
