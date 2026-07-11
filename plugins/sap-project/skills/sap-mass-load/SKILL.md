---
name: sap-mass-load
description: |
  Loads CSV/XLSX mass data into SAP through ONE explicit backend per run — a named BAPI called
  directly over RFC, or (v1) an SHDB recording looped through ABAP4_CALL_TRANSACTION — with the
  orchestration/UX layer that MASS/XD99/LSMW lack and LTMC (Fiori-only, unreachable from this stack)
  can't give a consultant: an AI-proposed column->field mapping from live DDIC texts that REQUIRES
  operator approval, RFC pre-validation of key lookups (T001W/T052/KNA1/MARA...) before anything is
  written, a mandatory dry-run report, a typed row-count/client confirm gate, a NON-OVERRIDABLE
  production-client refusal (T000 CCCATEGORY='P'), and a per-row ledger that makes a 2,000-row load
  safely re-runnable (resume retries only FAILED/PENDING rows; OK rows SKIPPED). Every write goes
  through a BAPI + BAPI_TRANSACTION_COMMIT (or CALL TRANSACTION) with a per-row commit/rollback and an
  authoritative re-read of a sample of created keys — never raw SQL. Entirely RFC in v1 (no GUI, no Z
  artefacts); FMODE-blank FM targets refuse with a v1.5 pointer. Prerequisites: pinned RFC profile via
  /sap-login (its SID/client IS the load target); NCo 3.1 (32-bit). A production client ends the skill.
argument-hint: "plan <file.csv|.xlsx> (--target-bapi <FM> | --target-bdc <rec>) [--key-cols C1,C2] [--sheet N] | validate <run-dir> | execute <run-dir> [--max-rows N] | resume <run-dir> | status <run-dir>"
---

# SAP Mass-Load Skill

You load mass data safely: propose a mapping (operator-approved), pre-validate keys over RFC, force a
dry-run, gate the write behind a typed confirm, refuse production clients, and keep a resumable per-row
ledger. Every write is a BAPI/CALL-TRANSACTION with per-row commit — never raw SQL.

Task: $ARGUMENTS

The client guard, interface introspection, validation, and the BAPI row loop are scripts; **you**
propose the mapping and run the confirm gates.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_mass_load_rfc.ps1` | `-Action clientguard\|interface\|validate` | Read-only core (guard + target introspection + dry-run) |
| `<SKILL_DIR>/references/sap_mass_load_execute.ps1` | `-DryRun` / live | BAPI row-loop executor (gated write) + ledger |
| `<SKILL_DIR>/references/mass_load_checktables.tsv` | read | Key-existence check tables (field -> table,keyfield) |
| `<SKILL_DIR>/references/mass_load_target_advisories.tsv` | read | Per-target release advisories (shown in the gate) |
| `/sap-call-bdc` | sub-skill | the `--target-bdc` recording format + BDCMSGCOLL vocabulary |
| `/sap-login` | sub-skill | Pinned RFC profile (= the load target SID/client) |

---

## Step 0 — Resolve Work Directory

Resolve `work_dir` + `{RUN_TEMP}`; run folder = `{work_dir}\mass_load\<run_id>\` (survives the
plan->validate->execute turns).

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_mass_load_run.json" -Skill sap-mass-load -ParamsJson "{}"
```

## Step 1 — Parse Args + Client Guard

Mode dispatch: `plan` | `validate` | `execute` | `resume` | `status`. Every mode except `status` runs
the client guard FIRST:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_mass_load_rfc.ps1" -Action clientguard -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

`STATUS: MASS_LOAD_CLIENT_REFUSED` (production client OR unreadable T000) -> STOP, non-overridable.

## Step 2 — plan

Flatten/parse the input (CSV/TSV native; `.xlsx` via the /sap-docs-extract reader, `--sheet`),
snapshot to the run folder + record its SHA256. Introspect the ONE target:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_mass_load_rfc.ps1" -Action interface -TargetBapi <FM> -OutFile "{RUN}\interface.tsv" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

`MASS_LOAD_TARGET_UNSUPPORTED` (blank FMODE) -> STOP, point at v1.5. Then **you** propose the
mapping (`input_col -> target(param or STRUCT-FIELD), DDIC text, length, CONVEXIT, rule MOVE|CONST|SKIP,
key_flag`) in chat, showing the matching `mass_load_target_advisories.tsv` warnings. An unmapped column
needs an explicit map/ignore decision — never silently dropped. On explicit operator approval, write
`mapping.tsv` + the approval hash into `run.json`.

## Step 3 — validate (mandatory before execute)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_mass_load_rfc.ps1" -Action validate -InputFile "{RUN}\input_snapshot.csv" -KeyCols "<biz-key-cols>" -KeyChecks "<COL=FIELD,...>" -CheckTablesFile "<SKILL_DIR>\references\mass_load_checktables.tsv" -OutFile "{RUN}\dryrun_report.tsv" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

`VERDICT: BLOCKED` (missing keys, duplicate business keys, or a key lookup that COULD_NOT_CHECK) ->
execute refuses. Derive `-KeyChecks` from the approved mapping (each key column -> its DDIC field).

## Step 4 — execute (typed gate; the only write)

Pre-flight: approved mapping present, input hash unchanged, dry-run READY and newer than mapping, row
count <= cap. **Typed confirm gate:** show target SID/client, client category, target BAPI, backend,
row count, 3 sample mapped rows, advisory warnings; require the user to type `LOAD <row-count>
<SID>/<CLIENT>` verbatim (a `--max-rows` raise above 1000 is re-confirmed separately). Then:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_mass_load_execute.ps1" -TargetBapi <FM> -InputFile "{RUN}\input_snapshot.csv" -MappingFile "{RUN}\mapping.tsv" -KeyCols "<cols>" -LedgerFile "{RUN}\ledger.tsv" -MaxRows <N> -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

(Add `-DryRun` to preview the built calls without writing.) Per row: build the BAPI params from the
mapping, invoke, evaluate RETURN, E/A -> ROLLBACK + ledger FAILED, else COMMIT WAIT='X' + ledger OK.
Then authoritative re-read: sample N OK keys via RFC_READ_TABLE against the target table (MARA/KNA1/...)
— a mismatch flags the ledger row VERIFY_FAILED.

## Step 5 — resume / status

`resume` -> the executor with `-Resume` (OK rows SKIPPED, FAILED/PENDING re-run after re-validating
their keys). `status` -> render `ledger.tsv` totals + failure clusters (no SAP contact).

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_mass_load_run.json" -Status SUCCESS -ExitCode 0
```

Classes: `MASS_LOAD_CLIENT_REFUSED`, `MASS_LOAD_TARGET_UNSUPPORTED`, `MASS_LOAD_MAPPING_UNAPPROVED`,
`MASS_LOAD_STALE_DRYRUN`, `MASS_LOAD_ROW_CAP`, `RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **v1 implemented:** plan (introspect + AI mapping + approval), validate (key pre-check + dup + dry-run),
  execute (BAPI row loop, per-row commit/rollback, ledger), resume (idempotent subset), status. Pure
  RFC, one target per run.
- **Live-verified on S4D (S/4HANA 1909):** the read-only safety core is proven — `clientguard` returned
  cat=T (would REFUSE non-overridably on 'P' or an unreadable T000); `interface` reported
  BAPI_MATERIAL_SAVEDATA FMODE=R with 51 params, and a blank-FMODE FM correctly hit
  MASS_LOAD_TARGET_UNSUPPORTED; `validate` on a fixture (duplicate MATERIAL + a bad PLANT `ZZ99`)
  returned **BLOCKED** with the dup-key BLOCKER and the T001W key-existence BLOCKER. The executor's
  `-DryRun` built the correct per-row BAPI calls (STRUCT-FIELD mapping -> HEADDATA/CLIENTDATA/PLANTDATA
  structs) and wrote the ledger — **without any SAP write**.
- **Deliberately NOT run autonomously:** the LIVE execute (real BAPI writes + commits) is behind the
  typed `LOAD <n> <SID>/<CLIENT>` gate — this session verified the guard, introspection, validation, and
  dry-run paths, not a live data load. The production-client refusal is non-overridable.
- **Honesty invariants:** a key lookup that can't run -> COULD_NOT_CHECK -> dry-run BLOCKED (never a
  silent pass); unapproved/stale mapping or hash drift -> refuse; every write is a BAPI+COMMIT with a
  per-row ledger and a sampled re-read (no raw SQL, Rule 1). All target BAPIs probed FMODE=R, so v1 needs
  no Z objects (Rule 2); FMODE-blank targets are the v1.5 wrapper path.
- **Deferred:** `--group-by` multi-row documents, FMODE-blank-via-wrapper, failure clustering in status
  (v1.5); `--backend=sm35` + the GUI-loop backend for BAPI-less targets (v2). ECC 6 shares the identical
  path (all 19 objects probed identical; live MATNR length read per system); EC2 was unavailable this
  session for the ECC re-confirm.
