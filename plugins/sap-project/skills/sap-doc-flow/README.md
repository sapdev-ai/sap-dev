# sap-doc-flow

**Reconstruct the O2C document chain from a bare business-document number and find where
it stalled** — read-only over RFC, no VA03/VL03N/VF03/FB03 hopping.

```
/sap-doc-flow <DOCNO>                          # auto-detect category
/sap-doc-flow order|delivery|invoice <DOCNO>   # explicit
   [--max-nodes N] [--no-narrative] [--evidence-dir <RUN_DIR>] [--connection PROFILE]
```

## What it does

- **Auto-detects** the category (order/delivery/invoice) by probing VBAK/LIKP/VBRK for the
  ALPHA-padded key, then **walks VBFA in both directions** (visited-set cycle guard, depth
  8, `--max-nodes` cap) to build the full order→delivery→goods-issue→invoice chain.
- **Decodes every node's status release-aware** — the ECC-vs-S/4 divergence handled in the
  reader, not by script variants: S/4 reads GBSTK/WBSTK/RFBSK in-table (VBAK/LIKP/VBRK);
  ECC reads them from VBUK. The branch is chosen by a DD03L probe (VBAK-GBSTK present ⇒
  S/4), **not** VBUK existence (VBUK survives on S/4 1909).
- **Follows the invoice into FI** via BKPF `AWTYP='VBRK'` + AWKEY candidates
  (`VBELN`, `VBELN||GJAHR`), so the accounting document (and any reversal) joins the chain
  — or renders `NOT_LINKED/NOT_POSTED` honestly when there's no FI hit.
- **Names where it stalled** — the first unhealthy or missing-expected-successor node,
  citing the decoded status ("invoice posted but no FI document — not posted to accounting").
- **Doubles as a /sap-diagnose evidence source** (`--evidence-dir`): emits
  `evidence_docflow.json` (source `DOCFLOW`) so incident triage gets the business-document
  dimension it otherwise lacks — a bare `--object VBELN:<key>` fans into the flow.

## Honest by construction

Key not found → `DOCFLOW_NOT_FOUND`. An ambiguous number (exists as >1 category) →
interactive prompt, or skipped-with-reason in reader mode. A node whose status table is
unreadable → `COULD_NOT_CHECK`, never rendered healthy. The node cap → `truncated=true`,
surfaced loudly. A missing FI document → `NOT_LINKED`, never guessed.

## Reads

`VBFA` (flow), `VBAK`/`LIKP`/`VBRK` (headers + S/4 status), `VBUK` (ECC status), `BKPF`
(FI hop), `DD03L` (release probe). All FMODE=R / TRANSP. `--items` (VBUP/VBAP),
`--clearing` (BSEG — CLUSTER on ECC), `accounting` reverse entry, and `po` P2P are the
next phases.

Read-only; no GUI, no Z-object, no dev-init — safe to point at production, same posture as
/sap-diagnose. Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP): a full O2C chain
decoded on each release, with the invoice→FI BKPF hop resolving the accounting document.
