# sap-test-replay

**Re-runnable pass/fail GUI regression tests from recorded scenarios** — the
eCATT/CBTA equivalent the suite lacks, so a regression cycle stops meaning "re-test
transactions by hand and paste screenshots into Word". A scaffold-recorded linear
scenario (control IDs + screen identity + popup transitions from `/sap-gui-probe`) is
compiled into GUI segments run by ONE generic interpreter VBS, with a screenshot on
every failure.

```
/sap-test-replay run  <scenario.replay.json> [--data <bindings.tsv>] [--keep-going] [--dry-run]
/sap-test-replay lint <scenario.replay.json> [--data <bindings.tsv>]
/sap-test-replay init <probe-folder> [--name <s>]
```

## What it does

- **Three checkpoint types** — `field` (control value), `message` (status-bar
  class/number/type, can capture the created document number into a token), `table`
  (post-step RFC_READ_TABLE key assertion; grid-row assertions are banned in v1 — the
  classic eCATT flake source).
- **Honest triage** — FAIL (the system regressed) is kept STRICTLY distinct from
  REPLAY_ERROR (the replay broke: guard mismatch / unexpected popup / capture
  failure), so flakiness never masquerades as a regression. A table check that can't
  run is COULD_NOT_CHECK → PASS_WITH_GAPS, never a silent pass. Verdict precedence:
  `REPLAY_ERROR` > `FAIL` > `PASS_WITH_GAPS` > `PASS`.
- **lint** validates token coverage, guard completeness, the tcode (TSTC), and
  checkpoint fields against live DDIC; degrades to LINT_PARTIAL without RFC.
- **init** (pure local) converts a `/sap-gui-probe` folder into a scenario skeleton —
  steps, guards, and popup branches pre-filled, checkpoints stubbed.
- Emits a `sapdev.testverdict/1` line so a campaign ledger and `/sap-run-abap-unit`
  join the same verdict stream. Outputs (`report.md`, `results.tsv`, `verdict.tsv`,
  screenshots) go to `{OUT}` = `Get-SapArtifactDir -ScopeKey TCODE_<tcode>` and are
  registered for `/sap-evidence-pack`.

## Prerequisites

- A scaffold-recorded scenario (`/sap-gui-probe` + `init`)
- Active SAP GUI session via `/sap-login` (broker acquire/release)
- SAP NCo 3.1 (32-bit) for lint DDIC checks and table checkpoints

## Reference files

| File | Purpose |
|---|---|
| `references/sap_replay_compile.ps1` | Lint (RFC) + segment compiler (`-Action lint\|compile`) |
| `references/sap_replay_exec.vbs` | Generic segment interpreter (32-bit cscript; attach-lib + session-lock) |
| `references/sap_replay_table_check.ps1` | RFC_READ_TABLE assertion engine |
| `references/sap_replay_report.ps1` | Verdict roll-up + `sapdev.testverdict/1` line |
| `references/replay_scenario_schema.md` | Scenario format documentation |
| `references/example_mm03.replay.json` | Worked MM03 example scenario |
| `references/sap_replay_exec.screens.json` | Golden-screen baseline (generic deps) |

## Safety & limitations (v1)

- **run is confirm-gated** — it executes real transactions. Non-DEV/modifiable client
  requires a **typed** confirmation `REPLAY <SID>`; DEV needs yes/no. `--dry-run`
  compiles + lints only (no GUI, no gate).
- Release variance lives in scenario DATA, not VBS code — a live screen that diverges
  from the recording surfaces as REPLAY_ERROR:GUARD pointing at a `/sap-gui-probe`
  re-record, never a wrong-screen action.
- The non-GUI pipeline (lint, compile, table checks, roll-up truth table) is
  live-verified on S4D (S/4HANA 1909); the GUI leg was deliberately not run
  autonomously. ECC 6 shares the identical RFC path; a scenario is release-bound
  (`recorded_release` vs the live marker).
- Deferred: `run --data` multi-row loop (v1.5); `campaign` ledger modes (v2); suites,
  branching, ALV cell assertions.
