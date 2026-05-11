# SAP Activate Object Skill

Activates an inactive SAP repository object via SAP GUI Scripting. Routes to
the right transaction by object type and verifies the result via DDIC tables
(`PROGDIR`, `DWINACTIV`).

## Skill Overview

1. Parse: object type + object name
2. Route to the appropriate transaction (SE38 / SE37 / SE24 / SE11)
3. Open the object in change mode and trigger activation (Ctrl+F3)
4. Handle the **inactive objects worklist** popup that SAP shows when there
   are multiple inactive objects of the same locality (transportable vs. local
   — SAP filters the popup by package locality of the triggering object)
5. Confirm activation via `PROGDIR-STATE = 'A'` (programs / FM includes) and
   `DWINACTIV` (DDIC objects)

## Auto-Trigger Keywords

- `activate program`, `activate report`, `activate ZHK*`
- `activate function module`, `activate fm`
- `activate class`, `activate interface`, `activate method`
- `activate table`, `activate view`, `activate domain`, `activate data element`
- `activate ddic <name>`

## Usage

```text
/sap-activate-object PROGRAM   ZHKR001
/sap-activate-object FM        ZHK_GET_DATA
/sap-activate-object CLASS     ZCL_HK_UTIL
/sap-activate-object TABLE     ZHKTBL001
/sap-activate-object DOMAIN    ZDOM_STATUS
```

Conversational forms:

- "Activate program ZHKR001"
- "Activate the function module ZHK_GET_DATA"
- "Activate class ZCL_HK_UTIL — it was left inactive after the last deploy"

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- Authorisation S_DEVELOP for the object class
- `RZ11` parameter `sapgui/user_scripting` set to TRUE on the SAP server

## Limitations

- Activation only — does not create or modify the object
- The inactive-objects worklist popup is **filtered by SAP** based on the
  locality (transportable vs. local) of the triggering object. If you have
  inactive objects of the *opposite* locality, run this skill once for each.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
