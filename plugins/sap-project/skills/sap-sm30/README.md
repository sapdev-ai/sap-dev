# sap-sm30

**Maintains standard customizing views/tables through SM30's own generated dialog** — the
functional consultant's core write the suite otherwise couldn't do (/sap-update-addon covers
only Y/Z tables). `show` is read-only over RFC; `add`/`update` are confirm-gated GUI writes
verified by an authoritative RFC re-read.

```
/sap-sm30 show <VIEW|TABLE> [--where "F=V,..."]
/sap-sm30 add <VIEW> --data rows.tsv
/sap-sm30 update <VIEW> (--data rows.tsv | --key K=V --set F=V)
```

## What it does

- **`show` resolves the maintenance object over RFC** (`references/sap_sm30_read.ps1`):
  TVDIR dialog registration (one-step vs two-step + generated function group), DD25L view
  class, DD26S base tables → primary, DD27S view-field → base-field + key flags, TDDAT auth
  group, T000 client modifiability — then pre-reads the current rows, so you see the DDIC
  shape + data before any write.
- **`add`/`update` drive SM30's generated maintenance dialog** through a generic
  GuiTableControl driver (`references/sap_sm30_maintain.vbs`): columns are mapped by the
  DD27S field names embedded in the cell IDs, never hardcoded (the per-view screens are
  generated), paging the vertical scrollbar past `VisibleRowCount`. add = New Entries + fill
  + Save; update = Position (SAPLSPO4 popup) per row, overwrite the non-key cells, Save.
- **Preview diff before the gate** — the pre-read snapshot vs the `--data` TSV / `--set`
  change set renders ADD n / CHANGE m with old→new per field. An add whose key exists or an
  update whose key is absent is rejected — no silent upsert.
- **Customizing TR** resolved via `/sap-transport-request --type customizing` (never a
  Workbench TR, never prompted); the KO008 popup after Save is guarded — filled from the
  resolved TR or `SM30_TR_REQUIRED` on an empty one, never blind-Enter'd.
- **Verify by re-read:** after the write, `sap_sm30_read.ps1 -Action preread` re-reads the
  written keys — the verdict comes from the re-read ONLY; any delta is `SM30_VERIFY_MISMATCH`.

## Safety gates

Every write sits behind a CONFIRM gate (yes/no on dev/QA; typed `MAINTAIN <VIEW> ON
<SID>/<CLIENT>` when T000 marks the client production-grade). The only write channel is SM30's
sanctioned dialog — no SQL on standard tables. `delete` is never offered
(`SM30_DELETE_UNSUPPORTED` → manual SM30). v1 is one-step views only: two-step views (TVDIR
TYPE='2') and SM34 clusters are refused loud; a non-modifiable client aborts
(`SM30_CLIENT_NOT_MODIFIABLE`); runs are capped at 200 rows (reviewable diff, bounded GUI loop).

## Verified

`resolve`/`preread` live-verified on S4D (S/4HANA 1909) 2026-07-11; **add/update recorded and
live-verified end-to-end on S4D 2026-07-12** against a purpose-built one-step scratch view —
New Entries and Position+edit both drove the write and were RFC-confirmed, plus a full
assembled-driver smoke test. The Customizing-TR popup did not fire on S4D/100, so that branch
is guarded-but-not-exercised. A live screen diverging from the captured contract emits
`NEEDS_RECORDING` (re-record via `/sap-gui-probe --record`). Golden-screen baseline:
`references/sap_sm30_maintain.screens.json`. Single code path ECC6 + S/4 (SAPMSVMA on both;
EC2 probed in-plan).

Prerequisites: pinned /sap-login RFC profile; a live GUI session for add/update; NCo 3.1
(32-bit). RFC reads are direct — no wrapper, no dev-init. v1.5: two-step views, text-table
companion writes. v2: SM34 view clusters; opt-in headless write via
VIEW_MAINTENANCE_LOW_LEVEL (only after GUI parity is proven).
