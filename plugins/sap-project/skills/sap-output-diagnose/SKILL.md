---
name: sap-output-diagnose
description: |
  Root-causes classic NAST output determination — "the invoice didn't print / the
  PO IDoc never went out" — read-only over RFC (no GUI). `billing <VBELN>` and
  `po <EBELN>` walk the whole chain an expert checks by hand: NAST status →
  CMFP processing-log excerpt (rendered via BAPI_MESSAGE_GETDETAIL) → the output
  determination procedure (TVFK-KALSM / T683S) → each access of the access
  sequence (T685/T682I/T682Z) → the generated B* condition tables, rebuilding each
  access key FROM THE DOCUMENT and probing it. Emits a ranked verdict with the
  exact missing condition key (NO_RECORD), the failing requirement routine
  (RV61B<nnn>), or the processing-log error. `reissue` re-drives the output via
  RSNAST00 (confirm-gated, delegated to /sap-run-report) then re-reads NAST to
  verify. S/4 Output Management (BRF+) is disclosed when present. Prerequisites:
  SAP profile via /sap-login (RFC); SAP NCo 3.1 (32-bit). No GUI, no Z-object,
  no /sap-dev-init.
argument-hint: "billing <VBELN> | po <EBELN>  [--type <KSCHL>] [--json] [--out PATH]   |   reissue (billing|po) <DOCNO> <KSCHL>"
---

# SAP Output (NAST) Determination Diagnosis

You root-cause **why an output did (or didn't) go out** for an SD billing document
(KAPPL=V3) or MM purchase order (KAPPL=EF), read-only over RFC. This automates the
20+ SE16 lookups and condition-technique knowledge an output expert applies — NAST
status, the CMFP processing log, the determination procedure, each access of the
access sequence, and the generated B* condition tables — into one ranked verdict.

Task: $ARGUMENTS

**You are read-only against SAP for `billing` / `po`.** The only state change is
`reissue`, which executes RSNAST00 through /sap-run-report behind a confirm gate.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — reads always allowed; the one write (RSNAST00) is a SAP-supplied API, confirm-gated |
| `<SKILL_DIR>/references/sap_output_nast_read.ps1` | `-App billing\|po -DocNo <n> [-Kschl -OutJson]` | Stages 1-3: doc resolve + NAST classify + CMFP log (RFC) |
| `<SKILL_DIR>/references/sap_output_walk.ps1` | `-App billing\|po -DocNo <n> [-Kschl -OutJson -CustomUrl]` | Stages 4-8: procedure/access walk + B* probes + BRF+ (RFC) |
| `<SKILL_DIR>/references/output_field_map.tsv` | read by the walk | Comm-field → header-source override (customer-extensible) |
| `<SKILL_DIR>/references/output_verdicts.md` | maintainer doc | Verdict vocabulary + ranking |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` / `sap_object_resolver.ps1` / `sap_artifact_lib.ps1` | dot-sourced by the engines | RFC connect, `Read-SapTableRows`, artifact index |
| `/sap-run-report` | sub-skill | Executes RSNAST00 (`reissue`) — owns the execution confirm gate |
| `/sap-job` | sub-skill | Checks the RSNAST00 periodic job (batch dispatch) |
| `/sap-explain-object` | sub-skill | Explains a flagged requirement routine `RV61B<nnn>` |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Set `{RUN_TEMP}` via `Get-SapRunTemp` (per-run scratch).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_output_diagnose_run.json" -Skill sap-output-diagnose -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

| Mode | Args | Access |
|---|---|---|
| `billing` | `<VBELN>` `[--type <KSCHL>]` `[--json]` `[--out PATH]` | **read-only** |
| `po` | `<EBELN>` `[--type <KSCHL>]` `[--json]` `[--out PATH]` | **read-only** |
| `reissue` | `(billing\|po) <DOCNO> <KSCHL>` `[--medium <NACHA>]` | **gated write** (RSNAST00) |

`pricing <VBELN> [<POSNR>]` is **Phase 2 (not implemented)** — if asked, say so and
stop. `--type` restricts the walk to one output type. Numeric doc numbers are
zero-padded to 10 digits by the engines.

---

## Step 2 — Ensure the RFC Profile

RFC connection only — no GUI session. A profile must be pinned (`/sap-login`); the
engines self-connect. **RFC unavailable → fail loud** (`RFC_LOGON_FAILED`), never a
partial verdict; suggest `/sap-doctor rfc`.

---

## Step 3 — Read NAST Status + Processing Log (stages 1-3)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_output_nast_read.ps1" -App <billing|po> -DocNo "<DOCNO>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutJson "{RUN_TEMP}\nast.json"
```

Parse:
```
DOC:  app=.. docno=.. exists=<Y|N> type=<FKART|BSART> org=..
NAST: kschl=.. medium=.. vstat=<0|1|2> status=<ISSUED_OK|PROCESSING_FAILED|NOT_YET_PROCESSED> cmfpnr=.. program=.. dispatch=<VSZTP>
LOG:  kschl=.. sev=<E|W|I> msg="<class-nr: rendered text>"
STATUS: OK n_outputs=.. failed=.. notyet=.. | OUTPUT_DOC_NOT_FOUND | RFC_ERROR
```

`OUTPUT_DOC_NOT_FOUND` (exit 1) → tell the user the document doesn't exist, log end
`OUTPUT_DOC_NOT_FOUND`, STOP. Otherwise classify each NAST row:

- **`PROCESSING_FAILED` (VSTAT=2)** — the headline. The `LOG:` line carries the
  rendered root cause (e.g. *"EDI: Partner profile does not exist"*). Report it and,
  if custom code is implicated, offer `/sap-fix-incident`.
- **`NOT_YET_PROCESSED` (VSTAT=0)** — determined but not dispatched. `dispatch`
  (VSZTP) `1` = send via periodically scheduled job → delegate `/sap-job list
  --jobname=RSNAST00*` to confirm the job runs; `3`/`4` = send with app / explicit.
- **`ISSUED_OK` (VSTAT=1)** — nothing wrong; name the `program` (print program/form).

---

## Step 4 — Walk the Determination (stages 4-8)

Run whenever an **expected** output type has **no NAST row** (the "no output"
ticket), or always for a complete picture:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_output_walk.ps1" -App <billing|po> -DocNo "<DOCNO>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -CustomUrl "{custom_url}" -OutJson "{RUN_TEMP}\walk.json"
```

Parse:
```
PROC:  app=.. kalsm=<procedure> steps=<n>
WALK:  kschl=.. access=<Bnnn> result=<RECORD_EXISTS|NO_RECORD|COULD_NOT_CHECK> key="<field=val ...>" knumh=.. nearmiss=<n>
FIND:  kschl=.. verdict=<RECORD_EXISTS|NO_RECORD|MANUAL_ONLY|COULD_NOT_CHECK> detail=".."
BRFPLUS: managed=<Y|N|?|SKIPPED_ECC> ...
STATUS: OK types=.. no_record=.. exists=.. manual=.. cnc=.. req_flagged=.. | RFC_ERROR
```

---

## Step 5 — Assemble the Verdict (you synthesize this)

Per output type, combine the NAST status with the walk finding:

| NAST | Walk | Verdict |
|---|---|---|
| ISSUED_OK | RECORD_EXISTS | **Issued OK** — name the print program |
| PROCESSING_FAILED | (any) | **PROCESSING_FAILED** — root cause = the `LOG:` message |
| NOT_YET_PROCESSED | RECORD_EXISTS | **Pending dispatch** — check the RSNAST00 job (batch) |
| *(no row)* | NO_RECORD | **NO_RECORD** — the exact missing key; point to NACE / VV31 / MN04 to create the record |
| *(no row)* | RECORD_EXISTS + `requirement=true` | **REQUIREMENT_BLOCKED** — the record exists but requirement routine `RV61B<nnn>` suppressed it → `/sap-explain-object RV61B<nnn>` |
| *(no row)* | RECORD_EXISTS (no requirement) | Record exists but no output — likely manually deleted or a downstream determination issue |
| *(any)* | MANUAL_ONLY | Output type is manual-only (no access sequence) |

Rank the overall verdict: **NO_GO** if the expected output is `NO_RECORD` or
`PROCESSING_FAILED`; **GO_WITH_WARNINGS** if BRF+ is present (`BRFPLUS: managed=?` —
disclose that an OM-managed document's NAST verdict may be incomplete) or any
`COULD_NOT_CHECK`; **GO** if issued OK. A `COULD_NOT_CHECK` (unmapped access field /
unreadable B-table) is **never** rendered as NO_RECORD. Render a diagnosis story +,
with `--json`/`--out`, a findings artifact (Step 6). VOFM requirement routines are
**named, never executed** — hand them to `/sap-explain-object`.

---

## Step 6 — Register Artifacts

Register the diagnosis + evidence JSON so `/sap-evidence-pack` collects them (best-effort):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-output-diagnose' -ScopeKey '<VBRK_|EKKO_><docno>' -ScopeKind 'DOC' -Kind 'output_diagnosis' -Format 'md' -Path '<PATH>' -Verdict '<GO|GO_WITH_WARNINGS|NO_GO>' -Coverage '<CHECKED_CLEAN|CHECKED_FINDINGS|COULD_NOT_CHECK>'"
```

---

## Step 7 — `reissue` (gated write)

1. Show the target: SID/client, application, object key, output type, medium; warn
   that re-issue will **PRINT / SEND / transmit again**.
2. **CONFIRM gate (Rule 5)** — wait for an explicit `yes`:
   > I will execute **RSNAST00** on `<SID>/<CLIENT>` to re-issue output `<KSCHL>`
   > (medium `<NACHA>`) for `<DOCNO>`. This sends it again. Proceed? (yes/no)

   `no` → log `SKIPPED`, STOP.
3. Delegate `/sap-run-report RSNAST00 --values "<application/object-key/type/send-again>"`
   (its own Rule-5 gate follows). RSNAST00 selection field names are confirmed once
   via `/sap-run-report variant show` on the first live run.
4. **Verify authoritatively** — re-run `sap_output_nast_read.ps1` for the doc and
   report the new VSTAT (never the report's status text). Still VSTAT=2 →
   `OUTPUT_REISSUE_FAILED` with the fresh log excerpt.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_output_diagnose_run.json" -Status SUCCESS -ExitCode 0
```

A diagnosis that builds — even NO_GO — is `SUCCESS`. Use `-Status FAILED` with the
mapped `-ErrorClass` for the fail-loud STOPs (`OUTPUT_DOC_NOT_FOUND`,
`RFC_LOGON_FAILED`, `OUTPUT_REISSUE_FAILED`).

---

## Scope & Limitations

- **v1 implemented:** `billing` (KAPPL=V3) + `po` (KAPPL=EF) full pipeline —
  NAST status, CMFP processing-log excerpt (BAPI_MESSAGE_GETDETAIL), determination
  walk (procedure → access sequence → B* condition tables) with the access key
  rebuilt **dynamically** from the document (T682Z + partner/​header resolution;
  `output_field_map.tsv` override for customer-exit fields), near-miss surfacing,
  requirement-routine flagging (RV61B<nnn>), and the S/4 BRF+ Output-Management
  disclosure. `reissue` via RSNAST00 (confirm-gated). Read-only for diagnosis.
- Single code path on ECC 6 and S/4HANA (all 19 v1 tables + 3 FMs probed identical);
  BRF+ stage is S/4-only via the `APOC_D_OR_ROOT` existence gate (skipped, not
  errored, on ECC).
- **Phase 2 (not yet):** `pricing <VBELN> [<POSNR>]` (VA03-style access-sequence
  walk over A* tables, KONV↔PRCD_ELEMENTS — KONV is a CLUSTER table on ECC so those
  reads must be fully KNUMV-keyed); sales-order (V1) / delivery (V2) apps (field-map
  rows only). `reissue` **live execution** is built + gated but its RSNAST00
  selection-screen names are confirmed on first live run.
- **Honesty:** an unmapped access key field or unreadable B-table is
  `COULD_NOT_CHECK`, never NO_RECORD; a BRF+-managed document caps the verdict at
  GO_WITH_WARNINGS (the NAST story is not complete); VOFM routines are named, never
  evaluated.
- Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) 2026-07-11 — billing on
  both (incl. a real VSTAT=2 "EDI partner profile does not exist" and a 41-step IDES
  procedure), po on ERP (NEU/NEUS, requirement routines, JA-rendered log), and the
  not-found negative.
