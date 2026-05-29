# SAP CMOD Enhancement Project Skill

Full-lifecycle management of SAP Enhancement Projects (classic modifications)
via transaction CMOD, using SAP GUI Scripting for mutations and read-only RFC
for lookups.

## Skill Overview

- **Check / status** — existence, active flag, package, short text, and
  assigned enhancements (RFC: `MODATTR` / `MODACT` / `MODTEXT` / `TADIR`).
- **Create** — new enhancement project + short text (Local `$TMP` or
  transportable package + TR).
- **Add / remove assignments** — assign or unassign SAP enhancements
  **position-aware**: add writes into the first empty row and skips
  duplicates; remove matches by value and re-scans after each deletion. Never
  a hardcoded row index.
- **Change short text**, **activate**, **deactivate**, **delete** the project.
- **Change package** — delegates to `/sap-change-package` (CMOD route).
- **Edit a component** — looks up `MODSAP` and routes by component type:
  E (function exit) → `/sap-se38`, S (screen) → `/sap-se51`,
  T (table) → `/sap-se11`, C (GUI code) → `/sap-se41`.
- **Login required** — run `/sap-login` first. RFC lookups need SAP NCo 3.1
  (32-bit, .NET 4.0) in the GAC.
- **Transport handling** — delegates TR resolution to `/sap-transport-request`
  for transportable projects; `$TMP` projects need no TR.

## Auto-Trigger Keywords

- CMOD, enhancement project, customer enhancement, classic modification
- create / delete / activate / deactivate enhancement project
- assign / unassign / add / remove enhancement (SMOD enhancement, e.g. CNEX0001)
- change project short text / description, change project package
- function exit, screen exit, table/append exit, GUI/CUA exit
- exit include (ZX…), `EXIT_SAPL…`, `_CUSTSCR1_`, `…+CUE`
- MODACT, MODATTR, MODSAP, MODTEXT

## Directory Structure

```
sap-cmod/
├── SKILL.md                              # Step-by-step workflow (mode dispatch)
├── README.md                             # This file
└── references/
    ├── sap_cmod_query.ps1                # RFC reads: check/status/assignments/components
    ├── sap_cmod_create.vbs               # Create project header + short text
    ├── sap_cmod_change_description.vbs   # Change short text
    ├── sap_cmod_add_assignments.vbs      # Assign enhancements (first-empty-row)
    ├── sap_cmod_delete_assignments.vbs   # Unassign enhancements (match-by-value)
    ├── sap_cmod_activate.vbs             # Activate project (Ctrl+F3)
    ├── sap_cmod_deactivate.vbs           # Deactivate project
    └── sap_cmod_delete.vbs               # Delete project (confirm; btnSPOP-OPTION1)
```

Package change is handled by `../sap-change-package/references/sap_change_package_cmod.vbs`.

## Usage

- "Check if CMOD project ZHKPJ002 exists and what's assigned"
- "Create CMOD project ZCMODT01 'Custom logic' with CNEX0001|CNEX0002"
- "Assign CNEX0002 to ZCMODT01"  /  "Remove CNEX0002 from ZCMODT01"
- "Change the description of ZCMODT01 to 'Updated text'"
- "Activate ZCMODT01"  /  "Deactivate ZCMODT01"
- "Change package of ZCMODT01 to ZMYPKG"
- "Edit the function exit of enhancement CNEX0007"
- "Delete CMOD project ZCMODT01" (asks for confirmation)

## Prerequisites

- SAP GUI for Windows installed; SAP GUI Scripting enabled (client + server).
- SAP NCo 3.1 (32-bit, .NET 4.0) in the GAC — for the RFC lookups.
- Active logged-in session (`/sap-login`).
- Authorization for CMOD plus the workbench transactions reached when editing
  components (SE38 / SE51 / SE11 / SE41).
- Enhancements must exist in SMOD before being assigned.

## Version

- Skill Version: 2.0.0
- Last Updated: 2026-05-29

## License

GPL-3.0 License — See LICENSE file in repository root.
