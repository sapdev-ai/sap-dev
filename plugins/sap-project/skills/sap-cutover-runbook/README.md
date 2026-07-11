# sap-cutover-runbook

**Turn a 200-step cutover Excel into a crash-safe, evidence-stamped tracker.** The cutover
lead stops doing 3am bookkeeping and starts answering "are we on the critical path?"
instantly — every start/done stamped with machine-read RFC evidence, not a screenshot pasted
into Word.

```
/sap-cutover-runbook init <runbook.xlsx|.docx|.tsv> [--commit --cutover <id>]
/sap-cutover-runbook record <id> <step> <start|done|fail|skip|block|reopen> [--verify] [--evidence <path>]
/sap-cutover-runbook report <id> [--live]
/sap-cutover-runbook checkpoint <id> <name> [--health]
```

## What it does

- **init** — parse the runbook into a draft ledger (column-synonym map → canonical schema;
  step type classified MANUAL-by-default, never guessed upward), emit a gaps report, and
  **stop for mandatory human curation**. `--commit` validates (unique ids, dependency cycle
  check, ≥1 checkpoint) and writes the immutable plan.
- **record** — append a timestamped event to the crash-safe ledger. `--verify` runs a
  read-only RFC verifier and attaches its result: transport-import **return code from
  TPALOG** (≤4 OK / ≥8 error), job status from **TBTCO**, table row count from
  RFC_READ_TABLE. A failed/unreachable verify is `COULD_NOT_CHECK` and **never auto-marks the
  step done** — the human decides.
- **report** — replay the events into a live board: per-phase progress, blockers, and the
  **critical path** (longest planned-duration chain through the remaining dependency DAG).
- **checkpoint** — roll up steps + open blockers into an advisory GO / GO_WITH_WARNINGS /
  NO_GO. `--health` adds a read-only snapshot: dumps (SNAP), update backlog (VBHDR), qRFC/tRFC
  queues, batch-input sessions, enqueue locks (ENQUE_READ), running imports (TRBAT).

## Honest + crash-safe by construction

- Curation is a **hard gate** (`CUTOVER_CURATION_PENDING` until commit) — `init` is honestly
  scoped as "draft + human curation", never magic parsing.
- The ledger is append-only JSONL + derived state at a **stable path**
  (`{artifact_dir}\cutover\<id>\`), so an 8–40h flight spanning Claude sessions and machine
  sleeps reconstructs identical state. A torn last line is quarantined, never parsed;
  `reopen` supersedes `done` (history never rewritten).
- v1 **never writes to SAP** — it reads only to verify. Execution stays with the existing
  gated skills (`run` auto-execution is v2, whitelist + `auto_ok` + liveness re-check).

## Reads

`TPALOG` (import return code), `TBTCO` (job status), `RFC_READ_TABLE` (table checks), plus the
health snapshot: `SNAP` / `VBHDR` / `TRFCQIN` / `TRFCQOUT` / `ARFCSSTATE` / `APQI` /
`ENQUE_READ` / `TRBAT`. All FMODE=R / TRANSP, identical on both releases — **zero Z-side
prerequisites**, so it tracks a cutover on the PRD/QAS targets a cutover actually touches.
Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) 2026-07-11 (incl. a real failed
import IDTK904302 → FAIL maxRC 8).
