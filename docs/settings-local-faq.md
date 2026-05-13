# `settings.local.json` — Q&A Memo

A short reference for how per-developer settings work in the `sap-dev`
plugins. Save / print / forward to teammates.

> Last updated: 2026-05-13 — based on `sap_settings_lib.{ps1,vbs}` shipped
> with v0.1.0+.

---

## TL;DR

- `plugins/<plugin>/settings.json` — **tracked**. Schema, descriptions, blank values.
- `plugins/<plugin>/settings.local.json` — **gitignored**. Your real values.
- Skills **read** the merged view (local overrides main per-key on the `value` field).
- Skills **write** only to `settings.local.json`. `settings.json` is never modified by a running skill.

---

## Q1. What problem does `settings.local.json` solve?

`settings.json` ships in the public repo and defines the schema (key names,
descriptions, defaults). When you fill in real values during testing —
SAP server, user, password — those values used to land in `settings.json`
and risked being committed.

`settings.local.json` is a sibling file, gitignored, that holds **your**
values. The plugin merges the two at runtime: your values override the
schema defaults on a per-key basis. There is no path by which credentials
can accidentally enter the tracked file, because skills are not allowed
to write there at all.

## Q2. How do reads work — does the local file fully replace the main file?

**No — per-key override**, not whole-file replacement. Only the `.value`
field is overridden. `description` and `sensitive` always come from the
schema (`settings.json`).

```
settings.json                       settings.local.json                effective
─────────────────────────────────   ─────────────────────────────────  ─────────
sap_user      .value = ""           sap_user      .value = "MICHAEL"   "MICHAEL"
sap_password  .value = ""           sap_password  .value = "dpapi:..." "dpapi:..."
sap_language  .value = "EN"         (key absent)                       "EN"
log_level     .value = "INFO"       log_level     .value = "DEBUG"     "DEBUG"
```

Keys that are in the schema but absent from your local file simply fall
back to the schema default. New keys added to the schema in the future
require no change to your local file.

## Q3. How do writes work — can a skill ever modify `settings.json`?

No. Every skill writes via `Set-SapUserSetting` (PowerShell) or
`SetSapUserSetting` (VBScript), which always targets
`settings.local.json`. If the file or the key doesn't exist yet, the
helper creates it.

The only time `settings.json` changes is when **you, the developer,
deliberately edit it** to add a new userConfig key or update a description.
That change should be small and reviewable — if `git diff` shows
non-blank `value` fields after editing the schema, something is wrong.

## Q4. I'm a new developer cloning the repo. What do I do?

Two options. Pick whichever you prefer.

**Option A — let `/sap-login` build the file for you (recommended).**

```text
> /sap-login
```

The skill prompts for SID, client, user, password, language. The password
is encrypted via DPAPI before being written to `settings.local.json`.
This is the path the toolkit was designed for.

**Option B — copy the schema and edit by hand.**

```powershell
cd C:\path\to\sap-dev
copy plugins\sap-dev-core\settings.json plugins\sap-dev-core\settings.local.json
notepad plugins\sap-dev-core\settings.local.json
# Fill in values for at least: sap_application_server, sap_system_number,
# sap_client, sap_user, sap_password (DPAPI-encrypted — see Q5).
# Delete keys you don't need to override; the schema defaults will kick in.
```

You can also keep only the keys you want to override and delete the rest;
the merge fills in everything else from the schema.

## Q5. How do I encrypt the password?

The toolkit's `sap_dpapi.ps1` helper:

```powershell
powershell -File plugins\sap-dev-core\shared\scripts\sap_dpapi.ps1 `
           -Action protect -Value "MyRealPassword"
# Output: dpapi:AQAAANCMnd8B...
```

Paste the `dpapi:...` blob into the `value` field for `sap_password` in
`settings.local.json`. DPAPI is bound to your Windows account — the
encrypted blob is useless on any other machine or under any other user.

To decrypt (for verification / debugging):

```powershell
powershell -File plugins\sap-dev-core\shared\scripts\sap_dpapi.ps1 `
           -Action unprotect -Value "dpapi:AQAAANCMnd8B..."
```

## Q6. I need to change my password / switch to a different SAP system. Where do I edit?

For routine changes, **edit `settings.local.json` directly** with any
text editor. For the password specifically, prefer one of:

| What changed | How to update |
|---|---|
| Password | `/sap-login` (re-prompts and re-encrypts), or run `sap_dpapi.ps1` and paste the new `dpapi:...` blob into `settings.local.json` |
| Server / system number / client / user | Edit `settings.local.json` directly |
| TR / package / function group | Edit directly, or run `/sap-dev-init` to bootstrap fresh ones |
| Logging level, cache TTL, MODE flags | Edit directly |
| Switching between two SAP landscapes | Keep multiple files (e.g., `settings.local.dev.json`, `settings.local.qa.json`) and copy-rename when switching |

## Q7. When I run `/sap-login` and change the password, which file is updated?

Always `settings.local.json`. Never `settings.json`. This is enforced by
the skill operating rules (Rule 7 in `CLAUDE.md`) and by the
`Set-SapUserSetting` helper: there is no API on the helper that targets
`settings.json`.

If the key was previously only in the schema and not in your local file,
the helper creates it in the local file. If the local file itself doesn't
exist, the helper creates it with the right shape.

## Q8. A new key was added to `settings.json` upstream. Do I need to do anything?

No. The merge layer falls back to the schema default for any key your
local file doesn't override. The only reason to touch your local file is
if you want to override the new key with a non-default value.

## Q9. My local file got out of sync with the schema. How do I reset?

Easiest:

```powershell
# Delete the local file
del plugins\sap-dev-core\settings.local.json
# Recreate via the skill
/sap-login
# (or via copy from schema, see Q4 Option B)
```

Or surgically: open `settings.local.json`, delete the keys you don't want,
keep the ones you do. Anything you delete reverts to the schema default
on the next read.

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

DPAPI is per-Windows-account. The encrypted `dpapi:...` blob in your
`settings.local.json` cannot be decrypted by anyone else, on any other
machine, even with the same password. So:

- Your local file is safe on your disk.
- Your local file is gitignored.
- Even if it leaked, the encrypted password is useless to attackers.

The schema file (`settings.json`) is in the public repo with all blank
values — there is nothing sensitive in it.

## Q12. Are there shared / project-wide settings that everyone should have the same value for?

If yes, those go in `settings.json` (the schema's `value` field becomes a
real default everyone gets). If those values are sensitive (e.g., a
shared service-account password), they should NOT be committed — instead,
distribute them via your team's secret store (1Password, Vault, etc.) and
have each developer paste them into their own `settings.local.json`.

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

## Q14. What's the expected file shape for `settings.local.json`?

Same as `settings.json` but you only need the keys you want to override,
and each entry only needs a `value` field. Example minimal file:

```json
{
  "userConfig": {
    "sap_application_server": { "value": "myhost.example.com" },
    "sap_system_number":      { "value": "00" },
    "sap_client":             { "value": "100" },
    "sap_user":               { "value": "DEVUSER" },
    "sap_password":           { "value": "dpapi:AQAAANCMnd8BFdERjHo..." },
    "sap_language":           { "value": "EN" }
  }
}
```

The helper happily accepts entries with `description` and `sensitive`
fields too (e.g., if you copied the whole schema into your local file).
Those extra fields are ignored on read — only `value` matters.

## Q15. What if I'm running in CI and there's no `settings.local.json`?

The merge layer just returns schema defaults. Most schema defaults are
empty strings, so a CI run that calls `/sap-login` without any
credentials configured will reach the "ask the user" branch — which fails
in non-interactive mode.

For CI, set the credentials by writing a `settings.local.json` in the CI
job's workspace before running any sap-dev skill. Or feed values via
environment variables and have a CI-only setup script call
`Set-SapUserSetting` for each one.

---

## Appendix — quick reference

| Task | Command |
|---|---|
| Read a value | `Get-SapSettingValue 'sap_user' '<default>'` (PS) or `GetSapSettingValue("sap_user", "<default>")` (VBS) |
| Read all values | `Get-SapSettings` (PS) or `GetSapSettings()` (VBS) |
| Write a value | `Set-SapUserSetting 'sap_user' 'NEWUSER'` (PS) or `Call SetSapUserSetting("sap_user", "NEWUSER")` (VBS) |
| Encrypt a password | `powershell -File shared\scripts\sap_dpapi.ps1 -Action protect -Value "..."` |
| Decrypt a password | `powershell -File shared\scripts\sap_dpapi.ps1 -Action unprotect -Value "dpapi:..."` |
| Reset cache | `Reset-SapSettingsCache` (PS) or `Call ResetSapSettingsCache()` (VBS) |
| Verify gitignore | `git check-ignore -v plugins/sap-dev-core/settings.local.json` |
| Reset local file | `del plugins\sap-dev-core\settings.local.json` then `/sap-login` |
