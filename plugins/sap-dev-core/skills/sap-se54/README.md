# SAP SE54 Table Maintenance Dialog Skill

Generate table maintenance dialogs in SAP via SE54 using SAP GUI Scripting.

## Skill Overview

This skill automates table maintenance dialog generation via SE54:

- **Existence Check**: Detects whether a maintenance dialog already exists for the table
- **Generation**: Sets authorization group, function group, maintenance type, and screen number
- **Object Directory**: Handles object directory entry popups for FUGR and TOBJ objects
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: Saves object directory entries with Local Object ($TMP) by default

## Auto-Trigger Keywords

This skill activates when discussing:

### SE54 & Table Maintenance Dialog
- SE54, table maintenance dialog, maintenance dialog generator
- generate table maintenance, create maintenance dialog
- table maintenance generation, maintenance screen generator

### Maintenance Dialog Details
- authorization group, function group, maintenance type
- one step maintenance, two step maintenance
- overview screen, SM30, table maintenance view

### Maintenance Dialog Existence
- maintenance dialog exists, check maintenance dialog
- Generated Objects, maintenance module

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-se54/
├── SKILL.md                          # Main skill file (step-by-step workflow)
├── README.md                         # This file (keywords for discoverability)
└── references/
    ├── sap_se54_login.vbs            # VBScript: login to SAP GUI
    ├── sap_se54_check.vbs            # VBScript: check if maintenance dialog exists
    └── sap_se54_generate.vbs         # VBScript: generate the maintenance dialog
```

## Usage

Invoke with a table name:

- "Generate table maintenance dialog for ZHKTBTEST005" — prompts for details
- "Create SE54 maintenance dialog for table ZCUSTOM01"
- "Generate maintenance dialog for ZHKTBTEST005 with function group ZHKT05"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP user with authorization for SE54 and table maintenance generation
- Target table must exist in SE11 (ABAP Dictionary)

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-03-31

## License

GPL-3.0 License - See LICENSE file in repository root.
