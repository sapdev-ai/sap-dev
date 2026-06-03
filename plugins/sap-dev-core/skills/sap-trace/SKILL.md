---
name: sap-trace
description: |
  Analyzes an already-recorded SAP performance trace and ranks the hotspots.
  Two sources: --import <file> reads a trace you exported yourself (fully
  offline, no SAP needed); --source st05|sat drives the GUI to display the
  latest recorded SQL trace (ST05, "Summarized SQL Statements") or runtime-
  analysis hit list (SAT) and exports it as a tab file. The analyzer
  normalizes either shape into a ranked hotspot list, flags anti-patterns
  (SELECT in loop, SELECT *, full-scan, unguarded FOR ALL ENTRIES, many
  executions, ABAP-side hotspots), maps each to a rule in
  abap_code_quality_rules.md and to the object's volume band, and proposes a
  fix. This v1 reads a trace that ALREADY EXISTS — it does not activate/
  deactivate ST05 or start a SAT measurement (capture orchestration is a later
  phase), and does not read SQL Monitor (SQLM).
  Pure read-only — never modifies the SAP system.
  Prerequisites: for --source, an active SAP GUI session (use /sap-login
  first); for --import, none.
argument-hint: "[--import <file>] [--source st05|sat] [--kind st05|sat|auto] [--user <u>] [--top N] [--threshold-ms N] [--perf-band small|medium|large] [--with-source] [--output <path>]"
---

# SAP Performance / SQL-Trace Analysis Skill

You take a recorded SAP performance trace (ST05 SQL trace or SAT runtime
analysis), rank the most expensive statements / units, map each to a known
ABAP performance anti-pattern, and suggest a concrete fix calibrated to the
object's volume band. The trace either already exists as an exported file
(`--import`) or is displayed-and-exported from the live GUI (`--source`).

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only skill |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar via `MessageType` codes (S/W/E/I/A), VKey over menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | *(rule)* | Performance gates (§12) the analyzer maps findings back to |
| `<SAP_DEV_CORE_SHARED_DIR>/templates/customer_brief.md` | *(template)* | Source of the object's volume band (small/medium/large) when `--perf-band` is not given |
| `<SAP_DEV_CORE_SHARED_DIR>/tables/perf_antipattern_map.tsv` | *(table)* | Maps a detected trace signal → §12 rule → fix template |
| `<SKILL_DIR>/references/sap_trace.ps1` | *(script)* | Offline analyzer: normalize → rank → map → render report |
| `<SKILL_DIR>/references/sap_trace_st05.vbs` | many | GUI: display latest ST05 trace, switch to summarized view, export tab file |
| `<SKILL_DIR>/references/sap_trace_sat.vbs` | many | GUI: open a SAT measurement, display hit list, export tab file |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_attach_lib.vbs` | `%%ATTACH_LIB_VBS%%` | Parallel-safe session attach (GUI path) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(script)* | Structured run logging |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Read:

| Setting | Default if blank |
|---|---|
| `trace_threshold_ms` | `100` |
| `trace_top_n` | `20` |

Set `{WORK_TEMP}` = `{work_dir}\temp` and `{TRACE_OUT}` = `{work_dir}\trace`. Ensure both exist:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
cmd /c if not exist "{TRACE_OUT}" mkdir "{TRACE_OUT}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_trace_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_trace_run.json" -Skill sap-trace -ParamsJson "{\"source\":\"<SOURCE>\"}"
```

---

## Step 1 — Parse Arguments

| Flag | Meaning | Default |
|---|---|---|
| `--import <file>` | Analyze an already-exported trace file (offline; no SAP) | — |
| `--source st05\|sat` | Drive the GUI to display + export the latest recorded trace | — |
| `--kind st05\|sat\|auto` | Format of the `--import` file when auto-detection is ambiguous | `auto` |
| `--user <u>` | ST05 display filter (whose trace to show) | pinned SAP user |
| `--from <HH:MM> --to <HH:MM>` | ST05 display time window | last 10 min |
| `--measurement <id>` | SAT: which saved measurement to open | latest |
| `--top N` | Max hotspots reported | `trace_top_n` (20) |
| `--threshold-ms N` | Surface statements whose total time ≥ N ms | `trace_threshold_ms` (100) |
| `--perf-band small\|medium\|large` | Volume band override | from customer brief |
| `--with-source` | Best-effort: annotate the offending program/include/line | off |
| `--output <path>` | Also write the normalized JSON here | `{TRACE_OUT}\<kind>_<ts>.json` |

Exactly one of `--import` / `--source` must be present. If neither → print
`ERROR: specify --import <file> or --source st05|sat` and stop.

If `--perf-band` is not supplied, read the volume band from the customer brief
(resolved per the Template Language Resolution order) for the matching object
kind (online=small, report=medium, batch=large, interface=medium); fall back to
`medium` if absent.

---

## Step 2 — Select the Trace Source

- **`--import <file>`** → skip to **Step 4** (analyzer), passing the file and `--kind`.
- **`--source st05|sat`** → ensure an active SAP GUI session (use `/sap-login`
  first if needed), then proceed to **Step 3** to display + export the trace.

> v1 displays a trace that **already exists**. For ST05 the trace must have
> been recorded (Activate Trace → run the workload → Deactivate) beforehand; for
> SAT a measurement must already be saved. Orchestrating the recording itself is
> a later phase.

---

## Step 3 — Display & Export the Recorded Trace (GUI path)

The export-to-local-file step is SAP-GUI-side file IO, so it raises the modal
**SAP GUI Security** dialog when the path isn't allow-listed — handle it exactly
as `/sap-se16n` does (pre-check + OS-level sidecar watcher around the blocking
cscript). The VBS identifies controls by recorded component IDs; the
ST05/SAT-specific IDs are shipped as `PH_*` **placeholder constants** (see
**Component IDs** below) — capture them once with `/sap-gui-record` or
`/sap-gui-probe` on your release and fill them in before first use. The ALV
export block at the bottom of each template already uses the known SE16N-style
IDs.

### Generate the filled-in VBScript

Pick the template by source: `sap_trace_st05.vbs` or `sap_trace_sat.vbs`.
Write `{WORK_TEMP}\sap_trace_run.ps1`:

```powershell
$tpl = '<SKILL_DIR>\references\sap_trace_st05.vbs'   # or ..._sat.vbs
$out = '{WORK_TEMP}\trace_st05_RUNTS.txt'             # RUNTS = a timestamp string
$content = Get-Content $tpl -Raw
$content = $content -replace '%%OUTPUT_FILE%%', $out
$content = $content -replace '%%FILTER_USER%%', 'THE_USER'
$content = $content -replace '%%FROM_TIME%%',   'HH:MM:SS'
$content = $content -replace '%%TO_TIME%%',     'HH:MM:SS'
$content = $content -replace '%%MEASUREMENT%%', 'THE_MEASUREMENT'   # SAT only; '' = latest
# Session-attach plumbing (Phase 4.2). AttachSapSession resolves the target
# session: SESSION_PATH constant -> SAPDEV_SESSION_PATH env var ->
# sole-connection default -> refuse loud.
$sessionPath = ''   # set to the parsed --session value if supplied
$content = $content -replace '%%SESSION_PATH%%',   $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_trace_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```

Replace `RUNTS` / `THE_USER` / `HH:MM:SS` / `THE_MEASUREMENT` and the
`<SKILL_DIR>` / `{WORK_TEMP}` placeholders with their real values.

Run:

```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_trace_run.ps1"
```

### Execute (with SAP GUI Security guard)

Per `shared/rules/sap_gui_security_handling.md`, pre-check the allow-list and run
the OS-level watcher around the blocking export. Substitute `THE_SID` /
`THE_CLIENT` with the pinned system / client:

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$out    = '{WORK_TEMP}\trace_st05_RUNTS.txt'
& "$shared\sap_gui_security_precheck.ps1" -Path $out -Access w -System 'THE_SID' -Client 'THE_CLIENT' -Transaction 'ST05' | Out-Host
$allowed = ($LASTEXITCODE -eq 0)
$watcher = $null
if (-not $allowed) {
    $watcher = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','40')
    Start-Sleep -Milliseconds 800
}
& 'C:/Windows/SysWOW64/cscript.exe' //NoLogo '{WORK_TEMP}\sap_trace_run.vbs'
if ($watcher) { $watcher | Wait-Process -Timeout 45 -ErrorAction SilentlyContinue }
```

The VBS prints a parseable last line:

| Last line | Meaning |
|---|---|
| `EXPORTED=<path> rows=<n>` | Trace displayed and exported (n data rows). Proceed to Step 4 with this file. |
| `TRACE_EMPTY: <reason>` | No trace records for the filter (e.g. trace not recorded, or window has no rows). Report to user and stop. |
| `ERROR: …` | GUI failure — show output and stop. |

---

## Step 4 — Run the Analyzer

Feed the trace file (from `--import` or the Step 3 export) to the offline
analyzer — same model as `/sap-log-analyze`:

```powershell
& "<SKILL_DIR>\references\sap_trace.ps1" `
    -InputFile <trace_file> `
    -Kind <st05|sat|auto> `
    -Top <N> `
    -ThresholdMs <N> `
    -PerfBand <small|medium|large> `
    -RuleMap "<SAP_DEV_CORE_SHARED_DIR>\tables\perf_antipattern_map.tsv" `
    -OutputJson <output_path> `
    [-WithSource]
```

The analyzer:
1. **Detects the shape** (ST05 "Summarized SQL Statements" vs SAT hit list) by
   header keywords (EN tested; falls back to positional) and normalizes each row
   into a hotspot record (`kind`, `object`, `statement`, `executions`,
   `identical`, `records`, `total_ms`, `avg_ms`, `src_program`, `flags`).
2. **Ranks** by `total_ms` and keeps the top `N` at or above `--threshold-ms`.
3. **Flags anti-patterns** and maps each to a §12 rule via `perf_antipattern_map.tsv`
   (high `identical` → *SELECT in loop*; `SELECT *` in the statement → *SELECT \**;
   very high records-per-execution → *full scan*; no restrictive WHERE →
   *NO_WHERE*; SAT net-time units → *ABAP hotspot*).
4. **Calibrates** severity to `--perf-band` (a 200 ms statement is fine for a
   `small` online txn, a red flag in a `large` batch job).
5. With `--with-source`, best-effort annotates the offending program/include/line
   from the trace columns (full source pull is a later enhancement).
6. Prints a markdown report and writes the normalized JSON to `--output`.

---

## Step 5 — Interpret the Output

**Last line of stdout:**

| Last line | Meaning |
|---|---|
| `HOTSPOTS=<n>` (n ≥ 1) | `n` hotspots above threshold. JSON written to `--output`; report printed above. |
| `TRACE_EMPTY: <reason>` | Parsed file had no rows above threshold, or no parseable rows. Non-fatal — report the reason. |
| `ERROR: …` | Parse/IO failure — show the full output and stop. |

---

## Step 6 — Report Results

Echo the analyzer's report verbatim, then summarize for the user:
- Source (import file or ST05/SAT) and the object/filter analyzed.
- The top hotspots: for each — object/statement, total time, executions, the
  matched anti-pattern (rule ref), and the suggested fix.
- The volume band used and the JSON path.
- If `TRACE_EMPTY`: state why (e.g. trace not recorded, all rows below threshold)
  and how to get a useful trace (record an ST05 trace around the workload, or
  lower `--threshold-ms`).

---

## Final — Log End

Best-effort. On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_trace_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_trace_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `TRACE_QUERY_FAILED` (GUI display/export), `TRACE_PARSE_FAILED`
(analyzer), `TRACE_EMPTY` (no usable rows), `GUI_TIMEOUT`.

---

## Offline self-test

The analyzer is fully testable without SAP. A fixture ST05 export ships at
`<SKILL_DIR>/references/fixtures/st05_summarized_sample.txt`:

```powershell
& "<SKILL_DIR>\references\sap_trace.ps1" -InputFile "<SKILL_DIR>\references\fixtures\st05_summarized_sample.txt" -RuleMap "<SAP_DEV_CORE_SHARED_DIR>\tables\perf_antipattern_map.tsv"
```

Expected: 3 hotspots (MARA SELECT-in-loop, VBAP SELECT *, KNA1 full-scan),
last line `HOTSPOTS=3`.

---

## Component IDs (for reference / debugging)

The two GUI templates ship with **recorded-ID placeholders** (`PH_*` constants)
— capture/verify them on first run per release with `/sap-gui-record` or
`/sap-gui-probe`, then replace each `PH_*` constant in the VBS. The ALV export
mechanism (`pressToolbarContextButton "&MB_EXPORT"` → `selectContextMenuItem "&PC"`
→ "Text with Tabs" radio → `wnd[1]/usr/ctxtDY_PATH` + `ctxtDY_FILENAME`) is reused
verbatim from `/sap-se16n` and is already filled in.

**ST05** (`sap_trace_st05.vbs`) — **captured live on S4D / S/4HANA 1909 (2026-06-03):**
`Display Trace` = `wnd[0]/tbar[1]/btn[7]` (F7); the restriction step is a **full
`wnd[0]` screen** (`R_ST05_TRACE_FILTER`, *not* a popup) with `ctxtUSER-LOW` /
`ctxtFROMTIME` / `ctxtTOTIME` (+ `ctxtFROMDATE`/`ctxtTODATE`) and Execute
`wnd[0]/tbar[1]/btn[8]` (F8); Summarize = menu `wnd[0]/mbar/menu[0]/menu[0]`
("Structure-Identical Statements", use `.select`); `RESULT_GRID` =
`wnd[0]/usr/cntlGUI_CONTROL_CONTAINER/shellcont/shell` (GridView). A `wnd[1]`
info popup after Execute ("Cannot open kernel trace file …") = no readable trace
→ the template dismisses it and reports `TRACE_EMPTY`.

**SAT** (`sap_trace_sat.vbs`) — **captured live on S4D / S/4HANA 1909 (2026-06-03):**
Evaluate tab `wnd[0]/usr/tabsTS_START/tabpLIST` (`.select`); measurements list
`…/tabpLIST/ssubLIST_REF1:SAPLS_ABAP_TRACE_DATA:0102/cntlCONTENT_CONTROL/shellcont/shell`;
open a measurement by **double-click** (`setCurrentCell` + `doubleClickCurrentCell`);
Hit List tab `…/SAPLATRA_TOOL_SE30_AGG_MAIN:0300/tabsTAB_MAIN/tabpMAIN_TAB_HIT` (`.select`);
`RESULT_GRID` = `…/tabpMAIN_TAB_HIT/ssubFULL:SAPLATRA_TOOL_HITLIST:0100/cntlCONTROL_HIT/shellcont/shell`.
The evaluation-desktop ids embed program/screen names that may shift across releases.

---

## Limitations

- **v1 analyzes an already-recorded trace.** It does not Activate/Deactivate
  ST05 or start a SAT measurement (capture orchestration is a later phase), and
  does not read SQL Monitor (SQLM, the zero-GUI source-line-mapped path) — that
  is v2.
- **ST05 traces are per-application-server and short-lived** — display/export
  promptly, and use ST05's "in other servers" option if the workload ran on a
  different app server.
- **Header detection is tuned for EN exports.** For JA/DE exports use `--kind`
  to force the shape; a future `--columns` override will map non-EN headers.
- **Full-scan / index detection is heuristic** (records-per-execution). Confirm a
  suspected full scan via the ST05 *Explain* (execution plan) manually — plans
  differ across HANA vs AnyDB.
- **ST05 export is a direct grid read** (`ColumnOrder`/`GetCellValue` → TSV), so
  `--source st05` does **not** trigger the SAP GUI Security dialog and reads
  currently-loaded rows; very large summarized grids may need scrolling (v1 covers
  typical trace volumes). The ST05 statement text elides the SELECT field list
  ("SELECT WHERE …"), so `SELECT_STAR` rarely fires on a live ST05 trace — that
  signal is mainly for imported / explicit-statement sources.
- **GUI control IDs:** both ST05 and SAT are captured/confirmed on S4D / 1909.
  The SAT evaluation-desktop ids embed program/screen names (e.g.
  `SAPLATRA_TOOL_SE30_AGG_MAIN:0300`) that can shift across releases — re-verify
  with `/sap-gui-probe` per release. Both GUI exports read the ALV grid directly
  (no SAP GUI Security dialog).
- **Authorizations:** `--source` needs ST05/SAT display authorization; without
  it the VBS returns `ERROR: trace not readable by <user>`.
- The skill never activates traces, never writes to SAP, and never deletes trace
  data — pure read-only.
