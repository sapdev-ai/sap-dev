# OUTPUT_MGMT — Output determination (NAST message control -> S/4 Output Management)  [DRAFT]

- **pattern_id:** OUTPUT_MGMT
- **category:** FUNCTIONAL   **tier:** R3   **confidence_default:** MANUAL_ONLY
- **simplification item:** S4TWL - Output Management
- **status:** DRAFT - functional/config redesign; **verify per release**
- **applies modules:** CROSS (SD, MM, and other document outputs)

## Summary
S/4HANA introduces a new **Output Management** (OM) framework - BRF+-based output
determination, Adobe forms, and the cloud-ready output channels - alongside the
classic **NAST** message-control technique (tables `NAST`/`TNAPR`, transaction
`NACE`, driver `RSNAST00`). For document types switched to OM, the classic NAST
path is bypassed. Custom output types, print/driver programs, and NAST-based
determination logic must be reviewed and, where the document uses OM, redesigned.
NAST still works for many objects, so this is coexistence-aware - treat as MANUAL.

## Applies when
- ATC simplification item `S4TWL-OUTPUT-MGMT` fires, **or**
- code references `NAST` / `TNAPR`, calls `RSNAST00`, or implements classic
  message-determination / print-program logic for documents now on OM.
- Modules: CROSS.

## Old -> New mapping (representative - DRAFT)
No table-level 1:1 mapping. NAST message control -> OM (BRF+ output parameter
determination + form templates). The right target depends on whether the
specific document type was moved to OM on your release - **verify**.

## Remediation approach
1. **Determine the regime per document type:** still NAST, or moved to OM? Only
   OM-enabled documents need migration; classic NAST output may remain valid.
2. **For OM documents:** re-model output types as OM determination (BRF+),
   migrate the form to the OM technology, and move custom logic out of the NAST
   print program into OM (form / determination / email).
3. **Do not** assume `RSNAST00`/NAST will drive OM documents - it will not.
4. Config + form work dominates; the recipe flags it, a human owns it.

## Released APIs / objects
- S/4 Output Management framework (BRF+ determination, OM API/BAdIs) - verify the
  released entry points for your release.

## Caveats & non-1:1 cases (always MANUAL_ONLY)
- Mixed estates (some docs NAST, some OM) need per-document analysis.
- Form technology migration (SAPscript/Smart Forms -> form templates) is its own
  effort.
- Output is customer-visible and audited - mandatory human sign-off.

## Before / After example (illustrative)
```abap
" before - classic NAST-driven output processing
SUBMIT rsnast00 WITH ... AND RETURN.   " or direct NAST reads / print-program hooks
```
```abap
" after - for OM-enabled documents, output is driven by S/4 Output Management
" (BRF+ determination + form template), NOT RSNAST00/NAST. Redesign. MANUAL.
```

## Validation
- Issue a document of the affected type on the sandbox; confirm output is
  produced via the correct framework and matches the expected form.
- Re-run `/sap-cc-analyze`; the Output Management finding must clear.

## Confidence & gating
- `MANUAL_ONLY`. Never auto-apply; coexistence + form/config work require a human.

## Sources (provenance - reference only)
- SAP S/4HANA simplification item "Output Management". Verify SAP Notes, which
  document types are OM-enabled, and the released OM APIs for your target
  release. Not a redistribution of SAP's Simplification Database.
