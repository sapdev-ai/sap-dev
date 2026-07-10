# Settings & config — Q&A Memo

A short reference for how user/developer settings work in the `sap-dev`
plugins. Save / print / forward to teammates.

> Last updated: 2026-05-31. Canonical contract:
> `plugins/sap-dev-core/shared/rules/settings_lookup.md`. Dev iteration &
> cache-vs-repo notes: `contributing/local_development_and_testing.md`.

> **What changed (2026):** configuration now resolves across four tiers,
> highest precedence first —
> 1. env var **`SAPDEV_AI_WORK_DIR`** — durable, update-proof root, for `work_dir` only;
> 2. **`settings.local.json`** (in a plugin checkout) — *developer* override, live only when running the plugin from a repo checkout (`--plugin-dir`);
> 3. **`{work_dir}\runtime\userconfig.json`** — machine-global user overrides, and the file skills **write** to (outside the versioned plugin cache, so it survives updates);
> 4. **`settings.json`** — tracked schema/defaults.
>
> SAP connection profiles + passwords live separately in
> `{work_dir}\runtime\connections.json` (managed by `/sap-login`). The older
> "edit `settings.local.json` in the plugin folder" advice still works for
> **developers running from a repo checkout**, but **end users** should use the
> env var + `userconfig.json` (or just `/sap-login`) — the plugin cache is
> versioned, so anything you put there is lost on update. (There is no VBS
> settings library — settings resolve in PowerShell only and reach VBS via
> `%%TOKEN%%` substitution / env vars; see settings_lookup.md.)

---

## TL;DR

- **Read precedence** (per-key, on `.value`, highest first):
  `SAPDEV_AI_WORK_DIR` (work_dir only) → `settings.local.json` (dev checkout) →
  `{work_dir}\runtime\userconfig.json` (machine-global) → `settings.json` (schema).
- Skills **write** to `userconfig.json` — never `settings.json`, and no longer
  `settings.local.json`.
- `settings.json` (tracked schema) is never modified by a running skill.
- `settings.local.json` is gitignored and now purely a **developer checkout
  override**, hand-edited; read only when you run the plugin from a repo checkout
  (`--plugin-dir`).
- SAP credentials live in `{work_dir}\runtime\connections.json` via `/sap-login`.

---

## Q1. Where do my settings actually live?

`settings.json` ships in the repo and defines only the **schema** (key names,
descriptions, defaults — all values blank). Your real values live elsewhere,
depending on what they are:

- **`work_dir`** — set the env var `SAPDEV_AI_WORK_DIR` (durable across plugin
  updates). Everything else stable lives under it.
- **SAP connection + password** — saved by `/sap-login` into
  `{work_dir}\runtime\connections.json` (passwords DPAPI-encrypted).
- **Other tunables** (`custom_url`, `log_*`, `fm_cache_*`, `template_language`,
  …) — written to `{work_dir}\runtime\userconfig.json` by skills, or hand-edited
  there.
- **`settings.local.json`** (in the plugin folder) — a *developer* override used
  only when you run the plugin from a repo checkout; gitignored, so credentials
  never get committed.

Nothing you customise needs to live inside the versioned plugin cache — which
matters because that folder is replaced on every plugin update.

## Q2. How do reads work — does one file fully replace another?

**No — per-key override** across the tiers, not whole-file replacement. Only the
`.value` field is overridden; `description` and `sensitive` always come from the
schema (`settings.json`). Precedence, highest first: env var (`work_dir` only) >
`settings.local.json` > `userconfig.json` > `settings.json`. (The illustrative
table below predates the connection store — today server/user/password live in
`connections.json`, not `settings.local.json` — but the *merge mechanics* it
shows are unchanged.)

```
settings.json                       settings.local.json                effective
─────────────────────────────────   ─────────────────────────────────  ─────────
sap_user      .value = ""           sap_user      .value = "MICHAEL"   "MICHAEL"
sap_password  .value = ""           sap_password  .value = "dpapi:..." "dpapi:..."
sap_language  .value = "EN"         (key absent)                       "EN"
log_level     .value = "INFO"       log_level     .value = "DEBUG"     "DEBUG"
```

A key absent from the higher-precedence tiers simply falls back to the next one,
ending at the schema default. New schema keys need no change to your override
files.

## Q3. How do writes work — can a skill ever modify `settings.json`?

No. Skills write via `Set-SapUserSetting` (PowerShell), which targets
`{work_dir}\runtime\userconfig.json` (creating the file, key, and `runtime\`
directory as needed). Per-connection keys (TR / package / function group / mode)
instead go to the pinned profile's `dev_defaults` in `connections.json`. Skills
never write `settings.json` or `settings.local.json`.

The only time `settings.json` changes is when **you, the developer, deliberately
edit it** to add a new userConfig key or update a description. That change should
be small and reviewable — if `git diff` shows non-blank `value` fields after
editing the schema, something is wrong.

## Q4. I'm setting up — what do I do?

**Recommended (end users and developers alike):**

```text
1. Set the durable root once (then restart your terminal / Claude host so it's inherited):
     [Environment]::SetEnvironmentVariable('SAPDEV_AI_WORK_DIR','D:\sap_work','User')
2. > /sap-login    # prompts for SID/client/user/password/language;
                   # saves to {work_dir}\runtime\connections.json (DPAPI-encrypted)
```

`/sap-login` is the path the toolkit was designed for. Other tunables
(`custom_url`, logging, etc.) are written to `{work_dir}\runtime\userconfig.json`
automatically as skills need them, or you can hand-edit that file.

**Developer extra — checkout overrides.** When you run the plugin *from a repo
checkout* (`pwsh ./scripts/run-local.ps1`, i.e. `--plugin-dir`), you can drop a
`plugins/sap-dev-core/settings.local.json` to override values *for that checkout
only* — it's gitignored and wins over `userconfig.json`. Same shape as the
schema; keep only the keys you want to override:

```json
{ "userConfig": { "log_level": { "value": "DEBUG" } } }
```

Do NOT put `work_dir` or credentials here for normal use — `work_dir` belongs in
the env var, credentials in `connections.json` via `/sap-login`.

## Q5. How do I encrypt the password?

The toolkit's `sap_dpapi.ps1` helper:

```powershell
powershell -File plugins\sap-dev-core\shared\scripts\sap_dpapi.ps1 `
           -Action protect -Value "MyRealPassword"
# Output: dpapi:AQAAANCMnd8B...
```

Normally you don't need this — `/sap-login` encrypts and stores the password in
`connections.json` for you. Reach for the helper only for manual or CI cases.
DPAPI is bound to your Windows account, so the encrypted blob is useless on any
other machine or under any other user.

To decrypt (for verification / debugging):

```powershell
powershell -File plugins\sap-dev-core\shared\scripts\sap_dpapi.ps1 `
           -Action unprotect -Value "dpapi:AQAAANCMnd8B..."
```

## Q6. I need to change my password / switch SAP system / tune a setting. Where?

| What changed | Where to update |
|---|---|
| Password | `/sap-login` (re-prompts, re-encrypts into `connections.json`) |
| Server / system number / client / user | `/sap-login` (saves a connection profile in `{work_dir}\runtime\connections.json`) |
| TR / package / function group | `/sap-dev-init`, or the pinned profile's `dev_defaults` in `connections.json` (per-connection) |
| `work_dir` | the `SAPDEV_AI_WORK_DIR` env var |
| Logging level, cache TTL, `custom_url`, MODE flags | `{work_dir}\runtime\userconfig.json` (skills write it; safe to hand-edit) |
| Switching between two SAP landscapes | `/sap-login` stores multiple profiles and picks the right one per session |
| A value just for a dev checkout | `plugins/sap-dev-core/settings.local.json` (read only under `--plugin-dir`) |

## Q7. When I run `/sap-login` and change the password, which file is updated?

`{work_dir}\runtime\connections.json` — the multi-profile connection store, with
the password DPAPI-encrypted. `/sap-login` does not touch `settings.json` or
`settings.local.json` for credentials. (General, non-connection settings written
by other skills go to `userconfig.json`; see Q3.)

## Q8. A new key was added to `settings.json` upstream. Do I need to do anything?

No. The merge layer falls back to the schema default for any key your
local file doesn't override. The only reason to touch your local file is
if you want to override the new key with a non-default value.

## Q9. How do I reset my settings?

Delete the override file(s) and let defaults / `/sap-login` repopulate:

```powershell
# machine-global user overrides:
del "$env:SAPDEV_AI_WORK_DIR\runtime\userconfig.json"   # or {work_dir}\runtime\userconfig.json
# connection profiles (forces re-login):
del "$env:SAPDEV_AI_WORK_DIR\runtime\connections.json"
/sap-login
# dev checkout override (only if you created one):
del plugins\sap-dev-core\settings.local.json
```

Or surgically: open a file and delete just the keys you don't want — each deleted
key reverts to the next tier (ultimately the schema default) on the next read.

## Q10. Can I commit `settings.local.json` by accident?

No, because `plugins/*/settings.local.json` is in `.gitignore`. Confirm
with:

```powershell
cd C:\path\to\sap-dev
git check-ignore -v plugins/sap-dev-core/settings.local.json
# Should print: .gitignore:N:plugins/*/settings.local.json  ...
```

If you ever see the file appear in `git status`, the `.gitignore` line
has been removed — restore it before doing anything else.

## Q11. How does this work with the public repo and DPAPI?

DPAPI is per-Windows-account. The encrypted `dpapi:...` blob in
`{work_dir}\runtime\connections.json` (where `/sap-login` stores connection
profiles and passwords — see Q1/Q2; the same applies to a hand-maintained
dev-checkout `settings.local.json`) cannot be decrypted by anyone else, on
any other machine, even with the same password. So:

- The credential files live outside the repo (`{work_dir}\runtime\`) or are
  gitignored (`settings.local.json`), so they are never committed.
- Even if one leaked, the encrypted password is useless to attackers.

The schema file (`settings.json`) is in the public repo with all blank
values — there is nothing sensitive in it.

## Q12. Are there shared / project-wide settings that everyone should have the same value for?

If yes, those go in `settings.json` (the schema's `value` field becomes a
real default everyone gets). If those values are sensitive (e.g., a
shared service-account password), they should NOT be committed — instead,
distribute them via your team's secret store (1Password, Vault, etc.) and
have each developer apply them locally — credentials via `/sap-login`
(`connections.json`), other values in their own `userconfig.json`.

## Q13. How do I know which file a value came from? (Debugging)

Quick PowerShell snippet:

```powershell
. C:\path\to\sap-dev\plugins\sap-dev-core\shared\scripts\sap_settings_lib.ps1
$cfg = Get-SapSettings
$cfg.userConfig.sap_user        # → { description; sensitive; value }
```

The `description` and `sensitive` always come from the schema. The
`value` is the one that's been overridden. To see what's only in your
local file, just read it directly:

```powershell
Get-Content C:\path\to\sap-dev\plugins\sap-dev-core\settings.local.json
```

## Q14. What's the expected file shape for `userconfig.json` / `settings.local.json`?

Both use the same shape as `settings.json`, but you only need the keys you want
to override, and each entry only needs a `value` field. Example minimal
`{work_dir}\runtime\userconfig.json`:

```json
{
  "userConfig": {
    "custom_url":        { "value": "D:\\sap_work\\custom" },
    "log_level":         { "value": "DEBUG" },
    "template_language": { "value": "JA" }
  }
}
```

(Connection fields — server / client / user / password — are NOT put here; they
live in `connections.json` via `/sap-login`.) The helper also accepts entries
that carry `description` / `sensitive` (e.g. if you copied the schema); those are
ignored on read — only `value` matters.

## Q15. What if I'm running in CI and nothing is configured?

The merge layer just returns schema defaults — mostly empty strings — so a CI
run that needs SAP credentials reaches the "ask the user" branch, which fails in
non-interactive mode.

For CI: set `SAPDEV_AI_WORK_DIR` for the job, then either pre-write
`{work_dir}\runtime\connections.json` (and `userconfig.json`) from your secret
store, or have a CI-only setup step call `Set-SapUserSetting` for each
non-connection value. Avoid baking credentials into the workspace; prefer the
secret store + env var.

---

## Appendix — quick reference

| Task | Command |
|---|---|
| Read a value | `Get-SapSettingValue 'log_level' '<default>'` (PS) |
| Read all values | `Get-SapSettings` (PS) |
| Write a value | `Set-SapUserSetting 'log_level' 'DEBUG'` (PS) — lands in `userconfig.json` |
| Set the durable root | `[Environment]::SetEnvironmentVariable('SAPDEV_AI_WORK_DIR','D:\sap_work','User')` (restart host) |
| Save / change SAP login | `/sap-login` (writes `connections.json`, DPAPI) |
| Encrypt a password (manual) | `powershell -File shared\scripts\sap_dpapi.ps1 -Action protect -Value "..."` |
| Reset cache | `Reset-SapSettingsCache` (PS) |
| Verify gitignore | `git check-ignore -v plugins/sap-dev-core/settings.local.json` |
| Where is my config? | `{work_dir}\runtime\userconfig.json` + `…\connections.json` |

> Note: settings are PowerShell-only. There is no VBS settings helper — a VBS
> that needs a userConfig value gets it pre-resolved from its PowerShell wrapper
> (token / env var). See settings_lookup.md.
