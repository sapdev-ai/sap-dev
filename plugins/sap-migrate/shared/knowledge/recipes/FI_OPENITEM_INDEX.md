# FI_OPENITEM_INDEX — FI open/cleared-item index tables (BSID/BSAD/BSIK/BSAK)  [DRAFT]

- **pattern_id:** FI_OPENITEM_INDEX
- **category:** DATA_MODEL   **tier:** R2   **confidence_default:** AI_REVIEW
- **simplification item:** S4TWL - Data Model in FI (elimination of index tables)
- **status:** DRAFT - mappings below are representative; **verify per release**
- **applies modules:** FI (AR/AP)

## Summary
The AR/AP secondary index tables for open and cleared items - **BSID, BSAD,
BSIK, BSAK** (and the GL counterparts BSIS/BSAS, covered by `ACDOCA_FIN`) - are
eliminated as redundant. S/4HANA ships **compatibility views with the same
names**, sourced from `BSEG`/`ACDOCA`. Most `SELECT … FROM bsid` reads therefore
still compile, but performance characteristics change, some fields are derived,
and the tables can no longer be written or appended to.

## Applies when
- ATC simplification item `S4TWL-FIN-INDEXTABLES` fires, **or**
- code reads/joins `BSID / BSAD / BSIK / BSAK`, or writes/append-structures them.
- Modules: FI (AR/AP).

## Old -> New mapping (representative - DRAFT)
See `object_map.tsv` (`pattern_id = FI_OPENITEM_INDEX`). Each table is now a
`COMPAT_VIEW_FOR` itself (same name) backed by BSEG/ACDOCA - **read-only**.

## Remediation approach
1. **Reads:** usually no code change is required (the compat view keeps the
   name), but **verify** the selected fields still exist and review WHERE clauses
   for performance (the view aggregates at read time).
2. **Writes / MODIFY / appends:** forbidden - these were SAP-maintained index
   tables. Remove direct writes; post via `BAPI_ACC_DOCUMENT_POST`
   (see COMPAT_VIEW_WRITE). Custom append structures must move elsewhere.
3. **Prefer released CDS** open-item views over the compat views for new code.

## Released APIs / objects
- Read: BSID/BSAD/BSIK/BSAK compatibility views (or released FI CDS views).
- Post: `BAPI_ACC_DOCUMENT_POST` (never direct index-table writes).

## Caveats & non-1:1 cases (when to downgrade to MANUAL_ONLY)
- Logic depending on the physical/secondary-index nature (e.g. assuming the row
  exists only for open items at a point in time) -> MANUAL.
- Heavy reporting over these views without selective WHERE -> performance review.

## Before / After example (illustrative)
```abap
" before - direct read of the AR open-item index
SELECT * FROM bsid INTO TABLE lt_open WHERE bukrs = lv_bukrs AND kunnr = lv_kunnr.
```
```abap
" after - same name now resolves to a compatibility view (verify fields/perf),
" or switch to a released FI open-item CDS view for new code.
SELECT * FROM bsid INTO TABLE @lt_open WHERE bukrs = @lv_bukrs AND kunnr = @lv_kunnr.
```

## Validation
- Reconcile open-item counts/sums for a known company code + account.
- Re-run `/sap-cc-analyze`; the FI index-table finding must clear.

## Confidence & gating
- `AI_REVIEW`. Pure reads often need no change (confirm), but any write/append or
  index-semantics assumption is MANUAL.

## Sources (provenance - reference only)
- SAP S/4HANA simplification item "Data Model in Financials - elimination of
  redundant index tables". Verify SAP Notes, view names, and field semantics for
  your target release. Not a redistribution of SAP's Simplification Database.
