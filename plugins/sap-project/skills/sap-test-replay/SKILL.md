---
name: sap-test-replay
description: |
  Turns a recorded business scenario into a re-runnable pass/fail GUI regression test — the
  eCATT/CBTA equivalent the suite lacks — so a regression cycle stops meaning "re-test transactions
  by hand and paste screenshots into Word". A scaffold-recorded linear scenario (control IDs + screen
  identity + popup transitions from /sap-gui-probe) is compiled into GUI segments run by ONE generic
  interpreter VBS, with exactly three checkpoint types — field (control value), message (status-bar
  class/number/type, can capture the created doc number into a token), and table (post-step
  RFC_READ_TABLE key assertion) — and a screenshot on every failure. The headline value AI adds is
  honest triage: FAIL (the system regressed) is kept STRICTLY distinct from REPLAY_ERROR (the replay
  broke: guard mismatch / unexpected popup / capture failure), so flakiness never masquerades as a
  regression; a table check that can't run is COULD_NOT_CHECK -> PASS_WITH_GAPS, never a silent pass.
  run executes transactions (confirm-gated; typed confirm off DEV); lint validates token coverage +
  guard completeness + tcode + checkpoint fields vs live DDIC; init converts a probe folder into a
  scenario skeleton. Emits a sapdev.testverdict/1 line so a campaign ledger and /sap-run-abap-unit
  join the same verdict stream. Release variance lives in scenario DATA, not VBS code. Prerequisites:
  a scaffold-recorded scenario (/sap-gui-probe + init); /sap-login session; NCo 3.1 (32-bit).
argument-hint: "run <scenario.replay.json> [--data <bindings.tsv>] [--keep-going] [--dry-run] | lint <scenario.replay.json> [--data <b.tsv>] | init <probe-folder> [--name <s>]"
---

# SAP Test-Replay Skill

You replay a recorded scenario as a pass/fail regression test: compile it, lint it, drive the GUI via
the generic interpreter, assert checkpoints (field / message / RFC table), and roll up a verdict that
keeps FAIL (regression) strictly apart from REPLAY_ERROR (the replay broke). run is confirm-gated —
it executes real transactions.

Task: $ARGUMENTS

The compile/lint, table checks, and roll-up are scripts; the interpreter is a generic VBS; **you**
run the confirm gate and narrate the failure triage.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_replay_compile.ps1` | `-Action lint\|compile` | Lint (RFC) + segment compiler |
| `<SKILL_DIR>/references/sap_replay_exec.vbs` | via 32-bit cscript | Generic segment interpreter (GUI) |
| `<SKILL_DIR>/references/sap_replay_table_check.ps1` | `-CheckFile -Values` | RFC_READ_TABLE assertion engine |
| `<SKILL_DIR>/references/sap_replay_report.ps1` | `-ReplayFile -CheckFile` | Verdict roll-up + `sapdev.testverdict/1` line |
| `<SKILL_DIR>/references/replay_scenario_schema.md` · `example_mm03.replay.json` | docs | Scenario format + example |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/test_verdict_contract.md` | contract | The verdict-line shape |
| `/sap-gui-probe` · `/sap-gui-skill-scaffold` · `/sap-gui-inspect` | sub-skills | record / scaffold / screenshot-on-fail |
| `/sap-login` | sub-skill | Session + broker acquire/release |

---

## Step 0 — Resolve Work Directory + Logging

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Then `sap_log_helper.ps1 -Action start -StateFile {RUN_TEMP}\sap_test_replay_run.json`.

## Step 1 — Parse Args + init/lint

`run` | `lint` | `init`. `init` (pure local) turns a probe/scaffold folder into a scenario skeleton
(steps + guards + popup branches pre-filled, checkpoints stubbed) and stops. `lint`:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_replay_compile.ps1" -Action lint -Scenario "<scenario>" -Data "<bindings>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

`VERDICT: LINT_ERROR` (unbound token, guard gap, missing tcode/field) -> `REPLAY_SCENARIO_INVALID`,
stop. `LINT_PARTIAL` (no RFC) -> proceed with the DDIC checks marked COULD_NOT_CHECK.

## Step 2 — run: session + release check

Ensure a GUI session (`/sap-login`), broker `acquire`, liveness check. WARN if the scenario's
`recorded_release` != the live `server_release_marker` (guards catch real divergence as
REPLAY_ERROR:GUARD).

## Step 3 — CONFIRM gate (mandatory; run executes transactions)

Render tcode, system/client, binding summary, checkpoint count. Non-DEV/modifiable client -> **typed**
confirmation `REPLAY <SID>`; DEV -> yes/no. `--dry-run` compiles + lints only (no GUI, no gate).

## Step 4 — Compile + segment loop

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_replay_compile.ps1" -Action compile -Scenario "<scenario>" -Data "<bindings>" -OutDir "{RUN_TEMP}\compiled"
```

For each `segment_NN.tsv`: substitute captured tokens, run the interpreter (32-bit cscript, with
`%%SESSION_PATH%%`/`%%ATTACH_LIB_VBS%%`/`%%SESSION_LOCK_VBS%%`/`%%STEPS_FILE%%` substituted), collect
its `REPLAY:`/`MSG:`/`CAPTURE:` lines, then run the RFC table checks for that boundary:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_replay_table_check.ps1" -CheckFile "{RUN_TEMP}\compiled\table_checks.tsv" -Values "<bindings+captures>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

On any `REPLAY_ERROR`/`FAIL`: invoke `/sap-gui-inspect screenshot composite` (attach to the report),
then stop (default) or continue (`--keep-going`).

## Step 5 — Roll-up + Register

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_replay_report.ps1" -ReplayFile "<replay-lines>" -CheckFile "<check-lines>" -CaseId "<case_id>" -ScenarioName "<name>" -OutDir "{OUT}" -RunId "<run_id>"
```

Verdict: `REPLAY_ERROR` > `FAIL` > `PASS_WITH_GAPS` > `PASS`. Register `report.md`, `results.tsv`,
`verdict.tsv` (the `sapdev.testverdict/1` line), and screenshots; broker `release`.

## Final — Log End

`sap_log_helper.ps1 -Action end` with status + error_class: `REPLAY_SCENARIO_INVALID`,
`REPLAY_GUARD_MISMATCH`, `REPLAY_UNEXPECTED_POPUP`, `REPLAY_CAPTURE_FAILED`, `REPLAY_ASSERT_FAILED`,
`RFC_LOGON_FAILED`, `GUI_TIMEOUT`.

---

## Scope & Limitations (v1)

- **v1 implemented:** `run` (compile -> segment interpreter -> RFC table checks -> verdict), `lint`,
  `init`. Three checkpoint types (field / message / table). Emits `sapdev.testverdict/1`.
- **Live-verified on S4D (S/4HANA 1909) — the non-GUI pipeline end to end:** `lint` returned LINT_OK
  for the shipped MM03 scenario (tokens bound, MM03 in TSTC, MARA-MATNR confirmed via
  DDIF_FIELDINFO_GET) and LINT_ERROR on an unbound token; `compile` split the scenario into the correct
  segment + table_checks; the **table-check engine** returned PASS for a real material and FAIL for a
  fake one; the **roll-up** passes the full truth table including the load-bearing distinction —
  **a step REPLAY_ERROR beats a checkpoint FAIL** (flakiness never masquerades as a regression),
  COULD_NOT_CHECK -> PASS_WITH_GAPS — and emits the verdict line.
- **Deliberately NOT run autonomously (the GUI leg):** `run` drives the interpreter VBS which EXECUTES
  transactions — it is confirm-gated (typed off DEV) and needs a scaffold-recorded scenario, so this
  session verified the compiler / lint / table-check / roll-up, not a live GUI replay. The interpreter
  ships correct (attach-lib + session-lock, control-ID dispatch, screen-identity guard poll, unexpected-
  popup -> REPLAY_ERROR:POPUP, language-independent MessageType capture) with a golden-screen baseline
  for its generic deps; a scenario's target screens are DATA, so drift surfaces as REPLAY_ERROR:GUARD
  pointing at a /sap-gui-probe re-record, never a wrong-screen action.
- **Honesty invariants:** guard mismatch / unexpected popup / capture failure -> REPLAY_ERROR (never
  FAIL, never PASS); a table check that can't run -> COULD_NOT_CHECK -> PASS_WITH_GAPS; grid-row
  assertions are banned in v1 (RFC key lookup only — the classic eCATT flake source).
- **Deferred:** `run --data` multi-row loop (v1.5); `campaign` ledger modes (v2); suites / branching /
  ALV cell assertions. ECC 6 shares the identical RFC path (all 3 FMs + tables probed identical;
  VA01/MM01/BP same driving programs); a scenario is release-bound (recorded_release vs live marker).
  EC2 was unavailable this session for the ECC re-confirm.
