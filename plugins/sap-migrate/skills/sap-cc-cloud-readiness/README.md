# sap-cc-cloud-readiness

**Measure each custom (Z/Y) object's distance from ABAP Cloud (clean core).**
`S4HANA_READINESS` (`/sap-cc-analyze`) tells you whether code survives the S/4
conversion; it says nothing about *how far each object is from clean core*. This
downloads source once over RFC and matches a versioned knowledge pack offline to
place every object on the extensibility ladder — with per-blocker evidence and an AI
summary of the cheapest wins.

```
/sap-cc-cloud-readiness scan --campaign <id>            # classify the REMEDIATE scope
/sap-cc-cloud-readiness scan --packages Z*,Y* --limit 200
/sap-cc-cloud-readiness scan --objects PROGRAM:ZFOO,FUGR:ZBAR
```

## Tiers

| Tier | Meaning |
|---|---|
| `TIER_1_READY` | No forbidden statement, no unreleased API — clean-core ready (as far as the pack knows). |
| `TIER_2_WRAPPABLE` | Only blockers are unreleased APIs the pack maps to a **successor** — a wrap/replace job. |
| `TIER_3_CLASSIC` | A forbidden statement (dynpro, native SQL, file I/O, classic list, direct DML) or an unreleased API with **no** successor. |
| `COULD_NOT_CHECK` | Source could not be read (class over RFC / not found / RFC failure) — **never** rendered TIER_1. |

## Honest by construction (never a false TIER_1)

- An API **absent** from the pack is `unknown`: counted, **never a blocker** — so a
  partial pack cannot manufacture a false `TIER_3`. The cost is disclosed the other
  way: a `TIER_1_READY` object with unknown refs is `coverage=PARTIAL`, never a clean
  `FULL`.
- A source that can't be read is `COULD_NOT_CHECK`, never TIER_1.
- Any dynamic token (`CALL FUNCTION <var>`, dynamic `CREATE OBJECT`, `SELECT … FROM
  (var)`) sets `dynamic_blindspot=YES` — the regex scanner is blind to it, disclosed
  per object. This is a **triage** input, not a certification.

## What it reads

Source over RFC via the shared sanctioned reader (`RPY_PROGRAM_READ` for
PROG/REPS/INCLUDE, `TFDIR`+include for FUNC — never `REPOSRC` directly), plus the
standalone scope resolver (`sap_object_resolver.ps1`) and the campaign `state.tsv`
(`decision=REMEDIATE`, read-only — never advanced). **Read-only**: no SQL writes, no
TR, no deployment. **S/4-only** — a non-S/4 pinned profile is refused (`CC_NOT_S4`),
pointing to `/sap-cc-analyze`.

## Coverage holes (visible)

Classes/interfaces are `COULD_NOT_CHECK` in v1 (class source over RFC unsupported;
the wrapper-bridged `SEO_METHOD_GET_SOURCE` reader is v1.5); FUGR/DDIC are out of the
source scan; `--atc` (SCICHKV_HD cloud-variant delegation) is v1.5 and `keyuser`
(key-user extensibility inventory) is v2. The shipped cloudification repository is a
**curated partial seed** — drop a full export at
`{custom_url}\knowledge\cloud\cloudification_repository.json` to raise coverage.

Verified live on S/4HANA 1909 (S4D) 2026-07-11: a real classic add-on program →
`TIER_3_CLASSIC` (28 blockers, 0 false positives on 806 lines); the generic RFC
wrapper FM → `TIER_1_READY` + honest `blindspot=Y`/`PARTIAL`; class → COULD_NOT_CHECK.
Part of the sap-migrate plugin (joins the `/sap-cc-*` campaign pipeline).
