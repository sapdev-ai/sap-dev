# SAP Dev Marketplace

Welcome to the **sap-dev** marketplace - a curated collection of production-tested SAP skills for Claude Code CLI. **Windows-only**: the skills drive SAP GUI for Windows via GUI Scripting — there is no macOS/Linux path, so check the prerequisites below before installing anything.

> 📖 **New here?** For a complete, step-by-step walkthrough from a clean Windows
> laptop all the way to generating and deploying ABAP — written for an SIer ABAP
> developer, with real SAP screenshots — read the
> **[Developer's Manual](../manual.md)**. This page is the quick
> reference; the manual is the guided tour.

## Quick Start

### Prerequisites
- **Windows 10/11**: hard requirement — GUI Scripting COM and DPAPI-encrypted
  credential storage are Windows-only.
- **SAP GUI for Windows 7.70+**: required for all GUI Scripting skills.
- **SAP GUI Scripting enabled on BOTH sides**:
  - client: SAP Logon > Options > Accessibility & Scripting > Scripting;
  - server: profile parameter `sapgui/user_scripting = TRUE` (RZ11 for the
    current session, RZ10 to persist) — **this usually needs your Basis team**;
    plan for it before the pilot, it is the #1 first-run blocker.
- **SAP authorizations** for the logon user (S_DEVELOP, S_TRANSPRT, ...):
  see [docs/security.md](../security.md) for the per-capability table your
  security team will ask about.
- **Python 3.10+**: required for the `sap-gen-code` plugin
  (`/sap-docs-extract` parses Excel/Word/PDF specs); the core plugin works
  without it.
- **(Optional) SAP NCo 3.1** (32-bit, .NET 4.0, in the GAC): enables the RFC
  fast-paths and verification gates; downloaded from SAP with your own S-User
  (not redistributed here).

After Step 3 below, run **`/sap-doctor`** — it preflights every prerequisite
above (GUI scripting client+server, NCo/GAC, RFC connectivity, dev
environment) and prints an actionable FIX per failing check.

### Installation

**Step 1: Add the marketplace**

```bash
/plugin marketplace add https://github.com/sapdev-ai/sap-dev
```

**Step 2: Install plugins** — one plugin per `/plugin install` command

```bash
/plugin install sap-dev-core@sap-dev   # foundation (required)
/plugin install sap-gen-code@sap-dev   # spec -> ABAP generation (optional)
/plugin install sap-migrate@sap-dev    # S/4HANA custom-code migration (optional)
/plugin install sap-project@sap-dev    # functional / operations delivery, test data (optional)
```

> Claude Code does not currently accept several plugins in a single `/plugin install`,
> so run the lines individually.

> **Order matters**: install `sap-dev-core` FIRST. The other three plugins
> resolve its `shared/` scripts at runtime and fail with a path error when it
> is absent.

**Step 3: Login and bootstrap**

```bash
# Login + bootstrap
/sap-login --add → /sap-dev-init
```
***When asked for login information, provide all at once. You can refer to SAP Logon for details.***

When you use Application server to connect.
|Login info (Application server)|
|-------|
| sap_logon_description = |
| sap_application_server = |
| sap_system_number = |
| sap_client = |
| sap_user = |
| sap_password = |
| sap_language = |

|Sample Login info (Application server)|
|-------|
|sap_logon_description = S4H [S42022.xxxx.com] |
|sap_application_server = S42022.xxxx.com |
|sap_system_number = 00 |
|sap_client = 100 |
|sap_user = XXXXXX |
|sap_password = YYYYYYYY |
|sap_language = EN |


When you use Message server to connect.
|Login info (Message server)|
|-------|
|sap_logon_description = |
|sap_message_server = |
|sap_logon_group = |
|sap_system_id = |
|sap_client = |
|sap_user = |
|sap_password = |
|sap_language = |

|Sample Login info (Message server)|
|-------|
|sap_logon_description = S4D [msgsrv.xxxx.com] |
|sap_message_server = msgsrv.xxxx.com |
|sap_logon_group =  |
|sap_system_id = S4D |
|sap_client = 100 |
|sap_user = XXXXXX |
|sap_password = YYYYYYYY |
|sap_language = EN |


**Step 4: Use the skills**

Once installed, Claude Code automatically discovers and uses skills when relevant:

```bash
# Example 1: Login to SAP
User: "Log in to my SAP DEV system"
Claude: [Automatically uses sap-login skill]

# Example 2: Create a data element
User: "Create a new data element ZMAP_VAR in SAP"
Claude: [Automatically uses sap-se11 skill]

# Example 3: Deploy ABAP code
User: "Deploy this ABAP report to my SAP system"
Claude: [Uses sap-se38]
```

---

## Available Skills (123)

### Core Utilities & ABAP Workbench (`sap-dev-core`)

61 skills. Ships the `abap-developer` agent (build / fix / deploy).

| Skill | Description |
|-------|-------------|
| `sap-activate-object` | Activates an inactive SAP repository object; routes to SE38/SE37/SE24/SE11 by type and handles the inactive-objects worklist popup |
| `sap-api-advisor` | Turns a natural-language goal into a ranked list of BAPIs / RFC FMs / classes with released-state, full interfaces, docs, and a paste-ready snippet (hard no-smoke-call rule) — read-only |
| `sap-atc` | Runs ABAP Test Cockpit end-to-end as a quality gate against the customer brief's MAX_PRIORITY threshold (baselines + exemptions supported) |
| `sap-call-bdc` | Executes BDC sessions via RFC by replaying SHDB recordings through ABAP4_CALL_TRANSACTION |
| `sap-change-package` | Changes the package (TADIR-DEVCLASS) assignment of a repository object via Goto > Object Directory Entry |
| `sap-check-abap` | Validates ABAP source quality across all dimensions — naming, types, unused, SQL fields, CALL FUNCTION signatures (RFC), and compiler-level syntax (RFC) |
| `sap-check-fix` | Routes "check and fix" / "check" / "fix" requests for an existing SAP object to SE38, SE37, SE24, or SE11 by detected type |
| `sap-cmod` | Manages SAP Enhancement Projects via CMOD and edits exit includes via SE38 |
| `sap-compare` | Compares the same ABAP/DDIC object across two saved SAP systems (field-by-field for DDIC, source diff for programs/FMs) over RFC and summarizes each difference — read-only |
| `sap-dev-clean` | Conservative cleanup of the artefacts `/sap-dev-init` created, in reverse dependency order with per-step confirmation |
| `sap-dev-init` | Initializes the SAP development environment: transport request, package, function group, and utility program |
| `sap-dev-status` | Read-only status report on the `/sap-dev-init` artefacts (TR, package, function group, wrapper FM, utility program) |
| `sap-diagnose` | Incident-triage orchestrator: fans out across 8 read-only readers (built-in SM13 / SM12 / SLG1 / SM37 / tRFC-qRFC queues / OData gateway RFC readers + the `sap-idoc` and `sap-st22` readers), correlates the evidence into clusters, and ranks root-cause hypotheses — pure read-only. Run one reader standalone with `--reader <name>` |
| `sap-doctor` | Read-only environment preflight: diagnoses why skills fail BEFORE they run — GUI scripting, 32-bit PowerShell / NCo / config, RFC connectivity, client modifiability, authorizations, and dev-env artefacts, with a FIX per failure. Opt-in `--screens` group replays golden-screen baselines to catch control-ID drift |
| `sap-enhancement-advisor` | Finds the safest extension point for a behavior change and recommends the enhancement mechanism (BAdI / SMOD / user-exit) with transparent scoring — read-only |
| `sap-error-kb` | Curates the team frequently_errors knowledge base — the per-object store of recurring FM / method / codegen traps that `/sap-gen-abap` reads to steer generation; review and promote auto-recorded CANDIDATE rows — pure-local |
| `sap-evidence-pack` | Collects the artifacts other delivery-assurance skills registered into one audit-ready pack with an executive summary and an honest "Missing evidence" section — pure-local |
| `sap-explain-object` | Read-only comprehension aid for an existing object: acquires source, builds a structure + call map, optionally pulls callers, and emits an explanation dossier |
| `sap-file-transfer` | Transfers files between the local PC and the SAP application server (CG3Z upload / CG3Y download, text or binary, popup-guarded) and lists app-server directories headlessly over RFC |
| `sap-fix-abap` | Fixes issues found by `/sap-check-abap` — renames, unused-comment-out, syntax-safe rewrites, CALL FUNCTION param fixes, and a bounded AI syntax-fix loop |
| `sap-fix-incident` | Closes the loop from a `/sap-diagnose` root cause to a deployed, test-verified custom-code fix — reproduces the defect as a RED ABAP Unit test, patches, re-checks with `/sap-check-abap`, deploys in DEV behind a transport; gated, never touches standard code or production |
| `sap-forms` | Read-only forms suite: inventory of SmartForms / SAPscript / Adobe forms with NAST usage overlay, SmartForm XML + SAPscript export, offline explain into the docs pipeline, confirm-gated test print |
| `sap-function-group` | Full lifecycle for SAP function groups: check, create, activate, query, and delete |
| `sap-git` | Install-free, read-only git backend for ABAP: `snapshot` serializes a package/TR/object scope to disk in an abapGit-ish layout with TR-annotated commits; `diff` shows working-system-vs-last-snapshot |
| `sap-gui-inspect` | Inspects the active SAP GUI session structurally (dumps component IDs + properties: `tree`/`menu`/`type`/`id`/`wnd` modes) and/or visually (`screenshot` — composes every visible window into an annotated PNG). Absorbed the former `sap-gui-object-details` and `sap-gui-diagnose`. |
| `sap-gui-probe` | Drives a SAP transaction step by step against a natural-language scenario and emits a synthesized recording-style VBS; `--record` (Mode R) captures a flow by hand instead of driving it (replaces the retired `sap-gui-record`) |
| `sap-gui-skill-scaffold` | Authors a new mode-aware transaction skill from N natural-language scenarios — runs `/sap-gui-probe` per scenario, merges probe folders via cross-probe diff, emits a ready-to-test draft |
| `sap-impact-analysis` | Pre-change impact analysis from SAP's cross-reference index (where-used + forward deps + entry points + transport history) with a transparent LOW/MEDIUM/HIGH risk band — read-only |
| `sap-job` | Manages ABAP background jobs — schedule / list / status / log / spool / cancel / delete — via the RFC fast-path (`Z_RUN_REPORT` + TBTCO/TBTCP) with SM36/SM37 GUI fallback; schedule/cancel/delete confirm first |
| `sap-log-analyze` | Summarizes sap-dev JSONL log files: per-skill counts, success/fail rates, p50/p95 duration, top error classes |
| `sap-login` | Opens a SAP GUI connection and logs in via SAP GUI Scripting; also verifies SAP NCo 3.1 RFC connectivity |
| `sap-rfc-wrapper` | Reaches non-RFC-callable ABAP code in two modes: `fm` calls a non-RFC-enabled function module via the generic `Z_GENERIC_RFC_WRAPPER_TBL` wrapper; `class` generates + deploys a dedicated RFC wrapper FM for a class method. Absorbed the former `sap-rfc-wrapper-fm` and `sap-rfc-wrapper-class`. |
| `sap-run-abap-unit` | Runs ABAP Unit tests on a deployed program or class via SE38/SE24 and reports per-method pass/fail with a verdict gate (optional code coverage) |
| `sap-run-report` | Executes an ABAP report foreground (SA38) or background with a variant / ad-hoc values, captures the output (list or spool via `/sap-sp02`), and maintains variants — always confirms before running |
| `sap-scratch-run` | A write-run-inspect ABAP REPL: generates a read-only-guarded `$TMP` probe report, deploys, executes, captures the output, and auto-deletes with verified cleanup; `fm` calls a function module capturing outputs + runtime |
| `sap-se01` | Manages SAP transport requests via SE01 (create / release) with description rendering and confirmation prompts |
| `sap-se11` | Creates, updates, and deletes Dictionary objects (tables, views, data elements, structures, table types, type groups, domains, search helps, lock objects) |
| `sap-se14` | DB Utility: read-only RFC consistency check, save-data-only activate-and-adjust (the delete-data branch is structurally unreachable), and gated unlock/continue for terminated conversions |
| `sap-se16n` | Queries any SAP table via SE16N (+ SE16H aggregation) and downloads the result set as a tab-delimited file; snapshot/diff supported |
| `sap-se19` | Creates BAdI implementations via SE19 and deploys method source to the implementing class via SE24 |
| `sap-se21` | Creates, checks, or deletes SAP development packages via SE21 |
| `sap-se24` | Deploys, checks/fixes, changes properties of, and deletes ABAP classes and interfaces via SE24 |
| `sap-se37` | Deploys, checks/fixes, changes attributes of, reassigns, and deletes ABAP function modules via SE37 |
| `sap-se38` | Deploys, checks/fixes, changes attributes of, and deletes ABAP programs via SE38 |
| `sap-se41` | Deploys PF-STATUS (GUI status) definitions via SE41 |
| `sap-se51` | Deploys screen (dynpro) flow logic via SE51 |
| `sap-se54` | Generates a table maintenance dialog via SE54 |
| `sap-se91` | Manages SAP message classes and entries via SE91 |
| `sap-sm12` | Lock list with lock-age and owner-liveness columns; `release` deletes a lock only after an all-server owner-liveness gate + typed confirmation + authoritative re-read verify |
| `sap-snro` | Creates and maintains SAP Number Range Objects (NRO) via SNRO, including sub-object intervals |
| `sap-sp02` | Downloads a SAP spool request to a local text file via SP02 |
| `sap-sql-query` | Ad-hoc join/aggregate SQL over RFC through a one-time-deployed, governance-gated helper FM (whitelist grammar, in-FM authority checks, server-side row/time caps) → TSV with provenance |
| `sap-st22` | `/sap-diagnose` reader: ABAP short-dump (ST22 / SNAP) evidence with dump fingerprinting — read-only |
| `sap-stms` | Moves a released transport request through the landscape (DEV → QAS → PRD) and reads import status / return code via STMS. Modes: `status` / `logs` (read-only), `import` / `import-all` (write, gated — a PRODUCTION target needs a typed-SID confirmation) |
| `sap-trace` | Analyzes an already-recorded SAP performance trace (ST05 / SAT or an imported file), ranks hotspots, flags anti-patterns, and proposes fixes — read-only |
| `sap-transport-readiness` | Release gate for a transport request: RFC structural checks (unreleased tasks, inactive objects, local objects) rolled up to GO / GO_WITH_WARNINGS / NO-GO — read-only |
| `sap-transport-request` | Single entry point that resolves a modifiable SAP transport request per the `way_to_get_transport_request` policy |
| `sap-update-addon` | Inserts, updates, or deletes records in SAP add-on tables (Y/Z prefix) via SM30, SE16, or `ZCMRUPDATE_ADDON_TABLE` |
| `sap-version-history` | The same-system time axis: list version directories, diff any two versions (or active-vs-last-released), and blame over a capped version window — read-only, pure RFC |
| `sap-vofm` | VOFM routine registry (read-only v1): list / check / resolve registered routines per group and detect registered-but-not-wired gaps in the frame include |
| `sap-where-used-list` | Runs SAP's Where-Used List for any repository object across SE11, SE38, SE37, SE24, and SE91 |

### Code Generation & Quality (`sap-gen-code`)

12 skills. (`sap-check-abap` / `sap-fix-abap` — validate / auto-fix ABAP quality — live in `sap-dev-core`.)

| Skill | Description |
|-------|-------------|
| `sap-docs-check` | Validates an extracted spec before ABAP generation across two dimensions: `ddic` (naming, type validity, domain/DTEL/table cross-references) and `process` (process-logic ambiguity + inconsistencies). Runs both by default; `--dimension ddic\|process` forces one. Absorbed the former `sap-docs-check-ddic` and `sap-docs-check-process`. |
| `sap-docs-convert` | Applies customer-specific normalisation rules (field rename, type rename, flag mapping, schema migration) to extracted spec files |
| `sap-docs-estimate` | Deterministic effort estimator over spec work folders and migration triage ledgers → a transparent complexity class mapped to wide effort bands with named drivers, an assumptions register, and a falsifiable record-actuals ledger — pure-local |
| `sap-docs-extract` | Reads a SAP design document (Excel/Word/PDF) and extracts structured info into separate text files by section |
| `sap-docs-layout` | Edits the structural layout of a SAP design spec template (.xlsx) via its `(Meta) Layout` sheet |
| `sap-gen-abap` | Generates ABAP source code (dialog/module pool, report, function module/RFC) from a process text file |
| `sap-gen-abap-unit` | Generates ABAP Unit tests for an existing object (class / FM / report) and closes the loop on a live system — pre-check, deploy, activate, run with coverage, fix, repeat until green (bounded) |
| `sap-gen-cds` | Generates an ABAP CDS view from a spec or natural-language description and deploys it WITHOUT ADT via the RFC installer FM `Z_CDS_DDL_INSTALL` — classic DDL on SAP_BASIS 7.50–7.54, view entities on 7.55+ |
| `sap-gen-idoc-handler` | Generates a correct inbound IDoc processing FM from a mapping spec + live IDoc-type metadata (fixed EDIDC/EDIDD/BDIDOCSTAT signature, 53/51 status protocol, the spec'd BAPI call) plus a seeded ABAP Unit test and a read-only `verify-wiring` mode |
| `sap-gen-rap` | Renders a complete managed RAP business object from a base table (root + projection CDS, BDEF pair, behavior pool, SRVD — dialect-forked 7.54 / 7.55+), packages it as an abapGit repo for a no-ADT import, and verifies every artifact via RFC re-reads — S/4-only |
| `sap-gen-test-plan` | Turns a spec work folder or `/sap-explain-object` dossier into a reviewer-ready functional test plan (cases per process step, every error message mapped to a provoking case, traceability matrix); optional read-only RFC validation pass |
| `sap-review-abap` | AI semantic + security code review for an existing ABAP object or local `.abap` file — line-cited findings across security, correctness, performance, and maintainability, gated via the customer brief |

### S/4HANA Custom-Code Migration + Clean Core (`sap-migrate`)

10 skills. Companion to `sap-dev-core` (install that first). Ships the `cc-migration-engineer` agent.

| Skill | Description |
|-------|-------------|
| `sap-cc-campaign` | Owns the migration campaign workspace + state ledger and orchestrates the engine (`init` / `status` / `next` / dashboard) |
| `sap-cc-inventory` | Enumerates and classifies the custom (Z/Y) repository objects in scope from TADIR/TRDIR over read-only RFC — pure analysis |
| `sap-cc-usage` | Overlays runtime usage data onto the inventory to split objects into REMEDIATE / DECOMMISSION / REVIEW (the "% retired" number) |
| `sap-cc-analyze` | Runs the S/4HANA-readiness ATC over the REMEDIATE objects (delegates to `/sap-atc`) and captures per-finding results |
| `sap-cc-triage` | Classifies each ATC finding into a remediation pattern + tier (R1 mechanical … R4 redesign) via the Simplification Knowledge Pack. `--learn` runs the knowledge-pack flywheel: learns real ATC message ids from a triaged campaign and feeds them back so future triage matches more (absorbed the former `sap-cc-learn`) |
| `sap-cc-remediate` | Remediates triaged R1 objects on the sandbox only, after a mandatory dry-run review — the one sap-migrate skill that writes to SAP |
| `sap-cc-decommission` | EXECUTES the retirement of unused custom objects a campaign flagged — physically deletes behind a hard signed gate and a per-object safety chain (`plan` builds the worklist, `apply` deletes); `/sap-cc-usage` only flags |
| `sap-cc-cloud-readiness` | Classifies a campaign's REMEDIATE objects by distance from ABAP Cloud — TIER_1_READY / TIER_2_WRAPPABLE / TIER_3_CLASSIC — via a versioned forbidden-statement scan + cloudification-repository lookup, with honest dynamic-call blind-spot flags — S/4-only, read-only |
| `sap-exit-modernize` | Orchestrates single-function-exit modernization to a BAdI (analyze / translate / deploy / verify): ranked targets from `/sap-enhancement-advisor`, AI translation with load-bearing MANUAL markers, all writes delegated + gated; the old CMOD project is never auto-deactivated |
| `sap-spau-triage` | Read-only SPDD/SPAU triage: builds the adjustment worklist from SMODILOG, enriches with version evidence + SAP Note status, and deterministically classifies each entry adopt / reset-candidate / re-implement / unclear with cited rationale |

### Delivery & Operations (`sap-project`)

40 skills for functional consultants, security, release, AMS/ops, and test teams.
Companion to `sap-dev-core` (install that first). Ships the `sap-consultant` agent
(incident / health / access / release / test / config lanes). Successor home of the
retired `sap-tcd` plugin — `sap-bp` / `sap-mm01` / `sap-va01` moved here unchanged.

| Skill | Description |
|-------|-------------|
| `sap-auth-diagnose` | Diagnoses authorization failures: `su53` scrapes the user's SU53 and joins failures against role/profile data into a classified diagnosis + fix proposal; `trace` runs a confirm-gated STAUTHTRACE bracket (S/4-only) with a minimal-authorization-set summary |
| `sap-auth-requirements` | Derives the authorization requirements of custom code (explicit + implicit AUTHORITY-CHECK surface, validated against SU21/SU24 data) into a CONFIRMED/INFERRED matrix + SU24 draft; `su24-audit` compares Z-tcode proposals against SAP defaults — read-only |
| `sap-bp` | Manages SAP Business Partners (Organization type) via the BP transaction |
| `sap-change-history` | Change-document forensics over CDHDR/CDPOS: resolves a business object / user / time window, decodes field-level old→new values with DDIC texts, and renders an AI timeline — read-only, RFC-only |
| `sap-config-compare` | Row-level diff of one customizing table or view between two saved systems (view resolved via DDIC, keyed diff with ignorable volatile columns) plus an AI functional summary — read-only |
| `sap-cutover-runbook` | Tracker-first cutover runbook: parses the customer runbook into a crash-safe append-only ledger, stamps start/done events with machine-read RFC evidence, renders delta-to-plan + critical path, and composes an advisory go/no-go checkpoint |
| `sap-data-volume` | Table-growth ranking (row counts + a local snapshot store for trends, Z-housekeeping flags) and archivability mapping (archive objects, ADMI run history, TAANA age profiles) — read-only |
| `sap-delivery-report` | Offline-first weekly delivery status report from the artifact index, build KPIs, and one TR-pipeline RFC read — deterministic RAG per a shipped rules table; every claim cites an artifact or is marked INFERRED |
| `sap-doc-flow` | Walks an O2C document flow both directions from any SD document key (VBFA + release-aware status decode), follows invoice→FI, and narrates where the flow stalled — read-only |
| `sap-explain-role` | PFCG role dossier: tcodes, authorization values, holders, composite decomposition, critical-grant matching + an executive summary — read-only |
| `sap-fi-post` | Posts G/L documents and vendor/customer invoices from a definition file via a mandatory `BAPI_ACC_DOCUMENT_CHECK` dry-run, then confirm-gated POST + COMMIT, verified by BKPF/BSEG re-reads |
| `sap-fiori-flp-audit` | Read-only RFC audit of classic Fiori launchpad content on S/4: what a user sees and why, broken/orphaned target mappings, unassigned catalogs |
| `sap-gateway-service` | Per-service OData verdict from hub + backend catalogs (`status`) and /IWFND error-log analysis with AI cause-mapping (`errors`) — read-only; refuses loud on non-Gateway systems |
| `sap-golden-master` | Golden-master regression for report output and table state: capture a normalized baseline, re-run identically, diff, and AI-triage every hunk into EXPECTED vs REGRESSION with a GO / REGRESSION verdict |
| `sap-health-check` | Morning health sweep (stuck IDocs, tRFC/qRFC, spool, failed jobs, dumps) with a persisted per-system baseline classifying findings NEW vs known-recurring — read-only |
| `sap-idoc` | Finds, decodes, and triages IDocs (EDIDC/EDIDS + typed segment decode), reprocesses behind a confirm gate via the standard reports with authoritative re-read verification; also the `/sap-diagnose` interface reader |
| `sap-img-find` | Natural-language search over a harvested IMG activity index → top hits with the full SPRO path, maintenance objects, and affected tables; confirm-gated launch of the chosen activity |
| `sap-interface-inventory` | Enumerates six interface sources (RFC destinations, WE20 partner profiles, Z RFC-FMs, OData catalog, proxies, jobs) into a register with CONFIRMED/INFERRED flags; `doc` reverse-engineers per-interface specs |
| `sap-mass-load` | CSV/XLSX mass loader targeting ONE explicit backend per run (a named BAPI over RFC, or an SHDB recording via BDC) with operator-approved mapping, RFC pre-validation, a mandatory dry-run, a typed confirm gate, and a per-row resume ledger; refuses production clients outright |
| `sap-mm01` | Manages SAP material masters via MM01/MM02/MM03 (create / update / check) |
| `sap-note-status` | Answers "is Note N implemented, where, and will it clash with our mods?" across every saved profile — CWB note status, component levels, SMODILOG collision flags — read-only |
| `sap-output-diagnose` | Diagnoses classic NAST output failures (SD billing / MM PO): walks the determination procedure, rebuilds each access's condition key, and ranks verdicts (NO_RECORD with the exact missing key / PROCESSING_FAILED / REQUIREMENT_BLOCKED); confirm-gated re-issue |
| `sap-pfcg` | PFCG role automation: read-only `show` plus confirm-gated create / add-remove-tcodes / generate / assign — every write verified by an authoritative AGR_* re-read; auth-tree edits stay recording-gated |
| `sap-refresh-verify` | Post-refresh audit of a QA/sandbox copy against a landscape-expectations config (logical system, PRD-pointing RFC destinations, released jobs, queue backlogs, lock policy) → doctor-style CHECK/FIX lines + a GO/NO_GO sign-off |
| `sap-release-notes` | Builds a CAB-ready change pack for a TR list / date range (E070/E071 joined to TADIR business-area grouping, reused readiness/impact verdicts) with a grounded cab_pack.md + changes.tsv — read-only |
| `sap-retrofit` | Detect-and-classify retrofit engine for dual-track landscapes: harvests released maintenance-line TRs, classifies each object GREEN/YELLOW/RED via cross-system diff + change evidence, auto-applies GREEN behind gates, drafts YELLOW merges (never deployed without typed confirmation) |
| `sap-rfc-monitor` | tRFC/qRFC queue snapshot with AI cluster classification (`queues`), confirm-gated retry via RSARFCEX (`retry`), and an RFCDES destination register with bulk connectivity test (`destinations`) |
| `sap-sm30` | Standard-customizing view maintenance via SM30: DDIC-resolve, RFC pre-read, confirm-gated preview diff, a generic table-control driver with Customizing-TR resolution, and an authoritative RFC re-read verify |
| `sap-sm35` | Batch-input session operations: list sessions via APQI, confirm-gated background processing via RSBDCSUB with poll-verification, log retrieval, and AI failure clustering into a triage report |
| `sap-sost` | SAPconnect outbound-queue triage: `list`/`trace` with error clustering, read-only `config-check` of SCOT routing + the send job, and a confirm-gated GUI resend with re-read verification |
| `sap-su01` | DEV-only test-user lifecycle (create / show / assign / lock / reset-password / delete / cleanup) on released `BAPI_USER_*` calls; generated passwords DPAPI-encrypted in a per-system registry; every write re-verified |
| `sap-suim` | Pure-RFC authorization reporting: users-by-role/tcode/auth-value, role-vs-role and user-vs-user effective diffs, cross-system same-role diff, and a critical-auth report — every report with an explicit PROFILE_COVERAGE disclosure — read-only |
| `sap-tcd-chain` | Headless BAPI-only O2C chain (order → delivery → goods issue → billing) with a VBFA verify-read after every step, stop-on-first-failure, and a persistent chain manifest |
| `sap-test-replay` | Compiles a recorded linear scenario into GUI segments run by one generic interpreter with three checkpoint types (field-by-control-ID, status-bar message, post-step RFC re-read) and strict PASS / FAIL / REPLAY_ERROR verdicts + screenshots on failure |
| `sap-translate` | `harvest` collects all translatable short texts of a TR/object list (text pools, T100, DDIC labels) into a review TSV with AI translations under hard length limits; confirm-gated `apply` writes back via the SE63 engine FMs with re-read verification |
| `sap-transport-copies` | GUI-first Transport-of-Copies pipeline: builds a type-T request from source TRs' object lists, hard-gates release on an RFC-verified object union, and delegates release/import |
| `sap-transport-sequencer` | Orders a TR list by object-overlap constraints + release timestamps and cross-checks the target system for unimported predecessors (`sequence`); `freeze-audit` audits TRs released/changed inside a policy-defined freeze window — read-only |
| `sap-user-guide` | Composes end-user training guides / UAT scripts from `/sap-gui-probe` run folders with authoritative field labels + F1 docs over RFC; optional confirm-gated step-by-step replay with per-step screenshots |
| `sap-va01` | Manages SAP sales orders via VA01/VA02/VA03 (create / update / check) |
| `sap-workflow` | Business Workflow runtime: `diagnose` stuck/errored workitems with agent-determination + binding failure decode, `explain` a WS/TS/WI, and confirm-gated `act` (restart / logical-delete / forward) via `SAP_WAPI_*` with authoritative re-reads |
