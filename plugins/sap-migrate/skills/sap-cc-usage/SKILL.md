---
name: sap-cc-usage
description: |
  Overlays runtime usage data onto the campaign inventory to decide what to
  remediate vs. retire. Joins a usage export onto `inventory.tsv`, applies the
  campaign's decommission policy, writes `usage.tsv` + `scope.tsv`
  (REMEDIATE / DECOMMISSION / REVIEW), and advances `state.tsv`. This is the
  step that produces the headline "X% retired without remediation" number.
  Two usage sources: (FILE) a hand-supplied export, and (SCMON/UPL) a DIRECT
  RFC read of the source system's ABAP Call Monitor (tx SCMON) / SUSG
  aggregation — `sap_cc_scmon_read.ps1` reads `SUSG_V_DATA` (aggregated) or
  `SCMON_VDATA` (raw) and produces the same export the FILE path ingests. The
  FILE/NONE paths are offline; only the SCMON/UPL read opens an RFC connection
  to the campaign's `source_profile`.
  SAFETY: if SCMON/SUSG has NO data (monitoring not active), the read returns
  NO_DATA and every object defaults to REMEDIATE — "no monitoring data" is never
  read as "everything unused". The `conservative` policy never auto-decommissions;
  it parks unused objects as REVIEW pending the `/sap-where-used-list`
  reference-safety check. `aggressive` flags all unused objects DECOMMISSION (no
  reference check — use with care). A short observation window emits a WINDOW_WARN
  (short windows miss period-end / year-end jobs and over-flag objects as unused).
  Run after `/sap-cc-inventory`, before `/sap-cc-analyze`.
  Prerequisites: FILE/NONE need no SAP connection; SCMON/UPL need SAP NCo 3.1
  (32-bit) + a saved `source_profile` (or a pinned `/sap-login` connection).
argument-hint: "--campaign <id> [--usage-source FILE|SCMON|UPL|NONE] [--usage-file <path>] [--source-profile <ref>] [--namespaces Z,Y] [--policy none|conservative|aggressive] [--min-exec 0]"
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
| `<SKILL_DIR>/references/sap_cc_usage.ps1` | *(invoke)* | Joins usage onto inventory, applies the policy, writes `usage.tsv` + `scope.tsv`, advances `state.tsv`. Emits parseable `USAGE:` / `DECISION:` / `METRIC:` / `STATUS:` lines. Offline (files only). |
| `<SKILL_DIR>/references/sap_cc_scmon_read.ps1` | *(invoke, RFC)* | **Direct SCMON/UPL reader** (SCMON/UPL source only). Reads the source system's `SUSG_V_DATA` (aggregated) / `SCMON_VDATA` (raw) + `SUSG_ADMIN` (window) via RFC and writes a usage export TSV. Emits `SCMON:` / `WINDOW_WARN:` / `EXPORT:` / `STATUS: OK\|NO_DATA\|ERROR`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` + `sap_dpapi.ps1` | *(used by the reader)* | NCo 3.1 connect + source-profile password decrypt (SCMON/UPL path only). |
| `/sap-where-used-list` | *(skill)* | Used in the **reference-safety check** (Step 4) to confirm a REVIEW candidate has no inbound callers among still-used objects before it is decommissioned. |

The workspace contract (`usage.tsv` / `scope.tsv` columns, the
SCOPED / DECOMMISSIONED / REVIEW states, the upsert rule) is defined by
`/sap-cc-campaign`. This skill **owns** `usage.tsv` and `scope.tsv`.

> The scoping helper (`sap_cc_usage.ps1`) and the FILE/NONE paths are offline —
> no SAP GUI, broker, attach lib, or TR. Two parts touch SAP, both read-only:
> the **SCMON/UPL reader** (RFC against the `source_profile`, Step 1.5) and the
> optional reference-safety check (Step 4, via `/sap-where-used-list`).

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
- `--usage-source FILE|SCMON|UPL|NONE` — defaults to FILE when `--usage-file`
  is given, else NONE.
  - `FILE` — ingest the `--usage-file` export (offline).
  - `SCMON` / `UPL` — **read usage directly from the source system** (Step 1.5):
    run `sap_cc_scmon_read.ps1` over RFC, then ingest its export. On NW 7.52+/S4
    SCMON subsumes UPL, so both read the same SUSG/SCMON path.
  - `NONE` — no usage data; every object → REMEDIATE (safe).
- `--source-profile <ref>` — (SCMON/UPL) connection profile of the system whose
  usage to read; defaults to the campaign's `source_profile`, else the pinned
  `/sap-login` connection.
- `--namespaces <list>` — (SCMON/UPL) `OBJ_NAME` prefixes to read, default
  `Z,Y`. Add customer namespaces (e.g. `Z,Y,/ACME/`) for non-Z/Y custom code.
- `--policy none|conservative|aggressive` — defaults to the brief's
  `scope.decommission_policy`, else `conservative`.
- `--min-exec <n>` — "used" means `exec_count > n` (default 0).

---

## Step 1.5 — Direct SCMON/UPL read (only when `--usage-source SCMON|UPL`)

Skip this step for FILE / NONE. For SCMON/UPL, read usage from the source system
first, then feed the result into Step 2.

Run the reader via **32-bit PowerShell** (SAP NCo 3.1 is in the 32-bit GAC):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_scmon_read.ps1" -CampaignDir "{CAMPAIGN_DIR}" -WorkDir "{work_dir}"
```

Append `-SourceProfile "<ref>"` and/or `-Namespaces "Z,Y,/ACME/"` to mirror the
flags. The reader writes `{CAMPAIGN_DIR}\usage_scmon_export.tsv`. Parse its last
`STATUS:` line:

| `STATUS:` | Meaning | Action |
|---|---|---|
| `OK` | Usage read; export written (`EXPORT:` line). | Proceed to Step 2 with `-UsageSource SCMON -UsageFile {CAMPAIGN_DIR}\usage_scmon_export.tsv`. |
| `NO_DATA` | SCMON/SUSG empty — monitoring not active/aggregated. | **Do NOT decommission anything.** Surface the `WARN:` to the operator, then run Step 2 with `-UsageSource NONE` (every object → REMEDIATE). Recommend activating SCMON (tx SCMON) + aggregating via SUSG for ≥ 12 months. |
| `ERROR` | RFC/profile failure (see the `ERROR:` line). | Fix the connection (`/sap-login`) or fall back to a manual `--usage-file` export. |

**Always surface any `WINDOW_WARN:` line.** It means the observation window is
short (or has gaps) — unused-flagging will over-decommission because period-end /
quarter-end / year-end jobs fall outside the window. When you see it, advise the
operator to treat DECOMMISSION candidates as REVIEW until a ≥ 12-month window is
available (and prefer `conservative` policy, which already parks them as REVIEW).

---

## Step 2 — Run the Scoping Helper

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_usage.ps1" -CampaignDir "{CAMPAIGN_DIR}"
```

Append any of `-UsageFile "<path>"`, `-UsageSource FILE|SCMON|UPL|NONE`,
`-Policy conservative`, `-MinExec 0` to mirror the flags. For the **SCMON/UPL**
path, pass `-UsageSource SCMON -UsageFile {CAMPAIGN_DIR}\usage_scmon_export.tsv`
(the Step 1.5 export) — the helper ingests it but stamps `usage_source=SCMON` in
`usage.tsv` for provenance. The scoping helper itself needs no NCo (the RFC work
is done in Step 1.5).

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
- `{CAMPAIGN_DIR}\usage_scmon_export.tsv` — (SCMON/UPL source only) the raw export the reader produced from the source system's Call Monitor; kept as evidence of what usage was read.

---

## Limitations / Known gaps (draft)

- **SCMON/UPL direct read shipped (v2).** `--usage-source SCMON|UPL` now reads
  the source system's ABAP Call Monitor / SUSG aggregation over RFC
  (`sap_cc_scmon_read.ps1` → `SUSG_V_DATA` aggregated, `SCMON_VDATA` raw
  fallback, `SUSG_ADMIN` for the window). Caveats:
  - **Observation window is decisive.** Usage truth = SCMON's collection window.
    A short window over-flags objects as unused (period-end / year-end jobs are
    missed). The reader emits `WINDOW_WARN` when the window is < 12 months or has
    gaps; prefer `conservative` policy until a long window exists. **Verified live
    on S/4HANA 1909: connect + the empty-data safe path (NO_DATA → REMEDIATE).**
  - **Requires monitoring data on the *source*.** If SCMON isn't active / SUSG
    isn't aggregated, the read returns NO_DATA and everything defaults to
    REMEDIATE (safe). Activate SCMON + run SUSG aggregation first.
  - **UPL on older releases** (pre-7.52, Solution-Manager-fed) used different
    tables; this reader targets the SCMON/SUSG model. For those, export from
    Solution Manager and use `--usage-file`.
  - Exec counts above the 32-bit range fall back to "used" (the used/unused
    signal is preserved; the exact count may be capped).
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
