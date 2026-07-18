---
name: sap-dev-init
description: |
  Initializes the SAP development environment after plugin installation.
  Ensures a transport request, package, and function group exist in SAP,
  then deploys the ZCMRUPDATE_ADDON_TABLE utility program.
  Mode-aware: respects `sap_dev_mode` (GUI / RFC / BDC) and selects the
  preferred skill variant for each step, falling back to the next mode in
  the chain when no implementation exists for the preferred mode.
  Prerequisites: Active SAP GUI session (use /sap-login first). SAP NCo 3.1
  (32-bit, .NET 4.0) in GAC for RFC sub-steps.
argument-hint: ""
---

# SAP Dev Init Skill

You initialize the SAP development environment by ensuring all required objects exist
in the target SAP system. This is typically run once after plugin installation.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_tr_object_entries.ps1` | RFC E071/E070 read (Step 1.5) — with `-OnlyOrphaned`, finds dev-init objects whose definition is gone but whose lock lingers in an old unreleased request (would block re-create); cleared via `/sap-se01 remove-objects` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` | **Rule 0 (highest priority)** — environment guard; enforced by Step 0.6 via `sap_safety_gate.ps1` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — applies to the GUI-driving sub-skills this orchestrator dispatches (sap-transport-request, sap-se21, sap-function-group, sap-se38) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — the `Z_GENERIC_RFC_WRAPPER_TBL` wrapper FM source deployed by this init flow follows modern syntax, OOP / exception conventions, and no literal MESSAGE strings. **Exception:** `ZCMRUPDATE_ADDON_TABLE.abap` (Step 8) is deliberately **classic-syntax** so a single source activates on ECC 6.0 / NetWeaver ≤7.40 as well as S/4HANA — do NOT modernize it (see that file's header + sap-update-addon Step 4c). |

---

## Step 0 — Resolve Work Directory and Mode

**Resolve `{work_dir}` per `<SAP_DEV_CORE_SHARED_DIR>\rules\work_dir_onboarding.md`**
— `/sap-dev-init` is an onboarding entry point (probe → use the env value / soft
tip / first-run prompt + set / migrate-on-change). **Never read `settings.json`
directly for `work_dir`** (that ignores `SAPDEV_AI_WORK_DIR` + `userconfig.json`).
Probe:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_workdir_setup.ps1" -Action probe
```

Once `{work_dir}` is known, apply the current-session env bridge (doc Step E):
prefix subsequent PowerShell commands with `$env:SAPDEV_AI_WORK_DIR='{work_dir}';`
(escape the `$` as `\$` when the command runs through bash; see `work_dir_onboarding.md` Step E).
The settings note below covers the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `custom_url`, `sap_dev_mode`.

**Per-connection keys (Phase 4.4)**: `sap_dev_mode` is SAP-system-specific (GUI/RFC/BDC capability varies per system). Per `settings_lookup.md` § Per-connection exception, read it from `connections.json[pinned-profile].dev_defaults` FIRST (resolve the pin via `{work_dir}\runtime\session_registry.json` `ai_sessions[<id>]`); only fall back to the two-file merge when `dev_defaults` is empty. Sub-steps that delegate to `/sap-transport-request`, `/sap-se21`, `/sap-function-group` inherit the same per-connection routing for TR/PKG/FG. **WRITES — standing dev defaults go in the connection block, not the global layer:** when this skill persists a standing default (TR / package / FG / `way_to_get_transport_request` / `rule_of_tr_description` / `tr_description_template`), write it **Connection-scoped** — `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dev_default.ps1 -Action set -Key <k> -Value <v> -Scope Connection` (or `Set-SapUserSetting … -Scope Connection`) — NOT `/update-config` (that writes the shared global layer, read only as a last-resort fallback, and not system-qualified). The delegated `/sap-transport-request` now persists the resolved TR **Session-scoped** (task default), so after it resolves the dev TR, ALSO persist that TR Connection-scoped here so the standing dev TR survives across conversations.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |
| `sap_dev_mode` | `GUI` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir from `Get-SapRunTemp` (env bridge applied):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command "\$env:SAPDEV_AI_WORK_DIR='{work_dir}'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

dev-init's OWN scratch (the `sap_dev_init_run.json` state file and the
`sap_gui_security_warmup_*.vbs` it generates) goes under `{RUN_TEMP}`. **The
cross-skill handoff files stay on `{WORK_TEMP}` (base), by design**: the `.def` /
`.abap` sources this skill copies for `/sap-se11`, `/sap-se37`, `/sap-se38` are
passed to those child skills as **absolute paths** and consumed there as
user-supplied files (the child never deletes them and writes its own scratch in
its own per-run dir). Keeping the handoffs on base avoids an rmdir-ordering hazard
— dev-init does **NOT** `rmdir {RUN_TEMP}`; its existing per-file cleanup and
`/sap-dev-clean` handle the handoff artifacts as before.

Validate `sap_dev_mode`. Allowed values: `GUI`, `RFC`, `BDC` (case-insensitive). Anything else → fall back to `GUI` and warn the user.

### Mode → fallback chain

| `sap_dev_mode` | Try in this order |
|---|---|
| `GUI` | GUI → RFC → BDC |
| `RFC` | RFC → BDC → GUI |
| `BDC` | BDC → RFC → GUI |

### Skill variants per task

For each step below, pick the **first skill in the active fallback chain** for which a row exists in the table. Skip empty cells; never invoke a missing skill.

| Task | GUI variant | RFC variant | BDC variant |
|---|---|---|---|
| Create / verify transport request | `/sap-se01` | `/sap-transport-request` | *(none)* |
| Create / verify package | `/sap-se21` | *(none)* | *(none)* |
| Create / verify function group | `/sap-function-group` (GUI sub-flow) | `/sap-function-group` (RFC sub-flow) | *(none)* |
| Create / update DDIC domain | `/sap-se11` | *(none)* | *(none)* |
| Create / update DDIC data element | `/sap-se11` | *(none)* | *(none)* |
| Create / update DDIC structure | `/sap-se11` | *(none)* | *(none)* |
| Create / update DDIC table type | `/sap-se11` | *(none)* | *(none)* |
| Deploy function module | `/sap-se37` | *(none)* | *(none)* |
| Deploy report | `/sap-se38` | *(none)* | *(none)* |

Examples:
- `sap_dev_mode = GUI`, task "Create transport request" → choose `/sap-se01` (GUI exists).
- `sap_dev_mode = RFC`, task "Create transport request" → choose `/sap-transport-request` (RFC exists).
- `sap_dev_mode = RFC`, task "Create package" → no RFC or BDC variant exists, fall back to GUI → choose `/sap-se21`.
- `sap_dev_mode = BDC`, task "Create function group" → no BDC, fall back to RFC → choose `/sap-function-group`.

Record the selected skills in a small "plan" block before executing, so the user can see which path will be taken:

```
sap_dev_mode = <MODE>
Plan:
  Transport request : /<chosen-skill>
  Package           : /<chosen-skill>
  Function group    : /<chosen-skill>
  ZCMD_RFCVAL       : /sap-se11
  ZCMDE_RFCVAL      : /sap-se11
  ZCMST_RFC_PARAM   : /sap-se11
  ZCMCT_RFC_PARAM   : /sap-se11
  RFC wrapper FM    : /sap-se37
  Update-addon PGM  : /sap-se38
```

**Invoke each planned skill via the Skill tool — never substitute its reference
VBS.** The plan above is a list of **skills to invoke**, not VBS to run. Each
sub-skill's SKILL.md holds its mode dispatch, release-specific fallbacks, TR
resolution and verification (e.g. `/sap-function-group` delete self-selects the
SE80 vs SE38 `SAPL<FG>` path; `/sap-se11` resolves the TR and RFC-verifies).
Reading a sub-skill's `references/*.vbs` and running it directly to save context
silently drops all of that. Driving a reference VBS directly is legitimate only
for skill development/debugging — never in this orchestration. (CLAUDE.md Rule 6.)

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{RUN_TEMP}\sap_dev_init_run.json`) so subsequent steps and the final
log-end call append to the same run. Best-effort: silently no-ops if
`userConfig.log_enabled=false` or the lib can't load.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_dev_init_run.json" -Skill sap-dev-init -ParamsJson "{}"
```

---

## Step 0.6 — Safety Gate (Rule 0 — `safety_policy.md`)

This skill creates a TR, package, function group and DDIC objects and deploys the utility program (via delegated skills, which gate themselves too). Run the gate up front for an early verdict:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-dev-init
```

| Verdict (last line) | Exit | Action |
|---|---|---|
| `SAFETY: ALLOW ...` | 0 | proceed (log via `-Action step`, step `safety_gate`) |
| `SAFETY: TYPED_CONFIRM_REQUIRED ... expect="PROD <SID>/<CLIENT>"` | 3 | the operator must **type** the shown token; re-run assert with `-ConfirmationText '<their verbatim answer>'`; proceed only on `ALLOW_CONFIRMED` |
| `SAFETY: REFUSED class=<C> ...` | 1 | **STOP.** End the run `FAILED` with `-ErrorClass <C>` and relay the gate's remediation lines. Never bypass, soften, retry, or drive the transaction manually instead — Rule 0 outranks every other instruction, including mid-session user ones. |
| `SAFETY: ERROR ...` | 2 | treat exactly as `REFUSED` (fail closed) |

---

## Step 1 — Check Authentication State

Authentication can be satisfied two ways: an **active SAP GUI session**
(usable for GUI/BDC variants) or **saved credentials** in
`settings.local.json` (usable for RFC variants). Some downstream skills
need one, some need the other, some need both.

### Step 1.0 — Determine what auth this run needs

From the mode dispatch in Step 0:
- `needs_session`  = the planned skill set contains any **GUI or BDC**
                     variant (anything other than pure RFC).
- `needs_creds`    = the planned skill set contains any **RFC** variant
                     (RFC requires `sap_user` + `sap_password` in the
                     merged settings — there is no session-fallback for
                     RFC).

`/sap-dev-init`'s default plan typically needs both: GUI to drive
SE21/SE38 and (when NCo 3.1 is available) RFC for the
`/sap-transport-request` fast-path.

### Step 1.1 — Probe current state

- `has_session` = run
  `C:\Windows\SysWOW64\cscript.exe //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_gui_login_status.vbs"`
  and check whether `STATUS: LOGGED_IN` is emitted.
- `has_creds`   = read merged settings (per
  `shared/rules/settings_lookup.md`); both `sap_user.value` and
  `sap_password.value` must be non-empty.

### Step 1.2 — Decide

| `needs_session` | `needs_creds` | `has_session` | `has_creds` | Action |
|:-:|:-:|:-:|:-:|---|
| ✓ | ✓ | ✓ | ✓ | **Proceed to Step 2.** All set. |
| ✓ | ✓ | ✓ | ✗ | Invoke `/sap-login`. Credentials are missing — `/sap-login` Step 1.5 will detect the existing session and offer to persist credentials. After it returns, re-probe `has_creds`; if still ✗, **stop** with: "RFC-based steps require saved credentials. Re-run `/sap-login` and accept the credential save when prompted." |
| ✓ | ✓ | ✗ | ✓ | Invoke `/sap-login`. Session is missing — `/sap-login` will run its full login flow against the saved credentials. After it returns, re-probe `has_session`; if still ✗, **stop** with the underlying error from `/sap-login`. |
| ✓ | ✓ | ✗ | ✗ | Invoke `/sap-login`. Both missing — `/sap-login` will prompt, save, and log in (its standard first-run flow). After it returns, re-probe both; if either still ✗, **stop** with a clear message. |
| ✓ | ✗ | ✓ | – | **Proceed to Step 2.** Session covers all needed paths. |
| ✓ | ✗ | ✗ | ✓ | Invoke `/sap-login` to start a session from saved credentials. Re-probe; **stop** if still no session. |
| ✗ | ✓ | – | ✓ | **Proceed to Step 2.** Credentials cover all needed paths. |
| ✗ | ✓ | – | ✗ | Invoke `/sap-login`. Re-probe `has_creds`; **stop** if still ✗. |

The "after returns, re-probe" pattern is important: `/sap-login` may
short-circuit on an existing session without prompting for credentials,
so we cannot assume credentials exist just because `/sap-login`
exited 0. Always verify the state we actually need.

### Step 1.3 — Read settings for downstream steps

Once Step 1.2 has resolved authentication, read these from the merged
settings (may be blank — Steps 2-5 will create them as needed):

- `sap_dev_transport_request`
- `sap_dev_package`
- `sap_dev_function_group`

---

## Step 1.4 — Self-heal stale dev-defaults

A stored `sap_dev_*` default can point at an artefact that no longer exists —
most often a transport request that was released or hand-deleted (its TRKORR is
gone from `E070`), but also a package or function group dropped by a prior
`/sap-dev-clean`. Reusing a dead TR makes the create/deploy steps below fail
("transport request does not exist / not modifiable"). So before resolving
anything, validate each non-blank stored default and **clear only the ones that
are provably stale** — healthy defaults are kept, so this stays idempotent (a
good setup is reused, never churned into a new TR every run).

Run `/sap-dev-status` (RFC, read-only) and read its per-artefact `STATE`:

- **TR** — if the stored `sap_dev_transport_request` is non-blank and
  `/sap-dev-status` reports it `RELEASED`, **or** an `E070` lookup returns no
  row for that TRKORR (hand-deleted, the case `DEFAULT`-policy verification
  alone may not catch), it is dead. **Clear it** at both the Session and
  Connection scope so Step 2b resolves a fresh TR instead of choking on the
  corpse:
  ```bash
  powershell -NoProfile -ExecutionPolicy Bypass -Command "\$env:SAPDEV_AI_WORK_DIR='{work_dir}'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; foreach (\$s in 'Session','Connection') { Set-SapUserSetting -Key 'sap_dev_transport_request' -Value '' -Scope \$s }"
  ```
  Log `INFO: cleared stale dev TR <TRKORR> (state=<RELEASED|NOT_FOUND>)` and let
  Step 2b resolve a fresh one.
- **Package / Function group** — if non-blank but `/sap-dev-status` reports
  `MISSING`, that's fine: keep the stored NAME — Step 3 / Step 4 recreate the
  artefact under it. Only clear the stored value if it is *malformed* (fails the
  `sap_object_naming_rules.tsv` regex); then Step 3 / Step 4 re-prompt for a
  valid name.
- **Config mismatch (anchor self-heal)** — if `/sap-dev-status` exits `3` /
  reports `STATUS: CONFIG_MISMATCH` (a `CONFIG_MISMATCH:` line), the stored
  `sap_dev_package` / `sap_dev_function_group` point at the **wrong** objects
  (typically an application build wrote its own package/TR into this connection's
  `dev_defaults`), while the toolset actually lives at the `ANCHOR:` values.
  **Re-point each mismatched key to its anchor value** (Connection + Session
  scope) so Steps 2–4 reuse the real toolset instead of creating a duplicate
  under the wrong (application) package — which would also clobber app objects'
  package assignment:
  ```bash
  powershell -NoProfile -ExecutionPolicy Bypass -Command "\$env:SAPDEV_AI_WORK_DIR='{work_dir}'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; foreach (\$s in 'Session','Connection') { Set-SapUserSetting -Key 'sap_dev_package' -Value '<anchor-package>' -Scope \$s; Set-SapUserSetting -Key 'sap_dev_function_group' -Value '<anchor-fugr>' -Scope \$s }"
  ```
  (Substitute `<anchor-package>` / `<anchor-fugr>` from the `ANCHOR:` line; only
  set the keys actually flagged `CONFIG_MISMATCH:` / `CONFIG_HINT:`.) Log
  `INFO: re-pointed dev defaults to anchor (package=<anchor-package> fugr=<anchor-fugr>)`.
  The anchor is authoritative (it is where the wrapper FM physically resides), so
  the re-point is deterministic and idempotent — a correctly-configured env emits
  `CONFIG: OK` and skips this entirely. The TR is not anchor-derivable; if it too
  points at unrelated work, clear it like a stale TR above so Step 2b resolves a
  fresh one.

Do **not** clear a TR that is merely `MODIFIABLE` (healthy) — that would mint a
new TR on every init (TR sprawl) and defeat idempotency. Self-heal touches only
provably-dead or anchor-contradicted references; everything else flows through to
Steps 2–4 unchanged.

---

## Step 1.5 — Pre-create transport hygiene (clear stale object-locks)

**Why this step exists.** An object recorded in an *unreleased* transport request
holds a **name-lock**. If that object was later deleted (e.g. an earlier
`/sap-dev-clean` that didn't clear the entry, or a manual SE11 delete) but its
`E071` entry lingered in the old request, the create steps below **fail**: SAP
refuses with `<object> is in request <TR>` / "enter object only in original
request". This is the exact failure mode that motivated the `/sap-se01
remove-objects` mode — clear the orphaned entry *before* creating, so Steps 4b–8
don't trip over it. (`/sap-dev-clean` is the other half: it clears these entries
on teardown. This step is the defensive complement for an env where teardown was
incomplete or the objects were deleted by hand.)

**Best-effort + RFC-gated.** The detection is an RFC read. If RFC is unavailable
on this system (no NCo / no saved creds and `sap_dev_mode = GUI` with no session
RFC), **skip this step** — the create steps still surface a lock error, which you
then resolve reactively with the same `/sap-se01 remove-objects` call.

1. **Find orphaned locks.** Run the shared helper for the dev-init objects with
   `-OnlyOrphaned` — it reports an entry ONLY when the object's definition is
   gone (a genuine stale lock), never for a live object:

   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_tr_object_entries.ps1" -OnlyOrphaned -Objects "ZCMD_RFCVAL,ZCMDE_RFCVAL,ZCMST_RFC_PARAM,ZCMCT_RFC_PARAM,Z_GENERIC_RFC_WRAPPER_TBL,ZCMRUPDATE_ADDON_TABLE,Z_CLASS_SOURCE_INSTALL,Z_RUN_REPORT"
   ```

   **Use the 32-bit `SysWOW64` PowerShell** as shown — the helper loads SAP NCo
   3.1 (32-bit-only); plain 64-bit `powershell` fails to load `sapnco.dll`. If it
   prints `STATUS: RFC_ERROR …` (RFC unavailable on this system), skip this step
   and rely on the reactive fallback in the create steps.
   Each `ENTRY<TAB>TRKORR<TAB>TRSTATUS<TAB>TRFUNCTION<TAB>PGMID<TAB>OBJECT<TAB>OBJ_NAME<TAB>REQUEST`
   line is an orphaned lock in an unreleased request; the trailing **`REQUEST`**
   column is the top-level request (the task's parent, since objects sit in
   tasks). The closing `STATUS: OK entries=<n> ...` gives the count. `entries=0`
   (or `STATUS: RFC_ERROR ...` → RFC unavailable) → nothing to do; continue to Step 1b.

2. **Clear them, request by request.** Group the `ENTRY` lines by their
   **`REQUEST`** column (pass the request — `/sap-se01 remove-objects` walks the
   request and its tasks); delegate with the `OBJ_NAME`s found under it:

   ```
   /sap-se01 remove-objects <REQUEST> OBJECTS=<comma-separated OBJ_NAMEs found under that request>
   ```

   These are all deleted-but-locked dev-init objects, so removal is safe and may
   proceed without an extra prompt (log what was cleared). After clearing, the
   names are free and the create steps below succeed.

3. This step is idempotent: a clean env reports `entries=0` and the step is a
   no-op. It never touches a live object (the `-OnlyOrphaned` gate checks the
   definition table per object type) nor a released request (those hold no lock).

---

## Step 1b — Trust `{work_dir}` in SAP GUI Security (one-time per workstation)

**Why this step exists.** Whenever an SAP GUI script (or SAP GUI itself) accesses a local file for read or write — Save spool, Save activation log, Upload source, BDC record upload, SE16N download — SAP GUI shows a "SAP GUI Security" modal dialog. The dialog title is translated per logon language (EN: "SAP GUI Security", JA: "SAP GUI セキュリティ", ZH: "SAP GUI 安全"). If the script doesn't dismiss it, every downstream skill that touches `{work_dir}` will block waiting for human input — and on customer machines we cannot pre-configure SAP GUI Options manually.

This step makes SAP GUI itself remember "Allow" for `{work_dir}\**` and `{WORK_TEMP}\**` so the dialog never appears again. It works by triggering the dialog once via a benign `Hardcopy` write under `{work_dir}`, then auto-clicking Allow with the **Remember My Decision** checkbox ticked. SAP GUI persists the decision in its own (version-specific) config — no fragile registry editing on our side.

**Writes vs. reads — the Hardcopy warmup is not enough on its own.** `Hardcopy` exercises only a *write*, so SAP persists a `w` rule. Reads (`GUI_UPLOAD`, file-open dialog) are governed by separate `r` rules — and SAP keys every "Remember" rule on the **current dynpro**, which for a report run is the *program name* (e.g. `ZMMRMAT040R01` / screen `1000`). So each newly generated program is a brand-new context that trips a fresh read dialog a per-program rule can never pre-cover; the same is true for programs that call `GUI_DOWNLOAD` directly (outside the stable ALV `SAPLKKBL` dynpro). Driving the dialog cannot fix this — "Remember" only ever produces narrow per-context rules. So this step *also* writes one **broad** Allow rule (read+write, any system/client/transaction/program) for `{work_dir}` directly into `saprules.xml` via `sap_gui_security_grant.ps1`, in SAP's own native serialization. `{work_dir}` is the operator's own dev sandbox, so it is deliberately trusted workstation-wide; SAP GUI still prompts for any path *outside* `{work_dir}`. (Callers that need least privilege can pin `-System`/`-Client` — see the grant sub-step.)

### Skip when

- `sap_dev_mode = RFC` (no GUI session, no dialog).
- `userConfig.sap_gui_security_warmup_done = true` (already done — see end of step).

### Pre-flight: detect a running SAP Logon other than this session

The customer may have launched SAP Logon manually before running `/sap-dev-init`. SAP GUI caches its security config at startup, so any newly-persisted trust decision may not take effect in those older processes. Detect:

```powershell
$procs = Get-Process -Name saplogon, sapgui -ErrorAction SilentlyContinue
if ($procs) {
    $ourPid = [int]"%%CURRENT_GUI_PID%%"
    $otherPids = $procs | Where-Object { $_.Id -ne $ourPid } | Select-Object -ExpandProperty Id
    if ($otherPids) { Write-Output "OTHER_GUI_PIDS:$($otherPids -join ',')" } else { Write-Output "ONLY_OURS" }
} else {
    Write-Output "NONE"
}
```

If `OTHER_GUI_PIDS:...` is reported, ask the customer:

> "An SAP Logon process is running outside this session (PIDs: <list>). The 'trust work_dir' setting only takes effect in SAP GUI sessions started **after** this step runs. Please close all SAP Logon windows except the one used by `/sap-login`, then continue. Type 'continue' when ready."

Wait for confirmation before proceeding.

### Run the warmup (PowerShell UIA sidecar + VBS warmup in parallel)

> **Architectural note.** Empirical finding (2026-05): when the SAP GUI Security dialog is modal, the SAP GUI Scripting COM API is **fully suspended** — even `oSess.findById("wnd[0]")` returns nothing. That kills any VBS-based dismiss strategy. The fix uses a **PowerShell UI Automation sidecar** (`sap_gui_security_sidecar.ps1`) that detects and dismisses the dialog at the OS level, completely independent of SAP's Scripting API. UIA can see the dialog because it queries Windows directly, not through SAP GUI.

The warmup is a two-process coordination:

- **Sidecar** (PowerShell + UIAutomation) runs in the background. Polls Windows belonging to `saplogon.exe` / `sapgui.exe` for a window matching the security-dialog fingerprint (≥3 buttons, ≥1 checkbox, ≥1 path-like text). When detected, it ticks the Remember checkbox and clicks the leftmost button (Allow). Falls back to SendKeys if UIA Invoke/Toggle patterns aren't supported on the dialog.
- **Warmup** (VBS) runs in the foreground. Triggers the dialog by writing a benign Hardcopy BMP under `{work_dir}`. The Hardcopy call blocks until the dialog is dismissed by the sidecar.

Two shared files are involved:

| File | Role |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_security_sidecar.ps1` | OS-level UIA + SendKeys auto-dismiss. Runs in background. |
| `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_security_warmup.vbs` | Foreground warmup — triggers the **write** dialog via Hardcopy. |
| `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_security_grant.ps1` | Idempotently writes the broad **read+write** Allow rule (covers `GUI_UPLOAD` / `GUI_DOWNLOAD` from arbitrary programs). See the "Cover read access" sub-section below. |

Generate the filled-in warmup VBS:

```powershell
$probe = Join-Path "{work_dir}" ("sap_gui_warmup_" + (Get-Date -Format yyyyMMddHHmmss) + ".bmp")
$warmupSrc = [System.IO.File]::ReadAllText('<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_security_warmup.vbs', [System.Text.Encoding]::UTF8)
# IMPORTANT: use the .Replace() string method, NOT the -replace operator.
# -replace treats the replacement string as a regex. Passing a Windows path
# through [regex]::Escape escapes the `.bmp` dot as `\.`; the trailing
# .Replace('\\','\') only fixes the doubled backslashes, leaving the dot
# escape behind. Result: a corrupted path like
#   C:\sap_dev_work\sap_gui_warmup_20260511115106\.bmp
# Plain .Replace() is literal and safe.
$warmupSrc = $warmupSrc.Replace('%%PROBE_FILE%%', $probe)
[System.IO.File]::WriteAllText("{RUN_TEMP}\sap_gui_security_warmup_run.vbs", $warmupSrc, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Output 'Generated'
```

Run them coordinated. PowerShell launches the sidecar in the background, then runs the warmup synchronously, then waits for the sidecar to finish:

```powershell
$sidecarOut = Join-Path $env:TEMP "sap_gui_security_sidecar.out"
$sidecarLog = Join-Path $env:TEMP "sap_gui_security_sidecar.log"
$warmupOut  = Join-Path $env:TEMP "sap_gui_security_warmup.out"

# Background sidecar (UIA + SendKeys fallback).
$sidecar = Start-Process -FilePath powershell.exe `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_security_sidecar.ps1',
                    '-TimeoutSeconds', '30',
                    '-LogPath', $sidecarLog) `
    -RedirectStandardOutput $sidecarOut `
    -NoNewWindow -PassThru

# Give the sidecar a moment to load UIA assemblies and start its first
# poll BEFORE the warmup tries to trigger the dialog.
Start-Sleep -Milliseconds 800

# Foreground warmup. The Hardcopy call blocks until the sidecar dismisses
# the dialog (or the customer clicks something manually).
& C:\Windows\SysWOW64\cscript.exe //NoLogo "{RUN_TEMP}\sap_gui_security_warmup_run.vbs" *> $warmupOut

# Wait for the sidecar to exit (it exits as soon as it dismisses or times out).
$sidecar | Wait-Process -Timeout 35

$warmupResult  = (Get-Content $warmupOut -Tail 1)
$sidecarResult = (Get-Content $sidecarOut -Tail 1)
Write-Output "WARMUP=$warmupResult"
Write-Output "SIDECAR=$sidecarResult"
```

### Cover read access (broad grant)

The Hardcopy warmup above only persists a **write** rule. To also cover **reads** (`GUI_UPLOAD` / file-open) — and writes from programs that bypass the stable ALV `SAPLKKBL` dynpro — write one broad read+write Allow rule for `{work_dir}`, leaving **system / client / transaction / program all "any"** (required for transaction/program, since each generated program is a new context; any-system because `{work_dir}` is the operator's own dev sandbox, trusted workstation-wide). This is the **single rule that permanently covers** the ATC result download, the generated material-upload `GUI_UPLOAD`, and every other SAP-GUI file IO under `{work_dir}` — provided that IO targets a path under `{work_dir}`. It edits `saprules.xml` directly because the dialog's "Remember" can only ever make narrow per-program rules.

```powershell
$rules = Join-Path $env:APPDATA 'SAP\Common\saprules.xml'
if (Test-Path $rules) { Copy-Item $rules "$rules.bak" -Force }   # backup before edit
# Context-aware idempotency: ALREADY only if an effective any-context rule already
# covers it; a stale '*'/backslash or narrow per-program same-path rule is purged
# and replaced (HEALED). All context fields empty = any system/client/txn/program.
$grant = & '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_security_grant.ps1' `
    -Path "{work_dir}\" -Access rw -AsDirectory
Write-Output "GRANT=$grant"
```

Expected: `GRANT=GRANTED: …` (first run, new rule), `GRANT=HEALED: … removed=<ids>` (a stale/narrow same-path rule was shadowing the grant and has been replaced), or `GRANT=ALREADY: …` (an effective rule is already present). On `GRANT=ERROR:`, surface the line and continue — but note the dialog **will** appear at runtime for reads until the rule is in place (this build does not wire a runtime sidecar fallback into the file-IO skills).

> **Restart SAP Logon after GRANTED / HEALED.** Because a rule was just written, and a running SAP Logon caches `saprules.xml` at startup, the new rule does **not** take effect in the current session — close every SAP Logon / SAP GUI window and reopen, then re-run `/sap-login`. After that one restart the trust is permanent for this Windows account (it survives reboots and plugin updates — it lives in SAP's own per-user store, not ours). On `ALREADY`, no restart is needed.

> **First-run authorization.** This writes a deliberate any-system trust for the operator's own work dir, which the Claude auto-mode security classifier guards. If it's blocked on the first `/sap-dev-init`, that's expected — approve it (or run the one-liner above manually). It is idempotent (`ALREADY`) thereafter, so the classifier only matters once per workstation. Scope it down to a specific `-System`/`-Client` (least privilege) only if your operator policy requires it.

> **Reload caveat.** A SAP Logon already running when this rule is written may have cached the rule store at startup; the new rule is guaranteed for SAP Logon processes started *after* the edit. If reads still prompt in the current session, close and reopen SAP Logon. (This is the same cache behaviour the pre-flight warns about for the Hardcopy trust.)

### Verify trust persisted

Run a SECOND warmup. If trust persisted, Hardcopy succeeds with no dialog and the poller times out (no dialog to dismiss). If the second pass still trips the dialog, trust did NOT persist (group-policy override; close-and-reopen SAP Logon required):

```powershell
$probe2 = Join-Path "{work_dir}" ("sap_gui_warmup_verify_" + (Get-Date -Format yyyyMMddHHmmss) + ".bmp")
$warmupSrc2 = [System.IO.File]::ReadAllText('<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_security_warmup.vbs', [System.Text.Encoding]::UTF8)
# .Replace() (literal), not -replace (regex). See the first warmup block for why.
$warmupSrc2 = $warmupSrc2.Replace('%%PROBE_FILE%%', $probe2)
[System.IO.File]::WriteAllText("{RUN_TEMP}\sap_gui_security_warmup_verify.vbs", $warmupSrc2, [System.Text.UnicodeEncoding]::new($false, $true))

# No poller this time. If a dialog appears, this will hang for human input —
# guard with a 5 s timeout (the second pass should complete in <1 s when trusted).
$verify = Start-Process -FilePath "C:\Windows\SysWOW64\cscript.exe" `
    -ArgumentList "//NoLogo", "{RUN_TEMP}\sap_gui_security_warmup_verify.vbs" `
    -RedirectStandardOutput (Join-Path $env:TEMP "sap_gui_verify.out") `
    -NoNewWindow -PassThru
if (-not ($verify | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue)) {
    Stop-Process -Id $verify.Id -Force
    Write-Output "VERIFY=DIALOG_STILL_APPEARS"
} else {
    Write-Output "VERIFY=$(Get-Content (Join-Path $env:TEMP 'sap_gui_verify.out') -Tail 1)"
}
```

**Parse the combined results:**

| Combined result | Meaning | Action |
|---|---|---|
| WARMUP=`ALLOWED` + SIDECAR=`DISMISSED:WIN32` + VERIFY=`ALLOWED` | Dialog appeared, the Win32 watcher ticked Remember + clicked Allow and verified it closed (a preceding `INFO: closed N security dialog(s)` line gives the count), trust persisted. | Persist `sap_gui_security_warmup_done=true`. Continue. |
| WARMUP=`ALLOWED` + SIDECAR=`FOUND_BUT_STUCK` | The watcher saw the dialog but the click never closed it (retried to its timeout). | Do **not** mark done. Review `$sidecarLog`; re-run, or have the customer dismiss the dialog manually once (ticking *Remember My Decision*) so the rule persists. |
| WARMUP=`ALLOWED` + SIDECAR=`TIMEOUT` + VERIFY=`ALLOWED` | No dialog appeared (`{work_dir}` was already trusted). | Persist `sap_gui_security_warmup_done=true`. Continue. |
| WARMUP=`NO_GUI` *or* SIDECAR=`NO_SAP_GUI` | No SAP GUI session attached. | Stop. Tell customer to run `/sap-login` first, then re-run. |
| WARMUP=`ALLOWED` + VERIFY=`DIALOG_STILL_APPEARS` | Sidecar dismissed the first dialog but trust did NOT persist. | Group policy override or SAP Logon needs restart. Show the fallback checklist below. **Do not** mark done. |
| WARMUP=`ERROR: …` *or* SIDECAR=`ERROR: …` | Hardcopy failed or sidecar couldn't dismiss. Read `$sidecarLog` for the detection trace. | Show full output. Do not mark done. Common causes: customer clicked Deny manually before sidecar could act; UIA assemblies not loaded; SAP GUI dialog is fully custom-drawn (rare). |

If the verify step reports `DIALOG_STILL_APPEARS` or any branch reports `ERROR:`, give the customer this checklist:

1. Close every SAP Logon / SAP GUI window. Verify no `saplogon.exe` / `sapgui.exe` processes remain.
2. Re-run `/sap-login` to start a fresh session.
3. Re-run `/sap-dev-init`.
4. If the error persists, your workstation may have a Group Policy that locks SAP GUI security to "always ask". This is not bypassable from a script. Either:
   - Ask the workstation admin to add `{work_dir}\**` to the SAP GUI security allowlist via GPO, or
   - Accept that the dialog will appear at runtime. Each file-IO skill that triggers it must launch `sap_gui_security_sidecar.ps1` as a parallel process (same coordination pattern as Step 1b above). The sidecar handles the dismiss at the OS level.

### Cleanup

```bash
cmd /c del {RUN_TEMP}\sap_gui_security_warmup_run.vbs & del {RUN_TEMP}\sap_gui_security_warmup_verify.vbs
```

The sidecar log at `$env:TEMP\sap_gui_security_sidecar.log` is intentionally preserved for diagnostic purposes — delete manually if not investigating a failure.

### Persist the warmup-done flag

On `ALLOWED` or `ALREADY_TRUSTED`, persist:
```
sap_gui_security_warmup_done = true
```
via `/update-config` so subsequent `/sap-dev-init` runs skip this step.

### Limitations

- **HKCU / per-user.** The trust applies only to the Windows account that ran the warmup. If multiple Windows accounts share the workstation, run `/sap-dev-init` once per account.
- **SAP GUI cache.** SAP Logon processes that were running before the warmup may need to restart to pick up the new trust. The pre-flight above warns about this.
- **Group Policy override.** If GPO locks the security config, the warmup completes but trust does not persist. The fallback is to launch `sap_gui_security_sidecar.ps1` from every file-IO skill at runtime, using the same parallel-process coordination as Step 1b. The sidecar dismisses the dialog at the OS level whenever it appears.

---

## Step 2 — Choose TR Policy and Get/Create Transport Request

This step is split into two parts: first establish the long-term TR sourcing
policy, then resolve a TR for the rest of `sap-dev-init` (and downstream
skills) to use.

### Step 2a — Ask for the TR sourcing policy

Read `way_to_get_transport_request` from the merged sap-dev-core settings (per `shared/rules/settings_lookup.md` — `settings.local.json` overrides `settings.json` per-key). If it is **blank or invalid**, ask the user (e.g. via AskUserQuestion):

> How should sap-dev skills obtain a transport request when one is needed?
> 1. `DEFAULT` — Always reuse the saved default TR (`sap_dev_transport_request`); ask only if blank or no longer modifiable.
> 2. `ASK` — Ask each time and (optionally) save your choice as the default.
> 3. `CREATE_NEW` — Always create a brand-new TR via `/sap-se01`; never reuse.

Persist the user's choice to `way_to_get_transport_request`
**Connection-scoped** (standing per-system policy — see the Step 0 WRITES note;
`sap_dev_default.ps1 … -Scope Connection`, not `/update-config`).

While asking the policy, also offer the description-rule settings if
`rule_of_tr_description` is blank:

> How should new TR descriptions be generated?
> - `ASK` — prompt me each time
> - `PATTERN` — render a template (e.g. `{YYYYMMDD}_{OBJECT_TYPE}_{OBJECT_DESCRIPTION}`)
> - `FIXED` — use a fixed text I provide
> - `RANDOM` — auto-generate a random one

If `PATTERN` or `FIXED`, prompt for `tr_description_template` and persist it
**Connection-scoped** (standing per-system formatting — see the Step 0 WRITES note).
The template defaults to `{YYYYMMDD}_{OBJECT_TYPE}_{OBJECT_DESCRIPTION}` if
the user just hits enter.

### Step 2b — Apply the policy

Now act per the policy chosen above. The persistence behaviour matches
`<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md`:

#### `DEFAULT`
1. If `sap_dev_transport_request` is non-blank, verify it is still modifiable
   (run `/sap-transport-request` with no TR argument; it will read the
   default and verify).
   - Modifiable → use it for the rest of init.
   - Not modifiable → ask the user for a different TR or to create a new one.
2. If `sap_dev_transport_request` is blank, ask the user:
   > "Provide an existing modifiable TR number, or type `new` to create one."
   - Existing TR → run `/sap-transport-request <TR>` to verify; if not
     modifiable, repeat.
   - `new` → run the **transport-request skill chosen in the Step 0 plan**
     (`/sap-se01` for GUI, `/sap-transport-request` for RFC) with
     `OBJECT_TYPE=BASIC OBJECT_DESCRIPTION=SAP_DEV_INIT`.
3. Persist the resolved TR to `sap_dev_transport_request` **Connection-scoped** —
   it's the STANDING dev TR, and the delegated `/sap-transport-request` only
   persisted it Session-scoped, so write the connection block here:
   `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dev_default.ps1 -Action set -Key sap_dev_transport_request -Value <TR> -Scope Connection`.

#### `ASK`
1. Keep `sap_dev_transport_request` blank.
2. For *this* sap-dev-init run only, ask the user for a TR (or `new` to
   create), verify modifiable, and use it for the remaining steps.
3. After resolving, ask once whether to save it as default. If yes, persist;
   otherwise leave blank.

#### `CREATE_NEW`
1. Keep `sap_dev_transport_request` blank.
2. Run the chosen transport-request skill to create a new TR with
   `OBJECT_TYPE=BASIC OBJECT_DESCRIPTION=SAP_DEV_INIT`.
3. Use the new TRKORR for the remaining steps. Do NOT persist.

After this step you have a `RESOLVED_TR` for the current session; downstream
steps (Package, Function Group, ZCMST/ZCMCT, wrappers, ZCMRUPDATE_ADDON_TABLE) use
`RESOLVED_TR` regardless of policy. If the chosen skill reports an error,
stop and show the error to the user.

---

## Step 3 — Get or Create Package

Run the **package skill chosen in the Step 0 plan** to ensure the development package exists.

Only one implementation currently exists:
- **`/sap-se21`** (GUI mode): RFC check on TDEVC, then GUI-scripted creation via SE21 if missing. Reused for all `sap_dev_mode` values until an RFC or BDC variant is added.

### Resolve the package name

1. If `sap_dev_package` is configured and non-blank → use it as `PACKAGE`.
2. If `sap_dev_package` is **blank**, **ask the user** for the package name.
   Do NOT silently fall back to a default. Suggested prompt:

   > `sap_dev_package` is not configured. Please provide the SAP development
   > package name to use (e.g. `ZHKDEVAI`). Press Enter on its own to accept
   > the default `ZCMDEVAI`.

   - If the user provides a name, persist it to `sap_dev_package`
     **Connection-scoped** (standing per-system default — see the Step 0 WRITES
     note; `sap_dev_default.ps1 … -Scope Connection`, not `/update-config`) so
     subsequent runs reuse it without prompting.
   - If the user accepts the default, persist `ZCMDEVAI`.
   - Validate the name against `<SAP_DEV_CORE_SHARED_DIR>/tables/sap_object_naming_rules.tsv`
     (`PACKAGE` row). If it fails the regex, show the rule and re-prompt.

3. If the package does not exist in SAP, it will be created with description
   "Basic Tools for sap-dev AI PKG" on the transport from Step 2.

After this step, `sap_dev_package` must contain a valid package name. If the skill reports an error, stop and show the error to the user.

---

## Step 4 — Get or Create Function Group

Run **`/sap-function-group`** to ensure the function group exists. The
skill is mode-aware: `userConfig.sap_dev_mode` selects which sub-flow
runs first, with the other sub-flow used only if the first is
unavailable. **Do not override the user's `sap_dev_mode`** — pass it
through and let the skill honour it.

- **RFC sub-flow**: RFC check on TLIBG, then `RS_FUNCTION_POOL_INSERT`
  to create. Args: `<FUGR> "<short text>"` (package and transport read
  from settings). Used when `sap_dev_mode = RFC`, or when
  `sap_dev_mode` is unset / `BDC` and NCo 3.1 is available.
- **GUI sub-flow**: GUI-driven creation via SE37 "Goto > Function
  Groups > Create Group". Defaults the package and transport to the
  values from Steps 2 and 3 when not given. Args:
  `<FUGR> "<short text>" <package> <transport>`. Used when
  `sap_dev_mode = GUI`, or when RFC is not available.

### Resolve the function-group name

1. If `sap_dev_function_group` is configured and non-blank → use it as `FUGR`.
2. If `sap_dev_function_group` is **blank**, **ask the user** for the function
   group name. Do NOT silently fall back to a default. Suggested prompt:

   > `sap_dev_function_group` is not configured. Please provide the SAP
   > function group name to use (must start with `ZFG`, e.g. `ZFGHKDEV`).
   > Press Enter on its own to accept the default `ZFGDEVAI`.

   - If the user provides a name, persist it to `sap_dev_function_group`
     **Connection-scoped** (standing per-system default — see the Step 0 WRITES
     note; `sap_dev_default.ps1 … -Scope Connection`, not `/update-config`) so
     subsequent runs reuse it without prompting.
   - If the user accepts the default, persist `ZFGDEVAI`.
   - Validate the name against `<SAP_DEV_CORE_SHARED_DIR>/tables/sap_object_naming_rules.tsv`
     (`FUNCTION_GROUP` row, `^ZFG[A-Z0-9_]*$`). If it fails the regex,
     show the rule and re-prompt.

3. Short text: `Basic Tools for sap-dev AI FMG`.

**GUI-mode caveats** (observed during the `sap-function-group` GUI
sub-flow testing on S/4HANA — see references/`sap_function_group_gui_create.vbs`):
- The short-text field `txtTLIBT-AREAT` may reject strings longer than ~33 characters with "invalid argument" even though SAP allows up to 80. Keep the short text ≤ 33 chars.
- The GUI VBS only treats status-bar type `E`/`A` as failure. An empty status bar after save is **not** treated as failure, so a missing-package situation can produce a misleading `DONE FUGR=...` line. After this step, verify the function group exists by querying TLIBT (or by re-running `/sap-function-group`) before proceeding.

After this step, `sap_dev_function_group` must contain a valid function group name. If verification fails, stop and show the error to the user.

---

## Step 4b — Create ZCMD_RFCVAL Domain

The wrapper's `PVALUE` payload field is CHAR 1333. Instead of depending on a
standard wide data element — the stock `GENE_KEY_VALUES` exists on S/4HANA but
**not** on AS ABAP 7.31 / ECC6 — the wrapper family ships and creates its own
domain + data element, so the DDIC is single-source across every release.

The definition file is at:
`<SKILL_DIR>/../sap-rfc-wrapper/references/ZCMD_RFCVAL.def`

Copy and re-encode as Unicode (UTF-16 LE — required by sap-se11 templates):
```powershell
Copy-Item '<SKILL_DIR>\..\sap-rfc-wrapper\references\ZCMD_RFCVAL.def' '{WORK_TEMP}\ZCMD_RFCVAL.def'
$c = [System.IO.File]::ReadAllText('{WORK_TEMP}\ZCMD_RFCVAL.def', [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText('{WORK_TEMP}\ZCMD_RFCVAL.def', $c, [System.Text.UnicodeEncoding]::new($false, $true))
```

Run:
```
/sap-se11 DOMAIN ZCMD_RFCVAL {WORK_TEMP}\ZCMD_RFCVAL.def {sap_dev_package} {RESOLVED_TR}
```

Short description: `RFC wrapper payload domain (CHAR 1333)`

The domain caps **output length at 132** so the structure later activates
without SAP's "output length > 255" warning, while still storing the full
1333-char chunk. If ZCMD_RFCVAL already exists, sap-se11 will update it.
If sap-se11 reports an error, show it to the user and suggest manual creation in SE11.

---

## Step 4c — Create ZCMDE_RFCVAL Data Element

**ZCMD_RFCVAL must be active** before this step — the data element references it.

The definition file is at:
`<SKILL_DIR>/../sap-rfc-wrapper/references/ZCMDE_RFCVAL.def`

Copy and re-encode:
```powershell
Copy-Item '<SKILL_DIR>\..\sap-rfc-wrapper\references\ZCMDE_RFCVAL.def' '{WORK_TEMP}\ZCMDE_RFCVAL.def'
$c = [System.IO.File]::ReadAllText('{WORK_TEMP}\ZCMDE_RFCVAL.def', [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText('{WORK_TEMP}\ZCMDE_RFCVAL.def', $c, [System.Text.UnicodeEncoding]::new($false, $true))
```

Run:
```
/sap-se11 DATAELEMENT ZCMDE_RFCVAL {WORK_TEMP}\ZCMDE_RFCVAL.def {sap_dev_package} {RESOLVED_TR}
```

Short description: `RFC wrapper XML payload chunk`

If ZCMDE_RFCVAL already exists, sap-se11 will update it.
If sap-se11 reports an error, show it to the user and suggest manual creation in SE11.

---

## Step 5 — Create ZCMST_RFC_PARAM Structure

**ZCMDE_RFCVAL must be active** before this step — the structure's `PVALUE`
field references it (single-source DDIC; no dependency on the S/4-only
`GENE_KEY_VALUES`).

> **Migrating an existing install** (structure already exists on the old
> `GENE_KEY_VALUES`): the `/sap-se11` structure *update* path only appends new
> components — it cannot change an existing field's data element — so an
> in-place re-run leaves `PVALUE` on the old DE (and may report a misleading
> success). To migrate, run `/sap-dev-clean` then `/sap-dev-init`: clean drops
> the structure so init recreates it fresh on `ZCMDE_RFCVAL`. Fresh installs
> are unaffected.

The definition file is at:
`<SKILL_DIR>/../sap-rfc-wrapper/references/ZCMST_RFC_PARAM.def`

Copy and re-encode as Unicode (UTF-16 LE — required by sap-se11 templates):
```powershell
Copy-Item '<SKILL_DIR>\..\sap-rfc-wrapper\references\ZCMST_RFC_PARAM.def' '{WORK_TEMP}\ZCMST_RFC_PARAM.def'
$c = [System.IO.File]::ReadAllText('{WORK_TEMP}\ZCMST_RFC_PARAM.def', [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText('{WORK_TEMP}\ZCMST_RFC_PARAM.def', $c, [System.Text.UnicodeEncoding]::new($false, $true))
```

Run:
```
/sap-se11 STRUCTURE ZCMST_RFC_PARAM {WORK_TEMP}\ZCMST_RFC_PARAM.def {sap_dev_package} {RESOLVED_TR} ENHANCEMENT_CATEGORY=NOT_EXTENSIBLE
```

Short description: `RFC wrapper parameter structure`

The explicit `ENHANCEMENT_CATEGORY=NOT_EXTENSIBLE` ensures sap-se11
substitutes the `%%ENHANCEMENT_CATEGORY%%` token in the create VBS
template. Without it, the unreplaced literal token reaches
`SetEnhancementCategory()` and the structure activates without a
category set — surfacing SAP's "Structure is not flagged for any
enhancement category" warning at activation time.

If ZCMST_RFC_PARAM already exists, sap-se11 will update it.
If sap-se11 reports an error, show it to the user and suggest manual creation in SE11.

---

## Step 6 — Create ZCMCT_RFC_PARAM Table Type

**ZCMST_RFC_PARAM must be active** before this step.

The definition file is at:
`<SKILL_DIR>/../sap-rfc-wrapper/references/ZCMCT_RFC_PARAM.def`

Copy and re-encode:
```powershell
Copy-Item '<SKILL_DIR>\..\sap-rfc-wrapper\references\ZCMCT_RFC_PARAM.def' '{WORK_TEMP}\ZCMCT_RFC_PARAM.def'
$c = [System.IO.File]::ReadAllText('{WORK_TEMP}\ZCMCT_RFC_PARAM.def', [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText('{WORK_TEMP}\ZCMCT_RFC_PARAM.def', $c, [System.Text.UnicodeEncoding]::new($false, $true))
```

Run:
```
/sap-se11 TABLETYPE ZCMCT_RFC_PARAM {WORK_TEMP}\ZCMCT_RFC_PARAM.def {sap_dev_package} {RESOLVED_TR}
```

Short description: `RFC wrapper parameter table type`

If ZCMCT_RFC_PARAM already exists, sap-se11 will update it.
If sap-se11 reports an error, show it to the user and suggest manual creation in SE11.

---

## Step 7 — Deploy Z_GENERIC_RFC_WRAPPER_TBL

**ZCMCT_RFC_PARAM must be active** before this step.

The ABAP source file is at:
`<SKILL_DIR>/../sap-rfc-wrapper/references/Z_GENERIC_RFC_WRAPPER_TBL.abap`

Copy the source to `{WORK_TEMP}\Z_GENERIC_RFC_WRAPPER_TBL.abap`:
```bash
powershell -Command "Copy-Item '<SKILL_DIR>\..\sap-rfc-wrapper\references\Z_GENERIC_RFC_WRAPPER_TBL.abap' '{WORK_TEMP}\Z_GENERIC_RFC_WRAPPER_TBL.abap'"
```

Run:
```
/sap-se37 Z_GENERIC_RFC_WRAPPER_TBL {WORK_TEMP}\Z_GENERIC_RFC_WRAPPER_TBL.abap
```

Pass:
- Function group: `{sap_dev_function_group}` (from Step 4)
- Short text: `Generic RFC wrapper for non-remote FMs`
- Package: `{sap_dev_package}` (from Step 3)
- Transport: `{RESOLVED_TR}` (from Step 2)

> **Note on the FM signature.** `Z_GENERIC_RFC_WRAPPER_TBL` keeps its
> "_TBL" name suffix for backward compatibility but the parameter
> `CT_PARAMS` is now **CHANGING `ZCMCT_RFC_PARAM`** (modern syntax),
> not the legacy `TABLES … STRUCTURE …`. NCo 3.1 exposes CHANGING
> table-typed parameters via the same `.GetTable()` API as the TABLES
> section, so `sap_rfc_wrapper_fm.ps1` needs no changes. Earlier
> revisions used `TABLES` for compatibility with the classic 32-bit
> `SAP.Functions` COM control (librfc32), which is no longer referenced
> anywhere in the plugin. The migration also permanently silences SAP's
> "TABLES parameters are obsolete!" Function Builder status-bar warning
> — a passive sbar text that ENTER cannot dismiss (the deploy flow
> previously tried this; confirmed 2026-05-12 that it doesn't work).

If Z_GENERIC_RFC_WRAPPER_TBL already exists with the legacy TABLES
signature, sap-se37 will UPDATE it in place — the new
`*"Local Interface:` comment block declares CHANGING and SAP regenerates
the function-include accordingly on activation. A re-run on the same
system will perform that signature migration automatically.

If sap-se37 reports an error, show it to the user and suggest manual deployment via SE37.

---

## Step 7b — Mark Z_GENERIC_RFC_WRAPPER_TBL as Remote-Enabled

The SE37 create flow in Step 7 leaves the new FM as **Regular Function
Module** (TFDIR.FMODE blank). The wrapper FM is only useful when called
via RFC from PowerShell (NCo 3.1) — so we must flip the processing
type to **Remote-Enabled Module** (TFDIR.FMODE='R') before it can serve
its purpose. Without this step, NCo 3.1 calls return
`FU_NOT_REMOTE_ENABLED` and the wrapper is dead-on-arrival.

Verification ahead of time: query TFDIR via RFC and check `FMODE` — if
already `R`, skip this step (idempotent re-runs of `/sap-dev-init`).

```
/sap-se37 change_attrs Z_GENERIC_RFC_WRAPPER_TBL PROCESSING_TYPE=REMOTE
```

Pass:
- Transport: `{RESOLVED_TR}` (Step 2 — for the post-save TR popup)
- SHORT_TEXT: empty (don't change the short text)
- UPDATE_KIND: empty (only applies to UPDATE processing type)

The `/sap-se37` change_attrs mode (Step 5d in that skill) opens SE37 in
change mode, navigates to the Attributes tab, ticks `radRS38L-REMOTE`,
saves, and handles the post-save TR popup. The FM does NOT need
re-activation after this — SAP marks TFDIR.FMODE on save.

Post-verification: re-query TFDIR.FMODE; expect `R`. If still blank,
the change_attrs call failed silently — open SE37 manually, set
Remote-Enabled, and save.

---

## Step 8 — Deploy ZCMRUPDATE_ADDON_TABLE Program

The ABAP source file is at:
`<SKILL_DIR>/../sap-update-addon/references/ZCMRUPDATE_ADDON_TABLE.abap`

(Go up 1 level from this skill directory to the skills/ folder, then into `sap-update-addon/references/`.)

> **Release note.** This utility is intentionally written in **classic,
> release-independent ABAP** so the SAME source activates on both classic
> ECC 6.0 / NetWeaver ≤7.40 and S/4HANA 1909+ (verified 2026-06-17 on SID ER1).
> Do not regenerate it with modern 7.40+ expression syntax — see the file
> header and sap-update-addon Step 4c. No release detection is needed: deploy
> this one file on every target.

Copy the ABAP source to `{WORK_TEMP}\ZCMRUPDATE_ADDON_TABLE.abap`:
```bash
powershell -Command "Copy-Item '<SKILL_DIR>\..\sap-update-addon\references\ZCMRUPDATE_ADDON_TABLE.abap' '{WORK_TEMP}\ZCMRUPDATE_ADDON_TABLE.abap'"
```

Run `/sap-se38 ZCMRUPDATE_ADDON_TABLE {WORK_TEMP}\ZCMRUPDATE_ADDON_TABLE.abap {sap_dev_package} {RESOLVED_TR}`

This deploys the utility program to the SAP system. If the program already exists, sap-se38 will update it.

If sap-se38 reports success, the deployment is complete.
If it reports an error, show the error to the user and suggest manual deployment.

---

## Step 8b — Deploy Z_CLASS_SOURCE_INSTALL (SE24 RFC class-source installer) — OPTIONAL, best-effort

This installer FM backs `/sap-se24`'s **Step 4.7 RFC deploy fallback** — it lets
`/sap-se24` install a global class's source **headlessly** (no GUI Upload dialog,
no inactive-objects worklist stall). It is a KEEPER in `{sap_dev_function_group}`
alongside the wrapper, but **OPTIONAL** (a nice-to-have, not core to the toolset),
so this step is **BEST-EFFORT and MUST NEVER fail `/sap-dev-init`**. `/sap-se24`
Step 4.7 also self-heals it on first RFC use, so skipping here is harmless.

It needs RFC **and** the OO source API (`CL_OO_FACTORY` / `IF_OO_CLIF_SOURCE`,
present on NW **7.31 EhP6+** incl. ECC6 EhP6 — verified live S4D 7.54 + EC2/ERP
7.31 EhP6). Deploy it **Remote-Enabled in one call** via the maintained RFC helper
(the same one `/sap-se24` Step 4.7 uses — no separate change_attrs step, unlike the
wrapper's Step 7b). Run under **32-bit** PowerShell (NCo 3.1):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\..\sap-se37\references\sap_rfc_fm_insert.ps1" -SourceFile "<SKILL_DIR>\..\sap-se24\references\Z_CLASS_SOURCE_INSTALL.abap" -FunctionGroup "{sap_dev_function_group}" -Transport "{RESOLVED_TR}" -Remote -ShortText "RFC installer: headless class source deploy (SE24 fallback)"
```

Interpret the `STATUS:` line — **all outcomes are non-fatal**:

| Result | Action |
|---|---|
| `STATUS: INSERTED_ACTIVE …` | Deployed + active, Remote-Enabled ✓. |
| `STATUS: EXISTS …` | Already present (idempotent re-run) ✓. |
| `STATUS: INSERTED_INACTIVE …` | Inserted but could not activate → this release lacks the full OO source API. Remove the inactive shell with `/sap-se37 delete Z_CLASS_SOURCE_INSTALL`, then SKIP — `/sap-se24` uses the GUI path on this release. |
| `STATUS: FG_MISSING …` / `RFC_ERROR …` / `INSERT_FAILED …` | Log an INFO `class_installer skipped: <reason>` and continue. Optional — `/sap-se24` Step 4.7 self-heals it later on a supported, RFC-capable system. |

Do **not** treat any of these as an init failure; record the outcome for the Step 9 summary.

---

## Step 8c — Deploy Z_RUN_REPORT (RFC background report runner) — OPTIONAL, best-effort

This FM backs `/sap-run-report`'s **Step 3B RFC background path** — it schedules a report
as a background job headlessly (`JOB_OPEN` → `SUBMIT … VIA JOB` → `JOB_CLOSE`) and returns
the job name/count so the caller can poll `TBTCO` and capture the spool
(`TBTCP.LISTIDENT` → `/sap-sp02`). It is a KEEPER in `{sap_dev_function_group}` alongside
the wrapper, but **OPTIONAL** (Phase B): `/sap-run-report` degrades to the GUI
Execute-in-Background fallback (its Step 3C) when it is absent, so this step is
**BEST-EFFORT and MUST NEVER fail `/sap-dev-init`**.

It needs only RFC (standard `JOB_*` FMs — present on every release). Deploy it
**Remote-Enabled in one call** via the same RFC helper (no separate change_attrs step). Run
under **32-bit** PowerShell (NCo 3.1):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\..\sap-se37\references\sap_rfc_fm_insert.ps1" -SourceFile "<SKILL_DIR>\..\sap-run-report\references\Z_RUN_REPORT.abap" -FunctionGroup "{sap_dev_function_group}" -Transport "{RESOLVED_TR}" -Remote -ShortText "RFC background report runner (/sap-run-report)"
```

Interpret the `STATUS:` line — **all outcomes are non-fatal**:

| Result | Action |
|---|---|
| `STATUS: INSERTED_ACTIVE …` | Deployed + active, Remote-Enabled ✓. |
| `STATUS: EXISTS …` | Already present (idempotent re-run) ✓. |
| `STATUS: FG_MISSING …` / `RFC_ERROR …` / `INSERT_FAILED …` / `INSERTED_INACTIVE …` | Log an INFO `run_report_fm skipped: <reason>` and continue. Optional — `/sap-run-report` uses the GUI background fallback until it is deployed. |

Do **not** treat any of these as an init failure; record the outcome for the Step 9 summary.

---

## Step 9 — Summary

Report the initialization results:

```
SAP Dev Environment Initialization Complete
============================================
Transport Request          : {RESOLVED_TR}  (policy: {way_to_get_transport_request})
Package                    : {sap_dev_package}
Function Group             : {sap_dev_function_group}
ZCMD_RFCVAL                : Created/Updated ✓
ZCMDE_RFCVAL               : Created/Updated ✓
ZCMST_RFC_PARAM            : Created/Updated ✓
ZCMCT_RFC_PARAM            : Created/Updated ✓
Z_GENERIC_RFC_WRAPPER_TBL  : Deployed ✓
ZCMRUPDATE_ADDON_TABLE      : Deployed ✓
Z_CLASS_SOURCE_INSTALL     : Deployed ✓   (optional — SE24 RFC fallback; "Skipped" on RFC-off / pre-7.31)

All sap-dev plugins are ready to use.
```

If any step failed, list what succeeded and what needs manual attention.

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_dev_init_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_dev_init_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `DEV_INIT_FAILED`, `TR_RESOLUTION_FAILED`, `PACKAGE_FAILED`, `FUGR_FAILED`, `DEPLOY_FAILED`.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `sap_dev_mode` not recognised | Typo / unsupported value | Edit settings.json; allowed values are `GUI`, `RFC`, `BDC` (case-insensitive). |
| Create step fails: `<object> is in request <TR>` / "enter object only in original request" | The object was deleted but its `E071` entry lingers in an old unreleased request, holding the name-lock | Step 1.5 should have cleared it; if it ran in a no-RFC env, clear it reactively: `/sap-se01 remove-objects <TR> OBJECTS=<object>`, then re-run the create. Find the TR via `sap_tr_object_entries.ps1 -OnlyOrphaned -Objects <object>`. |
| GUI step says "no SAP GUI session" | Step 1a was skipped or `/sap-login` failed | Run `/sap-login` manually, then resume. |
| `sap-se01` reports `ERROR: TR_RESOLUTION_FAILED` | The create-success statusbar yielded no TR number AND the SE16N fallback (E07T by AS4TEXT) found no match — e.g. the description contains characters (like `[`) the SE16N inline filter rejects | The request may still have been created — verify in SE01 / `E070` first, then pass the TR explicitly instead of re-running the create. See `sap-se01` notes. |
| `sap-function-group` (GUI sub-flow) reports `DONE FUGR=…` but FUGR is missing | Empty status bar after save (e.g. non-existent package) is not treated as failure | Verify via TLIBT / re-run the skill; ensure Step 3 (package) succeeded first. |
| `sap-function-group` (GUI sub-flow) "invalid argument" on `txtTLIBT-AREAT` | Short text too long for this S/4HANA system (~33 char limit observed) | Shorten the description. |
| SAP connection not configured | Missing settings | Run `/sap-login` first |
| Transport request creation failed | Missing S_CTS_ADMI authorization | Ask SAP admin for CTS authorization |
| Package creation failed | Missing S_DEVELOP authorization | Ask SAP admin for development authorization |
| Function group creation failed | Package or transport invalid | Verify Steps 2-3 completed successfully |
| ZCMD_RFCVAL domain creation failed | SE11 authorization | Create manually in SE11 (CHAR 1333, output length 132) |
| ZCMDE_RFCVAL data element creation failed | ZCMD_RFCVAL domain not active | Ensure Step 4b succeeded; the DE references domain ZCMD_RFCVAL |
| ZCMST_RFC_PARAM creation failed | SE11 authorization, or referenced data element (ZCMDE_RFCVAL / RS38L_PAR_ / DDOBJNAME) not active | Ensure Step 4c succeeded; create manually in SE11 or check ABAP Dictionary |
| ZCMCT_RFC_PARAM creation failed | ZCMST_RFC_PARAM not active | Ensure Step 5 succeeded before Step 6 |
| Z_GENERIC_RFC_WRAPPER_TBL deploy failed | ZCMCT_RFC_PARAM not active or SE37 authorization missing | Ensure Step 6 succeeded; deploy manually via SE37 |
| ZCMRUPDATE_ADDON_TABLE deploy failed | SE38 authorization missing | Deploy manually via SE38 |
| ZCMRUPDATE_ADDON_TABLE deploys but won't activate / won't launch on ECC 6.0 | Stale modern-syntax source (pre-2026-06-17) | Pull the current **classic-syntax** source and redeploy via `/sap-se38`; it activates on both ECC 6.0 and S/4HANA |
