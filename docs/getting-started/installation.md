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

## Available Skills (26)

### Core Utilities & ABAP Workbench (`sap-dev-core`)

| Skill | Description |
|-------|-------------|
| `sap-login` | SAP GUI Scripting login automation with DPAPI credential storage |
| `sap-call-bdc` | Executes BDC recordings via RFC (ABAP4_CALL_TRANSACTION) |
| `sap-update-addon` | Maintenance utilities for add-on tables (SE16/SM30) |
| `sap-se38` | Deploys, syntax checks, and activates ABAP programs |
| `sap-se37` | Manages ABAP Function Modules |
| `sap-se24` | Manages ABAP Classes and Interfaces |
| `sap-se11` | Manages Dictionary objects: tables, structures, domains, data elements |
| `sap-se19` | Manages BAdI implementations |
| `sap-se41` | Manages GUI PF-STATUS and Menu Painter objects |
| `sap-se51` | Manages Screen Painter flow logic |
| `sap-se54` | Manages Table Maintenance Generators |
| `sap-se91` | Manages Message Classes and entries |
| `sap-cmod` | Manages enhancement projects and user exits |
| `sap-gui-record` | Tools for recording and analyzing SAP GUI scripts |

### Code Generation & Quality (`sap-gen-code`)

| Skill | Description |
|-------|-------------|
| `sap-gen-abap` | Generates ABAP source from design documents (Excel/PDF) |
| `sap-check-abap` | Validates ABAP code against naming and technical standards |
| `sap-check-fm` | Validates Function Module parameter calls via RFC |
| `sap-docs-convert` | Converts design documents to processable text |
| `sap-docs-extract` | Extracts structured metadata from design documents |
| `sap-docs-check-process` | Validates technical process flow against business rules |
| `sap-docs-check-ddic` | Validates Dictionary field references against target systems |
| `sap-fix-abap` | Automatically fixes common ABAP coding errors and standard violations |
| `sap-fix-fm` | Automatically fixes Function Module interface mismatches |

### Business Process Automation (`sap-tcd`)

| Skill | Description |
|-------|-------------|
| `sap-bp` | Manages Business Partner master data |
| `sap-mm01` | Manages Material Master data (create/update/check) |
| `sap-va01` | Manages Sales Order processing |
