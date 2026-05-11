# SAP SE51 Screen Painter Deploy Skill

Deploy screen (dynpro) flow logic to SAP via SE51 using SAP GUI Scripting.

## Skill Overview

This skill automates the screen (dynpro) deployment lifecycle via SE51:

- **Create or Update**: Automatically detects whether the screen exists (SE51 Display) and runs the appropriate flow
- **Flow Logic Paste**: Pastes flow logic from Windows clipboard via `AppActivate` + `SendKeys` (SE51 does not support text file upload for flow logic)
- **Create Dialog**: Sets short description on the Attributes tab for new screens
- **Save & Activate**: Saves and activates in one pass
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: Dismisses transport request dialog with Local Object or Enter

## Auto-Trigger Keywords

This skill activates when discussing:

### SE51 & Screen Painter
- SE51, Screen Painter, screen painter
- create screen, change screen, create dynpro, change dynpro
- screen editor, dynpro editor

### Flow Logic Deployment
- deploy flow logic, upload flow logic, paste flow logic
- activate screen, activate dynpro
- flow logic source, PROCESS BEFORE OUTPUT, PROCESS AFTER INPUT
- MODULE call, screen module

### Screen Attributes
- screen short description, screen type, dynpro type
- normal screen, subscreen, modal dialog box, selection screen
- next dynpro, screen group

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, wscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, AppActivate, SendKeys

## Directory Structure

```
sap-se51/
├── SKILL.md                        # Main skill file (step-by-step workflow)
├── README.md                       # This file (keywords for discoverability)
└── references/
    ├── sap_se51_login.vbs          # VBScript: login to SAP GUI
    ├── sap_se51_check.vbs          # VBScript: check if screen exists (SE51 Display)
    ├── sap_se51_create.vbs         # VBScript: create new screen in SE51 (wscript.exe)
    └── sap_se51_update.vbs         # VBScript: update existing screen in SE51 (wscript.exe)
```

## Usage

Invoke with a program name, screen number, and flow logic source:

- "Deploy screen 0100 to SAPLZHKFG01" — prompts for flow logic and connection details
- "Create screen 0200 in SAPLZMYPRG with this flow logic"
- "Update screen 0100 in SAPLZHKFG01 with the new flow logic"
- "Deploy this screen to SAP via SE51"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- Windows OS (for clipboard operations)
- SAP user with authorization for SE51 and screen activation
- Target program (module pool / function group pool) must already exist

## Technical Notes

- **wscript.exe required**: Create and update VBS scripts use `AppActivate` + `SendKeys` for clipboard paste. This only works from `wscript.exe` (GUI mode), not `cscript.exe` (console mode).
- **Clipboard approach**: SE51's Upload/Download menu is for entire dynpro binary format, not flow logic text. The skill uses Windows clipboard paste instead.
- **Log file output**: Since `wscript.exe` has no stdout, create/update scripts write output to a log file.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-04-08

## License

GPL-3.0 License - See LICENSE file in repository root.
