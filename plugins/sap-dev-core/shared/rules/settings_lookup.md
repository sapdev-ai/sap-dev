# Settings Lookup Rule (settings.json + settings.local.json)

Companion to CLAUDE.md § Rule 7. Every skill that reads or writes a
`userConfig` value MUST follow this rule. The contract has two parts —
read and write — both of which apply at every reach into settings.

## The two files

| File | Tracked? | Role |
|---|---|---|
| `plugins/<plugin>/settings.json` | YES | **Schema.** Key names, descriptions, `sensitive` flags, default values. In the tracked copy every `value` field is blank or holds a safe default. |
| `plugins/<plugin>/settings.local.json` | NO (gitignored) | **Per-developer overrides.** Holds the credentials, server, packages, and any other key the developer wants to override. May be absent on a fresh clone. |

The plugin that owns the `userConfig` is almost always `sap-dev-core`, so
in practice both files live at:

```
<repo-root>/plugins/sap-dev-core/settings.json
<repo-root>/plugins/sap-dev-core/settings.local.json
```

Path resolution from a skill at `plugins/<plugin>/skills/<skill>/`:
- For skills inside **`sap-dev-core`**: go 2 levels up from `<SKILL_DIR>` to
  the plugin root, then `settings.json` / `settings.local.json`.
- For skills inside **`sap-gen-code`** or **`sap-tcd`** (cross-plugin):
  go 3 levels up to `plugins/`, then into `sap-dev-core/`, then the
  filename.

## Read rule

The effective `value` for a key is the **per-key merge** of
`settings.local.json` over `settings.json`. Only the `value` field is
overridden; `description` and `sensitive` always come from the schema.

```
settings.json                       settings.local.json                effective
─────────────────────────────────   ─────────────────────────────────  ─────────
sap_user      .value = ""           sap_user      .value = "MICHAEL"   "MICHAEL"
sap_password  .value = ""           sap_password  .value = "dpapi:..." "dpapi:..."
sap_language  .value = "EN"         (key absent)                       "EN"
```

Implementation choices, in preference order:

1. **PowerShell scripts:** dot-source
   `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1` and call
   `Get-SapSettingValue '<key>' '<default>'`.
2. **VBScript scripts:**
   `ExecuteGlobal FSO.OpenTextFile("%%SETTINGS_LIB_VBS%%",1).ReadAll()`
   then call `GetSapSettingValue("<key>", "<default>")`.
3. **Claude-driven Read-tool flows** (i.e., the AI executes the SKILL.md
   directly): read **both** files with the Read tool. If
   `settings.local.json` doesn't exist, treat it as `{"userConfig": {}}`.
   For each key, prefer `settings.local.json.userConfig.<key>.value` when
   non-empty; otherwise use `settings.json.userConfig.<key>.value`.

A key whose effective value is the empty string should be treated as
"not configured" — fall back to the documented default, or prompt the
user if no default exists.

## Write rule

ALL writes go to `settings.local.json` — never to `settings.json`. The
schema file changes only when a developer (the human) deliberately adds
a new `userConfig` key or edits a description.

Implementation choices, in preference order:

1. **PowerShell scripts:** `Set-SapUserSetting '<key>' '<value>'`. The
   helper creates the file and / or the key as needed.
2. **VBScript scripts:** `Call SetSapUserSetting("<key>", "<value>")`.
3. **Claude-driven Edit-tool flows:** target `settings.local.json`. If
   the file doesn't exist, create it with shape
   `{"userConfig":{"<key>":{"value":"<v>"}}}`. **Never** use the Edit tool
   to change a `value` field in `settings.json`.

## Onboarding

A fresh clone has no `settings.local.json`. The recommended bootstrap is
`pwsh ./scripts/dev-setup.ps1` (interactive prompts + DPAPI encryption +
helper-mediated writes). Alternative: run `/sap-login` once and let it
populate the file. See `docs/settings-local-faq.md` for the full Q&A.

## Why this matters

- The public repo never carries a non-blank credential.
- A new developer fills their values once; commits stay clean forever.
- New schema keys propagate automatically — the local override only
  contains the keys the developer actually overrides.
- DPAPI binds the encrypted password to the developer's Windows account,
  so even a leaked `settings.local.json` is useless on any other machine.

## What NOT to do

- ❌ Read `settings.json` directly when the value matters — you'll miss the
  developer's overrides for `sap_password`, `sap_user`, etc.
- ❌ Use the Edit tool on `settings.json` to persist a runtime decision.
- ❌ Prompt the user for a credential the merge could have provided.
- ❌ Print the contents of `settings.local.json` in a log line — the
  password may be present (DPAPI-encrypted, but still).
