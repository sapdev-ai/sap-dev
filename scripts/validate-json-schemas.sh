#!/usr/bin/env bash
# Aggregates all repository validation steps.
# 1. Schema-validates marketplace.json via ajv-cli (npx if not installed locally).
# 2. Runs the filesystem/version consistency check.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Schema validation (marketplace.json)"
npx --yes -p ajv-cli@5 -p ajv-formats@3 ajv validate \
  -s schemas/marketplace.schema.json \
  -d .claude-plugin/marketplace.json \
  --strict=false -c ajv-formats --all-errors

echo
echo "==> Schema validation (plugin.json manifests)"
npx --yes -p ajv-cli@5 -p ajv-formats@3 ajv validate \
  -s schemas/plugin.schema.json \
  -d "plugins/*/.claude-plugin/plugin.json" \
  --strict=false -c ajv-formats --all-errors

echo
echo "==> Consistency check (filesystem vs marketplace.json + manifest versions)"
node scripts/check-consistency.mjs
