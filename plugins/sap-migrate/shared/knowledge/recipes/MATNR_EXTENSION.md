# MATNR_EXTENSION — material number field-length extension (18 → 40)

- **pattern_id:** MATNR_EXTENSION
- **category:** FIELD_LENGTH   **tier:** R1   **confidence_default:** AUTO_OK
- **simplification item:** S4TWL - Material Number Field Length Extension
- **status:** ACTIVE   **applies modules:** CROSS

## Summary
The material number (MATNR) and related fields can be configured up to 40
characters in S/4HANA. Custom code that hardcodes the old CHAR18 length, moves
MATNR into a `CHAR18` field, or does offset/length operations assuming 18 chars
will truncate values or raise length errors.

## Applies when
- ATC simplification item `S4TWL-MATNR-LENGTH` fires, **or**
- code declares a material-number field as `TYPE c LENGTH 18`, moves MATNR into
  a too-short field, or slices it with `+0(18)` / `(18)`.
- Modules: CROSS.

## Old → New mapping
None — this is a field-length fix, not an object/field remap. Use the DDIC
type (`MATNR` data element) instead of a hardcoded length.

## Remediation approach (mechanical — R1)
1. Replace local CHAR18 declarations of material-number fields with `TYPE matnr`
   (or the relevant DDIC data element).
2. Remove hardcoded length 18 in offset/length operations on MATNR.
3. Re-check `CONVERSION_EXIT_MATN1` usage — still valid, but verify the
   receiving field length.
4. Where a truly mechanical type substitution is not possible (e.g. an external
   interface layout fixed at 18 chars), escalate to MANUAL.

## Released APIs / objects
None specific — DDIC type substitution.

## Caveats & non-1:1 cases (when to downgrade to MANUAL_ONLY)
- External file / interface layouts fixed at 18 chars are a functional decision
  → MANUAL, not auto.
- Concatenations / composite keys that combine MATNR with other fields may need
  width review.

## Before / After example
```abap
" before
DATA lv_matnr TYPE c LENGTH 18.
```
```abap
" after
DATA lv_matnr TYPE matnr.
```

## Validation
- Syntax check + ATC re-run; the `S4TWL-MATNR-LENGTH` finding must clear.

## Confidence & gating
- `AUTO_OK` for pure type substitutions; interface-width changes → MANUAL.

## Sources (provenance — reference only)
- SAP S/4HANA simplification item "Material Number Field Length Extension".
  Verify the exact SAP Note for your release. Not a redistribution of SAP's
  Simplification Database.
