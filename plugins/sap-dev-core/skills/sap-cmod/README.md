# SAP CMOD Enhancement Project Skill

Manage SAP Enhancement Projects via CMOD and edit exit includes via SE38 using SAP GUI Scripting.

## Skill Overview

This skill automates the CMOD enhancement project lifecycle:

- **Create Project**: Creates a new CMOD enhancement project with short text
- **Assign Enhancements**: Assigns one or more SAP enhancements (exits) to the project
- **Edit Exit Include**: Uploads ABAP source to exit includes (e.g. ZXV00U01) via SE38
- **Syntax Check & Activate**: Runs syntax check, saves, and activates in one pass
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: Dismisses transport request dialog with Local Object or Enter

## Auto-Trigger Keywords

This skill activates when discussing:

### CMOD & Enhancement Projects
- CMOD, enhancement project, customer enhancement
- create enhancement project, assign enhancement
- SAP enhancement, user exit, customer exit
- enhancement management, SMOD

### Exit Includes & Function Exits
- exit include, function exit, EXIT_SAPL
- change include, edit include, deploy include
- ZX include, user exit code
- include source code, include activation

### SE38 & ABAP Editor (for includes)
- SE38, ABAP Editor, edit program
- upload source, activate include
- syntax check include

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-cmod/
├── SKILL.md                              # Main skill file (step-by-step workflow)
├── README.md                             # This file (keywords for discoverability)
└── references/
    ├── sap_cmod_login.vbs                # VBScript: login to SAP GUI
    ├── sap_cmod_check.vbs                # VBScript: check if CMOD project exists
    ├── sap_cmod_create.vbs               # VBScript: create project + assign enhancements
    └── sap_cmod_change_include.vbs       # VBScript: edit exit include via SE38
```

## Usage

Invoke with a project name, enhancement, and optionally an include:

- "Create CMOD project ZHKPJ001 with enhancement 0VRF0001" — creates project and assigns enhancement
- "Deploy ZXV00U01 include source to SAP" — uploads, saves, and activates include
- "Set up enhancement project ZHKPJ001 with 0VRF0001 and change ZXV00U01"
- "Check if CMOD project ZHKPJ001 exists"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP GUI Security: "Open file" action set to Allow (for SE38 Upload)
- SAP user with authorization for CMOD, SE38, and include activation
- Enhancement must exist in SMOD before assigning to project

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-03-30

## License

GPL-3.0 License - See LICENSE file in repository root.
