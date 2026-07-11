---
name: sap-spau-triage
description: |
  Pre-assembles the SPDD/SPAU modification-adjustment worklist for an upgrade or S/4
  conversion and produces an ADVISORY classification per entry (adopt / reset-candidate /
  re-implement / unclear) with cited evidence, confidence, and effort band — so the upgrade
  team walks into the weekend with a triaged list instead of a blank SPAU tree, and the
  single biggest schedule risk (deciding reset-vs-adopt per entry under time pressure) is
  front-loaded. Read-only, pure RFC (NCo 3.1, 32-bit): scan builds the worklist from SMODILOG
  (aggregated per modified object) joined to ADIRACCESS access keys + TADIR packages;
  --deep pulls before/after version source via the SVRS FMs for AI diff commentary; inspect
  is a single-entry dossier. A deterministic offline classifier (rule table R1-R6 via the
  finding lib) fixes class/confidence/coverage BEFORE any LLM prose, so a recommendation
  never depends on model mood, and a reset-candidate is HIGH only with SVRS source-equal
  proof (note evidence is advisory LOW, never a reset on its own). It NEVER executes
  SPAU/SPDD — every recommendation is advisory in v1; a wrong "reset" deletes a customer
  modification, so every reset row cites its evidence and carries "verify in SPAU first".
  Fail-loud tri-state (unreadable versions / missing fields => COULD_NOT_CHECK, never a
  silent classify). No Z objects, no GUI (SPAU's driver diverges by release: SPAU_UI_START
  on 1909 vs RSUMOD04 on ECC6). Prerequisites: pinned RFC profile via /sap-login; NCo 3.1.
argument-hint: "scan [--package=<mask>] [--user=<mask>] [--since=YYYYMMDD] [--max=500] [--deep [--deep-max=25]] | inspect <OBJ_TYPE> <OBJ_NAME> [--deep]"
---

# SAP SPAU/SPDD Triage Skill

You pre-triage the modification-adjustment worklist an upgrade will present in SPAU/SPDD:
assemble the machine-readable evidence (modification log, access keys, version directory,
note status) over RFC, classify each entry with a deterministic rule table, and write an
ADVISORY report. You NEVER execute SPAU/SPDD and never reset a modification.

Task: $ARGUMENTS

The class/confidence/coverage of each entry is computed by `sap_spau_classify.ps1`
(deterministic); **you** write the per-entry rationale and (--deep) diff commentary on top.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_spau_rfc.ps1` | `-Action worklist\|versions\|notes` | RFC backend (SMODILOG/ADIRACCESS/TADIR/SVRS/CWBNT*) |
| `<SKILL_DIR>/references/sap_spau_classify.ps1` | `-WorklistTsv -VersionsTsv -NotesTsv -OutFile` | Offline deterministic classifier (R1-R6) |
| `<SKILL_DIR>/references/sap_spau_classify.tests.ps1` | offline | R1-R6 fixture corpus (7 cases) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced | Package/type resolution |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | `Register-SapArtifact` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` | dot-sourced | tri-state coverage model |
| `/sap-enhancement-advisor` | sub-skill | `route` re-implement candidates (v1.5) |
| `/sap-login` | sub-skill | Pinned RFC profile (no GUI session needed) |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_spau_triage_run.json" -Skill sap-spau-triage -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

Modes: `scan` (default) | `inspect <OBJ_TYPE> <OBJ_NAME>` | `route` (v1.5 -> hard ERROR "not
yet shipped"). Flags: `--package=<mask>`, `--user=<mask>`, `--since=YYYYMMDD`, `--max=<n>`
(default 500), `--deep [--deep-max=<n>]` (default 25). No GUI session is required — say so.

## Step 2 — RFC Preflight

Needs a pinned RFC profile (`/sap-login`). Read `server_release_marker` to annotate the
report (S/4: "new SPAU UI SPAU_UI_START; adjustment-free period applies" vs ECC: "classic
RSUMOD04/RSUMOD02 SPAU"). SE95 (`SAPRMOMO`) is the stable manual cross-check tcode on both.

## Step 3 — Build the Worklist (scan) / locate the entry (inspect)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_spau_rfc.ps1" -Action worklist -PackageMask "<mask>" -UserMask "<mask>" -Since "<YYYYMMDD>" -Max <n> -OutFile "{RUN_TEMP}\spau_worklist_raw.tsv" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Parse `WORKLIST: n=<k> partial=<0|1>`. `n=0` -> report "no adjustment-relevant modifications
found" with the filters echoed — a SUCCESS with n=0, never a fabricated entry. `partial=1`
-> the `--max` cap was hit; mark the report coverage PARTIAL. `SPAU_WORKLIST_READ_FAILED`
(exit 1) -> abort, no partial TSV registered.

## Step 4 — Version Evidence (--deep, always for inspect)

For the selected entries (cap `--deep-max`) run `-Action versions -ObjType <t> -ObjName <n>
-DeepMax 1 -OutDir "{RUN_TEMP}\versions"`; collect `VERSIONS:` (count, newest) + the
`active`/`newest` `.abap` source pair per object. Build a versions TSV (`obj_type`,
`obj_name`, `equal_source` Y/N from a normalized-source hash compare, `numbered`) to feed the
classifier's R1.

## Step 5 — Note Evidence (advisory)

For note-referencing entries run `-Action notes -Notes "<n1,n2,...>"`; every `NOTE:` line
carries `semantics=ADVISORY`. Build a notes TSV (`num`, `status`) for the classifier's R2.

## Step 6 — Classify (deterministic)

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_spau_classify.ps1" -WorklistTsv "{RUN_TEMP}\spau_worklist_raw.tsv" -VersionsTsv "{RUN_TEMP}\versions.tsv" -NotesTsv "{RUN_TEMP}\notes.tsv" -OutFile "{OUT}\spau_triage.tsv"
```

Parse `TRIAGE: reset=<n> adopt=<n> reimplement=<n> unclear=<n>`. Rule table (evidence-cited,
precedence first-match): **R6** conflict (source-equal reset signal + access-key registration)
-> unclear; **R1** source-equal (SVRS hash match) -> reset-candidate HIGH; **R2** this object's
own note completed in CWBNTCUST -> reset-candidate LOW (ADVISORY); **R4** FUGR/FUNC
enhancement-adjacent -> re-implement MEDIUM (routed v1.5); **R3** note-mod without linkage ->
adopt LOW COULD_NOT_CHECK, else modification-assistant change -> adopt MEDIUM; **R5** no
evidence / unknown -> unclear COULD_NOT_CHECK. A reset-candidate is HIGH **only** with a live
version source-equal proof — never on note evidence alone.

## Step 7 — Render + Register

Then **you** write `spau_triage.md`: per-class counts, per-package rollup, the entry table
(with each row's `class/confidence/effort/coverage/rationale`), the SPAU_ENH-flagged list, and
an SE95 cross-check footer. In `--deep`, read each before/after `.abap` pair and add diff
commentary (what the mod does, whether standard now covers it). **Every reset-candidate row
MUST carry its evidence citation and the literal "ADVISORY - verify in SPAU before resetting";
the report header carries the same disclaimer.** Register both files:

```bash
powershell -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-spau-triage' -ScopeKey '<SCOPE_KEY>' -Kind 'spau-triage-report' -Format 'md' -Path '{OUT}\spau_triage.md' -Coverage '<CHECKED|PARTIAL|COULD_NOT_CHECK>'"
```

Advisory outputs carry coverage, not a GO/NO_GO gate verdict.

## Step 8 — route (v1.5, not yet shipped)

For each re-implement candidate, invoke `/sap-enhancement-advisor PROGRAM <p>` via the Skill
tool and merge its plan reference into the triage TSV/MD.

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_spau_triage_run.json" -Status SUCCESS -ExitCode 0
```

`SPAU_WORKLIST_READ_FAILED` / `SPAU_VERSION_READ_FAILED` / `RFC_LOGON_FAILED` on the failure
paths. An empty worklist is `SUCCESS`, not an error.

---

## Scope & Limitations (v1)

- **v1 implemented:** `scan` (worklist + deterministic classify + report), `scan --deep`
  (version source pairs + AI diff commentary), `inspect` (single-entry dossier). Pure RFC,
  read-only, no GUI, no Z objects.
- **Live-verified on S4D (S/4HANA 1909):** the worklist read returned **500 real
  modification entries** (note-implementation mods on standard classes, packages resolved via
  TADIR, TRKORRs/users/dates captured); the version chain returned a real directory
  (n=60, newest v59) and `--deep` fetched genuine active + v59 ABAP source; notes returned
  honest NOT_DOWNLOADED. The classifier's rule table passes a **7-case offline fixture**
  (R1 HIGH reset only with version proof, R6 conflict beats R1, R2 needs precise per-object
  note linkage, note-without-linkage -> adopt/COULD_NOT_CHECK, R4 re-implement, R3 adopt,
  R5 unclear) and ran clean over the real 500-entry worklist (473 adopt / 27 re-implement).
  SMODILOG is **client-independent** (no MANDT) on S4D — the backend reads it accordingly.
- **Advisory contract (safety):** a wrong reset deletes a customer modification, so
  reset-candidate is HIGH only with SVRS source-equal proof, R2 note evidence is capped LOW
  and `semantics=ADVISORY`, and every reset row + the report header carry "verify in SPAU
  before resetting". The classifier refuses to emit a class without a rationale.
- **Not yet validated:** end-to-end classification ACCURACY against a real post-upgrade
  worklist (the dev box has redundant note-mods, not a live SPAU adjustment queue) — the
  README marks the skill BETA/advisory until the pre-GA gate (>=50 entries, >=90% of HIGH
  reset-candidates confirmed by a human expert, zero HIGH refuted) passes on a project system.
- **Deferred:** `route` (v1.5, /sap-enhancement-advisor merge); `compare --against` cross-system
  (v2); GUI navigation assist (v2 — needs per-release recordings, SPAU_UI_START vs RSUMOD04).
- ECC 6 shares the identical RFC data path (all tables + SVRS FMs probed identical); only the
  report's release-marker wording differs. No variant scripts.
