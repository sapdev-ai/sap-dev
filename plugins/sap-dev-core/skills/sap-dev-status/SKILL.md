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

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Read `sap_dev_transport_request`, `sap_dev_package`, `sap_dev_function_group`, plus the standard SAP RFC connection keys.

**Per-connection keys (Phase 4.4)**: `sap_dev_transport_request`, `sap_dev_package`, `sap_dev_function_group` are SAP-system-specific. Per `settings_lookup.md` § Per-connection exception, read them from `connections.json[pinned-profile].dev_defaults` FIRST (resolve the pin via `{work_dir}\runtime\session_registry.json` `ai_sessions[<id>]`); only fall back to the two-file merge when `dev_defaults` is empty.

**Target the connection named in the Task argument.** If the Task argument names a SAP connection (SID / description substring / UUID), resolve it and pin this AI session to it so the RFC checker (and the per-connection `dev_defaults` read above) target the *named* system, not whatever is currently pinned (the default). This skill is read-only, so a mismatch only mis-reports the wrong system — but `/sap-dev-clean` calls this as its pre-flight, where targeting the wrong system is a safety issue.

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; $m=@(Resolve-SapProfileHint -Hint '<TASK_ARG>'); if($m.Count -ne 1){ Write-Output ('TARGET=NEEDS_USER count='+$m.Count); return }; $rt=Join-Path (Get-SapWorkDir) 'runtime'; $aid=Get-SapAiSessionId -RuntimeDir $rt; & '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_broker.ps1' -Action pin -WorkTemp ((Get-SapWorkDir)+'\temp') -AiSessionId $aid -ConnectionId $m[0].id -PinReason user_switched | Out-Null; Write-Output ('TARGET='+$m[0].system_name+'/'+$m[0].client)"
```

If `TARGET=NEEDS_USER`, ask the user which connection (the hint matched 0 or several profiles).

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` / `*_run.vbs` and the `_run.json` state) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_dev_status_run.json" -Skill sap-dev-status -ParamsJson "{}"
```

---

## Step 1 — Generate and Run the Checker

Fill the shared artefacts script:

```powershell
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$ps       = Get-Content "$shared\scripts\sap_dev_artefacts.ps1" -Raw -Encoding UTF8
$ps       = $ps.Replace('%%SAP_SERVER%%',     '')
$ps       = $ps.Replace('%%SAP_SYSNR%%',      '')
$ps       = $ps.Replace('%%SAP_CLIENT%%',     '')
$ps       = $ps.Replace('%%SAP_USER%%',       '')
$ps       = $ps.Replace('%%SAP_PASSWORD%%',   '')
$ps       = $ps.Replace('%%SAP_LANGUAGE%%',   '')
$ps       = $ps.Replace('%%RFC_LIB_PS1%%',    "$shared\scripts\sap_rfc_lib.ps1")
$ps       = $ps.Replace('%%TR%%',             'THE_TR')
$ps       = $ps.Replace('%%PACKAGE%%',        'THE_PKG')
$ps       = $ps.Replace('%%FUGR%%',           'THE_FG')
$ps       = $ps.Replace('%%WRAPPER_FM%%',     '')
$ps       = $ps.Replace('%%WRAPPER_STRUCT%%', '')
$ps       = $ps.Replace('%%WRAPPER_TT%%',     '')
$ps       = $ps.Replace('%%UTIL_PROGRAM%%',   '')
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_dev_status_run.ps1', $ps, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Empty `WRAPPER_*` / `UTIL_PROGRAM` tokens fall back to the canonical
defaults built into the shared script (`Z_GENERIC_RFC_WRAPPER_TBL`,
`ZCMST_RFC_PARAM`, `ZCMCT_RFC_PARAM`, `ZCMRUPDATE_ADDON_TABLE`).

Run via **32-bit PowerShell** (NCo 3.1 is in `GAC_32`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_dev_status_run.ps1"
```

---

## Step 2 — Interpret the Output

The shared script emits one line per artefact, then anchor-validation lines,
then a summary:

```
ARTEFACT: <NAME> | KIND: <TR|PKG|FG|FM|STRUCT|TT|PGM> | STATE: <state> | DETAIL: <free text>
...
ANCHOR: wrapper_fm=<FM> | package=<actual> | fugr=<actual>
CONFIG_MISMATCH: <key> | configured=<X> | anchor=<Y> | <why>
CONFIG_HINT: <key> is blank | anchor=<Y>
CONFIG: OK | CONFIG: MISMATCH=<M>
STATUS: ALL_OK
STATUS: GAPS=<N>
STATUS: CONFIG_MISMATCH
STATUS: ERROR
```

**Anchor validation** (emitted when the wrapper FM exists): the FM is the
immovable anchor of the toolset, so the script resolves where it *actually*
lives — its function group (`TFDIR.PNAME`) and that FG's package (`TADIR`) — and
prints that as `ANCHOR:`. It then cross-checks the configured `sap_dev_package`
/ `sap_dev_function_group`:
- `CONFIG_MISMATCH:` — a **non-blank but different** value. This is the
  dangerous case (a destructive clean/reset would aim at the configured object,
  not the real toolset). `<Y>` is the correct value to fix the config to.
- `CONFIG_HINT:` — a **blank** value. Clean safely skips it, but it should be
  `<Y>`.

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
| `3` | Config mismatch; `STATUS: CONFIG_MISMATCH` — the configured `sap_dev_package` / `sap_dev_function_group` does not match where the wrapper FM actually lives. **Destructive skills (`/sap-dev-clean`) must refuse** until the config is corrected to the `ANCHOR:` values. |

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

**If `STATUS: CONFIG_MISMATCH`** (a `CONFIG_MISMATCH:` line is present), lead
with it — it outranks the per-artefact states. The configured dev defaults
point at the wrong objects (a frequent cause: an application build wrote its own
package/TR into the connection's `dev_defaults`). Show the `ANCHOR:` line (the
real home of the toolset) and tell the operator to correct the connection's
`dev_defaults` to the anchor values **before** running `/sap-dev-clean`, e.g.:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dev_default.ps1'" # see below
# Per mismatched key (Connection scope = the standing default for this system):
<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dev_default.ps1 -Action set -Scope Connection -Key sap_dev_package           -Value <anchor-package>
<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dev_default.ps1 -Action set -Scope Connection -Key sap_dev_function_group    -Value <anchor-fugr>
```

(`CONFIG_HINT:` lines are advisory — a blank key that clean skips; fill it to
the anchor value for completeness.)

If any state is not `ACTIVE` / `MODIFIABLE`, recommend the matching
remediation:

| Bad state | Recommend |
|---|---|
| `MISSING` (any) | `/sap-dev-init` |
| `INACTIVE` for FG | `/sap-function-group --activate-only` |
| `RELEASED` TR | `/sap-transport-request` (resolve fresh TR) |
| `NOT_CONFIGURED` | Run `/update-config` to set the missing key, then `/sap-dev-init` |
| `CONFIG_MISMATCH` | Correct the connection `dev_defaults` to the `ANCHOR:` values (commands above) |

---

## Step 4 — Clean Up

```bash
cmd /c del "{RUN_TEMP}\sap_dev_status_run.ps1"
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_dev_status_run.json" -Status SUCCESS -ExitCode 0
```

(For exit codes 1/2, set `-Status FAILED -ExitCode <code>` with
`-ErrorClass DEV_STATUS_GAPS` or `RFC_LOGON_FAILED`.)

---

## Auto-invocation contract

Other sap-dev skills MAY call `/sap-dev-status` as a pre-flight when
their flow assumes the dev env is set up — for example,
`/sap-rfc-wrapper fm` could fail fast with a clear "wrapper FM not
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
