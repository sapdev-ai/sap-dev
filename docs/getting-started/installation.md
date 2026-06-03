# SAP Dev Marketplace

Welcome to the **sap-dev** marketplace - a curated collection of production-tested SAP skills for Claude Code CLI.

## Quick Start

### Prerequisites
- **SAP GUI for Windows**: Required for all GUI Scripting skills.
- **SAP GUI Scripting**: Must be enabled on both client and server sides.
- **Python 3.10+**: Required for the `sap-gen-code` plugin.
- **Windows OS**: Required for DPAPI-encrypted credential storage.

### Installation

**Step 1: Add the marketplace**

```bash
/plugin marketplace add https://github.com/sapdev-ai/sap-dev
```

**Step 2: Install plugins**

```bash
# Install all core plugins
/plugin install sap-dev-core@sap-dev sap-gen-code@sap-dev sap-migrate@sap-dev sap-tcd@sap-dev
```

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

## Available Skills (70)

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
| `sap-diagnose` | Incident-triage orchestrator: fans out across the read-only readers (ST22 / SM13 / SM12 / SLG1 / SM37), correlates the evidence into clusters, and ranks root-cause hypotheses — pure read-only |
| `sap-enhancement-advisor` | Finds the safest extension point for a behavior change and recommends the enhancement mechanism (BAdI / SMOD / user-exit) with transparent scoring — read-only |
| `sap-evidence-pack` | Collects the artifacts other delivery-assurance skills registered into one audit-ready pack with an executive summary and an honest "Missing evidence" section — pure-local |
| `sap-explain-object` | Read-only comprehension aid for an existing object: acquires source, builds a structure + call map, optionally pulls callers, and emits an explanation dossier |
| `sap-function-group` | Full lifecycle for SAP function groups: check, create, activate, query, and delete |
| `sap-gui-diagnose` | Visual triage for stuck SAP GUI scripts — composes a screenshot of every visible window into an annotated PNG |
| `sap-gui-object-details` | Inspects components in the active SAP GUI session and dumps their IDs and properties |
| `sap-gui-probe` | Drives a SAP transaction step by step against a natural-language scenario and emits a synthesized recording-style VBS |
| `sap-gui-record` | Guides recording of SAP GUI interactions and extracts component IDs, actions, and field names from the VBS |
| `sap-gui-skill-scaffold` | Authors a new mode-aware transaction skill from N natural-language scenarios — runs `/sap-gui-probe` per scenario, merges probe folders via cross-probe diff, emits a ready-to-test draft |
| `sap-impact-analysis` | Pre-change impact analysis from SAP's cross-reference index (where-used + forward deps + entry points + transport history) with a transparent LOW/MEDIUM/HIGH risk band — read-only |
| `sap-log-analyze` | Summarizes sap-dev JSONL log files: per-skill counts, success/fail rates, p50/p95 duration, top error classes |
| `sap-login` | Opens a SAP GUI connection and logs in via SAP GUI Scripting; also verifies SAP NCo 3.1 RFC connectivity |
| `sap-rfc-wrapper-class` | Generates an RFC wrapper function module for a non-RFC-callable ABAP class method |
| `sap-rfc-wrapper-fm` | Calls a non-RFC-enabled SAP function module via the generic `Z_GENERIC_RFC_WRAPPER_TBL` wrapper |
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
| `sap-slg1` | `/sap-diagnose` reader: application-log (SLG1 / BALHDR) evidence over RFC — read-only |
| `sap-sm12` | `/sap-diagnose` reader: lock-entry (SM12) evidence via `ENQUEUE_READ` — read-only |
| `sap-sm13` | `/sap-diagnose` reader: update-task failure (SM13 / VBHDR + VBERROR) evidence over RFC — read-only |
| `sap-sm37` | `/sap-diagnose` reader: background-job (SM37 / TBTCO) evidence over RFC, flagging aborted jobs — read-only |
| `sap-snro` | Creates and maintains SAP Number Range Objects (NRO) via SNRO, including sub-object intervals |
| `sap-sp02` | Downloads a SAP spool request to a local text file via SP02 |
| `sap-st22` | `/sap-diagnose` reader: ABAP short-dump (ST22 / SNAP) evidence via GUI scripting — read-only |
| `sap-trace` | Analyzes an already-recorded SAP performance trace (ST05 / SAT or an imported file), ranks hotspots, flags anti-patterns, and proposes fixes — read-only |
| `sap-transport-readiness` | Release gate for a transport request: RFC structural checks (unreleased tasks, inactive objects, local objects) rolled up to GO / GO_WITH_WARNINGS / NO-GO — read-only |
| `sap-transport-request` | Single entry point that resolves a modifiable SAP transport request per the `way_to_get_transport_request` policy |
| `sap-update-addon` | Inserts, updates, or deletes records in SAP add-on tables (Y/Z prefix) via SM30, SE16, or `ZCMRUPDATE_ADDON_TABLE` |
| `sap-where-used-list` | Runs SAP's Where-Used List for any repository object across SE11, SE38, SE37, SE24, and SE91 |

### Code Generation & Quality (`sap-gen-code`)

| Skill | Description |
|-------|-------------|
| `sap-check-abap` | Validates ABAP source code quality before deployment (naming, types, unused variables, SQL field validation) |
| `sap-check-fm` | Validates ABAP `CALL FUNCTION` statements against actual FM parameter definitions retrieved via RFC |
| `sap-docs-check-ddic` | Validates DDIC objects extracted from a design document (naming, type validity, domain/DTEL/table cross-references) |
| `sap-docs-check-process` | Validates the process logic text file before ABAP code generation; flags ambiguity and inconsistencies |
| `sap-docs-convert` | Applies customer-specific normalisation rules (field rename, type rename, flag mapping, schema migration) to extracted spec files |
| `sap-docs-extract` | Reads a SAP design document (Excel/Word/PDF) and extracts structured info into separate text files by section |
| `sap-docs-layout` | Edits the structural layout of a SAP design spec template (.xlsx) via its `(Meta) Layout` sheet |
| `sap-fix-abap` | Fixes ABAP source code issues found by `/sap-check-abap` (renames violations, comments out unused variables) |
| `sap-fix-fm` | Fixes ABAP `CALL FUNCTION` parameter issues found by `/sap-check-fm` |
| `sap-gen-abap` | Generates ABAP source code (dialog/module pool, report, function module/RFC) from a process text file |

### S/4HANA Custom-Code Migration (`sap-migrate`)

Companion to `sap-dev-core` (install that first). Ships the `cc-migration-engineer` agent.

| Skill | Description |
|-------|-------------|
| `sap-cc-campaign` | Owns the migration campaign workspace + state ledger and orchestrates the engine (`init` / `status` / `next` / dashboard) |
| `sap-cc-inventory` | Enumerates and classifies the custom (Z/Y) repository objects in scope from TADIR/TRDIR over read-only RFC — pure analysis |
| `sap-cc-usage` | Overlays runtime usage data onto the inventory to split objects into REMEDIATE / DECOMMISSION / REVIEW (the "% retired" number) |
| `sap-cc-analyze` | Runs the S/4HANA-readiness ATC over the REMEDIATE objects (delegates to `/sap-atc`) and captures per-finding results |
| `sap-cc-triage` | Classifies each ATC finding into a remediation pattern + tier (R1 mechanical … R4 redesign) via the Simplification Knowledge Pack |
| `sap-cc-remediate` | Remediates triaged R1 objects on the sandbox only, after a mandatory dry-run review — the one sap-migrate skill that writes to SAP |
| `sap-cc-learn` | Knowledge-pack flywheel: learns real ATC message ids from a triaged campaign and feeds them back so future triage matches more |

### Business Process Automation (`sap-tcd`)

| Skill | Description |
|-------|-------------|
| `sap-bp` | Manages SAP Business Partners (Organization type) via the BP transaction |
| `sap-mm01` | Manages SAP material masters via MM01/MM02/MM03 (create / update / check) |
| `sap-va01` | Manages SAP sales orders via VA01/VA02/VA03 (create / update / check) |
