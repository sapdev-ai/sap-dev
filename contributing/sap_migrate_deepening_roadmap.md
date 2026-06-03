# sap-migrate Deepening — Roadmap Status

**Owner:** repo authors · **Last updated:** 2026-06-03 · **System used:** S4D
(S/4HANA 1909, single standalone box — no satellites/hub).

Consolidated status for the "Deepen S/4HANA migration" enhancement set. This is
the durable index; per-run detail lives in `temp/testReport/sap_*_20260603.md`
(referenced below). Source critique: the six items came from a review of the
`sap-migrate` plugin's v1 gaps.

## Guiding principle (applies to every item)

Each enhancement ships with an explicit **"couldn't verify / not applicable"
boundary instead of false confidence** — matching this repo's hard-won anti-
false-SUCCESS posture. Concretely: `n/a` vs `0%` (dashboard), `NO_DATA -> safe
REMEDIATE` (usage), fail-loud-not-silent (ATC variant + remote), and
DRAFT-until-ATC-verified (recipes).

## Status at a glance

| # | Item | Status | Live-verified? |
|---|---|---|---|
| (2) | Readiness ATC variant | DONE | YES — full 4-stage e2e on S4D |
| (6) | Migration dashboard | DONE | offline PS5.1 (pure aggregator) |
| (1) | SCMON/UPL direct usage read | DONE | connect + empty-safe path on S4D; aggregation offline |
| (5) | R2/R3 assist mode | ALREADY SHIPPED | n/a (pre-existing) |
| (3) | Remote / central ATC | DONE (scoped) | fail-loud guard on S4D; remote success path NOT (no hub) |
| (4) | More simplification recipes | DONE | regex + TSV offline; simpl-item match NOT (flywheel) |

---

## (2) Readiness ATC variant — `/sap-atc --variant=<NAME>`

**Problem:** `/sap-atc` ran the system DEFAULT check variant; the migrate chain
assumed S/4-readiness findings -> generic findings mislabeled as readiness (a
correctness bug, not a feature gap).

**Shipped:** `--variant=` (alias `--check-variant=`) sets the run-series check
variant; empty = system default (backward compatible); **fail-loud** if the
field can't be located (never silently runs default under a named-variant
request). Wired `sap-cc-analyze` / `sap-cc-remediate` to `--variant=S4HANA_READINESS`.

**Grounded (durable):** verified check-variant field on S/4HANA 1909 =
`wnd[0]/usr/ctxtSATC_CI_S_CFG_SERIE_UI_01-CHECK_VARIANT` (GuiCTextField). Live
gotchas: ENTER validates the WHOLE config screen (post-ENTER `E` may be an
unrelated field -> Step 5a.1 is WARN not abort); the Stage-2 run-series MANAGEMENT
grid name column is `NAME` (not `APP_CONFIG_NAME`, which is the Stage-3 monitor
grid); CREATE_SERIE + Continue does NOT persist (only Save does).

**Verified:** full 4-stage e2e on S4D against `PROGRAM ZTIGER` — SAP accepted
`S4HANA_READINESS`, run COMPLETED, P1/P2/P3=0, gate PASS.
Report: `sap_atc_readiness_variant_20260603.md`.

## (6) Migration dashboard — deepened `/sap-cc-campaign report`

**Decision:** the dashboard already existed (`report` -> `reports/dashboard.md`).
A separate `sap-cc-dashboard` skill would duplicate it and break "one skill = one
name", so the report was **deepened**, not replaced.

**Shipped (KPIs added):** `auto_fix_rate_pct` (from `fixlog.tsv` `auto_changes>0`),
`unmatched_findings_pct` + top UNMATCHED message ids (the `/sap-cc-learn` feed),
and **business-owner sign-off** (new `signoff` subcommand upserts
`campaign.json.signoffs[]`; dashboard cross-refs `human_gates` -> PENDING until
recorded; governance record, NOT an enforcement gate). Honesty: an absent ledger
renders `n/a` (not `0%`).

**Verified:** offline PS5.1 with a synthetic campaign — all KPIs correct, sign-off
upsert round-trips, empty-ledger -> `n/a`. Report: `sap_cc_dashboard_kpis_20260603.md`.

## (1) SCMON/UPL direct usage read — `/sap-cc-usage --usage-source SCMON|UPL`

**Shipped:** new `sap_cc_scmon_read.ps1` reads the source system's ABAP Call
Monitor over RFC and writes the standard usage export the FILE path ingests
(helper keeps `usage_source=SCMON`).

**Grounded (durable) — SCMON/SUSG data model (verified S/4HANA 1909):**
- `SUSG_V_DATA` (DB view) = aggregated usage: `OBJ_NAME | OBJ_TYPE | COUNTER |
  LAST_USED`. Canonical decommissioning source (what tx SUSG persists).
- `SCMON_VDATA` (DB view) = raw fallback (`SLICESTART/SLICEEND` for the window).
- `SUSG_ADMIN` = the observation window (`DATE_FROM/TO`, `DAYS_AVAILABLE/MISSING`).
- Use the VIEWS, not the normalized base tables (SCMON_DATA/SCMON_PROG).

**Safety (load-bearing):** empty SUSG+SCMON -> `STATUS: NO_DATA` -> every object
defaults to REMEDIATE. "No monitoring data" is **never** read as "everything
unused". A short window emits `WINDOW_WARN` (short windows miss period/year-end
jobs and over-flag unused — the roadmap's window trap).

**Verified:** connect + empty-safe path live on S4D (monitoring off -> 0 rows);
aggregation/dedup/export validated offline (exact reader logic, mock rows).
Non-zero live data not exercised (S4D has no SCMON data).
Report: `sap_cc_scmon_usage_read_20260603.md`.

## (5) R2/R3 assist mode — already shipped

The review flagged this as a gap, but `/sap-cc-remediate assist` already
assembles the per-object recipe/context bundle for AI-reasoned, human-reviewed
remediation (never auto-applied above R1). Not rebuilt. The genuinely missing
governance slice (sign-off tracking) was delivered under (6).

## (3) Remote / central ATC — `/sap-atc --object-provider` + check-system routing

**Constraint:** true central ATC needs a hub + satellites + SM59 RFC destinations
+ registered object providers — none exist on a standalone S4D, so the remote
success path is not testable here.

**Grounded (durable) — central-ATC mechanism (verified S/4HANA 1909):** a run
series binds to a remote object provider identified by `DATA_SOURCE_ID`
(`SCA_DS_OBJECT_PROVIDER_ID`), registered via tx ATC "Manage System Groupings"
in table `SATC_AC_OSY_ATTR` (+ an RFC destination). **Version direction:** the
hub's check content must be >= the satellite's target release (check OLD from a
NEW hub); the hub also needs the Simplification DB. On S4D `SATC_AC_OSY_ATTR` is
empty -> not a configured hub.

**Shipped (two modes):**
1. **Run-on-the-hub (recommended, supported):** `sap-cc-analyze` routes the
   readiness run to the `check_system_profile` via `/sap-login --switch` (reuses
   the live-verified `--variant` flow). Don't run readiness on the bare source ECC.
2. **True remote object provider:** `/sap-atc --object-provider=<DATA_SOURCE_ID>`
   sets the provider on the run-series config; **fail-loud** if the field isn't
   present (never runs local-as-remote).

**Verified:** the fail-loud guard live on S4D (with `--object-provider` on a
non-hub, Stage 2 aborts before Save). The remote success path is UNVERIFIED — the
`provCands` field id is a conjecture; on a real hub, `/sap-gui-probe` the config
screen and prepend the true id. Report: `sap_atc_central_remote_20260603.md`.

## (4) More simplification recipes — knowledge pack 5 -> 12 patterns

**Shipped (all DRAFT, data-driven — no skill code changed):** `SD_PRICING`
(KONV->PRCD_ELEMENTS), `FI_OPENITEM_INDEX` (BSID/BSAD/BSIK/BSAK compat views),
`MATDOC_DOCS` (MKPF/MSEG->MATDOC), `CREDIT_MGMT` (FD32->FSCM), `OUTPUT_MGMT`
(NAST->S/4 OM), `LIS_ANALYTICS` (info structures->CDS), `COMPAT_VIEW_WRITE`
(DML on read-only compat views = "custom table compatibility").

**Honest tiering:** NONE are R1 (mechanical). Three R2 data-model read-redirects
are AI-assisted; credit/output/LIS are R3 functional redesigns (MANUAL_ONLY);
`COMPAT_VIEW_WRITE` is R2 but MANUAL (writes are data-integrity-critical). They
expand the AI-**assist** base, not the auto-remediator.

**Verified:** TSVs round-trip with real tabs (no literal `\t`); all `recipe_ref`s
resolve; every `detect_code_regex` passed .NET-regex positive/negative tests
(e.g. `COMPAT_VIEW_WRITE` matches `UPDATE mard` but not `SELECT FROM mard`).
`detect_message_ids` left blank — filled from real ATC runs via the learn
flywheel. Report: `sap_migrate_recipes_20260603.md`.

---

## Honest backlog (needs more than a single 1909 box)

1. **(2)/(3) on a real estate** — a configured central hub + a satellite to
   record the object-provider config-screen field and run a true remote readiness
   analysis end-to-end.
2. **(1) with live data** — an active SCMON collection window + SUSG aggregation
   on a source system to validate non-zero usage-driven decommission scoping.
3. **(4) flywheel** — a real S/4-readiness ATC run over code containing the new
   patterns, to confirm the simplification-item / message-id matches and promote
   the 9 DRAFT patterns to ACTIVE (filling `detect_message_ids`).
4. **Deployment** — all edits are in the repo; users receive them on the next
   marketplace cache release (the SCMON/recipe/dashboard parts need no GUI
   recording; the ATC GUI changes re-record only if a release moves the IDs).

## Cross-references

- Detailed per-item run reports: `temp/testReport/sap_atc_readiness_variant_*.md`,
  `sap_cc_dashboard_kpis_*.md`, `sap_cc_scmon_usage_read_*.md`,
  `sap_atc_central_remote_*.md`, `sap_migrate_recipes_*.md`.
- Knowledge-pack contract: `plugins/sap-migrate/shared/knowledge/README.md`.
- Campaign workspace contract: `plugins/sap-migrate/skills/sap-cc-campaign/SKILL.md`.
