# Test-verdict contract (`sapdev.testverdict/1`)

One machine-readable verdict line per test case, emitted by any test-producing skill so a
campaign ledger / `/sap-evidence-pack` can join them. Tab-separated, one line per case:

```
sapdev.testverdict/1<TAB>case_id<TAB>producer_skill<TAB>verdict<TAB>evidence_path<TAB>run_id
```

| Field | Meaning |
|---|---|
| `case_id` | Stable id of the test case (scenario header `case_id`, or `<id>#NN` for a data-driven row). |
| `producer_skill` | The skill that produced the verdict (`sap-test-replay`, `sap-golden-master`, `sap-run-abap-unit`, ...). |
| `verdict` | `PASS` \| `PASS_WITH_GAPS` \| `FAIL` \| `REPLAY_ERROR` \| `COULD_NOT_VERIFY`. FAIL (a real regression) is kept STRICTLY distinct from REPLAY_ERROR / COULD_NOT_VERIFY (the test itself could not run) so flakiness never counts as a regression. |
| `evidence_path` | Path to the report/screenshot bundle backing the verdict (for `/sap-evidence-pack`). |
| `run_id` | The `SAPDEV_RUN_ID` of the producing run (joins to the log + artifact index). |

Producers write `verdict.tsv` (this one line) into their artifact-dir run folder and register
it (`kind=test-verdict-line`). Consumers (campaign ledgers) append these lines and roll up.
Authored 2026-07-11 by /sap-test-replay (first native emitter); /sap-golden-master and
/sap-run-abap-unit adopt the same shape.
