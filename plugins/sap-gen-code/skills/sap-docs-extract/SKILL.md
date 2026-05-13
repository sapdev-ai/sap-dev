---
name: sap-docs-extract
description: |
  Reads a SAP design document (Excel .xlsx, Word .doc/.docx, PDF), or an existing
  work folder, and extracts structured information into separate text files by
  information type: program summary, domains, data elements, tables, error
  messages, text elements, and process logic.

  Input — any of:
    * Path to a design document (.xlsx / .doc / .docx / .pdf) — extract creates
      a fresh work folder, dumps the document to {doc_name}_raw.txt, then
      proceeds with structuring.
    * Path to an existing work folder containing {doc_name}_raw.txt.
    * Path to a {doc_name}_raw.txt file directly.

  Output: Multiple {doc_name}_*.txt files written to the work folder. Existing
  files with the same names are silently overwritten without any user
  confirmation or logging. Optionally chain /sap-docs-convert afterwards to
  apply customer-specific normalisation rules.

  If the input file format is not one of .xlsx, .doc, .docx, or .pdf (and is
  not an existing work folder or `_raw.txt` file), abort with the error:
  "ERROR: Unsupported file format."
argument-hint: "<path-to-document  OR  work-folder  OR  _raw.txt>"
---

# SAP Docs Extract Skill

You read a SAP design document (Excel / Word / PDF) and extract structured
information into separate files by information type. The previous two-step
flow (`sap-docs-convert` → `sap-docs-extract`) is now folded into this single
skill: if the input is a raw document, extract handles the format conversion
itself before structuring.

Task: $ARGUMENTS

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve cross-plugin paths: 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\settings.json` and (if present) `sap-dev-core\settings.local.json`. Read `work_dir`, `custom_url`, `design_docs_url`, `source_code_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |
| `design_docs_url` | `{work_dir}\design_docs` |
| `source_code_url` | `{work_dir}\source_code` |

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. The shared helper persists `run_id` to a state
file so subsequent steps and Step 4 can append to the same run. Logging is
best-effort — if `userConfig.log_enabled=false` or the lib can't load, the
helper silently no-ops.

`<SAP_DEV_CORE_SHARED_DIR>` resolves to `plugins/sap-dev-core/shared/`.

State file: `{WORK_TEMP}\sap_docs_extract_run.json`

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_docs_extract_run.json" -Skill sap-docs-extract -ParamsJson "{\"input\":\"<USER_INPUT_PATH>\"}"
```

---

## Step 1 — Resolve Input and Locate / Create the Raw Text File

Extract the path argument from `$ARGUMENTS`.

If no path is given, ask the user:
> "Please provide the path to the design document (.xlsx / .doc / .docx / .pdf), an existing work folder, or a `_raw.txt` file."

Classify the argument using this decision table (evaluate rules in order; the
first matching rule wins):

| # | Condition | Action | Section |
|---|---|---|---|
| 1 | Argument is a file ending in `_raw.txt` | Use it directly | 1a |
| 2 | Argument is an existing directory | Locate the single `_raw.txt` inside | 1b |
| 3 | Argument is a file with extension `.xlsx`, `.doc`, `.docx`, or `.pdf` | Create work folder and dump to `_raw.txt` | 1c |
| 4 | None of the above | Abort with: `ERROR: Unsupported file format.` | — |


### 1a. Raw text file (`*_raw.txt`)

If the argument ends with `_raw.txt` and exists as a file → use it directly.
Set `{work_folder}` = the parent directory of that file.
Set `{doc_name}` = filename minus `_raw.txt` suffix.

### 1b. Existing work folder

If the argument is a directory, locate the single `*_raw.txt` file inside it:
```powershell
Get-ChildItem -Path "{work_folder}" -Filter "*_raw.txt"
```
If zero or multiple `_raw.txt` files exist, abort with the error message:
"ERROR: Expected exactly one `_raw.txt` file in the directory."

### 1c. Design document (.xlsx / .doc / .docx / .pdf) — produces the raw file

If the argument is a document file with one of those extensions, create a
fresh work folder and dump the document to plain text first:

1. Derive names:
   - `{doc_name}` = filename without extension
     (e.g., `spec_sample` from `spec_sample.xlsx`)
   - If `{doc_name}` exceeds 50 characters, truncate to 50.
   - `{timestamp}` = current date/time as `yyyyMMddHHmmss`
   - `{work_folder}` = `{source_code_url}/work/{doc_name}_{timestamp}`

2. Create the work folder:
   ```bash
   mkdir -p "{work_folder}"
   ```

3. Dump the document to `{work_folder}/{doc_name}_raw.txt` using the right
   reader for the file type:

   **For Excel (.xlsx)** — Python with openpyxl:
   ```python
   import openpyxl
   path = r"THE_DOCUMENT_PATH"
   output = r"THE_OUTPUT_PATH"
   wb = openpyxl.load_workbook(path)
   lines = []
   for sheet_name in wb.sheetnames:
       ws = wb[sheet_name]
       lines.append(f"========== Sheet: {sheet_name} (rows={ws.max_row}, cols={ws.max_column}) ==========")
       for row_idx, row in enumerate(ws.iter_rows(min_row=1, max_row=ws.max_row, values_only=True), start=1):
           if any(c is not None for c in row):
               cells = ["" if c is None else str(c) for c in row]
               lines.append(f"R{row_idx}\t" + "\t".join(cells))
       lines.append("")
   with open(output, "w", encoding="utf-8") as f:
       f.write("\n".join(lines))
   ```

   **For Word (.docx)** — Python with python-docx:
   ```python
   from docx import Document
   doc = Document(r"THE_DOCUMENT_PATH")
   lines = []
   for para in doc.paragraphs:
       if para.text.strip():
           lines.append(para.text)
   for table_idx, table in enumerate(doc.tables):
       lines.append(f"========== Table {table_idx + 1} ==========")
       for row in table.rows:
           cells = [cell.text.strip() for cell in row.cells]
           lines.append("\t".join(cells))
   with open(r"THE_OUTPUT_PATH", "w", encoding="utf-8") as f:
       f.write("\n".join(lines))
   ```

   **For Word (.doc)** — use the Read tool on the file, then write the content
   to the output file with the Write tool.

   **For PDF (.pdf)** — use the Read tool on the .pdf path; write the extracted
   text to the output file with the Write tool.

After 1c completes you have a populated `{work_folder}/{doc_name}_raw.txt`.

### Common to all three branches

All output files in subsequent steps MUST be written to `{work_folder}` — the
same directory that contains the `_raw.txt` file. Read the entire `_raw.txt`
file using the Read tool before proceeding to Step 2.

---

## Step 2 — Read the (Meta) Layout sheet (xlsx inputs)

For `.xlsx` inputs, open the original workbook with openpyxl and look for
a `(Meta) Layout` sheet. This sheet is the per-workbook contract that
tells the parser how every other sheet maps to an output file. The
canonical `spec_template.xlsx` ships with one populated.

If the workbook has no `(Meta) Layout` sheet, abort with:

```
ERROR: This workbook has no (Meta) Layout sheet. Either:
  - Copy your data into the canonical spec_template.xlsx (it ships with
    a Meta sheet), OR
  - Run /sap-docs-layout bootstrap <workbook> to add a Meta sheet from
    the canonical template.
```

For non-xlsx inputs (`.docx`, `.doc`, `.pdf`), there is no Meta sheet —
proceed with text-based extraction by inspecting `_raw.txt` directly and
inferring sections from natural document structure (headings, table
boundaries, well-known keywords).

---

## Step 3 — Apply the Layout

For xlsx inputs, walk the `(Meta) Layout` SECTIONS rows. For each row:

1. Locate the named worksheet by `sheet_name`.
2. Resolve the section's data anchor — first by `anchor_named_range` (if
   defined and resolvable), else by scanning column A for `anchor_keyword`.
3. Dispatch on `format`:
   - `kv` — read 2-column key/value pairs from the anchor row downward,
     emit as `KEY\tVALUE` lines.
   - `tsv` — read the header row at the anchor, then data rows below;
     emit as TSV with the COLUMNS table's `output_column` order.
   - `image` — handled in Step 3.5.
   - `text` — handled in Step 3.4.
4. Apply each column's `transform` (`trim`, `upper`, `lower`, `int`,
   `bool_X`) and `default_if_blank` per the COLUMNS table.
5. **Forward-fill the first output column on `tsv` sections.** After the
   COLUMNS-driven extraction emits rows, walk the rows top-down: any data
   row whose first column is blank inherits the most recent non-blank
   first-column value. The header row is never filled. The carry pointer
   PERSISTS across sections that write to the **same** `output_file` —
   so a later section (e.g. `ddic_tables_fields`) inherits the join key
   (`TABLE`) from the earlier section (`ddic_tables_metadata.TABLE_NAME`)
   when the spec author left the FK column blank on every field row. For
   multi-table specs the author still must put the table name on the
   first field row of each table — subsequent rows of that table carry
   automatically.

   Why this is conservative: if every field row already has an explicit
   TABLE value, forward-fill is a no-op (nothing is blank to fill). If
   ALL upstream sections produce zero rows AND the current section has
   blank first column, the first row stays blank — a downstream
   `/sap-docs-check-ddic` finding surfaces the authoring issue.

For non-xlsx inputs (no Meta sheet), apply hardcoded heuristics: scan the
raw text for the standard sections (Cover, DDIC, Process, Validation,
etc.) using natural document structure. This path is best-effort and may
miss customer-specific extensions.

---

## Step 3.4 — Dump Free-Form Text Sheets (xlsx input only)

If the original input was an `.xlsx` file AND the workbook contains a
`(Meta) Layout` sheet listing one or more sections with `format = text`,
dump those sheets verbatim now. A `text` section has no header row, no
TSV columns — the customer wrote free-form notes anywhere on the sheet.

Skip this step entirely when:

- The input was a `_raw.txt` file or an existing work folder, OR
- The workbook has no `(Meta) Layout` sheet, OR
- No section has `format = text`.

For each `format = text` section in `(Meta) Layout`:

1. Read the section's `sheet_name` and `output_file` columns.
2. Open the original `.xlsx` with openpyxl, locate the named worksheet.
3. Walk every row from row 1 to `worksheet.max_row`. For each row:
   - Build a list of cell values from columns A through `worksheet.max_column`
   - Replace `None` with empty string
   - Strip trailing empty cells
   - Join non-empty cells with a single tab; emit as one output line
   - If the entire row is empty, emit a blank line (preserves vertical structure)
4. Skip the title row (row 1) and the banner row (row 2) — they're chrome,
   not user content. The dump should start from row 3.
5. Strip trailing blank lines.
6. Write to `{work_folder}/{doc_name}{output_file}` as UTF-8.

Reference Python:

```python
import openpyxl

wb = openpyxl.load_workbook(xlsx_path, data_only=True)
ws = wb[sheet_name]
lines = []
for row in ws.iter_rows(min_row=3, max_row=ws.max_row,
                        values_only=True):
    cells = ["" if c is None else str(c) for c in row]
    while cells and cells[-1] == "":
        cells.pop()
    lines.append("\t".join(cells))
while lines and lines[-1].strip() == "":
    lines.pop()
out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
```

A completely empty supplement sheet results in an empty `_supplement.txt`
file — write the file anyway (zero bytes is a valid signal: customer
opted out of supplemental notes).

---

## Step 3.5 — Extract Embedded Images (xlsx input only)

If the original input was an `.xlsx` file (sub-step 1c) AND the workbook
contains a `(Meta) Layout` sheet listing one or more sections with
`format = image`, extract those images now. Images live in the binary
`.xlsx` archive — they are NOT in `{doc_name}_raw.txt` (the text dump in
Step 1c discards images). Source = the original `.xlsx`, not `_raw.txt`.

Skip this step entirely when:

- The input was a `_raw.txt` file or an existing work folder (no `.xlsx`
  to read images from), OR
- The workbook has no `(Meta) Layout` sheet (legacy template), OR
- No section in `(Meta) Layout` has `format = image`.

For each `format = image` section in `(Meta) Layout`:

1. Read the section's `sheet_name` and `output_file` columns.
2. Open the original `.xlsx` with openpyxl, locate the named worksheet.
3. Read `worksheet._images` — the list of embedded `Image` objects.
4. If the list is empty, **emit a warning** and skip this section
   (don't fail — image is optional):
   ```
   WARN: section <key>: sheet "<sheet_name>" has no embedded images. Skipping image extraction.
   ```
5. If the list has at least one image, save the FIRST image to
   `{work_folder}/{doc_name}{output_file}` (note: `output_file` already
   begins with an underscore, e.g. `_selection_screen_layout.png`).

Reference Python:

```python
import openpyxl
from PIL import Image as PILImage
import io

wb = openpyxl.load_workbook(xlsx_path)
ws = wb[sheet_name]
if not ws._images:
    print(f"WARN: sheet '{sheet_name}' has no embedded images")
else:
    img = ws._images[0]
    pil = PILImage.open(io.BytesIO(img._data()))
    pil.save(out_path, format="PNG")
```

If multiple images exist on one sheet, V1 saves only the first and emits a
warning naming the count. (V2 may save additional images as
`<output_file_stem>_2.png`, `_3.png`, etc.)

---

## Step 4 — Write Output Files

Write each file to `{work_folder}` (the same folder that contains the
`_raw.txt` file) using the Write tool. All files use UTF-8 encoding.

**Overwrite policy:** If a target file already exists, OVERWRITE it without
prompting. Do not back up, rename, or skip existing files. The Write tool
replaces the file content, which is the desired behaviour.

File name pattern (all paths relative to `{work_folder}`):

| Information Type | Output File |
|---|---|
| Program summary | `{doc_name}_PGM_summary.txt` |
| Domains | `{doc_name}_domains.txt` |
| Data elements | `{doc_name}_dataElements.txt` |
| Tables (DDIC) | `{doc_name}_tables.txt` |
| Initial table data (one per table) | `table_data_{TABLE_NAME}.txt` |
| Error messages | `{doc_name}_errorMsgs.txt` |
| Text elements | `{doc_name}_textElements.txt` |
| Process logic | `{doc_name}_process.txt` |
| Interface contract | `{doc_name}_interface.txt` |
| Selection definition | `{doc_name}_selection_definition.txt` |
| Selection screen layout (image, Step 3.5) | `{doc_name}_selection_screen_layout.png` |
| File mapping (inbound) | `{doc_name}_file_mapping_in.txt` |
| File mapping (outbound) | `{doc_name}_file_mapping_out.txt` |
| Supplement (free-form, Step 3.4) | `{doc_name}_supplement.txt` |
| Golden tests | `{doc_name}_golden.txt` |
| Dependencies | `{doc_name}_deps.txt` |

If an information type is not present in the source document, do not create
the file (do not write empty placeholders).

Report to the user:
- Work folder path: `{work_folder}`
- List of files created (or overwritten) with line counts
- Suggest next steps:
  - `/sap-docs-convert {work_folder}` *(optional)* to apply customer-specific
    field/type/flag rules from `spec_conversion_rules.tsv` before validation
  - `/sap-docs-check-process {work_folder}` to validate process logic

End the log run. Use `EXISTED` if the work folder already contained the
output files (and you only verified them); use `SUCCESS` for a fresh
extraction; use `FAILED` with an `ErrorClass` if any step blocked progress
(e.g. `INPUT_NOT_FOUND`, `RAW_DUMP_FAILED`, `EXTRACT_FAILED`):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_docs_extract_run.json" -Status SUCCESS -ExitCode 0
```
  - `/sap-docs-check-ddic {work_folder}` to validate DDIC definitions
  - `/sap-gen-abap {work_folder}/{doc_name}_process.txt` to generate ABAP code
