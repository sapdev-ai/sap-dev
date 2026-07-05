---
name: sap-doctor
description: |
  Read-only environment preflight ("doctor") for the sap-dev toolchain —
  diagnoses why skills fail BEFORE they run, across six default groups: gui (GUI +
  scripting reachable), cfg (32-bit PowerShell, NCo 3.1, work_dir, connections.json),
  rfc (pinned-profile connectivity), srv (client modifiability), auth (user
  authorizations vs the required set), devenv (dev-init artefacts). Emits one CHECK
  line per probe + a verdict (READY / DEGRADED / BLOCKED); a probe that can't run
  reports SKIP, never a false PASS, each with a copy-pasteable FIX. The default run
  is pure read-only and safe to chain (exit 0 = ready, 1 = blocked). OPT-IN group
  --screens replays the golden-screen baselines against the live system to catch
  control-ID drift before a GUI skill mis-steps (navigates the live session, off by
  default; --update-baseline writes baselines). Absorbed /sap-gui-screen-check.
  Prerequisites: SAP GUI; NCo 3.1 (32-bit) for rfc/srv; an active session for gui.
argument-hint: "[--quiet] [--no-devenv] [--screens [<vbs-stem>|--all]] [--update-baseline]"
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
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_readiness_probe.ps1` | `%%READINESS_PROBE_PS1%%` | srv group — `Get-SapReadinessCapability` for the `READINESS_CAP` check (dot-sourced; shared with `/sap-cc-analyze`) |
| `<SKILL_DIR>/references/sap_doctor_authz_probe.ps1` | *(32-bit PS)* | auth group — probes the pinned user's authorizations via `SUSR_USER_AUTH_FOR_OBJ_GET` (Step 3b) |
| `<SAP_DEV_CORE_SHARED_DIR>/tables/required_authorizations.tsv` | *(read)* | auth group — required-authorization set read by the probe above (machine-readable mirror of `docs/security.md §1`) |
| `<SKILL_DIR>/references/sap_doctor_checks.ps1` | *(template)* | cfg + rfc + srv checks (filled + run in 32-bit PowerShell) |
| `<SKILL_DIR>/references/sap_screen_check.ps1` | *(orchestrator)* | screens group (`--screens`) — reads baselines, runs the probe per checkpoint, compares, emits CHECK + SCREENCHECK lines |
| `<SKILL_DIR>/references/sap_screen_check_probe.vbs` | *(probe template)* | screens group — read-only navigate + identity + ID-presence probe (self-resolves SESSION_PATH; Tier-3 + baseline exempt) |
| `contributing/golden_screen_baselines.md` | *(contract)* | screens group — baseline schema (`sapdev.screenbaseline/1`) + authoring rules |
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
$ps     = $ps.Replace('%%READINESS_PROBE_PS1%%', "$shared\scripts\sap_readiness_probe.ps1")
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

## Step 3b — auth group: probe authorizations

Unless `RFC_PING` already FAILED (RFC down → skip, mark auth **SKIP**), probe the
pinned RFC user's authorizations against the required set. Run via **32-bit
PowerShell** (NCo 3.1 in `GAC_32`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_doctor_authz_probe.ps1"
```

It reads `<SAP_DEV_CORE_SHARED_DIR>\tables\required_authorizations.tsv` (the
machine-readable mirror of `docs/security.md §1`) and, for the logged-in user,
calls `SUSR_USER_AUTH_FOR_OBJ_GET` (RFC-enabled — **no dev-init wrapper needed**)
once per authorization object, evaluating each capability with faithful
AUTHORITY-CHECK semantics (a single authorization instance must cover every
required field; `*` matches anything). Output:

```
AUTH: <PASS|FAIL> <capability> (<objects>) - <description>
AUTH: NOT_PROBED (<why>)     # FM unavailable / auth data unreadable — honest, never a fabricated verdict
AUTH_SUMMARY: probed=<n> pass=<p> fail=<f> user=<u> fully_authorized_objects=<list>
```

Map to the **auth** group: all `PASS` → **PASS**; any `FAIL` → **WARN**;
`NOT_PROBED` (or RFC down) → **SKIP**. An auth `FAIL` is a *role-provisioning*
gap, not a broken runtime — it **DEGRADES**, never **BLOCKS** (over-blocking
would break the pre-flight for read-only skills the user is entitled to run).
Keep the per-capability `AUTH:` lines for Step 4; surface each `FAIL` as a
next-action bullet.

Exit code (probe): `0` all pass · `1` ≥1 FAIL · `2` NOT_PROBED.

---

## Step 3c — screens group (OPT-IN, only with `--screens`)

**Skip this entire group unless `--screens` was passed.** It is the live half of
the golden-screen harness — it replays the screen fingerprint baselines
(`references/<stem>.screens.json` across all skills) against the CURRENT system to
catch control-ID / screen-identity drift before a GUI skill silently mis-steps.
Unlike the other groups it **navigates the live session** (OK-code), so it is
opt-in and never part of the default pre-flight run.

**Data-loss guard.** The orchestrator navigates via OK-code (`/nSE38` …), which
discards the current transaction's unsaved data. First read the **current** screen
by running the probe once with an empty OK-code (assess-only, no navigation):

```powershell
$skill = '<SKILL_DIR>'
$vbs = ([System.IO.File]::ReadAllText("$skill\references\sap_screen_check_probe.vbs", [System.Text.Encoding]::UTF8)) `
       -replace '%%SESSION_PATH%%','' -replace '%%OKCODE%%','' -replace '%%REQUIRED_IDS%%',''
$run = '{RUN_TEMP}\sap_screen_check_guard.vbs'
[System.IO.File]::WriteAllText($run, $vbs, [System.Text.UnicodeEncoding]::new($false, $true))
& C:\Windows\SysWOW64\cscript.exe //NoLogo $run
Remove-Item $run -ErrorAction SilentlyContinue
```

If the `IDENTITY:` program is **not** an idle screen (`SAPLSMTR_NAVIGATION` /
`SAPMSYST`), **stop and ask the user to confirm** before proceeding (unsaved-work
risk). Once confirmed (or already idle), continue.

**Run the orchestrator.** Pick the scope from `$ARGUMENTS`: `--screens` with no stem
(or `--all`) → `-All`; `--screens <vbs-stem>` → resolve its baseline path and pass
`-BaselinePath "<...>.screens.json"` (or `-Skill <skill-name>` to sweep one skill).
Add `-Capture` **only** when the user also passed `--update-baseline`.

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_screen_check.ps1" -All -ProbeVbs "<SKILL_DIR>\references\sap_screen_check_probe.vbs" -WorkTemp "{WORK_TEMP}"
```

The orchestrator (plain PowerShell; it shells 32-bit cscript itself) emits:

```
CHECK: <stem>/<cp> | RESULT: PASS|DRIFT|PENDING|COULD_NOT_CHECK | IDS: <n>/<m> | IDENTITY: <pgm>/<scr> [| BASELINE: <pgm>/<scr> | SEVERITY: BLOCKER] | DETAIL: <text>
  MISSING_ID: <path>            (per missing/absent control)
CAPTURE: <baseline-path> | <cp.id> | program=<pgm> | dynpro=<scr>   (only with -Capture, for pending_live)
SCREENCHECK: <OK|DRIFT|DEGRADED> baselines=<N> checkpoints=<M> PASS=.. DRIFT=.. CNC=.. PENDING=..
```

Map the `SCREENCHECK:` verdict into the **screens** doctor group: `OK` → PASS;
`DRIFT` → **FAIL** (a `captured` checkpoint drifted — the named VBS will mis-step on
this release; this BLOCKS, consistent with any-FAIL below); `DEGRADED` → SKIP (only
`pending_live` / `COULD_NOT_CHECK` — nothing gated). Keep each drifted checkpoint's
`MISSING_ID` / identity for the report, and for every DRIFT recommend re-recording
that VBS (`/sap-gui-record` / `/sap-gui-probe`) for this release + updating its baseline.

**Promote pending_live baselines (only with `--update-baseline`).** If `-Capture` was
passed, apply each `CAPTURE: <path> | <cp.id> | program=<pgm> | dynpro=<scr>` line to
its baseline (Edit tool — the orchestrator never writes a baseline itself; manual +
reviewable per CLAUDE.md Directive 2): set `identity.program`/`identity.dynpro`,
`status`=`captured`, `captured_on.method`=`live`, `captured_on.date`=today, `release`=the
session release if known. Then re-run `node scripts/check-consistency.mjs` to confirm
the now-`captured` baseline still validates.

---

## Step 4 — Compose and report

Combine the sources (Step 1 gui, Step 2 cfg/rfc/srv, Step 3 devenv, Step 3b auth,
and Step 3c screens when `--screens` was passed) into one table, then compute the
**overall verdict**:

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
│ auth (10 caps)    │ auth  │ PASS   │ 10/10 capabilities pass (DEVELOPER)           │
│ devenv (5 arts)   │ devenv│ PASS   │ /sap-dev-status ALL_OK                        │
└───────────────────┴───────┴────────┴───────────────────────────────────────────────┘
VERDICT: DEGRADED  (0 FAIL · 1 WARN · 0 SKIP)
```

For every `FAIL` (and notable `WARN`), list the check's **FIX** string as a
next-action bullet. If the verdict is `READY`, say so plainly. Honor `--quiet`
by collapsing PASS rows and printing only WARN/FAIL/SKIP plus the verdict.

**Authorizations (auth group — append the Step 3b lines after the table).**
Append the probe's per-capability `AUTH:` lines verbatim below the table, then
the `AUTH_SUMMARY`. If it returned `AUTH: NOT_PROBED` (or RFC was down), append
that single line plus the pointer: *required-authorization table:
`docs/security.md §1`; after any authorization failure run SU53 on this user, or
capture STAUTHTRACE during a pilot to cut the final role.* For each `AUTH: FAIL`,
add a next-action bullet naming the failing capability + the same SU53/§1 pointer
(the user requests the missing role from Basis). An `AUTH: FAIL` maps to the
**auth** group `WARN` → the verdict DEGRADES, never BLOCKS.

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

(For a `BLOCKED` verdict set `-Status FAILED -ExitCode 1 -ErrorClass DOCTOR_BLOCKED`;
when the block is a `--screens` DRIFT specifically, use `-ErrorClass SCREEN_DRIFT`.)

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
- **auth group reads *assigned* authorizations, not a live AUTHORITY-CHECK.**
  The probe evaluates `SUSR_USER_AUTH_FOR_OBJ_GET` (the user's granted values)
  with AUTHORITY-CHECK semantics — one authorization instance must cover all
  required fields — for the representative object + fields per capability in
  `required_authorizations.tsv`, not every field/value a skill might hit. A
  `PASS` means "has the core grant", not "provably can never be denied"; an
  `AUTH: FAIL` is high-signal (the grant is genuinely absent). After a runtime
  denial, SU53 on the user remains the authoritative cut. The probe reads its
  OWN user's data, so it needs no special auth; if the read is refused it says
  `NOT_PROBED`, never a fabricated verdict.
- **Planned (not in v1):** explicit server-side `sapgui/user_scripting`
  parameter read (to distinguish client-vs-server when the gui probe returns
  `NO_SCRIPTING`); ADT/SICF reachability line; per-profile RFC fan-out.

---

## First-run verification (live)

On the first S4D run, confirm: (1) the T000 field names (`CCNOCLIIND`,
`CCCORACTIV`) and value semantics on your release; (2) that the empty-credential
substitution correctly triggers the `Connect-SapRfc` pinned-profile fallback;
(3) the `sap_check_gui_login_status.vbs` STATUS values map as tabled above;
(4) the auth probe — `SUSR_USER_AUTH_FOR_OBJ_GET` is RFC-enabled and the
capability PASS/FAIL matches the user's role. (Auth probe live-verified on
S4H/easy 2026-07-03: a DEVELOPER passed 10/10; an ungranted `ACTVT=99` correctly
FAILed; missing rules → `NOT_PROBED`.) Write the run report to
`sap-dev/temp/testReport/sap_doctor_e2e_<SID>_<date>.md`.
