# SAP Docs Convert Skill

Applies customer-specific normalisation rules to the extracted spec files in
a work folder. Reads `spec_conversion_rules.tsv` (default at
`sap-dev-core/shared/tables/`, override at
`{custom_url}/spec_conversion_rules.tsv`) and rewrites the affected `_*.txt`
files in place.

This skill is **optional** — projects already authoring specs in Customer
Brief format can skip it entirely. Use it when ingesting legacy specs from
older customer formats that need to be normalised before validation /
generation.

## Skill Overview

1. Resolve the rules file (positional arg → `{custom_url}` override → built-in
   default)
2. Snapshot all `_*.txt` files to `{work_folder}/.pre-convert/` (so the
   operation is reversible)
3. Apply rules per file:
   - **`field_rename`** — legacy field name → canonical name
   - **`type_rename`** — legacy DDIC type token → canonical token
   - **`flag_mapping`** — legacy flag value → one or more `KEY=VALUE` pairs
   - **`schema_migration`** — full schema migration (legacy customer YAML/TSV
     layout → Customer Brief layout); each migration name is a Markdown spec
     in `references/migrations/<name>.md`
4. Write back the affected files with the Write tool (UTF-8, overwriting)
5. Log per-file change counts to `{work_folder}/_convert_log.txt`

## Auto-Trigger Keywords

- `convert spec`, `normalise spec`, `apply spec rules`
- `migrate legacy spec to customer brief format`

## Usage

```text
/sap-docs-convert <work-folder>
/sap-docs-convert <work-folder> <rules-file-path>
```

Examples:

```text
/sap-docs-convert C:\sap_dev_work\source_code\work\Spec_20260501\
/sap-docs-convert C:\sap_dev_work\...\Spec_20260501\ C:\custom\my_rules.tsv
```

Conversational forms:

- "Apply the customer's naming rules to this work folder"
- "Normalise the extracted spec before validation"
- "Migrate this legacy spec to the new Customer Brief format"

## Prerequisites

- Work folder must contain at least one `*_raw.txt` file (output of
  `/sap-docs-extract`) plus the structured `_*.txt` files
- A rules file must be findable (positional arg, `{custom_url}` override, or
  built-in default)

## Rules file format

TSV with header. Required columns: `CATEGORY`, `FROM`, `TO`. Optional:
`SCOPE` (limit to specific files), `NOTES` (ignored).

```tsv
CATEGORY         FROM       TO                  SCOPE          NOTES
field_rename     FELDNAME   FIELDNAME                          legacy DE naming
type_rename      CHAR(N)    CHAR                               strip parens
flag_mapping     PK         KEY=X;INITIAL=X     _tables.txt    primary-key shorthand
```

See [spec_conversion_rules.tsv](../../../sap-dev-core/shared/tables/spec_conversion_rules.tsv)
for the built-in default with examples for each category.

## Rollback

```powershell
Get-ChildItem "{work_folder}\.pre-convert" -File |
    ForEach-Object { Copy-Item $_.FullName "{work_folder}\" -Force }
```

The `.pre-convert/` snapshot persists across runs (oldest snapshot is
preserved, so rolling back always restores the original extract output).

## Limitations

- The `_raw.txt` file is **never** modified — always represents the original
  document dump from `/sap-docs-extract`
- `schema_migration` rules require a corresponding Markdown spec at
  `references/migrations/<NAME>.md`; unknown migration names log a WARNING
  and are skipped

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
