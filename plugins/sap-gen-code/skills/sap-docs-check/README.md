# SAP Docs Check DDIC Skill

Validates DDIC objects (domains, data elements, tables) extracted from a
design document **before** they are created in SAP via `/sap-se11`.
Catches naming, type, and cross-reference errors at the design stage —
preventing wasted SAP round-trips for typo-class bugs.

Optionally verifies existence in the live SAP system via `RFC_READ_TABLE` on
`DD01L` / `DD04L` if SAP login info is configured.

## Skill Overview

1. Read `_domains.txt`, `_dataElements.txt`, `_tables.txt` from the work folder
   (output of `/sap-docs-extract`)
2. Validate naming conventions per
   `sap_object_naming_rules.tsv` (or `{custom_url}` override) — separate
   patterns for `DDIC_DOMAIN`, `DDIC_DATAELEMENT`, `DDIC_TABLE`
3. Validate DDIC types per `domain_datatypes.tsv` (e.g. `CHAR(N)` vs
   `NUMC(N,M)` argument counts)
4. Cross-reference: every table field's `DATAELEMENT` must exist in
   `_dataElements.txt`; every data element's `DOMNAME` must exist in
   `_domains.txt`
5. (Optional) Verify against the live SAP system — flag domains / DEs that
   already exist with a different definition
6. Write `check_result_ddic.txt` with PASS / WARNING / ERROR rows

## Auto-Trigger Keywords

- `check ddic`, `validate ddic`, `verify domains and data elements`
- `check design ddic`, `lint dictionary objects`

## Usage

```text
/sap-docs-check-ddic <work-folder>
/sap-docs-check-ddic <work-folder> <sap-logon-description>
```

Examples:

```text
/sap-docs-check-ddic C:\sap_dev_work\source_code\work\Spec_20260501123456\
/sap-docs-check-ddic C:\sap_dev_work\...\Spec_20260501123456\ DEV_100
```

Conversational forms:

- "Check the DDIC definitions in this work folder before I deploy"
- "Lint the dictionary objects extracted from `Spec.xlsx`"

## Prerequisites

- Work folder must contain at least one of `_domains.txt`,
  `_dataElements.txt`, `_tables.txt` (produced by `/sap-docs-extract`)
- For the optional live-SAP check: SAP NCo 3.1 in the GAC + `sap-dev-core`
  settings configured

## Output

`{work_folder}/check_result_ddic.txt` — TAB-separated, ready to open in Excel:

```
LEVEL    OBJECT_TYPE   OBJECT_NAME   FIELD     ISSUE
ERROR    DOMAIN        ZHKDM_KEY9              Length missing for CHAR
WARNING  DATAELEMENT   ZHKDE_KEY91   DOMNAME   ZHKDM_KEY9 declared but…
PASS     TABLE         ZHKTBL001               All fields validated
```

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
