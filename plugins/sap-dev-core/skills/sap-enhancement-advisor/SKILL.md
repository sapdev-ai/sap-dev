---
name: sap-enhancement-advisor
description: |
  Finds the safest extension point for a requested SAP behavior change and
  recommends which enhancement mechanism to use - so a project does not fail by
  modifying the wrong place (copying standard, editing a fragile exit, or missing
  the right BAdI). Complements /sap-se19 (which IMPLEMENTS a BAdI): this skill
  DECIDES. Three modes, auto-detected: inspect one BAdI / enhancement spot
  (classify classic/new/migrated + list implementations via SXS_ATTR / SXC_* /
  BADI_IMPL); inspect one SMOD enhancement (components via MODSAP + the CMOD
  projects using it via MODACT/MODATTR); or enumerate candidates for a program /
  tcode (enhancement spots + implementations in its package, BAdIs it references
  via the cross-reference index, and user-exit includes). Classifies and scores
  candidates with a TRANSPARENT heuristic (released enhancement interface > BAdI
  > exit > implicit; avoid standard modification), flags risks (multiple active
  implementations, migrated/obsolete BAdIs, no clean enhancement point), and
  emits candidates.tsv + existing_implementations.tsv + a recommended plan,
  registered in the artifact index. The optional business-intent string is
  ADVISORY only - the ranking is structural, not semantic; program-level
  enumeration is non-exhaustive (SE84 is). Read-only; never modifies SAP.
  Prerequisites: SAP profile saved via /sap-login (RFC); SAP NCo 3.1 (32-bit) in GAC.
argument-hint: "BADI <name> | ENHANCEMENT <smod> | PROGRAM <p> | TCODE <t>  [\"<intent>\"]"
---

# SAP Enhancement Advisor Skill

You find WHERE to implement an SAP behavior change and recommend the safest
mechanism. You decide; /sap-se19 and /sap-cmod implement. You are read-only.

Task: $ARGUMENTS

This is the fourth delivery-assurance skill, built on the Phase-0 primitives and
reusing the sap-se19 (BAdI) and sap-cmod (SMOD/CMOD) table knowledge.

---

## Shared Resources

| File | Call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules - read-only here |
| `<SKILL_DIR>/references/sap_enhancement_advisor.ps1` | `-Token [-Intent] [-TypeHint] [-OutputDir]` | The advisor engine |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced by the engine | Resolve program / tcode context |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` | dot-sourced by the engine | Risk findings |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced by the engine | Registers outputs for /sap-evidence-pack |
| `/sap-se19`, `/sap-cmod`, `/sap-impact-analysis` | sub-skills | Implement the recommendation / assess impact |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's `_run.json` log state under `{RUN_TEMP}`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_enhancement_advisor_run.json" -Skill sap-enhancement-advisor -ParamsJson "{}"
```

---

## Step 1 — Parse the Target + Intent

- **`BADI <name>`** / a BAdI / enhancement-spot name -> inspect mode (classify +
  list implementations).
- **`ENHANCEMENT <smod>`** / **`SMOD <name>`** -> SMOD inspect mode (components +
  CMOD projects).
- **`PROGRAM <p>`** / **`TCODE <t>`** / bare name -> enumerate candidates for the
  program.
- A trailing quoted string is the **business intent** (e.g. `"validate PO item
  before save"`) -> pass as `-Intent`. It is echoed in the report but does NOT
  change the ranking.

---

## Step 2 — Run the Advisor Engine

Run via **32-bit PowerShell** (NCo 3.1 in `GAC_32`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_enhancement_advisor.ps1" -Token "TCODE ME21N" -Intent "validate PO item before save"
```

Append `-TypeHint`, `-OutputDir` as needed. Creds resolve from the pinned profile.

Engine output:

```
ADVISOR: context=<O:N> mode=<BADI|SMOD|PROGRAM> candidates=<n> recommended=<name> rectype=<ctype>
PARTIAL: could_not_check=<tables>      (only if some reads were denied)
REPORT_MD / CANDIDATES_TSV / IMPLEMENTATIONS_TSV / RISK_TSV / RISK_JSON: <path>
```

Exit: `0` ok - `1` context not found - `2` RFC failure.

---

## Step 3 — Present the Recommendation

Read `ADVISOR:`, then `REPORT_MD`. Present:

1. **Recommended mechanism** and why (the transparent score + the facts:
   classic/new, released, existing implementations, filters).
2. **Candidate table** — all options with their scores, so the user can override.
3. **Existing implementations** — and whether to EXTEND one or CREATE a new one.
   **Always ask** before creating; **never auto-suffix-bump** a new name (e.g.
   `ZMM_PO_CHECK` vs `ZMM_PO_CHECK_002`) — that is the user's decision.
4. **Risk flags** — multiple active implementations (undefined order),
   migrated/obsolete BAdI (prefer the new one), or "no clean enhancement point"
   (standard-modification risk).
5. **Two mandatory caveats** (never omit):
   - The ranking is **structural/heuristic**, not semantic — verify the
     recommended interface's method signature actually exposes the data the
     intent needs.
   - For PROGRAM mode, enumeration is **non-exhaustive** — implicit enhancements
     and dynamically-called BAdIs are not listed; SE84/SE81 is the exhaustive
     tool. If a `PARTIAL:` line appeared, name the tables that could not be read.

---

## Step 4 — Hand Off

- **BAdI** recommended -> `/sap-se19 create ...` (or display an existing impl).
- **SMOD exit** recommended -> `/sap-cmod ...` (assign + edit + activate project).
- **User-exit include** -> `/sap-se38` to edit the customer include.
- Then `/sap-impact-analysis <impl>` on any active implementation before changing
  behavior, and feed the advice into `/sap-evidence-pack` (already registered in
  the artifact index under this context's scope).

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_enhancement_advisor_run.json" -Status SUCCESS -ExitCode 0
```

(Context-not-found -> `-ExitCode 1 -ErrorClass CONTEXT_NOT_FOUND`; RFC failure ->
`-ExitCode 2 -ErrorClass RFC_LOGON_FAILED`.)

---

## Scope & Limitations (MVP)

- **Solid:** BAdI inspection (classify + implementations) and SMOD inspection
  (components + CMOD projects) reuse verified table knowledge from /sap-se19 and
  /sap-cmod.
- **Best-effort, non-exhaustive:** program/tcode candidate enumeration (package
  enhancement spots/impls, referenced BAdIs via the cross-reference index,
  user-exit includes). Implicit enhancements, dynamically-called BAdIs, and the
  full SMOD-for-transaction list are NOT covered — use SE84/SE81 for exhaustive.
- **Intent is advisory.** No natural-language method matching in the MVP; the
  recommendation is structural. Phase 2: screen-field-aware advice, implicit
  enhancement detection, method-signature surfacing, skeleton generation.
- **Never modifies SAP**, never creates an implementation, never auto-names.
