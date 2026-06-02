---
name: sap-cc-learn
description: |
  Knowledge-pack flywheel: learns real ATC message ids from a triaged campaign
  and feeds them back into the Simplification Knowledge Pack's
  `catalog.tsv.detect_message_ids`, so future `/sap-cc-triage` runs match by
  message id (the highest-precedence, most reliable basis) and the UNMATCHED
  ratio drops campaign over campaign.
  Two safe sources of new message ids: (1) AUTO -- a message id seen only on
  findings that matched a single pattern is bound to that pattern (ids seen
  across multiple patterns are AMBIGUOUS and skipped); (2) ASSIGN -- the operator
  classifies UNMATCHED message ids to a pattern via an assign file, which apply
  merges. Offline; reads `findings/findings_triaged.tsv` and the pack.
  Run after `/sap-cc-triage` (ideally after the first real ATC-backed run).
  Prerequisites: a triaged campaign (`findings/findings_triaged.tsv`).
argument-hint: "<propose|apply> --campaign <id> [--knowledge <dir>] [--assign <file>] [--top-unmatched <n>]"
---

# SAP Custom-Code Migration — Knowledge-Pack Flywheel

You make the Simplification Knowledge Pack smarter after each campaign: bind the
real ATC message ids you observed to their patterns, and surface the UNMATCHED
ids so they can be classified. The next campaign matches more by message id and
leaves fewer findings UNMATCHED.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging. |
| `<SKILL_DIR>/../../shared/knowledge/catalog.tsv` | *(read/update)* | The pack index. `propose` reads it; `apply` updates `detect_message_ids`. Customer override at `{custom_url}\knowledge\catalog.tsv`. |
| `<SKILL_DIR>/references/sap_cc_learn.ps1` | *(invoke)* | The flywheel engine: propose / apply. |

The pack join contract + flywheel intent are defined in
`shared/knowledge/README.md`. This skill reads the campaign's
`findings/findings_triaged.tsv` (owned by `/sap-cc-triage`).

> Offline skill — no SAP. It only reads the triaged findings + the pack and
> (on `apply`) rewrites `catalog.tsv` (real TABs, UTF-8 no BOM).

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Set `{WORK_TEMP}` and `{CAMPAIGN_DIR}` = `{work_dir}\migrations\{campaign-id}`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_cc_learn_run.json" -Skill sap-cc-learn -ParamsJson "{}"
```

---

## Step 1 — Propose (read-only)

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_learn.ps1" -Action propose -CampaignDir "{CAMPAIGN_DIR}"
```

Output:

```
ADD: pattern=<P> message_id=<M>            # safe: id -> single matched pattern
AMBIGUOUS: message_id=<M> patterns=<...>   # id seen on >1 pattern; skipped
UNMATCHED: message_id=<M> count=<n> sample=<text>
LEARN: add=<n> ambiguous=<n> unmatched_ids=<n> proposal=<path>
STATUS: OK | EMPTY | ERROR
```

It also writes `findings\learn_proposal.md` — a human-readable table with an
**`assign_to_pattern`** column on the UNMATCHED list. Fill that column to
classify the high-count unmatched ids, then turn it into the assign file.

---

## Step 2 — Apply (updates the pack)

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_learn.ps1" -Action apply -CampaignDir "{CAMPAIGN_DIR}" -KnowledgeDir "{custom_url}\knowledge" [-AssignFile "<assign.tsv>"]
```

- Merges the AUTO candidates into `detect_message_ids`.
- With `-AssignFile` (TSV: `message_id<TAB>pattern_id`, header optional), also
  binds the operator-classified UNMATCHED ids — this is what actually cuts the
  UNMATCHED ratio next run.
- **Target the override** (`{custom_url}\knowledge`) so learned ids survive plugin
  updates. Applying to the shipped plugin pack is a maintainer action (improving
  the seed) — the helper prints a NOTE reminding you which you hit. Copy the seed
  `catalog.tsv` to the override first if it doesn't exist yet.

Output: `APPLIED: patterns_updated=<n> message_ids_added=<n> file=<path>`.

| Exit | Meaning |
|---|---|
| `0` | `STATUS: OK` — proposal written (propose) / catalog updated (apply). |
| `1` | No triaged findings (run `/sap-cc-triage`). |
| `2` | Bad workspace / catalog / assign file (see `ERROR:`). |

---

## Step 3 — Outputs

- `{CAMPAIGN_DIR}\findings\learn_proposal.md` — review + classification worksheet.
- `<KnowledgeDir>\catalog.tsv` — `detect_message_ids` enriched (apply only).

After apply, a re-run of `/sap-cc-triage` on the next campaign matches more
findings by message id and reports fewer UNMATCHED.

---

## Limitations / Known gaps (draft)

- **AUTO is single-pattern only.** A message id observed across multiple patterns
  is AMBIGUOUS (a generic check id) and never auto-bound — that would create
  conflicting matches. Only the operator (via `-AssignFile`) can bind such ids,
  and only with knowledge of the specific context.
- **Unmatched classification is human.** The skill surfaces and ranks UNMATCHED
  ids; deciding which pattern each belongs to (or that a NEW pattern/recipe is
  needed) is operator judgment fed back via the assign file.
- **Shipped vs override.** Prefer `{custom_url}\knowledge` for `apply` so learned
  data is yours and update-safe; only edit the shipped pack as a deliberate
  maintainer contribution.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_cc_learn_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status SKIPPED -ExitCode 1 -ErrorClass CC_LEARN_NO_FINDINGS`;
for exit `2` use `-Status FAILED -ExitCode 2 -ErrorClass CC_LEARN_BAD_INPUT`.
