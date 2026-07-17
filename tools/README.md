# tools/

Local build / authoring scripts. Not part of any plugin runtime — these are
helpers used by the maintainer to (re)generate artefacts that ship inside
the plugins.

| Script | Purpose |
|---|---|
| `build_spec_template.py` | Build the canonical `spec_template.xlsx` from scratch — 17 content sheets + a `(Meta) Layout` sheet that maps each section to its output file (left visible in the committed templates so reviewers can inspect it; `/sap-docs-layout` sets it to hidden in production). Bilingual: `--lang EN` (default) writes `spec_template.xlsx`; `--lang JA` writes `spec_template_JA.xlsx`. |
| `spec_translations.py` | Translation strings used by `build_spec_template.py`. Single source of truth for sheet names, headers, banner text, and README content per language. Adding a third language = add a `"ZH": {...}` entry to each dict; no other code changes needed. |

## Dependencies

Install the Python deps once before running any script here:

```bash
python -m pip install -r tools/requirements.txt
```

`requirements.txt` pins `openpyxl` (xlsx read/write), `Pillow` (embedded-image
decode for `extract_spec.py`), and `python-docx` (the `/sap-docs-extract`
`.docx` path).

## Usage

```bash
python tools/build_spec_template.py            # → spec_template.xlsx (EN)
python tools/build_spec_template.py --lang JA  # → spec_template_JA.xlsx
```

Or both:

```bash
for lang in EN JA; do python tools/build_spec_template.py --lang $lang; done
```

Run after any intentional change to `tools/spec_translations.py` or to the
sheet structure inside `tools/build_spec_template.py`. Both `.xlsx` outputs
are committed to the repo so customers don't need to run this script.

## Adding a new language (e.g. Chinese)

1. Add a `"ZH": {...}` entry to each dict in `tools/spec_translations.py`
   (`T_SHEETS`, `T_TITLES`, `T_BANNER`, `T_SECTION_BANNERS`, `T_HEADERS`,
   `T_KEYWORDS`, `T_COVER_LABELS`, `T_README`).
2. Run `python tools/build_spec_template.py --lang ZH`.
3. Update `.gitignore` allow-list to include the new `_ZH.xlsx` file.
4. Update `CLAUDE.md` "Currently shipped variants" list.

The build script will refuse with a clear error if any dict is missing the
requested language — guard against partial translations.

## Adding / removing a sheet

Edit `tools/build_spec_template.py`:

1. Add (or remove) a sheet-creation block in the `# Build workbook` section.
2. Add (or remove) the corresponding row in `SECTIONS_ROWS` (controls the
   `(Meta) Layout` SECTIONS table).
3. Add (or remove) rows in `COLUMN_ROWS` (one per output column for `tsv`/`kv`
   format; zero for `image`/`text`).
4. Add the per-language sheet name, title, banner, and column headers to
   `tools/spec_translations.py` for every supported language.
5. Rebuild for every language: `for lang in EN JA; do python tools/build_spec_template.py --lang $lang; done`.

The steps above are the full checklist. Remember the downstream wiring: the
`/sap-docs-extract` and `/sap-gen-abap` skills consume the new section's output
file — update their SKILL.md handling of the section-to-file mapping to match.


## Reference implementations

| Script | Purpose |
|---|---|
| `extract_spec.py` | Reference implementation of `/sap-docs-extract` for workbooks with a `(Meta) Layout` sheet. Reads SECTIONS + COLUMNS, dispatches by format (`kv`, `tsv`, `image`, `text`), produces the standard `_*.txt` / `_*.png` artefacts. Useful for CI / regression and as documentation of the skill's intent. |
| `sanity_check_spec.py` | Offline spec sanity check — Step 2a.5 of the `abap-developer` agent. Runs the eight checks defined in the agent body against a work folder (`python tools/sanity_check_spec.py <work_folder>`); exit 0 = pass/WARN-only, 1 = a STOP-level check failed. Prints a result table for the agent transcript. |

## Migration helpers

| Script | Purpose |
|---|---|
| `migrate_session_lock.py` | Retrofit existing VBS reference scripts with `TryLockSession` / `ReleaseSession` per Rule 7. Idempotent. Add new files to the `RETROFITS` dict and re-run. Also patches the matching `SKILL.md` token-replacement blocks where the Get-Content path is a literal. |
