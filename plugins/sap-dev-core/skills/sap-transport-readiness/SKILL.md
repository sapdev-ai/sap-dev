---
name: sap-transport-readiness
description: |
  Release gate for an ABAP transport request — answers "is this transport safe
  to release?" before it moves to QA / production. Resolves the TR (explicit
  number, or --current from the dev defaults), builds its object inventory from
  E071, and runs read-only RFC structural checks: unreleased child tasks (E070),
  inactive objects (DWINACTIV), local / $TMP objects inside a transportable
  request (TADIR), and a multi-package note. Optionally chains /sap-atc and
  /sap-run-abap-unit and folds their verdicts in. Evaluates everything into the
  reconciled finding model, gates each finding via the customer brief's Quality
  bar (§6, --strict promotes warnings), and rolls up to GO / GO_WITH_WARNINGS /
  NO-GO. Writes a reviewer report + findings TSV/JSON + object inventory and
  registers them all in the artifact index for /sap-evidence-pack. Read-only;
  never releases the TR — release stays a deliberate /sap-se01 step.
  Prerequisites: SAP profile saved via /sap-login (RFC); SAP NCo 3.1 (32-bit,
  .NET 4.0) in GAC. Z_GENERIC_RFC_WRAPPER_TBL is NOT required (all checks use
  RFC_READ_TABLE).
argument-hint: "<TR> | --current  [--strict] [--run-atc] [--include-unit-tests] [--brief <path>]"
---

# SAP Transport Readiness Skill

You run a **release gate** over a transport request and report GO / NO-GO with
the evidence. You are read-only — you NEVER release the TR. Release is a
deliberate, separate `/sap-se01 release` step the user takes after a GO.

Task: $ARGUMENTS

This skill is the first of the **delivery-assurance** family and is built on the
Phase-0 primitives: the object resolver (TR → E071 inventory), the finding model
+ gate policy, and the artifact index.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here, no writes to SAP |
| `<SKILL_DIR>/references/sap_transport_readiness.ps1` | `-Tr -SharedDir [-Strict] [-AtcVerdict] [-UnitVerdict] [-BriefPath]` | The RFC readiness engine |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced by the engine | TR `--Expand` → E071 object inventory |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` | dot-sourced by the engine | Reconciled finding model + verdict roll-up |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gate_policy.ps1` | dot-sourced by the engine | Gate computation from `customer_brief.md` §6 |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced by the engine | Registers outputs for `/sap-evidence-pack` |
| `/sap-atc` | sub-skill | Optional ATC run (`--run-atc`) |
| `/sap-run-abap-unit` | sub-skill | Optional ABAP Unit run (`--include-unit-tests`) |

---

## Step 0 — Resolve Work Directory and Settings

Resolve `work_dir` via the env-aware helper (do NOT read `settings.json`
directly — that ignores `SAPDEV_AI_WORK_DIR` and `userconfig.json`):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp`; ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_transport_readiness_run.json" -Skill sap-transport-readiness -ParamsJson "{}"
```

---

## Step 1 — Resolve the Transport Request

Parse `$ARGUMENTS` for the TR and flags:

- **Explicit TR** (e.g. `DEVK900123`, `S4DK900123`) → use it.
- **`--current`** → read `sap_dev_transport_request` (per-connection first:
  `connections.json[pinned].dev_defaults`, then the two-file settings merge per
  `shared/rules/settings_lookup.md`). If blank → tell the user to pass an
  explicit TR or run `/sap-transport-request`, and STOP.
- Flags: `--strict` (promote warnings to blockers), `--run-atc`,
  `--include-unit-tests`, `--brief <path>` (override the customer brief).

Prerequisite check: a SAP RFC profile must be pinned (`/sap-login`). The engine
self-connects via the pinned profile (no creds needed on the command line).

---

## Step 2 — (Optional) Run ATC and ABAP Unit first

These are opt-in because they are slower / heavier than the RFC structural
checks. Run them BEFORE the engine so their verdicts can be folded into one
unified readiness verdict.

- **`--run-atc`**: run `/sap-atc PACKAGE <pkg>` (or per object) over the TR's
  scope. Capture its pass/fail as a single verdict string: `GO` (within the
  brief's `MAX_PRIORITY`) or `NO_GO`. If ATC could not run, use `ERROR`.
- **`--include-unit-tests`**: run `/sap-run-abap-unit` over the TR's
  programs / classes. Capture `GO` / `NO_GO` / `ERROR`.

If a flag is not given, pass nothing for that verdict — the engine records it as
"not run" (no finding), and you note it in the report under *not run*.

> Do NOT invent these verdicts. Only pass `GO`/`NO_GO` when the sub-skill
> actually produced a result; pass `ERROR` if it failed; pass nothing if you
> did not run it.

---

## Step 3 — Run the Readiness Engine

Run via **32-bit PowerShell** (NCo 3.1 is in `GAC_32`). Pass the resolved TR,
the shared dir, and any flags / sub-skill verdicts:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_transport_readiness.ps1" -Tr "THE_TR" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Append, as applicable: `-Strict`, `-AtcVerdict GO|NO_GO|ERROR`,
`-UnitVerdict GO|NO_GO|ERROR`, `-BriefPath "<path>"`. Creds are resolved from
the pinned profile automatically.

The engine prints a parseable summary and writes the report files:

```
READINESS: tr=<TR> verdict=<GO|GO_WITH_WARNINGS|NO_GO> block=<n> warn=<n> info=<n> objects=<n>
REPORT_MD: <path>      FINDINGS_TSV: <path>
FINDINGS_JSON: <path>  INVENTORY_TSV: <path>
```

Exit code: `0` = GO / GO_WITH_WARNINGS · `1` = NO_GO · `2` = TR not found /
RFC failure.

---

## Step 4 — Interpret and Report

Read the `READINESS:` line for the verdict, then read `REPORT_MD` for the
detail. Present to the user:

1. **Verdict** up front: ✅ GO · ⚠️ GO WITH WARNINGS · ⛔ NO-GO.
2. **Blocking findings** (each with its remediation) — these must be fixed.
3. **Warnings** — review before release.
4. **Could-not-check** — if any check returned `COULD_NOT_CHECK`, say so
   explicitly. The report does NOT certify those areas clean (honesty contract).
5. Point to the report files and note they are registered in the artifact index
   (so `/sap-evidence-pack <TR>` can collect them later).

Default gate behaviour (overridden by `customer_brief.md` §6 and `--strict`):

| Finding | Default gate |
|---|---|
| Inactive object, unreleased child task, `$TMP`/local object in transport | BLOCK |
| ATC (severity ≥ HIGH per brief), failed ABAP Unit (if brief = mandatory) | BLOCK |
| Object locked by other user, dependency outside TR | WARN (BLOCK under `--strict`) |
| Multi-package note | INFO |
| Could-not-check (auth / RFC) | WARN — never a silent pass |

---

## Step 5 — Recommend Next Steps (never auto-release)

- **NO-GO**: list the exact remediations (e.g. `/sap-activate-object <obj>`,
  `/sap-change-package <obj> <pkg>`, `/sap-se01 release <child-task>`), then
  suggest re-running `/sap-transport-readiness <TR> --strict`.
- **GO / GO WITH WARNINGS**: state that the TR can be released via
  `/sap-se01 release <TR>` — and that release is the user's explicit action.
  **Do NOT release the TR yourself.**

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_transport_readiness_run.json" -Status SUCCESS -ExitCode 0
```

For NO-GO use `-Status SUCCESS -ExitCode 0` (the gate ran fine; NO-GO is a valid
result). For TR-not-found / RFC failure use `-Status FAILED -ExitCode 2
-ErrorClass RFC_LOGON_FAILED` (or `TR_NOT_FOUND`).

---

## Scope & Limitations (MVP)

- **Checks implemented:** TR existence/status, unreleased child tasks, object
  inventory, inactive objects, `$TMP`/local-in-transport, multi-package note,
  plus folded-in ATC / ABAP-Unit verdicts.
- **Phase 2 (not yet):** object locks (ENQUEUE via the wrapper FM), dependency
  completeness (objects referencing items outside the TR — needs the
  cross-reference reads from `/sap-impact-analysis`), customizing-key client
  review (E071K), transport-sequence analysis, import simulation.
- **Inactive probe is name-based** (DWINACTIV uses its own object-type codes);
  it reports `COULD_NOT_CHECK` rather than guessing when a read is denied.
- **Read-only.** This skill never modifies or releases anything in SAP.
