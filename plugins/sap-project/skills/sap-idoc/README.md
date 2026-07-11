# sap-idoc

Diagnose and reprocess **failing IDocs** — the #1 AMS interface incident class —
read-only over RFC (no GUI; no Z-object for find/explain/triage).

```
/sap-idoc find    [--dir=1|2] [--status=51,56] [--mestyp=M] [--partner=P] [--from=YYYYMMDD] [--to=YYYYMMDD] [--max=N]
/sap-idoc explain <DOCNUM>
/sap-idoc triage  [find-filters]
/sap-idoc reprocess <DOCNUM | --status=..&--mestyp=..>     # status-routed, confirm-gated
```

## What it does

- **`find`** — bounded `EDIDC` search (refuses an unbounded scan). Resolves each
  status to its text (`TEDS2`) and severity, and **counts failures per status ×
  message type** — the morning-triage digest.
- **`explain <DOCNUM>`** — the full `EDIDS` status timeline: every step with its
  severity (`STATYP`), message id (`STAMID-STAMNO`), parameters and rendered text.
  The last error step **is** the root cause ("posting period not open", "sold-to
  party not maintained for sales area", …). Cross-references SLG1 for app-log detail.
- **`triage`** — clusters status-51/56 failures by `(MESTYP, STAMID, STAMNO)`, labels
  each with a root cause + count, and hands custom-handler (`Z*`/`Y*` IDoc type)
  clusters to `/sap-fix-incident`.
- **`reprocess`** — status-routes the target to **RBDMANI2** (inbound error) /
  **RBDAPP01** (ready-to-post) / **RSEOUT00** (outbound) through `/sap-run-report`
  (confirm-gated), then re-reads `EDIDS` to verify old→new status — never the report's
  own text. An IDoc that doesn't reach success is reported, never summarized away.

## Reads

`EDIDC` (header/status, field-projected — the full row exceeds the RFC_READ_TABLE
limit), `EDIDS` (status history), `TEDS2` (status text). **`EDID4` is never read** (a
CLUSTER table on ECC; segment decode is the v1.5 wrapper path). All TRANSP / FMODE=R,
identical on both releases.

Read-only for find/explain/triage; the only write is the reprocess report, gated.
Complements `/sap-diagnose`'s `smq` queue reader (Wave-0 T1-B) as the IDoc half of
interface diagnosis. Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP).
