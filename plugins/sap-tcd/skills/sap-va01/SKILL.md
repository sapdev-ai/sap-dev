---
name: sap-va01
description: |
  Manages SAP sales orders via VA01/VA02/VA03 using SAP GUI Scripting.
  Creates new sales orders or updates existing ones. Existence
  check (VA03 Display), order creation (VA01) with header/item handling,
  order update (VA02), and save. Field values are provided as tab-separated
  section/field/value triples in a definition file.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<order-number-or-action> [field-values-to-set]"
---

# SAP VA01 Sales Order Maintenance Skill

You manage SAP sales orders via VA01 (Create), VA02 (Change), and VA03
(Display) using SAP GUI Scripting. The skill checks if an order
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

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve cross-plugin paths: 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\settings.json` and (if present) `sap-dev-core\settings.local.json`. Read `work_dir`, `custom_url`.

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

Start a structured log run. State file: `{WORK_TEMP}\sap_va01_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_va01_run.json" -Skill sap-va01 -ParamsJson "{\"order\":\"<VBELN>\"}"
```

---

## Step 1 — Collect Parameters

**Sales Order Details**

| Parameter | Description | Example |
|---|---|---|
| Order number | Sales order number (for update/check; blank for new) | `1659` |
| Order type | Sales document type key (for Create only) | `ZTA` |
| Sales organization | Sales organization (for Create only) | `BX01` |
| Distribution channel | Distribution channel (for Create only) | `00` |
| Division | Division (for Create only) | `00` |
| Field values | Header, sales, and item fields (see format below) | See Step 2 |

**Common Order Type Keys:**

| Key | Description |
|---|---|
| `OR` | Standard Order |
| `ZTA` | Standard Order (custom) |
| `RE` | Returns |
| `SO` | Rush Order |
| `CS` | Cash Sales |

---

## Step 2 — Prepare Field Definition File

The field definition file is a tab-separated text file that specifies which fields
to fill. Format:

```
SECTION<TAB>FIELD_NAME<TAB>VALUE
```

- **SECTION**: `HEADER` for header fields, `SALES` for Sales tab fields, or `ITEM_NN` for item rows
- **FIELD_NAME**: SAP ABAP field name (e.g., `KUAGV-KUNNR`, `RV45A-MABNR`)
- **VALUE**: The value to set. For checkboxes use `X`/`1` (checked) or empty/`0` (unchecked)
- Lines starting with `#` are comments. Blank lines are skipped.

**Header Fields (HEADER section):**

| Field Name | Description | Example |
|---|---|---|
| `KUAGV-KUNNR` | Sold-To Party | `20000000` |
| `KUWEV-KUNNR` | Ship-To Party | `20000000` |
| `VBKD-BSTKD` | Customer Reference | `PO-REF-001` |
| `VBKD-BSTDK` | Customer Ref. Date | `2026.04.01` |

**Sales Tab Fields (SALES section):**

| Field Name | Description | Example |
|---|---|---|
| `RV45A-KETDAT` | Requested Delivery Date | `2026.04.15` |
| `RV45A-DWERK` | Delivering Plant | `BX01` |
| `VBKD-PRSDT` | Pricing Date | `2026.04.01` |
| `VBKD-ZTERM` | Payment Terms | `BX01` |
| `VBKD-INCO1` | Incoterms | `EXW` |
| `VBKD-INCO2_L` | Incoterms Location 1 | `Shanghai` |
| `VBAK-AUGRU` | Order Reason (ComboBox key) | `001` |
| `VBAK-LIFSK` | Delivery Block (ComboBox key) | |
| `VBAK-FAKSK` | Billing Block (ComboBox key) | |
| `VBAK-AUTLF` | Complete Delivery (checkbox) | `X` |

**Item Table Fields (ITEM_NN sections):**

Item rows are numbered `ITEM_01`, `ITEM_02`, etc. Each maps to table row 0, 1, etc.

| Field Name | Description | Example |
|---|---|---|
| `RV45A-MABNR` | Material Number | `500070` |
| `RV45A-KWMENG` | Order Quantity | `5` |
| `VBAP-WERKS` | Plant | `BX01` |
| `VBAP-VRKME` | Sales Unit | `PC` |
| `VBAP-PSTYV` | Item Category | `TAN` |
| `VBAP-KDMAT` | Customer Material Number | |

**Example definition file (Create):**
```
# Header
HEADER	KUAGV-KUNNR	20000000
HEADER	VBKD-BSTKD	PO-REF-001
# Sales tab
SALES	RV45A-KETDAT	2026.04.15
SALES	VBKD-ZTERM	BX01
# Item line 1
ITEM_01	RV45A-MABNR	500070
ITEM_01	RV45A-KWMENG	5
# Item line 2
ITEM_02	RV45A-MABNR	500070
ITEM_02	RV45A-KWMENG	10
```

**Example definition file (Update — change customer reference):**
```
HEADER	VBKD-BSTKD	PO-REF-002-UPDATED
```

### Write the definition file

1. Write the field definitions to: `{WORK_TEMP}\va01_<ORDER_NUMBER>_fields.txt`
   - For new orders use a descriptive name: `{WORK_TEMP}\va01_new_fields.txt`
   - Use the tab-separated format above.
   - Include only the fields the user wants to set.
2. Confirm the file by reading it back.

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Order Exists (Update only)

Skip this step if creating a new order.

The check VBScript template is at `./references/sap_va01_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_va01_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_va01_check.vbs' -Raw
$content = $content -replace '%%ORDER_NUMBER%%','THE_ORDER_NUMBER'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_va01_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_ORDER_NUMBER` with the actual order number and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_va01_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_va01_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → order exists → proceed to Step 5a (Update via VA02).
- `NOT_EXIST` → order does not exist → tell user the order was not found.
- `ERROR:` → show full output and stop.

---

## Step 5a — Update Existing Order (VA02)

The update VBScript template is at `./references/sap_va01_update.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_va01_update_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_va01_update.vbs' -Raw
$content = $content -replace '%%ORDER_NUMBER%%','THE_ORDER_NUMBER'
$content = $content -replace '%%DEFINITION_FILE%%','THE_DEFINITION_FILE'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_va01_update_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_ORDER_NUMBER`, `THE_DEFINITION_FILE` (absolute path with backslashes), and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_va01_update_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_va01_update_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Order (VA01)

For creating a new order, you need the Order Type and Sales Area (Sales Org,
Distribution Channel, Division). Ask the user if not already provided.

The create VBScript template is at `./references/sap_va01_create.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_va01_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_va01_create.vbs' -Raw
$content = $content -replace '%%ORDER_TYPE%%','THE_ORDER_TYPE'
$content = $content -replace '%%SALES_ORG%%','THE_SALES_ORG'
$content = $content -replace '%%DIST_CHANNEL%%','THE_DIST_CHANNEL'
$content = $content -replace '%%DIVISION%%','THE_DIVISION'
$content = $content -replace '%%DEFINITION_FILE%%','THE_DEFINITION_FILE'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_va01_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_va01_create_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_va01_create_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user the sales order was created/updated.
- The status bar message contains the order number (e.g., "Standard Order 1659 has been saved.").
- Show the full script output as a code block.

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `Order type ... has not been defined` | Invalid order type for sales area | Check order type key and sales area |
| `does not exist in TVAK` | Order type key doesn't exist | Verify order type key |
| `is not in the database or has been archived` | Order not found (Update) | Check order number |
| `Failed to reach create screen` | Initial screen error | Check order type and sales area values |
| `Failed to reach change screen` | Order can't be opened for change | Check order status/authorization |
| `Header validation failed` | Required header field missing | Ensure Sold-To Party is set |
| `Item validation failed` | Invalid item data | Check material number, quantity |
| `Item table not found` | Screen structure issue | Contact support |
| `Item column not found` | Wrong field name for item | Verify field name (see table below) |
| `No SAP GUI session found` | Not logged in | Run login step first |
| `Definition file not found` | Wrong path | Verify file path and re-run Step 2 |

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_va01_check_run.vbs & del {WORK_TEMP}\sap_va01_check_run.ps1 & del {WORK_TEMP}\sap_va01_create_run.vbs & del {WORK_TEMP}\sap_va01_create_run.ps1 & del {WORK_TEMP}\sap_va01_update_run.vbs & del {WORK_TEMP}\sap_va01_update_run.ps1 & del {WORK_TEMP}\va01_*_fields.txt
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_va01_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_va01_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `VA01_FAILED`, `GUI_TIMEOUT`.
