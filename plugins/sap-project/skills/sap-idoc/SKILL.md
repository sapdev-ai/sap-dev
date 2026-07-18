---
name: sap-idoc
description: |
  Diagnoses and reprocesses failing IDocs — the #1 AMS interface incident class —
  read-only over RFC (no GUI). `find` runs a bounded EDIDC search (status /
  message type / partner / date window / docnum), resolves status texts (TEDS2)
  and severity, and counts failures per status+message type. `explain <DOCNUM>`
  gives the full EDIDS status history for one IDoc — each step with its severity,
  message id, parameters and rendered text — plus an SLG1 cross-reference, so the
  root cause (e.g. "posting period not open", "sold-to party not maintained") is
  read straight off the log. `triage` clusters status-51/56 failures by root cause
  and hands custom-handler clusters to /sap-fix-incident. `reprocess` status-routes
  a DOCNUM / cluster / selection to RBDMANI2 / RBDAPP01 / RSEOUT00 via /sap-run-report
  (confirm-gated) then re-reads EDIDS to verify. Prerequisites: SAP profile via
  /sap-login (RFC); SAP NCo 3.1 (32-bit). No GUI session, no Z-object dependency
  for find/explain/triage.
argument-hint: "find [--dir=1|2] [--status=51,56] [--mestyp=M] [--partner=P] [--from=YYYYMMDD] [--to=YYYYMMDD] [--max=N] | explain <DOCNUM> | triage [find-filters] | reprocess <DOCNUM|--status=..&--mestyp=..>"
---

# SAP IDoc Diagnosis + Reprocess

You diagnose failing IDocs in bulk and reprocess them behind a confirm gate,
read-only over RFC. The work is triage: decode hundreds of status-51/56 IDocs,
cluster them by actual root cause, and reprocess a whole cluster with one gate.

Task: $ARGUMENTS

**You are read-only for `find` / `explain` / `triage`.** The only state change is
`reprocess`, which executes an SAP-standard reprocess report through /sap-run-report
behind an evidence-first confirm gate.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` | *(rule)* | **Rule 0 (highest priority)** — environment guard; enforced by Step 4 via `sap_safety_gate.ps1` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — reads always allowed; reprocess is a SAP-supplied report, gated |
| `<SKILL_DIR>/references/sap_idoc_read.ps1` | `-Action find\|explain [filters\|-Docnum]` | EDIDC find + EDIDS explain (RFC) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` / `sap_object_resolver.ps1` / `sap_artifact_lib.ps1` | dot-sourced by the engine | RFC connect, `Read-SapTableRows`, artifact index |
| `/sap-run-report` | sub-skill | Executes RBDMANI2 / RBDAPP01 / RSEOUT00 (`reprocess`) — owns the execution gate |
| `/sap-diagnose` | related | Triages interface incidents via its `smq` (queues) reader (Wave-0 T1-B); this skill is the IDoc half — invoke directly or as a follow-up |
| `/sap-fix-incident` | sub-skill | Handoff for clusters whose handler is custom (Z/Y) code |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```
Set `{RUN_TEMP}` via `Get-SapRunTemp`.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_idoc_run.json" -Skill sap-idoc -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

| Mode | Args | Access |
|---|---|---|
| `find` | `[--dir=1\|2]` `[--status=..]` `[--mestyp=..]` `[--partner=..]` `[--from=..]` `[--to=..]` `[--max=500]` | **read-only** |
| `explain` | `<DOCNUM>` | **read-only** |
| `triage` | *find-filters* | **read-only** |
| `reprocess` | `<DOCNUM>` or a bounded selection (`--status=` & `--mestyp=`/`--partner=`) | **gated write** |

`find`/`triage` require **at least one bound** (status / mestyp / partner / date /
docnum) — the engine refuses an unbounded scan (`IDOC_SELECTION_UNBOUNDED`).
`test send` / `config-check` / `pointers` and segment-level SDATA **decode** are
**not implemented in v1** (see Scope). If asked, say so and continue.

---

## Step 2 — Ensure the RFC Profile

RFC connection only — no GUI. A profile must be pinned (`/sap-login`). RFC
unavailable → fail loud (`RFC_LOGON_FAILED`), manual pointer WE02/WE05; never a
partial "no IDocs" answer.

---

## Step 3 — `find` (read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_idoc_read.ps1" -Action find -Status "51,56" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutTsv "{RUN_TEMP}\idoc_list.tsv"
```

Parse `IDOC:` rows + `COUNT:` digests + `STATUS: OK rows=<n|">Max"> capped=..`. Render
the per-status × message-type counts first (the triage digest), then the list.
`capped=Y` or `rows=">Max"` → tell the user it's "at least N — narrow the window or
raise `--max`". `IDOC_SELECTION_UNBOUNDED` → ask for a bound and STOP.

## Step 3b — `explain <DOCNUM>` (read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_idoc_read.ps1" -Action explain -Docnum "<DOCNUM>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Parse `HEADER:` + ordered `STEP:` lines. The **last `sev=E` step** carries the root
cause (`text=`). Present the dossier: header (message type, partners, current
status) → status timeline → the error message(s). Then cross-reference SLG1 over the
failure window via `/sap-diagnose --reader slg1` (standalone single-reader mode) for
the application-log detail. `IDOC_NOT_FOUND` → report and STOP.

## Step 3c — `triage` (read-only)

Run `find` with the given filters, then **cluster** the failures. Key each IDoc by
`(MESTYP, STAMID, STAMNO)` — sample one `explain` per distinct message id to get the
error text — and label each cluster with a root-cause hypothesis + count + the
DOCNUM list. Write `{RUN_TEMP}\idoc_clusters.tsv`. A cluster whose `IDOCTP` is custom
(`Z*`/`Y*`) gets a `/sap-fix-incident` handoff line (the handler is custom code).
Rank clusters by count; every cluster names a concrete next step (reprocess-safe vs
fix-data-first vs fix-code).

---

## Step 4 — `reprocess` (gated write)

**Rule 0 first** (`safety_policy.md`; `reprocess` only — `find`/`explain`/`triage` skip it):
`powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-idoc` —
`SAFETY: ALLOW` (0) proceed; `TYPED_CONFIRM_REQUIRED` (3) -> the operator types the shown
`PROD <SID>/<CLIENT>` token, re-run with `-ConfirmationText '<their verbatim answer>'`, proceed only
on `ALLOW_CONFIRMED`; `REFUSED class=<C>` (1) / `ERROR` (2) -> **STOP**, end `FAILED` with
`-ErrorClass <C>`, relay the remediation lines — never bypass or work around it manually. The typed `REPROCESS <count>` confirm below still applies after ALLOW/ALLOW_CONFIRMED.

1. **Route** by status (the current EDIDC status of the target set):
   - inbound error **51 / 56 / 60 / 61 / 63 / 65** → **RBDMANI2**
   - inbound ready-to-post **64 / 66** → **RBDAPP01**
   - outbound ready **30** → **RSEOUT00**
   A set spanning multiple routes → one run per report; a DATA-class cluster (e.g.
   "posting period not open") is warned as **likely to re-fail** until the data/config
   is fixed.
2. **CONFIRM gate (Rule 5)** — show SID/client, the report, the IDoc count + status
   breakdown, and (if any) the cluster id; wait for an explicit `yes`. Typed
   confirmation (`REPROCESS <count>`) when count > 50 or the client is production-grade
   (read T000). `no` → log `SKIPPED`, STOP.
3. **Delegate** `/sap-run-report <REPORT> --background --values="<DOCNUM ranges>"`
   (its own Rule-5 gate follows). Compress the DOCNUM set to ranges.
4. **Verify authoritatively** — re-run `find --docnum` (or `explain`) per IDoc and
   report old→new status. Any IDoc not reaching a success status (53 inbound / 12,16
   outbound) is listed as **FAILED_REPROCESS** (`IDOC_REPROCESS_FAILED`), never
   summarized away as done.

---

## Step 5 — Register Artifacts & Log End

Register `idoc_list.tsv` / the dossier / `idoc_clusters.tsv` via `Register-SapArtifact`
(kind `idoc_list` / `idoc_dossier` / `idoc_clusters`), best-effort. Then:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_idoc_run.json" -Status SUCCESS -ExitCode 0
```

A find/explain that runs — even one full of failures — is `SUCCESS`. Use `-Status
FAILED` with the mapped `-ErrorClass` for the fail-loud STOPs
(`IDOC_SELECTION_UNBOUNDED`, `IDOC_NOT_FOUND`, `RFC_LOGON_FAILED`,
`IDOC_REPROCESS_FAILED`).

---

## Scope & Limitations

- **v1 implemented:** `find` (bounded EDIDC search + status text + severity + per
  status/mestyp counts), `explain` (full EDIDS status history + severity + rendered
  text + SLG1 cross-ref), `triage` (root-cause clustering + custom-handler handoff),
  `reprocess` (status-routed RBDMANI2/RBDAPP01/RSEOUT00 via /sap-run-report,
  confirm-gated, authoritative EDIDS re-read verify). Read-only for find/explain/triage.
- Single code path on ECC 6 and S/4HANA (EDIDC/EDIDS/TEDS2 field names identical).
- **v1.5 (not yet):** segment-level **SDATA decode** in `explain` (via
  `IDOC_READ_COMPLETELY` through the /sap-dev-init `Z_GENERIC_RFC_WRAPPER_TBL` —
  `EDID4` is a CLUSTER table on ECC and is never read directly); `test send` /
  `test assert` (clone + mutate + `IDOC_INBOUND_ASYNCHRONOUS`). EDIDS already carries
  the actionable root cause, so v1 `explain` is useful without segment decode.
- **v2 (not yet):** `config-check` (ALE chain validation) and `pointers`
  (change-pointer health). WE20/WE21/BD64 changes are never automated (advisory only).
- **Honesty:** an unbounded selection is refused; a capped read reports `>Max`; a
  post-reprocess non-success status is reported per IDoc, never as done. Reprocess
  **live execution** is built + gated but its RBDMANI2/RBDAPP01/RSEOUT00
  selection-screen names are confirmed on first live run.
- Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) 2026-07-11 — find (S4D 119
  failures across INVOIC/DESADV/MATMAS/custom ZMSG_BILLING; ERP 206 HRMD_ABA),
  explain (real "posting period not open" / "sold-to party not maintained" histories,
  ZH + JA rendered), unbounded-refusal and not-found guards.
