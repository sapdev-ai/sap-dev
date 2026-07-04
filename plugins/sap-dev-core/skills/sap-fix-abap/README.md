# sap-fix-abap

Fixes ABAP source code issues found by sap-check-abap.

## Fixes Applied

| Fix Type | Check Code | Action |
|---|---|---|
| RENAME | NAMING | Renames variable throughout the file (case-insensitive, word-boundary aware) |
| COMMENT_OUT | UNUSED | Prepends `*` to the declaration line |
| MANUAL | TYPE_NOT_FOUND | Flagged for user review — not auto-fixable |

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

`sap-gen-abap` → `sap-check-abap` → **sap-fix-abap** → `abap-deploy`

## Prerequisites

- Run `sap-check-abap` first to produce the result TSV
- No SAP connection required — fixes are applied locally

## Directory Structure

```
skills/sap-fix-abap/
├── SKILL.md    # Skill workflow definition
└── README.md   # This file
```

Version: 1.0.0 | License: GPL-3.0
