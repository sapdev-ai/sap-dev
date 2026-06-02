# ADD_ORDER_BY — add ORDER BY where implicit row order is relied upon

- **pattern_id:** ADD_ORDER_BY
- **category:** HANA   **tier:** R3   **confidence_default:** AI_REVIEW
- **simplification item:** (none — behavioral HANA rule)
- **status:** ACTIVE   **applies modules:** CROSS

## Summary
On a row store the database often returned rows in (primary-key / secondary-
index) order even without `ORDER BY`. On HANA the order of a `SELECT` without an
explicit `ORDER BY` is **non-deterministic**. Code that relies on implicit
ordering produces silent, data-dependent bugs after conversion.

## Applies when
- An ATC HANA check flags a SELECT whose result order is consumed, **or**
- code signature: a `SELECT ... INTO TABLE` followed by `READ TABLE ... BINARY
  SEARCH`, or first-row/last-row logic, `APPEND`-then-`READ INDEX 1`, or
  comparisons across adjacent rows.
- Modules: CROSS.

## Old → New mapping
None — behavioral fix, not an object/field remap.

## Remediation approach (judgment-heavy — this is why it is AI_REVIEW, not AUTO)
1. **Decide whether order is actually relied upon.** Look downstream of the
   SELECT: BINARY SEARCH, first/last-row logic, sorted processing, delta
   comparison between consecutive rows → order matters. Pure set processing
   (totals, EXISTS checks, full loops without positional logic) → it does not.
2. **If order matters:** add `ORDER BY` matching the relied-upon sort (often the
   primary key, or the key later used by BINARY SEARCH). Alternatively `SORT
   itab BY ...` right after the SELECT.
3. **If order does NOT matter:** make no change. Do **not** add `ORDER BY`
   blindly — it adds a sort cost for no benefit. Record "no change needed".
4. Keep the sort key consistent with any subsequent `READ TABLE ... BINARY
   SEARCH` key, or the search breaks.

## Released APIs / objects
None — `ORDER BY` / `SORT` language change only.

## Caveats & non-1:1 cases (when to downgrade to MANUAL_ONLY)
- Adding `ORDER BY` on a non-indexed column of a huge table can be expensive —
  flag for performance review (MANUAL) instead of auto-applying.
- `SELECT SINGLE` with a non-unique WHERE is a related but distinct ambiguity —
  handle separately.

## Before / After example
```abap
" before — relies on implicit primary-key order for BINARY SEARCH
SELECT matnr werks FROM marc INTO TABLE lt_marc WHERE werks = lv_werks.
READ TABLE lt_marc WITH KEY matnr = lv_matnr BINARY SEARCH.
```
```abap
" after — explicit ORDER BY matching the BINARY SEARCH key
SELECT matnr, werks FROM marc INTO TABLE @lt_marc
  WHERE werks = @lv_werks
  ORDER BY matnr.
READ TABLE lt_marc WITH KEY matnr = lv_matnr BINARY SEARCH.
```

## Validation
- Where feasible, compare the object's output before/after on identical input on
  the sandbox (must be deterministic).
- Re-run `/sap-cc-analyze`; the HANA ordering finding must clear (or be justified
  as "set processing — no order reliance").

## Confidence & gating
- `AI_REVIEW`: whether order is relied upon is judgment — always human-confirm.
  Large-table sorts → MANUAL performance review.

## Sources (provenance — reference only)
- SAP HANA/ABAP guidance: "the order of a result set is undefined without
  ORDER BY". General behavioral rule, not tied to a single simplification note.
