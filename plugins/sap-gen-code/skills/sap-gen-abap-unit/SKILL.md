---
name: sap-gen-abap-unit
description: |
  Generates ABAP Unit tests for an EXISTING object (global class / function module
  / report) and closes the loop on a live system: pre-check the generated test,
  deploy, activate, run with coverage, read failures, fix, repeat until green
  (bounded). Reads the active source, builds a call/data map, and runs a SEAM
  ANALYSIS that classifies every DB read and external call into a doubling strategy
  (OSQL test double for SELECTs, ABAP test double for injected dependencies, or
  flags untestable-without-refactor), then emits a test class honest about what it
  could and could not cover. Pairs with /sap-run-abap-unit (which runs the tests).
  Deploy is GUI (/sap-se24 --test-source CCAU for a class, /sap-se38 for a report
  test) and gated — asks before writing anything (Rule 2).
  Prerequisites: pinned /sap-login connection; active GUI session for class download
  + deploy + run; SAP NCo 3.1 for RFC source read.
argument-hint: "<OBJECT_NAME | path-to.abap> [--type class|fm|program|auto] [--target-coverage <n>] [--max-rounds 3] [--doubles auto|osql|none] [--deploy ask|yes|no] [--risk-level harmless|dangerous|critical] [--no-gui]"
---

# SAP Generate ABAP Unit Tests Skill

You generate an ABAP Unit test class for an existing object, then **close the
loop**: pre-check → deploy → activate → run-with-coverage → read failures → fix →
repeat until tests pass and coverage meets the target (or you report honestly what
is not testable without a refactor). The *generation* is your reasoning; the
*deploy / activate / run / coverage* half reuses skills that are already live-tested.

This skill observes `shared/rules/skill_operating_rules.md`. **Rule 2 (no
unsolicited deployment) applies**: generation is read-only, but the deploy/run
loop writes a test artifact to SAP — it is gated behind `--deploy` (default `ask`).

Task: $ARGUMENTS

> **Vocabulary.** This is the `gen` half of the ABAP-unit pair:
> `sap-gen-abap-unit` (you) generates → `/sap-run-abap-unit` runs. Same
> "abap-unit" token on purpose.

---

## Shared Resources

| File / token | Path | Purpose |
|---|---|---|
| `sap_settings_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1` | settings merge |
| `sap_connection_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1` | `Get-SapWorkDir`, `Get-SapCurrentSessionPath` |
| `sap_object_resolver.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1` | type + TADIR identity |
| `sap_rfc_read_source.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_read_source.ps1` | `Read-SapAbapSource` (program/include/FM) |
| `sap_explain_parse.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-explain-object\references\sap_explain_parse.ps1` | source → `map.json` (units / externals / db reads+writes) — **drives the seam analysis** |
| SE24 download VBS | `<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-se24\references\sap_se24_check_and_download.vbs` | class source (GUI) |
| `sap_attach_lib.vbs` (`%%ATTACH_LIB_VBS%%`) | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs` | `AttachSapSession` for the download VBS |
| `abap_code_quality_rules.md` (§15) | `<SAP_DEV_CORE_SHARED_DIR>\rules\abap_code_quality_rules.md` | the ABAP Unit emission rules (`FOR TESTING DURATION SHORT RISK LEVEL HARMLESS`, `cl_abap_unit_assert=>assert_*`) |
| `customer_brief.md` | `{custom_url}\customer_brief_<LANG>.md` → `{custom_url}\customer_brief.md` → built-in `_<LANG>` variant → built-in template (`<LANG>`: `userConfig.template_language` → `userConfig.sap_language` → `EN`) | `MODE_MIN_COVERAGE`, `MODE_OOP`, release, risk level |
| `sap_log_helper.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1` | structured logging |

**Skills this one orchestrates** (skills-first, per CLAUDE.md Rule 6 — invoke via
the Skill tool, never re-implement): `/sap-check-abap`, `/sap-transport-request`,
`/sap-se24` (`--test-source`), `/sap-se38`, `/sap-activate-object`,
`/sap-run-abap-unit`.

`<SAP_DEV_CORE_SHARED_DIR>` = `plugins/sap-dev-core/shared` — 3 levels up from
`<SKILL_DIR>`, then into `sap-dev-core\shared`.

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom'))); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`.
Set `{WORK_TEMP}` = `{work_dir}\temp`, `{OUT}` = `{WORK_TEMP}\aunit_gen\{OBJECT}`,
and `{RUN_TEMP}` = the `RUN_TEMP=` value printed above (`Get-SapRunTemp` mints +
creates a fresh per-run dir `{work_dir}\temp\run_<id>` — holds the log state
file; mint once here and reuse the same value in Step 0.5 and Final).

```bash
cmd /c if not exist "{OUT}" mkdir "{OUT}"
```

---

## Step 0.5 — Start Logging (best-effort)

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_gen_abap_unit_run.json" -Skill sap-gen-abap-unit -ParamsJson "{\"target\":\"<OBJECT>\"}"
```

---

## Step 1 — Parse Arguments

| Arg | Default | Notes |
|---|---|---|
| positional | — | Object name (uppercase) OR a `.abap` file path (FILE mode = generate from local source, no acquisition). |
| `--type` | `auto` | `class` / `fm` / `program`. |
| `--target-coverage <n>` | brief `MODE_MIN_COVERAGE` / `0` | Coverage % to drive the fix loop toward. |
| `--max-rounds <n>` | `3` | Cap on generate→run→fix iterations. |
| `--doubles <m>` | `auto` | `auto` = pick per dependency (Step 4); `osql` = force OSQL DB doubles; `none` = no doubles (pure-function tests only). |
| `--deploy <m>` | `ask` | `ask` confirms before each write; `yes` runs the loop unattended; `no` generates + pre-checks only (no SAP write). |
| `--risk-level <l>` | brief / `harmless` | Caps the emitted `RISK LEVEL`. The client's `SAUNIT_CLIENT_SETUP` is the real gate. |
| `--no-gui` | false | RFC-only acquisition; class bodies degrade to signature; deploy loop unavailable (needs GUI). |

If the positional is missing, ask and stop.

---

## Step 2 — Resolve Type + Acquire Source

Same acquisition the comprehension skills use:

- **OBJECT mode** — resolve identity via `sap_object_resolver.ps1` (32-bit, creds
  fall back to the pinned profile) → `{TYPE}`, `{PGMID}`, TADIR object code. Then:
  - program / include / FM → `Read-SapAbapSource -Name '{OBJECT}' -Type '{TYPE}' -OutDir '{OUT}' -WithIncludes` (RFC).
  - class → SE24 download VBS (GUI; substitute `%%CLASS_NAME%% %%OUTPUT_FILE%% %%SESSION_PATH%% %%ATTACH_LIB_VBS%%`, set `$env:SAPDEV_SESSION_PATH`, run 32-bit cscript) — as `/sap-explain-object` does.
- **FILE mode** — read the file into `{OUT}\source.txt`; infer type + name from the top-level statement.

Source lands at `{OUT}\source.txt`.

---

## Step 3 — Build the Map + Load Context

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-explain-object\references\sap_explain_parse.ps1" -SourceDir "{OUT}" -OutFile "{OUT}\map.json"
```

`map.json` gives the **units** (methods/FORMs to cover), **externals** (CALL
FUNCTION / CALL METHOD edges = candidate seams), and **db_reads / db_writes** (the
SELECTs that need OSQL doubles). Read the **customer brief** (`MODE_MIN_COVERAGE`,
`MODE_OOP`, ABAP **release** → modern syntax, default risk level) and
`abap_code_quality_rules.md` §15 (the canonical test-class shape).

---

## Step 4 — Seam Analysis (the hard part)

For each unit under test, classify every dependency from `map.json` and pick a
strategy. **Be honest** — legacy code with hard-wired statics is not magically
unit-testable.

| Dependency (from map.json) | Strategy | Emitted scaffold |
|---|---|---|
| `SELECT` on a table (`db_reads`/`db_writes`) | **OSQL test double** (`auto`/`osql`) | `cl_osql_test_environment=>create( … )` in `class_setup`, `…->insert_test_data( lt_rows )` per test, teardown `…->destroy( )`. Code under test runs unchanged, reads the doubles. |
| Dependency injected via constructor / setter (interface ref) | **`CL_ABAP_TESTDOUBLE`** | `cl_abap_testdouble=>create( '<IF>' )`, `…=>configure_call( )->returning( )`, inject into the CUT. |
| Static `CALL FUNCTION` / `CALL METHOD` with side effects, **no seam** | **Flag `SEAM_NEEDED`** | No double possible without a wrapper. Emit a `" TODO seam:` comment + a `testability.md` entry recommending the minimal injection refactor. Cover the pure parts only. |
| Pure unit (inputs → outputs, no I/O) | **Direct** | arrange / act / `cl_abap_unit_assert=>assert_equals( … )` with boundary + equivalence cases. |

Write `{OUT}\testability.md` — per unit: covered / partial / not-testable + reason.
This is the honesty contract; never imply coverage you can't deliver.

### Test container by object type

| `{TYPE}` | Container | Deploy via | Run via |
|---|---|---|---|
| `class` | CCAU **Local Test Classes** include — `CLASS ltcl_…_test DEFINITION FOR TESTING …` + IMPLEMENTATION only (NOT the global class) → `{OUT}\{OBJECT}_CCAU.abap` | `/sap-se24 {OBJECT} --test-source={OUT}\{OBJECT}_CCAU.abap` | `/sap-run-abap-unit {OBJECT} --type=CLASS --with-coverage` |
| `fm` | a standalone **test program** `Z<NS>_<FM>_UT` whose local test class `CALL FUNCTION '{OBJECT}'` and asserts on outputs | `/sap-se38` | `/sap-run-abap-unit Z<NS>_<FM>_UT --type=PROGRAM --with-coverage` |
| `program` | a **test program** `Z<NS>_<RPT>_UT` (or `Z<PROGRAM_ID>_TEST` for `/sap-gen-abap` output) | `/sap-se38` | `/sap-run-abap-unit <container> --type=PROGRAM --with-coverage` |

> **Report honesty.** A report's logic in `FORM`s cannot be called from a separate
> program. For a report, test only what is reachable: Z* FMs/classes it calls, or
> a `SUBMIT … AND RETURN` characterization test against known input (integration-
> level — mark it as such). If the logic is monolithic `FORM`s with no seam, say so
> and recommend extracting a testable class; do not fabricate coverage.

---

## Step 5 — Generate the Test Source

Emit the container source to the path in the table above, following
`abap_code_quality_rules.md` §15 and the brief (release-correct syntax — heed the
[sap-gen-abap inline-type pitfalls] the generator already knows: no
`STANDARD TABLE OF dbtab` in `METHODS` sigs on 7.52, named types not anonymous
`@DATA()` in method params, no inline `DATA(...)` in `CALL FUNCTION IMPORTING`).

Shape: `CLASS ltcl_… DEFINITION FOR TESTING DURATION SHORT RISK LEVEL {RISK}`,
`setup` / `teardown` (+ `class_setup`/`class_teardown` for the OSQL environment),
one `FOR TESTING` method per behavior with arrange/act/assert. Keep method names
descriptive (`test_<unit>_<case>`).

---

## Step 6 — Pre-Check the Generated Source (offline)

Run `/sap-check-abap {OUT}\<test-source>` to catch naming/type/syntax issues
**before** touching SAP. Fix anything it flags, then proceed. (This is the cheap
gate; it has no false-green for the patterns it knows.)

---

## Step 7 — Deploy / Activate / Run / Fix Loop

Skip entirely if `--deploy no` (stop after Step 6 with the generated source +
testability report). Otherwise, with `--deploy ask` confirm before the first
write; with `--deploy yes` run unattended. Resolve a TR once via
`/sap-transport-request`.

Loop, `round = 1 … --max-rounds`:

1. **Deploy** the container (`/sap-se24 --test-source=…` for a class, `/sap-se38`
   for a program).
2. **Activate** via `/sap-activate-object` (test includes/programs deploy inactive).
3. **Run** `/sap-run-abap-unit <container> --type=<T> --with-coverage --min-coverage=<target>`.
4. Read the verdict:
   - `AUNIT_VERDICT: PASS` **and** coverage ≥ target → **done**, exit the loop.
   - failures (`ALERT:` lines) or coverage < target, and `round < max-rounds` →
     feed the failing `class::method — message` lines and the uncovered units back
     into your generation, **regenerate** the affected tests, and repeat.
   - `SKIPPED:NO_TESTS` → generation produced nothing runnable; stop and report
     (Step 4 likely flagged the object untestable).
5. On `round = max-rounds` without green: stop and report the best state honestly
   (passing tests + remaining failures + achieved coverage). Never loop unbounded.

Respect `skill_operating_rules` Rule 2 at every write: under `ask`, surface the
exact object + TR and wait for confirmation.

---

## Step 8 — Report

Summarize: object + type, container deployed, tests passing/total, coverage
achieved vs target, rounds used, and — prominently — the **testability report**
(units covered / partial / needing a seam refactor). Point the user at
`{OUT}\testability.md` and the generated source. If `--deploy no`, say the tests
were generated + pre-checked but not deployed, and give the one-line deploy command.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_gen_abap_unit_run.json" -Status SUCCESS -ExitCode 0
```

| Outcome | Status / ExitCode / ErrorClass |
|---|---|
| Tests pass + coverage met | `-Status SUCCESS -ExitCode 0` |
| Generated, not deployed (`--deploy no`) | `-Status SUCCESS -ExitCode 0` |
| Loop ended with failures / below coverage | `-Status FAILED -ExitCode 1 -ErrorClass AUNIT_GEN_NOT_GREEN -ErrorMsg "failed=F cov=C%"` |
| Object untestable without refactor | `-Status SKIPPED -ExitCode 0 -ErrorClass AUNIT_GEN_NO_SEAM` |
| Source could not be acquired | `-Status FAILED -ExitCode 2 -ErrorClass AUNIT_GEN_SOURCE_UNAVAILABLE` |

---

## Limitations

- **Generation is reasoned, not guaranteed compile-clean on the first round.** That
  is exactly why the loop exists; `--max-rounds` bounds it.
- **Seams decide testability.** Hard-wired statics / monolithic `FORM`s cap what
  unit testing can reach — the skill flags this rather than faking coverage.
- **Reports are partially testable** (callable Z* dependencies + SUBMIT
  characterization only) — see the Report-honesty note.
- **Coverage is the runner's overall %** (statement/branch split is the runner's
  later refinement). Gate per the brief's `aunit_coverage_gate` (warn vs block).
- **FM / report coverage scope (live-confirmed S4D 2026-06-03).** When the test
  lives in a **separate** test program (`fm` and `program` containers), the coverage
  run scopes to that test program — whose only code is test code — so the production
  logic under test (e.g. the FM in its own function group) is **not** counted and
  coverage reads `0.00` / `NA` even though the tests pass. This is expected, not a
  failure: report tests-pass and coverage separately, and tell the user that FM
  coverage requires measuring the function group. The **`class` (CCAU) container
  does** capture coverage, because the test class sits inside the class under test.
- **Single object per invocation.** For a package, iterate object-by-object and log
  what you skip.
- **Writes are gated** behind `--deploy` and `/sap-transport-request`; nothing
  reaches SAP without a TR and (under `ask`) confirmation.

---

## Pipeline Integration

```
existing object ──► [ sap-gen-abap-unit ] ──► /sap-se24 --test-source | /sap-se38
                      (generate + seam)            (deploy)
                                   └──► /sap-activate-object ──► /sap-run-abap-unit --with-coverage ──► (fix loop)
```

Complements `/sap-gen-abap` (which emits `Z<PROGRAM_ID>_TEST` alongside new code):
this skill brings the same test discipline to **brownfield** objects that shipped
with no tests. A regression safety net here is the precondition the `sap-migrate`
remediation flow wants before it changes anything.
