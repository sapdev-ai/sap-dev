# SD_PRICING — SD pricing data model (KONV -> PRCD_ELEMENTS)  [DRAFT]

- **pattern_id:** SD_PRICING
- **category:** DATA_MODEL   **tier:** R2   **confidence_default:** AI_REVIEW
- **simplification item:** S4TWL - Data Model Changes in SD Pricing
- **status:** DRAFT - mappings below are representative; **verify per release**
- **applies modules:** SD (also MM purchasing pricing)

## Summary
S/4HANA persists pricing condition records (transaction data) in **PRCD_ELEMENTS**
instead of **KONV**. The condition technique (access sequences, condition types)
is unchanged; only the persistence changed. SAP provides compatibility access so
many `SELECT … FROM konv` reads still compile, but custom code should target
PRCD_ELEMENTS and must never write conditions by direct table update.

## Applies when
- ATC simplification item `S4TWL-SD-PRICING` fires, **or**
- code reads/joins `KONV` (e.g. by `KNUMV`), or updates KONV directly.
- Modules: SD, MM (purchasing) pricing.

## Old -> New mapping (representative - DRAFT)
See `object_map.tsv` (`pattern_id = SD_PRICING`). `KONV` is `REPLACED_BY`
`PRCD_ELEMENTS`; the key (`KNUMV` + item/step/counter) and most fields align, but
field availability and lengths can differ by release - **verify before relying
on a name**.

## Remediation approach
1. **Reads:** change `FROM konv` to `FROM prcd_elements` (or the released CDS
   view for pricing) keyed by `KNUMV`. Re-check selected fields exist.
2. **Writes:** never `UPDATE/INSERT/MODIFY konv` (or PRCD_ELEMENTS). Pricing is
   created/changed only through sales/purchasing document processing or the
   pricing API - direct condition writes are unsupported (see COMPAT_VIEW_WRITE).
3. **Buffer / KOMV runtime structure** (in-memory pricing result) is unchanged -
   only the database table moved; don't confuse KOMV (runtime) with KONV (table).

## Released APIs / objects
- Read: `PRCD_ELEMENTS` / released pricing CDS views (verify names per release).
- Change conditions: via document processing / pricing, not direct DML.

## Caveats & non-1:1 cases (when to downgrade to MANUAL_ONLY)
- Code that hard-codes KONV field offsets or assumes its physical layout -> MANUAL.
- Mass condition maintenance frameworks -> review against the released pricing API.
- Performance: PRCD_ELEMENTS is large; always restrict by `KNUMV`.

## Before / After example (illustrative)
```abap
" before
SELECT * FROM konv INTO TABLE lt_konv WHERE knumv = lv_knumv.
```
```abap
" after - persisted conditions now live in PRCD_ELEMENTS (verify fields/release)
SELECT * FROM prcd_elements INTO TABLE @lt_cond WHERE knumv = @lv_knumv.
```

## Validation
- Compare condition rows for a known `KNUMV` before vs. after on the sandbox.
- Re-run `/sap-cc-analyze`; the SD pricing data-model finding must clear.

## Confidence & gating
- `AI_REVIEW`. Read redirects are usually mechanical; any write path or
  layout-dependent logic is MANUAL.

## Sources (provenance - reference only)
- SAP S/4HANA simplification item "Data Model Changes in SD Pricing"
  (KONV -> PRCD_ELEMENTS). Verify SAP Notes, view names, and fields for your
  target release. Not a redistribution of SAP's Simplification Database.
