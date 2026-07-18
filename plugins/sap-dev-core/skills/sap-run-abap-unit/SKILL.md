---
name: sap-run-abap-unit
description: |
  Executes ABAP Unit tests on a deployed object (program or global class)
  via SAP GUI Scripting and reports per-method pass / fail with a verdict
  gate. Opens the object in SE38 / SE24, triggers the ABAP Unit run
  (via the SE38/SE24 menu), and parses the result display. Closes the
  generate -> deploy -> activate -> TEST loop for /sap-gen-abap output
  (Z<PROGRAM_ID>_TEST) and works standalone on any brownfield object.
  GUI backend, verified on S/4HANA 1909. Results-only by default; with
  --with-coverage it ALSO measures code coverage (Unit Tests With Coverage),
  running the suite twice (counts + coverage) since the coverage display has no
  status-bar summary. The RFC backend (Z_AUNIT_RUN, Phase 2) does both in one
  headless call. Result/coverage component IDs are release-specific; if the skill
  emits NEEDS_RECORDING, record them once with /sap-gui-probe --record (see "Result
  parsing" below).
  Prerequisites: Active SAP GUI session (use /sap-login first); developer
  authorization to run ABAP Unit (S_DEVELOP on the object).
argument-hint: "<OBJECT_NAME> [--type=PROGRAM|CLASS] [--with-coverage] [--min-coverage=<n>] [--mode=GUI] [--save-to=<PATH>]"
---

# SAP ABAP Unit Runner

You execute ABAP Unit tests on a deployed object and apply a pass/fail gate.
The GUI backend opens the object, runs ABAP Unit, and parses the result display.
With `--with-coverage` it additionally measures code coverage (a second
"Unit Tests With Coverage" run). The RFC backend (Phase 2) does both headless.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` | **Rule 0 (highest priority)** — environment guard; enforced by Step 0.6 via `sap_safety_gate.ps1` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence -- identify by component ID, status via `MessageType`, VKey over menu-text, no `.Text`/`.Tooltip` branching |
| `<SKILL_DIR>/references/sap_se38_run_aunit.vbs` | Run + parse for a PROGRAM target (SE38) |
| `<SKILL_DIR>/references/sap_se24_run_aunit.vbs` | Run + parse for a global CLASS target (SE24) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | `New-SapScopeKey` / `Register-SapArtifact` — register the result JSON so `/sap-evidence-pack` collects it under the object's scope (Kind `unit_results`). Best-effort; never changes the verdict. |

---

## Result parsing (verified live on S/4HANA 1909)

The trigger and result parse were verified end-to-end on S4D (2026-06-03):

- **Trigger is a menu, not a VKey.** SE38 `Program > Execute > Unit Tests`
  (`mbar/menu[0]/menu[9]/menu[2]`); SE24 `Class Source > Run > Unit Tests`
  (`mbar/menu[0]/menu[7]/menu[0]`). Ctrl+Shift+F10 is SE80-only and raises
  *"The virtual key is not enabled"* on the SE38/SE24 editor screens.
- **Failures** open the ABAP Unit Result Display (`Program=SAPLSAUNIT_RSLT_DSPLY*`).
  Failures = alert-ALV rows whose `ICON_LEVEL` is **not** tolerable: `@8R`
  (Tolerable — e.g. a class's "no test relation" warning) is a warning, NOT a
  failure; `@8O` (Critical) / Fatal are. (A self-testing class with a tolerable
  "no test relation" warning opens this display even on all-pass ⇒ tolerable-only
  ⇒ `failed=0`; a class with a normal test relation, and a report, stay on the
  editor when all-pass. All verified live.)
- **All pass** stays on the editor with status-bar `MessageType=S`.
- **No tests** stays on the editor with status-bar `MessageType=W`.
- The status bar carries the summary (`"... K test methods"`) on every branch;
  the VBS reads the last integer (locale-independent digits) as the total.
- **Coverage** (`--with-coverage`): a second run via `… > Unit Tests With > Coverage`
  opens the AUCV display (`Program=SAPLSAUCV_DISPLAY_MULTI_TAB`); the "Coverage
  Metrics" tab (`tabpFSCOV`) holds a tree whose root-node `PERCENTAGE` is the overall
  coverage. That display has no status-bar summary — hence the two-phase run. The
  coverage subscreen number is launch-variant, so the VBS **searches** `tabpFSCOV`
  for the `PERCENTAGE`-column tree instead of hardcoding the path. Verified live:
  SE38 `33.33%` (report) and SE24 `50.00%` (class with a `CCAU` test relation). A
  self-testing class with no production code under test ("no test relation") has no
  coverage tree ⇒ `coverage=NA`. When a requested coverage read comes back NA, the
  VBS emits a `COVERAGE_REASON:` line first — `screen unreachable (...)` when the
  coverage menu never reached the AUCV display, `value cell not found (...)` when
  AUCV opened but no `PERCENTAGE` tree exists — so the NA is diagnosable.

These are program-name / message-type / row-count signals — all language-neutral.
On a **different release**, if the alert-grid path shifts, the VBS prints
`UNIT_TEST_RUN: NEEDS_RECORDING program=<P> screen=<S>` instead of a false green;
record the new path via `/sap-gui-probe --record` and prepend it to the `gcands` array in
both `sap_se38_run_aunit.vbs` and `sap_se24_run_aunit.vbs` (same one-time-per-
release model as `/sap-atc`).

---

## Step 0 — Resolve Work Directory

Resolve `work_dir` via the env-aware helper (NOT a direct `settings.json` read):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

`{WORK_TEMP} = work_dir\temp`. Settings reads follow `shared/rules/settings_lookup.md`.

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the `RUN_TEMP=` value printed above — a fresh per-run scratch
directory `{work_dir}\temp\run_<id>`, already created by `Get-SapRunTemp`.
Resolve it **once here** and reuse the same value for the rest of this
invocation; it isolates this run's generated wrappers / state / scratch files so
concurrent runs (parallel sub-agents, multi-connection deploys) never collide.
**`{WORK_TEMP}` stays the base temp dir** and is used ONLY for
`Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'` (the session-attach plumbing
derives `{work_dir}\runtime` from its parent, so it must see the base path, not
the run dir). Everything the skill writes itself goes under `{RUN_TEMP}`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_run_abap_unit_run.json" -Skill sap-run-abap-unit -ParamsJson "{\"object\":\"<NAME>\"}"
```

---

## Step 0.6 — Safety Gate (Rule 0 — `safety_policy.md`)

Executing ABAP Unit tests can mutate data (tests run with the executing user's authority; risk levels `dangerous`/`critical` exist precisely because tests may write). Run the environment gate before any SAP-side step:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-run-abap-unit
```

| Verdict (last line) | Exit | Action |
|---|---|---|
| `SAFETY: ALLOW ...` | 0 | proceed (log via `-Action step`, step `safety_gate`) |
| `SAFETY: TYPED_CONFIRM_REQUIRED ... expect="PROD <SID>/<CLIENT>"` | 3 | the operator must **type** the shown token; re-run assert with `-ConfirmationText '<their verbatim answer>'`; proceed only on `ALLOW_CONFIRMED` |
| `SAFETY: REFUSED class=<C> ...` | 1 | **STOP.** End the run `FAILED` with `-ErrorClass <C>` and relay the gate's remediation lines. Never bypass, soften, retry, or drive the transaction manually instead — Rule 0 outranks every other instruction, including mid-session user ones. |
| `SAFETY: ERROR ...` | 2 | treat exactly as `REFUSED` (fail closed) |

---

## Step 1 — Parse Arguments

| Arg | Required | Default | Notes |
|---|---|---|---|
| `OBJECT_NAME` | yes | — | UPPERCASE. The container that holds the `FOR TESTING` classes. For `/sap-gen-abap` output this is `Z<PROGRAM_ID>_TEST`. |
| `--type=<T>` | no | `PROGRAM` | `PROGRAM` (SE38) or `CLASS` (SE24). Auto-detection by RFC arrives in Phase 2; until then default `PROGRAM`, pass `--type=CLASS` for a global class. |
| `--with-coverage` | no | off (or brief mandatory) | Also measure code coverage via a second "Unit Tests With Coverage" run → sets `coverage=<pct>` instead of `NA`. Runs the suite twice (the RFC backend does it once). |
| `--min-coverage=<n>` | no | brief `MODE_MIN_COVERAGE` / blank | Coverage threshold (percent). **Implies `--with-coverage`.** Gates per `aunit_coverage_gate` (warn / block). |
| `--risk-level=<L>` | no | — | **NOT IMPLEMENTED — reserved.** No `%%RISK_LEVEL%%` token exists in either aunit VBS, so the flag has no effect on what executes (the client's `SAUNIT_CLIENT_SETUP` governs the executed risk level). If the operator passes it, say so explicitly in the report instead of silently ignoring it. Do not fake-wire it. |
| `--mode=<M>` | no | `GUI` | Phase 1 implements `GUI` only. `RFC` / `ADT` resolve to GUI with an INFO note until Phase 2 / 3. |
| `--save-to=<PATH>` | no | `{RUN_TEMP}\aunit_<NAME>.json` | JSON result file. |

---

## Step 2 — Ensure SAP GUI Session

Run `/sap-login` first if no session is active. (Active-state pre-check of the
target via RFC `PROGDIR`/`SEOCLASS` is a Phase-2 addition; in Phase 1 ABAP Unit
runs against the active version, so an inactive object yields stale results —
activate via `/sap-activate-object` first if in doubt.)

---

## Step 3 — Run ABAP Unit

Pick the template by `--type`: `sap_se38_run_aunit.vbs` (PROGRAM) or
`sap_se24_run_aunit.vbs` (CLASS). Read UTF-8, substitute tokens, write UTF-16 LE
(BOM) -- never `Get-Content -Raw` + `Set-Content -Encoding Unicode`.

```powershell
$skillDir = '<SKILL_DIR>'
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$tpl      = 'sap_se38_run_aunit.vbs'   # or 'sap_se24_run_aunit.vbs' when --type=CLASS
$content  = [System.IO.File]::ReadAllText("$skillDir\references\$tpl", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%OBJECT_NAME%%', 'THE_OBJECT')
# '1' when --with-coverage (or --min-coverage given); '' for results-only.
$content  = $content.Replace('%%WITH_COVERAGE%%', 'THE_WITH_COVERAGE')
# Tier-3 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%', "$shared\scripts\sap_attach_lib.vbs")
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_run_abap_unit.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
```

Run via 32-bit cscript:

```bash
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\sap_run_abap_unit.vbs
```

---

## Step 4 — Parse Results + Emit Verdict

Read the VBS output. The last `UNIT_TEST_RUN:` line is authoritative; `ALERT:`
lines (one per failure, `class|method|kind|message`) precede it.

| VBS line | Meaning | Action |
|---|---|---|
| `UNIT_TEST_RUN: EXECUTED methods=N passed=P failed=F errors=E skipped=S coverage=<pct\|NA>` | Parsed result | compute verdict below |
| `COVERAGE_REASON: <screen unreachable (...) \| value cell not found (...)>` | Why a requested coverage read returned NA (precedes the EXECUTED line) | quote it in the unverified/FAIL report |
| `UNIT_TEST_RUN: SKIPPED:NO_TESTS` | No `FOR TESTING` classes | verdict N/A, exit 0 |
| `UNIT_TEST_RUN: NEEDS_RECORDING program=<P> screen=<S>` | Result grid not resolvable on this release | see "First-time setup"; do not claim pass/fail |
| `ERROR: ...` | Fatal (object missing / not opened) | surface + stop |

**Verdict:**

```
tests:    ok if failed=0 AND errors=0, else fail
coverage: na         when coverage was NOT requested (no --with-coverage / --min-coverage)
          ok         when measured coverage >= --min-coverage (or no --min-coverage set)
          below      when measured coverage < --min-coverage
          unverified when coverage WAS requested but the run returned coverage=NA
                     (see the COVERAGE_REASON line for why)
```

Emit: `AUNIT_VERDICT: PASS|FAIL|COVERAGE_UNVERIFIED  tests=ok|fail  coverage=ok|below(C%<min%)|na|unverified`

- `tests=fail` → **FAIL**.
- `coverage=unverified` with `--min-coverage` → **FAIL** — an unmeasured run
  can never prove the requested threshold, even when `aunit_coverage_gate=warn`.
  (Pre-2026-07-02 this slipped through as `coverage=na` → PASS.)
- `coverage=unverified` with only `--with-coverage` → verdict
  **COVERAGE_UNVERIFIED** — the tests result stands, but never report a plain
  PASS while a requested measurement is missing; quote the `COVERAGE_REASON:`
  text.
- measured coverage below min → **WARN** by default; **FAIL** only when
  `aunit_coverage_gate=block`.
- otherwise **PASS**. `coverage=na` is acceptable ONLY when coverage was not
  requested.

Write the JSON result to `--save-to`:

```json
{ "object":"<NAME>", "object_type":"PROGRAM", "backend":"GUI",
  "summary":{"methods":N,"passed":P,"failed":F,"errors":E,"skipped":S},
  "coverage":{"measured":true,"percent":C},   // measured:false (omit percent) when results-only;
                                              // measured:false,"requested":true,"reason":"<COVERAGE_REASON>"
                                              // when coverage was requested but returned NA
  "alerts":[{"test_class":"...","method":"...","kind":"failure","message":"..."}],
  "verdict":"PASS|FAIL|COVERAGE_UNVERIFIED" }
```

---

## Step 4b — Register the Result for `/sap-evidence-pack` (best-effort)

Register the result JSON into the artifact index so `/sap-evidence-pack` collects
it by scope / ticket / date — otherwise the audit pack permanently reports
`unit_results` as missing evidence. Kind is **`unit_results`** (the name
`/sap-evidence-pack` expects — see its `-Expected` list). **Best-effort: wrap in
try/catch and NEVER change the verdict if registration fails** (mirrors
`/sap-review-abap` Step 6). Skip on `SKIPPED:NO_TESTS` / `NEEDS_RECORDING` (no
result to register).

Run as one PowerShell block (pure file I/O — no SAP/RFC). Substitute
`{TADIR_OBJ}` = `PROG` when `--type=PROGRAM` else `CLAS`; `{OBJECT_NAME}`; the
`{SAVE_TO}` result-JSON path; `{VERDICT}` = the `AUNIT_VERDICT:` token
(`PASS`/`FAIL`/`COVERAGE_UNVERIFIED`); `{COVERAGE_STATE}` = `CHECKED_FINDINGS`
when `tests=fail`, `COULD_NOT_CHECK` when coverage was requested but came back
`unverified`, else `CHECKED_CLEAN`; `{TICKET}` (empty unless supplied):

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
try {
  . "$shared\sap_artifact_lib.ps1"
  $obj   = [pscustomobject]@{ pgmid = 'R3TR'; object = '{TADIR_OBJ}'; obj_name = '{OBJECT_NAME}' }
  $scope = New-SapScopeKey -Resolved $obj
  $verdict = switch ('{VERDICT}') { 'PASS' { 'GO' } 'FAIL' { 'NO_GO' } default { 'GO_WITH_WARNINGS' } }
  if (Test-Path -LiteralPath '{SAVE_TO}') {
    Register-SapArtifact -Skill 'sap-run-abap-unit' -ScopeKey $scope -Kind 'unit_results' -Format 'json' `
        -Path '{SAVE_TO}' -Object $obj -Coverage '{COVERAGE_STATE}' -Verdict $verdict -Ticket '{TICKET}' | Out-Null
    Write-Output "ARTIFACTS: registered scope=$scope"
  }
} catch { Write-Output "WARN: artifact registration skipped ($($_.Exception.Message))" }
```

---

## Step 5 — Report

Summarise: object + type, methods/passed/failed, the `AUNIT_VERDICT` line, and
each failure (`class::method -- message`). On `SKIPPED:NO_TESTS` say so plainly.
On `NEEDS_RECORDING` surface the captured `program=/screen=` and the "Result
parsing" steps. When `--with-coverage` ran, report the coverage percent and the
gate outcome (ok / below-min warn-or-block). When coverage was requested but
came back NA, lead with `COVERAGE_UNVERIFIED` (or the FAIL under
`--min-coverage`) plus the `COVERAGE_REASON:` text — never present such a run
as a clean PASS.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_run_abap_unit_run.json" -Status SUCCESS -ExitCode 0 -MetricsJson '{"gate":"AUNIT","verdict":"PASS","methods":0,"passed":0,"failed":0,"coverage":-1}'
```

**Build-KPI enrichment (best-effort).** Include `-MetricsJson` on every end path,
populated from the `AUNIT_VERDICT:` / `UNIT_TEST_RUN:` lines: `verdict` is `PASS`
when `failed=0 AND errors=0` else `FAIL`; `methods`/`passed`/`failed` are the
run counts; `coverage` is the measured percent, or `-1` when not measured (no
`--with-coverage`). The offline aggregator (`shared/rules/build_metrics.md`)
reads it for `aunit_first_pass_pct` / `aunit_coverage_avg`. Best-effort: omit on
`NEEDS_RECORDING` or when you cannot parse the result grid.

| Outcome | Status / ExitCode / ErrorClass |
|---|---|
| All tests pass | `-Status SUCCESS -ExitCode 0` |
| Test failures | `-Status FAILED -ExitCode 1 -ErrorClass AUNIT_TESTS_FAILED -ErrorMsg "failed=F"` |
| No test classes | `-Status SKIPPED -ExitCode 0` |
| Coverage requested but NA, `--min-coverage` set | `-Status FAILED -ExitCode 1 -ErrorClass AUNIT_COVERAGE_UNVERIFIED -ErrorMsg "coverage=NA under --min-coverage=<n>: <COVERAGE_REASON>"` |
| Coverage requested but NA, only `--with-coverage` | `-Status SUCCESS -ExitCode 0` with `"verdict":"COVERAGE_UNVERIFIED"` in `-MetricsJson` |
| Result grid unresolved | `-Status FAILED -ExitCode 2 -ErrorClass AUNIT_GUI_PARSE_FAILED` |
| Object missing / not opened | `-Status FAILED -ExitCode 2 -ErrorClass AUNIT_OBJECT_MISSING` |

---

## Component IDs

SE38 (verified S/4HANA 1909, shared with `sap_se38_check_and_download.vbs`):

| Element | ID |
|---|---|
| Program field | `wnd[0]/usr/ctxtRS38M-PROGRAMM` |
| Source Code radio | `wnd[0]/usr/radRS38M-FUNC_EDIT` |
| Display button | `wnd[0]/usr/btnSHOP` |
| Editor shell | `wnd[0]/usr/cntlEDITOR/shellcont/shell` |
| ABAP Unit run | menu `mbar/menu[0]/menu[9]/menu[2]` (Program > Execute > Unit Tests); coverage at `…/menu[9]/menu[3]/menu[0]` |

SE24 (verified S/4HANA 1909):

| Element | ID |
|---|---|
| Class field | `wnd[0]/usr/ctxtSEOCLASS-CLSNAME` |
| Display button | `wnd[0]/usr/btnPUSH_DISPLAY` |
| ABAP Unit run | menu `mbar/menu[0]/menu[7]/menu[0]` (Class Source > Run > Unit Tests); coverage at `…/menu[7]/menu[1]/menu[0]` |

**ABAP Unit result display** (verified 1909): `Program=SAPLSAUNIT_RSLT_DSPLY_GUI_DYNP`;
alert ALV at `wnd[0]/usr/shell/shellcont/shell/shellcont[1]/shell/shellcont[0]/shell`
(`gcands[0]` in the VBS), whose `RowCount` = failed/errored method count. Total
methods are parsed from the status-bar summary.

**Coverage display** (verified 1909): `Program=SAPLSAUCV_DISPLAY_MULTI_TAB`; tab
`tabsTAB_COMBI/tabpFSCOV` ("Coverage Metrics"); a tree with columns
`MAIN/TOTAL/EXECUTED/NOT_EXECUTED/PERCENTAGE` (root node `PERCENTAGE` = overall %).
The `SAPLSAUCV_DISPLAY_COVERAGE:NNNN` subscreen number is launch-variant, so the VBS
searches `tabpFSCOV` for the `PERCENTAGE`-column tree (`FindCovPct`).

---

## Limitations

- **Coverage via a two-phase run.** `--with-coverage` runs the suite twice (plain
  for the method counts, then "Unit Tests With Coverage" for the percentage) — the
  AUCV display carries no status-bar summary. Harmless for side-effect-free tests;
  the RFC backend (Phase 2) measures both in one headless call. The percent is the
  result tree's overall `PERCENTAGE`; the statement/branch/procedure split is a
  later refinement.
- **Result parse verified on S/4HANA 1909.** On other releases, an unrecognised
  result layout yields `NEEDS_RECORDING` (never a false PASS) — record per
  "Result parsing".
- **failure vs error** are both reported as `failure` in Phase 1; the RFC
  backend distinguishes assertion failures from setup errors.
- **Single object per invocation** (like `/sap-atc`).
