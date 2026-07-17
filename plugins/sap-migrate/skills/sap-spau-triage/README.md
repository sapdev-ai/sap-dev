# sap-spau-triage

**Walk into the upgrade weekend with a triaged SPAU/SPDD list instead of a blank
tree.** This skill pre-assembles the modification-adjustment worklist for an
upgrade or S/4 conversion and produces an **advisory** classification per entry —
adopt / reset-candidate / re-implement / unclear — with cited evidence,
confidence, and effort band, front-loading the single biggest schedule risk
(deciding reset-vs-adopt per entry under time pressure). **BETA / advisory**: it
never executes SPAU/SPDD and never resets a modification.

```
/sap-spau-triage scan [--package=<mask>] [--user=<mask>] [--since=YYYYMMDD] [--max=500]
/sap-spau-triage scan --deep [--deep-max=25]        # + before/after source diff commentary
/sap-spau-triage inspect <OBJ_TYPE> <OBJ_NAME> [--deep]
```

## How it classifies

Read-only, pure RFC (NCo 3.1, 32-bit; no GUI, no Z objects): `scan` builds the
worklist from SMODILOG (aggregated per modified object) joined to ADIRACCESS
access keys + TADIR packages; `--deep` pulls before/after version source via the
SVRS FMs. A **deterministic offline classifier** (rule table R1–R6, first-match)
fixes class / confidence / coverage *before* any AI prose — a recommendation
never depends on model mood:

| Rule | Signal | Class |
|---|---|---|
| R6 | source-equal reset signal *plus* access-key registration (conflict) | unclear |
| R1 | SVRS source-equal proof (live version hash match) | reset-candidate **HIGH** |
| R2 | the object's own note completed in CWBNTCUST | reset-candidate LOW (ADVISORY) |
| R4 | FUGR/FUNC enhancement-adjacent | re-implement MEDIUM |
| R3 | note-mod without linkage → adopt LOW `COULD_NOT_CHECK`; assistant change → adopt MEDIUM | adopt |
| R5 | no evidence | unclear `COULD_NOT_CHECK` |

## Advisory contract (safety)

A wrong "reset" deletes a customer modification, so: a reset-candidate is HIGH
**only** with SVRS source-equal proof (note evidence is capped LOW and
`semantics=ADVISORY`, never a reset on its own); every reset row cites its
evidence and carries the literal "ADVISORY - verify in SPAU before resetting"
(the report header repeats it); unreadable versions / missing fields are
`COULD_NOT_CHECK`, never a silent classify. Outputs carry *coverage*, not a
GO/NO_GO verdict.

## Prerequisites

- Pinned RFC profile via `/sap-login` (RFC password); SAP NCo 3.1 (32-bit).
- No SAP GUI session needed — SPAU's own driver diverges by release
  (SPAU_UI_START on 1909 vs RSUMOD04 on ECC6), which is exactly why this skill
  stays RFC-only. SE95 is the stable manual cross-check on both.

## Key files

`references/sap_spau_rfc.ps1` (RFC backend: worklist / versions / notes),
`references/sap_spau_classify.ps1` (the deterministic classifier; its 7-case
fixture corpus lives in `sap_spau_classify.tests.ps1`). Outputs:
`spau_triage.tsv` + `spau_triage.md` (per-class counts, per-package rollup,
entry table, SE95 cross-check footer), registered via the artifact index.

## Status & limitations (BETA)

Live-verified on S/4HANA 1909 (S4D): 500 real modification entries read, a real
version chain fetched under `--deep`, and the classifier ran clean over the full
worklist. **Not yet validated: end-to-end classification accuracy against a real
post-upgrade adjustment queue** — the skill is BETA/advisory until the pre-GA
gate (>=50 entries, >=90% of HIGH reset-candidates human-confirmed, zero HIGH
refuted) passes on a project system. `route` (feeding re-implement candidates to
`/sap-enhancement-advisor`) is v1.5; cross-system `compare` and GUI navigation
assist are v2. ECC6 shares the identical RFC data path.

Part of the sap-migrate plugin (the upgrade-adjustment leg, alongside the
`/sap-cc-*` campaign pipeline).
