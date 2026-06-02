# Migration Campaign Brief — One-Page Form

This is the **minimum information** needed to run **one S/4HANA custom-code
migration campaign**. Fill it once per campaign (typically one per conversion
wave / track). Hand it to the conversion lead or the Basis + ABAP owner.

This is **not** the build-time `customer_brief.md` (which profiles a *new-build*
project and drives code generation). This brief profiles a **remediation
campaign** and is read once by `/sap-cc-campaign init`, which copies it into the
campaign's `campaign.json`.

> 💡 **See [`migration_brief_sample.md`](migration_brief_sample.md) for a
> filled-in example.** Copy the sample, swap the values. Every field can also be
> supplied on the command line (CLI flags override the brief), and `init` runs
> fine with no brief at all — absent fields are simply recorded blank.

---

## 1. Campaign

| Field | Example | Your value |
|---|---|---|
| Campaign id | `CCMIG01` (or pass `--campaign`) | |
| Description | `ECC6 EhP8 → S/4HANA 2023, wave 1 (FI + MM)` | |

---

## 2. Systems (connection profile names saved via `/sap-login`)

Give the **profile names**, not hostnames — the campaign skills resolve
credentials from the connection store.

| Field | Example | Your value |
|---|---|---|
| Source system profile (analyzed **read-only**) | `ECCPRD_COPY` | |
| Sandbox system profile (remediation deploy target) | `S4DEV` | |
| Remote-ATC check-system profile | `S4ATC` | |

> ⚠️ Never remediate on production. Point `source` at a system copy / sandbox,
> and run the S/4-readiness ATC from a dedicated **check system** that has the
> Simplification Database loaded.

---

## 3. Source → Target

| Field | Example | Your value |
|---|---|---|
| Source release | `ECC 6.0 EhP8 (NetWeaver 7.50)` | |
| Target S/4HANA release | `S/4HANA 2023` | |
| Target Support Package | `SP02` | |
| Conversion approach | `brownfield` / `selective` | |

---

## 4. Scope & decommission

| Field | Example | Your value |
|---|---|---|
| In-scope packages / namespaces | `Z*`, `Y*`, `/MYCO/` | |
| Exclusions | `ZLEGACY_*` (frozen — do not touch) | |
| Decommission policy | `conservative` (default) / `aggressive` / `none` | |
| Usage data source | `SCMON` / `UPL` / `FILE` | |
| Usage window | `2025-01-01 .. 2026-05-31` | |

- **conservative** — flag for decommission only objects with **zero** recorded
  usage **and** no inbound references from still-used objects.
- **aggressive** — flag any object with zero recorded usage in the window.
- **none** — remediate everything in scope (skip usage analysis).

---

## 5. Quality & gates

| Field | Example | Your value |
|---|---|---|
| S/4-readiness ATC block threshold | `priority 1+2 gate` (MAX_PRIORITY = 2) | |
| Human gate — scope sign-off (before analysis) | `yes` (default) | |
| Human gate — dry-run review (before apply) | `yes` (default) | |
| Human gate — tier R2+ sign-off (semantic fixes) | `yes` (default) | |

---

## 6. References (do **not** restate here)

These already have a single source of truth; the campaign reuses them:

| Concern | Source |
|---|---|
| ABAP variable naming | `abap_naming_rules.tsv` (override at `{custom_url}`) |
| Repository-object naming | `sap_object_naming_rules.tsv` |
| Code-quality rules | `abap_code_quality_rules.md` |
| Namespace/package for any **new** helper object | the build `customer_brief.md` |

---

## How this is consumed by the skills

- `/sap-cc-campaign init` reads this brief → `campaign.json` (`systems`,
  `target`, `scope`, `human_gates`).
- `/sap-cc-inventory` uses `in_scope_packages` / exclusions.
- `/sap-cc-usage` uses the usage source + window + `decommission_policy`.
- `/sap-cc-analyze` uses the `check_system_profile` (remote ATC), target
  release, and the readiness block threshold.
- `/sap-cc-remediate` deploys to `sandbox_profile` and honours the dry-run gate.
- The brief lives at `{custom_url}\migration_brief.md` (per-campaign override of
  the default at `<SAP_DEV_CORE_SHARED_DIR>/templates/migration_brief.md`),
  resolved via the standard Template Language Resolution order (`_JA` variant
  pending; override at `{custom_url}` until it ships).
