# Settings Lookup Rule (env var → settings.local.json → userconfig.json → settings.json)

Companion to CLAUDE.md § Rule 7. Every skill that reads or writes a
`userConfig` value MUST follow this rule. The contract has two parts —
read and write — both of which apply at every reach into settings.

## The files (resolution tiers)

Effective values are a per-key merge across these tiers, **highest precedence first**:

| Tier | Source | Tracked? | Survives plugin update? | Role |
|---|---|---|---|---|
| 0 | env var `SAPDEV_AI_WORK_DIR` | n/a | **yes** | Bootstrap for `work_dir` ONLY — the durable, update-proof root. |
| 1 | `plugins/<plugin>/settings.local.json` | NO (gitignored) | no (in cache) | **Dev checkout override.** Live only when the plugin runs from a repo checkout (e.g. `--plugin-dir`). Hand-edited; never written by a skill. |
| 2 | `{work_dir}\runtime\userconfig.json` | NO | **yes** (outside the plugin tree) | **Machine-global user overrides** + the single skill WRITE target. What end users configure. |
| 3 | `plugins/<plugin>/settings.json` | YES | no (in cache) | **Schema.** Key names, descriptions, `sensitive` flags, defaults. Read-only at runtime. |

Per-key precedence: **env (work_dir only) > settings.local.json > userconfig.json > settings.json**. Only `.value` is overridden; `description`/`sensitive` always come from the schema (tier 3).

The plugin that owns `userConfig` is almost always `sap-dev-core`:

    <plugin-root>/settings.json          # schema (tier 3; in repo or cache)
    <plugin-root>/settings.local.json    # dev checkout override (tier 1)
    {work_dir}\runtime\userconfig.json   # machine-global overrides + write target (tier 2)

> **work_dir is the bootstrap pointer.** It locates `userconfig.json`, so it is resolved WITHOUT reading `userconfig.json` (env var → settings.local.json → settings.json → default `C:\sap_dev_work`). Never set `work_dir` in `userconfig.json` — it is ignored there.

> **Implementation status — PowerShell only (verified).** Tiers 0 and 2 and the new write target are implemented in `sap_settings_lib.ps1` + `Get-SapWorkDir` (`sap_connection_lib.ps1`). The VBS counterpart `sap_settings_lib.vbs` does NOT yet support tiers 0/2 — and separately has a **pre-existing VBScript compile bug** (its `_`-prefixed helper names are illegal VBScript identifiers, so an `ExecuteGlobal` include fails to compile). Every load-bearing settings read is PowerShell, so this is latent; fixing the VBS lib + porting tiers 0/2 is a tracked follow-up.

Path resolution from a skill at `plugins/<plugin>/skills/<skill>/`:
- For skills inside **`sap-dev-core`**: go 2 levels up from `<SKILL_DIR>` to
  the plugin root, then `settings.json` / `settings.local.json`.
- For skills inside **`sap-gen-code`** or **`sap-tcd`** (cross-plugin):
  go 3 levels up to `plugins/`, then into `sap-dev-core/`, then the
  filename.

## Per-connection exception (Phase 4.3+)

A small set of keys is **system-specific** — their values change meaning
across SAP systems (a TR number from S4D is meaningless on S4H; a TR-
description template might follow Customer A's convention but not
Customer B's). For these keys the source of truth is the **pinned
connection's `dev_defaults`** block in `connections.json` (at
`{work_dir}\runtime\connections.json`), not `settings.local.json`.

The current list (read it live from
`sap_connection_lib.ps1:$SapPerConnectionDevKeys`):

| Key | Why per-connection |
|---|---|
| `sap_dev_transport_request` | TR numbers carry the SID prefix (`S4DK*`) |
| `sap_dev_package` | naming conventions vary per project / customer |
| `sap_dev_function_group` | same as package |
| `sap_dev_mode` | GUI / RFC / BDC capability varies per system |
| `way_to_get_transport_request` | TR-workflow policy varies per project |
| `rule_of_tr_description` | TR-description style varies per customer |
| `tr_description_template` | coupled to `rule_of_tr_description` |

For these keys the resolution chain becomes **three** steps, not two:

```
1. connections.json[pinned-profile].dev_defaults[<key>]   <- highest priority
2. settings.local.json.userConfig.<key>.value             <- override (rarely used for these)
3. settings.json.userConfig.<key>.value                   <- schema default
```

`connections.json` is gitignored AND lives outside the plugin tree
entirely (it's under the user's `work_dir`). So per-connection values
never need to worry about commit hygiene.

## Read rule

The effective `value` for a key is the **per-key merge** across the tiers above,
highest first: env var (`work_dir` only) > `settings.local.json` >
`userconfig.json` > `settings.json`. Only the `value` field is overridden;
`description` and `sensitive` always come from the schema.

**Per-connection keys (the table above) override this:** read the pinned
profile's `dev_defaults[<key>]` first; only fall through to the two-file
merge when `dev_defaults` is empty or absent.

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
   `Get-SapSettingValue '<key>' '<default>'`. The helper handles
   per-connection routing automatically — for keys in the per-connection
   list it consults `Get-SapCurrentDevDefault` first.
2. **VBScript scripts:**
   `ExecuteGlobal FSO.OpenTextFile("%%SETTINGS_LIB_VBS%%",1).ReadAll()`
   then call `GetSapSettingValue("<key>", "<default>")`. **Note:** the VBS
   helper does NOT yet implement per-connection routing — it always reads
   from the two-file merge. None of the per-connection keys are currently
   read from VBS context, so this is fine in practice. If a future VBS
   needs one of those keys, port the routing logic from
   `sap_settings_lib.ps1` first.
3. **Claude-driven Read-tool flows** (i.e., the AI executes the SKILL.md
   directly): for **non-per-connection keys**, read `settings.json`,
   `{work_dir}\runtime\userconfig.json`, and `settings.local.json` with the
   Read tool (treat any missing file as `{"userConfig": {}}`). For each key,
   prefer `settings.local.json` → then `userconfig.json` → then `settings.json`
   on the `.value` field (first non-empty wins). Resolve `work_dir` itself from
   `$env:SAPDEV_AI_WORK_DIR` → settings.local.json → settings.json → default,
   NOT from userconfig.json.
   For **per-connection keys**, additionally read
   `{work_dir}\runtime\connections.json`, find the profile whose `id`
   matches the AI session's pinned `connection_id` (look it up via
   `{work_dir}\runtime\session_registry.json` `ai_sessions[<id>]`), and
   prefer that profile's `dev_defaults[<key>]` over the two-file merge.
   When no profile is pinned, the two-file merge applies.

A key whose effective value is the empty string should be treated as
"not configured" — fall back to the documented default, or prompt the
user if no default exists.

## Write rule

Non-per-connection writes go to **`userconfig.json`** (`{work_dir}\runtime\`,
outside the versioned plugin cache, so they survive plugin updates) — never to
`settings.json`, and no longer to `settings.local.json`. `settings.local.json`
stays a hand-edited dev checkout override (higher read precedence) and is never
written by a skill. The schema file changes only when a developer deliberately
adds a new `userConfig` key or edits a description.

**Per-connection keys override this:** writes to the keys listed in the
per-connection table target the pinned profile's `dev_defaults` block in
`connections.json`. The two-file merge is used only as a fallback when
no profile is pinned (e.g. a fresh box that has never run `/sap-login`).

Implementation choices, in preference order:

1. **PowerShell scripts:** `Set-SapUserSetting '<key>' '<value>'`. The
   helper creates the file and/or the key as needed, and **automatically
   routes per-connection keys** to `Set-SapCurrentDevDefault` (which
   targets `connections.json[pinned-profile].dev_defaults`). Callers
   don't need to know which keys are per-connection.
2. **VBScript scripts:** `Call SetSapUserSetting("<key>", "<value>")`.
   No per-connection routing on the VBS side — only call this for the
   global keys.
3. **Claude-driven Edit-tool flows:** for **non-per-connection keys**,
   target `{work_dir}\runtime\userconfig.json`. If the file (or its `runtime\`
   directory) doesn't exist, create it with shape
   `{"userConfig":{"<key>":{"value":"<v>"}}}`. Do NOT write
   `settings.local.json` (a hand-edited dev override), and **never** use the
   Edit tool to change a `value` field in `settings.json`.
   For **per-connection keys**, target the matching profile's
   `dev_defaults` block in `connections.json`. Preferred: shell out to
   `Set-SapCurrentDevDefault` via PowerShell rather than hand-editing
   `connections.json`, because that file is broker-locked under a named
   mutex (`SapDevConnectionStore_v1`) — concurrent writes from a
   different SAP-driving process would race a direct file edit.

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
