---
name: sap-forms
description: |
  Makes the suite see SAP forms: SmartForms, SAPscript, and Adobe forms — inventory them with
  real usage evidence, read a 40-node form as a navigable tree/spec, and feed /sap-cc-* scope
  decisions with counts instead of anecdotes. inventory enumerates all three form families
  (STXFADM SmartForms, TADIR SAPscript/Adobe) with namespace/package filters, overlays the TNAPR
  output-determination assignment (output types, channels, driver program, routine) and NAST usage
  counts in a date window -> forms_inventory.tsv. download smartform exports the XML via the
  SMARTFORMS Utilities->Download GUI menu (no FM route exists — SSF_DOWNLOAD_FORM is absent on both
  releases); download sapscript exports ITF via RSTXSCRP (confirm-gated report). inspect adobe reads
  the readable Adobe metadata (TADIR + TNAPR usage) and is honest that the FP* layout tables are NOT
  RFC-readable (RAWSTRING columns) so there is no XDP extraction. explain parses a downloaded
  SmartForm XML into a page/window/text/code/condition node tree (or a SAPscript ITF into
  windows/formats/elements), with --spec emitting a sap-docs work folder for re-implementation
  campaigns. test-print delegates to /sap-run-report + /sap-sp02. Read-only except the confirm-gated
  report executions; no new Z objects. Prerequisites: pinned RFC profile via /sap-login; NCo 3.1
  (32-bit); a GUI session for the download modes; /sap-dev-init only for the v1.5 wrapper-FM enrichment.
argument-hint: "inventory [--type all|smartforms|sapscript|adobe] [--namespace Z,Y | --all] [--packages ..] [--usage-days N] [--no-usage] | download smartform <N> | download sapscript <N> | inspect adobe <N> | explain <kind> <N> [--spec] | test-print driver <PROG>"
---

# SAP Forms Skill

You make forms legible: inventory SmartForms/SAPscript/Adobe with TNAPR+NAST usage evidence, export
and parse a form into a node tree/spec, and delegate test-prints. Read-only except confirm-gated
report executions; the SmartForm XML round-trip is GUI-menu-only (no FM exists).

Task: $ARGUMENTS

The inventory / Adobe-inspect are RFC scripts; the parse is offline; the SmartForm download is a
GUI VBS; **you** narrate the tree and the scope evidence.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_forms_inventory.ps1` | `-Type -Namespace -UsageDays` | Forms inventory + TNAPR/NAST overlay (RFC) |
| `<SKILL_DIR>/references/sap_forms_fp_inspect.ps1` | `-Name` | Adobe inspect (TADIR + usage; FP* = COULD_NOT_CHECK) |
| `<SKILL_DIR>/references/sap_forms_parse.ps1` | `-Kind smartform\|sapscript -InFile` | Offline form parser (node tree) |
| `<SKILL_DIR>/references/sap_forms_sf_download.vbs` | via 32-bit cscript | SmartForm XML download (SMARTFORMS menu) |
| `<SKILL_DIR>/references/sap_forms_sf_download.screens.json` | baseline | Golden-screen baseline (NEEDS_RECORDING rails) |
| `/sap-run-report` · `/sap-sp02` | sub-skills | `download sapscript` (RSTXSCRP) + `test-print` |
| `/sap-login` · `/sap-se16n` | sub-skills | session / RFC-blocked table fallback |

---

## Step 0 — Resolve Work Directory + Logging

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Then `sap_log_helper.ps1 -Action start -StateFile {RUN_TEMP}\sap_forms_run.json`.

## Step 1 — Parse Args + Backend

Modes: `inventory` | `download smartform|sapscript` | `inspect adobe` | `explain` | `test-print
driver|nast`. RFC modes need the pinned profile; download modes need a GUI session (/sap-login).

## Step 2.5 — CONFIRM gate

`download sapscript` (RSTXSCRP executes) and `test-print *` are confirm-gated (report execution;
`test-print nast` with NACHA!=1 -> typed `REPROCESS`). Read modes (inventory/inspect/explain/download
smartform) skip.

## Step 3A — inventory

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_forms_inventory.ps1" -Type <t> -Namespace "Z,Y" [-Packages ..] [-UsageDays N] [-NoUsage] -OutFile "{OUT}\forms_inventory.tsv" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Render the TSV (form_type, name, package, output_types, channels, driver, routine, usage_count,
coverage). A usage column that can't be read is COULD_NOT_CHECK / `>=N (capped)`, never "unused".

## Step 3B — download smartform (GUI)

Pre-arm the security sidecar; substitute `%%SESSION_PATH%%`/`%%ATTACH_LIB_VBS%%`/`%%FORMNAME%%`/
`%%SAVE_PATH%%`/`%%MENU_PATH%%` (the recorded Utilities->Download findById from the baseline) and run
`sap_forms_sf_download.vbs` (32-bit cscript). `FORMS: NEEDS_RECORDING` -> record the SMARTFORMS
Utilities->Download menu with `/sap-gui-probe --record` for this release, set `%%MENU_PATH%%`, retry.
Verify the file exists, is non-empty, and parses as `<SMARTFORM>`-rooted XML.

## Step 3C — download sapscript / 3D — inspect adobe / 3E — explain

- `download sapscript`: confirm -> delegate `/sap-run-report RSTXSCRP` (object class FORM, EXPORT) ->
  fetch the export; verify ITF header present.
- `inspect adobe`: `sap_forms_fp_inspect.ps1 -Name <N>` -> dossier (TADIR existence/package/author +
  TNAPR usage; FP* interface/context/layout are COULD_NOT_CHECK — not RFC-readable, SFP GUI/ADT only).
- `explain`: ensure a fresh download/inspect, then `sap_forms_parse.ps1 -Kind <k> -InFile <file>` ->
  `<name>_form_tree.md` (+ `--spec` sap-docs work folder). Wrapper-FM enrichment (READ_TEXT/
  SSF_STATUS_INFO via Z_GENERIC_RFC_WRAPPER_TBL) is best-effort and SKIPs with the /sap-dev-init prompt
  when the wrapper is absent (Rule 2 — never auto-deploy).

## Step 3F — test-print

`driver <PROG>` -> `/sap-run-report` (its own gate) -> `/sap-sp02` spool. `nast <KAPPL> <KSCHL>
<OBJKY>` -> pre-read the single NAST row (refuse wildcard/missing OBJKY); NACHA!=1 -> typed
`REPROCESS`; then `/sap-run-report RSNAST00` -> `/sap-sp02`.

## Step 4 — Register + Summarize

Register `inventory` / `export` / `dossier` / `spec` / `run_output` artifacts (coverage tri-state).
Print one `FORMS:` verdict line per mode + paths.

## Final — Log End

`sap_log_helper.ps1 -Action end` with status + error_class: `FORMS_NOT_FOUND`, `FORMS_EXPORT_INVALID`,
`FORMS_NAST_CHANNEL_REFUSED`, `RFC_LOGON_FAILED`, plus `NEEDS_RECORDING` recording-stops.

---

## Scope & Limitations (v1)

- **v1 implemented:** `inventory`, `download smartform` (GUI), `download sapscript` (RSTXSCRP),
  `inspect adobe`, `explain` (offline parse + --spec), `test-print` (delegation). One code path for
  ECC 6 + S/4.
- **Live-verified on S4D (S/4HANA 1909):** `inventory` enumerated **11,134 forms** (2719 SmartForms /
  3172 SAPscript / 5243 Adobe) with packages, and the **TNAPR + NAST overlay is proven with real
  evidence** — SAPscript **MEDRUCK** shows 25 output-determination assignments (EA/ABSA ...), channels
  1/2/5, driver SAPFM06P, routine ENTRY_ABSA, and **usage=604** NAST records; a SmartForm matched via
  the `SFORM` column. `explain` parsed a SmartForm XML into a page/window/text/code/condition tree and
  a malformed file into `FORMS_EXPORT_INVALID`; a SAPscript ITF into windows/formats/elements.
  `inspect adobe` on MEDRUCK_PO returned package/author from TADIR.
- **Live-proven RFC limitations (honesty):** the Adobe FP* tables (**FPLAYOUT / FPINTERFACE /
  FPCONTEXT**) are **NOT RFC-readable** — RAWSTRING columns make RFC_READ_TABLE die "ASSIGN CASTING in
  SAPLSDTX" even for narrow fields (same limit as the /UI2 tables; the plan's "metadata columns only"
  assumption did not hold live), so `inspect adobe` reports the interface/context/layout as
  COULD_NOT_CHECK with that reason and does NO XDP extraction. There is also no SmartForm download FM
  (SSF_DOWNLOAD_FORM absent), so that path is GUI-menu-only.
- **Deliberately NOT run autonomously (the GUI legs):** `download smartform` (SMARTFORMS
  Utilities->Download menu) and `download sapscript` (RSTXSCRP) drive/execute in the GUI and need a
  session; the SMARTFORMS menu position is release-specific and ships **NEEDS_RECORDING**-guarded
  (record via /sap-gui-probe, set `%%MENU_PATH%%`) rather than guessing. This session verified the
  RFC inventory / Adobe-inspect / offline-parse paths, not a live GUI download.
- **Deferred:** `test-print nast` NACHA!=1 typed gate (v1.5); wrapper-FM enrichment in `explain`
  (v1.5); `patch smartform` text-node/condition edits (v2). EC2 shares the identical path (RSTXSCRP /
  RSNAST00 / SAPMSSFO probed identical; DOCTL is CLUSTER on ECC handled by DOCU_GET elsewhere); EC2 was
  unavailable this session for the ECC re-confirm.
