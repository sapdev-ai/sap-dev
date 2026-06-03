---
name: sap-cc-analyze
description: |
  Runs the S/4HANA-readiness ATC over a migration campaign's REMEDIATE objects
  and captures per-finding results into `findings/findings_raw.tsv`, advancing
  each analyzed object to ANALYZED.
  The actual ATC run is delegated to the existing `/sap-atc` skill (so this
  skill ships no new GUI scripting). It invokes `/sap-atc --variant=S4HANA_READINESS`
  so the run executes the S/4HANA readiness check variant (NOT the system
  default) -- see Step 2. `/sap-atc` fails loud if that variant's config field
  cannot be located on the connected release, so a non-readiness run can never
  be silently passed off as readiness;
  this skill owns the deterministic spine: `prepare` builds the worklist from
  `scope.tsv`, and `ingest` parses ATC result exports into the campaign's
  findings ledger and advances state. The `ingest` parser is header-tolerant —
  it accepts `/sap-atc` output or a manual ATC "Manage Results" export.
  Run after `/sap-cc-usage` (which marks REMEDIATE/SCOPED), before
  `/sap-cc-triage`.
  Prerequisites: the connected system must offer the `S4HANA_READINESS` check
  variant with the Simplification Database loaded, and `/sap-atc` must be
  working (it needs a one-time Scripting Recorder session per SAP release).
argument-hint: "<prepare|ingest> --campaign <id> [--results <file|dir>] [--limit <n>]"
---

# SAP Custom-Code Migration — S/4 Readiness Analysis

You run S/4HANA-readiness ATC across the campaign's REMEDIATE objects and fold
the findings (with their simplification-item context) into the campaign ledger.
The ATC engine is `/sap-atc`; this skill prepares its worklist and ingests its
results.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging. |
| `<SKILL_DIR>/references/sap_cc_analyze.ps1` | *(invoke)* | Offline spine: `prepare` (scope→worklist) and `ingest` (ATC results→`findings_raw.tsv`, state→ANALYZED). |
| `/sap-atc` | *(skill)* | The ATC engine. Run per worklist object with `--variant=S4HANA_READINESS`. Needs a one-time recorded session per release (see that skill). |

Workspace contract (`findings/findings_raw.tsv` columns, the ANALYZED state)
is defined by `/sap-cc-campaign`. This skill **owns** `findings/findings_raw.tsv`
and `findings/analyze_worklist.tsv`.

> This skill ships **no GUI VBS** — the GUI work is `/sap-atc`'s. Its own helper
> is offline (files only), so it carries no session-broker / attach / Tier-3
> surface.

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp` (create if needed) and
`{CAMPAIGN_DIR}` = `{work_dir}\migrations\{campaign-id}`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_cc_analyze_run.json" -Skill sap-cc-analyze -ParamsJson "{}"
```

---

## Step 1 — Prepare the Worklist

Build the list of REMEDIATE objects that still need analysis (state SCOPED):

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_analyze.ps1" -Action prepare -CampaignDir "{CAMPAIGN_DIR}"
```

Add `-Limit <n>` to cap the batch (useful for a first controlled run). Output:
`WORKLIST: total=<n> file=...analyze_worklist.tsv` plus
`SKIPPED: total=<m> file=...analyze_skipped.tsv` -- objects whose type has no
`/sap-atc` Object-Set category (DEVC, MSAG, bare FUNC) are diverted to the
skipped sidecar and kept OUT of the worklist, so they are not later mis-marked
ANALYZED. Exit `1`/`STATUS: EMPTY` means nothing is in REMEDIATE/SCOPED -- run
`/sap-cc-usage` first (or all objects are already ANALYZED).

---

## Step 2 — Run S/4-readiness ATC (via `/sap-atc`)

`prepare` wrote `analyze_worklist.tsv` with an **`atc_type`** column (the value
`/sap-atc` expects, mapped from the ledger type). For each worklist row, run ATC
on `atc_type` and pass **`--drill`** so `/sap-atc` exports the per-finding TSV
that `ingest` consumes:

```
/sap-atc <atc_type> <obj_name> --variant=S4HANA_READINESS --drill --save-to={CAMPAIGN_DIR}\findings\atc_raw\<obj_name>.txt
```

This writes `<obj_name>.txt.findings.tsv` (PRIO/CHECK_ID/CHECK_TITLE/OBJECT/
LINE/MSG_TEXT). Collect every drill export under one folder, e.g.
`{CAMPAIGN_DIR}\findings\atc_raw\`. Notes:

- **Readiness variant.** Always pass **`--variant=S4HANA_READINESS`** — this is
  the whole point of the analysis step. `/sap-atc` sets that variant on the ATC
  run series; the connected system must offer it as a GLOBAL variant with the
  Simplification Database loaded. Watch the `/sap-atc` `VARIANT:` line: it must
  read `S4HANA_READINESS`, not `SYSTEM_DEFAULT`. `/sap-atc` **fails loud** if it
  cannot locate the variant config field on this release (rather than running
  the default and mislabelling generic findings as readiness) — see that
  skill's Step 4 / "Component IDs". If you hit that error and cannot record the
  field id immediately, the fallbacks are: (a) set the connected system's
  default ATC variant to `S4HANA_READINESS` and run `/sap-atc` WITHOUT
  `--variant=`, or (b) run the readiness ATC manually and drop its per-finding
  export into `atc_raw\` for `ingest`.
- Use the per-finding **drill** export, NOT the run **summary** TXT -- the
  summary has no per-object column, so `ingest` skips it.

- The connected system must offer the **`S4HANA_READINESS`** variant with the
  **Simplification Database** loaded. If your source ECC lacks it, run against a
  prepared sandbox/check system (the campaign's `sandbox`/`check_system`).
- `/sap-atc` requires a one-time **Scripting Recorder** session per release to
  capture its SCI/ATC node + grid IDs — see `/sap-atc` and `/sap-gui-record`.

### Central / remote check system

Readiness checks must run on a system that **has** the S/4 simplification content
— typically NOT the source ECC. Use the campaign's `check_system_profile` (the
hub). Two modes:

1. **Run on the hub (recommended, fully supported).** Before the ATC loop, point
   the session at the check system: `/sap-login --switch <check_system_profile>`.
   `/sap-atc` then runs on the hub, which carries the readiness content. The hub
   must have the code under test (transported/copied in) and its check content
   must be **≥** the target release (version direction: check OLD from NEW).
   When `campaign.json.systems.check_system_profile` is set, prefer this — do NOT
   run readiness ATC on the bare source ECC (it lacks the content; the run would
   fail-loud on the variant or yield nothing useful).
2. **True remote object provider.** If the hub is configured for central ATC
   (tx ATC → Manage System Groupings + an SM59 RFC destination to the source),
   pass `/sap-atc … --object-provider=<DATA_SOURCE_ID>` so the hub analyzes the
   source in place. `/sap-atc` fails loud if the provider isn't configured (it
   never silently runs a local analysis as remote). **Note:** the provider field
   id is unverified (no configured hub was available to record against) — see
   `/sap-atc` "Central / remote ATC".

- **Scale (v1):** this is per-object. For large estates a batched single-object-
  set run is still a documented enhancement (see Limitations).

---

## Step 3 — Ingest the Results

Fold the exports into the campaign ledger and advance state:

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_analyze.ps1" -Action ingest -CampaignDir "{CAMPAIGN_DIR}" -ResultsPath "{CAMPAIGN_DIR}\findings\atc_raw"
```

`-ResultsPath` accepts a single file or a folder. The parser maps common ATC
export headers (object / type / priority / check / line / message / message id /
**simplification item** / **SAP note**) onto the canonical schema; columns it
can't find are left blank. When the export has no object-type column (the
`/sap-atc` drill TSV has `OBJECT` but no type), `ingest` backfills `obj_type`
from the campaign ledger so triage's per-object rollup matches. Output:

```
FINDINGS: total=<n> new=<n> objects_with_findings=<n> file=<path>
PRIORITY: <p> | COUNT: <n>
ANALYZED: <n>
STATUS: OK | EMPTY | ERROR
```

Objects marked ANALYZED = those in the worklist (i.e. actually run) plus any that
produced findings — so a clean object (zero findings) still advances. Re-ingest
is safe (findings dedupe on object|check|line|message-id).

| Exit | Meaning |
|---|---|
| `0` | `STATUS: OK` — findings appended, state advanced. |
| `1` | Nothing to do. |
| `2` | Bad workspace / results path (see `ERROR:`). |

After ingest, recommend triage: `/sap-cc-campaign next` (→ `/sap-cc-triage`).

---

## Step 4 — Outputs (campaign workspace)

- `{CAMPAIGN_DIR}\findings\analyze_worklist.tsv` — `obj_name · obj_type · atc_type` (objects to run, with the mapped `/sap-atc` type).
- `{CAMPAIGN_DIR}\findings\analyze_skipped.tsv` — `obj_name · obj_type · reason` (in-scope objects with no ATC category; left SCOPED, not analyzed).
- `{CAMPAIGN_DIR}\findings\findings_raw.tsv` — `obj_name · obj_type · check_id · priority · line · message_id · message_text · simplification_item · sap_note`.
- `{CAMPAIGN_DIR}\state.tsv` — REMEDIATE objects advanced SCOPED → ANALYZED.

---

## Limitations / Known gaps (draft)

- **Per-object ATC in v1.** The worklist is looped through `/sap-atc` one object
  at a time. A single batched ATC **object set** (one run for many objects) is
  still a scale enhancement (needs its own recorded flow).
- **Central / remote check system supported (see Step 2 "Central / remote check
  system").** Run readiness on the hub via `/sap-login --switch <check_system>`
  (recommended), or — when the hub is configured for central ATC — pass
  `/sap-atc … --object-provider=<id>` for a true remote run. The `--object-provider`
  field id is **unverified** (no configured hub was available to record against);
  the fail-loud guard is verified live, so a misconfigured remote run aborts
  rather than silently running local. Version direction: hub content ≥ target.
- **Simplification-item capture depends on the export.** The
  `simplification_item` / `sap_note` columns are populated only if the ATC
  readiness export includes them; `/sap-atc`'s current count-oriented output may
  not, in which case a per-finding "Manage Results" export is used. Verify on
  first run for your release.
- **Recording debt is inherited from `/sap-atc`.** This skill adds no GUI code,
  but the ATC run it depends on is release-coupled (re-record per release).
- **No re-analysis downgrade.** Objects already past ANALYZED keep their state;
  re-running prepare excludes them.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_cc_analyze_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status SKIPPED -ExitCode 1 -ErrorClass CC_ANALYZE_EMPTY`;
for exit `2` use `-Status FAILED -ExitCode 2 -ErrorClass CC_ANALYZE_BAD_INPUT`.
