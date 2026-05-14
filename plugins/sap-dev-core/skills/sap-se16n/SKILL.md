---
name: sap-se16n
description: |
  Queries any SAP table via SE16N using SAP GUI Scripting and downloads the
  result set as a tab-delimited text file. Supports filtering by any combination
  of table fields with single value, multi-value (IN list), or range (BT)
  selection, and any of the standard SE16N operators (EQ, NE, GT, LT, GE, LE,
  BT, NB, CP, NP, IN). Optionally restricts the output columns to a specific
  set of fields; if no SELECT list is given, all fields are returned. Detects
  the "no values found" path and writes a marker file instead of an empty
  download. Typical use: dump rows from any SAP table for inspection or as
  reference data for development.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<TABLE> [field=value ...] [select=F1,F2,...]"
---

# SAP SE16N Table Query Skill

You query a SAP table via transaction SE16N and download the result set as a
tab-delimited text file. Filters and the optional output-field list are passed
to the underlying VBScript via a side-channel parameters file so that an
arbitrary number of filter fields and values can be specified.

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

Start a structured log run. State file: `{WORK_TEMP}\sap_se16n_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se16n_run.json" -Skill sap-se16n -ParamsJson "{\"table\":\"<TABLE>\"}"
```

---

## Step 1 — Collect Parameters

| Parameter | Description | Example |
|---|---|---|
| Table name | SAP transparent / pooled / cluster table | `T001` |
| Filter fields | Zero or more `field op value(s)` triples — see operator table | `LAND1 IN CN,JP` |
| Select fields | Optional comma-separated list of output columns; empty = all fields | `BUKRS,BUTXT,LAND1,WAERS` |
| Output file | Absolute path of the resulting `.txt` file (default: `{WORK_TEMP}\se16n_<TABLE>.txt`) | |

**Operators** (column 2 of each FILTER row):

| Op | Meaning | Values column count |
|---|---|---|
| `EQ` | equals | 1 |
| `NE` | not equal | 1 |
| `GT` / `LT` / `GE` / `LE` | comparison | 1 |
| `BT` | between (LOW..HIGH) | 2 |
| `NB` | not between | 2 |
| `CP` | matches pattern (`*`, `+`) | 1 |
| `NP` | does not match pattern | 1 |
| `IN` | one of the listed values | 2..N (auto-uses multi-select popup) |

**Routing rule:** an `IN` operator OR a single filter with more than one value
opens the SE16N multi-select popup (`btnPUSH`) and fills the LOW column of
`tblSAPLSE16NMULTI_TC`. A single value with any other operator is set directly
on `ctxtGS_SELFIELDS-LOW` of the criteria row.

If the user gives the criteria as natural language (e.g. *"T001 where Country
is CN or JP and Currency is CNY"*), parse to:

| Field | Op | Values |
|---|---|---|
| `LAND1` | `IN` | `CN`, `JP` |
| `WAERS` | `EQ` | `CNY` |

---

## Step 2 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use
the `/sap-login` skill first, then return here.

---

## Step 3 — Write the PARAMS_FILE

Write `{WORK_TEMP}\se16n_params.txt` with two literal section headers, **`SELECT`**
and **`FILTER`**, each followed by its rows. Either section may be empty.

Format:

```
SELECT
<FIELDNAME>
<FIELDNAME>
FILTER
<FIELDNAME><TAB><OP><TAB><VAL1>[<TAB><VAL2>...]
<FIELDNAME><TAB><OP><TAB><VAL1>[<TAB><VAL2>...]
```

**Field columns are separated by a real tab character (`\t`) — not spaces.**

Example for `T001` filter `LAND1 ∈ {CN, JP}` AND `WAERS = CNY`, returning all
fields:

```
SELECT
FILTER
LAND1	IN	CN	JP
WAERS	EQ	CNY
```

Same query but only outputting `BUKRS, BUTXT, LAND1, WAERS`:

```
SELECT
BUKRS
BUTXT
LAND1
WAERS
FILTER
LAND1	IN	CN	JP
WAERS	EQ	CNY
```

Use the Write tool to create the file. The VBS reads it as system default
codepage; ASCII is always safe.

---

## Step 4 — Generate and Run the VBS

The VBS template is at `./references/sap_se16n.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se16n_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se16n.vbs' -Raw
$content = $content -replace '%%TABLE_NAME%%','THE_TABLE'
$content = $content -replace '%%PARAMS_FILE%%','{WORK_TEMP}\se16n_params.txt'
$content = $content -replace '%%OUTPUT_FILE%%','{WORK_TEMP}\se16n_THE_TABLE.txt'
# Session-attach plumbing (Phase 3.5 multi-connection aware). The shared
# AttachSapSession helper resolves the target session in this order:
#   1. SESSION_PATH constant (set from the parsed --session argument)
#   2. SAPDEV_SESSION_PATH env var
#   3. SAPDEV_PIN_FILE env var -> pin file's session_path field
#   4. Sole-connection + sole-session auto-default
#   5. Refuse with helpful error (multiple connections, no resolver)
$sessionPath = ''   # set to the parsed --session value if supplied
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
# Tell the attach helper where the pin file lives. Harmless in single-
# connection environments; essential in multi-connection ones.
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se16n_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_TABLE` with the actual table name (UPPERCASE) and `<SKILL_DIR>` /
`{WORK_TEMP}` with their absolute paths.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se16n_run.ps1"
```

### Execute

The VBS template uses 32-bit COM automation, so use the 32-bit cscript:
```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo {WORK_TEMP}\sap_se16n_run.vbs
```

---

## Step 5 — Interpret the Output

**Last line of stdout:**

| Last line | Meaning |
|---|---|
| `ROWS=<n>` (n ≥ 1) | Query returned `n` data rows. Output file is tab-delimited with a header line. |
| `ROWS=0 (NO_DATA)` | "No values found" or empty result set. Output file contains a single line `NO_DATA<TAB><status text>`. |
| `ERROR: …` | Failure — show the full output and stop. |

**Output file** (`{WORK_TEMP}\se16n_<TABLE>.txt`):
- First line = header (technical field names)
- Subsequent lines = data rows
- Field separator = TAB

If you need to summarise the result for the user, read the first ~20 lines and
report the row count and a few sample rows.

---

## Step 6 — Report Results

Report back to the user:
- The table queried, the filter spec, and the SELECT list (if any)
- The total row count
- The output file path
- For NO_DATA: the SAP status bar text from the marker file

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se16n_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se16n_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE16N_FAILED`, `TABLE_NOT_FOUND`, `GUI_TIMEOUT`.

---

## Component IDs (for reference / debugging)

Selection-criteria table control: `wnd[0]/usr/tblSAPLSE16NSELFIELDS_TC`

| Col | ID prefix | Purpose |
|---|---|---|
| 0 | `txtGS_SELFIELDS-SCRTEXT_M` | Field description ("Fld name") |
| 1 | `btnOPTION` | Operator icon button |
| 2 | `ctxtGS_SELFIELDS-LOW` | From value |
| 3 | `ctxtGS_SELFIELDS-HIGH` | To value |
| 4 | `btnPUSH` | Multi-select popup launcher |
| 5 | `chkGS_SELFIELDS-MARK` | Output column checkbox |
| 6 | `txtGS_SELFIELDS-FIELDNAME` | Technical field name |

Multi-select popup: `wnd[1]/usr/tblSAPLSE16NMULTI_TC/ctxtGS_MULTI_SELECT-LOW[1,n]`,
applied with `wnd[1]/tbar[0]/btn[8]` (Copy).

Execute: `wnd[0]/tbar[1]/btn[8]` (F8).

ALV export: `pressToolbarContextButton "&MB_EXPORT"` then
`selectContextMenuItem "&PC"`. Format radios are at
`wnd[1]/usr/subSUBSCREEN_STEPLOOP:SAPLSPO5:0150/sub:SAPLSPO5:0150/radSPOPLI-SELFLAG[col,0]`
(note: `[col,0]`, not `[col,row]`):

| col | Label (S/4HANA 1909, EN) |
|---|---|
| 0 | Unconverted |
| 1 | Text with Tabs ← tab-delimited |
| 2 | Rich text format |
| 3 | HTML Format |
| 4 | In the clipboard |

Older releases label `[1,0]` as "Spreadsheet". The VBS walks the radios at
runtime and matches `Tab` or `preadsheet` substrings, then falls back to
`[1,0]`. File dialog: `wnd[1]/usr/ctxtDY_PATH` and `wnd[1]/usr/ctxtDY_FILENAME`.

---

## Limitations

- The skill does not support sort orders, aggregations, or saved variants —
  use SE16N directly in the SAP GUI for those.
- The `SELECT` list filters output columns by toggling MARK checkboxes; column
  ordering in the output file follows SAP's natural ordering, not the order in
  the SELECT list.
- Pooled / cluster tables that SE16N forbids reading return `NO_DATA` with a
  message like "Display of cluster table not allowed" — surface this to the
  user.
- Date / numeric values must be passed in SAP internal format
  (`YYYY.MM.DD`, no thousand separators) unless the user has set their personal
  display format to match.
- Some long-text / non-selectable fields (e.g. `AS4TEXT` on `E070`, `STEXT` on
  many tables) cannot be filtered via SE16N at all — SAP renders the row
  greyed-out (no operator, no input, no multi-select). The skill detects this
  via `Changeable=False`, prints a `WARN:` message, automatically adds the
  field to the SELECT list, and continues with the remaining filters. The user
  must post-filter the output file for the skipped condition.
