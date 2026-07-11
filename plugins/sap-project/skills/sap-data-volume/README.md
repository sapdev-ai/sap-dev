# sap-data-volume

**Read-only DB growth + archivability evidence over RFC** — the table-growth watch nobody
does until the disk is full or a client copy takes a weekend. Replaces manual DB02/DB15/SARA
spelunking with one repeatable, snapshot-trended command.

```
/sap-data-volume growth [--top N] [--tables A,B] [--z-only] [--max-tables N] [--physical] [--z-threshold N]
/sap-data-volume archivability [--object O] [--table T] [--residence-days N]
```

## What it does

- **growth** (read-only): ranks tables by row count via `EM_GET_NUMBER_OF_ENTRIES` — the fast
  SE16 "Number of Entries" DB-stat count that works on **cluster** tables too — joins the
  DD09L size category, diffs against a **persisted local snapshot** for a rows/day trend, and
  raises two flags: `Z_TABLE_NO_HOUSEKEEPING` (a big Z table with no archiving mapping and
  positive growth) and `LOG_TABLE_LARGE` (a known log offender over threshold). Default scope
  = the offender catalog + Z*/Y* tables (capped by `--max-tables`); `--tables` / `--z-only`
  narrow it. `--physical` adds an estimated physical-size pass via report RSTABLESIZE
  (delegated to /sap-run-report, which asks its own confirm).
- **archivability** (read-only): per archiving object — the archived **tables** (ARCH_DEF),
  the **run history** (ADMI_RUN / ADMI_STATS: last run, count, per-run written/deleted
  stats), and whether a **TAANA age analysis** exists (TAAN_HEAD). `--table` reverse-maps a
  table to its archiving object(s).

## Honest by construction

- Counts are DB-statistics, not live COUNT(*): a non-existent/failed table returns `-1` → a
  `COUNT_FAILED` row, never a fake 0. A table absent from DD02L is `SKIP`ped.
- First `growth` run = `BASELINE_CREATED` (trend `n/a`, never an invented number); later runs
  show real rows/day.
- The per-bucket **age distribution** lives in the TAAN_DATA cluster blob (CLUSTD RAW) which
  RFC_READ_TABLE cannot decode → `age_pct` is `COULD_NOT_CHECK` with a pointer to `analyze`
  (v1.5), never a fabricated percentage.
- **ECC divergence:** CDPOS/EDID4 are CLUSTER on ECC (TRANSP on S/4) — the report attributes
  physical size to the CDCLS/EDI40 cluster; row counts stay exact either way.

## Reads

`DD02L` (existence/class), `DD09L` (size category), `EM_GET_NUMBER_OF_ENTRIES` (counts),
`ARCH_OBJ`/`ARCH_TXT`/`ARCH_DEF` (archiving catalog + table map), `ADMI_RUN`/`ADMI_STATS`
(run history), `TAAN_HEAD` (analysis presence). All FMODE=R / TRANSP, identical on both
releases. Snapshots are local TSV under `{work_dir}\cache\data_volume\<SID>_<CLIENT>\`.

Read-only on SAP; no Z-object, no dev-init — safe to point at production. `analyze` (schedule
a TAANA analysis) is v1.5; `archive-run` (SARA write/delete) is v2 and refused in v1. Verified
live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) 2026-07-11.
