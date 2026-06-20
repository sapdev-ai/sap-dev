# SAP SE16N Table Query Skill

Queries any SAP table via transaction SE16N using SAP GUI Scripting and
downloads the result set as a tab-delimited text file. Supports any combination
of filter fields and any of the SE16N operators (EQ, NE, GT, LT, GE, LE, BT,
NB, CP, NP, IN), with single value, range (BT), or multi-value (IN) selection.

## Skill Overview

1. Read sap-dev-core's settings.json to resolve the work directory
2. Build a side-channel **PARAMS_FILE** (tab-delimited) with two sections:
   - `SELECT` — output column FIELDNAMEs (empty = all fields)
   - `FILTER` — `<FIELDNAME><TAB><OP><TAB><VAL1>[<TAB><VAL2>...]` rows
3. Token-replace `%%TABLE_NAME%%`, `%%PARAMS_FILE%%`, `%%OUTPUT_FILE%%` in the
   VBS template via PowerShell, save as UTF-16
4. Run with 32-bit cscript (`C:\Windows\SysWOW64\cscript.exe`)
5. The VBS opens SE16N, scrolls the field-selection table control to locate
   each filter field by its FIELDNAME (col 6), sets values, runs F8, then
   exports the ALV result list via "Spreadsheet" (tab-delimited)
6. Output file appears at `{WORK_TEMP}\se16n_<TABLE>.txt`

## PARAMS_FILE Format

```
SELECT
<FIELDNAME>
<FIELDNAME>
FILTER
<FIELDNAME><TAB><OP><TAB><VAL1>[<TAB><VAL2>...]
<FIELDNAME><TAB><OP><TAB><VAL1>[<TAB><VAL2>...]
```

Both sections may be empty. SELECT empty = output all fields. FILTER empty =
no row restrictions (full table dump).

| Operator | Meaning | Value count |
|---|---|---|
| EQ / NE / GT / LT / GE / LE | comparison | 1 |
| BT | between | 2 |
| NB | not between | 2 |
| CP | matches pattern (`*`, `+`) | 1 |
| NP | does not match pattern | 1 |
| IN | one of N | 2..N (multi-select popup) |

Multi-value or `IN` automatically routes through SE16N's multi-select popup
(`btnPUSH`).

## Auto-Trigger Keywords

This skill activates when the user says:

- `query table XXX`, `select from XXX`, `dump table XXX`, `download table XXX`
- `se16n XXX`, `se16 XXX`
- combined with any of: `where`, `with`, `field=value`, `IN (...)`, `between`,
  output specifications like `select FIELD1, FIELD2`

## Usage

```text
/sap-se16n T001
/sap-se16n T001 where LAND1 in CN,JP and WAERS = CNY
/sap-se16n MARA where MATKL = 0001 select MATNR,MTART,MATKL,MEINS
/sap-se16n VBAK where ERDAT between 20240101 and 20241231
```

Conversational forms:

- "Get all entries from T001 where Country is CN or JP"
- "Show MARA rows with material group 0001, only MATNR / MTART / MATKL"
- "Dump VBAK created in 2024 to a file"

## Test Case (T001 — Company Code)

Query: `Country (LAND1) ∈ {CN, JP}` AND `Currency (WAERS) = CNY`, output all
fields.

`{WORK_TEMP}\se16n_params.txt`:
```
SELECT
FILTER
LAND1	IN	CN	JP
WAERS	EQ	CNY
```

Expected: at most a handful of rows (the China company codes whose default
currency is CNY). `ROWS=<n>` printed on the last line; output written to
`{WORK_TEMP}\se16n_T001.txt` with the standard T001 header line.

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- The target table must be readable in SE16N for the logged-in user
- 32-bit `cscript.exe` available at `C:\Windows\SysWOW64\cscript.exe`

## Limitations

- No sort / aggregation / saved variant support — use SE16N interactively for
  those
- Output column order follows SAP's natural ordering, not the SELECT list order
- Cluster / pooled tables that SE16N rejects produce `NO_DATA` with the SAP
  status text — pass this back to the user verbatim
- Date literals must be 8-digit `YYYYMMDD` (e.g. `20240131`) — SAP DATS fields
  accept this for any user date format (`USR01-DATFM`), so it is locale-independent;
  a separator form like `YYYY.MM.DD` only works when it matches the user's DATFM.
  Numeric literals must have no thousand separators
- Only the first 8 values per multi-select are guaranteed visible without the
  popup needing scrolling; the VBS scrolls automatically beyond that

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-04-23

## License

GPL-3.0 License - See LICENSE file in repository root.
