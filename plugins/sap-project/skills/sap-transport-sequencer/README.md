# sap-transport-sequencer

**Order transports into a safe import sequence, and audit code freezes** — read-only
over RFC, **detect-only** (never imports, never releases). Fills the cross-TR gap that
`/sap-transport-readiness` (single-TR) explicitly defers.

```
/sap-transport-sequencer sequence <TR1,TR2,…|--file=<path>> [--target=<profile>] [--max=200] [--skip-missing]
/sap-transport-sequencer freeze-audit --from=YYYYMMDD --to=YYYYMMDD [--policy=<path>]
```

## What it does

- **`sequence`** — reads the TR set from the source system (E070/E07T/E071), folds each
  LIMU object into its R3TR parent (so two TRs editing different pieces of `ZCL_X` count
  as one overlap; FUNC→FUGR via ENLFDIR), builds an object-overlap graph, and orders the
  released TRs by release timestamp under overlap constraints. Flags **unreleased** TRs
  and open tasks, same-object **overlaps**, **same-timestamp** ambiguity, still-modifiable
  **overtakers**, and source-side **missing predecessors** (a released TR touching a
  listed object but not in the set). With `--target=<profile>` it cross-checks a second
  system for **unimported predecessors** (target E070) and **first-time-delivery** objects
  (target TADIR). Output ends with a ready-to-paste `/sap-stms import` list — **which it
  never runs**.
- **`freeze-audit`** — one windowed E070 pass finds TRs released or changed inside a
  freeze window, minus policy exceptions (TRs / users / packages), with per-violation
  **VRSD materiality** (version count = did the object really change in-window). Produces
  a violations list + freeze annex for the audit trail.

## Detect-only by construction

There is deliberately **no `import`, `release`, or `enforce` verb** — execution stays
with `/sap-stms` and its typed production gates (a human decision). Freeze enforcement is
organizational; this skill produces the evidence, not the block.

## Honest by construction

An unknown TR is a hard `SEQ_TR_NOT_FOUND` (unless `--skip-missing`). An unreachable
`--target` is an explicit continue/abort choice with `COULD_NOT_CHECK` rows, never a
silent "safe". Same-timestamp overlapping pairs are flagged (date+time granularity is not
infinite precision), never silently ordered. v1 customizing overlap is **table-level**
(disjoint E071K keys not yet distinguished — conservative, never unsafe). E070 stores no
creation date, so freeze-audit says "released/changed in-window" honestly and leans on
VRSD evidence.

## Reads

`E070`/`E070A`/`E071`/`E07T` (TR headers/attributes/objects/texts), `ENLFDIR` (FUNC→FUGR
fold), `TADIR` (target first-time + package exceptions), `VRSD` (change materiality). All
FMODE=R / TRANSP, identical on ECC 6 and S/4HANA — one code path.

Read-only; never imports/releases; the `/sap-stms import` lines are emitted as text.
`--keys` (E071K key-level overlap), `--deep` (TMS queue + VRSD downgrade compare), and
`--since-last-run` (freeze ledger) are the next phases. Verified live on S/4HANA 1909
(S4D) and ECC 6 (EC2/ERP).
