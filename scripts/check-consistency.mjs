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
import { join, dirname, resolve, basename } from 'node:path';
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
//   sap_close_connection.vbs            — closes a /app/con[N] by path (login family)
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
  'sap_close_connection.vbs',           // connection-level close-by-path helper
                                        // (login family); takes a /app/con[N]
                                        // path directly, no session attach.
  'sap_gui_security_warmup.vbs',
  'sap_attach_lib.vbs',
  // generic golden-screen inspector: self-resolves SESSION_PATH (Chr(37)
  // sentinel) like sap_gui_object_details.vbs, so it follows neither the attach
  // contract nor the baseline gate.
  'sap_screen_check_probe.vbs',
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
// Wrappers that drive SAP via cscript don't need to bootstrap an AI
// session id (Phase 4.1): the broker auto-resolves it via parent-PID
// walk on every acquire/release. If a wrapper wants to surface the id
// to the VBS for diagnostic logging, it can set $env:SAPDEV_AI_SESSION_ID
// to the value Get-SapAiSessionId returned — but it's optional.
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

// ---------------------------------------------------------------------------
// Non-ASCII source guard (added 2026-06-02).
//
// Windows PowerShell 5.1 — the runtime these skills invoke via
// C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe — and 32-bit
// cscript both read a BOM-less .ps1 / .vbs as the host ANSI codepage, NOT as
// UTF-8. A non-ASCII character in a string literal then mojibakes at runtime:
// this was hit for real when an em-dash (U+2014) in a literal in
// sap-migrate/.../sap_cc_usage.ps1 rendered as `窶・` in a generated scope.tsv.
// The project's discipline is ASCII source (e.g. sap_syntax_check_lib.vbs uses
// ChrW() to keep the runtime strings ASCII); a leading UTF-8 BOM (EF BB BF) is
// the explicit opt-in for the few files that genuinely need non-ASCII bytes.
//
// Scope: every shipped .ps1 / .vbs under each plugin's
// skills/<skill>/references/ plus sap-dev-core's shared/scripts/.
//
// Reported as an INFORMATIONAL warning, NOT a hard failure: the current tree
// carries pre-existing non-ASCII (em-dashes in comment headers and in
// WScript.Echo / Write-Host diagnostic strings, plus a handful of localized
// CJK comparison literals) that predate this guard. Surfacing offenders as
// warnings flags new regressions to contributors without breaking the build
// or forcing a tree-wide rewrite. Bytes are read raw (Buffer) so the BOM
// detection and the > 0x7F scan are not perturbed by any decoding assumption.
// ---------------------------------------------------------------------------

function listShippedScripts(sourceAbs) {
  const out = [];
  const pushDir = (dir, relPrefix) => {
    if (!existsSync(dir) || !statSync(dir).isDirectory()) return;
    for (const fname of readdirSync(dir)) {
      if (!/\.(ps1|vbs)$/i.test(fname)) continue;
      out.push({ rel: `${relPrefix}/${fname}`, abs: join(dir, fname) });
    }
  };
  // skills/<skill>/references/*.{ps1,vbs}
  const skillsDir = join(sourceAbs, 'skills');
  if (existsSync(skillsDir) && statSync(skillsDir).isDirectory()) {
    for (const skillEntry of readdirSync(skillsDir)) {
      if (!statSync(join(skillsDir, skillEntry)).isDirectory()) continue;
      pushDir(join(skillsDir, skillEntry, 'references'), `skills/${skillEntry}/references`);
    }
  }
  // shared/scripts/*.{ps1,vbs} (present for sap-dev-core; guarded for the rest)
  pushDir(join(sourceAbs, 'shared', 'scripts'), 'shared/scripts');
  return out;
}

const encodingWarnings = [];

for (const plugin of mp.plugins) {
  const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
  const sourceAbs = join(repoRoot, sourceRel);
  for (const { rel, abs } of listShippedScripts(sourceAbs)) {
    const buf = readFileSync(abs); // raw bytes — no text decoding
    // A leading UTF-8 BOM (EF BB BF) is the explicit opt-in for non-ASCII bytes.
    if (buf.length >= 3 && buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) continue;
    // Flag the first byte > 0x7F, with its 1-based line and decoded code point.
    let line = 1;
    for (let i = 0; i < buf.length; i++) {
      const b = buf[i];
      if (b === 0x0A) { line++; continue; }
      if (b > 0x7F) {
        const cp = buf.toString('utf8', i).codePointAt(0);
        const cpHex = 'U+' + cp.toString(16).toUpperCase().padStart(4, '0');
        encodingWarnings.push(`${plugin.name}: ${rel} has a non-ASCII byte at line ${line} (${cpHex}) without a UTF-8 BOM; Windows PowerShell 5.1 / cscript read BOM-less .ps1/.vbs as the ANSI codepage and will mojibake it at runtime — re-save as ASCII (e.g. '--' for an em-dash, ChrW() for runtime non-ASCII strings) or prepend a UTF-8 BOM if the non-ASCII is intentional`);
        break;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Golden-screen baseline coverage gate (added 2026-06-03).
//
// GUI-robustness initiative, half 1 (the static half). Every operational
// SAP-driving .vbs under skills/<skill>/references/ SHOULD ship a screen
// fingerprint baseline `<stem>.screens.json` recording the control IDs + screen
// identity (program/dynpro) it depends on at each checkpoint. /sap-gui-screen-
// check (the live half, not yet built) replays those baselines against a target
// release and fails loudly at the exact missing control — turning the repo's
// dominant "silent false-success after a screen/control moved" bug class into a
// pre-flight drift report. Contract: contributing/golden_screen_baselines.md.
//
// Two tiers, mirroring the non-ASCII guard's "don't break the build on
// pre-existing debt" stance:
//   * MISSING baseline   -> informational WARN (a ratcheting coverage metric).
//                           Promote to a hard error once coverage hits 100%.
//   * MALFORMED baseline -> HARD error. Safe: only fires on a baseline that was
//                           actually authored, so it cannot break today's tree.
// ---------------------------------------------------------------------------

const BASELINE_SCHEMA = 'sapdev.screenbaseline/1';
const baselineWarnings = [];
let baselineOperational = 0;
let baselinePresent = 0;

function validateScreenBaseline(pluginName, skill, vbsFile, jsonAbs) {
  const tag = `${pluginName}: ${skill}/${basename(jsonAbs)}`;
  let b;
  try { b = JSON.parse(readFileSync(jsonAbs, 'utf8')); }
  catch (e) { errors.push(`${tag} is not valid JSON: ${e.message}`); return; }

  if (b.schema !== BASELINE_SCHEMA) {
    errors.push(`${tag} has schema "${b.schema}"; expected "${BASELINE_SCHEMA}"`);
  }
  if (b.vbs !== vbsFile) {
    errors.push(`${tag} field vbs="${b.vbs}" does not match its paired template "${vbsFile}"`);
  }
  if (!b.captured_on || typeof b.captured_on !== 'object') {
    errors.push(`${tag} missing captured_on object {release, kernel, date, method}`);
  }
  if (!Array.isArray(b.checkpoints) || b.checkpoints.length === 0) {
    errors.push(`${tag} must have a non-empty checkpoints array`);
    return;
  }
  b.checkpoints.forEach((cp, i) => {
    const where = `${tag} checkpoint[${i}]`;
    if (!cp || typeof cp !== 'object') { errors.push(`${where} is not an object`); return; }
    if (!cp.id || typeof cp.id !== 'string') errors.push(`${where} missing string id`);
    const pending = cp.status === 'pending_live';
    if (cp.status !== 'captured' && cp.status !== 'pending_live') {
      errors.push(`${where} status must be "captured" or "pending_live"`);
    }
    if (!Array.isArray(cp.required_ids)) {
      errors.push(`${where} required_ids must be an array of findById paths`);
    } else if (!pending && cp.required_ids.length === 0) {
      errors.push(`${where} required_ids is empty but status is "captured"`);
    }
    if (!cp.identity || typeof cp.identity !== 'object') {
      errors.push(`${where} missing identity object {program, dynpro}`);
    } else if (!pending && (!cp.identity.program || !cp.identity.dynpro)) {
      errors.push(`${where} identity.program and identity.dynpro are required when status is "captured"`);
    }
  });
}

for (const plugin of mp.plugins) {
  const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
  const sourceAbs = join(repoRoot, sourceRel);
  const skillsDir = join(sourceAbs, 'skills');
  for (const { skill, file, abs } of listVbsTemplates(skillsDir)) {
    if (TIER3_EXEMPT_VBS.has(file)) continue;
    const body = readFileSync(abs, 'utf8');
    // A SAP-driving VBS is detected the way the Tier-3 contract describes it:
    // migrated templates declare Const SESSION_PATH + include the attach lib +
    // call AttachSapSession (the raw GetObject("SAPGUI") moved into
    // sap_attach_lib.vbs), while legacy/unmigrated ones still bind the
    // Scripting engine directly. Either way it drives a screen flow and needs a
    // baseline. Non-driving VBS (static-analysis tools etc.) are skipped.
    const isDriving =
      /Const\s+SESSION_PATH\s*=\s*"%%SESSION_PATH%%"/i.test(body) ||
      body.includes('%%ATTACH_LIB_VBS%%') ||
      /AttachSapSession\s*\(/.test(body) ||
      /GetObject\("SAPGUI"\)/i.test(body) ||
      /GetScriptingEngine/i.test(body);
    if (!isDriving) continue;
    baselineOperational++;
    const jsonAbs = join(dirname(abs), file.replace(/\.vbs$/i, '.screens.json'));
    if (existsSync(jsonAbs)) {
      baselinePresent++;
      validateScreenBaseline(plugin.name, skill, file, jsonAbs);
    } else {
      const want = file.replace(/\.vbs$/i, '.screens.json');
      baselineWarnings.push(`${plugin.name}: ${skill}/${file} has no screen baseline (${want}); /sap-gui-screen-check cannot detect release/locale drift for it — capture one per contributing/golden_screen_baselines.md`);
    }
  }
}

const baselineCoverage = `screen-baseline coverage ${baselinePresent}/${baselineOperational}` +
  (baselineWarnings.length > 0 ? ` (${baselineWarnings.length} unbaselined)` : '');

// ---------------------------------------------------------------------------
// Build-KPI gate-enrichment + Step-0 work_dir gates (added 2026-06-13 with the
// first-pass-yield metrics work).
//
// (a) The build-KPI aggregator (shared/scripts/sap_build_kpi.ps1) reconstructs
//     generated-ABAP builds from the JSONL logs and needs each gate skill to
//     stamp its verdict payload onto its own `## Final — Log End` end record via
//     a `-MetricsJson '{...}'` argument. The end record itself is already
//     guaranteed by Rule 4; this gate guards the enrichment so a future edit
//     cannot silently drop a gate's KPI fields. Contract:
//     shared/rules/build_metrics.md.
// (b) Step-0 work_dir resolution MUST be env-aware (CLAUDE.md Rule 7), never a
//     direct settings.json read that ignores SAPDEV_AI_WORK_DIR / userconfig.json.
//     Long-acknowledged gap; this is the static guard against a new skill
//     regressing it. There are TWO accepted env-aware forms:
//       1. Calling Get-SapWorkDir directly (the canonical one-liner the 49
//          non-onboarding skills use).
//       2. Routing through the onboarding helper sap_workdir_setup.ps1
//          (-Action probe), which calls Get-SapWorkDir internally (see that
//          script's 'probe' branch). The onboarding entry points /sap-login and
//          /sap-dev-init use this form because their Step 0 is a full
//          probe -> set / first-run-prompt / migrate flow, not a bare
//          resolution; inlining the one-liner would drop that onboarding logic.
//     Both honour the env var; a direct settings.json read references NEITHER
//     token, so the regression this guards against is still caught.
//
// Both are informational WARN (ratcheting), mirroring the non-ASCII / baseline
// gates: they surface regressions without breaking the build.
// ---------------------------------------------------------------------------

const LEDGER_GATE_SKILLS = new Set([
  'sap-gen-abap',
  'sap-check-abap',
  'sap-se38',
  'sap-se37',
  'sap-se24',
  'sap-atc',
  'sap-run-abap-unit',
]);

const ledgerWarnings = [];
const step0Warnings = [];
const runTempWarnings = [];

for (const plugin of mp.plugins) {
  const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
  const sourceAbs = join(repoRoot, sourceRel);
  const skillsDir = join(sourceAbs, 'skills');
  if (!existsSync(skillsDir)) continue;
  for (const skillEntry of readdirSync(skillsDir)) {
    const skillMdPath = join(skillsDir, skillEntry, 'SKILL.md');
    if (!existsSync(skillMdPath)) continue;
    const md = readFileSync(skillMdPath, 'utf8');

    // (a) Gate skills must pass -MetricsJson on their log-end block.
    if (LEDGER_GATE_SKILLS.has(skillEntry) && !md.includes('-MetricsJson')) {
      ledgerWarnings.push(`${plugin.name}: skills/${skillEntry}/SKILL.md is a build-KPI gate skill but its Final/Log-End block never passes -MetricsJson; the first-pass-yield aggregator will read this gate as n/a (shared/rules/build_metrics.md)`);
    }

    // (b) Skills with a Step-0 work-dir resolution must resolve it env-aware:
    //     Get-SapWorkDir directly, OR via the onboarding helper
    //     sap_workdir_setup.ps1 (which calls Get-SapWorkDir internally). See the
    //     header comment above for why the onboarding entry points use the helper.
    if (/Resolve Work Director/i.test(md)
        && !/Get-SapWorkDir/.test(md)
        && !/sap_workdir_setup\.ps1/.test(md)) {
      step0Warnings.push(`${plugin.name}: skills/${skillEntry}/SKILL.md has a Step 0 "Resolve Work Directory" but resolves work_dir via neither Get-SapWorkDir nor the env-aware onboarding helper sap_workdir_setup.ps1; resolve work_dir env-aware, not via a direct settings.json read (CLAUDE.md Rule 7)`);
    }

    // (c) Run-scoped temp isolation ({RUN_TEMP}). HARD ERROR: never point the
    //     session-attach plumbing at the per-run dir. Get-SapCurrentSessionPath
    //     -WorkTemp derives the durable runtime dir ({work_dir}\runtime, home of
    //     session_registry.json) from its PARENT, so passing {RUN_TEMP} there
    //     relocates the broker registry and breaks parallel-session coordination.
    //     Migrated skills keep the base '{WORK_TEMP}' on that call.
    if (/Get-SapCurrentSessionPath\s+-WorkTemp\s+'?\{RUN_TEMP\}'?/.test(md)) {
      errors.push(`${plugin.name}: skills/${skillEntry}/SKILL.md passes {RUN_TEMP} to Get-SapCurrentSessionPath -WorkTemp; that derives {work_dir}\\runtime from the parent and would relocate session_registry.json. Keep the base '{WORK_TEMP}' on that call; only the skill's own scratch goes under {RUN_TEMP}.`);
    }
    // (d) Ratcheting WARN: a skill still writing its generated *_run.vbs/.ps1 to
    //     the shared base {WORK_TEMP} is unmigrated -- two concurrent runs collide
    //     on that fixed name (generate-then-cscript TOCTOU -> wrong-object deploy).
    //     Move per-run scratch to {RUN_TEMP} (Get-SapRunTemp). Informational until
    //     full coverage, then promote to a hard error.
    if (/\{WORK_TEMP\}\\[^\s'"]*_run\.(?:vbs|ps1)/.test(md)) {
      runTempWarnings.push(`${plugin.name}: skills/${skillEntry}/SKILL.md writes a generated *_run.vbs/.ps1 under the shared base {WORK_TEMP}; move per-run scratch to {RUN_TEMP} (Get-SapRunTemp) so concurrent runs don't collide (CLAUDE.md "Work Directory Configuration")`);
    }
  }
}

if (errors.length === 0) {
  let summary = `OK: ${mp.plugins.length} plugins, ${totalSkills} skills, all manifests aligned at version ${mp.version}, Tier 3 attach contract clean`;
  if (phase4Warnings.length > 0) {
    summary += `, ${phase4Warnings.length} Phase-4 warning(s)`;
  }
  if (encodingWarnings.length > 0) {
    summary += `, ${encodingWarnings.length} non-ASCII warning(s)`;
  }
  if (ledgerWarnings.length > 0) {
    summary += `, ${ledgerWarnings.length} build-KPI warning(s)`;
  }
  if (step0Warnings.length > 0) {
    summary += `, ${step0Warnings.length} Step-0 warning(s)`;
  }
  if (runTempWarnings.length > 0) {
    summary += `, ${runTempWarnings.length} run-temp warning(s)`;
  }
  summary += `, ${baselineCoverage}`;
  console.log(summary);
  for (const w of phase4Warnings) console.warn('  WARN: ' + w);
  for (const w of encodingWarnings) console.warn('  WARN: ' + w);
  for (const w of ledgerWarnings) console.warn('  WARN: ' + w);
  for (const w of step0Warnings) console.warn('  WARN: ' + w);
  for (const w of runTempWarnings) console.warn('  WARN: ' + w);
  for (const w of baselineWarnings) console.warn('  WARN: ' + w);
  process.exit(0);
} else {
  console.error(`FAIL: ${errors.length} consistency issue(s):`);
  for (const e of errors) console.error('  - ' + e);
  if (phase4Warnings.length > 0) {
    console.error(`\nPhase-4 warnings (informational):`);
    for (const w of phase4Warnings) console.error('  WARN: ' + w);
  }
  if (encodingWarnings.length > 0) {
    console.error(`\nNon-ASCII source warnings (informational):`);
    for (const w of encodingWarnings) console.error('  WARN: ' + w);
  }
  if (ledgerWarnings.length > 0) {
    console.error(`\nBuild-KPI gate-enrichment warnings (informational):`);
    for (const w of ledgerWarnings) console.error('  WARN: ' + w);
  }
  if (step0Warnings.length > 0) {
    console.error(`\nStep-0 work_dir warnings (informational):`);
    for (const w of step0Warnings) console.error('  WARN: ' + w);
  }
  if (runTempWarnings.length > 0) {
    console.error(`\nRun-scoped temp ({RUN_TEMP}) warnings (informational):`);
    for (const w of runTempWarnings) console.error('  WARN: ' + w);
  }
  console.error(`\n${baselineCoverage}`);
  if (baselineWarnings.length > 0) {
    console.error(`Golden-screen baseline warnings (informational):`);
    for (const w of baselineWarnings) console.error('  WARN: ' + w);
  }
  process.exit(1);
}
