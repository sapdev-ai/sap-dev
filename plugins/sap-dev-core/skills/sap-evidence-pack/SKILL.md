---
name: sap-evidence-pack
description: |
  Generates a reviewer / customer / audit-ready delivery evidence pack from the
  artifact index — answers "what did we change, how was it checked, and why is it
  safe?". It does NOT run checks itself; it COLLECTS what the other
  delivery-assurance skills already registered (transport-readiness,
  impact-analysis, ATC, check-abap, ABAP Unit, ...) for a scope (a TR, an object,
  a package), a ticket, or a date range, copies them into one categorized pack
  folder (reports / validations / impact / inventory), and writes a human-readable
  index.md with an executive summary, a contents table with verdicts, and — most
  importantly — a **Missing evidence** section that states honestly what was NOT
  produced instead of pretending everything was checked. Artifacts whose files
  are gone are flagged too. Pure-local (reads the manifest + copies files); no SAP
  needed unless an object scope must be resolved to its canonical scope key.
  Read-only with respect to SAP.
  Prerequisites: the other skills must have been run first to register artifacts
  (otherwise the pack honestly reports "no evidence found"). SAP NCo 3.1 (32-bit)
  only needed when resolving an object name to a scope key.
argument-hint: "<TR> | <TYPE> <NAME> | PACKAGE <pkg> | --ticket <id> | --since <date>  [--output <dir>] [--include-logs]"
---

# SAP Evidence Pack Skill

You assemble a **delivery evidence pack** from artifacts the other
delivery-assurance skills registered in the artifact index. You collect and
summarize — you do NOT re-run checks. If little was checked, the pack says so.

Task: $ARGUMENTS

This is the fourth delivery-assurance skill. It is the aggregator that makes the
others' output credible — including, deliberately, by listing what is missing
(the "missing evidence" philosophy).

---

## Shared Resources

| File | Call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SKILL_DIR>/references/sap_evidence_pack.ps1` | `-ScopeKey \| -Token \| -Ticket \| -Since [-OutputDir] [-IncludeLogs]` | The pure-local pack assembler |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced by the engine | `Find-SapArtifacts` — the manifest query |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | *(only for object scopes)* | Resolve an object name → canonical scope key |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_evidence_pack_run.json" -Skill sap-evidence-pack -ParamsJson "{}"
```

---

## Step 1 — Determine the Scope

Pick the query mode from `$ARGUMENTS`:

- **`TR <tr>`** → pass `-Token "TR <tr>"` (scope `TR_<tr>` derived locally — no SAP).
- **`PACKAGE <pkg>`** → pass `-Token "PACKAGE <pkg>"` (scope `PKG_<pkg>` — no SAP).
- **Object** (`<TYPE> <NAME>` or bare `<NAME>`) → the canonical scope key uses the
  TADIR object code (e.g. `PROG_ZMMR001`), so resolve it first with the object
  resolver, then pass `-ScopeKey`:
  ```bash
  C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1" -Token "PROGRAM ZMMR001"
  ```
  Read the `OBJECT: ... object=<O> name=<N>` line → scope key is `<O>_<N>`.
- **`--ticket <id>`** → pass `-Ticket <id>` (collect everything tagged with that
  ticket; no scope needed, no SAP).
- **`--since <date>`** → pass `-Since <date>` (everything registered since; no SAP).

Flags: `--output <dir>` (pack location), `--include-logs` (include raw JSONL run
logs in the pack).

---

## Step 2 — Assemble the Pack

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_evidence_pack.ps1" -Token "TR THE_TR"
```

…or `-ScopeKey "PROG_ZMMR001"`, or `-Ticket "SAP-4821"`, or `-Since 2026-06-01`.
Append `-OutputDir`, `-IncludeLogs` as needed. This engine is pure-local — it
does not connect to SAP — so plain `powershell` is fine (32-bit not required).

Engine output:

```
EVIDENCE: scope=<key> artifacts=<n> missing=<m> missing_files=<k> pack=<dir>
INDEX_MD: <path>
```

Exit: `0` ok (even with 0 artifacts — it writes an honest "no evidence" pack) ·
`2` on error.

---

## Step 3 — Report

Open `INDEX_MD` and present:

1. **Scope** and **overall verdict** (rolled up from the collected artifacts —
   NO_GO wins over GO_WITH_WARNINGS wins over GO).
2. **What's in the pack** — the contents table (which skill produced what, with
   verdicts and coverage).
3. **Missing evidence** — read this section out explicitly. If `missing=<m>` is
   non-zero, name the gaps (e.g. "ATC was not run; no ABAP Unit results") and
   recommend the skill that would fill each:
   - missing `readiness_report` → `/sap-transport-readiness <TR>`
   - missing `impact_report` → `/sap-impact-analysis <obj>`
   - missing `atc_findings` → `/sap-atc <obj>`
   - missing `unit_results` → `/sap-run-abap-unit <obj>`
4. If any artifact files were **missing on disk** (`missing_files`), flag that the
   index references outputs that have been moved/deleted.

Do NOT overstate coverage. The pack is credible precisely because it is honest
about what was and was not checked.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_evidence_pack_run.json" -Status SUCCESS -ExitCode 0
```

---

## Scope & Limitations (MVP)

- **Collects, does not check.** The pack is only as complete as the artifacts the
  other skills registered. Empty index → honest "no evidence" pack.
- **Formats:** Markdown `index.md` + copied source artifacts (TSV/JSON/MD). HTML /
  PDF export, bilingual EN/JA/ZH summaries, signed-approval section, and
  ticket-system upload are Phase 2.
- **Object scope** needs the resolver (one RFC call) to get the canonical scope
  key; TR / package / ticket / date scopes are fully offline.
- **`--include-logs`** pulls raw JSONL run logs only if they were registered as
  `raw_log` artifacts (off by default to keep packs lean).
