#!/usr/bin/env node
// Verifies marketplace.json against the filesystem and across manifests.
// Fails (exit 1) on:
//   - Skill directory exists on disk but is not registered in marketplace.json
//   - Skill registered in marketplace.json but directory or SKILL.md missing
//   - Plugin entry version disagrees with its plugins/<name>/.claude-plugin/plugin.json
//   - marketplace top-level version != metadata.version
//   - metadata.total_skills != actual sum across plugins
//   - metadata.total_plugins != number of plugin entries
//   - SKILL.md references an implementation file (references/..., <SKILL_DIR>/...,
//     <SAP_DEV_CORE_SHARED_DIR>/...) that does not exist on disk (entries in
//     KNOWN_MISSING_REFERENCES emit WARN instead; the allowlist is currently empty)
//   - Shipped .ps1/.vbs contains a non-ASCII byte without a UTF-8 BOM
//     (promoted from WARN on 2026-07-02 once the tree reached zero offenders)
//   - SKILL.md passes {RUN_TEMP} to Get-SapCurrentSessionPath -WorkTemp
//   - A committed screen baseline (.screens.json) is malformed
//   - A file in sap-dev-core/shared/scripts is not mentioned in CLAUDE.md's
//     "Current Shared Files" table (authors' discovery surface; added
//     2026-07-03 after 23 undocumented scripts were found)
// WARN-level ratchets (do not fail the build yet): Phase-4 broker hints,
// build-KPI enrichment, Step-0 work_dir resolution, {WORK_TEMP}-root scratch
// (.vbs/.ps1/.json/.xml/.log/.txt), missing screen baselines,
// single/zero-consumer shared-script placement (CLAUDE.md placement rule,
// reverse direction of the coverage ERROR above).
// Former ratchets promoted to ERROR on 2026-07-10 (counts reached zero):
// bare-cscript / wscript invocations, locale-literal GUI-text branching.

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
// sap-dev-core's `sap_check_abap.vbs` / `sap_check_fm.vbs` are static-analysis
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
  // pure ExecuteGlobal function library (no session attach, no engine bind;
  // paths arrive via %%CONTENT_VERIFY_PS1%% token). Skill-private, so it lives
  // in sap-se38/references/ per the CLAUDE.md placement rule instead of
  // shared/scripts/ — exempted here exactly like the shared include libs are
  // by location.
  'sap_se38_content_verify.vbs',
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
// HARD ERROR since 2026-07-02 (was an informational WARN): the pre-existing
// debt -- 13 files carrying em-dashes / arrows / CJK glyphs in comments and
// WScript.Echo diagnostics -- was cleaned to ASCII in the same change, so any
// hit now is a fresh regression. Runtime non-ASCII strings stay expressible
// via ChrW()/[char]; a leading UTF-8 BOM remains the explicit opt-in for a
// file that genuinely needs non-ASCII bytes. Bytes are read raw (Buffer) so
// the BOM detection and the > 0x7F scan are not perturbed by any decoding
// assumption.
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
        errors.push(`${plugin.name}: ${rel} has a non-ASCII byte at line ${line} (${cpHex}) without a UTF-8 BOM; Windows PowerShell 5.1 / cscript read BOM-less .ps1/.vbs as the ANSI codepage and will mojibake it at runtime — re-save as ASCII (e.g. '--' for an em-dash, ChrW() for runtime non-ASCII strings) or prepend a UTF-8 BOM if the non-ASCII is intentional`);
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
      baselineWarnings.push(`${plugin.name}: ${skill}/${file} has no screen baseline (${want}); /sap-doctor --screens cannot detect release/locale drift for it — capture one per contributing/golden_screen_baselines.md`);
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

// Bucket A (cross-session / cross-connection coordination) allowlist: artifacts a
// DIFFERENT session must find by a predictable shared path, so they are NOT per-run
// scratch and must never be flagged by the {WORK_TEMP} gate (d) below. Keep small +
// explicit; mirror in the run-temp PreToolUse hook's SHARED_ALLOWLIST. Most live in
// {work_dir}\runtime or shared/scripts (so they don't match {WORK_TEMP}\*.vbs|ps1
// anyway) — listed for intent + future-proofing. See CLAUDE.md "Two-bucket temp model".
const RUN_TEMP_SHARED_ALLOWLIST = new Set([
  'session_registry.json',       // broker state (home: {work_dir}\runtime)
  'sap_session_broker.ps1',      // shipped broker        (home: shared/scripts)
  'sap_session_broker_com.vbs',  // shipped broker COM    (home: shared/scripts)
  'sap_attach_lib.vbs',          // shipped attach helper (home: shared/scripts)
  // 2026-07-02 (gate widened to .json/.xml/.log/.txt): Bucket-A coordination
  // state that a DIFFERENT session must find at a predictable path.
  'connections.json',            // multi-profile store   (home: {work_dir}\runtime)
  'session_dev_defaults.json',   // per-(AI-session x connection) dev defaults (home: {work_dir}\runtime)
  'work_dir.txt',                // durable work_dir pointer (home: %APPDATA%\sapdev-ai)
  'run-temp-hook.log',           // the run-temp hook's own cross-run audit trail ({WORK_TEMP} root by design)
  'sap_active_session.json',     // LEGACY Phase-4.1 pin file, removed in 4.2; only referenced in
                                 // historical "this file is gone" notes -- keep allowlisted so those
                                 // notes don't WARN; do not reintroduce the file itself
].map(s => s.toLowerCase()));

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
    // (d) Ratcheting WARN: a skill writing a GENERATED script (.vbs/.ps1) or a
    //     fixed-name scratch/state file (.json/.xml/.log/.txt -- widened
    //     2026-07-02) to the shared base {WORK_TEMP} root is unmigrated -- two
    //     concurrent runs collide on that fixed name (generate-then-cscript
    //     TOCTOU -> wrong-object deploy; the 2026-06-20 sap_se38_update_run.vbs
    //     cross-session clobber; same-shape risk for the sap_*_run.json state
    //     files a parallel wave W9 is migrating). Move per-run scratch to
    //     {RUN_TEMP} (Get-SapRunTemp), minus the cross-session
    //     RUN_TEMP_SHARED_ALLOWLIST (Bucket A). The trailing (?![A-Za-z0-9])
    //     keeps .json from prefix-matching .jsonl (se19's cross-run safety
    //     ledger is deliberately a stable-path .jsonl). Informational until
    //     full coverage, then promote to a hard error. See CLAUDE.md
    //     "Two-bucket temp model".
    const workTempScripts = [...md.matchAll(/\{WORK_TEMP\}\\([^\s'"\\]+\.(?:vbs|ps1|json|xml|log|txt))(?![A-Za-z0-9])/gi)]
      .map(m => m[1])
      .filter(name => !RUN_TEMP_SHARED_ALLOWLIST.has(name.toLowerCase()));
    if (workTempScripts.length > 0) {
      const uniq = [...new Set(workTempScripts)].sort();
      runTempWarnings.push(`${plugin.name}: skills/${skillEntry}/SKILL.md writes generated script(s)/state file(s) under the shared base {WORK_TEMP} (${uniq.join(', ')}); move per-run scratch to {RUN_TEMP} (Get-SapRunTemp) so concurrent runs don't collide (CLAUDE.md "Two-bucket temp model")`);
    }
  }
}

// ---------------------------------------------------------------------------
// Referenced-implementation existence gate (added 2026-07-02).
//
// The 2026-07-02 full-repo review found two SHIPPED skills whose SKILL.md
// routes operations through references/ files that were never committed
// ("ghost implementations"): sap-doctor (sap_screen_check.ps1 +
// sap_screen_check_probe.vbs) and sap-docs-layout (edit_meta_layout.py +
// shared/templates/spec_layout_schema.md). CI verified token substitution but
// never that a referenced file EXISTS, so the ghosts shipped silently. This
// gate makes a missing referenced implementation a HARD ERROR.
//
// Extraction (tuned against the 2026-07-02 tree for zero false positives):
//   * `references/<relpath>.<ext>` -- optionally prefixed by a skill name
//     (`skills/sap-x/references/...` or `sap-x/references/...`), which then
//     resolves against THAT skill. ext in {vbs,ps1,py,abap,json,tsv,txt,md}.
//   * `<SKILL_DIR>/<relpath>.<ext>` -- current-skill-relative.
//   * `<SAP_DEV_CORE_SHARED_DIR>/<relpath>.<ext>` -- resolves under
//     plugins/sap-dev-core/shared/ (how sap-docs-layout references its
//     missing schema template).
// Ignored as generated outputs / non-concrete mentions:
//   * paths directly prefixed by {RUN_TEMP} / {WORK_TEMP} (runtime copies);
//   * anything carrying placeholder or glob characters (<stem>, %%TOKEN%%,
//     *, {var}) -- those never survive the [A-Za-z0-9_.\-] path charset.
// Cross-skill fallback: a reference that does not resolve in the current
// skill counts as found when the same references-relative path exists in ANY
// other skill (sap-explain-object legitimately reads sap-se24's download
// template via a PS variable, which hides the owning skill from the regex).
// The gate targets never-committed files, which exist in NO skill.
//
// Missing file => HARD ERROR, except the KNOWN_MISSING allowlist below, which
// emits WARN. Empty since wave W11 re-implemented both 2026-07-02 ghosts
// (sap-doctor sap_screen_check.ps1 + sap_screen_check_probe.vbs;
// sap-docs-layout edit_meta_layout.py + the schema doc, relocated to
// <SKILL_DIR>/templates/spec_layout_schema.md). The mechanism stays for
// future review-verified ghosts -- do NOT add entries without a
// review-verified reason string.
// ---------------------------------------------------------------------------

const KNOWN_MISSING_REFERENCES = new Map([]);

const refExistWarnings = [];
{
  const REF_EXTS = 'vbs|ps1|py|abap|json|tsv|txt|md';
  const SEG = String.raw`[A-Za-z0-9_.\-]+`;
  const RELPATH = String.raw`(?:${SEG}[\\/])*${SEG}\.(?:${REF_EXTS})`;
  const reRefs = new RegExp(String.raw`(?:skills[\\/])?(?:(${SEG})[\\/])?references[\\/]+(${RELPATH})\b`, 'g');
  const reSkillRel = new RegExp(String.raw`<SKILL_DIR>[\\/]+(${RELPATH})\b`, 'g');
  const reSharedRel = new RegExp(String.raw`<SAP_DEV_CORE_SHARED_DIR>[\\/]+(${RELPATH})\b`, 'g');

  // All skill dirs across plugins, for explicit-skill + cross-skill resolution.
  const skillDirsByName = new Map();
  for (const plugin of mp.plugins) {
    const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
    const skillsDir = join(repoRoot, sourceRel, 'skills');
    if (!existsSync(skillsDir)) continue;
    for (const entry of readdirSync(skillsDir)) {
      const full = join(skillsDir, entry);
      if (statSync(full).isDirectory()) skillDirsByName.set(entry, full);
    }
  }
  const sharedDirAbs = join(repoRoot, 'plugins', 'sap-dev-core', 'shared');

  const allowReason = (skillEntry, rel) => {
    const allow = KNOWN_MISSING_REFERENCES.get(skillEntry);
    if (!allow) return null;
    const norm = rel.replace(/\\/g, '/').toLowerCase();
    for (const f of allow.files) {
      const fn = f.replace(/\\/g, '/').toLowerCase();
      if (norm === fn || norm.endsWith('/' + fn)) return allow.reason;
    }
    return null;
  };

  for (const plugin of mp.plugins) {
    const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
    const skillsDir = join(repoRoot, sourceRel, 'skills');
    if (!existsSync(skillsDir)) continue;
    for (const skillEntry of readdirSync(skillsDir)) {
      const skillMdPath = join(skillsDir, skillEntry, 'SKILL.md');
      if (!existsSync(skillMdPath)) continue;
      const lines = readFileSync(skillMdPath, 'utf8').split(/\r?\n/);
      const reported = new Set();

      const report = (rel, lineNo, where) => {
        const key = where + '|' + rel.toLowerCase();
        if (reported.has(key)) return;
        reported.add(key);
        const reason = allowReason(skillEntry, rel);
        if (reason) {
          refExistWarnings.push(`${plugin.name}: skills/${skillEntry}/SKILL.md:${lineNo} references ${where}${rel} -- known missing, pending W11 re-implementation (${reason})`);
        } else {
          errors.push(`${plugin.name}: skills/${skillEntry}/SKILL.md:${lineNo} references ${where}${rel} which does not exist on disk; a shipped SKILL.md must not route through uncommitted implementation files -- commit the file, fix the path, or (review-verified ghosts only) add it to KNOWN_MISSING_REFERENCES with a reason`);
        }
      };

      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        let m;
        reRefs.lastIndex = 0;
        while ((m = reRefs.exec(line)) !== null) {
          const pre = line.slice(Math.max(0, m.index - 14), m.index);
          if (/\{(RUN|WORK)_TEMP\}[\\/]*$/i.test(pre)) continue; // runtime copy, not the shipped template
          const rel = m[2].replace(/\\/g, '/');
          const explicitSkill = m[1] && skillDirsByName.has(m[1]) ? m[1] : null;
          if (explicitSkill) {
            if (!existsSync(join(skillDirsByName.get(explicitSkill), 'references', ...rel.split('/')))) {
              report(rel, i + 1, `${explicitSkill}/references/`);
            }
            continue;
          }
          if (existsSync(join(skillsDir, skillEntry, 'references', ...rel.split('/')))) continue;
          let foundElsewhere = false;
          for (const dir of skillDirsByName.values()) {
            if (existsSync(join(dir, 'references', ...rel.split('/')))) { foundElsewhere = true; break; }
          }
          if (!foundElsewhere) report(rel, i + 1, 'references/');
        }
        reSkillRel.lastIndex = 0;
        while ((m = reSkillRel.exec(line)) !== null) {
          const rel = m[1].replace(/\\/g, '/');
          if (/^references\//i.test(rel)) continue; // handled by the references/ form above
          if (!existsSync(join(skillsDir, skillEntry, ...rel.split('/')))) report(rel, i + 1, '<SKILL_DIR>/');
        }
        reSharedRel.lastIndex = 0;
        while ((m = reSharedRel.exec(line)) !== null) {
          const rel = m[1].replace(/\\/g, '/');
          if (!existsSync(join(sharedDirAbs, ...rel.split('/')))) report(rel, i + 1, '<SAP_DEV_CORE_SHARED_DIR>/');
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Bare cscript / wscript invocation gate (added 2026-07-02; promoted from
// WARN to ERROR on 2026-07-10 when the bare-invocation count ratcheted to
// zero, per the original promotion plan).
//
// SAP GUI Scripting COM binds only from a 32-bit host: a bare `cscript`
// resolves to the 64-bit binary on x64 Windows and the generated VBS fails
// (the recurring "false-success / no destination" class), so every SKILL.md
// invocation must spell the 32-bit host explicitly --
// C:\Windows\SysWOW64\cscript.exe (either slash form, quoted or bare).
// `wscript(.exe)` is never acceptable for these templates: the attach-lib
// diagnostics echo via WScript.Echo, which under wscript renders each echo
// as a BLOCKING MsgBox. Comment lines (leading ' or #) inside embedded
// snippets are skipped -- the gate targets copy-pasteable invocations.
// ---------------------------------------------------------------------------

for (const plugin of mp.plugins) {
  const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
  const skillsDir = join(repoRoot, sourceRel, 'skills');
  if (!existsSync(skillsDir)) continue;
  for (const skillEntry of readdirSync(skillsDir)) {
    const skillMdPath = join(skillsDir, skillEntry, 'SKILL.md');
    if (!existsSync(skillMdPath)) continue;
    const lines = readFileSync(skillMdPath, 'utf8').split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (/^\s*['#]/.test(line)) continue; // embedded VBS/PS comment, not an invocation
      const tokRe = /\b(cscript|wscript)(\.exe)?(?![\w.])/gi;
      let m;
      while ((m = tokRe.exec(line)) !== null) {
        const after = line.slice(m.index + m[0].length);
        // Invocation-ish: optional closing quote, whitespace, then an argument
        // (//switch, quoted/tokenized/variable path, drive path, or .\path).
        if (!/^["']?\s+(\/\/|["'{$]|[A-Za-z]:|\.[\\/])/.test(after)) continue;
        const before = line.slice(0, m.index);
        if (m[1].toLowerCase() === 'wscript') {
          errors.push(`${plugin.name}: skills/${skillEntry}/SKILL.md:${i + 1} invokes wscript -- blocks with MsgBox under attach-lib echoes; use C:\\Windows\\SysWOW64\\cscript.exe //NoLogo instead`);
        } else if (!/syswow64[\\/]+$/i.test(before)) {
          errors.push(`${plugin.name}: skills/${skillEntry}/SKILL.md:${i + 1} invokes bare cscript (picks the 64-bit host; SAP GUI COM needs 32-bit) -- prefix C:\\Windows\\SysWOW64\\ per CLAUDE.md / feedback_sap_gui_vbs_must_be_32bit`);
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Locale-literal gate (added 2026-07-02; promoted from WARN to ERROR on
// 2026-07-10 when the hit count ratcheted to zero, per the original
// promotion plan).
//
// language_independence_rules.md forbids branching on translated GUI text,
// yet the 2026-07-02 review found ~40 shipped lines that InStr() SAP screen
// text against English literals ("resulted in errors", "locked", "Initial
// Screen", ...) or compare LCase(<title var>) against English window titles.
// Those paths silently misbehave on ZH/JA/DE logons (the product is declared
// EN/ZH/JA). This gate flags, in references/*.vbs:
//   lines that are NOT comments, do NOT contain WScript.Echo (localized text
//   is allowed in diagnostics), and either
//     (a) compare a lowercased *title* variable: LCase(..Title..) = "...", or
//     (b) call InStr(...) whose argument text (from the InStr( onward, code
//         part only) contains a quoted English literal from the curated list.
// Curated literals keep the signal high -- every 2026-07-02 hit was verified
// real locale-dependence (41/41). The shipped hits were migrated to
// control-ID / MessageType / icon-ID checks (or the documented multi-locale
// matcher exception below) on 2026-07-10.
// ---------------------------------------------------------------------------

const LOCALE_PHRASES = [
  'error', 'locked', 'saved', 'does not exist', 'initial screen',
  'resulted in errors', 'is inconsistent', 'generation environment',
  'create maintenance', 'workbench', 'transport request', 'view',
];

// Code part of a VBS line: strip a trailing '-comment, respecting "strings".
function vbsCodePart(line) {
  let out = '';
  let inStr = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inStr) { out += c; if (c === '"') inStr = false; continue; }
    if (c === '"') { inStr = true; out += c; continue; }
    if (c === "'") break;
    out += c;
  }
  return out;
}
function vbsQuotedStrings(code) {
  const out = [];
  const re = /"((?:[^"]|"")*)"/g;
  let m;
  while ((m = re.exec(code)) !== null) out.push(m[1]);
  return out;
}

// Files that implement the DOCUMENTED multi-locale matcher exception: the
// ATC Run Monitor state cell exposes no MessageType and its icon markup is
// release-dependent, so sap_atc_check_run_status.vbs matches state wording
// across the product's declared logon languages (EN literals + ChrW-built
// JA/ZH) with the icon-ID prefixes staying authoritative -- see its header
// comment. That EN leg legitimately contains curated literals. Keep this
// list SHORT and justified: naive EN-only branching anywhere else must
// still be flagged.
const LOCALE_LITERAL_EXEMPT = new Set([
  'sap-atc/sap_atc_check_run_status.vbs',
]);

for (const plugin of mp.plugins) {
  const sourceRel = plugin.source.replace(/^\.\//, '').replace(/\/$/, '');
  const sourceAbs = join(repoRoot, sourceRel);
  for (const { skill, file, abs } of listVbsTemplates(join(sourceAbs, 'skills'))) {
    if (LOCALE_LITERAL_EXEMPT.has(`${skill}/${file}`)) continue;
    const lines = readFileSync(abs, 'utf8').split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i];
      if (/^\s*'/.test(raw)) continue;
      if (/WScript\.Echo/i.test(raw)) continue;
      const code = vbsCodePart(raw);
      if (!code.trim()) continue;
      const titleHit = /LCase\s*\(\s*\w*Title\w*\s*\)\s*=/i.test(code);
      let phrase = null;
      const instrIdx = code.search(/InStr\s*\(/i);
      if (instrIdx >= 0) {
        for (const q of vbsQuotedStrings(code.slice(instrIdx))) {
          const ql = q.toLowerCase();
          const hit = LOCALE_PHRASES.find(p => ql.includes(p));
          if (hit) { phrase = hit; break; }
        }
      }
      if (titleHit || phrase) {
        const kind = titleHit ? 'window-title compare (LCase(..Title..) = ...)' : `InStr against English literal "${phrase}"`;
        errors.push(`${plugin.name}: ${skill}/${file}:${i + 1} ${kind} -- locale-dependent; branch on control ID / sbar MessageType / icon-ID instead (shared/rules/language_independence_rules.md)`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// CLAUDE.md shared-scripts inventory coverage + placement ratchet (the two
// directions of the CLAUDE.md placement rule).
//
// Direction 1 -- HARD ERROR: every .ps1/.vbs shipped in
// plugins/sap-dev-core/shared/scripts must be mentioned by filename in
// CLAUDE.md's "Current Shared Files" table (the authors' discovery surface;
// the 2026-07-03 review found 23 undocumented scripts, among them the
// load-bearing post-activate / content-verify gates). Adding a new shared
// script? Add its table row in the same commit.
//
// Direction 2 -- WARN ratchet: a shared script whose consumer count has
// fallen to ONE same-plugin skill (or zero), with no wiring from a sibling
// shared script / shared rules doc and no reasoned allowlist entry, belongs
// in skills/<consumer>/references/ instead (placement rule clause 1;
// precedent: the 2026-07-03 relocation of the se38 content-verify pair, the
// three check-abap validators, and the gui-probe helpers -- plus the
// deletion of the zero-consumer sap_check_transport.ps1 this check would
// have flagged years earlier). Consumer = any plugins/*/skills/<skill> tree
// or plugins/*/agents/*.md mentioning the filename; a single CROSS-plugin
// consumer is fine (core is the distribution vehicle); wiring = a mention
// from another shared script or shared/rules/*.md (platform primitives,
// clause 2). WARN-level: flags drift, never fails the build.
const SHARED_PLACEMENT_ALLOWLIST = new Map([
  ['sap_login.vbs',                     'login/connection bootstrap family (placement rule clause 2)'],
  ['sap_rfc_connect.ps1',               'login/connection bootstrap family (clause 2)'],
  ['sap_rfc_system_info.ps1',           'release-marker producer; sap_select_vbs_variant.ps1 consumes the marker via connections.json (clause 2)'],
  ['sap_gui_security_warmup.vbs',       'GUI-security trust family with sidecar + grant (clause 2)'],
  ['sap_run_with_lock.ps1',             'machine-global paste mutex, foreground-guard sibling, designed for any future paste-based skill (clause 2)'],
  ['sap_se37_post_activate_verify.ps1', 'post-activate verify family is one maintained safety contract; the se11 member is multi-consumer via gui-skill-scaffold (clause 2)'],
  ['sap_se38_post_activate_verify.ps1', 'post-activate verify family is one maintained safety contract (clause 2)'],
  ['sap_rfc_syntax_check.ps1',          'shared headless-syntax-check engine (EDITOR_SYNTAX_CHECK via wrapper) consumed by the se38 deploy gate now; se37/se24 gates + the merged sap-check-abap syntax dimension land next (clause 1 multi-consumer / clause 2 platform primitive)'],
  ['sap_keyed_diff_lib.ps1',            'the ONE suite-wide keyed row-diff engine; consumed by sap-se16n snapshot diff now; sap-config-compare (wave 1) + sap-compare --table-content land next (clause 1 multi-consumer / clause 2 platform primitive)'],
]);
const sharedPlacementWarnings = [];
{
  const sharedScriptsDir = join(repoRoot, 'plugins', 'sap-dev-core', 'shared', 'scripts');
  if (existsSync(sharedScriptsDir)) {
    const claudeMdText = readFileSync(join(repoRoot, 'CLAUDE.md'), 'utf8');
    const sharedFiles = readdirSync(sharedScriptsDir).filter((f) => /\.(ps1|vbs)$/i.test(f)).sort();

    // Direction 1: table coverage.
    for (const f of sharedFiles) {
      if (!claudeMdText.includes(f)) {
        errors.push(`sap-dev-core: shared/scripts/${f} is not mentioned in CLAUDE.md's "Current Shared Files" table -- add a row (file, used-by, purpose) so authors discover it instead of re-implementing it`);
      }
    }

    // Direction 2: consumer-count placement ratchet.
    const readTreeText = (dir) => {
      let txt = '';
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, entry.name);
        if (entry.isDirectory()) txt += readTreeText(p);
        else if (/\.(md|ps1|vbs)$/i.test(entry.name)) {
          try { txt += readFileSync(p, 'utf8') + '\n'; } catch { /* unreadable file: skip */ }
        }
      }
      return txt;
    };
    const consumerBlobs = new Map(); // '<plugin>:<skill>' or '<plugin>:agent:<name>' -> concatenated text
    const pluginsDir = join(repoRoot, 'plugins');
    for (const pluginName of readdirSync(pluginsDir)) {
      const skillsDir = join(pluginsDir, pluginName, 'skills');
      if (existsSync(skillsDir) && statSync(skillsDir).isDirectory()) {
        for (const skillName of readdirSync(skillsDir)) {
          const sd = join(skillsDir, skillName);
          if (statSync(sd).isDirectory()) consumerBlobs.set(`${pluginName}:${skillName}`, readTreeText(sd));
        }
      }
      const agentsDir = join(pluginsDir, pluginName, 'agents');
      if (existsSync(agentsDir) && statSync(agentsDir).isDirectory()) {
        for (const a of readdirSync(agentsDir)) {
          if (!/\.md$/i.test(a)) continue;
          try { consumerBlobs.set(`${pluginName}:agent:${basename(a, '.md')}`, readFileSync(join(agentsDir, a), 'utf8')); } catch { /* skip */ }
        }
      }
    }
    const sharedTexts = new Map();
    for (const f of sharedFiles) {
      try { sharedTexts.set(f, readFileSync(join(sharedScriptsDir, f), 'utf8')); } catch { sharedTexts.set(f, ''); }
    }
    let rulesText = '';
    const rulesDir = join(repoRoot, 'plugins', 'sap-dev-core', 'shared', 'rules');
    if (existsSync(rulesDir)) {
      for (const r of readdirSync(rulesDir)) {
        if (!/\.md$/i.test(r)) continue;
        try { rulesText += readFileSync(join(rulesDir, r), 'utf8') + '\n'; } catch { /* skip */ }
      }
    }

    for (const f of sharedFiles) {
      const consumers = [...consumerBlobs.entries()].filter(([, txt]) => txt.includes(f)).map(([id]) => id);
      if (consumers.length >= 2) continue;                                                // clause 1: multi-consumer
      if (consumers.length === 1 && !consumers[0].startsWith('sap-dev-core:')) continue;  // clause 1: cross-plugin consumer
      const wired = [...sharedTexts.entries()].some(([g, txt]) => g !== f && txt.includes(f)) || rulesText.includes(f);
      if (wired) continue;                                                                // clause 2: platform-wired
      if (SHARED_PLACEMENT_ALLOWLIST.has(f)) continue;                                    // reasoned exception
      if (consumers.length === 0) {
        sharedPlacementWarnings.push(`sap-dev-core: shared/scripts/${f} has NO consumer anywhere under plugins/ and no shared-side wiring -- dead shared script? Delete it (git history keeps it; the 2026-07-03 sweep deleted sap_check_transport.ps1 for exactly this) or wire/document its consumer`);
      } else {
        sharedPlacementWarnings.push(`sap-dev-core: shared/scripts/${f} has a single same-plugin consumer (${consumers[0]}) and no shared-side wiring -- per CLAUDE.md's placement rule move it to skills/${consumers[0].split(':')[1]}/references/ (git mv + retarget the SKILL.md paths), or add a reasoned SHARED_PLACEMENT_ALLOWLIST entry`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Rule 0 safety-gate coverage (shared/rules/safety_policy.md) -- HARD ERRORS.
//
// Every skill on the write-capable list below MUST run
// `sap_safety_gate.ps1 -Action assert` from its SKILL.md before its first
// SAP-mutating step. This list IS the write-capable inventory: when a new
// write-capable skill ships (or an existing one gains a write mode), add it
// here in the same commit that wires its gate block. Phase 2 (2026-07-18)
// reached full coverage (53 skills). Deliberate EXCLUSIONS, so nobody
// "fixes" them onto the list without cause:
//   * /sap-stms -- keeps its own TARGET-based PROD gate (W2/W3): an import's
//     target system differs from the pinned connection the generic assert
//     judges.
//   * Pure read / local skills: sap-git (refuses writes), sap-trace,
//     sap-sp02, sap-fix-abap (local file edits), sap-se16n, sap-sql-query.
//   * Write modes documented but UNSHIPPED (add when they ship):
//     sap-vofm (create/update/regen v1.5), sap-sost (resend v1.5),
//     sap-gateway-service (activate v2), sap-spau-triage (route v1.5),
//     sap-gen-rap (deploy v1.5).
//   * Analysis-artifact writers only (SCI object sets / run series, no
//     repo or business mutation): sap-atc, sap-cc-analyze.
//   * Sole write leg is delegating a report capture/export to the gated
//     /sap-run-report: sap-forms, sap-golden-master.
//   * sap-gui-skill-scaffold -- probes run through sap-gui-probe (gated).
const SAFETY_GATE_SKILLS = new Map([
  ['sap-dev-core', ['sap-se38', 'sap-se37', 'sap-se24', 'sap-se11', 'sap-se01',
                    'sap-se14', 'sap-run-report', 'sap-job',
                    'sap-activate-object', 'sap-call-bdc', 'sap-change-package',
                    'sap-check-fix', 'sap-cmod', 'sap-dev-clean', 'sap-dev-init',
                    'sap-file-transfer', 'sap-fix-incident', 'sap-function-group',
                    'sap-gui-probe', 'sap-rfc-wrapper', 'sap-run-abap-unit',
                    'sap-scratch-run', 'sap-se19', 'sap-se21', 'sap-se41',
                    'sap-se51', 'sap-se54', 'sap-se91', 'sap-sm12', 'sap-snro',
                    'sap-transport-request', 'sap-update-addon']],
  ['sap-gen-code', ['sap-gen-cds']],
  ['sap-migrate',  ['sap-cc-decommission', 'sap-cc-remediate',
                    'sap-exit-modernize']],
  ['sap-project',  ['sap-sm30', 'sap-pfcg',
                    'sap-bp', 'sap-fi-post', 'sap-idoc', 'sap-mass-load',
                    'sap-mm01', 'sap-output-diagnose', 'sap-retrofit',
                    'sap-rfc-monitor', 'sap-sm35', 'sap-su01', 'sap-tcd-chain',
                    'sap-test-replay', 'sap-translate', 'sap-transport-copies',
                    'sap-user-guide']],
]);
{
  const policyPath = join(repoRoot, 'plugins', 'sap-dev-core', 'shared', 'rules', 'safety_policy.md');
  const gatePath   = join(repoRoot, 'plugins', 'sap-dev-core', 'shared', 'scripts', 'sap_safety_gate.ps1');
  if (!existsSync(policyPath)) {
    errors.push(`sap-dev-core: shared/rules/safety_policy.md is missing -- Rule 0 (the highest-priority safety policy) has no source of truth`);
  }
  if (!existsSync(gatePath)) {
    errors.push(`sap-dev-core: shared/scripts/sap_safety_gate.ps1 is missing -- Rule 0 has no enforcement arm`);
  }
  const rootClaudeMd = join(repoRoot, 'CLAUDE.md');
  if (existsSync(rootClaudeMd) && !readFileSync(rootClaudeMd, 'utf8').includes('safety_policy.md')) {
    errors.push(`CLAUDE.md does not reference safety_policy.md -- restore the "Directive 0" section so Rule 0 stays the highest-priority instruction`);
  }
  const opRulesPath = join(repoRoot, 'plugins', 'sap-dev-core', 'shared', 'rules', 'skill_operating_rules.md');
  if (existsSync(opRulesPath) && !readFileSync(opRulesPath, 'utf8').includes('safety_policy.md')) {
    errors.push(`sap-dev-core: shared/rules/skill_operating_rules.md lost its Rule 0 pointer to safety_policy.md -- restore it (the safety policy outranks the operating rules)`);
  }
  const gateCallRe = /sap_safety_gate\.ps1[^\n]*-Action\s+assert/;
  for (const [pluginName, skills] of SAFETY_GATE_SKILLS) {
    for (const skillName of skills) {
      const skillMdPath = join(repoRoot, 'plugins', pluginName, 'skills', skillName, 'SKILL.md');
      if (!existsSync(skillMdPath)) {
        errors.push(`${pluginName}: skills/${skillName}/SKILL.md is on the Rule 0 write-capable list but does not exist -- update SAFETY_GATE_SKILLS in check-consistency.mjs`);
        continue;
      }
      const md = readFileSync(skillMdPath, 'utf8');
      if (!gateCallRe.test(md)) {
        errors.push(`${pluginName}: skills/${skillName}/SKILL.md is write-capable but never runs 'sap_safety_gate.ps1 -Action assert' -- add the Step 0.6 safety-gate block (see safety_policy.md 0.4; sap-se38 is the canonical example)`);
      }
      if (!md.includes('safety_policy.md')) {
        errors.push(`${pluginName}: skills/${skillName}/SKILL.md runs the safety gate but does not reference safety_policy.md -- add the Shared Resources row so authors find the contract`);
      }
    }
  }
}

if (errors.length === 0) {
  let summary = `OK: ${mp.plugins.length} plugins, ${totalSkills} skills, all manifests aligned at version ${mp.version}, Tier 3 attach contract clean`;
  if (phase4Warnings.length > 0) {
    summary += `, ${phase4Warnings.length} Phase-4 warning(s)`;
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
  if (refExistWarnings.length > 0) {
    summary += `, ${refExistWarnings.length} known-missing reference warning(s)`;
  }
  if (sharedPlacementWarnings.length > 0) {
    summary += `, ${sharedPlacementWarnings.length} shared-placement warning(s)`;
  }
  summary += `, ${baselineCoverage}`;
  console.log(summary);
  for (const w of phase4Warnings) console.warn('  WARN: ' + w);
  for (const w of ledgerWarnings) console.warn('  WARN: ' + w);
  for (const w of step0Warnings) console.warn('  WARN: ' + w);
  for (const w of runTempWarnings) console.warn('  WARN: ' + w);
  for (const w of refExistWarnings) console.warn('  WARN: ' + w);
  for (const w of sharedPlacementWarnings) console.warn('  WARN: ' + w);
  for (const w of baselineWarnings) console.warn('  WARN: ' + w);
  process.exit(0);
} else {
  console.error(`FAIL: ${errors.length} consistency issue(s):`);
  for (const e of errors) console.error('  - ' + e);
  if (phase4Warnings.length > 0) {
    console.error(`\nPhase-4 warnings (informational):`);
    for (const w of phase4Warnings) console.error('  WARN: ' + w);
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
  if (refExistWarnings.length > 0) {
    console.error(`\nKnown-missing reference warnings (allowlisted ghosts, pending W11):`);
    for (const w of refExistWarnings) console.error('  WARN: ' + w);
  }
  if (sharedPlacementWarnings.length > 0) {
    console.error(`\nShared-placement warnings (informational):`);
    for (const w of sharedPlacementWarnings) console.error('  WARN: ' + w);
  }
  console.error(`\n${baselineCoverage}`);
  if (baselineWarnings.length > 0) {
    console.error(`Golden-screen baseline warnings (informational):`);
    for (const w of baselineWarnings) console.error('  WARN: ' + w);
  }
  process.exit(1);
}
