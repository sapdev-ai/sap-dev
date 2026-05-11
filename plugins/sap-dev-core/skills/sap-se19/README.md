# SAP SE19 BAdI Implementation Skill

Create BAdI implementations via SE19 (New BAdI / Enhancement Framework) and deploy method source to the implementing class via SE24 using SAP GUI Scripting.

## Skill Overview

This skill automates the SE19 BAdI implementation lifecycle:

- **Two-Level Creation**: Creates Enhancement Implementation (container) and BAdI Implementation (element) in one pass
- **Class Generation**: Creates the implementing class (empty) with Local Object transport
- **Source Upload**: Uploads full class source to the implementing class via SE24 source-code-based view
- **Syntax Check & Activate**: Saves and activates both the Enhancement Implementation and the class
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: Dismisses transport request dialog with Local Object or Enter

## Auto-Trigger Keywords

This skill activates when discussing:

### SE19 & BAdI Builder
- SE19, BAdI Builder, BAdI implementation builder
- create BAdI implementation, change BAdI implementation
- BAdI Builder initial screen, Enhancement Framework

### BAdI & Enhancement Framework (New BAdI)
- BAdI, Business Add-In, BAdI implementation
- Enhancement Implementation, Enhancement Spot
- New BAdI, Enhancement Framework
- implementing class, BAdI definition
- create enhancement implementation, assign BAdI

### SE24 & Class Builder (for source upload)
- SE24, Class Builder, class editor
- source-code-based view, upload class source
- implementing class source, method source

### Enhancement Spots & Common BAdIs
- ME_PROCESS_PO_CUST, purchase order BAdI
- MB_DOCUMENT_BADI, goods movement BAdI
- BADI_FDCB_SUBBAS01, accounting BAdI
- enhancement spot, BAdI definition list

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-se19/
├── SKILL.md                              # Main skill file (step-by-step workflow)
├── README.md                             # This file (keywords for discoverability)
└── references/
    ├── sap_se19_login.vbs                # VBScript: login to SAP GUI
    ├── sap_se19_check.vbs                # VBScript: check if Enhancement Implementation exists
    ├── sap_se19_create.vbs               # VBScript: create Enhancement Impl + BAdI Impl + class
    └── sap_se19_update_method.vbs        # VBScript: upload class source via SE24
```

## Usage

Invoke with an Enhancement Spot, implementation name, and optionally source:

- "Create BAdI implementation ZHK_BADI_PO_001 for ME_PROCESS_PO_CUST" — creates Enhancement Impl + BAdI Impl + implementing class
- "Deploy method source to ZCL_IM_ZHK_PO_001" — uploads class source via SE24
- "Set up BAdI implementation for ME_PROCESS_PO_CUST and deploy the handler code"
- "Check if Enhancement Implementation ZHK_BADI_PO_001 exists"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP GUI Security: "Open file" action set to Allow (for SE24 Upload)
- SE24 configured for source-code-based view (not form-based)
- SAP user with authorization for SE19, SE24, and class activation
- Enhancement Spot must already exist (standard SAP or custom)

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-03-30

## License

GPL-3.0 License - See LICENSE file in repository root.
