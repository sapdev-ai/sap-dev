---
name: sap-log-analyze
description: Summarize sap-dev JSONL log files. Aggregates per-skill counts, success/fail rates, p50/p95 duration, top error_class, and recent FAILED runs (with parent_run_id chain). Filters by --since / --skill / --status. With --builds, instead reconstructs generated-ABAP builds from the same logs and reports first-pass-yield KPIs (gen/check/syntax/activation/ATC/ABAP-Unit) to a dashboard. Reads log_dir from sap-dev-core/settings.json.
---

# /sap-log-analyze

Analyze JSONL log files produced by the shared sap-dev logger
(`sap_log_lib.ps1` / `sap_log_lib.vbs`).

## Shared Resources

| Token / Path | Source | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | rule | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | rule | GUI-scripting language independence — offline log analysis, but rule applies to skills whose logs this analyzes |
| `<SAP_DEV_CORE_SHARED_DIR>` | placeholder | Resolves to `plugins/sap-dev-core/shared/` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_build_kpi.ps1` | script | Builds-mode aggregator (`--builds`): reconstructs builds from the logs, computes first-pass-yield KPIs, writes `{work_dir}\metrics\{build_kpi.jsonl,dashboard.md}` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/build_metrics.md` | rule | `sapdev.buildkpi/1` schema + KPI definitions + the gate-enrichment contract |
| sap-dev-core `settings.json` | `userConfig.work_dir`, `userConfig.log_dir` | Locates log directory |

## Usage

```
/sap-log-analyze
/sap-log-analyze --since 2026-04-01
/sap-log-analyze --skill sap-se11
/sap-log-analyze --status FAILED
/sap-log-analyze --since 2026-04-01 --skill sap-se38 --status FAILED --top 20
/sap-log-analyze --csv C:\sap_dev_work\temp\log_summary.csv
/sap-log-analyze --builds
/sap-log-analyze --builds --since 2026-06-01
```

Flags:
- `--since YYYY-MM-DD` — include records with `ts >= that date` (default: all)
- `--skill <name>` — restrict to one skill (default: all)
- `--status <SUCCESS|FAILED|SKIPPED|EXISTED|ABANDONED>` — filter end-records
- `--top N` — number of recent FAILED runs to display (default 10)
- `--csv <path>` — also write per-skill summary as CSV
- `--builds` — **builds mode**: instead of the per-skill log summary, reconstruct
  one generated-ABAP build per logical generate→check→deploy→ATC→unit-test run
  and report first-pass-yield KPIs + a dashboard. Honours `--since`. See
  `<SAP_DEV_CORE_SHARED_DIR>/rules/build_metrics.md`.

## Steps

## Step 0 — Resolve Work Directory & Log Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys (`log_dir`, …).

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Read:
- `log_dir`  — defaults to `{work_dir}\logs`

If `log_dir` does not exist, report "no logs found" and stop.

## Step 1 — Parse User Flags

Parse the user message for `--builds`, `--since`, `--skill`, `--status`, `--top`, `--csv`.
Defaults: `--top 10`, no other filters.

**If `--builds` is present, go to Step 1.5 and skip Steps 2-4** (builds mode is a
distinct report — it does not also print the per-skill log summary).

## Step 1.5 — Builds Mode (only when `--builds`)

Reconstruct generated-ABAP builds from the same logs and report first-pass-yield
KPIs. This is the offline aggregator described in
`<SAP_DEV_CORE_SHARED_DIR>/rules/build_metrics.md`; it reads only the logs (no
SAP), and its only writes are the derived report under `{work_dir}\metrics\`
(`build_kpi.jsonl` + `dashboard.md`) — analogous to `/sap-cc-campaign report`.

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_build_kpi.ps1" -LogDir "<log_dir>" [-Since <YYYY-MM-DD>]
```

Echo the script's stdout (the `BUILD:` / `METRIC:` / `GROUP:` grammar lines)
verbatim, then show the `dashboard.md` path it reports and offer to display the
dashboard. If the script prints `INFO: no gate events found`, tell the user no
generated-ABAP builds have been logged yet (the KPIs need at least one run of
the gate skills — sap-gen-abap / sap-check-abap / sap-se38 / sap-atc /
sap-run-abap-unit — since their build-KPI enrichment shipped). Then stop.

## Step 2 — Run the Analyzer

Run `<SKILL_DIR>\references\sap_log_analyze.ps1` with the resolved log
directory and any filter flags:

```powershell
& "<SKILL_DIR>\references\sap_log_analyze.ps1" `
    -LogDir <log_dir> `
    [-Since <YYYY-MM-DD>] `
    [-Skill <name>] `
    [-Status <code>] `
    [-Top <N>] `
    [-CsvPath <path>]
```

## Step 3 — Render the Summary

The script prints four sections to stdout:

1. **Overall** — total records, file count, date range covered, total runs (start records).
2. **Per-skill summary** — table: skill / runs / SUCCESS / FAILED / SKIPPED / EXISTED / ABANDONED / p50_ms / p95_ms.
3. **Top error_class** — table: error_class / count / last_seen / sample skills.
4. **Recent FAILED runs** — table: ts / skill / run_id / parent_run_id / error_class / error_msg (truncated 80 chars).

Echo the script output verbatim to the user.

## Step 4 — Optional CSV Export

If `--csv` was supplied, the script writes the per-skill summary to that
path. Confirm the path back to the user.

## Notes

- The analyzer reads only `*.log` and `*.log.*` files in `log_dir`.
- Only **JSONL**-formatted lines are parsed. Lines that fail JSON parsing
  are silently skipped (counted as `bad_lines`). TSV / TEXT logs require
  re-running with `log_format` set back to `JSONL`, or external tooling.
- The analyzer is read-only. It never modifies or deletes log files.
- **Builds mode (`--builds`) is still derived + offline.** It reads only the
  logs and never touches SAP; its sole writes are the derived metrics report
  (`{work_dir}\metrics\build_kpi.jsonl` + `dashboard.md`), exactly as
  `/sap-cc-campaign report` renders a dashboard from a campaign ledger. The KPIs
  are reconstructed after the fact from the gate skills' own end records — there
  is no separate build registry and no per-build instrumentation.
