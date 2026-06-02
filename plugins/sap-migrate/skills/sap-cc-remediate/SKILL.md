---
name: sap-cc-remediate
description: |
  Remediates the campaign's TRIAGED R1 objects and records the outcome. This is
  the only sap-migrate skill that changes SAP — and it does so ONLY on the
  sandbox, ONLY for tier-R1 objects, and ONLY after a mandatory dry-run review.
  Three actions:
    apply  — DRY-RUN (R1): for each TRIAGED R1 object, apply the deterministic R1
             rule pack (migration_rules_r1.tsv) to the downloaded source and write
             <obj>.after.abap + <obj>.diff + a fixlog row. AUTO rules rewrite;
             FLAG rules only report (no change). Nothing is deployed; state is
             unchanged. The operator reviews the diffs — that is the gate.
    assist — R2/R3: assemble a per-object context bundle (<obj>.context.md) from
             the matched recipe + object/field/API maps + the findings + source,
             for the AI to produce a recipe-faithful rewrite. No rewrite, no SAP;
             DRAFT patterns are flagged advisory-only.
    record — after the operator deploys the approved <obj>.after.abap (via
             /sap-se38|37|24 -> /sap-activate-object -> /sap-atc re-check) and
             passes an outcomes file, advance state TRIAGED -> REMEDIATED
             (deployed) / -> VERIFIED (ATC clean) and stamp the fixlog.
  R1 is deterministic (apply). R2/R3 (data-model / HANA) are AI-reasoned: assist
  prepares the context, the AI rewrites per the recipe, and a human reviews
  before deploy — never auto-applied. Objects with tier '?' (unclassified) and
  DRAFT-pattern findings are advisory-only per the pack rules. Run after
  `/sap-cc-triage`.
  Prerequisites: downloaded source for each R1 object; deploy/activate happen via
  the delegated workbench skills on the sandbox system.
argument-hint: "<apply|assist|record> --campaign <id> [--rules <path>] [--knowledge <dir>] [--source-dir <dir>] [--limit <n>] [--results <path>]"
---

# SAP Custom-Code Migration — Remediate (R1)

You apply the mechanical S/4 fixes to the triaged R1 objects, show the operator
exactly what would change (dry-run), and — only after approval and a real
sandbox deploy + ATC re-check — record the result. Safety first: never deploy
without the dry-run gate; never auto-touch anything above R1.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. This is an explicit remediation skill; it deploys (to the sandbox) only after operator approval at the dry-run gate. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging. |
| `<SKILL_DIR>/references/sap_cc_remediate.ps1` | *(invoke)* | Offline engine: `apply` (rule-pack dry-run) + `record` (state/fixlog advance). |
| `<SKILL_DIR>/references/migration_rules_r1.tsv` | *(read)* | Deterministic R1 transforms. `mode` AUTO (rewrite) / FLAG (report only). Customer override via `--rules {custom_url}\knowledge\migration_rules_r1.tsv`. |
| `<SKILL_DIR>/../../shared/knowledge/recipes/<pattern>.md` | *(read)* | Recipe guidance for R2/R3 (AI-assisted) remediation. |
| `/sap-se38` `/sap-se37` `/sap-se24` | *(skills)* | Download source + deploy the approved `<obj>.after.abap`. |
| `/sap-activate-object`, `/sap-atc`, `/sap-fix-abap` | *(skills)* | Activate, ATC re-check (variant `S4HANA_READINESS`), and assist on syntax. |

Workspace contract (`remediation\*`, `fixlog.tsv`, REMEDIATED/VERIFIED states)
is defined by `/sap-cc-campaign`. This skill **owns** `remediation\`.

> The helper itself is offline (files only). All SAP writes happen through the
> delegated workbench skills, on the **sandbox** profile, gated by the dry-run
> review.

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{WORK_TEMP}` and `{CAMPAIGN_DIR}` = `{work_dir}\migrations\{campaign-id}`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_cc_remediate_run.json" -Skill sap-cc-remediate -ParamsJson "{}"
```

---

## Step 1 — Download source for the R1 objects

The dry-run needs each R1 object's active source at
`{CAMPAIGN_DIR}\remediation\<obj_name>.before.abap`. The TRIAGED R1 set is the
objects with `state=TRIAGED` and `tier=R1` in `state.tsv`. For each, download
the source from the **sandbox** via the matching workbench skill
(`/sap-se38` / `/sap-se37` / `/sap-se24` check-and-fix download), saving it as
`<obj_name>.before.abap`.

---

## Step 2 — Dry-run apply (the gate)

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_remediate.ps1" -Action apply -CampaignDir "{CAMPAIGN_DIR}"
```

Add `-Limit <n>` for a first controlled batch, or `-Rules "{custom_url}\knowledge\migration_rules_r1.tsv"` for a customer pack. Output:

```
OBJ: <name> | STATUS: <DRYRUN_CHANGED|FLAGGED|NO_RULE_HIT|SOURCE_MISSING> | AUTO: <n> | FLAG: <n>
APPLY: objects=<n> changed=<n> flagged=<n> norule=<n> missing=<n>
STATUS: OK | EMPTY | ERROR
```

It writes `remediation\<obj>.after.abap` and `remediation\<obj>.diff`. **Present
the diffs to the operator and get explicit approval before any deploy.**
`FLAGGED` objects have FLAG-only hits (e.g. offset/length on a MATNR field) that
need manual judgment — do not auto-deploy those.

| Exit | Meaning |
|---|---|
| `0` | `STATUS: OK` — dry-run written. |
| `1` | No TRIAGED R1 objects (run `/sap-cc-triage`, or all R1 done). |
| `2` | Bad workspace or rule pack (see `ERROR:`). |

---

## Step 2b — R2/R3 remediation (AI-assisted, recipe-guided)

For TRIAGED objects with tier R2 (data-model) or R3 (HANA), the fix is reasoned,
not mechanical. Assemble the per-object context bundle:

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_remediate.ps1" -Action assist -CampaignDir "{CAMPAIGN_DIR}"
```

(Optionally `-KnowledgeDir "{custom_url}\knowledge"` for a customer pack, `-Limit <n>`.)
For each R2/R3 object it writes `remediation\<obj>.context.md` containing: the
object's findings, the matched recipe(s), the object/field/API maps for those
patterns, and the source. Output:

```
OBJ: <name> | TIER: <R2|R3> | PATTERNS: <...> | CONTEXT: <AI_CONTEXT_READY|AI_CONTEXT_DRAFT|SOURCE_MISSING>
ASSIST: objects=<n> ready=<n> draft=<n> missing=<n>
```

Then, per object (you, the AI, do this):
1. Read `<obj>.context.md` and rewrite the source **following the recipe + maps** —
   e.g. redirect stock reads to `NSDM_V_*`, add `ORDER BY` only where order is
   relied upon, route FI postings through the accounting BAPI.
2. Write the rewrite to `remediation\<obj>.after.abap` and a short rationale to
   `remediation\<obj>.rationale.md`.
3. **Never rewrite a write-path to a stock/FI base table** — escalate to MANUAL.
   **DRAFT** patterns (`AI_CONTEXT_DRAFT`) are advisory-only: verify the mappings
   on the target release and get functional sign-off before trusting them.
4. **Mandatory human review** of the diff. Then deploy + record exactly like R1
   (Step 3 + Step 4).

---

## Step 3 — Deploy approved fixes (delegated, on the sandbox)

For each approved `<obj>.after.abap`:
1. Deploy via `/sap-se38` / `/sap-se37` / `/sap-se24` (to the **sandbox**).
2. Activate via `/sap-activate-object`; use `/sap-fix-abap` if a syntax issue
   surfaces.
3. Re-run readiness ATC via `/sap-atc <type> <name> S4HANA_READINESS` and confirm
   the original finding(s) cleared.

Build an outcomes TSV — `obj_name`, `obj_type`, `outcome`
(`VERIFIED` = deployed + ATC clean / `DEPLOYED` = deployed, recheck pending /
`FAILED`).

---

## Step 4 — Record outcomes

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_remediate.ps1" -Action record -CampaignDir "{CAMPAIGN_DIR}" -ResultsFile "<outcomes.tsv>"
```

Advances state TRIAGED → REMEDIATED (DEPLOYED) / → VERIFIED (VERIFIED) and stamps
`remediation\fixlog.tsv`. Output: `RECORD: verified=<n> remediated=<n> failed=<n>`.
Then `/sap-cc-campaign report` / `next` (→ transport bundle for VERIFIED objects).

---

## Step 5 — Outputs (campaign workspace)

- `remediation\<obj>.before.abap` / `.after.abap` / `.diff` — per-object dry-run artifacts.
- `remediation\fixlog.tsv` — `obj_name · obj_type · status · auto_changes · flag_hits · deploy_status · atc_recheck · updated_on · notes`.
- `state.tsv` — R1 objects advanced to REMEDIATED / VERIFIED.

---

## Limitations / Known gaps (draft)

- **R1 only, conservatively.** The seed rule pack auto-rewrites just the
  high-confidence, name-signalled MATNR case; ambiguous matches (offset/length,
  generic CHAR18) are FLAG (report-only). The pack is meant to grow — add AUTO
  rules only when a transform is safe by construction.
- **R2/R3 are AI-assisted, never auto-applied.** `assist` (Step 2b) assembles the
  recipe + map context (`<obj>.context.md`); the AI rewrites and a human reviews
  before deploy. R4, `?`-tier (unclassified), write-paths to base tables, and
  DRAFT-pattern objects are excluded from auto-apply (advisory-only).
- **Deploy is delegated + manual-gated.** The helper never writes to SAP; it
  produces proposals. Deploy/activate/re-check go through the workbench skills on
  the sandbox, only after the operator approves the diffs.
- **The flywheel.** Every approved R2/R3 fix is a candidate to append to the
  knowledge pack (a vetted before/after + real `detect_message_ids`).

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_cc_remediate_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status SKIPPED -ExitCode 1 -ErrorClass CC_REMEDIATE_EMPTY`;
for exit `2` use `-Status FAILED -ExitCode 2 -ErrorClass CC_REMEDIATE_BAD_INPUT`.
