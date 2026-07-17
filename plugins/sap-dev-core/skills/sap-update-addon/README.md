# SAP Update Add-on Table Skill

Inserts or updates records in SAP add-on tables (Y/Z prefix); DELETE is not
automated on any method path (refused before touching data — drive SM30
manually for row deletion). Automatically detects the best maintenance method
available for the table and routes to the appropriate transaction.

## Skill Overview

1. Parse: table name + data file (UTF-8, TAB-delimited text, one header line)
   + optional operation (`INSERT` / `UPDATE`; `DELETE` is refused with
   exit 1 on all three methods)
2. Detect the best method via RFC:
   - **(a) SM30** — if a maintenance view exists (preferred)
   - **(b) SE16** — if `DD02L-MAINFLAG = 'X'` (direct table maintenance allowed)
   - **(c) `ZCMRUPDATE_ADDON_TABLE`** — fallback program for any add-on table
     (deployed by `/sap-dev-init`)
3. Drive the chosen transaction via SAP GUI Scripting; load the data file
   row by row
4. Capture errors per row to a result file for review

## Auto-Trigger Keywords

- `update addon table`, `insert into Z table`
- `delete from Y table` — triggers the skill, which **refuses** DELETE and
  points to manual SM30
- `maintain table`, `load data into ZHK*`
- `populate ZHKFIXEDVALS`, `update ZHK_CONFIG`

## Usage

```text
/sap-update-addon ZHKFIXEDVALS C:\data\fixedvals.txt
/sap-update-addon ZHK_CONFIG C:\data\config.txt UPDATE
```

Conversational forms:

- "Load `C:\data\fixedvals.txt` into ZHKFIXEDVALS"
- "Update ZHK_CONFIG with the new rows from this file"

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- SAP NCo 3.1 in the GAC (for the method-detection RFC calls)
- Authorisation S_TABU_DIS (or S_TABU_NAM for SE16) for the target table
- For method (c): `ZCMRUPDATE_ADDON_TABLE` must already be deployed (run
  `/sap-dev-init` to deploy it)

## Limitations

- Customer namespace only (Z*/Y*) — never touches SAP standard tables (per
  the skill operating rules)
- Maximum row count per call ~10000 (SAP GUI scripting throughput limit;
  split larger loads)
- The data file's header line carries the target field names (uppercase,
  MANDT excluded); columns are mapped by header name, not position, on all
  three methods. The PROG (`ZCMRUPDATE_ADDON_TABLE`) method additionally
  requires the header to list ALL non-MANDT fields of the table (exact set,
  any order) — a column-count or missing-field mismatch fails loud before
  any row is written
- Data file must be **UTF-8**, TAB-delimited, with one header line (all three
  methods — PROG / SE16 / SM30 — read UTF-8)
- **Classic ECC 6.0 + S/4HANA:** the `ZCMRUPDATE_ADDON_TABLE` (PROG) fallback is
  classic-syntax and activates/runs on **both** ECC 6.0 and S/4HANA 1909
  (live-verified on SID ER1 and S4D). The SE16 *Create Entries* (INSERT/UPDATE)
  path uses `tbar[1]/btn[5]` on the SE16 initial screen — the **same** button on
  both releases (the old "S/4 = btn[18]" assumption was wrong) — and is
  live-verified end-to-end on both. The SM30 path still needs a maintenance
  view; SE16 *DELETE* is a stub on all releases (drive SM30 manually).
- **PROG selection-screen labels:** `ZCMRUPDATE_ADDON_TABLE` assigns its
  selection texts (アップロード / ダウンロード / テーブル名 / ファイルパス) at
  runtime in `INITIALIZATION` via the release-independent `%_<name>_%_app_%-text`
  fields, because the program is deployed **source-only** (no text-pool upload).
  Without that the screen renders the raw technical names (`RB_UP` / `RB_DOWN` /
  `P_TABLE` / `P_FILE`).

## Version

- Skill Version: 1.1.1
- Last Updated: 2026-06-17

## License

GPL-3.0 License - See LICENSE file in repository root.
