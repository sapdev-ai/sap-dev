# Design — `/sap-run-abap-unit` (execute ABAP Unit + coverage)

**Status**: **Phase 1 (GUI backend) implemented and live-verified on S4D /
S/4HANA 1909.** Phases 2 (RFC coverage) and 3 (ADT) remain proposed.
**Rev 2 (2026-06-03)**: resolved open items; tightened mode-dispatch precedence,
coverage attribution, risk-level semantics, and the runner-API spike ladder.
**Rev 3 (2026-06-03)**: Phase 1 built + **live-verified on S4D** — all three
branches (pass / fail / no-tests) confirmed end-to-end. Key correction from
testing: the run trigger is the SE38/SE24 **menu** (`Program > Execute > Unit
Tests` = `mbar/menu[0]/menu[9]/menu[2]`; `Class Source > Run > Unit Tests` =
`mbar/menu[0]/menu[7]/menu[0]`), **not** Ctrl+Shift+F10 (SE80-only — raises
"virtual key is not enabled"). Result read from the `SAPLSAUNIT_RSLT_DSPLY`
display (alert-grid `RowCount` = failures) + status-bar summary (methods) +
`MessageType` S/W on the editor (pass / no-tests). Note: GUI coverage IS
reachable (`Run > Unit Tests With > Coverage`) — a possible alternative to the
Phase-2 RFC backend. Test report: `temp/testReport/run_abap_unit_20260603.md`.
**Rev 4 (2026-06-03)**: GUI **coverage** wired + live-verified on S4D
(`coverage=33.33` on a 1-of-3-procedures fixture). Trigger = `… > Unit Tests With
> Coverage` (`menu[0]/menu[9]/menu[3]/menu[0]` SE38; `menu[0]/menu[7]/menu[1]/menu[0]`
SE24) → AUCV display `SAPLSAUCV_DISPLAY_MULTI_TAB`, "Coverage Metrics" tab
`tabpFSCOV`, tree root `PERCENTAGE`. Implemented as a **two-phase** run (plain
counts + coverage) because the AUCV display has no status-bar summary — opt in via
`--with-coverage` / `--min-coverage`. So the GUI backend now delivers a large part
of the Phase-2 coverage goal; the RFC helper remains for headless / single-run /
per-metric (statement/branch/procedure) coverage.
**Rev 5 (2026-06-03)**: SE24 (global class) results path **live-verified on S4D** —
and it caught a real parser bug. The alert ALV lists alerts of varying *severity*,
and a **class always opens the result display even on all-pass** (with a Tolerable
"no test relation" warning), so counting all alert rows as failures was wrong.
Fixed: `CountFailures` reads the `ICON_LEVEL` column and counts only non-tolerable
rows (`@8R` Tolerable excluded; `@8O` Critical / Fatal counted) — verified
pass⇒`failed=0`, fail⇒`failed=1`. SE24 coverage trigger + AUCV display verified;
`ReadCoverage` made **search-based** (`FindCovPct`) because the
`SAPLSAUCV_DISPLAY_COVERAGE:NNNN` subscreen number is launch-variant. The
self-testing global `FOR TESTING` fixture has no production code under test
("no test relation") so it yields `coverage=NA`; a real SE24 coverage number needs
a class that tests a *separate* production class (the read path is shared with the
verified SE38 `33.33%`).
**Rev 6 (2026-06-03)**: SE24 coverage **closed end-to-end** — deployed a production
class (`ZCL_AUNIT_COV`, methods `add`/`sub`) plus a test class in its `CCAU` "Local
Test Classes" include (tests `add`, not `sub`) and read `coverage=50.00` live (1 of
2 methods covered). The `CCAU` fixture is built by navigating to the test-class pane
(SE24 toolbar `btn[35]` → `SAPLSEO_CLEDITOR`) **before** the upload (the upload
targets the current editor). Refined finding: with a *normal* test relation, an
all-pass class stays on the editor (sbar `S`) like a report — only the self-test
"no test relation" case opens the result display on all-pass; the parser handles
both. So SE38 (`33.33%`) and SE24 (`50.00%`) coverage are both live-verified.

**Roadmap ref**: P2 — "Close the test loop: run ABAP Unit + coverage."

**Plugin / location (when built)**: `plugins/sap-dev-core/skills/sap-run-abap-unit/`
(a runtime/workbench operation like `/sap-atc` and `/sap-activate-object` —
reusable beyond the generation pipeline, so it lives in **sap-dev-core**, not
sap-gen-code).

**Depends on**: `/sap-dev-init` (deploys the RFC helper), `/sap-activate-object`
(active-state pre-req), `shared/templates/customer_brief.md` (MODE flags),
`agents/abap-developer.md` (new Step 2j.1).

**Decisions locked (2026-06-03)**:
1. **Coverage backend = RFC helper** — deploy a small `Z_AUNIT_RUN` FM + DDIC,
   matching how `Z_GENERIC_RFC_WRAPPER_TBL` ships today.
2. **Auto-run when brief = mandatory** — agent Step 2j.1 auto-runs only when the
   Customer Brief marks ABAP Unit `yes (mandatory)`; failed tests STOP.
3. **Coverage gate = warn by default** — below-min coverage warns (exit 0); only
   test failures fail the run. `aunit_coverage_gate=block` makes it gating.

---

## TL;DR

`sap-gen-abap` emits `Z<PROGRAM_ID>_TEST.abap` (program holding local test class
`ltcl_main`, one `test_*` per golden row); the `abap-developer` agent deploys +
activates it at **Step 2j** and then **deliberately stops** ("do not auto-execute
… that's the user's call"). Generated tests are therefore never run — coverage is
illusory.

This skill **executes** ABAP Unit on a deployed object and returns structured
pass/fail + code-coverage, with a verdict gate. It also works standalone on any
brownfield object. Three backends, resolved by `sap_dev_mode`:
**RFC helper (default)** → **GUI (fallback)** → **ADT (future, P12)**.

---

## 1. Run target (important)

The run target is the **container object** holding the `FOR TESTING` classes:

- Generated code → the program **`Z<PROGRAM_ID>_TEST`** (holds `ltcl_main`).
- Brownfield → any program or global class whose local/embedded test classes
  should execute.

Pre-req: object must be **active**. The skill verifies active state (RFC
`PROGDIR.STATE` for programs / `SEOCLASS` for classes — same check `/sap-se38`
uses) and, if inactive, emits `AUNIT_OBJECT_INACTIVE` and points the caller at
`/sap-activate-object` rather than running stale code.

### Non-goals & prerequisites

**Non-goals (v1)**: does not author or repair failing tests (that stays with the
developer / `/sap-fix-abap`); does not provision test data / fixtures; does not
run multiple objects per invocation (single container, like `/sap-atc`); does not
gate on ATC findings (that is `/sap-atc`).

**Prerequisites**: an active SAP session (GUI backend) or saved RFC profile (RFC
backend) via `/sap-login`; developer authorization to execute ABAP Unit
(`S_DEVELOP` on the object); for coverage, the `Z_AUNIT_RUN` helper deployed via
`/sap-dev-init`.

---

## 2. Backend strategy & mode dispatch

`sap_dev_mode` semantics apply, but **BDC is N/A** (no batch-input path to
AUnit), so the skill declares per-backend availability the way
`/sap-function-group` documents "GUI only / RFC only":

| Capability | RFC (helper) | GUI | ADT (future, P12) |
|---|---|---|---|
| Pass/fail per method | ✅ structured | ✅ parse result tree (fragile) | ✅ cleanest |
| Code coverage % | ✅ AUCV runner | ⚠️ deferred (best-effort) | ✅ |
| Headless / no GUI window | ✅ | ❌ needs GUI session | ✅ |
| Language-neutral | ✅ (no UI text) | ⚠️ via MessageType/IDs only | ✅ |
| Zero Z-footprint | ❌ 1 FM + 5 DDIC | ✅ | ✅ |
| Works on old ECC w/o ADT | ✅ | ✅ | ❌ |

**Resolution precedence** (first match wins):

1. **`--mode RFC|GUI|ADT`** explicit flag.
2. **`aunit_default_mode`** setting, when not `auto`.
3. **`auto`** (default): if the `Z_AUNIT_RUN` helper exists (TFDIR probe) → **RFC**
   (the only backend with coverage); else if a GUI session is attachable → **GUI**;
   else if ADT services are active → **ADT**.

`auto` intentionally prefers RFC over the global `sap_dev_mode`, because coverage
(the reason this skill exists) needs RFC. The global `sap_dev_mode` is honoured
only as a tiebreaker when coverage is **not** requested and both RFC and GUI are
viable. GUI release-variants resolve through `sap_select_vbs_variant.ps1`.

---

## 3. Backend A (default) — RFC helper `Z_AUNIT_RUN`

Gives results **and** coverage, headless and language-neutral, and fits the
established "deploy a small Z utility via `/sap-dev-init`" model (exactly how
`Z_GENERIC_RFC_WRAPPER_TBL` + `ZCMST/ZCMCT_RFC_PARAM` ship today).

### 3.1 Objects (toolkit-namespaced; override per customer brief namespace)

| Object | Type | Purpose |
|---|---|---|
| `ZCMST_AUNIT_RESULT` | DDIC structure | one per-method result row: `TEST_CLASS, METHOD, STATUS(PASS/FAIL/ERROR/SKIP), SEVERITY, MSG, SRC_LINE` |
| `ZCMCT_AUNIT_RESULT` | DDIC table type | rows of `ZCMST_AUNIT_RESULT` |
| `ZCMST_AUNIT_COV` | DDIC structure | coverage row: `OBJECT, KIND(STMT/BRANCH/PROC), TOTAL, EXECUTED, PERCENT` |
| `ZCMCT_AUNIT_COV` | DDIC table type | rows of `ZCMST_AUNIT_COV` |
| `ZCMST_AUNIT_SUMMARY` | DDIC structure | `METHODS, PASSED, FAILED, ERRORS, SKIPPED, DURATION_MS, COV_MEASURED` |
| `Z_AUNIT_RUN` | Function module (remote-enabled) | runs AUnit + coverage on one object |

`.def` files for the DDIC objects use **real TAB bytes** (chr(9)), per the SE11
`.def` convention — never literal `\t`.

**Namespace (decided)**: these names follow the customer-brief namespace (default
`Z` / `ZCM*`), resolved the same way the other shipped helper objects
(`Z_GENERIC_RFC_WRAPPER_TBL`, `ZCMST_RFC_PARAM`) are — a customer on a registered
namespace gets the helper under that namespace. The `Z_AUNIT_RUN` / `ZCM*_AUNIT_*`
literals above are the default-namespace forms.

### 3.2 `Z_AUNIT_RUN` signature (all-flat → natively RFC-safe; no chunking)

```
IMPORTING  IV_OBJECT       TYPE SOBJ_NAME
           IV_OBJTYPE      TYPE CHAR4         "PROG / CLAS
           IV_WITH_COVERAGE TYPE ABAP_BOOL
           IV_RISK_LEVEL   TYPE CHAR1         "H / D / C — max risk executed
           IV_DURATION     TYPE CHAR1         "S / M / L
EXPORTING  ES_SUMMARY      TYPE ZCMST_AUNIT_SUMMARY
TABLES     ET_RESULTS      TYPE ZCMCT_AUNIT_RESULT
           ET_COVERAGE     TYPE ZCMCT_AUNIT_COV
EXCEPTIONS NO_TESTS  RISK_BLOCKED  OBJECT_INACTIVE  RUNNER_UNAVAILABLE
```

Internally wraps the ABAP Unit + Code Coverage runner (**`CL_AUCV_TEST_RUNNER`**,
the class behind ADT's "run with coverage"). The helper maps `IV_OBJECT` +
`IV_OBJTYPE` to the AUnit program key (the program name for `PROG`; the generated
class-pool name for `CLAS`). **Coverage is attributed to the production code the
tests exercise** — `ET_COVERAGE` carries one row per executed program/include, and
the `--min-coverage` gate (§6) applies to the **object under test**, never to the
test container itself.

> **SPIKE (first task of Phase 2)** — confirm the runner API on the S/4HANA 1909
> (kernel 754) test system before writing the FM, taking the first rung that works:
>   1. **`CL_AUCV_TEST_RUNNER`** (`RUN_FOR_PROGRAM_KEYS`-style entry) → results **+
>      coverage**. Preferred.
>   2. **Code Inspector "ABAP Unit" dynamic check** (`CL_CI_TEST_ABAP_UNIT` family)
>      via a programmatic inspection → results **only**, no coverage. Reuses the
>      `/sap-atc` CI mental model.
>   3. Plain ABAP Unit runner → results only.
>
> Whatever rung is used, set `ES_SUMMARY-COV_MEASURED = abap_false` when coverage
> is not produced, and record the chosen API + signature back into this doc.

### 3.3 Runtime driver `references/sap_aunit_run_rfc.ps1`

`Connect-SapRfc` (credential fallback resolves from `connections.json`) → probe
TFDIR for `Z_AUNIT_RUN` (emit `AUNIT_HELPER_MISSING` + fall back to GUI if
absent) → call FM → read `ET_RESULTS` / `ET_COVERAGE` / `ES_SUMMARY` → write JSON
→ emit status line. **32-bit** PowerShell (NCo 3.1), per `sap_rfc_lib.ps1`.

---

## 4. Backend B (fallback) — GUI

VBS templates `references/sap_se38_run_aunit.vbs` (program) and
`references/sap_se24_run_aunit.vbs` (class):

1. `Set oSession = AttachSapSession(SESSION_PATH)` (shared attach lib; the Tier-3
   parallel-safe contract).
2. Open the object in SE38/SE24 display.
3. Trigger ABAP Unit — **Ctrl+Shift+F10** via `sendVKey`, never a translated menu
   path.
4. On *ABAP Unit: Results Display*, read the result tree (GuiShell): per-method
   status by node, failures from the alert list. Counts come from the tree —
   **never** a localized status-bar string; `sbar.MessageType` is used only as a
   coarse S/E/W signal (language-independence rules).
5. Echo the parseable status line.

Notes: **results-only in v1** (GUI coverage deferred). No in-session file IO →
**no SAP-GUI-Security modal** to coordinate (simpler than the SE24 download flow).
Result-tree node IDs are per-release recording debt → capture once with
`/sap-gui-record`; keep release-variant VBS resolvable via
`sap_select_vbs_variant.ps1`. Optional `%%SESSION_LOCK_VBS%%` to block focus
stealing during the run.

---

## 5. Backend C (future) — ADT (depends on P12)

`POST /sap/bc/adt/abapunit/testruns` with a run-config body referencing the
object → results XML (test classes/methods + alerts with severity); coverage via
the ADT coverage run option. Cleanest, fully headless, no Z-footprint. Becomes
preferred wherever ADT services are active.

---

## 6. Skill I/O contract

**Args**:
`<OBJECT_NAME> [--type PROGRAM|CLASS] [--with-coverage] [--min-coverage <pct>]
[--risk-level harmless|dangerous|critical] [--duration short|medium|long]
[--mode RFC|GUI|ADT] [--save-to <path>]`.
Type auto-detected (probe TRDIR then SEOCLASS) when omitted.

> **Risk level (default `dangerous`, decided)** — AUnit levels are ordered
> HARMLESS (no persistent changes) < DANGEROUS (may change persistent
> data/customizing) < CRITICAL (may change system settings); the value is a **cap**
> (runs that level and below). Default `dangerous` matches the SAP IDE and is safe
> because the **client's `SAUNIT_CLIENT_SETUP` is the real control** — SAP itself
> blocks DANGEROUS/CRITICAL in clients not configured to allow them (surfaced as
> `AUNIT_RISK_BLOCKED`, never a silent write). `--risk-level harmless` restricts to
> side-effect-free tests. **No silent skips**: any test whose declared risk exceeds
> the cap is reported (`skipped_by_risk`), not dropped quietly.
>
> *gen-abap coordination*: generated `ltcl_main` tests should declare
> `RISK LEVEL HARMLESS` (pure logic on golden I/O); if a project's templates emit a
> higher level, raise `aunit_risk_level` so they are not capped out.

**Outputs**: `{WORK_TEMP}\aunit_<OBJECT>.json` (schema §6.2) + optional `.tsv`.

### 6.1 Parseable last lines (mirroring `gen-abap` `TEST_FILE:` / `atc` `GATE_VERDICT:`)

```
UNIT_TEST_RUN: EXECUTED methods=N passed=P failed=F errors=E skipped=S coverage=C%   (or coverage=NA)
UNIT_TEST_RUN: SKIPPED:NO_TESTS          ← object has no FOR TESTING classes
UNIT_TEST_RUN: SKIPPED:MODE_OFF          ← MODE_UNIT_TESTS=OFF and not explicitly invoked
UNIT_TEST_RUN: FAILED:<reason>
WARN: skipped_by_risk=<k> above cap '<level>'   ← when tests exceed --risk-level (non-fatal)
AUNIT_VERDICT: PASS|FAIL  tests=ok|fail  coverage=ok|below(C%<min%)|na
```

### 6.2 JSON schema (excerpt)

```json
{ "object":"ZMMRMAT042R01_TEST", "object_type":"PROGRAM", "backend":"RFC",
  "summary":{"methods":12,"passed":11,"failed":1,"errors":0,"skipped":0,"skipped_by_risk":0,"duration_ms":840},
  "coverage":{"measured":true,"object":"ZMMRMAT042R01","statement":86.4,"branch":72.0,"procedure":90.0},
  "alerts":[{"test_class":"LTCL_MAIN","method":"TEST_VALIDATE_QTY","kind":"failure",
             "severity":"critical","message":"Expected 5 but was 3","line":123}],
  "verdict":"FAIL","gate":{"min_coverage":80,"coverage_ok":true,"tests_ok":false} }
```

### 6.3 Verdict / exit truth table

| Tests | Coverage vs min | `aunit_coverage_gate` | `AUNIT_VERDICT` | Exit |
|---|---|---|---|---|
| pass | ≥ min, or ungated/NA | — | PASS | 0 |
| pass | < min | `warn` (default) | PASS + `WARN` | 0 |
| pass | < min | `block` | FAIL | 1 |
| fail | any | — | FAIL | 1 |

Exit codes: `0` = pass (and coverage ≥ min if gated); `1` = test failures or
coverage-gate-block fail; `2` = infra error (RFC/GUI/inactive).

### 6.4 Error classes (for `sap_log_helper.ps1 -ErrorClass`)

`AUNIT_TESTS_FAILED`, `AUNIT_COVERAGE_BELOW_MIN`, `AUNIT_NO_TESTS`,
`AUNIT_RISK_BLOCKED`, `AUNIT_OBJECT_INACTIVE`, `AUNIT_HELPER_MISSING`,
`AUNIT_GUI_PARSE_FAILED`, `AUNIT_RFC_FAILED`, `GUI_TIMEOUT`.

---

## 7. SKILL.md structure (canonical skeleton)

`Step 0` resolve work_dir via `Get-SapWorkDir` (never read settings.json
directly) → `Step 0.5` `sap_log_helper.ps1 -Action start -Skill sap-run-abap-unit
-StateFile {WORK_TEMP}\sap_run_abap_unit_run.json` → `Step 1` parse args +
auto-detect type + **mode dispatch** → `Step 2` verify object **active**
(RFC) → `Step 3` run (3-RFC / 3-GUI branch) → `Step 4` parse results + coverage →
JSON → `Step 5` apply gate + emit verdict → `Final` `sap_log_helper.ps1 -Action
end`.

VBS plumbing exactly as the other skills: read template **UTF-8** →
`.Replace('%%…%%')` → write **UTF-16 LE BOM**; declare
`Const SESSION_PATH = "%%SESSION_PATH%%"`, include `%%ATTACH_LIB_VBS%%`, call
`AttachSapSession(SESSION_PATH)`; wrapper sets
`$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath`; execute via
`C:/Windows/SysWOW64/cscript.exe //NoLogo`. `## Shared Resources` block lists
attach lib, session-lock (GUI), `sap_rfc_lib.ps1`, `sap_select_vbs_variant.ps1`,
log helper, and the rules docs (operating + language-independence).

---

## 8. Skill folder layout (when built)

```
plugins/sap-dev-core/skills/sap-run-abap-unit/
  SKILL.md                         # name: sap-run-abap-unit
  references/
    sap_aunit_run_rfc.ps1          # RFC driver (Connect-SapRfc → Z_AUNIT_RUN → JSON)
    sap_se38_run_aunit.vbs         # GUI: program target, Ctrl+Shift+F10, parse tree
    sap_se24_run_aunit.vbs         # GUI: class target
    Z_AUNIT_RUN.abap               # RFC helper FM (AUCV runner wrapper)
    ZCMST_AUNIT_RESULT.def  ZCMCT_AUNIT_RESULT.def
    ZCMST_AUNIT_COV.def     ZCMCT_AUNIT_COV.def
    ZCMST_AUNIT_SUMMARY.def
```

Registering the skill (when built) requires the usual entries the CI consistency
gate checks: `.claude-plugin/marketplace.json`, skill-count bookkeeping, and the
parallel-safe-attach contract for the two new VBS files.

---

## 9. Settings & customer-brief additions

**`plugins/sap-dev-core/settings.json`** (new keys, written via `userconfig.json`
per Rule 7):

| Key | Allowed | Default | Purpose |
|---|---|---|---|
| `aunit_default_mode` | `auto`/`RFC`/`GUI`/`ADT` | `auto` | backend preference; `auto` = RFC→GUI→ADT |
| `aunit_min_coverage` | int or blank | blank | min coverage %; blank = ungated |
| `aunit_coverage_gate` | `warn`/`block` | `warn` | below-min coverage warns vs fails |
| `aunit_risk_level` | `harmless`/`dangerous`/`critical` | `dangerous` | max risk level executed (incl. lower) |

**`shared/templates/customer_brief.md` → "6. Quality bar"**: add an optional line
*"Minimum ABAP Unit coverage %: `<n>` / no requirement"* → new `MODE_MIN_COVERAGE`.
The existing "ABAP Unit tests required?" line already carries the
mandatory/nice-to-have/no distinction (see §10). `--min-coverage` overrides the
brief.

---

## 10. Pipeline integration (`agents/abap-developer.md`) + the one policy change

**Required refinement**: today `MODE_UNIT_TESTS` collapses "yes (mandatory)" and
"nice to have" into a boolean. To gate auto-run, preserve the brief's tri-state:
**`MODE_UNIT_TESTS = MANDATORY | OPTIONAL | OFF`** (parsed from the existing
"6. Quality bar → ABAP Unit tests required?" line — no new brief field for this
part).

Insert **Step 2j.1** right after 2j (test class active):

```
2j.1  if MODE_UNIT_TESTS = MANDATORY:
         /sap-run-abap-unit Z<PROGRAM_ID>_TEST --with-coverage [--min-coverage <MODE_MIN_COVERAGE>]
         → failed tests STOP the pipeline (surface alerts)
         → coverage below min: WARN (unless aunit_coverage_gate=block)
      elif MODE_UNIT_TESTS = OPTIONAL:
         offer/prompt; report but do not gate
      else (OFF): skip
      → surface UNIT_TEST_RUN + AUNIT_VERDICT in the final summary, next to ATC.
```

Two notes for the implementer:
- The tri-state is read **only** by the agent's auto-run gate. `sap-gen-abap`'s
  emit logic stays boolean (emit the test file when `MODE_UNIT_TESTS ≠ OFF`) — no
  change there.
- Step 2j.1 should **cross-check** the executed `methods=N` against the
  `TEST_FILE: EMITTED … methods=N` count `sap-gen-abap` reported; a mismatch means
  tests were silently dropped (didn't compile / identifier issues) and is worth
  surfacing.

Relationship to ATC (Step 2i): complementary. ATC's own "ABAP Unit" check could
later consume this, but coverage + clean parsing live in this skill.

---

## 11. Lifecycle wiring (RFC helper)

Matching how the existing wrapper FM is handled across the three sibling skills:

- **`/sap-dev-init`** — new steps deploy the 5 DDIC objects (via `/sap-se11`) then
  `Z_AUNIT_RUN` (via `/sap-se37`, remote-enabled), after the existing wrapper-FM
  steps. Gated by the same user-consent / `skill_operating_rules` deploy rule.
- **`/sap-dev-status`** — report the helper FM + DDIC presence (TFDIR / DD02L /
  DD40L) alongside the existing artefacts.
- **`/sap-dev-clean`** — remove them in reverse-dependency order (FM → table types
  → structures), confirmed, before the wrapper FM.

The run skill has a soft dependency on `/sap-dev-init` having run (like
`/sap-rfc-wrapper-fm` → `Z_GENERIC_RFC_WRAPPER_TBL`); absence → `AUNIT_HELPER_MISSING`
→ auto-fall back to GUI.

---

## 12. Edge cases & failure modes

- **No `FOR TESTING` classes** → `SKIPPED:NO_TESTS`, exit 0 (not a failure).
- **Assertion failure vs. setup error** → distinguish `kind:"failure"` from
  `kind:"error"` (missing fixture/test data surfaces as error, not a real defect)
  so callers don't "fix" the wrong thing.
- **RISK CRITICAL/DANGEROUS blocked by client** → `AUNIT_RISK_BLOCKED` + guidance;
  don't false-fail.
- **Object inactive** → `AUNIT_OBJECT_INACTIVE` → `/sap-activate-object`.
- **Helper missing** (dev-init not run) → `AUNIT_HELPER_MISSING` → GUI fallback.
- **AUCV unavailable on release** → coverage `measured:false`, report tests only.
- **Long-running tests** → generous RFC timeout; GUI variant blocks (single object).
- **Non-EN logon (ZH/JA)** → must parse identically (regression-critical given the
  prior locale-classifier bug history).

---

## 13. Test plan (validate the skill itself)

Reuse a known-good generated object (e.g. the `ZMMRMAT0*` reports from prior live
runs on S4H). Scenarios:

1. All pass + coverage measured → `PASS`, coverage populated.
2. One deliberately failing assertion → `FAIL`, alert captured with line.
3. Object with no tests → `SKIPPED:NO_TESTS`.
4. `--min-coverage` above actual → `warn` → WARN+exit 0; `block` → FAIL+exit 1.
5. RFC helper absent → graceful GUI fallback, equivalent verdict.
6. **ZH or JA logon** → identical parse (language independence).
7. RFC vs GUI on the same object → same pass/fail verdict.

Write the run report to `sap-dev/temp/testReport/run_abap_unit_<YYYYMMDD>.md`
(NOT `contributing/`, per Rule 8).

---

## 14. Phasing

- **Phase 1 (~M)** — GUI backend, results-only; standalone skill + agent 2j.1
  with the mandatory gate. Zero Z-footprint; ships value immediately; reuses the
  `/sap-atc` run→parse patterns.
- **Phase 2 (~M)** — `CL_AUCV_TEST_RUNNER` spike → `Z_AUNIT_RUN` + 5 DDIC objects
  → `/sap-dev-init|status|clean` wiring → results **+ coverage**, warn-gated. RFC
  becomes default.
- **Phase 3 (after P12)** — ADT backend; preferred where available.

---

## 15. Decisions & remaining open items

**Resolved in this revision (design defaults; overridable):**
- **Helper namespace** → follows the customer-brief namespace, like the existing
  helper objects (§3.1).
- **`aunit_risk_level` default** → `dangerous` cap; safe because the client's
  `SAUNIT_CLIENT_SETUP` gates DANGEROUS/CRITICAL and over-cap tests are reported,
  not silently skipped (§6).
- **Coverage attribution** → gate targets the production object under test, not the
  test container (§3.2 / §6).
- **Mode precedence** → `--mode` > `aunit_default_mode` > `auto` (RFC-first) (§2).

**Genuinely open (need a live system or a cross-skill change):**
- **Runner-API spike** on 1909 — pick the working rung of the §3.2 ladder and
  record the exact signature here.
- **gen-abap risk level** — confirm generated `ltcl_main` declares
  `RISK LEVEL HARMLESS`; if not, align it or raise the default cap.
- **ADT availability** — whether `/sap/bc/adt/abapunit/testruns` is active on the
  target system (Phase 3 / depends on P12).
