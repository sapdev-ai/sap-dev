# SAP SE41 Menu Painter Skill

Manage PF-STATUS (GUI status) subobjects on SAP via SE41 using SAP GUI Scripting.

## Skill Overview

This skill manages the full GUI status lifecycle via SE41, one operation per run:

- **Operations**: `CREATE`, `UPDATE`, `DISPLAY`, `DELETE`, `ACTIVATE`, `DEACTIVATE`, `COPY`, plus an existence `CHECK`
- **Single shipped VBScript**: All operations are driven by one self-contained VBScript shipped at `references/sap_se41_ops.vbs` (token-substituted per run per SKILL.md Step 4), selected by the `OPERATION` token
- **Field-by-Field Entry**: SE41 has no Upload/Download — function codes are entered directly into the editor grid from a pipe-delimited definition file (CREATE/UPDATE)
- **Standard Toolbar**: Assigns function codes to the 13 standard toolbar button slots
- **Function Keys**: Assigns function codes and text to recommended and freely assigned function keys
- **Save & Activate**: Saves (handling "Enter Function Text" popups) and activates in one pass
- **Delete commits**: DELETE removes the inactive version then activates to drop the active version
- **DEACTIVATE**: Not supported by SE41 — returns `NOT_SUPPORTED` (status is a static repository object)
- **Package changes**: Delegated to `/sap-change-package`
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json

## Auto-Trigger Keywords

This skill activates when discussing:

### SE41 & Menu Painter
- SE41, Menu Painter, GUI status editor
- create status, change status, PF-STATUS
- menu painter editor, status editor

### GUI Status & Function Codes
- GUI status, PF-STATUS, interface status
- function codes, function key assignment
- standard toolbar, application toolbar
- toolbar buttons, menu bar status

### Status Deployment
- deploy status, deploy GUI status
- create PF-STATUS, update PF-STATUS
- activate status, save status
- status definition, function code definition

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-se41/
├── SKILL.md                        # Main skill file (workflow; runs the shipped references VBS)
├── README.md                       # This file (keywords for discoverability)
└── references/
    ├── sap_se41_ops.vbs            # The operations VBScript — single source of truth (token-substituted per run)
    └── sap_se41_ops.screens.json   # Golden-screen baseline for the operations VBS
```

The operations VBScript is shipped at `references/sap_se41_ops.vbs` — the single
source of truth used at run time; SKILL.md Step 4 reads it from `references/`,
substitutes the `%%TOKEN%%` values, and runs the result. No copy is embedded in
SKILL.md.

## Usage

Invoke with an operation, program name, status name, and (for CREATE/UPDATE)
function code definitions:

- "Create PF-STATUS ZSTATUS01 for program SAPLZHKT05" — prompts for status type and function codes
- "Display status ZTEST01 of SAPLZHKT05"
- "Update status ZTEST01 of SAPLZHKT05 — add F5=Execute, F6=Refresh"
- "Copy status ZTEST01 of SAPLZHKT05 to ZTEST02"
- "Delete status ZTEST01 of SAPLZHKT05"
- "Activate interface SAPLZHKT05"

## Definition File Format

The skill uses a pipe-delimited `.def` file for function code definitions:

```
# Standard toolbar
STD|3|BACK|Back
STD|4|RW|Exit
STD|5|CANC|Cancel
# Function keys
FK|F5|ZEXEC|Execute Report
FK|F6|ZREFR|Refresh
FK|Shift-F1|ZATTR|Attributes
```

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP user with authorization for SE41 and status activation
- Target program/function pool must already exist

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-04-01

## License

GPL-3.0 License - See LICENSE file in repository root.
