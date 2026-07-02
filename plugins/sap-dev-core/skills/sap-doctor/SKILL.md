---
name: sap-doctor
description: |
  Read-only environment preflight ("doctor") for the sap-dev toolchain.
  Diagnoses why skills fail BEFORE they run, across five groups:
    * gui    — SAP GUI installed + SAP GUI Scripting reachable (client + server)
    * cfg    — 32-bit PowerShell, SAP NCo 3.1 in GAC_32, work_dir env var +
               writability, connections.json present + valid
    * rfc    — RFC connectivity to the AI-session's pinned connection profile
    * srv    — client Repository modifiability (T000 change option)
    * devenv — TR / package / function group / wrapper artefacts (delegated to
               /sap-dev-status)
  Emits one parseable CHECK line per probe and an overall verdict
  (READY / DEGRADED / BLOCKED). DEGRADES GRACEFULLY: a probe that cannot run
  reports SKIP, never a false PASS. Every failure carries a copy-pasteable FIX.
  Pure read-only; never modifies the SAP system (only writes/deletes a tiny
  temp probe file under work_dir to test writability).
  Auto-invokable as a pre-flight from any sap-dev skill — exit 0 = ready,
  1 = blocked.
  Prerequisites: SAP GUI installed; SAP NCo 3.1 (32-bit, .NET 4.0) in GAC for
  the rfc/srv groups; an active SAP GUI session for the gui group.
argument-hint: "[--quiet] [--no-devenv]"
---

# SAP Environment Doctor Skill

You diagnose the health of the sap-dev runtime environment so a user knows —
before invoking a real skill — whether their GUI, RFC, config, and dev-env are
all ready. Think `brew doctor` / `flutter doctor` for sap-dev. Designed to run
in a couple of seconds and to be safe to chain as a pre-flight.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only skill |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` | *(dot-source)* | `Get-SapWorkDir` (Step 0) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir` (Step 0) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_check_gui_login_status.vbs` | *(static VBS)* | gui group — SAP GUI / scripting reachability probe (no tokens) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | cfg/rfc/srv groups — `Connect-SapRfc` (pinned-profile fallback) |
| `<SKILL_DIR>/references/sap_doctor_checks.ps1` | *(template)* | cfg + rfc + srv checks (filled + run in 32-bit PowerShell) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(logging)* | Step 0.5 / Final logging |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT read `settings.json`
directly (that ignores `SAPDEV_AI_WORK_DIR` and `userconfig.json`). Parse the
`WORK_DIR=` line from:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp` and ensure it exists:

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
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_doctor_run.json" -Skill sap-doctor -ParamsJson "{}"
```

---

## Step 1 — gui group: probe SAP GUI / scripting

Run the static, read-only GUI status probe via **32-bit cscript** (PowerShell
cannot bind the SAPGUI Scripting COM object — it must be reached through
cscript):

```bash
C:/Windows/SysWOW64/cscript.exe //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_gui_login_status.vbs"
```

Map its `STATUS:` line to a gui-group result:

| STATUS | gui result | Meaning / FIX |
|---|---|---|
| `LOGGED_IN` | **PASS** | SAP GUI Scripting works end-to-end (client + server scripting both on — you cannot get an engine + session Info otherwise). Record SYSTEM/CLIENT/USER/LANGUAGE detail lines. |
| `LOGIN_SCREEN` | **WARN** | GUI + scripting OK but no authenticated session — FIX: run `/sap-login`. |
| `NO_SESSION` | **WARN** | SAP GUI running, scripting OK, no session open — FIX: `/sap-login`. |
| `NO_SCRIPTING` | **FAIL** | Scripting engine unavailable — FIX: SAP Logon > Options > Scripting > Enable Scripting (client) **and** ensure `sapgui/user_scripting=TRUE` on the server (RZ11). |
| `NO_GUI` | **FAIL** | SAP GUI / SAP Logon not running — FIX: start SAP Logon (GUI skills need it). |

A `LOGGED_IN` result is the authoritative proof that scripting is fully enabled
on both client and server — no separate server-parameter read is needed.

---

## Step 2 — cfg + rfc + srv groups

Fill the checks template. **Substitute the six SAP credential tokens with EMPTY
strings** so `Connect-SapRfc` falls back to the AI-session's pinned connection
profile (Phase 4.3) — the doctor then probes the *real* pinned connection and
surfaces a broken pin/profile as an `RFC_PING` failure.

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>'
$skill  = '<SKILL_DIR>'
$ps     = Get-Content "$skill\references\sap_doctor_checks.ps1" -Raw -Encoding UTF8
$ps     = $ps.Replace('%%RFC_LIB_PS1%%',  "$shared\scripts\sap_rfc_lib.ps1")
$ps     = $ps.Replace('%%WORK_DIR%%',     '{work_dir}')
$ps     = $ps.Replace('%%SAP_SERVER%%',   '')
$ps     = $ps.Replace('%%SAP_SYSNR%%',    '')
$ps     = $ps.Replace('%%SAP_CLIENT%%',   '')
$ps     = $ps.Replace('%%SAP_USER%%',     '')
$ps     = $ps.Replace('%%SAP_PASSWORD%%', '')
$ps     = $ps.Replace('%%SAP_LANGUAGE%%', '')
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_doctor_checks_run.ps1', $ps, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Run via **32-bit PowerShell** (NCo 3.1 lives in `GAC_32`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_doctor_checks_run.ps1"
```

Each output line is:

```
CHECK: <ID> | GROUP: <cfg|rfc|srv> | RESULT: <PASS|WARN|FAIL|SKIP> | DETAIL: <text> | FIX: <remediation or ->
DOCTOR_PS: <READY|DEGRADED|BLOCKED> FAIL=<n> WARN=<n> SKIP=<n>
```

Check IDs: `PS_BITNESS`, `NCO_GAC`, `WORKDIR_ENV`, `WORKDIR_WRITE`,
`CONNECTIONS` (cfg); `RFC_PING` (rfc); `CLIENT_MODIFIABLE` (srv).

---

## Step 3 — devenv group (skip with `--no-devenv`)

Unless the user passed `--no-devenv` or `--quiet`, also invoke `/sap-dev-status`
and fold its artefact lines into the report as the **devenv** group. It is
read-only, RFC-only, and authoritative for the TR / package / function group /
wrapper FM + DDIC / utility-program artefacts — do not re-implement those checks
here. Map its `STATUS:` to a devenv group result: `ALL_OK` → PASS,
`GAPS=<n>` → WARN (FIX: `/sap-dev-init`), `ERROR` → SKIP (RFC down — already
reflected by `RFC_PING`).

If `RFC_PING` already FAILED, skip the `/sap-dev-status` call and mark devenv
**SKIP** (it would only re-report the same RFC failure).

---

## Step 4 — Compose and report

Combine the three sources (Step 1 gui, Step 2 cfg/rfc/srv, Step 3 devenv) into
one table, then compute the **overall verdict**:

- **BLOCKED** — any check is `FAIL`.
- **DEGRADED** — no FAIL, but at least one `WARN` or `SKIP`.
- **READY** — every check `PASS`.

```
SAP Doctor — <SYSTEM>/<CLIENT> as <USER>
┌───────────────────┬───────┬────────┬───────────────────────────────────────────────┐
│ Check             │ Group │ Result │ Detail                                        │
├───────────────────┼───────┼────────┼───────────────────────────────────────────────┤
│ GUI scripting     │ gui   │ PASS   │ LOGGED_IN — S4D/100 as DEVELOPER (EN)         │
│ PS_BITNESS        │ cfg   │ PASS   │ 32-bit PowerShell                             │
│ NCO_GAC           │ cfg   │ PASS   │ SAP NCo 3.1 present in GAC_32                  │
│ WORKDIR_ENV       │ cfg   │ WARN   │ SAPDEV_AI_WORK_DIR not set                     │
│ WORKDIR_WRITE     │ cfg   │ PASS   │ work_dir writable: C:\sap_dev_work             │
│ CONNECTIONS       │ cfg   │ PASS   │ connections.json present and valid            │
│ RFC_PING          │ rfc   │ PASS   │ pinned profile reachable                      │
│ CLIENT_MODIFIABLE │ srv   │ PASS   │ client 100 allows Repository changes          │
│ devenv (5 arts)   │ devenv│ PASS   │ /sap-dev-status ALL_OK                        │
└───────────────────┴───────┴────────┴───────────────────────────────────────────────┘
VERDICT: DEGRADED  (0 FAIL · 1 WARN · 0 SKIP)
```

For every `FAIL` (and notable `WARN`), list the check's **FIX** string as a
next-action bullet. If the verdict is `READY`, say so plainly. Honor `--quiet`
by collapsing PASS rows and printing only WARN/FAIL/SKIP plus the verdict.

---

## Step 5 — Clean Up

```bash
cmd /c del "{RUN_TEMP}\sap_doctor_checks_run.ps1"
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_doctor_run.json" -Status SUCCESS -ExitCode 0
```

(For a `BLOCKED` verdict set `-Status FAILED -ExitCode 1 -ErrorClass DOCTOR_BLOCKED`.)

---

## Exit-code contract (for auto-invocation)

| Code | Meaning |
|---|---|
| `0` | `READY` or `DEGRADED` (no FAIL) |
| `1` | `BLOCKED` (one or more FAIL) |

Other sap-dev skills MAY call `/sap-doctor` as a pre-flight when a clean
environment is a precondition — e.g. before a first deploy in a session — to
fail fast with an actionable FIX instead of a vague mid-flow GUI/RFC error.
Read-only and fast, so it is safe to chain.

---

## Known Issues / Limitations

- **gui group needs an attached session.** `LOGGED_IN` is the only result that
  proves server-side scripting; `NO_SESSION` / `LOGIN_SCREEN` mean "can't yet
  confirm server scripting — log in and re-run." This is intentional (the
  authoritative signal is empirical, not a guessed parameter read).
- **`CLIENT_MODIFIABLE` reads the client option (T000), not the system-global
  change option (SE06).** A system set globally "Not modifiable" can still pass
  the client check; a deploy would then fail at activation. Live-verify the
  T000 field set on first run against your release.
- **`CONNECTIONS` is shallow in v1** — it confirms the file exists and is valid
  JSON, not that the pinned profile resolves. `RFC_PING` covers the resolve path
  empirically (it uses the pinned-profile fallback).
- **`--fix` is not implemented in v1.** All remediations are reported as FIX
  strings; nothing is changed automatically. (Planned: auto-create work_dir
  subfolders, set the env var.)
- **Planned (not in v1):** explicit server-side `sapgui/user_scripting`
  parameter read (to distinguish client-vs-server when the gui probe returns
  `NO_SCRIPTING`); best-effort `S_DEVELOP` / `S_TRANSPORT` authorization probe;
  ADT/SICF reachability line; per-profile RFC fan-out.

---

## First-run verification (live)

On the first S4D run, confirm: (1) the T000 field names (`CCNOCLIIND`,
`CCCORACTIV`) and value semantics on your release; (2) that the empty-credential
substitution correctly triggers the `Connect-SapRfc` pinned-profile fallback;
(3) the `sap_check_gui_login_status.vbs` STATUS values map as tabled above.
Write the run report to `sap-dev/temp/testReport/sap_doctor_e2e_<SID>_<date>.md`.
