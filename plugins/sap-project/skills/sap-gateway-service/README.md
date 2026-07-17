# sap-gateway-service

**Answer "why does this OData service 500?"** — replaces the /IWFND/MAINT_SERVICE + SICF +
/IWFND/ERROR_LOG scavenger hunt behind every Gateway ticket. `status` verdicts every
service's registration × alias × active state over RFC; `errors` clusters the error log and
maps each cluster to a cause. Read-only in v1.

```
/sap-gateway-service status [<service>] [--all]
/sap-gateway-service errors [--service X] [--user U] [--date YYYYMMDD] [--top N] [--deep]
```

## What it does

- **`status`** (pure RFC) reads the hub catalog (`/IWFND/I_MED_SRH` registration +
  IS_ACTIVE — a build finding: the active flag is `'A'`, not `'X'`) × the system-alias
  assignment (`/IWFND/V_MGDEAM`) and returns OK / INACTIVE / NO_ALIAS / NOT_REGISTERED per
  service — a missing alias being the classic 500 cause.
- **`errors`** (GUI reader) scrapes `/IWFND/ERROR_LOG` — the 22-column error-list ALV plus,
  with `--deep`, the full exception-detail tree per entry — then clusters by (service,
  message) and AI-maps each cluster to a cause: a named `Z*_DPC_EXT`/`_MPC_EXT`/`CL_Z*`
  source program → CUSTOM_CODE (handed to `/sap-explain-object` + `/sap-fix-incident`);
  alias/auth/metadata-cache text → the matching config cause; the same window is
  cross-linked through `/sap-st22`.
- **S/4-only, refused loud on ECC**: a DD02L preflight distinguishes `GW_NOT_INSTALLED`
  from `GW_BACKEND_ONLY` (`/IWBEP` present, hub on another box — pin it via `/sap-login`)
  instead of faking support.
- **Registers as /sap-diagnose's `odata` reader** (`--anchor` switches `errors` into the
  diagnose evidence contract).

## Honest by construction

The error list is GUI-only by live-proven build finding: `/IWFND/SU_ERRLOG` cannot be read
via RFC_READ_TABLE OR BBP_RFC_READ_TABLE (its RSTR/STRG columns trip an ASSIGN-CASTING
dump) — the backend detects this and returns `GW_ERRLOG_GUI_ONLY` rather than a raw dump.
On a release whose ERROR_LOG layout differs (e.g. S/4HANA 2023 renders it as `SAPMSDYP`
screen 10, empty-until-selected), the reader skips gracefully with `GRID_NOT_FOUND` pending
a `/sap-gui-probe --record` recording — never a silent empty result. `smoke` (HTTP GET
`$metadata` — executes provider code) is v1.5 behind a preflight + confirm; `activate`
(MAINT_SERVICE + SICF) is v2 — until then the skill prints the manual steps and exits
SKIPPED. No OData V4 in v1.

## Reads

`/IWFND/I_MED_SRH` + `/IWFND/V_MGDEAM` (status, via `references/sap_gateway_read.ps1`),
`DD02L` (preflight), and the `/IWFND/ERROR_LOG` GUI scrape
(`references/sap_gateway_errlog_deep.vbs` — recorded + live-verified end-to-end on S4D
2026-07-11, golden-screen baseline shipped; attaches parallel-safe via the shared attach
lib). No wrapper, no Z object, no dev-init.

Prerequisites: pinned `/sap-login` RFC profile (SAP NCo 3.1, 32-bit); a live GUI session
for the `errors` reader. `status` is live-verified on S/4HANA 1909 (S4D); ECC 6 (EC2/ERP)
was probed in-plan as backend-only → `GW_BACKEND_ONLY` refusal.
