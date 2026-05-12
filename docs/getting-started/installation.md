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
/plugin install sap-dev-core@sap-dev sap-gen-code@sap-dev sap-tcd@sap-dev
```

**Step 3: Use the skills**

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

## Available Skills (49)

### Core Utilities & ABAP Workbench (`sap-dev-core`)

| Skill | Description |
|-------|-------------|
| `sap-activate-object` | Activates an inactive SAP repository object; routes to SE38/SE37/SE24/SE11 by type and handles the inactive-objects worklist popup |
| `sap-atc` | Runs ABAP Test Cockpit end-to-end as a quality gate against the customer brief's MAX_PRIORITY threshold |
| `sap-call-bdc` | Executes BDC sessions via RFC by replaying SHDB recordings through ABAP4_CALL_TRANSACTION |
| `sap-change-package` | Changes the package (TADIR-DEVCLASS) assignment of a repository object via Goto > Object Directory Entry |
| `sap-check-fix` | Routes "check and fix" / "check" / "fix" requests for an existing SAP object to SE38, SE37, SE24, or SE11 by detected type |
| `sap-cmod` | Manages SAP Enhancement Projects via CMOD and edits exit includes via SE38 |
| `sap-dev-clean` | Conservative cleanup of the artefacts `/sap-dev-init` created, in reverse dependency order with per-step confirmation |
| `sap-dev-init` | Initializes the SAP development environment: transport request, package, function group, and utility program |
| `sap-dev-status` | Read-only status report on the `/sap-dev-init` artefacts (TR, package, function group, wrapper FM, utility program) |
| `sap-function-group` | Full lifecycle for SAP function groups: check, create, activate, query, and delete |
| `sap-gui-diagnose` | Visual triage for stuck SAP GUI scripts — composes a screenshot of every visible window into an annotated PNG |
| `sap-gui-object-details` | Inspects components in the active SAP GUI session and dumps their IDs and properties |
| `sap-gui-probe` | Drives a SAP transaction step by step against a natural-language scenario and emits a synthesized recording-style VBS |
| `sap-gui-record` | Guides recording of SAP GUI interactions and extracts component IDs, actions, and field names from the VBS |
| `sap-gui-skill-scaffold` | Authors a new mode-aware transaction skill from N natural-language scenarios — runs `/sap-gui-probe` per scenario, merges probe folders via cross-probe diff, emits a ready-to-test draft |
| `sap-log-analyze` | Summarizes sap-dev JSONL log files: per-skill counts, success/fail rates, p50/p95 duration, top error classes |
| `sap-login` | Opens a SAP GUI connection and logs in via SAP GUI Scripting; also verifies SAP NCo 3.1 RFC connectivity |
| `sap-rfc-wrapper-class` | Generates an RFC wrapper function module for a non-RFC-callable ABAP class method |
| `sap-rfc-wrapper-fm` | Calls a non-RFC-enabled SAP function module via the generic `Z_GENERIC_RFC_WRAPPER_TBL` wrapper |
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

### Business Process Automation (`sap-tcd`)

| Skill | Description |
|-------|-------------|
| `sap-bp` | Manages SAP Business Partners (Organization type) via the BP transaction |
| `sap-mm01` | Manages SAP material masters via MM01/MM02/MM03 (create / update / check) |
| `sap-va01` | Manages SAP sales orders via VA01/VA02/VA03 (create / update / check) |
