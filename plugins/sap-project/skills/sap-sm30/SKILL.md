---
name: sap-sm30
description: |
  Maintains standard customizing views/tables via SM30 — the functional consultant's core write
  the suite couldn't do (/sap-update-addon covers only Y/Z tables and refuses table-control
  layouts). show resolves the maintenance object over RFC (TVDIR dialog registration incl.
  one-step vs two-step type + generated function group, DD25L view class, DD26S base tables ->
  primary, DD27S view-field -> base-field + key flags, TDDAT auth group, T000 client
  modifiability) and pre-reads the current rows, so you see the DDIC shape + data before any
  write. add (New Entries) and update (Position+edit) drive SM30's own generated maintenance
  dialog through a generic GuiTableControl driver (columns mapped by the DD27S field names in the
  cell IDs, not hardcoded — the per-view screens are generated), behind a confirm-gated preview
  diff, with the Customizing TR resolved via /sap-transport-request --type customizing, and
  verified by an authoritative RFC re-read (a write that the re-read doesn't confirm is
  SM30_VERIFY_MISMATCH). v1 = one-step views only (two-step refused loud); delete is never offered.
  RFC reads are direct (no wrapper, no dev-init); the only write channel is SM30's sanctioned
  dialog (no SQL on standard tables). Single code path ECC6 + S/4 (SAPMSVMA on both). Prerequisites:
  pinned /sap-login RFC profile; a live GUI session for add/update; NCo 3.1 (32-bit).
argument-hint: "show <VIEW|TABLE> [--where \"F=V,...\"] | add <VIEW> --data rows.tsv | update <VIEW> (--data rows.tsv | --key K=V --set F=V)"
---

# SAP SM30 View Maintenance Skill

You maintain a standard customizing view: `show` resolves + pre-reads (read-only); `add`/`update`
drive SM30's generated dialog behind a preview diff + confirm gate + Customizing TR, verified by
an RFC re-read. v1 is one-step views only; delete is refused.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_sm30_read.ps1` | `-Action resolve\|preread` | RFC resolve + pre-read + verify |
| `<SKILL_DIR>/references/sap_sm30_maintain.vbs` | GUI (`%%SESSION_PATH%%`·`%%ATTACH_LIB_VBS%%`·`%%SESSION_LOCK_VBS%%`·`%%PARAMS_FILE%%`·`%%OUTPUT_FILE%%`) | Generic table-control driver (add / update) — recorded + live-verified on S4D (S/4HANA 1909) 2026-07-12 |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_attach_lib.vbs` · `sap_session_lock.vbs` | libs | RFC + Tier-3 attach + write lock |
| `/sap-transport-request` (`--type customizing`) · `/sap-doctor` · `/sap-se16n` | sub-skills | Customizing TR / srv+auth preflight / wide-view export |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_sm30_run.json`). Pinned RFC profile; GUI session for add/update.

## Step 1 — Parse & Dispatch

`show` (read) | `add` | `update` (write). `delete` -> refuse `SM30_DELETE_UNSUPPORTED` (pointer to
manual SM30). Validate the `--data` TSV header against the DD27S field list early.

## Step 2 — Resolve (always)

```bash
... sap_sm30_read.ps1 -Action resolve -Object <V> -OutDir "{RUN_TEMP}\sm30"
```

`SM30INFO:` lines (kind / maint_type / function_group / primary_table / fields / keys / auth_group
/ client_category) + `SM30: VERDICT`. Refuse loud on: no TVDIR entry (`SM30_NO_MAINT_DIALOG`),
`maint_type=2` (`SM30_TWO_STEP_UNSUPPORTED`, v1), client not modifiable (`SM30_CLIENT_NOT_MODIFIABLE`
from T000). `show` -> also `preread` (below) then STOP.

## Step 3 — Pre-read + preview diff (add/update)

`sap_sm30_read.ps1 -Action preread` snapshots the current rows (projected to the view's base
fields, `--where`-filtered). Build the change set from the `--data` TSV / `--set`; render the
preview diff (ADD n / CHANGE m, old->new per field). Reject an add whose key exists or an update
whose key is absent — no silent upsert.

## Step 4 — CONFIRM gate + TR

**CONFIRM** (yes/no on dev/QA; typed `MAINTAIN <VIEW> ON <SID>/<CLIENT>` when T000 marks the client
production-grade). On no -> `SKIPPED`. Resolve the Customizing TR via `/sap-transport-request
--type customizing` (never prompt, never a Workbench TR; a blank TR at the KO008 popup aborts).

## Step 5 — Drive SM30 + verify

The generic table-control driver `sap_sm30_maintain.vbs` is **recorded + live-verified on S4D
(S/4HANA 1909) 2026-07-12** (no longer `NEEDS_RECORDING`). Its per-run parameters ride a `PARAMS_FILE`
(KEY=VALUE: `VIEW` / `MODE=add|update` / `DATA_FILE` / `TRKORR`), so the run-time VBS carries only the
Tier-3 + IO tokens. `DATA_FILE` = the TSV whose header row = DD27S FIELDNAMEs (**key fields first**, in
key order) and each later row = one entry; MANDT/CLIENT are auto and skipped. Substitute the attach +
lock + IO tokens, set `SAPDEV_SESSION_PATH` (parallel-safe attach contract), write UTF-16 LE, and run
via **32-bit cscript**:

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
. "$shared\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
# PARAMS_FILE lines: VIEW=<name>  MODE=add|update  DATA_FILE=<abs tsv>  TRKORR=<customizing-TR-or-empty>
$vbs = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_sm30_maintain.vbs', [Text.Encoding]::UTF8)
$vbs = $vbs.Replace('%%ATTACH_LIB_VBS%%',   "$shared\sap_attach_lib.vbs")
$vbs = $vbs.Replace('%%SESSION_LOCK_VBS%%', "$shared\sap_session_lock.vbs")
$vbs = $vbs.Replace('%%SESSION_PATH%%',     '')   # or the --session value
$vbs = $vbs.Replace('%%PARAMS_FILE%%',      '{RUN_TEMP}\sm30_params.txt')
$vbs = $vbs.Replace('%%OUTPUT_FILE%%',      '{RUN_TEMP}\sm30_result.json')
[IO.File]::WriteAllText('{RUN_TEMP}\sm30_maintain_run.vbs', $vbs, [System.Text.UnicodeEncoding]::new($false, $true))
```

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo "{RUN_TEMP}\sm30_maintain_run.vbs"
```

**Generic table-control driver:** the overview belongs to the *generated* program SAPL<AREA>, so it
discovers the sole `GuiTableControl` by type (`TryLockSession` around the write) and maps columns by
the DD27S field names embedded in cell IDs (`txt/ctxt<VIEW>-<FIELD>[col,row]`) — never hardcoded; it
pages the vertical scrollbar past `VisibleRowCount`. **add** = New Entries (`tbar[1]/btn[5]`) + fill +
Save; **update** = Position (`btnVIM_POSI_PUSH` -> SAPLSPO4 0300) per row, fill the key cell(s) in key
order, Continue, overwrite the non-key cells, Save. The Customizing-TR (`KO008-TRKORR`) popup is
guarded after Save (filled from `TRKORR`, or `SM30_TR_REQUIRED` on empty — never blind-Enter'd). Parse
stdout `SM30: view=<v> mode=<m> rows=<n>` + `STATUS: <status>` and read `{RUN_TEMP}\sm30_result.json`
(`status`, `rows_written`, `messages[]`): `STATUS: NEEDS_RECORDING` (with `SM30: NEEDS_RECORDING
step=<label>`) = the live screen diverged from the captured contract -> re-record via `/sap-gui-probe
--record`; `SM30_TR_REQUIRED` -> resolve a Customizing TR and retry; `SM30_KEY_NOT_FOUND` -> the update
key is absent (no upsert); `SM30_SAVE_FAILED` -> the save sbar returned E/A. Then **verify** via a
`sap_sm30_read.ps1 -Action preread` re-read filtered (`-Where`) to the written keys — verdict from the
re-read ONLY; any delta -> `SM30_VERIFY_MISMATCH`.

## Step 6 — Register

`Register-SapArtifact` (kind `preview_diff` / `verify_read`, scope R3TR VIEW `<name>`, verdict) so
`/sap-evidence-pack` proves who changed what with approval.

## Final — Log End

Log end. Error classes: `SM30_NO_MAINT_DIALOG`, `SM30_TWO_STEP_UNSUPPORTED`, `SM30_CLUSTER_UNSUPPORTED`,
`SM30_CLIENT_NOT_MODIFIABLE`, `SM30_DELETE_UNSUPPORTED`, `SM30_VERIFY_MISMATCH`, `SM30_TR_REQUIRED`,
`SM30_KEY_NOT_FOUND`, `SM30_SAVE_FAILED`, `NEEDS_RECORDING`,
`PREREAD_UNFILTERED`; reused `RFC_LOGON_FAILED` / `GUI_TIMEOUT` / `TR_NOT_MODIFIABLE`.

---

## Scope & Limitations (v1)

- **Resolve + pre-read live-verified on S4D (S/4HANA 1909) 2026-07-11:** `resolve V_T001W` returned
  the full DDIC shape (maint_type=2, function_group=0ORG, maint_tcode=OX10, primary_table=T001W,
  22 fields, keys MANDT/WERKS, auth_group MCOR, client_category T) and correctly verdicted
  `SM30_TWO_STEP_UNSUPPORTED`; `preread V_T001W --where WERKS=1710` read plant 1710 ("JIT Plant")
  projected to the view's base fields; a table with no TVDIR entry -> `SM30_NO_MAINT_DIALOG`. EC2
  (ECC 6) was probed in-plan (all 15 objects + SAPMSVMA identical; TDDAT is POOL there, read narrow)
  but unreachable at build time; one RFC code path.
- **add/update is the GUI write** (SM30's generated dialog is SAP's sanctioned write API for
  customizing views — no SQL on standard tables). The **generic table-control driver** (column
  mapping by DD27S cell-ID names, vertical/horizontal virtualization) is the L-effort core and is
  captured per the proving views via `/sap-gui-probe` — now **recorded + live-verified on S4D
  (S/4HANA 1909) 2026-07-12** (capture bullet below), never a guessed dynpro. Depends on the shipped
  `/sap-transport-request --type customizing` extension (verified present).
- **add/update recorded + live-verified on S4D (S/4HANA 1909) 2026-07-12.** `sap_sm30_maintain.vbs`
  was captured end-to-end against the purpose-built one-step scratch view `ZSAPDEV_SM30` (function
  group `ZSMDEVAI`, overview dynpro 0010): **New Entries** (`tbar[1]/btn[5]`) and **Position+edit**
  (`btnVIM_POSI_PUSH` -> SAPLSPO4 0300) both drove the write and were **RFC-verified** (row `REC001`
  created, then its text updated); the **assembled driver was then smoke-tested end-to-end** on the same
  view (add + update of a second key `REC002`, both RFC-confirmed). **Position-verdict finding:** SM30
  does not reliably emit an `S` sbar after Position (`One entry chosen` shows only when narrowing to a
  single row; a scroll-to-key on a multi-row view leaves the sbar empty), so the driver confirms a
  position by the popup dismissing AND row 0's key matching the requested key — never by the sbar
  message. The generic driver discovers the sole `GuiTableControl` and maps
  columns by the DD27S FIELDNAMEs in the cell IDs (never a hardcoded column), and pages the vertical
  scrollbar past `VisibleRowCount`. The Customizing-TR (`KO008-TRKORR`) popup did NOT fire on S4D/100
  (standard recording routine; the client did not prompt) so it is **guarded-but-not-exercised** — the
  driver fills it from the resolved TR or reports `SM30_TR_REQUIRED` on an empty TR, and never
  blind-Enters it. Golden-screen baseline `sap_sm30_maintain.screens.json` (sm30_initial /
  sm30_overview / sm30_position_popup).
- **v1 = one-step (table-control overview) views only.** Two-step views (TVDIR TYPE='2', common in
  SD/FI) are refused loud; SM34 clusters refused; delete never offered (manual SM30). Runs capped at
  200 rows (reviewable diff + bounded GUI loop).
- **v1.5:** two-step views (overview + detail dynpro), text-table companion writes. **v2:** SM34 view
  clusters; opt-in headless write via VIEW_MAINTENANCE_LOW_LEVEL through the dev-init wrapper (Rule-2
  consent, only after GUI parity is proven).
