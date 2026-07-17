# SAP ABAP Unit Runner Skill

Executes ABAP Unit tests on a deployed object (program or global class) via
SAP GUI Scripting and reports per-method pass / fail with a verdict gate.
Opens the object in SE38 / SE24, triggers the ABAP Unit run via the menu, and
parses the result display. Closes the generate → deploy → activate → **TEST**
loop for `/sap-gen-abap` output (`Z<PROGRAM_ID>_TEST`) and works standalone on
any brownfield object. Results-only by default; with `--with-coverage` it ALSO
measures code coverage ("Unit Tests With Coverage"), running the suite twice
since the coverage display has no status-bar summary. Read-only from the
system's perspective — it runs tests, it never changes the object.

## Skill Overview

1. Parse: object name + `--type=PROGRAM|CLASS` (default `PROGRAM`),
   `--with-coverage`, `--min-coverage=<n>` (implies `--with-coverage`),
   `--mode=GUI`, `--save-to=<PATH>`
2. Ensure an active SAP GUI session (`/sap-login`)
3. Run the type-matched VBS: SE38 `Program > Execute > Unit Tests` or SE24
   `Class Source > Run > Unit Tests` (the trigger is a menu, not a VKey);
   with coverage, a second "Unit Tests With Coverage" run reads the AUCV
   display's overall `PERCENTAGE`
4. Parse the result: `UNIT_TEST_RUN: EXECUTED methods=N passed=P failed=F …
   coverage=<pct|NA>` plus one `ALERT:` line per failure — tolerable warnings
   (e.g. a class's "no test relation") are NOT counted as failures
5. Emit the verdict gate `AUNIT_VERDICT: PASS|FAIL|COVERAGE_UNVERIFIED` and
   write the JSON result; register it as `unit_results` for
   `/sap-evidence-pack` (best-effort, never changes the verdict)

**Verdict rules:** test failures → FAIL. Coverage requested but unmeasured
(`coverage=NA`) → FAIL under `--min-coverage` (an unmeasured run can never
prove the threshold), or `COVERAGE_UNVERIFIED` under plain `--with-coverage` —
never a clean PASS with a missing requested measurement (the `COVERAGE_REASON:`
line says why). Measured coverage below the minimum → WARN by default, FAIL
only when `aunit_coverage_gate=block`.

## Auto-Trigger Keywords

- `run abap unit <name>`, `run unit tests on <name>`
- `abap unit ZHKR001_TEST`, `unit test the class ZCL_HK_UTIL`
- `run tests with coverage`, `check coverage of <name>`

## Usage

```text
/sap-run-abap-unit ZHKR001_TEST
/sap-run-abap-unit ZCL_HK_UTIL --type=CLASS
/sap-run-abap-unit ZHKR001_TEST --with-coverage
/sap-run-abap-unit ZHKR001_TEST --min-coverage=70
/sap-run-abap-unit ZHKR001_TEST --save-to=C:\out\aunit_result.json
```

Notes: `--risk-level` is **reserved, not implemented** (no token exists in the
VBS; the client's `SAUNIT_CLIENT_SETUP` governs the executed risk level — the
skill says so rather than silently ignoring it). `--mode` accepts `GUI` only
in Phase 1; `RFC` / `ADT` resolve to GUI with an INFO note.

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- Developer authorization to run ABAP Unit (S_DEVELOP on the object)
- `RZ11` parameter `sapgui/user_scripting` set to TRUE on the SAP server

## Re-recording on other releases

The trigger menus, result display (`SAPLSAUNIT_RSLT_DSPLY_GUI_DYNP` alert ALV),
and coverage display (`SAPLSAUCV_DISPLAY_MULTI_TAB` / `tabpFSCOV`) were
verified live on S/4HANA 1909. On a release where the alert-grid path shifts,
the VBS prints `UNIT_TEST_RUN: NEEDS_RECORDING program=<P> screen=<S>` instead
of a false green — record the new path via `/sap-gui-probe --record` and
prepend it to the `gcands` array in both `sap_se38_run_aunit.vbs` and
`sap_se24_run_aunit.vbs` (same one-time-per-release model as `/sap-atc`).

## Directory Structure

```text
sap-run-abap-unit/
├── SKILL.md                                # Skill definition (single source of truth)
└── references/
    ├── sap_se38_run_aunit.vbs              # Run + parse for a PROGRAM target (SE38)
    ├── sap_se38_run_aunit.screens.json     # Golden-screen baseline (SE38 flow)
    ├── sap_se24_run_aunit.vbs              # Run + parse for a global CLASS target (SE24)
    └── sap_se24_run_aunit.screens.json     # Golden-screen baseline (SE24 flow)
```

## Limitations

- **Coverage is a two-phase run** — `--with-coverage` executes the suite twice
  (counts, then coverage); harmless for side-effect-free tests. The RFC
  backend (`Z_AUNIT_RUN`, Phase 2) does both in one headless call.
- Result parse verified on S/4HANA 1909; other releases yield
  `NEEDS_RECORDING`, never a false PASS.
- Assertion failures and setup errors are both reported as `failure` in
  Phase 1 (the RFC backend distinguishes them).
- Single object per invocation (like `/sap-atc`).
- ABAP Unit runs against the **active** version — an inactive object yields
  stale results; activate via `/sap-activate-object` first if in doubt.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
