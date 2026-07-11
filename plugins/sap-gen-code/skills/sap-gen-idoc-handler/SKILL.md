---
name: sap-gen-idoc-handler
description: |
  Generates a CORRECT inbound IDoc processing function module from two machine-readable inputs — the
  IDoc type's segment metadata (IDOCTYPE_READ_COMPLETE) and a field-mapping spec — plus a golden
  template that encodes the trap-rich protocol once: the fixed EDIDC/EDIDD/BDIDOCSTAT/BDWFRETVAR
  signature WE57 demands, the per-DOCNUM packet loop (the classic mass-processing junior trap), typed
  segment decode, the 53(ok)/51(error) status-record-per-IDoc protocol, RETURN_VARIABLES, and BAL
  application-log hooks — with a seeded ABAP Unit test that proves status 53 on the happy path BEFORE
  anything is wired. generate is read-only through generation (metadata read + offline template fill +
  offline /sap-check-abap) then a Rule-2-gated deploy delegated to /sap-function-group + /sap-se37 +
  /sap-se38, verified by /sap-run-abap-unit; the WE57/BD51/WE42/WE20 wiring is emitted as numbered
  operator instructions (NEVER auto-written — those are SAP-standard config tables). verify-wiring is a
  read-only RFC check of EDIFCT/TBD51/TEDE2/EDP21 that reports PRESENT/MISSING/COULD_NOT_CHECK per
  expected row + a WIRED/PARTIAL/UNWIRED verdict. One golden template serves ECC 6 and S/4 (release ABAP
  level from the customer brief). No new Z helper objects (the generated FM is the deliverable).
  Prerequisites: pinned RFC profile via /sap-login; NCo 3.1 (32-bit); a GUI session only for deploy.
argument-hint: "generate <mapping.tsv> --idoctype <BASICTYPE> [--message-type <MESTYP>] [--fm-name Z_IDOC_INPUT_X] [--fugr FG] [--bapi BAPI] [--deploy ask|yes|no] | verify-wiring <FM> --idoctype <BT> --message-type <MT> [--process-code PC] [--partner P --partner-type LS|KU|LI]"
---

# SAP Generate IDoc Handler Skill

You generate a correct inbound IDoc handler FM (+ seeded ABAP Unit test) from IDoc-type metadata and a
mapping spec, deploy it behind a confirm gate through the workbench skills, and check its WE57/BD51/WE42
wiring — read-only until the gated deploy, and never auto-writing the SAP-standard config tables.

Task: $ARGUMENTS

The metadata read + wiring check are scripts; **you** fill the golden template (`references/
idoc_inbound_handler_template.abap`) + test template from the segment tree and mapping spec.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_idoc_type_read.ps1` | `-IdocType <BT>` | Segment-tree metadata (IDOCTYPE_READ_COMPLETE) |
| `<SKILL_DIR>/references/sap_idoc_wiring_check.ps1` | `-FmName ...` | verify-wiring RFC read (EDIFCT/TBD51/TEDE2/EDP21) |
| `<SKILL_DIR>/references/idoc_inbound_handler_template.abap` | template | Golden handler (fixed signature + protocol) |
| `<SKILL_DIR>/references/idoc_inbound_test_template.abap` | template | Seeded ABAP Unit test |
| `<SKILL_DIR>/references/idoc_mapping_template.tsv` | template | Mapping-spec input shape |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lookup_struct.ps1` · `sap_rfc_lookup_fm.ps1` | shared | segment struct + BAPI signature |
| `/sap-check-abap` · `/sap-function-group` · `/sap-se37` · `/sap-se38` · `/sap-run-abap-unit` | sub-skills | gate + gated deploy + test |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_gen_idoc_handler_run.json" -Skill sap-gen-idoc-handler -ParamsJson "{}"
```

## Step 1 — Parse Arguments + Validate Spec

Modes: `generate` | `verify-wiring`. Validate FM/report names via `sap_check_object_name.ps1`. Load
the mapping spec; unknown `rule` token or missing `target` -> `IDOC_MAPPING_INVALID` (fail loud).

## Step 2 — verify-wiring (read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_idoc_wiring_check.ps1" -FmName <FM> -IdocType <BT> -MessageType <MT> [-ProcessCode <PC>] [-Partner <P> -PartnerType <LS|KU|LI>] -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Render the `WIRING:` lines + `VERDICT:` (WIRED / PARTIAL / UNWIRED / COULD_NOT_CHECK). A read that
errors is COULD_NOT_CHECK, never a false PRESENT. Done.

## Step 3 — generate: metadata

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_idoc_type_read.ps1" -IdocType <BT> [-CimType <EXT>] -OutFile "{WORK}\<name>_idoc_segments.tsv" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

`IDOC_TYPE_NOT_FOUND` -> abort. Cross-check every mapping-spec segment against the tree — a spec
segment not in the tree is a HARD error naming the segment (never silently generate a bad decode).

## Step 4 — Resolve structures + BAPI signature

`sap_rfc_lookup_struct.ps1` on each mapped SEGMENTTYP (they are plain DDIC structures) + `sap_rfc_lookup_fm.ps1`
on `--bapi`; `sap_error_hints.ps1 -Action resolve` for trap hints (frequently_errors loop).

## Step 5 — Generate (offline, you)

Fill `idoc_inbound_handler_template.abap` -> `<name>_handler.abap` (per-mapping `WHEN '<SEG>'` decode
blocks, the BAPI call from the mapped fields, MSG_CLASS from the customer brief; release ABAP level per
the brief for an ECC target) and `idoc_inbound_test_template.abap` -> `<name>_test.abap` (canned EDIDD
from `sample_value`). Write `<name>_wiring_instructions.md` (numbered WE57/BD51/WE42/WE20 steps).

## Step 6 — Offline gate

`/sap-check-abap` on both sources; loop fixes until clean.

## Step 7 — Deploy (Rule-2 confirm gate)

`--deploy no`/silence -> SKIPPED (sources stay local). `yes` (or an explicit confirm to the `ask`
prompt listing FM / FG / test report / target system) -> `/sap-function-group` (ensure) -> `/sap-se37`
(FM) -> `/sap-se38` (test report); TRs resolve inside those skills. Then `/sap-run-abap-unit
Z<FM_STEM>_TEST` and report per-method pass/fail.

## Step 8 — Wiring

Print the wiring instructions and run `sap_idoc_wiring_check.ps1` (read-only) — expected mostly MISSING
on a fresh FM (that IS the operator TODO list). NEVER auto-write EDIFCT/TBD51/TEDE2/EDP21 (Rule 1:
SAP-standard config tables; `/sap-update-addon` is Y/Z-only).

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_gen_idoc_handler_run.json" -Status SUCCESS -ExitCode 0
```

Classes: `IDOC_TYPE_NOT_FOUND`, `IDOC_MAPPING_INVALID`, `IDOC_WIRING_INCOMPLETE`, `RFC_LOGON_FAILED`,
`AUNIT_*` (from the delegated test).

---

## Scope & Limitations (v1)

- **v1 implemented:** `generate` (metadata -> golden-template fill -> offline check -> gated deploy ->
  ABAP Unit -> wiring instructions) and `verify-wiring` (read-only EDIFCT/TBD51/TEDE2/EDP21 check).
- **Live-verified on S4D (S/4HANA 1909):** `sap_idoc_type_read.ps1` read **MATMAS05 -> 28 segments,
  7 mandatory** (E1MARAM must/max1, E1MAKTM must/max99, ...) with an honest `IDOC_TYPE_NOT_FOUND` on a
  fake type. `sap_idoc_wiring_check.ps1` correctly returns **UNWIRED** for a fake FM (all MISSING) and
  detects a real inbound FM's `TBD51` registration — with the `@($null).Count==1` trap fixed so an
  errored read is COULD_NOT_CHECK, never a false PRESENT. (On S/4 1909, classic MATMAS inbound is
  BAPI-ALE via BOR `BUS1001006`, so `IDOC_INPUT_MATMAS01` is legitimately EDIFCT-MISSING there — the
  checker reflects that honestly rather than inventing a match.) The golden handler + test templates
  encode the packet loop + 53/51 protocol + BAL + RETURN_VARIABLES once, correctly.
- **Deliberately NOT run autonomously:** the deploy step (SAP writes via /sap-se37 + /sap-se38) and the
  ABAP Unit run are confirm-gated and delegated — this session verified the metadata + wiring + template
  paths, not a live class deploy. The SAP-standard wiring tables are NEVER auto-written (operator
  instructions + read-only check only).
- **Honesty invariants:** spec segment not in the tree -> hard error; unknown IDoc type ->
  IDOC_TYPE_NOT_FOUND; a wiring read that fails -> COULD_NOT_CHECK (never WIRED); deploy declined ->
  SKIPPED, sources on disk.
- **Deferred:** `generate --outbound` (v2); automated `wire` (v2 — needs a writable API for EDIFCT/TEDE2,
  open question); CIMTYP extension test (needs a live extension type); end-to-end IDoc inject test via
  /sap-idoc's v1.5 inbound leg (v1 verification = ABAP Unit). ECC 6 shares the identical read path (all
  22 objects probed identical); EC2 was unavailable this session for the ECC re-confirm.
