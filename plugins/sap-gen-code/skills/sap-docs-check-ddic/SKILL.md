---
name: sap-docs-check-ddic
description: |
  Validates DDIC objects (domains, data elements, tables) extracted from a design
  document. Checks naming conventions, data type validity, and cross-references
  between domains, data elements, and table fields. Optionally verifies existence
  in SAP system via RFC_READ_TABLE on DD01L/DD04L if SAP login info is provided.
  Input: work folder path containing {doc_name}_domains.txt, _dataElements.txt, _tables.txt
  Output: {work_folder}/check_result_ddic.txt
argument-hint: "<work-folder-path> [<sap-logon-description>]"
---

# SAP Docs Check DDIC Skill

You validate DDIC object definitions extracted from a design document before they are created in SAP via `/sap-se11`.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `sap-dev-core/shared/tables/sap_object_naming_rules.tsv` | *(read by helper)* | DDIC naming patterns (DDIC_DOMAIN / DDIC_DATAELEMENT / DDIC_TABLE). Custom override: `{custom_url}\sap_object_naming_rules.tsv` |
| `sap-dev-core/shared/scripts/sap_check_object_name.ps1` | *(helper)* | Shared name validator invoked in Steps 2a / 3a / 4a |

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Read `work_dir` (default `C:\sap_dev_work`).
Set `{WORK_TEMP}` = `{work_dir}\temp` and ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_docs_check_ddic_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_docs_check_ddic_run.json" -Skill sap-docs-check-ddic -ParamsJson "{\"work_folder\":\"<WORK_FOLDER>\"}"
```

---

## Step 1 — Parse Arguments and Locate Files

Extract from `$ARGUMENTS`:
- **Work folder path** — required
- **SAP Logon description** — optional; enables RFC-based existence checks

Find and read:
- `{doc_name}_domains.txt` (optional — skip domain checks if missing)
- `{doc_name}_dataElements.txt` (optional — skip DE checks if missing)
- `{doc_name}_tables.txt` (optional — skip table checks if missing)

---

## Step 2 — Check Domains

For each domain in `_domains.txt`:

### 2a. Name Validation
- Name must be ≤ 30 characters (SAP DDIC limit).
- Pattern check via shared validator (custom override → default):
  ```bash
  powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType DDIC_DOMAIN -ObjectName <NAME> -CustomUrl "{custom_url}"
  ```
  Exit `1` → emit a `Naming` / `Warning` row in the result file with the
  validator's stdout line. Exit `2` → log once and skip.

### 2b. Data Type Validation
Valid SAP ABAP Dictionary data types:
`CHAR`, `NUMC`, `DATS`, `TIMS`, `DEC`, `CURR`, `QUAN`, `UNIT`, `LANG`, `CLNT`, `INT1`, `INT2`, `INT4`, `INT8`, `FLTP`, `STRING`, `SSTRING`, `RAWSTRING`, `RAW`, `ACCP`, `DF16_DEC`, `DF16_RAW`, `DF34_DEC`, `DF34_RAW`

Check:
- DATATYPE is in the valid list
- LENGTH is appropriate for the data type (e.g., CURR needs DECIMALS)
- If SIGN = `X`, data type should be numeric (DEC, CURR, QUAN, FLTP)

---

## Step 3 — Check Data Elements

For each data element in `_dataElements.txt`:

### 3a. Name Validation
- Name must be ≤ 30 characters.
- Pattern check via shared validator (`-ObjectType DDIC_DATAELEMENT`),
  same invocation pattern as Step 2a. Violation → `Naming` / `Warning`.

### 3b. Domain Reference Check

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

---

## Step 4 — Check Table Fields

For each table in `_tables.txt`:

### 4a. Table Name Validation
- Name must be ≤ 30 characters.
- Pattern check via shared validator (`-ObjectType DDIC_TABLE`),
  same invocation pattern as Step 2a. Violation → `Naming` / `Warning`.

### 4b. Field Data Element Check

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

### 4b-1. Primitive-type-as-DATAELEMENT trap (REFINED)

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
    Suppress this rule entirely (rule 4b's existence check already passed
    via the same lookup; nothing to add).
  - **DD04L returns 0 rows** → name doesn't exist as DTEL → **Error**:
    `"DATAELEMENT='<X>' looks like a primitive DDIC type and does not exist as a data element. Wrap it in a project data element (e.g. ZHKDE_SEQ) using a domain (ZHKDM_NUMC3) of that primitive type."`

In short: rule 4b-1 is a *hint to a missing-DTEL error*, never a standalone
fail. If the name resolves to a real DTEL via DD04L, the regex is wrong and
we say nothing.

### 4b-2. Currency reference completeness

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

### 4c. Key Field Validation
- At least one key field must be defined
- MANDT should be the first key field for client-dependent tables

### 4d. Cross-table DTEL → Domain referential integrity (NEW)

Walk every data element in `_dataElements.txt` and look up its `DOMNAME` in
`_domains.txt`. Catches the most common typo: a missing/extra digit on the
suffix (e.g. DTEL points at `ZHKDM_KEY13` but the spec only defines
`ZHKDM_KEY131`).

**Detection**: `DTEL.DOMNAME` is in `Z*` / `Y*` namespace AND not present in
`_domains.txt` AND (offline) or (not found in DD01L online).

If matched → **Error**: `"DTEL '<DE>' points at DOMNAME='<DOM>' which is not in _domains.txt and not a standard SAP domain. Likely typo — _domains.txt has these similar names: <fuzzy-match-suggestions>"`. Suggest the closest names by Levenshtein distance ≤ 2.

### 4e. Naming consistency drift (NEW)

Detect when domain/DTEL/table names in the same spec use different suffix
conventions (e.g. some end in `13`, some in `131`). Group all Z-namespace
names by their leading 3 chars (project sub-prefix) and inspect the
trailing numeric segment. If two distinct trailing segments appear within
the same spec → flag as **Warning**: `"Naming convention drift: spec uses both '<suffix-A>' and '<suffix-B>' on Z-namespace objects. Pick one and apply consistently."`

### 4f. Live-SAP ReferenceTable validation (NEW)

For every field in `_tables.txt` with a non-blank `ReferenceTable` that
is a STANDARD SAP table (not in the spec's own `_tables.txt`), verify
via RFC that the table exists AND its `Ref.Field` exists on it. Catches:

- Typo in a standard reference (e.g. `T100` vs `T001`).
- Wrong field name (e.g. `T001-WAERK` where the actual currency field
  might be `T001-WAERS`).
- Reference to a table that was removed/renamed in this S/4HANA release.

Self-referencing CURR/QUAN fields (ReferenceTable = the same `Z*` table
defined in this spec) are already covered by Step 4b-2 and the spec's
own field list — no live lookup needed for those.

**Detection**: walk `_tables.txt`. For each row with `ReferenceTable`
matching a standard table (uppercase, doesn't appear in spec's
`_tables.txt`):

1. Collect `<ReferenceTable>\t<Ref.Field>\tTable <T> field <F> ReferenceTable\tCross-reference`
   into `{WORK_TEMP}\spec_refs_request.txt`.
2. Collect unique `<ReferenceTable>` names into `{WORK_TEMP}\struct_request.txt`.
3. Invoke `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_struct.ps1`
   to populate `{work_folder}\_struct_signatures.txt` (same cache
   `/sap-gen-abap` Step 1.5e uses — gen-abap will reuse what this
   check populated).
4. Invoke `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_spec_refs.ps1`
   to validate. The validator appends rows to
   `{work_folder}/check_result_ddic.txt` in the same TSV format the
   rest of this skill uses.

If matched → **Error**: `"ReferenceTable <T>.<F> referenced by field
<X> does not exist (per live DDIF_FIELDINFO_GET)."` — fix advice
points at SE11 lookup for the correct table+field.

When RFC is unavailable, downgrade to **Warning** with hint to verify
manually post-deploy.

---

## Step 5 — Write Result File

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

## Step 6 — Summary

Report to the user:
- Objects checked: N domains, N data elements, N tables
- Issues found (by severity)
- Mode: offline or online (SAP system connected)
- Result file path
- Suggest next steps:
  - Fix errors and re-run
  - `/sap-se11` to create DDIC objects in SAP

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_docs_check_ddic_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_docs_check_ddic_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `DDIC_CHECK_FAILED`, `INPUT_NOT_FOUND`.
