---
name: sap-mm01
description: |
  Manages SAP material masters via MM01/MM02/MM03 using SAP GUI Scripting.
  Creates new materials or updates existing ones. Existence
  check (MM03 Display), material creation (MM01) with view/org-level handling,
  material update (MM02), and save. Field values are provided as tab-separated
  section/field/value triples in a definition file.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<material-number> [field-values-to-set]"
---

# SAP MM01 Material Master Maintenance Skill

You manage SAP material masters via MM01 (Create), MM02 (Change), and MM03
(Display) using SAP GUI Scripting. The skill checks if the material
exists, then creates or updates it with the provided field values.

Task: $ARGUMENTS

---

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

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve cross-plugin paths: 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\settings.json` and (if present) `sap-dev-core\settings.local.json`. Read `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` / `*_run.vbs` and the `_run.json` state) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{RUN_TEMP}\sap_mm01_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_mm01_run.json" -Skill sap-mm01 -ParamsJson "{\"material\":\"<MATNR>\"}"
```

---

## Step 1 — Collect Parameters

**Material Master Details**

| Parameter | Description | Example |
|---|---|---|
| Material number | Material to create or update | `ZHKMAT013` |
| Industry sector | Industry sector key (only for Create) | `M` |
| Material type | Material type key (only for Create) | `FERT` |
| Plant | Plant number | `1000` |
| Field values | Field values per view (see format below) | See Step 2 |

**Industry Sector Keys:**

| Key | Description |
|---|---|
| `M` | Mechanical engineering |
| `C` | Chemical industry |
| `P` | Pharmaceuticals |
| `A` | Plant engineering/construction |

**Common Material Type Keys:**

| Key | Description |
|---|---|
| `FERT` | Finished Product |
| `HALB` | Semifinished Product |
| `ROH` | Raw Material |
| `HIBE` | Operating supplies |
| `ERSA` | Spare parts |
| `KMAT` | Configurable materials |

---

## Step 2 — Prepare Field Definition File

The field definition file is a tab-separated text file that specifies which fields
to fill in each material master view. Format:

```
SECTION<TAB>FIELD_NAME<TAB>VALUE
```

- **SECTION**: `ORG` for organizational levels, or tab panel ID (`SP01`–`SP35`) for view fields
- **FIELD_NAME**: SAP ABAP field name (e.g., `MARA-MEINS`, `MARC-DISMM`)
- **VALUE**: The value to set. For checkboxes use `X`/`1` (checked) or empty/`0` (unchecked)
- Lines starting with `#` are comments. Blank lines are skipped.

**Tab Panel IDs:**

| Tab ID | View Name | Key Fields |
|---|---|---|
| `SP01` | Basic Data 1 | `MAKT-MAKTX` (Description), `MARA-MEINS` (Base UoM), `MARA-MATKL` (Material Group), `MARA-SPART` (Division), `MARA-BRGEW` (Gross Weight), `MARA-GEWEI` (Weight Unit), `MARA-NTGEW` (Net Weight) |
| `SP02` | Basic Data 2 | |
| `SP04` | Sales: Sales Org. 1 | `MARA-SPART` (Division) |
| `SP05` | Sales: Sales Org. 2 | |
| `SP06` | Sales: General/Plant | |
| `SP10` | Purchasing | `MARA-BSTME` (Order Unit), `MARC-EKGRP` (Purchasing Group) |
| `SP13` | MRP 1 | `MARC-DISMM` (MRP Type), `MARC-DISPO` (MRP Controller), `MARC-DISLS` (Lot Size), `MARC-EKGRP` (Purchasing Group) |
| `SP14` | MRP 2 | `MARC-BESKZ` (Procurement Type), `MARC-LGPRO` (Issue Storage Loc.), `MARC-LGFSB` (Default Storage Loc.), `MARC-WEBAZ` (GR Processing Time), `MARC-DZEIT` (In-House Production Time) |
| `SP15` | MRP 3 | |
| `SP16` | MRP 4 | |
| `SP20` | Work Scheduling | |
| `SP21` | Plant Data / Storage 1 | |
| `SP22` | Plant Data / Storage 2 | |
| `SP26` | Quality Management | |
| `SP27` | Accounting 1 | (nested tabstrip — accounting fields) |
| `SP28` | Accounting 2 | |
| `SP29` | Costing 1 | |
| `SP30` | Costing 2 | |

**Organizational Level Fields (ORG section):**

| Field Name | Description | Example |
|---|---|---|
| `RMMG1-WERKS` | Plant | `1000` |
| `RMMG1-LGORT` | Storage Location | `1001` |
| `RMMG1-VKORG` | Sales Organization | `1000` |
| `RMMG1-VTWEG` | Distribution Channel | `10` |
| `RMMG1-BWTAR` | Valuation Type | |

**Example definition file:**
```
# Organizational levels
ORG	RMMG1-WERKS	1000
# Basic Data 1
SP01	MAKT-MAKTX	Test Material HK 013
SP01	MARA-MEINS	PC
SP01	MARA-MATKL	0001
SP01	MARA-SPART	01
SP01	MARA-BRGEW	100
SP01	MARA-GEWEI	KG
SP01	MARA-NTGEW	98
SP01	MARA-MTPOS_MARA	NORM
# MRP 1
SP13	MARC-DISMM	PD
SP13	MARC-DISPO	001
SP13	MARC-DISLS	EX
SP13	MARC-EKGRP	101
# MRP 2
SP14	MARC-BESKZ	E
SP14	MARC-LGPRO	1001
SP14	MARC-LGFSB	1001
SP14	MARC-WEBAZ	7
SP14	MARC-DZEIT	5
```

### Write the definition file

1. Write the field definitions to: `{RUN_TEMP}\<MATERIAL>_fields.txt`
   - The per-run directory keeps concurrent sessions from clobbering each other's files.
   - Write the file as UTF-8 (the VBS reads it via ADODB.Stream `Charset="utf-8"`, so JA/ZH values survive intact).
   - Use the tab-separated format above.
   - Include only the views and fields the user wants to set.
   - If the user references an existing material, use MM03 to look up its field values.
2. Confirm the file by reading it back.

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Material Exists

The check VBScript template is at `./references/sap_mm01_check.vbs`.

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_mm01_check_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_mm01_check.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%MATERIAL%%','THE_MATERIAL'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_mm01_check_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_MATERIAL` with the actual material number and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_mm01_check_run.ps1"
```

### Execute

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo {RUN_TEMP}\sap_mm01_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → material exists → proceed to Step 5a (Update via MM02).
- `NOT_EXIST` → material does not exist → proceed to Step 5b (Create via MM01).
- `ERROR:` → show full output and stop. The check reports `NOT_EXIST` only for the
  known MM03 not-found message (M3 305, matched via the locale-independent
  MessageId/MessageNumber); any other error state (authorization, lock, unexpected
  screen/popup) is `ERROR` — never create against an undetermined material.

---

## Step 5a — Update Existing Material (MM02)

The update VBScript template is at `./references/sap_mm01_update.vbs`.

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_mm01_update_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_mm01_update.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%MATERIAL%%','THE_MATERIAL'
$content = $content -replace '%%DEFINITION_FILE%%','THE_DEFINITION_FILE'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_mm01_update_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_MATERIAL`, `THE_DEFINITION_FILE` (absolute path with backslashes), and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_mm01_update_run.ps1"
```

### Execute

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo {RUN_TEMP}\sap_mm01_update_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Material (MM01)

For creating a new material, you need the Industry Sector and Material Type.
Ask the user if not already provided:
> "This is a new material. Please provide the Industry Sector and Material Type."

The create VBScript template is at `./references/sap_mm01_create.vbs`.

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_mm01_create_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_mm01_create.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%MATERIAL%%','THE_MATERIAL'
$content = $content -replace '%%INDUSTRY%%','THE_INDUSTRY'
$content = $content -replace '%%MATERIAL_TYPE%%','THE_MATERIAL_TYPE'
$content = $content -replace '%%DEFINITION_FILE%%','THE_DEFINITION_FILE'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_mm01_create_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_mm01_create_run.ps1"
```

### Execute

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo {RUN_TEMP}\sap_mm01_create_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user the material was created/updated.
- Parse the machine-readable `MATERIAL: <number>` line (echoed right before
  `SUCCESS:`) for the saved material number.
- Show the full script output as a code block.

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `does not exist or is not activated` | Material not found (Update) | Create first or check material number |
| `Enter a material type` | Missing material type (Create) | Provide material type and industry sector |
| `Failed to reach data screen` | View/org level issue | Check org-level values (plant, sales org) |
| `Field not found` | Field name mismatch | Verify ABAP field name for the target view |
| `Material creation failed` | SAP validation error | Check status bar message, fix field values |
| `Could not confirm the save` | Save ended without an S status (warning left standing, empty status) | Read the echoed status text, fix the data, re-run; verify via Step 4 whether the material was saved |
| `Unexpected popup` | Unknown modal appeared — the script refuses to blind-dismiss real business-record dialogs | Resolve the popup manually in SAP GUI, then re-run |
| `Could not determine existence` | Check hit an sbar E that is not the known not-found message (auth/lock) | Read the echoed MessageId/MessageNumber and resolve the underlying error |
| `No SAP GUI session found` | Not logged in | Run login step first |
| `Definition file not found` | Wrong path | Verify file path and re-run Step 2 |

---

## Step 7 — Clean Up

Delete the temporary files this run created — only the exact definition file
written in Step 2, never a wildcard over a shared directory:
```bash
cmd /c del {RUN_TEMP}\sap_mm01_check_run.vbs & del {RUN_TEMP}\sap_mm01_check_run.ps1 & del {RUN_TEMP}\sap_mm01_create_run.vbs & del {RUN_TEMP}\sap_mm01_create_run.ps1 & del {RUN_TEMP}\sap_mm01_update_run.vbs & del {RUN_TEMP}\sap_mm01_update_run.ps1 & del {RUN_TEMP}\<MATERIAL>_fields.txt
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_mm01_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_mm01_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `MM01_FAILED`, `GUI_TIMEOUT`.
