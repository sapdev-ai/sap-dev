# SAP SE24 Class Builder Deploy Skill

Deploy ABAP class source code to SAP via SE24 using SAP GUI Scripting.

## Skill Overview

This skill automates the ABAP class deployment lifecycle via SE24:

- **Create or Update**: Automatically detects whether the class exists (SE24 Display) and runs the appropriate flow
- **Source Upload**: Uploads full class source from a local file or pasted code via SE24's source-code-based view "Upload from local file" menu
- **Create Dialog**: Sets class name and short description for new classes
- **Save & Activate**: Saves, handles transport dialog, and activates in one pass
- **Syntax Check**: Runs Check (Ctrl+F2) after activation, reads errors from the error grid
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: Supports package/transport assignment or Local Object ($TMP)
- **Encoding Conversion**: Auto-converts UTF-8 source to system codepage for upload (文字化け fix)

## Auto-Trigger Keywords

This skill activates when discussing:

### SE24 & Class Builder
- SE24, Class Builder, class builder
- create class, change class, update class
- class editor, ABAP class

### Class Deployment
- deploy class, upload class source, upload ABAP class
- activate class, class source code
- class definition, class implementation
- .abap file, ABAP source

### Class Existence
- class exists, check class, SE24 Display
- class not found, create new class

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-se24/
├── SKILL.md                        # Main skill file (step-by-step workflow)
├── README.md                       # This file (keywords for discoverability)
└── references/
    ├── sap_se24_login.vbs          # VBScript: login to SAP GUI
    ├── sap_se24_check.vbs          # VBScript: check if class exists (SE24 Display)
    ├── sap_se24_create.vbs         # VBScript: create new class shell in SE24
    └── sap_se24_update.vbs         # VBScript: update existing class in SE24 (upload source)
```

## Usage

Invoke with a class name and source:

- "Deploy ZCL_HK_TEST001 to SAP" — prompts for source and connection details
- "Upload this ABAP class to SE24 as ZCL_HK_HELLO"
- "Create class ZCL_HK_CALC with description 'Calculator class'"
- "Update ZCL_HK_TEST001 with the new source code"

## Key Differences from SE37

| Aspect | SE37 (Function Module) | SE24 (Class) |
|---|---|---|
| Source scope | FM body only (between FUNCTION/ENDFUNCTION) | Complete class (DEFINITION + IMPLEMENTATION) |
| Editor view | Single tab (Source code) | Source-code-based view required |
| Upload menu | `menu[3]/menu[9]/menu[3]/menu[0]` | `menu[3]/menu[8]/menu[2]/menu[0]` |
| Pre-upload dialog | None | "Save before upload" (press No) |
| Existence check | SE16N on TFDIR table | SE24 Display + tabsCTS detection |
| Create flow | Create + upload in one script | Shell create, then separate source upload |

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP user with authorization for SE24 and class activation
- For source upload: class must be in **source-code-based view** (switch via Utilities > Settings in SE24)
- ABAP source files must be **UTF-8 without BOM** (PowerShell `Set-Content -Encoding UTF8` adds BOM — use `[System.IO.File]::WriteAllText()` instead)

## Version

- Skill Version: 1.1.0
- Last Updated: 2026-04-08

## License

GPL-3.0 License - See LICENSE file in repository root.
