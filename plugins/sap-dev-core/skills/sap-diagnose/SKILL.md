---
name: sap-diagnose
description: |
  Incident triage orchestrator for SAP support. From a single anchor (time window,
  user, transaction, background job, business-object key, or a known short-dump)
  it fans out across its read-only evidence readers — the internal RFC set (SM13
  update-task failures, SM12 locks, SLG1 application log, SM37 jobs) plus the GUI
  dump reader /sap-st22 — correlates the evidence into incident clusters, and
  produces ranked root-cause hypotheses with a recommended fix path. Pass --reader
  <name> (sm13 | sm12 | slg1 | sm37 | st22) to run one reader standalone and just
  print its evidence. PURE READ-ONLY: never writes to SAP; lock/update remediation
  is surfaced as manual SM12 / SM13 steps. With --fix it hands a custom-code-defect
  top hypothesis to /sap-fix-incident (the gated, write-capable companion) —
  diagnose itself still writes nothing. Safe to point at production.
  Prerequisites: a saved /sap-login profile (RFC password); SAP NCo 3.1 (32-bit);
  an active SAP GUI session for the ST22 leg.
argument-hint: "[<natural-language incident>] [--user U] [--tcode T] [--program P] [--job J] [--dump KEY] [--object TYPE:KEY] [--date today|YYYYMMDD] [--time HH:MM] [--window MIN] [--sources a,b] [--reader sm13|sm12|slg1|sm37|st22] [--depth quick|standard|deep] [--remediate] [--fix] [--connection PROFILE] [--report] [--out PATH]"
---

# SAP Incident Diagnosis Orchestrator

You triage a SAP incident the way a senior support consultant does — but in
parallel, with full cross-source correlation. Take one anchor, fan out across
the read-only readers, merge their evidence into incident clusters, and report
ranked root-cause hypotheses plus the next concrete command. You NEVER modify
the SAP system; custom-code fixes are handed to `/sap-fix-incident` (gated), and
lock/update remediation is surfaced as manual SM12 / SM13 operator steps (the
readers are read-only — no automated release/reprocess exists).

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / role | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Read-only by construction; remediate handoff respects "ask before mutating". |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | Applies to the GUI ST22 leg + any downstream fix skill. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Per-key settings merge; per-connection pin resolution. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo helpers for the anchor server-time read. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(lib)* | `Get-SapWorkDir`, pinned profile. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(lib)* | start/step/end logging. |
| `<SKILL_DIR>/references/sap_diagnose_anchor_resolve.ps1` | *(helper)* | flags → absolute SERVER-time anchor. |
| `<SKILL_DIR>/references/sap_diagnose_correlate.ps1` | *(helper)* | deterministic graph + clustering. |
| `<SKILL_DIR>/references/diagnose_evidence_schema.json` | *(schema)* | evidence contract every reader emits. |
| `<SKILL_DIR>/references/diagnose_source_matrix.tsv` | *(table)* | anchor-signal → reader set. |
| `<SKILL_DIR>/references/sap_diagnose_reader_lib.ps1` | `%%DIAG_READER_LIB_PS1%%` | Reader helpers (anchor, read-table, evidence emit) — dot-sourced by the four RFC reader scripts below. |
| `<SKILL_DIR>/references/sap_sm37_read.ps1` | *(reader)* | Background-job reader (TBTCO). |
| `<SKILL_DIR>/references/sap_sm13_read.ps1` | *(reader)* | Update-task failure reader (VBHDR + VBERROR). |
| `<SKILL_DIR>/references/sap_sm12_read.ps1` | *(reader)* | Lock-entry reader (ENQUEUE_READ). |
| `<SKILL_DIR>/references/sap_slg1_read.ps1` | *(reader)* | Application-log reader (BALHDR). |

**Evidence readers.** The four RFC readers (SM13 / SM12 / SLG1 / SM37) are
**internal to this skill** — the `references/sap_*_read.ps1` scripts above, run
directly in Step 4 (they were formerly the standalone `/sap-sm13` … `/sap-sm37`
skills, folded in here to shrink the catalogue). The **GUI dump reader stays a
separate skill**, `/sap-st22` (called via the Skill tool), because it drives
ST22 through GUI scripting. `/sap-trace` (performance) is likewise separate and
is not auto-chained.

**Fix hand-off** (Step 8.5, only with `--fix`): `/sap-fix-incident` — the
write-capable companion. Diagnose stays read-only; it only invokes the fix skill
(which owns its own confirmation gate + guard rails) after a confirmation.

---

## Step 0 — Resolve Work Directory and Settings

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Resolve the active connection: `--connection` if given, else the AI-session pin
in `{work_dir}\runtime\session_registry.json`. Read `log_redact_keys` and the
SAP RFC connection keys for that system. Set `{WORK_TEMP}` = `{work_dir}\temp`,
`{RUN_DIR}` = `{WORK_TEMP}\diagnose\<run>`:

```bash
cmd /c if not exist "{WORK_TEMP}\diagnose" mkdir "{WORK_TEMP}\diagnose"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_diagnose_run.json" -Skill sap-diagnose -ParamsJson "{}"
```

## Step 1 — Parse the Anchor

Interpret the leading natural-language text + flags into a flags object
`{ date, time, window, from_ts, to_ts, user, tcode, program, job, jobcount,
dump, object, client }`. Explicit flags win. If the anchor is too thin (e.g.
date only), default to "most recent error-class events in window" and say so.
Write the flags to `{RUN_DIR}\flags.json`.

## Step 2 — Resolve the Anchor to Server Time

Fill `sap_diagnose_anchor_resolve.ps1` with `%%RFC_LIB_PS1%%` + the SAP
connection tokens (same substitution pattern as `/sap-dev-status`), then run it
under **32-bit PowerShell**:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_DIR}\anchor_resolve_run.ps1" -InputJson "{RUN_DIR}\flags.json" -OutFile "{RUN_DIR}\anchor.json"
```

> **Server-time discipline.** The window is resolved against the SAP server
> clock (RFC `RFC_SYSTEM_INFO` → `RFCTZONE`), never the workstation. Echo the
> `RESOLVED_WINDOW=` line. A skew here silently returns "no evidence" — the same
> failure class as the SE01-create timezone bug.

> **Standalone single-reader mode (`--reader <name>`).** When `--reader` names
> one reader (`sm13` | `sm12` | `slg1` | `sm37` | `st22`), **skip source
> selection (Step 3)**: resolve the anchor (Steps 1–2), run just that one reader
> with the Step 4 mechanics, print its evidence summary, and STOP — no
> correlation, clustering, or hypotheses (Steps 5–8 are not run). This replaces
> the former standalone `/sap-sm13` … `/sap-sm37` skills one-for-one; e.g.
> `/sap-diagnose --reader sm37 --job ZFOO --date today` == the old `/sap-sm37`.

## Step 3 — Select Sources

Read `references/diagnose_source_matrix.tsv`, pick the reader set by the
strongest anchor signal, honor `--sources` and `--depth` (quick = top-3; deep =
all). Echo `SOURCES_SELECTED: ...`.

> **Not-yet-available readers.** The matrix lists some sources that have **no
> reader skill yet** — `sm21` (system log), `queues` (qRFC/tRFC SMQ1/SMQ2), and
> `gw_log` (Gateway/OData). These are marked `(manual)` in the TSV. Do **not**
> try to invoke them via the Skill tool. Instead, name the manual transaction in
> the report's `next_actions` (e.g. "run **SM21** for the window", "check
> **SMQ1/SMQ2** for stuck queues", "check **/IWFND/ERROR_LOG**") so the operator
> collects that evidence by hand. Only the internal RFC readers (`sm13`, `sm12`,
> `slg1`, `sm37`) and the `st22` GUI reader skill (plus `trace`, a separate
> skill) are available today.

## Step 4 — Collect Evidence (fan-out)

Each reader is read-only, time-boxed, top-N capped, and writes an evidence file
matching `diagnose_evidence_schema.json`. A reader that errors or lacks
authorization writes a `skipped` stub — record it and continue; never drop a
source silently.

### Step 4a — Internal RFC readers (SM13 / SM12 / SLG1 / SM37)

For each selected RFC source, materialize its reader script and run it under
**32-bit PowerShell**. Substitute **only** the two library paths; leave the
`%%SAP_*%%` credential tokens literal so `Connect-SapRfc` fills them from the
pinned connection profile. The four readers share one signature
(`-AnchorJson <path> -OutFile <path> [-TopN <n>]`), so the block below is
identical per source — swap `<src>` ∈ { `sm13`, `sm12`, `slg1`, `sm37` }:

```powershell
$ps = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_<src>_read.ps1', [Text.Encoding]::UTF8)
$ps = $ps.Replace('%%RFC_LIB_PS1%%',         '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$ps = $ps.Replace('%%DIAG_READER_LIB_PS1%%', '<SKILL_DIR>\references\sap_diagnose_reader_lib.ps1')
[IO.File]::WriteAllText('{RUN_DIR}\<src>_run.ps1', $ps, (New-Object Text.UTF8Encoding($false)))
```

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_DIR}\<src>_run.ps1" -AnchorJson "{RUN_DIR}\anchor.json" -OutFile "{RUN_DIR}\evidence_<src>.json"
```

The RFC readers are independent — materialize and run the whole selected set
before correlating. Honor `--top-n` by appending `-TopN <n>`. Each reader prints
an `EVIDENCE: source=<SRC> …` summary line and writes `evidence_<src>.json`,
which `sap_diagnose_correlate.ps1` consumes in Step 5.

### Step 4b — GUI dump reader (ST22)

If `st22` is in the selected set, invoke `/sap-st22` **via the Skill tool**,
passing `--anchor {RUN_DIR}\anchor.json --out {RUN_DIR}\evidence_st22.json`. It
uses the pinned GUI session, so run it on its own (do not interleave it with a
second GUI skill).

> **`--fix` (or `--depth deep`) → run ST22 deep.** When `--fix` is set, invoke
> `/sap-st22` with `--deep` so the deliverable carries a `dump_detail` (failing
> `include`/`line` + source snippet) — that is the input `/sap-fix-incident`
> needs in Step 8.5. Without it the fix skill would have to re-open the dump
> itself. This stays read-only.

## Step 5 — Correlate

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_diagnose_correlate.ps1" -RunDir "{RUN_DIR}" -TightSeconds 5
```

Writes `{RUN_DIR}\correlation.json` (incident clusters + weighted edges:
explicit / business-key = HIGH, identity+temporal / context = MED, temporal =
LOW; clusters use MED+). Each cluster carries a timeline, an `anchor_event_id`,
and an `earliest_event_id` (nearer the root cause).

## Step 6 — Generate Ranked Hypotheses

Read `correlation.json` + the raw evidence and reason per cluster. For each, emit
`{ rank, confidence, category, statement, symptom_vs_root, evidence_ids,
confirm_by, refute_by, recommended_action }`. Hard rules:

- **Separate symptom from root cause** — a dump is a symptom; the cause is
  missing config / bad data / a code defect / contention. Use the earliest
  event + the SLG1 business reason to find the cause.
- **Rank by evidence strength × specificity** (explicit links + multiple
  corroborating sources outrank a lone coincidence).
- **Fill `confirm_by` / `refute_by`** before presenting a hypothesis as likely.

## Step 7 — Recommend & Hand Off

| Root cause | Next command |
|---|---|
| custom-code defect | *(closed loop)* `/sap-fix-incident --incident <out>` — auto-chained by `--fix` (Step 8.5); or manually `/sap-explain-object <type> <name>` → `/sap-se38\|37\|24` fix |
| config-missing | name the IMG/config table; verify read-only via `/sap-se16n` |
| data-defect | point at the record (read-only `/sap-se16n`) |
| lock-contention | *(manual — operator-performed)* open **SM12** (`/nSM12`), find the reported row, confirm with the lock owner, then **Lock Entry → Delete** by hand. The SM12 reader leg is **read-only** — there is no automated `--release`. |
| stuck update | *(manual — operator-performed)* open **SM13** (`/nSM13`), find the failed record, confirm with the update owner, then **Repeat Update / Delete** by hand. The SM13 reader leg is **read-only** — there is no automated `--reprocess`. |

The orchestrator performs no write itself. With `--fix` it delegates the
custom-code path to `/sap-fix-incident`, which owns its own confirmation gate
(Rule 2) and guard rails. For lock/update contention there is **no automated
remediation** — the sm12/sm13 readers are read-only, so `--remediate` surfaces
the **manual SM12 / SM13 steps above** (which the operator performs by hand)
rather than invoking a dequeue/reprocess. Diagnose never mutates SAP directly
under any flag.

## Step 8 — Emit Outputs

Derive `incident_id` from the resolved server timestamp + a short hash of the
anchor. Write the JSON deliverable to `--out`
(default `{work_dir}\diagnose\<incident_id>.json`) with `incident_run`,
`evidence`, `correlation`, `hypotheses`, `truncation` (LOUD), `next_actions`.
With `--report`, also write `<out>.md`. Print a final status line:

```
STATUS: DIAGNOSED clusters=<n> top_confidence=<HIGH|MED|LOW> report=<path>
STATUS: NO_EVIDENCE window=<from>..<to>   (possible time-zone skew — see Failure Modes)
STATUS: ERROR <reason>
```

## Step 8.5 — Optional: Chain the Fix (`--fix`)

Only when `--fix` was passed. **`/sap-diagnose` itself still writes nothing
here** — it hands the deliverable to the gated `/sap-fix-incident`.

Chain only if **both** hold:

1. The deliverable was emitted (Step 8) with a non-empty `--out` path, and
2. The rank-1 hypothesis `category == custom-code-defect`.

Otherwise do NOT chain — print the Step-7 next command and stop (config-missing /
data-defect / lock-contention have their own paths; a low-confidence or non-code
top hypothesis is never auto-fixed).

When both hold:

1. **Present** the rank-1 hypothesis (statement, symptom_vs_root, evidence ids,
   confidence) and say `--fix` will hand it to `/sap-fix-incident`.
2. **Confirm** (Rule 2): *"Hand this custom-code root cause to /sap-fix-incident?
   It will reproduce the defect as a test, propose a patch, and — after its own
   confirmation — deploy to DEV behind a transport. (yes / no)"*. Proceed only on
   explicit `yes`.
3. **Invoke via the Skill tool**: `/sap-fix-incident --incident <out>` (the
   Step-8 deliverable path). The fix skill re-applies its own guard rails
   (Z/Y-only, DEV-only, never standard / production) and its own deploy gate —
   this chain bypasses none of them.
4. Relay the fix skill's `STATUS:` line back to the user.

Echo `FIX_CHAIN: invoked target=<type:name>` or
`FIX_CHAIN: skipped reason=<not-code|low-confidence|no-deliverable|declined>`.

## Step 9 — Clean Up

Keep the deliverable under `{work_dir}\diagnose`; remove `{RUN_DIR}` unless
`--depth deep` (then retain raw evidence for audit and say so). **If `--fix`
chained a fix (Step 8.5), retain the deliverable regardless** — it is the
`--incident` input the fix skill consumed.

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_diagnose_run.json" -Status SUCCESS -ExitCode 0
```

`NO_EVIDENCE` → `-Status SKIPPED -ExitCode 1 -ErrorClass DIAGNOSE_NO_EVIDENCE`.

---

## Known Issues

- **Cluster tables.** ST22 (SNAP) and SLG1 (BALDAT) are clusters; the readers use
  the GUI / BALHDR-header respectively and never `RFC_READ_TABLE` them (the
  `sap_rfc_lib.ps1` guard would block it).
- **SM13 is date-precision.** `VBHDR` has no sub-second time, so SM13 events
  correlate via the engine's `context` edge (same day + user + program/tcode)
  and business keys, not the tight temporal window.
- **ST22 GUI recording debt.** ST22 selection/grid component IDs vary by release;
  the reader tries candidates and degrades to `skipped` with a record hint
  (`/sap-gui-record`) if it cannot locate the list.

## Failure Modes

| Symptom | Cause | Recovery |
|---|---|---|
| `NO_EVIDENCE` for a real incident | server/workstation time-zone skew | re-check `RESOLVED_WINDOW`; widen `--window`; confirm server tz |
| a reader returns `skipped` | no auth for that tcode/FM | re-run that reader alone with a privileged user (`--reader <name>`); triage continues |
| hundreds of events | anchor too broad | narrow `--user`/`--tcode`; read `truncation[]` |
| one giant cluster | `TightSeconds` too loose on a busy system | lower `-TightSeconds` |

## Limitations

- Coverage equals the installed readers; a missing reader is reported skipped.
- No performance leg in v1 ("slow" routes to `/sap-trace`, a separate skill —
  invoke it directly for trace analysis; `/sap-diagnose` does not chain it).
- Correlation is heuristic: explicit links are ground truth; temporal/identity/
  context edges are confidence-scored, hence the `confirm_by`/`refute_by` rule.
