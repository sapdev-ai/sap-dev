#!/usr/bin/env node
// Verifies marketplace.json against the filesystem and across manifests.
// Fails (exit 1) on:
//   - Skill directory exists on disk but is not registered in marketplace.json
//   - Skill registered in marketplace.json but directory or SKILL.md missing
//   - Plugin entry version disagrees with its plugins/<name>/.claude-plugin/plugin.json
//   - marketplace top-level version != metadata.version
//   - metadata.total_skills != actual sum across plugins
//   - metadata.total_plugins != number of plugin entries

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const mp = JSON.parse(readFileSync(join(repoRoot, '.claude-plugin/marketplace.json'), 'utf8'));

const errors = [];
const warn = (msg) => errors.push(msg);

if (mp.version !== mp.metadata.version) {
  warn(`marketplace top-level version (${mp.version}) != metadata.version (${mp.metadata.version})`);
}
if (mp.metadata.total_plugins !== mp.plugins.length) {
  warn(`metadata.total_plugins (${mp.metadata.total_plugins}) != actual plugin count (${mp.plugins.length})`);
}

let totalSkills = 0;
for (const plugin of mp.plugins) {
  const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
  const sourceAbs = join(repoRoot, sourceRel);

  // Plugin manifest version check.
  const manifestPath = join(sourceAbs, '.claude-plugin', 'plugin.json');
  if (!existsSync(manifestPath)) {
    warn(`${plugin.name}: missing plugin.json at ${manifestPath}`);
  } else {
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    if (manifest.version !== plugin.version) {
      warn(`${plugin.name}: plugin.json version (${manifest.version}) != marketplace entry version (${plugin.version})`);
    }
  }

  // Registered skills must exist with a SKILL.md.
  const registered = new Set();
  for (const skillRel of plugin.skills) {
    const rel = skillRel.replace(/^\.\//, '');
    const skillAbs = join(sourceAbs, rel);
    const skillName = rel.replace(/^skills\//, '');
    registered.add(skillName);
    if (!existsSync(skillAbs)) {
      warn(`${plugin.name}: registered skill missing on disk: ${skillRel}`);
      continue;
    }
    if (!existsSync(join(skillAbs, 'SKILL.md'))) {
      warn(`${plugin.name}: ${skillRel} has no SKILL.md`);
    }
  }
  totalSkills += plugin.skills.length;

  // Skills on disk that are NOT registered.
  const skillsDir = join(sourceAbs, 'skills');
  if (existsSync(skillsDir)) {
    for (const entry of readdirSync(skillsDir)) {
      const full = join(skillsDir, entry);
      if (!statSync(full).isDirectory()) continue;
      if (!registered.has(entry)) {
        warn(`${plugin.name}: skill directory not registered in marketplace.json: skills/${entry}`);
      }
    }
  }

  // Agents — registered must exist on disk; agents on disk should be registered.
  const registeredAgents = new Set();
  for (const agentRel of plugin.agents ?? []) {
    const rel = agentRel.replace(/^\.\//, '');
    const agentAbs = join(sourceAbs, rel);
    registeredAgents.add(rel.replace(/^agents\//, ''));
    if (!existsSync(agentAbs)) {
      warn(`${plugin.name}: registered agent missing on disk: ${agentRel}`);
    }
  }
  const agentsDir = join(sourceAbs, 'agents');
  if (existsSync(agentsDir)) {
    for (const entry of readdirSync(agentsDir)) {
      if (!entry.endsWith('.md')) continue;
      if (!registeredAgents.has(entry)) {
        warn(`${plugin.name}: agent file not registered in marketplace.json: agents/${entry}`);
      }
    }
  }
}

if (mp.metadata.total_skills !== totalSkills) {
  warn(`metadata.total_skills (${mp.metadata.total_skills}) != sum across plugins (${totalSkills})`);
}

if (errors.length === 0) {
  console.log(`OK: ${mp.plugins.length} plugins, ${totalSkills} skills, all manifests aligned at version ${mp.version}`);
  process.exit(0);
} else {
  console.error(`FAIL: ${errors.length} consistency issue(s):`);
  for (const e of errors) console.error('  - ' + e);
  process.exit(1);
}
