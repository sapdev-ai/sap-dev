---
name: sap-bp
description: |
  Manages SAP Business Partners via the BP transaction using SAP GUI Scripting.
  Creates new partners (Organization type) or updates existing ones.
  Existence check, partner creation with role/grouping selection, and
  partner update with field values from a definition file.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<bp-number> [field-values-to-set]"
---

# SAP BP Business Partner Maintenance Skill

You manage SAP Business Partners via the BP transaction (Create, Change,
Display) using SAP GUI Scripting. The skill checks if the partner
exists, then creates or updates it with the provided field values.

Task: $ARGUMENTS

---

## Step 0 — Resolve Work Directory

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

Start a structured log run. State file: `{WORK_TEMP}\sap_bp_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_bp_run.json" -Skill sap-bp -ParamsJson "{\"bp_number\":\"<BP>\"}"
```

---

## Step 1 — Collect Parameters

**Business Partner Details**

| Parameter | Description | Example |
|---|---|---|
| BP number | Business Partner number (blank = auto-assign on create) | `14` |
| BP role | Role key (only for Create) | `FLCU01` |
| BP grouping | Grouping key (only for Create, blank = default) | `0010` |
| Field values | Field values per tab (see format below) | See Step 2 |

**Common BP Role Keys:**

| Key | Description |
|---|---|
| `000000` | Business Partner (Gen.) |
| `FLCU01` | Customer |
| `FLCU00` | FI Customer |
| `FLVN01` | Purchase Vendor |
| `FLVN00` | FI Vendor |
| `BUP002` | Prospect |
| `CRM000` | Sold-To Party |

---

## Step 2 — Prepare Field Definition File

The field definition file is a tab-separated text file that specifies which fields
to fill on each Business Partner tab. Format:

```
SECTION<TAB>FIELD_NAME<TAB>VALUE
```

- **SECTION**: Tab panel ID (`TAB_01`–`TAB_14`) for General Data view fields
- **FIELD_NAME**: SAP field name (e.g., `BUT000-NAME_ORG1`, `ADDR1_DATA-CITY1`)
- **VALUE**: The value to set. For ComboBox fields use the key. For checkboxes use `X`/`1` (checked) or empty/`0` (unchecked)
- Lines starting with `#` are comments. Blank lines are skipped.

**Tab Panel IDs (General Data View):**

| Tab ID | Tab Name | Key Fields |
|---|---|---|
| `TAB_01` | Address | `BUT000-NAME_ORG1` (Name 1), `BUT000-NAME_ORG2` (Name 2), `BUT000-NAME_ORG4` (Name 3), `BUS000FLDS-TITLE_MEDI` (Title ComboBox), `BUT000-TITLE_LET` (Salutation), `BUS000FLDS-BU_SORT1_TXT` (Search Term), `ADDR1_DATA-STREET` (Street), `ADDR1_DATA-HOUSE_NUM1` (House No.), `ADDR1_DATA-POST_CODE1` (Postal Code), `ADDR1_DATA-CITY1` (City), `ADDR1_DATA-COUNTRY` (Country), `ADDR1_DATA-REGION` (Region), `ADDR1_DATA-LANGU` (Language ComboBox), `SZA1_D0100-TEL_NUMBER` (Phone), `SZA1_D0100-SMTP_ADDR` (Email), `SZA1_D0100-MOB_NUMBER` (Mobile) |
| `TAB_02` | Address Overview | (Multiple addresses — read only in most cases) |
| `TAB_03` | Identification | (ID type/number fields) |
| `TAB_04` | Control | (Control fields — authorization group, etc.) |
| `TAB_05` | Payment Transactions | (Bank details) |
| `TAB_06` | Status | (Status flags) |
| `TAB_07` | Where-Used List | (Read only) |
| `TAB_08` | Additional Texts (Create) / Legal Data (Change) | |
| `TAB_09` | Technical Identification (Create) / Customer: General Data (Change) | |
| `TAB_10` | — (Change only) Customer: Tax Data | |
| `TAB_11` | — (Change only) Customer: Additional Data | |
| `TAB_12` | — (Change only) Customer: Unloading Points | |
| `TAB_13` | — (Change only) Customer: Texts | |
| `TAB_14` | — (Change only) Transport Data | |

**Example definition file:**
```
# Address tab
TAB_01	BUT000-NAME_ORG1	Test Company Ltd
TAB_01	BUT000-NAME_ORG2	Asia Pacific Division
TAB_01	BUS000FLDS-BU_SORT1_TXT	TESTCO
TAB_01	ADDR1_DATA-STREET	123 Main Street
TAB_01	ADDR1_DATA-POST_CODE1	100000
TAB_01	ADDR1_DATA-CITY1	Beijing
TAB_01	ADDR1_DATA-COUNTRY	CN
TAB_01	SZA1_D0100-TEL_NUMBER	+86-10-12345678
TAB_01	SZA1_D0100-SMTP_ADDR	info@testcompany.com
```

### Write the definition file

1. Write the field definitions to: `{WORK_TEMP}\<BP_NUMBER>_fields.txt`
   - Use the tab-separated format above.
   - Include only the tabs and fields the user wants to set.
   - If the user references an existing BP, use BP Display to look up field values.
2. Confirm the file by reading it back.

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Business Partner Exists

The check VBScript template is at `./references/sap_bp_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_bp_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_bp_check.vbs' -Raw
$content = $content -replace '%%BP_NUMBER%%','THE_BP_NUMBER'
Set-Content '{WORK_TEMP}\sap_bp_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_BP_NUMBER` with the actual BP number and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_bp_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_bp_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → partner exists → proceed to Step 5a (Update).
- `NOT_EXIST` → partner does not exist → proceed to Step 5b (Create).
- `ERROR:` → show full output and stop.

---

## Step 5a — Update Existing Business Partner

The update VBScript template is at `./references/sap_bp_update.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_bp_update_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_bp_update.vbs' -Raw
$content = $content -replace '%%BP_NUMBER%%','THE_BP_NUMBER'
$content = $content -replace '%%DEFINITION_FILE%%','THE_DEFINITION_FILE'
Set-Content '{WORK_TEMP}\sap_bp_update_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_BP_NUMBER`, `THE_DEFINITION_FILE` (absolute path with backslashes), and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_bp_update_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_bp_update_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Business Partner (Organization)

For creating a new Business Partner, you need the BP Role.
Ask the user if not already provided:
> "This is a new Business Partner. Please provide the BP Role (e.g., FLCU01 for Customer)."

**Important — Role / Grouping Behavior:**
- Setting a non-default role (anything other than `000000`) triggers a popup
  *"Change to another BP role in create mode"*. The script presses the popup's
  **Create** button to refresh the screen with the chosen role and editable fields.
- The **Grouping** must be compatible with the chosen role. For example, a grouping
  assigned to generic BP may not work for Customer role. If you see an error like
  *"Grouping ZM01 has not been assigned to any customer accounts group"*, ask the
  user for a valid grouping for their system and role.
- Some groupings require an **external BP number** (e.g., grouping `0001`).
  If you see *"Enter the external customer number"*, set the `%%BP_NUMBER%%` token.
- For Customer (`FLCU01`) role, the **Language Key** (`ADDR1_DATA-LANGU`) is
  typically required in the definition file.

The create VBScript template is at `./references/sap_bp_create.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_bp_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_bp_create.vbs' -Raw
$content = $content -replace '%%BP_NUMBER%%','THE_BP_NUMBER'
$content = $content -replace '%%BP_ROLE%%','THE_BP_ROLE'
$content = $content -replace '%%BP_GROUPING%%','THE_BP_GROUPING'
$content = $content -replace '%%DEFINITION_FILE%%','THE_DEFINITION_FILE'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
Set-Content '{WORK_TEMP}\sap_bp_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`.
- `THE_BP_NUMBER`: Leave blank for auto-assign, or set an external number
- `THE_BP_ROLE`: Role key (e.g., `FLCU01`)
- `THE_BP_GROUPING`: Grouping key (leave blank for default)

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_bp_create_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_bp_create_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user the Business Partner was created/updated.
- Show the full script output as a code block.

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `does not exist` | BP not found (Update) | Create first or check BP number |
| `Failed to enter Create mode` | Navigation issue | Ensure BP transaction is accessible |
| `Failed to switch to Change mode` | Authorization issue | Check user authorizations |
| `Validation error` | Missing required fields | Check Name, Country, and other mandatory fields |
| `Business Partner creation failed` | SAP validation error | Check status bar message, fix field values |
| `has not been assigned to any customer accounts group` | Grouping incompatible with role | Ask user for valid grouping for the chosen role |
| `Enter the external customer number` | Grouping uses external numbering | Provide a BP number via `%%BP_NUMBER%%` |
| `Required field Language Key` | Language key missing for role | Add `ADDR1_DATA-LANGU` to definition file |
| `No SAP GUI session found` | Not logged in | Run login step first |
| `Definition file not found` | Wrong path | Verify file path and re-run Step 2 |

---

## Step 7 — Clean Up

Delete all temporary files (including the field definition file):
```bash
cmd /c del {WORK_TEMP}\sap_bp_check_run.vbs & del {WORK_TEMP}\sap_bp_check_run.ps1 & del {WORK_TEMP}\sap_bp_create_run.vbs & del {WORK_TEMP}\sap_bp_create_run.ps1 & del {WORK_TEMP}\sap_bp_update_run.vbs & del {WORK_TEMP}\sap_bp_update_run.ps1 & del {WORK_TEMP}\*_fields.txt
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_bp_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_bp_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `BP_FAILED`, `GUI_TIMEOUT`.
