---
name: sap-delivery-report
description: |
  Assembles the weekly delivery status report — objects in build/test/prod,
  quality-gate posture (RAG), TR pipeline position, and week-over-week progress —
  by correlating what the suite already produces instead of re-gathering it by
  hand every Friday. Offline-first: aggregates the artifact index (ATC /
  check-abap / abap-unit / transport-readiness / impact verdicts), build KPIs, and
  optional campaign state, adds exactly one live RFC read (E071→E070/E07T) for TR
  position, and derives a DETERMINISTIC RAG from a shipped, customer-tunable rules
  table. Persists a snapshot for --since diffing and renders report.md (+ trend
  TSVs, optional docx). Every RAG cell cites the artifact ids behind it; any claim
  not backed by evidence is prefixed INFERRED: and "no evidence" is AMBER, never
  green. Read-only (one RFC read, all writes local; --offline drops even that).
  Prerequisites: SAP profile via /sap-login (RFC) unless --offline; SAP NCo 3.1
  (32-bit) in GAC. No GUI, no Z-object dependency.
argument-hint: "[generate] <PACKAGE pkg | TR trkorr | PROGRAM name | --ticket id> [--since last|YYYY-MM-DD] [--offline] [--docx] [--title \"...\"] | snapshots <scope>"
---

# SAP Delivery Report Skill

You assemble a **cross-workstream delivery status report** with a defensible RAG,
a TR pipeline view, and a week-over-week diff — from machine-readable evidence the
suite already produced. You are **read-only** (at most one RFC read).

Task: $ARGUMENTS

The aggregation + deterministic RAG + snapshot are computed by
`references/sap_delivery_report.ps1`; **you** render the narrative `report.md` from
its `report_data.json`, under a hard grounding rule (cite or prefix `INFERRED:`).

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Read-only operating rules |
| `<SKILL_DIR>/references/sap_delivery_report.ps1` | `-Action generate\|snapshots -Scope <x> [-Since -Offline -Ticket -Title]` | The aggregation + RAG + snapshot engine |
| `<SKILL_DIR>/references/sap_delivery_rag_rules.tsv` | read by the engine | Deterministic RAG derivation (customer-tunable, tighten-only) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | `Find-SapArtifacts`, scope key, `Register-SapArtifact` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced | Scope resolution, `Read-SapTableRows` (the one RFC read) |
| `/sap-log-analyze` | sub-skill | `--builds` KPI refresh when the KPI file is stale |
| `docx` | sub-skill | `--docx` rendering of the finished report |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_delivery_report_run.json" -Skill sap-delivery-report -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

- Mode: **`generate`** (default) or **`snapshots`** (list stored snapshots for a scope).
- `<scope>`: `PACKAGE <pkg>` | `TR <TRKORR>` | `PROGRAM <name>` (or any resolver token) |
  `--ticket <id>` | a scope-key directly (`PROG_X`, `PKG_Y`, `SID_S4D_100`).
- Flags: `--since <last|YYYY-MM-DD|snapshot-id>`, `--offline` (skip the RFC read),
  `--docx`, `--title "<text>"`, `--campaign <id>`.

## Step 2 — RFC Preflight (skip if `--offline`)

`generate` on an object/package/TR token needs an RFC connection (`/sap-login`) to
resolve the scope + read TR position. A **scope-key or `--ticket`** target, or
`--offline`, runs **fully local** (no RFC). If a token scope is given without a
pinned profile and not `--offline`, point the user to `/sap-login`.

---

## Step 3 — Run the Engine

Run via **32-bit PowerShell** (any PowerShell for `--offline`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_delivery_report.ps1" -Action generate -Scope "PACKAGE ZDEV" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -SkillDir "<SKILL_DIR>"
```

Append `-Since last`, `-Offline`, `-Ticket <id>`, `-Title "..."`, `-CustomUrl "{custom_url}"`.
The engine aggregates the artifact index, computes RAG, writes `report_data.json` +
a snapshot + trend TSVs, registers the data, and prints:

```
REPORT_DATA: <path>   SNAPSHOT: <path>   ARTIFACT_DIR: <path>
RAG: GREEN=<n> AMBER=<n> RED=<n>   SCOPE_KEY: <key>
STATUS: OK | SCOPE_EMPTY | NO_INDEX | RFC_ERROR
```

STATUS handling: `SCOPE_EMPTY` (exit 1) → resolver found nothing, tell the user,
`DR_SCOPE_EMPTY`, STOP. `NO_INDEX` (exit 0) → no artifact index yet; the report still
renders with an **all-AMBER "no evidence" posture** — say so, log `DR_NO_ARTIFACT_INDEX`
WARN. `RFC_ERROR` (exit 2) → the RFC read failed; TR column is COULD_NOT_CHECK but the
report still renders — never present a partial as complete.

## Step 4 — Render `report.md` (you write this)

Read `report_data.json` (the computed `rows[]` with per-object `gates{kind:{verdict,
coverage,artifact_id,rag}}`, `rag_counts`, `workstream_rag`, `kpi`, `diff`) and write
`report.md` into `ARTIFACT_DIR`, sections in order:

1. **Header** — system/client, date, scope, title, overall workstream RAG.
2. **RAG summary** — GREEN/AMBER/RED counts; the worst-of rollup and why.
3. **Per-workstream detail** — group `rows` by RAG; for each object cite its gate
   artifact ids (e.g. `readiness_report A-1a2b… GO`). **Every RAG cell must carry its
   citing artifact id(s).**
4. **TR pipeline** — the `rows` with a `tr`: TRKORR, status, owner, text.
5. **KPIs** — from `kpi` if present; if absent, "not produced" (never 0%). Offer to
   run `/sap-log-analyze --builds` to refresh when stale.
6. **Progress since** *(only with `--since`)* — the `diff` block: transition counts
   (e.g. AMBER→GREEN ×4, new RED ×1), new/removed objects. `first report for this
   scope` when no prior snapshot; `DR_SNAPSHOT_CORRUPT` if the named snapshot is unreadable.
7. **Missing evidence** — mandatory: every object with zero artifacts (the AMBER
   floor), every COULD_NOT_CHECK, the `--offline` TR gap. Never rendered green.
8. **Appendix** — the RAG rule table (from `sap_delivery_rag_rules.tsv`) + a citation index.

**Grounding rule + self-check:** any sentence not backed by an artifact id or an
RFC-read row must start with the literal `INFERRED:`. Before declaring success, grep
your rendered narrative for uncited assertions and fix them.

## Step 5 — Optional docx + Register + Summarize

`--docx` → hand `report.md` to the `docx` skill. Register the report:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-delivery-report' -ScopeKey '<SCOPE_KEY>' -Kind 'delivery_report' -Format 'md' -Path '<ARTIFACT_DIR>\report.md' -Verdict '<workstream_rag>' -Coverage '<CHECKED_CLEAN|CHECKED_FINDINGS|COULD_NOT_CHECK>'"
```

Print: `REPORT: <path>` + `RAG: GREEN=<n> AMBER=<n> RED=<n>` + `SNAPSHOT: <id>`.

---

## snapshots mode

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_delivery_report.ps1" -Action snapshots -Scope "PACKAGE ZDEV" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -SkillDir "<SKILL_DIR>"
```

Prints one `SNAP: id=<ts> ts=<..> green/amber/red` line per stored snapshot. Present
them so the user can pick a `--since <id>`.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_delivery_report_run.json" -Status SUCCESS -ExitCode 0
```

`SCOPE_EMPTY` → `-Status FAILED -ErrorClass DR_SCOPE_EMPTY`. A rendered report (even
NO_INDEX all-AMBER) is `SUCCESS`.

---

## Scope & Limitations (v1)

- **v1 implemented:** `generate` (artifact aggregation + deterministic RAG + one RFC
  TR-position read + snapshot + `--since` diff + trend TSVs + `--docx`), `snapshots`,
  `--offline`. Scope types: package (expanded via direct TADIR read), TR (via E071),
  program/class/FM, ticket, or a raw scope-key.
- **Phase 2 (not yet):** `--imports` (per-system TPALOG import history — v1.5),
  `--tms-queue` (live import-queue position via the wrapper FM — v2), `--campaign`
  campaign-state fold-in beyond a best-effort read.
- **RAG is computed, never narrated** — from `sap_delivery_rag_rules.tsv` (shipped
  data, printed in the appendix). Two hard floors cannot be relaxed by a customer
  override: no evidence ⇒ AMBER; COULD_NOT_CHECK ⇒ at least AMBER. Overrides may only
  tighten.
- **Honesty invariants:** COULD_NOT_CHECK / no-evidence never render green; every RAG
  cell carries citations; uncited narrative is prefixed `INFERRED:`.
- **Read-only.** The only SAP touch is `RFC_READ_TABLE` (E071/E070/E07T), skipped
  entirely with `--offline`. No writes, no report execution, no GUI.
