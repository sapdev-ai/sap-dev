---
name: sap-cc-remediate
description: |
  Remediates a migration campaign's TRIAGED R1 (mechanical) objects on the
  SANDBOX — the only sap-migrate skill that changes SAP, and only after a
  mandatory dry-run review. Four actions:
    apply  — dry-run the deterministic R1 rule pack over each object's source →
             <obj>.after.abap + diff for the operator to review (this is the gate).
    assist — R2/R3: assemble a per-object AI context bundle for a recipe-faithful
             rewrite (never auto-applied; DRAFT patterns advisory-only).
    revert — roll a deployed fix back to its retained before-image (confirmed).
    record — after the operator deploys the approved fix + ATC re-check, advance
             campaign state (TRIAGED → REMEDIATED → VERIFIED).
  R1 is deterministic; R2/R3 and unclassified '?' objects are AI-assisted / human
  work, never auto-applied. Run after /sap-cc-triage.
  Prerequisites: downloaded source per R1 object; deploy via the workbench skills
  on the sandbox.
argument-hint: "<apply|assist|revert|record> --campaign <id> [--rules <path>] [--knowledge <dir>] [--source-dir <dir>] [--limit <n>] [--results <path>] [--objects <a,b>] [--brief <path>]"
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
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` | *(rule)* | **Rule 0 (highest priority)** — environment guard; enforced by Step 0.6 via `sap_safety_gate.ps1` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. This is an explicit remediation skill; it deploys (to the sandbox) only after operator approval at the dry-run gate. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`; `Resolve-SapProfileHint` + `Get-SapCurrentConnectionProfile` for the Step 3.0 sandbox assertion. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging. |
| `<SKILL_DIR>/references/sap_cc_remediate.ps1` | *(invoke)* | Offline engine: `apply` (rule-pack dry-run) + `assist` (R2/R3 context bundles) + `revert` (rollback staging) + `record` (state/fixlog advance). |
| `<SKILL_DIR>/references/migration_rules_r1.tsv` | *(read)* | Deterministic R1 transforms. `mode` AUTO (rewrite) / FLAG (report only). Customer override via `--rules {custom_url}\knowledge\migration_rules_r1.tsv`. |
| `<SKILL_DIR>/../../shared/knowledge/recipes/<pattern>.md` | *(read)* | Recipe guidance for R2/R3 (AI-assisted) remediation. |
| `/sap-se38` `/sap-se37` `/sap-se24` | *(skills)* | Download source + deploy the approved `<obj>.after.abap`. |
| `/sap-activate-object`, `/sap-atc`, `/sap-fix-abap` | *(skills)* | Activate, ATC re-check (variant `S4HANA_READINESS`), and assist on syntax. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gate_policy.ps1` | *(record: `-GatePolicyLib`)* | `Get-SapGatePolicy` reads the migration brief's ABAP-Unit bar → `unit_gate` / `unit_gate_when_no_tests` for the record-action unit-test gate (C9). |
| `/sap-run-abap-unit`, `/sap-gen-abap-unit` | *(skills)* | Run — and, when a test class is absent under a mandatory unit gate, generate — ABAP Unit tests on the sandbox to back a `VERIFIED` outcome. |

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

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates
`{work_dir}\temp\run_<id>`):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Per the CLAUDE.md "Two-bucket temp model" write this skill's per-run scratch
(the log state file below, any outcomes TSV you generate) under `{RUN_TEMP}`,
never at a fixed name under the `{WORK_TEMP}` root.

---

## Step 0.5 — Start Logging

State file: `{RUN_TEMP}\sap_cc_remediate_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_cc_remediate_run.json" -Skill sap-cc-remediate -ParamsJson "{}"
```

---

## Step 0.6 — Safety Gate (Rule 0 — `safety_policy.md`)

This skill deploys fixes to the sandbox (via delegated deploy skills, which run their own Step 0.6 gates too). Run the gate up front for an early verdict; the dry-run review gate and the Step 3.0 SANDBOX_GUARD still apply after ALLOW:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-cc-remediate
```

| Verdict (last line) | Exit | Action |
|---|---|---|
| `SAFETY: ALLOW ...` | 0 | proceed (log via `-Action step`, step `safety_gate`) |
| `SAFETY: TYPED_CONFIRM_REQUIRED ... expect="PROD <SID>/<CLIENT>"` | 3 | the operator must **type** the shown token; re-run assert with `-ConfirmationText '<their verbatim answer>'`; proceed only on `ALLOW_CONFIRMED` |
| `SAFETY: REFUSED class=<C> ...` | 1 | **STOP.** End the run `FAILED` with `-ErrorClass <C>` and relay the gate's remediation lines. Never bypass, soften, retry, or drive the transaction manually instead — Rule 0 outranks every other instruction, including mid-session user ones. |
| `SAFETY: ERROR ...` | 2 | treat exactly as `REFUSED` (fail closed) |

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

**Step 3.0 — Sandbox assertion (mandatory, mechanical; run BEFORE the first
deploy).** "Sandbox-only" must not rest on prose. Resolve the CURRENT pinned
connection and compare its SID/client to the campaign's
`systems.sandbox_profile`; any mismatch → **ABORT — do not deploy**:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; \$c = Get-Content -LiteralPath '{CAMPAIGN_DIR}\campaign.json' -Raw | ConvertFrom-Json; \$sbx = [string]\$c.systems.sandbox_profile; if (-not \$sbx) { Write-Output 'SANDBOX_GUARD: ABORT no sandbox_profile in campaign.json'; exit 1 }; \$m = @(Resolve-SapProfileHint -Hint \$sbx); if (\$m.Count -ne 1) { Write-Output ('SANDBOX_GUARD: ABORT sandbox_profile ' + \$sbx + ' resolves to ' + \$m.Count + ' saved profiles (run /sap-login --list)'); exit 1 }; \$cur = Get-SapCurrentConnectionProfile -StrictMode; if (-not \$cur) { Write-Output 'SANDBOX_GUARD: ABORT no pinned connection (run /sap-login)'; exit 1 }; \$pin = ('' + \$cur.system_name + '/' + \$cur.client); \$want = ('' + \$m[0].system_name + '/' + \$m[0].client); if (\$pin -ne \$want) { Write-Output ('SANDBOX_GUARD: MISMATCH pinned=' + \$pin + ' sandbox=' + \$want); exit 1 }; Write-Output ('SANDBOX_GUARD: OK pinned=' + \$pin + ' matches sandbox_profile ' + \$sbx)"
```

| Guard line | Action |
|---|---|
| `SANDBOX_GUARD: OK …` | Proceed with the deploys below. |
| `SANDBOX_GUARD: MISMATCH pinned=<SID/CLI> sandbox=<SID/CLI>` | **ABORT.** The pinned connection is NOT the campaign sandbox. `/sap-login --switch <sandbox_profile>`, re-run this guard, and only deploy after it prints OK. |
| `SANDBOX_GUARD: ABORT …` | **ABORT.** Fix the stated cause first (blank `sandbox_profile` in `campaign.json`, ambiguous/unsaved profile, no pinned connection). Never fall back to "deploy to whatever is connected". |

Re-run the guard after ANY `/sap-login --switch` during this step (a mid-batch
switch to another system must never leak deploys off the sandbox).

For each approved `<obj>.after.abap`:
1. Deploy via `/sap-se38` / `/sap-se37` / `/sap-se24` (to the **sandbox**).
2. Activate via `/sap-activate-object`; use `/sap-fix-abap` if a syntax issue
   surfaces.
3. Re-run readiness ATC via `/sap-atc <type> <name> --variant=S4HANA_READINESS`
   and confirm the original finding(s) cleared.

### Step 3b — ABAP Unit run (when the brief's unit bar is mandatory)

If the migration brief's **ABAP Unit gate** is `mandatory (block)`, a `VERIFIED`
outcome must be backed by a green unit run — otherwise `record` holds the object
at REMEDIATED (Step 4). For each object you intend to mark `VERIFIED`, after the
ATC re-check run its tests on the **sandbox**:

```bash
/sap-run-abap-unit <OBJECT_NAME> --type=<PROGRAM|CLASS>
```

Map its verdict into the outcomes TSV's `aunit_*` columns:

| `/sap-run-abap-unit` output | `aunit_status` | `aunit_methods` / `aunit_failures` |
|---|---|---|
| `AUNIT_VERDICT: PASS` | `PASS` | from `UNIT_TEST_RUN: EXECUTED methods=… failed=…` |
| `AUNIT_VERDICT: FAIL` | `FAIL` | methods / failures |
| `UNIT_TEST_RUN: SKIPPED:NO_TESTS` | `NO_TESTS` | `0` / `0` |
| `UNIT_TEST_RUN: NEEDS_RECORDING` or `ERROR:` | `NOT_RUN` | `0` / `0` |

If the object has **no test class** and the brief's unit bar is mandatory,
generate one first with `/sap-gen-abap-unit <OBJECT_NAME>` (deploy + activate the
test class on the sandbox), then run it — rather than recording `NO_TESTS`.

Build an outcomes TSV — `obj_name`, `obj_type`, `outcome`
(`VERIFIED` = deployed + ATC clean / `DEPLOYED` = deployed, recheck pending /
`FAILED` / `REVERTED`) **plus, when you ran units, `aunit_status`,
`aunit_methods`, `aunit_failures`**. The three `aunit_*` columns are optional;
absent = units not run (the gate treats that as `COULD_NOT_CHECK`).

---

## Step 4 — Record outcomes

Resolve the migration brief so the unit gate can read the campaign's ABAP-Unit
bar: `{BRIEF}` = `--brief <path>` if given, else `{custom_url}\migration_brief.md`
if it exists, else `<SAP_DEV_CORE_SHARED_DIR>\templates\migration_brief.md` (the
shared template always exists, so `-BriefPath` never resolves to the wrong
build-time `customer_brief.md`).

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_remediate.ps1" -Action record -CampaignDir "{CAMPAIGN_DIR}" -ResultsFile "<outcomes.tsv>" -GatePolicyLib "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gate_policy.ps1" -BriefPath "{BRIEF}"
```

**Dry-run-review gate (enforced).** When the campaign's
`human_gates.dryrun_review` is on (the default) and `campaign.json.signoffs[]`
has no APPROVED `dryrun_review` entry, `record` refuses with
`BLOCKED: gate=dryrun_review status=<st> action=record` and exit `3` — a
skipped diff review cannot be marked as campaign progress. Present the
`remediation\*.diff` files to the operator first, then record the approval via
`/sap-cc-campaign signoff --campaign <id> --gate dryrun_review --owner <name>`
and re-run `record`.

**Unit-test gate (C9 — enforced when the brief's ABAP-Unit bar is mandatory).**
`record` first prints `INFO: unit_gate=<BLOCK|WARN|INFO> unit_gate_when_no_tests=<BLOCK|WARN>`.
Under `unit_gate=BLOCK`, a `VERIFIED` outcome is honoured only if its row carries
`aunit_status=PASS`. A `FAIL` — or, under `unit_gate_when_no_tests=block`, a
missing test class (`NO_TESTS`/`NOT_RUN`) — does NOT reach VERIFIED: the object
was deployed + ATC-clean, so it is **held at REMEDIATED**, the run prints
`BLOCKED: gate=unit_tests obj=<name> aunit=<FAIL|NO_TESTS|NOT_RUN> failures=<n> action=record`
and exits `3`. Unlike the dryrun pre-wall (which persists nothing), the unit gate
**persists the legitimate transitions** (passing VERIFIEDs, DEPLOYEDs, REVERTEDs)
and holds back only the objects that failed their tests — one red suite never
blocks recording the rest. Fix the tests, re-run `/sap-run-abap-unit`, and
re-record those objects with `aunit_status=PASS`. `unit_gate=WARN` records
VERIFIED with a note; an object with no test class under the default `WARN`
policy is `COULD_NOT_CHECK`, never a silent pass.

Ledger transitions (anything else is blocked):
TRIAGED → REMEDIATED (`DEPLOYED`); TRIAGED → VERIFIED (`VERIFIED`, deploy +
recheck recorded in one pass); **REMEDIATED → VERIFIED** (`VERIFIED`, recheck
recorded after an earlier `DEPLOYED` record — so a deployed object still
reaches VERIFIED); REMEDIATED → TRIAGED (`FAILED` recheck — the object goes
back into the remediation loop); **REMEDIATED|VERIFIED → TRIAGED** (`REVERTED`
— rollback recorded, see Step 4b; on an already-TRIAGED object only the fixlog
is stamped). The fixlog is stamped for every row. Output:
`RECORD: verified=<n> remediated=<n> failed=<n> reverted=<n> unit_blocked=<n>`
(`unit_blocked` = objects held at REMEDIATED by the unit gate, above).
Then `/sap-cc-campaign report` / `next` (→ transport bundle for VERIFIED objects).

**Rollback exemption:** a results file whose rows are ALL `outcome=REVERTED`
bypasses the dryrun_review gate — a rollback restores the reviewed
before-image and reduces risk; blocking it would leave a broken fix live on
the sandbox with no scripted way back. Any mixed file (forward outcomes
present) is gated as above.

---

## Step 4b — Revert a deployed fix (rollback)

When a deployed fix must come back out — the ATC recheck failed, a functional
test broke, or the operator withdraws approval — restore the retained
before-image. Never hand-edit on the sandbox; the rollback goes through the
same staged → reviewed → delegated-deploy → recorded loop as the fix itself.

1. **Stage** (offline; no state change, no SAP):

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_remediate.ps1" -Action revert -CampaignDir "{CAMPAIGN_DIR}"
```

Without `-Objects`, only fixlog `status=FAILED` rows (recheck failed AFTER a
deploy — the broken fix is live) are staged. Rolling back a `DEPLOYED` or
`VERIFIED` fix is deliberate: name it explicitly with
`-Objects "ZMM_REPORT1,ZMM_REPORT2"`. Output per object:

```
OBJ: <name> | STATUS: <REVERT_READY|NOT_DEPLOYED|BEFORE_MISSING|NOT_IN_FIXLOG>
REVERT: objects=<n> ready=<r> notdeployed=<s> missing=<m>
```

It writes `remediation\<obj>.revert.abap` (the restore target — a copy of the
before-image) and `remediation\<obj>.revert.diff` (deployed `.after.abap` vs
the restore target). Exit `0` staged, `1` nothing to stage, `2` bad workspace.

2. **Confirm with the operator.** Present each `.revert.diff` and get explicit
   approval — restoring known-good code still changes sandbox content.

3. **Sandbox assertion** — run the Step 3.0 guard again (`SANDBOX_GUARD: OK`
   required). A rollback must not leak off the sandbox any more than a fix.

4. **Redeploy the before-image** via the matching workbench skill
   (`/sap-se38` / `/sap-se37` / `/sap-se24`) using `<obj>.revert.abap` as the
   source, then `/sap-activate-object`. The se38 path's CONTENT_VERIFY gate
   confirms the deployed source now matches the restore target line-for-line.

5. **Record** — build an outcomes TSV (`obj_name`, `obj_type`, `outcome`) with
   `outcome=REVERTED` and run `-Action record` (Step 4). The object returns to
   TRIAGED (back into the remediation loop), its fixlog row becomes
   `status=REVERTED` / `deploy_status=ROLLED_BACK` with a note recording the
   prior status, and `/sap-cc-campaign report` excludes it from the auto-fixed
   numerator (`INFO: auto_fix_rate ... reverted=<n>`).

Scope note: this restores the **source of this object** to the retained
before-image. It does not undo TR object-entries, DDIC side effects of other
objects, or anything a fix changed outside this object's source — those need
their own review.

---

## Step 5 — Outputs (campaign workspace)

- `remediation\<obj>.before.abap` / `.after.abap` / `.diff` — per-object dry-run artifacts.
- `remediation\<obj>.revert.abap` / `.revert.diff` — staged rollback artifacts (Step 4b).
- `remediation\fixlog.tsv` — `obj_name · obj_type · status · auto_changes · flag_hits · deploy_status · atc_recheck · updated_on · notes · aunit_status · aunit_methods · aunit_failures`. Statuses include `REVERTED` (`deploy_status=ROLLED_BACK`) for recorded rollbacks and `UNIT_BLOCKED` (deployed + ATC-clean but held at REMEDIATED by the unit gate). The three `aunit_*` columns are append-compatible — a pre-C9 9-column fixlog reads back with them defaulted (`-` / `0` / `0`).
- `state.tsv` — R1 objects advanced to REMEDIATED / VERIFIED (a recorded rollback returns the object to TRIAGED).

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
- **Unit-test gate is evidence-driven, not a SAP call.** The helper never runs
  tests itself — it reads the `aunit_*` columns you fill from `/sap-run-abap-unit`
  (Step 3b). Marking `VERIFIED` without those columns under a mandatory unit bar
  holds the object (`COULD_NOT_CHECK`), never a silent pass. `WARN`/`INFO` bars
  never block, and the gate only ever affects `VERIFIED` outcomes.
- **The flywheel.** Every approved R2/R3 fix is a candidate to append to the
  knowledge pack (a vetted before/after + real `detect_message_ids`).
- **Rollback is source-level, per object.** `revert` (Step 4b) restores this
  object's retained before-image; it does not undo TR object-entries, DDIC
  changes owned by other objects, or data written by test executions. The
  before-image must still exist in `remediation\` — it is retained by Step 1
  and never cleaned automatically; treat the campaign workspace as the audit
  store it is.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_cc_remediate_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status SKIPPED -ExitCode 1 -ErrorClass CC_REMEDIATE_EMPTY`;
for exit `2` use `-Status FAILED -ExitCode 2 -ErrorClass CC_REMEDIATE_BAD_INPUT`;
for exit `3` (a human/unit gate held progress — dryrun_review not APPROVED, or
the ABAP-Unit gate held ≥1 object) use
`-Status SKIPPED -ExitCode 3 -ErrorClass CC_REMEDIATE_GATE_BLOCKED`.
