# sap-golden-master

**Golden-master regression testing for SAP report output and table state** — answers
*"does this produce the same output after the change?"* as one command instead of a manual
before/after Excel diff. Pure composition of shipped skills: no new Z object, no driving VBS.

```
/sap-golden-master capture <ID> (--report PROG [--variant V]
                                 | --table TAB --select F1,F2 [--where ...] [--key ...])
/sap-golden-master verify <ID> [--tr TRKORR] [--spec file]
/sap-golden-master rebase <ID>
/sap-golden-master list | show <ID> | delete <ID>
```

## What it does

- **capture** stores a deterministic baseline: a report's background spool (delegated to
  `/sap-run-report` + `/sap-job` + `/sap-sp02`) or a table dump (delegated to `/sap-se16n`),
  then normalizes away volatile tokens — dates, times, timestamps, the capture user, page
  headers — per `references/golden_master_normalization_rules.tsv` (customer-overridable
  via `{custom_url}`). Table legs are key-sorted so row order is canonical. An `add`
  mode appends a second leg to an existing baseline.
- **verify** re-runs the identical variant with the manifest's replay args, normalizes with
  the same rules, diffs (keyed diff for tables, line diff for spools), then Claude **triages
  each hunk against the TR text and/or `--spec`** into EXPECTED / REGRESSION / UNEXPLAINED
  and emits a `GO` / `REGRESSION` / `COULD_NOT_VERIFY` verdict, registered for
  `/sap-evidence-pack`.
- **rebase** replaces the golden copy after an intended change — only after an explicit
  "replace the golden copy?" confirmation.
- A **variant-drift guard** fingerprints the report variant (VARID change stamp) at capture
  and refuses a verify whose fingerprint differs (`GM_VARIANT_DRIFT`) unless
  `--accept-variant-drift`.
- Baselines live at `{golden_master_dir}\<SID>_<CLIENT>\<ID>\` with a
  `sapdev.goldenmaster/1` `manifest.json` — **keyed per (SID, CLIENT)**, so an S4D golden
  can never silently verify against another system (`GM_SYSTEM_MISMATCH`).

## Honest by construction

`COULD_NOT_VERIFY` is never rendered `GO`: a missing spool, aborted job, or empty
re-capture where the golden had rows is `GM_CAPTURE_INCOMPLETE`. UNEXPLAINED hunks (and
any hunk-cap overflow) count as REGRESSION — conservative by default. An EXPECTED
classification must cite the TR/spec text that predicts it. A failed capture leg leaves
no partial golden. `list` / `show` / `delete` are local-only and never touch SAP.

## Key reference files

`sap_gm_manifest.ps1` (store layout + manifest), `sap_gm_meta.ps1` (RFC meta: system
identity, VARID fingerprint, DD03L keys, TR text), `sap_gm_normalize.ps1` (offline
volatile-token normalizer), `sap_gm_diff.ps1` (offline golden-vs-current diff),
`golden_master_normalization_rules.tsv`.

Read-only toward SAP data — the only executions are the delegated report runs, whose
Rule-5 confirm gates are THE gates (never bypassed or re-implemented). Prerequisites:
active SAP GUI session (`/sap-login`) for the delegated capture legs; SAP NCo 3.1 (32-bit)
for the RFC meta reads. Phase 2: headless RFC spool read, ALV interactive capture,
scheduled drift monitor; a variant-*contents* snapshot is a v1.5 enhancer (v1's
wrapper-free VARID stamp already works without dev-init). `/sap-test-replay` builds on
the shipped manifest schema.
