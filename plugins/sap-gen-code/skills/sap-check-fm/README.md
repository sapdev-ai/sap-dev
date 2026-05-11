# SAP Check FM Skill

Validate ABAP `CALL FUNCTION` parameter names and data types against live SAP function module definitions via RFC.

## Skill Overview

This skill parses ABAP source code, extracts every `CALL FUNCTION` block, and validates it against the live SAP system:

- **Parameter name checks**: unknown parameters, missing mandatory parameters, parameters placed in the wrong section (EXPORTING/IMPORTING/CHANGING/TABLES/EXCEPTIONS)
- **Data type checks**: resolves the type of each passed variable from local DATA/TYPES declarations, then fetches the FM parameter type from SAP and compares. For structures, compares every field component by name and type.
- **Compatibility analysis**: distinguishes exact matches from compatible differences and incompatible mismatches using ABAP type family rules

## RFC Function Modules Used

| RFC FM | Purpose |
|---|---|
| `RPY_FUNCTIONMODULE_READ_NEW` | Retrieve FM parameter definitions (name, type, mandatory flag) |
| `DDIF_FIELDINFO_GET` | Get structure/table field components (DFIES_TAB) |
| `DDIF_DTEL_GET` | Get data element details (DATATYPE, LENG, DECIMALS) |

## CALL FUNCTION Keyword → FM Definition Table Mapping

| ABAP keyword | FM definition table in RPY_FUNCTIONMODULE_READ_NEW |
|---|---|
| `EXPORTING` | `IMPORT_PARAMETER` |
| `IMPORTING` | `EXPORT_PARAMETER` |
| `CHANGING` | `CHANGING_PARAMETER` |
| `TABLES` | `TABLE_PARAMETER` |
| `EXCEPTIONS` | `EXCEPTION` |

## Type Lookup Strategy

| Parameter section | Type lookup |
|---|---|
| `TABLES` | Always `DDIF_FIELDINFO_GET` (must be structure/table) |
| `EXPORTING`, `IMPORTING`, `CHANGING` | Try `DDIF_FIELDINFO_GET` first; if result empty, try `DDIF_DTEL_GET` |

## Type Compatibility Rules

| Result | Condition |
|---|---|
| `TYPE_MATCH` | Identical type names |
| `TYPE_COMPATIBLE` | Different names but same DATATYPE + LENG + DECIMALS, or same type family |
| `TYPE_WARNING` | Same DATATYPE, different LENG (truncation risk) |
| `TYPE_INCOMPATIBLE` | Different type families, or structure field missing/mismatched |
| `TYPE_UNKNOWN` | Variable not found in local declarations (LIKE, global var, constant, sy-field) |

**Type families:**
- Character: `CHAR`, `NUMC`, `LCHR`, `SSTRING`, `STRING`, `CLNT`, `LANG`
- Numeric: `DEC`, `CURR`, `QUAN`, `FLTP`
- Integer: `INT1`, `INT2`, `INT4`, `INT8`
- Date: `DATS`, `DATN` — Time: `TIMS`, `TIMN` — Binary: `RAW`, `RAWSTRING`, `LRAW`

## Auto-Trigger Keywords

### ABAP Validation
- CALL FUNCTION validation, check function module parameters
- ABAP parameter mismatch, wrong section, EXPORTING IMPORTING mismatch
- missing mandatory parameter, unknown parameter ABAP
- validate RFC call, check FM interface, FM parameter type check
- structure field comparison, ABAP type compatibility

### RFC & Type Metadata
- RPY_FUNCTIONMODULE_READ_NEW, FM parameter definition
- DDIF_FIELDINFO_GET, DFIES_TAB, structure field info
- DDIF_DTEL_GET, data element type, DD04V_WA
- SAP.Functions COM, RFC connection VBScript

## Directory Structure

```
sap-check-fm/
├── SKILL.md                        # Main skill workflow
├── README.md                       # This file
└── references/
    └── sap_check_fm.vbs            # VBScript template: parser + RFC + type comparison
```

## Usage

```
/sap-check-fm C:\src\ZPROGRAM.abap DEV_100
```

Or:
- "Check CALL FUNCTION parameters in ZPROGRAM.abap against DEV system"
- "Validate FM parameter usage and types in my ABAP source"
- "Find wrong-section, missing, and type-incompatible parameters"

## Prerequisites

- SAP GUI for Windows installed (`wdtfuncs.ocx` / `SAP.Functions` 32-bit COM)
- 64-bit Windows with `C:\Windows\SysWOW64\cscript.exe` (standard on all 64-bit Windows)
- SAP user with `S_RFC` authorization for: `RPY_FUNCTIONMODULE_READ_NEW`, `DDIF_FIELDINFO_GET`, `DDIF_DTEL_GET`

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-04-05

## License

GPL-3.0 — See LICENSE file in repository root.
