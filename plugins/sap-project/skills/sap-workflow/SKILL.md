---
name: sap-workflow
description: |
  Diagnose, explain, and fix SAP Business Workflow runtime over RFC — the SWI1/SWIA/SWEL/SWU3
  expert path in one skill. diagnose finds stuck/errored workitems for an anchor (WI id /
  business object / task / user / status+date), decodes the SWWLOGHIST error (message class +
  number rendered via T100), flags agent-determination gaps (a READY dialog workitem with no
  actual agent), and reports event-queue + type-linkage + WF-BATCH health. explain builds a
  dossier for a WS/TS task or live WI (text, active definition version/status, triggering event
  linkages). act restart / cancel / forward a workitem through released SAP_WAPI_* write APIs
  behind a refusal matrix (restart only from ERROR; cancel refused if already
  COMPLETED/CANCELLED; forward needs --to + a dialog item) and a confirm gate, verified by an
  authoritative SWWWIHEAD.WI_STAT re-read (a WAPI success code with an unchanged status is
  WF_ACT_FAILED, never a false success). Pure RFC (all FMs FMODE=R on ECC6 + S/4, single code
  path); no GUI, no wrapper FM, no Z object, no dev-init. RFC unavailable fails LOUD (BLOCKED ->
  /sap-doctor), never a silent GUI degrade. Registers as /sap-diagnose's workflow reader.
  Prerequisites: pinned /sap-login RFC profile; NCo 3.1 (32-bit).
argument-hint: "diagnose [--status error|all] [--task TS/WS..] [--user U] [--since YYYYMMDD] [--wi ID] | explain <WS/TS/WI> | act <restart|cancel|forward> <WI> [--to USER]"
---

# SAP Workflow Runtime Skill

You answer "why is this approval / workflow stuck?" and, on request, fix it — all over RFC.
`diagnose` and `explain` run unprompted (read-only); every `act` verb is confirm-gated and
verified by an authoritative status re-read. You never write a table and never guess a status.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_workflow_rfc.ps1` | `-Mode diagnose\|explain\|act` | The whole backend (all three modes) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_connection_lib.ps1` | dot-source | RFC connect + pinned profile |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` · `sap_artifact_lib.ps1` | dot-source | Finding/coverage model + evidence registration |
| `/sap-explain-object` · `/sap-st22` · `/sap-diagnose` | sub-skills | Z-object chain / dump drill / evidence reader (`workflow` row) |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_workflow_run.json`). Pure RFC — no GUI, no session attach, no baseline.

## Step 1 — Parse & Dispatch

First token = `diagnose` (default) | `explain` | `act`. `act` requires a verb
(`restart|cancel|forward`) + WI id. `diagnose` takes `--wi/--task/--user/--object/--status/
--since/--top` (default `--status error --since <today-30d> --top 20`, hard cap 200). Pinned
profile via `/sap-login` (or `--connection <hint>` -> backend `-Profile`).

## Step 2 — Connect

Backend connects the pinned RFC profile. RFC unavailable -> `STATUS: BLOCKED` -> tell the user
to run `/sap-doctor`; do NOT degrade to GUI (v1 is RFC-only by design).

## Step 3 — diagnose

```bash
... sap_workflow_rfc.ps1 -Mode diagnose [-Status error|all] [-Task ..] [-User ..] [-WiId ..] [-Since YYYYMMDD] -Top 20 -OutDir "{RUN_TEMP}\wf"
```

Emits `WFSEL:` (match count), one `WF:` per workitem (`wi/type/stat/task/top/agent/flag/err/text`
— `err` is the decoded SWWLOGHIST message, `flag=AGENT_DETERMINATION` when a READY dialog WI has
no agent), `WFENV:` health rows (event-queue backlog, inactive type linkages, WF-BATCH lock
state, SWU3 = COULD_NOT_CHECK), then `STATUS: OK matched=.. errors=.. agent_gaps=..`. Map each
error/agent-gap to `New-SapFinding` (severity per signal, tri-state coverage — SWU3/absent reads
are COULD_NOT_CHECK, never "passed"); `Get-SapVerdict`; render a table + next-action hints
(`/sap-workflow act restart <wi>`, manual SWU3, `/sap-st22` when SWWLOGHIST shows a runtime
abort). Zero matches -> say so explicitly (never an empty-file false success).

## Step 4 — explain

```bash
... sap_workflow_rfc.ps1 -Mode explain -Task <WS/TS..>   (or -WiId <id>)
```

`WFEXPL:` lines give task short/text, active definition version+status (WS only; COULD_NOT_CHECK
if no active SWDSHEADER row), and triggering event linkages (`WFEVENT:` objtype/event/active).
Render a dossier MD; when the task calls a Z class/FM, offer to chain `/sap-explain-object`.

## Step 5 — act (confirm-gated)

1. Backend pre-reads the WI and applies the **refusal matrix** BEFORE any prompt: restart needs
   `WI_STAT=ERROR`; cancel refused on COMPLETED/CANCELLED; forward needs `--to` + a dialog (W)
   item. A refusal -> `WFACT: REFUSED` + `WF_ACT_INVALID_STATE`; stop (the user is never asked to
   confirm a no-op). Run once with `-DryRun` to preview the target + FM.
2. **CONFIRM gate** (you, in chat): restart/forward = yes/no naming WI, task, text, SID/client;
   cancel = typed WI-id confirmation (logical delete is irreversible). On "no" -> log `SKIPPED`,
   issue NO RFC write.
3. Re-run without `-DryRun`. Backend calls the released WAPI FM (WORKITEM_ID + DO_COMMIT='X'),
   reads RETURN_CODE, then **re-reads SWWWIHEAD.WI_STAT**: `rc=0` + status changed -> OK;
   `rc=0` + unchanged -> `WF_ACT_FAILED`; `rc<>0` -> `WF_ACT_FAILED`. `restart` targets the top
   workflow (`TOP_WI_ID`); `cancel` on a type-F item cancels the whole workflow.

## Step 6 — Outputs + Register

Write `workflow_<mode>_<anchor>.tsv` / dossier MD / `workflow_act_<wi>.tsv` to `{RUN_TEMP}`,
copy durables to the artifact dir, `Register-SapArtifact` each (Kind `workflow_findings` /
`workflow_dossier` / `workflow_action`; scope key literal `WI_<id>` / `WF_<task>`).

## Final — Log End

Log end (`SUCCESS`/`SKIPPED`/`FAILED` + error_class). Error classes: `WF_WI_NOT_FOUND`,
`WF_ACT_INVALID_STATE`, `WF_ACT_FAILED`, `WF_DEFINITION_NOT_FOUND`, `WF_INPUT`; reused
`RFC_LOGON_FAILED` / `RFC_ERROR` / `BLOCKED`.

---

## Scope & Limitations (v1)

- **Live-verified** S4D (S/4HANA 1909) + EC2 (ECC 6) 2026-07-11: `diagnose` decoded 6 ERROR
  workitems on S4D (SWF_RUN-630 / SWF_FLEX_ENGINE-002 via T100) and flagged 5 READY dialog
  workitems as AGENT_DETERMINATION on EC2, where it also caught **WF-BATCH locked (UFLAG=64)**;
  `explain` resolved task text + active definition version + triggering events; `act` refusal
  matrix + dry-run verified (restart-from-COMPLETED and cancel-of-CANCELLED correctly refused
  before any prompt). Identical object surface -> single code path, no release variants.
- **act mutations are wired + gated, not run autonomously.** The WAPI signatures are probe-
  verified (`WORKITEM_ID` NUM12 + `DO_COMMIT`; `SAP_WAPI_FORWARD_WORKITEM` USER_IDS table;
  `RETURN_CODE`/`NEW_STATUS` exports) and every path up to the mutation is verified; the actual
  restart/cancel/forward runs only behind the Step-5 confirm gate (workflow writes are gated by
  the auto-mode classifier — not executed unattended).
- **RFC-only, fail-loud.** No GUI VBS, no `Z_GENERIC_RFC_WRAPPER_TBL`, no dev-init. RFC down ->
  BLOCKED (no silent GUI degrade). SWU3 full customizing check has no headless program (blank
  PGMNA) -> COULD_NOT_CHECK with a manual pointer; health is approximated by
  SWEQUEUE/SWETYPECOU/WF-BATCH reads. HRS1201 task-binding + SWDSHEADER version edge cases degrade
  to COULD_NOT_CHECK, never a guessed value.
- **Data volume:** SWWWIHEAD is huge — every enumeration is status/date/anchor-filtered with a
  ROWCOUNT cap; `--top` is hard-capped at 200.
- **v1.5:** `act complete` (SWW_WI_ADMIN_COMPLETE); SWEQADM queue on/off state; step-level graph
  in explain. **v2:** `act raise-event` / decision handling; GUI SWIA fallback; RSWWERRE mass-
  retry batch via /sap-job.
