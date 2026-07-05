# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.7.1] — 2026-07-05

### Added

- **Headless compiler-level ABAP syntax check** — new shared engine
  `sap-dev-core/shared/scripts/sap_rfc_syntax_check.ps1` runs `EDITOR_SYNTAX_CHECK`
  through the dev-init wrapper `Z_GENERIC_RFC_WRAPPER_TBL` (asXML, read-only). Passes
  `I_TRDIR` (UCCHECK/FIXPT/SUBC) so a **non-existent** program checks in Unicode mode
  (no existing-program dependency), and `ALL_ERRORS='X'` returns **every** error +
  warning with line/column — the offline equivalent of Ctrl+F2. Live-validated on
  S/4HANA (exact line/col, multi-error, clean-pass). Token `%%RFC_SYNTAX_CHECK_PS1%%`.
- **`/sap-se38` pre-insert syntax gate** (Step 4.6) — runs the engine on the source
  before the GUI deploy for self-contained programs (type `1`); degrades silently to
  the existing Ctrl+F2 when RFC/the wrapper is unavailable.

### Changed

- **Retired `sap-gui-record`; folded into `/sap-gui-probe --record` (68 → 67 skills).**
  The manual-recording capability (guide the operator through SAP GUI Script
  Recording, then parse the saved VBS into a findById/action map) is now a
  fallback capture mode of `/sap-gui-probe` — **Mode R** — alongside its default
  AI-drive capture. AI cannot start a GUI recording, so the standalone skill only
  added a menu entry, not an AI-invocable capability. The SAP GUI Scripting API
  cheat-sheet (component-ID grammar, type prefixes, VKey codes, toolbar positions,
  runtime gotchas) was promoted to the shared reference
  `sap-dev-core/shared/rules/sap_gui_scripting_reference.md` so every VBS author
  reads it in one place. Repointed all `/sap-gui-record` references across skills,
  the cc-migration agent, docs (EN/JA/ZH), READMEs, and reference-VBS comments to
  `/sap-gui-probe --record` (paired "record or probe" mentions collapsed to
  `/sap-gui-probe`); removed the skill dir + marketplace / catalogue entries.
- **`sap-cc-learn` → `/sap-cc-triage --learn` (69 → 68 skills).** The
  knowledge-pack flywheel (learns real ATC message ids from a triaged campaign and
  feeds them back into the pack's `detect_message_ids`) is now an opt-in mode of the
  skill that owns the triaged findings it reads. Default `/sap-cc-triage` still
  classifies; `--learn <propose|apply>` runs the flywheel. The `sap_cc_learn.ps1`
  engine moved into `sap-cc-triage/references/`; the `CC_LEARN_*` error classes are
  retained (now emitted by the `--learn` mode). Rewired the `/sap-cc-campaign`
  dashboard (SKILL.md + `sap_cc_campaign.ps1` output strings), CLAUDE.md
  knowledge-pack row, marketplace (`total_skills` 68), and the manual (EN/JA/ZH) +
  README + installation catalogue (also restoring `sap-cc-decommission`, which the
  README/manual migration lists had omitted). Not a campaign-pipeline step — the
  `next` state machine never sequenced it — so no ledger/gate change.
- **Slimmed 29 over-length skill descriptions to fix skill-list truncation.**
  Frontmatter `description` blocks over ~1024 chars were being cut mid-sentence in
  the skill list the model sees at session start — hiding secondary modes (e.g.
  the se01/se24/se38 delete + remove-objects modes) from auto-invocation. Rewrote
  each to a trigger-focused form that keeps *what it does* + *when to invoke* +
  prerequisites while moving mechanics (FM/table names, VKey codes, popup handling,
  release caveats) into the body where they already live. Result: 0 descriptions
  over 1024 (was 29 of 69); total description payload ~70,000 → ~55,000 chars
  (~3,800 fewer tokens injected per session). No body/behaviour changes.
- **Discoverability consolidation (Wave 2): merged 6 skills into 3 (one a rename),
  dropping the catalogue 72 → 69.** No behaviour change to the surviving skills
  beyond the new mode/flag dispatch.
  - **`sap-gui-object-details` + `sap-gui-diagnose` → `/sap-gui-inspect`** (rename +
    merge). The structural component/property dump and the visual HardCopy-screenshot
    triage are now one inspection skill with two mode families: structural
    (`tree`/`menu`/`type`/`id`/`wnd`) and visual (`screenshot [topmost|composite|full]`).
    The diagnose capture/compose scripts moved into `sap-gui-inspect/references/`; helper
    VBS filenames kept unchanged so the CI attach-exempt list + moved screen baseline
    resolve by basename. Rewired the ~15 GUI-driving skills that carried a
    "FIRST/SECOND RESORT" troubleshooting block, plus the gui-probe/scaffold engine
    references (incl. the load-bearing `sap_gui_probe_dump.ps1` path).
  - **`sap-rfc-wrapper-fm` + `sap-rfc-wrapper-class` → `/sap-rfc-wrapper`** —
    mode-dispatched (`fm` calls a non-RFC FM via the generic wrapper;
    `class` generates + deploys a dedicated wrapper FM for a class method). The fm
    skill's references (incl. `Z_GENERIC_RFC_WRAPPER_TBL.abap` + the `.def` DDIC types
    that `/sap-dev-init` deploys) stayed under the renamed dir; dev-init's 10
    load-bearing reference paths were retargeted.
  - **`sap-gui-screen-check` → `/sap-doctor --screens`** — the live half of the
    golden-screen harness became an **opt-in** doctor group (orchestrator + probe moved
    into `sap-doctor/references/`). It is NOT part of doctor's default read-only,
    safe-to-chain run — it navigates the live GUI (guards against unsaved-data loss) and,
    with `--update-baseline`, writes baseline files. Updated the CI coverage-gate message,
    `error_classes.md` (SCREEN_DRIFT emitter), `contributing/golden_screen_baselines.md`,
    and the seeded baseline metadata.
  - Rewired all consumers + the marketplace (`total_skills` 72 → 69), CLAUDE.md (incl. the
    naming-convention examples that cited the retired `sap-rfc-wrapper-*` family), the
    manual (EN/JA/ZH) + README + installation catalogue.
- **Discoverability consolidation (Wave 1): merged 8 skills into 3, dropping the
  catalogue 78 → 72.** Three merges, each following an established consolidation
  pattern; no behaviour change to the surviving skills beyond the new flags.
  - **Diagnose readers folded into `/sap-diagnose`.** The four RFC evidence readers
    `sap-sm37` / `sap-sm13` / `sap-sm12` / `sap-slg1` (thin wrappers over
    `sap_diagnose_reader_lib.ps1`) are now internal reader scripts under
    `sap-diagnose/references/`, materialized and run directly in its Step 4. A new
    `/sap-diagnose --reader sm13|sm12|slg1|sm37|st22` runs a single reader standalone
    (one-for-one replacement of the removed skills). The GUI dump reader `/sap-st22`
    stays a separate skill (it drives ST22 via GUI scripting). `sap_diagnose_reader_lib.ps1`
    relocated from `shared/scripts/` into `sap-diagnose/references/` (single consumer
    now — per the CLAUDE.md placement rule). −4 skills.
  - **`sap-docs-check-ddic` + `sap-docs-check-process` → `/sap-docs-check`** — a
    dimension-dispatched skill (`--dimension ddic|process|all`; default runs both by
    input-file presence), mirroring the earlier `check-fm → check-abap` merge. Both
    the `check_result_ddic.txt` and `check_result_process.txt` outputs are preserved.
    −1 skill.
  - **`sap-document-object` → `/sap-explain-object --spec`** — the spec-document
    generator becomes a mode of the comprehension skill it already built on
    (`--spec [--format md|docx|xlsx] [--audience functional|technical]`, Step 7.5:
    RFC enrichment → synthesize spec → render). −1 skill.
  - Rewired all consumers: the `abap-developer` agent, the marketplace manifest
    (skills arrays + `total_skills` 78 → 72 + core/gen-code descriptions), CLAUDE.md
    shared-resource tables, `build_metrics.md` + `sap_build_kpi.ps1` gate map,
    `error_classes.md`, `ddic_excel_layout_rules.md`, and the manual (EN/JA/ZH) +
    README + installation catalogue.
- **Merged the ABAP check/fix skills into sap-dev-core.** `sap-check-abap` +
  `sap-check-fm` + the new syntax check are now **one dimension-dispatched
  `/sap-check-abap`** (dimensions: naming/type/sql/unused/contract/spec/conv/**fm**/**syntax**);
  `sap-fix-abap` + `sap-fix-fm` + a bounded AI syntax-fix loop are now **one
  `/sap-fix-abap`**. Both moved from **sap-gen-code → sap-dev-core** (so the
  se38/se37/se24 deploy skills can gate on them without violating the one-way plugin
  dependency). The standalone `sap-check-fm` and `sap-fix-fm` skills were **removed**
  (absorbed as the `fm` dimension / Step 6b); `/sap-check-abap` and `/sap-fix-abap`
  keep their names. Skill count 80 → 78. `sap-se37`/`sap-se24` note that FM
  fragments / class pools are syntax-checked **in-context** by their existing Ctrl+F2.

### Fixed

- **`/sap-check-abap` false `TYPE_NOT_FOUND` on DDIC table types (DD40L) —
  class 4 of the known false-positive set.** `DATA lt_files TYPE filetable.`
  (FILETABLE = the standard table type for `CL_GUI_FRONTEND_SERVICES=>gui_upload`,
  1 row in DD40L on the ERP system) was flagged as an unknown type. The DDIC
  sidecar helper `sap_rfc_lookup_ddic.ps1` already resolved DD40L correctly
  (returning kind `TTYP`); the defect was in the VBS **consumer**
  `sap_check_abap.vbs`, whose result-parse loop mapped only `STRUCT`/`DTEL` and
  folded every other resolved kind (`TTYP` table type, `DOMAIN`, `CLASS`) into the
  `Else` → `TK_UNKNOWN` branch, driving a false `TYPE_NOT_FOUND` in Phase 5b. Added
  `TK_TTYP`/`TK_DOMAIN`/`TK_CLASS` constants + a parse-loop branch that stores those
  resolved kinds as KNOWN, and reclassified a `TTYP`-typed variable to `DK_TABLE`
  — which also removes a *secondary* false `NAMING` warning (`lt_files` was
  classified `DK_VARIABLE` → wrongly expected `lv_`). Documented in the skill's
  "ABAP Parsing Limitations" + the README RFC-lookup table. Verified end-to-end
  against the real edited VBS with a stubbed DDIC helper (A/B vs. reverted code:
  `FILETABLE` / `ZDOMAIN_X` / `CL_GUI_FRONTEND_SERVICES` all flip from false
  `TYPE_NOT_FOUND` to `TYPE_RESOLVED`, while a genuinely non-existent type stays
  flagged — no over-suppression). Found on the MaterialUpload A3 build
  (EC2, `ZMMRMAT0A3R01`, 2026-07-03).

- **DDIC lookup sidecar `sap_rfc_lookup_ddic.ps1` wrote its result TSV with a
  UTF-8 BOM — corrupting the FIRST batched type/table name for every consumer.**
  A separate latent bug found while fixing the DD40L/TTYP false-positive above.
  The helper wrote the result with `[System.IO.File]::WriteAllText(…,
  [System.Text.Encoding]::UTF8)` (and the two empty-result paths with
  `Set-Content -Encoding UTF8`), both of which emit a UTF-8 BOM (`EF BB BF`) under
  the 32-bit Windows PowerShell 5.1 the helper runs on. Both VBS consumers read the
  file in ASCII/ANSI mode (`OpenTextFile(…, 1, False, 0)`) **without** stripping a
  BOM — `sap_check_abap.vbs` (line 1639) and `sap_check_fm.vbs`'s **DDIC** reader
  (line 648; note its *FM* reader at line 542 already strips one). The 3 BOM bytes
  decode as garbage glued to the first line's first token — on the cp932 (ja-JP)
  test host, `FILETABLE` became `・ｿFILETABLE` (`U+30FB U+FF7F …`) — so it never
  matches `g_typeKind`, and Phase 5b's `If g_typeKind.Exists(tvBase)` (no `Else`)
  silently skips it: a genuine typo in the **first-declared** type/table slips
  through (false negative). Online-mode only (offline skips Phase 4); deterministic
  (batch order = source-declaration order). Fixed at the producer — the result TSV
  (payload **and** both empty-result paths) is now written as BOM-less UTF-8 via
  `New-Object System.Text.UTF8Encoding($false)`. Producer fix is codepage-agnostic:
  a consumer-side `Left(line,3)=Chr(&HEF)&Chr(&HBB)&Chr(&HBF)` strip would **not**
  match on cp932 (the bytes decode to `U+30FB U+FF7F`, not `EF BB BF`), so the BOM
  is removed at the source rather than patched per-reader. Verified offline on the
  real runtime (32-bit WinPS 5.1, cp932, 32-bit cscript): with a BOM the first
  token reads `・ｿFILETABLE` (no match); BOM-less it reads `FILETABLE` (match).
  `sap-check-fm` benefits from the same source fix. (task_dcc17d69,
  `temp/testReport/ddic_lookup_bom_fix_20260703.md`.)

## [0.7.0] — 2026-07-03

Customer-pain release built on the 2026-07-03 reviews
(`temp/testReport/plugin_skill_review_20260703.md` + `…_pm.md`). Headlines: the
S/4HANA migration campaign gains **execution + assurance** — `/sap-cc-decommission`
(retire unused code behind a signed, audited ledger), a WORKLOAD usage fallback,
landscape-drift detection, a unit-test exit gate, scripted `revert`, and batched ATC;
**enterprise-adoption hardening** — a machine authorization probe, `docs/security.md`,
code-enforced migration governance gates, and a closed credential crash-window;
golden-screen drift coverage 8→120; and the first **clean-core codegen lane**,
`/sap-gen-cds` (ADT-free CDS view generation, live-verified on S/4HANA 7.54 + 7.57).
Also parallel-run safety (two-bucket temp complete) and shared RFC-read hardening.

### Added

- **`/sap-gen-cds` — ADT-free CDS view generation + deploy (pain-plan D13,
  clean-core codegen lane).** New sap-gen-code skill (total_skills 79→80) that
  generates classic CDS DDL (`DEFINE VIEW … @AbapCatalog.sqlViewName`, SAP_BASIS
  7.50-7.54) or view entities (`DEFINE VIEW ENTITY`, 7.55+) from a spec/description
  and deploys it to a live system **without ADT**, via the RFC-enabled installer FM
  `Z_CDS_DDL_INSTALL` (hosts `CL_DD_DDL_HANDLER_FACTORY`: create → save →
  write_tadir(prid=-1) → activate). Release-gated ≥7.50 (a file-based CVERS probe
  — `references/sap_cds_release_probe.ps1` — so no shell-var-eaten inline command;
  honest `NOT_SUPPORTED` on ECC6/7.31), naming-checked (`CDS_VIEW`/`CDS_SQL_VIEW`
  rows in `sap_object_naming_rules.tsv`), and RFC-verified: classic views by the
  generated SQL view `AS4LOCAL=A` (DD02L/DD25L, checked per-row), **view entities by
  a DWINACTIV activation probe** (no SQL view exists — never reports ACTIVE on TADIR
  presence alone). WHERE clauses are split one-per-OPTIONS-row so DDL names ≥21 chars
  don't overflow RFC_READ_TABLE. `--activate|--no-activate` wired through
  (`EV_STATE=CREATED` stages inactive). Guarded delete flow: handler delete →
  **confirmed `EV_STATE=DELETED`** → only then the `sap_tadir_delete` orphan clear
  (`-Force` justified by the API's positive delete confirmation, never on an
  unconfirmed delete). `DDDDLSRC` added to the shared `sap_rfc_lib` forbidden-read
  guard (STRING column → SAPLSDTX cast dump, same class as REPOSRC). **Live e2e on
  S4D 1909** (D13 spike + Phase 1: `ZCM_GENCDS_TEST_V` → `VERIFY: ACTIVE` → delete →
  `VERIFY: MISSING`; decision doc `temp/testReport/cds_rap_spike_D13_20260703.md`).
  ATC-on-DDLS deferred (`/sap-atc` has no CDS SCI category yet → honest
  `ATC: SKIPPED`). Error classes `CDS_RELEASE_UNSUPPORTED` / `CDS_INSTALLER_MISSING`
  / `CDS_ACTIVATE_FAILED` registered in `error_classes.md`. Phase 2 (RAP behaviour
  definitions / OData) stays demand-gated.
- **`/sap-cc-decommission` — execute the retirement of unused custom code
  (pain-plan A2, headline).** New sap-migrate skill (total_skills 78→79) that turns
  `/sap-cc-usage`'s DECOMMISSION *flags* into physical, audited deletions behind a
  HARD `decommission_signoff` gate (BLOCKED exit 3 until APPROVED — deletions
  transport to QA/PROD). Per object the SKILL runs a safety chain — where-used +
  resolver re-verify → source backup (`Read-SapAbapSource` + `Register-SapArtifact
  kind=source_backup`) → Workbench TR → delegated delete
  (`/sap-se38|24|11|function-group`) → resolver `NOT_FOUND` confirmation — then the
  offline engine (`references/sap_cc_decommission.ps1`, actions `plan`/`record`)
  appends an audit ledger `decommission\decommissioned.tsv` (object · backup
  artifact · TR · verified-gone date · sign-off owner). `plan` orders
  consumers-before-providers (DDIC last) and is idempotent (ledgered objects
  excluded); `/sap-cc-campaign report` gains `retired_without_remediation_pct`
  (kept separate from the *flagged* savings, n/a until the ledger exists) and
  `next` recommends decommission while any flagged object is unretired. Offline
  end-to-end tested (gate block, ordered worklist, promotion, ledger, idempotency,
  KPI, next). **Live-verified end-to-end on S4H (2026-07-03, RFC+GUI co-located):**
  3 throwaway `$TMP` programs deployed → gate BLOCKED unsigned (exit 3) → sign-off
  → `plan` (3× PROG→se38) → per-object chain (system-assertion OK → resolver
  RESOLVED → source backup + artifact → se38 delete → resolver **NOT_FOUND** with
  TRDIR=0/TADIR=0) → `record` (ledger + state DECOMMISSIONED) →
  `retired_without_remediation_pct=100`. Error classes `CC_DECOMMISSION_*` added.
- **Batched ATC for large estates (pain-plan A5).** `/sap-atc --object-list=<file>`
  builds ONE SCI object set from a file of `<TYPE> <NAME>` lines (grouped by
  category, mixed types allowed) → ONE run series → ONE result, keyed per object
  by the Stage-4b drill `OBJ_NAME` — collapsing one-run-per-object into
  one-run-per-batch. `sap_sci_create_object_set.vbs` gains a multi-object mode
  that drives the select-options **Multiple Selection** dialog (`SAPLALDB`
  `tblSAPLALDBSINGLE`, page-8 fill with bottom-row scroll — the live-proven
  sap-se16n pattern; `VisibleRowCount`/`pageSize` over-count and `findById`
  resolves phantom rows, so neither is trusted); the single-object path is
  byte-identical to before. `/sap-cc-analyze --batch-size <n>` (`prepare
  -BatchSize`) chunks the worklist into `findings\atc_raw\batches\
  analyze_batch_<nnn>.tsv` object-list files and loops them through the batched
  `/sap-atc`; a `--variant <NAME>` override lets the analyze loop run a
  non-readiness variant. **Live-verified on S4H (2026-07-03, DEFAULT variant):** a
  10-program batch (`ZGATE_A5B10`) produced **exactly** the same per-object
  verdicts as 10 single ATC runs — aggregate P1=2 P2=8 P3=203 on both sides, and
  the sole P1 carrier matched slice-for-slice.
- **`/sap-cc-usage --usage-source WORKLOAD` — ST03N usage fallback (pain-plan A3).**
  For systems where SCMON/UPL was never activated, `references/sap_cc_workload_read.ps1`
  reads the SWNC workload monitor (`SWNC_GET_WORKLOAD_STATISTIC` → TCDET, summed
  over `--workload-months`, Z/Y tcodes resolved to programs via `TSTC`) as a
  **positive-only, LOW-confidence** proxy. Safety is engine-enforced: an object
  absent from a WORKLOAD read is UNKNOWN → REMEDIATE if it is a class/FM/table
  (workload never lists those), or REVIEW at most if a PROG — it can **never** drive
  an `aggressive` DECOMMISSION, and the join guards are inert for it. Verified live
  (S/4HANA): the NO_DATA-safe path (empty collector → REMEDIATE); positive-mapping
  semantics offline-unit-tested (unseen PROG → REVIEW, invisible CLAS/TABL →
  REMEDIATE, zero DECOMMISSION under aggressive). **Live-confirmed on S4H
  (2026-07-03):** TSTC Z/Y→program mapping (20 mappings) + TCDET `ENTRY_ID`/`COUNT`
  field-name resolution against live line-type metadata + end-to-end NO_DATA-safe
  plumbing. **Fixed a metadata-introspection bug found by that verification:** the
  reader enumerated `$tc.Metadata` (which yields the single table-type name
  `SWNCGL_T_AGGTCDET`) instead of `$tc.Metadata.LineType` (the 31 row fields incl.
  ENTRY_ID/COUNT), so the columns never resolved and the positive path returned
  NO_DATA *even on a populated system* — now enumerates LineType (with a fallback).
  Real-row aggregation still awaits a workload-populated collector (Basis
  prerequisite; none of the accessible S4H/S4D/S4G/EC2 boxes has one).
- **`/sap-cc-campaign` landscape-drift detection (pain-plan A4).** New optional
  `report` pre-step `references/sap_cc_drift_read.ps1` reads the source system's
  `E070`/`E071` for transports touching in-scope objects since the campaign start
  (`--MaxTrs`-bounded with a `WINDOW_WARN`) plus `SMODILOG` (SPDD/SPAU exposure),
  writing `drift\drift.tsv`. The dashboard gains a **Landscape drift** section
  flagging objects already REMEDIATED/VERIFIED that changed under the campaign as
  RE-ANALYZE candidates, and an `INFO: drift touched=<n> reanalyze=<r>` line. New
  recipe `knowledge/recipes/DUAL_MAINTENANCE.md` documents the freeze/retrofit
  discipline. **Fully verified live on S4H (2026-07-03) with authentic drift** —
  real developer TRs touching tracked Z programs: `touched=4 reanalyze=3
  open_trs=2 released_trs=2 modlog=22570`, RE-ANALYZE correctly `Y` for touched
  REMEDIATED/ANALYZED objects and `N` for SCOPED, and the dashboard **Landscape
  drift** table renders with the flags + recipe pointer. Also **fixed** `report`
  to create the `reports\` dir defensively before writing `dashboard.md` (it was
  created only by `init`, so `report` on a hand-assembled/cleaned workspace
  path-not-found-failed).
- **`/sap-doctor` authorization probe (pain-plan E15a).** New `auth` group:
  `references/sap_doctor_authz_probe.ps1` reads
  `shared/tables/required_authorizations.tsv` (machine-readable mirror of
  `docs/security.md §1`) and, for the logged-in RFC user, calls
  `SUSR_USER_AUTH_FOR_OBJ_GET` — **found to be RFC-enabled, so no dev-init
  wrapper is needed** (the original plan assumed otherwise) — once per
  authorization object, evaluating each capability with faithful
  AUTHORITY-CHECK semantics (a single authorization instance must cover every
  required field; `*` and `VON..BIS` ranges honoured). Emits
  `AUTH: PASS|FAIL <capability>` + `AUTH_SUMMARY`; a `FAIL` DEGRADES the verdict
  (never BLOCKS — a role-provisioning gap, not a broken runtime); FM/read
  unavailable → honest `AUTH: NOT_PROBED`, never a fabricated verdict. Replaces
  the old "AUTH: not probed" placeholder; `docs/security.md §1` updated to point
  at the probe + TSV. **Live-verified (S4H/easy):** a DEVELOPER passed 10/10
  capabilities; an ungranted `ACTVT=99` correctly FAILed; missing rules →
  NOT_PROBED (7/7 negative cases).
- **Unit-test exit gate for migration remediation (pain-plan C9).**
  `/sap-cc-remediate record` now consults `Get-SapGatePolicy`: when the
  migration brief's ABAP-Unit bar is `mandatory (block)`, a `VERIFIED` outcome
  is honoured only with a passing `/sap-run-abap-unit` result (new optional
  results-file columns `aunit_status`/`aunit_methods`/`aunit_failures`; the
  fixlog gains the same three, **append-compatible** with pre-C9 9-column logs).
  A failing suite — or, under `unit_gate_when_no_tests=block`, a missing test
  class — holds the object at REMEDIATED (deployed + ATC-clean but not verified)
  with a `BLOCKED: gate=unit_tests …` line and exit 3; the gate **persists** the
  passing transitions, so one red suite never blocks recording the rest.
  `sap_gate_policy.ps1` gains `unit_gate_when_no_tests` (default WARN) and now
  reads gate directives only from the brief's Pick tables (prose can't be
  mis-parsed). The `migration_brief` template + sample gain narrow-in-place
  ABAP-Unit gate rows; the `abap-developer` agent's post-ATC flow generates
  tests via `/sap-gen-abap-unit` when a mandatory bar finds no test class. Error
  class `CC_REMEDIATE_GATE_BLOCKED` added. Offline-tested 30/30 (pass/fail/
  no-tests paths, append-compat, brief parse, lib-driven resolution).
  **Live-verified end-to-end on S4H (topsap, S/4HANA 2022 / 7.57):** a real
  `$TMP` fixture with a deliberately failing ABAP Unit test was deployed +
  activated, `/sap-run-abap-unit` returned a real FAIL (`methods=1 failed=1`),
  and `record` (gate resolved live from the migration brief → `unit_gate=BLOCK`)
  **held it at REMEDIATED** (`UNIT_BLOCKED`, exit 3) — with the pre-C9 9-column
  fixlog upgraded to 12 columns on the live system; the test was then fixed,
  re-run (real PASS `methods=1 passed=1`), and re-recorded → **VERIFIED** (exit
  0). Fixture cleaned up afterward. The live run also surfaced + fixed a cosmetic
  note refresh (a held→VERIFIED row now records "verified after unit-gate hold"
  rather than retaining the stale hold note).
- **Readiness-capability pre-check** (`shared/scripts/sap_readiness_probe.ps1`,
  `Get-SapReadinessCapability` dot-source + CLI) wired into **`/sap-doctor`**
  (new informational `READINESS_CAP` check, never degrades the verdict) and
  **`/sap-cc-analyze`** (Step 1.5 preflight before the ATC loop). Read-only RFC
  probe of `SCICHKV_HD` → `READINESS_CAPABLE | NO_READINESS_VARIANTS |
  RFC_ERROR` (+ variant count / release-suffixed target variants), so pointing a
  readiness run at a system with no `S4HANA_READINESS` variants (e.g. an ECC
  box) fails fast instead of looping plan-errors. Deliberately keyed on variant
  presence, NOT the `SYCM_*` table family — that is a proven FALSE signal
  (present on plan-erroring 1909 systems, absent on a working 2022 system; see
  `temp/testReport/cc_harvest_attempt_20260703.md`). The authoritative catch
  remains `/sap-atc`'s existing `ATC_PLAN_ERRORS` (`COUNT_PLNERR > 0`) gate.
  Live-verified: EC2 → NO_READINESS_VARIANTS (0), S4D → 7 variants, S4H → 16
  (incl. `_2022`/`_2020`).
- **`/sap-cc-remediate revert` — scripted rollback for deployed fixes (pain-plan
  C10).** New `revert` action stages the retained `<obj>.before.abap` as
  `<obj>.revert.abap` (+ `.revert.diff` for operator review; default scope =
  recheck-FAILED fixes, `-Objects "A,B"` for explicit DEPLOYED/VERIFIED
  rollbacks); after the delegated sandbox redeploy (Step 4b: sandbox assertion +
  workbench skills + CONTENT_VERIFY), `record` accepts `outcome=REVERTED`
  (REMEDIATED|VERIFIED → TRIAGED; fixlog `status=REVERTED`,
  `deploy_status=ROLLED_BACK`, note records the prior status). A results file
  that is ALL `REVERTED` bypasses the `dryrun_review` gate — a rollback restores
  the reviewed before-image; blocking it would strand a broken fix on the
  sandbox. `/sap-cc-campaign report` keeps reverted fixes in the attempt
  denominator but out of the auto-fixed numerator
  (`INFO: auto_fix_rate ... reverted=<n>`). Offline-tested end-to-end: staging
  selection (FAILED-default / explicit / NOT_DEPLOYED / BEFORE_MISSING /
  NOT_IN_FIXLOG), gate bypass vs mixed-file BLOCK (exit 3), both ledger
  transitions, and the KPI line.
- **Golden-screen baseline coverage 8/121 → 120/121 (pain-plan C12).** Static
  seeds (`method: static`, `status: pending_live`) authored for all 112
  remaining driving VBS across sap-dev-core + sap-tcd — per-checkpoint
  `findById` dependency sets with popups as their own checkpoints, dynamic IDs
  excluded per contract, either/or release alternatives split into separate
  checkpoints (mm01 1909 vs ECC6), absence-probes never seeded as required
  (present-means-failure IDs like sap_se37_delete's post-delete tab strip).
  Verified: consistency gate green (0 malformed baselines), plus an automated
  cross-check that every seeded id exists verbatim in its paired VBS (0
  violations in the new wave; 2 of the 8 pre-existing seeds carry assembled
  full paths, exercised at live capture). The sole remaining gap is
  `sap_stms_import.vbs` (placeholder IDs pending `/sap-gui-record`
  calibration). Seeding conventions codified in
  `contributing/golden_screen_baselines.md`.

### Fixed

- **`/sap-login` reconnect via connection string false-reported "Could not
  obtain a SAP GUI session" and then stacked a duplicate logon screen.** On a
  direct `/H/<host>/S/<port>` open (`OpenConnectionByConnectionString`),
  `sap_login.vbs` identified the just-opened connection by matching
  `GuiConnection.Description == connectionString` — but for a connection-string
  open the Description does **not** echo that string while the session sits on
  `SAPMSYST` (observed live 2026-07-03: S4D, `sap1.vicp.cc` sysnr 70, from
  NO_SESSION). So the Step-3 wait loop never matched → `ERROR: Could not obtain
  a SAP GUI session` even though the connection *had* opened; and the Step-2
  reuse scan missed the leftover logon screen (its identity match needs
  client+user, both empty pre-login; the description fallback fails for the same
  reason), so a re-run opened a **second** `con[N]` login screen instead of
  reusing the first. Two changes: **(1)** Step 3 now identifies the new
  connection by **connection Id** — the handle returned by the `Open*` call, with
  a pre-open Id-snapshot diff as fallback — instead of by Description, and polls
  until a session materializes; this is endpoint-shape-agnostic and still
  excludes a pre-existing logged-in connection (no false "Already logged in").
  **(2)** Step 2 gains a **login-screen-of-our-system** tier `(1b)`: a session
  still on `SAPMSYST` has no client/user yet but its backend `SystemName` is
  known, so the leftover logon screen is adopted when `SystemName == <profile
  SID>` — a positive-signal-only match (never adopts a different system's login
  screen; skipped for legacy no-SID profiles). Net: the first run now succeeds
  instead of erroring, and any leftover logon screen is reused rather than
  duplicated. Offline whole-file VBScript compile verified (early-`WScript.Quit`
  injection under 32-bit cscript, plus a broken-syntax negative control). Related
  memory: `feedback_sap_login_multi_connection_wait_loop`.
- **`sap_tadir_delete.ps1` could not clear TADIR orphans for long object
  names.** Its `Read-Rows` helper passed the whole
  `PGMID = … AND OBJECT = … AND OBJ_NAME = '<name>'` key as ONE
  `RFC_READ_TABLE` OPTIONS row; for a DDLS/CDS name ≥21 chars the clause
  exceeds the 72-char OPTIONS cap → `SAPSQL_PARSE_ERROR` → the read returned
  `$null` → `TADIR: FAILED … (TADIR read failed)`, so both the def-gone safety
  guard and the orphan delete silently broke (same class as the `/sap-gen-cds`
  verify fix). Now splits the WHERE one clause per OPTIONS row (the shared
  `Add-RfcWhereClauses` rule). **Found live on S4D during the `/sap-gen-cds`
  delete test** (24-char view name): before the fix the orphan clear reported
  `TADIR read failed`; after it, `TADIR: DELETED` and verify returned
  `MISSING`. Affects every caller (dev-clean, se01 remove-objects, the P2
  orphan remediation) for any object name ≥21 chars.
- **`/sap-se37` forced EXPORTING parameters to pass-by-reference on
  RFC-enabled FMs.** `Build-ParamTabCode` — the interface-tab generator in
  `sap-se37/SKILL.md`, used by both the create (`sap_se37_create.vbs`) and
  update (`sap_se37_update.vbs`) flows — hardcoded the Pass-by-Value checkbox at
  `chkRSFBPARA-VALUE[5,r]` for *every* tab. Column 5 is correct for
  IMPORTING/CHANGING, but the EXPORTING tab has no Default(3)/Optional(4)
  columns, so its Value checkbox sits at column **3**; writing col 5 there was a
  swallowed no-op, so `VALUE(EV_*)` export params silently persisted as
  pass-by-**reference** and activating the FM as Remote-Enabled failed with
  *"In RFC modules, only parameters with pass by value are allowed."* The
  generator now takes explicit per-tab `$optionalCol`/`$valueCol` (EXPORT = 0/3,
  IMPORTING/CHANGING = 4/5, TABLES = 4/0) instead of one `$hasValue` flag, and
  the "SE37 Component IDs Reference" table documents the per-tab checkbox
  columns. Found during the Plan D13 spike deploying `Z_CDS_DDL_INSTALL`;
  RFC-verified live on S/4HANA 1909 (all 4 EXPORTING params were by-reference
  until `chkRSFBPARA-VALUE[3,r]` was ticked). Offline logic test covers all four
  tabs + reference params. *(Investigated but NOT changed: the reported
  `/sap-activate-object` SE37 worklist "Select All" concern — `sap_activate_se37.vbs`
  contains no `sendVKey 26` and deliberately presses Continue-only, using
  `btn[9]` solely to detect the worklist, per the proven-safe SE38 model.)*
- **`/sap-activate-object` (SE11) stale comment implied "activate all listed
  objects."** The header comment in `sap_activate_se11.vbs` documented the
  inactive-objects worklist as "-> press btn[9] + btn[0] to activate all listed
  objects" — the exact over-activation its own body (correctly Continue-only)
  guards against; a maintainer "fixing the code to match the docs" would have
  co-activated unrelated developers' inactive objects on a shared DEV. Comment
  corrected to match the shipped Continue-only behavior. **Live-verified the
  worklist model is safe on BOTH S/4HANA 1909 (S4D) and ECC 6.0 (EC2):** a
  controlled test — a throwaway `$TMP` inactive report activated next to 28
  (S4D) / 5 (EC2) other inactive objects — showed the SE38/SE37 worklist
  pre-selects ONLY the triggering object (`SELECTED_COUNT=1`; the others aren't
  even listed without the "Whole Worklist" `btn[18]` / "Select All" `btn[9]`,
  which the skills never press). RFC before/after confirmed nothing else
  activated. Note the worklist grid id differs by release (S4D
  `tblSAPLSEWORKINGAREAT_LOCAL` under a Transportable/Local tab strip; ECC 6.0
  `tblSAPLSEWORKINGAREAENVIRONMENT` with no tab strip) — identified by the
  locale-independent `btn[9]` discriminator, not the grid path.
- **SE38 content-verify gate silently disabled by the single-consumer
  relocation.** `sap_se38_content_verify.ps1` kept a bare `$PSScriptRoot`
  sibling include of `sap_rfc_read_source.ps1` after moving from
  `shared/scripts/` to `sap-se38/references/` (2026-07-03), so every deploy
  soft-warned `CONTENT_VERIFY: UNAVAILABLE` — the stale-paste false-success
  gate was off. Caught live on S4D during the 2026-07-03 smoke (fixture
  create surfaced the WARN); the include now resolves
  `<plugin>\shared\scripts\` from the references dir and fails LOUD when the
  lib is missing. Verified live: MATCH on a clean deploy, MISMATCH (exit 2,
  first-diff line report) against a stale source. The other three scripts
  relocated the same day carry no `$PSScriptRoot` includes (checked).
- **Two-bucket temp model completed.** The last 15 skills writing fixed-name
  state/scratch under `{WORK_TEMP}` moved to `{RUN_TEMP}` (all 10 substantive
  sap-gen-code skills + sap-diagnose / se41 / se51 / snro / trace) — the
  run-temp ratchet is now 0; concurrent sessions can no longer clobber each
  other's `_run.json` / scratch files.
- **Migration human gates enforced in code, not just by the agent prompt.**
  `/sap-cc-campaign next` returns `BLOCKED` (exit 3) until `scope_signoff` is
  recorded APPROVED; `/sap-cc-remediate record` refuses (`BLOCKED`, exit 3)
  until `dryrun_review` is APPROVED — a skipped diff review can no longer be
  marked as campaign progress. (`dryrun_review` is deliberately NOT blocked at
  `next`: the dry-run produces the very diffs under review.) Offline-tested
  end-to-end (init → BLOCKED → signoff → released; REJECTED stays blocked).
- **Credential crash-window closed.** `/sap-login` now generates a guarded
  runner whose `finally` deletes the password-bearing `.ps1`/`.vbs` even when
  the login crashes or times out (previously deletion lived in a later bash
  block a crashed run never reached); the Step 4 RFC test is wrapped the same
  way, and login start sweeps >10-minute-old password-bearing scratch left by
  hard kills.
- **Z-FM signature-cache staleness.** `/sap-se37` invalidates the deployed /
  deleted FM's signature-cache rows, so a same-day `/sap-gen-abap` /
  `/sap-check-fm` run never generates against the pre-deploy interface
  (`--refresh-cache` remains for FMs changed on other machines).
- **Silent degradation made loud in the spec pipeline.** `/sap-gen-abap`
  warns (user-facing + a TODO block in the generated source) when
  `_selection_definition.txt` / `_interface.txt` are absent instead of
  silently falling back to lossy prose parsing; `/sap-check-abap` appends a
  `SIGNATURE_CHECKS_SKIPPED` WARNING row when the struct/authz caches are
  absent, so reduced coverage is visible in the written report.
- Deleted monorepo-root pollution (`nul`, `ROLLNAME` scratch); confirmed no
  committed writer (ad-hoc session commands).

### Added

- `shared/rules/error_classes.md` — the published `error_class` taxonomy
  (48 classes across ATC/AUNIT/CC/STMS/infra families) for log/alerting
  consumers; referenced from CLAUDE.md and `sap_log_lib.ps1`.
- `docs/security.md` — required SAP authorizations per capability,
  credential-handling statement, `saprules.xml` grant rationale +
  least-privilege narrowing, write-safety enforcement map, and a
  security-review checklist; linked from README + installation guide;
  `/sap-doctor` now appends an `AUTH: not probed` manual-check line pointing
  at it.
- CI: `check-consistency.mjs` now HARD-ERRORS when a file in
  `sap-dev-core/shared/scripts` is not mentioned in CLAUDE.md's "Current
  Shared Files" table (23 missing rows backfilled, incl. the post-activate /
  content-verify gates).
- A `shared/scripts/` vs `skills/<skill>/references/` **placement rule** is
  codified in CLAUDE.md (shared = ≥2 consumers / cross-plugin, OR
  platform-wired primitive, OR non-driving VBS include-lib; everything else
  is skill-local). Applying it, 7 single-consumer scripts moved to their
  owning skills with consumer paths retargeted:
  `sap_se38_content_verify.ps1/.vbs` → sap-se38/references (+
  `TIER3_EXEMPT_VBS` entry for the include-lib shim),
  `sap_check_conversion/signatures/spec_coverage.ps1` →
  sap-check-abap/references (they now ship with the plugin that uses them),
  `sap_session_owner.ps1` + `sap_probe_end_of_run.ps1` →
  sap-gui-probe/references. The post-activate verify family stays shared
  (se11's member is also called by sap-gui-skill-scaffold; the three are one
  maintained safety-gate contract).
- The placement rule is CI-enforced in **both directions**:
  `check-consistency.mjs` hard-errors on a shared script missing its
  CLAUDE.md row, and now also emits a `shared-placement` WARN ratchet when a
  shared script's consumers shrink to one same-plugin skill or zero (no
  sibling-script/rules wiring, no reasoned `SHARED_PLACEMENT_ALLOWLIST`
  entry). The new check immediately exposed `sap_check_transport.ps1` as
  zero-consumer dead code (untouched since v0.1.0; its CLAUDE.md row falsely
  claimed five deploy-skill consumers — TR validation moved into
  `/sap-transport-request` long ago): **deleted**, row removed.
- README: grouped index of all 80 skills, "Current Limitations (v0.7.0)"
  section, Windows-only prominence, install-order and settings-precedence
  notes; installation guide prerequisites hardened (server-side
  `sapgui/user_scripting` with Basis wording, Python requirement,
  `/sap-doctor` verification pointer).

### Changed

- **sap-migrate knowledge pack 2026.07** (13 patterns; 3 ACTIVE + 10 DRAFT):
  - Detection reworked for its REAL haystack — `/sap-cc-triage` matches
    `detect_code_regex` against the finding's message text + check id, not
    source code, so every table pattern now also matches ATC message
    phrasings (`table X` / `usage of X`), and `detect_simpl_items` carries
    the full public S4TWL item title alongside the short provenance key
    (exports usually carry the title; exact-token matching previously could
    never fire). README schema docs corrected to say all this.
  - `BP_CVI` regex narrowed to writes + maintenance APIs/tcodes per its own
    description — a bare `SELECT ... FROM kna1` (legitimate in S/4) no longer
    false-classifies; it stays UNMATCHED → REVIEW.
  - `BSIS`/`BSAS` moved from `ACDOCA_FIN` to `FI_OPENITEM_INDEX` (SAP's
    index-table item, now titled "FI index tables"), added to
    `COMPAT_VIEW_WRITE`'s DML list, and given object_map rows.
  - New DRAFT pattern **`SD_STATUS_TABLES`** (VBUK/VBUP eliminated; status
    fields moved into VBAK/VBAP/LIKP/LIPS/VBRK/VBRP; no like-for-like compat
    views) with recipe, object_map and field_map rows — one of the most
    common SD adaptation items and previously a guaranteed UNMATCHED.
  - `MATNR_EXTENSION` (the ACTIVE R1 pattern) gains a message-text regex —
    it previously had no regex channel at all.
  - Coverage honesty: pack README now states the ~20–30% auto-classify
    expectation and the UNMATCHED-by-design framing up front (repo README
    limitations updated to 13 patterns).
  - Verified offline: 13×14 TSV integrity, all regexes compile, and a
    9-finding synthetic triage run hits every intended pattern/basis
    (SIMPL_ITEM title match, message-phrasing regex, write-vs-read
    disambiguation, narrowed BP_CVI leaving reads UNMATCHED, new pattern).
- sap-gen-code / sap-tcd descriptions (plugin.json + marketplace) now declare
  the sap-dev-core dependency and install order (sap-migrate already did).
- sap-se01 SKILL.md frontmatter description trimmed ~350 → ~130 words
  (skill-list token cost).

## [0.6.9] — 2026-07-02

Hardening release. A full-repo skill review (~130 verified findings, 29 high)
and its remediation across all four plugins, then live-validated on S/4HANA
1909 under a Chinese (ZH) logon.

### Fixed

- **False-success on write paths.** Activation/save flows that printed SUCCESS
  on a status-bar error now gate on `MessageType` and fail loud + exit 1 (SE11
  updates, SE51, SE41, SNRO intervals, SE38 text elements, function-group
  create). `sap-update-addon` (SM30/SE16/PROG) and `sap-call-bdc` now verify the
  write (status-bar / `MSGTYP`) instead of reporting unconditional success, and
  refuse unsupported DELETEs. `sap-tcd` (BP/MM01/VA01) captures the created
  document number and aborts incomplete sales orders by default.
- **Quality gates that passed on failure.** `/sap-atc` fails loud on an
  unparseable result grid and on an empty object set (object-resolver
  pre-flight) instead of reporting PASS; the poll loop now has a real timeout.
  `/sap-run-abap-unit` no longer lets a `coverage=NA` silently satisfy an
  explicit `--min-coverage`.
- **Locale-dependent GUI logic.** `sap-tcd` (all 9 scripts), the change-package
  family, SE91, SE54, SNRO and SE16N now decide by control ID + `MessageType`,
  not translated window/status text, so they work under ZH/JA logons; evidence
  and definition files are read/written as UTF-8.
- **Transport integrity.** SE01 create now resolves the new TRKORR
  authoritatively over RFC (new `sap-se01/references/sap_se01_resolve_trkorr.ps1`,
  reading `E07T`/`E070`) — fixing both the empty-status-bar gap on 1909 ZH and
  the old workstation/server timezone bug, while never guessing a wrong TR.
  Select-All is removed from the inactive-objects worklist (no more
  co-activating other developers' objects on a shared DEV); an empty transport
  request now aborts instead of silently registering as `$TMP`.
- **`/sap-sp02` could not run** — the variable `eNum` collided with the
  VBScript reserved word `Enum` (a compile error); renamed.
- **`sap-check-abap` false positives** (field-symbol naming, early-return
  `FOR ALL ENTRIES` guard) removed, and the shipped object-naming defaults
  realigned with what `/sap-gen-abap` actually emits; the invalid `sap-fix-fm`
  auto-fix stub corrected.
- **Login credential hygiene.** The password is piped to DPAPI via stdin (off
  the process command line), and plaintext scratch is cleaned up on every path
  via PowerShell `Remove-Item` (the previous `cmd /c del` silently failed under
  git-bash).

### Added

- **`/sap-gui-screen-check` implementation.** The orchestrator + probe scripts
  (previously documented but never committed) now ship.
- **`/sap-docs-layout` helper.** The openpyxl `edit_meta_layout.py` + the
  `(Meta) Layout` schema doc now ship.
- **Evidence registration** for `/sap-atc` and `/sap-run-abap-unit` outputs so
  `/sap-evidence-pack` collects them instead of always reporting them missing.
- **CI gates** in `scripts/check-consistency.mjs`: referenced-script existence
  (error), bare-`cscript` and locale-literal ratchets, `{RUN_TEMP}` coverage
  widened to `.json/.xml/.log/.txt`; non-ASCII in committed scripts is now a
  hard error.

### Changed

- ~20 skills migrated per-run scratch/state files to `{RUN_TEMP}` so concurrent
  sessions no longer collide.
- Migration-campaign integrity (sap-migrate): a usage join-rate guard (no more
  estate-wide decommission on a zero-match export), per-object `ANALYZED`
  marking, a mechanical sandbox-target assertion before remediate-deploy, and
  honest KPI denominators.

## [0.6.8] — 2026-06-28

### Added

- **End-to-end developer manual.** A new `docs/manual.md` walks an SIer ABAP
  developer from a clean Windows laptop through install → `/sap-login` →
  `/sap-dev-init` → the spec → ABAP generation pipeline → deploy → the ATC /
  ABAP-Unit gates → transport-to-production, with real S/4HANA screenshots and a
  worked `abap-developer` agent example. Trilingual: `docs/manual.md` (EN,
  canonical) + `docs/manual_JA.md` + `docs/manual_ZH.md` (each carries an
  "EN is canonical" banner). Linked from the README and the installation guide.

### Changed

- **Installation docs corrected.** Each plugin must be installed with its own
  `/plugin install` command (Claude Code does not accept several plugins in one
  invocation); added a `/reload-plugins` step (or a Claude desktop restart)
  after install; and a note that SAP GUI 7.70 often deploys SAP NCo 3.1 into the
  GAC automatically — check `GAC_32\sapnco\…\sapnco.dll` +
  `sapnco_utils\…\sapnco_utils.dll` before downloading.

_Documentation-only release — no skill behaviour changed since 0.6.7._

## [0.6.7] — 2026-06-26

### Added

- **`/sap-se01` gained transport-object un-assignment and empty-TR/Task
  deletion.** A new **`remove-objects`** mode surgically unassigns `E071` object
  entries from a transport while keeping the TR (targeted by object name, or
  remove-all), and the **delete** flow now removes an empty TR/Task
  node-by-node, bottom-up (tasks before their request) so a drained request
  collapses cleanly. Both are backed by a new shared RFC reader
  `shared/scripts/sap_tr_object_entries.ps1` (NCo 3.1) that lists `E071` entries
  by object, by TR (walking request + tasks via `E070-STRKORR`), or only the
  orphaned ones — surfacing each entry's `OBJFUNC` (`K` create/change vs `D`
  deletion) plus a `deletions=` count and the real capturing `REQUEST`.

- **`/sap-dev-clean` and `/sap-dev-init` transport hygiene.** `/sap-dev-clean`
  now clears the dev-init object entries from their transport and **deletes the
  TR once it is empty** (plus a `--reset` / `--force` full-reset path);
  `/sap-dev-init` runs a **pre-create orphaned-lock sweep** so a stale `E071`
  entry from an old released/deleted transport can no longer block re-creating
  the same object. Both also gained **anchor validation + self-healing for stale
  dev defaults**, so a build that clobbered `dev_defaults` can no longer let
  dev-clean target the wrong package/TR.

- **`/sap-se37` clipboard source paste + post-activate verification.** Source is
  pasted via the clipboard behind the OS-level foreground guard (so it can never
  land in the user's foreground editor), and the function module is RFC-verified
  after activation.

- **AI-session liveness heartbeat.** A stable-id breadcrumb that lets the
  session broker distinguish a live conversation from an orphaned one, hardening
  parallel-session isolation.

### Fixed

- **False VBScript crash on a CLEAN ABAP syntax check after activation
  (`getCellValue … "parameter is incorrect"` / E_INVALIDARG).** The SE37/SE24
  update + create syntax-grid parse closed the narrow per-`Info.Language` guard
  with `On Error GoTo 0`, which in VBScript cancels the *block-level*
  `On Error Resume Next` entirely (one error-handling flag per procedure — there
  is no handler stack). The following `getCellValue(row,"LINE")` loop then ran
  UNguarded and its `Err.Clear` calls were dead code, so when
  `FindSyntaxErrorGrid` mis-latched onto a non-syntax ALV that has a `MSGTYPE`
  column but no `LINE` column, the read threw and aborted the whole script
  *after* the object had already activated cleanly (2026-06-22 S4D wrapper-FM
  deploy: false error tail on a verified-clean activation). Fixed by (a) a new
  shared `SafeGetCell(oGrid, iRow, sCol)` in `sap_syntax_check_lib.vbs` that
  wraps the read in its OWN `On Error Resume Next` and returns `""` on a missing
  column / out-of-range row / any COM failure — immune to the caller's
  error-handling mode; and (b) re-arming the cancelled block guard
  (`On Error GoTo 0` → `Err.Clear`) in the three affected files. A clean check
  that mis-latches now degrades to empty cells (classified "no error") instead
  of raising. Primary fix: `sap_se37_update.vbs` (the reported crash),
  `sap_se37_create.vbs`, `sap_se24_update.vbs`. All nine syntax-grid readers
  (additionally `sap_se38_create/update.vbs` incl. their post-activate gate,
  `sap_se24_test_classes.vbs`, and the three `*_check_and_download.vbs`) were
  migrated to `SafeGetCell` for one bulletproof read path — this also fixes a
  latent stale-variable bug in `sap_se24_test_classes.vbs` (loop-scoped `Dim`
  vars were not re-initialised, so a failed read reused the prior row's value).
  Offline-validated against a mock grid whose `LINE` column throws.

- **`/sap-se01` release wasted its pass cap re-releasing an already-released
  task via fixed label positions.** It targeted a task at a fixed `lbl[col,row]`
  and pressed Release up to its cap (one success, then N "already released"
  no-ops), locating the request the same fragile way. It now collects each task
  number once, releases each exactly once, and locates every node by **TR
  number** (language-independent) rather than by screen position.

- **`/sap-se01` release reported `DONE` on a failed transport-control release
  (false success).** A request left `D` after a non-zero `tp` return code (e.g.
  `0012`) was still reported `DONE`. The verdict now flags a non-zero `tp` RC or
  an `E`/`A` status, and the **RFC verify of `E070-TRSTATUS = R` for the request
  and every task is the authoritative gate**.

- **`/sap-se21` create reported `PACKAGE_CREATED` even when the create was
  canceled (false success).** The success line is now gated on actually reaching
  the Change-Package screen (`SAPLPB_PACKAGE/1000`); a canceled create emits an
  `ERROR` and a non-zero exit instead.

- **Deletion entries (`E071-OBJFUNC = 'D'`) were invisible and could be silently
  un-recorded.** Emptying or deleting a transport that holds deletion records
  un-records those deletions (the object stays deleted locally but the deletion
  never transports). The shared reader now surfaces them with a `deletions=`
  count, `/sap-se01` Delete-Mode requires a knowing confirmation before draining
  such a TR, and `shared/rules/tr_resolution.md` gained a **§6** documenting the
  **fold-into-modifiable-request** behaviour — a deletion records in the
  object's own still-open request, not the TR you passed, so verify where it
  landed instead of assuming.

- **Delete-flow robustness across `/sap-se11`, `/sap-se21`, `/sap-se37`,
  `/sap-se24`, `/sap-se38`.** A **shared post-delete popup walker** replaces the
  divergent per-skill loops (each modal dispatched by DDIC control id only);
  `/sap-se11` delete now confirms success by **control presence** instead of the
  translated window title; and ECC 6.0 "Create Object Directory Entry" (KO007)
  handling was hardened.

- **A `TADIR` orphan left after a DDIC delete could block the package delete
  indefinitely (`/sap-se21`, `/sap-dev-clean`).** When a domain / data-element /
  … definition was deleted (`DD01L` / `DD04L` / … row gone) its `TADIR`
  object-directory row could survive, and SE21 then refused to delete the owning
  package. A new safety-guarded helper `shared/scripts/sap_tadir_delete.ps1`
  removes the orphan row via the dev-init wrapper FM → `TR_TADIR_INTERFACE` (the
  SAP write API for `TADIR` — not remote-enabled, so reached as an asXML dynamic
  call through `Z_GENERIC_RFC_WRAPPER_TBL`; no raw SQL on `TADIR`). It deletes a
  row **only** when the object's definition is verifiably gone (per-type
  def-table probe `DOMA`→`DD01L`, `DTEL`→`DD04L`, `TABL`→`DD02L`, …;
  `REFUSED_DEF_EXISTS` for a live object, `REFUSED_UNMAPPED` for an unknown
  type), and treats a post-delete RFC re-read of `TADIR` returning zero rows as
  the authoritative success — so it can never orphan a live object. Wired into
  `/sap-se21` (Step 8a) and `/sap-dev-clean` (Step 5). Caveat: cleaning the
  dev-init package's *own* orphans fails by construction (the wrapper FM is
  deleted with it) — redeploy via `/sap-dev-init` or clean via SE03 / `RSWBO052`.

### Changed

- **Sub-skill delegation is enforced through the Skill tool.** Documentation and
  `/sap-function-group` delete now make explicit that orchestrators
  (`/sap-dev-clean`, `/sap-dev-init`) must invoke `/sap-se*` via the Skill tool
  rather than running their reference VBS directly — otherwise mode dispatch,
  fallbacks (e.g. ECC 6.0 `/sap-se38 delete SAPL<FG>`), and post-action
  verification are silently bypassed.

## [0.6.6] — 2026-06-20

### Added

- **Parallel multi-session build safety — three isolation layers on top of the
  session-attach contract (layer 1),** after concurrent same-spec builds across
  several SAP connections surfaced cross-session clobbering:
  - **Layer 2 — two-bucket temp model.** Per-run scratch is isolated to
    `{RUN_TEMP}` (`{work_dir}\temp\run_<id>`); only allowlisted coordination
    files (`session_registry.json`, `connections.json`,
    `session_dev_defaults.json`, AI-session pins) live at the shared
    `{work_dir}\runtime\` path. Enforced statically by `scripts/check-consistency.mjs`
    (hard error on `{RUN_TEMP}` passed to `Get-SapCurrentSessionPath -WorkTemp`;
    warning on fixed-named scratch under the `{WORK_TEMP}` root) and at runtime by
    `scripts/run-temp-hook.mjs` (a `PreToolUse` hook; modes `block`/`warn`/`off`
    via `SAPDEV_RUNTEMP_HOOK`, fails open). Motivated by a cross-session
    `sap_se38_update_run.vbs` collision between two concurrent builds.
  - **Layer 3 — two-layer dev defaults.** The per-connection dev keys
    (`sap_dev_transport_request`, `sap_dev_package`, `sap_dev_function_group`,
    `sap_dev_mode`, `way_to_get_transport_request`, `rule_of_tr_description`,
    `tr_description_template`) now resolve Session → Connection → global, with a
    per-`(AI-session × connection)` Session layer at
    `{work_dir}\runtime\session_dev_defaults.json` (`Set-SapUserSetting -Scope
    Session`, now the writers' default, + the `shared/scripts/sap_dev_default.ps1`
    CLI; reads centralized through `Get-SapCurrentDevDefault`). Fixes
    same-connection default thrash and stops `/sap-login --switch` carrying a TR
    across systems. Session entries are age-pruned (7 days).
  - **Layer 4 — per-session log files.** New `log_file_pattern` placeholders
    `{AI_SESSION}` / `{SID}` / `{CLIENT}` give one coherent log per
    `(AI session × connection)` instead of interleaving the daily file.

### Changed

- **`contributing/parallel_safe_session_attach.md` extended from a
  session-attach-only contract into the full four-layer parallel-safety
  reference** (layers 2–4 section, an at-a-glance table, and a "known gap" note
  that the customer brief is still a single shared file — keep it
  connection-agnostic, comment-language blank). CLAUDE.md's pointer row updated to
  match (CI gate now "seven conditions", four-layer scope, extended history tail).

## [0.6.5] — 2026-06-17

### Fixed

- **`/sap-se37`, `/sap-se24` and the SE38/SE37/SE24 check-and-download paths
  could report a deploy as SUCCESS while the object stayed INACTIVE on ECC 6.0.**
  The Ctrl+F2 syntax-check / activation result grid sits at a release-specific
  container path (`wnd[0]/shellcont/shell/shellcont[1]/shell` on S/4HANA 1909;
  nested deeper on ECC 6.0). The hardcoded path resolved to an empty/different
  control on the other release, so real syntax errors were silently dropped
  (`SYNTAX_ERRORS: 0` → Activate → false SUCCESS). A new shared
  `FindSyntaxErrorGrid` (in `sap_syntax_check_lib.vbs`) **walks** `wnd[0]/shellcont`
  for the GridView carrying a `MSGTYPE` column instead of hardcoding the path, and
  is wired into `sap_se38` / `sap_se37` / `sap_se24` create/update + every
  `check_and_download`. Live-verified on both ECC 6.0 (ER1) and S/4HANA 1909 (S4D,
  incl. a Chinese logon — icon `5C` + "错误" classified). Reusable gotcha fixed in
  the walk: re-reading `oNode.Children` for `.Count` then per-index throws err 618
  (the COM enumerator invalidates) — bind the collection once and use `.ElementAt(k)`.

- **`/sap-se24` create crashed (`control could not be found`) on the S/4HANA SE24
  screen flow that shows the Class/Interface chooser first.** `sap_se24_create.vbs`
  pressed Create then immediately expected the description field; it now detects
  and advances the `DY_0101` chooser when present (no-op when absent — other flows
  go straight to the details dialog) and aborts gracefully instead of crashing if
  the details dialog is unexpected. Live-verified on S4D.

- **The SAP GUI Security auto-dismiss watcher could leave a source upload hung for
  minutes.** A first-time `/sap-se37` / `/sap-se24` source upload raises **two**
  "SAP GUI Security" dialogs in quick succession; `sap_gui_security_sidecar.ps1`
  exited after the first `BM_CLICK` (without verifying the window closed), so the
  second dialog hung the driving cscript. It now verifies each dialog actually
  closed (retries if not) and keeps watching through re-prompts until a quiet grace
  window; new `FOUND_BUT_STUCK` status. The process doc
  (`sap_gui_security_handling.md`), `/sap-dev-init` result table, and the
  `CLAUDE.md` shared-files row (which still described the obsolete UIA
  implementation) were corrected. Live-verified on S4D across `/sap-se37`,
  `/sap-se24`, `/sap-se16n`, and `/sap-atc`.

- **Two concurrent AI sessions on different SAP systems (e.g. S4D + S4H) could
  corrupt `userconfig.json` and cross-contaminate system-specific dev settings.**
  Three distinct multi-connection races, all in the shared settings / connection
  libraries:
  - **`userconfig.json` torn / lost writes.** `Set-SapUserSetting` did an
    unlocked, non-atomic `WriteAllText`, while `Get-SapSettings` *threw* on a
    parse error. Two sessions writing a global key at overlapping times produced
    a lost update or a half-written file, after which every settings read in that
    session died. The whole read-modify-write now runs under a cross-process
    named mutex (`SapDevUserConfigStore_v1`) and swaps the file in atomically
    (temp file + NTFS `File.Replace`), so a concurrent reader never sees a torn
    document. A `userconfig.json` / `settings.local.json` that is unreadable
    anyway now **WARNs and is skipped** (falling back to `settings.json`
    defaults) instead of aborting the skill; a write over a corrupt file backs it
    up to `userconfig.json.corrupt.<pid>` and rewrites cleanly.
  - **`connections.json` could be wiped under a concurrent read.**
    `Write-SapConnectionStore` was likewise non-atomic, so a reader that hit a
    half-written file reset to an *empty* store — and the next save then
    overwrote the real file, losing every saved connection. It now uses the same
    atomic temp-file + `File.Replace` swap.
  - **Per-connection dev defaults leaked across systems when a session was
    unpinned.** `Get-SapCurrentDevDefault` / `Set-SapCurrentDevDefault` resolved
    the profile via `Get-SapCurrentConnectionProfile`, which falls back to the
    **default connection** (and a single-password auto-bootstrap) when this AI
    session has no pin. Because a transport request carries the SID prefix
    (`S4DK…` vs `S4HK…`), an unpinned S4H session would *read* S4D's TR/package/
    function-group and, on save, *write* an S4H value into S4D's `dev_defaults`
    block. A new strict resolver (`Get-SapDevDefaultProfile`) returns a profile
    only when it is unambiguously this session's — explicit pin, or a sole saved
    connection — and otherwise returns `$null`, so reads fall through to the
    global value and writes go to the global file (with a one-shot WARN telling
    the user to `/sap-login` to pin) instead of silently corrupting the default
    connection. Banner / version-info / RFC callers still use the original
    default-fallback resolver unchanged.
  - Verified on Windows PowerShell 5.1: per-connection isolation under pin /
    no-pin, write targeting, corrupt-file resilience, and a cross-process
    concurrent-writer race (16/16; `temp/test_multiconn_devdefaults.ps1`).

## [0.6.4] — 2026-06-13

### Added

- **Build-metrics KPI ledger — first-pass-yield for generated ABAP.** A new
  *derived* quality yardstick that answers "did that prompt change / new KB row /
  model bump actually move the needle?" `sap_build_kpi.ps1` reconstructs one
  `sapdev.buildkpi/1` row per build from data the pipeline **already** writes —
  the structured JSONL logs (every gate skill's `start` / `end` records, so even
  STOP / ABANDONED runs are captured for free) and the delivery-assurance artifact
  index — and trends first-attempt pass rates across the GEN / SPEC / CHECK /
  SYNTAX / ACTIVATE / TEXT / ATC / AUNIT gates into
  `{work_dir}\metrics\build_kpi.jsonl`, surfaced via `/sap-log-analyze --builds`.
  The cardinal rule is **derive, do not instrument**: where a KPI needs a number
  the bare log lacks (ATC P1/P2/P3, ABAP Unit coverage) it rides as an extra field
  on the gate skill's existing end record — no new per-build write path and no
  agent-level "append a row" instruction (both have silently failed in this repo
  before, and STOP/partial builds are exactly the runs such instructions skip).
  Contract: `shared/rules/build_metrics.md`.

- **Offline ABAP generation-contract regression net (CI-gated).** Three
  deterministic, no-SAP-connection checks that gate generation quality before a
  single GUI call:
  - `scripts/lint-abap-contract.mjs` — mechanises the offline-checkable subset of
    `/sap-gen-abap`'s pre-emit ATC checklist plus the sibling-file sync rules
    (line length, literal `MESSAGE`, read-only `TEXT-NNN`, block / declaration
    order, `SELECT *`, `LOOP ... WHERE`/`EXIT`, and signature-based
    `AUTHORITY-CHECK` / `CALL FUNCTION` validation). `--fixture` promotes silent
    "signature absent" skips to hard errors — the snapshot-completeness gate that
    closes the green-wash hole where a missing snapshot read as a pass.
  - `scripts/diff-abap-skeleton.mjs` — structure/set-based skeleton diff of the
    generator's own manifest siblings (`.traceability.txt`, `.deps.txt`,
    `.messages.txt`, `.text_elements.txt`) against a per-fixture `case.json`,
    catching a validation rule / dependency / message / selection field silently
    **dropped or re-mapped** across generator or prompt changes (rule swaps a
    line-based diff misses).
  - `shared/scripts/sap_check_spec_coverage.ps1` — the user-facing twin: derives
    the expected skeleton from the operator's **own** spec (`/sap-docs-extract`
    output) instead of a committed golden, so it works on any fresh build.
  Wired into `/sap-check-abap` as offline checks 5 (generation contract) and 6
  (spec coverage), and into CI via `npm run lint:abap` / `skeleton:abap` /
  `validate` (both `.mjs` ship `--selftest` fixtures). Self-tested on Node; the
  PowerShell coverage validator on Windows PowerShell 5.1 + pwsh 7.

### Changed

- **`/sap-atc` now documents SAP GUI Security handling for result-file
  downloads / exports.** The ATC result `.txt` download trips the "SAP GUI
  Security" dialog the same way a generated `GUI_DOWNLOAD` report does; the
  SKILL.md now points at the `{work_dir}` grant / sidecar coordination so the
  download does not silently block, with a matching note in
  `shared/rules/sap_gui_security_handling.md`.

- **`/sap-check-abap` validator hardening.** `sap_check_abap.vbs` gains UTF-8
  handling and improved line-length checks; `sap_check_signatures.ps1` output is
  aligned with `sap_check_abap.vbs` for consistent downstream parsing.

### Fixed

- **A `work_dir` chosen during onboarding did not stick for later skills in the
  same session — they silently fell back to `C:\sap_dev_work` while connections /
  config lived elsewhere.** `SAPDEV_AI_WORK_DIR` is persisted at *User* scope,
  which only reaches **new** processes; the running host and every sibling
  PowerShell it spawns (one per skill call) never inherit it. The per-run
  `$env:…=` bridge only covered the `/sap-login` run itself, so the next skill
  (`/sap-se38`, `/sap-se16n`, …) resolved the default. Hand-writing `work_dir`
  into the versioned-cache `settings.json` bridged the session but was lost on the
  next plugin update.
  - Added a **durable, out-of-cache bootstrap pointer** at
    `%APPDATA%\sapdev-ai\work_dir.txt`. It survives plugin updates (outside the
    versioned cache) **and** is read fresh by every subprocess, so a work_dir
    chosen mid-session resolves correctly for every later skill — no restart, no
    `settings.json` edit. New resolution order: env var → `settings.local.json`
    → **pointer file** → `settings.json` → default.
  - `sap_workdir_setup.ps1 -Action set` now writes the pointer alongside the User
    env var (`POINTER_SET=True`); `-Action probe` reports
    `POINTER_PATH/POINTER_EXISTS/POINTER_VALUE`. Resolver functions added to
    `sap_settings_lib.ps1` (`Get-SapWorkDirPointerPath`, `Read-SapWorkDirPointer`).
  - **Existing users now get the pointer too** (closes a gap where it only
    appeared on a first-run or explicit change): new `-Action pin -WorkDir <path>`
    writes ONLY the pointer (no consent-gated env-var change), idempotently
    (`ALREADY=True` when unchanged). Onboarding (`work_dir_onboarding.md` Step B.1)
    auto-pins any **non-default** resolved `work_dir` that isn't already recorded —
    so a single `/sap-login` makes a `C:\Work\…`-style work_dir durable without a
    manual `settings.json` edit. The default `C:\sap_dev_work` is intentionally
    never pinned (it is the hardcoded fallback, so a pointer adds nothing).
  - `/sap-doctor` now treats *env-unset + pointer-present* as a durable **PASS**
    instead of warning; it only warns when neither pins `work_dir`.
  - Docs updated: `work_dir_onboarding.md` (resolution order, Step B signals,
    Step C/E), CLAUDE.md (Rule 7 + Work Directory Configuration).
  - Verified on Windows PowerShell 5.1 and pwsh 7: full precedence ladder
    (env > settings.local > pointer > settings.json > default) + set/probe
    round-trip.

## [0.6.3] — 2026-06-08

### Fixed

- **SAP GUI Security broad-grant could be silently shadowed by a stale rule, so the
  "SAP GUI Security" dialog kept appearing at runtime even though `/sap-dev-init`
  reported the warmup done** — e.g. on the ATC result download and when running a
  generated `GUI_UPLOAD` / `GUI_DOWNLOAD` report such as a material-upload program.
  `sap_gui_security_grant.ps1` decided idempotency on the rule's **path + permissions
  only**, ignoring its context fields. A same-path rule left from an earlier attempt —
  with literal `*` context values (SAP treats *empty*, not `*`, as "any") or a
  backslash path (SAP stores forward slashes) — matches nothing at runtime yet
  satisfied that check, so the script returned `ALREADY` forever and the effective
  any-context `rw` rule was never written.
  - Idempotency is now **context-aware and self-healing**: `ALREADY` only when an
    *effective* any-context same-path rule with sufficient permissions already exists;
    a malformed (`*` / backslash) or narrow (per-program) same-path rule is **purged
    and replaced** with the canonical empty-context rule — a new
    `HEALED: … removed=<ids>` outcome (it also upgrades `w` → `rw`). Only single-name
    elements for the exact path are touched; multi-name and other-path rules are
    byte-preserved.
  - `/sap-dev-init` Step 1b now surfaces the `HEALED` outcome and makes the one-time
    **SAP Logon restart** explicit (a running SAP Logon caches `saprules.xml` at
    startup, so a freshly written rule only takes effect after a restart — permanent
    thereafter). Contract docs updated: `shared/rules/sap_gui_security_handling.md`
    and the CLAUDE.md shared-files table.
  - Verified on Windows PowerShell 5.1 and pwsh 7 (23/23), and end-to-end live on
    S/4HANA 1909: a healed `{work_dir}` rule covers both a write (Hardcopy) and a read
    (`GUI_UPLOAD`, subrc 0) under a fresh program dynpro with no dialog.

## [0.6.2] — 2026-06-07

### Added

- **Code-comment language specification.** `/sap-gen-abap` now writes source-code
  comments in the configured language (EN / JA / ZH — driven by the customer brief
  / SAP logon language), so generated ABAP is commented in the operator's language.
  Specified in `abap_code_quality_rules.md` + the customer brief template.

- **frequently_errors feedback loop** — a team-shareable, curated catalog of
  recurring FM / class-method / codegen mistakes + remedies that closes the
  generate → deploy → check loop on `sap-gen-abap`. Complements the FM/struct/
  authz *signature* caches (which give a call's *shape*) by capturing the
  *traps* signatures cannot express. New skill count **77 → 78**.
  - **3-tier store** (precedence: highest wins on conflict, union otherwise,
    `MUTE` suppresses): `{custom_url}\frequently_errors.tsv` (hand-authored
    override) > `{custom_url}\frequently_errors\<OBJECT>.tsv` (per-object,
    auto-recorded + curated) > `shared/tables/frequently_errors.tsv` (plugin
    seed). System-agnostic and team-shareable via `custom_url` (NOT MEMORY
    files).
  - **Seed** `shared/tables/frequently_errors.tsv` — 17 CONFIRMED traps mined
    from real MaterialUpload builds (BAPI_MATERIAL_SAVEDATA explicit-MATNR /
    marmdata weight-volume / inline-`DATA()`-on-7.52; GUI_UPLOAD/DOWNLOAD
    FILENAME=STRING; CL_GUI_FRONTEND_SERVICES file_open_dialog; literal
    MESSAGE; M_MATE_MAR/M_MATE_WRK authz fields; text-symbol; REPOSRC dump),
    cross-referenced to `abap_code_quality_rules.md` §14/§22/§24.
  - **Engine + CLI** `shared/scripts/sap_error_hints_lib.ps1` (+ `sap_error_hints.ps1`
    CLI: `resolve` / `record` / `curate`). READ path = `sap-gen-abap` **Step
    1.5f** (OFFLINE 3-tier merge → `_error_hints.txt`, injected at Step 2,
    new ATC-checklist item #9). WRITE path = `sap-se38`/`se37`/`se24` (Step 6b
    / Final) + `sap-atc` (Step 6c) auto-record on failure as `CANDIDATE`,
    attributing each error to its FM/METHOD **by source line number**
    (locale-independent) with an `_UNATTRIBUTED` fallback. Verified on
    Windows PowerShell 5.1 + pwsh 7 (21/21 offline assertions).
  - **Curation skill** `/sap-error-kb` (`list` / `promote` / `mute` / `show`) —
    only `CONFIRMED` rows reach generation by default
    (`frequently_errors_inject_status`); auto-records stay `CANDIDATE` until a
    human adds the remedy and promotes, so documented `sap-check` false
    positives can't silently poison the generator.
  - New settings `frequently_errors_enabled` / `frequently_errors_autorecord`
    / `frequently_errors_inject_status`; contract doc
    `shared/rules/frequently_errors.md`.

### Fixed

- **Transport-request RFC create built a Customizing request instead of Workbench.**
  The RFC/BDC create path in `sap_transport_request.ps1`
  (`CTS_API_CREATE_CHANGE_REQUEST`) passed `CATEGORY="W"` on the belief that
  W=Workbench, but that value maps straight to `E070-TRFUNCTION`, where
  **K=Workbench, W=Customizing**. The result was a Customizing request — which
  cannot hold Workbench objects, so every deploy looped on the SAPLSTRD transport
  prompt. Changed to `CATEGORY="K"` and corrected the inverted comment. Verified
  live on S/4HANA 1909: `CATEGORY="K"` → `E070-TRFUNCTION=K`, and SAP auto-creates
  the development task on first object assignment (a task-less Workbench request is
  fully usable). Latent until now because prior releases only exercised the GUI
  `/sap-se01` create path (`sap_dev_mode=GUI`), not the RFC path.

- **SE38 attribute changes are now persisted.** `sap_se38_change_attrs.vbs` set the
  title via the Goto→Attributes dialog and reported success, but the change never
  reached the DB (Save was disabled on the initial screen). Reworked to the
  source-editor path (open in change mode → Goto→Attributes → Save → Activate).

- **SE38 program title no longer stored as cp932 mojibake.** The title had flowed
  through a PowerShell source literal in a BOM-less `.ps1` (read as system ANSI
  under Windows PowerShell 5.1). Routed via a UTF-8 file (`[IO.File]::ReadAllText`
  UTF8), keeping the generator ASCII-only; non-ASCII titles (e.g. Chinese) now
  store clean.

- **SE24 / SE37 change-attribute robustness.** SE24 properties-change reworked for
  S/4HANA source-based Class Builder compatibility; SE37 short text routed via a
  UTF-8 file (same cp932 class as the SE38 title fix).

## [0.6.1] — 2026-06-04

### Fixed

- **Source-encoding hygiene (ASCII-first cleanup).** Converted the lone genuinely-executed
  CJK literal in `sap_update_addon_se16.vbs` (the success/error `WScript.Echo`) to `ChrW()`,
  removed the UTF-8 BOMs from the five `sap_change_package_{se11,se24,se37,se38,se91}.vbs`
  templates (plus `cmod`), and ASCII-cleaned their comment em-dashes (`—` → `--`). All six are
  now pure ASCII; the non-ASCII guard holds at 133. Recorded the standing decision **not** to
  convert the tree to UTF-16 / UTF-8-BOM, plus the runtime file-I/O and SAP `GUI_UPLOAD`
  (`codepage='4110'`) encoding axes, in `contributing/source_encoding_policy.md`.

- **CJK/JA mojibake in PowerShell JSON ingest under Windows PowerShell 5.1.**
  `Get-Content -Raw | ConvertFrom-Json` reads with the system ANSI codepage by
  default on PS 5.1, so the Write-tool's BOM-less UTF-8 JSON was decoded as ANSI —
  any finding text quoting Chinese / Japanese spec field labels then garbled into
  the exported deliverable. Added `-Encoding UTF8` to the affected ingest blocks:
  `sap-review-abap` Step 6 emit (`candidate_findings.json` → `.review.tsv` /
  `.review.json`; confirmed live on S4D 2026-06-04 reviewing ZMMRMAT053R01, where
  the Chinese file-mapping labels 工厂视图 / 旧物料编号 / MRP 管理者 came out
  garbled until the fix) and `sap-st22` Step 1 anchor ingest (`anchor.json`,
  defensively — fields read today are ASCII). Other JSON ingests across the
  shared `.ps1` scripts already specify `-Encoding UTF8`; `.vbs` reads use
  ADODB.Stream and are unaffected.

## [0.6.0] — 2026-06-03

Completes the SAP delivery loop on top of 0.5.0's lifecycle platform: a
**diagnose → fix** closed loop, **transport landscape movement** (DEV → QAS →
PRD), AI semantic + **security** review, ABAP Unit generation, a reverse
object → spec documenter, an environment preflight **doctor**, and a
golden-screen **drift** harness. **4 plugins · 77 skills · 2 agents**
(sap-dev-core 55, sap-gen-code 12, sap-migrate 7, sap-tcd 3). The newest
write-capable / production-touching paths (`/sap-stms` import, `/sap-st22
--deep`, `/sap-fix-incident` deploy) ship **gated and fail-safe**, with live
calibration status noted per entry below — nothing claims a verification it
has not had.

### Transport landscape movement: `/sap-stms`

- **`/sap-stms`** (sap-dev-core) — the missing link after release: moves a
  **released** TR through the landscape (DEV → QAS → PRD) and reads its import
  status / return code. Four modes: **status** (default, read-only — a target's
  import queue, or where a TR sits), **logs** (read-only — import log + RC mapped
  0=OK / 4=OK_WITH_WARNINGS / 8=ERROR / 12=FATAL), **import** (write, gated), and
  **import-all** (write, double-gated). Safety is the product: read-only default;
  `import` needs explicit confirmation; a **production** target requires a typed
  SID echo **plus** a second confirmation (the most outward-facing, least-
  reversible action in the toolset); never imports an unreleased (`E070-TRSTATUS
  != R`) or NO-GO TR without `--force`. Honesty contract: missing TMS import auth
  → `COULD_NOT_IMPORT` (never a faked success); **RC 8/12 is a failure even if
  the queue row looks "done."** GUI for the action, RFC (E070) for the
  released-status read. The destructive `sap_stms_import.vbs` ships as a
  **recording-gated, fail-safe scaffold**: its Import-Request / options-dialog
  control IDs are `PLACEHOLDER_*` and a calibration gate ABORTS (`not-calibrated`,
  presses nothing) until they are `/sap-gui-record`-captured for the release; even
  once calibrated, the import button fires only after positively verifying the
  selected queue row's `TRKORR` equals the requested TR — so an uncalibrated or
  mis-targeted run fails safe, never mis-imports. Read-only `sap_stms_queue_read`
  / `sap_stms_log_read` ship working (candidate IDs + graceful degradation). All
  three VBS follow the Tier-3 attach contract. Completes the delivery chain
  `/sap-fix-incident` → `/sap-transport-readiness` → `/sap-se01 release` →
  **`/sap-stms`**. Totals:
  **77 skills** (sap-dev-core 55). **Live STMS calibration + import test pending.**

### Diagnose → fix closed loop: `/sap-fix-incident` + `/sap-st22 --deep`

- **`/sap-st22 --deep`** (sap-dev-core) — deep per-dump extraction. Opens each
  in-scope dump from the ST22 list and scrapes the failing source line + snippet
  into the event's `include`/`line` fields plus a new `dump_detail` object in the
  shared `/sap-diagnose` evidence contract. Strictly additive — list rows are
  collected before any dump is opened, so a deep failure can never lose the v1
  evidence; every failure degrades to `detail_status = partial | skipped`
  (HTML-rendered dumps yield `partial`, with exception/program still known from
  the list level), never a false "no defect." The error line is anchored on the
  locale-independent `>>>>` marker, so no branching on a translated section
  header. New params `--deep` / `--dump-key` / `--max-deep`. Offline-verified
  (clean 32-bit `cscript` compile + valid evidence schema); **live ST22
  detail-screen calibration pending** (the detail container ID needs a
  `/sap-gui-record` pass to lift HTML-rendered dumps from `partial` to `ok`).
- **`/sap-fix-incident`** (sap-dev-core) — the write-capable companion to the
  read-only `/sap-diagnose`, closing the last mile from a root cause to a
  deployed, **test-verified** fix. Takes a diagnose deliverable (or a dump key)
  whose top hypothesis is a CUSTOM-CODE DEFECT, acquires the failing source,
  reasons a minimal patch, **reproduces the defect in an ABAP Unit test (RED)**
  via `/sap-gen-abap-unit`, applies the patch, re-checks with `/sap-check-abap`,
  deploys to a modifiable DEV system behind a transport (`/sap-se38|37|24` +
  `/sap-activate-object`), and proves the test **GREEN** with
  `/sap-run-abap-unit`. Hard guard rails: custom-code-defect on `Z*/Y*` only;
  never patches SAP standard code (→ Note / enhancement, analysis only); never
  writes to the incident's own system when it is non-modifiable / production —
  the fix is made in DEV and handed to `/sap-transport-readiness` →
  `/sap-se01 release` → `/sap-stms`. Deploy is gated (`skill_operating_rules`
  Rule 2): the default PROPOSEs a diff and waits for confirmation. Findings flow
  through the reconciled finding model and register for `/sap-evidence-pack`.
  Totals: **76 skills** (sap-dev-core 54).
- **`/sap-diagnose --fix`** (entry sugar) — runs the loop from one command:
  `/sap-diagnose` runs its ST22 leg `--deep`, presents the hypotheses, and — only
  when the rank-1 hypothesis is a custom-code defect and after an explicit
  confirmation — hands the deliverable to `/sap-fix-incident` (Step 8.5).
  **`/sap-diagnose` itself still writes nothing**; the fix skill owns its deploy
  gate + guard rails. No new skill (a flag on the existing orchestrator).

### Live screen-drift check: `/sap-gui-screen-check` (GUI-robustness harness, half 2)

- **`/sap-gui-screen-check`** (sap-dev-core, `sap-gui-*` family) — the live half
  of the golden-screen harness. Replays the `*.screens.json` baselines against
  the CURRENT SAP system: for each checkpoint it navigates via the `reach`
  OK-code, reads the screen identity (program + dynpro), and tests that every
  control ID the driving VBS depends on still resolves via `findById`. A missing
  control or identity mismatch on a `captured` checkpoint is reported as **DRIFT
  (BLOCKER)** — naming the exact control and the VBS that will silently mis-step
  on this release; a `pending_live` checkpoint is captured and (only with
  `--update-baseline`) promoted to `captured`. Language-independent (asserts IDs
  + program/dynpro, never displayed text). Read-only against SAP except the gated
  baseline write. Architecture: a deterministic PowerShell orchestrator
  `references/sap_screen_check.ps1` (enumerate baselines, run the probe per
  checkpoint, compare identity + control presence, roll up a `SCREENCHECK:`
  verdict, exit 1 on drift) shelling the read-only probe
  `references/sap_screen_check_probe.vbs` (self-resolves SESSION_PATH like
  `sap_gui_object_details.vbs`; Tier-3 + baseline exempt). **Live-smoked
  (assess-only) on S4D 1909 (2026-06-03):** the probe attaches and reads screen
  identity; the SKILL.md data-loss guard correctly fired on a non-idle session,
  so the navigate + promote path is verified on first idle-session run.
- **Baselines backfilled** (static / `pending_live`): `sap_se37_create`,
  `sap_se24_create`, `sap_se11_{domain,dataelement,structure,table}_create` —
  screen-baseline coverage now **7/116**.
- v1 scope: OK-code (initial-screen) checkpoints only; new-control INFO diff and
  `sap_finding_lib` bridging are documented future work. Totals: **75 skills**
  (sap-dev-core 53).

### Golden-screen baseline coverage gate (GUI-robustness harness, half 1)

- **New CI gate** in `scripts/check-consistency.mjs` — every operational
  SAP-driving `.vbs` under `skills/<skill>/references/` should ship a screen
  fingerprint baseline `<stem>.screens.json` (schema `sapdev.screenbaseline/1`)
  recording the control IDs + screen identity (program/dynpro) it depends on at
  each checkpoint. Two tiers, mirroring the non-ASCII guard's "don't break the
  build on pre-existing debt" stance: a **missing** baseline is an informational
  `WARN` and a ratcheting `screen-baseline coverage N/M` metric; a **malformed**
  baseline is a **hard error**. Driving-VBS detection follows the Tier-3 contract
  (declares `Const SESSION_PATH` / includes `%%ATTACH_LIB_VBS%%` / calls
  `AttachSapSession` / binds the Scripting engine, minus the exempt set) — so it
  catches both migrated and legacy templates. Initial coverage: **1/116**.
- **Contract doc** `contributing/golden_screen_baselines.md` (repo-level, not
  shipped) — schema, worked example, authoring guide, and the promotion path to
  a hard gate once coverage reaches 100%. CLAUDE.md Shared Resources updated.
- **Seeded baseline** `sap-se38/references/sap_se38_create.screens.json` —
  `initial` checkpoint, `method: static` / `status: pending_live`, dependency set
  (`ctxtRS38M-PROGRAMM`, `radRS38M-FUNC_EDIT`, `btnNEW`, `okcd`) extracted from
  the VBS; live `identity` capture pending the `/sap-gui-screen-check` build.
- This is the **static half** of the harness; the live half
  (`/sap-gui-screen-check` — replays baselines against a target release, reports
  drift as BLOCKER findings) is the next step. The gate is the pre-flight
  counterpart to the per-object RFC PROGDIR/DWINACTIV post-deploy verify: that
  catches "did the write land?" after a run; this catches "will the write path
  even execute?" before, across all skills.

### Environment preflight: `/sap-doctor` (read-only)

- **`/sap-doctor`** (sap-dev-core) — a `brew doctor` / `flutter doctor` for the
  sap-dev toolchain. Diagnoses *why a skill would fail before it runs*, across
  five groups: **gui** (SAP GUI + scripting reachable — reuses the static
  `sap_check_gui_login_status.vbs`; a `LOGGED_IN` result is the authoritative
  proof that client + server scripting are both on), **cfg** (32-bit PowerShell,
  SAP NCo 3.1 in `GAC_32`, `SAPDEV_AI_WORK_DIR` set + work_dir writable,
  `connections.json` present + valid), **rfc** (RFC connectivity to the
  AI-session's pinned profile via the `Connect-SapRfc` pinned-profile fallback),
  **srv** (client Repository modifiability — `T000.CCNOCLIIND`, so a non-modifiable
  client is caught before a deploy fails at activation), and **devenv** (TR /
  package / function group / wrapper artefacts, delegated to `/sap-dev-status`).
  Emits one parseable `CHECK:` line per probe and an overall
  `READY / DEGRADED / BLOCKED` verdict; every failure carries a copy-pasteable
  **FIX**. Honours the honesty contract — a probe that cannot run reports `SKIP`,
  never a false `PASS`. Read-only (only writes/deletes a tiny temp probe file to
  test work_dir writability). New checker `references/sap_doctor_checks.ps1`.
  First strike of the GUI-robustness initiative; the golden-screen regression
  harness is the planned follow-up. **Live-verified on S4D 1909 (2026-06-03):**
  empty-credential substitution correctly drove the `Connect-SapRfc`
  pinned-profile fallback (`RFC_PING` PASS), the `T000.CCNOCLIIND` read returned
  the client modifiability correctly (`CLIENT_MODIFIABLE` PASS), and the GUI
  `LOGGED_IN` mapping held — no code changes from the run. Report:
  `temp/testReport/sap_doctor_e2e_S4D_20260603.md`.

### Three new AI-leverage quality skills (GUI+RFC only)

- **`/sap-review-abap`** (sap-gen-code) — AI semantic + security code review of an
  existing object or a `.abap` file. Distinct from the deterministic
  `/sap-check-abap` and the in-system `/sap-atc`: it reasons over logic, security
  (dynamic-SQL injection, missing/incorrect `AUTHORITY-CHECK`), performance, and
  robustness; every finding cites a line + code excerpt and survives an
  adversarial self-verification pass before it is emitted (false positives
  dropped, not shipped). Findings flow through the shared finding model
  (`sap_finding_lib` → `sap_gate_policy` → `Export-SapFindings*`), are gated
  against the customer brief's Quality bar, and register for `/sap-evidence-pack`.
  Read-only. Source acquired via the existing RFC reader (program/include/FM) +
  SE24 GUI download (class).
- **`/sap-gen-abap-unit`** (sap-gen-code) — generates ABAP Unit tests for an
  existing class / FM / report, then closes the loop: pre-check (`/sap-check-abap`)
  → deploy (`/sap-se24 --test-source` CCAU local test classes, or `/sap-se38`) →
  `/sap-activate-object` → `/sap-run-abap-unit --with-coverage` → fix → repeat
  (bounded by `--max-rounds`). A seam analysis classifies each DB read / external
  call into a doubling strategy (`CL_OSQL_TEST_ENVIRONMENT` / `CL_ABAP_TESTDOUBLE`)
  and is honest about untestable-without-refactor code. Deploy is gated behind
  `--deploy` (default `ask`) per `skill_operating_rules` Rule 2. Pairs with
  `/sap-run-abap-unit` (same `abap-unit` vocabulary).
- **`/sap-document-object`** (sap-dev-core) — reverse of the spec→code pipeline:
  turns an existing object into a formal specification document (Markdown by
  default, Word via `--format docx`, or a filled `spec_template.xlsx` that
  round-trips back through `/sap-docs-extract`). Builds on `/sap-explain-object`'s
  comprehension map, enriches it with DDIC (DD02T/DD03L) and message (T100) detail
  over RFC, and marks every section CONFIRMED (system-read) vs INFERRED (reasoned).
  Read-only.

Totals: **4 plugins · 74 skills · 2 agents** (sap-dev-core 52, sap-gen-code 12).
Names were vetted against the skill naming convention (the `<verb>-abap` family;
`abap-unit` token reused to pair with `/sap-run-abap-unit`; `-object` suffix to
avoid the `sap-docs-*` near-collision). All three are GUI+RFC only — no ADT.

## [0.5.0] — 2026-06-03

Rolls up the interim 0.3.1–0.3.4 patch bumps and adds a fourth plugin plus
five new skill families. **4 plugins · 70 skills · 2 agents.**

### New plugin: `sap-migrate` — S/4HANA custom-code migration engine

- Runs a brownfield custom-code conversion as a tracked **campaign**. Seven skills:
  `sap-cc-campaign` (owns the campaign workspace + state ledger and orchestrates
  the engine), `sap-cc-inventory` (classifies in-scope Z/Y objects from TADIR/TRDIR
  over read-only RFC), `sap-cc-usage` (overlays runtime usage to split objects into
  REMEDIATE / DECOMMISSION / REVIEW), `sap-cc-analyze` (runs the S/4HANA-readiness
  ATC via `/sap-atc`), `sap-cc-triage` (classifies findings into remediation tiers
  R1–R4 via the Simplification Knowledge Pack), `sap-cc-remediate` (sandbox-only R1
  remediation after a mandatory dry-run — the one sap-migrate skill that writes),
  and `sap-cc-learn` (feeds real ATC message ids back into the knowledge pack).
- Ships the **`cc-migration-engineer` agent**, the `migration_brief.md` (+ sample)
  templates, and the **Simplification Knowledge Pack** under
  `plugins/sap-migrate/shared/knowledge/`.

### sap-dev-core — new skill families

- **Incident diagnosis (read-only):** `sap-diagnose` orchestrator that fans out
  across five read-only evidence readers — `sap-st22` (short dumps, GUI),
  `sap-sm13` (update-task failures), `sap-sm12` (lock entries via `ENQUEUE_READ`),
  `sap-slg1` (application log / BALHDR), `sap-sm37` (background jobs / TBTCO) —
  correlates the evidence into incident clusters and ranks root-cause hypotheses.
- **Performance:** `sap-trace` analyzes an already-recorded ST05 / SAT trace (or an
  imported file), ranks hotspots, flags anti-patterns, and maps each to a code-
  quality rule + a fix.
- **Delivery assurance:** `sap-transport-readiness` (RFC release gate → GO /
  GO_WITH_WARNINGS / NO-GO), `sap-impact-analysis` (where-used / forward-dep / entry-
  point analysis from the cross-reference index with a transparent risk band),
  `sap-enhancement-advisor` (recommends the safest BAdI / SMOD / user-exit extension
  point with transparent scoring), and `sap-evidence-pack` (collects registered
  artifacts into an audit-ready pack with an honest "Missing evidence" section).
  Backed by new Phase-0 shared libraries: `sap_object_resolver.ps1`,
  `sap_artifact_lib.ps1`, `sap_finding_lib.ps1`, `sap_gate_policy.ps1`.
- **Testing:** `sap-run-abap-unit` runs ABAP Unit on a deployed program / class via
  SE38 / SE24 with a verdict gate and optional code coverage.
- **Comprehension / compare:** `sap-explain-object` (acquires source, builds a
  structure + call map, emits an explanation dossier) and `sap-compare` (diffs the
  same object across two saved SAP systems over RFC).

### Onboarding & infrastructure (folded in from 0.3.1–0.3.4)

- First-run **`work_dir` onboarding** for `/sap-login` / `/sap-dev-init`, resolved
  via the env-aware `Get-SapWorkDir` (env var `SAPDEV_AI_WORK_DIR` →
  `settings.local.json` → `settings.json` → default) so a custom work directory
  survives plugin updates.
- Removed the dead VBScript settings library — settings are PowerShell-only; VBS
  receives resolved values via `%%TOKEN%%` substitution + environment variables.
- Added the **non-ASCII source guard** to `scripts/check-consistency.mjs`
  (informational): flags BOM-less `.ps1` / `.vbs` files with bytes > 0x7F that would
  mojibake under Windows PowerShell 5.1 / 32-bit cscript.

## [0.3.0] — 2026-05-27

### Syntax-check classifier — locale-aware shared lib (2026-05-27)

- **Bug fixed.** `sap-se38`, `sap-se37`, and `sap-se24` deploy skills silently passed real syntax errors on non-EN logons. The Ctrl+F2 grid's MSGTYPE column is rendered as `"@<HEX-ID>\Q<localized-label>@"` — the label is in the user's logon language. The inline classifier matched only the literal English `"ERROR"` substring (plus `"1"` / `"E"`), so on a ZH logon `@5C\Q错误@` and on JA `@5C\Qエラー@` were classified as non-errors, `SYNTAX_ERRORS: 0` was emitted, the script proceeded to Activate against syntactically-broken code, the popup walker dismissed the "Activate anyway?" SPOP, the verify heuristic accepted screen 101 + empty sbar as success, and the run reported `SUCCESS` while PROGDIR still held `STATE='I'`. Reproduced on 2026-05-27 against ZMMRMAT049R02 (line 21 `TYPE matkl2` — unknown DDIC type) on an S/4HANA 1909 ZH session.
- **New shared lib**: [`shared/scripts/sap_syntax_check_lib.vbs`](plugins/sap-dev-core/shared/scripts/sap_syntax_check_lib.vbs). Three functions:
    - `GetSyntaxErrorWord(sLang)` — returns the SAP-localized "Error" word for the given logon-language code. Accepts both 1-char SAP codes (`E`/`D`/`F`/`S`/`I`/`P`/`1`/`M`/`J`/`3`/`R`) and 2-char ISO codes (`EN`/`DE`/`FR`/`ES`/`IT`/`PT`/`ZH`/`ZF`/`JA`/`KO`/`RU`). Uses `ChrW()` literals so the source stays ASCII.
    - `ExtractIconId(sCell)` — parses `@<HEX-ID>\Q…@` and returns the uppercased ID, locale-independent.
    - `IsErrorMsgType(sCell, sLogonLang)` — two-tier classifier: legacy `"1"` / `"E"` / English `"ERROR"` substring (backward compat) → localized-word `InStr` (primary path on non-EN logons) → icon-ID prefix in `{03, 0A, 5C, AT, AY}` (locale-independent fallback). Empty MSGTYPE returns `False` so continuation/child rows don't double-count.
- **Refactor**: deduplicated five identical 28-line inline `GetSyntaxErrorWord` blocks plus five inline two-tier match sites into a single shared include. Caller VBS files include via `ExecuteGlobal FSO.OpenTextFile("%%SYNTAX_CHECK_LIB_VBS%%",1).ReadAll()` and call `IsErrorMsgType(sCell, sLogonLang)` directly. Net change across 9 files: **−270 lines** (+77 / −347).
- **Token wiring**: SKILL.md PS1 generators for sap-se38 (create + update), sap-se37 (create + update), and sap-se24 (update) substitute `%%SYNTAX_CHECK_LIB_VBS%%` with the absolute path to the shared lib.
- **CLAUDE.md Shared Resources table** updated with a row for the new file describing the contract, calling convention, and the pre-refactor bug history.
- **Affected files**:
    - Added: `plugins/sap-dev-core/shared/scripts/sap_syntax_check_lib.vbs`
    - Modified callers: `sap_se38_create.vbs`, `sap_se38_update.vbs`, `sap_se37_create.vbs`, `sap_se37_update.vbs`, `sap_se24_update.vbs`
    - Modified SKILL.md: `sap-se38/SKILL.md`, `sap-se37/SKILL.md`, `sap-se24/SKILL.md`
    - Modified `CLAUDE.md` (Shared Resources table)
- **Verified end-to-end**: regenerated the update VBS from the refactored template + new shared lib and re-ran against the unchanged broken matkl2 source on ZH S/4HANA 1909. Output: `INFO: Logon language = 'ZH'; matching syntax-error word = '错误'`, `SYNTAX_ERRORS: 1`, `ERROR: Syntax errors found. Fix errors and retry.`, exit code 1 — no activation attempt.

## [0.2.0] — 2026-05-17

### Phase 4.3 — Per-connection settings + universal RFC credential fallback (2026-05-17)

- **Per-connection dev defaults**: `sap_dev_transport_request`, `sap_dev_package`, and `sap_dev_function_group` are now stored per-connection in `runtime/connections.json` under `connections[].dev_defaults`. Fixes silent cross-system contamination where a parallel session on a different SID would overwrite the shared `settings.local.json` keys with an invalid TR for the other system. New helpers in `sap_connection_lib.ps1`: `Get-SapPerConnectionDevKeys`, `Get-SapCurrentDevDefault`, `Set-SapCurrentDevDefault`. `Get-SapSettingValue` (sap_settings_lib.ps1) auto-routes reads for the three system-keyed values through the per-connection store with file-based settings as fallback — existing skills get isolation without code changes.
- **Connect-SapRfc auto-fallback to pinned profile**: `shared/scripts/sap_rfc_lib.ps1::Connect-SapRfc` parameters (`-Client`, `-User`, `-Password`, `-Language`, endpoint fields) are no longer `Mandatory`. When any required value is empty or still a literal `%%TOKEN%%`, the function dot-sources `sap_connection_lib.ps1` and resolves credentials from the AI-session's pinned connection profile (DPAPI-decrypted password via `sap_dpapi.ps1`). All ~19 downstream RFC PS1 templates start working once the user saves a password via `/sap-login` Step 5b — no per-file edits needed. Callers that pass explicit values still take precedence (backward-compatible). Literal-token detection uses `StartsWith('%%') -and EndsWith('%%')`.
- **SE11 create post-activate RFC verify wired**: all 9 `sap-se11/references/sap_se11_*_create.vbs` templates (domain, dataelement, table, structure, tabletype, typegroup, searchhelp, lockobject, view) now call a shared `PostActivateVerifyOrFail` Sub (new `shared/scripts/sap_se11_post_activate_verify.vbs`) which shells out to a new `shared/scripts/sap_se11_post_activate_verify.ps1`. The PS1 reads the pinned connection profile and runs `RFC_READ_TABLE` against the appropriate DDIC catalog (DD01L/DD02L/DD04L/DD25L/DD30L/DD40L). Fail-closed on `INACTIVE` / `MISSING`; soft-warn on `ERROR:` (RFC unavailable). Also promotes `sbar.MessageType="E"|"A"` after Activate from `WARNING (fall-through)` to `ERROR + WScript.Quit 1`. SE11 SKILL.md create-wrapper PS block substitutes two new tokens: `%%POST_ACTIVATE_VERIFY_VBS%%`, `%%POST_ACTIVATE_VERIFY_PS1%%`.
- Legacy `sap-se11/references/sap_se11_verify_active.ps1` is now obsolete (never wired); replaced by the credential-less Phase-4.3 helper.

### Phase 4 — Multi-profile + AI-session pin (2026-05-16)

- **Multi-profile connection store** at `{work_dir}\runtime\connections.json`. Supports multiple saved SAP systems per Windows user, DPAPI-encrypted passwords, identity-based 4-step dedup (SystemName/Client/User → LogonPadEntry / MessageServer / AppServer+SysNr). New `/sap-login` argument modes: `--list`, `--add`, `--switch <id>`, `--set-default <id>`, `--delete <id>`.
- **AI-session pin** tying each Claude Code conversation (and its subagents) to a single SAP connection. Pin enforcement at broker layer refuses cross-connection acquires with a clear error. Mid-session `--switch` releases stale claims on the old connection atomically.
- **Phase 4.1: parent-PID-based AI session id** (`Get-SapAiSessionId` in `sap_connection_lib.ps1`). Walks the process tree skipping script-host processes (powershell, cscript, etc.) until it hits the Claude Code process. Subagents inherit; parallel conversations get distinct ids. Replaces the earlier write-once-if-missing `ai_session_id.txt` approach, which silently shared one id across parallel conversations. Broker auto-resolves `-AiSessionId` — wrappers no longer need bootstrap code.
- **Phase 4.2: `sap_active_session.json` pin file eliminated.** Version info (gui_*, server_*) moved into the connection profile in `connections.json`. Session path resolved live via `Get-SapCurrentSessionPath` (reads broker registry's `ai_sessions` pin + matching connection block). 25+ deploy SKILL.md wrappers migrated from `SAPDEV_PIN_FILE` to `SAPDEV_SESSION_PATH`. `sap_attach_lib.vbs` Strategy 3 (pin-file read) removed.
- **RFC load-balanced login**: `Connect-SapRfc` in `sap_rfc_lib.ps1` now accepts `-MessageServer` + `-LogonGroup` + `-SystemID` as an alternative to `-Server` + `-Sysnr`.
- **MessageServer / LogonGroup / Group / Program / ScreenNumber** captured from `GuiSessionInfo` by `sap_login_capture_active_session.vbs` and broker `INFO`. Stuck-screen tracking on broker entries via `-Action stuck -Program -Screen`.
- **Broker actions added**: `pin`, `unpin`, `set-connection-id`, `stuck`. Broker `release -WasCreated` calls the COM helper's new `CLOSE` action to drop spawned sessions.
- Legacy single-connection settings (`sap_logon_description`, `sap_application_server`, `sap_system_number`, `sap_client`, `sap_user`, `sap_password`, `sap_language`, `sap_pinned_session`) removed from `settings.json` schema. `Import-LegacyConnectionFromSettings` remains as a one-shot migration path for fresh upgrades.

## [0.1.0] — 2026-05-12

Initial public release. Early-access status — APIs and skill arguments may change between 0.x releases without strict semver compatibility. A `1.0.0` will be declared once the API contract is stable and at least one customer has used the toolkit in production for ≥3 months.

### Repository structure
- Monorepo with three plugins under `plugins/`: `sap-dev-core`, `sap-gen-code`, `sap-tcd`.
- Central marketplace catalog at `.claude-plugin/marketplace.json`.
- JSON Schemas for `marketplace.json` and per-plugin `plugin.json` under `schemas/`.

### sap-dev-core (36 skills + `abap-developer` agent)
- SAP GUI Scripting login + DPAPI-encrypted credential storage (`sap-login`).
- BDC execution via RFC `ABAP4_CALL_TRANSACTION` (`sap-call-bdc`).
- Add-on table maintenance via SE16/SM30 (`sap-update-addon`).
- ABAP Workbench drivers: `sap-se01`, `sap-se11`, `sap-se16n`, `sap-se19`, `sap-se21`, `sap-se24`, `sap-se37`, `sap-se38`, `sap-se41`, `sap-se51`, `sap-se54`, `sap-se91`, `sap-snro`, `sap-sp02`, `sap-cmod`.
- Object lifecycle helpers: `sap-activate-object`, `sap-change-package`, `sap-check-fix`, `sap-transport-request`, `sap-function-group`, `sap-where-used-list`.
- Dev-environment lifecycle: `sap-dev-init`, `sap-dev-status`, `sap-dev-clean`.
- Quality + observability: `sap-atc` (4-stage ATC pipeline with Object Set + Run Series + Run Monitor + Manage Results), `sap-log-analyze`.
- GUI utilities: `sap-gui-record`, `sap-gui-object-details`, `sap-gui-diagnose`, `sap-gui-probe` (drives a transaction step-by-step against a natural-language scenario, dumps each screen via the object-details engine, and emits a synthesized replay VBS — skill-authoring aid), `sap-gui-skill-scaffold` (consumes N probe folders for the same TCD and emits a ready-to-test mode-aware skill draft via cross-probe diff; supports `--parallel` to run probes concurrently against multiple SAP GUI sessions).

### Active-session pinning + version capture (2026-05-13)

- `sap-login` Step 6 now captures the active SAP GUI session — connection / session index, system / client / user / language, SAP GUI version (`oApp.MajorVersion`), and server release via `RFC_SYSTEM_INFO` + `CVERS` (S/4HANA 2022, ECC 6.0 EhP8, etc.). When multiple connections are open, asks the user which to pin. Writes `{WORK_TEMP}\sap_active_session.json`.
- Every GUI-using skill reads the pin to resolve its default session — fixes the multi-connection ambiguity (DEV + QAS, DEV/100 + DEV/121) where the implicit `Children(0).Children(0)` could target the wrong system.
- `sap-gui-probe` accepts `--session "/app/con[N]/ses[M]"` for explicit pinning and threads the session path through every dump + action call. `sap_gui_probe_action.vbs` gains an optional `session` field in the action JSON.
- `sap-gui-skill-scaffold --parallel` spawns one Task sub-agent per scenario, each bound to a distinct SAP GUI session (auto-created via `oCon.CreateSession()` up to SAP's default cap of 6). Cap configurable via `--parallel-cap`.
- New shared helper `sap_select_vbs_variant.ps1` for version-aware VBS picking: skills can ship multiple variants tagged by `server_release_marker` (e.g., `sap_se38_update.S4HANA_2022.vbs`) and the selector picks the best match at execution time. Framework only — no existing skill ships variants today; `sap-gui-skill-scaffold` auto-tags emitted files with the captured release.
- New shared `sap_rfc_system_info.ps1` (calls `RFC_SYSTEM_INFO` + `CVERS`) and `shared/tables/sap_release_markers.tsv` (component → canonical marker lookup).
- **Cross-AI-session persistence (opt-in):** `/sap-login --remember` writes the captured `session_path` to `settings.local.json` via `Set-SapUserSetting sap_pinned_session` (per Rule 7 — never to the tracked `settings.json`). Next AI session: consumer skills read the hint via `Get-SapSettingValue`, re-capture GUI fields against the hinted session, and rebuild `{WORK_TEMP}\sap_active_session.json`. Stale-hint guard: if the hinted session no longer resolves via `findById`, the hint is cleared via `Set-SapUserSetting sap_pinned_session ''` and the skill falls through to single-connection silent default or multi-connection refusal.
- RFC wrapper generators: `sap-rfc-wrapper-class`, `sap-rfc-wrapper-fm`.
- `abap-developer` agent: BUILD / FIX / DEPLOY orchestrator that reads a Customer Brief and dispatches the workbench skills.

### sap-gen-code (10 skills)
- Spec ingestion: `sap-docs-extract`, `sap-docs-convert`, `sap-docs-layout`.
- Validation: `sap-docs-check-ddic`, `sap-docs-check-process`, `sap-check-abap`, `sap-check-fm`.
- Generation + auto-fix: `sap-gen-abap`, `sap-fix-abap`, `sap-fix-fm`.

### sap-tcd (3 skills)
- Business process automation: `sap-bp`, `sap-mm01`, `sap-va01`.

### Shared infrastructure (sap-dev-core/shared)
- Reusable PowerShell + VBScript libraries: RFC connection helpers (NCo 3.1), DPAPI secret protection, structured JSONL logging, session-lock + foreground guards for SAP GUI Scripting, OS-level dismissal of the SAP GUI Security dialog via UI Automation.
- Mandatory rule docs: skill operating rules, transport-request resolution policy, SAP GUI language-independence rules, ABAP code-quality rules.
- Customer-facing templates: `customer_brief.md`, `spec_template.xlsx` (EN + JA variants), DDIC Excel layout cheat-sheet.

### Tooling
- `npm run validate:marketplace` — JSON Schema validation via ajv-cli.
- `npm run check:consistency` — verifies all skill directories are registered, manifest versions match, and counts are correct.
- `npm run validate` — runs both of the above.
