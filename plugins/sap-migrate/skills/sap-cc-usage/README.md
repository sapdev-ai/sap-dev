# sap-cc-usage

**Decide, for every inventoried custom object, whether to remediate, retire,
or review — by overlaying how often it actually runs.**
Second step of the sap-migrate pipeline (inventory → usage → decommission →
analyze → triage → remediate, orchestrated by `/sap-cc-campaign`). Retiring
dead code is usually the single biggest scope reduction in a conversion; this
step produces the headline "X% retired without remediation" number. It joins a
usage signal onto `inventory.tsv`, applies the decommission policy, and writes
`usage.tsv` + `scope.tsv` (REMEDIATE / DECOMMISSION / REVIEW). **This skill
only flags** — physical deletion is `/sap-cc-decommission`'s job, behind its
own signed gate.

```
/sap-cc-usage --campaign <id> --usage-source SCMON
/sap-cc-usage --campaign <id> --usage-file <export.tsv> --policy conservative
/sap-cc-usage --campaign <id> --usage-source WORKLOAD --workload-months 12
/sap-cc-usage --campaign <id> --usage-source NONE
```

## Usage sources

| Source | How | Confidence |
|---|---|---|
| `SCMON` / `UPL` | Direct RFC read of the source's ABAP Call Monitor / SUSG aggregation (`sap_cc_scmon_read.ps1`). **Preferred** — the canonical decommissioning signal. | Window-dependent (`WINDOW_WARN` when < 12 months or gapped). |
| `FILE` | Hand-supplied export (TSV/CSV: name, exec count, optional last-used). Offline. | As good as the export. |
| `WORKLOAD` | ST03N/SWNC fallback when SCMON was never activated (`sap_cc_workload_read.ps1`). | **Positive-only, LOW** — confirms what ran; can never prove "unused", so it never drives a DECOMMISSION (engine-enforced). |
| `NONE` | No usage data. | Every object → REMEDIATE (safe). |

## Safe by construction

- **No monitoring data never means "everything unused".** `NO_DATA` → every
  object defaults to REMEDIATE.
- **Join-rate guard.** A usage file matching zero inventory objects is rejected
  (`USAGE_JOIN_ZERO`), and a join rate below 10% requires `--force-low-join`
  (`USAGE_JOIN_LOW`) — both before anything is written, so a wrong-system or
  wrong-format export can't silently flag the estate unused.
- **Policy semantics:** `conservative` (default) parks unused objects as
  REVIEW pending the reference-safety check; `aggressive` flags DECOMMISSION
  without it (use with care); `none` remediates everything.
- **Reference-safety gate (Step 4).** Before a REVIEW object is promoted to
  DECOMMISSION, `/sap-where-used-list` must confirm no inbound callers from
  still-used objects. Manual / operator-driven in v1 — the helper never
  deletes and never promotes without it.

## Outputs and exit codes

`usage.tsv`, `scope.tsv` (both owned by this skill), `state.tsv` advanced to
SCOPED / DECOMMISSIONED / REVIEW, plus the raw `usage_scmon_export.tsv` /
`usage_workload_export.tsv` kept as evidence. Exit `0` = OK; `1` = inventory
empty/missing (run `/sap-cc-inventory`); `2` = bad input or the join guard
fired (nothing written). The helper prints the REMEDIATE / DECOMMISSION /
REVIEW split, the join rate, and `METRIC: decommission_savings_pct`.

## Prerequisites

- A populated `inventory.tsv` (`/sap-cc-inventory` first).
- `FILE` / `NONE` are fully offline. `SCMON` / `UPL` / `WORKLOAD` need SAP
  NCo 3.1 (32-bit) + a saved `source_profile` (or the pinned `/sap-login`
  connection).

## Key reference files

- `references/sap_cc_usage.ps1` — the offline scoping engine: join, policy,
  `usage.tsv` + `scope.tsv`, state advance.
- `references/sap_cc_scmon_read.ps1` — RFC reader for SUSG/SCMON
  (`SUSG_V_DATA` / `SCMON_VDATA` + `SUSG_ADMIN` window).
- `references/sap_cc_workload_read.ps1` — RFC reader for the ST03N workload
  fallback (`SWNC_GET_WORKLOAD_STATISTIC`, tcodes resolved via `TSTC`).

## Limitations

Usage truth = the observation window (short windows over-flag period-end
jobs — surface every `WINDOW_WARN`); matching is name-level against top-level
objects (sub-object exports err safe toward REVIEW); pre-7.52 UPL fed from
Solution Manager needs a manual `--usage-file` export; reference-safety
promotion is manual in v1. Part of the sap-migrate plugin (`/sap-cc-*`
campaign pipeline).
