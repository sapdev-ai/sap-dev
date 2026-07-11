# sap-output-diagnose

Root-cause **NAST output determination** — "the invoice didn't print / the PO IDoc
never went out" — read-only over RFC (no GUI, no Z-object, no dev-init).

```
/sap-output-diagnose billing <VBELN> [--type <KSCHL>] [--json] [--out PATH]
/sap-output-diagnose po      <EBELN> [--type <KSCHL>] [--json] [--out PATH]
/sap-output-diagnose reissue (billing|po) <DOCNO> <KSCHL>     # confirm-gated
```

## What it does

Automates the 20+ lookups an output expert does by hand:

1. **NAST status** — issued OK (VSTAT 1) / processing failed (2) / not yet processed (0).
2. **Processing log** — for a failed output, the CMFP log (APLID WFMC) rendered to
   text via `BAPI_MESSAGE_GETDETAIL` (e.g. *"EDI: Partner profile does not exist"*).
3. **Determination walk** — the procedure (`TVFK-KALSM` / `T683S`) → each access of
   the access sequence (`T685`/`T682I`/`T682Z`) → the generated **B\*** condition
   tables, **rebuilding each access key from the document dynamically** and probing it.

Then a ranked verdict: **NO_RECORD** (with the exact missing condition key),
**REQUIREMENT_BLOCKED** (record exists but `RV61B<nnn>` suppressed it),
**PROCESSING_FAILED** (the log excerpt), or **issued OK**. `reissue` re-drives
RSNAST00 (gated) and re-reads NAST to verify.

## Dynamic, not hard-coded

The access key is rebuilt from `T682Z` (which comm-structure field feeds each B-table
key field) resolved against the document — VBRK/EKKO header fields directly, billing
partner functions (bill-to/ship-to) via VBPA, and a customer override in
`output_field_map.tsv` for user-exit fields. An unresolvable field → `COULD_NOT_CHECK`,
never a false NO_RECORD. Each B-table's real key is read via `DDIF_FIELDINFO_GET` (they
vary — some have validity fields, some don't).

## Reads

`VBRK`/`EKKO` (doc), `NAST` (status), `CMFK`/`CMFP` + `BAPI_MESSAGE_GETDETAIL` (log),
`TVFK`/`T683S`/`T685`/`T682I`/`T682Z` (condition technique), `B*` (condition records),
`TNAPR` (print program/form), `APOC_D_OR_ROOT` (S/4 BRF+ disclosure). All FMODE=R /
TRANSP, probed identical on both releases.

Read-only for `billing`/`po`; the only write is RSNAST00 (`reissue`), confirm-gated.
Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) — one code path, BRF+ the only
release-gated stage.
