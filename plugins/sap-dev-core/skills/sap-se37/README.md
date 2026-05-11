# SAP SE37 Function Module Deploy Skill

Deploy ABAP function module source code to SAP via SE37 using SAP GUI Scripting.

## Skill Overview

This skill automates the function module deployment lifecycle via SE37:

- **Create or Update**: Automatically detects whether the function module exists (SE16N on TFDIR) and runs the appropriate flow
- **Source Upload**: Uploads FM body source from a local file or pasted code via SE37's "Upload from local file" menu on the Source code tab
- **Create Dialog**: Sets function group and short text for new function modules
- **Syntax Check & Activate**: Runs syntax check, saves, and activates in one pass
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: Dismisses transport request dialog with Local Object or Enter

## Auto-Trigger Keywords

This skill activates when discussing:

### SE37 & Function Builder
- SE37, Function Builder, function module builder
- create function module, change function module
- function module editor, FM editor

### Function Module Deployment
- deploy function module, upload FM source, upload function module
- activate function module, syntax check FM
- function module source, .abap file
- function group, function module body

### Function Module Existence
- TFDIR, function module exists, check function module
- SE16N, table browser, FM lookup

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-se37/
├── SKILL.md                        # Main skill file (step-by-step workflow)
├── README.md                       # This file (keywords for discoverability)
└── references/
    ├── sap_se37_login.vbs          # VBScript: login to SAP GUI
    ├── sap_se37_check.vbs          # VBScript: check if FM exists (SE16N/TFDIR)
    ├── sap_se37_create.vbs         # VBScript: create new FM in SE37
    └── sap_se37_update.vbs         # VBScript: update existing FM in SE37
```

## Usage

Invoke with a function module name and source:

- "Deploy ZHKFM_TEST001 to SAP" — prompts for source and connection details
- "Upload this ABAP code to SE37 as ZHKFM_HELLO"
- "Create function module ZHKFM_CALC in function group ZHKFG01"
- "Update ZHKFM_TEST001 with the new source code"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP user with authorization for SE37, SE16N, and function module activation
- Target function group must already exist (create via SE37: Goto > Function Groups > Create Group)

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-03-30

## License

GPL-3.0 License - See LICENSE file in repository root.
