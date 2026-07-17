# sap-release-notes

**Generates a business-readable CAB / release pack for a set of ABAP transport requests** —
what does this release change, how risky is it, what test evidence exists, and how would we
roll back? Read-only against SAP; no GUI session, no Z-object dependency.

```
/sap-release-notes <TR1[,TR2,...]>
/sap-release-notes --from YYYY-MM-DD [--to YYYY-MM-DD] [--user U] [--prefix ZPRJ]
                   [--ticket ID] [--max-impact N] [--refresh] [--docx]
```

## What it does

- **Resolves scope** from an explicit TR list or an E070 date range (owner / prefix filters;
  default `--to` = today), then builds the object inventory from E071 (request + child tasks)
  via `references/sap_release_notes_inventory.ps1` — one `changes.tsv` row per changed object.
- **Groups changes by business area** (package → application component → package text, with a
  customer override map); object types get human labels from
  `references/sap_release_object_types.tsv` (customer-overridable via `{custom_url}`).
- **Folds in existing verdicts** from the artifact index — `/sap-transport-readiness`
  GO/NO-GO per TR and `/sap-impact-analysis` risk bands per changed object — running them
  read-only only where missing (`--max-impact` caps the fan-out, default 25; `--refresh`
  re-runs). It never triggers ATC or ABAP-Unit itself.
- **Writes `cab_pack.md`** against a fixed section template (executive summary, changes by
  business area, risk, test evidence, ADVISORY rollback approach, open items / missing
  evidence, technical appendix), registers it for `/sap-evidence-pack`, and renders a
  best-effort `.docx` copy on `--docx`.

## Honest by construction

A hard grounding rule: every factual claim in the pack must trace to an inventory row or a
recorded verdict — object purposes, risk, and history are never invented. The
**Missing-evidence** section is mandatory: every TR/object without a verdict, every
`(unresolved)` package, every COULD_NOT_CHECK lands there, and an absent verdict is never
rendered as a pass. Rollback text is advisory template only — CTS has no true rollback, and a
one-click rollback is never claimed. Fail-loud scope handling: no content objects →
`EMPTY_SCOPE`; a date range matching > 50 TRs is refused (`TOO_MANY_TRS`); a pack is never
written from a failed inventory.

## Reads

`E070`/`E07T`/`E071` (scope + inventory), `TADIR`/`TDEVC`/`TDEVCT`/`DF14T` (package → area
grouping). Grouping is best-effort and honest: `TABU`/`VDAT` customizing and deleted objects
have no TADIR package and land in `(unresolved)`; `LIMU` sub-objects are attributed to their
R3TR master where derivable. Phase 2 (parsed but declared not-yet-implemented):
`--customizing` (E071K TABKEY decode + IMG grouping, v1.5) and `--deep --against`
(per-object source diffs via /sap-compare, v2).

Read-only; never releases, imports, or modifies anything in SAP; no confirm gates needed.
Prerequisites: SAP profile via /sap-login (RFC password); SAP NCo 3.1 (32-bit) in GAC.
