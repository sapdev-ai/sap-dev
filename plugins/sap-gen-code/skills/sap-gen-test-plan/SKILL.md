---
name: sap-gen-test-plan
description: |
  Turns a design-spec work folder (_process.txt / _golden.txt / _errorMsgs.txt from
  /sap-docs-extract) or an /sap-explain-object dossier into a reviewer-ready FUNCTIONAL
  test plan — cases per process step, exactly one negative case per validation rule wired
  to its error message, boundary cases per selection field, and a case<->step<->rule<->message
  traceability matrix — closing the gap where the spec's Golden Tests sheet feeds ONLY ABAP
  Unit generation and nobody derives the functional plan, so QA re-derives cases by hand and
  error paths go untested. Offline-first: pure derivation + rendering (md, or xlsx via
  anthropic-skills:xlsx). An optional --validate flag adds a read-only RFC pass that confirms
  every referenced message (T100/T100A), table (DD02L), tcode (TSTC), and FM (TFDIR), pulls
  DD03L key fields into test-data templates, and upgrades provenance INFERRED->VERIFIED (with
  MISMATCH/NOT_FOUND surfaced as findings, tri-state COULD_NOT_CHECK honesty). Every message is
  mapped to a provoking case or lands in UNMAPPED (verdict WARN, never dropped); a case is
  CONFIRMED (spec-traceable) or INFERRED (model-derived) and no path flips that without a live
  read. Read-only; no SAP writes, no confirm gates. Prerequisites: a spec work folder or an
  object dossier; for --validate a pinned RFC profile via /sap-login + NCo 3.1 (32-bit).
argument-hint: "<work_folder | OBJECT | dossier_dir> [--format md|xlsx|both] [--validate] [--out <dir>]"
---

# SAP Generate Test Plan Skill

You derive a functional test plan from a spec or an object dossier: a case per process
step, one negative case per validation rule mapped to its message, boundary cases per
selection field, and a full traceability matrix — with honest coverage (UNMAPPED /
UNCOVERED are shown, never hidden) and an optional live-RFC grounding pass. You never
write to SAP.

Task: $ARGUMENTS

The derivation is **yours** (steered by `references/test_case_derivation_rules.md`); the
`--validate` RFC pass and the rendering helpers are scripts.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/test_case_derivation_rules.md` | read by Claude | Case-derivation checklist + provenance rules |
| `<SKILL_DIR>/references/test_plan_template.md` | read by Claude | Canonical section/sheet layout |
| `<SKILL_DIR>/references/sap_testplan_validate.ps1` | `-InFile -OutTsv` | The --validate RFC backend (Layer 2) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced / CLI | Object resolution (dossier mode + validate connect) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | `Register-SapArtifact`, scope key |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` | dot-sourced | `New-SapFinding` for MISMATCH/NOT_FOUND |
| `/sap-explain-object` | sub-skill | Dossier acquisition (`--spec`) in from-dossier mode |
| `anthropic-skills:xlsx` | sub-skill | `--format xlsx\|both` rendering |
| `/sap-login` | sub-skill | Pinned RFC profile (only for `--validate`) |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_gen_test_plan_run.json" -Skill sap-gen-test-plan -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments & Detect Mode

- Arg is a directory containing `*_process.txt` -> **from-spec**.
- Arg is a directory containing a dossier / `map.json` -> **from-dossier**.
- Arg is a bare object name -> resolve via `sap_object_resolver.ps1`; if no dossier exists,
  offer `/sap-explain-object <OBJ> --spec` (read-only) and consume its output (v1.5 auto-invoke).
- Else abort `INPUT_NOT_FOUND`.

Flags: `--format md|xlsx|both` (default md), `--validate`, `--out <dir>`.

## Step 2 — Load Inputs

- **from-spec:** read the TSVs. Split `_process.txt` on its `# === VALIDATION ===` /
  `# === PROCESS ===` banners (a banner-less file = one PROCESS block, degraded, WARN).
  `_process.txt` is MANDATORY (abort `TESTPLAN_INPUT_INCOMPLETE` if absent/empty); WARN on
  missing `_golden.txt` / `_errorMsgs.txt`. Optional enrichers: `_interface.txt`,
  `_selection_definition.txt`, `_tables.txt` + `table_data_*.txt`, `_deps.txt`.
- **from-dossier:** read the dossier + `map.json` (units, call edges, db_reads/db_writes,
  selection screen, message usages).

Build the internal model: `steps[]`, `validation_rules[]`, `messages[]`, `golden_rows[]`,
`selection_fields[]`, `tables[]`.

## Step 3 — Derive Cases

Follow `references/test_case_derivation_rules.md` exactly: import golden rows (CONFIRMED);
one positive case per step (CONFIRMED); one negative case per validation rule wired to its
`ERR_MSG_REF` (CONFIRMED); boundary cases per selection field + defensible edge cases
(INFERRED). Assign `TC-###` ids.

## Step 4 — Message Mapping + Traceability

Map every message to >=1 provoking case; build the case<->step<->rule<->message matrix;
collect `UNMAPPED` messages and `UNCOVERED` steps. Never drop either — they downgrade the
verdict to WARN.

## Step 5 — Test-Data Prerequisites

From golden INPUTS + `_tables.txt` + `table_data_*.txt` (+ map.json db_reads) list per-table
prerequisites (table, purpose, key template, rows needed, source).

## Step 6 — Validate (only with `--validate`)

Write the facts to check into `{RUN_TEMP}\validate_in.tsv` (one `<kind>\t<name>\t<sub>` per
line: `msg`+MSGID+MSGNO for every referenced message, `table`/`tcode`/`fm` for prerequisites,
`keyfields`+TABNAME for every test-data table), then run via **32-bit PowerShell**:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_testplan_validate.ps1" -InFile "{RUN_TEMP}\validate_in.tsv" -OutTsv "{OUT}\validate_results.tsv" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Parse `VALIDATE:` lines. `VERIFIED` -> upgrade that fact's status; `MISMATCH` / `NOT_FOUND`
-> `New-SapFinding` (severity MEDIUM, coverage CHECKED) and fold the fact into the plan as a
flagged expected-result. `keyfields VERIFIED` -> use the returned key list as the test-data
key template. `STATUS: RFC_ERROR` (exit 2) or `COULD_NOT_CHECK` (exit 1) -> mark ALL facts
COULD_NOT_CHECK, cap the verdict at WARN, and STILL render the offline plan — never abort,
never upgrade a fact to VERIFIED without its live read.

## Step 7 — Render

`{OUT}` = `--out` value, else the work folder (from-spec) / dossier dir (from-dossier).
Write `{OUT}\{doc_name}_test_plan.md` from `references/test_plan_template.md`. `--format
xlsx|both` -> delegate to `anthropic-skills:xlsx` for `{doc_name}_test_plan.xlsx` (six
sheets mirroring the template). If the xlsx skill is unavailable, fall back to md with an
explicit WARN (never a silent format downgrade). Always write `traceability.tsv` +
`test_data_prereqs.tsv` (+ `validate_results.tsv` with `--validate`).

## Step 8 — Register + Summarize

```bash
powershell -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-gen-test-plan' -ScopeKey '<SCOPE_KEY>' -Kind 'test_plan' -Format 'md' -Path '{OUT}\{doc_name}_test_plan.md' -Verdict '<OK|WARN>' -Coverage '<CHECKED_CLEAN|CHECKED_FINDINGS|COULD_NOT_CHECK>'"
```

Print the coverage summary (cases by provenance, messages mapped/unmapped, steps
covered/uncovered, validate verdict) + suggested next steps.

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_gen_test_plan_run.json" -Status SUCCESS -ExitCode 0
```

`SUCCESS` (clean) / `SUCCESS` + note WARN (unmapped/uncovered/COULD_NOT_CHECK) / `FAILED`
with error_class (`INPUT_NOT_FOUND`, `TESTPLAN_INPUT_INCOMPLETE`, `TESTPLAN_RENDER_FAILED`,
`RFC_LOGON_FAILED`).

---

## Scope & Limitations (v1)

- **v1 implemented:** from-spec (work folder) and from-dossier (dossier dir) derivation;
  `--validate` read-only RFC grounding (messages, tables, tcodes, FMs, key-field templates);
  `--format md|xlsx|both`; provenance (CONFIRMED/INFERRED) + validate tri-state
  (VERIFIED/MISMATCH/COULD_NOT_CHECK); traceability matrix with UNMAPPED/UNCOVERED sections.
- **Verified:** the `--validate` backend is **live-verified on S4D** — real message
  (00/001 VERIFIED), fake class (NOT_FOUND), defined-class/undefined-number (MISMATCH), real
  vs fake table/tcode/FM, and DD03L key-field templates (MANDT stripped) all return the
  correct status. All three FMs probed FMODE=R on S4D + EC2, so `--validate` needs no wrapper
  FM and works on a system where /sap-dev-init never ran.
- **Honesty invariants:** every message is mapped or UNMAPPED (WARN); a case is CONFIRMED
  only when spec-traceable; no path flips INFERRED->VERIFIED without a live `VALIDATE:
  VERIFIED` line; RFC failure => COULD_NOT_CHECK on every fact, verdict capped at WARN, offline
  plan still written.
- **Deferred:** v1.5 auto-invoke of `/sap-explain-object --spec` by bare object name; v2
  machine-readable scenario stubs for /sap-test-replay + /sap-tcd-chain (blocked on the
  /sap-test-replay checkpoint contract — deliberate merge decision).
- **Read-only.** No SAP writes on any path; no confirm gates (Rule 5 never bites — nothing is
  executed/scheduled); no Z objects (Rule 2 never bites). ECC 6 support is full for
  `--validate` (11/11 probed identical); the offline core is system-independent.
