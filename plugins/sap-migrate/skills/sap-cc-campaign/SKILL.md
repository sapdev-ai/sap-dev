---
name: sap-cc-campaign
description: |
  Owns the S/4HANA custom-code migration *campaign workspace* and is the
  orchestration entry point for the migration engine (sap-migrate plugin).
  Five subcommands:
    (a) init   — create a campaign workspace under {work_dir}\migrations\<id>
                 from the migration Customer Brief (source release, target
                 S/4 release, in-scope packages, decommission policy, the
                 source / sandbox / remote-ATC connection profiles, human
                 gates), seed campaign.json + the empty state ledger.
    (b) status — print per-state / per-tier counts + the headline metrics.
    (c) report — render reports/dashboard.md: the migration dashboard. State +
                 tier + pattern rollup plus five KPIs — decommission savings,
                 ATC-clean rate, auto-fix rate (R1 mechanical, from fixlog.tsv),
                 unresolved/UNMATCHED findings (the human-triage backlog + the
                 /sap-cc-learn feed), and business-owner sign-off status. Every
                 percentage is honest: "n/a" (not 0%) when the underlying ledger
                 hasn't been produced yet.
    (d) next   — recommend the next pipeline skill to run for this campaign,
                 honouring the human-approval gates (scope sign-off, dry-run
                 review).
    (e) signoff— record/update one business-owner sign-off (gate, owner,
                 status, date, note) in campaign.json so the dashboard can show
                 governance status. Offline; the only writer of signoffs[].
  Pure workspace/state/reporting skill — OFFLINE: it never opens a SAP GUI
  session, makes no RFC call, and needs no SAP NCo. It only reads/writes the
  campaign workspace files that the other sap-cc-* skills produce and consume.
  This SKILL.md is the canonical definition of the workspace contract.
  Prerequisites: none (no SAP connection). The downstream skills it sequences
  (/sap-cc-inventory, /sap-cc-usage, /sap-cc-analyze, /sap-cc-triage,
  /sap-cc-remediate) do require SAP access.
argument-hint: "<init|status|report|next|signoff> --campaign <id> [--brief <path>] [--source <profile>] [--sandbox <profile>] [--check-system <profile>] [--target-release <rel>] [--gate <gate>] [--owner <name>] [--signoff-status APPROVED|PENDING|REJECTED] [--note <text>]"
---

# SAP Custom-Code Migration — Campaign Manager

You own the **campaign workspace** for an S/4HANA custom-code migration and
act as the pipeline's orchestration brain. Every other `sap-cc-*` skill writes
into and reads from the workspace you create here; this skill never touches the
SAP system itself. It is fast, offline, and safe to call as often as you like.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules (applies to the downstream skills this one sequences). |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings/`work_dir` resolution contract. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` | *(dot-source)* | `Get-SapSettingValue` — settings merge. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir` — env-aware `work_dir`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging across bash blocks. |
| `<SAP_DEV_CORE_SHARED_DIR>/templates/migration_brief.md` | *(read)* | Migration Campaign Brief (+ `migration_brief_sample.md`); supplies the campaign profile for `init` (resolved via the standard Template Language Resolution order). Distinct from the build-time `customer_brief.md`. |
| `<SKILL_DIR>/references/sap_cc_campaign.ps1` | *(invoke)* | **Companion helper (v1, shipped).** Offline aggregator: performs the atomic `init` write (campaign.json + `state.tsv`), and for `status` / `report` / `next` reads `state.tsv` (+ the triage pattern summary) and emits parseable count / recommendation lines. |

> This skill drives no SAP GUI, so — unlike the deploy skills — it does NOT
> include `language_independence_rules.md`, the session broker, the attach
> library, or any RFC lib. Keep it that way: campaign state is plain files.

---

## Step 0 — Resolve Work Directory and Settings

**Resolve `work_dir` via the env-aware helper** — do NOT read `work_dir` from
`settings.json` directly (that ignores `SAPDEV_AI_WORK_DIR` and `userconfig.json`).
Parse the `WORK_DIR=` line from:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp` and ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates
`{work_dir}\temp\run_<id>`):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Per the CLAUDE.md "Two-bucket temp model" write this skill's per-run scratch
(the log state file below) under `{RUN_TEMP}`, never at a fixed name under the
`{WORK_TEMP}` root.

`{custom_url}` (from the same command) is needed only by `init` to resolve a
customer-overridden migration brief.

---

## Step 0.5 — Start Logging

State file: `{RUN_TEMP}\sap_cc_campaign_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_cc_campaign_run.json" -Skill sap-cc-campaign -ParamsJson "{}"
```

(Pass the parsed args into `-ParamsJson` when convenient, e.g.
`{"sub":"init","campaign":"CCMIG01"}`.)

---

## Step 1 — Parse Arguments & Dispatch

Parse `$ARGUMENTS`:

- **Positional 1** — the subcommand: `init` | `status` | `report` | `next` |
  `signoff`. If missing or unrecognised → print usage (the `argument-hint`) and
  exit `2`.
- `--campaign <id>` — **required for all subcommands.** Validate it matches
  `^[A-Za-z0-9_-]{1,40}$` (it becomes a folder name). On violation exit `2`.
- `init` also accepts: `--brief <path>`, `--source <profile>`,
  `--sandbox <profile>`, `--check-system <profile>`, `--target-release <rel>`.
  These override the corresponding fields read from the brief.
- `signoff` also accepts: `--gate <gate>` (**required** — e.g. `scope_signoff`,
  `dryrun_review`, `go_live`), `--owner <name>`, `--signoff-status <APPROVED|
  PENDING|REJECTED>` (default `APPROVED`), `--note <text>`.

Set `{CAMPAIGN_DIR}` = `{work_dir}\migrations\{campaign-id}`.

For every subcommand except `init`: if `{CAMPAIGN_DIR}\campaign.json` does not
exist, print `ERROR: campaign '<id>' not found — run /sap-cc-campaign init --campaign <id>`
and exit `1`.

Then jump to the matching step below.

---

## Step 2 — Subcommand: `init`

Create the workspace. **Idempotent**: if `{CAMPAIGN_DIR}\campaign.json` already
exists, do NOT overwrite anything — print `EXISTED: campaign '<id>' at {CAMPAIGN_DIR}`
and exit `0`.

1. **Resolve the migration brief.** Order: `--brief <path>` →
   `{custom_url}\migration_brief.md` → built-in
   `<SAP_DEV_CORE_SHARED_DIR>\templates\migration_brief.md` (apply the standard
   language suffix from Template Language Resolution). Read its fields:
   `source_release`, `target_s4_release` + `sp`, `in_scope_packages`,
   `decommission_policy`, `source_profile`, `sandbox_profile`,
   `check_system_profile`, `human_gates`. CLI flags override any field, and
   `init` also runs brief-less — any field absent from both the brief and the
   flags is recorded blank (downstream skills ask when they actually need it).
2. **Build the profile JSON** from the resolved fields (CLI flags override brief
   values), e.g.
   `{"brief_ref":"<path>","systems":{"source_profile":"…","sandbox_profile":"…","check_system_profile":"…"},"target":{"s4_release":"…","sp":"…"},"scope":{"in_scope_packages":["Z*","Y*"],"decommission_policy":"conservative"},"human_gates":{"scope_signoff":true,"dryrun_review":true,"tier_r2_plus":true}}`.
3. **Create the workspace via the helper.** It makes the directory tree, writes
   `campaign.json` (stamping `schema_version` / `created` / `updated` /
   `phase:ASSESS` on top of your profile JSON, then re-parsing to validate) and
   writes the empty `state.tsv` header with **real TAB bytes, UTF-8 no BOM** —
   which is exactly why `init` is delegated rather than hand-written (it sidesteps
   the Write-tool `\t`-literal trap):

   ```bash
   powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_campaign.ps1" -Action init -CampaignDir "{CAMPAIGN_DIR}" -CampaignId "<id>" -ProfileJson "<profile-json>"
   ```

   It is idempotent: an existing `campaign.json` is left untouched and the helper
   prints `EXISTED:`.
4. Echo the helper's `INIT:` / `EXISTED:` line plus the resolved profiles to the
   operator, then exit `0`.

`campaign.json` schema (v1):

```json
{
  "schema_version": 1,
  "campaign_id": "CCMIG01",
  "created": "2026-06-02",
  "updated": "2026-06-02",
  "phase": "ASSESS",
  "brief_ref": "C:\\sap_dev_work\\custom\\migration_brief.md",
  "systems": {
    "source_profile":       "ECCPRD_COPY",
    "sandbox_profile":      "S4DEV",
    "check_system_profile": "S4ATC"
  },
  "target": { "s4_release": "S/4HANA 2023", "sp": "SP02" },
  "scope":  { "in_scope_packages": ["Z*", "Y*"], "decommission_policy": "conservative" },
  "human_gates": { "scope_signoff": true, "dryrun_review": true, "tier_r2_plus": true },
  "signoffs": [
    { "gate": "scope_signoff", "status": "APPROVED", "owner": "Jane PM", "date": "2026-06-03", "note": "approved in CCB" }
  ]
}
```

`signoffs[]` is **optional** and written only by the `signoff` subcommand (Step
6). Each entry: `gate` (key, matches a `human_gates` key or any milestone),
`status` (`APPROVED` / `PENDING` / `REJECTED`), `owner`, `date` (ISO-8601),
`note`. The `report` dashboard renders one row per configured gate, marking it
PENDING until a matching sign-off is recorded.

`phase` ∈ `ASSESS` → `ANALYZE` → `REMEDIATE` → `VALIDATE` → `DELIVER` → `DONE`.
It is a campaign-level rollup recomputed by `status` / `report` / `next` from
the state ledger; `init` always seeds `ASSESS`.

---

## Step 3 — Subcommand: `status`

Print a compact, current state summary.

**Primary path** — run the helper:

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_campaign.ps1" -Action status -CampaignDir "{CAMPAIGN_DIR}"
```

The helper emits parseable lines, then a summary (see *Helper output contract*):

```
STATE: <STATE> | COUNT: <n>
...
TIER: <R1|R2|R3|R4|-> | COUNT: <n>
METRIC: decommission_savings_pct | VALUE: <n>
METRIC: atc_clean_pct | VALUE: <n>          (-1 = n/a: nothing remediated yet)
METRIC: auto_fix_rate_pct | VALUE: <n>      (-1 = n/a: no R1 apply attempts yet)
INFO: auto_fix_rate attempts=<n> auto=<a> excluded=<k> (...)   (denominator audit)
METRIC: unmatched_findings_pct | VALUE: <n> (-1 = n/a: nothing triaged yet)
STATUS: PHASE=<phase> TOTAL=<n> REMEDIATE=<n> DECOMMISSION=<n> REVIEW=<n>
```

**Fallback** (helper not built yet, small campaign < ~500 rows): read
`{CAMPAIGN_DIR}\state.tsv` directly and tally `state` / `tier` yourself. For
larger campaigns the helper is required — do NOT pull thousands of rows into
context; say so and stop.

Render the result as a short table in your reply, plus the `STATUS:` line
verbatim. If `campaign.json.phase` differs from the recomputed phase, update
`campaign.json` (`phase` + `updated`).

Exit `0` on success, `1` if `state.tsv` is empty (nothing inventoried yet —
recommend `/sap-cc-inventory`).

---

## Step 4 — Subcommand: `report`

Same aggregation as `status`, but **also** folds in three more ledgers and
**writes** the rendered dashboard to `{CAMPAIGN_DIR}\reports\dashboard.md`:

- per-pattern counts from `findings\findings_triaged.tsv` (column `pattern`);
- **unresolved findings** = rows with `pattern=UNMATCHED` (the human-triage
  backlog) → an `unmatched_findings_pct` metric + the top UNMATCHED
  `message_id`s (the feed for `/sap-cc-learn`);
- **auto-fix rate** from `remediation\fixlog.tsv` = share of **R1 auto-apply
  attempt rows** the R1 mechanical rules actually rewrote (`auto_changes>0`).
  The denominator counts only rows for ledger-tier-R1 objects with a real apply
  attempt — assist (`AI_CONTEXT_*`) rows, `SOURCE_MISSING` rows, and non-R1
  objects carry `auto_changes=0` by design and are excluded so they cannot
  dilute the management-facing number; the excluded-row count is printed on an
  `INFO: auto_fix_rate attempts=<n> auto=<a> excluded=<k>` line (and shown in
  the dashboard) so the denominator stays auditable;
- **business-owner sign-offs** = `campaign.json.human_gates` cross-referenced
  with the optional `campaign.json.signoffs[]` (PENDING when not recorded).

Every percentage is honest: a metric whose source ledger does not exist yet is
reported as `-1` on the `METRIC:` line and rendered **`n/a`** (never `0%`) in the
dashboard — so "not measured yet" is never mistaken for "perfect / zero".

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_campaign.ps1" -Action report -CampaignDir "{CAMPAIGN_DIR}"
```

Dashboard layout (write this structure to `reports\dashboard.md`):

```
# Migration Campaign <id> — Dashboard (<date>)

Source <source_profile> (<source_release>)  →  Target <s4_release> <sp>
Sandbox <sandbox_profile>   Remote-ATC <check_system_profile>   Phase: <phase>

## Scope
| Decision     | Objects |
|--------------|---------|
| REMEDIATE    |   <n>   |
| DECOMMISSION |   <n>   |  (= <savings>% of in-scope retired without remediation)
| REVIEW       |   <n>   |

## Pipeline state
| State         | Objects |
|---------------|---------|
| INVENTORIED   |  <n>    |
| SCOPED        |  <n>    |
| ANALYZED      |  <n>    |
| TRIAGED       |  <n>    |
| REMEDIATED    |  <n>    |
| VERIFIED      |  <n>    |
| TRANSPORTED   |  <n>    |
| DECOMMISSIONED|  <n>    |

## Remediation by tier   ## Top finding patterns
| Tier | Objects |       | Pattern        | Findings |
|------|---------|       |----------------|----------|
| R1   |  <n>    |       | FIELD_LENGTH   |  <n>     |
| R2   |  <n>    |       | ADD_ORDER_BY   |  <n>     |
| ...  |         |       | ...            |          |

## Key metrics
| Metric | Value |
|--------|-------|
| Decommission savings | <n>% (objects retired without remediation) |
| ATC-clean after remediation | <n>% | n/a |
| Auto-fix rate (R1 mechanical) | <n>% (<auto>/<total> objects rewritten by rule) |
| Unresolved findings (need human triage) | <n>% (<unmatched>/<total> findings UNMATCHED) |

## Unresolved findings (feed for /sap-cc-learn)
| Message id | Findings |   (top UNMATCHED message ids; classify via /sap-cc-learn)
|------------|----------|

## Business-owner sign-offs
| Gate | Status | Owner | Date |   (one row per human gate; PENDING until recorded)
|------|--------|-------|------|
```

The helper also emits parseable lines the orchestrator can surface:
`METRIC: <name> | VALUE: <int>` (four metrics; `-1` = n/a),
`PATTERN: <pattern> | COUNT: <n>`, `UNRESOLVED: <message_id> | COUNT: <n>`, and
`SIGNOFF: gate=<g> status=<APPROVED|PENDING|REJECTED> owner=<o> date=<d>`.

Print `REPORT: wrote {CAMPAIGN_DIR}\reports\dashboard.md` and echo the headline
metrics. Exit `0`.

---

## Step 5 — Subcommand: `next`

Recommend the next pipeline action from the current state, honouring the human
gates in `campaign.json`. This is how an operator (or the future
`cc-migration-engineer` agent) drives the campaign one safe step at a time.

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_campaign.ps1" -Action next -CampaignDir "{CAMPAIGN_DIR}"
```

Recommendation logic (the helper encodes this; documented here as the contract):

| Current situation (from `state.tsv` / files) | NEXT |
|---|---|
| `state.tsv` empty | `/sap-cc-inventory --campaign <id>` |
| Objects `INVENTORIED`, no `decision` set | `/sap-cc-usage --campaign <id>` → then **GATE: scope sign-off** |
| `human_gates.scope_signoff` and scope not yet approved | **PAUSE** — present scope summary; wait for operator approval |
| `REMEDIATE` objects not yet `ANALYZED` | `/sap-cc-analyze --campaign <id>` |
| `ANALYZED` not yet `TRIAGED` | `/sap-cc-triage --campaign <id>` |
| `TRIAGED` R1 objects not yet `REMEDIATED` | `/sap-cc-remediate apply --campaign <id>` (R1 dry-run) → **GATE: dry-run review** → deploy the approved diffs via the workbench skills, then `/sap-cc-remediate record` |
| `REMEDIATED` not `VERIFIED` | re-run `/sap-atc <type> <name> --variant=S4HANA_READINESS` per object, then `/sap-cc-remediate record` with the outcomes (a `FAILED` recheck returns the object to TRIAGED; persistent failures → manual review) |
| `VERIFIED` not `TRANSPORTED` | bundle + release the transport (productionization pipeline) |
| All objects `TRANSPORTED` or `DECOMMISSIONED` | `DONE` — campaign complete |

**Analyze-skipped objects are non-blocking.** A REMEDIATE object whose type has
no ATC category (DEVC, MSAG, bare FUNC) is diverted by `/sap-cc-analyze` to
`findings\analyze_skipped.tsv` and left `SCOPED` (it can never be analyzed). The
recommender excludes such objects from the "await analysis" count — so `next`
advances to `/sap-cc-triage` instead of looping on `/sap-cc-analyze` — **and**
from the DONE check, so the campaign still converges (DONE notes `(<n> skipped:
no ATC category)`). They remain visible as `SCOPED` in `status`/`report`; the
reason is in `analyze_skipped.tsv`.

The helper prints exactly one line:
`NEXT: skill=<skill-or-DONE-or-PAUSE> reason=<short> [gate=<scope_signoff|dryrun_review>]`

Surface that recommendation to the operator. **Never auto-run a downstream
write skill past a gate** — at a gate, stop and ask for explicit approval.
Exit `0`.

---

## Step 6 — Subcommand: `signoff`

Record (or update) one business-owner sign-off so the dashboard can show
governance status against the campaign's human gates. This is the **only**
writer of `campaign.json.signoffs[]`. Upsert is by `gate` — re-running for the
same gate replaces that entry (e.g. PENDING → APPROVED, or a re-approval after
scope change).

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_campaign.ps1" -Action signoff -CampaignDir "{CAMPAIGN_DIR}" -Gate "<gate>" -Owner "<name>" -SignoffStatus <APPROVED|PENDING|REJECTED> -Note "<text>"
```

- `--gate` is **required** (helper exits `2` without it). Convention: use the
  gate keys the pipeline already understands — `scope_signoff`, `dryrun_review`
  — plus any milestone you want to track (e.g. `go_live`). A sign-off for a gate
  that isn't in `human_gates` is still recorded and shown (extra approval).
- The helper stamps today's date, validates `campaign.json` re-parses after the
  write, and prints `SIGNOFF: gate=<g> status=<s> owner=<o> date=<d>`.
- This is a **governance record**, not an enforcement gate: it does not unblock
  `next` (the operator still approves interactively at the gate). It makes "who
  approved what, when" visible on the dashboard.

Exit `0` on success; `2` on missing `--gate` or workspace I/O failure.

---

## The Campaign Workspace (canonical contract)

Everything the migration engine produces lives under one folder. This skill
owns the folder, `campaign.json`, and the `state.tsv` ledger; each other skill
owns its detail file(s) and **upserts the `state` of every object it touches**.

```
{work_dir}\migrations\{campaign_id}\
  campaign.json                     # master profile + phase   (owner: THIS skill)
  state.tsv                         # per-object state ledger   (owner: THIS skill; upserted by all)
  inventory.tsv                     # all in-scope Z/Y objects  (owner: /sap-cc-inventory)
  usage.tsv                         # object -> used?/exec count(owner: /sap-cc-usage)
  scope.tsv                         # REMEDIATE|DECOMMISSION|REVIEW (owner: /sap-cc-usage)
  findings\findings_raw.tsv         # ATC S/4-readiness export  (owner: /sap-cc-analyze)
  findings\findings_triaged.tsv     # + tier/pattern/fixability (owner: /sap-cc-triage)
  remediation\{obj}.before.abap     # pre-fix snapshot          (owner: /sap-cc-remediate)
  remediation\{obj}.after.abap      # post-fix source           (owner: /sap-cc-remediate)
  remediation\fixlog.tsv            # per-object fix result      (owner: /sap-cc-remediate)
  reports\dashboard.md              # rendered dashboard        (owner: THIS skill)
  logs\                             # JSONL run logs (sap_log_lib)
```

**`state.tsv`** (the single source of truth for progress; tab-separated, UTF-8
no BOM, header row first):

| Column | Meaning |
|---|---|
| `obj_name` | Repository object name (key, with `obj_type`) |
| `obj_type` | `PROG` / `FUGR` / `CLAS` / `INTF` / `FUNC` / DDIC kinds / … |
| `state` | One of the states below |
| `tier` | `R1`–`R4` once triaged, else `-` |
| `decision` | `REMEDIATE` / `DECOMMISSION` / `REVIEW` once scoped, else `-` |
| `updated_on` | ISO-8601 date of the last transition |

**Object state machine** (each downstream skill advances its objects; this
skill only reads to roll up):

```
NEW
 └─ INVENTORIED            (/sap-cc-inventory)
      └─ SCOPED ───────────(/sap-cc-usage; decision=REMEDIATE)
      │     └─ ANALYZED ───(/sap-cc-analyze)
      │           └─ TRIAGED ──(/sap-cc-triage; sets tier)
      │                 └─ REMEDIATED ──(/sap-cc-remediate)
      │                       └─ VERIFIED ──(ATC re-check clean)
      │                             └─ TRANSPORTED   [terminal]
      ├─ DECOMMISSIONED     (/sap-cc-usage; decision=DECOMMISSION) [terminal]
      └─ REVIEW             (/sap-cc-usage; decision=REVIEW — operator decides)
```

Upsert rule for all skills: match on `(obj_name, obj_type)`; replace the row's
`state` / `tier` / `decision` / `updated_on`; never duplicate a key.

---

## Helper output contract (`references/sap_cc_campaign.ps1`)

CLI: `-Action <init|status|report|next|signoff> -CampaignDir <abs-path>
[-CampaignId <id>] [-ProfileJson <json>] [-Gate <g>] [-Owner <o>]
[-SignoffStatus <APPROVED|PENDING|REJECTED>] [-Note <t>]`.
Emits parseable lines (one fact per line, `KEY: value | KEY: value`) — `STATE:`,
`TIER:`, `DECISION:`, `METRIC:` (names `decommission_savings_pct`,
`atc_clean_pct`, `auto_fix_rate_pct`, `unmatched_findings_pct`; `-1` = n/a),
`INFO:` (`auto_fix_rate attempts=<n> auto=<a> excluded=<k> …` — the audit line
for the auto-fix denominator), `PATTERN:`, `UNRESOLVED:`, `SIGNOFF:`, `NEXT:`,
`INIT:`/`EXISTED:`/`REPORT:` — followed by a single `STATUS:` summary line. Exit codes `0` ok / `1` gaps (e.g.
empty ledger) / `2` error (bad/missing workspace, missing `--gate`). It performs
no SAP I/O. Keep the line grammar stable — the subcommands and `/sap-log-analyze`
parse it.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success (`INIT` / `EXISTED` / `STATUS` / `REPORT` / `NEXT` emitted). |
| `1` | Campaign not found, or ledger empty / pipeline gap that needs the recommended next skill. |
| `2` | Bad arguments, invalid campaign id, or workspace I/O failure. |

---

## Limitations / Known gaps (draft)

- **Companion helper shipped (v2).** `references/sap_cc_campaign.ps1` implements
  `init` / `status` / `report` / `next` / `signoff`. The `report` dashboard now
  carries the full KPI set (decommission savings, ATC-clean, **auto-fix rate**
  from `fixlog.tsv`, **unresolved/UNMATCHED** from `findings_triaged.tsv`, and
  **business-owner sign-off** status), each rendered `n/a` until its ledger
  exists. The R2–R4 remediation tiers and some sap-cc-* skills are still
  evolving — so `next` recommends `MANUAL` once the R1 / decommission work is
  exhausted.
- **Sign-off is a governance record, not an enforcement gate.** `signoff`
  records who approved a gate for the dashboard; it does not unblock `next`
  (the operator still approves interactively). The `report` dashboard cross-
  references `human_gates` against `signoffs[]` so unrecorded gates show PENDING.
- **Migration brief shipped.** `migration_brief.md` (+ `migration_brief_sample.md`)
  ships in `shared/templates`; `init` reads it, or runs brief-less from CLI flags
  (absent fields recorded blank rather than failing). The `_JA` variant is
  pending — override at `{custom_url}` until it ships.
- **Single-system-pair per campaign.** One source / sandbox / check-system
  triple per campaign id. Multi-track conversions = one campaign id per track.
- **Reporting is rollup-only.** This skill never edits detail files
  (`inventory.tsv`, `findings_*`, `fixlog.tsv`) — it only reads them and owns
  `campaign.json` + `state.tsv`. Drill-down stays in the owning skill.
- **No SAP verification.** `next` recommends from local state; it does not
  re-confirm object existence on the live system (the downstream skills do).

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_cc_campaign_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status FAILED -ExitCode 1 -ErrorClass CC_CAMPAIGN_GAP`; for
exit `2` use `-Status FAILED -ExitCode 2 -ErrorClass CC_CAMPAIGN_BAD_INPUT`.
