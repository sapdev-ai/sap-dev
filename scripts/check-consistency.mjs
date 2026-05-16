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

// ---------------------------------------------------------------------------
// Tier 3 contract checks (added 2026-05-14 after the multi-connection migration):
//
// Every operational SAP-driving .vbs under plugins/<plugin>/skills/<skill>/references/
// MUST attach to its target session via the shared helper:
//
//   Const SESSION_PATH = "%%SESSION_PATH%%"
//   ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
//       .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
//   Set oSession = AttachSapSession(SESSION_PATH)
//
// The legacy `For Each oCandidate In oApp.Children / For Each oSessIter In ...`
// idiom silently grabs the first session of the first connection, which
// causes parallel skills to trample each other and multi-connection users
// to silently miss-target the wrong SAP system. Catch regressions at CI time.
//
// Exempt by design (these don't fit the helper's contract):
//   sap_login.vbs                       — bootstrap; runs before SAPGUI exists
//   sap_check_gui_login_status.vbs      — pre-flight probe
//   sap_gui_object_details.vbs          — own findById(SESSION_PATH) per Phase-1 fix
//   sap_gui_probe_action.vbs            — own action.json "session" field resolution
//   sap_login_capture_active_session.vbs — captures the just-logged-in session
//   sap_gui_security_warmup.vbs         — one-shot SAP-GUI-Security warmup; bootstrap
//   sap_attach_lib.vbs                  — the helper itself
//
// For SKILL.md PowerShell wrappers, every generator block that writes a
// runtime VBS via `Set-Content ... _run.vbs` should substitute %%ATTACH_LIB_VBS%%
// — but ONLY when the referenced template actually contains the token (i.e.
// it's a SAP-driving VBS that needs the helper). Non-SAP-driving VBS like
// sap-gen-code's `sap_check_abap.vbs` / `sap_check_fm.vbs` are static-analysis
// tools and don't need the helper.
// ---------------------------------------------------------------------------

const TIER3_EXEMPT_VBS = new Set([
  'sap_login.vbs',
  'sap_check_gui_login_status.vbs',
  'sap_gui_object_details.vbs',
  'sap_gui_probe_action.vbs',
  'sap_login_capture_active_session.vbs',
  'sap_gui_security_warmup.vbs',
  'sap_attach_lib.vbs',
]);

const LEGACY_ATTACH_PATTERNS = [
  /For\s+Each\s+oCandidate\s+In\s+oApp/i,
  /For\s+Each\s+oCandidate\s+In\s+oApplication/i,
  /For\s+Each\s+c\s+In\s+oApp\.Children/i,
  /For\s+Each\s+oC\s+In\s+oApp\.Children/i,
  /For\s+Each\s+oCand\s+In\s+oApp\.Children/i,
];

function listVbsTemplates(skillsDir) {
  const out = [];
  if (!existsSync(skillsDir)) return out;
  for (const skillEntry of readdirSync(skillsDir)) {
    const refDir = join(skillsDir, skillEntry, 'references');
    if (!existsSync(refDir)) continue;
    if (!statSync(refDir).isDirectory()) continue;
    for (const fname of readdirSync(refDir)) {
      if (!fname.endsWith('.vbs')) continue;
      out.push({ skill: skillEntry, file: fname, abs: join(refDir, fname) });
    }
  }
  return out;
}

for (const plugin of mp.plugins) {
  const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
  const sourceAbs = join(repoRoot, sourceRel);
  const skillsDir = join(sourceAbs, 'skills');
  const vbsFiles  = listVbsTemplates(skillsDir);

  for (const { skill, file, abs } of vbsFiles) {
    if (TIER3_EXEMPT_VBS.has(file)) continue;
    const body = readFileSync(abs, 'utf8');

    // 1. Legacy For-Each idiom must not appear.
    for (const re of LEGACY_ATTACH_PATTERNS) {
      if (re.test(body)) {
        warn(`${plugin.name}: ${skill}/${file} contains legacy attach idiom (${re.source}); migrate to AttachSapSession(SESSION_PATH) per shared/rules/sap_session_broker.md`);
        break;
      }
    }

    // 2. If SESSION_PATH is declared, ATTACH_LIB_VBS must also be included.
    const hasSessionPathConst = /Const\s+SESSION_PATH\s*=\s*"%%SESSION_PATH%%"/i.test(body);
    const hasAttachLibInclude = body.includes('%%ATTACH_LIB_VBS%%');
    if (hasSessionPathConst && !hasAttachLibInclude) {
      warn(`${plugin.name}: ${skill}/${file} declares Const SESSION_PATH but does not include %%ATTACH_LIB_VBS%%; AttachSapSession() will be undefined at runtime`);
    }

    // 3. If neither token is present, the file is unmigrated. Require migration.
    const looksOperational = /GetObject\("SAPGUI"\)/i.test(body) || /GetScriptingEngine/i.test(body);
    if (looksOperational && !hasSessionPathConst && !hasAttachLibInclude) {
      warn(`${plugin.name}: ${skill}/${file} drives SAP GUI but uses neither Const SESSION_PATH nor %%ATTACH_LIB_VBS%%; migrate per shared/rules/sap_session_broker.md (or add to TIER3_EXEMPT_VBS if intentionally bootstrap-only)`);
    }

    // 4. AttachSapSession must actually be called when the helper is included.
    if (hasAttachLibInclude && !/AttachSapSession\s*\(/.test(body)) {
      warn(`${plugin.name}: ${skill}/${file} includes %%ATTACH_LIB_VBS%% but never calls AttachSapSession(...); include is dead code`);
    }
  }

  // SKILL.md cross-check: if a SKILL.md wraps any VBS whose source contains
  // %%ATTACH_LIB_VBS%%, the SKILL.md MUST substitute that token. Only checks
  // SKILL.md files that wrap at least one SAP-driving template (i.e. one
  // whose source needs the helper) — exempt files and non-SAP-driving VBS
  // (sap-gen-code's static-analysis VBS, for example) are correctly skipped.
  if (existsSync(skillsDir)) {
    for (const skillEntry of readdirSync(skillsDir)) {
      const skillMdPath = join(skillsDir, skillEntry, 'SKILL.md');
      if (!existsSync(skillMdPath)) continue;
      const md = readFileSync(skillMdPath, 'utf8');

      // Which template VBS does this SKILL.md reference? Match both
      // forward-slash and backslash path separators.
      const referenced = [...md.matchAll(/references[\\/]([a-zA-Z0-9_]+\.vbs)/g)].map(m => m[1]);
      if (referenced.length === 0) continue;

      // For each referenced template, check whether its source needs ATTACH_LIB.
      const refDir = join(skillsDir, skillEntry, 'references');
      let anyNeedsAttach = false;
      for (const t of new Set(referenced)) {
        if (TIER3_EXEMPT_VBS.has(t)) continue;
        const tplPath = join(refDir, t);
        if (!existsSync(tplPath)) continue;
        const tplBody = readFileSync(tplPath, 'utf8');
        if (tplBody.includes('%%ATTACH_LIB_VBS%%')) {
          anyNeedsAttach = true;
          break;
        }
      }
      if (!anyNeedsAttach) continue;

      if (!md.includes('%%ATTACH_LIB_VBS%%')) {
        warn(`${plugin.name}: skills/${skillEntry}/SKILL.md wraps a SAP-driving template that needs %%ATTACH_LIB_VBS%% substitution, but the SKILL.md never substitutes it; the runtime VBS will fail to attach`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Phase 4 contract checks (added 2026-05-16 with the multi-profile +
// AI-session-pin work).
//
// SKILL.md wrappers that invoke `sap_session_broker.ps1 -Action acquire`
// SHOULD pass `-AiSessionId` so the broker's pin enforcement can refuse
// cross-connection acquires for the same AI session. The check is a soft
// warning rather than a hard error because some bootstrap-style skills
// (sap-dev-init, sap-login itself) legitimately call acquire/release
// before the AI-session-id file exists. The CI emits these as warnings
// surfaced in the output but does not fail the build on them.
//
// Skills using `release -WasCreated` MUST NOT separately call `-Action
// reset` or invoke RESET on the COM helper for the same session — that's
// double cleanup and risks killing a freshly spawned replacement session.
//
// Wrappers that drive SAP via cscript SHOULD set $env:SAPDEV_AI_SESSION_ID
// from the runtime\ai_session_id.txt file before launching cscript so
// the attach lib can record it in its diagnostic INFO line.
//
// Exempt from these checks: the same TIER3_EXEMPT_VBS files (bootstrap),
// plus the broker / connection / capture scripts themselves.
// ---------------------------------------------------------------------------

const PHASE4_BROKER_CALLERS_EXEMPT = new Set([
  // The skills that legitimately call broker BEFORE the AI session ID
  // is available (they are responsible for bootstrapping it).
  'sap-login',
  'sap-dev-init',
]);

const phase4Warnings = [];

for (const plugin of mp.plugins) {
  const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
  const sourceAbs = join(repoRoot, sourceRel);
  const skillsDir = join(sourceAbs, 'skills');
  if (!existsSync(skillsDir)) continue;

  for (const skillEntry of readdirSync(skillsDir)) {
    if (PHASE4_BROKER_CALLERS_EXEMPT.has(skillEntry)) continue;
    const skillMdPath = join(skillsDir, skillEntry, 'SKILL.md');
    if (!existsSync(skillMdPath)) continue;
    const md = readFileSync(skillMdPath, 'utf8');

    // 1. SKILL.md that mentions broker acquire SHOULD also mention -AiSessionId.
    const callsAcquire = /sap_session_broker\.ps1[^\n]*-Action[^\n]*acquire/i.test(md)
                       || /broker[^\n]*-Action[^\n]*acquire/i.test(md);
    const mentionsAiSessionId = /-AiSessionId/i.test(md) || /SAPDEV_AI_SESSION_ID/i.test(md);
    if (callsAcquire && !mentionsAiSessionId) {
      phase4Warnings.push(`${plugin.name}: skills/${skillEntry}/SKILL.md calls broker acquire but does not pass -AiSessionId / SAPDEV_AI_SESSION_ID; pin enforcement will not engage for this AI session`);
    }

    // 2. SKILL.md using release -WasCreated should not separately reset.
    const wasCreatedRelease = /-WasCreated\b/.test(md);
    const separateReset = /Reset-SessionToEasyAccess|COM helper[^\n]*RESET/i.test(md);
    if (wasCreatedRelease && separateReset) {
      phase4Warnings.push(`${plugin.name}: skills/${skillEntry}/SKILL.md combines release -WasCreated with an explicit RESET; release with -WasCreated already closes the session (or falls back to RESET when it is the last)`);
    }
  }
}

if (errors.length === 0) {
  let summary = `OK: ${mp.plugins.length} plugins, ${totalSkills} skills, all manifests aligned at version ${mp.version}, Tier 3 attach contract clean`;
  if (phase4Warnings.length > 0) {
    summary += `, ${phase4Warnings.length} Phase-4 warning(s)`;
  }
  console.log(summary);
  for (const w of phase4Warnings) console.warn('  WARN: ' + w);
  process.exit(0);
} else {
  console.error(`FAIL: ${errors.length} consistency issue(s):`);
  for (const e of errors) console.error('  - ' + e);
  if (phase4Warnings.length > 0) {
    console.error(`\nPhase-4 warnings (informational):`);
    for (const w of phase4Warnings) console.error('  WARN: ' + w);
  }
  process.exit(1);
}
