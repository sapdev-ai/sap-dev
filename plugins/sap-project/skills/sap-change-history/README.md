# sap-change-history

**Answer "who changed this object / this data, and when" headlessly over RFC** — resolve a
business token (PO, customer, vendor, material, sales order, G/L account …) to its
change-document class, scan CDHDR, and pull the fully DECODED field-level rows
(table · field · old → new, with DDIC labels). No more hand-joining CDHDR/CDPOS in SE16N.

```
/sap-change-history <object> <key> [--from=YYYYMMDD] [--to] [--changenr=N] [--correlate]
/sap-change-history user <U> [--from --to]
/sap-change-history window --from=X [--to] [--class=C]
/sap-change-history classes [--all]
```

## What it does

- **Resolves the token** via a curated map
  (`references/sap_change_history_objectclas_map.tsv`, custom override at `{custom_url}`
  honored; a raw `OBJECTCLAS:<class>` token bypasses it) and ALPHA-converts the key to the
  key element's internal width (numeric keys get leading zeros).
- **Scans CDHDR** for the change headers, then **decodes** field-level old → new via
  `CHANGEDOCUMENT_READ` through the dev-init wrapper `Z_GENERIC_RFC_WRAPPER_TBL` — one call
  that sidesteps both the CDPOS 512-byte RFC_READ_TABLE limit and ECC-6's CDPOS **cluster**
  storage; one code path, no release variant.
- **Renders an auditable timeline** (`change_timeline.md` — grouped by change number:
  who · when · tcode, then field label: old → new) plus evidence-grade TSVs.
- **`--correlate`** time-orders the changes against transport imports (E070) and
  /sap-diagnose evidence, so "TR imported → field changed 5 min later" reads as one story —
  and registers change-history as a diagnose evidence source.
- **`user` / `window` scans** plus a **`classes`** dump (the curated map validated against
  live TCDOB/TCDOBT) round out the surface.

## Honest by construction

An object with no change documents is `CDH_NO_CHANGES` — an honest empty ("object may not
be change-doc-enabled"), never fabricated as "nothing changed". Unknown token →
`CDH_CLASS_UNKNOWN` with the curated list. Wrapper missing → `CDH_WRAPPER_MISSING`,
pointing to `/sap-dev-init` (which owns the deploy consent — this skill never deploys
anything). Decode fan-out beyond `--decode-max` stays header-only and registers
`COULD_NOT_CHECK` coverage for the remainder, never a silent short list. `user`/`window`
scans are window- and `--max`-bounded by design.

## Reads

`CDHDR` (headers), `CHANGEDOCUMENT_READ` via the wrapper (decoded positions — never a raw
CDPOS read), `TCDOB`/`TCDOBT` (class map), `E070`/`E071` (imports), `DD03L`/`DD04T`
(labels). Pure RFC — no GUI, no SQL writes. Prerequisites: pinned `/sap-login` profile
(SAP NCo 3.1, 32-bit) plus the dev-init wrapper FM for the decode step (deployed by
`/sap-dev-init`, never by this skill).

Read-only, always. Verified live on S/4HANA 1909 (S4D) — a real material's 59 change rows
decoded end-to-end with DDIC field labels, matching a CDPOS spot-check; ECC 6 (EC2/ERP)
parity per the plan's probe. `config <TABLE>` (customizing/table history from DBTABLOG —
SCU3 headless) is phase 2 and a fail-loud stub today.
