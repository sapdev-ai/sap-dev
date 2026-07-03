# SD_STATUS_TABLES — SD status tables eliminated (VBUK/VBUP -> document tables)  [DRAFT]

- **pattern_id:** SD_STATUS_TABLES
- **category:** DATA_MODEL   **tier:** R2   **confidence_default:** AI_REVIEW
- **simplification item:** S4TWL - Data Model Changes in SD
- **status:** DRAFT - mappings below are representative; **verify per release**
- **applies modules:** SD (sales documents, deliveries, billing)

## Summary
S/4HANA eliminates the SD status tables **VBUK** (header status) and **VBUP**
(item status). The status fields moved INTO the document tables themselves:
sales documents **VBAK/VBAP**, deliveries **LIKP/LIPS**, billing **VBRK/VBRP**.
Unlike KONV or the FI index tables, **no like-for-like compatibility views are
provided for VBUK/VBUP** — a `SELECT ... FROM vbuk` does not survive the
conversion and must be redirected to the owning document table's status
fields (same names for the common statuses, e.g. `GBSTK`, `LFSTK`, `GBSTA`).

## Applies when
- ATC simplification item `S4TWL - Data Model Changes in SD` fires for status
  tables, **or**
- code reads/joins `VBUK` or `VBUP` (typically by `VBELN` / `VBELN`+`POSNR`).
- Modules: SD.

## Old -> New mapping (representative - DRAFT)
See `object_map.tsv` / `field_map.tsv` (`pattern_id = SD_STATUS_TABLES`).
`VBUK` is `MERGED_INTO` the header tables (`VBAK`; deliveries `LIKP`, billing
`VBRK`), `VBUP` into the item tables (`VBAP`; deliveries `LIPS`, billing
`VBRP`). Common status fields keep their names (`VBUK-GBSTK -> VBAK-GBSTK`,
`VBUP-LFSTA -> VBAP-LFSTA`, ...) but **which document table owns the status
depends on the document category** the code was reading — field availability
differs per release; verify each field before relying on it.

## Remediation approach
1. **Identify the document category** the VBUK/VBUP read serves (sales order,
   delivery, billing doc — often visible from the surrounding joins or the
   VBELN's source).
2. **Header reads:** redirect `FROM vbuk WHERE vbeln = ...` to the owning
   header table (`VBAK`/`LIKP`/`VBRK`) selecting the same-named status fields.
3. **Item reads:** redirect `FROM vbup WHERE vbeln = ... AND posnr = ...` to
   the owning item table (`VBAP`/`LIPS`/`VBRP`).
4. **Joins collapse:** a `JOIN vbuk ON vbak~vbeln = vbuk~vbeln` becomes
   redundant — the status columns are on the SAME row now; drop the join and
   read the fields directly.
5. **Writes:** custom code must never have written VBUK/VBUP; if it did,
   escalate to MANUAL (status is owned by SD document processing).

## Released APIs / objects
- None required — this is a read redirect onto the document tables (or the
  released sales-document CDS views, verify names per release).

## Caveats & non-1:1 cases (when to downgrade to MANUAL_ONLY)
- Code that reads VBUK for a **mixed set of document categories** through one
  generic path -> needs a per-category split (VBAK vs LIKP vs VBRK) -> MANUAL.
- A status field the code used that has **no counterpart** on the document
  table in the target release -> MANUAL (re-derive or redesign).
- Generic frameworks keying on VBUK's table name (dynamic SQL, `(lv_tab)`)
  -> MANUAL.
- Archived/converted historical documents: verify status backfill on the
  sandbox before trusting comparisons.

## Before / After example (illustrative)
```abap
" before
SELECT SINGLE gbstk lfstk FROM vbuk
  INTO (lv_gbstk, lv_lfstk)
  WHERE vbeln = lv_vbeln.
```
```abap
" after - status fields live on the sales-document header itself (verify per release)
SELECT SINGLE gbstk, lfstk FROM vbak
  INTO (@lv_gbstk, @lv_lfstk)
  WHERE vbeln = @lv_vbeln.
```

## Validation
- Compare header/item status values for known documents before vs. after on
  the sandbox (same VBELN/POSNR set).
- Re-run `/sap-cc-analyze`; the SD data-model finding for VBUK/VBUP must clear.

## Confidence & gating
- `AI_REVIEW`. Single-category read redirects are usually mechanical; mixed
  document categories, missing fields, or any write path is MANUAL.

## Sources (provenance - reference only)
- SAP S/4HANA simplification item "Data Model Changes in SD" (status tables
  VBUK/VBUP eliminated; status fields moved to the document tables). Verify
  SAP Notes, field availability, and CDS view names for your target release.
  Not a redistribution of SAP's Simplification Database.
