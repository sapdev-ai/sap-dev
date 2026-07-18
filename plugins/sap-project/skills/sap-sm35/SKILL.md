---
name: sap-sm35
description: |
  Batch-input (SM35) session operations, headless over RFC. list enumerates sessions from APQI
  (filter by name / status / creator / date), decodes QSTATE at runtime, joins APQL for log
  presence, and reports the built-in APQI statistics — total vs errored transactions and error
  message counts — so you see every failed session and its error volume without a screen-by-screen
  read. process runs a named session in background via RSBDCSUB (delegated to /sap-run-report,
  confirm-gated because it EXECUTES the queued transactions and changes data), then poll-verifies
  APQI-QSTATE -> PROCESSED / PROCESSED_WITH_ERRORS / STILL_RUNNING / TIMEOUT. triage builds a
  per-session error summary + AI narrative from the APQI stats and (when available) the message
  log. The message-level log (TemSe) is not cleanly RFC-readable — BDC_OBJECT_READ returns dynpro
  content, not messages, and the TemSe RSTS chain is non-RFC / absent on ECC — so deep
  MSGID/MSGNO clustering comes from the SM35 GUI log scrape (NEEDS_RECORDING) in v1.5. rerun
  (corrected re-run file from a /sap-call-bdc source) is v1.5. Pure RFC_READ_TABLE (FMODE=R,
  single code path ECC6 + S/4); read-only except the confirm-gated process delegation.
  Prerequisites: pinned /sap-login RFC profile; NCo 3.1 (32-bit); a live GUI session only for the
  GUI log fallback + the /sap-run-report execution.
argument-hint: "list [<SESSION>] [--status new|error|processed|inprocess|all] [--created-by U] [--from YYYYMMDD] [--to YYYYMMDD] | process <SESSION> | triage <SESSION>"
---

# SAP SM35 Batch-Input Skill

You list and triage batch-input sessions and, on request, process them — headless over RFC. list
and triage are read-only; process is confirm-gated because it executes queued transactions.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` + `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_safety_gate.ps1` | Rule 0 | Environment guard — Step 3 runs `-Action assert` before the write |
| `<SKILL_DIR>/references/sap_sm35_list.ps1` | `-Session -Status ...` | Session lister + APQI-stat triage + process poll |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_connection_lib.ps1` | dot-source | RFC connect |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` · `sap_artifact_lib.ps1` | dot-source | Findings + evidence |
| `/sap-run-report` · `/sap-call-bdc` · `/sap-rfc-wrapper` | sub-skills | RSBDCSUB execution / rerun (v1.5) / BDC content read (v1.5) |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_sm35_run.json`). Pinned RFC profile via `/sap-login`.

## Step 1 — Parse & Dispatch

`list` (default) | `process` | `triage`. Uppercase `<SESSION>`. `process` requires a session name.

## Step 2 — list

```bash
... sap_sm35_list.ps1 [-Session <G>] [-Status new|error|processed|inprocess|all] [-CreatedBy U] [-FromDate ..] [-ToDate ..] -Max 100 -OutDir "{RUN_TEMP}\sm35"
```

Renders `SM35:` lines as a table (name / state(label) / created / trans / errors / msgs / log /
prog) + `sm35_sessions.tsv`. `LISTED n=0` is a normal empty result, never an error. RFC down ->
`SM35_RFC_UNAVAILABLE` (fail loud -> /sap-doctor).

## Step 3 — process (confirm-gated)

**Rule 0 first** (`safety_policy.md`; `process` only — `list`/`triage` skip it):
`powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-sm35` —
`SAFETY: ALLOW` (0) proceed; `TYPED_CONFIRM_REQUIRED` (3) -> the operator types the shown
`PROD <SID>/<CLIENT>` token, re-run with `-ConfirmationText '<their verbatim answer>'`, proceed only
on `ALLOW_CONFIRMED`; `REFUSED class=<C>` (1) / `ERROR` (2) -> **STOP**, end `FAILED` with
`-ErrorClass <C>`, relay the remediation lines — never bypass or work around it manually. The composed /sap-run-report Rule-5 confirm still applies after ALLOW/ALLOW_CONFIRMED.

1. Pre-check via `list -Session <G>`: session exists and QSTATE is processable (new/error). Not
   found -> `SM35_SESSION_NOT_FOUND`.
2. **CONFIRM gate:** "I will PROCESS batch-input session `<G>` (state `<label>`, created `<date>`
   by `<user>`, `<trans>` transactions) in background via RSBDCSUB on `<SID>/<CLIENT>`. Its queued
   transactions will EXECUTE and may change data. Proceed? (yes/no)". On no -> log `SKIPPED`, no
   run. **Single-gate:** compose this context INTO the `/sap-run-report RSBDCSUB` delegation so its
   own Rule-5 prompt carries it — do not add a second prompt.
3. Delegate RSBDCSUB to `/sap-run-report` (selection = session name, background). Then poll
   `sap_sm35_list.ps1 -Session <G>` every ~10 s up to `--wait` (default 300): QSTATE F ->
   `PROCESSED`, E -> `PROCESSED_WITH_ERRORS` (offer `triage <G>`), still R/X -> `STILL_RUNNING`,
   elapsed -> `SM35_PROCESS_TIMEOUT`.

## Step 4 — triage

Run `list -Session <G>`; summarize the session's error signal from APQI stats (errored vs total
transactions, error-message count) into `sm35_triage_<G>.md` + findings (MSGTY-agnostic at the
stat level: any errored transactions -> HIGH `bdc-error-cluster`, coverage CHECKED). For
**message-level** clustering by (MSGID, MSGNO), the SM35 GUI **log** display must be scraped —
that VBS is not yet shipped (to-be-recorded): emit `NEEDS_RECORDING` and capture it once via
`/sap-gui-probe --record` on this release; deep clustering is v1.5. If neither stats nor a readable log is available -> triage
`COULD_NOT_CHECK` (never an empty-but-green triage).

## Step 5 — Register

`Register-SapArtifact` (scope `BDC_<GROUPID>`; kinds `session_list` / `triage_report`; coverage +
verdict) for `/sap-evidence-pack`.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class). Error classes: `SM35_RFC_UNAVAILABLE`,
`SM35_SESSION_NOT_FOUND`, `SM35_LOG_NOT_FOUND`, `SM35_PROCESS_TIMEOUT`, `SM35_RERUN_SOURCE_MISSING`;
reused `RFC_LOGON_FAILED` / `GUI_TIMEOUT`.

---

## Scope & Limitations (v1)

- **Live-verified on S4D (S/4HANA 1909) 2026-07-11:** `list` enumerated real error sessions with
  decoded QSTATE (E->"errors" via DD07V) and the built-in APQI stats (e.g. `01`: 83 transactions,
  3 errored, 15 error messages) + APQL log-presence; the `error` status filter works. EC2 (ECC 6)
  was probed in-plan (APQI/APQL/RSBDCSUB identical, SAPMSBDC_CC on both) but was unreachable at
  build time; the code path is release-agnostic.
- **Build-time finding — the message log is not pure-RFC.** BDC_OBJECT_READ (probed FMODE blank,
  needs the wrapper) returns **DYNPROTAB (dynpro/transaction content), not error messages**, and
  the TemSe message log (APQL->RSTS) is non-RFC and `RSTS_OPEN_RL` is absent on ECC. So the
  session-level error signal comes from APQI statistics (verified), and deep MSGID/MSGNO
  clustering is deferred to the GUI `log` scrape (NEEDS_RECORDING) + v1.5 — never fabricated.
- **process is confirm-gated and delegated** (executes queued transactions). `list`/`triage` are
  read-only. No new Z objects; no SQL writes (mutations happen only inside RSBDCSUB).
- **v1.5:** GUI log scrape + message-level clustering; `rerun` (corrected file from a /sap-call-bdc
  `bdc/` source, then delegate execution). **v2:** `purge` via RSBDCREO (typed-confirm mass delete).
- Data volume: APQI can hold thousands of sessions — `--max` (default 100) + date filters cap the
  read; only DATATYP='BDC' queues are listed.
