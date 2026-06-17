# SAP Update Add-on Table Skill

Inserts, updates, or deletes records in SAP add-on tables (Y/Z prefix).
Automatically detects the best maintenance method available for the table
and routes to the appropriate transaction.

## Skill Overview

1. Parse: table name + data file (CSV / TSV) + optional operation
   (`INSERT` / `UPDATE` / `DELETE`)
2. Detect the best method via RFC:
   - **(a) SM30** — if a maintenance view exists (preferred)
   - **(b) SE16** — if `DD02L-MAINFLAG = 'X'` (direct table maintenance allowed)
   - **(c) `ZCMRUPDATE_ADDON_TABLE`** — fallback program for any add-on table
     (deployed by `/sap-dev-init`)
3. Drive the chosen transaction via SAP GUI Scripting; load the data file
   row by row
4. Capture errors per row to a result file for review

## Auto-Trigger Keywords

- `update addon table`, `insert into Z table`, `delete from Y table`
- `maintain table`, `load data into ZHK*`
- `populate ZHKFIXEDVALS`, `update ZHK_CONFIG`

## Usage

```text
/sap-update-addon ZHKFIXEDVALS C:\data\fixedvals.csv
/sap-update-addon ZHK_CONFIG C:\data\config.csv UPDATE
/sap-update-addon ZHK_CONFIG C:\data\stale.csv DELETE
```

Conversational forms:

- "Load `C:\data\fixedvals.csv` into ZHKFIXEDVALS"
- "Update ZHK_CONFIG with the new rows from this file"
- "Delete the entries listed in stale.csv from ZHK_CONFIG"

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
- Data file must use the table's exact field order (no header-driven mapping
  yet — feature in roadmap)
- Data file must be **UTF-8**, TAB-delimited, with one header line (all three
  methods — PROG / SE16 / SM30 — read UTF-8)
- **Classic ECC 6.0 + S/4HANA:** the `ZCMRUPDATE_ADDON_TABLE` (PROG) fallback is
  classic-syntax and activates/runs on **both** ECC 6.0 and S/4HANA 1909
  (live-verified on SID ER1 and S4D). The SE16 *Create Entries* (INSERT/UPDATE)
  path uses `tbar[1]/btn[5]` on the SE16 initial screen — the **same** button on
  both releases (the old "S/4 = btn[18]" assumption was wrong) — and is
  live-verified end-to-end on both. The SM30 path still needs a maintenance
  view; SE16 *DELETE* is a stub on all releases (use SM30 or delete manually).

## Version

- Skill Version: 1.1.0
- Last Updated: 2026-06-17

## License

GPL-3.0 License - See LICENSE file in repository root.
