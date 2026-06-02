---
name: sap-cc-usage
description: |
  Overlays runtime usage data onto the campaign inventory to decide what to
  remediate vs. retire. Joins a usage export onto `inventory.tsv`, applies the
  campaign's decommission policy, writes `usage.tsv` + `scope.tsv`
  (REMEDIATE / DECOMMISSION / REVIEW), and advances `state.tsv`. This is the
  step that produces the headline "X% retired without remediation" number.
  v1 is OFFLINE and file-driven: usage comes from an export
  (`--usage-file`, the SCMON/SUSG/Solution-Manager output) — direct SCMON/UPL
  RFC read is a later increment. SAFETY: the `conservative` policy never
  auto-decommissions; it parks unused objects as REVIEW pending the
  `/sap-where-used-list` reference-safety check (so a still-referenced object is
  never deleted). `aggressive` flags all unused objects DECOMMISSION (no
  reference check — use with care). Run after `/sap-cc-inventory`, before
  `/sap-cc-analyze`.
  Prerequisites: a usage export for FILE source (no SAP connection needed in v1).
argument-hint: "--campaign <id> [--usage-file <path>] [--usage-source FILE|SCMON|NONE] [--policy none|conservative|aggressive] [--min-exec 0]"
---

# SAP Custom-Code Migration — Usage & Decommission Scoping

You decide, for every inventoried custom object, whether it should be
**remediated**, **retired (decommissioned)**, or **reviewed** — by overlaying
how often it actually runs. Retiring dead code is usually the single biggest
scope reduction in a conversion, so this step's savings number matters.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging. |
| `<SKILL_DIR>/references/sap_cc_usage.ps1` | *(invoke)* | Joins usage onto inventory, applies the policy, writes `usage.tsv` + `scope.tsv`, advances `state.tsv`. Emits parseable `USAGE:` / `DECISION:` / `METRIC:` / `STATUS:` lines. |
| `/sap-where-used-list` | *(skill)* | Used in the **reference-safety check** (Step 4) to confirm a REVIEW candidate has no inbound callers among still-used objects before it is decommissioned. |

The workspace contract (`usage.tsv` / `scope.tsv` columns, the
SCOPED / DECOMMISSIONED / REVIEW states, the upsert rule) is defined by
`/sap-cc-campaign`. This skill **owns** `usage.tsv` and `scope.tsv`.

> v1 is an offline file-processing skill — no SAP GUI, broker, attach lib, RFC,
> or TR. The only SAP-touching part is the optional reference-safety check in
> Step 4, which delegates to `/sap-where-used-list`.

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
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_cc_usage_run.json" -Skill sap-cc-usage -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments & Pre-flight

- `--campaign <id>` — **required.** Need both `{CAMPAIGN_DIR}\campaign.json` and
  a populated `inventory.tsv`. If inventory is missing/empty, stop and tell the
  operator to run `/sap-cc-inventory` first.
- `--usage-file <path>` — the usage export (FILE source). Recommended format:
  TSV/CSV, **col1 = object name**, **col2 = exec count**, optional **col3 = last
  used**; a header row is auto-detected. A single-column file (just names) is
  treated as "present = used".
- `--usage-source FILE|SCMON|NONE` — defaults to FILE when `--usage-file` is
  given, else NONE. `SCMON`/`UPL` are not yet read directly (v1 prints a WARN
  and proceeds with no usage data — everything REMEDIATE).
- `--policy none|conservative|aggressive` — defaults to the brief's
  `scope.decommission_policy`, else `conservative`.
- `--min-exec <n>` — "used" means `exec_count > n` (default 0).

---

## Step 2 — Run the Scoping Helper

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_usage.ps1" -CampaignDir "{CAMPAIGN_DIR}"
```

Append any of `-UsageFile "<path>"`, `-UsageSource FILE`, `-Policy conservative`,
`-MinExec 0` to mirror the flags. (Plain `powershell` is fine — v1 needs no NCo.)

**Policy semantics:**

| Policy | used (`exec > min`) | unused | no usage data |
|---|---|---|---|
| `none` | REMEDIATE | REMEDIATE | REMEDIATE |
| `aggressive` | REMEDIATE | **DECOMMISSION** (no reference check) | REMEDIATE |
| `conservative` (default) | REMEDIATE | **REVIEW** (pending reference check) | REMEDIATE |

---

## Step 3 — Interpret the Output

```
USAGE: source=<src> policy=<p> min_exec=<n> matched=<n> file=<path>
USED: <n> | UNUSED: <n> | UNKNOWN: <n>
DECISION: REMEDIATE | COUNT: <n>
DECISION: DECOMMISSION | COUNT: <n>
DECISION: REVIEW | COUNT: <n>
METRIC: decommission_savings_pct | VALUE: <n>
SCOPE: wrote <path>
STATUS: OK | EMPTY | ERROR
```

| Exit | Meaning |
|---|---|
| `0` | `STATUS: OK` — `usage.tsv` + `scope.tsv` written, `state.tsv` advanced. |
| `1` | `STATUS: EMPTY` — inventory empty/missing (run `/sap-cc-inventory`). |
| `2` | `STATUS: ERROR` — bad workspace / usage file / policy (see the `ERROR:` line). |

Report the REMEDIATE / DECOMMISSION / REVIEW split and the savings %.

---

## Step 4 — Reference-safety check (conservative → DECOMMISSION)

This is the **human/where-used gate** that turns REVIEW candidates into safe
DECOMMISSION decisions. For `conservative` runs, before any REVIEW object is
retired, confirm nothing still calls it:

1. For each REVIEW candidate (or a sampled/batched subset), run
   `/sap-where-used-list <object>`.
2. If it has **no** inbound references from objects that are still **used**
   (REMEDIATE in `scope.tsv`), it is safe to retire → the operator promotes it
   to DECOMMISSION.
3. If it IS referenced by a used object, leave it REVIEW (it must be remediated
   or its caller adjusted first).

> v1 performs this gate **manually / operator-driven** (the helper parks unused
> objects as REVIEW and never deletes without it). Automating the batch
> promotion (a `--apply-references` pass over the cross-reference index) is the
> next increment — see Limitations.

After any promotions, re-run `/sap-cc-campaign report` to refresh the dashboard.

---

## Step 5 — Outputs (campaign workspace)

- `{CAMPAIGN_DIR}\usage.tsv` — `obj_name · obj_type · exec_count · last_used_on · usage_source · used_flag` (this skill owns it).
- `{CAMPAIGN_DIR}\scope.tsv` — `obj_name · obj_type · decision · reason · referenced_by_used` (this skill owns it).
- `{CAMPAIGN_DIR}\state.tsv` — decisions set; INVENTORIED objects advanced to SCOPED / DECOMMISSIONED / REVIEW.

---

## Limitations / Known gaps (draft)

- **Usage ingestion is file-based in v1.** Direct SCMON / UPL / SUSG RFC reads
  are deferred (the data structures and access paths vary by release and often
  live in Solution Manager, not the dev box). Export usage centrally and pass
  `--usage-file`. `--usage-source SCMON` currently WARNs and proceeds with no
  usage data.
- **Reference-safety promotion is manual in v1.** `conservative` parks unused
  objects as REVIEW; promoting them to DECOMMISSION via `/sap-where-used-list`
  is operator-driven (Step 4). The automated batch promotion is the next
  increment. `aggressive` decommissions unused objects **without** this check —
  use only when you accept that risk.
- **Name-level matching.** Usage is matched to the top-level object name. If the
  export lists sub-objects (method/FM names), parent usage may be under-counted
  — which errs SAFE (more REVIEW, never wrongful decommission). Rolled-up
  top-level exports give the best results.
- **No downgrade.** Objects already past SCOPED keep their state; the decision
  is still updated and re-running is safe.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_cc_usage_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status SKIPPED -ExitCode 1 -ErrorClass CC_USAGE_NO_INVENTORY`;
for exit `2` use `-Status FAILED -ExitCode 2 -ErrorClass CC_USAGE_BAD_INPUT`.
