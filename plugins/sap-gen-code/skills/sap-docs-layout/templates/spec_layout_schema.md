# `(Meta) Layout` sheet schema (`schema_version` 1)

Canonical schema for the hidden `(Meta) Layout` sheet inside a SAP design-spec
workbook (`spec_template.xlsx` and its `_JA` variant, built by
`tools/build_spec_template.py`). This sheet is the **only** authoritative
description of the workbook's layout: `/sap-docs-extract` reads it to locate
every section, and `/sap-docs-layout` (via
`references/edit_meta_layout.py`) is the supported way to edit it.

Read this before generating or editing meta rows. Do not edit the sheet by
hand — its own title row says so.

## Sheet identity and placement

| Property | Value |
|---|---|
| Sheet name | `(Meta) Layout` — identical in the EN and JA template variants (only content-sheet names are localized) |
| Sheet state | `hidden` in production workbooks (`bootstrap` hides it); the shipped canonical template leaves it visible for review |
| Row 1 | Title banner: `(Meta) Layout — managed by /sap-docs-layout. Do not edit by hand.` |

## Layout of the sheet

Three blocks, all anchored in **column A** and parsed positionally:

```
row 1   <title banner>
row 2   schema_version     | 1
row 3   bootstrapped_from  | <seeded by /sap-docs-layout bootstrap>
row 4   language           | EN | JA | ZH
row 5   (blank)
row 6   ## SECTIONS                          <- banner
row 7   key | sheet_name | ... (headers)
row 8+  one row per section (19 in the canonical template)
        (blank gap)
row N   ## COLUMNS                           <- banner
row N+1 section_key | output_position | ... (headers)
row N+2+ one row per output column (96 in the canonical template)
```

Parsers MUST locate the two `## SECTIONS` / `## COLUMNS` banner cells by
scanning column A (do not hard-code row numbers), take the row directly below
each banner as the header row, and read data rows until the first row whose
first column is empty. Absolute row numbers above are the canonical template's
current values, not part of the contract.

### Header rows (key/value pairs, columns A/B, between the title and `## SECTIONS`)

| Key | Meaning |
|---|---|
| `schema_version` | Integer. Currently `1`. The skill refuses to operate on versions it does not understand. Bump it when changing this schema, and update `edit_meta_layout.py` (`SUPPORTED_SCHEMA_VERSIONS`) plus `/sap-docs-extract`. |
| `bootstrapped_from` | Provenance stamp. The canonical template ships `<seeded by /sap-docs-layout bootstrap>`; `bootstrap` overwrites it with `<source-file> @ <date>`. Informational. |
| `language` | `EN` / `JA` / `ZH` — the localization of the workbook's sheet names / headers / anchor keywords. `validate` warns when it looks inconsistent with the sheet names. |

## `## SECTIONS` table

One row per extractable section. Header row (exact spellings):

`key | sheet_name | section_label | output_file | format | anchor_named_range | anchor_keyword | header_row_offset | data_starts_offset | required | notes`

| Column | Stable across localization? | Meaning |
|---|---|---|
| `key` | **stable English** | Section identifier (`cover`, `ddic_domains`, ...). Never localized; joined against `section_key` in the COLUMNS table and used in all skill flags (`--section`). |
| `sheet_name` | localized | Worksheet the section lives on. Several sections may **share one sheet** (`interface_*` on `Interface Contract`; `ddic_tables_*` on `Tables`) — a rename must update every row mapped to that sheet. |
| `section_label` | stable English (V1) | Human label used by `inspect` output. |
| `output_file` | **stable English** | File `/sap-docs-extract` writes into the work folder, relative to `{doc_name}` (e.g. `_domains.txt` becomes `{doc_name}_domains.txt`). An optional `#fragment` suffix (`_interface.txt#inputs`) means several sections fold into ONE output file, fragment by fragment, in SECTIONS-table order; two `ddic_tables_*` sections share `_tables.txt` the same way. |
| `format` | fixed enum | `kv` \| `tsv` \| `image` \| `text` — see the format table in the SKILL.md ("Allowed `format` values"). Anything else fails `validate`. |
| `anchor_named_range` | stable | Workbook-level named range pointing at the section's anchor cell (e.g. `Cover.Anchor` = `'Cover'!$A3`). Preferred anchor. Usable only when it resolves to a sheet that exists in THIS workbook — Excel rewrites cross-workbook copies into external `[N]Sheet!...` refs, which must fall through to the keyword scan. |
| `anchor_keyword` | localized | Fallback anchor: first cell whose trimmed value equals the keyword, scanned across **ALL columns**, top-to-bottom then left-to-right within each row (NOT just column A — `ddic_tables_fields` anchors on `FIELDNAME` in column C). Empty for `image` / `text` sections. |
| `header_row_offset` | int | Rows from the anchor row to the header row. `0` everywhere in the canonical template (the anchor IS the header row). |
| `data_starts_offset` | int | Rows from the header row to the first data row. `1` for `kv`/`tsv`; `0` for `image`/`text` (unused). |
| `required` | `yes` / `no` | Whether `/sap-docs-extract` must produce this section for a spec to be complete. |
| `notes` | free text | Documentation only. |

### Canonical sections (EN template, 19 rows)

| key | sheet_name | output_file | format | required |
|---|---|---|---|---|
| `cover` | Cover | `_PGM_summary.txt` | kv | yes |
| `interface_inputs` | Interface Contract | `_interface.txt#inputs` | tsv | yes |
| `interface_outputs` | Interface Contract | `_interface.txt#outputs` | tsv | yes |
| `interface_exceptions` | Interface Contract | `_interface.txt#exceptions` | tsv | no |
| `selscr` | Selection Screen | `_selection_screen_layout.png` | image | no |
| `seldef` | Selection Definition | `_selection_definition.txt` | tsv | no |
| `validation` | Validation Rules | `_process.txt#validation` | tsv | no |
| `process` | Processing Flow | `_process.txt#process` | tsv | yes |
| `filemap_in` | Mapping (File In) | `_file_mapping_in.txt` | tsv | no |
| `filemap_out` | Mapping (File Out) | `_file_mapping_out.txt` | tsv | no |
| `supplement` | Supplement | `_supplement.txt` | text | no |
| `ddic_domains` | Domains | `_domains.txt` | tsv | yes |
| `ddic_dataelements` | Data Elements | `_dataElements.txt` | tsv | yes |
| `ddic_tables_metadata` | Tables | `_tables.txt` | tsv | yes |
| `ddic_tables_fields` | Tables | `_tables.txt` | tsv | yes |
| `errmsgs` | Error Messages | `_errorMsgs.txt` | tsv | no |
| `textels` | Text Elements | `_textElements.txt` | tsv | no |
| `golden` | Golden Tests | `_golden.txt` | tsv | no |
| `deps` | Dependencies | `_deps.txt` | tsv | no |

Anchor named ranges follow the `<Section>.Anchor` naming pattern
(`Cover.Anchor`, `Interface.Inputs.Anchor`, `DDIC.Tables.Fields.Anchor`, ...);
the canonical template defines 19 of them, all single-cell.

## `## COLUMNS` table

One row per output column of a `kv`/`tsv` section, grouped by section.
`image` / `text` sections have **zero** rows here (validate enforces it).
Header row (exact spellings):

`section_key | output_position | output_column | source_column_header | source_column_letter | transform | default_if_blank | required | notes`

| Column | Stable across localization? | Meaning |
|---|---|---|
| `section_key` | **stable English** | FK to `SECTIONS.key`. |
| `output_position` | int | 1-based position of the column in the emitted TSV. Contiguous within a section; `add-column` renumbers on insert. |
| `output_column` | **stable English** | The TSV header name (`DOMAIN_NAME`, `MSG_TEXT`, ...). Downstream skills (`/sap-docs-check-ddic`, `/sap-gen-abap`) key on these — never localize. |
| `source_column_header` | localized | Header text on the actual worksheet. Fallback lookup when the letter is stale. For `kv` sections it is a meta-comment (e.g. `(col A labels)`) — `kv` has no on-sheet header row. |
| `source_column_letter` | per-workbook | Worksheet column letter (`A`, `B`, ...). Primary lookup. Shared-sheet caveat: an `add-column` on one section shifts the letters of every later column of **all** sections on that sheet — `edit_meta_layout.py` keeps them (and the anchors' named ranges) in sync. |
| `transform` | fixed enum | Applied by `/sap-docs-extract` per cell: `trim` (default), `upper`, `lower`, `int`, `bool_X` (truthy input becomes `X`, else empty). `add-column` offers `trim` / `upper` / `int` / `bool_X`. |
| `default_if_blank` | value | Substituted when the cell is blank (e.g. `0` for `DECIMALS`). Usually empty. |
| `required` | `yes` / `no` | Required columns must have a non-empty header cell on the sheet (`tsv` sections; enforced by `validate`). |
| `notes` | free text | Documentation only. |

The canonical template carries 96 column rows; per-section counts: cover 2,
interface_inputs/outputs/exceptions 4 each, seldef 13, validation 4,
process 3, filemap_in/out 9 each, ddic_domains 9, ddic_dataelements 7,
ddic_tables_metadata 5, ddic_tables_fields 8, errmsgs 4, textels 2, golden 5,
deps 4 (selscr and supplement have none by design).

## Localization contract

The `_JA` (and future `_ZH`) template variants keep this schema **identical**:
localized values appear only in `sheet_name`, `section_label` (future),
`source_column_header` and `anchor_keyword`; `key`, `output_file`,
`output_column`, `format`, letters, offsets and flags stay stable English.
That is what lets `/sap-docs-extract` produce byte-compatible output files
from a localized workbook.

## Change management

- Any change to the tables' column sets, the banner strings, the header keys
  or the `format` enum is a **schema change**: bump the `schema_version`
  header row, document it here, and update `edit_meta_layout.py`
  (`SUPPORTED_SCHEMA_VERSIONS`) and `/sap-docs-extract` in the same change.
- The canonical meta content is generated by `tools/build_spec_template.py`
  (`SECTIONS_ROWS` / `COLUMN_ROWS`) — keep that builder, this doc, and the
  shipped `spec_template.xlsx` in sync.
