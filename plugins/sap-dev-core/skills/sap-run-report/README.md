# sap-run-report

Execute an ABAP report/program on a live SAP system, or maintain its variants.

## What it does

- **run** (default): `/sap-run-report ZFOO [--variant=V] [--foreground|--background] [--values="P_A=1;S_B=BT:10,20"] [--save-output=PATH]`
- **variant**: `/sap-run-report variant <list|show|delete> ZFOO [VARIANT]`

Foreground = SA38 F8, synchronous, classic list captured (best-effort). Background =
scheduled job (monitor via SM37 / `/sap-job`). Variant list/show/delete route through
`/sap-rfc-wrapper`.

## Safety

Running a report can change data (UPDATE / COMMITting BAPI / job submit / IDoc / mail).
The skill **always confirms before it runs** (`skill_operating_rules.md` Rule 5) and never
runs as an unconfirmed side effect of another skill.

## Phasing

- **Phase A (this):** GUI foreground run + variant list/show/delete + GUI background schedule.
  Release-specific popups (Get Variant, background-exec, `%PC` list save) are seeded and
  guarded with `NEEDS_RECORDING`; capture them once with `/sap-gui-probe --record`.
- **Phase B:** RFC background via `Z_RUN_REPORT` (headless run → `TBTCO` poll → spool capture
  via `/sap-sp02` → `/sap-st22` on abort) + dedicated `sap_variant_rfc.ps1` for variant
  create/edit.

Prerequisites: active SAP GUI session (`/sap-login`). Full flow in `SKILL.md`; design
rationale in `docs/architecture/sap-run-report-and-sap-job-design.md`.
