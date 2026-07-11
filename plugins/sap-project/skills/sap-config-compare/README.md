# sap-config-compare

**Keyed, row-level RFC diff of one customizing table/view across two systems or
clients** — the shareable answer to *"it works in QAS but not in DEV/PRD"*. Read-only
(no GUI, no SCU0/SCMP, no Z-object).

```
/sap-config-compare <TABLE|VIEW> --against <profile-hint>
                    [--where "F1=V1,F2=A..B"] [--options "<raw>"]
                    [--fields F1,F2] [--keys-only] [--max-rows N]
```

## What it does

- **Dual-connect** LEFT (pinned profile) + RIGHT (`--against`), reusing the
  /sap-compare second-profile pattern; identity per side is read **live** (SID via
  RFC_SYSTEM_INFO, logon client via USR02) — not from the possibly-stale profile store.
- **Resolves** the object on both sides: table → direct; database/projection view →
  direct; maintenance/help view → decomposed to its primary base table (RFC_READ_TABLE
  cannot read a maintenance view), with the other base tables disclosed as not-diffed.
- **Compared-field set** = intersection of both sides' fields, minus the technical
  client key (for client-dependent tables), minus STRG/RSTR and columns too wide to
  chunk. Structural drift (columns on one side only) is reported, never diffed silently.
- **Unbounded-read guard** — a keys-only probe refuses (`CFG_UNBOUNDED_READ`) a full
  read over `--max-rows` when no filter was given, and suggests a key-field filter.
- **Chunked offset-based read** — fields are packed into ≤512-byte groups (keys repeat
  per group) and each field is sliced by its RFC_READ_TABLE FIELDS OFFSET/LENGTH, so a
  value containing any delimiter char can never corrupt the parse. Numeric columns are
  normalized by their DDIC DECIMALS so `1.234,56` and `1,234.56` compare equal.
- **Diffs** with the ONE shared keyed-diff engine (`sap_keyed_diff_lib.ps1`) →
  `diff.tsv` (`LEFT_ONLY` / `RIGHT_ONLY` / `CHANGED`) + a functional summary that
  translates deltas using DDIC texts ("condition type PR00: calc rule differs").

## Honest by construction

Every verdict is gap-aware. Any excluded column, one-sided column (release skew),
maintenance-view base table not diffed, or row cap degrades a clean `IDENTICAL` to
`IDENTICAL_WITH_GAPS` / `DIFFERENT_WITH_GAPS`, all listed in `meta.json` + the summary.
An unbounded read is refused, never silently truncated. `LEFT_ONLY` = pinned side,
`RIGHT_ONLY` = `--against` side.

## Reads

`DD02L`/`DD25L`/`DD26S` (object + view resolution), `DDIF_FIELDINFO_GET` (field
metadata: key/datatype/length/decimals), `RFC_SYSTEM_INFO` + `USR02` (live identity),
the compared table/view itself, `DD02T`/`DD04T` (texts). All FMODE=R / TRANSP,
identical on both releases.

Read-only; never writes; never drives GUI. The keyed-diff engine is shared with
`/sap-se16n` (snapshot diff) and `/sap-compare` (`--table-content`). `--client` cross-
client sugar, multi-base maintenance-view diff, and `preset` functional bundles are the
next phases. Verified live on S/4HANA 1909 (S4D) ↔ ECC 6 (EC2/ERP).
