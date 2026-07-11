---
name: sap-refresh-verify
description: |
  Runs the post-refresh (system-copy) checklist as a 2-minute audited CHECK/FIX report instead of
  a 45-minute error-prone wiki walk: after a QA/sandbox copy from PRD, confirms BDLS was run
  (T000 LOGSYS + TBDLS), RFC destinations don't still point at PRD (RFCDES scan), inherited PRD
  jobs are gone (TBTCO/TBTCP), tRFC/qRFC queues are disarmed (SMQ FMs + ARFCSSTATE), the client
  role isn't Production (SCC4), and dialog users are locked (USR02) — each compared against a
  per-landscape expectations file the operator writes once (init-config scaffolds it). One missed
  item means QA emails real customers or posts into a live interface; this front-loads all of it
  with an evidence-pack sign-off and explains why each finding matters. RFC-only, read-only in
  audit: emits doctor-style CHECK lines + a GO/GO_WITH_WARNINGS/NO_GO verdict; a hard identity gate
  (RFC_SYSTEM_INFO vs config SID) aborts before it can ever audit the wrong box. The ONLY write is
  a confirm-gated job deschedule delegated to /sap-job; BDLS/SM59/SMQ1/SU10 stay copy-pasteable
  manual FIXes (never auto-remediated). Tri-state honest (a check that can't run is COULD_NOT_CHECK,
  never PASS; an allowlisted PRD-pointing destination is REVIEW, never green). Prerequisites:
  pinned RFC profile via /sap-login; NCo 3.1 (32-bit); an expectations config (init-config makes one).
argument-hint: "audit [--config <path>] [--max-rows N] | init-config | deschedule <JOBNAME> <JOBCOUNT> | deschedule --all-flagged"
---

# SAP Refresh-Verify Skill

You audit a freshly-refreshed QA/sandbox system against the operator's landscape expectations and
produce a GO / NO_GO sign-off. You are read-only except one confirm-gated job deschedule (delegated
to /sap-job). You NEVER run BDLS, repoint RFCs, or lock users — those stay manual FIX text.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_refresh_audit.ps1` | `-Action audit\|identity -Config <p>` | The audit engine (all checks) |
| `<SKILL_DIR>/references/refresh_expectations_template.json` | copied by `init-config` | Expectations config template |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | `Register-SapArtifact` |
| `/sap-job` | sub-skill | `deschedule` delegation (`delete <JOBNAME> <JOBCOUNT>`) |
| `/sap-sost` | sub-skill (optional) | `mail/sost` SAPconnect config-check (SKIP if absent) |
| `/sap-login` | sub-skill | Pinned RFC profile |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_refresh_verify_run.json" -Skill sap-refresh-verify -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments & Resolve Config

Modes: `audit` (default) | `init-config` | `deschedule`. Config path = `--config`, else
`{custom_url}\refresh_expectations_<SID>_<CLIENT>.json` (SID/client from the pinned profile).

## Step 2 — init-config

Read the pinned profile's SID/client + a `sap_refresh_audit.ps1 -Action identity` (for the live
SID). Copy `references/refresh_expectations_template.json` to
`{custom_url}\refresh_expectations_<SID>_<CLIENT>.json` with `sid`/`client` pre-filled and the
current LOGSYS/role noted as candidate comments. Tell the operator they MUST fill
`prd_host_patterns` (at minimum) + `expected_logsys` before auditing. Local write only — done.

## Step 2.5 — Identity Gate (audit / deschedule)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_refresh_audit.ps1" -Action identity -Config "<config>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

`STATUS: REFRESH_IDENTITY_MISMATCH` -> ABORT (never audit the wrong box). `REFRESH_CONFIG_MISSING`
-> point at `init-config`. `REFRESH_CONFIG_INVALID` -> name the missing key.

## Step 3 — audit

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_refresh_audit.ps1" -Action audit -Config "<config>" -OutDir "{OUT}" -MaxRows <N> -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Stream each `CHECK: id=<id> group=<g> result=<PASS|FAIL|REVIEW|SKIP|COULD_NOT_CHECK> detail=".."
fix=".."` line and the final `VERDICT:`. (`REVIEW` is a deliberate extension of the /sap-doctor
CHECK grammar for allowlisted/ambiguous findings that must never render PASS.)

## Step 3C — mail/sost delegation

If `/sap-sost` is installed, invoke `/sap-sost config-check` via the Skill tool and fold its
verdict into `mail/sost` (FAIL/REVIEW/PASS). If not installed, keep the engine's SKIP + the FIX
"install /sap-sost for SAPconnect coverage".

## Step 4 — Render + Register

Write `refresh_audit_<SID>_<CLIENT>_<ts>.md` (config digest, every CHECK line grouped, the verdict,
the FIX list, and — when present — the flagged-jobs ledger from `{OUT}\jobs_flagged.tsv`). Verdict
rollup: any FAIL -> NO_GO; any REVIEW/COULD_NOT_CHECK -> GO_WITH_WARNINGS; else GO. Register:

```bash
powershell -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-refresh-verify' -ScopeKey 'SYS_<SID>_<CLIENT>' -Kind 'refresh_audit' -Format 'md' -Path '{OUT}\refresh_audit_<SID>_<CLIENT>_<ts>.md' -Verdict '<GO|GO_WITH_WARNINGS|NO_GO>' -Coverage '<CHECKED_CLEAN|CHECKED_FINDINGS|COULD_NOT_CHECK>'"
```

## Step 5 — deschedule (gated write, the only remediation)

Load the flagged-jobs list (`{OUT}\jobs_flagged.tsv` from the last audit) or the explicit
`<JOBNAME> <JOBCOUNT>`. **Confirm gate:** a single job -> `/sap-job delete` brings its own confirm.
`--all-flagged` -> THIS skill first takes a **typed** confirmation `DESCHEDULE <n> JOBS ON
<SID>/<CLIENT>` (and ALWAYS the typed form if T000 shows `CCCATEGORY='P'`), then still lets
/sap-job confirm each (no `--auto` passthrough). Delegate each removal to `/sap-job delete
<JOBNAME> <JOBCOUNT>`; after each, the audit's TBTCO re-read verifies it's gone. Report per-job
DELETED/FAILED. Never batch-delete without the typed phrase.

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_refresh_verify_run.json" -Status SUCCESS -ExitCode 0
```

Classes: `REFRESH_IDENTITY_MISMATCH`, `REFRESH_CONFIG_MISSING`, `REFRESH_CONFIG_INVALID`,
`RFC_ERROR`, `RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **v1 implemented:** `audit` (10-check battery), `init-config`, `deschedule` (gated, /sap-job
  delegation). RFC-only, read-only except the deschedule.
- **Live-verified on S4D (S/4HANA 1909):** the identity gate matched; a deliberately-wrong config
  produced **NO_GO** with every check FAILing correctly — `client/logsys` (LOGSYS matched a PRD
  pattern -> "BDLS not run"), `client/logsys-defined` (missing in TBDLS), `rfc/prd-pointing` (the
  server-side `RFCOPTIONS LIKE '%pattern%'` scan matched real destinations incl.
  `s4sapdev_S4D_70`), `jobs/released` (139 non-allowlisted jobs), `queues/qout`+`qin` (14+12
  queues via `TRFC_Q*_GET_CURRENT_QUEUES`), `queues/trfc` (4876 SM58 LUWs via ARFCSSTATE),
  `users/lock-policy` (555 unlocked dialog users, UFLAG bits evaluated) — and a corrected config
  flipped those to PASS (GO_WITH_WARNINGS, driven only by the honest queue REVIEWs), proving PASS
  honesty. `mail/sost` correctly SKIPs when /sap-sost is not installed.
- **Honesty invariants (Rule 10):** a check that cannot run is COULD_NOT_CHECK (never PASS); an
  allowlisted PRD-pointing destination is REVIEW (never green); a capped read (`--max-rows`, default
  5000) that truncates forces REVIEW; the verdict caps at GO_WITH_WARNINGS on any COULD_NOT_CHECK.
- **Safety:** no config -> REFUSES to audit (never guesses a landscape). Identity mismatch ->
  aborts. deschedule is the only write, confirm-gated (typed for `--all-flagged` / production
  client). No Z objects (Rule 2); v1.5 `--deep-rfc` (structured RFCDES parse via the wrapper) is
  the first wrapper-dependent surface and SKIPs with a /sap-dev-init pointer when absent.
- **ECC 6** shares the identical path (all 11 tables + 3 FMs probed identical); no release variant.
- **Deferred:** `--deep-rfc` (v1.5), `--compare <prev-report>` (v2), `--all-clients` sweep (v2),
  trusted-system table scan (v2).
