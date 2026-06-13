#!/usr/bin/env node
// diff-abap-skeleton.mjs
//
// Deterministic, OFFLINE "skeleton diff" for generated ABAP. This is the
// logic-regression net the contract lint (lint-abap-contract.mjs) cannot be:
// the lint checks that the code obeys the project's contract rules; the
// skeleton diff checks that the generated program still COVERS the spec it was
// generated from -- i.e. that no validation rule, dependency, message, or
// selection field was silently dropped or re-mapped between generator/prompt
// changes.
//
// It compares the generator's own emitted manifest siblings
//   <stem>.traceability.txt  (spec-section -> code-location map; rules sect 17)
//   <stem>.deps.txt          (STANDARD_TABLES/BAPIS/CLASSES/AUTHZ_OBJECTS/...; sect 16)
//   <stem>.messages.txt      (NNN<TAB>TYPE<TAB>text; sect 20)
//   <stem>.text_elements.txt ([SELECTION_TEXTS]/[TEXT_SYMBOLS]; sect 21)
//   _selection_definition.txt (optional cross-check of the screen field count)
// against a per-fixture expected skeleton in case.json.
//
// The comparison is STRUCTURE/SET based, never byte/line based, because:
//   * traceability line numbers shift whenever the generator emits code
//     differently (reordering, comments, wrapping) -- they are stripped.
//   * spec-section ids and labels are free text -- only the STABLE part (the
//     id prefix before ':') and the deterministic target method are compared.
//   * the .abap source itself is NOT byte-compared (LLM generation is
//     non-deterministic). Logic INSIDE a method (right section, wrong field or
//     operator) is OUT OF SCOPE here -- that is the job of the live ABAP Unit
//     run on the _golden.txt rows, not this static skeleton.
//
// case.json (schema "sapdev.skeleton/1"):
//   {
//     "schema": "sapdev.skeleton/1",
//     "program": "ZMMRMAT058R01",
//     "deps": {                       // each listed name must be PRESENT (subset)
//       "STANDARD_TABLES": ["MARA","MAKT"],
//       "BAPIS": ["BAPI_MATERIAL_SAVEDATA"],
//       "AUTHZ_OBJECTS": ["M_MATE_MAR"]
//     },
//     "traceability": {
//       "min_by_category": { "Validation": 3, "Processing": 1, "FILE MAPPING": 4 },
//       "pairs": [ ["Validation #1","lcl_main->validate"], ... ]  // each must be PRESENT
//     },
//     "messages": ["001","002"],      // each message id must be PRESENT
//     "selection_texts_count": 5,     // exact count of [SELECTION_TEXTS] rows
//     "text_symbols": ["001","002"]   // each text symbol id must be PRESENT
//   }
// Every section is optional -- only what is present in case.json is asserted.
//
// Output grammar (stable):
//   SKELETON: <ok|miss> | <kind> | <detail>
//   SKELETON-SUMMARY: misses=<n> checks=<n> program=<name>
// Exit: 0 when no miss, 1 when any miss, 2 on bad invocation.

import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const DEP_SECTIONS = new Set(['STANDARD_TABLES', 'BAPIS', 'CLASSES', 'AUTHZ_OBJECTS', 'CUSTOM_OBJECTS']);

// --- parsers ---------------------------------------------------------------

// .deps.txt -> Map(section -> Set(NAME))
function parseDeps(content) {
  const out = new Map();
  let cur = null;
  for (const raw of content.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === '') continue;
    if (DEP_SECTIONS.has(line.toUpperCase())) { cur = line.toUpperCase(); if (!out.has(cur)) out.set(cur, new Set()); continue; }
    if (cur) out.get(cur).add(line.toUpperCase());
  }
  return out;
}

// .traceability.txt -> { pairs: Set("<tagId>||<method>"), tags: [normTagId...] }
// A line is  [<free-text id>] <arrow> <object>-><method> (line N)
// tagId  = normalized text before the first ':' inside the brackets (stable).
// method = location with the trailing "(line N)" stripped.
// The coarse "min_by_category" count is done at compare time by PREFIX-matching
// the normalized tag against the category key (e.g. "validation" matches
// "validation #1", "file mapping" matches "file mapping row 4"), which avoids
// having to guess where a free-text category ends.
function parseTraceability(content) {
  const pairs = new Set();
  const tags = [];
  for (const raw of content.split(/\r?\n/)) {
    const m = raw.match(/^\s*\[(.+?)\]\s*(?:→|->)\s*(.+?)\s*$/);
    if (!m) continue;
    const tagId = normTagId(m[1].trim());
    const method = m[2].replace(/\s*\(line\s+\d+\)\s*$/i, '').trim().toLowerCase();
    pairs.add(tagId + '||' + method);
    tags.push(tagId);
  }
  return { pairs, tags };
}

// Stable tag id: text before the first ':' , whitespace-collapsed, lowercased.
function normTagId(tag) {
  return tag.split(':')[0].replace(/\s+/g, ' ').trim().toLowerCase();
}

// Normalize a category key for prefix matching (whitespace-collapsed, lowercased).
function normKey(s) {
  return String(s).replace(/\s+/g, ' ').trim().toLowerCase();
}

// .messages.txt -> Set(NNN)
function parseMessages(content) {
  const out = new Set();
  for (const line of content.split(/\r?\n/)) {
    const m = line.match(/^\s*(\d{1,3})\t/);
    if (m) out.add(m[1].padStart(3, '0'));
  }
  return out;
}

// .text_elements.txt -> { selectionCount, symbols: Set(NNN) }
function parseTextElements(content) {
  const symbols = new Set();
  let selectionCount = 0;
  let block = null;
  for (const raw of content.split(/\r?\n/)) {
    const line = raw.replace(/\s+$/, '');
    if (/^\s*\[SELECTION_TEXTS\]/i.test(line)) { block = 'sel'; continue; }
    if (/^\s*\[TEXT_SYMBOLS\]/i.test(line)) { block = 'sym'; continue; }
    if (/^\s*\[/.test(line)) { block = null; continue; }
    if (line.trim() === '') continue;
    if (block === 'sel') selectionCount++;
    else if (block === 'sym') {
      const m = line.match(/^\s*(\d{1,3})\b/);
      if (m) symbols.add(m[1].padStart(3, '0'));
    }
  }
  return { selectionCount, symbols };
}

// _selection_definition.txt -> data-row count (excludes header)
function parseSelectionDefCount(content) {
  const rows = content.split(/\r?\n/).filter(l => l.trim() !== '');
  return Math.max(0, rows.length - 1); // row 0 is the header
}

// --- comparison ------------------------------------------------------------

function diffSkeleton(folder, stem, expected) {
  const misses = [];
  let checks = 0;
  const miss = (kind, detail) => misses.push({ kind, detail });

  const read = (name) => {
    const p = join(folder, name);
    return existsSync(p) ? readFileSync(p, 'utf8') : null;
  };

  // deps
  if (expected.deps) {
    const c = read(`${stem}.deps.txt`);
    if (c === null) { checks++; miss('deps', `${stem}.deps.txt absent but case.json expects deps`); }
    else {
      const actual = parseDeps(c);
      for (const [section, names] of Object.entries(expected.deps)) {
        const have = actual.get(section.toUpperCase()) || new Set();
        for (const n of names) {
          checks++;
          if (!have.has(String(n).toUpperCase())) miss('dep', `${section}/${n} expected but absent from ${stem}.deps.txt`);
        }
      }
    }
  }

  // traceability
  if (expected.traceability) {
    const c = read(`${stem}.traceability.txt`);
    if (c === null) { checks++; miss('traceability', `${stem}.traceability.txt absent but case.json expects traceability`); }
    else {
      const actual = parseTraceability(c);
      const exp = expected.traceability;
      if (exp.min_by_category) {
        for (const [cat, min] of Object.entries(exp.min_by_category)) {
          checks++;
          const key = normKey(cat);
          const got = actual.tags.filter(t => t.startsWith(key)).length;
          if (got < min) miss('trace-count', `category '${cat}': ${got} entries, expected >= ${min}`);
        }
      }
      if (exp.pairs) {
        for (const [tag, method] of exp.pairs) {
          checks++;
          const key = normTagId(tag) + '||' + String(method).trim().toLowerCase();
          if (!actual.pairs.has(key)) miss('trace-pair', `'${tag}' -> '${method}' not present (dropped or re-mapped)`);
        }
      }
    }
  }

  // messages
  if (expected.messages) {
    const c = read(`${stem}.messages.txt`);
    if (c === null) { checks++; miss('messages', `${stem}.messages.txt absent but case.json expects messages`); }
    else {
      const actual = parseMessages(c);
      for (const id of expected.messages) {
        checks++;
        if (!actual.has(String(id).padStart(3, '0'))) miss('message', `message ${id} expected but absent from ${stem}.messages.txt`);
      }
    }
  }

  // text_elements + optional selection-definition cross-check
  if (expected.selection_texts_count != null || expected.text_symbols) {
    const c = read(`${stem}.text_elements.txt`);
    if (c === null) { checks++; miss('text_elements', `${stem}.text_elements.txt absent but case.json expects text elements`); }
    else {
      const actual = parseTextElements(c);
      if (expected.selection_texts_count != null) {
        checks++;
        if (actual.selectionCount !== expected.selection_texts_count) {
          miss('selection-count', `[SELECTION_TEXTS] has ${actual.selectionCount} rows, expected ${expected.selection_texts_count}`);
        }
        // cross-check against _selection_definition.txt when present
        const sd = read('_selection_definition.txt');
        if (sd !== null) {
          checks++;
          const n = parseSelectionDefCount(sd);
          if (n !== actual.selectionCount) {
            miss('selection-xref', `[SELECTION_TEXTS] (${actual.selectionCount}) != _selection_definition.txt rows (${n})`);
          }
        }
      }
      if (expected.text_symbols) {
        for (const id of expected.text_symbols) {
          checks++;
          if (!actual.symbols.has(String(id).padStart(3, '0'))) miss('text-symbol', `TEXT-${id} expected but absent from [TEXT_SYMBOLS]`);
        }
      }
    }
  }

  return { misses, checks };
}

function report(program, misses, checks) {
  for (const m of misses) console.log(`SKELETON: miss | ${m.kind} | ${m.detail}`);
  if (misses.length === 0) console.log(`SKELETON: ok | all | ${checks} expectation(s) satisfied`);
  console.log(`SKELETON-SUMMARY: misses=${misses.length} checks=${checks} program=${program}`);
  return misses.length;
}

// --- self-test -------------------------------------------------------------

function selftest() {
  const stem = 'ZDEMO';
  const traceGood = [
    'SPEC SECTION → ABAP LOCATION',
    '[Validation #1: code must be I or U]   → lcl_main->validate (line 142)',
    '[Validation #2: material must exist]   → lcl_main->validate (line 156)',
    '[Processing 3.2: BAPI call]            → lcl_main->execute  (line 198)',
    '[FILE MAPPING row 4: MARA-MATNR]       → lcl_main->build    (line 84)',
  ].join('\n');
  // "swap": Validation #1 now maps to a DIFFERENT method (the VAL3-vs-VAL1 class).
  const traceSwap = traceGood.replace('[Validation #1: code must be I or U]   → lcl_main->validate (line 142)',
    '[Validation #1: code must be I or U]   → lcl_main->build (line 142)');
  const depsGood = 'STANDARD_TABLES\nMARA\nMAKT\n\nBAPIS\nBAPI_MATERIAL_SAVEDATA\n\nAUTHZ_OBJECTS\nM_MATE_MAR\n';
  const depsDrop = 'STANDARD_TABLES\nMARA\n\nBAPIS\nBAPI_MATERIAL_SAVEDATA\n\nAUTHZ_OBJECTS\nM_MATE_MAR\n'; // MAKT dropped
  const messages = '001\tE\tInvalid code\n002\tE\tMaterial missing\n';
  const textElems = '[SELECTION_TEXTS]\nP_BUKRS\tCompany\nP_WERKS\tPlant\n\n[TEXT_SYMBOLS]\n001\tSelection\n';

  const caseJson = {
    schema: 'sapdev.skeleton/1', program: stem,
    deps: { STANDARD_TABLES: ['MARA', 'MAKT'], BAPIS: ['BAPI_MATERIAL_SAVEDATA'], AUTHZ_OBJECTS: ['M_MATE_MAR'] },
    traceability: { min_by_category: { Validation: 2, Processing: 1, 'FILE MAPPING': 1 }, pairs: [['Validation #1', 'lcl_main->validate'], ['Processing 3.2', 'lcl_main->execute']] },
    messages: ['001', '002'],
    selection_texts_count: 2,
    text_symbols: ['001'],
  };

  const runs = [
    { name: 'skeleton: matching golden -> ok', trace: traceGood, deps: depsGood, expectMiss: false },
    { name: 'skeleton: re-mapped validation pair -> miss (swap)', trace: traceSwap, deps: depsGood, expectMiss: true, wantKind: 'trace-pair' },
    { name: 'skeleton: dropped dependency -> miss', trace: traceGood, deps: depsDrop, expectMiss: true, wantKind: 'dep' },
  ];

  let failures = 0;
  for (const r of runs) {
    const dir = mkdtempSync(join(tmpdir(), 'skel-'));
    try {
      writeFileSync(join(dir, `${stem}.traceability.txt`), r.trace, 'utf8');
      writeFileSync(join(dir, `${stem}.deps.txt`), r.deps, 'utf8');
      writeFileSync(join(dir, `${stem}.messages.txt`), messages, 'utf8');
      writeFileSync(join(dir, `${stem}.text_elements.txt`), textElems, 'utf8');
      const { misses } = diffSkeleton(dir, stem, caseJson);
      const got = misses.length > 0;
      const kindOk = !r.wantKind || misses.some(m => m.kind === r.wantKind);
      if (got !== r.expectMiss || !kindOk) {
        failures++;
        console.log(`SELFTEST FAIL: ${r.name}`);
        console.log(`  expected miss=${r.expectMiss}${r.wantKind ? ` kind=${r.wantKind}` : ''} got misses=${misses.length}`);
        for (const m of misses) console.log(`    ${m.kind}: ${m.detail}`);
      } else {
        console.log(`SELFTEST ok: ${r.name}`);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
  console.log(`SELFTEST-SUMMARY: ${runs.length - failures}/${runs.length} cases passed`);
  return failures === 0 ? 0 : 1;
}

// --- CLI -------------------------------------------------------------------

const argv = process.argv.slice(2);
if (argv.includes('--selftest')) {
  process.exit(selftest());
}
function argval(name) { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; }
const workFolder = argval('--work-folder');
const program = argval('--program');
const casePath = argval('--case');
if (!workFolder || !program || !casePath) {
  console.error('usage: node diff-abap-skeleton.mjs --work-folder <dir> --program <stem> --case <case.json> | --selftest');
  process.exit(2);
}
if (!existsSync(casePath)) { console.error(`ERROR: case file not found: ${casePath}`); process.exit(2); }
let expected;
try { expected = JSON.parse(readFileSync(casePath, 'utf8')); }
catch (e) { console.error(`ERROR: bad case.json: ${e.message}`); process.exit(2); }
const { misses, checks } = diffSkeleton(workFolder, program, expected);
const n = report(program, misses, checks);
process.exit(n > 0 ? 1 : 0);
