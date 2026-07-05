# SAP Docs Check Skill

Validates an extracted design spec **before** it feeds ABAP code generation
(`/sap-gen-abap`) and DDIC creation (`/sap-se11`). One skill, two dimensions —
catches typo-class and ambiguity bugs at the design stage, preventing wasted
SAP round-trips:

- **`ddic`** — DDIC objects (domains, data elements, tables): naming, data-type
  validity, domain/DTEL/table cross-references, currency-reference completeness,
  and the primitive-type-as-data-element trap. Optionally verifies existence in
  the live SAP system via `RFC_READ_TABLE` on `DD01L` / `DD04L` and validates
  live `ReferenceTable.field` refs when a SAP logon is provided.
- **`process`** — process-logic text (`_process.txt`): unclear/ambiguous steps,
  missing information, and logic / data-type / cross-reference inconsistencies.
  Optionally validates SAP `TABLE.FIELD` references against the live system (RFC).

Runs **both** dimensions by default (whichever dimension's input files exist in
the work folder); pass `--dimension ddic|process` to force one.

> Replaces the former `/sap-docs-check-ddic` and `/sap-docs-check-process`
> skills, folded into one dimension-dispatched skill.

## Auto-Trigger Keywords

- `check spec`, `validate spec`, `check the design docs`, `lint the spec`
- `check ddic`, `validate ddic`, `verify domains and data elements`
- `check process`, `validate process logic`

## Usage

```text
/sap-docs-check <work-folder>
/sap-docs-check <work-folder> --dimension ddic
/sap-docs-check <work-folder> --dimension process
/sap-docs-check <work-folder> <sap-logon-description>       # enables the RFC checks
```

Examples:

```text
/sap-docs-check C:\sap_dev_work\source_code\work\Spec_20260501123456\
/sap-docs-check C:\sap_dev_work\...\Spec_20260501123456\ DEV_100
```

Conversational forms:

- "Check the extracted spec in this work folder before I generate the code"
- "Validate just the DDIC definitions"
- "Lint the process logic extracted from `Spec.xlsx`"

## Prerequisites

- Work folder must contain the relevant dimension's inputs (produced by
  `/sap-docs-extract`): `_domains.txt` / `_dataElements.txt` / `_tables.txt`
  for the DDIC dimension, `_process.txt` for the process dimension.
- For the optional live-SAP checks: SAP NCo 3.1 in the GAC + `sap-dev-core`
  settings configured.

## Output

- `{work_folder}/check_result_ddic.txt` — TAB-separated DDIC findings.
- `{work_folder}/check_result_process.txt` — TAB-separated process findings.

Both are ready to open in Excel (`No / … / Description / Severity / Status`
columns), listing only problems (Error / Warning) for review.

## Version

- Skill Version: 2.0.0
- Last Updated: 2026-07-05

## License

GPL-3.0 License - See LICENSE file in repository root.
