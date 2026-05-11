# SAP Where-Used List Skill

Run SAP's Where-Used List (Verwendungsnachweis, Ctrl+Shift+F3) for any
ABAP repository object — the canonical "who references this?" check
before refactoring or deleting an object.

## Skill Overview

1. Map `OBJECT_TYPE` to the right transaction (SE11 / SE38 / SE37 /
   SE24 / SE91) and name field.
2. Navigate to that initial screen, fill the name, set cursor on it.
3. Send `Ctrl+Shift+F3` (`sendVKey 39`).
4. Tick every scope on the popup (`Select All` + `Continue`).
5. Branch:
   - **No usages** → SAP shows a "<obj> not used" popup; report
     `NOT_FOUND`.
   - **List rendered, default mode** → report `FOUND_LIST` (list stays
     on screen).
   - **List rendered, `--to-spool`** → drive *List > Print > Print*,
     parse the spool number from the status bar, report
     `SPOOL_CREATED:<NUM>`.

Pure read-only — never modifies the SAP system.

## Auto-Trigger Keywords

- `where used <NAME>`, `where-used list of <NAME>`
- `find references to <NAME>`, `who uses <NAME>`
- `check usages of <NAME> before delete`, `is <NAME> safe to delete`
- `save where-used to spool for <NAME>`

## Usage

```text
# Just check — no spool, no download
/sap-where-used-list TABLE ZTABLE_001

# Save to spool so a follow-up download can write it locally
/sap-where-used-list DATAELEMENT ZHKDE_VAL152 --to-spool

# Then download the spool with /sap-sp02
/sap-sp02 <SPOOL_NUM> C:\Temp\where_used_ZHKDE_VAL152.txt
```

Conversational forms:

- "Is data element ZHKDE_VAL152 safe to delete?"
- "Who uses table ZTABLE_001?"
- "Find references to FM Z_HKFM_TEST007 and save the list."

## Supported Object Types

| OBJECT_TYPE | Transaction |
|---|---|
| `TABLE` / `VIEW` / `DATAELEMENT` / `STRUCTURE` / `TABLETYPE` / `TYPEGROUP` / `DOMAIN` / `SEARCHHELP` / `LOCKOBJECT` | SE11 |
| `PROGRAM` | SE38 |
| `FM` | SE37 |
| `CLASS` / `INTERFACE` | SE24 |
| `MESSAGE_CLASS` | SE91 |

## Composition with `/sap-sp02`

```text
/sap-where-used-list <TYPE> <NAME> --to-spool   # → SPOOL_CREATED:<NUM>
/sap-sp02 <NUM> <C:\Temp\where_used_<NAME>.txt> # → local text file
```

Neither skill auto-invokes the other. This keeps NOT_FOUND runs cheap
(no useless download) and makes the saved file available on demand.

## Prerequisites

- Active SAP GUI session (run `/sap-login` first).

## Limitations

- **Static workbench index only.** Dynamic references (`CALL FUNCTION
  '...'`, `CREATE OBJECT (cls)`, `GENERATE SUBROUTINE POOL`,
  external-system RFC calls) are not in the index. A `NOT_FOUND` is
  necessary-but-not-sufficient for safe deletion.
- **METHOD-level lookup** isn't directly supported — query the parent
  `CLASS` and grep the result list for the method name.
- **Print-params dialog field positions** verified on S/4HANA 1909;
  other releases may need a one-time recording.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-09

## License

GPL-3.0 License - See LICENSE file in repository root.
