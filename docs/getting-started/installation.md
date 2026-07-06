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
/plugin install sap-tcd@sap-dev        # BP / MM01 / VA01 automation (optional)
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

## Available Skills (67)

### Core Utilities & ABAP Workbench (`sap-dev-core`)

| Skill | Description |
|-------|-------------|
| `sap-activate-object` | Activates an inactive SAP repository object; routes to SE38/SE37/SE24/SE11 by type and handles the inactive-objects worklist popup |
| `sap-atc` | Runs ABAP Test Cockpit end-to-end as a quality gate against the customer brief's MAX_PRIORITY threshold |
| `sap-call-bdc` | Executes BDC sessions via RFC by replaying SHDB recordings through ABAP4_CALL_TRANSACTION |
| `sap-change-package` | Changes the package (TADIR-DEVCLASS) assignment of a repository object via Goto > Object Directory Entry |
| `sap-check-fix` | Routes "check and fix" / "check" / "fix" requests for an existing SAP object to SE38, SE37, SE24, or SE11 by detected type |
| `sap-cmod` | Manages SAP Enhancement Projects via CMOD and edits exit includes via SE38 |
| `sap-compare` | Compares the same ABAP/DDIC object across two saved SAP systems (field-by-field for DDIC, source diff for programs/FMs) over RFC and summarizes each difference — read-only |
| `sap-dev-clean` | Conservative cleanup of the artefacts `/sap-dev-init` created, in reverse dependency order with per-step confirmation |
| `sap-dev-init` | Initializes the SAP development environment: transport request, package, function group, and utility program |
| `sap-dev-status` | Read-only status report on the `/sap-dev-init` artefacts (TR, package, function group, wrapper FM, utility program) |
| `sap-diagnose` | Incident-triage orchestrator: fans out across the read-only readers (its built-in SM13 / SM12 / SLG1 / SM37 RFC readers + the `sap-st22` GUI dump reader), correlates the evidence into clusters, and ranks root-cause hypotheses — pure read-only. Run one reader standalone with `--reader <name>` |
| `sap-doctor` | Read-only environment preflight: diagnoses why skills fail BEFORE they run — GUI scripting, 32-bit PowerShell / NCo / config, RFC connectivity, client modifiability, authorizations, and dev-env artefacts, with a FIX per failure. Opt-in `--screens` group replays golden-screen baselines to catch control-ID drift |
| `sap-enhancement-advisor` | Finds the safest extension point for a behavior change and recommends the enhancement mechanism (BAdI / SMOD / user-exit) with transparent scoring — read-only |
| `sap-error-kb` | Curates the team frequently_errors knowledge base — the per-object store of recurring FM / method / codegen traps that `/sap-gen-abap` reads to steer generation; review and promote auto-recorded CANDIDATE rows — pure-local |
| `sap-evidence-pack` | Collects the artifacts other delivery-assurance skills registered into one audit-ready pack with an executive summary and an honest "Missing evidence" section — pure-local |
| `sap-explain-object` | Read-only comprehension aid for an existing object: acquires source, builds a structure + call map, optionally pulls callers, and emits an explanation dossier |
| `sap-fix-incident` | Closes the loop from a `/sap-diagnose` root cause to a deployed, test-verified custom-code fix — reproduces the defect as a RED ABAP Unit test, patches, re-checks with `/sap-check-abap`, deploys in DEV behind a transport; gated, never touches standard code or production |
| `sap-function-group` | Full lifecycle for SAP function groups: check, create, activate, query, and delete |
| `sap-gui-inspect` | Inspects the active SAP GUI session structurally (dumps component IDs + properties: `tree`/`menu`/`type`/`id`/`wnd` modes) and/or visually (`screenshot` — composes every visible window into an annotated PNG). Absorbed the former `sap-gui-object-details` and `sap-gui-diagnose`. |
| `sap-gui-probe` | Drives a SAP transaction step by step against a natural-language scenario and emits a synthesized recording-style VBS; `--record` (Mode R) captures a flow by hand instead of driving it (replaces the retired `sap-gui-record`) |
| `sap-gui-skill-scaffold` | Authors a new mode-aware transaction skill from N natural-language scenarios — runs `/sap-gui-probe` per scenario, merges probe folders via cross-probe diff, emits a ready-to-test draft |
| `sap-impact-analysis` | Pre-change impact analysis from SAP's cross-reference index (where-used + forward deps + entry points + transport history) with a transparent LOW/MEDIUM/HIGH risk band — read-only |
| `sap-log-analyze` | Summarizes sap-dev JSONL log files: per-skill counts, success/fail rates, p50/p95 duration, top error classes |
| `sap-login` | Opens a SAP GUI connection and logs in via SAP GUI Scripting; also verifies SAP NCo 3.1 RFC connectivity |
| `sap-rfc-wrapper` | Reaches non-RFC-callable ABAP code in two modes: `fm` calls a non-RFC-enabled function module via the generic `Z_GENERIC_RFC_WRAPPER_TBL` wrapper; `class` generates + deploys a dedicated RFC wrapper FM for a class method. Absorbed the former `sap-rfc-wrapper-fm` and `sap-rfc-wrapper-class`. |
| `sap-run-abap-unit` | Runs ABAP Unit tests on a deployed program or class via SE38/SE24 and reports per-method pass/fail with a verdict gate (optional code coverage) |
| `sap-se01` | Manages SAP transport requests via SE01 (create / release) with description rendering and confirmation prompts |
| `sap-se11` | Creates, updates, and deletes Dictionary objects (tables, views, data elements, structures, table types, type groups, domains, search helps, lock objects) |
| `sap-se16n` | Queries any SAP table via SE16N and downloads the result set as a tab-delimited file |
| `sap-se19` | Creates BAdI implementations via SE19 and deploys method source to the implementing class via SE24 |
| `sap-se21` | Creates, checks, or deletes SAP development packages via SE21 |
| `sap-se24` | Deploys, checks/fixes, changes properties of, and deletes ABAP classes and interfaces via SE24 |
| `sap-se37` | Deploys, checks/fixes, changes attributes of, reassigns, and deletes ABAP function modules via SE37 |
| `sap-se38` | Deploys, checks/fixes, changes attributes of, and deletes ABAP programs via SE38 |
| `sap-se41` | Deploys PF-STATUS (GUI status) definitions via SE41 |
| `sap-se51` | Deploys screen (dynpro) flow logic via SE51 |
| `sap-se54` | Generates a table maintenance dialog via SE54 |
| `sap-se91` | Manages SAP message classes and entries via SE91 |
| `sap-snro` | Creates and maintains SAP Number Range Objects (NRO) via SNRO, including sub-object intervals |
| `sap-sp02` | Downloads a SAP spool request to a local text file via SP02 |
| `sap-st22` | `/sap-diagnose` reader: ABAP short-dump (ST22 / SNAP) evidence via GUI scripting — read-only |
| `sap-stms` | Moves a released transport request through the landscape (DEV → QAS → PRD) and reads import status / return code via STMS. Modes: `status` / `logs` (read-only), `import` / `import-all` (write, gated — a PRODUCTION target needs a typed-SID confirmation) |
| `sap-trace` | Analyzes an already-recorded SAP performance trace (ST05 / SAT or an imported file), ranks hotspots, flags anti-patterns, and proposes fixes — read-only |
| `sap-transport-readiness` | Release gate for a transport request: RFC structural checks (unreleased tasks, inactive objects, local objects) rolled up to GO / GO_WITH_WARNINGS / NO-GO — read-only |
| `sap-transport-request` | Single entry point that resolves a modifiable SAP transport request per the `way_to_get_transport_request` policy |
| `sap-update-addon` | Inserts, updates, or deletes records in SAP add-on tables (Y/Z prefix) via SM30, SE16, or `ZCMRUPDATE_ADDON_TABLE` |
| `sap-where-used-list` | Runs SAP's Where-Used List for any repository object across SE11, SE38, SE37, SE24, and SE91 |

### Code Generation & Quality (`sap-gen-code`)

| Skill | Description |
|-------|-------------|
| `sap-check-abap` *(moved to sap-dev-core)* | Validates ABAP source quality across all dimensions — naming, types, unused, SQL fields, CALL FUNCTION signatures (RFC), and compiler-level syntax (RFC). Absorbed the former `sap-check-fm`. |
| `sap-docs-check` | Validates an extracted spec before ABAP generation across two dimensions: `ddic` (naming, type validity, domain/DTEL/table cross-references) and `process` (process-logic ambiguity + inconsistencies). Runs both by default; `--dimension ddic\|process` forces one. Absorbed the former `sap-docs-check-ddic` and `sap-docs-check-process`. |
| `sap-docs-convert` | Applies customer-specific normalisation rules (field rename, type rename, flag mapping, schema migration) to extracted spec files |
| `sap-docs-extract` | Reads a SAP design document (Excel/Word/PDF) and extracts structured info into separate text files by section |
| `sap-docs-layout` | Edits the structural layout of a SAP design spec template (.xlsx) via its `(Meta) Layout` sheet |
| `sap-fix-abap` *(moved to sap-dev-core)* | Fixes issues found by `/sap-check-abap` — renames, unused-comment-out, syntax-safe rewrites, CALL FUNCTION param fixes (absorbed `sap-fix-fm`), and a bounded AI syntax-fix loop |
| `sap-gen-abap` | Generates ABAP source code (dialog/module pool, report, function module/RFC) from a process text file |
| `sap-gen-abap-unit` | Generates ABAP Unit tests for an existing object (class / FM / report) and closes the loop on a live system — pre-check, deploy, activate, run with coverage, fix, repeat until green (bounded) |
| `sap-gen-cds` | Generates an ABAP CDS view from a spec or natural-language description and deploys it WITHOUT ADT via the RFC installer FM `Z_CDS_DDL_INSTALL` — classic DDL on SAP_BASIS 7.50–7.54, view entities on 7.55+ |
| `sap-review-abap` | AI semantic + security code review for an existing ABAP object or local `.abap` file — line-cited findings across security, correctness, performance, and maintainability, gated via the customer brief |

### S/4HANA Custom-Code Migration (`sap-migrate`)

Companion to `sap-dev-core` (install that first). Ships the `cc-migration-engineer` agent.

| Skill | Description |
|-------|-------------|
| `sap-cc-campaign` | Owns the migration campaign workspace + state ledger and orchestrates the engine (`init` / `status` / `next` / dashboard) |
| `sap-cc-inventory` | Enumerates and classifies the custom (Z/Y) repository objects in scope from TADIR/TRDIR over read-only RFC — pure analysis |
| `sap-cc-usage` | Overlays runtime usage data onto the inventory to split objects into REMEDIATE / DECOMMISSION / REVIEW (the "% retired" number) |
| `sap-cc-analyze` | Runs the S/4HANA-readiness ATC over the REMEDIATE objects (delegates to `/sap-atc`) and captures per-finding results |
| `sap-cc-triage` | Classifies each ATC finding into a remediation pattern + tier (R1 mechanical … R4 redesign) via the Simplification Knowledge Pack. `--learn` runs the knowledge-pack flywheel: learns real ATC message ids from a triaged campaign and feeds them back so future triage matches more (absorbed the former `sap-cc-learn`) |
| `sap-cc-remediate` | Remediates triaged R1 objects on the sandbox only, after a mandatory dry-run review — the one sap-migrate skill that writes to SAP |
| `sap-cc-decommission` | EXECUTES the retirement of unused custom objects a campaign flagged — physically deletes behind a hard signed gate and a per-object safety chain (`plan` builds the worklist, `apply` deletes); `/sap-cc-usage` only flags |

### Business Process Automation (`sap-tcd`)

| Skill | Description |
|-------|-------------|
| `sap-bp` | Manages SAP Business Partners (Organization type) via the BP transaction |
| `sap-mm01` | Manages SAP material masters via MM01/MM02/MM03 (create / update / check) |
| `sap-va01` | Manages SAP sales orders via VA01/VA02/VA03 (create / update / check) |
