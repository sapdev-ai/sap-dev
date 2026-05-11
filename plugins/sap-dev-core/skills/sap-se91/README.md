# SAP SE91 Message Class Maintenance Skill

Manage SAP message classes and their messages via SE91 using SAP GUI Scripting.

## Skill Overview

This skill automates the message class lifecycle via SE91:

- **Create or Update**: Automatically detects whether the message class exists (SE91 Display) and runs the appropriate flow
- **Inline Table Editing**: Populates message texts directly in SE91's table control with scrolling support for up to 1000 messages (000-999)
- **Create Flow**: Creates message class with short text on Attributes tab, then populates messages on Messages tab
- **Update Flow**: Opens in Change mode, updates message texts, and saves
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: Dismisses transport request dialog with Local Object or Enter

## Auto-Trigger Keywords

This skill activates when discussing:

### SE91 & Message Maintenance
- SE91, Message Maintenance, message class editor
- create message class, change message class
- message class maintenance, message editor

### Message Management
- message class, message number, message text
- T100, T100A, SAP messages
- deploy messages, upload messages
- add messages, update messages
- message placeholder, &1 &2 &3 &4

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-se91/
├── SKILL.md                        # Main skill file (step-by-step workflow)
├── README.md                       # This file (keywords for discoverability)
└── references/
    ├── sap_se91_login.vbs          # VBScript: login to SAP GUI
    ├── sap_se91_check.vbs          # VBScript: check if message class exists
    ├── sap_se91_create.vbs         # VBScript: create new message class
    └── sap_se91_update.vbs         # VBScript: update messages in existing class
```

## Usage

Invoke with a message class name and messages:

- "Create message class ZHKMSG01 with messages 000-005" — prompts for details
- "Add messages to SE91 class ZHKMSG_TEST"
- "Update message 001 in ZHKMSG01 to 'Record not found: &1'"
- "Deploy these messages to SAP message class ZHKMSG01"

## Messages File Format

Tab-separated, one message per line:
```
000	First message text
001	Record &1 not found
002	Processing complete: &1 items in &2
050	Sparse numbering is supported
```

- Message numbers: 3 digits, 000-999
- Message text: max 73 characters
- Placeholders: &1, &2, &3, &4 (max 4 per message)

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP user with authorization for SE91 and message class editing

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-03-31

## License

GPL-3.0 License - See LICENSE file in repository root.
