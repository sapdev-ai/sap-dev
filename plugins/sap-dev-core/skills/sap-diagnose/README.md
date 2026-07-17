# SAP Incident Diagnosis Orchestrator Skill

Triage a SAP incident from a single anchor (time window, user, transaction,
background job, business-object key, or a known short dump). The skill fans
out across its read-only evidence readers, correlates the evidence into
incident clusters, and produces ranked root-cause hypotheses with a
recommended fix path. **PURE READ-ONLY** — it never writes to SAP, and is
safe to point at production.

## Skill Overview

1. Parse the natural-language incident + flags into an anchor
2. Resolve the anchor window against the SAP **server** clock (never the
   workstation — a time-zone skew silently returns "no evidence")
3. Select readers from the source matrix by the strongest anchor signal
   (honoring `--sources` and `--depth quick|standard|deep`)
4. Fan out: six internal RFC readers — SM13 update-task failures, SM12 locks,
   SLG1 application log, SM37 jobs, SMQ tRFC/qRFC queues, Gateway/OData
   error-log preflight — plus the GUI dump reader `/sap-st22` (a separate
   skill). A reader that errors or lacks authorization writes a `skipped`
   stub; no source is ever dropped silently
5. Correlate into incident clusters (weighted edges; each cluster carries a
   timeline and an earliest event nearer the root cause)
6. Emit ranked hypotheses (`confidence`, `symptom_vs_root`, `confirm_by` /
   `refute_by`, `recommended_action`) and the deliverable JSON under
   `{work_dir}\diagnose\<incident_id>.json` (`--report` adds a Markdown twin)

## Auto-Trigger Keywords

- `diagnose <incident>`, `triage <incident>`, `root-cause <symptom>`
- "why did the job fail this morning", "user MILLER got a dump in VA01"
- "what happened between 09:00 and 09:30"

## Usage

```text
/sap-diagnose "order save failed for user MILLER around 09:15" --date today
/sap-diagnose --user MILLER --tcode VA01 --date 20260716 --time 09:15 --window 30
/sap-diagnose --job ZNIGHTLY --date today --depth deep --report
/sap-diagnose --reader sm37 --job ZFOO --date today
/sap-diagnose "dump in ZHKR001" --fix
```

Key flags (see `SKILL.md` for the full list):

- `--reader <sm13|sm12|slg1|sm37|smq|gateway|st22>` — run ONE reader
  standalone and just print its evidence (no correlation / hypotheses). This
  replaces the former standalone `/sap-sm13` … `/sap-sm37` skills one-for-one.
- `--fix` — after diagnosis, hand a **custom-code-defect** top hypothesis to
  `/sap-fix-incident` (the gated, write-capable companion). Chaining requires
  your explicit yes; diagnose itself still writes nothing.
- `--remediate` — for lock contention, points at `/sap-sm12 release` (which
  owns its own liveness gate + typed confirmation). For stuck updates it
  surfaces the **manual SM13 steps** — there is no automated reprocess.

## Prerequisites

- A saved `/sap-login` profile (RFC password required)
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC for the RFC readers
- An active SAP GUI session for the ST22 leg (use `/sap-login` first)

## Directory Structure

```
sap-diagnose/
├── SKILL.md
├── README.md
└── references/
    ├── diagnose_evidence_schema.json      # evidence contract every reader emits
    ├── diagnose_source_matrix.tsv         # anchor-signal → reader set
    ├── sap_diagnose_anchor_resolve.ps1    # flags → absolute SERVER-time anchor
    ├── sap_diagnose_correlate.ps1         # deterministic graph + clustering
    ├── sap_diagnose_reader_lib.ps1        # shared reader helpers (dot-sourced)
    ├── sap_sm13_read.ps1                  # update-task failure reader (VBHDR + VBERROR)
    ├── sap_sm12_read.ps1                  # lock-entry reader (ENQUEUE_READ)
    ├── sap_slg1_read.ps1                  # application-log reader (BALHDR)
    ├── sap_sm37_read.ps1                  # background-job reader (TBTCO)
    ├── sap_smq_read.ps1                   # tRFC + qRFC reader
    └── sap_gateway_read.ps1               # Gateway/OData error-log preflight
```

## Limitations

- **No write path under any flag.** Lock release is delegated to
  `/sap-sm12 release`, custom-code fixes to `/sap-fix-incident`, stuck-update
  remediation to manual SM13 — each with its own confirmation gate.
- The `sm21` (system log) source has **no reader yet** — it is named in the
  report's next actions for manual collection.
- The `gateway` reader is a present/absent preflight only; the full OData
  error-log read is owned by `/sap-gateway-service`.
- No performance leg — "slow" routes to `/sap-trace` (a separate skill, not
  auto-chained).
- ST22 selection/grid component IDs vary by release; the reader tries
  candidates and degrades to `skipped` with a `/sap-gui-probe --record` hint.
- Correlation is heuristic: explicit links are ground truth; temporal /
  identity / context edges are confidence-scored — hence the mandatory
  `confirm_by` / `refute_by` on every hypothesis.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
