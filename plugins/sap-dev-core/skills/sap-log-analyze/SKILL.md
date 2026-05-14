---
name: sap-log-analyze
description: Summarize sap-dev JSONL log files. Aggregates per-skill counts, success/fail rates, p50/p95 duration, top error_class, and recent FAILED runs (with parent_run_id chain). Filters by --since / --skill / --status. Reads log_dir from sap-dev-core/settings.json.
---

# /sap-log-analyze

Analyze JSONL log files produced by the shared sap-dev logger
(`sap_log_lib.ps1` / `sap_log_lib.vbs`).

## Shared Resources

| Token / Path | Source | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | rule | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>` | placeholder | Resolves to `plugins/sap-dev-core/shared/` |
| sap-dev-core `settings.json` | `userConfig.work_dir`, `userConfig.log_dir` | Locates log directory |

## Usage

```
/sap-log-analyze
/sap-log-analyze --since 2026-04-01
/sap-log-analyze --skill sap-se11
/sap-log-analyze --status FAILED
/sap-log-analyze --since 2026-04-01 --skill sap-se38 --status FAILED --top 20
/sap-log-analyze --csv C:\sap_dev_work\temp\log_summary.csv
```

Flags:
- `--since YYYY-MM-DD` — include records with `ts >= that date` (default: all)
- `--skill <name>` — restrict to one skill (default: all)
- `--status <SUCCESS|FAILED|SKIPPED|EXISTED|ABANDONED>` — filter end-records
- `--top N` — number of recent FAILED runs to display (default 10)
- `--csv <path>` — also write per-skill summary as CSV

## Steps

## Step 0 — Resolve Work Directory & Log Directory

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `plugins/sap-dev-core/settings.local.json` over `plugins/sap-dev-core/settings.json` per-key on the `.value` field; writes always go to the local file. Read:
- `work_dir` — defaults to `C:\sap_dev_work`
- `log_dir`  — defaults to `{work_dir}\logs`

If `log_dir` does not exist, report "no logs found" and stop.

## Step 1 — Parse User Flags

Parse the user message for `--since`, `--skill`, `--status`, `--top`, `--csv`.
Defaults: `--top 10`, no other filters.

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
