# MATDOC_DOCS — Material document tables (MKPF/MSEG -> MATDOC)  [DRAFT]

- **pattern_id:** MATDOC_DOCS
- **category:** DATA_MODEL   **tier:** R2   **confidence_default:** AI_REVIEW
- **simplification item:** S4TWL - Material Document Tables MKPF and MSEG
- **status:** DRAFT - mappings below are representative; **verify per release**
- **applies modules:** MM (Inventory Management)

## Summary
S/4HANA Material Inventory Management persists material documents in a single
table, **MATDOC**, replacing the header/item pair **MKPF/MSEG**. SAP ships
compatibility views so `SELECT … FROM mseg` style reads still compile, but custom
code should read MATDOC (or released CDS) and must only create documents via
goods-movement APIs. Companion to `MATDOC_STOCK` (which covers the *stock*
aggregate tables MARD/MARC/MCHB); this pattern covers the *document* tables.

## Applies when
- ATC simplification item `S4TWL-MMIM-MATDOC` fires, **or**
- code reads/joins `MKPF` or `MSEG`, or writes them directly.
- Modules: MM-IM.

## Old -> New mapping (representative - DRAFT)
See `object_map.tsv` (`pattern_id = MATDOC_DOCS`). `MKPF`/`MSEG` are
`AGGREGATED_INTO` `MATDOC`; SAP-provided compatibility views (names vary by
release, e.g. the NSDM compatibility set) preserve the old shape - **verify**.

## Remediation approach
1. **Reads:** prefer `FROM matdoc` (header + item fields live in one row) or a
   released material-document CDS view. The compat views keep MKPF/MSEG reads
   working - confirm the fields you select still exist.
2. **Joins:** an MKPF-MSEG join collapses to a single MATDOC read - simplify it.
3. **Writes:** never write MKPF/MSEG/MATDOC directly; post goods movements via
   `BAPI_GOODSMVT_CREATE` (see `api_replacements.tsv` / COMPAT_VIEW_WRITE).

## Released APIs / objects
- Read: `MATDOC` / released material-document CDS views.
- Post: `BAPI_GOODSMVT_CREATE`.

## Caveats & non-1:1 cases (when to downgrade to MANUAL_ONLY)
- Code relying on the separate header/item physical layout (e.g. per-table
  enqueue, append structures on MSEG) -> MANUAL.
- Performance: MATDOC is very large; always restrict by document number/year or
  material/plant.

## Before / After example (illustrative)
```abap
" before - header/item join
SELECT mkpf~mblnr mseg~zeile mseg~matnr FROM mkpf
  INNER JOIN mseg ON mseg~mblnr = mkpf~mblnr AND mseg~mjahr = mkpf~mjahr
  INTO TABLE lt_docs WHERE mkpf~budat IN s_budat.
```
```abap
" after - one table now (verify fields/release); consider a released CDS view
SELECT mblnr, zeile, matnr FROM matdoc
  INTO TABLE @lt_docs WHERE budat IN @s_budat.
```

## Validation
- Compare document line counts for a known posting-date range before vs. after.
- Re-run `/sap-cc-analyze`; the material-document finding must clear.

## Confidence & gating
- `AI_REVIEW`. Read/join redirects are usually mechanical; writes and layout
  assumptions are MANUAL.

## Sources (provenance - reference only)
- SAP S/4HANA simplification item "Material Document Tables MKPF and MSEG"
  (Material Inventory Management). Verify SAP Notes, compatibility-view names,
  and fields for your target release. Not a redistribution of SAP's
  Simplification Database.
