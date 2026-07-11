---
name: sap-doc-flow
description: |
  Reconstructs the O2C document chain from a bare business-document number and finds
  where it stalled — read-only over RFC (no VA03/VL03N/VF03/FB03 hopping). Walks VBFA in
  both directions from an order/delivery/invoice, decodes every node's status
  release-aware (S/4 in-table VBAK/LIKP/VBRK vs ECC VBUK), follows the invoice into FI via
  BKPF/AWKEY, and writes a flow map + "where it stalled" narrative. Auto-detects the
  document category. Doubles as a /sap-diagnose evidence source (the business-document
  dimension incident triage otherwise lacks). Prerequisites: pinned profile via /sap-login
  (RFC); SAP NCo 3.1 (32-bit). No GUI, no Z-object, no dev-init — safe to point at
  production, same posture as /sap-diagnose.
argument-hint: "<DOCNO>  |  order|delivery|invoice <DOCNO>  [--max-nodes N] [--json] [--no-narrative] [--evidence-dir <RUN_DIR>] [--connection PROFILE]"
---

# SAP Document Flow — O2C Chain & Stall Finder

A support ticket arrives as a bare number ("invoice 90001234 is wrong"). You reconstruct
the whole order→delivery→goods-issue→invoice→accounting chain and name where it stalled —
seconds instead of minutes of VA03/VL03N/VF03/FB03 hopping. Read-only.

Task: $ARGUMENTS

**Pure read-only** (RFC_READ_TABLE only) — no writes, no report execution, no GUI. No
confirm gates. Safe to point at production.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_doc_flow_read.ps1` | `-Category -DocNo [-MaxNodes -NoNarrative -EvidenceDir] -OutDir` | VBFA walker + release-aware decode + BKPF hop |
| `<SKILL_DIR>/references/doc_flow_vbtyp_map.tsv` | map | VBTYP → node category/label |
| `<SKILL_DIR>/references/doc_flow_status_map.tsv` | map | (category, field, value) → health/label |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | Step 5 | Artifact index for /sap-evidence-pack |
| `/sap-diagnose` (evidence consumer) | `--object VBELN:… --reader docflow` | This skill is diagnose's `docflow` reader |

---

## Step 0 — Resolve Work Directory & OUT

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{RUN_TEMP}` via `Get-SapRunTemp`. `{OUT}` = `Get-SapArtifactDir -ScopeKey
DOC_<CATEGORY>_<KEY> -Skill sap-doc-flow`.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_doc_flow_run.json" -Skill sap-doc-flow -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

Bare `<DOCNO>` → `auto`. Explicit `order|delivery|invoice <DOCNO>`. Flags: `--max-nodes N`
(default 200), `--json`, `--no-narrative`, `--evidence-dir <RUN_DIR>` (reader mode for
/sap-diagnose), `--connection PROFILE` (else pinned). `accounting <BELNR> --company
<BUKRS>` and `po <EBELN>` are **v1.5 / v2 (not implemented)** → say NOT_YET_IMPLEMENTED
and STOP. All modes read-only — no confirm-gate step.

## Step 2 — Walk & Decode (RFC)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_doc_flow_read.ps1" -Category <auto|order|delivery|invoice> -DocNo "<DOCNO>" -MaxNodes 200 -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutDir "{OUT}"
```

Add `-EvidenceDir "{RUN_DIR}"` and `-NoNarrative` in diagnose-reader mode. The engine
detects the release schema (DD03L VBAK-GBSTK probe → `SCHEMA: S4|ECC`), ALPHA-pads the
key, auto-detects the category, walks VBFA both directions (visited-set, depth 8,
`--max-nodes`), decodes each node's status release-aware, and follows the invoice into FI.
Parse:

```
SCHEMA: <S4|ECC>
NODE: cat=.. key=.. status=.. health=<OK|OPEN|IN_PROCESS|BLOCKED|CANCELLED|NOT_POSTED|COULD_NOT_CHECK> date=.. detail=".."
EDGE: from=.. to=.. vbtyp=..->..
STALL: node=.. reason=".."
STATUS: OK|DOCFLOW_NOT_FOUND|DOCFLOW_AMBIGUOUS_KEY|RFC_ERROR nodes=.. truncated=<bool> schema=..
```

- `DOCFLOW_NOT_FOUND` (exit 1) → the key is in no SD header; log FAILED, STOP.
- `DOCFLOW_AMBIGUOUS_KEY` (exit 1, only in `--evidence-dir` mode) → the same number exists
  as >1 category; **interactively** (non-reader mode) ask the user which category and
  re-run with it. In reader mode the engine emits skipped-with-reason and stops.
- `truncated=true` → the node cap was hit; surface it **loudly** in map + narrative.
- A node whose header could not be read is `health=COULD_NOT_CHECK` — never rendered
  healthy.

## Step 3 — Render Flow Map + "Where It Stalled" (you write this)

Unless `--no-narrative`, write `docflow_report.md` into `{OUT}` from `docflow_nodes.tsv` +
`docflow_edges.tsv`. **Grounding rule: every node/status traces to a TSV row.**
1. **Flow map** — indented tree / mermaid, each node with a `[health]` badge and its
   decoded status ("order 4969 — completely processed [OK]").
2. **Where it stalled** — the first unhealthy or missing-expected-successor node along
   order→delivery→goods-issue→invoice→accounting, citing the decoded status ("invoice
   90005177 posted (RFBSK=C) but no FI document — not posted to accounting"). State
   `truncated`/`COULD_NOT_CHECK` caveats explicitly.
3. **Release note** — `schema=S4` reads status in-table (VBAK/LIKP/VBRK); `schema=ECC`
   from VBUK — noted so the reader knows the source.

## Step 4 — Register & Log End

Register `docflow_nodes.tsv`/`docflow_edges.tsv` (kind `docflow_map`),
`docflow_report.md` (kind `docflow_report`), and `evidence_docflow.json` (kind
`docflow_evidence`, when `--evidence-dir`) via `Register-SapArtifact` under scope
`DOC_<CATEGORY>_<KEY>`. Emit one finding per stalled/blocked node
(`New-SapFinding`; MEDIUM for BLOCKED/NOT_POSTED, LOW for OPEN; Coverage
`COULD_NOT_CHECK` where a status table was unreadable). Echo:

```
DOCFLOW: anchor=<key> schema=<S4|ECC> nodes=<n> stalls=<n> truncated=<bool>
```

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_doc_flow_run.json" -Status SUCCESS -ExitCode 0
```

`DOCFLOW_NOT_FOUND` / `DOCFLOW_AMBIGUOUS_KEY` end `-Status FAILED` with that class;
`RFC_LOGON_FAILED` on connect failure.

## Step 5 (only `--evidence-dir`) — Confirm Evidence

Confirm `evidence_docflow.json` (source=DOCFLOW, object_keys + explicit_links = every
chain key) so `/sap-diagnose correlate` can join doc-flow nodes to SM13/SLG1/ST22 events
by business key.

---

## Scope & Limitations

- **v1 implemented:** `auto` / `order` / `delivery` / `invoice` — VBFA both-direction walk
  (visited-set, depth 8, `--max-nodes`), release-aware status decode (S/4 in-table vs ECC
  VBUK), invoice→FI BKPF/AWKEY hop, `--evidence-dir` reader mode for /sap-diagnose. Read-only.
- **Release branch is per-system, one reader script**: DD03L VBAK-GBSTK probe (present =
  S/4, absent = ECC) — NOT VBUK existence (VBUK exists on S/4 1909 too). Verified live:
  S4D (S/4HANA 1909, order 720 in-table decode) and ERP (ECC 6, order 4969 → delivery →
  invoice → **FI doc via BKPF hop**, VBUK decode) 2026-07-11.
- **Honesty:** key not found → `DOCFLOW_NOT_FOUND`; ambiguous key → interactive prompt (or
  skipped-with-reason in reader mode); a node whose status table is unreadable →
  `COULD_NOT_CHECK`, never healthy; the node cap → `truncated=true` surfaced loudly; a
  missing FI document → `NOT_LINKED/NOT_POSTED` honestly, never guessed.
- **Not yet:** `--items` (VBUP/VBAP item statuses, v1.5), `--clearing` (BSEG payment depth
  — BSEG is CLUSTER on ECC, PK-scoped reads with COULD_NOT_CHECK degrade, v1.5),
  `accounting <BELNR>` reverse entry (v1.5), `po <EBELN>` P2P via EKBE (v2).
- **/sap-diagnose integration:** registers as the `docflow` reader (evidence source
  `DOCFLOW`) so a bare `--object VBELN:<key>` fans into the business-document dimension
  incident triage otherwise lacks.
