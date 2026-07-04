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

Type-existence classification is delegated to the shared sidecar helper
`sap-dev-core/shared/scripts/sap_rfc_lookup_ddic.ps1`, which resolves each
unknown type name through this chain (first hit wins) and returns a kind the
VBS maps to `STRUCT` / `TTYP` / `DTEL` / `DOMAIN` / `CLASS` / `UNKNOWN`:

| RFC / catalog | Resolves to | Purpose |
|---|---|---|
| `DDIF_FIELDINFO_GET` | `STRUCT` | Structure / transparent-pool-cluster table; also drives the field list for SQL-field validation |
| `DD40L` (`RFC_READ_TABLE`) | `TTYP` | **Table type** (e.g. `FILETABLE` for `CL_GUI_FRONTEND_SERVICES=>gui_upload`) — resolves row type / row kind |
| `DD04L` (`RFC_READ_TABLE`) | `DTEL` | Data element → underlying built-in type |
| `DD01L` (`RFC_READ_TABLE`) | `DOMAIN` | Domain used directly as a type |
| `SEOCLASS` (`RFC_READ_TABLE`) | `CLASS` | Global class / interface (reached via `TYPE REF TO`) |

`DDIF_FIELDINFO_GET` raises `NOT_FOUND` for everything except structures and
transparent/pool/cluster tables, so table types, data elements, domains, and
classes each need their dedicated catalog table — the checker must not report
`TYPE_NOT_FOUND` merely because a name isn't a structure.

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
