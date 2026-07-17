# SAP Generate Test Plan Skill

Turns a design-spec work folder (the `_process.txt` / `_golden.txt` /
`_errorMsgs.txt` files produced by `/sap-docs-extract`) — or an
`/sap-explain-object` dossier — into a reviewer-ready **functional test
plan**: cases per process step, exactly one negative case per validation rule
wired to its error message, boundary cases per selection field, and a
case↔step↔rule↔message traceability matrix.

It closes a gap in the docs→gen pipeline
(`sap-docs-extract` → `sap-docs-convert` → `sap-docs-check` → `sap-gen-abap`):
the spec's Golden Tests sheet feeds only ABAP Unit generation, so nobody
derives the *functional* plan — QA re-derives cases by hand and error paths go
untested. This skill derives that plan from the same extracted spec, or from a
live object's dossier for brownfield code with no spec.

## Skill Overview

1. Detect the mode: **from-spec** (a work folder with `*_process.txt`) or
   **from-dossier** (a dossier dir with `map.json`); a bare object name is
   resolved and the skill offers `/sap-explain-object <OBJ> --spec` first
2. Build the internal model: steps, validation rules, messages, golden rows,
   selection fields, tables
3. Derive cases per `references/test_case_derivation_rules.md`: golden rows
   and per-step/per-rule cases are **CONFIRMED** (spec-traceable); boundary
   and edge cases are **INFERRED** (model-derived) — provenance is never
   silently upgraded
4. Map every message to a provoking case; anything left lands in **UNMAPPED**
   (verdict WARN, never dropped), uncovered steps in **UNCOVERED**
5. With `--validate`: a read-only RFC pass confirms every referenced message
   (T100/T100A), table (DD02L), tcode (TSTC), and FM (TFDIR), pulls DD03L key
   fields into test-data templates, and upgrades provenance
   INFERRED→VERIFIED — with MISMATCH / NOT_FOUND surfaced as findings and
   tri-state COULD_NOT_CHECK honesty (an RFC failure caps the verdict at WARN
   but still renders the offline plan)
6. Render `{doc_name}_test_plan.md` (and `.xlsx` via `anthropic-skills:xlsx`
   with `--format xlsx|both`), plus `traceability.tsv` and
   `test_data_prereqs.tsv`; register the artifacts for `/sap-evidence-pack`

## Auto-Trigger Keywords

- `generate test plan`, `functional test plan from the spec`
- `derive test cases`, `traceability matrix for this work folder`

## Usage

```text
/sap-gen-test-plan <work_folder | OBJECT | dossier_dir> [--format md|xlsx|both] [--validate] [--out <dir>]
```

Examples:

```text
/sap-gen-test-plan C:\sap_dev_work\source_code\work\Spec_20260501\
/sap-gen-test-plan C:\sap_dev_work\source_code\work\Spec_20260501\ --format both --validate
/sap-gen-test-plan ZMMR001
```

Conversational forms:

- "Generate a functional test plan from this work folder"
- "Derive test cases for ZMMR001 and validate the messages against the system"

## Key Files

| File | Purpose |
|---|---|
| `references/test_case_derivation_rules.md` | Case-derivation checklist + provenance rules (read by Claude) |
| `references/test_plan_template.md` | Canonical section/sheet layout for the rendered plan |
| `references/sap_testplan_validate.ps1` | The `--validate` RFC backend (32-bit PowerShell) |

## Prerequisites

- A spec work folder (from `/sap-docs-extract`) or an object dossier (from
  `/sap-explain-object`) — `_process.txt` is mandatory in from-spec mode
- For `--validate`: a pinned RFC profile via `/sap-login` + SAP NCo 3.1
  (32-bit); no wrapper FM is needed (works on systems where `/sap-dev-init`
  never ran)
- For `--format xlsx|both`: the `anthropic-skills:xlsx` skill (falls back to
  md with an explicit WARN when unavailable)

## Suggested next steps

- `/sap-gen-abap-unit` — the automated counterpart: ABAP Unit tests for the
  developer-level cases
- Seed the listed test-data prerequisites (e.g. via the sap-project test lane)
  before executing the plan

## Limitations

- **Read-only.** No SAP writes on any path, no confirm gates, no Z objects.
- The offline derivation is system-independent; only `--validate` touches SAP
  (live-verified on S4D; ECC 6 fully supported).
- Every message is mapped or listed UNMAPPED; a fact is upgraded to VERIFIED
  only by a live `VALIDATE: VERIFIED` read — never by inference.
- Deferred: auto-invoking `/sap-explain-object --spec` for a bare object name
  (v1.5 — currently offered, not automatic); machine-readable scenario stubs
  for `/sap-test-replay` + `/sap-tcd-chain` (v2).

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
