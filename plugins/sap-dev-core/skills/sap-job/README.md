# sap-job

Manage ABAP background jobs on a live SAP system — schedule, list, status, log, spool,
cancel, delete.

## What it does

- **schedule**: `/sap-job schedule ZFOO [--variant=V] [--start=immediate|YYYYMMDDHHMMSS|event:E] [--period=daily|weekly|monthly] [--jobname=N]`
- **list**: `/sap-job list [--user=U] [--jobname=Z*] [--from=YYYYMMDD] [--to=YYYYMMDD] [--status=R|Y|P|S|A|F]`
- **status / log / spool / cancel / delete**: `/sap-job <verb> <JOBNAME> <JOBCOUNT> [--save-output=PATH]`

Mode-aware: prefers the RFC fast-path (schedule via the RFC-enabled `Z_RUN_REPORT`;
list/status via `TBTCO`; spool id via `TBTCP`; delete via `BP_JOB_DELETE`) and falls
through to the SM36 / SM37 GUI drivers when RFC is unavailable, honouring
`userConfig.sap_dev_mode`. `JOBCOUNT` is the 8-char job number — get it from `list`.

## Safety

`schedule` **executes** a report (possibly on a recurrence), and `cancel` / `delete`
are irreversible. The skill **always confirms those three** (`skill_operating_rules.md`
Rule 5) and never acts as an unconfirmed side effect. The monitoring verbs
(`list` / `status` / `log` / `spool`) are read-only and run without a prompt.

## Status

- **RFC path (verified pattern):** `schedule`(immediate), `list`, `status`, `spool`, and
  `delete` reuse the Phase-B `Z_RUN_REPORT` + `TBTCO`/`TBTCP` reads. Immediate scheduling +
  the table reads are the same mechanism proven live for `/sap-run-report` background runs.
- **GUI path (captured + verified live):** `sap_sm37_ops.vbs` (SM37 operations) and
  `sap_sm36_schedule.vbs` (SM36 wizard) carry control IDs **captured live on S4G (S/4HANA, EN)
  and EC2 (ECC 7.31, JA)**, 2026-07-09 — identical across both (core `SAPLBTCH`/`SAPMSSY0`
  kernel dialogs). SM37 `list`/`log` and the full SM36 immediate wizard were verified live
  end-to-end; `.screens.json` baselines are `captured`. Verified on both systems: `schedule`
  (immediate / date-time / periodic — S4G `TBTCS`-confirmed), `list` / `status` / `log`,
  `delete` (SM37 Shift+F2), and `cancel` (a running WAIT job aborted + RFC-confirmed `A` on S4G;
  on EC2 the localized menu matcher, SAPLSPO1 confirm, and SM37 re-query are all live-confirmed).
  Both destructive ops **self-verify** before reporting (delete: job left the list; cancel: job
  left the Active status) — never a false success; any release drift → `JOB: NEEDS_RECORDING`.
  `log`/`cancel` are GUI-primary (job-log text is in TemSe; aborting a running job needs SM37's
  server/PID resolution).

Reuses `Z_RUN_REPORT` (deployed by `/sap-dev-init`); delegates spool text to `/sap-sp02`
and abort detail to `/sap-st22`.

Prerequisites: active SAP GUI session (`/sap-login`); the RFC path additionally needs SAP
NCo 3.1 (32-bit) + `Z_RUN_REPORT`. Full flow in `SKILL.md`; design rationale in
`docs/architecture/sap-run-report-and-sap-job-design.md` (§3).
