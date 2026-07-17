# sap-tcd-chain

**Headless order-to-cash document chain over RFC BAPIs** — sales order → outbound
delivery → goods issue → billing, each step committed (WAIT='X') and **VBFA-verified
before the next**, so regression testing gets whole document flows instead of isolated
documents. Completes the test-data family absorbed from the former sap-tcd plugin
(`/sap-bp` partners, `/sap-mm01` materials, `/sap-va01` orders) by chaining the
documents those skills feed.

```
/sap-tcd-chain run o2c --scenario <file> [--from-order <VBELN>]
               [--stop-after order|delivery|gi|billing] [--dry-run]
/sap-tcd-chain status <VBELN|manifest>
```

## What it does

- **run o2c** — drives the chain step by step, threading each document key into the
  next. Every backend action calls the SAP write BAPI, commits, then verifies the VBFA
  successor row (VBTYP_N J=delivery, R=goods issue, M=billing, with a 0/1/2/4s backoff
  for V2-update lag) — success is never trusted from the BAPI echo alone.
- **Stops on the first failure** and dumps the verbatim BAPIRET2. A blocked step is
  almost always a customizing problem (shipping point, copy control, picking
  relevance) — the message IS the deliverable, never silently retried. A BAPI that
  "succeeded" without a VBFA successor is `VERIFY_FAILED`, never rendered as done.
- **--dry-run** — zero SAP writes: master-data preflight (KNA1/MARA) plus a genuine
  server-side order simulate (`BAPI_SALESORDER_CREATEFROMDAT2 TESTRUN`). Preflight
  failures point at `/sap-bp` / `/sap-mm01` (never auto-invoked).
- **status** — read-only VBFA replay on any existing order, reporting
  `VERIFIED`/`MISSING` per chain step.
- Writes an auditable `chain_manifest.json` (schema `sapdev.tcdchain/1`) into the
  artifact dir and registers it (`Register-SapArtifact`), verdict
  COMPLETE/PARTIAL/FAILED.

## Scenario file

Tab-delimited `SECTION<TAB>FIELD<TAB>VALUE`: `ORDER_HEADER` (DOC_TYPE, SALES_ORG,
DISTR_CHAN, DIVISION), `ORDER_PARTNERn` (ROLE=AG sold-to, NUMBER), `ORDER_ITEM_NN`
(MATERIAL, QTY), `DELIVERY` (SHIP_POINT), `BILLING`. Commented sample:
`references/scenario_o2c_sample.txt`.

## Prerequisites

- SAP profile saved via `/sap-login` (RFC password) with SD posting authorization
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC
- No GUI session, no Z objects, no transports needed (pure RFC in v1)

## Reference files

| File | Purpose |
|---|---|
| `references/sap_tcd_chain_rfc.ps1` | BAPI chain + VBFA verify (`-Action preflight\|create-order\|create-delivery\|post-gi\|create-billing\|verify-flow`) |
| `references/scenario_o2c_sample.txt` | Commented scenario-file template |

## Safety & limitations (v1)

- `run o2c` is **confirm-gated** (mandatory yes/no naming SID/client, doc type,
  sold-to, item count) — it writes real SD documents. Decline = zero documents.
- All v1 FMs are remote-enabled on S/4HANA 1909 and ECC 6 — one code path. VBFA is the
  only linkage source; VBUK is never read (dead on S/4 for new documents).
- Scenario parsing, preflight, `status`/`verify-flow`, and the order step's TESTRUN
  wiring are live-verified on S4D; the delivery / GI / billing steps are wired from
  their verified interfaces but need a config-complete O2C org path — customizing
  dependence is the top risk, surfaced not solved.
- Phase 2 (not implemented): `reset` (LIFO reversal), `run p2p` (PO→GR→IR), and
  `--order-gui` (delegate the order step to `/sap-va01`).
