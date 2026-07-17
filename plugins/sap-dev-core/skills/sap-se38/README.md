# SAP SE38 Deploy Skill

Deploy ABAP source code to SAP via SE38 using SAP GUI Scripting.

## Skill Overview

This skill automates the full ABAP program deployment lifecycle via SE38:

- **Create or Update**: Automatically detects whether the program exists (SE16N on TRDIR) and runs the appropriate flow
- **Source Upload**: Pastes the ABAP source (from a local file or pasted code) into the ABAP Editor via the Windows clipboard + SendKeys, behind the OS foreground guard + session lock + machine-global paste mutex (the Utilities > Upload menu is not used — it opens a non-scriptable native file picker and its path does not exist on NW 7.31/ECC6)
- **Attributes Dialog**: Sets program type and title for new programs
- **Save, Syntax Check & Activate**: Saves (Ctrl+S), runs syntax check (Ctrl+F2); only on clean check, presses Activate (Ctrl+F3)
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: TR resolved via `/sap-transport-request` (per `way_to_get_transport_request`); the VBS fills the resolved TR into the KO008 popup and aborts loud when a TR is required but missing — it never silently presses Local Object

## Auto-Trigger Keywords

This skill activates when discussing:

### SE38 & ABAP Editor
- SE38, ABAP Editor, ABAP Workbench
- program editor, source code editor
- create program, change program, new report

### ABAP Deployment
- deploy ABAP, upload ABAP, upload source code
- activate program, syntax check, save and activate
- ABAP source file, .abap file
- program type, executable program, include program

### Program Existence
- TRDIR, program exists, check program
- SE16N, table browser, program lookup

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-se38/
├── SKILL.md                              # Main skill file (step-by-step workflow)
├── README.md                             # This file (keywords for discoverability)
└── references/
    ├── sap_se38_check.vbs                # VBScript: check if program exists (SE16N/TRDIR)
    ├── sap_se38_create.vbs               # VBScript: create new program in SE38
    ├── sap_se38_update.vbs               # VBScript: update existing program in SE38
    ├── sap_se38_check_and_download.vbs   # VBScript: syntax-check + download source (check-and-fix mode)
    ├── sap_se38_change_attrs.vbs         # VBScript: change program attributes (title / status / type)
    ├── sap_se38_delete.vbs               # VBScript: delete a program (irreversible; confirmed first)
    ├── sap_se38_text_elements.vbs        # VBScript: update selection texts / text symbols
    ├── sap_se38_content_verify.vbs       # VBScript+PS1 pair: content-integrity post-verify
    ├── sap_se38_content_verify.ps1       #   (deployed source matches the local file)
    ├── sap_rfc_program_insert.ps1        # PowerShell: headless RFC deploy via RPY_PROGRAM_INSERT
    └── *.screens.json                    # Golden-screen baselines (one per driving VBS)
```

Login is centralized in `/sap-login` (shared `sap_login.vbs`); this skill attaches to
the existing session.

## Usage

Invoke with a program name and source:

- "Deploy ZMYREPORT to SAP" — prompts for source and connection details
- "Upload this ABAP code to SE38 as ZHELLO_WORLD"
- "Create program ZTEST_001 from C:\Sources\ztest_001.abap"
- "Update ZMTTMS0230 with the new version"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP user with authorization for SE38, SE16N, and program activation

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-03-30

## License

GPL-3.0 License - See LICENSE file in repository root.
