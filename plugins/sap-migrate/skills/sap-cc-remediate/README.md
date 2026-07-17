# sap-cc-remediate

**Apply the mechanical (R1) S/4 fixes on the sandbox — behind the dry-run gate.**
This is the only sap-migrate skill that changes SAP, and it never does so
directly: the helper is offline (files only), all writes go through the
workbench skills (`/sap-se38` / `/sap-se37` / `/sap-se24`) on the **sandbox**
profile, and only after the operator has reviewed the dry-run diffs. Run after
`/sap-cc-triage` (usually via `/sap-cc-campaign next`).

```
/sap-cc-remediate apply  --campaign <id> [--limit <n>] [--rules <path>]   # dry-run (the gate)
/sap-cc-remediate assist --campaign <id> [--knowledge <dir>]              # R2/R3 AI context bundles
/sap-cc-remediate revert --campaign <id> [--objects <a,b>]                # stage a rollback
/sap-cc-remediate record --campaign <id> --results <outcomes.tsv>         # advance campaign state
```

## The four actions

| Action | What it does |
|---|---|
| `apply` | Dry-runs the deterministic R1 rule pack (`references/migration_rules_r1.tsv`) over each TRIAGED R1 object's downloaded source → `<obj>.after.abap` + `.diff` for operator review. Nothing touches SAP. |
| `assist` | For R2/R3 objects: assembles a per-object `<obj>.context.md` (findings + recipe + object/field/API maps + source) for a recipe-faithful AI rewrite — never auto-applied. |
| `revert` | Stages a rollback to the retained before-image (`.revert.abap` + `.revert.diff`); the redeploy goes through the same review → sandbox-guard → delegated-deploy loop as a fix. |
| `record` | After the operator deploys the approved fix + ATC re-check, advances the ledger (TRIAGED → REMEDIATED → VERIFIED) and stamps `fixlog.tsv`. |

## Safety gates (never bypassed)

- **Dry-run review gate** — `record` refuses (`BLOCKED: gate=dryrun_review`,
  exit 3) until the campaign carries an APPROVED `dryrun_review` signoff via
  `/sap-cc-campaign signoff`. A rollback-only results file is the one exemption.
- **Sandbox assertion** — before any deploy, the pinned connection's SID/client
  is mechanically compared to the campaign's `systems.sandbox_profile`
  (`SANDBOX_GUARD: OK` required); any mismatch aborts. Re-run after every
  `/sap-login --switch`.
- **Never auto-apply above R1** — R2/R3 are AI-assisted with mandatory human
  review; R4, unclassified `?` objects, DRAFT-pattern objects, and write-paths
  to stock/FI base tables are excluded from auto-apply (advisory only). FLAG-only
  rule hits (e.g. offset/length on a MATNR field) are report-only, never deployed.
- **Unit-test gate (C9)** — when the migration brief's ABAP-Unit bar is
  mandatory, a `VERIFIED` outcome needs `aunit_status=PASS` from
  `/sap-run-abap-unit`; failing or missing tests hold the object at REMEDIATED
  (never a silent pass).

## Prerequisites

- A TRIAGED campaign workspace (`/sap-cc-triage` has run).
- Each R1 object's source downloaded to `remediation\<obj>.before.abap` via the
  matching workbench skill (also the rollback before-image — never cleaned).
- For deploys: the campaign's sandbox profile saved and pinned via `/sap-login`.

## Key files

`references/sap_cc_remediate.ps1` (the offline engine for all four actions);
`references/migration_rules_r1.tsv` (deterministic R1 transforms, `mode`
AUTO/FLAG; customer override via `--rules {custom_url}\knowledge\migration_rules_r1.tsv`);
`shared/knowledge/recipes/<pattern>.md` (R2/R3 guidance). Outputs live in the
campaign workspace: `remediation\*` (owned by this skill), `fixlog.tsv`, `state.tsv`.

Part of the sap-migrate plugin (the write leg of the `/sap-cc-*` campaign
pipeline).
