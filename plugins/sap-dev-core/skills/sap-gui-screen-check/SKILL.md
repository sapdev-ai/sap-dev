---
name: sap-gui-screen-check
description: |
  Live half of the golden-screen regression harness. Replays the screen
  fingerprint baselines (`references/<stem>.screens.json`, schema
  sapdev.screenbaseline/1) against the CURRENT SAP system and reports control /
  screen-identity drift BEFORE a user hits a silent false-success. For each
  checkpoint the orchestrator (`sap_screen_check.ps1`) drives the read-only probe
  (`sap_screen_check_probe.vbs`): navigate to the screen via the `reach` OK-code,
  read its identity (program + dynpro), and test that every control ID the
  driving VBS depends on still resolves via findById. Language-independent
  (asserts IDs + program/dynpro, never displayed text). A missing control or an
  identity mismatch on a `captured` checkpoint is reported as DRIFT (BLOCKER) —
  the named VBS will silently mis-step on this release; a `pending_live`
  checkpoint is captured and (only with --update-baseline) promoted to
  `captured`. Pairs with the static CI coverage gate in
  scripts/check-consistency.mjs and the contract in
  contributing/golden_screen_baselines.md.
  Drives the live session via OK-code navigation — run it from an idle session.
  Read-only against SAP (only navigates); only writes a baseline file with
  --update-baseline.
  Prerequisites: an active SAP GUI session (use /sap-login first).
argument-hint: "[<vbs-stem> | --all] [--update-baseline] [--quiet]"
---

# SAP GUI Screen-Check Skill

You replay golden-screen baselines against the live SAP system to catch
release/locale drift in the control IDs and screen identities the driving VBS
templates depend on. This is the pre-flight counterpart to the per-object RFC
PROGDIR/DWINACTIV post-deploy verify: that catches "did the write land?" after a
run; you catch "will the write path even execute?" before, across all skills.

The deterministic work (enumerate baselines, run the probe per checkpoint, parse,
compare identity + control presence, roll up a verdict) lives in the PowerShell
orchestrator `references/sap_screen_check.ps1`, which shells the read-only probe
`references/sap_screen_check_probe.vbs` via 32-bit cscript. Your job is the
pre-flight safety guard, invoking the orchestrator with the right scope, and
(only under `--update-baseline`) applying its `CAPTURE:` lines to the baselines.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — baseline write gated behind `--update-baseline` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | Assert by component ID + program/dynpro, never displayed text |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_check_gui_login_status.vbs` | *(static VBS)* | Step 1 — confirm a live session |
| `<SKILL_DIR>/references/sap_screen_check.ps1` | *(orchestrator)* | Reads baselines, runs the probe per checkpoint, compares, emits CHECK + SCREENCHECK lines |
| `<SKILL_DIR>/references/sap_screen_check_probe.vbs` | *(probe template)* | Read-only navigate + identity + ID-presence probe (self-resolves SESSION_PATH; Tier-3 + baseline exempt) |
| `contributing/golden_screen_baselines.md` | *(contract)* | Baseline schema + authoring rules |

---

## Step 0 — Resolve Work Directory

Resolve `work_dir` via the env-aware helper (parse the `WORK_DIR=` line):

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
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_gui_screen_check_run.json" -Skill sap-gui-screen-check -ParamsJson "{}"
```

---

## Step 1 — Pre-flight + navigation-safety guard

Confirm a live session:

```bash
C:/Windows/SysWOW64/cscript.exe //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_gui_login_status.vbs"
```

- Not `LOGGED_IN` → stop: "No authenticated SAP session — run /sap-login first."
- Record `SYSTEM` / `CLIENT` (for the report and `captured_on`).

**Data-loss guard.** The orchestrator navigates via OK-code (`/nSE38` …), which
discards the current transaction's unsaved data. Read the **current** screen by
running the probe once with an empty OK-code (assess-only, no navigation):

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
`SAPMSYST`), **stop and ask the user to confirm** before proceeding — they may
have unsaved work. Once confirmed (or already idle), continue.

---

## Step 2 — Run the orchestrator

Pick the scope from `$ARGUMENTS`:

- `--all` (or no positional) → `-All`
- `<vbs-stem>` → resolve its baseline path and pass `-BaselinePath "<...>.screens.json"`
  (or `-Skill <skill-name>` to sweep one skill's baselines).

Add `-Capture` **only** when the user passed `--update-baseline`.

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

Exit code: `1` if any checkpoint DRIFTed, else `0`.

---

## Step 3 — Promote pending_live baselines (only with `--update-baseline`)

If `-Capture` was passed, apply each `CAPTURE: <path> | <cp.id> | program=<pgm> |
dynpro=<scr>` line to its baseline (Edit tool) — the orchestrator never writes a
baseline itself (manual + reviewable per CLAUDE.md Directive 2). For the named
checkpoint in `<path>`:

- set `identity.program` = `<pgm>`, `identity.dynpro` = `<scr>`,
- set `status` = `captured`,
- set `captured_on.method` = `live`, `captured_on.date` = today, `release` = the
  session release if known (else leave); leave `kernel` for the operator.

Then re-run the CI gate to confirm the now-`captured` baseline still validates:

```bash
node scripts/check-consistency.mjs
```

---

## Step 4 — Report

Print a table: per checkpoint — baseline, checkpoint id, RESULT, and detail. For
every **DRIFT**, name the exact control(s) (`MISSING_ID`) or the identity that
moved and the VBS that depends on it, then recommend re-recording that VBS
(`/sap-gui-record` / `/sap-gui-probe`) for this release and updating its baseline.
End with the overall verdict from the `SCREENCHECK:` line:

| SCREENCHECK | Meaning |
|---|---|
| `OK` | every `captured` checkpoint matched (identity + all required IDs) → **CLEAN** |
| `DRIFT` | one or more `captured` checkpoints drifted → re-record the named VBS |
| `DEGRADED` | only `pending_live` / `COULD_NOT_CHECK` checkpoints; nothing gated |

Honor `--quiet` by printing only DRIFT / COULD_NOT_CHECK rows plus the verdict.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_gui_screen_check_run.json" -Status SUCCESS -ExitCode 0
```

(For a DRIFT verdict set `-Status FAILED -ExitCode 1 -ErrorClass SCREEN_DRIFT`.)

---

## Known Issues / Limitations

- **OK-code (initial-screen) checkpoints only in v1.** A checkpoint whose `reach`
  is a multi-step recipe is reported COULD_NOT_CHECK by the probe (it navigates
  by `reach.okcode` only). Deepen by extending the probe/orchestrator.
- **Navigates the live session.** Run from an idle session; the Step 1 guard asks
  before navigating away from a non-idle screen (unsaved-data risk).
- **New-control detection (INFO) not in v1.** The probe tests the required set and
  reads identity; it does not yet diff the full present-control set.
- **Release/kernel in `captured_on`** are best-effort — SAP GUI Scripting does not
  expose the kernel patch cleanly; the operator may fill them.
- **Findings are self-contained.** v1 does not yet bridge DRIFT into
  `sap_finding_lib` for `/sap-evidence-pack` composition (future).

---

## First-run verification (live)

On first use, run `/sap-gui-screen-check sap_se38_create --update-baseline` from
SAP Easy Access: it should navigate to SE38, read the initial-screen identity,
confirm `ctxtRS38M-PROGRAMM` / `radRS38M-FUNC_EDIT` / `btnNEW` / `okcd` all
PRESENT, emit a `CAPTURE:` line, and (after Step 3 promotion) leave the seeded
`pending_live` checkpoint `captured` with the CI gate green. Write the report to
`sap-dev/temp/testReport/sap_gui_screen_check_e2e_<SID>_<date>.md`.
