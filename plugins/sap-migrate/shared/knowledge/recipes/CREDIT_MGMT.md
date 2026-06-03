# CREDIT_MGMT — Credit Management (FI-AR-CR -> FIN-FSCM-CR)  [DRAFT]

- **pattern_id:** CREDIT_MGMT
- **category:** FUNCTIONAL   **tier:** R3   **confidence_default:** MANUAL_ONLY
- **simplification item:** S4TWL - Credit Management (FIN-FSCM-CR)
- **status:** DRAFT - functional redesign; **verify per release / project design**
- **applies modules:** FI (AR), SD (credit checks)

## Summary
Classic SD/FI-AR Credit Management (transaction **FD32**, credit master in
**KNKK/KNKA**, credit-control-area logic) is **not available** in S/4HANA. It is
replaced by **SAP Credit Management (FIN-FSCM-CR)** with its own master data
(`UKM_BP` / business-partner credit segment, tables in the `UKMBP_*` area) and a
BRF+-based credit-check decision. This is a **functional** change, not a code
swap: custom credit logic, credit-master access, and SD credit checks must be
redesigned onto FSCM. Treat as MANUAL.

## Applies when
- ATC simplification item `S4TWL-FSCM-CREDIT` fires, **or**
- code reads/uses `KNKK` / `KNKA`, calls `FD3x`, or hooks classic SD credit
  checks / credit-control-area logic.
- Modules: FI-AR, SD.

## Old -> New mapping (representative - DRAFT)
See `object_map.tsv` (`pattern_id = CREDIT_MGMT`). Classic credit master
(`KNKK`/`KNKA`) is `REPLACED_BY` the FSCM BP credit segment; there is **no 1:1
table mapping** - the data model and check logic differ. Verify the FSCM tables
and released APIs for your release.

## Remediation approach
1. **Do not** try to read KNKK/KNKA or call FD3x on S/4 - redesign onto FSCM.
2. Move credit-master access to the FSCM business-partner credit segment via the
   released FSCM APIs (`UKM_*`); move credit decisions to the FSCM/BRF+ check.
3. Custom SD credit-check user-exits/BAdIs must be re-implemented against the
   FSCM check framework.
4. This is project/config work (credit segments, risk classes, BRF+ rules) - the
   recipe flags it; a human owns the redesign.

## Released APIs / objects
- FSCM credit master + check via the released `UKM_*` APIs / BAdIs
  (see `api_replacements.tsv`; verify per release).

## Caveats & non-1:1 cases (always MANUAL_ONLY)
- No mechanical mapping exists; auto-remediation is unsafe.
- Requires FSCM configuration to exist on the target before code can be adapted.
- Credit decisions are financially sensitive - mandatory human sign-off.

## Before / After example (illustrative)
```abap
" before - classic credit master read (NOT available on S/4)
SELECT SINGLE klimk skfor FROM knkk INTO (lv_limit, lv_recv)
  WHERE kunnr = lv_kunnr AND kkber = lv_kkber.
```
```abap
" after - redesign onto SAP Credit Management (FIN-FSCM-CR) released APIs.
" No 1:1 mapping; consult the FSCM credit-segment API for your release. MANUAL.
```

## Validation
- Functional test of the credit decision on the sandbox against expected limits.
- Re-run `/sap-cc-analyze`; the Credit Management finding must clear.

## Confidence & gating
- `MANUAL_ONLY`. Never auto-apply. The recipe assembles context; a consultant
  designs and a human approves.

## Sources (provenance - reference only)
- SAP S/4HANA simplification item "Credit Management (FIN-FSCM-CR)". Verify SAP
  Notes, FSCM tables, and released APIs for your target release. Not a
  redistribution of SAP's Simplification Database.
