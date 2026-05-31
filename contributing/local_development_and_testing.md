# Local Development & Testing (cache vs. repo, config locations, fast inner loop)

**Applies to**: anyone editing this repo's plugin source
(`plugins/sap-dev-core`, `plugins/sap-gen-code`, …) who wants to test changes
against a live SAP system before publishing.

**Audience**: plugin developers (Role 1). This doc is *not* shipped to end
users and has no runtime callers — it lives in `contributing/` for the same
reason as `parallel_safe_session_attach.md`.

**Status**: the **Current behaviour** sections describe how the shipped code
(v0.3.x) actually works and were verified on a live install. The **Proposed
improvements** section at the end is design-only — none of it is implemented
yet. Don't cite it as fact.

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
installPath : C:\Users\<you>\.claude\plugins\cache\sap-dev\sap-dev-core\0.3.1
version     : 0.3.1
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

Three distinct locations. Knowing which is which removes 90% of "why didn't my
change take effect" confusion.

| File | Location | Tracked? | Version-dependent? | Role |
|---|---|---|---|---|
| `settings.json` | `<plugin-root>/settings.json` (cache **or** repo) | yes | yes (in cache) | **Schema** — key names, descriptions, `sensitive` flags, default values. Read-only at runtime. |
| `settings.local.json` | `<plugin-root>/settings.local.json` | **no** (gitignored) | **yes (in cache)** | Per-developer overrides. Resolved *relative to the running plugin root* by `sap_settings_lib.ps1` (`Resolve-SapSettingsPaths`). |
| `connections.json` | `{work_dir}\runtime\connections.json` | no | **no** — outside the plugin tree | SAP connection profiles (DPAPI-encrypted passwords) + per-connection `dev_defaults` (TR / package / FG). Survives plugin updates. |

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
  Today `work_dir` is resolved by `Get-SapWorkDir` from settings (default
  `C:\sap_dev_work`). If you set a custom `work_dir` *only* in a cache
  `settings.local.json`, a plugin update silently reverts it to the default and
  the new version looks for `connections.json` in the wrong place.

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
becomes live under `--plugin-dir`. Layer them like git config: env (future) >
checkout-local (`settings.local.json`) > machine-global (`connections.json` /
proposed `userconfig.json`) > schema defaults.

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

Add `scripts/dev.ps1` so the dev session is one command:

```powershell
# scripts/dev.ps1 — run Claude with the local plugins live (in-place)
# Usage:  pwsh ./scripts/dev.ps1
# Then, in-session: edit .ps1/.vbs -> just re-invoke; edit SKILL.md frontmatter -> /reload-plugins
claude --plugin-dir "$PSScriptRoot\..\plugins\sap-dev-core" `
       --plugin-dir "$PSScriptRoot\..\plugins\sap-gen-code" @args
```

Run it from a terminal even if you normally use the desktop app — see above.

---

## Proposed improvements (NOT yet implemented — design only)

These came out of the dev-experience discussion and are recorded here so they're
not re-derived. **None are in the code yet.** Do not treat as current behaviour.

1. **`SAPDEV_AI_WORK_DIR` env var** as the highest-priority source for
   `work_dir` in `Get-SapWorkDir`. Set once at the OS user level (then restart
   the host so child processes inherit it). Makes the one load-bearing bootstrap
   value immune to plugin updates; all stable state under `work_dir` then
   follows reliably. (Note: existing env vars use a bare `SAPDEV_` prefix —
   `SAPDEV_SESSION_PATH`, `SAPDEV_RUN_ID`; `SAPDEV_AI_WORK_DIR` adds an `_AI_`
   infix to match the product name. Document the chosen name once.)

2. **`{work_dir}\runtime\userconfig.json`** — a stable, outside-the-cache home
   for *all* end-user overrides (`custom_url`, `log_*`, `fm_cache_*`,
   `template_language`, …), sibling to `connections.json`. Read order would
   become: env var → `userconfig.json` → `settings.local.json` (dev/checkout
   only) → `settings.json` defaults. With this, nothing an end user customises
   lives in the versioned cache.

3. **Cross-version migration** — on first read where the current
   `settings.local.json` is absent, copy forward the newest sibling-version
   `settings.local.json` (one-shot, sentinel-guarded so a deliberate reset
   isn't clobbered). A cheap bridge; becomes unnecessary once (2) lands.

4. **Retire `settings.local.json` for end users.** Its only real job is
   *developer git hygiene* (gitignored override in a checkout). End users have
   no git, and writing mutable user state into a tool-managed versioned cache is
   an anti-pattern. Keep it as a checkout-only dev override; move the end-user
   override layer to (1) + (2).

Blast radius for all of the above is small: reads/writes funnel through
`sap_settings_lib.ps1` / `.vbs` (the helper is the sole chokepoint), plus one
hardcoded path in `sap_log_lib.vbs` and the `Get-SapWorkDir` resolver in
`sap_connection_lib.ps1`.
