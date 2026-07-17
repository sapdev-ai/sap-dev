# sap-refresh-verify

**Runs the post-refresh (system-copy) checklist as a 2-minute audited CHECK/FIX report** —
after a QA/sandbox copy from PRD, one missed item means QA emails real customers or posts into
a live interface; this front-loads all of it with an evidence-pack sign-off. RFC-only,
read-only in audit.

```
/sap-refresh-verify audit [--config <path>] [--max-rows N]
/sap-refresh-verify init-config
/sap-refresh-verify deschedule <JOBNAME> <JOBCOUNT> | deschedule --all-flagged
```

## What it does

- **Audits against a per-landscape expectations file** the operator writes once
  (`init-config` scaffolds it to `{custom_url}\refresh_expectations_<SID>_<CLIENT>.json` from
  `references/refresh_expectations_template.json`; no config → the audit REFUSES rather than
  guess a landscape).
- **10-check battery** (engine: `references/sap_refresh_audit.ps1`): BDLS was run (T000
  LOGSYS + TBDLS), RFC destinations don't still point at PRD (RFCDES scan), inherited PRD
  jobs are gone (TBTCO/TBTCP), tRFC/qRFC queues are disarmed (SMQ FMs + ARFCSSTATE), the
  client role isn't Production (SCC4/T000), dialog users are locked (USR02) — each emitted as
  a doctor-style `CHECK: id=.. result=PASS|FAIL|REVIEW|SKIP|COULD_NOT_CHECK fix=..` line with
  a copy-pasteable FIX, rolled up to **GO / GO_WITH_WARNINGS / NO_GO**. (`REVIEW` is a
  deliberate extension of the /sap-doctor CHECK grammar for findings that must never render
  PASS.)
- **Hard identity gate** — RFC_SYSTEM_INFO vs the config's SID aborts before it can ever
  audit the wrong box (`REFRESH_IDENTITY_MISMATCH`).
- **mail/sost delegation** — when `/sap-sost` is installed, its `config-check` verdict is
  folded into the `mail/sost` check; otherwise SKIP with an install pointer.
- **Renders + registers** `refresh_audit_<SID>_<CLIENT>_<ts>.md` (config digest, every CHECK
  line, the FIX list, the flagged-jobs ledger) in the artifact index for `/sap-evidence-pack`.

## The only write: deschedule

`deschedule` removes inherited PRD jobs, delegated to `/sap-job delete` (which brings its own
confirm gate). `--all-flagged` first takes a **typed** confirmation `DESCHEDULE <n> JOBS ON
<SID>/<CLIENT>` (always typed when T000 shows a production client), then still lets /sap-job
confirm each; a TBTCO re-read verifies each removal. BDLS, SM59 repointing, SMQ1, and SU10
stay copy-pasteable manual FIX text — never auto-remediated.

## Honest by construction

A check that cannot run is COULD_NOT_CHECK, never PASS; an allowlisted PRD-pointing
destination is REVIEW, never green; a capped read (`--max-rows`, default 5000) that truncates
forces REVIEW; any COULD_NOT_CHECK caps the verdict at GO_WITH_WARNINGS; any FAIL → NO_GO.

## Reads

T000, TBDLS, RFCDES, TBTCO/TBTCP, ARFCSSTATE + the `TRFC_Q*_GET_CURRENT_QUEUES` FMs, USR02.
ECC 6 shares the identical path (all tables + FMs probed identical) — no release variant.
Deferred: `--deep-rfc` (v1.5), `--compare <prev-report>`, `--all-clients` sweep,
trusted-system table scan (v2).

Prerequisites: pinned RFC profile via /sap-login; NCo 3.1 (32-bit); an expectations config.
No GUI, no Z objects. Live-verified on S/4HANA 1909 (S4D): a deliberately-wrong config
produced NO_GO with every check FAILing correctly, and a corrected config flipped them to
PASS — GO_WITH_WARNINGS driven only by the honest queue REVIEWs.
