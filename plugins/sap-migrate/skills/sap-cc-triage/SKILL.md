---
name: sap-cc-triage
description: |
  Classifies each S/4-readiness ATC finding into a remediation pattern by
  joining `findings/findings_raw.tsv` against the Simplification Knowledge Pack
  (`shared/knowledge/catalog.tsv`). Writes `findings/findings_triaged.tsv` with
  the pattern, tier (R1 mechanical / R2 data-model / R3 HANA / R4 redesign),
  category, and fixability, then advances each analyzed object to TRIAGED and
  stamps its rolled-up tier in `state.tsv` (so the pipeline can route R1 objects
  to auto-remediation and R2+/unclassified to AI/manual).
  Match precedence per the pack contract: message id > simplification item >
  code regex; ties prefer ACTIVE patterns; unresolved findings are left
  UNMATCHED (fixability=REVIEW) for human triage. Offline (files + the shared
  knowledge pack) — no SAP connection. Run after `/sap-cc-analyze`, before
  `/sap-cc-remediate`.
  Prerequisites: `findings/findings_raw.tsv` from `/sap-cc-analyze` (an empty /
  header-only file is fine -- it means a clean analysis, triaged to tier `-`).
argument-hint: "--campaign <id> [--knowledge <dir>]"
---

# SAP Custom-Code Migration — Triage

You turn raw ATC readiness findings into a routed remediation plan: every
finding gets a **pattern** and **tier**, and every analyzed object gets a
rolled-up tier so `/sap-cc-remediate` knows whether it can auto-fix (R1), needs
AI help (R2/R3), or needs a human (R4 / unclassified).

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging. |
| `<SKILL_DIR>/../../shared/knowledge/catalog.tsv` | *(read)* | The Simplification Knowledge Pack index — the join source (pattern / tier / detect_* / confidence). Customer override at `{custom_url}\knowledge\catalog.tsv`. |
| `<SKILL_DIR>/references/sap_cc_triage.ps1` | *(invoke)* | The classifier: joins findings to the catalog, writes `findings_triaged.tsv`, advances state. |

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

**Knowledge pack resolution:** default is the plugin pack at
`<SKILL_DIR>\..\..\shared\knowledge`. If `{custom_url}\knowledge\catalog.tsv`
exists, pass that folder via `--knowledge` to use the customer's extended pack.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_cc_triage_run.json" -Skill sap-cc-triage -ParamsJson "{}"
```

---

## Step 1 — Pre-flight

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
see the pack's "flywheel"). Then recommend:

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

## Limitations / Known gaps (draft)

- **Seed pack coverage.** The shipped pack has 5 patterns (3 ACTIVE, 2 DRAFT).
  Findings outside those patterns come back UNMATCHED (→ REVIEW) — expected
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
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_cc_triage_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status SKIPPED -ExitCode 1 -ErrorClass CC_TRIAGE_NO_FINDINGS`;
for exit `2` use `-Status FAILED -ExitCode 2 -ErrorClass CC_TRIAGE_BAD_INPUT`.
