---
name: sap-dev-status
description: |
  Read-only status report for the sap-dev-init artefacts: transport
  request, package, function group, the wrapper FM
  Z_GENERIC_RFC_WRAPPER_TBL plus its DDIC parameter structure /
  table type, and the ZCMRUPDATE_ADDON_TABLE utility program.
  Queries via RFC (TLIBG, TDEVC, TFDIR, DD02L, DD40L, PROGDIR, E070,
  TADIR) and emits one parseable line per artefact plus a summary
  STATUS line.
  Auto-invokable as a pre-flight from any sap-dev skill — exit code
  0 = healthy, 1 = gaps, 2 = RFC failure.
  Pure read-only; never modifies the SAP system.
  Prerequisites: SAP NCo 3.1 (32-bit, .NET 4.0) in GAC.
argument-hint: "[--quiet]"
---

# SAP Dev Environment Status Skill

You report on the health of the artefacts `/sap-dev-init` is responsible
for. Designed to run in well under a second over RFC, so other skills
can call it as a pre-flight.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — RFC-only skill, but rule applies to any downstream skill this is invoked from |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_dev_artefacts.ps1` | many | RFC artefact checker (also used by `/sap-dev-clean` and `/sap-dev-init`). |

---

## Step 0 — Resolve Work Directory and Settings

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Read `work_dir`, `sap_dev_transport_request`, `sap_dev_package`, `sap_dev_function_group`, plus the standard SAP RFC connection keys.

**Per-connection keys (Phase 4.4)**: `sap_dev_transport_request`, `sap_dev_package`, `sap_dev_function_group` are SAP-system-specific. Per `settings_lookup.md` § Per-connection exception, read them from `connections.json[pinned-profile].dev_defaults` FIRST (resolve the pin via `{work_dir}\runtime\session_registry.json` `ai_sessions[<id>]`); only fall back to the two-file merge when `dev_defaults` is empty.

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_dev_status_run.json" -Skill sap-dev-status -ParamsJson "{}"
```

---

## Step 1 — Generate and Run the Checker

Fill the shared artefacts script:

```powershell
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$ps       = Get-Content "$shared\scripts\sap_dev_artefacts.ps1" -Raw -Encoding UTF8
$ps       = $ps.Replace('%%SAP_SERVER%%',     'THE_SERVER')
$ps       = $ps.Replace('%%SAP_SYSNR%%',      'THE_SYSNR')
$ps       = $ps.Replace('%%SAP_CLIENT%%',     'THE_CLIENT')
$ps       = $ps.Replace('%%SAP_USER%%',       'THE_USER')
$ps       = $ps.Replace('%%SAP_PASSWORD%%',   'THE_PASSWORD')
$ps       = $ps.Replace('%%SAP_LANGUAGE%%',   'THE_LANGUAGE')
$ps       = $ps.Replace('%%RFC_LIB_PS1%%',    "$shared\scripts\sap_rfc_lib.ps1")
$ps       = $ps.Replace('%%TR%%',             'THE_TR')
$ps       = $ps.Replace('%%PACKAGE%%',        'THE_PKG')
$ps       = $ps.Replace('%%FUGR%%',           'THE_FG')
$ps       = $ps.Replace('%%WRAPPER_FM%%',     '')
$ps       = $ps.Replace('%%WRAPPER_STRUCT%%', '')
$ps       = $ps.Replace('%%WRAPPER_TT%%',     '')
$ps       = $ps.Replace('%%UTIL_PROGRAM%%',   '')
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_dev_status_run.ps1', $ps, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Empty `WRAPPER_*` / `UTIL_PROGRAM` tokens fall back to the canonical
defaults built into the shared script (`Z_GENERIC_RFC_WRAPPER_TBL`,
`ZCMST_RFC_PARAM`, `ZCMCT_RFC_PARAM`, `ZCMRUPDATE_ADDON_TABLE`).

Run via **32-bit PowerShell** (NCo 3.1 is in `GAC_32`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_dev_status_run.ps1"
```

---

## Step 2 — Interpret the Output

The shared script emits one line per artefact, then a summary:

```
ARTEFACT: <NAME> | KIND: <TR|PKG|FG|FM|STRUCT|TT|PGM> | STATE: <state> | DETAIL: <free text>
...
STATUS: ALL_OK
STATUS: GAPS=<N>
STATUS: ERROR
```

`<state>` values:

| State | Meaning |
|---|---|
| `ACTIVE` | Artefact exists and is in the expected ready-to-use state |
| `INACTIVE` | Exists but its active version is missing (run the relevant `--activate-only`) |
| `MISSING` | Not in the system (run `/sap-dev-init` to create) |
| `MODIFIABLE` (TR only) | Transport request can accept new objects |
| `RELEASED` (TR only) | Transport request is closed; resolve a new TR |
| `EMPTY` (PKG only) | Package exists but has no TADIR children |
| `NON_EMPTY` (PKG only) | Package exists with TADIR children |
| `NOT_CONFIGURED` | The corresponding `sap_dev_*` setting is blank in settings.json |
| `ERROR` | RFC call failed for this artefact |

Exit code:

| Code | Meaning |
|---|---|
| `0` | Everything healthy (`STATUS: ALL_OK`) |
| `1` | One or more gaps; `STATUS: GAPS=<N>` |
| `2` | RFC connection failed; `STATUS: ERROR` |

---

## Step 3 — Report

Format the output as a small table in your reply:

```
┌──────────────────────────────────┬────────┬────────────────┬──────────────────────────────────────────┐
│ Artefact                         │ Kind   │ State          │ Detail                                   │
├──────────────────────────────────┼────────┼────────────────┼──────────────────────────────────────────┤
│ S4DK941132                       │ TR     │ MODIFIABLE     │ TRSTATUS=D                               │
│ ZCMPKG018                        │ PKG    │ NON_EMPTY      │ TDEVC ok, TADIR children=12              │
│ ZFG018                           │ FG     │ ACTIVE         │ TLIBG ok, PROGDIR.STATE=A for SAPLZFG018 │
│ Z_GENERIC_RFC_WRAPPER_TBL        │ FM     │ ACTIVE         │ TFDIR ok                                 │
│ ZCMST_RFC_PARAM                  │ STRUCT │ ACTIVE         │ DD02L AS4LOCAL=A                         │
│ ZCMCT_RFC_PARAM                  │ TT     │ ACTIVE         │ DD40L AS4LOCAL=A                         │
│ ZCMRUPDATE_ADDON_TABLE           │ PGM    │ ACTIVE         │ PROGDIR.STATE=A                          │
└──────────────────────────────────┴────────┴────────────────┴──────────────────────────────────────────┘
STATUS: ALL_OK
```

If any state is not `ACTIVE` / `MODIFIABLE`, recommend the matching
remediation:

| Bad state | Recommend |
|---|---|
| `MISSING` (any) | `/sap-dev-init` |
| `INACTIVE` for FG | `/sap-function-group --activate-only` |
| `RELEASED` TR | `/sap-transport-request` (resolve fresh TR) |
| `NOT_CONFIGURED` | Run `/update-config` to set the missing key, then `/sap-dev-init` |

---

## Step 4 — Clean Up

```bash
cmd /c del "{WORK_TEMP}\sap_dev_status_run.ps1"
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_dev_status_run.json" -Status SUCCESS -ExitCode 0
```

(For exit codes 1/2, set `-Status FAILED -ExitCode <code>` with
`-ErrorClass DEV_STATUS_GAPS` or `RFC_LOGON_FAILED`.)

---

## Auto-invocation contract

Other sap-dev skills MAY call `/sap-dev-status` as a pre-flight when
their flow assumes the dev env is set up — for example,
`/sap-rfc-wrapper-fm` could fail fast with a clear "wrapper FM not
deployed; run /sap-dev-init" message instead of running the wrapper
script and getting a vague `FM_NOT_FOUND` from RFC. Status is RFC-only
and read-only, so this is safe to chain liberally.

The skill is idempotent and fast (<1s typical). Don't worry about
calling it twice.

---

## Limitations

- **Static artefact set.** The shared checker hardcodes the
  `/sap-dev-init` artefact list (wrapper FM + DDIC + utility
  program). If the customer has forked init to add their own
  artefacts, extend `sap_dev_artefacts.ps1` accordingly.
- **No customer-namespace check.** A passed-in TR / package / FG that
  starts with `SAP*` instead of `Z*`/`Y*` is reported as-is; this skill
  does not enforce naming conventions.
- **Package emptiness check is shallow.** Counts direct `TADIR`
  children only — does not recurse into sub-packages.
