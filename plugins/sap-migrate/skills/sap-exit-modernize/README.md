# sap-exit-modernize

**Convert one classic CMOD function exit into a BAdI implementation — gated,
honest, and never destructive.** The canonical clean-core chore: the skill does
the tedious reads (exit identity, source, project status) and the genuinely hard
AI translation, while the old CMOD project is **never auto-deactivated** — the
pipeline ends by *printing* the `/sap-cmod deactivate` proposal for a human to
run after sign-off. One exit at a time; no new Z objects invented.

```
/sap-exit-modernize <EXIT_FM>                      # full pipeline
/sap-exit-modernize analyze   <EXIT_FM>
/sap-exit-modernize translate <EXIT_FM> [--target <BADI>] [--class ZCL_...]
/sap-exit-modernize deploy    <EXIT_FM>
/sap-exit-modernize verify    <EXIT_FM> [--skip-unit] [--with-atc]
```

## The pipeline

| Stage | What happens |
|---|---|
| `analyze` | RFC, read-only: resolves the exit's identity (MODSAP/MODACT/MODATTR/ENLFDIR), reads its source + ZX include, checks whether a containing CMOD project is active, and gets ranked replacement targets from `/sap-enhancement-advisor`. Owns the **NO_SAFE_TARGET** verdict — if only implicit points / standard-mod remain, translate and deploy refuse. |
| `translate` | An offline classifier flags the constructs with no clean BAdI counterpart — TABLES / COMMON PART globals, SY-* writes, direct standard-table DB writes, `MESSAGE ... RAISING`, PERFORM into the standard program, COMMIT WORK — each becoming a commented `TODO(MANUAL-n)` block; the AI maps the exit signature to the chosen BAdI method around them. The class is syntax-checked with **zero SAP writes**. |
| `deploy` | Confirm-gated: marker_count=0 → a normal yes/no; markers present → a **typed** `DEPLOY <class>` confirmation acknowledging the inert MANUAL sections. All writes are delegated to `/sap-se24` + `/sap-se19`, then verified by an authoritative BADI_IMPL / SXC_EXIT re-read. |
| `verify` | Characterization test via `/sap-gen-abap-unit` (honest **UNVERIFIED** where the logic isn't extractable — never rendered passed), optional `/sap-atc`, an `/sap-evidence-pack` dossier, and the printed deactivate proposal. |

## Prerequisites

- Pinned RFC profile via `/sap-login` (RFC password); SAP NCo 3.1 (32-bit).
- An active SAP GUI session only for the `deploy` / `verify` stages.

## Key files

`references/sap_exit_read.ps1` (analyze RFC reader),
`references/sap_exit_markers.ps1` (offline MANUAL-marker classifier; its
10-assertion corpus lives in `sap_exit_markers.tests.ps1`). Per-exit artifacts
persist under `{work_dir}\exit_modernize\<EXIT_FM>\` (analysis, markers TSV,
translation, mapping, before/after diff) so analyze-today + deploy-tomorrow works.

## Limitations (v1)

- Function exits (`EXIT_*` FMs) only — screen, table, and menu exit components
  are refused (`EXIT_SCOPE_UNSUPPORTED`, v2). One exit per run; batch
  `--project` analyze is v1.5.
- Live-verified on S/4HANA 1909 (S4D): the full analyze chain on
  `EXIT_SAPMV45A_920`, plus the marker classifier's offline corpus (comments
  stripped; Z-table writes allowed, standard-table writes flagged). The deploy
  and verify legs are confirm-gated and delegated — not run autonomously.
- Honesty invariants: `active=COULD_NOT_CHECK` when project status is unreadable;
  a too-complex signature degrades the syntax check to `COULD_NOT_CHECK` (never a
  false-fail); every MANUAL marker is a finding, never dropped.

Part of the sap-migrate plugin (the enhancement-modernization leg of the
clean-core track).
