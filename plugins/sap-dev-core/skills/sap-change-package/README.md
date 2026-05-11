# SAP Change Package Skill

Changes the package (`TADIR-DEVCLASS`) assignment of an SAP repository object
via the standard "Object Directory Entry" dialog (Goto > Object Directory
Entry). Routes by object type to SE38 / SE37 / SE24 / SE11 / SE91. Handles
three flows automatically based on current vs. new package locality.

## Skill Overview

1. Parse: object type + object name + new package
2. Pre-check `TADIR.DEVCLASS` to determine current locality (`$TMP` or `Z*/Y*`)
3. Choose the flow:
   - **(a) `$TMP → Z*/Y*`** — resolve a modifiable TR via
     `/sap-transport-request`, then enter the new package + TR
   - **(b) `Z*/Y* → Z*/Y*`** — pre-check `E071`/`E070` to ensure the object is
     NOT linked to a modifiable TR (would block the move)
   - **(c) `Z*/Y* → $TMP`** — confirm with the user, then press "Local object"
4. Verify via `TADIR` re-query

## Auto-Trigger Keywords

- `change package`, `move to package`, `reassign package`
- `move to $TMP`, `move to local`
- `change devclass`

## Usage

```text
/sap-change-package PROGRAM ZHKR001          ZHK_MM
/sap-change-package FM      ZHK_GET_DATA     ZHK_UTIL
/sap-change-package CLASS   ZCL_HK_UTIL      ZHK_UTIL
/sap-change-package TABLE   ZHKTBL001        $TMP
```

Conversational forms:

- "Move ZHKR001 to package ZHK_MM"
- "Change ZCL_HK_UTIL's package to ZHK_UTIL"
- "Move ZHKTBL001 to local — drop the transport"

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- For flows (a) and (b): authorisation S_DEVELOP for the source and target packages
- For flow (a): `way_to_get_transport_request` policy configured per
  `tr_resolution.md`

## Limitations

- Does NOT handle objects locked in released TRs (E070-TRSTATUS = `R`); SAP
  blocks these and the skill aborts with the error from the dialog.
- Does NOT split partial-object moves (e.g. moving only specific FMs out of
  a function group). Whole object only.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
