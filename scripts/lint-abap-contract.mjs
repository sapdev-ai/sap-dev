#!/usr/bin/env node
// lint-abap-contract.mjs
//
// Deterministic, OFFLINE "contract lint" for generated ABAP. Mechanises the
// offline-checkable subset of /sap-gen-abap's pre-emit ATC checklist plus the
// sibling-file sync rules, so the regression suite can gate generation quality
// in CI (ubuntu, Node) without a SAP connection.
//
// This is NOT a parser-level syntax checker (abaplint fills that role) and NOT
// a logic-fidelity check (the traceability-skeleton diff fills that). It catches
// the specific contract violations that this project has hit repeatedly and that
// are mechanically detectable from the generated text + its committed sibling
// files. Each rule cites shared/rules/abap_code_quality_rules.md or the
// pre-emit checklist in sap-gen-abap/SKILL.md.
//
// Usage:
//   node scripts/lint-abap-contract.mjs <file.abap> [--work-folder <dir>] [--fixture]
//   node scripts/lint-abap-contract.mjs --selftest
//
// --work-folder lets the sibling-file (.text_elements.txt, .messages.txt) and
// signature (_authz_signatures.txt, _fm_signatures.txt) rules run; without it
// those rules are skipped (reported as such, never as a pass).
//
// --fixture turns SILENT SKIPS into HARD ERRORS for objects the generated code
// actually references. This is the snapshot-completeness gate (P2.1): the
// signature rules below intentionally skip a CALL FUNCTION / AUTHORITY-CHECK
// when its signature row is absent or marked UNAVAILABLE/NOT_FOUND, because in
// normal operation the generator falls back to training knowledge with a TODO.
// In a regression fixture that "skip" is the failure we must NOT tolerate: an
// incomplete snapshot would let the fixture pass while exercising exactly the
// training-knowledge fallback the regression exists to catch. With --fixture,
// any referenced object without a concrete signature/sibling becomes a
// SNAPSHOT_INCOMPLETE / SIBLING_MISSING ERROR. See shared/rules/build_metrics.md.
//
// Output grammar (stable):
//   LINT: <ERROR|WARN> | <RULE_ID> | <file>:<line> | <detail>
//   LINT-SUMMARY: errors=<n> warns=<n> skipped-rules=<csv>[ mode=fixture]
// Exit: 0 when no ERROR findings, 1 when any ERROR finding, 2 on bad invocation.

import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { join, dirname, basename, resolve, isAbsolute } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

// Anchor for CLI path resolution: this script's repo root (scripts/..). The
// --selftest is cwd-independent by construction (in-memory sources + mkdtemp
// under the OS tmpdir); this anchor additionally lets the documented fixture
// commands (`node scripts/lint-abap-contract.mjs tests/fixtures/...
// --work-folder tests/fixtures/... --fixture`, see .github/workflows/
// validate.yml + tests/fixtures/README.md) be replayed from ANY cwd: a
// relative CLI path is tried against the cwd first (unchanged behavior for
// every currently-working invocation), then against the repo root as a
// fallback instead of dying with "file not found".
const SCRIPT_REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
function resolveCliPath(p) {
  if (!p || isAbsolute(p) || existsSync(p)) return p;
  const fromRoot = resolve(SCRIPT_REPO_ROOT, p);
  return existsSync(fromRoot) ? fromRoot : p;
}

// ---------------------------------------------------------------------------
// Finding model
// ---------------------------------------------------------------------------

function mkFinding(severity, rule, line, detail) {
  return { severity, rule, line, detail };
}

// Strip ABAP string literals ('...') and string templates (`...`) to their
// length-preserving blanks, so keyword/`.`-terminator scans don't trip on
// quoted content. Full-line comments (* ...) and trailing comments (" ...) are
// also blanked. Line structure (count + length) is preserved.
function blankNoise(line) {
  let out = '';
  let i = 0;
  let inStr = false, inTmpl = false;
  // Full-line comment.
  if (/^\s*\*/.test(line)) return ' '.repeat(line.length);
  while (i < line.length) {
    const c = line[i];
    if (inStr) {
      if (c === "'") { inStr = false; out += "'"; } else { out += ' '; }
      i++; continue;
    }
    if (inTmpl) {
      if (c === '`') { inTmpl = false; out += '`'; } else { out += ' '; }
      i++; continue;
    }
    if (c === "'") { inStr = true; out += "'"; i++; continue; }
    if (c === '`') { inTmpl = true; out += '`'; i++; continue; }
    if (c === '"') { out += ' '.repeat(line.length - i); break; } // trailing comment
    out += c; i++;
  }
  return out;
}

// Blank ONLY comments (full-line * and trailing "), keeping string-literal
// CONTENTS intact. Rules that read names out of string literals (AUTHORITY-CHECK
// OBJECT '<X>', CALL FUNCTION '<FM>', ID '<field>') need the contents, but still
// must not match keywords that appear inside a comment.
function blankComments(line) {
  if (/^\s*\*/.test(line)) return ' '.repeat(line.length);
  let out = '';
  let i = 0;
  let inStr = false, inTmpl = false;
  while (i < line.length) {
    const c = line[i];
    if (inStr) { out += c; if (c === "'") inStr = false; i++; continue; }
    if (inTmpl) { out += c; if (c === '`') inTmpl = false; i++; continue; }
    if (c === "'") { inStr = true; out += c; i++; continue; }
    if (c === '`') { inTmpl = true; out += c; i++; continue; }
    if (c === '"') { out += ' '.repeat(line.length - i); break; }
    out += c; i++;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Source-only rules (no sibling/signature files needed)
// ---------------------------------------------------------------------------

const EVENT_BLOCKS = /^\s*(INITIALIZATION|START-OF-SELECTION|END-OF-SELECTION|LOAD-OF-PROGRAM|AT\s+SELECTION-SCREEN|AT\s+LINE-SELECTION|TOP-OF-PAGE|END-OF-PAGE)\b/i;

// ABAP numeric type tokens that must never receive a SPLIT fragment (text-parse
// into a packed/int/float target is an activation error; rules section 25).
// NUMC (N), DATS (D), TIMS (T) are character-type and ARE valid SPLIT targets,
// so they are deliberately excluded.
const NUMERIC_TYPE = /\bTYPE\s+(I|INT1|INT2|INT4|INT8|P|F|DECFLOAT16|DECFLOAT34|B|S)\b/i;

function checkSource(text, file) {
  const findings = [];
  const rawLines = text.split(/\r?\n/);
  const blanked = rawLines.map(blankNoise);

  // Map declared-name -> declared numeric-ness, for the SPLIT-into-numeric rule.
  // Conservative: only names with an explicit elementary numeric TYPE token on
  // their declaration line are considered numeric. (Inline DATA() / DDIC types
  // are left to the live syntax check / ATC; offline we only flag the
  // unambiguous case.)
  const numericVars = collectNumericVars(rawLines, blanked);

  let firstEventLine = -1;
  for (let i = 0; i < blanked.length; i++) {
    if (EVENT_BLOCKS.test(blanked[i])) { firstEventLine = i; break; }
  }

  for (let i = 0; i < rawLines.length; i++) {
    const raw = rawLines[i];
    const b = blanked[i];
    const ln = i + 1;

    // R-LINE: line length. >72 mandated by the generation style rule (WARN);
    // >255 is the hard ABAP limit (ERROR).
    const len = raw.replace(/\s+$/, '').length;
    if (len > 255) {
      findings.push(mkFinding('ERROR', 'LINE_HARD_LIMIT', ln, `line is ${len} chars (>255 hard ABAP limit)`));
    } else if (len > 72) {
      findings.push(mkFinding('WARN', 'LINE_TOO_LONG', ln, `line is ${len} chars (>72; rule: wrap to <=72)`));
    }

    // R-MSG: literal MESSAGE text. ATC P2 guaranteed; project rule = always
    // route through a message class. Matches MESSAGE 'literal' and MESSAGE |tmpl|.
    if (/\bMESSAGE\b/i.test(b)) {
      if (/\bMESSAGE\s+'/i.test(raw) || /\bMESSAGE\s+\|/i.test(raw)) {
        findings.push(mkFinding('ERROR', 'LITERAL_MESSAGE', ln, 'literal MESSAGE text; route via a message class: MESSAGE eNNN(zXXX) (rules section 20)'));
      }
    }

    // R-TEXT-ASSIGN: assignment to a TEXT-NNN symbol (read-only in modern ABAP).
    if (/\bTEXT-\d{1,3}\s*=(?!=)/i.test(b)) {
      findings.push(mkFinding('ERROR', 'TEXT_NNN_ASSIGN', ln, 'assignment to a read-only TEXT-NNN symbol; populate via the .text_elements.txt sibling (rules section 21)'));
    }

    // R-SELECT-STAR: SELECT * / SELECT SINGLE * (advisory; offline cannot prove
    // column usage <80%).
    if (/\bSELECT\s+(SINGLE\s+)?\*/i.test(b)) {
      findings.push(mkFinding('WARN', 'SELECT_STAR', ln, 'SELECT * — list only the columns you use (rules section 12)'));
    }

    // R-CLASS-AFTER-EVENT: a CLASS ... DEFINITION after the first event block.
    // The live-confirmed DECL_ORDER bug: a global class/types scoped into an
    // event block -> "type unknown" at activation (rules section 10).
    if (firstEventLine >= 0 && i > firstEventLine) {
      // Local test classes (FOR TESTING) and DEFERRED forward declarations
      // legitimately follow the event blocks; only a real global class
      // DEFINITION after an event is the DECL_ORDER activation bug.
      if (/^\s*CLASS\s+\w+\s+DEFINITION\b/i.test(b) && !/\bFOR\s+TESTING\b/i.test(b) && !/\bDEFERRED\b/i.test(b)) {
        findings.push(mkFinding('ERROR', 'CLASS_DEF_AFTER_EVENT', ln, `CLASS DEFINITION after an event block (first at line ${firstEventLine + 1}); move all global TYPES/CLASS DEFINITION/DATA before the event blocks (rules section 10)`));
      }
    }
  }

  // R-LOOP-EXIT: LOOP AT ... WHERE ... with an EXIT before the matching ENDLOOP
  // (first-match anti-pattern). Use READ TABLE ... TRANSPORTING NO FIELDS.
  for (let i = 0; i < blanked.length; i++) {
    if (/^\s*LOOP\s+AT\b.*\bWHERE\b/i.test(blanked[i])) {
      for (let j = i + 1; j < Math.min(blanked.length, i + 8); j++) {
        if (/^\s*ENDLOOP\b/i.test(blanked[j])) break;
        if (/^\s*EXIT\s*\.?\s*$/i.test(blanked[j])) {
          findings.push(mkFinding('WARN', 'LOOP_WHERE_EXIT', i + 1, 'LOOP AT ... WHERE ... EXIT first-match; use READ TABLE ... WITH KEY ... TRANSPORTING NO FIELDS (rules section 19)'));
          break;
        }
      }
    }
  }

  // R-COMMA-SELECT: a SELECT whose statement uses @host vars must use a
  // comma-separated field list (strict Open SQL >= 7.50); a space-separated
  // multi-column list with @ is a compile error. Statement-based.
  // R-SPLIT-NUMERIC: a SPLIT ... INTO whose receivers include an elementary
  // numeric variable (text-parse into numeric is an activation error; sect 25).
  for (const stmt of splitStatements(rawLines, blanked)) {
    const sb = stmt.blank;
    if (/^\s*SELECT\b/i.test(sb) && /@/.test(sb)) {
      const m = sb.match(/\bSELECT\b\s+(?:SINGLE\s+|DISTINCT\s+)*([\s\S]*?)\bFROM\b/i);
      if (m) {
        const cols = m[1].trim();
        if (cols !== '*' && cols !== '' && !cols.includes(',')) {
          const toks = cols.split(/\s+/).filter(Boolean);
          if (toks.length >= 2) {
            findings.push(mkFinding('ERROR', 'COMMA_SELECT_HOSTVAR', stmt.line, 'SELECT with @host variables needs a comma-separated field list (strict Open SQL >= 7.50); space-separated columns are a compile error (rules section 9)'));
          }
        }
      }
    }
    // SPLIT <src> AT <sep> INTO [TABLE] t1 t2 ...  -> any receiver that is a
    // known elementary numeric var is an error.
    const sp = sb.match(/\bSPLIT\b[\s\S]*?\bINTO\b\s+(?:TABLE\b\s+)?([\s\S]*?)\.\s*$/i);
    if (sp) {
      const recv = sp[1].split(/\s+/).map(t => t.replace(/[.,]+$/, '').trim()).filter(Boolean);
      for (const r of recv) {
        if (numericVars.has(r.toUpperCase())) {
          findings.push(mkFinding('ERROR', 'SPLIT_INTO_NUMERIC', stmt.line, `SPLIT receiver '${r}' is an elementary numeric variable; text-parse targets must be character-type (C/N/STRING) (rules section 25)`));
        }
      }
    }
  }

  return findings;
}

// Collect names declared with an explicit elementary numeric TYPE on their
// declaration line: `DATA lv_x TYPE i.` / `DATA: lv_a TYPE p, lv_b TYPE c.`
// Conservative by design — only unambiguous cases.
function collectNumericVars(rawLines, blanked) {
  const numeric = new Set();
  for (let i = 0; i < blanked.length; i++) {
    const b = blanked[i];
    if (!/^\s*(DATA|FIELD-SYMBOLS|CONSTANTS|STATICS)\b/i.test(b)) continue;
    // split chained declarations on commas
    for (const part of b.split(',')) {
      const m = part.match(/(?:DATA|CONSTANTS|STATICS|FIELD-SYMBOLS)?\s*:?\s*([A-Za-z_]\w*)\s+(TYPE\s+\w+)/i);
      if (m && NUMERIC_TYPE.test(m[2])) {
        numeric.add(m[1].toUpperCase());
      }
    }
  }
  return numeric;
}

// Split source into ABAP statements (terminated by '.'), tracking the 1-based
// start line. Works on the blanked text (strings/comments removed) so the '.'
// terminator scan is reliable; carries both raw and blanked joins.
function splitStatements(rawLines, blanked) {
  const stmts = [];
  let curRaw = '', curBlank = '', curContent = '', startLine = -1;
  for (let i = 0; i < blanked.length; i++) {
    const b = blanked[i];
    if (b.trim() === '') continue;
    if (startLine < 0) startLine = i + 1;
    curRaw += (curRaw ? '\n' : '') + rawLines[i];
    curBlank += (curBlank ? ' ' : '') + b;
    curContent += (curContent ? ' ' : '') + blankComments(rawLines[i]);
    // statement ends at a '.' that terminates the (blanked) line content
    if (/\.\s*$/.test(b)) {
      stmts.push({ line: startLine, raw: curRaw, blank: curBlank, content: curContent });
      curRaw = ''; curBlank = ''; curContent = ''; startLine = -1;
    }
  }
  if (curBlank.trim() !== '') stmts.push({ line: startLine, raw: curRaw, blank: curBlank, content: curContent });
  return stmts;
}

// What objects does the generated source actually reference? Used to decide
// whether an absent sibling/signature file is a real gap in --fixture mode.
// Returns Maps of NAME -> first-reference 1-based line.
function extractReferencedObjects(text) {
  const rawLines = text.split(/\r?\n/);
  const fms = new Map(), authzObjs = new Map(), textSyms = new Map(), msgNums = new Map();
  for (let i = 0; i < rawLines.length; i++) {
    // FM / AUTHZ names live inside quotes -> keep string contents (blankComments).
    const c = blankComments(rawLines[i]);
    let m;
    const cf = /\bCALL\s+FUNCTION\s+'([^']+)'/gi;
    while ((m = cf.exec(c)) !== null) { const k = m[1].trim().toUpperCase(); if (!fms.has(k)) fms.set(k, i + 1); }
    const ac = /\bAUTHORITY-CHECK\s+OBJECT\s+'([^']+)'/gi;
    while ((m = ac.exec(c)) !== null) { const k = m[1].trim().toUpperCase(); if (!authzObjs.has(k)) authzObjs.set(k, i + 1); }
    // TEXT-NNN / MESSAGE eNNN are bare tokens -> blank string contents (blankNoise).
    const b = blankNoise(rawLines[i]);
    const ts = /\bTEXT-(\d{1,3})\b/gi;
    while ((m = ts.exec(b)) !== null) { const id = m[1].padStart(3, '0'); if (!textSyms.has(id)) textSyms.set(id, i + 1); }
    const mg = /\bMESSAGE\s+[eiwsax](\d{1,3})\s*\(/gi;
    while ((m = mg.exec(b)) !== null) { const id = m[1].padStart(3, '0'); if (!msgNums.has(id)) msgNums.set(id, i + 1); }
  }
  return { fms, authzObjs, textSyms, msgNums };
}

// ---------------------------------------------------------------------------
// Sibling-file sync rules (need the committed .text_elements.txt / .messages.txt)
// ---------------------------------------------------------------------------

// Parse [TEXT_SYMBOLS] ids out of a .text_elements.txt file's content.
function parseTextSymbols(content) {
  const declared = new Set();
  const te = content.split(/\r?\n/);
  let inSyms = false;
  for (const line of te) {
    if (/^\s*\[TEXT_SYMBOLS\]/i.test(line)) { inSyms = true; continue; }
    if (/^\s*\[/.test(line)) { inSyms = false; continue; }
    if (inSyms) {
      const m = line.match(/^\s*(\d{1,3})\b/);
      if (m) declared.add(m[1].padStart(3, '0'));
    }
  }
  return declared;
}

// R-TEXTSYM: every TEXT-NNN referenced in the source has a [TEXT_SYMBOLS] entry.
function checkTextElements(text, declared, fileName) {
  const findings = [];
  const rawLines = text.split(/\r?\n/);
  const seen = new Set();
  for (let i = 0; i < rawLines.length; i++) {
    const b = blankNoise(rawLines[i]);
    const re = /\bTEXT-(\d{1,3})\b/gi;
    let m;
    while ((m = re.exec(b)) !== null) {
      const id = m[1].padStart(3, '0');
      const key = id + ':' + (i + 1);
      if (seen.has(key)) continue;
      seen.add(key);
      if (!declared.has(id)) {
        findings.push(mkFinding('ERROR', 'TEXT_SYMBOL_UNDECLARED', i + 1, `TEXT-${m[1]} referenced but absent from [TEXT_SYMBOLS] in ${fileName} (rules section 21)`));
      }
    }
  }
  return findings;
}

// Parse message numbers out of a .messages.txt file's content.
function parseMessages(content) {
  const declared = new Set();
  for (const line of content.split(/\r?\n/)) {
    const m = line.match(/^\s*(\d{1,3})\t/);
    if (m) declared.add(m[1].padStart(3, '0'));
  }
  return declared;
}

// R-MSGNUM: every MESSAGE eNNN(class) / iNNN / wNNN ... referenced has a row in
// the .messages.txt sibling.
function checkMessages(text, declared, fileName) {
  const findings = [];
  const rawLines = text.split(/\r?\n/);
  for (let i = 0; i < rawLines.length; i++) {
    const b = blankNoise(rawLines[i]);
    // MESSAGE e012(zxx) ... or MESSAGE ID ... TYPE ... NUMBER 012
    const re = /\bMESSAGE\s+[eiwsax](\d{1,3})\s*\(/gi;
    let m;
    while ((m = re.exec(b)) !== null) {
      const id = m[1].padStart(3, '0');
      if (!declared.has(id)) {
        findings.push(mkFinding('ERROR', 'MESSAGE_NUM_UNDECLARED', i + 1, `message number ${m[1]} referenced but absent from ${fileName} (rules section 20)`));
      }
    }
  }
  return findings;
}

// ---------------------------------------------------------------------------
// Signature-based rules (need committed _authz_signatures.txt / _fm_signatures.txt)
// ---------------------------------------------------------------------------

// Parse _authz_signatures.txt content -> { byObj: Map(obj -> Set(field)),
// unavailable: Set(obj) }. Sentinel rows `OBJCT \t NOT_FOUND` /
// `OBJCT \t UNAVAILABLE` mark an object whose SU21 fields could not be resolved.
function parseAuthz(content) {
  const byObj = new Map();
  const unavailable = new Set();
  const af = content.split(/\r?\n/);
  for (let i = 1; i < af.length; i++) {          // row 0 is the header
    const cols = af[i].split('\t');
    if (cols.length < 2) continue;
    const obj = (cols[0] || '').trim().toUpperCase();
    if (!obj) continue;
    const pos = (cols[1] || '').trim().toUpperCase();
    if (pos === 'NOT_FOUND' || pos === 'UNAVAILABLE') { unavailable.add(obj); continue; }
    const field = (cols[2] || '').trim().toUpperCase();
    if (!field) continue;
    if (!byObj.has(obj)) byObj.set(obj, new Set());
    byObj.get(obj).add(field);
  }
  return { byObj, unavailable };
}

// R-AUTHZ: each AUTHORITY-CHECK OBJECT '<X>' must list exactly the fields that
// _authz_signatures.txt records for <X> (offline equivalent of the SU21 check).
function checkAuthz(text, parsed, fileName, fixtureMode) {
  const findings = [];
  const { byObj, unavailable } = parsed;
  const rawLines = text.split(/\r?\n/);
  const blanked = rawLines.map(blankNoise);
  for (const stmt of splitStatements(rawLines, blanked)) {
    const m = stmt.content.match(/\bAUTHORITY-CHECK\s+OBJECT\s+'([^']+)'/i);
    if (!m) continue;
    const obj = m[1].trim().toUpperCase();
    if (unavailable.has(obj)) {
      // A sentinel row: the snapshot could not resolve this object's SU21
      // fields. In a regression fixture that is an incomplete snapshot.
      if (fixtureMode) {
        findings.push(mkFinding('ERROR', 'SNAPSHOT_INCOMPLETE', stmt.line, `AUTHORITY-CHECK OBJECT '${obj}' has a NOT_FOUND/UNAVAILABLE row in ${fileName}; offline regression cannot validate its SU21 field list (rules section 14)`));
      }
      continue;
    }
    if (!byObj.has(obj)) {
      findings.push(mkFinding('ERROR', 'AUTHZ_OBJECT_UNKNOWN', stmt.line, `AUTHORITY-CHECK OBJECT '${obj}' not in ${fileName} (resolve via SU21/USOBT; rules section 14)`));
      continue;
    }
    const expected = byObj.get(obj);
    const usedFields = new Set();
    const fre = /\bID\s+'([^']+)'/gi;
    let fm;
    while ((fm = fre.exec(stmt.content)) !== null) usedFields.add(fm[1].trim().toUpperCase());
    for (const ef of expected) {
      if (!usedFields.has(ef)) {
        findings.push(mkFinding('ERROR', 'AUTHZ_FIELD_MISSING', stmt.line, `AUTHORITY-CHECK OBJECT '${obj}' is missing field ID '${ef}' (SU21 fields: ${[...expected].join(', ')}; rules section 14)`));
      }
    }
    for (const uf of usedFields) {
      if (!expected.has(uf)) {
        findings.push(mkFinding('ERROR', 'AUTHZ_FIELD_UNKNOWN', stmt.line, `AUTHORITY-CHECK OBJECT '${obj}' uses unknown field ID '${uf}' (SU21 fields: ${[...expected].join(', ')}; rules section 14)`));
      }
    }
  }
  return findings;
}

// Parse _fm_signatures.txt content -> { byFm: Map(fm -> Map(param -> section)),
// unavailable: Set(fm) }. UNAVAILABLE/NOT_FOUND section rows mark an FM whose
// signature could not be resolved.
function parseFmSignatures(content) {
  const byFm = new Map();
  const unavailable = new Set();
  const ff = content.split(/\r?\n/);
  for (let i = 1; i < ff.length; i++) {          // row 0 is the header
    const cols = ff[i].split('\t');
    if (cols.length < 3) continue;
    const fm = (cols[0] || '').trim().toUpperCase();
    const section = (cols[1] || '').trim().toUpperCase();
    const param = (cols[2] || '').trim().toUpperCase();
    if (!fm) continue;
    if (section === 'UNAVAILABLE' || section === 'NOT_FOUND') { unavailable.add(fm); continue; }
    if (!param) continue;
    if (!byFm.has(fm)) byFm.set(fm, new Map());
    byFm.get(fm).set(param, section);
  }
  return { byFm, unavailable };
}

// R-CALLFUNC: each CALL FUNCTION '<FM>' parameter name must exist in the FM's
// signature (_fm_signatures.txt) and be in the section it is passed under.
function checkCallFunction(text, parsed, fileName, fixtureMode) {
  const findings = [];
  const { byFm, unavailable } = parsed;
  const sectionKeywords = /^(EXPORTING|IMPORTING|TABLES|CHANGING|EXCEPTIONS)$/i;
  const rawLines = text.split(/\r?\n/);
  const blanked = rawLines.map(blankNoise);
  for (const stmt of splitStatements(rawLines, blanked)) {
    const m = stmt.content.match(/\bCALL\s+FUNCTION\s+'([^']+)'([\s\S]*)/i);
    if (!m) continue;
    const fm = m[1].trim().toUpperCase();
    if (unavailable.has(fm) || !byFm.has(fm)) {
      // No concrete signature: the param check below cannot run. In normal mode
      // this is an honest skip; in a regression fixture it means the snapshot is
      // incomplete and the run would silently exercise training-knowledge fallback.
      if (fixtureMode) {
        const why = unavailable.has(fm) ? 'a NOT_FOUND/UNAVAILABLE row' : 'no row';
        findings.push(mkFinding('ERROR', 'SNAPSHOT_INCOMPLETE', stmt.line, `CALL FUNCTION '${fm}' has ${why} in ${fileName}; offline regression would silently fall back to training knowledge for its signature (rules section 24)`));
      }
      continue;
    }
    const sig = byFm.get(fm);
    const body = m[2];
    const tokens = body.split(/\s+/).filter(Boolean);
    let curSection = '';
    for (let t = 0; t < tokens.length; t++) {
      const tok = tokens[t].replace(/[.,]$/, '');
      if (sectionKeywords.test(tok)) { curSection = tok.toUpperCase(); continue; }
      if (tokens[t + 1] === '=' && curSection && curSection !== 'EXCEPTIONS') {
        const param = tok.toUpperCase();
        if (!sig.has(param)) {
          findings.push(mkFinding('ERROR', 'CALLFUNC_UNKNOWN_PARAM', stmt.line, `CALL FUNCTION '${fm}' passes unknown parameter '${param}' (not in its signature; rules section 24)`));
        } else if (sig.get(param) !== curSection) {
          findings.push(mkFinding('ERROR', 'CALLFUNC_WRONG_SECTION', stmt.line, `CALL FUNCTION '${fm}' passes '${param}' under ${curSection} but it is ${sig.get(param)} (rules section 24)`));
        }
      }
    }
  }
  return findings;
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

function lintFile(abapPath, workFolder, opts = {}) {
  const fixtureMode = !!opts.fixture;
  const text = readFileSync(abapPath, 'utf8');
  const file = basename(abapPath);
  let findings = checkSource(text, file);
  const skipped = [];

  const stem = basename(abapPath).replace(/\.abap$/i, '');
  const folder = workFolder || dirname(abapPath);
  const ref = extractReferencedObjects(text);

  // text_elements.txt (generated sibling)
  const textElem = join(folder, `${stem}.text_elements.txt`);
  if (existsSync(textElem)) {
    findings = findings.concat(checkTextElements(text, parseTextSymbols(readFileSync(textElem, 'utf8')), basename(textElem)));
  } else if (fixtureMode && ref.textSyms.size > 0) {
    for (const [id, line] of ref.textSyms) {
      findings.push(mkFinding('ERROR', 'SIBLING_MISSING', line, `TEXT-${id} referenced but ${stem}.text_elements.txt is absent; generation must emit it (rules section 21)`));
    }
  } else {
    skipped.push('TEXT_SYMBOL_UNDECLARED');
  }

  // messages.txt (generated sibling)
  const messages = join(folder, `${stem}.messages.txt`);
  if (existsSync(messages)) {
    findings = findings.concat(checkMessages(text, parseMessages(readFileSync(messages, 'utf8')), basename(messages)));
  } else if (fixtureMode && ref.msgNums.size > 0) {
    for (const [id, line] of ref.msgNums) {
      findings.push(mkFinding('ERROR', 'SIBLING_MISSING', line, `MESSAGE number ${id} referenced but ${stem}.messages.txt is absent; generation must emit it (rules section 20)`));
    }
  } else {
    skipped.push('MESSAGE_NUM_UNDECLARED');
  }

  // _authz_signatures.txt (RFC snapshot)
  const authz = join(folder, '_authz_signatures.txt');
  if (existsSync(authz)) {
    findings = findings.concat(checkAuthz(text, parseAuthz(readFileSync(authz, 'utf8')), basename(authz), fixtureMode));
  } else if (fixtureMode && ref.authzObjs.size > 0) {
    for (const [obj, line] of ref.authzObjs) {
      findings.push(mkFinding('ERROR', 'SNAPSHOT_INCOMPLETE', line, `AUTHORITY-CHECK OBJECT '${obj}' referenced but _authz_signatures.txt is absent; offline regression would silently skip the SU21 field check (rules section 14)`));
    }
  } else {
    skipped.push('AUTHZ_*');
  }

  // _fm_signatures.txt (RFC snapshot)
  const fmSig = join(folder, '_fm_signatures.txt');
  if (existsSync(fmSig)) {
    findings = findings.concat(checkCallFunction(text, parseFmSignatures(readFileSync(fmSig, 'utf8')), basename(fmSig), fixtureMode));
  } else if (fixtureMode && ref.fms.size > 0) {
    for (const [fm, line] of ref.fms) {
      findings.push(mkFinding('ERROR', 'SNAPSHOT_INCOMPLETE', line, `CALL FUNCTION '${fm}' referenced but _fm_signatures.txt is absent; offline regression would silently fall back to training knowledge (rules section 24)`));
    }
  } else {
    skipped.push('CALLFUNC_*');
  }

  return { file, findings, skipped, fixtureMode };
}

function report(file, findings, skipped, fixtureMode) {
  for (const f of findings) {
    console.log(`LINT: ${f.severity} | ${f.rule} | ${file}:${f.line} | ${f.detail}`);
  }
  const errors = findings.filter(f => f.severity === 'ERROR').length;
  const warns = findings.filter(f => f.severity === 'WARN').length;
  const modeTail = fixtureMode ? ' mode=fixture' : '';
  console.log(`LINT-SUMMARY: errors=${errors} warns=${warns} skipped-rules=${skipped.join(',') || 'none'}${modeTail}`);
  return errors;
}

// ---------------------------------------------------------------------------
// Self-test (the CI gate: seeded good + bad cases the lint must classify)
// ---------------------------------------------------------------------------

function selftestSource() {
  const cases = [
    {
      name: 'clean OOP report',
      text: [
        'REPORT zclean MESSAGE-ID zmm.',
        'TYPES: BEGIN OF ty_row, matnr TYPE matnr, END OF ty_row.',
        'CLASS lcl_main DEFINITION.',
        '  PUBLIC SECTION.',
        '    METHODS run.',
        'ENDCLASS.',
        'DATA gv_count TYPE i.',
        'PARAMETERS p_matnr TYPE matnr.',
        'START-OF-SELECTION.',
        '  NEW lcl_main( )->run( ).',
        'CLASS lcl_main IMPLEMENTATION.',
        '  METHOD run.',
        '    SELECT matnr, mtart FROM mara INTO TABLE @DATA(lt) WHERE matnr = @p_matnr.',
        '  ENDMETHOD.',
        'ENDCLASS.',
      ].join('\n'),
      expectErrors: [],
    },
    {
      name: 'literal MESSAGE',
      text: "START-OF-SELECTION.\n  MESSAGE 'hard coded' TYPE 'E'.",
      expectErrors: ['LITERAL_MESSAGE'],
    },
    {
      name: 'TEXT-NNN assignment',
      text: 'START-OF-SELECTION.\n  TEXT-001 = lv_title.',
      expectErrors: ['TEXT_NNN_ASSIGN'],
    },
    {
      name: 'comma-SELECT with host var',
      text: 'START-OF-SELECTION.\n  SELECT matnr mtart FROM mara INTO TABLE @lt WHERE matnr = @lv.',
      expectErrors: ['COMMA_SELECT_HOSTVAR'],
    },
    {
      name: 'comma-SELECT classic (no host var) is OK',
      text: 'START-OF-SELECTION.\n  SELECT matnr mtart FROM mara INTO TABLE lt.',
      expectErrors: [],
    },
    {
      name: 'CLASS DEFINITION after event block',
      text: 'START-OF-SELECTION.\n  WRITE / lv.\nCLASS lcl_late DEFINITION.\nENDCLASS.',
      expectErrors: ['CLASS_DEF_AFTER_EVENT'],
    },
    {
      name: 'string in literal does not trip MESSAGE rule',
      text: "START-OF-SELECTION.\n  lv_text = 'MESSAGE ''x'' TYPE'.",
      expectErrors: [],
    },
    {
      name: 'SPLIT into a numeric receiver',
      text: 'DATA lv_qty TYPE p.\nDATA lv_name TYPE string.\nSTART-OF-SELECTION.\n  SPLIT lv_line AT \';\' INTO lv_name lv_qty.',
      expectErrors: ['SPLIT_INTO_NUMERIC'],
    },
    {
      name: 'SPLIT into char receivers is OK',
      text: 'DATA lv_a TYPE string.\nDATA lv_b TYPE c.\nSTART-OF-SELECTION.\n  SPLIT lv_line AT \';\' INTO lv_a lv_b.',
      expectErrors: [],
    },
  ];

  let failures = 0;
  for (const c of cases) {
    const findings = checkSource(c.text, c.name);
    const gotErrors = findings.filter(f => f.severity === 'ERROR').map(f => f.rule).sort();
    const want = [...c.expectErrors].sort();
    const ok = gotErrors.length === want.length && gotErrors.every((r, i) => r === want[i]);
    if (!ok) {
      failures++;
      console.log(`SELFTEST FAIL: ${c.name}`);
      console.log(`  expected ERRORs: [${want.join(', ')}]`);
      console.log(`  got ERRORs     : [${gotErrors.join(', ')}]`);
      for (const f of findings) console.log(`    ${f.severity} ${f.rule} @${f.line}: ${f.detail}`);
    } else {
      console.log(`SELFTEST ok: ${c.name} (errors=[${want.join(', ')}])`);
    }
  }
  return failures;
}

// Fixture-mode self-test: writes a temp work folder with a .abap that calls a
// BAPI + checks an authz object, then runs lintFile under --fixture against
// (a) a COMPLETE snapshot -> no SNAPSHOT_INCOMPLETE, (b) an INCOMPLETE snapshot
// (UNAVAILABLE rows) -> SNAPSHOT_INCOMPLETE fires, (c) absent snapshot files ->
// SNAPSHOT_INCOMPLETE fires. This proves the green-wash hole is closed.
function selftestFixture() {
  const abap = [
    'REPORT zfix.',
    'START-OF-SELECTION.',
    "  AUTHORITY-CHECK OBJECT 'M_MATE_MAR' ID 'ACTVT' FIELD '01' ID 'BEGRU' FIELD space.",
    "  CALL FUNCTION 'BAPI_MATERIAL_SAVEDATA'",
    '    EXPORTING headdata = ls_head',
    '    IMPORTING return = ls_return.',
  ].join('\n');

  const completeFm = [
    'FM_NAME\tSECTION\tPARAM_NAME\tOPTIONAL\tTYPE_REF\tTYPE_KIND',
    'BAPI_MATERIAL_SAVEDATA\tEXPORTING\tHEADDATA\t\tBAPI_MARA\tTDEF',
    'BAPI_MATERIAL_SAVEDATA\tIMPORTING\tRETURN\t\tBAPIRET2\tTDEF',
  ].join('\n');
  const completeAuthz = [
    'OBJCT\tPOSITION\tFIELD',
    'M_MATE_MAR\t1\tACTVT',
    'M_MATE_MAR\t2\tBEGRU',
  ].join('\n');
  const incompleteFm = [
    'FM_NAME\tSECTION\tPARAM_NAME\tOPTIONAL\tTYPE_REF\tTYPE_KIND',
    'BAPI_MATERIAL_SAVEDATA\tUNAVAILABLE\t\t\t\t',
  ].join('\n');
  const incompleteAuthz = [
    'OBJCT\tPOSITION\tFIELD',
    'M_MATE_MAR\tUNAVAILABLE\t',
  ].join('\n');

  const runs = [
    { name: 'fixture: complete snapshot -> clean', fm: completeFm, authz: completeAuthz, expectIncomplete: false },
    { name: 'fixture: UNAVAILABLE rows -> incomplete', fm: incompleteFm, authz: incompleteAuthz, expectIncomplete: true },
    { name: 'fixture: absent snapshot files -> incomplete', fm: null, authz: null, expectIncomplete: true },
  ];

  let failures = 0;
  for (const r of runs) {
    const dir = mkdtempSync(join(tmpdir(), 'lintfx-'));
    try {
      const abapPath = join(dir, 'ZFIX.abap');
      writeFileSync(abapPath, abap, 'utf8');
      if (r.fm !== null) writeFileSync(join(dir, '_fm_signatures.txt'), r.fm, 'utf8');
      if (r.authz !== null) writeFileSync(join(dir, '_authz_signatures.txt'), r.authz, 'utf8');
      const { findings } = lintFile(abapPath, dir, { fixture: true });
      const hasIncomplete = findings.some(f => f.rule === 'SNAPSHOT_INCOMPLETE');
      if (hasIncomplete !== r.expectIncomplete) {
        failures++;
        console.log(`SELFTEST FAIL: ${r.name}`);
        console.log(`  expected SNAPSHOT_INCOMPLETE=${r.expectIncomplete} got=${hasIncomplete}`);
        for (const f of findings) console.log(`    ${f.severity} ${f.rule} @${f.line}: ${f.detail}`);
      } else {
        console.log(`SELFTEST ok: ${r.name}`);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
  return failures;
}

function selftest() {
  const f1 = selftestSource();
  const f2 = selftestFixture();
  const total = f1 + f2;
  const cases = 9 + 3;
  console.log(`SELFTEST-SUMMARY: ${cases - total}/${cases} cases passed`);
  return total === 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const argv = process.argv.slice(2);
if (argv.includes('--selftest')) {
  process.exit(selftest());
}
if (argv.length === 0) {
  console.error('usage: node lint-abap-contract.mjs <file.abap> [--work-folder <dir>] [--fixture] | --selftest');
  process.exit(2);
}
const fixture = argv.includes('--fixture');
const wfIdx = argv.indexOf('--work-folder');
const workFolder = resolveCliPath(wfIdx >= 0 ? argv[wfIdx + 1] : '');
const rawFileArg = argv.find((a, i) => !a.startsWith('--') && (wfIdx < 0 || i !== wfIdx + 1));
const fileArg = resolveCliPath(rawFileArg);
if (!fileArg || !existsSync(fileArg)) {
  console.error(`ERROR: file not found: ${rawFileArg}`);
  process.exit(2);
}
const { file, findings, skipped, fixtureMode } = lintFile(fileArg, workFolder, { fixture });
const errors = report(file, findings, skipped, fixtureMode);
process.exit(errors > 0 ? 1 : 0);
