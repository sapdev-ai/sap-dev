# SAP SE37 Function Module Deploy Skill

Deploy ABAP function module source code to SAP via SE37 using SAP GUI Scripting.

## Skill Overview

This skill automates the function module deployment lifecycle via SE37:

- **Create or Update**: Automatically detects whether the function module exists (SE37 Display probe via `sap_se37_check.vbs` — `ctxtRS38L-NAME` + `FUNC_TAB_STRIP`) and runs the appropriate flow
- **Source Upload**: Pastes the FM body source into the Source-code editor via the Windows clipboard + SendKeys, behind the OS foreground guard + session lock (the Utilities > Upload menu is S/4-only — its path does not exist on NW 7.31/ECC6)
- **Create Dialog**: Sets function group and short text for new function modules
- **Syntax Check & Activate**: Runs syntax check, saves, and activates in one pass
- **Secondary Modes**: check-and-fix, change-attributes, reassign-function-group, and delete on an existing FM (see SKILL.md)
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: TR resolved via `/sap-transport-request` (per `way_to_get_transport_request`); the VBS fills the resolved TR into `ctxtKO008-TRKORR` and aborts with ERROR (exit 1) when a TR popup appears with TRANSPORT empty — it never silently presses Local Object

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
- SE37 Display, Function Builder lookup

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-se37/
├── SKILL.md                              # Main skill file (step-by-step workflow)
├── README.md                             # This file (keywords for discoverability)
└── references/
    ├── sap_se37_check.vbs                # VBScript: check if FM exists (SE37 Display probe)
    ├── sap_se37_create.vbs               # VBScript: create new FM in SE37
    ├── sap_se37_update.vbs               # VBScript: update existing FM (clipboard + SendKeys paste)
    ├── sap_se37_check_and_download.vbs   # VBScript: syntax-check + download source (check-and-fix mode)
    ├── sap_se37_change_attrs.vbs         # VBScript: change FM attributes (short text / processing type)
    ├── sap_se37_reassign_fugr.vbs        # VBScript: reassign FM to another function group
    ├── sap_se37_delete.vbs               # VBScript: delete an FM (irreversible; confirmed first)
    ├── sap_rfc_fm_insert.ps1             # PowerShell: headless RFC deploy via RPY_FUNCTIONMODULE_INSERT
    └── *.screens.json                    # Golden-screen baselines (one per driving VBS)
```

Login is centralized in `/sap-login` (shared `sap_login.vbs`); this skill attaches to
the existing session.

## Usage

Invoke with a function module name and source:

- "Deploy ZHKFM_TEST001 to SAP" — prompts for source and connection details
- "Upload this ABAP code to SE37 as ZHKFM_HELLO"
- "Create function module ZHKFM_CALC in function group ZHKFG01"
- "Update ZHKFM_TEST001 with the new source code"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP user with authorization for SE37 and function module activation
- Target function group must already exist (create it via `/sap-function-group`)

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
