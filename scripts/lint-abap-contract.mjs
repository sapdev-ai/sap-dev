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
//   node scripts/lint-abap-contract.mjs <file.abap> [--work-folder <dir>]
//   node scripts/lint-abap-contract.mjs --selftest
//
// --work-folder lets the sibling-file (.text_elements.txt, .messages.txt) and
// signature (_authz_signatures.txt, _fm_signatures.txt) rules run; without it
// those rules are skipped (reported as such, never as a pass).
//
// Output grammar (stable):
//   LINT: <ERROR|WARN> | <RULE_ID> | <file>:<line> | <detail>
//   LINT-SUMMARY: errors=<n> warns=<n> skipped-rules=<csv>
// Exit: 0 when no ERROR findings, 1 when any ERROR finding, 2 on bad invocation.

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';

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

function checkSource(text, file) {
  const findings = [];
  const rawLines = text.split(/\r?\n/);
  const blanked = rawLines.map(blankNoise);

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
      if (/^\s*CLASS\s+\w+\s+DEFINITION\b/i.test(b)) {
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
  for (const stmt of splitStatements(rawLines, blanked)) {
    const sb = stmt.blank;
    if (!/^\s*SELECT\b/i.test(sb)) continue;
    if (!/@/.test(sb)) continue;                 // no host var -> classic syntax allowed
    const m = sb.match(/\bSELECT\b\s+(?:SINGLE\s+|DISTINCT\s+)*([\s\S]*?)\bFROM\b/i);
    if (!m) continue;
    const cols = m[1].trim();
    if (cols === '*' || cols === '') continue;   // SELECT * is a separate rule
    if (cols.includes(',')) continue;            // already comma-separated -> ok
    // count whitespace-separated tokens that look like columns/host-vars
    const toks = cols.split(/\s+/).filter(Boolean);
    if (toks.length >= 2) {
      findings.push(mkFinding('ERROR', 'COMMA_SELECT_HOSTVAR', stmt.line, 'SELECT with @host variables needs a comma-separated field list (strict Open SQL >= 7.50); space-separated columns are a compile error (rules section 9)'));
    }
  }

  return findings;
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

// ---------------------------------------------------------------------------
// Sibling-file sync rules (need the committed .text_elements.txt / .messages.txt)
// ---------------------------------------------------------------------------

// R-TEXTSYM: every TEXT-NNN referenced in the source has a [TEXT_SYMBOLS] entry.
function checkTextElements(text, textElemPath) {
  const findings = [];
  const declared = new Set();
  const te = readFileSync(textElemPath, 'utf8').split(/\r?\n/);
  let inSyms = false;
  for (const line of te) {
    if (/^\s*\[TEXT_SYMBOLS\]/i.test(line)) { inSyms = true; continue; }
    if (/^\s*\[/.test(line)) { inSyms = false; continue; }
    if (inSyms) {
      const m = line.match(/^\s*(\d{1,3})\b/);
      if (m) declared.add(m[1].padStart(3, '0'));
    }
  }
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
        findings.push(mkFinding('ERROR', 'TEXT_SYMBOL_UNDECLARED', i + 1, `TEXT-${m[1]} referenced but absent from [TEXT_SYMBOLS] in ${basename(textElemPath)} (rules section 21)`));
      }
    }
  }
  return findings;
}

// R-MSGNUM: every MESSAGE eNNN(class) / iNNN / wNNN ... referenced has a row in
// the .messages.txt sibling.
function checkMessages(text, messagesPath) {
  const findings = [];
  const declared = new Set();
  const mf = readFileSync(messagesPath, 'utf8').split(/\r?\n/);
  for (const line of mf) {
    const m = line.match(/^\s*(\d{1,3})\t/);
    if (m) declared.add(m[1].padStart(3, '0'));
  }
  const rawLines = text.split(/\r?\n/);
  for (let i = 0; i < rawLines.length; i++) {
    const b = blankNoise(rawLines[i]);
    // MESSAGE e012(zxx) ... or MESSAGE ID ... TYPE ... NUMBER 012
    const re = /\bMESSAGE\s+[eiwsax](\d{1,3})\s*\(/gi;
    let m;
    while ((m = re.exec(b)) !== null) {
      const id = m[1].padStart(3, '0');
      if (!declared.has(id)) {
        findings.push(mkFinding('ERROR', 'MESSAGE_NUM_UNDECLARED', i + 1, `message number ${m[1]} referenced but absent from ${basename(messagesPath)} (rules section 20)`));
      }
    }
  }
  return findings;
}

// ---------------------------------------------------------------------------
// Signature-based rules (need committed _authz_signatures.txt / _fm_signatures.txt)
// ---------------------------------------------------------------------------

// R-AUTHZ: each AUTHORITY-CHECK OBJECT '<X>' must list exactly the fields that
// _authz_signatures.txt records for <X> (offline equivalent of the SU21 check).
function checkAuthz(text, authzPath) {
  const findings = [];
  // OBJCT \t POSITION \t FIELD  (header on row 1)
  const byObj = new Map();
  const af = readFileSync(authzPath, 'utf8').split(/\r?\n/);
  for (let i = 1; i < af.length; i++) {
    const cols = af[i].split('\t');
    if (cols.length < 3) continue;
    const obj = (cols[0] || '').trim().toUpperCase();
    const field = (cols[2] || '').trim().toUpperCase();
    if (!obj || !field) continue;
    if (!byObj.has(obj)) byObj.set(obj, new Set());
    byObj.get(obj).add(field);
  }
  // Parse AUTHORITY-CHECK statements.
  const rawLines = text.split(/\r?\n/);
  const blanked = rawLines.map(blankNoise);
  for (const stmt of splitStatements(rawLines, blanked)) {
    const m = stmt.content.match(/\bAUTHORITY-CHECK\s+OBJECT\s+'([^']+)'/i);
    if (!m) continue;
    const obj = m[1].trim().toUpperCase();
    if (!byObj.has(obj)) {
      findings.push(mkFinding('ERROR', 'AUTHZ_OBJECT_UNKNOWN', stmt.line, `AUTHORITY-CHECK OBJECT '${obj}' not in ${basename(authzPath)} (resolve via SU21/USOBT; rules section 14)`));
      continue;
    }
    const expected = byObj.get(obj);
    const usedFields = new Set();
    const fre = /\bID\s+'([^']+)'/gi;
    let fm;
    while ((fm = fre.exec(stmt.content)) !== null) usedFields.add(fm[1].trim().toUpperCase());
    // every expected field must be present (DUMMY counts as covering a field
    // only via an explicit ID '<field>' FIELD DUMMY clause, which still names it)
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

// R-CALLFUNC: each CALL FUNCTION '<FM>' parameter name must exist in the FM's
// signature (_fm_signatures.txt) and be in the section it is passed under.
function checkCallFunction(text, fmPath) {
  const findings = [];
  // FM_NAME \t SECTION \t PARAM_NAME \t OPTIONAL \t TYPE_REF \t TYPE_KIND
  const byFm = new Map(); // fm -> Map(param -> section)
  const ff = readFileSync(fmPath, 'utf8').split(/\r?\n/);
  let unavailable = new Set();
  for (let i = 1; i < ff.length; i++) {
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
  const sectionKeywords = /^(EXPORTING|IMPORTING|TABLES|CHANGING|EXCEPTIONS)$/i;
  const rawLines = text.split(/\r?\n/);
  const blanked = rawLines.map(blankNoise);
  for (const stmt of splitStatements(rawLines, blanked)) {
    const m = stmt.content.match(/\bCALL\s+FUNCTION\s+'([^']+)'([\s\S]*)/i);
    if (!m) continue;
    const fm = m[1].trim().toUpperCase();
    if (unavailable.has(fm) || !byFm.has(fm)) continue; // signature absent -> skip (honest)
    const sig = byFm.get(fm);
    const body = m[2];
    // walk the parameter bindings section by section
    const tokens = body.split(/\s+/).filter(Boolean);
    let curSection = '';
    for (let t = 0; t < tokens.length; t++) {
      const tok = tokens[t].replace(/[.\,]$/, '');
      if (sectionKeywords.test(tok)) { curSection = tok.toUpperCase(); continue; }
      // a "<param> =" binding
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

function lintFile(abapPath, workFolder) {
  const text = readFileSync(abapPath, 'utf8');
  const file = basename(abapPath);
  let findings = checkSource(text, file);
  const skipped = [];

  const stem = basename(abapPath).replace(/\.abap$/i, '');
  const folder = workFolder || dirname(abapPath);

  const textElem = join(folder, `${stem}.text_elements.txt`);
  if (existsSync(textElem)) findings = findings.concat(checkTextElements(text, textElem));
  else skipped.push('TEXT_SYMBOL_UNDECLARED');

  const messages = join(folder, `${stem}.messages.txt`);
  if (existsSync(messages)) findings = findings.concat(checkMessages(text, messages));
  else skipped.push('MESSAGE_NUM_UNDECLARED');

  const authz = join(folder, '_authz_signatures.txt');
  if (existsSync(authz)) findings = findings.concat(checkAuthz(text, authz));
  else skipped.push('AUTHZ_*');

  const fmSig = join(folder, '_fm_signatures.txt');
  if (existsSync(fmSig)) findings = findings.concat(checkCallFunction(text, fmSig));
  else skipped.push('CALLFUNC_*');

  return { file, findings, skipped };
}

function report(file, findings, skipped) {
  for (const f of findings) {
    console.log(`LINT: ${f.severity} | ${f.rule} | ${file}:${f.line} | ${f.detail}`);
  }
  const errors = findings.filter(f => f.severity === 'ERROR').length;
  const warns = findings.filter(f => f.severity === 'WARN').length;
  console.log(`LINT-SUMMARY: errors=${errors} warns=${warns} skipped-rules=${skipped.join(',') || 'none'}`);
  return errors;
}

// ---------------------------------------------------------------------------
// Self-test (the CI gate: seeded good + bad cases the lint must classify)
// ---------------------------------------------------------------------------

function selftest() {
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
  console.log(`SELFTEST-SUMMARY: ${cases.length - failures}/${cases.length} cases passed`);
  return failures === 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const argv = process.argv.slice(2);
if (argv.includes('--selftest')) {
  process.exit(selftest());
}
if (argv.length === 0) {
  console.error('usage: node lint-abap-contract.mjs <file.abap> [--work-folder <dir>] | --selftest');
  process.exit(2);
}
const wfIdx = argv.indexOf('--work-folder');
const workFolder = wfIdx >= 0 ? argv[wfIdx + 1] : '';
const fileArg = argv.find((a, i) => !a.startsWith('--') && (wfIdx < 0 || i !== wfIdx + 1));
if (!fileArg || !existsSync(fileArg)) {
  console.error(`ERROR: file not found: ${fileArg}`);
  process.exit(2);
}
const { file, findings, skipped } = lintFile(fileArg, workFolder);
const errors = report(file, findings, skipped);
process.exit(errors > 0 ? 1 : 0);
