---
name: sap-cc-triage
description: |
  Two modes for an S/4HANA migration campaign's readiness findings.
  Default — CLASSIFY: joins findings/findings_raw.tsv against the Simplification
  Knowledge Pack (catalog.tsv) and writes findings/findings_triaged.tsv with each
  finding's pattern + tier (R1 mechanical … R4 redesign) + fixability, then advances
  each object to TRIAGED with a rolled-up tier (routing R1 to auto-remediation,
  R2+/unclassified to AI/manual). Match precedence: message id > simplification item
  > code regex; no match → UNMATCHED (REVIEW). Run after /sap-cc-analyze, before
  /sap-cc-remediate.
  --learn — the knowledge-pack FLYWHEEL (absorbed from the former /sap-cc-learn):
  learns real ATC message ids from the triaged findings back into the pack's
  detect_message_ids so future runs leave fewer UNMATCHED (`propose` = read-only,
  `apply` merges + operator --assign into catalog.tsv). Offline.
  Prerequisites: classify needs findings_raw.tsv (/sap-cc-analyze); --learn needs
  findings_triaged.tsv (a prior classify run).
argument-hint: "--campaign <id> [--knowledge <dir>]  |  --learn <propose|apply> --campaign <id> [--knowledge <dir>] [--assign <file>] [--top-unmatched <n>]"
---

# SAP Custom-Code Migration — Triage

You turn raw ATC readiness findings into a routed remediation plan: every
finding gets a **pattern** and **tier**, and every analyzed object gets a
rolled-up tier so `/sap-cc-remediate` knows whether it can auto-fix (R1), needs
AI help (R2/R3), or needs a human (R4 / unclassified).

With **`--learn`** you run the knowledge-pack **flywheel** instead: learn the real
ATC message ids observed in this campaign's triaged findings back into the pack so
the *next* campaign matches more and leaves fewer UNMATCHED. That mode (folded in
from the former `/sap-cc-learn`) is documented in **"Flywheel mode (`--learn`)"**
below.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging. |
| `<SKILL_DIR>/../../shared/knowledge/catalog.tsv` | *(read; `--learn apply` updates)* | The Simplification Knowledge Pack index — the join source (pattern / tier / detect_* / confidence). Classify reads it; `--learn apply` updates its `detect_message_ids`. Customer override at `{custom_url}\knowledge\catalog.tsv`. |
| `<SKILL_DIR>/references/sap_cc_triage.ps1` | *(invoke)* | The classifier: joins findings to the catalog, writes `findings_triaged.tsv`, advances state. |
| `<SKILL_DIR>/references/sap_cc_learn.ps1` | *(invoke, `--learn`)* | The flywheel engine: `propose` (read-only) / `apply` (updates the pack's `detect_message_ids`). |

Workspace contract (`findings/findings_triaged.tsv` `pattern` column, the
TRIAGED state) is defined by `/sap-cc-campaign`; the knowledge-pack join
contract is defined in `shared/knowledge/README.md`. This skill **owns**
`findings/findings_triaged.tsv`.

> Offline skill — no SAP GUI / broker / attach / RFC / TR. It reads the
> per-campaign findings + the plugin-shared knowledge pack and writes files.

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp` (create if needed) and
`{CAMPAIGN_DIR}` = `{work_dir}\migrations\{campaign-id}`.

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates
`{work_dir}\temp\run_<id>`):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Per the CLAUDE.md "Two-bucket temp model" write this skill's per-run scratch
(the log state file below) under `{RUN_TEMP}`, never at a fixed name under the
`{WORK_TEMP}` root.

**Knowledge pack resolution:** default is the plugin pack at
`<SKILL_DIR>\..\..\shared\knowledge`. If `{custom_url}\knowledge\catalog.tsv`
exists, pass that folder via `--knowledge` to use the customer's extended pack.

---

## Step 0.5 — Start Logging

State file: `{RUN_TEMP}\sap_cc_triage_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_cc_triage_run.json" -Skill sap-cc-triage -ParamsJson "{}"
```

---

## Step 1 — Pre-flight & mode dispatch

**Mode dispatch.** If `--learn <propose|apply>` is present, skip the classify
steps (2–4) and jump to **"Flywheel mode (`--learn`)"** below. Otherwise run the
default CLASSIFY flow (Steps 2–4).

CLASSIFY inputs:
- `--campaign <id>` — **required.** Needs `{CAMPAIGN_DIR}\findings\findings_raw.tsv`
  (from `/sap-cc-analyze`). If missing, stop and run analyze first.
- `--knowledge <dir>` — optional knowledge-pack override (default: the plugin
  pack; or `{custom_url}\knowledge`).

---

## Step 2 — Run the Classifier

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_triage.ps1" -CampaignDir "{CAMPAIGN_DIR}"
```

Add `-KnowledgeDir "{custom_url}\knowledge"` to use a customer-extended pack.
(Plain `powershell` — offline, no NCo.)

**Join contract** (from `shared/knowledge/README.md`): each finding matches a
catalog pattern by **message id**, else **simplification item**, else
**code regex** (coarse fallback against the message text); ties prefer
`status=ACTIVE`. The chosen pattern supplies `pattern` / `tier` / `category` /
`fixability` (= `confidence_default`) / `recipe_ref`. No match →
`pattern=UNMATCHED`, `fixability=REVIEW`.

**Object tier rollup** (written to `state.tsv`): clean object (no findings) →
`-`; **any unclassified finding → `?`** (forces human triage, never
auto-remediated); all findings matched → max severity (R4>R3>R2>R1).

---

## Step 3 — Interpret the Output

```
TRIAGE: findings=<n> matched=<n> unmatched=<n> objects=<n> file=<path>
CLEAN: ...                          # only when analyze produced 0 findings
PATTERN: <pattern_id> | COUNT: <n>
TIER: <R1|R2|R3|R4> | COUNT: <n>
STATUS: OK | EMPTY | ERROR
```

| Exit | Meaning |
|---|---|
| `0` | `STATUS: OK` — `findings_triaged.tsv` written, state advanced to TRIAGED. **A clean campaign (analyze produced 0 findings) also exits 0** — every analyzed object is triaged clean (tier `-`) and a `CLEAN:` line is emitted. |
| `1` | `findings_raw.tsv` missing — `/sap-cc-analyze` has not run yet. |
| `2` | Bad workspace, missing knowledge catalog, or unreadable findings (see `ERROR:`). |

Report the pattern + tier breakdown and the `unmatched` count (a high unmatched
count means the pack needs new `detect_message_ids` from this release's ATC run —
feed them back with `--learn`; see "Flywheel mode" below). Then recommend:

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\..\sap-cc-campaign\references\sap_cc_campaign.ps1" -Action report -CampaignDir "{CAMPAIGN_DIR}"
```

`/sap-cc-campaign report` rolls `findings_triaged.tsv` up by `pattern`; then
`/sap-cc-campaign next` routes to `/sap-cc-remediate` for the R1 work.

---

## Step 4 — Outputs (campaign workspace)

- `{CAMPAIGN_DIR}\findings\findings_triaged.tsv` — per-finding:
  `…the 9 raw columns… · pattern · tier · category · fixability · est_effort · recipe_ref · match_basis · status`.
- `{CAMPAIGN_DIR}\state.tsv` — analyzed objects advanced ANALYZED → TRIAGED with
  the rolled-up `tier`.

---

## Flywheel mode (`--learn`) — knowledge-pack feedback

Run only when `--learn <propose|apply>` is passed. This is the knowledge-pack
flywheel (folded in from the former `/sap-cc-learn`): it binds the real ATC message
ids observed in this campaign's `findings/findings_triaged.tsv` to their patterns so
the *next* campaign matches more by message id and leaves fewer UNMATCHED. Offline —
reads the triaged findings + the pack; `apply` rewrites `catalog.tsv` (real TABs,
UTF-8 no BOM). Requires a prior classify run (`findings/findings_triaged.tsv`).

### `--learn propose` (read-only)

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
**`assign_to_pattern`** column on the UNMATCHED list. Fill that column to classify
the high-count unmatched ids, then turn it into the assign file.

### `--learn apply` (updates the pack)

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_learn.ps1" -Action apply -CampaignDir "{CAMPAIGN_DIR}" -KnowledgeDir "{custom_url}\knowledge" [-AssignFile "<assign.tsv>"]
```

- Merges the AUTO candidates into `detect_message_ids`.
- With `-AssignFile` (TSV `message_id<TAB>pattern_id`, header optional), also binds
  the operator-classified UNMATCHED ids — this is what actually cuts the UNMATCHED
  ratio next run.
- **Target the override** (`{custom_url}\knowledge`) so learned ids survive plugin
  updates; applying to the shipped pack is a maintainer action (the helper prints a
  NOTE saying which you hit). Copy the seed `catalog.tsv` to the override first if it
  doesn't exist yet.

Output: `APPLIED: patterns_updated=<n> message_ids_added=<n> file=<path>`.

| Exit (learn) | Meaning |
|---|---|
| `0` | proposal written (propose) / catalog updated (apply). |
| `1` | No triaged findings — run the default classify first. |
| `2` | Bad workspace / catalog / assign file (see `ERROR:`). |

**Only AUTO single-pattern ids are auto-bound.** An id seen across multiple patterns
is AMBIGUOUS and never auto-bound; only the operator (via `-AssignFile`) can bind
such ids or classify UNMATCHED ones — deciding which pattern each belongs to (or that
a NEW pattern/recipe is needed) is human judgment. Prefer `{custom_url}\knowledge`
for `apply` so learned data is yours and update-safe. After apply, a re-run of the
default classify on the next campaign matches more findings by message id.

---

## Limitations / Known gaps (draft)

- **Seed pack coverage.** The shipped pack has 12 patterns (3 ACTIVE, 9 DRAFT
  — see `shared/knowledge/catalog.tsv` / `manifest.json`). Findings outside
  those patterns come back UNMATCHED (→ REVIEW) — expected
  early; the pack grows via its flywheel (real `detect_message_ids` + new
  recipes). A high unmatched ratio is a signal to extend the pack, not a bug.
- **Regex matches message text, not source.** The `detect_code_regex` fallback
  runs against the finding's message text + check id (what `findings_raw` has),
  not the live source line. Message-id / simplification-item matching is the
  reliable path; populate `detect_message_ids` from real runs to reduce regex
  reliance.
- **DRAFT patterns are classified but not auto-applied.** Triage will tag a
  finding with a DRAFT pattern (status column carries `DRAFT`); `/sap-cc-remediate`
  must exclude DRAFT from auto-apply (advisory only) per the pack rules.
- **Object tier is the max severity.** An object with mixed findings rolls up to
  its hardest tier, and any unclassified finding forces `?` — so an object is
  only auto-remediable (R1) when *every* finding is a matched R1.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_cc_triage_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status SKIPPED -ExitCode 1 -ErrorClass CC_TRIAGE_NO_FINDINGS`;
for exit `2` use `-Status FAILED -ExitCode 2 -ErrorClass CC_TRIAGE_BAD_INPUT`.
In `--learn` mode use `CC_LEARN_NO_FINDINGS` (exit 1) / `CC_LEARN_BAD_INPUT` (exit 2).
