# sap-fix-abap

Fixes ABAP source code issues found by sap-check-abap.

## Fixes Applied

| Fix Type | Check Code | Action |
|---|---|---|
| RENAME | NAMING | Renames variable throughout the file (case-insensitive, word-boundary aware) |
| COMMENT_OUT | UNUSED | Prepends `*` to the declaration line |
| SYNTAX_SAFE | SQL_STRICT_COMMA | Inserts the missing commas between SELECT-list fields |
| SYNTAX_SAFE | LINE_TOO_LONG / LINE_HARD_LIMIT | Wraps the statement at a token boundary (manual when the overlong stretch is inside a string literal) |
| SYNTAX_SAFE | CLASS_DEF_AFTER_EVENT | Moves the `CLASS … DEFINITION` block above the first event block |
| FM param — Auto (RFC) | UNKNOWN_PARAM | Renames the `CALL FUNCTION` parameter to the correct FM parameter name (Step 6b) |
| FM param — Auto (RFC) | WRONG_SECTION | Moves the parameter assignment to the correct keyword section (Step 6b) |
| FM param — Auto (RFC) | MISSING_MANDATORY | Inserts a stub line for the missing mandatory parameter (Step 6b) |
| SYNTAX — Auto (AI loop) | SYNTAX_ERROR | Bounded check → patch → re-check loop driving the headless syntax-check engine (Step 8) |
| MANUAL | TYPE_NOT_FOUND and all other semantic codes (see SKILL.md Step 2 table) | Flagged for user review — not auto-fixable |

## Usage

```
/sap-fix-abap C:\src\ZPROGRAM.abap
/sap-fix-abap C:\src\ZPROGRAM.abap C:\src\ZPROGRAM.abap.check.tsv
```

## Input

Tab-delimited result file (`.check.tsv`) produced by `sap-check-abap`, with columns:

```
CHECK_TYPE  SEVERITY  LINE  VARIABLE  SCOPE  DATA_KIND  DETAIL  FIX_ADVICE
```

The sibling result files `<abap>.check_fm.tsv` (`fm` dimension → Step 6b) and
`<abap>.syntax.tsv` (`syntax` dimension → Step 8 loop) are also fixed when present.

## Workflow

1. Parse arguments (ABAP file + optional result TSV)
2. Read and classify findings (fixable vs. manual)
3. Build fix plan (RENAME, COMMENT_OUT, MANUAL)
4. User confirmation (all / selective / cancel)
5. Backup original file (`.YYYYMMDD_HHMMSS.bak`)
6. Apply fixes using Edit tool
7. Report summary + suggest re-check

## Rename Strategy

- Case-insensitive, word-boundary aware replacement
- Longest variable names renamed first (avoids substring conflicts)
- Chain declarations skipped for COMMENT_OUT (flagged for manual removal)

## Pipeline

`sap-gen-abap` → `sap-check-abap` → **sap-fix-abap** → deploy (`sap-se38` / `sap-se37` / `sap-se24`)

## Prerequisites

- Run `sap-check-abap` first to produce the result TSV
- No SAP connection required for NAMING / UNUSED / syntax-safe rewrites; the `fm` and `syntax` fix paths additionally need SAP NCo 3.1 (32-bit) + the dev-init wrapper FM for read-only RFC calls (live FM-signature lookup, headless syntax check). All edits are still applied locally to the `.abap` file — nothing is written to SAP

## Directory Structure

```
skills/sap-fix-abap/
├── SKILL.md    # Skill workflow definition
└── README.md   # This file
```

Version: 1.0.0 | License: GPL-3.0
