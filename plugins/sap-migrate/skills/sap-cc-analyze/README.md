# sap-cc-analyze

**Run the S/4HANA-readiness ATC over a campaign's REMEDIATE objects and fold
the findings into the campaign ledger.**
Sits in the sap-migrate pipeline after `/sap-cc-usage`, before `/sap-cc-triage`
(inventory → usage → decommission → **analyze** → triage → remediate,
orchestrated by `/sap-cc-campaign`). The ATC engine itself is `/sap-atc
--variant=S4HANA_READINESS` — this skill ships no new GUI scripting; it
prepares the worklist, loops the ATC runs, and ingests the per-finding exports
into `findings/findings_raw.tsv`, advancing each covered object to ANALYZED.

```
/sap-cc-analyze prepare --campaign <id>
/sap-cc-analyze prepare --campaign <id> --limit 20 --batch-size 50
/sap-cc-analyze ingest  --campaign <id> --results <file|dir>
/sap-cc-analyze prepare --campaign <id> --variant DEFAULT
```

## Two actions

- **`prepare`** — builds `findings\analyze_worklist.tsv` from `scope.tsv`
  (REMEDIATE objects still SCOPED), mapping each ledger type to the
  `/sap-atc` object type. Types with no ATC category (DEVC, MSAG, bare FUNC)
  are diverted to `analyze_skipped.tsv` and never mis-marked ANALYZED —
  `/sap-cc-campaign next` treats them as non-blocking. With `--batch-size <n>`
  it also writes `--object-list` batch files so one `/sap-atc` run covers a
  whole batch instead of one object.
- **`ingest`** — parses ATC result exports (the `/sap-atc --drill`
  per-finding TSVs, or a manual "Manage Results" export — header-tolerant)
  into the findings ledger and advances state.

## Honest by construction

- **Readiness is never faked.** `/sap-atc` fails loud if it cannot set the
  `S4HANA_READINESS` variant, so a generic run is never passed off as a
  readiness run. A Step-1.5 RFC preflight (`sap_readiness_probe.ps1`) catches
  the no-variants case before the loop; the authoritative gate remains
  `/sap-atc`'s `ATC_PLAN_ERRORS` — readiness findings come from checking the
  ECC source (or a hub checking it remotely via central ATC), not from a local
  S/4-target run.
- **ANALYZED only on evidence.** An object advances only when this ingest has
  a finding row for it, or it appears in the `checked_objects.tsv`
  clean-coverage export appended after a completed zero-finding run. The
  worklist alone is never evidence — uncovered objects stay SCOPED and are
  counted on an `INFO:` line, so a partially-run loop can never record unrun
  objects as analyzed-clean. Re-ingest is safe (findings dedupe).

## Prerequisites

- A scoped campaign (`/sap-cc-usage` first).
- The connected system must offer the `S4HANA_READINESS` GLOBAL variant with
  the Simplification Database loaded — typically the campaign's check hub, not
  the bare source ECC (`/sap-login --switch <check_system_profile>`).
- A working `/sap-atc` (active SAP GUI session; its per-stage recordings
  target the S/4HANA 1909 ATC layout — re-record a failing stage with
  `/sap-gui-probe --record`).

## Key reference files

- `references/sap_cc_analyze.ps1` — the offline spine: `prepare`
  (scope → worklist + optional batches) and `ingest` (exports →
  `findings_raw.tsv`, state → ANALYZED).

## Limitations

Simplification-item / SAP-note columns are populated only when the export
carries them (verify on first run for your release); the `/sap-atc
--object-provider` field id for true remote central-ATC runs is unverified
(the fail-loud guard is verified); recording debt is inherited from `/sap-atc`
(release-coupled component IDs); objects already past ANALYZED are excluded by
re-prepare. Part of the sap-migrate plugin (`/sap-cc-*` campaign pipeline).
