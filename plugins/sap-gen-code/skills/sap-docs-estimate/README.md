# sap-docs-estimate

**Turn the spec pipeline's structural signals into a transparent, falsifiable effort
estimate.** Delivery managers quote stacks of incoming specs and migration waves on gut feel;
this scores them deterministically from the artefacts the pipeline already produces — and
records actuals so the estimate becomes measurable instead of unfalsifiable.

```
/sap-docs-estimate <work-folder> [--brief <path>]        # score one spec
/sap-docs-estimate --batch <folder-of-work-folders>      # portfolio roll-up
/sap-docs-estimate --ledger <findings_triaged.tsv>       # band a migration wave (tier x object)
/sap-docs-estimate record-actuals <estimate-id> --actual <hours> [--phase build|test|total]
```

## What it does

- **score** — count the work folder's `_*.txt` DDIC/process/interface/test signals plus
  `/sap-docs-check` ambiguity rows, apply published weights, and map the complexity class
  (XS–XL) to a **wide effort band** with named drivers, a coverage matrix, and an assumptions
  register. The build band is uplifted by DECLARED test/integration/functional multipliers
  (shown, never hidden).
- **--batch** — the same scorer over every spec folder, one portfolio table.
- **--ledger** — band a `/sap-cc-triage` wave: each object scored by (remediation tier R1–R4 ×
  TADIR object type). Read-only toward campaign state.
- **record-actuals** — append real hours to an append-only ledger keyed by estimate id, so
  every estimate is falsifiable. `calibrate` (v1.5) tightens the multipliers once ≥8 pairs
  accrue; below that it refuses (no fake calibration).

## Honest by construction

- A missing input file = that signal `COULD_NOT_CHECK` — the band **widens**, never a silent
  zero.
- Every report is labelled `STRUCTURAL BAND — not a quote; calibration=NONE|n` so a wide,
  uncalibrated band can never masquerade as a commitment.
- Uplift factors are DECLARED guesses kept in the assumptions register until actuals calibrate
  them; `record-actuals` on an unknown id and `calibrate` below the pair threshold both refuse
  loud.
- Deterministic: same inputs → identical score (verified).

## No SAP needed

v1 is pure-local — no RFC, no GUI, no TR, no deploys — so it runs before dev setup and works
regardless of the connected system. The optional `--live-delta` brownfield-credit RFC mode
(objects the spec defines that already exist score as UPDATE not CREATE) is v2 and claimed for
S/4HANA only. Ships with offline fixtures under `references/fixtures/`. Part of the sap-docs-*
spec pipeline in sap-gen-code.
