# Contributing to sap-dev

Thanks for your interest. The full design rationale lives in `CLAUDE.md`; this
file is the human-oriented short version.

## First-time setup (per developer)

Personal SAP credentials for a dev checkout live in
`plugins/sap-dev-core/settings.local.json`, which is gitignored and is only
ever hand-edited (or written by `dev-setup.ps1`). The tracked `settings.json`
is the schema only — all its `value` fields are blank. Reads merge per key:
`settings.local.json` > `{work_dir}\runtime\userconfig.json` >
`settings.json`; **skill writes always target `userconfig.json`**, never the
local file or the schema. See `docs/settings-local-faq.md` for the full Q&A.

After cloning, run **one** of:

```powershell
# Option A — guided bootstrap (recommended)
pwsh ./scripts/dev-setup.ps1
# Prompts for server / system / client / user / password / language;
# DPAPI-encrypts the password; writes everything to settings.local.json.

# Option B — let /sap-login build the file interactively
#   (inside Claude Code)
/sap-login

# Option C — copy the schema and edit by hand
copy plugins\sap-dev-core\settings.json plugins\sap-dev-core\settings.local.json
notepad plugins\sap-dev-core\settings.local.json
```

To re-prompt for every field (e.g., switching SAP systems):
`pwsh ./scripts/dev-setup.ps1 -Force`.

## Repository layout

```
sap-dev/
├── .claude-plugin/marketplace.json   Central catalog of plugins + skills
├── plugins/<plugin>/
│   ├── .claude-plugin/plugin.json    Plugin manifest
│   ├── settings.json                 Optional userConfig schema
│   ├── shared/                       (sap-dev-core only) cross-plugin assets
│   └── skills/<skill>/
│       ├── SKILL.md                  Expert instructions for the AI
│       └── README.md                 Discovery metadata
├── schemas/                          JSON Schemas for both manifests
├── scripts/                          Repository-level checks
└── tools/                            Python helpers (e.g. sample spec gen)
```

## Adding a new skill

1. Pick a name. **Every skill must be prefixed with `sap-`** (kebab-case, single
   dashes, no duplicate prefixes). Reuse an existing sub-namespace where one
   fits — `sap-docs-*`, `sap-check-*` / `sap-fix-*`, `sap-cc-*`,
   `sap-gui-*`, `sap-se##*`. See `CLAUDE.md` § Skill Naming Convention.
2. Create the directory under `plugins/<plugin>/skills/<skill-name>/`.
3. Add `SKILL.md` (the AI-facing instructions) and `README.md` (discovery
   keywords). Look at any neighbouring skill for the expected sections —
   YAML frontmatter, `## Shared Resources`, numbered `## Step N` blocks,
   `## Final — Log End`.
4. **If the skill writes to SAP**, observe the mandatory rules:
   - `shared/rules/skill_operating_rules.md` — no direct SQL on standard
     tables, no unsolicited deploys.
   - `shared/rules/tr_resolution.md` — delegate transport-request resolution
     to `/sap-transport-request`; never prompt the user yourself.
   - `shared/rules/language_independence_rules.md` — identify GUI controls
     by ID + DDIC field name, never by displayed text.
5. Register the skill in `.claude-plugin/marketplace.json` under the
   appropriate plugin's `skills` array. Keep the array alphabetically sorted
   and update `metadata.total_skills`.
6. Run `npm run validate` and fix any reported issues.

## Modifying shared resources

Anything under `plugins/sap-dev-core/shared/` is consumed by other plugins.
Treat it as a public contract: rename → bump version, add new keys
non-breakingly, document the change in `CLAUDE.md` § Current Shared Files.

## Validation

- `npm run validate:marketplace` — schema-validates `.claude-plugin/marketplace.json`.
- `npm run check:consistency` — verifies every skill directory is registered,
  every registered skill exists with a `SKILL.md`, and all manifest versions
  agree.
- `npm run validate` — runs both.

The project website is maintained **outside this repository** (a sibling
`website/` workspace) and carries its own i18n check there
(`npm run check:i18n` / `node scripts/check-i18n.mjs` — verifies the locale
files share the same key structure). Nothing website-related is validated
from this repo.

## Reserved words

Marketplace and plugin `name`/`description` fields MUST NOT contain
`official`, `anthropic`, or `claude`. The Claude Code CLI rejects these to
prevent marketplace impersonation.

## Versioning

Single source of truth: `.claude-plugin/marketplace.json` `version` ===
`metadata.version`. Each plugin entry's version must equal that plugin's
`.claude-plugin/plugin.json` `version`. The consistency check enforces this.

## License

This repository is licensed under GPL-3.0. By contributing you agree your
contributions will be released under the same license.
