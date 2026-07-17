# /sap-trace — performance / SQL-trace analysis (v1)

Analyzes an **already-recorded** SAP performance trace and ranks the hotspots,
mapping each to an ABAP performance anti-pattern (`abap_code_quality_rules.md §12`)
and a concrete fix, calibrated to the object's volume band.

## Two sources

| Mode | What it does | SAP needed? |
|---|---|---|
| `--import <file>` | Analyze a trace you already exported (ST05 "Summarized SQL Statements" or SAT hit list) | No |
| `--source st05\|sat` | Drive the GUI to **display** the latest recorded trace and export it, then analyze | Yes (GUI) |

v1 reads a trace that already exists. It does **not** activate/deactivate ST05,
start a SAT measurement, or read the SQL Monitor (SQLM) — those are later phases
(see the design notes / roadmap).

## Examples

```
/sap-trace --import C:\sap_dev_work\temp\my_st05_export.txt
/sap-trace --import trace.txt --kind sat --top 30 --threshold-ms 50
/sap-trace --source st05 --user DEVUSER --perf-band large
```

## Offline self-test (no SAP)

```powershell
& ".\references\sap_trace.ps1" `
    -InputFile ".\references\fixtures\st05_summarized_sample.txt" `
    -RuleMap "..\..\shared\tables\perf_antipattern_map.tsv"
```

Expected: 3 hotspots (MARA SELECT-in-loop, VBAP SELECT *, KNA1 full-scan), last
line `HOTSPOTS=3`.

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | Orchestration: arg parsing, GUI export, analyzer call, reporting |
| `references/sap_trace.ps1` | Offline analyzer (normalize → rank → map → report → JSON) |
| `references/sap_trace_st05.vbs` | GUI: display + export ST05 summarized SQL trace (recorded IDs, S/4HANA 1909) |
| `references/sap_trace_sat.vbs` | GUI: open + export a SAT measurement hit list (recorded IDs, S/4HANA 1909) |
| `references/fixtures/st05_summarized_sample.txt` | Fixture for the offline self-test |
| `../../shared/tables/perf_antipattern_map.tsv` | signal → rule → fix map (customer-overridable) |

The GUI templates ship with **real component IDs captured live on S4D /
S/4HANA 1909 (2026-06-03)** — no placeholders to fill before using `--source`.
Re-record with `/sap-gui-probe` only if a later release moves a control. The
ALV-export block is reused from `/sap-se16n` and is already complete.
