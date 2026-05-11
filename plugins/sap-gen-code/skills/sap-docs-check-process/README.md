# SAP Docs Check Process Skill

Validates the process logic file (`{doc_name}_process.txt`) extracted from a
design document **before** ABAP code generation. Catches unclear or ambiguous
parts that would cause `/sap-gen-abap` to either ask for clarification or
generate fragile code.

## Skill Overview

1. Read `_process.txt` from the work folder (output of `/sap-docs-extract`)
2. Detect unclear / ambiguous markers in the text:
   - Literal `TODO`, `TBD`, `未定`, `後で`, `要確認` markers from the source spec
   - Inconsistent terminology (same field named differently in two sections)
   - Unspecified validation rules (e.g. "validate the input" with no concrete
     rule)
   - Missing FROM / WHERE / JOIN clauses in described SQL
   - Undefined exception handling for described error paths
3. Write `check_result_process.txt` with one row per finding:
   `SECTION  LEVEL  ISSUE  SUGGESTION`

## Auto-Trigger Keywords

- `check process`, `validate process logic`, `lint process flow`
- `check the process file before generating abap`

## Usage

```text
/sap-docs-check-process <work-folder>
```

Examples:

```text
/sap-docs-check-process C:\sap_dev_work\source_code\work\Spec_20260501123456\
```

Conversational forms:

- "Check the process logic before generating ABAP"
- "Lint the extracted process flow for unclear parts"
- "Make sure there are no TBDs left in the process spec"

## Prerequisites

- Work folder must contain `{doc_name}_process.txt` (produced by
  `/sap-docs-extract`)

## Output

`{work_folder}/check_result_process.txt` — TAB-separated, opens cleanly in
Excel:

```
SECTION              LEVEL    ISSUE                          SUGGESTION
== VALIDATION RULES  ERROR    Rule 4 says "validate input"…  Specify which fields…
== PROCESSING FLOW   WARNING  TBD marker on line 47           Resolve before /sap-gen-abap
```

## When to skip this skill

If your design specs are written in Customer Brief format with a strict
template (no free-form text), this skill produces few findings. Still worth
running once per spec as a sanity check.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
