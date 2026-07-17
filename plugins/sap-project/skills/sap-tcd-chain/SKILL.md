---
name: sap-tcd-chain
description: |
  Drives a complete headless O2C business-document chain — sales order → outbound
  delivery → goods issue → billing — over RFC BAPIs, so regression testing gets whole
  document flows, not isolated documents. Each step is created via its SAP write BAPI,
  committed (WAIT='X'), and VBFA-verified before the next step (VBTYP_N J=delivery,
  R=goods issue, M=billing) — success is never trusted from the BAPI echo. Stops on
  the first failure and dumps the verbatim BAPIRET2 (a blocked step is almost always a
  customizing problem — the message IS the deliverable), writing an auditable chain
  manifest that `status` re-verifies and phase-2 `reset` reverses. `--dry-run`
  TESTRUN-simulates the order + preflights master data with zero writes. Pure RFC (all
  v1 FMs remote-enabled on S/4HANA 1909 + ECC 6) — no GUI, no Z objects, no transports;
  VBUK is never read (dead on S/4 for new docs). Prerequisites: SAP profile via
  /sap-login (RFC) with SD posting authorization; SAP NCo 3.1 (32-bit).
argument-hint: "run o2c --scenario <file> [--from-order <VBELN>] [--stop-after order|delivery|gi|billing] [--dry-run] | status <VBELN|manifest>"
---

# SAP O2C Chain Skill

You drive an order-to-cash document chain headlessly, **verifying each step against
VBFA before the next**, and stop cleanly with the verbatim BAPIRET2 when config blocks
a step. You never continue past a failed or unverified step.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_tcd_chain_rfc.ps1` | `-Action preflight\|create-order\|create-delivery\|post-gi\|create-billing\|verify-flow` | BAPI chain + VBFA verify |
| `<SKILL_DIR>/references/scenario_o2c_sample.txt` | template | Commented scenario-file sample |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | Chain manifest + evidence registration |
| `/sap-login` | sub-skill | Pinned RFC profile |
| `/sap-bp` · `/sap-mm01` | sub-skills | Pointed to in preflight failures (never auto-invoked) |

Scenario file: tab-delimited `SECTION<TAB>FIELD<TAB>VALUE` — `ORDER_HEADER`
(DOC_TYPE, SALES_ORG, DISTR_CHAN, DIVISION), `ORDER_PARTNERn` (ROLE=AG sold-to,
NUMBER), `ORDER_ITEM_NN` (MATERIAL, QTY), `DELIVERY` (SHIP_POINT), `BILLING`.

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging
(`sap_log_helper.ps1`, state `{RUN_TEMP}\sap_tcd_chain_run.json`). RFC-only — no GUI session.

## Step 1 — Parse & Dispatch

Modes: `run o2c` (+ `--dry-run`, `--from-order`, `--stop-after`), `status`. Phase-2
(`reset`, `run p2p`) → say not implemented, cite the roadmap. Validate the scenario
file locally first.

## Step 2 — RFC Profile

Pinned RFC profile required (`/sap-login`) — no GUI fallback in v1; missing profile →
`RFC_LOGON_FAILED`, STOP.

## Step 3 — `--dry-run` (zero SAP writes)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_tcd_chain_rfc.ps1" -Action preflight -Scenario "<file>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Then `-Action create-order -Scenario <file> -TestRun X` — a genuine server-side
simulate (`BAPI_SALESORDER_CREATEFROMDAT2 TESTRUN`) with zero persistence. Render the
`STEP:` + `BAPIRET:` lines. `--dry-run` stops here (report the verdict). `SCENARIO_INVALID`
(missing sold-to / item / org) → show the offending lines, STOP.

## Step 4 — Confirm Gate (`run o2c`, mandatory)

State it and get a yes/no:

> I will create a real O2C chain in `<SID>/<CLIENT>`: order (`<DOC_TYPE>`, sold-to
> `<AG>`, `<n>` items) → delivery → goods issue → billing. This writes real documents.
> Proceed? (yes/no)

Decline → log `SKIPPED`, STOP (zero documents).

## Step 5 — Drive the Chain (verified, stop-on-first-failure)

Run the steps in order, threading each step's key into the next
(`create-order` → `-Order <VBELN>` → `create-delivery` → `-Delivery <VBELN>` →
`post-gi` / `create-billing`). `--from-order <VBELN>` skips step 1. Honor `--stop-after`.

Each backend action: calls the BAPI → COMMIT (WAIT='X') → **VBFA verify** (with a
0/1/2/4s backoff for V2-update lag) → prints `STEP: <name> OK key=<doc>`. On failure:
- `STEP_FAILED` → the BAPI returned E/A; the transaction was **rolled back**; the
  `BAPIRET:` lines are the deliverable (almost always customizing: shipping point, copy
  control, division/text, picking relevance). Finalize the manifest PARTIAL, STOP.
- `VERIFY_FAILED` → the BAPI "succeeded" but no VBFA successor row appeared — a false
  success; STOP (`TCD_CHAIN_VERIFY_FAILED`). Never render it as done.

## Step 6 — Manifest + Register (you assemble it)

Write `chain_manifest.json` (schema `sapdev.tcdchain/1`) into the artifact dir
(`Get-SapArtifactDir -ScopeKey TCDCHAIN_<SID>_<CLIENT>_<order>`) from the `STEP:` lines:
`{system, client, scenario, steps[{step, key, status}], verdict}`. Register
(`Register-SapArtifact -Kind tcd_chain_manifest -Verdict COMPLETE|PARTIAL|FAILED`).
Print `CHAIN: <verdict> order=<VBELN> delivery=<..> gi=<..> billing=<..>`.

## status mode

`-Action verify-flow -Order <VBELN>` replays the VBFA reads (order → J/R/M successors)
and reports `VERIFIED`/`MISSING` per step — read-only, works on any existing order.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class): `TCD_SCENARIO_INVALID` /
`TCD_CHAIN_STEP_FAILED` / `TCD_CHAIN_VERIFY_FAILED`.

---

## Scope & Limitations (v1)

- **v1:** `run o2c` (order→delivery→GI→billing, VBFA-verified, stop-on-first-failure),
  `--dry-run` (TESTRUN order simulate + KNA1/MARA preflight), `--from-order`,
  `--stop-after`, `status`.
- **Phase 2:** `reset` (LIFO reversal — GI reversal via `WS_REVERSE_GOODS_ISSUE` is not
  remote-enabled, routes through the dev-init wrapper); `run p2p` (PO→GR→IR);
  `--order-gui` (v1.5, delegate step 1 to `/sap-va01`).
- **Verification status:** scenario parsing, `preflight`, `status`/`verify-flow` (the full
  VBFA linkage), and the order step's BAPI wiring are live-verified on S4D; the order
  step uses `TESTRUN` for a real zero-persistence simulate. The delivery / goods-issue /
  billing BAPIs are wired from their verified (FMODE=R) interfaces but need a
  config-complete O2C org path for a live end-to-end run — **customizing dependence is the
  top risk, surfaced not solved:** the skill's contract is faithful BAPIRET2 + stop, never
  a silent retry. Pin a known-good doc-type / org / plant / sold-to / material per system.
- **VBFA is the only linkage source** (VBUK is never read — dead on S/4 for new docs);
  identical on ECC 6 and S/4. Alphanumeric keys (e.g. sold-to `J_KLYY`) are passed
  unpadded; numeric keys are ALPHA zero-padded. No GUI, no Z objects, no transports in v1.
