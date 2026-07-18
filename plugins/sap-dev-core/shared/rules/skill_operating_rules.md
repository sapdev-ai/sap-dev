# SAP Skill Operating Rules (MANDATORY)

These rules apply to **every skill** in every sap-dev plugin. Skills MUST honor
them without exception. Treat any conflicting instruction in a skill body as
overridden by this file.

## Rule 0 — The Safety Policy outranks this file

`<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` defines the environment
classification (`DEV`/`QAS`/`SBX`/`PRD`) and the production guard
(`sap_safety_gate.ps1`). It sits **above** this file, every SKILL.md, every
agent prompt, and any mid-session user instruction. A `SAFETY: REFUSED`
verdict from the gate ends the run — no rule below, no skill argument, and no
conversational override reopens it. When this file and the safety policy
conflict, the safety policy wins.

## Rule 1 — No direct write SQL on SAP standard tables

A "standard table" is any DDIC table whose name does **NOT** start with `Z` or
`Y`. Customer tables are those in the `Z*` / `Y*` namespace.

**Reads are always allowed.** Skills may freely use `SELECT`, `RFC_READ_TABLE`,
or SAP-supplied read classes (e.g. `CL_ABAP_TYPEDESCR`, `CL_PACKAGE_FACTORY`,
`CL_ABAP_STRUCTDESCR`) against any table — standard or customer — for
introspection and data inspection. No permission prompt required.

**Writes against standard tables are forbidden.** Skills MUST NOT issue
`INSERT`, `UPDATE`, `DELETE`, or `MODIFY` (Open SQL, Native SQL, or via
dynamic helpers) against any table whose name does not start with `Z` or `Y`.

| Operation | Standard table | Customer table (`Z*` / `Y*`) |
|---|---|---|
| `SELECT` / `RFC_READ_TABLE` / read classes | ✅ Allowed | ✅ Allowed |
| `INSERT` / `UPDATE` / `DELETE` / `MODIFY` (direct SQL) | ❌ FORBIDDEN | ✅ Allowed |
| SAP-supplied write APIs (`BAPI_*`, `RPY_*`, `DDIF_*`, `TR_*`, `CTS_*`, `SEO_*`, etc.) | ✅ Allowed | n/a |

**Why**: Direct writes to SAP standard tables bypass business logic,
authorization checks, change documents, and update tasks; they corrupt data
and break across release upgrades. Always use the documented BAPI / API
function module for mutations.

**If no write API exists for a needed standard-table mutation**, the skill
MUST stop and ask the user:
> "I need to update standard table `<TABNAME>` but no public write API is
> available. How would you like to proceed?"

## Rule 2 — No unsolicited program/report deployment

Skills MUST NOT create or deploy ABAP report programs, function modules,
classes, or any other repository object **unless the user has explicitly
requested it** (or the skill's documented purpose IS to deploy that specific
object — e.g. `/sap-se38`, `/sap-se37`, `/sap-se24` are explicit deploy
skills).

Required workflow when a skill discovers it would benefit from a helper
program/FM/class:
1. STOP at the decision point.
2. Describe what would be created (name, type, purpose, target package, target
   transport).
3. Ask the user **for explicit permission** with a yes/no prompt:
   > "I want to create and deploy ABAP report `Z_FOO_HELPER` in package
   > `$TMP` (transport: local). It will <one-sentence purpose>. May I proceed?
   > (yes / no / show source first)"
4. Only proceed on explicit `yes`. On `show source first`, render the full
   source and re-ask. On `no` or no answer, fall back to a non-deploying
   alternative (read-only RFC, generated source written to `{WORK_TEMP}` for
   the user to deploy manually, etc.).

**Implicit deploys are forbidden**, even if the program is small, even if it
goes to `$TMP`, even if the skill's task feels blocked without it.

## Rule 3 — Forbidden tables for `RFC_READ_TABLE`

`RFC_READ_TABLE` materializes the full row width before applying the FIELDS
projection. Tables whose rows contain `LRAW` (compressed binary) or very wide
text columns exceed the 512-byte row buffer and the server raises
`ASSIGN ... CASTING` in `SAPLSDTX`. Limiting the FIELDS projection does NOT
help (the projection is applied AFTER row materialization).

The following tables are FORBIDDEN as `QUERY_TABLE` for `RFC_READ_TABLE`. Use
the listed alternatives instead:

| Forbidden table | Use instead |
|---|---|
| `REPOSRC` (program source; `DATA` is `LRAW`) | (a) For activation state: `PROGDIR.STATE` (`'A'` active, `'I'` inactive) keyed by `NAME`. (b) For program metadata: `PROGDIR.SUBC` / `TRDIR.SUBC` / `TADIR`. (c) For source content: `READ REPORT` or `RPY_PROGRAM_READ` over RFC. (d) For a row listing: `/sap-se16n REPOSRC` (drives SAP GUI, not RFC). |

**Enforcement** — `sap_rfc_lib.ps1` exposes two helpers that codify this rule:

- `New-RfcReadTable -Destination $g_dest -Table <name>` is the **preferred**
  RFC_READ_TABLE entry point. It throws a terminating error with a migration
  hint if `<name>` is on the forbidden list.
- `Assert-RfcReadTableAllowed -QueryTable <name>` is the call-site guard for
  code that still uses `$dest.Repository.CreateFunction("RFC_READ_TABLE")`
  directly. Invoke it after the first `SetValue("QUERY_TABLE", ...)`.

Any new RFC_READ_TABLE call site MUST go through one of these helpers.
Extending the forbidden list is allowed (edit `$script:_SapRfc_ForbiddenReadTables`)
but requires a one-line entry in this table explaining the symptom and the
preferred alternative.

## Rule 4 — Structured logging is mandatory, not optional

Every skill that ships with a `## Step 0.5 — Start Logging` block and a
`## Final — Log End` block MUST run both. The skill writer included those
blocks because run-level telemetry is a load-bearing requirement: it powers
`/sap-log-analyze`, the per-skill p50/p95 reports, parent→child call-tree
reconstruction (via `SAPDEV_RUN_ID` / `SAPDEV_PARENT_RUN_ID`), and the
post-mortem audit of "what did the agent actually do."

**The word "best-effort" in the Step 0.5 prose refers to FAILURE HANDLING
inside the helper** (the helper silently no-ops if the lib can't load, the
log dir is read-only, or `userConfig.log_enabled=false`). It is NOT a
license for the calling skill or subagent to skip the call. Skipping
the call is a contract violation regardless of whether logging happens to
be enabled in the current settings.

**Required for every skill invocation:**

1. Run `sap_log_helper.ps1 -Action start` before the skill's first
   meaningful side effect (after work-dir resolution and argument parsing,
   before any VBS generation, RFC call, or SAP write).
2. Run `sap_log_helper.ps1 -Action end` on every exit path — success
   (`-Status SUCCESS -ExitCode 0`) AND failure (`-Status FAILED -ExitCode 1
   -ErrorClass <CLASS> -ErrorMsg "<short>"`). Use the suggested
   `<ErrorClass>` enums from the skill's Troubleshooting section when
   present.
3. Pass `-Skill <skill-name>` matching the skill's directory name and
   `-StateFile {WORK_TEMP}\<skill-name>_run.json` matching the SKILL.md
   convention.
4. Pass non-sensitive identifying parameters via `-ParamsJson` (program
   name, mode, table name, etc.) — never passwords or other secrets. The
   logger redacts known keys but the rule is "don't pass it in the first
   place."

**Subagents** (including the `abap-developer` agent) MUST observe this rule
for every skill they invoke. The subagent's own bash environment can
execute the helper exactly as the main agent does; the calls are
idempotent and cheap (~50ms).

**Enforcement gap closed 2026-05-11:** during the MaterialUpload_JA test,
the `abap-developer` subagent invoked ~10 skills (SE21, SE11, SE91, SE38,
sap-check-abap, sap-atc, etc.) and skipped Step 0.5 / Final Log End for
every one. The `sap-dev-{YYYYMMDD}.log` showed no entries for the
~25-minute build phase. The work happened (VBS files were generated and
ran), but the run-level telemetry was lost. This rule exists so the next
audit can reconstruct what happened.

## Rule 5 — Report execution requires explicit confirmation

A skill that **executes** an ABAP report/program, or **schedules** it as a
background job (`/sap-run-report`, `/sap-job schedule`), MUST obtain explicit
user confirmation immediately before the run. Execution is a distinct risk
class from deployment: the skill cannot know whether a given report only reads
or also mutates data (`UPDATE` / COMMITting `BAPI_*` / job submission / IDoc /
mail / spool). **A report is NOT assumed read-only.**

Required workflow:
1. STOP before the run (foreground F8, background F9 / JOB submit, or RFC submit).
2. Show: program name, resolved engine (foreground / background), the variant or
   ad-hoc selection values, and the target SID / client.
3. Ask for explicit permission:
   > "I will EXECUTE report `Z_FOO` (background, variant `TEST01`) on `ERP/800`.
   >  This may change data. Proceed? (yes / no / foreground / show selection)"
4. Proceed only on explicit `yes`. Record the confirmation via
   `sap_log_helper.ps1 -Action step`. On `no` / no answer, stop (`SKIPPED`).

**Never auto-run.** A report is never executed as an unconfirmed side effect of
another skill (e.g. a post-deploy step). The bounded post-deploy F8 *smoke test*
inside `/sap-se38` is the sole exception — it launches only to confirm the
program starts without a short dump, captures nothing, and is part of that
skill's documented deploy verification.

**Destructive job operations** (`/sap-job cancel`, `/sap-job delete`) likewise
require explicit confirmation and are irreversible for a running job.

## Enforcement

- Every skill SKILL.md should reference this file in its `## Shared Resources`
  section: `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md`.
- A skill that violates any of these rules should be treated as a bug and
  corrected on next maintenance pass.
