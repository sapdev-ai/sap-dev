---
name: sap-docs-check
description: |
  Validates an extracted design spec before ABAP code generation, across two
  dimensions: `ddic` checks DDIC objects (domains / data elements / tables) —
  naming, data-type validity, domain/DTEL/table cross-references, currency-ref
  completeness, the primitive-as-data-element trap; `process` checks the
  process-logic text for unclear/ambiguous steps, missing info, and logic /
  type / cross-reference inconsistencies. Both optionally verify references
  against the live system over RFC when a SAP logon is given. Runs BOTH by default
  (whichever inputs exist); --dimension ddic|process forces one. Writes a
  TAB-separated result file per dimension for Excel review. Replaces the former
  /sap-docs-check-ddic and /sap-docs-check-process.
  Input: work folder path; optional SAP Logon description enables the RFC checks.
argument-hint: "<work-folder-path> [--dimension ddic|process|all] [<sap-logon-description>]"
---

# SAP Docs Check Skill

You validate an extracted design spec before it feeds ABAP code generation
(`/sap-gen-abap`) and DDIC creation (`/sap-se11`). One skill, two dimensions:

- **`ddic`** — DDIC object definitions (`_domains.txt`, `_dataElements.txt`,
  `_tables.txt`) → `check_result_ddic.txt`.
- **`process`** — process-logic text (`_process.txt`) → `check_result_process.txt`.

By default both run (whichever dimension's inputs are present). Pass
`--dimension ddic` or `--dimension process` to force one.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/ddic_excel_layout_rules.md` | *(rule)* | DDIC Excel-spec authoring rules — naming-suffix consistency, primitive-type-as-DTEL trap, currency reference, column order. Cross-check extracted DDIC against these rules. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — RFC-only validator, but rule applies to downstream deploy skills (sap-se11) the validated spec feeds |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | *(rule)* | ABAP code-quality rules — DDIC + process-logic spec quality directly determines downstream ABAP quality; validation findings here surface ABAP-quality risk before code generation |
| `sap-dev-core/shared/tables/sap_object_naming_rules.tsv` | *(read by helper)* | DDIC naming patterns (DDIC_DOMAIN / DDIC_DATAELEMENT / DDIC_TABLE). Custom override: `{custom_url}\sap_object_naming_rules.tsv` |
| `sap-dev-core/shared/tables/domain_datatypes.tsv` | *(read directly)* | Valid SE11 domain data types + per-type length/decimals/sign rules — the authority for the DDIC dimension's data-type check (same table `/sap-se11` validates against) |
| `sap-dev-core/shared/scripts/sap_check_object_name.ps1` | *(helper)* | Shared name validator invoked by the DDIC dimension |
| `sap-dev-core/shared/scripts/sap_rfc_lookup_struct.ps1` | *(helper)* | DDIC structure signature cache — populates `_struct_signatures.txt` for the live ReferenceTable / TABLE.FIELD checks (both dimensions; same cache `/sap-gen-abap` Step 1.5e uses) |
| `sap-dev-core/shared/scripts/sap_check_spec_refs.ps1` | *(helper)* | Offline `(TABLE, FIELD)` reference validator — appends `Error`/`Warning` rows to the result file (both dimensions' live-ref checks) |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Set `{WORK_TEMP}` = `{work_dir}\temp` and ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's per-run scratch (the `_run.json` log state and the live-ref request files) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{RUN_TEMP}\sap_docs_check_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_docs_check_run.json" -Skill sap-docs-check -ParamsJson "{\"work_folder\":\"<WORK_FOLDER>\",\"dimension\":\"<DIMENSION>\"}"
```

---

## Step 1 — Parse Arguments and Select Dimensions

Extract from `$ARGUMENTS`:
- **Work folder path** — required.
- **`--dimension ddic|process|all`** — optional; default `all`.
- **SAP Logon description** — optional; enables the RFC-based checks in either
  dimension.

Locate the input files in the work folder:
- `{doc_name}_domains.txt`, `{doc_name}_dataElements.txt`, `{doc_name}_tables.txt` — DDIC dimension inputs.
- `{doc_name}_process.txt` — process dimension input (`{doc_name}_PGM_summary.txt`, and the DDIC files, are optional cross-reference inputs).

Decide which dimensions to run:

| `--dimension` | Runs |
|---|---|
| `all` (default) | **DDIC** if any of `_domains` / `_dataElements` / `_tables` is present, **AND** **Process** if `_process.txt` is present. |
| `ddic` | DDIC only. If no DDIC inputs are present, report and stop. |
| `process` | Process only. If `_process.txt` is absent, report and stop. |

Echo `DIMENSIONS_SELECTED: <ddic[,process]>`. Then run each selected dimension's
section below, and finish with the combined **Summary**.

---

# Dimension: DDIC

Run this section when `ddic` is selected. It validates DDIC object definitions
extracted from the design document before they are created in SAP via
`/sap-se11`, writing problems to `{work_folder}/check_result_ddic.txt`.

## D1 — Check Domains

For each domain in `_domains.txt`:

### D1a. Name Validation
- Name must be ≤ 30 characters (SAP DDIC limit).
- Pattern check via shared validator (custom override → default):
  ```bash
  powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType DDIC_DOMAIN -ObjectName <NAME> -CustomUrl "{custom_url}"
  ```
  Exit `1` → emit a `Naming` / `Warning` row in the result file with the
  validator's stdout line. Exit `2` → log once and skip.

### D1b. Data Type Validation

Validate DATATYPE against
`<SAP_DEV_CORE_SHARED_DIR>\tables\domain_datatypes.tsv` — the SE11 truth
table `/sap-se11` uses (columns: `DATATYPE`, `DESCRIPTION`, `FIXED_LENGTH`,
`MAX_LENGTH`, `DECIMALS_ALLOWED`, `SIGN_ALLOWED`, `OBSOLETE`, `NOTES`). Do
NOT validate against a hardcoded inline list — an inline list drifts (the
pre-2026-07 list omitted `CUKY`, so every currency-key domain false-failed
with "invalid data type" while rule D3b-2 simultaneously required a CUKY
reference).

Check:
- DATATYPE is a row in the TSV → otherwise **Error**: "invalid data type"
- Row has `OBSOLETE` = `X` (`PREC`, `VARC`, `DF16_SCL`, `DF34_SCL`) → **Warning**: obsolete type, do not use
- LENGTH respects the row's `FIXED_LENGTH` / `MAX_LENGTH` (e.g. `CUKY` fixed 5, `CHAR` up to 1333, `CURR` up to 17)
- DECIMALS only for rows with `DECIMALS_ALLOWED` = `X` (e.g. CURR needs DECIMALS)
- If SIGN = `X`, the row must have `SIGN_ALLOWED` = `X` (DEC, CURR, QUAN, FLTP)

## D2 — Check Data Elements

For each data element in `_dataElements.txt`:

### D2a. Name Validation
- Name must be ≤ 30 characters.
- Pattern check via shared validator (`-ObjectType DDIC_DATAELEMENT`),
  same invocation pattern as D1a. Violation → `Naming` / `Warning`.

### D2b. Domain Reference Check

**Offline mode** (no SAP login):
- Check if `DOMNAME` exists in the `_domains.txt` list
- If not in list, flag as warning: "Domain not in design document — may be a standard SAP domain"

**Online mode** (SAP login provided):
- First check `_domains.txt` list
- If not found, query SAP via RFC_READ_TABLE:

```
Table: DD01L
Fields: DOMNAME
Options: DOMNAME = '{domain_name}' AND AS4LOCAL = 'A'
```

Use `SAP.Functions` COM object with 32-bit cscript:
```vbscript
Set oRFC = oFunctions.Add("RFC_READ_TABLE")
oRFC.Exports("QUERY_TABLE") = "DD01L"
oRFC.Exports("DELIMITER") = "|"
' Set FIELDS table
Set oFields = oRFC.Tables("FIELDS")
oFields.Rows.Add
oFields(oFields.RowCount, "FIELDNAME") = "DOMNAME"
' Set OPTIONS table
Set oOptions = oRFC.Tables("OPTIONS")
oOptions.Rows.Add
oOptions(oOptions.RowCount, "TEXT") = "DOMNAME = '" & sDomainName & "' AND AS4LOCAL = 'A'"
oRFC.Call
' Check DATA table row count
If oRFC.Tables("DATA").RowCount = 0 Then
    ' Domain does not exist
End If
```

If not found in SAP either → Error: "Domain does not exist"

## D3 — Check Table Fields

For each table in `_tables.txt`:

### D3a. Table Name Validation
- Name must be ≤ 30 characters.
- Pattern check via shared validator (`-ObjectType DDIC_TABLE`),
  same invocation pattern as D1a. Violation → `Naming` / `Warning`.

### D3b. Field Data Element Check

For each field's DATAELEMENT value:

**Offline mode**:
- Check if it exists in `_dataElements.txt` list
- If not in list, flag as warning: "Data element not in design document — may be standard"

**Online mode** (SAP login provided):
- First check `_dataElements.txt` list
- If not found, query SAP via RFC_READ_TABLE:

```
Table: DD04L
Fields: ROLLNAME
Options: ROLLNAME = '{dtel_name}' AND AS4LOCAL = 'A'
```

If not found → Error: "Data element does not exist"

### D3b-1. Primitive-type-as-DATAELEMENT trap (REFINED)

A common spec mistake: customers write a primitive DDIC type (e.g. `CHAR4`,
`DEC10`) in the DATAELEMENT column. SE11 rejects these — only real data
elements work.

**However**, several primitive-shaped names ARE real SAP-shipped data
elements (e.g. `NUMC1`, `NUMC2`, `NUMC3`, `NUMC4`, `DATS`, `TIMS`, `CHAR1`).
A regex-only rule produces false positives for those.

**Detection**: regex against the DATAELEMENT value:

```
^(CHAR|NUMC|DATS|TIMS|DEC|CURR|QUAN|UNIT|RAW|RAWSTRING|STRING|SSTRING|FLTP|INT1|INT2|INT4|INT8|LANG|CLNT|ACCP|LCHR|LRAW|DF16_DEC|DF34_DEC)\d*$
```

If matched, BEFORE flagging: confirm the name is NOT a real DTEL.

- **Offline mode**: skip — emit a `Warning` only, with a hint that the user
  should verify the name is a real DTEL or wrap it in a project DE. Never
  emit `Error` from this rule alone in offline mode (false-positive risk).
- **Online mode**: query SAP via `RFC_READ_TABLE` on `DD04L` with
  `ROLLNAME = '<X>' AND AS4LOCAL = 'A'`. The result determines severity:
  - **DD04L returns 1+ rows** → it IS a real DTEL → **DO NOT FLAG**.
    Suppress this rule entirely (rule D3b's existence check already passed
    via the same lookup; nothing to add).
  - **DD04L returns 0 rows** → name doesn't exist as DTEL → **Error**:
    `"DATAELEMENT='<X>' looks like a primitive DDIC type and does not exist as a data element. Wrap it in a project data element (e.g. ZHKDE_SEQ) using a domain (ZHKDM_NUMC3) of that primitive type."`

In short: rule D3b-1 is a *hint to a missing-DTEL error*, never a standalone
fail. If the name resolves to a real DTEL via DD04L, the regex is wrong and
we say nothing.

### D3b-2. Currency reference completeness

For a field of CURR type, SAP DDIC requires BOTH `ReferenceTable` AND
`Ref.Field` to be populated — including the self-referencing case where the
WAERK column lives in the same table being defined. SE11 on modern S/4HANA
(verified on 1909 and later) refuses to activate a CURR column whose
`ReferenceTable` is blank, even if `Ref.Field` is set.

NOTE: an older NetWeaver-era convention permitted leaving `ReferenceTable`
blank when the reference was to the same table. That convention is
deprecated; do not apply it on S/4HANA. (This rule was inverted on
2026-05-09 after a real deployment surfaced the contradiction.)

**Detection**: field underlying type is CURR (lookup via `_dataElements.txt`
→ `_domains.txt` → DATATYPE) AND (`ReferenceTable` is blank OR `Ref.Field`
is blank).

If matched → **Error**: `"CURR field '<F>' is missing ReferenceTable or Ref.Field. SE11 requires both to be populated, including for self-referencing currency fields. Set ReferenceTable=<the table containing the WAERK column> and Ref.Field=<the WAERK column name>."`

### D3c. Key Field Validation
- At least one key field must be defined
- MANDT should be the first key field for client-dependent tables

### D3d. Cross-table DTEL → Domain referential integrity

Walk every data element in `_dataElements.txt` and look up its `DOMNAME` in
`_domains.txt`. Catches the most common typo: a missing/extra digit on the
suffix (e.g. DTEL points at `ZHKDM_KEY13` but the spec only defines
`ZHKDM_KEY131`).

**Detection**: `DTEL.DOMNAME` is in `Z*` / `Y*` namespace AND not present in
`_domains.txt` AND (offline) or (not found in DD01L online).

If matched → **Error**: `"DTEL '<DE>' points at DOMNAME='<DOM>' which is not in _domains.txt and not a standard SAP domain. Likely typo — _domains.txt has these similar names: <fuzzy-match-suggestions>"`. Suggest the closest names by Levenshtein distance ≤ 2.

### D3e. Naming consistency drift

Detect when domain/DTEL/table names in the same spec use different suffix
conventions (e.g. some end in `13`, some in `131`). Group all Z-namespace
names by their leading 3 chars (project sub-prefix) and inspect the
trailing numeric segment. If two distinct trailing segments appear within
the same spec → flag as **Warning**: `"Naming convention drift: spec uses both '<suffix-A>' and '<suffix-B>' on Z-namespace objects. Pick one and apply consistently."`

### D3f. Live-SAP ReferenceTable validation

For every field in `_tables.txt` with a non-blank `ReferenceTable` that
is a STANDARD SAP table (not in the spec's own `_tables.txt`), verify
via RFC that the table exists AND its `Ref.Field` exists on it. Catches:

- Typo in a standard reference (e.g. `T100` vs `T001`).
- Wrong field name (e.g. `T001-WAERK` where the actual currency field
  might be `T001-WAERS`).
- Reference to a table that was removed/renamed in this S/4HANA release.

Self-referencing CURR/QUAN fields (ReferenceTable = the same `Z*` table
defined in this spec) are already covered by rule D3b-2 and the spec's
own field list — no live lookup needed for those.

**Detection**: walk `_tables.txt`. For each row with `ReferenceTable`
matching a standard table (uppercase, doesn't appear in spec's
`_tables.txt`):

1. Collect `<ReferenceTable>\t<Ref.Field>\tTable <T> field <F> ReferenceTable\tCross-reference`
   into `{RUN_TEMP}\spec_refs_request.txt`.
2. Collect unique `<ReferenceTable>` names into `{RUN_TEMP}\struct_request.txt`.
3. Invoke `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_struct.ps1`
   to populate `{work_folder}\_struct_signatures.txt` (same cache
   `/sap-gen-abap` Step 1.5e uses — gen-abap will reuse what this
   check populated).
4. Invoke `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_spec_refs.ps1`
   to validate. The validator appends rows to
   `{work_folder}/check_result_ddic.txt` in the same TSV format the
   rest of this dimension uses.

If matched → **Error**: `"ReferenceTable <T>.<F> referenced by field
<X> does not exist (per live DDIF_FIELDINFO_GET)."` — fix advice
points at SE11 lookup for the correct table+field.

When RFC is unavailable, downgrade to **Warning** with hint to verify
manually post-deploy.

## D4 — Write DDIC Result File

Write **only problems** (errors and warnings) to `{work_folder}/check_result_ddic.txt` in TAB-separated format (so the user can open it in Excel to review and update):

```
No	Object Type	Object Name	Check	Description	Severity	Status
1	Domain	ZHKDM_AMT9	DataType	CURR type should have DECIMALS defined	Warning	Open
2	Table	ZHKFIXEDVALS9	Field	Data element NUMC3 not in design document and not verified in SAP	Warning	Open
3	DataElement	ZHKDE_KEY1	Domain	DOMNAME='ZHKDM_KEY13' not in _domains.txt. Closest match: ZHKDM_KEY131 (typo?)	Error	Open
4	Table	ZHKFIXEDVALS	Field	DATAELEMENT='NUMC3' looks like a primitive DDIC type, not a data element. Wrap in ZHKDE_SEQ.	Error	Open
```

Columns:
- **No**: Sequential number
- **Object Type**: `Domain`, `DataElement`, `Table`
- **Object Name**: The DDIC object name
- **Check**: What was checked (`Name`, `DataType`, `Domain`, `Field`, `Key`, `Naming`)
- **Description**: Clear explanation of the problem (include fuzzy-match suggestion when applicable)
- **Severity**: `Error` (blocks SE11 creation) or `Warning` (proceeds with assumption)
- **Status**: Always `Open` (user updates to `Fixed` or `Ignored` after review)

Do NOT include items that passed checks — only record problems.

---

# Dimension: Process

Run this section when `process` is selected. It validates the process logic
extracted from a design document before it is used for ABAP code generation by
`/sap-gen-abap`, writing problems to `{work_folder}/check_result_process.txt`.

Required input: `{doc_name}_process.txt`. Optional cross-reference inputs:
`{doc_name}_PGM_summary.txt`, `_domains.txt`, `_dataElements.txt`, `_tables.txt`.

## P1 — Check for Unclear Parts

Scan the process text for issues in these categories:

### P1a. Missing or Vague Descriptions

- Fields with no description or validation rules where mandatory = 必須
- Processing steps described with vague words only (e.g., "適宜処理する", "必要に応じて") without concrete logic
- BAPI/FM references without specifying which parameters to pass
- Error messages referenced but not defined (no message class/number)
- "TODO", "TBD", "未定", "後で", "要確認" markers

### P1b. Missing Information

- Field definitions referenced in processing flow but not in field list
- Table/structure references without specifying which fields
- Selection screen parameters mentioned but not defined
- Output fields described but no source specified

## P2 — Check for Inconsistencies

### P2a. Logic Inconsistencies

- Contradictory validation rules (e.g., field required in one place, optional in another)
- Processing flow references fields not in field definitions
- Conditional logic with undefined conditions
- Loop/iteration over table with no table structure defined

### P2b. Data Type Inconsistencies

- Field used as numeric in calculations but defined as CHAR
- Length mismatches between field definition and validation rules
- Date fields used as string or vice versa

### P2c. Cross-reference Issues

- Fields in FILE MAPPING not matching FIELD DEFINITIONS
- BAPI parameter names not matching known SAP conventions
- Table column references that don't exist in table definition

## P3 — Write Base Process Result File

Write the P1 and P2 findings to `{work_folder}/check_result_process.txt` in TAB-separated format:

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

Write this file BEFORE running P4 — the RFC validator there APPENDS to
it and numbers its findings after the existing rows. (Pre-2026-07 the RFC
step ran before this one, so writing the base results here overwrote its
appended findings.)

## P4 — Validate SAP table.field refs against live SAP (RFC, optional — appends to the P3 file)

**Why:** the spec often references SAP tables and fields directly — in
`_file_mapping_in.txt` (SAP_TABLE.SAP_FIELD columns), in validation rules
("file BUKRS = T001-BUKRS"), or in the process flow. A typo there
(`MARA.MATNR2`, `T001.BUKRS_X`) doesn't fail the text checks above but
will surface either as a generated `SELECT` syntax error at SE38 upload
or as a wrong-data bug at runtime. This step catches them offline.

**Skip this step** if no `_file_mapping_in.txt` / `_file_mapping_out.txt`
is present AND no spec section references SAP standard tables, OR if
SAP RFC connection is not configured.

### P4a — Collect (TABLE, FIELD) pairs to validate

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

Write to `{RUN_TEMP}\spec_refs_request.txt` (one row per pair, tab-separated
— per-run scratch, see the Step 0 two-bucket rule).
Skip the rest of P4 if the request file is empty.

### P4b — Populate the struct signature cache

Build a deduplicated list of unique `<TABLE>` names from the request file.
Write them to `{RUN_TEMP}\struct_request.txt` (one per line).

Invoke `sap_rfc_lookup_struct.ps1` (the same lookup `/sap-gen-abap` Step
1.5e uses). Token-replace per the FM-lookup pattern (see
sap-gen-abap SKILL.md Step 1.5c/1.5e for the canonical token list).
Output goes to `{work_folder}\_struct_signatures.txt` so a subsequent
`/sap-gen-abap` run picks up the same cache without re-fetching.

If RFC fails / is unconfigured, the cache file is written empty/partial
with `UNAVAILABLE` marker rows. The validator below downgrades affected
checks to `Warning` automatically — the step is fail-soft.

### P4c — Run the spec-refs validator

Template at `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_spec_refs.ps1`.

Count existing rows in `{work_folder}/check_result_process.txt` (header
not included — the base file written in P3) to compute `STARTING_NO`
so the new findings continue the sequence. Pass that, the request file,
the cache file, and the result file path:

```powershell
$content = Get-Content '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_spec_refs.ps1' -Raw
$content = $content.Replace('%%REQUEST_FILE%%',    '{RUN_TEMP}\spec_refs_request.txt')
$content = $content.Replace('%%STRUCT_SIG_FILE%%', '{work_folder}\_struct_signatures.txt')
$content = $content.Replace('%%RESULT_FILE%%',     '{work_folder}\check_result_process.txt')
$content = $content.Replace('%%STARTING_NO%%',     'THE_NEXT_NO')
Set-Content '{RUN_TEMP}\sap_check_spec_refs_run.ps1' $content -Encoding UTF8
```

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_check_spec_refs_run.ps1"
```

The validator appends rows in the same `No\tCategory\tLocation\tDescription\tSeverity\tStatus`
format the rest of this dimension uses. New error/warning classes added by P4:

| Reason text | Severity |
|---|---|
| `Table <T> does not exist on the target SAP system (per live RFC).` | Error |
| `Field <F> does not exist on table <T> (per live DDIF_FIELDINFO_GET).` | Error |
| `Cannot validate <T>.<F> — RFC unavailable when the signature cache was populated.` | Warning |

Clean up:
```bash
cmd /c del {RUN_TEMP}\sap_check_spec_refs_run.ps1
cmd /c del {RUN_TEMP}\spec_refs_request.txt
cmd /c del {RUN_TEMP}\struct_request.txt
```

---

## Summary

Report to the user, covering only the dimensions that ran:

- **Which dimensions ran** (ddic / process) and the mode (offline / online).
- **DDIC** (if run): objects checked (N domains, N data elements, N tables),
  issues by severity, result file `{work_folder}/check_result_ddic.txt`.
- **Process** (if run): total issues by category and severity, result file
  `{work_folder}/check_result_process.txt`.
- Suggested next steps:
  - Fix errors and re-run `/sap-docs-check`.
  - `/sap-se11` to create the DDIC objects in SAP.
  - `/sap-gen-abap {work_folder}/{doc_name}_process.txt` once the spec is clean.

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_docs_check_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_docs_check_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `DDIC_CHECK_FAILED`, `PROCESS_CHECK_FAILED`, `INPUT_NOT_FOUND`.
