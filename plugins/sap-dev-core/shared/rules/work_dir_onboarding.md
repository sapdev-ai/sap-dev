# work_dir Resolution & First-Run Onboarding

**Used by**: `/sap-login` and `/sap-dev-init` Step 0 — the onboarding entry
points. Every **other** skill resolves `work_dir` with the plain env-aware
one-liner (`Get-SapWorkDir`) and does **NOT** prompt; only these two onboard.

`work_dir` is the load-bearing value — connections, settings (`userconfig.json`),
logs and caches all live under it. The durable, update-proof root is the **user
environment variable `SAPDEV_AI_WORK_DIR`** (the versioned plugin cache is not),
mirrored to a **durable out-of-cache pointer file `%APPDATA%\sapdev-ai\work_dir.txt`**.
The `set` action writes BOTH; the resolver reads both. Why two:

- The **env var** is what external shells / future sessions inherit.
- The **pointer file** is what bridges the **current** AI session. A freshly set
  *User* env var never reaches already-running processes (this host + every
  sibling PowerShell it spawns, one per skill call), so without the pointer the
  next skill in the same session falls back to `C:\sap_dev_work`. The pointer is
  read fresh by every subprocess, so the work_dir chosen mid-session sticks for
  every later skill — and, living outside the versioned cache, survives plugin
  updates (unlike a value hand-written into `settings.json`).

Full resolution order (highest first): env var → `settings.local.json` (dev
checkout override) → `%APPDATA%\sapdev-ai\work_dir.txt` → `settings.json` →
default `C:\sap_dev_work`.

Helper: `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_workdir_setup.ps1`
(`-Action probe | set | migrate`).

---

## Step A — Probe

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_workdir_setup.ps1" -Action probe
```

Returns `WORK_DIR`, `ENV_SET`, `ENV_VALUE`, `POINTER_PATH`, `POINTER_EXISTS`,
`POINTER_VALUE` (the durable pointer file), `STORE_EXISTS` (is there a
`connections.json` under the resolved work_dir), `USERCONFIG_EXISTS`.

## Step B — Decide `{work_dir}`

| Signal | Action |
|---|---|
| `ENV_SET=True` | Use `WORK_DIR`. No prompt. (If the user explicitly asks to change it → **Step D**.) Then **Step B.1** (keep the pointer in sync). |
| `ENV_SET=False`, `POINTER_EXISTS=True` | Already onboarded durably via the pointer file. Use `WORK_DIR`, no prompt, no tip. (Change → **Step D**.) |
| `ENV_SET=False`, `POINTER_EXISTS=False`, `STORE_EXISTS=True` | Existing user, not yet pinned durably. Use `WORK_DIR` (no prompt). Then **Step B.1** auto-pins it. |
| `ENV_SET=False`, `POINTER_EXISTS=False`, `STORE_EXISTS=False` | **First run** → **Step C**. |

### Step B.1 — Auto-pin a non-default work_dir (zero-consent, idempotent)

Whenever `{work_dir}` resolves to a **non-default** path (`WORK_DIR` ≠
`C:\sap_dev_work`) that the pointer does not already record (`POINTER_VALUE` ≠
`WORK_DIR`), write the pointer so the choice is durable across plugin updates
**and** read by every later skill this session. This is what makes the pointer
reliably appear after a single `/sap-login` for an *existing* user (the
first-run/change paths already write it via `set`). Writing only the `%APPDATA%`
file — not the User env var — is a low-stakes, local record of where config
already lives, so it needs no prompt:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_workdir_setup.ps1" -Action pin -WorkDir "{work_dir}"
```

Returns `PIN_OK=True` (and `ALREADY=True` when it was already that value).
When `WORK_DIR` **is** the default `C:\sap_dev_work`, skip — the default is the
hardcoded fallback, so a pointer adds nothing. Optionally still tip the user:
*"set `SAPDEV_AI_WORK_DIR=<WORK_DIR>` so non-AI shells inherit it too."*

## Step C — First-run prompt + set

1. Ask (AskUserQuestion): *"Where should the SAP dev work directory live?
   Everything durable — SAP connections, settings, logs, caches — lives under
   it."* Options: **`C:\sap_dev_work` (default, recommended)** and an Other path.
2. The chosen value persists to a **user environment variable** (a standing
   config change) — only proceed after the user has chosen (their choice is the
   consent).
3. Persist it:
   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_workdir_setup.ps1" -Action set -WorkDir "<chosen>"
   ```
4. `{work_dir}` = `<chosen>` for the rest of this run.
5. Tell the user: *"Set `SAPDEV_AI_WORK_DIR=<chosen>` (durable env var) and wrote
   the pointer `%APPDATA%\sapdev-ai\work_dir.txt`. Active immediately — every
   skill this session resolves to it. Other already-open terminals/hosts pick up
   the env var after you restart them."*

The `set` action persists **both** the User env var and the pointer file, so the
choice is durable across plugin updates *and* effective for the current session
without a restart. (`SET_OK=True`, `POINTER_SET=True` confirm both writes.)

## Step D — Change (user picks a different work_dir, or changes the env var)

When the new `{work_dir}` differs from a path that already holds state
(`STORE_EXISTS` or `USERCONFIG_EXISTS` at the **old** path):

1. **Warn**: *"Your SAP connections (`connections.json`), settings
   (`userconfig.json`), logs and caches live under `<old>`. Switching to `<new>`
   points the tools at `<new>`, which is empty — your profiles/settings won't
   appear there until moved. `<old>` is left untouched as a backup."*
2. **Auto-offer to migrate** (AskUserQuestion): *Copy `connections.json` +
   `userconfig.json` from `<old>` to `<new>`?* → **Copy** / **Start fresh** /
   **Cancel**.
   - **Copy**:
     ```bash
     powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_workdir_setup.ps1" -Action migrate -From "<old>" -To "<new>"
     ```
     Non-destructive: never deletes `<old>`, never overwrites an existing file at
     `<new>` (reports `SKIPPED`); logs/caches stay at `<old>` (regenerable).
   - **Start fresh**: proceed; the user re-logs in / re-inits at `<new>`.
   - **Cancel**: keep `<old>`; make no change.
3. Then **set** the env var to `<new>` (Step C.3) and apply the session bridge.

## Step E — Current-session env bridge (within THIS skill run)

The pointer file (written by `set` in Step C.3) already bridges the session for
**later skills** — they each resolve `{work_dir}` from it on their own. Step E is
the narrower in-run guard for the **rest of `/sap-login` / `/sap-dev-init`
itself**: a freshly set User env var does not reach this run's already-spawned
subprocesses, and on a brand-new first-run `set` the pointer write and the first
dependent command can race. So prefix every PowerShell command in the remainder
of THIS run with the env assignment before dot-sourcing, so internal
`Get-SapWorkDir` calls (e.g. the connection-store path) agree with `{work_dir}`
deterministically:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command "\$env:SAPDEV_AI_WORK_DIR='{work_dir}'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; <your command>"
```

The leading `\$` escapes the dollar so **bash** passes a literal `$env:` to
PowerShell (these fences run through the Bash tool, which would otherwise expand
`$env` to nothing and leave a stray `:`); drop the backslash only if you run the
line via the PowerShell tool directly. This bridge is harmless when `ENV_SET=True`
already (it re-asserts the same value) and a belt-and-suspenders guard on a fresh
first-run set (the pointer file is the primary, cross-skill bridge).
