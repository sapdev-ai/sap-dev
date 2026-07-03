# ACDOCA_FIN — Financials data model (Universal Journal / ACDOCA)  [DRAFT]

- **pattern_id:** ACDOCA_FIN
- **category:** DATA_MODEL   **tier:** R2   **confidence_default:** AI_REVIEW
- **simplification item:** S4TWL - Universal Journal (Financials data model)
- **status:** DRAFT — mappings below are representative; **verify per release**
- **applies modules:** FI, CO

## Summary
S/4HANA merges FI and CO into the **Universal Journal**, line-item table
**ACDOCA**. Classic totals tables (GLT0, FAGLFLEXT, …) and several line-item
tables are replaced by ACDOCA plus SAP-provided compatibility views. Custom code
that reads those totals tables, or — worse — posts FI/CO by direct table update,
must be adapted.

## Applies when
- ATC simplification item `S4TWL-FIN-DATAMODEL` fires, **or**
- code reads `GLT0 / FAGLFLEXA / FAGLFLEXT / COEP / COBK / BSIS / BSAS …`, or
  posts FI/CO by direct table writes.
- Modules: FI, CO.

## Old → New mapping (representative — DRAFT)
See `object_map.tsv` (`pattern_id = ACDOCA_FIN`). Totals / line-item tables are
`AGGREGATED_INTO` ACDOCA; SAP ships compatibility views whose exact names vary by
release — **verify before relying on a name**.

## Remediation approach
1. **Reads of totals / line items:** redirect to the ACDOCA-based compatibility
   view (or a released CDS view) for the table in question. Field semantics can
   differ (ledger, currency types) — review, don't blind-swap.
2. **Postings:** never post FI/CO by direct table update. Use
   `BAPI_ACC_DOCUMENT_POST` (see `api_replacements.tsv`).
3. **Currency / ledger:** ACDOCA is ledger- and multi-currency-aware; confirm
   the custom logic selects the right ledger (RLDNR) and currency fields.

## Released APIs / objects
- Read: ACDOCA-based compatibility / released CDS views (verify names per release).
- Post: `BAPI_ACC_DOCUMENT_POST`.

## Modern successor — read via a CDS view (`/sap-gen-cds`)
For FI/CO reporting reads, the modern pattern is a **CDS view** over ACDOCA — a
released analytical/compatibility view where one fits, otherwise a thin custom
projection scaffolded with `/sap-gen-cds` (ledger- and currency-aware, selective
`WHERE`, embedded-analytics annotations for KPIs). Reads only; **never** a posting
path (use `BAPI_ACC_DOCUMENT_POST`). Financial correctness stays human-signed-off
(`AI_REVIEW`, leaning MANUAL).

## Caveats & non-1:1 cases (frequently MANUAL)
- Logic that depended on the *physical* layout of GLT0/BSEG (totals buckets,
  period columns) usually needs a functional rewrite → MANUAL.
- Performance: ACDOCA is large; selective WHERE + correct indexes matter.
- This recipe is **DRAFT** — treat its mappings as starting points; confirm
  against the target release's compatibility-view catalog.

## Before / After example (illustrative)
```abap
" before — reads classic GL totals
SELECT * FROM glt0 INTO TABLE lt_glt0 WHERE bukrs = lv_bukrs.
```
```abap
" after — read via the ACDOCA-based compatibility view (VERIFY the view name)
" Confirm field / ledger / currency semantics before relying on this mapping.
SELECT * FROM <acdoca_compat_view> INTO TABLE @lt_tot WHERE rbukrs = @lv_bukrs.
```

## Validation
- Reconcile a known company-code / period total before vs. after on the sandbox.
- Re-run `/sap-cc-analyze`; the FIN data-model finding must clear.

## Confidence & gating
- `AI_REVIEW`, leaning MANUAL: financial correctness is high-risk — always human
  sign-off; never auto-apply a posting-path change.

## Sources (provenance — reference only)
- SAP S/4HANA simplification item "Universal Journal / Data Model in Financials".
  Verify exact SAP Notes, compatibility views, and field semantics for your
  target release. Not a redistribution of SAP's Simplification Database.
