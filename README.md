# SAP Dev Skills

SAP development automation skills for AI coding assistants.

> These skills follow Claude Code plugin patterns and are optimized for the
> Claude Code CLI. While the underlying skill content can be adapted for other
> AI harnesses, they are not automatically usable outside Claude Code without
> extraction and modification.

Project home: <https://sapdev.ai>

## Available Plugins (3 plugins · 49 skills · 1 agent · v0.2.0)

| Plugin | Skills | Description |
|--------|--------|-------------|
| **sap-dev-core** | 36 + agent | Foundation. **Multi-profile login** (DPAPI-encrypted credentials per SAP system, AI-session pin so each Claude conversation drives one SAP), TR resolution, package / function-group management, ABAP Workbench (SE38 / SE37 / SE24 / SE11 / SE91 / SE16N / SE21 / SE01 / SE19 / SE41 / SE51 / SE54 / SNRO / SP02 / CMOD), 4-stage ATC quality gate, standalone activator, package mover, where-used list, RFC wrapper generators, BDC executor, GUI recording / inspection / visual diagnostics, **skill-authoring tooling** (`gui-probe` + `gui-skill-scaffold` — probe an unknown transaction with natural-language scenarios → scaffold a working skill draft), structured logging, log analysis, dev-env lifecycle (init / status / clean), **session broker** for parallel execution against multiple SAP sessions. Ships the **`abap-developer` agent** (BUILD / FIX / DEPLOY) that reads your Customer Brief and orchestrates the skills. |
| **sap-gen-code** | 10 | Spec → ABAP pipeline. Customise spec-template layout per customer, extract from Excel / Word / PDF, normalise via customer rules, validate DDIC and process, generate ABAP per Customer Brief profile (with FM-signature pre-fetch + per-system cache), validate naming / types / SQL / FM args via live RFC, auto-fix detected issues. |
| **sap-tcd** | 3 | Business process automation: Business Partner (BP), Material Master (MM01 / MM02 / MM03), Sales Order (VA01 / VA02 / VA03). |

## Repository Structure

```
sap-dev/
├── .claude-plugin/
│   └── marketplace.json          # Marketplace catalog
├── plugins/
│   ├── sap-dev-core/             # Plugin: foundation + ABAP Workbench
│   │   ├── .claude-plugin/       # Plugin manifest (plugin.json)
│   │   ├── shared/               # Shared resources for all sap-dev plugins
│   │   │   ├── tables/           # Naming rules, DDIC types, conversion rules (TSV)
│   │   │   ├── scripts/          # Reusable PS1 / VBS helpers
│   │   │   ├── rules/            # AI guidance conventions (mandatory)
│   │   │   └── templates/        # Customer Brief, sample spec layouts
│   │   └── skills/               # 36 skills
│   ├── sap-gen-code/             # Plugin: spec → ABAP
│   └── sap-tcd/                  # Plugin: business transactions
├── schemas/
│   ├── marketplace.schema.json   # Schema for marketplace.json
│   └── plugin.schema.json        # Schema for plugin.json
├── tools/                        # Build helpers (regenerate sample spec, etc.)
├── package.json
└── README.md
```

## Installation

Add the marketplace to Claude Code:

```bash
# Add the marketplace
/plugin marketplace add https://github.com/sapdev-ai/sap-dev

# Install the core plugin (others are optional)
/plugin install sap-dev-core@sap-dev
```

After install, run once per SAP system:

```text
/sap-login --add     # Save a SAP connection profile (DPAPI-encrypted)
/sap-dev-init        # Bootstrap TR + package + function group + utility programs
```

Manage multiple saved profiles with `/sap-login --list`, `--switch <id>`,
`--set-default <id>`, `--delete <id>`. Each Claude Code conversation pins
to one profile; subagents inherit the pin.

See [docs/getting-started/installation.md](docs/getting-started/installation.md) for details.

## Prerequisites

- Windows 10 / 11 (SAP GUI Scripting is Windows-only)
- SAP GUI for Windows 7.70+ with scripting enabled
- Claude Code CLI
- (Optional) [SAP NCo 3.1](https://support.sap.com/en/product/connectors/msnet.html) for RFC features — see note below

## Building New Skills

Follow the monorepo structure:

1. Create a skill directory: `plugins/<plugin-name>/skills/<skill-name>/`.
2. Add `SKILL.md` and `README.md` to the skill directory.
3. Add the skill path to the plugin's `skills` array in `.claude-plugin/marketplace.json`.
4. Follow the [skill naming convention](CLAUDE.md#skill-naming-convention).
5. Validate with `npm run validate:marketplace`.

## License

This project is licensed under the GNU General Public License v3.0 — see the [LICENSE](LICENSE) file for details.

## Third-party software & legal notes

### SAP NCo 3.1 (not redistributed)

RFC-based skills require [SAP .NET Connector 3.1](https://support.sap.com/en/product/connectors/msnet.html), which must be downloaded by the customer from SAP Service Marketplace using their own S-User account. This project **does not redistribute SAP NCo binaries**. After installation, NCo must be present in the GAC.

### SAP licensing — indirect access

`sap-dev` invokes SAP through the standard GUI Scripting and RFC interfaces using the developer's own SAP Dialog user license. The plugin does not introduce indirect access for downstream systems, does not run as a service account, and does not cache SAP data outside the developer's workstation. Customers should still confirm with their SAP licensing team before deploying in any production-adjacent setting.

### SAP trademarks

SAP, ABAP, S/4HANA, NetWeaver, and related marks are trademarks of SAP SE in Germany and other countries. **This project is not affiliated with, endorsed by, or sponsored by SAP SE.** All references to SAP transactions and APIs are made for descriptive purposes only.

### No warranty

Per the GPL-3.0 license, this software is provided "as is" without warranty of any kind. Use against production systems at your own risk; always test against sandbox or development clients first.

## Contact

- Issues / discussions: <https://github.com/sapdev-ai/sap-dev/issues>
- Commercial enquiries: <hello@sapdev.ai>
- Project site: <https://sapdev.ai>
