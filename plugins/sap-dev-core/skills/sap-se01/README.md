# SAP SE01 — Create Transport Request Skill

Creates a new SAP transport request via transaction SE01 using SAP GUI
Scripting, gates the create on the statusbar MessageType, then resolves the
new TRKORR from the create-success message itself (locale-independent
transport-number shape), falling back to a two-step SE16N lookup (`E07T` by
`AS4TEXT`, then `E070` by `AS4USER` + `TRSTATUS = D`, highest TRKORR wins).
Emits `RESULT_TR: <TRKORR>` (authoritative) plus `INFO: TRKORR=<TRKORR>`
(back-compat); if nothing resolves it fails with `TR_RESOLUTION_FAILED`
rather than guessing.

This is the **GUI-based** companion to `sap-transport-request` (which uses
`CTS_API_CREATE_CHANGE_REQUEST` via RFC). Use this skill when you need to
create a Customizing request (the RFC API only creates Workbench requests) or
when RFC is unavailable.

## Skill Overview

1. Parse arguments: request type (`W`/`C`) and short description
2. Run `sap_se01_create.vbs` — it creates the request via SE01 GUI, gates on
   the statusbar MessageType (E/A = create failed), and resolves the new
   TRKORR itself (statusbar primary, SE16N `E07T`→`E070` fallback)
3. Parse the `RESULT_TR:` line, return the new TRKORR

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
- The SE16N fallback's `AS4TEXT` filter uses the inline single-value cell,
  which rejects some characters (e.g. `[`). The primary statusbar extraction
  is unaffected; when both paths fail the VBS exits with
  `TR_RESOLUTION_FAILED` instead of guessing.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-04-23

## License

GPL-3.0 License - See LICENSE file in repository root.
