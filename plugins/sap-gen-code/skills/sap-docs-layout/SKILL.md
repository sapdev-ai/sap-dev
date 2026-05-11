---
name: sap-docs-layout
description: |
  Edits the structural layout of a SAP design spec template (.xlsx) by writing
  to the workbook's `(Meta) Layout` sheet. Lets customers customize sheet
  names, column orders, and output mappings without editing Markdown rules or
  skill code. The meta sheet becomes the per-workbook source of truth that
  `/sap-docs-extract` reads on its next run.

  Operations:
    inspect       Print the current layout in human-readable form.
    bootstrap     Copy a `(Meta) Layout` sheet from the canonical
                  `spec_template.xlsx` into a workbook that doesn't have one.
    add-column    Add a column to a section. Updates xlsx + meta in one step.
    rename-sheet  Rename a sheet and update meta so the parser still finds it.
    validate      Reconcile the meta sheet against actual workbook structure.

  Input: workbook path + operation + op-specific args.
  Output: in-place modifications to the .xlsx file. A timestamped backup is
  written next to the original before any write operation.
argument-hint: "<operation>  [<workbook-path>]  [op-specific-flags]"
---

# SAP Docs Layout Skill

You edit the structural layout of a customer's design-spec template. Customers
fill specs into `spec_template.xlsx`; this skill is what they use to customize
that template's structure without touching Markdown rules or Python.

The skill writes to a hidden `(Meta) Layout` sheet inside the workbook. That
sheet is the **only** authoritative description of the workbook's layout.
`/sap-docs-extract` reads it directly. The canonical `spec_template.xlsx`
ships with a populated Meta sheet; `bootstrap` copies it into other
workbooks when needed.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/templates/spec_layout_schema.md` | Canonical schema for the `(Meta) Layout` sheet. Read this before generating or editing meta rows. |
| `<SAP_DEV_CORE_SHARED_DIR>/templates/spec_template.xlsx` | Canonical reference template. Default target when no workbook path is provided. `bootstrap` copies its `(Meta) Layout` sheet into other workbooks. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | Structured logging. |
| `<SKILL_DIR>/references/edit_meta_layout.py` | openpyxl helper — read/write meta sheet, perform structural edits, copy Meta sheet between workbooks. |

---

## Step 0 — Resolve Work Directory

Read sap-dev-core's `settings.json` (resolve path: 3 levels up from
`<SKILL_DIR>`, then `sap-dev-core/settings.json`). Read `work_dir`,
`custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_docs_layout_run.json" -Skill sap-docs-layout -ParamsJson "{\"args\":\"<RAW_ARGUMENTS>\"}"
```

---

## Step 1 — Parse Operation and Workbook Path

Tokenise `$ARGUMENTS`. The first positional argument MUST be one of:

```
inspect | bootstrap | add-column | rename-sheet | validate
```

If the first token is none of those, the user spoke conversationally
("add an AuthGroup column to my Field Definitions sheet") — translate into the
explicit form yourself, confirm with the user, and proceed.

The second positional argument is the **workbook path**. If omitted:

1. If `{custom_url}\spec_template.xlsx` exists → use it.
2. Else fall back to `<SAP_DEV_CORE_SHARED_DIR>\templates\spec_template.xlsx`.

Report the chosen path:

```
INFO: Workbook: <resolved-path>
INFO: Operation: <op>
```

If the resolved workbook does not exist, abort with:

```
ERROR: Workbook not found at <path>. Pass the path explicitly:
  /sap-docs-layout <op> C:\path\to\template.xlsx ...
```

Op-specific flags follow the workbook path. They are documented per operation
in Steps 3a–3e below.

---

## Step 2 — Backup the Workbook (skip for `inspect` and `validate`)

Read-only operations (`inspect`, `validate`) never modify the file — skip this
step for them.

For all other operations, before any write:

```python
from datetime import datetime
import shutil
from pathlib import Path

src = Path(workbook_path)
ts = datetime.now().strftime("%Y%m%d%H%M%S")
backup = src.with_suffix(f".bak.{ts}.xlsx")
shutil.copy2(src, backup)
print(f"INFO: Backup written to {backup}")
```

The backup lives next to the workbook and is never auto-cleaned. Customers
can delete old `.bak.*.xlsx` files themselves.

---

## Step 3 — Dispatch on Operation

### 3a. `inspect`

**Args:** none beyond workbook path.

Read the `(Meta) Layout` sheet via `references/edit_meta_layout.py`
(function `read_meta`). If the sheet is absent:

```
WARN: This workbook has no (Meta) Layout sheet. Run:
  /sap-docs-layout bootstrap <workbook>
to create one from the built-in defaults.
```

Otherwise print, in this order:

1. Workbook header — file path, last modified date, sheet count.
2. **Sections table** as a markdown table: `key`, `sheet_name`, `output_file`,
   `format`, `required`.
3. **Columns table** grouped by `section_key`, one block per section, each as
   a markdown table: `output_position`, `output_column`, `source_column_header`,
   `source_column_letter`, `transform`, `required`.
4. A one-line summary: `N sections, M columns, K required sections`.

### 3b. `bootstrap`

Copy a `(Meta) Layout` sheet into a workbook that doesn't have one. Useful
when a customer has localized or customized a template in Excel before
running the skill, and the meta sheet got lost or never existed.

**Args:**

| Flag | Default |
|---|---|
| `--from <path>` | `<SAP_DEV_CORE_SHARED_DIR>\templates\spec_template.xlsx` (the canonical reference) |
| `--force` | not set (refuse if `(Meta) Layout` already exists in the target) |

Behaviour:

1. If the target workbook already has a `(Meta) Layout` sheet AND
   `--force` is not set, abort with:
   ```
   ERROR: (Meta) Layout already exists. Use --force to overwrite or run
     /sap-docs-layout inspect <workbook>
   to review the current layout first.
   ```
2. Open the source workbook (`--from`) with openpyxl. Read its
   `(Meta) Layout` sheet contents (header rows + SECTIONS table +
   COLUMNS table).
3. Open the target workbook. Create (or replace, if `--force`) a
   `(Meta) Layout` sheet, copy in the source content row-by-row,
   preserving formatting (font, fill, borders, named ranges scoped to
   the sheet).
4. Update the `language` row to match the target workbook's localization
   if obvious from sheet names; otherwise leave as-is and warn.
5. Hide the sheet by default (`sheet_state = 'hidden'`).
6. Verify with a follow-up `inspect` and report the result to the user.

### 3c. `add-column`

**Args (all required unless noted):**

| Flag | Meaning |
|---|---|
| `--section <key>` | Section key from the meta Sections table (e.g. `ddic_dataelements`). |
| `--name <COL>` | Output column name (e.g. `AUTHGROUP`). Becomes the TSV header. |
| `--after <existing>` | Output column to insert after. Use `START` to insert at position 1. |
| `--source-header <text>` | Header text on the actual sheet. Optional — defaults to `--name`. |
| `--required` | Optional — marks the column required. Default optional. |
| `--transform <fn>` | Optional — one of `trim`, `upper`, `int`, `bool_X`. Default `trim`. |

Behaviour:

1. Read meta. If `--section` not found, abort with the list of known keys.
2. Open the worksheet named `meta.sections[--section].sheet_name`.
3. Insert a new column on the worksheet at the position implied by `--after`.
4. Write `--source-header` into the header cell. Copy header style from the
   neighbouring column.
5. Update the meta Columns table — insert a new row for this section with
   `output_position` shifted to match the inserted column. Renumber any rows
   below it.
6. Save.
7. Report:
   ```
   OK: Added column <NAME> to sheet "<sheet>" at position <N>.
       Meta updated: section=<key>, output_position=<N>.
       Run /sap-docs-layout validate <workbook> to confirm.
   ```

### 3d. `rename-sheet`

**Args:**

| Flag | Meaning |
|---|---|
| `--section <key>` | Section key whose sheet to rename. |
| `--to <new-name>` | New sheet name (any Excel-valid string up to 31 chars). |

Behaviour:

1. Read meta. Resolve section's current `sheet_name`.
2. Validate `--to`:
   - 1–31 characters.
   - Must not collide with any existing sheet name in this workbook.
   - No characters from `:\\/?*[]`.
3. Rename the worksheet via openpyxl (`ws.title = new_name`).
4. Update `meta.sections[<key>].sheet_name` to the new name.
5. Update any Excel **named ranges** that reference the old sheet name — scan
   `wb.defined_names` and rewrite the sheet portion of each affected range.
6. Save.
7. Report old → new and the count of named ranges updated.

### 3e. `validate`

**Args:**

| Flag | Default |
|---|---|
| `--dry-parse` | not set (skip the dry-parse phase) |

Behaviour — read-only, never modifies the workbook.

Phase A — **structural reconciliation**:

For every section in the meta Sections table, dispatch on `format`:

**`format = kv` or `format = tsv`:**
- The named worksheet exists. (Else FAIL.)
- The `anchor_named_range` is defined and resolves on that sheet, OR the
  `anchor_keyword` is found in column A of that sheet. (Else WARN.)
- For every column in the meta Columns table for this section:
  - `source_column_letter` is in range, OR `source_column_header` text is
    found on the anchor row. (Else WARN.)
  - Required columns have a non-empty header cell. (Else FAIL.)

**`format = image`:**
- The named worksheet exists. (Else FAIL.)
- The meta Columns table has ZERO rows for this section. (Else FAIL —
  image-format sections must not have COLUMN entries; they describe a
  single embedded image, not tabular data.)
- The named sheet contains at least one embedded image (read via
  `worksheet._images` in openpyxl). (Else WARN with the message
  *"section <key>: sheet '<name>' has no embedded image yet — paste a
  whole-screen image into the sheet before extraction"*.)
- The `anchor_named_range`, if set, resolves on the sheet. The anchor is
  not used for parsing image-format sections, but a defined anchor is
  still part of the schema regularity invariant.
- The `anchor_keyword` should be empty for image-format sections. If
  populated, WARN — keyword scanning is meaningless for images.

**`format = text`:**
- The named worksheet exists. (Else FAIL.)
- The meta Columns table has ZERO rows for this section. (Else FAIL —
  text-format sections are unstructured; they have no columns.)
- The `anchor_named_range`, if set, resolves on the sheet (schema
  regularity invariant). Anchor is not used for parsing.
- The `anchor_keyword` should be empty for text-format sections. If
  populated, WARN.
- An EMPTY sheet (no cells beyond the title/banner rows) is acceptable —
  the customer opted out of supplemental notes. Do not warn.

**`format = <unknown>`:** FAIL with `"section <key>: unknown format
'<value>'. Allowed: kv, tsv, image, text."`

For every worksheet in the workbook NOT named `(Meta) Layout`, `README`, or
`(Auto) *`:
- It is referenced by at least one section in meta. (Else WARN — orphan
  sheet.)

Phase B — **dry-parse** (only if `--dry-parse`):

Run `/sap-docs-extract` against this workbook with output redirected to a
scratch folder under `{WORK_TEMP}\layout_validate\<timestamp>\`. Report which
expected output files were produced and which were empty / missing. Delete
the scratch folder after reporting unless any check failed.

Output:

```
=== Phase A: Structural reconciliation ===
OK   <N> sections checked
OK   <M> columns checked
WARN <K> warnings
FAIL <X> errors

=== Phase B: Dry-parse ===   (only if --dry-parse)
OK   <K> output files produced as expected
WARN <Y> output files empty
FAIL <Z> expected output files missing

=== Punch list ===
- [WARN] section "ddic_tables": anchor_keyword "Table name" not found on sheet "DDIC Definitions"
- [FAIL] section "interface_inputs": column "TYPE" required but header cell is blank
- ...
```

Exit 0 if no FAIL, 1 otherwise (so this is callable from CI).

---

## Step 4 — Final — Log End

Use `SUCCESS` for completed write operations, `EXISTED` for `inspect`/`validate`
that found no issues, `FAILED` with an `ErrorClass` if any step blocked
progress (`META_NOT_FOUND`, `META_ALREADY_EXISTS`, `SECTION_UNKNOWN`,
`SHEET_NOT_FOUND`, `INVALID_ARGUMENT`, `XLSX_WRITE_FAILED`).

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_docs_layout_run.json" -Status SUCCESS -ExitCode 0
```

---

## Notes for Maintainers

- The skill is a thin orchestrator. All openpyxl logic lives in
  `references/edit_meta_layout.py`. Refactor there, not in SKILL.md.
- `bootstrap` copies the `(Meta) Layout` sheet from a reference workbook
  (default: the canonical `spec_template.xlsx`). It does NOT parse Markdown —
  the Markdown-bootstrap path was removed in favour of a single source of
  truth (the canonical workbook's Meta sheet).
- The schema for the `(Meta) Layout` sheet is documented in
  `<SAP_DEV_CORE_SHARED_DIR>/templates/spec_layout_schema.md`. Bump the
  schema's `version` row when changing it; the skill should refuse to
  operate on workbooks with a schema version it doesn't understand.
- This skill never touches data sheets' content cells. Only headers, named
  ranges, sheet names, column structure, and the `(Meta) Layout` sheet
  itself are within scope.

### Allowed `format` values in the SECTIONS table

| `format` | Meaning | Required Meta state | Output produced by `/sap-docs-extract` |
|---|---|---|---|
| `kv` | Two-column key/value layout (Cover sheet pattern). | At least 2 COLUMN rows (`FIELD`, `VALUE` or equivalent). Anchor named range or keyword required. | One `_<name>.txt` file with `KEY\tVALUE` lines |
| `tsv` | Standard tabular layout — one TSV row per data row. | One COLUMN row per output column. Anchor required. Required columns must have non-empty header cells. | One `_<name>.txt` TSV with header + data rows |
| `image` | Sheet contains an embedded image (e.g. selection-screen layout). No tabular data. | ZERO COLUMN rows. Anchor named range optional, anchor_keyword should be empty. Sheet should contain ≥1 embedded image. | One `_<name>.png` (the first embedded image, saved via openpyxl `worksheet._images`) |
| `text` | Free-form notes (Supplement sheet pattern). No header, no columns, no schema. | ZERO COLUMN rows. Anchor named range optional, anchor_keyword should be empty. | One `_<name>.txt` plain-text dump (every non-empty cell, row-by-row, tab-joined) |

Adding a new `format` is a schema change — bump `schema_version` in the
meta header, document semantics here, and update both `validate` (Phase A
dispatch) and `/sap-docs-extract` (image-extraction-equivalent step) to
handle it.
