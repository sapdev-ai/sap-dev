# Local Development & Testing (cache vs. repo, config locations, fast inner loop)

**Applies to**: anyone editing this repo's plugin source
(`plugins/sap-dev-core`, `plugins/sap-gen-code`, …) who wants to test changes
against a live SAP system before publishing.

**Audience**: plugin developers (Role 1). This doc is *not* shipped to end
users and has no runtime callers — it lives in `contributing/` for the same
reason as `parallel_safe_session_attach.md`.

**Status**: the **Current behaviour** sections describe how the shipped code
works and were verified on a live install. The env var + `userconfig.json` tiers
(see **Implemented**, near the end) landed in `sap_settings_lib.ps1` /
`sap_connection_lib.ps1` and are verified — **PowerShell only**; the VBS twin has
a separate pre-existing gap noted there. The **Still proposed** items are
design-only — don't cite them as fact.

---

## TL;DR

1. **Skills run from the *cache*, not your repo.** Installing from the remote
   marketplace copies the plugin to
   `~/.claude/plugins/cache/sap-dev/sap-dev-core/<ver>/`. Editing your working
   tree and re-invoking a skill does **nothing** to those runs.
2. **To test repo edits, launch the CLI with `--plugin-dir`** (in-place, no
   cache copy, per-session, isolated):
   ```powershell
   claude --plugin-dir "<repo>\plugins\sap-dev-core" --plugin-dir "<repo>\plugins\sap-gen-code"
   ```
3. **Reload rules:** `.ps1`/`.vbs` edits are live on the next skill invocation
   (no reload). `SKILL.md` frontmatter / new skills / `hooks/` / `agents/` /
   `.mcp.json` need `/reload-plugins` (or a new session).
4. **Desktop app has no `--plugin-dir`.** Desktop-primary developers run the
   dev loop in a parallel **CLI terminal**; desktop sessions keep running the
   stable cached version, undisturbed.
5. **Before any e2e**, run the no-Claude gates: `npm run check:consistency`
   and `npm run validate`, plus direct script runs (Tier 0 below).

---

## Current behaviour: how the plugin is loaded

This marketplace is registered from the **remote git URL**
(`https://github.com/sapdev-ai/sap-dev.git`), per
`~/.claude/plugins/known_marketplaces.json`. Installing a plugin **copies** its
files into the per-version cache and records the install in
`~/.claude/plugins/installed_plugins.json`, e.g.:

```
installPath : C:\Users\<you>\.claude\plugins\cache\sap-dev\sap-dev-core\0.7.2
version     : 0.7.2
gitCommitSha: <sha>
```

So when you invoke `/sap-se38`, `/sap-login`, etc., Claude executes the **cached
copy at that path** — not `…\sapdev-ai\sap-dev\plugins\sap-dev-core`. Your repo
edits are invisible to skill runs until you either republish/update, or load the
repo in-place with `--plugin-dir` (below).

> Local-path marketplaces (`/plugin marketplace add <local-dir>`) also **copy to
> cache** — they are *not* live. Don't use them for iteration; use
> `--plugin-dir`.

---

## Current behaviour: where configuration actually lives

Knowing which is which removes 90% of "why didn't my change take effect"
confusion. Listed highest read-precedence first:

| Source | Location | Tracked? | Survives update? | Role |
|---|---|---|---|---|
| env var `SAPDEV_AI_WORK_DIR` | OS user environment | n/a | **yes** | Bootstrap for `work_dir` ONLY (highest precedence). |
| `work_dir.txt` pointer | `%APPDATA%\sapdev-ai\work_dir.txt` | n/a | **yes** | Durable out-of-cache mirror of the env var for `work_dir` ONLY — also bridges the current AI session (a freshly-set User env var never reaches already-running processes). Written together with the env var by `sap_workdir_setup.ps1 set`. |
| `settings.local.json` | `<plugin-root>/settings.local.json` | **no** (gitignored) | **no (in cache)** | Dev *checkout* override; live only when running from a repo checkout (`--plugin-dir`). Hand-edited, never written by a skill. |
| `userconfig.json` | `{work_dir}\runtime\userconfig.json` | no | **yes** — outside the plugin tree | Machine-global user overrides + the single skill WRITE target. The end-user config home. |
| `connections.json` | `{work_dir}\runtime\connections.json` | no | **yes** — outside the plugin tree | SAP connection profiles (DPAPI passwords) + per-connection `dev_defaults` (TR / package / FG). |
| `settings.json` | `<plugin-root>/settings.json` (cache **or** repo) | yes | no (in cache) | **Schema** — names, descriptions, `sensitive` flags, defaults. Read-only at runtime. |

Per-key read precedence: **env (work_dir only) > settings.local.json > userconfig.json > settings.json**. (`connections.json` is a separate per-connection store for TR/package/FG/mode, not part of this merge.)

Key consequences:

- **`settings.local.json` is version-dependent.** It sits inside the versioned
  cache folder, so a plugin update to a new version starts with a fresh
  `settings.json` and **no** `settings.local.json`. Overrides placed in the old
  version folder are not seen by the new one.
- **A fresh marketplace install has no `settings.local.json`** — it's
  gitignored (`plugins/*/settings.local.json`) and never packaged. Installed
  runs therefore fall back to **schema defaults** (`work_dir` → the default
  `C:\sap_dev_work`).
- **Your durable state already lives outside the cache.** Login profiles and
  dev defaults are in `{work_dir}\runtime\connections.json`. That's why live
  SAP testing works even though the cache has no `settings.local.json`, and why
  it survives plugin updates (as long as `work_dir` resolves to the same place).
- **`work_dir` is the load-bearing value.** Everything stable lives under it.
  `work_dir` resolves env var `SAPDEV_AI_WORK_DIR` → settings.local.json →
  `%APPDATA%\sapdev-ai\work_dir.txt` (durable out-of-cache pointer) →
  settings.json → default `C:\sap_dev_work`. Set the **env var** once at the OS
  user level (then restart the host so it's inherited) to make the root
  update-proof; otherwise a custom `work_dir` set only in a cache
  `settings.local.json` is silently lost on update and the new version looks for
  `connections.json` / `userconfig.json` in the wrong place.

Full read/write contract: `plugins/sap-dev-core/shared/rules/settings_lookup.md`
and `docs/settings-local-faq.md`.

---

## Current behaviour: two runtimes (and which `settings.local.json` is live)

"Developer vs. end user" is about **which copy of the code runs**, not who you
are:

| Runtime | Plugin code from | Which `settings.local.json` is read |
|---|---|---|
| **Installed** (normal `claude`, desktop app) | cache `…\<ver>\` | the cache copy — usually **absent**, so schema defaults apply |
| **`--plugin-dir`** (your repo, see below) | your repo plugin root | the **repo's** `settings.local.json` (the checkout-local override) |

So the repo's `settings.local.json` is **inert for installed runs** and only
becomes live under `--plugin-dir`. Layer them like git config (most-specific
wins): env var (`work_dir` only) > checkout-local `settings.local.json` >
machine-global `userconfig.json` > schema defaults (`settings.json`) — with the
`%APPDATA%\sapdev-ai\work_dir.txt` pointer slotting between `settings.local.json`
and `settings.json` for `work_dir` itself.

> Tip: if the repo's `settings.local.json` overrides `work_dir` to a different
> path than your installed runs use, your `--plugin-dir` session will look for
> `connections.json` somewhere else and may need a fresh `/sap-login`. Keep them
> aligned, or leave `work_dir` unset in the repo file.

---

## The fast inner loop (three tiers, fastest → slowest)

### Tier 0 — no Claude at all (seconds)
Most logic lives in shared PowerShell / reference VBS. Test it directly from the
repo against SAP, plus the static gates:

```powershell
# dot-source / run a script directly
. .\plugins\sap-dev-core\shared\scripts\sap_settings_lib.ps1
Get-SapSettingValue 'work_dir'

# static gates (CI parity)
npm run check:consistency   # node scripts/check-consistency.mjs
npm run validate            # JSON-schema validation
```

### Tier 1 — end-to-end through Claude (`--plugin-dir`)
Launch the CLI pointing at your repo plugin roots:

```powershell
claude --plugin-dir "C:\Work\Dev\ClaudeCodeDev\sapdev-ai\sap-dev\plugins\sap-dev-core" `
       --plugin-dir "C:\Work\Dev\ClaudeCodeDev\sapdev-ai\sap-dev\plugins\sap-gen-code"
```

- `--plugin-dir` loads **in place** (no cache copy), so edits are live.
- It **shadows** the marketplace-installed version for that session only;
  launch without the flag → back to the cached version. No uninstall needed.
- Point each flag at a **plugin root** (the dir containing
  `.claude-plugin/plugin.json`). Loading both as siblings preserves
  `sap-gen-code`'s cross-plugin path resolution (`<3-levels-up>/sap-dev-core/
  shared`), which assumes both plugins sit under a common parent.
- Confirm the flag exists on your build: `claude --help` (look for
  `--plugin-dir`). `--bare` disables it.

**Reload matrix inside a `--plugin-dir` session:**

| You edited… | Takes effect | Action |
|---|---|---|
| `.ps1` / `.vbs` (SAP-driving logic) | next invocation | re-run the skill (subprocess reads disk fresh) |
| `SKILL.md` instruction body | next invocation | re-run the skill |
| `SKILL.md` frontmatter (name/description/triggers), a **new** skill, `agents/`, `hooks/`, `.mcp.json` | after reload | `/reload-plugins` (or new session) |

> `/reload-plugins` re-reads from wherever the session is *already* pointed — it
> does **not** switch cache↔repo. You must already be in a `--plugin-dir`
> session for it to pick up repo edits. Check the active path with `/plugin`.

### Tier 2 — pre-publish smoke (do once)
When it works under `--plugin-dir`, push → bump version → update the marketplace
install → run once from the **real cache**. This is the only tier that exercises
install-path-specific behaviour (version-folder `settings.local.json`, token
substitution, path resolution) that a `--plugin-dir` run can mask.

---

## Desktop app vs. CLI

**All desktop sessions/windows share one global config** — there is no
per-session isolation. Every desktop conversation reads the same `~/.claude/`
(installed plugin version, cache, `settings.json`, MCP servers) and the same
`{work_dir}\runtime\connections.json`. That config is also shared with the CLI
on the same machine.

**The desktop app has no `--plugin-dir` equivalent** (it's a CLI launch flag).
Consequences for a desktop-primary developer:

- Run the dev loop in a **parallel CLI terminal** via `--plugin-dir`. That
  terminal is a separate, isolated process — it does **not** affect any desktop
  session, which keep running the stable cached version for real work.
- The only in-desktop dev route is dropping a plugin under
  `~/.claude/skills/<name>/` (auto-loads; `/reload-plugins` refreshes). Avoid it
  here: it's **global** across all desktop sessions (because they share config),
  and a same-named entry can **collide** with the marketplace-installed
  `sap-dev-core`. Prefer the CLI terminal.

| Scenario | Desktop app | CLI |
|---|---|---|
| Test repo edits for one session (isolated) | ❌ — use a parallel CLI terminal | ✅ `claude --plugin-dir …` |
| Auto-load a dev plugin every session (global) | ✅ `~/.claude/skills/<name>/` (collision risk here) | ✅ same, or `--plugin-dir` |
| Refresh edits without restart | ✅ `/reload-plugins` | ✅ `/reload-plugins` |

---

## Recommended launcher

Add `scripts/run-local.ps1` so the dev session is one command:

```powershell
# scripts/run-local.ps1 — run Claude with the local plugins live (in-place)
# Usage:  pwsh ./scripts/run-local.ps1
# Then, in-session: edit .ps1/.vbs -> just re-invoke; edit SKILL.md frontmatter -> /reload-plugins
claude --plugin-dir "$PSScriptRoot\..\plugins\sap-dev-core" `
       --plugin-dir "$PSScriptRoot\..\plugins\sap-gen-code" @args
```

Run it from a terminal even if you normally use the desktop app — see above.

---

## Implemented (PowerShell, verified)

1. **`SAPDEV_AI_WORK_DIR` env var** is the highest-priority source for `work_dir`
   in `Get-SapWorkDir` (`sap_connection_lib.ps1`) and `Get-SapWorkDirBootstrap`
   (`sap_settings_lib.ps1`). Set it once at the OS user level (then restart the
   host so child processes inherit it) and the one load-bearing bootstrap value —
   and therefore all stable state under `work_dir` — is immune to plugin updates.
   (Naming note: other env vars use a bare `SAPDEV_` prefix —
   `SAPDEV_SESSION_PATH`, `SAPDEV_RUN_ID`; this one adds an `_AI_` infix by choice
   to match the product name.)

2. **`{work_dir}\runtime\userconfig.json`** — stable, outside-the-cache home for
   all machine-global user overrides (`custom_url`, `log_*`, `fm_cache_*`,
   `template_language`, …), sibling to `connections.json`, and the **single skill
   write target** (`Set-SapUserSetting`). Read-merge precedence (git-style,
   most-specific wins): env var (`work_dir` only) > `settings.local.json` (dev
   checkout, on top) > `userconfig.json` (machine-global base) > `settings.json`
   (schema). End users have no `settings.local.json`, so `userconfig.json` is
   authoritative for them; a developer's checkout-local `settings.local.json`
   overrides it only under `--plugin-dir`. `work_dir` is bootstrap-only and is
   never read from `userconfig.json`.

> **No VBS settings library.** A `sap_settings_lib.vbs` twin once existed but
> never compiled (its `_`-prefixed helper subs were illegal VBScript
> identifiers) and was never wired into any skill, so it was removed
> (2026-06-01). Settings are PowerShell-only: a VBS that needs a userConfig
> value receives it pre-resolved from its PowerShell wrapper via `%%TOKEN%%`
> substitution or an environment variable.

## Still proposed (not implemented)

3. **Cross-version migration of `settings.local.json`** — largely obsolete now
   that user config lives in `userconfig.json` (outside the cache, survives
   updates). Only still relevant for carrying a developer's *checkout* override
   between version folders, which `--plugin-dir` sidesteps anyway.

4. **Retire `settings.local.json` for end users** — effectively achieved by (2):
   end-user writes go to `userconfig.json`; `settings.local.json` is now only the
   dev checkout override (its original git-hygiene job).

Blast radius was small as predicted: reads/writes funnel through
`sap_settings_lib.ps1` (the sole chokepoint) plus `Get-SapWorkDir` in
`sap_connection_lib.ps1`. The VBS helper and the inline resolver in
`sap_log_lib.vbs` remain on the old two-file model pending the VBS fix above.
