---
name: sap-impact-analysis
description: |
  Pre-change / pre-release impact analysis — answers "if I change this object,
  what else might break?" from SAP's system-maintained CROSS-REFERENCE INDEX
  (D010TAB, D010INC, WBCROSSGT, CROSS, DD04L), NOT by parsing source (REPOSRC is
  blocked) and NOT by driving the slow GUI where-used. Resolves the object,
  then gathers: reverse dependencies (where-used — programs/objects that use it),
  forward dependencies (what a program uses), runtime entry points (tcodes, jobs,
  variants, RFC-enabled flag), and transport history (E071/E070). Computes a
  transparent LOW/MEDIUM/HIGH risk band from where-used fan-out + standard-object
  flag, writes a markdown report + per-dimension TSVs + risk findings, and
  registers them in the artifact index for /sap-evidence-pack. Always discloses
  the dynamic-dispatch blind spot (CALL FUNCTION lv_name, dynamic SELECT,
  SUBMIT (rep)) and reports COULD_NOT_CHECK rather than guessing on read
  failures. Inputs: program / class / FM / table / data element / domain / tcode
  (and TR / package by expansion). Read-only.
  Prerequisites: SAP profile saved via /sap-login (RFC); SAP NCo 3.1 (32-bit,
  .NET 4.0) in GAC.
argument-hint: "<TYPE> <NAME> | <NAME> | TCODE <t> | TABLE <t>  [--depth 1] [--output <dir>] [--high-fanout 50]"
---

# SAP Impact Analysis Skill

You answer "**what does changing this object affect?**" using SAP's own
cross-reference index — fast, RFC-only, both directions. You are read-only.

Task: $ARGUMENTS

This is the second delivery-assurance skill, built on the Phase-0 primitives and
the cross-reference-index data-source strategy: read the index tables, never the
source, never the GUI where-used.

---

## Shared Resources

| File | Call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_impact_analysis.ps1` | `-Token -SharedDir [-TypeHint] [-HighFanout] [-MedFanout] [-OutputDir]` | The cross-reference impact engine |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced by the engine | Object resolution + `Read-SapTableRows` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` | dot-sourced by the engine | Risk findings + severity ranks |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced by the engine | Registers outputs for `/sap-evidence-pack` |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

(`{WORK_TEMP}` = `{work_dir}\temp`.)

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's `_run.json` log state under `{RUN_TEMP}`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_impact_analysis_run.json" -Skill sap-impact-analysis -ParamsJson "{}"
```

---

## Step 1 — Parse the Target

- **`<TYPE> <NAME>`** (e.g. `TABLE ZMM_ORDER`, `PROGRAM ZMMR001`, `TCODE ME21N`,
  `FM Z_MM_POST`, `DOMAIN ZDOM`) → pass `-Token "<TYPE> <NAME>"`. Best signal —
  use it when you know the type.
- **Bare `<NAME>`** → pass `-Token "<NAME>"`; the resolver disambiguates via
  TADIR. If it returns AMBIGUOUS, re-run with a `-TypeHint`.
- **`TCODE <t>`** → the engine resolves the underlying program and analyses that.
- **`TR <tr>` / `PACKAGE <pkg>`** → these are *sets*. Resolve+expand the
  inventory first (the object resolver's `-Expand`), then run the engine **once
  per object** (cap at a sensible number — e.g. 25 — and `log()` what you
  skipped; never silently truncate). Aggregate the per-object risk bands in your
  summary. For a large package, advise the user to scope to specific objects.

Flags: `--depth N` (MVP computes depth 1 — direct deps; transitive is Phase 2),
`--output <dir>`, `--high-fanout <n>` / `--med-fanout <n>` (risk band thresholds).

---

## Step 2 — Run the Impact Engine

Run via **32-bit PowerShell** (NCo 3.1 in `GAC_32`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_impact_analysis.ps1" -Token "TABLE ZMM_ORDER" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Append `-TypeHint`, `-HighFanout`, `-MedFanout`, `-OutputDir` as needed. Creds
resolve from the pinned profile automatically.

Engine output:

```
IMPACT: object=<O:N> risk=<LOW|MEDIUM|HIGH> reverse=<n> forward=<n> runtime=<n> trs=<n>
PARTIAL: could_not_check=<tables>            (only if some reads were denied)
REPORT_MD / REVERSE_TSV / FORWARD_TSV / RUNTIME_TSV / TRANSPORT_TSV / RISK_TSV / RISK_JSON: <path>
```

Exit: `0` ok · `1` object not found / ambiguous · `2` RFC failure.

---

## Step 3 — Interpret and Report

Read the `IMPACT:` line, then `REPORT_MD`. Present:

1. **Risk band** (LOW / MEDIUM / HIGH) and the headline counts: reverse
   (where-used), forward (uses), runtime entry points, transports.
2. **Reverse dependencies** — the programs/objects that would be affected. This
   is the core answer to "what might break."
3. **Runtime entry points** — tcodes / jobs / variants / RFC-enabled. These are
   how the object is reached at runtime.
4. **Two mandatory caveats** (never omit — honesty contract):
   - If a `PARTIAL:` line appeared, say **which dimensions are incomplete** (auth
     / RFC). The analysis does NOT certify those clean.
   - **Dynamic dispatch is invisible** to the cross-reference index — manually
     check for `CALL FUNCTION lv_name`, dynamic `SELECT`, `SUBMIT (rep)`.
5. The risk band is a **transparent heuristic** (fan-out bands + standard-object
   flag), not a guarantee — present the facts (the dependency lists) as the
   primary value, the band as a hint.

---

## Step 4 — Recommend Next Steps

Tie the findings to actions:

- **HIGH band / large fan-out** → recommend a regression plan over the dependent
  objects; run `/sap-atc PACKAGE <pkg>` and `/sap-run-abap-unit` on the affected
  scope.
- **Standard (non-Z/Y) object** → recommend `/sap-enhancement-advisor` to find a
  BAdI/exit instead of modifying standard.
- **Pre-release** → feed this into `/sap-transport-readiness <TR>` and
  `/sap-evidence-pack` (the reports are already registered in the artifact index
  under this object's scope).
- Mention the report files and that they are collectible by `/sap-evidence-pack`.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_impact_analysis_run.json" -Status SUCCESS -ExitCode 0
```

(Object-not-found → `-ExitCode 1 -ErrorClass OBJECT_NOT_FOUND`; RFC failure →
`-ExitCode 2 -ErrorClass RFC_LOGON_FAILED`.)

---

## Scope & Limitations (MVP)

- **Direction coverage:** reverse where-used for table / global symbol / data
  element / domain / FM; forward (uses) for **programs** only.
- **Index source, by design:** uses `D010TAB`/`D010INC`/`WBCROSSGT`/`CROSS`/
  `DD04L`. These are authoritative for STATIC global references and HIGH
  confidence. The `WBCROSSGT.OTYPE` / `CROSS.TYPE` code *values* vary by release
  — the engine reads and reports them, it does not hardcode-filter.
- **Include→program resolution** is the cheap `D010INC` path; unresolved includes
  (e.g. some class includes) are reported as the include name. The authoritative
  `RS_EU_CROSSREF`-via-wrapper path is Phase 2.
- **Depth 1 only** (direct dependencies). Transitive (`--depth >1`) is Phase 2.
- **Dynamic dispatch is never covered** and is always disclosed.
- **DDIC field detail** (data-element → table fields via `DD03L`) is best-effort;
  a read failure degrades to `COULD_NOT_CHECK`, never a silent gap.
- **Read-only.** Never modifies SAP.
