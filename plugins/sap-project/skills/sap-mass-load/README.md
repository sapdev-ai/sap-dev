# sap-mass-load

**Loads CSV/XLSX mass data into SAP through ONE explicit backend per run** — a named BAPI
called directly over RFC, or an SHDB recording looped through ABAP4_CALL_TRANSACTION —
with the orchestration and safety layer MASS/XD99/LSMW lack: approved mapping, key
pre-validation, mandatory dry-run, typed confirm gate, and a resumable per-row ledger.
Entirely RFC in v1 (no GUI, no Z artefacts).

```
/sap-mass-load plan <file.csv|.xlsx> (--target-bapi <FM> | --target-bdc <rec>)
               [--key-cols C1,C2] [--sheet N]
/sap-mass-load validate <run-dir>
/sap-mass-load execute <run-dir> [--max-rows N]
/sap-mass-load resume <run-dir>
/sap-mass-load status <run-dir>
```

## What it does

- **plan** snapshots the input (SHA256-recorded), introspects the one target over RFC,
  and proposes an **AI column→field mapping from live DDIC texts** that REQUIRES explicit
  operator approval — an unmapped column needs a map/ignore decision, never a silent drop.
  Matching rows from `mass_load_target_advisories.tsv` (per-target release advisories) are
  shown alongside.
- **validate** (mandatory before execute) pre-checks key lookups over RFC against the
  check tables in `mass_load_checktables.tsv` (T001W/T052/KNA1/MARA/...), detects
  duplicate business keys, and writes a dry-run report. `VERDICT: BLOCKED` → execute
  refuses.
- **execute** is the only write, behind a **typed confirm gate**: the user must type
  `LOAD <row-count> <SID>/<CLIENT>` verbatim after seeing target system, client category,
  backend, row count, sample mapped rows, and advisories. Per row: build the BAPI call
  from the mapping, evaluate RETURN, E/A → ROLLBACK + ledger FAILED, else
  BAPI_TRANSACTION_COMMIT (WAIT='X') + ledger OK — then an **authoritative re-read** of a
  sample of created keys via RFC_READ_TABLE (mismatch → VERIFY_FAILED). Never raw SQL.
- **resume** re-runs only FAILED/PENDING ledger rows (OK rows SKIPPED, keys re-validated)
  — a 2,000-row load is safely re-runnable. **status** renders ledger totals locally with
  no SAP contact.

## Safety gates

A **production client is refused non-overridably** (T000 CCCATEGORY='P', or an unreadable
T000) — every mode except `status` runs the client guard first, and the pinned
`/sap-login` profile's SID/client IS the load target. An unapproved or stale mapping,
input-hash drift, or a dry-run older than the mapping → refuse. A key lookup that cannot
run is COULD_NOT_CHECK → dry-run BLOCKED, never a silent pass. An FMODE-blank FM target
refuses with `MASS_LOAD_TARGET_UNSUPPORTED` (the v1.5 wrapper path). Row counts above the
cap (default 1000 via `--max-rows`) are re-confirmed separately.

## Key reference files

`sap_mass_load_rfc.ps1` (read-only core: client guard, target introspection, dry-run
validation), `sap_mass_load_execute.ps1` (the gated BAPI row-loop executor + ledger;
`-DryRun` previews the built calls without writing), `mass_load_checktables.tsv`,
`mass_load_target_advisories.tsv`. The `--target-bdc` recording format follows
`/sap-call-bdc`.

The read-only safety core is live-verified on S/4HANA 1909 (S4D): client guard,
interface introspection (BAPI_MATERIAL_SAVEDATA, 51 params), a BLOCKED dry-run on a
fixture with a duplicate key and a bad plant, and the executor's `-DryRun` — the LIVE
execute was deliberately not run autonomously. ECC 6 shares the identical code path.
Deferred: `--group-by` multi-row documents and failure clustering (v1.5); `--backend=sm35`
and the GUI loop for BAPI-less targets (v2). Prerequisites: pinned RFC profile via
`/sap-login`; SAP NCo 3.1 (32-bit).
