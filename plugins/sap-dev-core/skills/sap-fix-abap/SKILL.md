---
name: sap-fix-abap
description: |
  Fixes ABAP source code issues found by sap-check-abap (all dimensions).
  Reads the check result file(s), builds a fix plan, and applies fixes:
  - NAMING violations: renames variables throughout the file
  - UNUSED variables: comments out declarations
  - SYNTAX-SAFE rewrites (SQL_STRICT_COMMA / line-length / DECL_ORDER)
  - CALL FUNCTION param fixes (UNKNOWN_PARAM rename / MISSING_MANDATORY stub /
    WRONG_SECTION move) from the `fm` dimension — absorbed from the former sap-fix-fm
  - SYNTAX errors: a bounded AI-assisted check->patch->re-check loop that drives the
    headless `sap_rfc_syntax_check.ps1` engine (no blind auto-fix)
  - TYPE_NOT_FOUND and other semantic codes: flagged for manual review
  Creates a timestamped backup (.bak) before modifying the source file.
  Prerequisites: Run sap-check-abap first to produce the result file(s). The `fm`
  and `syntax` fix paths need SAP NCo 3.1 (32-bit) + the dev-init wrapper.
argument-hint: "<path-to-abap-source-file> [<path-to-check-result-tsv>] [--syntax-loop]"
---

# SAP Fix ABAP Skill

You fix ABAP source code quality issues detected by sap-check-abap. You rename variables that violate naming conventions, comment out unused declarations, and flag type issues for manual review. You always back up the file before making changes.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — offline fixer, but rule applies to downstream deploy skills the fixed source feeds |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — fixes applied here (variable renames, unused-comment-out) must preserve / restore modern-ABAP conventions; never introduce literal MESSAGE strings or downgrade syntax to obsolete forms while fixing |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve cross-plugin paths: 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\settings.json` and (if present) `sap-dev-core\settings.local.json`. Set `{WORK_TEMP}` = `{work_dir}\temp` and
ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's `_run.json` state under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{RUN_TEMP}\sap_fix_abap_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_fix_abap_run.json" -Skill sap-fix-abap -ParamsJson "{\"abap_file\":\"<ABAP_FILE>\",\"result_tsv\":\"<TSV>\"}"
```

---

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:
- **ABAP source file path** — required. Ask if not provided.
- **Check result TSV path** — optional; default is `<abap-file>.check.tsv`.

Also look for the sibling result files the other `sap-check-abap` dimensions
write (fix whichever are present):
- `<abap-file>.check_fm.tsv` — `fm`-dimension findings (CALL FUNCTION params) → Step 6b.
- `<abap-file>.syntax.tsv` — `syntax`-dimension findings → the Step 8 syntax loop.

Verify both files exist:
```bash
powershell -Command "if (Test-Path 'ABAP_FILE') { 'OK' } else { 'NOT FOUND' }"
powershell -Command "if (Test-Path 'RESULT_FILE') { 'OK' } else { 'NOT FOUND' }"
```

If either file does not exist, tell the user and stop.

---

## Step 2 — Read and Parse the Result TSV

Read the result TSV file. The file begins with a header section:

```
STATUS:	SUCCESS_WITH_ISSUES: N declaration(s), M issue(s).
ABAP_FILE	<path>
NAMING_RULES	<path>
TIMESTAMP	<datetime>
TOTAL_DECLARATIONS	N
TOTAL_ISSUES	M
```

Followed by a blank line, column headers, and tab-delimited finding rows:

```
CHECK_TYPE	SEVERITY	LINE	VARIABLE	SCOPE	DATA_KIND	DETAIL	FIX_ADVICE
```

Parse all findings into a list. Classify each by fixability. The table covers
EVERY code `/sap-check-abap` can emit (VBS engine, Step 1.5 object naming, and
the Step 3.5 / 3.6 / 3.7 sidecar validators). **Auto** is reserved for
transforms that cannot change runtime semantics; any code whose fix could —
even when a mechanical rewrite looks tempting — is **Manual** with guidance.

| CHECK_TYPE | Fixable? | Action |
|---|---|---|
| `NAMING` | Auto | Rename variable throughout file (case-insensitive, word-boundary aware) |
| `UNUSED` | Auto | Comment out declaration line (skip chain declarations) |
| `SQL_STRICT_COMMA` | Auto | Insert the missing commas between SELECT-list fields (`SELECT a b c` → `SELECT a, b, c`) — pure syntax; SAP rejects the statement without them (§9) |
| `LINE_TOO_LONG` / `LINE_HARD_LIMIT` | Auto | Wrap the statement at a token boundary onto a continuation line. **Manual** when the overlong stretch is inside a string literal — splitting a literal changes its value |
| `CLASS_DEF_AFTER_EVENT` | Auto | Move the `CLASS … DEFINITION` block, unchanged, above the first event block — declaration reordering only (§10) |
| `TYPE_NOT_FOUND` | Manual | Create the type in SE11 or correct the type name |
| `TYPE_RESOLVED` | No — INFO | Informational — skip |
| `SQL_TABLE_NOT_FOUND` | Manual | Correct the table name in SQL, or create the Z-table via `/sap-se11` first |
| `SQL_FIELD_NOT_FOUND` | Manual | Correct the field name against the SE11 definition |
| `OBJECT_NAMING` | Manual | Renaming a program / FORM / class / method changes the deployment identity and every call site; spec names are authoritative — confirm with the user first |
| `METHOD_PARAM_NOT_FOUND` | Manual | Align the call with the class's METHODS signature (or fix the signature) — which side is wrong needs human judgment |
| `LITERAL_MESSAGE` | Manual | Allocate a message number in the project message class, add it to the `.messages.txt` sibling, replace with `MESSAGE eNNN(<class>)` — number allocation is a project decision (§20) |
| `TEXT_NNN_ASSIGN` | Manual | TEXT-NNN symbols are read-only; assign to a variable instead, or populate the text via `.text_elements.txt` (§21) |
| `TEXT_SYMBOL_UNDECLARED` | Manual | Add the TEXT-NNN row (with its text) to `[TEXT_SYMBOLS]` in the `.text_elements.txt` sibling, or fix the typoed reference (§21) |
| `MESSAGE_NUM_UNDECLARED` | Manual | Add the message (with its text) to the `.messages.txt` sibling, or fix the typoed number (§20) |
| `SELECT_STAR` | Manual | Replace `*` with the explicit column list actually used — dropping a still-needed column breaks runtime, so the used-field analysis needs review (§12) |
| `SELECT_IN_LOOP` | Manual | Restructure: pre-select into an internal table before the loop, then READ from it (§12) |
| `FOR_ALL_ENTRIES_NO_GUARD` | Manual | Wrap the SELECT in `IF <itab> IS NOT INITIAL … ENDIF` (or add an early `IF <itab> IS INITIAL. RETURN. ENDIF.`) — this changes the empty-driver behaviour by design; decide whether the target table must also be CLEARed on the empty path (§12) |
| `MESSAGE_E_IN_METHOD` | Manual | Replace with RAISE EXCEPTION / result-table pattern, or `MESSAGE … INTO` capture — control-flow change (§11) |
| `LOOP_WHERE_EXIT` | Manual | Replace with `READ TABLE … TRANSPORTING NO FIELDS` only after confirming the loop body has no other effect (§19) |
| `SPLIT_INTO_NUMERIC` | Manual | Introduce a character-typed intermediate as the SPLIT receiver, then MOVE to the numeric target — adds a conversion step (§25) |
| `METHOD_TOO_LONG` | Manual | Split into smaller methods (§18) |
| `MISSING_AT_HOST_VAR` | Manual | Add `@` host-variable escapes consistently across the WHOLE statement — mixing escaped and unescaped is itself a syntax error (§13) |
| `STRING_CONCAT_SQL` | Manual | Replace dynamic-SQL string concatenation with static SQL or a whitelisted-token approach (§13) |
| `MISSING_AUTHZ_CHECK` | Manual | Add an AUTHORITY-CHECK shaped per the live SU21 field list (`_authz_signatures.txt`) before the write (§14) |
| `STRUCT_FIELD_MISSING` / `STRUCT_TYPE_MISSING` | Manual | Fix the field / type against `_struct_signatures.txt` or SE11 — the correct target field is a semantic decision (§22) |
| `AUTHZ_OBJECT_MISSING` / `AUTHZ_FIELD_COUNT` / `AUTHZ_FIELD_NAME` | Manual | Re-shape the AUTHORITY-CHECK to the SU21 field list in `_authz_signatures.txt`; if the cache is stale, `/sap-gen-abap --refresh-cache` (§14) |
| `SPEC_DEP_MISSING` / `SPEC_MESSAGE_MISSING` / `SPEC_TEXTSYM_MISSING` / `SPEC_SELECTION_COUNT` | Manual | Spec-coverage gaps — regenerate via `/sap-gen-abap` or add the missing artefact; do NOT hand-patch manifest files just to silence the gap |
| `SPEC_TRACEABILITY_INFO` | No — INFO | Informational — skip |
| `CONV_CURR_MISSING_REF` / `CONV_CURR_DISPLAY_TO_BAPI` | Manual | Map the currency (CUKY) / unit (UNIT) reference column alongside the amount, or fix the conversion path (§28) |
| `UNKNOWN_PARAM` *(fm)* | Auto (RFC) | Rename the `CALL FUNCTION` parameter to the correct FM parameter name (re-fetched live) — Step 6b |
| `WRONG_SECTION` *(fm)* | Auto (RFC) | Move the parameter assignment to the correct keyword section (EXPORTING/IMPORTING/CHANGING/TABLES) — Step 6b |
| `MISSING_MANDATORY` *(fm)* | Auto (RFC) | Insert a stub line for the missing mandatory parameter (value left for the user to fill) — Step 6b |
| `TYPE_INCOMPATIBLE` / `TYPE_WARNING` / `FM_NOT_FOUND` *(fm)* | Manual | Adjust the passed variable's type to the FM parameter, or fix the FM name — a semantic decision |
| `SYNTAX_ERROR` *(syntax)* | Auto (AI loop) | Bounded check→patch→re-check loop (Step 8) — Claude edits the source per LINE/COL/MESSAGE; never a blind rewrite |
| `SYNTAX_WARNING` / `SYNTAX_COULD_NOT_CHECK` / `FM_COULD_NOT_CHECK` | Manual / skip | Review the warning, or note the dimension could not run (RFC off / wrapper absent) |

If there are no fixable issues, tell the user "No fixable issues found in result file." and stop.

---

## Step 3 — Build Fix Plan

### Fix type: RENAME (NAMING violations)

For each `NAMING` finding, the `FIX_ADVICE` column contains the suggested rename (e.g., "Rename TT_MESSAGE to GT_MESSAGE").

Extract the old name and new name from the FIX_ADVICE. Plan a **global rename** — the variable name must be replaced everywhere it appears in the ABAP source:
- Declaration lines (DATA, CONSTANTS, FIELD-SYMBOLS, PARAMETERS, etc.)
- Assignment statements
- FORM/METHOD parameter references
- WRITE, MOVE, APPEND, READ TABLE, LOOP AT, etc.
- Condition expressions (IF, CASE, CHECK, WHERE)

The rename is **case-insensitive** and **word-boundary aware** — only replace the variable name when it appears as a complete token, not as a substring of another name.

### Fix type: COMMENT_OUT (UNUSED variables)

For each `UNUSED` finding:
- Prepend `*` to the declaration line (making it an ABAP comment)
- If the declaration is part of a chain (`DATA: a TYPE t1, b TYPE t2.`), do **not** comment out the entire line — instead, note it for manual review and skip.

### Fix type: SYNTAX_SAFE (SQL_STRICT_COMMA / LINE_TOO_LONG / LINE_HARD_LIMIT / CLASS_DEF_AFTER_EVENT)

Semantics-preserving rewrites, applied with the Edit tool per the Step 2 table:

- `SQL_STRICT_COMMA` — insert the missing commas between the SELECT-list
  fields named in the finding (and only there).
- `LINE_TOO_LONG` / `LINE_HARD_LIMIT` — break the statement at a token
  boundary onto an indented continuation line. If the overlong stretch is
  inside a string literal, downgrade to manual (note it in the plan).
- `CLASS_DEF_AFTER_EVENT` — move the entire `CLASS … DEFINITION` …
  `ENDCLASS.` block, byte-identical, to just before the first event block.

### Fix type: MANUAL (all codes classified Manual in Step 2)

These cannot be safely auto-fixed. List them separately for user awareness
with the per-code guidance from the Step 2 table (e.g. `TYPE_NOT_FOUND` —
create the type in SE11 or correct the type name).

### Present the plan

Show the complete fix plan as a numbered list:

```
Fix plan for ABAP file: <path>
(backup will be created as <path>.<YYYYMMDD_HHMMSS>.bak)

Auto-fixable:
  [1] RENAME  Line 22   TT_MESSAGE  →  GT_MESSAGE  (global table prefix)
  [2] RENAME  Line 143  LS_CENTRAL  →  LV_CENTRAL  (local variable prefix)
  [3] RENAME  Line 144  LS_CENTRAL_PERSON  →  LV_CENTRAL_PERSON
  ...
  [N] COMMENT_OUT  Line 50  LV_UNUSED  (unused variable)

Manual review required:
  - TYPE_NOT_FOUND  Line 30  LV_FOO  type ZXYZ not in source or SAP dictionary

Total: N auto-fixable, M manual
```

---

## Step 4 — Confirm with User

Ask:
> "Apply this fix plan? (yes / no / select numbers to apply only specific fixes)"

- **yes** → proceed with all auto-fixable fixes
- **no** → stop
- **numbers** (e.g., "1,3,5" or "all except 2") → apply only the listed fix numbers

> **Agent-driven runs:** when this skill is invoked by the `abap-developer`
> agent inside its bounded check→fix→check loop, the agent reviews the plan
> and answers this confirmation itself on the operator's behalf — applying
> Auto-classified fixes only. The human decision point remains the agent's
> own pre-deploy confirmation (its Step 2g).

---

## Step 5 — Backup the ABAP Source File

Create a timestamped backup before making any changes:
```bash
powershell -Command "Copy-Item 'THE_ABAP_FILE' 'THE_ABAP_FILE.$(Get-Date -Format yyyyMMdd_HHmmss).bak'"
```

Confirm the backup was created successfully before proceeding.

---

## Step 6 — Apply Fixes

Read the ABAP source file. Apply each confirmed fix using the Edit tool.

### Applying RENAME

Use the Edit tool with `replace_all: true` to rename the variable throughout the entire file.

**Important considerations:**
- ABAP is case-insensitive — the rename must match regardless of case
- Use word-boundary awareness — do not rename substrings (e.g., renaming `LS_ADDR` must not affect `LS_ADDR_INFO`)
- Apply renames from **longest variable name to shortest** to avoid substring conflicts
- If two renames would conflict (e.g., both `LS_CENTRAL` and `LS_CENTRAL_PERSON` are being renamed), apply the longer name first

**Rename strategy:**
1. Sort all RENAME fixes by variable name length (longest first)
2. For each rename, use the Edit tool:
   - `old_string`: the exact line or occurrence containing the old variable name
   - `new_string`: the same content with the variable name replaced
   - `replace_all: true` when safe (single unique occurrence pattern)

For variables that appear multiple times, it may be necessary to:
- First read the file to find all occurrences
- Apply Edit for each distinct context where the variable appears

### Applying COMMENT_OUT

For each UNUSED variable to comment out:
- Find the declaration line
- Prepend `*` to the beginning of the line (making it an ABAP comment)

Before:
```abap
  DATA: lv_unused TYPE string.
```
After:
```abap
* DATA: lv_unused TYPE string.
```

**Skip** if the variable is part of a chain declaration (commas before or after on the same DATA: line). Note these as "skipped — chain declaration, manual removal recommended."

---

## Step 7 — Report

Present a summary:

```
Fix summary for: <path>
Backup: <path>.<timestamp>.bak

Applied:
  ✓ N renames
  ✓ M declarations commented out

Skipped:
  - K type issues (manual review)
  - J chain declarations (manual removal)

Next steps:
  - Run /sap-check-abap <file> to verify remaining issues
  - Review TYPE_NOT_FOUND items manually in SE11
```

---

## Step 6b — Fix CALL FUNCTION parameters (`fm` findings)

Run when `<abap-file>.check_fm.tsv` exists and has fixable rows. Absorbed from the
former `sap-fix-fm`. The backup from Step 5 already covers this file.

For the unique set of FMs with `UNKNOWN_PARAM` / `MISSING_MANDATORY` /
`WRONG_SECTION` findings, **re-fetch the live signature** (authoritative — the
result file may be stale) via the shared helper, then edit each `CALL FUNCTION`
block:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<generated sap_rfc_lookup_fm.ps1 run script>"
```

Then apply per finding (Edit tool, within the correct `CALL FUNCTION 'X' … .` block only):
- `UNKNOWN_PARAM` → rename the wrong parameter to the correct FM parameter name.
- `WRONG_SECTION` → move the `param = value.` assignment under the correct keyword
  (`EXPORTING` / `IMPORTING` / `CHANGING` / `TABLES`); create the keyword line if absent.
- `MISSING_MANDATORY` → insert a stub `<param> = <value>.` line under its section
  (leave a clearly-marked placeholder value for the user to fill; never invent data).
- `TYPE_*` / `FM_NOT_FOUND` → list for manual review (semantic).

---

## Step 8 — Syntax fix loop (`syntax` findings)

Run when `<abap-file>.syntax.tsv` has `SYNTAX_ERROR` rows (or on `--syntax-loop`).
This is the **bounded AI-assisted** close of the check→fix→re-check loop — real
syntax errors need judgement, so there is **no blind auto-fix**.

Loop (default **max 4** iterations). **Match the engine mode to the source kind** —
exactly as sap-check-abap Step 3.9: `REPORT`/`PROGRAM` → `-Subc 1` (no `-Wrap`); an
`FUNCTION…ENDFUNCTION` fragment → `-Subc F -Wrap`; a `CLASS`/`INTERFACE` pool →
`-Subc K -Wrap`. Under `-Wrap` the engine's `LINE=` values are already the **original**
file's line numbers, so the Edits in step 1 land on the right lines.

1. For each `SYNTAX_ERROR LINE=<n> COL=<c> MSG=<text>`, read the source around
   line `n` and apply a targeted Edit that addresses that specific compiler
   message (undeclared field → declare or correct the name; missing period → add
   it; etc.). Use judgement; do not rewrite unrelated code.
2. Re-run the engine on the edited file — **same `-Subc`/`-Wrap` as the check**:
   ```bash
   # REPORT/PROGRAM: -Subc 1 (omit -Wrap) | FM: -Subc F -Wrap | class/interface: -Subc K -Wrap
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_syntax_check.ps1" -SourceFile "THE_ABAP_FILE" -ProgramName "THE_PROGRAM_NAME" -Subc "<1|F|K>" -Wrap -OutTsv "THE_ABAP_FILE.syntax.tsv"
   ```
3. **Stop** on `STATUS: CLEAN`, on `STATUS: COULD_NOT_CHECK` (a fragment whose signature
   the wrap cannot model — defer to the deploy skill's in-context Ctrl+F2, do not guess),
   on **no progress** (the same finding set two rounds running), or at the iteration cap.
   Report the final state; if errors remain, list them for the user rather than guessing further.

The backup from Step 5 covers the source; every edit is local to the `.abap` file —
nothing is written to SAP.

---

## Fix Limitations

- **Chain declarations**: If an unused variable is part of a `DATA:` chain (comma-separated), it cannot be safely commented out without affecting the surrounding declarations. These are flagged for manual removal.
- **Inline declarations**: `DATA(lv_x)` / `FINAL(lv_x)` inline forms ARE detected by sap-check-abap (with a kind-lenient naming rule, since the runtime kind is unknown); a NAMING rename on an inline-declared name is applied like any other rename.
- **Substring conflicts**: Variables whose names are prefixes of other variables (e.g., `LS_ADDR` and `LS_ADDR_INFO`) require careful ordering. The skill applies longer names first to avoid partial replacements.
- **TYPE_NOT_FOUND**: These require SAP Dictionary changes (SE11) or source code corrections that cannot be automated.
- **Structure vs. scalar (offline mode)**: If sap-check-abap ran in offline mode, structures may be misidentified as variables. Some NAMING renames may suggest `lv_` for what should remain `ls_`. If you suspect this, recommend the user re-run sap-check-abap in online mode (with SAP connection) before applying fixes.

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_fix_abap_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_fix_abap_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `FIX_ABAP_FAILED`, `BACKUP_FAILED`.

---

## Pipeline Integration

This skill is part of the ABAP quality pipeline:

1. **sap-gen-abap** — generates ABAP source code
2. **sap-check-abap** — validates code quality ← run this first
3. **sap-fix-abap** ← you are here — applies automatic fixes
4. **abap-deploy** — deploys to SAP system (sap-se38 / sap-se37 / sap-se24 / sap-se11 / sap-se91)
