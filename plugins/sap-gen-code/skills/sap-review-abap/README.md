# SAP Review ABAP Skill

AI semantic + security code review for an **existing** ABAP object or a local
`.abap` file. Reads the active source, builds a structure + call/data map,
then reasons over the code across a fixed dimension checklist — emitting
prioritized, line-cited findings that a rule engine structurally cannot
derive. **Read-only**: it never deploys, activates, or edits.

This is the *judgment* stage of the quality lane, distinct from its
neighbours:

```
sap-gen-abap → sap-check-abap → [ sap-review-abap ] → sap-atc → sap-fix-abap → deploy
                (deterministic)     (semantic)         (gate)     (apply)
```

- `/sap-check-abap` — deterministic parse: naming, DDIC types, SQL field
  existence. Cheap, exact, no judgement.
- `/sap-atc` — SAP's in-system Code Inspector rule set; the hard gate.
- `/sap-review-abap` — LLM reasoning over logic, security, and performance.
  Advisory by default.

## Skill Overview

1. Acquire the source: RFC read for programs/includes/FMs, SE24 GUI download
   for classes, or a local `.abap` file directly (FILE mode — no SAP
   connection needed)
2. Build `map.json` (units, external calls, DB reads/writes) and load the
   customer brief (release, `MODE_*` flags, Quality bar)
3. Review across five dimensions, each category anchored to a §-rule in
   `abap_code_quality_rules.md`:
   - **security** — dynamic-SQL injection, missing/wrong `AUTHORITY-CHECK`,
     client handling, hardcoded secrets
   - **correctness** — unchecked `SY-SUBRC`, unguarded `READ TABLE`, logic
     errors, uninitialized use
   - **perf** — SELECT-in-LOOP, nested loops, unguarded `FOR ALL ENTRIES`,
     `SELECT *`
   - **robustness** — `MESSAGE e` in methods, unhandled exceptions, LUW
     hygiene, missing locks
   - **maintainability** — method length, dead code, magic numbers, deep
     nesting
4. **Adversarial self-verification** — a mandatory second pass that tries to
   refute each candidate; findings without a defensible line + code excerpt
   are dropped (precision over recall)
5. Gate findings via the customer brief's Quality bar, compute a
   GO / GO_WITH_WARNINGS / NO_GO verdict, and export
   `<OBJECT>.review.tsv` / `.review.json` through the shared finding model
   (collected by `/sap-evidence-pack`, composable into
   `/sap-transport-readiness`)
6. Synthesize `review.md` — verdict banner, findings with excerpts and fixes,
   an explicit "Not checked" honesty section, and suggested next steps

## Auto-Trigger Keywords

- `review abap`, `code review Z...`, `security review of this program`
- `is this ABAP safe / performant`, `review this .abap file`

## Usage

```text
/sap-review-abap <OBJECT_NAME | path-to.abap> [--type program|include|fm|class|auto] [--dimensions all|security,perf,correctness,robustness,maintainability] [--callers] [--gate advisory|block] [--no-gui]
```

Flags:

- `--type` — object kind (default `auto`; inferred from source in FILE mode)
- `--dimensions` — comma list to restrict the review (default `all`)
- `--callers` — pull where-used to weight blast radius (OBJECT mode, needs a
  GUI session)
- `--gate` — `advisory` (default) reports only; `block` computes a blocking
  pre-deploy verdict (strict gate policy)
- `--no-gui` — RFC-only; class bodies degrade to signature-only and
  `--callers` is ignored

Conversational forms:

- "Review ZMMR001 for security and performance"
- "Code-review this .abap file before I deploy it"
- "Review ZCL_PRICING_ENGINE with blast radius" (triggers `--callers`)

## Prerequisites

- Pinned `/sap-login` connection for object-name input (RFC source read)
- Active SAP GUI session for class download and `--callers`
- A local `.abap` file needs no SAP connection at all
- Optional: a filled `customer_brief.md` §6 Quality bar (controls gating);
  `_authz_signatures.txt` from a prior `/sap-gen-abap` run lets the security
  dimension verify auth objects against SU21 instead of marking them
  `COULD_NOT_CHECK`

## Suggested next steps

- `/sap-fix-abap` — apply the mechanical fixes
- `/sap-atc` — the hard in-system quality gate
- `/sap-gen-abap-unit` — add tests where coverage on the risky paths is thin

## Limitations

- **Judgement, not proof.** Findings are reasoned, not theorem-proved; treat
  MEDIUM/LOW-confidence items as prompts for a human. Advisory by default for
  exactly this reason.
- OBJECT mode reviews the **active** version only — use FILE mode for an
  in-flight working copy.
- Class source is the pretty-printed display view (flagged in the report).
- Dynamic dispatch and macros are not traced — always disclosed in the
  "Not checked" section of `review.md`.
- Single object per invocation; for a TR or package, expand the inventory and
  call once per object.
- Read-only — never deploys, activates, or edits.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
