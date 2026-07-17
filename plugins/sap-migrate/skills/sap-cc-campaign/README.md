# sap-cc-campaign

**The campaign workspace owner and orchestration brain of the sap-migrate
pipeline.**
Every other `sap-cc-*` skill (inventory → usage → decommission → analyze →
triage → remediate) reads from and writes into the workspace this skill
creates; this skill itself never touches the SAP system — it is pure
workspace/state/reporting, **offline** (no SAP GUI, no RFC, no NCo), fast, and
safe to call as often as you like.

```
/sap-cc-campaign init    --campaign <id> [--brief <path>] [--source <profile>] [--sandbox <profile>]
/sap-cc-campaign status  --campaign <id>
/sap-cc-campaign report  --campaign <id>
/sap-cc-campaign next    --campaign <id>
/sap-cc-campaign signoff --campaign <id> --gate scope_signoff --owner "Jane PM"
```

## Five subcommands

| Sub | What it does |
|---|---|
| `init` | Creates the workspace from the Migration Campaign Brief (`migration_brief.md` — distinct from the build-time customer brief): `campaign.json` + the empty `state.tsv` ledger. Idempotent — an existing campaign is never overwritten. |
| `status` | Per-state / per-tier counts + the headline metrics. |
| `report` | Renders `reports\dashboard.md`: state/tier/pattern rollup + five KPIs. An optional RFC drift pre-step (`sap_cc_drift_read.ps1`) detects source-side changes to tracked objects. |
| `next` | Recommends the next pipeline skill from the ledger, honouring the human gates. |
| `signoff` | Records a business-owner sign-off in `campaign.json.signoffs[]` — the only writer of that array, and the enforcement input for the gates. |

## Human gates (enforced in code, not convention)

- **`scope_signoff`** — `next` refuses to release the analyze step
  (`BLOCKED:`, exit `3`) until an APPROVED sign-off is recorded.
- **`dryrun_review`** — not blocked at `next` (the dry-run must run to produce
  the diffs the operator reviews); surfaced as `gate_status=PENDING` and
  hard-enforced downstream: `sap_cc_remediate.ps1 -Action record` refuses to
  mark progress until it is APPROVED.

A downstream write skill is **never auto-run past a gate** — at a gate the
pipeline stops and asks for explicit approval.

## Honest metrics

`status`/`report` emit five `METRIC:` lines — `decommission_savings_pct`,
`retired_without_remediation_pct`, `atc_clean_pct`, `auto_fix_rate_pct`,
`unmatched_findings_pct` — where `-1` means **n/a** (the source ledger doesn't
exist yet), rendered `n/a` in the dashboard, never `0%`, so "not measured yet"
is never mistaken for "perfect". `INFO:` audit lines keep the auto-fix
denominator and the physically-retired count auditable, and *flagged* for
decommission is kept separate from *physically retired* (the
`/sap-cc-decommission` ledger).

## The workspace contract

`{work_dir}\migrations\{campaign_id}\` holds `campaign.json` + `state.tsv`
(owned here) plus each downstream skill's detail files (`inventory.tsv`,
`usage.tsv`, `scope.tsv`, `findings\*`, `remediation\*`, `decommission\*`).
`state.tsv` is the single source of truth for progress; the object state
machine runs INVENTORIED → SCOPED → ANALYZED → TRIAGED → REMEDIATED →
VERIFIED → TRANSPORTED (with DECOMMISSIONED and REVIEW branches). Exit codes:
`0` ok, `1` campaign not found / ledger gap, `2` bad arguments or workspace
I/O, `3` gate BLOCKED (`next` only).

## Prerequisites

None — this skill is fully offline. The downstream skills it sequences do need
SAP access (see each skill's README).

## Key reference files

- `references/sap_cc_campaign.ps1` — the offline aggregator: atomic `init`
  write, `status` / `report` / `next` rollups, `signoff` upsert; parseable
  `STATE:` / `TIER:` / `METRIC:` / `NEXT:` / `SIGNOFF:` line grammar.
- `references/sap_cc_drift_read.ps1` — optional read-only RFC drift reader
  (`E070`/`E071` transports + `SMODILOG` since campaign start → `drift\drift.tsv`).

## Limitations

One source/sandbox/check-system triple per campaign id (multi-track = one
campaign per track); reporting is rollup-only (detail files stay with their
owning skill); `next` recommends from local state without re-confirming
objects on the live system; `next` returns `MANUAL` once the R1 /
decommission work is exhausted (R2–R4 tiers are AI-assisted / human work).
Part of the sap-migrate plugin (`/sap-cc-*` campaign pipeline).
