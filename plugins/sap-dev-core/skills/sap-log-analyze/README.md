# SAP Log Analyze Skill

Summarises the JSONL log files produced by the shared sap-dev logger
(`sap_log_lib.ps1` / `sap_log_lib.vbs`). Reports per-skill counts, success
/ fail rates, p50 / p95 duration, the top `error_class` values, and recent
FAILED runs with their parent_run_id chain.

Read-only. Never modifies log files.

## Skill Overview

1. Resolve `log_dir` from `sap-dev-core/settings.json` (default
   `{work_dir}\logs`)
2. Read every `.log` file matching `log_file_pattern` (default
   `sap-dev-{YYYYMMDD}.log`)
3. Parse each line as JSONL (TSV / TEXT lines are counted as `bad_lines` and
   skipped)
4. Print four sections to stdout:
   - **Overall** — file count, record count, date range, phase totals
   - **Per-skill summary** — runs / SUCCESS / FAILED / SKIPPED / EXISTED /
     ABANDONED counts plus p50 / p95 `duration_ms`
   - **Top error_class** — counts, last_seen, sample skills
   - **Recent FAILED runs** — `run_id`, `parent_run_id` chain, `error_class`,
     truncated `error_msg`

## Auto-Trigger Keywords

- `log analyze`, `analyze logs`, `summarize logs`
- `which skills failed today`, `top errors this week`
- `log report`, `log summary`

## Usage

```text
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
- `--csv <path>` — also write the per-skill summary as CSV

Conversational forms:

- "Summarise this week's sap-dev logs"
- "Which skills failed most often today?"
- "Export per-skill stats since April 1 to a CSV"

## Prerequisites

- The sap-dev logger must be enabled (`log_enabled=true`, default)
- Log format must be `JSONL` (default) — TSV/TEXT formats produce no analysis
- At least one log file must exist (run any skill once to seed)

## Limitations

- JSONL only — TSV / TEXT log formats are skipped (counted as `bad_lines`)
- No remote log aggregation — reads local files in `log_dir` only

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
