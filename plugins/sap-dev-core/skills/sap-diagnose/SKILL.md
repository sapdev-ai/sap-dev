---
name: sap-diagnose
description: |
  Incident triage orchestrator for SAP support. From a single incident anchor
  (a time window, user, transaction, background job, business object key, or a
  known short-dump) it fans out across the read-only Diagnose readers — /sap-st22
  (dumps, GUI), /sap-sm13 (update-task failures), /sap-sm12 (locks), /sap-slg1
  (application log), /sap-sm37 (jobs) — then correlates the collected evidence
  into incident clusters and produces ranked root-cause hypotheses with a
  recommended fix path.
  PURE READ-ONLY: this skill never writes to SAP. When a fix implies a write
  (release a lock, reprocess an update) it only PROPOSES the gated command; the
  matching reader's remediate mode owns the confirmation.
  Mostly RFC-driven (SM13/SM12/SLG1/SM37) and therefore robust across releases;
  ST22 is GUI (ADT not used). Safe to point at production.
  Prerequisites: a saved profile via /sap-login (RFC password); SAP NCo 3.1
  (32-bit, .NET 4.0) in GAC; active SAP GUI session for the ST22 leg.
argument-hint: "[<natural-language incident>] [--user U] [--tcode T] [--program P] [--job J] [--dump KEY] [--object TYPE:KEY] [--date today|YYYYMMDD] [--time HH:MM] [--window MIN] [--sources a,b] [--depth quick|standard|deep] [--remediate] [--connection PROFILE] [--report] [--out PATH]"
---

# SAP Incident Diagnosis Orchestrator

You triage a SAP incident the way a senior support consultant does — but in
parallel, with full cross-source correlation. Take one anchor, fan out across
the read-only readers, merge their evidence into incident clusters, and report
ranked root-cause hypotheses plus the next concrete command. You NEVER modify
the SAP system; remediation is handed off to a confirmation-gated reader mode.

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

**Reader skills** (called via the Skill tool in Step 4): `/sap-st22`,
`/sap-sm13`, `/sap-sm12`, `/sap-slg1`, `/sap-sm37`.

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
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_diagnose_run.json" -Skill sap-diagnose -ParamsJson "{}"
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

## Step 3 — Select Sources

Read `references/diagnose_source_matrix.tsv`, pick the reader set by the
strongest anchor signal, honor `--sources` and `--depth` (quick = top-3; deep =
all). Include `/sap-sm21` at standard+ when available. Echo
`SOURCES_SELECTED: ...`.

## Step 4 — Collect Evidence (fan-out)

Invoke each selected reader **via the Skill tool**, passing
`--anchor {RUN_DIR}\anchor.json --out {RUN_DIR}\evidence_<source>.json`. Each
reader is read-only, time-boxed, top-N capped, and writes an evidence file
(`diagnose_evidence_schema.json`). RFC readers (sm13/sm12/slg1/sm37) are
independent — invoke them together; the GUI reader (st22) uses the pinned
session, so run it on its own. A reader that errors or lacks authorization
writes a `skipped` stub — record it and continue; never drop a source silently.

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
| custom-code defect | `/sap-explain-object <type> <name>` → `/sap-se38\|37\|24` fix |
| config-missing | name the IMG/config table; verify read-only via `/sap-se16n` |
| data-defect | point at the record (read-only `/sap-se16n`) |
| lock-contention | *(gated)* `/sap-sm12 --release <lock>` — only with `--remediate` |
| stuck update | *(gated)* `/sap-sm13 --reprocess <key>` — only with `--remediate` |

The orchestrator performs no write under any flag.

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

## Step 9 — Clean Up

Keep the deliverable under `{work_dir}\diagnose`; remove `{RUN_DIR}` unless
`--depth deep` (then retain raw evidence for audit and say so).

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_diagnose_run.json" -Status SUCCESS -ExitCode 0
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
| a reader returns `skipped` | no auth for that tcode/FM | run it standalone with a privileged user; triage continues |
| hundreds of events | anchor too broad | narrow `--user`/`--tcode`; read `truncation[]` |
| one giant cluster | `TightSeconds` too loose on a busy system | lower `-TightSeconds` |

## Limitations

- Coverage equals the installed readers; a missing reader is reported skipped.
- No performance leg in v1 ("slow" routes to a future `/sap-trace`).
- Correlation is heuristic: explicit links are ground truth; temporal/identity/
  context edges are confidence-scored, hence the `confirm_by`/`refute_by` rule.
