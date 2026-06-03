---
name: sap-atc
description: |
  Runs the SAP ABAP Test Cockpit (ATC) end-to-end as a quality gate:
  builds an SCI Object Set scoped to the target object(s), creates an
  ATC Run Series bound to that set, polls the ATC Run Monitor until the
  run completes, then reads the Priority 1 / Priority 2 / Priority 3
  finding counts from the Manage Results screen and (best-effort)
  downloads the result text file. Applies the customer brief's
  MAX_PRIORITY threshold to decide pass / fail.
  Replaces the legacy SCI-results-tree implementation that lacked a
  Priority column. Per-stage VBS references are recorded against the
  S/4HANA 1909 ATC layout — re-record on first failure with
  /sap-gui-record if your release uses different tree node IDs / grid
  column IDs.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<OBJECT_TYPE> <OBJECT_NAME> [--variant=<NAME>] [--object-provider=<ID>] [--max-priority=<n>] [--object-set=<NAME>] [--run-series=<NAME>] [--poll-interval=<sec>] [--max-wait=<sec>] [--save-to=<PATH>] [--drill] [--no-drill]"
---

# SAP ATC Quality Gate Skill

You drive the proper SAP ATC pipeline — Object Set → Run Series → Run
Monitor → Manage Results — and apply a priority-based gate. The four
stages each have their own VBS reference; SKILL.md orchestrates them
with a polling loop in the middle.

Task: $ARGUMENTS

---

## Stage map

```
Stage 1: SCI       /nSCI       create / refresh Object Set "<SET>"
   |
   v
Stage 2: ATC       /nATC       tree node 12 → CREATE_SERIE bound to <SET>
   |                            → EXECUTE_SERIE → run is async
   v
Stage 3: ATC       /nATC       tree node 13 → poll Run Monitor for <RUN>
   |                            until STATE=COMPLETED (or FAILED)
   v
Stage 4: ATC       /nATC       tree node 14 → Manage Results: read
                                P1/P2/P3 counts; best-effort download
                                to <OUTPUT_PATH>
   |
   v
Gate logic in SKILL.md compares the counts to MAX_PRIORITY.
   |
   v
Stage 4b: ATC      /nATC       (optional) tree node 14 → drill into the
                                run-series row → export per-finding ALV
                                as TSV. Auto-triggered when gate FAILS;
                                always triggered by --drill. Outputs
                                <OUTPUT_PATH>.findings.tsv with one row
                                per finding: PRIO | CHECK_ID | CHECK_TITLE
                                | OBJECT | LINE | MSG_TEXT.
   |
   v
Final PASS / FAIL emitted with the findings.tsv path when available.
```

---

## Shared Resources

| File | Stage | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | — | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | — | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SKILL_DIR>/references/sap_sci_create_object_set.vbs` | 1 | Define the scope — programs / classes / FMs / interfaces / FUGRs |
| `<SKILL_DIR>/references/sap_atc_create_run_series.vbs` | 2 | Schedule + trigger the ATC run |
| `<SKILL_DIR>/references/sap_atc_check_run_status.vbs` | 3 | Read run state from the Monitor (read-only; safe to call in a poll loop) |
| `<SKILL_DIR>/references/sap_atc_get_results.vbs` | 4 | Pull P1/P2/P3 counts + try to save the result TXT (outer grid only — summary level) |
| `<SKILL_DIR>/references/sap_atc_drill_findings.vbs` | 4b | (Optional) Drill into the run-series row → export per-finding ALV as TSV. Run when gate FAILS or `--drill` is passed. |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. `{WORK_TEMP} = work_dir\temp`.

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_atc_run.json" -Skill sap-atc -ParamsJson "{\"object_type\":\"<TYPE>\",\"object_name\":\"<NAME>\"}"
```

---

## Step 0a — Read MAX_PRIORITY from the Customer Brief

If the customer brief defines `MAX_PRIORITY` (typically `2` = block on
critical + high), use it as the default gate threshold. Allow override
via `--max-priority=<n>` on the skill argument list. Range: 1-4
(1=critical / 2=high / 3=medium / 4=low; lower = worse, fail-on-or-below).

If neither brief nor argument supplies a value, default to `2`.

---

## Step 1 — Parse Arguments

| Arg | Required | Default | Notes |
|---|---|---|---|
| `OBJECT_TYPE` | yes | — | One of `PROGRAM` / `CLASS` / `INTERFACE` / `FUGR` / `DDIC` / `TYPEGROUP` / `WDYN`. SCI groups Class and Interface under one category, so both map to `XSO_CLAS` + `SO_CLAS-LOW`. **`FM` is intentionally rejected** — SCI Object Sets have no per-function-module category; pass `FUGR <function-group-name>` instead to scope at FG level. |
| `OBJECT_NAME` | yes | — | UPPERCASE repository name. |
| `--variant=<NAME>` | no | *(empty = system default)* | Global ATC check variant to run, e.g. `S4HANA_READINESS` for an S/4HANA-conversion readiness check. When omitted, the run series leaves the check-variant field untouched and ATC runs the system's configured default variant (the prior behaviour). **Passing a named variant is mandatory for migration readiness** — see `/sap-cc-analyze`, which calls this skill with `--variant=S4HANA_READINESS`. The named variant must EXIST and be GLOBAL on the connected system (readiness needs the Simplification Database loaded). Accepts `--check-variant=<NAME>` as an alias. |
| `--object-provider=<ID>` | no | *(empty = LOCAL)* | **Central / remote ATC.** Binds the run series to a registered remote object provider (`DATA_SOURCE_ID`) so a central hub analyzes a remote satellite's code. Requires the hub to be configured (tx ATC → Manage System Groupings + an SM59 RFC destination to the satellite, hub check content ≥ the satellite's target release). When omitted, the run is LOCAL. When supplied but the provider field isn't on the config screen, Stage 2 **fails loud** (never silently runs local-as-remote). **The provider field id is UNVERIFIED** — no configured hub was available to record against; see "Central / remote ATC" below. |
| `--max-priority=<n>` | no | `2` (or brief) | Gate threshold — fail if any priority ≤ this value has count > 0. |
| `--object-set=<NAME>` | no | auto | Reuse a named SCI Object Set. If omitted, generate `ZGATE_<8-char-hash-of-objname>` so re-runs on the same target reuse the same set. |
| `--run-series=<NAME>` | no | auto | Run Series name. If omitted, generate `RUN_<YYYYMMDD>_<HHMMSS>` to avoid collisions. |
| `--poll-interval=<sec>` | no | `15` | Stage 3 polling cadence. |
| `--max-wait=<sec>` | no | `600` (10 min) | Stage 3 timeout. |
| `--save-to=<PATH>` | no | `{WORK_TEMP}\ATC_<series>.txt` | Local path for the downloaded result TXT. |
| `--drill` | no | (off by default; auto when gate FAILS) | Force Stage 4b — drill into the run-series row and export per-finding ALV as TSV to `<save-to>.findings.tsv`. Use to see WHICH findings exist even when the gate passes (e.g. inspecting P3 informational findings). |
| `--no-drill` | no | (off) | Disable Stage 4b even when the gate FAILS. Useful for CI runs where the operator only needs PASS/FAIL counts and will drill manually if needed. |

**Naming generation** (when not supplied):

- **Object set**: `ZGATE_` + first 8 hex chars of an MD5 of
  `<OBJECT_TYPE>:<OBJECT_NAME>`. Stable across runs of the same target.
  Max length budget: SCI accepts up to 30 chars on `SCI_DYNP-OBJS`; we
  use 14.
- **Run series**: `R_` + `Get-Date -Format "yyMMdd_HHmmss"` →
  `R_260509_195347` (16 chars). The ATC popup field
  `ctxtSATC_CI_S_CFG_SERIE_UI_02-NAME` has **MaxLength = 16** on
  S/4HANA 1909 — verified live; the older `RUN_<YYYYMMDD>_<HHMMSS>`
  form (19 chars) fails with "method got an invalid argument". The
  shorter form is unique to the second across 100 years.

---

## Step 2 — Ensure SAP GUI Session

Run `/sap-login` first if no session is active.

---

## Step 3 — Stage 1: Create Object Set (SCI)

Fill `sap_sci_create_object_set.vbs` and run it. Tokens:
`%%OBJECT_SET_NAME%%`, `%%OBJECT_TYPE%%`, `%%OBJECT_NAME%%`,
`%%SESSION_LOCK_VBS%%`.

```powershell
# IMPORTANT: read with explicit UTF-8 and write with UTF-16 LE (BOM).
# The VBS templates contain Japanese/Chinese tooltip stems for
# locale-independent state decoding (see sap_atc_check_run_status.vbs).
# `Get-Content -Raw` reads via the Windows ANSI codepage and silently
# mangles those high-byte characters into garbage that VBScript then
# refuses to compile ("unterminated string literal"). Likewise
# `Set-Content -Encoding Unicode` was observed to double-encode in
# some PowerShell versions. Use System.IO.File directly.
$skillDir = '<SKILL_DIR>'
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_sci_create_object_set.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%OBJECT_SET_NAME%%','THE_OBJECT_SET')
$content  = $content.Replace('%%OBJECT_TYPE%%',    'THE_OBJECT_TYPE')
$content  = $content.Replace('%%OBJECT_NAME%%',    'THE_OBJECT_NAME')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%',"$shared\scripts\sap_session_lock.vbs")
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%', "$shared\scripts\sap_attach_lib.vbs")
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_atc_stage1_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
```

> **Stages 2-4 use the same I/O pattern.** Always
> `[System.IO.File]::ReadAllText(..., UTF8)` +
> `[System.IO.File]::WriteAllText(..., UnicodeEncoding)`. Never
> `Get-Content -Raw` + `Set-Content -Encoding Unicode` for these files —
> any localized string in the template will be silently corrupted.
> Explicit generator blocks for each stage are spelled out below
> (Steps 4, 5, 6) so each stage is self-contained.

Run via cscript. Expected last line:
`SUCCESS: Object set <NAME> created/updated with <TYPE> <NAME>.`

If it fails with "Object set <NAME> already exists" or similar, that's
fine for our reuse model — proceed to Stage 2 with the same name. If
it fails with a missing-field-id error, the SCI screen layout shifted;
re-record via `/sap-gui-record`.

---

## Step 4 — Stage 2: Create + Execute Run Series (ATC)

Fill `sap_atc_create_run_series.vbs`. Tokens: `%%RUN_SERIES_NAME%%`,
`%%OBJECT_SET_NAME%%`, `%%CHECK_VARIANT%%`, `%%OBJECT_PROVIDER%%`,
`%%SESSION_LOCK_VBS%%`.

Substitute `%%CHECK_VARIANT%%` with the parsed `--variant=` value, or the
**empty string** when no variant was supplied (the empty value is what tells
the VBS to leave the check-variant field untouched and run the system default —
the prior behaviour). When a variant IS requested but the VBS cannot locate the
check-variant input field on the connected release, **Stage 2 fails loud**
(`ERROR: --variant=… requested but the run-series check-variant input field
could not be located`) rather than silently running the default variant — a
silent fallback would misreport non-readiness findings as readiness. If you hit
that error, re-record the ATC run-series config screen via `/sap-gui-probe` (or
`/sap-gui-record`) and add the real field id to the `chkvCands` list in
`sap_atc_create_run_series.vbs`.

```powershell
$skillDir = '<SKILL_DIR>'
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_atc_create_run_series.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%RUN_SERIES_NAME%%', 'THE_RUN_SERIES')
$content  = $content.Replace('%%OBJECT_SET_NAME%%', 'THE_OBJECT_SET')
# Empty string = run the system default variant (prior behaviour).
$content  = $content.Replace('%%CHECK_VARIANT%%',   'THE_CHECK_VARIANT')
# Empty string = LOCAL analysis; a value = remote object provider (central ATC).
$content  = $content.Replace('%%OBJECT_PROVIDER%%', 'THE_OBJECT_PROVIDER')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', "$shared\scripts\sap_session_lock.vbs")
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%', "$shared\scripts\sap_attach_lib.vbs")
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_atc_stage2_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
```

Run via cscript. Expected lines:
`VARIANT: <S4HANA_READINESS | SYSTEM_DEFAULT>` (which variant the run will use)
`PROVIDER: <provider-id | LOCAL>` (LOCAL = this system's own code; an id = central/remote)
`SUCCESS: Run series <NAME> scheduled (object set <SET>, variant <ID>, provider <P>).`

Confirm the `VARIANT:` line reports the variant you intended — if you passed
`--variant=S4HANA_READINESS` but it reads `SYSTEM_DEFAULT`, the token was not
substituted (treat as a bug, not a clean run).

After this point the ATC run is **async** — SAP queues the work and
executes it in the background. Stage 3 polls.

---

## Step 5 — Stage 3: Poll Run Status

Generate the Stage 3 VBS once (it's reused inside the poll loop):

```powershell
$skillDir = '<SKILL_DIR>'
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_atc_check_run_status.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%RUN_SERIES_NAME%%', 'THE_RUN_SERIES')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', "$shared\scripts\sap_session_lock.vbs")
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%', "$shared\scripts\sap_attach_lib.vbs")
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_atc_stage3_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
```

Then loop:

1. Run `{WORK_TEMP}\sap_atc_stage3_run.vbs` via cscript.
2. Parse the last line:
   - `STATE=COMPLETED` → break, proceed to Stage 4.
   - `STATE=RUNNING` → wait `--poll-interval` seconds, retry.
   - `STATE=FAILED` → abort with `ERROR: ATC run <NAME> failed`.
   - `STATE=NOT_FOUND` → wait one cycle (the Monitor may not have
     picked up the freshly-scheduled run yet), then retry; if still
     NOT_FOUND after 3 cycles, abort.
   - `STATE=UNKNOWN:<raw>` → log and retry once; if it persists,
     fall back to "treat as RUNNING" until `--max-wait` elapses.

Hard cap at `--max-wait` seconds (default 600). On timeout, abort
with `ERROR: ATC run <NAME> did not complete within <N>s`.

Implementation hint for the orchestrator (PowerShell):

```powershell
$pollInterval = 15
$maxWait      = 600
$elapsed      = 0
do {
  $out = & cscript //NoLogo "{WORK_TEMP}\sap_atc_stage3_run.vbs"
  $state = ($out -match '^STATE=(.+)$') | Out-Null; $Matches[1]
  if ($state -eq 'COMPLETED') { break }
  if ($state -eq 'FAILED')    { throw "ATC run failed" }
  Start-Sleep -Seconds $pollInterval
  $elapsed += $pollInterval
} while ($elapsed -lt $maxWait)
```

Don't echo the polling output to chat each iteration — that's noisy.
Suppress and only show on state-change or timeout.

---

## Step 6 — Stage 4: Read Results + Apply Gate

Fill `sap_atc_get_results.vbs`. Tokens: `%%RUN_SERIES_NAME%%`,
`%%OUTPUT_PATH%%`, `%%SESSION_LOCK_VBS%%`.

```powershell
$skillDir = '<SKILL_DIR>'
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_atc_get_results.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%RUN_SERIES_NAME%%', 'THE_RUN_SERIES')
$content  = $content.Replace('%%OUTPUT_PATH%%',    'THE_OUTPUT_PATH')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', "$shared\scripts\sap_session_lock.vbs")
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%', "$shared\scripts\sap_attach_lib.vbs")
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_atc_stage4_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
```

Run `{WORK_TEMP}\sap_atc_stage4_run.vbs` via cscript.

Parse the output for these lines:

```
PRIORITY_COUNTS: P1=<n> P2=<n> P3=<n>
FILE: <path> (<size> bytes)        ← only on successful auto-download
SAVE_HINT: <diagnostic>            ← only when auto-download skipped
SUCCESS: Read result for run series <NAME>.
```

Gate logic:

| MAX_PRIORITY | Pass condition |
|---|---|
| `1` | `P1 == 0` (any critical finding fails) |
| `2` (default) | `P1 == 0 AND P2 == 0` |
| `3` | `P1 == 0 AND P2 == 0 AND P3 == 0` |
| `4` | report findings but never fail (informational) |

Emit a final verdict line in your reply:

```
GATE_VERDICT: PASS  P1=0 P2=0 P3=18 (threshold=2 → P3 doesn't block)
GATE_VERDICT: FAIL  P1=3 P2=2 P3=14 (threshold=2 → P1+P2 sum 5 blocks)
```

---

## Step 6b — Stage 4b: Drill Into Per-Finding Detail (conditional)

The aggregated P1/P2/P3 counts from Stage 4 tell the operator THAT the
gate failed but not WHY. The findings ALV (check ID, source line, message
text — one row per finding) lives one screen deeper, behind a doubleClick
on the run-series row. Stage 4b drills there and exports the grid as
TSV.

**Trigger conditions** (run Stage 4b when ANY is true):

1. `--drill` was passed on the command line.
2. Gate verdict is FAIL AND `--no-drill` was NOT passed.

Otherwise skip Stage 4b.

### 6b.1 — Fill and run sap_atc_drill_findings.vbs

Compute output path:

```
DRILL_PATH = <save-to>.findings.tsv
            (i.e. same dir + filename as --save-to but with .findings.tsv suffix)
```

Token-replace and run the same way as Stage 4 (UTF-8 read + UTF-16 LE
write):

```powershell
$skillDir = '<SKILL_DIR>'
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_atc_drill_findings.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%RUN_SERIES_NAME%%', 'THE_RUN_SERIES')
$content  = $content.Replace('%%OUTPUT_PATH%%',    'THE_DRILL_PATH')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%',"$shared\scripts\sap_session_lock.vbs")
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%', "$shared\scripts\sap_attach_lib.vbs")
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_atc_stage4b_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
```

Run via cscript. Expected output lines:

```
INFO: Outer row <N> for series <NAME> — drilling in.
INFO: Findings grid located at <path>
FINDING_COUNT: <n>
FILE: <DRILL_PATH> (<size> bytes)
SUCCESS: Drilled findings for run series <NAME>.
```

### 6b.2 — Interpret + report

The findings TSV has the header row:
```
PRIO	CHECK_ID	CHECK_TITLE	OBJECT	LINE	MSG_TEXT
```

When the gate FAILED, parse this TSV and surface the offending findings
(`PRIO <= MAX_PRIORITY`) in the final reply — one bullet per row with
file:line and message text. Don't dump the whole TSV inline if it's
long; quote the top 5 by priority and point the operator at the TSV
path for the rest.

When the gate PASSED but `--drill` forced Stage 4b, mention the file
path so the operator can review informational findings if interested.

### 6b.3 — Failure handling

If Stage 4b errors out (e.g. drill couldn't locate the findings grid
because the screen 201 layout shifted on a newer SAP_BASIS release):

- Do NOT fail the overall skill — the gate verdict from Stage 4 already
  determined PASS/FAIL.
- Emit a warning line: `WARN: Stage 4b drill failed — operator must
  inspect findings manually via /nATC > Manage Results > <series>.`
- Suggest re-recording via `/sap-gui-record` against the result-display
  screen, then updating the `findingPaths` fallback list in
  `sap_atc_drill_findings.vbs`.

---

## Step 7 — Report

For the operator's final reply, summarise:

- Object set used (auto-generated or supplied)
- Run series name
- Total wall time (from Stage 2 schedule to Stage 4 read)
- Priority counts table:
  ```
  Priority 1 (critical) :  3
  Priority 2 (high)     :  2
  Priority 3 (medium)   : 14
  ```
- Gate verdict (PASS / FAIL) and which counts contributed to the FAIL
- Local result-file path if the auto-download succeeded; otherwise
  the SAVE_HINT message and the manual-download instructions
- Per-finding TSV path (`<save-to>.findings.tsv`) when Stage 4b ran,
  with a 1-line preview: `Findings: N (top: P<n> <check> @<obj>:<line>)`
- For FAILED gates, list the offending findings (`PRIO <= MAX_PRIORITY`)
  inline — quote the top 5 by priority, point at the TSV for the rest

If the operator wants the full finding list, point them at the saved
TXT, the findings TSV (when Stage 4b ran), or the still-open
ATC > Manage Results > <series> screen.

---

## Step 8 — Clean Up

```bash
cmd /c del {WORK_TEMP}\sap_atc_stage1_run.vbs & del {WORK_TEMP}\sap_atc_stage2_run.vbs & del {WORK_TEMP}\sap_atc_stage3_run.vbs & del {WORK_TEMP}\sap_atc_stage4_run.vbs & del {WORK_TEMP}\sap_atc_stage4b_run.vbs
```

Keep the downloaded result TXT (`--save-to`) and, when Stage 4b ran, the
findings TSV (`<save-to>.findings.tsv`) — both are operator artefacts.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_atc_run.json" -Status SUCCESS -ExitCode 0
```

For gate FAIL, set `-Status FAILED -ExitCode 1 -ErrorClass ATC_GATE_FAIL`
and put the P1/P2/P3 counts in `-ErrorMsg`.

For other failure modes:
- `-ErrorClass ATC_OBJ_SET_FAILED` (Stage 1 broke)
- `-ErrorClass ATC_RUN_SCHEDULE_FAILED` (Stage 2 broke)
- `-ErrorClass ATC_RUN_TIMEOUT` (Stage 3 ran out of wait time)
- `-ErrorClass ATC_RESULT_PARSE_FAILED` (Stage 4 couldn't read counts)

---

## Component IDs (verified S/4HANA 1909, recorded reference)

ATC tree nodes (left pane of `/nATC`):

| Node ID | Function |
|---|---|
| `         12` | Schedule / Manage Run Series (Stage 2 entry) |
| `         13` | Run Monitor (Stage 3 entry) |
| `         14` | Manage Results (Stage 4 entry) |

The string format `"         12"` (10 leading spaces + node ID) is how
SAP GUI scripting addresses ATC tree nodes. Different ATC roles /
versions may renumber these — re-record if Stage 2/3/4 fails to
navigate.

Run Monitor grid (Stage 3, tree node 13) — column IDs **verified live on
S/4HANA 1909**:

| Column ID | What it shows |
|---|---|
| `APP_CONFIG_NAME` | Run Series name (the value Stage 2 supplied) |
| `STATE_ICON` | Icon-encoded state, e.g. `@DF\QState: Finished@` |
| `TITLE`, `RESTARTS`, `DURATION`, `STARTED_ON_DATE`, `STARTED_ON_TIME`, `VALID_TO_DATE`, `STARTED_BY`, `COUNT_PLNERR` | Other monitor columns |

Manage Results grid (Stage 4, tree node 14) — column IDs **verified live**:

| Column ID | What it shows |
|---|---|
| `RUN_SERIES_NAME` | Run Series name |
| `COUNT_PRIO1` / `COUNT_PRIO2` / `COUNT_PRIO3` | Finding counts per priority bucket |
| `COUNT_PLNERR` | Planning errors |
| `IS_ACTIVE`, `IS_CENTRAL_RUN`, `IS_IN_BASELINE`, `TITLE`, `SCHEDULED_BY`, `SCHEDULED_ON_DATE`, `SCHEDULED_SYS`, `VALID_TO_DATE`, `DATA_SOURCE_ID`, `ANNOTATION` | Other admin columns |

The Stage 3 / Stage 4 VBS files put these IDs first in their column-
candidate lists, with older release names (`RUN_SERIES_NAME`, `PRIO_<n>`,
`STATUS_ICON`, etc.) as portability fallbacks.

Run-series config screen (Stage 2, `SAPLSATC_CI_CFG_SERIE_DIALOG` screen
3000) — the check-variant field id is **VERIFIED live on S/4HANA 1909**
(2026-06-03 probe). It sits directly under `wnd[0]/usr` next to the TITLE
field, NOT inside the object-selection tabstrip. `sap_atc_create_run_series.vbs`
tries the verified id first, then a candidate list (`chkvCands`) for other
releases, and **aborts loud** if none match when `--variant=` is supplied:

| Field id | Status |
|---|---|
| `wnd[0]/usr/ctxtSATC_CI_S_CFG_SERIE_UI_01-CHECK_VARIANT` | **Verified, S/4HANA 1909** — `GuiCTextField`, `changeable=True`. Set via `.Text`. |
| `wnd[0]/usr/cmbSATC_CI_S_CFG_SERIE_UI_01-CHECK_VARIANT` | Fallback if a release renders it as a dropdown (set via `.key`) |
| `wnd[0]/usr/ctxtG_DYNP_3000-CHECK_VARIANT` / `…-CI_CHK_VARIANT` / `…-CHKV` / `…-VARIANT` | Cross-release structure-name fallbacks |
| `wnd[0]/usr/ctxtP3B_CHKV`, `…3010/ctxtG_DYNP_3000-CHECK_VARIANT` | Last-resort fallbacks |

The same grid probe also confirmed the Stage-2 run-series **management grid**
exposes its name column as `NAME` (there is no `APP_CONFIG_NAME` there — that id
belongs to the Stage-3 *Run Monitor* grid). The row-matching candidate list in
`sap_atc_create_run_series.vbs` already falls through to `NAME`, so this is
handled; the lead comment naming `APP_CONFIG_NAME` as "verified" for that grid
is slightly misleading and could be reordered in a future pass.

**On a different release:** if Stage 2 errors with "check-variant input field
could not be located", record the config screen via `/sap-gui-probe` or
`/sap-gui-record`, read the real field id, and prepend it to `chkvCands`. Then
update this table.

---

## Recording references

Each stage's VBS header points to its source recording:

| Stage VBS | Recording |
|---|---|
| `sap_sci_create_object_set.vbs` | `C:\Temp\Record_SCI_CreateObjectSet_01.vbs` |
| `sap_atc_create_run_series.vbs` | `C:\Temp\Record_ATC_CreateRunSeries_01.vbs` |
| `sap_atc_check_run_status.vbs`  | `C:\Temp\Record_ATC_CheckRunStatus_01.vbs` |
| `sap_atc_get_results.vbs`       | `C:\Temp\Record_ATC_CheckResult_01.vbs` |

When something breaks on a different SAP release, re-record on the
target system and patch the affected VBS.

---

## Composition with `/sap-sp02`

The Stage 4 download is best-effort — if the ATC Manage Results detail
screen doesn't expose a `Save list to local file` shortcut on your
release, Stage 4 emits `SAVE_HINT:` and leaves the screen open. The
operator can then run `/sap-sp02` against any spool produced via *List
> Print > Print* (the same idiom as `/sap-where-used-list --to-spool`)
to capture a TXT copy.

---

## Central / remote ATC (`--object-provider`)

Large conversions run readiness ATC from a **central check system** (a hub on
NW 7.52+/S4 that carries the S/4 simplification content) against the custom code
on **remote satellites** (e.g. the ECC source), instead of running ATC on each
system. Two ways to do that with this skill:

1. **Logged-into-the-hub (no `--object-provider`)** — the simplest, fully
   supported path: point your session at the hub (e.g.
   `/sap-login --switch <check_system>`), make sure the code under test is
   present there, and run `/sap-atc --variant=S4HANA_READINESS` *locally* on the
   hub. This is the migration chain's default (see `/sap-cc-analyze`).
2. **True remote object provider (`--object-provider=<ID>`)** — the hub analyzes
   a satellite's code *in place* over RFC. The run series binds to a registered
   object provider (`DATA_SOURCE_ID` / `SCA_DS_OBJECT_PROVIDER_ID`).

**Prerequisites for option 2 (all on the hub):**
- An **SM59 RFC destination** to each satellite.
- A registered **object provider / system grouping** (tx ATC → *Manage System
  Groupings*; stored in `SATC_AC_OSY_ATTR`). `/sap-atc` does not create these.
- **Version direction:** the hub's check content must be **≥** the satellite's
  target release. You check OLD systems FROM a NEW hub — never the reverse.
- The **Simplification Database / readiness content** loaded on the hub (same as
  for `--variant=S4HANA_READINESS`).

**Status — UNVERIFIED (single-system limitation).** The remote object-provider
field only appears on the run-series config screen once providers are
registered; no configured hub was available, so the field id in `provCands`
(`sap_atc_create_run_series.vbs`) is a conjecture. The **fail-loud guard is
verified live (S/4HANA 1909):** with `--object-provider` set on a non-hub, Stage
2 aborts with "no remote object-provider field found" *before any Save* — it
never silently runs a LOCAL analysis under a remote request. On a real hub, if
Stage 2 fails-loud, record the config screen via `/sap-gui-probe` and prepend the
true field id to `provCands`, then update the table below.

| Provider field candidate (UNVERIFIED) | Notes |
|---|---|
| `wnd[0]/usr/ctxtG_DYNP_3000-DATA_SOURCE_ID` / `cmb…` | Most likely (the run stamps `DATA_SOURCE_ID`; input or dropdown) |
| `…-OBJECT_PROVIDER`, `ctxtSATC_CI_S_CFG_SERIE_UI_01-DATA_SOURCE_ID` | Alternatives |

## Limitations

- **One-time recording per release.** ATC tree node IDs and result-
  grid column IDs were captured on S/4HANA 1909. On other releases,
  re-record via `/sap-gui-record` and patch the four VBS files.
- **OBJECT_TYPE coverage** (verified live, S/4HANA 1909):
  - `PROGRAM` → `XSO_REPO` + `SO_REPO-LOW` ✓
  - `CLASS` / `INTERFACE` → `XSO_CLAS` + `SO_CLAS-LOW` ✓
    (SCI groups them as one category)
  - `FUGR` → `XSO_FUGR` + `SO_FUGR-LOW` ✓
  - `DDIC` → `XSO_DDIC` + `SO_DDIC-LOW` (untested but field ID dumped)
  - `TYPEGROUP` → `XSO_DDTY` + `SO_DDTY-LOW` (untested)
  - `WDYN` → `XSO_WDYN` + `ctxtSO_WDYN-LOW` (untested; uses ctxt
    instead of txt)
  - `FM` is intentionally rejected — there is no per-FM category in
    SCI Object Sets. The Stage 1 VBS produces a clear redirect
    message pointing at `FUGR <function-group-name>` instead.
- **Stage 4 download is best-effort.** The recording stops before the
  download step; the VBS attempts `Ctrl+Shift+F9` followed by a
  format-radio + `DY_PATH/DY_FILENAME` dialog (the SP02 idiom). If the
  Manage Results detail screen on your release uses a different save
  path, the VBS emits `SAVE_HINT:` and leaves the screen open for
  manual export.
- **No baseline / exemption flow.** ATC has rich baseline-comparison
  and exemption-management features; v1 of this skill ignores them and
  reads raw P1/P2/P3 counts. Future expansion: a `--baseline=<NAME>`
  flag that compares against a saved baseline rather than absolute zero.

---

## Migration note (for operators of the previous skill)

The previous `sap-atc` shipped a single `sap_atc_run.vbs` that drove
SCI's results-tree screen (Error / Warnings / Information columns, no
Priority). That implementation is retired — the four-stage flow above
captures findings via ATC's native Priority columns and supports
async runs, Object Set reuse, and downloadable result files.

Operator-visible API changes:

- The first positional argument is still `<OBJECT_TYPE> <OBJECT_NAME>`.
- The old positional `[CHECK_VARIANT]` argument is replaced by the
  named flag **`--variant=<NAME>`** (alias `--check-variant=`). When
  omitted, the run series leaves the check-variant field untouched and
  ATC runs the system's configured default variant (plus the default
  behaviour flags `GENERATED_CODE-ANALYZE`,
  `QUICKFIXES-GENERATE_QUICKFIXES`) — same as before. When supplied
  (e.g. `--variant=S4HANA_READINESS`), Stage 2 sets that variant on the
  run-series config, and **fails loud rather than silently falling back
  to the default** if it cannot locate the field on the connected
  release (see Step 4).
- `MAX_PRIORITY` is still honoured but now applies to ATC's actual
  priority columns instead of a heuristic mapping.
