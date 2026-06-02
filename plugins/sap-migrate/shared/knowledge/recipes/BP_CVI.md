# BP_CVI — Business Partner approach (customer/vendor via CVI)  [DRAFT]

- **pattern_id:** BP_CVI
- **category:** DATA_MODEL   **tier:** R2   **confidence_default:** AI_REVIEW
- **simplification item:** S4TWL - Business Partner Approach
- **status:** DRAFT   **applies modules:** SD, MM, FI (master data)

## Summary
In S/4HANA the **Business Partner (BP)** is the single entry point for customer
and vendor master data (Customer/Vendor Integration, CVI). The classic tables
(KNA1/KNB1/KNVV, LFA1/LFB1/LFM1) still exist and are kept in sync by CVI, so most
*reads* keep working — but *create/change* must go through the BP, not the legacy
transactions/FMs.

## Applies when
- ATC simplification item `S4TWL-BP-APPROACH` fires, **or**
- code calls `XD01/XD02/XK01/XK02` or legacy FMs/BAPIs to create/change
  customers/vendors (e.g. `SD_CUSTOMER_MAINTAIN_ALL`,
  `BAPI_CUSTOMER_CREATEFROMDATA1`).
- Modules: SD, MM, FI master data.

## Old → New mapping
See `object_map.tsv` / `api_replacements.tsv` (`pattern_id = BP_CVI`).
- Reads of KNA1/LFA1 etc. → usually unchanged (CVI keeps them filled).
- Create/change → Business Partner APIs / CVI inbound.

## Remediation approach
1. **Reads:** typically no change — KNA1/LFA1/… remain populated. Confirm the
   field is still maintained under CVI (some are now derived).
2. **Create/change:** replace legacy create/change calls with a BP create/
   maintain path — `CVI_EI_INBOUND_MAIN` (mass) or `BAPI_BUPA_CREATE_FROM_DATA`
   plus role assignment (FLCU00/FLCU01 for customer, FLVN00/FLVN01 for vendor).
3. **Number ranges / grouping:** BP grouping and CVI number-range synchronization
   must be configured — surface config dependencies for the functional team.

## Released APIs / objects
- `CVI_EI_INBOUND_MAIN` (mass BP create/update), `BAPI_BUPA_CREATE_FROM_DATA`
  (single create) — verify availability and role config per release.

## Caveats & non-1:1 cases (often MANUAL)
- Direct legacy create/change with complex sub-screens → functional redesign,
  MANUAL.
- CVI configuration (groupings, number ranges, field mapping) is project config,
  not code — report it as a dependency; don't try to "fix" it in code.
- **DRAFT** — verify FM/BAPI availability and the exact role keys for your release.

## Before / After example (illustrative)
```abap
" before — legacy mass customer maintain
CALL FUNCTION 'SD_CUSTOMER_MAINTAIN_ALL' EXPORTING ...
```
```abap
" after — route through CVI / Business Partner (verify interface for your release)
" Build the CVI inbound structure and call CVI_EI_INBOUND_MAIN, or
" BAPI_BUPA_CREATE_FROM_DATA + role assignment. Human review required.
```

## Validation
- Create a test BP on the sandbox via the new path; confirm the customer/vendor
  view is generated (a KNA1/LFA1 row appears via CVI).
- Re-run `/sap-cc-analyze`; the BP finding must clear.

## Confidence & gating
- `AI_REVIEW`, leaning MANUAL for create/change paths; reads are usually
  no-change.

## Sources (provenance — reference only)
- SAP S/4HANA simplification item "Business Partner Approach". Verify exact SAP
  Notes, CVI configuration, and API availability for your target release. Not a
  redistribution of SAP's Simplification Database.
