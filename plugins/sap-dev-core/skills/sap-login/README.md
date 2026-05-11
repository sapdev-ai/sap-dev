# SAP GUI Login Skill

SAP GUI Scripting login automation for opening connections and logging into SAP systems.

## Skill Overview

This skill provides automation for SAP GUI login operations including:

- **Login Popup**: GUI popup window for entering login details when no credentials are provided
- **Centralized Settings**: Reads connection parameters from sap-dev-core settings.json
- **Auto-Login**: Fills in credentials automatically from settings.json
- **Auto-Start**: Launch SAP Logon if not running
- **Manual Login Fallback**: Wait up to 5 minutes for manual login when no password provided
- **Session Reuse**: Detect and reuse existing SAP GUI sessions

## Auto-Trigger Keywords

This skill activates when discussing:

### SAP GUI
- SAP GUI, SAP Logon, SAP GUI Scripting, SAP connection
- sap logon pad, open connection, login to SAP
- SAP session, SAP scripting engine

### Login & Credentials
- SAP login, SAP credentials, SAP password
- auto-login, settings.json, connection parameters
- client number, SAP user, logon language

### Scripting
- VBScript, cscript, SAP scripting
- GetObject SAPGUI, OpenConnection
- sendVKey, findById

## Directory Structure

```
sap-login/
├── SKILL.md                        # Main skill file (this file's companion)
├── README.md                       # This file (keywords for discoverability)
└── references/
    ├── sap_login.vbs               # VBScript template with placeholder tokens
    └── sap_login_popup.ps1         # PowerShell WPF login popup with connection dropdown
```

## Usage

Ask about any SAP GUI login automation topic:

- "Log in to my SAP system"
- "Open a SAP GUI connection"
- "Store my SAP credentials"
- "Connect to SAP DEV system"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)

## Version

- Skill Version: 1.1.0
- Last Updated: 2026-03-29

## License

GPL-3.0 License - See LICENSE file in repository root.
