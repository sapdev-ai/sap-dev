# SAP Dev Plugin Architecture

The **sap-dev** repository is a monorepo that hosts multiple Claude Code plugins. It uses a centralized marketplace system to manage and distribute these plugins and their associated skills.

## Structure

### Monorepo Layout
```
sap-dev/
├── .claude-plugin/
│   └── marketplace.json      # Central registry for the marketplace
├── plugins/
│   ├── <plugin-name>/        # Individual plugin directory
│   │   ├── .claude-plugin/   # Plugin manifest (plugin.json)
│   │   └── skills/           # Skill definitions for this plugin
│   │       └── <skill-name>/
│   │           ├── SKILL.md  # Main skill instructions
│   │           └── README.md # Optional human-facing docs (not used for discovery)
├── schemas/
│   ├── marketplace.schema.json # Validation for marketplace.json
│   └── plugin.schema.json      # Validation for plugin.json
```

## Marketplace System

The marketplace is defined by the `marketplace.json` file under the repo-root `.claude-plugin/` directory. This file acts as a catalog, listing all plugins available in the repository and their constituent skills.

### Registry (`marketplace.json`)
The registry provides:
- **Marketplace Metadata**: Versioning, ownership, and aggregate statistics.
- **Plugin Definitions**: Each entry in the `plugins` array defines:
  - `source`: The relative path to the plugin directory (e.g., `./plugins/sap-dev-core`).
  - `skills`: An array of relative paths to individual skill directories (e.g., `./skills/sap-se38`).
  - `version`: The semantic version of the plugin.

### Plugin Manifests (`plugin.json`)
Each plugin contains its own `plugin.json` in a `.claude-plugin` subdirectory. This manifest follows standard Claude Code plugin patterns, containing name, version, and description metadata.

## Skill Discovery

Skills are discovered by Claude Code from the `SKILL.md` YAML frontmatter (`name` + `description`).
- **SKILL.md**: Contains the frontmatter used for discovery/triggering plus the expert instructions and tool usage patterns for the skill.
- **README.md**: Optional human-facing documentation; plays no role in skill discovery or triggering (as of 2026-07-24 every one of the 123 skills happens to ship with one, but nothing requires it).

## Validation

The repository includes JSON schemas for both the marketplace registry and the plugin manifests.
- **Marketplace Validation**: `npm run validate:marketplace` uses `ajv` to ensure the registry matches the expected structure and links to valid skill paths.
- **Plugin Validation**: Ensures that individual plugin manifests are correctly formatted.

## Deployment & Installation

Users add the entire repository as a marketplace:
```bash
/plugin marketplace add <repo-url>
```
Once added, individual plugins can be installed by name:
```bash
/plugin install <plugin-name>@sap-dev
```
