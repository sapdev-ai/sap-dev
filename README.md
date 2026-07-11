# SAP Dev Skills

SAP development automation skills for AI coding assistants. **Windows-only**
— the skills drive SAP GUI for Windows via GUI Scripting (plus optional RFC
via SAP NCo); there is no macOS/Linux path.

> These skills follow Claude Code plugin patterns and are optimized for the
> Claude Code CLI. While the underlying skill content can be adapted for other
> AI harnesses, they are not automatically usable outside Claude Code without
> extraction and modification.

Project home: <https://sapdev.ai>

## Available Plugins (4 plugins · 123 skills · 3 agents · v0.7.2)

| Plugin | Skills | Description |
|--------|--------|-------------|
| **sap-dev-core** | 61 + agent | Foundation. **Multi-profile login** (DPAPI-encrypted credentials per SAP system, AI-session pin so each Claude conversation drives one SAP), TR resolution, package / function-group management, ABAP Workbench (SE38 / SE37 / SE24 / SE11 / SE91 / SE16N / SE21 / SE01 / SE19 / SE41 / SE51 / SE54 / SNRO / SP02 / CMOD), 4-stage ATC quality gate, ABAP Unit runner, **report execution + variant maintenance** (`sap-run-report` — SA38 foreground/background, confirm-gated), **background-job lifecycle** (`sap-job` — SM36/SM37 + RFC fast-path), **PC ↔ app-server file transfer** (`sap-file-transfer` — CG3Z/CG3Y + RFC `list`/`exists`), standalone activator, package mover, where-used list, RFC wrapper generators, BDC executor, GUI recording / inspection / visual diagnostics, **skill-authoring tooling** (`gui-probe` + `gui-skill-scaffold` — probe an unknown transaction with natural-language scenarios → scaffold a working skill draft), **incident diagnosis + repair** (`sap-diagnose` orchestrator over ST22 / SM13 / SM12 / SLG1 / SM37 readers + performance-trace analysis, with `sap-fix-incident` closing the loop from a root cause to a test-verified custom-code fix deployed in DEV behind a transport — gated, never touching standard code or production), **delivery assurance** (transport-readiness release gate, impact analysis, enhancement advisor, evidence pack), **transport landscape movement** (`sap-stms` — read import queues / logs, and import a released TR through DEV→QAS→PRD with tiered confirmation and a typed-SID production gate), cross-system object compare / explain, structured logging, log analysis, dev-env lifecycle (init / status / clean), **environment doctor** (`sap-doctor` — read-only preflight across GUI scripting, NCo/config, RFC connectivity, client modifiability, and dev-env artefacts, with an actionable FIX per failure; the opt-in `--screens` group replays per-VBS golden-screen baselines against the live system to catch release/locale control-ID drift before a silent false-success), **session broker** for parallel execution against multiple SAP sessions. Ships the **`abap-developer` agent** (BUILD / FIX / DEPLOY) that reads your Customer Brief and orchestrates the skills. |
| **sap-gen-code** | 12 | Spec → ABAP pipeline. Customise spec-template layout per customer, extract from Excel / Word / PDF, normalise via customer rules, validate DDIC and process, generate ABAP per Customer Brief profile (with FM-signature pre-fetch + per-system cache), validate naming / types / SQL / FM args via live RFC, auto-fix detected issues. |
| **sap-migrate** | 10 + agent | S/4HANA custom-code migration engine. Run a brownfield conversion as a tracked campaign (`sap-cc-campaign`): inventory custom (Z/Y) objects, overlay runtime usage to flag unused code for decommission, run the S/4HANA-readiness ATC, triage findings into remediation tiers, and auto-remediate mechanical (R1) changes on a sandbox. Ships the **`cc-migration-engineer` agent**. Companion to sap-dev-core (install that first). |
| **sap-project** | 40 + agent | Functional / operations delivery for consultants, integration, security, release, and AMS teams. Test data (Business Partner, Material Master, Sales Order), authorizations & roles, incident & interface diagnosis (IDoc / output / RFC queues / document flow), release & transport ops, config compare, health checks, and regression testing. Absorbed the former sap-tcd skills. Ships the **`sap-consultant` agent**. Companion to sap-dev-core. |

## Skill Index

All 123 skills, grouped by task (all names are `/`-invocable in Claude Code;
skills outside sap-dev-core are tagged with their plugin):

- **Session & environment** — `sap-login`, `sap-doctor` (incl. `--screens`
  golden-screen drift), `sap-dev-init`, `sap-dev-status`, `sap-dev-clean`
- **ABAP Workbench deploy & lifecycle** — `sap-se38` (programs), `sap-se37`
  (function modules), `sap-se24` (classes), `sap-se11` (DDIC), `sap-se14`
  (DB adjust / activate), `sap-se91` (message classes), `sap-function-group`,
  `sap-se21` (packages), `sap-se41` (GUI statuses), `sap-se51` (screens),
  `sap-se54` (table maintenance), `sap-snro` (number ranges), `sap-cmod`,
  `sap-se19` (BAdIs), `sap-vofm` (VOFM routines), `sap-activate-object`,
  `sap-change-package`, `sap-check-fix`
- **Transport** — `sap-transport-request`, `sap-se01`, `sap-stms`,
  `sap-transport-readiness`
- **Quality gates** — `sap-atc`, `sap-run-abap-unit`, `sap-check-abap` /
  `sap-fix-abap` (naming · types · SQL · CALL FUNCTION · compiler syntax);
  plus `sap-review-abap`, `sap-gen-abap-unit` (sap-gen-code)
- **Data & object insight** — `sap-se16n`, `sap-sql-query` (SELECT over RFC),
  `sap-update-addon`, `sap-where-used-list`, `sap-compare`, `sap-explain-object`
  (`--spec` emits a formal spec document), `sap-version-history`, `sap-git`
  (serialize repository objects to git), `sap-forms` (SmartForms / SAPscript /
  Adobe inventory + parse), `sap-sp02` (spool)
- **Report execution & jobs** — `sap-run-report` (foreground/background run +
  variant maintenance, confirm-gated), `sap-scratch-run` (ad-hoc ABAP snippet),
  `sap-job` (background-job schedule / monitor / cancel), `sap-file-transfer`
  (PC ↔ app-server files + `list`/`exists`)
- **Incident diagnosis & ops** — `sap-diagnose` (the SM13 / SM12 / SLG1 / SM37
  RFC readers are built in — run one standalone with `--reader <name>`),
  `sap-st22`, `sap-sm12` (lock entries), `sap-trace`, `sap-log-analyze`,
  `sap-fix-incident`
- **Delivery assurance** — `sap-impact-analysis`, `sap-evidence-pack`,
  `sap-enhancement-advisor`, `sap-api-advisor` (released-API guidance)
  (+ `sap-transport-readiness` above)
- **RFC & batch input** — `sap-rfc-wrapper` (fm + class modes),
  `sap-call-bdc`
- **Skill authoring & error KB** — `sap-gui-probe` (`--record` captures a
  flow by hand), `sap-gui-inspect`, `sap-gui-skill-scaffold`, `sap-error-kb`
- **Spec → ABAP pipeline (sap-gen-code)** — `sap-docs-layout`,
  `sap-docs-extract`, `sap-docs-convert`, `sap-docs-check` (DDIC + process
  dimensions), `sap-docs-estimate`, `sap-gen-abap`, `sap-gen-abap-unit`,
  `sap-gen-cds` (CDS views), `sap-gen-rap` (RAP business objects),
  `sap-gen-idoc-handler`, `sap-gen-test-plan`, `sap-review-abap` (ABAP
  check/fix moved to sap-dev-core: `sap-check-abap`, `sap-fix-abap`)
- **S/4HANA migration (sap-migrate)** — `sap-cc-campaign`, `sap-cc-inventory`,
  `sap-cc-usage`, `sap-cc-analyze`, `sap-cc-triage` (incl. `--learn` flywheel),
  `sap-cc-remediate`, `sap-cc-decommission`, `sap-cc-cloud-readiness`,
  `sap-spau-triage` (SPAU note adjustment), `sap-exit-modernize` (customer
  exit → BAdI)
- **Functional & operations (sap-project)** — ships the **`sap-consultant`
  agent** that orchestrates these across six lanes:
  - *Test data & regression* — `sap-bp`, `sap-mm01`, `sap-va01`, `sap-tcd-chain`
    (headless O2C document chain), `sap-fi-post`, `sap-golden-master`,
    `sap-mass-load`, `sap-test-replay`
  - *Incident & interface diagnosis* — `sap-doc-flow`, `sap-output-diagnose`,
    `sap-idoc`, `sap-rfc-monitor`, `sap-change-history`, `sap-sost`,
    `sap-workflow`, `sap-gateway-service`, `sap-interface-inventory`
  - *Authorizations & users* — `sap-auth-diagnose`, `sap-suim`,
    `sap-explain-role`, `sap-su01` (DEV-only), `sap-pfcg`, `sap-auth-requirements`
  - *Release & transport ops* — `sap-release-notes`, `sap-delivery-report`,
    `sap-transport-copies`, `sap-transport-sequencer`, `sap-refresh-verify`,
    `sap-cutover-runbook`, `sap-retrofit`, `sap-note-status`
  - *Config & customizing* — `sap-config-compare`, `sap-img-find`, `sap-sm30`,
    `sap-translate` (SE63), `sap-sm35` (batch input)
  - *Health & data* — `sap-health-check`, `sap-data-volume`
  - *Fiori & docs* — `sap-fiori-flp-audit`, `sap-user-guide`

## Current Limitations (v0.7.2)

Honest list of shipped-but-bounded functionality — these fail **loud**, not
silent:

- `/sap-doctor --fix` reports FIX recommendations only; it does not apply them.
- `/sap-run-abap-unit` is GUI-backed (Phase 1); the headless RFC backend is
  Phase 2. On a release whose result screen isn't recorded yet it emits
  `NEEDS_RECORDING` with instructions instead of guessing.
- `/sap-run-report` foreground list capture (`%PC`) is best-effort — ALV output
  needs the background→spool path (`/sap-sp02`). `/sap-job cancel` (abort a
  *running* job) is captured but not yet live-verified, and GUI job ops target
  by job NAME — exact-JOBCOUNT disambiguation is the RFC path's job.
- `/sap-stms` import ships with two uncalibrated checkbox IDs
  (immediate / leave-in-queue) — it refuses (`STMS_NOT_CALIBRATED`) until one
  `/sap-gui-probe --record` pass on your release wires them.
- Golden-screen baseline coverage is 126/127 driving scripts (1 unbaselined),
  but most are `pending_live` static seeds — drift detection is fully armed for a
  script only after a `/sap-doctor --screens` pass verifies its control-ID
  identity live on your release.
- sap-project test-data control IDs were recorded on S/4HANA 1909; `sap-bp` / `sap-va01`
  popups need a re-record for ECC6 (`sap-mm01` already probes both layouts).
- sap-migrate's knowledge pack ships 13 patterns (3 ACTIVE + 10 DRAFT;
  ~20–30% of typical ECC6 findings auto-classify today); DRAFT patterns are
  advisory-only by design, and the pack grows via `/sap-cc-triage --learn` from real
  campaign runs — no pattern carries harvested ATC message ids yet (regex +
  simplification-item matching until the flywheel fills them).
- Central/remote ATC (`--object-provider`) is implemented fail-loud but the
  provider field ID is unverified against a live hub.

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
│   │   └── skills/               # 61 skills
│   ├── sap-gen-code/             # Plugin: spec → ABAP
│   ├── sap-migrate/              # Plugin: S/4HANA custom-code migration
│   └── sap-project/              # Plugin: functional / operations delivery
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

# Install the core plugin FIRST (the other three require it)
/plugin install sap-dev-core@sap-dev
```

**Install order matters:** `sap-gen-code`, `sap-migrate`, and `sap-project` are
companions that resolve `sap-dev-core`'s `shared/` scripts at runtime —
installed alone, their skills fail with a path-resolution error. Always
install `sap-dev-core` first (or alongside).

After install, run once per SAP system:

```text
/sap-login --add     # Save a SAP connection profile (DPAPI-encrypted)
/sap-dev-init        # Bootstrap TR + package + function group + utility programs
```

Manage multiple saved profiles with `/sap-login --list`, `--switch <id>`,
`--set-default <id>`, `--delete <id>`. Each Claude Code conversation pins
to one profile; subagents inherit the pin.

**Changing settings later:** runtime values resolve
`SAPDEV_AI_WORK_DIR` env var → `settings.local.json` (repo checkouts only) →
`{work_dir}\runtime\userconfig.json` → the plugin's `settings.json`. Hand-edits
to the shipped `settings.json` are **silently shadowed** by `userconfig.json` —
change values through the skills or edit `userconfig.json`; see
[docs/settings-local-faq.md](docs/settings-local-faq.md).

See [docs/getting-started/installation.md](docs/getting-started/installation.md) for details,
or the end-to-end **[Developer's Manual](docs/manual.md)** —
a complete walkthrough from install to generating and deploying ABAP, with screenshots.

## Prerequisites

- Windows 10 / 11 (SAP GUI Scripting is Windows-only)
- SAP GUI for Windows 7.70+ with scripting enabled — **client-side** (SAP Logon
  option) AND **server-side** (`sapgui/user_scripting = TRUE` via RZ11; ask
  your Basis team — this is the #1 first-run blocker)
- Claude Code CLI
- Python 3.x on `PATH` — **required by sap-gen-code's `/sap-docs-extract`**
  (Excel/Word/PDF spec parsing); the core plugin works without it
- (Optional) [SAP NCo 3.1](https://support.sap.com/en/product/connectors/msnet.html) for RFC features — see note below
- Verify the machine with **`/sap-doctor`** after install — it preflights GUI
  scripting, NCo/GAC, RFC connectivity, and the dev environment with an
  actionable FIX per failing check
- Required SAP authorizations for the logon user: see
  [docs/security.md](docs/security.md)

## Building New Skills

Follow the monorepo structure:

1. Create a skill directory: `plugins/<plugin-name>/skills/<skill-name>/`.
2. Add `SKILL.md` and `README.md` to the skill directory.
3. Add the skill path to the plugin's `skills` array in `.claude-plugin/marketplace.json`.
4. Follow the [skill naming convention](CLAUDE.md#skill-naming-convention).
5. Validate with `npm run validate:marketplace` and `npm run check:consistency` (the latter fails if a skill directory is not registered in `marketplace.json`, or if any version / skill-count / plugin-count is out of sync).

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
