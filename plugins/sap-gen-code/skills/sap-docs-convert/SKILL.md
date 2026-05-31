---
name: sap-docs-convert
description: |
  Applies customer-specific normalisation rules to the extracted spec files
  in a work folder. Reads `spec_conversion_rules.tsv` (default at
  sap-dev-core/shared/tables/, override at {custom_url}/spec_conversion_rules.tsv)
  and rewrites the affected `_*.txt` files in place.

  Three rule categories:
    * field_rename  — legacy field name → canonical name
    * type_rename   — legacy DDIC type token → canonical token
    * flag_mapping  — legacy flag value → one or more KEY=VALUE pairs

  Plus optional schema migration (legacy customer YAML/TSV layout → Customer
  Brief layout).

  Input:  work folder containing the extracted `_*.txt` files (output of /sap-docs-extract).
  Output: same files rewritten in place; a `.pre-convert/` snapshot is taken first.
  This skill is OPTIONAL — projects already authoring specs in Customer Brief
  format can skip it entirely.
argument-hint: "<work-folder>  [rules-file-path]"
---

# SAP Docs Convert Skill

You normalise an extracted spec by applying customer-specific rules. Runs
between `/sap-docs-extract` and the validation / generation skills:

```
spec.xlsx ──[sap-docs-extract]──▶ raw _*.txt
                                     │
                                     ▼
                  ──[sap-docs-convert]── (optional, rules-driven)
                                     │
                ┌────────────────────┼─────────────────────┐
                ▼                    ▼                     ▼
       /sap-docs-check-ddic  /sap-docs-check-process   /sap-gen-abap
```

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — offline normaliser, but rule applies to downstream deploy skills the converted spec feeds |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — type-rename and flag-mapping rules that convert legacy spec fields into Customer Brief layout must preserve ABAP-quality affordances (DTEL vs. primitive, currency reference) so the generated code stays clean |

---

## Step 0 — Resolve Work Directory and Rules File

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve cross-plugin paths: 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\settings.json` and (if present) `sap-dev-core\settings.local.json`. Read `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir`   | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Locate the rules file (priority order — first hit wins):

1. The 2nd positional argument, if provided.
2. `{custom_url}\spec_conversion_rules.tsv` — customer override.
3. `<SAP_DEV_CORE_SHARED_DIR>\tables\spec_conversion_rules.tsv` — built-in default.

If no rules file is found, abort with:
> "No spec_conversion_rules.tsv found. Either pass the path as the 2nd argument, drop one in {custom_url}, or use the default at sap-dev-core/shared/tables/."

Also set `{WORK_TEMP}` = `{work_dir}\temp` (used below for the log state file).

---

## Step 0.5 — Start Logging

Start a structured log run. Best-effort: silently no-ops if disabled or the
lib can't load. `<SAP_DEV_CORE_SHARED_DIR>` resolves to
`plugins/sap-dev-core/shared/`. State file: `{WORK_TEMP}\sap_docs_convert_run.json`.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_docs_convert_run.json" -Skill sap-docs-convert -ParamsJson "{\"work_folder\":\"<WORK_FOLDER>\",\"rules_file\":\"<RULES_PATH>\"}"
```

---

## Step 1 — Resolve Work Folder

Extract the work-folder argument. If missing, ask:
> "Please provide the work folder path containing the extracted `_*.txt` files."

Verify the folder exists and contains at least one `*_raw.txt` file. Locate
the single `*_raw.txt` to derive `{doc_name}` (strip `_raw.txt` suffix). If
zero or multiple raw files exist, abort with a clear error.

---

## Step 2 — Snapshot Pre-Convert State

Before any rewriting, copy the current `_*.txt` files to a snapshot folder so
the operation is reversible:

```powershell
$snap = Join-Path "{work_folder}" ".pre-convert"
if (-not (Test-Path $snap)) { New-Item -ItemType Directory -Path $snap | Out-Null }
Get-ChildItem -Path "{work_folder}" -Filter "*.txt" -File |
    ForEach-Object { Copy-Item $_.FullName -Destination $snap -Force }
```

If `.pre-convert` already exists from a prior run, leave it alone — keep the
oldest snapshot so the user can always roll back to the original extract
output.

---

## Step 3 — Read the Rules File

The rules file is TSV with a header line. Required columns:

| Column     | Meaning |
|---|---|
| `CATEGORY` | One of `field_rename`, `type_rename`, `flag_mapping`, `schema_migration` |
| `FROM`     | Source token (legacy value) |
| `TO`       | Target token (canonical value); for `flag_mapping` use `KEY1=VAL1;KEY2=VAL2` |
| `SCOPE`    | *(optional)* Comma-separated list of files to limit the rule to. Empty = apply everywhere. Examples: `_tables.txt`, `_domains.txt,_dataElements.txt` |
| `NOTES`    | *(optional)* Free-text comment, ignored by the engine |

Example rows:

```tsv
CATEGORY	FROM	TO	SCOPE	NOTES
field_rename	FELDNAME	FIELDNAME		legacy German naming
field_rename	KEY_FLAG	KEY	_tables.txt	
type_rename	CHAR(N)	CHAR		strip parentheses
type_rename	STRING255	CHAR 255	_domains.txt	flatten to fixed-length
flag_mapping	PK	KEY=X;INITIAL=X	_tables.txt	primary-key shorthand
schema_migration	LEGACY_HK_V1	CUSTOMER_BRIEF		see notes
```

Skip blank lines and lines starting with `#`.

---

## Step 4 — Apply Rules

Iterate the target files in `{work_folder}`:

| File | Rules to apply |
|---|---|
| `{doc_name}_PGM_summary.txt`   | field_rename |
| `{doc_name}_domains.txt`       | field_rename, type_rename |
| `{doc_name}_dataElements.txt`  | field_rename, type_rename |
| `{doc_name}_tables.txt`        | field_rename, type_rename, flag_mapping |
| `{doc_name}_errorMsgs.txt`     | field_rename |
| `{doc_name}_textElements.txt`  | field_rename |
| `{doc_name}_process.txt`       | field_rename, type_rename |
| `table_data_*.txt`             | field_rename (header row only) |

For each rule:

- **field_rename / type_rename**: do whole-token replacement (no substring
  match across word boundaries). For TSV files, replace cell values exactly,
  not partial strings.
- **flag_mapping**: rule `FROM=PK`, `TO=KEY=X;INITIAL=X` means: when a row
  contains a column with value `PK`, set the `KEY` column to `X` and the
  `INITIAL` column to `X`. Implemented per file format — driven by header row.
- **schema_migration**: free-form transformation block. Each migration name
  (e.g. `LEGACY_HK_V1`) is a known transformation in this skill's
  `references/migrations/<name>.md`. If the migration name is unknown, log a
  WARNING and skip it.

Honour `SCOPE`: if non-empty, only apply the rule to files whose name appears
in the comma-separated list.

---

## Step 5 — Write Back, Log What Changed

For each file rewritten, write the new content with the Write tool (UTF-8,
overwriting the original).

Maintain a per-run log at `{work_folder}/_convert_log.txt` (overwrite each
run) recording:

```
sap-docs-convert run @ <timestamp>
Rules file: <path>
Rules loaded: <n>
File: {doc_name}_tables.txt
  field_rename: FELDNAME -> FIELDNAME (3 hits)
  type_rename : CHAR(N)  -> CHAR      (5 hits)
  flag_mapping: PK       -> KEY=X;INITIAL=X (1 hit)
File: {doc_name}_domains.txt
  type_rename : STRING255 -> CHAR 255 (2 hits)
TOTAL CHANGES: 11
Rolled-back snapshot: {work_folder}/.pre-convert/
```

If a rule has zero hits across all files, list it as `(0 hits)` so the user
can spot stale rules.

---

## Step 6 — Report

Report to the user:

- Rules file used: `<path>` (was it the override or the default?)
- Number of rules loaded
- Per-file change counts (concise version of the log)
- Snapshot location (so the user knows how to roll back)
- Suggest next steps:
  - `/sap-docs-check-process {work_folder}`
  - `/sap-docs-check-ddic {work_folder}`
  - `/sap-gen-abap {work_folder}/{doc_name}_process.txt`

If the user wants to roll back, they restore from `{work_folder}/.pre-convert/`:

```powershell
Get-ChildItem "{work_folder}\.pre-convert" -File |
    ForEach-Object { Copy-Item $_.FullName "{work_folder}\" -Force }
```

End the log run. Use `SUCCESS` when at least one rule changed at least one
file; use `EXISTED` when no rule matched (no-op convert); use `FAILED` with
`ErrorClass=CONVERT_FAILED` if a rule could not be applied:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_docs_convert_run.json" -Status SUCCESS -ExitCode 0
```

---

## Notes

- This skill is **idempotent on the snapshot** — running it twice in a row
  with the same rules produces the same result, because the second run's
  inputs are the already-converted files. Re-run after a rollback if you
  want to compare different rule sets.
- The `_raw.txt` file is **not** modified — it always represents the original
  document dump from `/sap-docs-extract`.
- `schema_migration` rules are intentionally pluggable. To add a new
  migration, drop a `references/migrations/<NAME>.md` file with a clear
  step-by-step transformation spec; the skill will load it on demand.
