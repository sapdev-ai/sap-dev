---
name: sap-docs-check-process
description: |
  Validates the process logic text file ({doc_name}_process.txt) before ABAP code
  generation. Checks for unclear/ambiguous parts and inconsistencies in the process
  logic. Outputs a TAB-separated result file for Excel review.
  Input: work folder path containing {doc_name}_process.txt
  Output: {work_folder}/check_result_process.txt
argument-hint: "<work-folder-path>"
---

# SAP Docs Check Process Skill

You validate the process logic extracted from a design document before it is used for ABAP code generation by `/sap-gen-abap`.

Task: $ARGUMENTS

---

## Step 0 — Resolve Work Directory

Read sap-dev-core's settings.json. Read `work_dir` (default `C:\sap_dev_work`).
Set `{WORK_TEMP}` = `{work_dir}\temp` and ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_docs_check_process_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_docs_check_process_run.json" -Skill sap-docs-check-process -ParamsJson "{\"work_folder\":\"<WORK_FOLDER>\"}"
```

---

## Step 1 — Locate Input Files

Extract the work folder path from `$ARGUMENTS`.

Find and read:
- `{doc_name}_process.txt` (required)
- `{doc_name}_PGM_summary.txt` (optional, for cross-reference)
- `{doc_name}_domains.txt` (optional, for type cross-reference)
- `{doc_name}_dataElements.txt` (optional)
- `{doc_name}_tables.txt` (optional)

---

## Step 2 — Check for Unclear Parts

Scan the process text for issues in these categories:

### 2a. Missing or Vague Descriptions

- Fields with no description or validation rules where mandatory = 必須
- Processing steps described with vague words only (e.g., "適宜処理する", "必要に応じて") without concrete logic
- BAPI/FM references without specifying which parameters to pass
- Error messages referenced but not defined (no message class/number)
- "TODO", "TBD", "未定", "後で", "要確認" markers

### 2b. Missing Information

- Field definitions referenced in processing flow but not in field list
- Table/structure references without specifying which fields
- Selection screen parameters mentioned but not defined
- Output fields described but no source specified

---

## Step 3 — Check for Inconsistencies

### 3a. Logic Inconsistencies

- Contradictory validation rules (e.g., field required in one place, optional in another)
- Processing flow references fields not in field definitions
- Conditional logic with undefined conditions
- Loop/iteration over table with no table structure defined

### 3b. Data Type Inconsistencies

- Field used as numeric in calculations but defined as CHAR
- Length mismatches between field definition and validation rules
- Date fields used as string or vice versa

### 3c. Cross-reference Issues

- Fields in FILE MAPPING not matching FIELD DEFINITIONS
- BAPI parameter names not matching known SAP conventions
- Table column references that don't exist in table definition

---

## Step 3.5 — Validate SAP table.field refs against live SAP (RFC, optional)

**Why:** the spec often references SAP tables and fields directly — in
`_file_mapping_in.txt` (SAP_TABLE.SAP_FIELD columns), in validation rules
("file BUKRS = T001-BUKRS"), or in the process flow. A typo there
(`MARA.MATNR2`, `T001.BUKRS_X`) doesn't fail the text checks above but
will surface either as a generated `SELECT` syntax error at SE38 upload
or as a wrong-data bug at runtime. This step catches them offline.

**Skip this step** if no `_file_mapping_in.txt` / `_file_mapping_out.txt`
is present AND no spec section references SAP standard tables, OR if
SAP RFC connection is not configured.

### 3.5a — Collect (TABLE, FIELD) pairs to validate

Walk the work folder for:

- `_file_mapping_in.txt` — TSV with columns including `SAP_TABLE` and
  `SAP_FIELD`. For each row, emit `<SAP_TABLE>\t<SAP_FIELD>\tFILE_MAPPING_IN row <N>\tCross-reference`.
- `_file_mapping_out.txt` — same shape.
- `_process.txt` — grep for `MARA.<FIELD>`, `T001.<FIELD>`, etc., or
  any `<UPPER>.<UPPER>` pattern in validation-rule sections. Be
  conservative; emit only when both sides match an identifier shape.

Filter:
- Drop any `<TABLE>.<FIELD>` where `<TABLE>` starts with `Z` or `Y` AND
  the table is defined in the spec's own `_tables.txt` (it's a Z-object
  being created in this same run; no live SAP cache hit expected).
- Drop duplicates.

Write to `{WORK_TEMP}\spec_refs_request.txt` (one row per pair, tab-separated).
Skip the rest of 3.5 if the request file is empty.

### 3.5b — Populate the struct signature cache

Build a deduplicated list of unique `<TABLE>` names from the request file.
Write them to `{WORK_TEMP}\struct_request.txt` (one per line).

Invoke `sap_rfc_lookup_struct.ps1` (the same lookup `/sap-gen-abap` Step
1.5e uses). Token-replace per the FM-lookup pattern (see
sap-gen-abap SKILL.md Step 1.5c/1.5e for the canonical token list).
Output goes to `{work_folder}\_struct_signatures.txt` so a subsequent
`/sap-gen-abap` run picks up the same cache without re-fetching.

If RFC fails / is unconfigured, the cache file is written empty/partial
with `UNAVAILABLE` marker rows. The validator below downgrades affected
checks to `Warning` automatically — the step is fail-soft.

### 3.5c — Run the spec-refs validator

Template at `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_spec_refs.ps1`.

Count existing rows in `{work_folder}/check_result_process.txt` (header
not included) to compute `STARTING_NO` so the new findings continue the
sequence. Pass that, the request file, the cache file, and the result
file path:

```powershell
$content = Get-Content '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_spec_refs.ps1' -Raw
$content = $content.Replace('%%REQUEST_FILE%%',    '{WORK_TEMP}\spec_refs_request.txt')
$content = $content.Replace('%%STRUCT_SIG_FILE%%', '{work_folder}\_struct_signatures.txt')
$content = $content.Replace('%%RESULT_FILE%%',     '{work_folder}\check_result_process.txt')
$content = $content.Replace('%%STARTING_NO%%',     'THE_NEXT_NO')
Set-Content '{WORK_TEMP}\sap_check_spec_refs_run.ps1' $content -Encoding UTF8
```

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_check_spec_refs_run.ps1"
```

The validator appends rows in the same `No\tCategory\tLocation\tDescription\tSeverity\tStatus`
format the rest of this skill uses. New error/warning classes added by 3.5:

| Reason text | Severity |
|---|---|
| `Table <T> does not exist on the target SAP system (per live RFC).` | Error |
| `Field <F> does not exist on table <T> (per live DDIF_FIELDINFO_GET).` | Error |
| `Cannot validate <T>.<F> — RFC unavailable when the signature cache was populated.` | Warning |

Clean up:
```bash
cmd /c del {WORK_TEMP}\sap_check_spec_refs_run.ps1
cmd /c del {WORK_TEMP}\spec_refs_request.txt
cmd /c del {WORK_TEMP}\struct_request.txt
```

---

## Step 4 — Write Result File

Write results to `{work_folder}/check_result_process.txt` in TAB-separated format:

```
No	Category	Location	Description	Severity	Status
1	Unclear	PROCESSING FLOW 3.2	Processing step "データ更新" has no concrete logic	Warning	Open
2	Inconsistency	FIELD DEFINITIONS / VALIDATION RULES	Field "品目コード" is mandatory but validation rule 3 treats it as optional	Error	Open
3	Missing	FILE MAPPING	Field "旧品目コード" referenced in validation rule 6 but not in field list	Error	Open
```

Columns:
- **No**: Sequential number
- **Category**: `Unclear`, `Missing`, `Inconsistency`
- **Location**: Section and line/rule number where the issue is found
- **Description**: Clear explanation of the problem
- **Severity**: `Error` (blocks code generation) or `Warning` (can proceed with assumptions)
- **Status**: Always `Open` (user updates to `Fixed` or `Ignored` after review)

---

## Step 5 — Summary

Report to the user:
- Total issues found (by category and severity)
- Result file path
- If no errors: "Process text is ready for code generation. Run `/sap-gen-abap {work_folder}/{doc_name}_process.txt`"
- If errors exist: "Please review and fix the issues in the result file, then re-run this check."

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_docs_check_process_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_docs_check_process_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `PROCESS_CHECK_FAILED`, `INPUT_NOT_FOUND`.
