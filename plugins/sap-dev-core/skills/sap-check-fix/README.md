# SAP Check & Fix Router Skill

Routes a "check and fix" request to the right ABAP Workbench skill based on
the named object kind, or auto-detects the kind by probing SE38 → SE37 → SE24
→ SE11 when the user gives only an object name.

## Skill Overview

This skill is a thin dispatcher. It does not modify code or definitions on its
own — it identifies the target object's kind and then calls the appropriate
underlying skill in **check-and-fix mode** (no source file argument), so the
downstream skill performs:

1. Display the existing object
2. Run syntax / consistency check
3. Download the source / definition
4. Fix detected errors
5. Re-upload and activate

## Routing Rules

| User says | Object name interpreted as | Calls |
|---|---|---|
| `check and fix report XXX` / `check report XXX` / `fix program XXX` / `fix pgm XXX` | ABAP program | `/sap-se38 XXX` |
| `check and fix function module XXX` / `fix fm XXX` | Function module | `/sap-se37 XXX` |
| `check and fix class XXX` / `fix interface XXX` / `check method CLASS=>METH` | Class / interface (SE24 opens the whole class) | `/sap-se24 XXX` |
| `check and fix table XXX` | DDIC database table | `/sap-se11 TABLE XXX` |
| `check and fix view XXX` | DDIC view | `/sap-se11 VIEW XXX` |
| `check and fix structure XXX` / `data element XXX` / `table type XXX` | DDIC data type | `/sap-se11 DATATYPE XXX` |
| `check and fix type group XXX` | DDIC type group | `/sap-se11 TYPEGROUP XXX` |
| `check and fix domain XXX` | DDIC domain | `/sap-se11 DOMAIN XXX` |
| `check and fix search help XXX` | DDIC search help | `/sap-se11 SEARCHHELP XXX` |
| `check and fix lock object XXX` | DDIC lock object | `/sap-se11 LOCKOBJECT XXX` |
| `check and fix dictionary XXX` / `ddic XXX` (no subtype) | Probe DDIC subtypes | `/sap-se11 ...` |
| `check and fix XXX` (no kind keyword) | **Auto-probe** SE38 → SE37 → SE24 → SE11 (TABLE → DATATYPE → DOMAIN) | The first hit |

## Auto-Trigger Keywords

This skill activates when the user says:

- `check`, `check and fix`, `fix`
- combined with: `report`, `program`, `pgm`, `function module`, `fm`,
  `class`, `interface`, `method`, `dictionary`, `ddic`, `table`, `view`,
  `structure`, `data element`, `domain`, `table type`, `type group`,
  `search help`, `lock object`
- or with no kind keyword at all — the skill probes the system

## Usage

```text
/sap-check-fix report ZHKR001
/sap-check-fix fm ZHK_GET_DATA
/sap-check-fix class ZCL_HK_UTIL
/sap-check-fix domain ZDOM_STATUS
/sap-check-fix table ZHKTBL001
/sap-check-fix ZHKR001            ← no kind, will probe
```

Conversational forms:

- "check and fix report ZHKR001"
- "fix function module ZHK_FOO"
- "check class ZCL_DEMO"
- "check and fix ZHKTBL001"        ← no kind, will probe

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- The target object must already exist in the SAP system — this skill never
  creates new objects. To create, use `/sap-se38`, `/sap-se37`, `/sap-se24`,
  or `/sap-se11` directly.

## Limitations

- Probe order: SE38 → SE37 → SE24 → SE11 (TABLE → DATATYPE → DOMAIN). A name
  that exists as multiple object types resolves to the earliest match. Pass
  the kind keyword explicitly to override.
- Auto-probe does not cover VIEW, TYPEGROUP, SEARCHHELP, LOCKOBJECT — name
  the kind explicitly for those.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-04-23

## License

GPL-3.0 License - See LICENSE file in repository root.
