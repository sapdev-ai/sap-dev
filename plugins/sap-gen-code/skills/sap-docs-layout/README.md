# SAP Docs Layout Skill

Structurally edit the customer's design-spec template (`.xlsx`) without
editing Markdown parser rules or Python code. The skill writes to a hidden
`(Meta) Layout` sheet inside the workbook, and that sheet becomes the
per-workbook source of truth that `/sap-docs-extract` reads.

## When to use

- You're onboarding a new customer whose existing design-spec template has
  different sheet names or column orders than the shipped default.
- An ABAP project needs an additional column on Field Definitions
  (e.g. `AuthGroup`, `BusinessUnit`) that the default layout doesn't cover.
- You localized the template to Japanese / Chinese / German and need the
  parser to find sheets by their localized names.
- You want to verify a customized template still parses correctly before
  handing it to a customer.

## Operations

| Operation | Purpose |
|---|---|
| `inspect` | Print the current layout in plain English |
| `bootstrap` | Seed a `(Meta) Layout` sheet from the built-in defaults |
| `add-column` | Add a column to a section — xlsx + meta updated together |
| `rename-sheet` | Rename a sheet and update meta so the parser still finds it |
| `validate` | Reconcile meta against the workbook + optional dry-parse |

## Auto-Trigger Keywords

- `customize spec template`, `edit spec layout`, `add column to spec`
- `rename sheet in template`, `localize spec template`
- `validate spec layout`, `check spec template structure`

## Usage

```text
/sap-docs-layout inspect      C:\path\to\spec_template.xlsx
/sap-docs-layout bootstrap    C:\path\to\spec_template.xlsx
/sap-docs-layout add-column   C:\path\to\spec_template.xlsx --section ddic_dataelements --name AUTHGROUP --after LABEL_LONG [--source-header <text>] [--required] [--transform trim]
/sap-docs-layout rename-sheet C:\path\to\spec_template.xlsx --section cover --to "封面"
/sap-docs-layout validate     C:\path\to\spec_template.xlsx --dry-parse
```

If you omit the workbook path the skill defaults to
`{custom_url}\spec_template.xlsx`, falling back to the built-in shared
template.

Conversational forms also work:

- "Show me the layout of my spec template"
- "Add an AuthGroup column to Field Definitions, after Length"
- "Rename Cover to 封面 in my template"
- "Does my customized template still parse correctly?"

## Prerequisites

- Python with `openpyxl` installed.
- A workbook with a `(Meta) Layout` sheet (run `bootstrap` first if absent).

## Suggested next steps

- After `bootstrap` or `add-column`: run `validate --dry-parse` to confirm
  `/sap-docs-extract` will still produce the expected output files.
- After `validate` passes: hand the customized template to the customer.
- The customer fills in their spec data, then runs `/sap-docs-extract` —
  it reads `(Meta) Layout` directly, no `--guide` flag needed.

## Limitations (V1)

- One section per sheet for now. Sections that span multiple sheets are not
  supported in V1 — workaround is to split into multiple sections.
- `add-column` inserts at column-block boundaries; arbitrary mid-block
  insertion with formula propagation is V2.
- Bulk operations (add-section, register-external-template) are V2. For now,
  bootstrap from the built-in defaults and edit incrementally.

## Version

- Skill Version: 0.1.0
- Last Updated: 2026-05-04

## License

GPL-3.0 License — see LICENSE file in the repository root.
