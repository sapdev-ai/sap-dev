# sap-workflow

**Diagnose, explain, and fix SAP Business Workflow runtime over RFC** — the
SWI1/SWIA/SWEL/SWU3 expert path in one skill, answering "why is this approval stuck?"
and, on request, fixing it. `diagnose` and `explain` run unprompted (read-only); every
`act` verb is confirm-gated and verified by an authoritative status re-read.

```
/sap-workflow diagnose [--status error|all] [--task TS/WS..] [--user U] [--since YYYYMMDD] [--wi ID]
/sap-workflow explain <WS/TS/WI>
/sap-workflow act <restart|cancel|forward> <WI> [--to USER]
```

## What it does

- **diagnose** — finds stuck/errored workitems for an anchor (WI id / business object
  / task / user / status+date; default `--status error --since <today-30d> --top 20`),
  decodes the SWWLOGHIST error via T100, flags agent-determination gaps (a READY
  dialog workitem with no actual agent), and reports environment health: event-queue
  backlog, inactive type linkages, WF-BATCH lock state. Findings roll up through the
  shared finding/coverage model with next-action hints.
- **explain** — a dossier for a WS/TS task or live WI: task text, active definition
  version/status, triggering event linkages; offers to chain `/sap-explain-object`
  when the task calls a Z class/FM.
- **act** — restart / cancel / forward a workitem through released `SAP_WAPI_*` write
  APIs behind a **refusal matrix applied before any prompt** (restart only from ERROR;
  cancel refused if already COMPLETED/CANCELLED; forward needs `--to` + a dialog item)
  and a confirm gate (cancel requires a **typed WI-id** — logical delete is
  irreversible). Every mutation is verified by an authoritative `SWWWIHEAD.WI_STAT`
  re-read: a WAPI success code with an unchanged status is `WF_ACT_FAILED`, never a
  false success.
- Registers `workflow_findings` / `workflow_dossier` / `workflow_action` artifacts;
  also serves as `/sap-diagnose`'s `workflow` evidence reader.

## Prerequisites

- Pinned RFC profile via `/sap-login`; SAP NCo 3.1 (32-bit)
- Pure RFC — no GUI session, no wrapper FM, no Z object, no dev-init
- RFC unavailable fails LOUD (`BLOCKED` → run `/sap-doctor`), never a silent GUI
  degrade

## Reference files

| File | Purpose |
|---|---|
| `references/sap_workflow_rfc.ps1` | The whole backend (`-Mode diagnose\|explain\|act`, with `-DryRun` preview for act) |

## Safety & limitations (v1)

- **Live-verified on S4D (S/4HANA 1909) + EC2 (ECC 6):** diagnose decoded ERROR
  workitems via T100, flagged READY dialog items as AGENT_DETERMINATION, and caught a
  locked WF-BATCH; explain resolved task text + definition version + events; the act
  refusal matrix and dry-run verified. Identical object surface — single code path.
- **act mutations are wired + gated, not run autonomously** — the actual
  restart/cancel/forward executes only behind the confirm gate. `restart` targets the
  top workflow; `cancel` on a type-F item cancels the whole workflow.
- SWU3's full customizing check has no headless program → COULD_NOT_CHECK with a
  manual pointer, never rendered as "passed". SWWWIHEAD is huge — every enumeration is
  filtered and ROWCOUNT-capped; `--top` is hard-capped at 200.
- v1.5: `act complete`, SWEQADM queue state, step-level graph in explain. v2:
  `act raise-event` / decision handling, GUI SWIA fallback, RSWWERRE mass-retry via
  `/sap-job`.
