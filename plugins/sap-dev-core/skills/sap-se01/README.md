# SAP SE01 — Create Transport Request Skill

Creates a new SAP transport request via transaction SE01 using SAP GUI
Scripting, then resolves the new TRKORR by querying table `E070` via
`/sap-se16n` (filtered by user, date, last 30 seconds, and `STRKORR = ''`).

This is the **GUI-based** companion to `sap-transport-request` (which uses
`CTS_API_CREATE_CHANGE_REQUEST` via RFC). Use this skill when you need to
create a Customizing request (the RFC API only creates Workbench requests) or
when RFC is unavailable.

## Skill Overview

1. Parse arguments: request type (`W`/`C`) and short description
2. Capture pre-creation timestamp
3. Run `sap_se01_create.vbs` to create the request via SE01 GUI
4. Capture post-creation timestamp
5. Build a `sap-se16n` PARAMS_FILE and run it on `E070`
6. Parse the result, return the new TRKORR

## Auto-Trigger Keywords

- `create transport request`, `new TR`, `create CR` (Change Request)
- `create customizing request`, `create workbench request`
- `se01`, `transport request`, combined with create / new

## Usage

```text
/sap-se01 W "Hotfix for VBAK item table"
/sap-se01 C "Customizing for company code 1000"
/sap-se01 workbench "ZHK demo development"
```

Conversational forms:
- "Create a workbench request titled 'Item enhancements'"
- "Create a customizing request for our pricing config"
- "I need a new TR — Workbench, description 'Test pkg'"

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- The logged-in user must be authorised to create transport requests
  (S_TRANSPRT)
- `sap_user` set in sap-dev-core settings.json (used to filter E070)

## Limitations

- The VBS does not pick a specific target client / system for the request — it
  uses the SE01 default for the logged-in client.
- "Tasks owner" follow-up popup not handled (rarely appears).
- Time-window filtering on AS4TIME assumes the workstation clock is within ~30
  seconds of the SAP application server. Widen the window if you see
  `NO_DATA` or false matches.
- TRKORR resolution relies on the request being top-level (`STRKORR = ''`) —
  this is the normal case for SE01-created requests.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-04-23

## License

GPL-3.0 License - See LICENSE file in repository root.
