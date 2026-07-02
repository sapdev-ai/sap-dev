#!/usr/bin/env node
// =============================================================================
// run-temp-hook.mjs  --  PreToolUse hook: keep generated scripts out of the
// {WORK_TEMP} root (the "two-bucket temp model" in CLAUDE.md).
//
// WHY a runtime hook on top of the static check-consistency.mjs gate: CI scans
// the *repo* SKILL.md, but agents run the *cache* copy (which can lag the
// migrated repo), and ad-hoc orchestrator/agent scratch is in no SKILL.md at
// all. Both bit us on 2026-06-20 (two concurrent v74 builds clobbered a shared
// {WORK_TEMP}\sap_se38_update_run.vbs, and the orchestrator wrote _probe*.ps1 /
// _verify074.ps1 straight into the temp root). A PreToolUse hook sees the live
// tool call, so it catches both.
//
// WHAT it flags: a GENERATED SCRIPT (.vbs / .ps1) written DIRECTLY into
//   {work_dir}\temp\<name>   (the {WORK_TEMP} root, NOT a {RUN_TEMP} subdir
//   {work_dir}\temp\run_<id>\..., and NOT a Bucket-A SHARED_ALLOWLIST name).
//
// PRECISION by tool:
//   * Write / Edit -> file_path is unambiguously a write target -> ENFORCED
//     (block by default; the model just re-issues under {RUN_TEMP}).
//   * Bash / PowerShell -> a command only MENTIONS paths (a del/cscript is not
//     a write), so command-scanning is ADVISORY ONLY here, never blocks.
//
// MODES (env SAPDEV_RUNTEMP_HOOK):  block (default) | warn | off
// SAFETY: always exits 0 and fails OPEN on any error -- it can never wedge a
//   session. Disable instantly with  setx SAPDEV_RUNTEMP_HOOK off  (or delete
//   the hook block in .claude/settings.local.json).
//
// Contract: CLAUDE.md "Two-bucket temp model". Allowlist mirrors
// RUN_TEMP_SHARED_ALLOWLIST in check-consistency.mjs.
// =============================================================================

import { readFileSync, appendFileSync } from 'node:fs';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

// Bucket A: cross-session coordination artifacts that legitimately live at a
// shared path. (Most live in {work_dir}\runtime or shared/scripts and so never
// match a {WORK_TEMP}\*.vbs|ps1 write anyway -- listed for intent + symmetry.)
const SHARED_ALLOWLIST = new Set([
  'session_registry.json',
  'sap_session_broker.ps1',
  'sap_session_broker_com.vbs',
  'sap_attach_lib.vbs',
  // 2026-07-02 (hook widened to .json/.xml/.log/.txt): Bucket-A coordination
  // state; keep in sync with RUN_TEMP_SHARED_ALLOWLIST in check-consistency.mjs.
  'connections.json',
  'session_dev_defaults.json',
  'work_dir.txt',
  'run-temp-hook.log',           // this hook's own audit trail (appended below)
  'sap_active_session.json',     // legacy Phase-4.1 pin; historical references only
].map((s) => s.toLowerCase()));

const MODE = (process.env.SAPDEV_RUNTEMP_HOOK || 'block').toLowerCase();

function resolveWorkDir() {
  const env = process.env.SAPDEV_AI_WORK_DIR;
  if (env && env.trim()) return env.trim();
  try {
    const ptr = join(process.env.APPDATA || '', 'sapdev-ai', 'work_dir.txt');
    if (existsSync(ptr)) {
      const v = readFileSync(ptr, 'utf8').trim();
      if (v) return v;
    }
  } catch { /* ignore */ }
  return 'C:\\sap_dev_work';
}

const norm = (s) => String(s == null ? '' : s).replace(/\//g, '\\').toLowerCase();

function findRootScripts(text, tempRoot) {
  // Match  <tempRoot>\<basename>.<ext>  where <basename> has no path
  // separator (i.e. a DIRECT child of the temp root, not a run_<id> subdir),
  // plus the literal {work_temp}\<name>.<ext> token form (defensive).
  // ext: generated scripts (.vbs/.ps1) plus fixed-name scratch/state files
  // (.json/.xml/.log/.txt -- widened 2026-07-02, mirroring the static gate).
  // The (?![a-z0-9]) tail keeps .json from prefix-matching .jsonl (se19's
  // stable-path cross-run ledger).
  const esc = tempRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const res = [
    new RegExp(esc + '\\\\([^\\\\/"\'\\s]+\\.(?:vbs|ps1|json|xml|log|txt))(?![a-z0-9])', 'gi'),
    /\{work_temp\}\\([^\\/"'\s]+\.(?:vbs|ps1|json|xml|log|txt))(?![a-z0-9])/gi,
  ];
  const hits = new Set();
  for (const re of res) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      const base = m[1];
      if (!SHARED_ALLOWLIST.has(base)) hits.add(base);
    }
  }
  return [...hits].sort();
}

function out(obj) { try { process.stdout.write(JSON.stringify(obj)); } catch { /* ignore */ } }

try {
  if (MODE === 'off') process.exit(0);

  const raw = readFileSync(0, 'utf8');                 // stdin (PreToolUse payload)
  if (!raw || !raw.trim()) process.exit(0);
  const payload = JSON.parse(raw);
  const tool = String(payload.tool_name || payload.toolName || '');
  const input = payload.tool_input || payload.toolInput || {};

  const workDir = resolveWorkDir();
  const tempRoot = norm(workDir) + '\\temp';

  const isWrite = /^(Write|Edit|MultiEdit|NotebookEdit)$/i.test(tool);
  const candidate = isWrite ? norm(input.file_path) : norm(input.command);
  if (!candidate) process.exit(0);

  const hits = findRootScripts(candidate, tempRoot);
  if (hits.length === 0) process.exit(0);

  const list = hits.join(', ');
  const reason =
    `Generated script(s) [${list}] are headed for the {WORK_TEMP} root ` +
    `(${workDir}\\temp). Per the two-bucket temp model (CLAUDE.md), per-run scratch ` +
    `MUST go under {RUN_TEMP} = ${workDir}\\temp\\run_<id>\\ (mint it with ` +
    `Get-SapRunTemp, or use a run-scoped subdir) so concurrent sessions don't ` +
    `clobber a fixed name. Only Bucket-A cross-session coordination state belongs ` +
    `at a shared path. Re-issue the write under a {RUN_TEMP} subdirectory.`;

  // Guaranteed audit trail (best-effort; never throws past here).
  try {
    let ts = '';
    try { ts = new Date().toISOString(); } catch { ts = ''; }
    appendFileSync(join(workDir, 'temp', 'run-temp-hook.log'),
      `${ts}\t${tool}\t${MODE}\t${list}\n`);
  } catch { /* ignore */ }

  // Bash/PowerShell: command text only MENTIONS a path -> advisory, never block.
  const enforce = MODE === 'block' && isWrite;

  if (enforce) {
    out({
      decision: 'block',                                // legacy shape
      reason,
      hookSpecificOutput: {                             // current shape
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reason,
      },
    });
  } else {
    out({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        additionalContext: `[run-temp advisory] ${reason}`,
      },
    });
  }
  process.exit(0);
} catch {
  process.exit(0);                                      // fail OPEN: never wedge a tool call
}
