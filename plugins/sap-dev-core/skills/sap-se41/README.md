# SAP SE41 Menu Painter Deploy Skill

Deploy PF-STATUS (GUI status) definitions to SAP via SE41 using SAP GUI Scripting.

## Skill Overview

This skill automates the GUI status deployment lifecycle via SE41:

- **Create or Update**: Automatically detects whether the status exists and runs the appropriate flow
- **Field-by-Field Entry**: SE41 has no Upload/Download — function codes are entered directly into the editor grid from a pipe-delimited definition file
- **Standard Toolbar**: Assigns function codes to the 13 standard toolbar button slots
- **Function Keys**: Assigns function codes and text to recommended and freely assigned function keys
- **Save & Activate**: Saves (handling "Enter Function Text" popups) and activates in one pass
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
├── SKILL.md                        # Main skill file (step-by-step workflow)
├── README.md                       # This file (keywords for discoverability)
└── references/
    ├── sap_se41_login.vbs          # VBScript: login to SAP GUI
    ├── sap_se41_check.vbs          # VBScript: check if status exists
    ├── sap_se41_create.vbs         # VBScript: create new PF-STATUS
    └── sap_se41_update.vbs         # VBScript: update existing PF-STATUS
```

## Usage

Invoke with a program name, status name, and function code definitions:

- "Create PF-STATUS ZSTATUS01 for program SAPLZHKT05" — prompts for status type and function codes
- "Deploy GUI status ZDIALOG to SAPLZMYAPP with Back, Exit, Cancel on toolbar"
- "Update status ZTEST01 of SAPLZHKT05 — add F5=Execute, F6=Refresh"
- "Create a normal screen status with standard navigation buttons"

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
