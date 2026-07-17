---
name: sap-data-volume
description: |
  Read-only DB growth + archivability evidence over RFC — the table-growth watch nobody
  does until the disk is full. `growth` ranks tables by row count (EM_GET_NUMBER_OF_ENTRIES,
  fast DB-stat counts that work on cluster tables too), diffs against a persisted local
  snapshot for a rows/day trend, and flags known log-table offenders (BALDAT, EDID4, CDPOS,
  DBTABLOG) and Z tables that lack housekeeping. `archivability` maps each archiving object
  to its tables (ARCH_DEF), pulls its run history (ADMI_RUN/ADMI_STATS), and reports whether
  a TAANA age analysis exists. Replaces manual DB02/DB15/SARA spelunking. Prerequisites:
  pinned profile via /sap-login (RFC); SAP NCo 3.1 (32-bit). No GUI, no Z-object, no
  dev-init — safe to point at production. `analyze` (schedule TAANA) is v1.5; `archive-run`
  (SARA write/delete) is v2 and refused in v1.
argument-hint: "growth [--top N] [--tables A,B] [--z-only] [--max-tables N] [--physical]  |  archivability [--object O] [--table T] [--residence-days N]"
---

# SAP Data Volume — Growth & Archivability (read-only)

Automate the read-only DB-volume evidence pass: ranked table growth with a local snapshot
trend, log-table + Z-housekeeping flags, and per-archiving-object history + analysis
coverage — all over RFC with honest COULD_NOT_CHECK where a source is absent on the release.

Task: $ARGUMENTS

**Pure read-only on SAP** in every v1 mode (RFC_READ_TABLE + EM_GET_NUMBER_OF_ENTRIES).
The only local write is the growth snapshot file. `--physical` delegates report RSTABLESIZE
to /sap-run-report, which asks its **own** Rule-5 confirm — this skill never pre-answers it.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_data_volume_rfc.ps1` | `-Action growth\|archivability … -OutDir` | The two RFC modes → growth.tsv / archivability.tsv |
| `<SKILL_DIR>/references/sap_data_volume_offenders.tsv` | catalog | Known log/growth tables + archiving object + ECC physical cluster; override at `{custom_url}\sap_data_volume_offenders.tsv` |
| `/sap-run-report` (Skill tool) | RSTABLESIZE / RSSPACECHECK | `--physical` size pass (its own Rule-5 confirm) |
| `/sap-sp02` (Skill tool) | spool → file | `--physical` spool collection |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | Step 6 | Artifact index for /sap-evidence-pack |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | Step 0.5 / Final | Structured run logging |

---

## Step 0 — Resolve Work Directory, OUT, Snapshot Dir

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('STAMP=' + (Get-Date -Format 'yyyyMMddHHmmss')); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Resolve the pinned connection's SID+client. Set `{RUN_TEMP}` = the `RUN_TEMP=` value printed
above (`Get-SapRunTemp` mints + creates the per-run scratch dir holding the log state file;
mint it once here and reuse — re-minting breaks the `-Action end` state-file lookup);
`{OUT}` = `Get-SapArtifactDir
-ScopeKey SYS_<SID>_<CLIENT> -Skill sap-data-volume`. **Snapshot dir (Bucket A, durable — NOT
temp):** `{work_dir}\cache\data_volume\<SID>_<CLIENT>` (the engine derives the real SID+client
live from RFC_SYSTEM_INFO / USR02, so pass this dir and it self-creates).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_data_volume_run.json" -Skill sap-data-volume -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments & Mode

- **growth** (default): `--top N` (report cutoff, default 20), `--tables A,B` (explicit
  scope; else offenders + Z*/Y* tables), `--z-only` (only Z*/Y*), `--max-tables N`
  (default 200), `--physical` (Step 5 size pass), `--z-threshold N` (Z-housekeeping row
  threshold, default 1000000).
- **archivability**: `--object O1,O2`, `--table T1,T2` (reverse-map via ARCH_DEF), or
  neither (default = objects with run history), `--residence-days N`.
- **analyze** → **v1.5**: say `NOT_YET_IMPLEMENTED — schedules a TAANA batch job (Rule 5);
  ships in v1.5 with a recorded GUI leg` and STOP.
- **archive-run** → **v2**: **hard refuse** — `archive-run drives SARA write/delete and is
  deferred to phase 2; refused in v1` and STOP. Never attempt it.

## Step 2 — Ensure RFC Profile

Pinned via /sap-login. A GUI session is required **only** for the `--physical` delegation
chain (/sap-run-report), not for the RFC reads.

## Step 3 — growth (read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_data_volume_rfc.ps1" -Action growth -MaxTables <N> -OffenderFile "<SKILL_DIR>\references\sap_data_volume_offenders.tsv" -SnapshotDir "{work_dir}\cache\data_volume\<SID>_<CLIENT>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutDir "{OUT}"
```

Add `-Tables "A,B"` / `-ZOnly` / `-ZThreshold N` per args. Parse `DATAVOL:` (per-table
row/class/sizecat/delta/perday), `DATAVOL_FLAG:` (Z_TABLE_NO_HOUSEKEEPING / LOG_TABLE_LARGE),
`DATAVOL_SNAPSHOT:` (BASELINE_CREATED first run — trend `n/a`, honest — else DELTA),
`DATAVOL_SKIP:` (table not in DD02L), and `STATUS:`. A connect failure → exit 2,
`RFC_LOGON_FAILED`, **no verdict**. A `COUNT_FAILED` row is tri-state — never rendered as 0.
The engine writes `growth.tsv` and the snapshot.

Render `growth_report.md` into `{OUT}`: top-N table with rows / class / size-cat / delta /
per-day, then the flags section, then (on ECC) the cluster-attribution note for CDPOS/EDID4
(physical size is on CDCLS/EDI40 — `EM_GET_NUMBER_OF_ENTRIES` still counts them fine, verified
live). **Grounding rule: every row traces to growth.tsv.** State the window is
snapshot-to-snapshot (first run = baseline).

## Step 4 — archivability (read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_data_volume_rfc.ps1" -Action archivability -Object "<O>" -ResidenceDays <N> -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutDir "{OUT}"
```

Use `-ArchTable "T"` for the reverse map. Parse `DATAVOL_ARCH:` (object / text / tables /
last-run / runs / analysis / entry-cnt) + `STATUS:`. The engine writes `archivability.tsv`.
Render `archivability_report.md`: per object — description, archived tables, run history
(last run + count + status), and TAANA analysis coverage. **Honesty:** the per-bucket age
distribution lives in the TAAN_DATA cluster blob (CLUSTD RAW), which RFC_READ_TABLE cannot
decode — so `age_pct` is `COULD_NOT_CHECK` with a pointer to `analyze` (v1.5), never a
fabricated percentage. `analysis=ABSENT` means no TAANA analysis exists for the object's
tables — suggest `/sap-data-volume analyze <TABLE>` (v1.5).

## Step 5 — --physical (optional, growth only)

If `--physical`: for the top offenders, invoke **/sap-run-report** (Skill tool) for
`RSTABLESIZE` (background), then **/sap-sp02** to collect the spool, and parse the estimated
physical size into the physical column. /sap-run-report runs its **own** Rule-5 confirm —
surface it, never pre-answer. Unparseable spool → `COULD_NOT_CHECK` for the physical column
only (`DATAVOL_PARSE_FAILED` if `--strict`), never a fake size.

## Step 6 — Register & Log End

Register `growth.tsv` (kind `data_volume_report`), the snapshot (kind
`data_volume_snapshot`), `archivability.tsv` (kind `archivability_report`), and the rendered
`*_report.md` via `Register-SapArtifact` under scope `SYS_<SID>_<CLIENT>` with Coverage =
counted/scope and Verdict = check-result status (analytical skill — no gate). Echo:

```
DATAVOL: <mode> tables=<n> flagged=<k> counted=<c>/<scope> could_not_check=<z>
```

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_data_volume_run.json" -Status SUCCESS -ExitCode 0
```

---

## Scope & Limitations

- **v1 implemented:** `growth` (row-count ranking via EM_GET_NUMBER_OF_ENTRIES + DD09L size
  category + local snapshot rows/day trend + offender & Z-housekeeping flags; optional
  `--physical` via /sap-run-report) and `archivability` (ARCH_DEF table map, ADMI_RUN/
  ADMI_STATS run history, TAAN_HEAD analysis presence). Read-only on SAP.
- **Single code path on ECC 6 and S/4HANA** — every FM/table exists identically; verified
  live on S4D (S/4HANA 1909: BALDAT 2.28M, CDPOS 982K, DD02L 834K; ZTGP300 flagged) and ERP
  (ECC 6: EDID4 6.4M + CDPOS 5.9M as CLUSTER, AM_ASSET 16 archiving runs / 23 tables,
  DBTABLOG TAANA analyses) 2026-07-11.
- **Counts are fast DB-statistics** (EM_GET_NUMBER_OF_ENTRIES), not live COUNT(*) — they
  work on cluster tables (EDID4/CDPOS on ECC) and are the SE16 "Number of Entries" figure.
  A non-existent/failed table returns `-1` → a `COUNT_FAILED` row, never a fake 0.
- **ECC divergence (probe-driven):** CDPOS/EDID4 are CLUSTER on ECC (TRANSP on S/4) — the
  report attributes physical size to the CDCLS/EDI40 cluster and says so; row counts are
  still exact.
- **Honesty (tri-state):** first run = `BASELINE_CREATED` (trend `n/a`, never invented);
  a table absent from DD02L = `SKIP`; a TAANA age distribution is `COULD_NOT_CHECK` (cluster
  blob) with a pointer to `analyze`. Snapshot window is snapshot-to-snapshot (workstation
  clock); scope is capped by `--max-tables` (default 200), stated in the report.
- **Residence times** have no generic cross-object table — v1 takes `--residence-days` /
  `--residence-file` and says so; without a decodable TAANA distribution the "% older than
  residence" stays COULD_NOT_CHECK.
- **Not yet:** `analyze` (schedule a TAANA analysis via a to-be-recorded TAANA GUI leg —
  v1.5; no VBS ships yet: emit `NEEDS_RECORDING` and capture it once via
  `/sap-gui-probe --record`); `archive-run` (SARA write/delete — v2, refused in v1); DB02
  physical-size GUI export (release/DB-specific — NEEDS_RECORDING extension point).
