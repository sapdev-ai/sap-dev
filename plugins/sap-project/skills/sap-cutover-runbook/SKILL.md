---
name: sap-cutover-runbook
description: |
  Turn a 200-step cutover Excel into a crash-safe, evidence-stamped tracker — the cutover
  lead stops doing 3am bookkeeping and answers "are we on the critical path?" instantly.
  `init` parses the runbook into a draft ledger behind a mandatory human-curation gate;
  `record` stamps start/done/fail events with machine-read RFC evidence (transport import
  return code from TPALOG, job status from TBTCO, table row counts) — never a screenshot;
  `report` renders the live board with per-phase progress, blockers, and the critical path
  over the remaining dependency DAG; `checkpoint --health` composes an advisory go/no-go with
  a tri-state system-health snapshot (dumps, update backlog, qRFC/tRFC queues, locks, running
  imports). v1 is read-only toward SAP (reads only); `run` auto-execution is v2. Prerequisites:
  /sap-login profiles (one per system named in the plan); SAP NCo 3.1 (32-bit). No Z-object,
  no dev-init — safe to point at a PRD/QAS cutover target.
argument-hint: "init <runbook.xlsx|.docx|.tsv> [--commit --cutover <id>]  |  record <id> <step> <start|done|fail|skip|block|reopen> [--verify]  |  report <id> [--live]  |  checkpoint <id> <name> [--health]"
---

# SAP Cutover Runbook — Tracker-First, Evidence-Stamped

Run the cutover off a crash-safe ledger instead of a hand-typed Excel: parse → curate →
stamp events with machine-read RFC evidence → live board with critical path → advisory
go/no-go at each checkpoint. **v1 never writes to SAP** (it only reads to verify);
execution stays with the existing gated skills (v2 `run`).

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_cutover_ledger.ps1` | `-Action parse\|commit\|record\|state` | Local crash-safe ledger (draft, plan, append-only events, derived state) |
| `<SKILL_DIR>/references/sap_cutover_verify.ps1` | `-StepType … [-System …]` | Read-only RFC step verifier (TPALOG / TBTCO / TABLE_CHECK) |
| `<SKILL_DIR>/references/sap_cutover_health.ps1` | `-System … -OutDir` | Read-only RFC health snapshot (8 signals) |
| `<SKILL_DIR>/references/sap_cutover_report.ps1` | `-OutDir` | Local board + critical path |
| `<SKILL_DIR>/references/runbook_column_map.tsv` | map | Customer heading → canonical field synonyms; override `{custom_url}\runbook_column_map.tsv` |
| `<SKILL_DIR>/references/cutover_health_defaults.json` | thresholds | Health warn/crit thresholds; override `{custom_url}\cutover_health.json` |
| `/sap-login` (Skill tool) | profiles | One RFC profile per `system` named in the plan |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | Step 7 | Artifact index for /sap-evidence-pack |

The **ledger directory `{artifact_dir}\cutover\<id>\` is a deliberate stable-path (Bucket-A)
exception**: a different Claude session hours into the flight must find it by predictable path.
That is the point — do not relocate it under `{RUN_TEMP}`.

## Step 0 — Resolve Work Dir + Ledger Root

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Ledger dir `{LEDGER}` = `{artifact_dir}\cutover\<cutover-id>`. Set `{RUN_TEMP}` = the
`RUN_TEMP=` value printed above (`Get-SapRunTemp` mints + creates the per-run scratch dir
holding the log state file) — for scratch; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_cutover_runbook_run.json" -Skill sap-cutover-runbook -ParamsJson "{}"
```

## Step 1 — Mode Dispatch

First token = `init` | `record` | `report` | `checkpoint` | `run`. Resolve `<cutover-id>` →
`{LEDGER}`. Every mode except `init` hard-fails `CUTOVER_LEDGER_NOT_FOUND` if `cutover.json`
is absent (curation not committed → `CUTOVER_CURATION_PENDING`). `run` → **v2**: say
`NOT_YET_IMPLEMENTED — auto-execution ships in v2` and STOP.

## Step 2 — init (parse → curate → commit)

**Parse.** Read the workbook/doc yourself (the /sap-docs-extract precedent: open the
xlsx/docx, dump the raw grid to a TSV under `{RUN_TEMP}` preserving the header row). For a
`.tsv` input, use it directly. Then:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cutover_ledger.ps1" -Action parse -Grid "{RUN_TEMP}\grid.tsv" -ColumnMap "<SKILL_DIR>\references\runbook_column_map.tsv" -OutDir "{LEDGER}"
```

Parse writes `runbook_draft.tsv` + `gaps.md`. Step type is a **PROPOSAL, MANUAL by default,
never guessed upward** (a TR key → TRANSPORT_IMPORT, job/report/table tokens → the matching
type). **Present the draft + gaps to the user and STOP for curation** — nothing is committed
in the same run. The user reviews/corrects step types, owners, dependencies, checkpoints, and
sets `auto_ok=YES` on any step they will let v2 auto-run.

**Commit** (only after the user confirms the curated draft):

```bash
… -Action commit -Draft "{LEDGER}\runbook_draft.tsv" -CutoverId "<id>" -OutDir "{LEDGER}"
```

Commit validates: unique ids, deps resolve, **no cycle** (`CUTOVER_DEP_CYCLE`), ≥1 checkpoint
(`CUTOVER_PARSE_FAILED reason=no_checkpoint`), and downgrades any automatable step still
missing its verify params to MANUAL with a WARN (never a silent automatable-without-params).
Writes immutable `cutover.json` + empty `events.jsonl`. Register `cutover.json` (kind
`cutover_plan`).

## Step 3 — record

```bash
… -Action record -OutDir "{LEDGER}" -StepId "<step>" -Event "<start|done|fail|skip|block|reopen>" -Actor "<who>" [-Note "…"] [-EvidenceRef "<path>"] [-Verify "<VERIFY:..>"]
```

Unknown step id → `CUTOVER_STEP_UNKNOWN`. With `--verify`, first run the verifier and pass its
result into `-Verify`:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cutover_verify.ps1" -StepType <T> -System <profile> [-Trkorr <tr> -Target <sid>] [-Jobname <j>] [-Table <t> -Where <w>]
```

Parse `VERIFY: PASS|FAIL|RUNNING|COULD_NOT_CHECK`. **A failed/unreachable verify is
COULD_NOT_CHECK and NEVER auto-marks the step done** — record the operator's stated event,
attach the verify result as evidence, and let the human decide. Copy any `--evidence` file
under `{LEDGER}\evidence\<step>\`.

## Step 4 — report

Optional `--live`: sweep in-flight automatable steps through the verifier first. Then:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cutover_report.ps1" -OutDir "{LEDGER}"
```

Parse `CUTOVER: id=… done=n/total blocked=b critical="…" critical_min=…`. The engine writes
`cutover_board.md` (phase table, critical path with per-step minutes, blockers, checkpoint
rollups). Present the headline and the critical path; register `cutover_board.md` (kind
`cutover_board`).

## Step 5 — checkpoint

Roll up steps marked for `<name>` + open blockers/failures. With `--health`, per system
profile named in the plan:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cutover_health.ps1" -System <profile> -StartDate <YYYYMMDD> -Defaults "<SKILL_DIR>\references\cutover_health_defaults.json" -OutDir "{LEDGER}"
```

Parse `HEALTH: probe=… count=… severity=… coverage=…`. **Compose the advisory verdict** (this
is the AI layer): any HIGH probe or open blocker → **NO_GO** input; any `COULD_NOT_CHECK`
caps at **GO_WITH_WARNINGS** (an unreachable system is never a silent healthy); otherwise
**GO**. The verdict is **advisory — the human decides**; name every unverified critical step
explicitly. Write + register `checkpoint_<name>.md` + `health_<ts>.tsv` (kind
`cutover_checkpoint` / `cutover_health`).

## Step 6 — Register & Log End

Register artifacts under scope `CUTOVER_<id>` with Coverage/Verdict from the finding model.
Echo the mode headline. Then:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_cutover_runbook_run.json" -Status SUCCESS -ExitCode 0
```

---

## Scope & Limitations

- **v1 implemented (read-only toward SAP):** `init` (parse + mandatory curation gate + crash-safe
  commit), `record` (+ `--verify` RFC evidence), `report` (board + critical path), `checkpoint`
  (+ `--health` snapshot). The only writes are local ledger files.
- **Single code path on ECC 6 and S/4HANA** — all 14 load-bearing objects are FMODE=R / TRANSP
  on both. Verified live 2026-07-11: S4D import S4DK900414 → PASS (TPALOG maxRC 4), job
  SAP_WORKFLOW_SYSTEM → PASS, T000 count; ERP import IDTK904302 → **FAIL (maxRC 8)**; health
  snapshot 8/8 probes on both (S4D 4876 tRFC / 4763 qRFC-out; ERP 1854 tRFC / 649 dumps).
- **Evidence is machine-read, not a screenshot:** transport import result = TPALOG **max return
  code** for the TRKORR (≤4 OK, ≥8 error; a TRBAT row = still RUNNING); job status = TBTCO
  (F=PASS, A=FAIL, R/Y/P/S=RUNNING); table check = RFC_READ_TABLE row count. Reads only.
- **Honest by construction:** step type is MANUAL-by-default and never guessed upward; curation
  is a hard gate (`CUTOVER_CURATION_PENDING` until commit); a torn last event line is
  quarantined on replay, never parsed as state; `reopen` supersedes `done` (history never
  rewritten); a failed/unreachable verify is `COULD_NOT_CHECK` and never auto-marks done; an
  unreachable health probe caps the verdict at GO_WITH_WARNINGS.
- **Crash-safe + resumable:** the ledger (`cutover.json` + append-only `events.jsonl` + derived
  `state.tsv`) lives at the stable path `{artifact_dir}\cutover\<id>\`, so a fresh Claude
  session hours later reconstructs identical state.
- **Not yet:** `run` auto-execution of the 4 whitelisted step types (TRANSPORT_IMPORT →
  /sap-stms, JOB_SCHEDULE → /sap-job, REPORT_RUN → /sap-run-report, TABLE_CHECK → /sap-se16n)
  is **v2** — whitelist + `auto_ok=YES` gate + liveness/identity re-verification + the
  delegates' own confirm gates, never bypassed. v1 is a tracker: no verb mutates SAP.
- **Single-writer** (one cutover lead) in v1; events arriving out of timestamp order draw a
  WARN. Multi-writer merge is a v2+ question.
