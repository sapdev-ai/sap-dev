# LIS_ANALYTICS — Logistics Information System info structures -> embedded analytics  [DRAFT]

- **pattern_id:** LIS_ANALYTICS
- **category:** FUNCTIONAL   **tier:** R3   **confidence_default:** MANUAL_ONLY
- **simplification item:** S4TWL - LIS / SIS (Logistics Information System)
- **status:** DRAFT - redesign onto CDS analytics; **verify per release**
- **applies modules:** CROSS (SD-SIS, MM-PURCHIS, INVCO, ...)

## Summary
The Logistics Information System (LIS) - SIS, PURCHIS, INVCO and their **info
structures `S001..Snnn`** plus statistics update rules - is superseded in
S/4HANA by **CDS-based embedded analytics** (real-time aggregation over the
primary documents / ACDOCA-style sources), removing the separately persisted,
redundantly updated info structures. Custom reports reading `S###` info
structures, and custom LIS update logic, should be redesigned onto released CDS
analytical views. Treat as MANUAL (redesign, not a swap).

## Applies when
- ATC simplification item `S4TWL-LIS` fires, **or**
- code reads/joins LIS info structures (`S001`, `S### …`), uses `MCSI`/standard
  analyses, or implements custom LIS statistics updates.
- Modules: CROSS (SD/MM logistics analytics).

## Old -> New mapping (representative - DRAFT)
No 1:1 table mapping. Persisted info structures (`S###`) -> real-time CDS
analytical views over the source documents. The right released CDS view depends
on the analysis - **verify per release**.

## Remediation approach
1. **Reads of `S###`:** identify the business metric, then move to the released
   CDS analytical view that provides it in real time; do not assume the info
   structure is still updated.
2. **Custom update rules / `MCSI`-style logic:** redesign as CDS (no separate
   statistics update layer).
3. This is analytics redesign; the recipe assembles context, a human owns the
   target-view selection and reconciliation.

## Released APIs / objects
- Released CDS analytical views for logistics (SD/MM) - verify names per release.

## Caveats & non-1:1 cases (always MANUAL_ONLY)
- Metric semantics differ (real-time vs. periodically updated info structure);
  numbers may legitimately change - reconcile with the business.
- Some info structures may still exist on a given release; confirm before
  assuming removal.

## Before / After example (illustrative)
```abap
" before - read a persisted SIS info structure
SELECT * FROM s001 INTO TABLE lt_sis WHERE spmon = lv_period.
```
```abap
" after - source the metric from a released logistics CDS analytical view
" (real-time aggregation; verify the view + field semantics per release). MANUAL.
```

## Validation
- Reconcile a known KPI (e.g. sales volume for a period) info-structure vs. CDS.
- Re-run `/sap-cc-analyze`; the LIS finding must clear.

## Confidence & gating
- `MANUAL_ONLY`. Never auto-apply; metric reconciliation requires a human.

## Sources (provenance - reference only)
- SAP S/4HANA simplification item for LIS / SIS. Verify SAP Notes, which info
  structures are affected, and the released CDS replacements for your target
  release. Not a redistribution of SAP's Simplification Database.
