# sap-delivery-report

**Assemble the weekly delivery status report** — objects in build/test/prod, quality-gate
posture (RAG), TR pipeline position, and week-over-week progress — by correlating what the
suite already produced instead of re-gathering it by hand every Friday. Offline-first; at
most ONE live RFC read.

```
/sap-delivery-report [generate] <PACKAGE pkg | TR trkorr | PROGRAM name | --ticket id>
                     [--since last|YYYY-MM-DD] [--offline] [--docx] [--title "..."]
/sap-delivery-report snapshots <scope>
```

## What it does

- **Aggregates the artifact index** (ATC / check-abap / abap-unit / transport-readiness /
  impact verdicts), build KPIs, and optional campaign state — all local.
- **Adds exactly one live RFC read** (E071 → E070/E07T) for TR pipeline position;
  `--offline` drops even that.
- **Derives a DETERMINISTIC RAG** from a shipped, customer-tunable rules table
  (`references/sap_delivery_rag_rules.tsv`, printed in the report appendix). Customer
  overrides may only tighten, never relax.
- **Persists a snapshot** per run and diffs against `--since last|<date>|<id>` — transition
  counts (AMBER→GREEN ×4, new RED ×1), new/removed objects — plus trend TSVs.
- **Renders `report.md`** — the engine computes `report_data.json`; Claude writes the
  narrative from it under a hard grounding rule, with an optional `--docx` handoff.

## Honest by construction

Every RAG cell cites the artifact ids behind it; any narrative claim not backed by evidence
is prefixed `INFERRED:`. Two hard floors no customer override can relax: **no evidence ⇒
AMBER** and **COULD_NOT_CHECK ⇒ at least AMBER** — "no evidence" is never green. A failed
RFC read renders the TR column COULD_NOT_CHECK but never presents the partial report as
complete; a missing artifact index still renders, as an explicit all-AMBER "no evidence"
posture. Absent KPIs read "not produced", never 0%.

## Reads

The local artifact index (`index.jsonl`) + KPI files; the one RFC read is `RFC_READ_TABLE`
on `E071`/`E070`/`E07T` (TADIR for package scope expansion). Pinned `/sap-login` profile +
SAP NCo 3.1 (32-bit) required unless the scope is a scope-key / `--ticket` or `--offline`
is passed — those run fully local. No GUI, no Z-object dependency, no writes to SAP.

Read-only by design. Scope types: package, TR, program/class/FM, ticket, or a raw
scope-key. `--imports` (TPALOG import history), `--tms-queue` (live import-queue position),
and a deeper `--campaign` fold-in are the documented next phases. Live-verified on S/4HANA
1909 (S4D).
