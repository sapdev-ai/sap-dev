# sap-cc-triage

**Turn raw S/4-readiness findings into a routed remediation plan.**
`/sap-cc-analyze` leaves you with a flat `findings_raw.tsv`; this skill joins every
finding against the **Simplification Knowledge Pack** (`catalog.tsv`) and writes
`findings_triaged.tsv` — each finding gets a *pattern* and *tier* (R1 mechanical …
R4 redesign), and each object gets a rolled-up tier so `/sap-cc-remediate` knows
whether it may auto-fix (R1), needs AI help (R2/R3), or needs a human (R4 / `?`).
Run after `/sap-cc-analyze`, before `/sap-cc-remediate`.

```
/sap-cc-triage --campaign <id>                              # classify (default)
/sap-cc-triage --campaign <id> --knowledge {custom_url}\knowledge
/sap-cc-triage --learn propose --campaign <id>              # flywheel, read-only
/sap-cc-triage --learn apply --campaign <id> --knowledge {custom_url}\knowledge [--assign <file>]
```

## How findings are matched

Precedence per finding: **message id** > **simplification item** > **code regex**
(a coarse fallback against the message *text*, not the ABAP source); ties prefer
`status=ACTIVE` patterns. No match → `pattern=UNMATCHED`, `fixability=REVIEW`.
Object tier rollup into `state.tsv` (ANALYZED → TRIAGED): clean object → `-`;
**any unclassified finding → `?`** (forces human triage, never auto-remediated);
otherwise the max severity (R4 > R3 > R2 > R1) — an object is auto-remediable
only when *every* finding is a matched R1.

## Flywheel mode (`--learn`)

The pack ships with `detect_message_ids` intentionally blank; `--learn` binds the
real ATC message ids observed in this campaign back into the pack so the *next*
campaign matches more and leaves fewer UNMATCHED. `propose` is read-only (writes
`findings\learn_proposal.md`); `apply` merges AUTO single-pattern ids — an id seen
on more than one pattern is AMBIGUOUS and only an operator `--assign` file can
bind it. Target the `{custom_url}\knowledge` override so learned ids survive
plugin updates.

## What it reads / writes

Offline — no SAP GUI, broker, RFC, or TR. Reads the campaign's
`findings\findings_raw.tsv` plus the plugin pack at `shared/knowledge/`
(customer override: `{custom_url}\knowledge\`); writes
`findings\findings_triaged.tsv` (this skill **owns** it) and advances `state.tsv`.
Engines: `references/sap_cc_triage.ps1` (classify) and
`references/sap_cc_learn.ps1` (flywheel). The join contract lives in
`shared/knowledge/README.md`.

## Coverage honesty (expected UNMATCHED)

The shipped pack is a curated seed — **13 patterns (3 ACTIVE, 10 DRAFT)** — not a
mirror of SAP's ~500-item catalog: expect roughly 20–30% of findings to
auto-classify on a typical brownfield estate. A high unmatched ratio is the
signal to extend the pack (via `--learn` and new recipes), not a bug. DRAFT
patterns are classified and tagged (`status=DRAFT`) but `/sap-cc-remediate`
excludes them from auto-apply — advisory only.

Verified as part of the sap-migrate campaign pipeline: `/sap-cc-campaign report`
rolls `findings_triaged.tsv` up by pattern, and `/sap-cc-campaign next` routes
the R1 work to `/sap-cc-remediate`.
