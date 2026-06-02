# MATDOC_STOCK — material stock fields aggregated into MATDOC

- **pattern_id:** MATDOC_STOCK
- **category:** DATA_MODEL   **tier:** R2   **confidence_default:** AI_REVIEW
- **simplification item:** S4TWL - Material Inventory Management (MM-IM)
- **status:** ACTIVE   **applies modules:** MM-IM

## Summary
In S/4HANA the stock **quantity** fields are no longer stored in the transparent
tables MARD / MARC / MCHB / … . They are written once to the material-document
table **MATDOC** and aggregated on read. SAP ships **NSDM compatibility views**
(`NSDM_V_MARD`, `NSDM_V_MARC`, `NSDM_V_MCHB`, …) that reproduce the old field
layout. Custom code that SELECTs stock quantities straight from the base table
returns wrong/zero values; custom code that *writes* those fields is invalid.

## Applies when
- ATC simplification item `S4TWL-MMIM-NSDM` fires, **or**
- code signature `SELECT ... FROM mard|marc|mchb|...` reading a stock-quantity
  field, or any write (UPDATE/MODIFY/INSERT) to those fields.
- Modules: MM-IM.

## Old → New mapping
See `object_map.tsv` / `field_map.tsv` (`pattern_id = MATDOC_STOCK`). Summary:

| Old | New | Access |
|---|---|---|
| MARD (stock qty) | NSDM_V_MARD | read-only |
| MARC (stock qty) | NSDM_V_MARC | read-only |
| MCHB (batch stock) | NSDM_V_MCHB | read-only |
| MARD-LABST/INSME/SPEME/RETME/UMLME | NSDM_V_MARD-<same field> | read-only |

## Remediation approach
1. **Reads:** redirect the SELECT from the base table to the matching `NSDM_V_*`
   compatibility view. Field names are unchanged, so usually only the FROM
   clause changes.
2. **Add `ORDER BY`** on the key when the result is processed with an assumption
   of order (see pattern `ADD_ORDER_BY`).
3. **Performance:** the compatibility view aggregates MATDOC at runtime. Do not
   call it row-by-row inside a loop; select the set once into an internal table.
   For high-volume aggregation prefer the released stock API / a reviewed direct
   MATDOC query.
4. **Writes:** never write stock quantities to the base table. Escalate any
   `UPDATE/MODIFY mard ... <stock field>` to MANUAL (R4) — stock changes must go
   through a goods movement (`BAPI_GOODSMVT_CREATE`, see `api_replacements.tsv`).

## Released APIs / objects
- Read: `NSDM_V_*` compatibility views (or released CDS stock views per release).
- Write: `BAPI_GOODSMVT_CREATE`. Never a direct table update.

## Caveats & non-1:1 cases (when to downgrade to MANUAL_ONLY)
- Any write path to stock fields → MANUAL.
- Aggregation / reporting inside tight loops → human performance review.
- The exact compatibility-view set varies slightly by release — verify the view
  name exists on the target before applying.

## Before / After example
```abap
" before — reads stock directly from the base table (wrong on S/4HANA)
SELECT matnr werks lgort labst
  FROM mard INTO TABLE lt_stock
  WHERE matnr = lv_matnr.
```
```abap
" after — read-only compatibility view; ORDER BY for deterministic processing
SELECT matnr, werks, lgort, labst
  FROM nsdm_v_mard
  INTO TABLE @lt_stock
  WHERE matnr = @lv_matnr
  ORDER BY matnr, werks, lgort.
```

## Validation
- Generate an ABAP Unit test asserting the rewritten SELECT returns the same
  rows/quantities as a known goods-movement state on the sandbox.
- Re-run `/sap-cc-analyze` (ATC) on the object — the `S4TWL-MMIM-NSDM` finding
  must clear.

## Confidence & gating
- `AI_REVIEW`: read redirects are safe to auto-propose but require human review
  before apply. Any write path forces MANUAL.

## Sources (provenance — reference only)
- SAP S/4HANA simplification item "Material Inventory Management (MM-IM) / New
  Stock Data Model". Verify the exact SAP Note and compatibility-view list for
  your target release. Not a redistribution of SAP's Simplification Database.
