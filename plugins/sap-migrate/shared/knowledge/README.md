# Simplification Knowledge Pack (sap-migrate)

The curated, versioned knowledge base that powers **AI-reasoned** S/4HANA
custom-code remediation. It is consumed by the (Phase-2) skills:

- **`/sap-cc-triage`** — classifies each ATC S/4-readiness finding into a
  remediation *pattern* (writes `findings_triaged.tsv`).
- **`/sap-cc-remediate`** — rewrites the code following the pattern's *recipe*.

This is a **plugin-shared resource**, distinct from the per-campaign workspace
under `{work_dir}\migrations\{campaign_id}\` (which is owned by
`/sap-cc-campaign`). Nothing here is campaign-specific.

> **Status:** 13 patterns (3 ACTIVE, 10 DRAFT). All DRAFT patterns carry
> representative mappings that MUST be verified against the target release
> before auto-remediation (and `/sap-cc-remediate` excludes DRAFT from
> auto-apply). The 2026-06 additions are S/4 data-model + functional patterns:
> `SD_PRICING` (KONV→PRCD_ELEMENTS, R2), `FI_OPENITEM_INDEX` (FI index tables
> BSID/BSAD/BSIK/BSAK + BSIS/BSAS compat views, R2), `MATDOC_DOCS`
> (MKPF/MSEG→MATDOC, R2), `CREDIT_MGMT`
> (FD32→FSCM, R3 MANUAL), `OUTPUT_MGMT` (NAST→S/4 OM, R3 MANUAL), `LIS_ANALYTICS`
> (info structures→CDS, R3 MANUAL), `COMPAT_VIEW_WRITE` (DML on read-only compat
> views, R2 MANUAL). 2026-07 added `SD_STATUS_TABLES` (VBUK/VBUP eliminated, R2)
> and enriched every pattern's detection: `detect_simpl_items` now also carries
> the full public item title, and the regexes match both quoted-statement forms
> and ATC message phrasings ("table X" / "usage of X"). None are R1 — they
> expand the AI-assisted (R2/R3) base, not the mechanical auto-remediator.
> `detect_message_ids` are intentionally blank on every pattern (filled from
> real ATC runs via the flywheel); matching runs on simplification item / code
> regex until then. See `manifest.json`.

> **Coverage expectation (tell the customer this up front):** the pack is a
> CURATED top slice of SAP's Simplification Item space — the mechanical
> data-model/field-length patterns that hit most ECC6 custom estates — not a
> mirror of the ~500-item catalog. On a typical brownfield estate expect
> roughly **20–30% of readiness findings to auto-classify** today; the rest
> surface as `UNMATCHED` → REVIEW **by design** (that is the honest signal to
> route them to AI-assisted/manual triage, not a defect). Shops with heavy
> custom finance/reporting/integration layers will sit at the low end. The
> ratio compounds with every campaign via the flywheel (real
> `detect_message_ids` + new patterns), and a customer can extend the pack at
> `{custom_url}\knowledge\` without waiting on releases.

## Why it is layered (not one big TSV)
Remediation needs two kinds of content: *queryable structured data* (old→new
object/field/API mappings — ideal for TSV) and *rich prose + multi-line code*
(transformation recipes — awkward in TSV). So the pack mirrors the house pattern
of `*_rules.tsv` + `rules/*.md`: **TSV index/maps for lookup + one Markdown
recipe per pattern** for the guidance the AI follows.

## Layout
```
shared/knowledge/
  manifest.json          # version, target-release coverage, provenance
  catalog.tsv            # master index: one row per pattern (the join key)
  object_map.tsv         # old object  -> new object/view/API
  field_map.tsv          # old table-field -> new source (for SELECT rewrites)
  api_replacements.tsv   # old FM/BAPI/txn -> released replacement
  recipes/<pattern_id>.md  # rich, AI-facing transformation guidance (1 per pattern)
  recipes/_TEMPLATE.md     # clone this to add a pattern
  examples/                # optional large standalone before/after .abap pairs
```

## Conventions (match the sap-migrate plugin)
- TSV: **lowercase snake_case headers**, **real TAB bytes**, **UTF-8 no BOM**,
  **CRLF**, header row first. (Generate TSVs with PowerShell + a real `` `t ``,
  never the Write-tool literal `\t`.)
- Empty cell = empty field (two consecutive tabs). No quoting; never put a tab
  or newline inside a field.

## Schema — `catalog.tsv` (the index, 14 cols)
| Column | Meaning |
|---|---|
| `pattern_id` | Stable key. **Equals the value `/sap-cc-triage` writes into `findings_triaged.tsv.pattern`** and the dashboard rolls up. |
| `category` | `FIELD_LENGTH` \| `DATA_MODEL` \| `HANA` \| `API_REMOVED` \| `SYNTAX` \| `FUNCTIONAL` |
| `tier` | `R1` \| `R2` \| `R3` \| `R4` (drives automation; matches the remediate tiers) |
| `simplification_item` | SAP S4TWL item name (provenance); blank for behavioral patterns |
| `title` / `description` | human title + one-line summary |
| `detect_simpl_items` | csv of tokens matched **exactly (case-insensitive)** against the finding's `simplification_item` column. Include BOTH the short provenance key (`S4TWL-SD-PRICING`) AND the full public item title (`S4TWL - Data Model Changes in SD Pricing`) — ATC exports usually carry the title. No commas inside a token (csv split). |
| `detect_message_ids` | csv of ATC message ids (seed blank — fill from real ATC runs; see flywheel). The only locale-proof channel. |
| `detect_code_regex` | fallback regex matched against the finding's **`message_text` + `check_id`** (NOT the ABAP source!). Write it to hit both quoted-statement forms (`FROM konv`) and message phrasings (`table KONV` / `usage of KONV`). EN-biased by nature — on non-EN logons rely on message ids once harvested. Keep read patterns `from|join`-anchored so DML findings still route to `COMPAT_VIEW_WRITE`. |
| `recipe_ref` | `recipes/<pattern_id>.md` |
| `confidence_default` | `AUTO_OK` \| `AI_REVIEW` \| `MANUAL_ONLY` (default fixability) |
| `applies_modules` | FI \| MM \| SD \| CROSS \| ... |
| `target_release_min` | min target release where the mapping holds |
| `status` | `ACTIVE` \| `DRAFT` \| `DEPRECATED` |

## Schema — `object_map.tsv` (9 cols)
`map_id · pattern_id · old_object · old_object_type · new_object · new_object_type · access_mode · relationship · caveat`
- `relationship` ∈ `REPLACED_BY` \| `COMPAT_VIEW_FOR` \| `AGGREGATED_INTO` \| `SPLIT_INTO` \| `MERGED_INTO`
- `access_mode` ∈ `READ_ONLY` \| `READ_WRITE` (compatibility views are usually read-only)

## Schema — `field_map.tsv` (7 cols)
`map_id · pattern_id · old_field · new_source · new_kind · derivation · notes`
- `new_kind` ∈ `DIRECT` \| `COMPAT_VIEW` \| `DERIVED` \| `AGGREGATION` \| `REMOVED`
- `derivation` filled only for `DERIVED`/`AGGREGATION`

## Schema — `api_replacements.tsv` (9 cols)
`api_id · pattern_id · old_api · old_api_kind · new_api · new_api_kind · released · call_pattern_ref · notes`
- `old_api_kind`/`new_api_kind` ∈ `FM` \| `BAPI` \| `TXN` \| `METHOD` \| `PATTERN`
- `released` = `Y`/`N` (is the replacement an SAP **released**, clean-core-safe API?)

## How it is consumed (the join contract)
1. **`/sap-cc-triage`** reads `findings\findings_raw.tsv` and joins each finding
   to `catalog.tsv` on `detect_simpl_items` / `detect_message_ids` (fallback:
   `detect_code_regex`). It writes `pattern` = `catalog.pattern_id`, plus
   `tier` and `fixability` (from `confidence_default`), into
   `findings\findings_triaged.tsv`. On multiple candidate matches: most specific
   wins (message-id > simpl-item > regex); unresolved → leave for REVIEW.
2. **`/sap-cc-remediate`** loads `recipes/<pattern_id>.md` + the matching
   `object_map` / `field_map` / `api_replacements` rows + the object source,
   produces the rewrite, then runs check → deploy(sandbox) → activate → ATC
   re-check → ABAP Unit (the recipe's *Validation* section). Gated by
   `confidence_default` (R2/R3 always human-reviewable; DRAFT patterns excluded).

`status.tsv`/dashboard rollup in `/sap-cc-campaign` already groups
`findings_triaged.tsv` by `pattern` — so `pattern_id` here IS that pattern token.

## Provenance & IP (read this)
- Build entries from the **public** Simplification Item Catalog and SAP Notes.
- **Do NOT** paste or redistribute SAP's Simplification Database content.
- Every recipe ends with a *Sources* line citing its item for reference only.
- Treat all object/field/API names as **release-dependent** — verify before use.

## Versioning
- `manifest.json` pins the pack to its `target_releases` (mappings differ by
  release) and records `pattern_count` / `status_counts`.
- Ship patterns incrementally with the `status` column. `/sap-cc-remediate`
  must ignore `DRAFT`/`DEPRECATED` for auto-apply (advisory only).

## Adding a pattern (checklist)
1. `cp recipes/_TEMPLATE.md recipes/<PATTERN_ID>.md` and fill every section.
2. Add one `catalog.tsv` row (regenerate the TSV with PowerShell + real tabs).
3. Add `object_map` / `field_map` / `api_replacements` rows as needed
   (`pattern_id` = your new id).
4. Bump `manifest.json` (`pattern_count`, `status_counts`, `last_updated`).
5. Start at `status=DRAFT`; promote to `ACTIVE` once verified on a real ATC run.

## The flywheel
Every human-approved R2/R3 remediation is a candidate to append back here as a
vetted before/after example and to fill in the real `detect_message_ids` —
the pack compounds with every campaign.

## Path resolution & customer override
A consuming skill (e.g. `/sap-cc-triage` at
`plugins/sap-migrate/skills/sap-cc-triage/`) resolves this folder as
`<SKILL_DIR>\..\..\shared\knowledge`. A customer may override/extend at
`{custom_url}\knowledge\` (same precedence idea as the other shared tables) —
e.g. to add patterns for their own retired Z-framework.

## Related (not in this pack)
- `migration_rules_r1.tsv` — deterministic, mechanical R1 transforms run by
  `/sap-cc-remediate` (no AI). Catalog indexes the R1 patterns; the rule table
  itself ships with the remediate skill at
  `plugins/sap-migrate/skills/sap-cc-remediate/references/migration_rules_r1.tsv`
  (customer override: `{custom_url}\knowledge\migration_rules_r1.tsv`, passed
  via that skill's `--rules` flag).
