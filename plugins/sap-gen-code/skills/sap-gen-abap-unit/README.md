# SAP Generate ABAP Unit Tests Skill

Generates an ABAP Unit test class for an **existing** object (global class,
function module, or report) and closes the loop on a live system:
pre-check → deploy → activate → run with coverage → read failures → fix →
repeat until green (bounded by `--max-rounds`).

This is the `gen` half of the ABAP-unit pair: `sap-gen-abap-unit` generates,
`/sap-run-abap-unit` runs. It complements `/sap-gen-abap` (which emits a
`Z<PROGRAM_ID>_TEST` alongside newly generated code) by bringing the same test
discipline to **brownfield** objects that shipped with no tests.

## Skill Overview

1. Resolve the object's identity (`sap_object_resolver.ps1`) and acquire the
   active source — RFC read for programs/includes/FMs, SE24 GUI download for
   classes, or a local `.abap` file directly (FILE mode)
2. Build a call/data map (`map.json`: units, externals, DB reads/writes) and
   load the customer brief (`MODE_MIN_COVERAGE`, `MODE_OOP`, ABAP release,
   risk level)
3. **Seam analysis** — classify every dependency into a doubling strategy:
   - `SELECT` on a table → **OSQL test double** (`cl_osql_test_environment`)
   - injected interface dependency → **`CL_ABAP_TESTDOUBLE`**
   - hard-wired static call with no seam → flag **`SEAM_NEEDED`** (no fake
     coverage; a `testability.md` honesty report records what is and is not
     testable)
4. Generate the test container: a CCAU local-test-classes include for a class,
   a standalone test program for an FM or report
5. Pre-check offline via `/sap-check-abap`, then (gated behind `--deploy`)
   run the deploy → activate → run-with-coverage → fix loop through
   `/sap-se24 --test-source` / `/sap-se38`, `/sap-activate-object`, and
   `/sap-run-abap-unit`
6. Report tests passing/total, coverage vs target, rounds used, and the
   testability report

## Auto-Trigger Keywords

- `generate unit tests`, `gen abap unit`, `write ABAP Unit tests for Z...`
- `add tests to an existing class / FM / report`

## Usage

```text
/sap-gen-abap-unit <OBJECT_NAME | path-to.abap> [--type class|fm|program|auto] [--target-coverage <n>] [--max-rounds 3] [--doubles auto|osql|none] [--deploy ask|yes|no] [--risk-level harmless|dangerous|critical] [--no-gui]
```

Flags:

- `--type` — object kind (default `auto`, resolved via TADIR)
- `--target-coverage <n>` — coverage % the fix loop drives toward (default:
  the brief's `MODE_MIN_COVERAGE`, else 0)
- `--max-rounds <n>` — cap on generate→run→fix iterations (default 3)
- `--doubles` — `auto` picks per dependency; `osql` forces OSQL DB doubles;
  `none` emits pure-function tests only
- `--deploy` — `ask` (default) confirms before each write; `yes` runs the loop
  unattended; `no` generates + pre-checks only, no SAP write
- `--risk-level` — caps the emitted `RISK LEVEL` (default from brief /
  `harmless`)
- `--no-gui` — RFC-only acquisition; class bodies degrade to signature; the
  deploy loop is unavailable

Conversational forms:

- "Generate ABAP Unit tests for ZCL_PRICING_ENGINE"
- "Write unit tests for FM Z_CALC_TAX and run them until green"
- "Generate tests for this .abap file but don't deploy anything"

## Prerequisites

- Pinned SAP connection via `/sap-login`; SAP NCo 3.1 (32-bit) for the RFC
  source read
- Active SAP GUI session for class download, deploy, and the test run
  (FILE mode with `--deploy no` needs no SAP connection)
- Optional but recommended: a filled `customer_brief.md` (coverage target,
  OOP mode, ABAP release, risk level)

## Suggested next steps

- `/sap-run-abap-unit <container> --with-coverage` — re-run the suite
  standalone later (regression)
- `/sap-atc` — quality gate on the object and its new test container
- For objects flagged `SEAM_NEEDED`: apply the minimal injection refactor from
  `testability.md`, then re-run this skill

## Limitations

- Generation is reasoned, not guaranteed compile-clean on the first round —
  that is why the loop exists, bounded by `--max-rounds`.
- Seams decide testability: hard-wired statics / monolithic `FORM`s cap what
  unit testing can reach. The skill flags this rather than faking coverage;
  reports are only partially testable (callable Z* dependencies plus
  `SUBMIT` characterization tests).
- FM / report containers live in a **separate** test program, so the coverage
  run scopes to that program and reads `0.00` / `NA` even when tests pass
  (live-confirmed S4D). Only the `class` (CCAU) container captures real
  coverage.
- Single object per invocation — for a package, iterate object by object.
- Writes are gated behind `--deploy` and `/sap-transport-request`; nothing
  reaches SAP without a TR and (under `ask`) explicit confirmation.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
