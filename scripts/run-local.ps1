# =============================================================================
# scripts/run-local.ps1 — launch Claude Code with the LOCAL plugins loaded
# in-place (no marketplace install, no cache copy), for fast dev iteration.
# =============================================================================
# Usage:
#   pwsh ./scripts/run-local.ps1                 # launch a dev session
#   pwsh ./scripts/run-local.ps1 --model opus    # extra args pass through
#
# Why: when sap-dev is installed from the marketplace, skills run from the
# versioned cache (~/.claude/plugins/cache/...), NOT this repo. --plugin-dir
# loads the plugin in place so your edits are live for that one session, and
# shadows the cached version without uninstalling it. Launch a normal `claude`
# (or restart the desktop app) to go back to the published version.
#
# In-session reload rules:
#   * edit a .ps1 / .vbs  -> just re-invoke the skill (read fresh from disk)
#   * edit SKILL.md frontmatter / a new skill / hooks / agents / .mcp.json
#                          -> run /reload-plugins (no need to relaunch)
#
# Desktop-app users: the desktop app has no --plugin-dir equivalent. Run this
# in a CLI terminal; it does not affect your desktop sessions (they keep using
# the stable cached version). See contributing/local_development_and_testing.md.
# =============================================================================

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

claude --plugin-dir (Join-Path $repoRoot 'plugins\sap-dev-core') `
       --plugin-dir (Join-Path $repoRoot 'plugins\sap-gen-code') `
       --plugin-dir (Join-Path $repoRoot 'plugins\sap-migrate') `
       --plugin-dir (Join-Path $repoRoot 'plugins\sap-project') @args
