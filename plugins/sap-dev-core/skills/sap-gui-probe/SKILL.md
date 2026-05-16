---
name: sap-gui-probe
description: |
  Drive a SAP transaction step by step against a natural-language scenario,
  dumping each screen's full property tree via /sap-gui-object-details and
  emitting a synthesized recording-style VBS at the end. Designed as a
  skill-authoring aid: probe SE37 before writing a new /sap-se37 flow.
  Captures more than the SAP recorder -- not just findById paths and
  actions, but also Changeable, Tooltip, IconName, popup transitions, and
  the program/transaction/screen identity at every step.

  Two safety modes:
    * mode=confirm (default) -- read-only actions auto-proceed; write
      actions (Save / Activate / Delete and the matching VKey codes 11, 14,
      27, 28, 33) pause for explicit user confirmation.
    * mode=auto  -- opt-in via trailing `--auto` flag in the scenario;
      every action proceeds without prompting.

  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<TXN>: <scenario>   e.g. 'SE37: display FM RFC_READ_TABLE then exit'   append --auto to skip confirmations"
---

# SAP GUI Probe Skill

You drive a SAP transaction step by step against a natural-language
scenario the user supplied. At every screen transition you call the
sap-gui-object-details VBS to capture a full property dump, you emit one
small action JSON describing the next move, you classify that action as
READ or WRITE, you (optionally) confirm with the user, and you execute it.

When the scenario is complete you synthesize every action into one
replayable VBS. The output folder is the deliverable -- a fresh skill
author can read it and write a deterministic skill for the probed flow.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | Two-file settings model — merge `settings.local.json` over `settings.json` per-key on `.value`; writes always go to `settings.local.json` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |

---

## Step 0 — Resolve work directory and run folder

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Read sap-dev-core's `settings.json` (go 2 levels up from `<SKILL_DIR>` to the
plugin root, then `settings.json`). Read `work_dir`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Derive:
- `{WORK_TEMP}`  = `{work_dir}\temp`
- `{TS}`         = current timestamp `yyyyMMdd-HHmmssfff` (milliseconds — REQUIRED for parallel-safety; two probes started in the same second under a parallel scaffolder run would otherwise collide on folder name)
- `{PID}`        = the orchestrator's process ID — append as an extra suffix to guarantee uniqueness across simultaneous AI sessions on the same host. PowerShell: `$PID`. Bash on Windows: `echo $$` (the cygwin/git-bash PID, distinct per shell). Either works.
- `{TXN}`        = transaction code extracted from the scenario in Step 1
- `{RUN_FOLDER}` = `{work_dir}\probes\{TXN}_{TS}_p{PID}`

Ensure folders exist (one Bash call, two mkdir):
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
cmd /c if not exist "{RUN_FOLDER}" mkdir "{RUN_FOLDER}"
```

**Why ms + pid?** Today's parallel scaffolder spawns N sub-agents from one process; each sub-agent invokes this skill in its own cscript run, but they all derive `{TS}` from `Get-Date -Format 'yyyyMMdd-HHmmss'` and can land in the same second. Adding `fff` (ms) and the process ID makes collisions effectively impossible in practice. Sub-agents under the SAME orchestrator process share `{PID}` but have different `{TS}` ms; sub-agents under DIFFERENT orchestrator processes (the typical AI-session-vs-AI-session case) have different `{PID}`. Either axis alone is sufficient; using both is belt-and-braces.

---

## Step 0.5 — Start logging

State file: `{RUN_FOLDER}\sap_gui_probe_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_FOLDER}\sap_gui_probe_run.json" -Skill sap-gui-probe -ParamsJson "{\"txn\":\"<TXN>\",\"mode\":\"<MODE>\",\"scenario\":\"<short scenario>\"}"
```

---

## Step 0.6 — Resolve active SAP GUI session

Pick the SAP GUI session to drive. Resolution order (first hit wins):

1. **Explicit `--session "/app/con[N]/ses[M]"` flag** in `$ARGUMENTS` → use it verbatim.
2. **AI-session pin** → run:
   ```powershell
   . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
   $sessionPath = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
   ```
   `Get-SapCurrentSessionPath` resolves the AI-session id (via parent-PID walk), looks up `ai_sessions[<id>].connection_id` in `session_registry.json`, finds a usable session on that connection block, and returns its path. Returns empty when no pin and no sole-conn fallback.
3. **Exactly one connection attached** → `Get-SapCurrentSessionPath` already handles this via its sole-conn fallback; returns `/app/con[0]/ses[0]` automatically. Preserves today's behaviour for single-connection users.
4. **Multiple connections, no pin** → empty return. Refuse with: *"multiple SAP GUI connections detected and no active session pinned; run /sap-login first to pick one."* Log end Status=FAILED ErrorClass=NO_PIN.

The resolved path is stored as `{SESSION_PATH}` and propagated to every subsequent step:
- Dump calls in Step 2.1 / 2.7 pass `-SessionPath "{SESSION_PATH}"` to `sap_gui_probe_dump.ps1`.
- Action JSONs in Step 2.3 include a `"session": "{SESSION_PATH}"` field, which `sap_gui_probe_action.vbs` resolves via `oApp.findById(...)`.

Stale pin guard: if `findById({SESSION_PATH})` returns `Nothing` (the user closed the session), fall back through the same order starting at step 2. If step 3 fires, the probe aborts cleanly.

*Phase 4.2 note:* prior versions of this skill read `{WORK_TEMP}\sap_active_session.json` for the session path AND used `userConfig.sap_pinned_session` as a fallback. Both removed. Session path resolution now goes through `Get-SapCurrentSessionPath`; version info (when needed) comes from `Get-SapCurrentConnectionProfile`. Cross-AI-session persistence lives in `connections.json` via `default_target_id`.

Also stamp the probe's run state with version info copied from the pin file (if present):
- `gui_version_raw`, `gui_major`
- `server_release_marker`, `server_release_raw`, `system_name`, `client`

These propagate into `sap_gui_probe_run.json` and the synthesized.vbs header.

---

## Step 0.7 — Pre-flight: GUI session must be live

Run the canonical login probe (no template substitution -- it's a static
script). Aborts the probe if no session is attached.

```bash
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_gui_login_status.vbs"
```

If the last line is anything other than `STATUS: LOGGED_IN`, stop and tell
the user to run `/sap-login` first. Log end with Status=FAILED ErrorClass=NO_SESSION.

---

## Step 1 — Parse the scenario

The argument is opaque free text. You (Claude) parse it. Extract:

1. **TXN code** -- usually the leading token before the first colon. Heuristic:
   match `^([A-Z][A-Z0-9_/]{1,19})\s*[:\-]` against the trimmed scenario.
   If no clean match, ask the user once for the TXN.
2. **Mode flag** -- if `--auto` appears anywhere (case-insensitive), set
   `MODE = auto`. Otherwise `MODE = confirm`. Strip the flag from the
   working copy of the scenario.
2b. **Session flag** -- if `--session "<path>"` or `--session <path>` (no
    quotes) appears, capture `<path>` and strip the flag. Overrides the
    Step 0.6 resolution and pins the probe to that session for every dump
    and action call.
3. **Flow summary** -- a one-line plan in your own words. Echo it to the
   user before Step 2 so they can correct course early. Example:

   > Probing **SE37** in **confirm** mode. Plan: open SE37 → enter FM
   > `RFC_READ_TABLE` → press Display → land on the FM display tabs → F3
   > back twice to SAP Easy Access. ~6 steps expected.

4. **Step counter** -- initialise `N = 1`. Max steps = 30 (hard cap).

If `MODE = auto`, emit a single line warning before Step 2:

> ⚠️  AUTO MODE — write actions (Save/Activate/Delete) will run without confirmation.

---

## Step 1.5 — Claim the session (parallel-safety) — REQUIRED

Before doing ANY work against the resolved `{SESSION_PATH}`, claim the
session via the shared owner-lock helper. This prevents two parallel
probe runs from accidentally landing on the same session and corrupting
each other's state. The lock is advisory but it surfaces accidents loud
and early rather than silently after destruction.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_owner.ps1" -Action claim -SessionPath "{SESSION_PATH}" -OwnerSkill "sap-gui-probe" -OwnerRunId "%SAPDEV_RUN_ID%" -WorkTemp "{WORK_TEMP}"
```

Read the last line of stdout:
- `CLAIMED` → proceed.
- `DENIED: held by <skill> pid=<pid> age=<sec>` → another agent has the
  session locked. Abort cleanly with `ABANDONED: session {SESSION_PATH} already claimed by <skill>`.
  Do NOT proceed — the scaffolder dispatcher should have assigned a free
  session and didn't; failing fast lets the operator see the misalignment.

Best-effort release on EVERY exit path (success, failure, abandon):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_owner.ps1" -Action release -SessionPath "{SESSION_PATH}" -WorkTemp "{WORK_TEMP}"
```

The lock has a 10-minute TTL — a crashed probe doesn't permanently
block its session.

---

## Step 2 — The dump / decide / classify / confirm / act / dump loop

### 2.0 — Stale-state guard (parallel-safety) — REQUIRED before step 01

Before action 1, dump the current screen state and verify the session is
at SAP Easy Access (transaction `SMEN`, screen `101` or `40`). When the
scaffolder is running probes in parallel, a session may have been left
mid-flow by a previous probe that crashed, or by an unrelated agent. If
the session is NOT at Easy Access, send `/n` (reset to Easy Access),
sleep 600 ms, dump again, and verify.

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_gui_probe_dump.ps1" -Mode wnd -Filter 0 -OutputFile "{RUN_FOLDER}\step_00_pre.txt" -SessionPath "{SESSION_PATH}"
```

Read the dump. Confirm:
- `Transaction:` is empty or `SMEN`.
- `Screen:` is `101` or `40`.
- No popup window (`POPUP WINDOW wnd[1]` absent).

If any check fails, send a reset action and re-dump:

```bash
echo {"verb":"SET_OKCD","value":"/n","session":"{SESSION_PATH}","note":"reset stale state"} > "{RUN_FOLDER}\step_00_reset.json"
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo "<SKILL_DIR>\references\sap_gui_probe_action.vbs" "{RUN_FOLDER}\step_00_reset.json"
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_gui_probe_dump.ps1" -Mode wnd -Filter 0 -OutputFile "{RUN_FOLDER}\step_00_post.txt" -SessionPath "{SESSION_PATH}"
```

If the second dump STILL shows non-Easy-Access state, abort with
`ABANDONED: session not reachable from stale state` rather than corrupting
another probe's session by issuing destructive keystrokes (Shift+F3 can
close a session entirely — that's how today's CUKY runner destroyed
ses[3]).

For each step until the scenario is complete or N > 30:

### 2.1 — Dump the current screen ("before")

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_gui_probe_dump.ps1" -Mode wnd -Filter 0 -OutputFile "{RUN_FOLDER}\step_NN_before.txt" -SessionPath "{SESSION_PATH}"
```

`NN` is the zero-padded step counter (`01`, `02`, ...). Use `-Mode wnd -Filter 0`
for the main window; switch to `-Mode tree` (no filter) when you expect a
popup so all of `wnd[1]..wnd[5]` are captured too. Use `-Mode id -Filter <path>`
when you only need to verify one component.

After the call, **Read the dump file** (limit ~120 lines is usually enough)
to extract:
- Title (`MAIN WINDOW wnd[0]   Title: [...]`)
- Program / Transaction / Screen (header lines)
- Any popup window present (`POPUP WINDOW wnd[1]`)
- The findById paths of the controls you need for the next action

### 2.2 — Decide the next action

Based on (a) the dump, (b) the original scenario, (c) the prior actions
already logged in this run, decide the single next move. Possible verbs:

| Verb | Use when | Required JSON fields |
|---|---|---|
| `SET_OKCD` | navigate via OK-Code box (`/nMM03`, `/n`, `/i`) | `value` |
| `SET_TEXT` | type into a normal field | `target`, `value` |
| `SEND_VKEY` | press a function key (Enter=0, F3=3, F4=4, F8=8, Ctrl+S=11, Ctrl+F2=26, Ctrl+F3=27, Shift+F2=14) | `vkey` (and `target`=`wnd[0]` or the popup) |
| `PRESS` | click a toolbar / popup button | `target` |
| `SELECT_ROW` | tick a GuiTableControl row (uses `getAbsoluteRow(n).Selected = True`) | `target`, `row` |
| `DOUBLE_CLICK` | double-click (tree node, ALV cell, status-bar long-msg) | `target` |

### 2.3 — Write the action JSON

Write `{RUN_FOLDER}\step_NN_action.json` with this exact shape (flat JSON
only -- no comments, no nested objects). Always include `note` -- the
synthesized.vbs uses it as the per-step comment, and the classifier in
Step 2.4 reads it for the write-keyword check on `PRESS`.

```json
{
  "verb":    "SET_TEXT",
  "target":  "wnd[0]/usr/ctxtRMMG1-MATNR",
  "value":   "ZHKAMATVer7001",
  "session": "/app/con[0]/ses[0]",
  "note":    "Enter material number"
}
```

The `session` field is **optional**. When present, `sap_gui_probe_action.vbs` resolves it via `oApp.findById(...)`; when absent, the dispatcher falls back to the first connection's first session (preserves single-session behaviour). Step 2 of this skill always populates `session` from `{SESSION_PATH}` so every action runs against the pinned session.

### 2.4 — Classify the action

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_gui_probe_classify_action.ps1" -ActionPath "{RUN_FOLDER}\step_NN_action.json"
```

Last line on stdout is `READ` or `WRITE`. The full ruleset is in the
script header.

### 2.5 — Confirm if WRITE and MODE=confirm

If the classifier returned `WRITE` **and** the mode is `confirm`, pause and
ask the user with AskUserQuestion. Surface:

- The action JSON (rendered as a one-liner: `PRESS wnd[0]/tbar[0]/btn[11] — Save`)
- The current screen identity (Program / Transaction / Screen number / Title from the dump)
- Two options: `Proceed`, `Abort run`.

If the user picks Abort, jump to Step 4 and log end Status=ABANDONED.

If MODE=auto, skip the confirmation entirely.

### 2.6 — Run the action

```bash
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo "<SKILL_DIR>\references\sap_gui_probe_action.vbs" "{RUN_FOLDER}\step_NN_action.json"
```

Last line is `DONE` or `ERROR: <text>`. On error: read the run folder's
last `*_before.txt` to surface current screen state, log a diagnostic
to the user, and stop (do not auto-retry). The user picks: abort, or
edit the action JSON manually and tell you to re-run that step.

### 2.7 — Dump the resulting screen ("after")

Same call as Step 2.1 but with `-OutputFile "{RUN_FOLDER}\step_NN_after.txt"`.
Use `-Mode tree` (no window scope) here -- a popup may have appeared.

### 2.8 — Compare and decide whether to continue

Read the new dump's header. Compare `Program / Transaction / Screen` between
before and after. Cases:

- **Different screen** -- progress; increment `N`, loop.
- **Same screen, no popup** -- NOOP. The action didn't change anything.
  Surface the situation to the user (action verb, target, current screen)
  with AskUserQuestion: `Continue with a different action`, `Abort`.
- **Same main screen but a popup appeared** -- handle the popup in the next
  iteration; increment `N`, loop. (You'll see `POPUP WINDOW wnd[1]` in the
  dump.)
- **Scenario complete** -- exit the loop and go to Step 3.

If `N > 30`, abort: tell the user the hard cap was hit and the scenario may
need to be split; log end Status=ABANDONED.

---

## Step 3 — Synthesize the replay VBS

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_gui_probe_synthesize.ps1" -RunFolder "{RUN_FOLDER}"
```

Output is `{RUN_FOLDER}\synthesized.vbs`. The script reads every
`step_NN_action.json` in alphanumeric order, emits one VBS line per action
with a step-delimited comment + the `note`, and ends with `WScript.Echo
"REPLAY DONE"`.

---

## Step 4 — Cleanup

Best-effort return to SAP Easy Access. Use SET_OKCD via the action dispatcher:

```bash
echo {"verb":"SET_OKCD","value":"/n","note":"return to Easy Access"} > "{RUN_FOLDER}\step_99_action.json"
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo "<SKILL_DIR>\references\sap_gui_probe_action.vbs" "{RUN_FOLDER}\step_99_action.json"
```

If a modal popup is open and `/n` doesn't work, surface that to the user
and stop -- don't keep retrying.

---

## Final — Log end and report

On success:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_FOLDER}\sap_gui_probe_run.json" -Status SUCCESS -ExitCode 0
```

On failure / abandon, swap `-Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"` or `-Status ABANDONED -ExitCode 0`. Suggested
classes: `NO_SESSION`, `ACTION_FAILED`, `MAX_STEPS`, `USER_ABORTED`.

Report to the user:

- `{RUN_FOLDER}` path
- `synthesized.vbs` path
- A short markdown table of every step: `# | screen-identity | verb | target/value | note`
- Any notable edge cases discovered (NOOP steps, unexpected popups, write
  actions that were skipped after user abort)

---

## Recipes

**SE37 display-FM probe (read-only, 6 steps):**
```
/sap-gui-probe "SE37: display FM RFC_READ_TABLE; then F3 back to Easy Access"
```

**MM03 view probe (read-only, 8 steps, demonstrates table-row tick):**
```
/sap-gui-probe "MM03: display material ZHKAMATVer7001 Basic Data 1 view; F3 back to Easy Access"
```

**SE38 activate probe (one write action, confirm-mode pauses once):**
```
/sap-gui-probe "SE38: open program ZSANDBOX, run syntax check (Ctrl+F2), then Activate (Ctrl+F3), then exit"
```

**Same flow without prompts (auto mode):**
```
/sap-gui-probe "SE38: open ZSANDBOX, syntax check, activate, exit --auto"
```

---

## Edge cases and gotchas

1. **GuiTableControl row checkboxes are virtual.** `findById("...chkMSICHTAUSW-KZSEL[1,0]")` fails on MM03's View Selection in S/4HANA -- the row's `Selected` property is reachable only via `getAbsoluteRow(<n>).Selected = True`. The `SELECT_ROW` verb does this; **do not** try to emit a `findById` for a row checkbox in `SET_TEXT`.

2. **Popups break wnd[0] dumps.** When you expect a popup (e.g. after pressing Display in SE38 with no source loaded, after Save), dump with `-Mode tree` (no window scope) so `wnd[1]` is captured. Use `oSession.ActiveWindow.Id` in your reasoning -- if a popup is open, the next action must address `wnd[1]/...`, not `wnd[0]/...`.

3. **AbapEditor swallows status-bar messages.** SE38 / SE37 source editors don't update `wnd[0]/sbar` after Ctrl+F2 / Ctrl+F3 -- the message goes into `wnd[0]/shellcont/shell/shellcont[1]/shell` instead. For probe runs this means you can't classify success/failure from sbar alone; the dump after the action will tell you (look for the error grid).

4. **Original-language popup on SAPLSETX.** First write action on an object whose master language differs from logon language triggers a "Continue / Don't Save" popup. Your next dump will show `POPUP WINDOW wnd[1]` titled "Information"; press `wnd[1]/tbar[0]/btn[0]` (Continue) and proceed.

5. **NOOP can mean the field rejected the value.** If before/after dumps are identical, the most common cause is a field-level validation error left in the status bar. Read `wnd[0]/sbar` in the after-dump.

6. **`--auto` is not a substitute for the safety classifier.** Even in auto mode, the classifier still runs and writes `_class` annotation to the action JSON. Use that annotation in your end-of-run report to surface every WRITE action that ran, so the user can audit.
