# Migration Campaign Brief — SAMPLE (Campaign: CCMIG01)

> This is a **filled-in example** for a brownfield conversion
> `ECC6 EhP8 → S/4HANA 2023`. The blank fillable form is
> [`migration_brief.md`](migration_brief.md). Copy this file to
> `{custom_url}\migration_brief.md` and edit the values.

---

## 1. Campaign

| Field | Value |
|---|---|
| Campaign id | `CCMIG01` |
| Description | `ECC6 EhP8 → S/4HANA 2023, wave 1 (FI + MM custom code)` |

---

## 2. Systems

| Field | Value |
|---|---|
| Source system profile (read-only) | `ECCPRD_COPY` (Jan-2026 production copy, client 100) |
| Sandbox system profile (deploy target) | `S4DEV` (client 120) |
| Remote-ATC check-system profile | `S4ATC` (client 100; Simplification DB loaded, target 2023) |

---

## 3. Source → Target

| Field | Value |
|---|---|
| Source release | `ECC 6.0 EhP8 (NetWeaver 7.50, kernel 753)` |
| Target S/4HANA release | `S/4HANA 2023` |
| Target Support Package | `SP02` |
| Conversion approach | `brownfield` (in-place conversion) |

---

## 4. Scope & decommission

| Field | Value |
|---|---|
| In-scope packages / namespaces | `Z*`, `Y*` |
| Exclusions | `ZLEGACY_*` (frozen archive), `ZTEST_*` (sandbox throwaways) |
| Decommission policy | `conservative` |
| Usage data source | `SCMON` (ABAP Call Monitor, aggregated) |
| Usage window | `2025-01-01 .. 2026-05-31` (17 months incl. 2 year-end closes) |

**Conservative policy note:** wave 1 retires only Z objects with zero SCMON hits
in the window **and** no inbound where-used from still-called objects —
expected to remove ~45% of the ~1,800 in-scope objects without remediation.

---

## 5. Quality & gates

| Field | Value |
|---|---|
| S/4-readiness ATC block threshold | `priority 1+2 gate` (MAX_PRIORITY = 2) |
| Human gate — scope sign-off | `yes` — conversion lead approves the REMEDIATE / DECOMMISSION split |
| Human gate — dry-run review | `yes` — every R1 batch reviewed as a diff before apply |
| Human gate — tier R2+ sign-off | `yes` — ACDOCA / Business-Partner semantic rewrites need developer sign-off |

---

## 6. References

| Concern | Source |
|---|---|
| ABAP variable naming | default `abap_naming_rules.tsv` (no override) |
| Repository-object naming | default `sap_object_naming_rules.tsv` |
| Code-quality rules | `abap_code_quality_rules.md` |
| Namespace for new helpers | per build `customer_brief.md` (`Z`, sub-prefix `ZHK`) |

---

## How to use this sample

1. Copy this file to `{custom_url}\migration_brief.md` for your campaign.
2. Replace the `CCMIG01` values with your campaign's.
3. Run `/sap-cc-campaign init --campaign <id> --brief {custom_url}\migration_brief.md`.
4. Then `/sap-cc-campaign next` to walk the pipeline one safe step at a time.
