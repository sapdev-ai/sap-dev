# sap-interface-inventory

**Enumerates a SAP system's integration surface and correlates it into a named interface
register** — the "list of all interfaces" every upgrade, S/4 migration, or system takeover
needs and no SAP system has. Read-only over RFC (no writes, no report execution, no GUI,
no Z-object dependency).

```
/sap-interface-inventory scan [--sources rfc,idoc,zfm,odata,proxy,jobs]
                              [--max-rows N] [--namespace Z,Y] [--profile <name>]
/sap-interface-inventory doc <idoc MESTYP|rfcfm FMNAME|dest RFCDEST> [--format md|docx] [--deep]
/sap-interface-inventory refresh          # v1.5 — not yet implemented
```

## What it does

- **scan** reads six confirmable sources into per-source TSVs: RFC destinations (RFCDES),
  IDoc/ALE partner profiles (EDP13/EDP21/EDIFCT/TBD05), Z/Y RFC-enabled FMs (TFDIR), OData
  services (the Gateway hub catalog), ABAP proxies (SPROXHDR), and interface-relevant
  batch jobs (TBTCO/TBTCP mapped via `references/interface_program_map.tsv`,
  customer-overridable).
- Claude then **clusters the sources into `interface_register.tsv`** — one row per named
  logical interface with technology, direction, partner/destination, message/service,
  handler, and an EVIDENCE column citing the concrete source rows — under a **hard
  CONFIRMED-vs-INFERRED rule**: CONFIRMED only when a direct config chain links the
  evidence (e.g. an EDP21 inbound row + its EDIFCT handler); any name-similarity or
  job-heuristic link stays INFERRED, never upgraded.
- `interface_register.md` adds the human-readable register grouped by technology plus a
  **mandatory Gaps section** listing every source that could not be checked and the
  v2-deferred sources not scanned.
- **doc** reverse-engineers one interface into a spec: the IDoc segment tree (via
  IDOCTYPE_READ_COMPLETE, with per-segment fields and DDIC texts) or an RFC-FM signature
  (via RPY_FUNCTIONMODULE_READ), each section marked CONFIRMED (read live) vs INFERRED
  (narration). OData/proxy doc flavors are refused in v1. `--format docx` renders via the
  docx skill; `--deep` chains `/sap-explain-object` for handler narration.

## Honest by construction

Release divergence is handled by runtime existence probes, never a silently thinner
register: a missing source table (Gateway catalog on ECC, SPROXHDR on a proxy-less
release) becomes a NOT_APPLICABLE / COULD_NOT_CHECK row plus a Gaps entry. `rows=">N"`
means the row cap was hit — "at least N", never a pretended exact count. A connect
failure fails loud (`RFC_LOGON_FAILED`); a partial register is never presented as
complete. The RFCOPTIONS parser masks credential-shaped tokens before anything reaches a
TSV or log; a denied RFCDES read surfaces as COULD_NOT_CHECK with the auth object named.

## Reads

RFCDES, EDP13/EDP21/EDIFCT/TBD05, TFDIR, the Gateway hub catalog, SPROXHDR, TBTCO/TBTCP
(scan); IDOCTYPE_READ_COMPLETE + RPY_FUNCTIONMODULE_READ (doc). Backends:
`references/sap_interface_scan.ps1` + `references/sap_interface_doc.ps1`. Every output is
registered via the artifact index for `/sap-evidence-pack`.

Read-only; no confirm gates needed in any v1 mode. Prerequisites: pinned `/sap-login`
RFC profile (no GUI session); SAP NCo 3.1 (32-bit). Phase 2: `refresh` NEW/GONE/CHANGED
delta, the Z-source `CALL FUNCTION … DESTINATION` scan, SOAMANAGER runtime
reconstruction, OData/proxy doc flavors.
