# sap-run-report

Execute an ABAP report/program on a live SAP system, or maintain its variants.

## What it does

- **run** (default): `/sap-run-report ZFOO [--variant=V] [--foreground|--background] [--values="P_A=1;S_B=BT:10,20"] [--save-output=PATH]`
- **variant**: `/sap-run-report variant <list|show|set|delete> ZFOO [VARIANT] [--values="..."] [--desc="..."]`

Foreground = SA38 F8, synchronous, classic list captured (best-effort). Background =
headless RFC run via `Z_RUN_REPORT` when available (`TBTCO` poll → spool capture via
`/sap-sp02`), degrading to a GUI-scheduled job (monitor via SM37 / `/sap-job`). Variant
list/show route through `/sap-rfc-wrapper` (RFC); set (create/overwrite) and delete drive
the SAPLSVAR GUI dialogs.

## Safety

Running a report can change data (UPDATE / COMMITting BAPI / job submit / IDoc / mail).
The skill **always confirms before it runs** (`skill_operating_rules.md` Rule 5) and never
runs as an unconfirmed side effect of another skill.

## Status

- **Shipped and live-verified (2026-07-09):** GUI foreground run; RFC background via
  `Z_RUN_REPORT` (`references/sap_run_report_rfc.ps1` — headless run → `TBTCO` poll →
  spool capture via `/sap-sp02` → `/sap-st22` on abort) with GUI background schedule as
  fallback; variant list/show (RFC) + set/delete (SAPLSVAR GUI).
  Release-specific popups (Get Variant, background-exec, `%PC` list save) are seeded and
  guarded with `NEEDS_RECORDING`; capture them once with `/sap-gui-probe --record`.
- **Possible future:** a dedicated `sap_variant_rfc.ps1` RFC alternative for variant
  create/edit (today set/delete are GUI-only).

Prerequisites: active SAP GUI session (`/sap-login`). Full flow in `SKILL.md`; design
rationale in `docs/architecture/sap-run-report-and-sap-job-design.md`.
