# COMPAT_VIEW_WRITE — Direct DML on tables now backed by compatibility views  [DRAFT]

- **pattern_id:** COMPAT_VIEW_WRITE
- **category:** DATA_MODEL   **tier:** R2   **confidence_default:** MANUAL_ONLY
- **simplification item:** (cross-cutting consequence of the FI/MM/SD data-model items)
- **status:** DRAFT - **verify per release**
- **applies modules:** CROSS (FI, MM, SD)

## Summary
Many former tables are, in S/4HANA, **read-only compatibility views** over a new
source (e.g. stock `MARD/MARC/MCHB`, material documents `MKPF/MSEG`, pricing
`KONV`, FI index tables `BSID/BSAD/BSIK/BSAK`, GL totals `GLT0/FAGLFLEXT`). Reads
keep working; **writes do not**. Custom code that does `UPDATE / MODIFY / INSERT /
DELETE` directly on these objects now fails (the view is not writable) or is
functionally wrong. This is the cross-cutting "custom table compatibility" issue
- the write must be replaced by the proper released API. Always MANUAL: a
mis-routed write corrupts business data.

## Applies when
- Code performs `UPDATE / MODIFY / INSERT INTO / DELETE FROM` on a table that is
  now a compatibility view / aggregated source (see the regex in `catalog.tsv`),
  **or** an ATC finding flags a write to a redirected object.
- Modules: CROSS.

## Old -> New mapping
None at field level - this is a **write-path** fix. Route the write through the
released API for the domain:

| Domain (table written) | Use instead |
|---|---|
| Stock / material docs (MARD/MARC/MCHB/MKPF/MSEG) | `BAPI_GOODSMVT_CREATE` (goods movement) |
| FI postings / index tables (BSID…/GLT0…) | `BAPI_ACC_DOCUMENT_POST` |
| SD pricing conditions (KONV/PRCD_ELEMENTS) | sales/purchasing document processing / pricing |
| Customer/vendor master (KNA1/LFA1) | Business Partner (see `BP_CVI`) |

## Remediation approach
1. **Identify the write target** and the business operation it implements.
2. **Replace the DML** with the released API/BAPI for that operation (table
   above). Never write a compatibility view.
3. If the "write" was actually maintaining a custom shadow of standard data,
   re-evaluate the requirement - it may be obsolete on S/4.
4. Escalate to MANUAL always: changing a write path is data-integrity-critical.

## Released APIs / objects
- `BAPI_GOODSMVT_CREATE`, `BAPI_ACC_DOCUMENT_POST`, document processing /
  pricing, Business Partner APIs (see `api_replacements.tsv` across patterns).

## Caveats & non-1:1 cases (always MANUAL_ONLY)
- Direct DML on a *custom* Z-table is fine - this pattern is only for **standard**
  tables that became views/aggregates. Confirm the target is standard.
- A write inside a custom framework may have downstream effects - review fully.

## Before / After example (illustrative)
```abap
" before - direct stock update (now unsupported; MARD is a compatibility view)
UPDATE mard SET labst = labst + lv_qty WHERE matnr = lv_matnr AND werks = lv_werks AND lgort = lv_lgort.
```
```abap
" after - stock changes only via a goods movement (released API). MANUAL review.
CALL FUNCTION 'BAPI_GOODSMVT_CREATE' EXPORTING goodsmvt_header = ls_head goodsmvt_code = ls_code TABLES goodsmvt_item = lt_item ...
```

## Validation
- Confirm the operation posts a proper document and the value is reflected via
  the read (compat) view; no direct-write dump in the sandbox.
- Re-run `/sap-cc-analyze`; the write-to-redirected-object finding must clear.

## Confidence & gating
- `MANUAL_ONLY`. Never auto-apply - write-path changes are data-integrity-critical.

## Sources (provenance - reference only)
- Cross-cutting consequence of the SAP S/4HANA data-model simplification items
  (FI / MM-IM / SD pricing). Verify which tables are read-only compatibility
  views on your target release. Not a redistribution of SAP's Simplification
  Database.
