---
name: sap-sost
description: |
  SAPconnect outbound-queue triage (SOST/SCOT) over RFC — the step past where application output
  diagnosis stops. list snapshots the SOST status log filtered by date / transmission method
  (INT/FAX/PAG) / status (error/wait/sent), and --cluster groups failures by (MSGID,MSGNO) with
  the T100 error text into top root causes. trace shows a per-message status timeline (created ->
  attempts -> final) and returns NOT_IN_SAPCONNECT when nothing matches (pointing back to the app
  layer / /sap-output-diagnose). config-check validates the SCOT pipe read-only: SAPconnect nodes
  (SXNODES active), the RSCONN01 send job (TBTCP->TBTCO), and stuck-queue age — rolled up to a
  GO / GO_WITH_WARNINGS / NO_GO verdict, designed to be pulled into /sap-health-check. resend is a
  confirm-gated GUI SOST drive (v1.5 — no RFC resend FM exists) verified by an authoritative SOST
  re-read. Pure RFC_READ_TABLE + the remote-enabled SO_DOCUMENT_READ_API1 (trace --body, v1.5); no
  wrapper FM, no dev-init, single code path ECC6 + S/4 (SOST is a real table on both; SOST/SOSV/SOSG
  all run SAPLSBCS_OUT). Prerequisites: pinned /sap-login RFC profile; NCo 3.1 (32-bit).
argument-hint: "list [--status error|wait|sent|all] [--type INT|FAX|PAG] [--from YYYYMMDD] [--cluster] | trace --recipient <addr> | config-check"
---

# SAP SOST SAPconnect Triage Skill

You triage stuck outbound email/fax: cluster the failures, trace one message's timeline, and check
whether the SAPconnect pipe itself (nodes + send job) is healthy — all read-only over RFC.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_sost_read.ps1` | `-Action list\|trace\|config` | The RFC read backend (all three v1 modes) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_connection_lib.ps1` | dot-source | RFC connect |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` · `sap_artifact_lib.ps1` | dot-source | Findings + evidence |
| `/sap-run-report` · `/sap-job` · `/sap-output-diagnose` | sub-skills | RSCONN01 `--kick` (v1.5) / send-job forensics / app-layer handoff |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_sost_run.json`). Pinned RFC profile via `/sap-login`.

## Step 1 — Parse & Dispatch

`list` (default `--status error`, last 7 days) | `trace` | `config-check`. All read-only in v1.

## Step 2 — list

```bash
... sap_sost_read.ps1 -Action list [-Status error|wait|sent|all] [-Type INT|FAX|PAG] [-FromDate ..] [-Cluster] -OutDir "{RUN_TEMP}\sost"
```

`SOST:` lines (date/type/msgty/message/node/object) -> `queue_snapshot.tsv`; with `--cluster`,
`SOSTCLUSTER:` top (MSGID,MSGNO) root causes with T100 text -> `error_clusters.tsv`. Present the
top clusters as the headline ("N messages failed with <text>").

## Step 3 — trace

```bash
... sap_sost_read.ps1 -Action trace --recipient <addr> (or --sender U) [-FromDate ..]
```

`SOSTTRACE:` per-object attempt timeline. Zero matches -> `NOT_IN_SAPCONNECT` verdict: tell the
user the message never reached SAPconnect and point at `/sap-output-diagnose`. (`--body` via
`SO_DOCUMENT_READ_API1` is v1.5.)

## Step 4 — config-check

```bash
... sap_sost_read.ps1 -Action config [-Type INT] [-StuckHours 4] -OutDir "{RUN_TEMP}\sost"
```

`SOSTCHECK:` for nodes (SXNODES active) / send job (RSCONN01 in TBTCP->TBTCO) / stuck queue, each a
tri-state result -> `config_check.tsv` + overall `GO`/`GO_WITH_WARNINGS`/`NO_GO`. Map each to
`New-SapCheckResult` (a table that fails to read is COULD_NOT_CHECK, never a silent pass);
`Get-SapVerdict`. A missing RSCONN01 send job with a stuck queue is the classic "node up, nothing
sends" pattern — surface it explicitly.

## Step 5 — resend (v1.5, confirm-gated GUI)

No RFC resend FM exists (probed). resend drives transaction SOST via a recorded VBS
(`sap_sost_resend.vbs`, `NEEDS_RECORDING` until captured with `/sap-gui-probe --record`) behind a
confirm gate (typed confirmation for >25 messages or a production client), then an authoritative
SOST re-read verifies the status flip; `--kick` submits RSCONN01 via /sap-run-report (its own gate).

## Step 6 — Register

`Register-SapArtifact` (scope `SYS_<SID>`; kinds `queue_snapshot` / `error_clusters` / `msg_trace`
/ `config_check`; coverage + verdict) for `/sap-evidence-pack`.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class). Error classes: `SOST_SELECTION_EMPTY`,
`SOST_RESEND_FAILED`, `NEEDS_RECORDING`; reused `RFC_LOGON_FAILED` / `RFC_ERROR` / `GUI_TIMEOUT`.

---

## Scope & Limitations (v1)

- **Live-verified on S4D (S/4HANA 1909) 2026-07-11:** `list --cluster` grouped 11 `XS-816`
  failures into one root cause — "Message cannot be transferred to node & due to connection error
  (final)" (T100). `config-check` returned a coherent NO_GO: SMTP node active, **no RSCONN01 send
  job scheduled** (steps=0), 17 error/wait messages stuck — the textbook "node up, nothing sends"
  diagnosis. EC2 (ECC 6) was probed in-plan (identical SO*/SX* table set, SAPLSBCS_OUT on both) but
  unreachable at build time; the read backend is release-agnostic.
- **SOST is the primary source** (a real transparent status-log table on both releases): each row
  is one send-attempt status carrying MSGID/MSGTY/MSGNO/MSGV1-4. Status maps to MSGTY (E,A=error,
  W=wait, S,I=sent). `trace` groups by the SOST object id; recipient matching is best-effort on the
  MSGV variables (the exact recipient address lives in SOOS/address objects — a v1.5 join).
- **resend has no RFC path** (SX_OBJECT_RESEND / SX_SNDREC_RESEND exist on neither release) — it is
  a confirm-gated recorded GUI drive, shipped `NEEDS_RECORDING` (v1.5). v1 is read-only.
- **Data volume:** SOST grows unbounded — a default 7-day window + `--max` ROWCOUNT cap (500) +
  explicit narrow field lists keep reads under the RFC_READ_TABLE 512-byte row limit.
- **v1.5:** resend GUI capture; `trace --body` (SO_DOCUMENT_READ_API1); /sap-diagnose source-matrix
  registration. **v2:** BCST_SR (BCS) linkage; SOSG auth-scoped variant; health-snapshot diffing.
