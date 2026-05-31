# work_dir Resolution & First-Run Onboarding

**Used by**: `/sap-login` and `/sap-dev-init` Step 0 — the onboarding entry
points. Every **other** skill resolves `work_dir` with the plain env-aware
one-liner (`Get-SapWorkDir`) and does **NOT** prompt; only these two onboard.

`work_dir` is the load-bearing value — connections, settings (`userconfig.json`),
logs and caches all live under it. The durable, update-proof root is the **user
environment variable `SAPDEV_AI_WORK_DIR`** (the versioned plugin cache is not).

Helper: `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_workdir_setup.ps1`
(`-Action probe | set | migrate`).

---

## Step A — Probe

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_workdir_setup.ps1" -Action probe
```

Returns `WORK_DIR`, `ENV_SET`, `ENV_VALUE`, `STORE_EXISTS` (is there a
`connections.json` under the resolved work_dir), `USERCONFIG_EXISTS`.

## Step B — Decide `{work_dir}`

| Signal | Action |
|---|---|
| `ENV_SET=True` | Use `WORK_DIR`. No prompt. (If the user explicitly asks to change it → **Step D**.) |
| `ENV_SET=False`, `STORE_EXISTS=True` | Existing user on the default/settings dir. Use `WORK_DIR`, do **not** block. Print one line: *"Tip: set `SAPDEV_AI_WORK_DIR=<WORK_DIR>` to make your work dir update-proof — re-run this skill to choose."* |
| `ENV_SET=False`, `STORE_EXISTS=False` | **First run** → **Step C**. |

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
5. Tell the user: *"Set `SAPDEV_AI_WORK_DIR=<chosen>` (durable). Active for this
   run; other already-open terminals/hosts pick it up after you restart them."*

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

## Step E — Current-session env bridge (always, once `{work_dir}` is known)

Setting the user env var does **not** reach this session's already-spawned
subprocesses (they inherited their environment at launch). So for the rest of
THIS run, prefix every PowerShell command with the env assignment before
dot-sourcing, so internal `Get-SapWorkDir` calls (e.g. the connection-store
path) agree with `{work_dir}`:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:SAPDEV_AI_WORK_DIR='{work_dir}'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; <your command>"
```

This is harmless when `ENV_SET=True` already (it re-asserts the same value) and
load-bearing on a fresh first-run set.
