---
name: sap-gateway-service
description: |
  OData/Gateway service diagnosis over RFC — replaces the /IWFND/MAINT_SERVICE + SICF +
  /IWFND/ERROR_LOG scavenger hunt behind every "the service returns 500" ticket. status reads the
  hub catalog (/IWFND/I_MED_SRH registration + IS_ACTIVE) x the system-alias assignment
  (/IWFND/V_MGDEAM) per service and returns a verdict OK / INACTIVE / NO_ALIAS / NOT_REGISTERED —
  a missing alias is the classic 500 cause. errors surfaces the /IWFND/ERROR_LOG content, clusters
  it by (service, message), and AI-maps each cluster to a cause (CUSTOM_CODE via the named
  DPC/MPC source program -> /sap-fix-incident + /sap-explain-object handoff; NO_ALIAS / AUTH /
  METADATA_CACHE config causes), cross-linking /sap-st22. S/4-only: a DD02L preflight distinguishes
  GW_NOT_INSTALLED from GW_BACKEND_ONLY (IW_BEP present, hub on another box -> pin it via
  /sap-login) and refuses loud on ECC rather than faking support. Registers as /sap-diagnose's
  odata reader. Pure RFC for status (no wrapper, no Z object, no dev-init); smoke (HTTP) is v1.5
  and activate (MAINT_SERVICE + SICF) is v2, both gated. Prerequisites: pinned /sap-login RFC
  profile; a live GUI session for errors (the error log is GUI-only); NCo 3.1 (32-bit).
argument-hint: "status [<service>] [--all] | errors [--service X] [--user U] [--date YYYYMMDD] [--top N] [--deep]"
---

# SAP Gateway Service Skill

You answer "why does this OData service 500?" — status checks registration + alias + active; errors
maps the log to a cause and hands custom-code defects to the fix pipeline. Read-only in v1.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_gateway_read.ps1` | `-Action status\|errors` | RFC status backend + errors preflight |
| `<SKILL_DIR>/references/sap_gateway_errlog_deep.vbs` | GUI reader (`%%SESSION_PATH%%`·`%%ATTACH_LIB_VBS%%`·`%%PARAMS_FILE%%`·`%%OUTPUT_FILE%%`) | `/IWFND/ERROR_LOG` scrape — error-list ALV (22 cols) + `--deep` detail tree. Recorded + live-verified end-to-end on S4D 2026-07-11 |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_attach_lib.vbs` | `%%ATTACH_LIB_VBS%%` | Parallel-safe session attach (`AttachSapSession`) for the GUI reader |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_connection_lib.ps1` | dot-source | RFC connect |
| `/sap-st22` · `/sap-fix-incident` · `/sap-explain-object` · `/sap-diagnose` | sub-skills | Dump leg / custom-code handoff / DPC-MPC dossier / odata reader |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_gateway_service_run.json`). Pinned RFC profile via `/sap-login`.

## Step 1 — Parse & Dispatch

`status` (default) | `errors`. `smoke` -> "v1.5"; `activate` -> "v2" (print the manual MAINT_SERVICE
+ SICF steps, exit SKIPPED). `--anchor PATH` switches `errors` into the /sap-diagnose reader contract.

## Step 1.5 — Gateway preflight (in the backend)

The backend probes `/IWFND/I_MED_SRH` via DD02L: absent + `/IWBEP/I_MGW_SRH` present ->
`GW_BACKEND_ONLY` (the hub is on another system — pin it via `/sap-login`); both absent ->
`GW_NOT_INSTALLED`. Fail loud (exit 1) — no partial ECC mode.

## Step 2 — status

```bash
... sap_gateway_read.ps1 -Action status [-Service <n>] -OutDir "{RUN_TEMP}\gw"
```

`GWSVC: service=.. active=.. alias=.. verdict=OK|INACTIVE|NO_ALIAS` -> render the per-service
table. Unknown service -> `GW_SERVICE_NOT_FOUND`.

## Step 3 — errors

The error list lives in `/IWFND/ERROR_LOG`. **Build finding:** `/IWFND/SU_ERRLOG` is NOT readable
via RFC_READ_TABLE or BBP_RFC_READ_TABLE (its RSTR/STRG columns trip a SAPLSDTX/SAPLBBPB
ASSIGN-CASTING dump) — the backend returns `GW_ERRLOG_GUI_ONLY`, so `errors` is driven by the
`/IWFND/ERROR_LOG` **GUI reader** `sap_gateway_errlog_deep.vbs` (recorded + live-verified end-to-end
on S4D 2026-07-11 — needs a live GUI session; pin one via `/sap-login`). Substitute the attach + IO
tokens, set `SAPDEV_SESSION_PATH` (parallel-safe attach contract), and run it via **32-bit cscript**:

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
. "$shared\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
# PARAMS_FILE = KEY=VALUE lines: FROMDATE=YYYYMMDD TODATE=YYYYMMDD USER=<b> SERVICE=<n> TOPN=<n> [DEEP=1]
$vbs = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_gateway_errlog_deep.vbs', [Text.Encoding]::UTF8)
$vbs = $vbs.Replace('%%ATTACH_LIB_VBS%%', "$shared\sap_attach_lib.vbs")
$vbs = $vbs.Replace('%%SESSION_PATH%%',   '')   # or the --session value
$vbs = $vbs.Replace('%%PARAMS_FILE%%',    '{RUN_TEMP}\gwerr_params.txt')
$vbs = $vbs.Replace('%%OUTPUT_FILE%%',    '{RUN_TEMP}\gwerr.json')
[IO.File]::WriteAllText('{RUN_TEMP}\gwerr_run.vbs', $vbs, [System.Text.UnicodeEncoding]::new($false, $true))
```

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo "{RUN_TEMP}\gwerr_run.vbs"
```

Parse `GWERR: entries=<n> deep=<d> file=<path>` + `STATUS: OK`; a `STATUS: GRID_NOT_FOUND` line means
the `/IWFND/ERROR_LOG` layout differs on this release (**e.g. S/4HANA 2023 renders it as `SAPMSDYP`
screen 10, empty-until-selected** — the reader skips gracefully; re-record via `/sap-gui-probe
--record` to add that release's candidate IDs). Read `{RUN_TEMP}\gwerr.json` — `entries[]` carry the
22 list columns + a `detail[]` tag/value tree per entry when `--deep`. Then cluster by (service,
message) and AI-map each cluster to a cause: a named `Z*_DPC_EXT`/`_MPC_EXT`/`CL_Z*` source program
(from the detail tree's `.....Program`) -> `CUSTOM_CODE` (offer `/sap-explain-object` +
`/sap-fix-incident`); alias/auth/metadata text -> the matching config cause; cross-link the same
window through `/sap-st22`. `--anchor` -> emit the diagnose evidence JSON.

## Step 4 — Register

`Register-SapArtifact` (kind `gw_status` / `gw_errors`; coverage CHECKED, or COULD_NOT_CHECK when
the deep scrape is unavailable) for `/sap-evidence-pack`.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class). Error classes: `GW_NOT_INSTALLED`,
`GW_BACKEND_ONLY`, `GW_SERVICE_NOT_FOUND`, `GW_ERRLOG_GUI_ONLY`, `NEEDS_RECORDING`; reused
`RFC_LOGON_FAILED` / `RFC_ERROR`.

---

## Scope & Limitations (v1)

- **status live-verified on S4D (S/4HANA 1909) 2026-07-11:** the catalog lists active services
  (`/IWFND/I_MED_SRH`, IS_ACTIVE='A' — a build finding: the active flag is 'A', not 'X') with their
  system-alias join (`/IWFND/V_MGDEAM`) and a verdict; on this dev system V_MGDEAM is empty so every
  service correctly reads `NO_ALIAS`. EC2 (ECC 6) was probed in-plan as **backend-only** (all
  `/IWFND/*` absent, `/IWBEP/I_MGW_SRH` present) -> `GW_BACKEND_ONLY` refusal; it was unreachable at
  build time but the preflight logic is release-gated by DD02L.
- **Build finding — the error list is GUI-only.** `/IWFND/SU_ERRLOG` cannot be read via
  RFC_READ_TABLE OR BBP_RFC_READ_TABLE (string/RSTR columns -> ASSIGN-CASTING dump, verified both
  FMs on S4D), so the plan's RFC error-list is not viable; `errors` uses the `/IWFND/ERROR_LOG` GUI
  reader `sap_gateway_errlog_deep.vbs` — **recorded + live-verified end-to-end on S4D 2026-07-11**:
  it read the 22-column error-list ALV plus, with `--deep`, the full exception-detail tree of a real
  OData-403 entry (T100 message + ERROR_TEXT + SOURCE program/include/line + SAP-note 1797736 + HTTP
  status + hub version); non-ASCII (CJK) error text round-trips intact via the reader's UTF-8 output.
  The backend still detects the RFC-unreadability and returns `GW_ERRLOG_GUI_ONLY` rather than a raw
  dump. **Cross-release finding:** S/4HANA 2023 renders `/IWFND/ERROR_LOG` as program `SAPMSDYP`
  screen 10 (empty-until-selected, unlike 1909's `/IWFND/SUTIL_LOG` screen 100), where the reader
  skips loud (`GRID_NOT_FOUND`) pending a 2023 recording — the S4D (1909) path is the verified one.
- **S/4-only, pure read-only.** status is direct RFC (no wrapper, no Z object, no dev-init). smoke
  (HTTP GET `$metadata`, executes provider code) is v1.5 behind an ICM_GET_INFO preflight + confirm;
  activate (MAINT_SERVICE + SICF) is v2 behind /sap-gui-probe recordings (prints manual steps until
  then). No OData V4 (separate /IWFND/V4_ADMIN surface) in v1.
- **Registers as /sap-diagnose's `odata` reader** (`--anchor` contract), closing the matrix's
  `gw_log(manual)` gap.
