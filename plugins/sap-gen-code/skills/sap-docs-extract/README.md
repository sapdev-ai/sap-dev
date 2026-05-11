# SAP Docs Extract Skill

Reads a SAP design document (Excel `.xlsx`, Word `.doc`/`.docx`, or PDF) —
**or** an existing work folder — and extracts structured information into
separate text files by information type: program summary, domains, data
elements, tables, error messages, text elements, and process logic.

This skill is the single entry point of the spec-to-ABAP pipeline. The
previous two-step flow (`sap-docs-convert` → `sap-docs-extract`) was folded
into this one skill: if the input is a raw document, extract handles the
format conversion itself before structuring.

## Skill Overview

Three input modes:

| If you pass… | extract does… |
|---|---|
| A `.xlsx` / `.doc` / `.docx` / `.pdf` file | Creates a fresh work folder, dumps the document to `{doc_name}_raw.txt`, then proceeds with structuring |
| An existing work folder | Locates the single `*_raw.txt` inside it, then structures |
| A `_raw.txt` file directly | Treats the parent directory as the work folder, then structures |

In all cases the output is the same set of `_*.txt` files written to the
work folder (overwritten without prompting):

| Output file | Content |
|---|---|
| `{doc_name}_PGM_summary.txt` | Program ID, name, type, package, function group, ABAP version |
| `{doc_name}_domains.txt` | DDIC domain definitions (TSV) |
| `{doc_name}_dataElements.txt` | DDIC data element definitions (TSV) |
| `{doc_name}_tables.txt` | DDIC table definitions + field lists |
| `{doc_name}_errorMsgs.txt` | Error message definitions |
| `{doc_name}_textElements.txt` | Selection screen / text element labels |
| `{doc_name}_process.txt` | Validation rules + processing flow (feeds `/sap-gen-abap`) |
| `{doc_name}_interface.txt` | Interface contract — inputs / outputs / exceptions |
| `{doc_name}_selection_definition.txt` | Selection screen field definitions (TSV) |
| `{doc_name}_selection_screen_layout.png` | **Image** — whole selection-screen layout, extracted from the workbook for `/sap-gen-abap` to read as multimodal input |
| `{doc_name}_file_mapping_in.txt` | File field → SAP table.field (inbound interfaces) |
| `{doc_name}_file_mapping_out.txt` | SAP table.field → file field (outbound interfaces, V2) |
| `{doc_name}_supplement.txt` | Free-form notes — whatever the customer wrote on the Supplement sheet, dumped verbatim |
| `{doc_name}_golden.txt` | Golden test scenarios (feed `MODE_UNIT_TESTS`) |
| `{doc_name}_deps.txt` | Dependencies (FMs, BAPIs, includes, classes) |
| `table_data_<TABLE>.txt` | Initial / fixed data per table (one file per table) |

## Auto-Trigger Keywords

- `extract spec`, `extract design doc`, `parse design doc`
- `read design xlsx`, `extract from PDF`
- `convert design doc to text`

## Usage

```text
/sap-docs-extract  C:\path\to\spec.xlsx
/sap-docs-extract  C:\path\to\spec.docx
/sap-docs-extract  C:\path\to\spec.pdf
/sap-docs-extract  C:\sap_dev_work\source_code\work\Spec_20260501123456\
/sap-docs-extract  C:\sap_dev_work\...\Spec_20260501123456\Spec_raw.txt
```

Conversational forms:

- "Extract this Excel design document"
- "Parse the design spec and split it into the standard files"
- "Re-extract this work folder — I edited the raw text"

## Prerequisites

- Python with `openpyxl` (for `.xlsx`)
- Python with `python-docx` (for `.docx`)
- For `.doc` and `.pdf`: Claude reads the file directly via the Read tool

## Suggested next steps

After extract completes, chain into:

- `/sap-docs-convert {work_folder}` *(optional)* — apply customer-specific
  field/type/flag normalisation rules
- `/sap-docs-check-process {work_folder}` — validate the process logic for
  unclear parts before generation
- `/sap-docs-check-ddic {work_folder}` — validate DDIC definitions before
  deployment
- `/sap-gen-abap {work_folder}/{doc_name}_process.txt` — generate ABAP

## Limitations

- Sheet identification relies on Japanese keywords (表紙, ドメイン・データエレメント,
  テーブル定義, etc.). For non-Japanese specs, sheet matching may be incomplete
  — feature in roadmap.
- Existing output files are overwritten without prompting. If you've manually
  edited `_*.txt` files, save them elsewhere before re-running extract.

## Version

- Skill Version: 1.1.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
