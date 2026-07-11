---
name: sap-st22
description: |
  /sap-diagnose reader: ABAP runtime-error (short dump) evidence from ST22 in GUI
  mode (ADT not used; SNAP is a cluster table, so dumps are read by driving ST22
  via SAP GUI Scripting). Read-only: sets the date/user selection, displays the
  dump list, and scrapes it into the shared diagnose evidence contract. With --deep
  it also opens each in-scope dump and scrapes the failing source line + snippet
  into the event's include/line + a dump_detail object (what /sap-fix-incident
  consumes to root-cause a dump); deep is strictly additive — a deep failure
  degrades to partial/skipped and never loses the list-level evidence. Component
  IDs vary by release: the reader tries candidates and degrades to a clean
  skipped/partial with a /sap-gui-probe --record hint. After scraping, it
  fingerprints each dump (SHA1 of exception|program[|include|line]) into a
  team-shareable recurrence ledger and prints a NEW / KNOWN_RECURRING / GONE
  delta (--no-fingerprint opts out; best-effort, never changes the verdict).
  Usually invoked by /sap-diagnose; runs standalone.
  Prerequisites: active SAP GUI session (/sap-login first); RZ11
  sapgui/user_scripting = TRUE.
argument-hint: "[--anchor PATH] [--user U] [--date today|YYYYMMDD] [--window MIN] [--session PATH] [--out PATH] [--top-n N] [--deep] [--dump-key KEY] [--max-deep N] [--no-fingerprint]"
---

# SAP ST22 Dump Reader (Diagnose, GUI)

You drive ST22 read-only, display the dump list for the incident window, and
emit one evidence event per dump. GUI mode — no ADT.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | Address controls by ID; status via MessageType; VKey navigation; no text branching. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_attach_lib.vbs` | `%%ATTACH_LIB_VBS%%` | Parallel-safe session attach (`AttachSapSession`). |
| `<SKILL_DIR>/references/sap_st22_read.vbs` | *(reader)* | ST22 navigation + dump-list scrape → evidence JSON. |
| `<SKILL_DIR>/references/sap_st22_fingerprint.ps1` | *(local)* | Dump fingerprint + recurrence ledger (`{custom_url}\ops_kb\dump_fingerprints.tsv`); NEW/KNOWN_RECURRING/GONE delta. Pure-local, best-effort. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(lib)* | start/end logging. |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```
Set `{WORK_TEMP}` = `{work_dir}\temp`; `{RUN_DIR}` = a fresh `{WORK_TEMP}\diagnose\<run>` (or the orchestrator's run dir when `--anchor` points into it). Parse `{custom_url}` from the `CUSTOM_URL=` line — the fingerprint ledger (Step 2.5) lives at `{custom_url}\ops_kb\dump_fingerprints.tsv`.

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's `_run.json` log state under `{RUN_TEMP}` (the reader scratch already lives in the per-run `{RUN_DIR}`); keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_st22_run.json" -Skill sap-st22 -ParamsJson "{}"
```

## Step 1 — Resolve the Anchor + Build the Params File

`--anchor <path>` (orchestrator) or build `{RUN_DIR}\anchor.json` from flags.
Parse the deep flags from `$ARGUMENTS`: `--deep` → `$deep=$true`; `--dump-key
<KEY>` → `$dumpKey`; `--max-deep <N>` → `$maxDeep` (default 5). Derive the ST22
params file from the anchor:

```powershell
$a = Get-Content '{RUN_DIR}\anchor.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$from = "$($a.window.from_ts)"; $to = "$($a.window.to_ts)"
$lines = @(
  "FROMDATE=" + $from.Substring(0,8),
  "TODATE="   + $to.Substring(0,8),
  "USER="     + "$($a.user)",
  "TOPN=200"
)
# Deep mode (only when the caller passed --deep): open each in-scope dump and
# scrape the failing line + snippet. --dump-key scopes to one dump (the
# synthetic key = yyyymmdd + hhmmss + program); --max-deep bounds the crawl.
if ($deep)    { $lines += "DEEP=1" }
if ($dumpKey) { $lines += "DUMPKEY=$dumpKey" }
if ($maxDeep) { $lines += "MAXDEEP=$maxDeep" }
$lines | Set-Content '{RUN_DIR}\st22_params.txt' -Encoding Default
```

> **Deep mode is read-only too.** Opening a dump and pressing Back changes
> nothing in SAP. But it is slower (one GUI round-trip per dump), so it is
> opt-in and bounded by `--max-deep`. `/sap-diagnose` only requests `--deep`
> when a hypothesis needs the failing line (i.e. the custom-code-defect path
> that feeds `/sap-fix-incident`).

## Step 2 — Run the Reader (32-bit cscript)

Substitute the attach tokens + IO paths. Set `SAPDEV_SESSION_PATH` so the
attach helper targets this AI session's pinned connection (per the parallel-safe
attach contract).

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
. "$shared\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
$vbs = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_st22_read.vbs', [Text.Encoding]::UTF8)
$vbs = $vbs.Replace('%%ATTACH_LIB_VBS%%', "$shared\sap_attach_lib.vbs")
$vbs = $vbs.Replace('%%SESSION_PATH%%',   '')   # or the --session value
$vbs = $vbs.Replace('%%PARAMS_FILE%%',    '{RUN_DIR}\st22_params.txt')
$vbs = $vbs.Replace('%%OUTPUT_FILE%%',    '{RUN_DIR}\evidence_st22.json')
[IO.File]::WriteAllText('{RUN_DIR}\st22_run.vbs', $vbs, [System.Text.UnicodeEncoding]::new($false, $true))
```

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo "{RUN_DIR}\st22_run.vbs"
```

(32-bit `cscript` is mandatory — SAP GUI Scripting COM is 32-bit. Never `cmd /c`.)

## Step 2.5 — Fingerprint + Recurrence Ledger (best-effort)

Unless `--no-fingerprint` was passed **or** the reader returned `status=skipped`
(no evidence to fingerprint), fold this run's dumps into the recurrence ledger.
Pure-local, best-effort — it NEVER changes the reader verdict:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_st22_fingerprint.ps1" -EvidenceFile "{RUN_DIR}\evidence_st22.json" -LedgerPath "{custom_url}\ops_kb\dump_fingerprints.tsv"
```

Parse the machine lines — `FINGERPRINT: <fp> precision=<deep|list> status=<NEW|KNOWN_RECURRING> count=<n> …`, `GONE: <fp> days=<n> …`, and the final `STATUS: OK new=<n> recurring=<m> gone=<g> …` — and surface them in Step 3. A `STATUS: SKIP …` line means the step no-op'd (evidence missing / ledger IO error): report nothing and continue. `--deep` runs produce the finer `precision=deep` grain (exception|program|include|line); list-level runs produce `precision=list`.

## Step 3 — Report
Parse `EVIDENCE: source=ST22 status=ok events=<n> deep=<n> ...` +
`evidence_st22.json`. If `status=skipped`, report the reason (likely "grid not
found — run /sap-gui-probe --record on ST22"). In `--deep` mode, each event may carry a
`dump_detail` object — surface its `detail_status`:

- `ok` — failing `include`/`line` + a `source_extract` snippet were captured
  (this is what a downstream fix consumes).
- `partial` — the dump was opened but its body was not scrapeable (typically an
  HTML-rendered dump). The exception / program are still known from the list
  level; recommend a `/sap-gui-probe --record` pass on the ST22 dump-detail screen for
  this release. **Never report `partial` as "no defect found."**
- `skipped` — could not re-open the dump from the list.

**Recurrence (from Step 2.5).** Report the NEW vs KNOWN_RECURRING split plus any
GONE (not-seen-in-N-days) fingerprints — e.g. "3 dumps: 1 NEW (`MESSAGE_TYPE_X`
in ZFOO), 2 KNOWN_RECURRING (first seen 2026-06-30, total 11)". A KNOWN_RECURRING
with a high `total` is a chronic dump worth escalating; a NEW dump inside a
release window is a regression signal. The ledger persists at
`{custom_url}\ops_kb\dump_fingerprints.tsv` for `/sap-diagnose --kb match`,
`/sap-health-check` trend, and `/sap-evidence-pack`.

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_st22_run.json" -Status SUCCESS -ExitCode 0
```

## Known Issues / Failure Modes
- **Recording debt.** ST22 selection-field + result-grid IDs vary by release. The
  reader tries candidate IDs then scans for the grid; if it cannot locate the
  list it emits `status=skipped` with a hint to run `/sap-gui-probe --record` on ST22 and
  update the candidates in `sap_st22_read.vbs`.
- **List level** emits date/time/user/program/exception/short-text + a synthetic
  `dump_key` (date+time+program) so SM13 can link to it. `--deep` adds the
  failing line + source snippet on top (see below).
- **Deep detail recording debt.** The dump detail view's text container ID
  varies by release; the scraper walks `wnd[0]/usr` for `GuiTextedit` controls
  and anchors the error line on the locale-independent `>>>>` marker. On releases
  that render the dump as an **HTML viewer** there is no readable text control,
  so deep returns `detail_status=partial` (exception/program still captured) —
  run `/sap-gui-probe --record` on the ST22 dump-open and add the detail container ID to
  `sap_st22_read.vbs` (`ReadDetailText` candidates) to lift it to `ok`. **Live
  calibration on the target release is pending** — the candidate-ID + `>>>>`
  approach is built and degrades safely, but has not yet been recorded against a
  real ST22 dump.
- **Call-stack / chosen-variables** parsing (the `call_stack` / `chosen_variables`
  arrays in `dump_detail`) is the next deep increment; v1 deep leaves them empty.
- **Requires an active GUI session** and `sapgui/user_scripting = TRUE`.
- **Fingerprint ledger is best-effort + workstation-dated.** `first_seen` /
  `last_seen` use the workstation date (local bookkeeping, not an SAP timestamp);
  a missing evidence file or ledger IO error surfaces as `STATUS: SKIP …` and
  never fails the reader. `--no-fingerprint` skips Step 2.5 entirely.
- **Modal SAP GUI Security dialog** suspends scripting; if a file-IO dialog
  appears, the orchestrator's sidecar pattern applies (this reader does no file
  IO inside SAP, so it normally won't trigger it).
