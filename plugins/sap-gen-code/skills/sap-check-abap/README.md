# sap-check-abap

Validates ABAP source code quality before deployment.

## Checks Performed

| Check | Severity | Description |
|---|---|---|
| Naming conventions | WARNING | Variable prefix doesn't match `shared/abap_naming_rules.tsv` |
| Type validity | ERROR | Data type not found in local TYPES or SAP Dictionary |
| Unused variables | WARNING | Variable declared but never referenced |
| SQL table validation | ERROR | SQL table not found in SAP Dictionary |
| SQL field validation | ERROR | SQL field not found in the referenced table |

## SAP RFCs Used (Online Mode)

| FM | Purpose |
|---|---|
| `DDIF_FIELDINFO_GET` | Determine if type is a structure; get field list; validate SQL table fields |
| `DDIF_DTEL_GET` | Resolve data element to underlying built-in type |

## Usage

```
/sap-check-abap C:\src\ZPROGRAM.abap DEV_100
/sap-check-abap C:\src\ZPROGRAM.abap           # offline mode (no SAP connection)
```

## Output

Tab-delimited result file (`.check.tsv`) with columns:

```
CHECK_TYPE  SEVERITY  LINE  VARIABLE  SCOPE  DATA_KIND  DETAIL  FIX_ADVICE
```

## Naming Rules

Shared file at `shared/abap_naming_rules.tsv`. Editable by the user.

Standard prefixes:

| Scope | Kind | Prefix |
|---|---|---|
| LOCAL | VARIABLE | lv_ |
| LOCAL | STRUCTURE | ls_ |
| LOCAL | TABLE | lt_ |
| GLOBAL | VARIABLE | gv_ |
| GLOBAL | STRUCTURE | gs_ |
| GLOBAL | TABLE | gt_ |
| PARAM | IMPORTING | iv_ |
| SELECTION | PARAMETER | p_ |

## Pipeline

`sap-gen-abap` → **sap-check-abap** → `sap-fix-abap` → `abap-deploy`

## Prerequisites

- SAP GUI for Windows (32-bit COM: `SAP.Functions`)
- S_RFC authorization for DDIF FMs (online mode only)
- `shared/abap_naming_rules.tsv` in project root

## Directory Structure

```
skills/sap-check-abap/
├── SKILL.md              # Skill workflow definition
├── README.md             # This file
└── references/
    └── sap_check_abap.vbs  # VBScript template
```

Version: 1.0.0 | License: GPL-3.0
