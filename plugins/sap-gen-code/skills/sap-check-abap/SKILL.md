---
name: sap-check-abap
description: |
  Validates ABAP source code quality before deployment. Checks:
  (1) Variable naming conventions against shared rules file,
  (2) Data type validity via SAP Dictionary (DDIF_FIELDINFO_GET / DDIF_DTEL_GET),
  (3) Unused variable detection,
  (4) SQL field validation — checks SELECT/UPDATE/DELETE field names against table definitions,
  (5) Generation contract rules (offline) — literal MESSAGE, read-only TEXT-NNN, block order / DECL_ORDER, SELECT *, LOOP-WHERE-EXIT, SPLIT-into-numeric, line length, and TEXT/MESSAGE sibling-file sync,
  (6) Spec-coverage (offline) — confirms the generated code covers every dependency, message, text element, and selection field in the design spec.
  Writes a tab-delimited result file with fix advice for each issue.
  SAP connection is optional — offline mode skips type and SQL field validation; the generation-contract and spec-coverage checks are always offline.
  Prerequisites: SAP GUI installed (provides SAP.Functions 32-bit COM object).
argument-hint: "<path-to-abap-source-file>"
---

# SAP Check ABAP Skill

You validate ABAP source code quality before deployment. You check variable naming conventions against a shared rules file, validate data types against the SAP Dictionary, detect unused variables, and verify SQL field references against table definitions. Results are written to a tab-delimited file with fix advice.

Task: $ARGUMENTS

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve cross-plugin paths: 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\settings.json` and (if present) `sap-dev-core\settings.local.json`. Read `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` / `*_run.vbs` and the `_run.json` state) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{RUN_TEMP}\sap_check_abap_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_check_abap_run.json" -Skill sap-check-abap -ParamsJson "{\"abap_file\":\"<ABAP_FILE>\"}"
```

---

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:
- **ABAP source file path** — required. If not provided, ask for it before continuing.

Verify the source file exists:
```bash
powershell -Command "if (Test-Path 'THE_FILE_PATH') { 'EXISTS' } else { 'NOT FOUND' }"
```

If the file does not exist, tell the user and stop.

Set these paths:
- **RESULT_FILE**: Same directory as the ABAP file, with `.check.tsv` extension (e.g. `{WORK_TEMP}\ztest.abap` → `{WORK_TEMP}\ztest.abap.check.tsv`)
- **NAMING_RULES**: First check if `{custom_url}\abap_naming_rules.tsv` exists. If yes, use it. Otherwise fall back to `<SAP_DEV_CORE_SHARED_DIR>\tables\abap_naming_rules.tsv` — resolve `<SAP_DEV_CORE_SHARED_DIR>` by going 3 levels up from `<SKILL_DIR>` (skill → skills/ → plugin dir → plugins root), then into `sap-dev-core\shared`
- **OBJECT_RULES**: First check `{custom_url}\sap_object_naming_rules.tsv`. If yes, use it. Otherwise fall back to `<SAP_DEV_CORE_SHARED_DIR>\tables\sap_object_naming_rules.tsv`. Used by Step 1.5 to validate program / FORM / class / method names.

Check custom overrides:
```bash
powershell -Command "if (Test-Path '{custom_url}\abap_naming_rules.tsv') { 'CUSTOM' } else { 'DEFAULT' }"
powershell -Command "if (Test-Path '{custom_url}\sap_object_naming_rules.tsv') { 'CUSTOM' } else { 'DEFAULT' }"
```

---

## Step 1.5 — Validate Top-Level Object Names

Parse the ABAP source for top-level object declarations and validate each name
against `sap_object_naming_rules.tsv` via the shared validator
`<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1`.

Patterns to scan (case-insensitive, regex):

| ABAP construct | OBJECT_TYPE for validator |
|---|---|
| `^\s*REPORT\s+(\w+)` or `^\s*PROGRAM\s+(\w+)` | `PROGRAM` |
| `^\s*FORM\s+(\w+)` | `SUBROUTINE` |
| `^\s*CLASS\s+(\w+)\s+DEFINITION\b` — classify by shape: a name matching `^(lcl_\|ltcl_\|ltc_\|lif_)` (case-insensitive), or a definition WITHOUT the `PUBLIC` addition (the addition may sit on a continuation line before the statement's closing period), is an in-source **local** class / test class; only a definition WITH the `PUBLIC` addition is a global class. Skip `DEFINITION DEFERRED` and `DEFINITION LOCAL FRIENDS` lines entirely. | `GLOBAL_CLASS` (PUBLIC definitions) / `LOCAL_CLASS` (in-source local classes) |
| `^\s*(?:METHODS|CLASS-METHODS)\s+(\w+)` (inside global CLASS DEFINITION blocks only) | `METHOD` |

> The shipped `sap_object_naming_rules.tsv` deliberately has NO `LOCAL_CLASS`
> row: the validator returns exit code `2` (UNKNOWN_TYPE) for local classes,
> which per the exit-code rule below is logged once and skipped — so `lcl_*` /
> `ltcl_*` classes are never checked against the `^ZCL_` global-class pattern.
> Shops that want to enforce a local-class convention add a `LOCAL_CLASS` row
> to `{custom_url}\sap_object_naming_rules.tsv`.

For each match, call:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType <TYPE> -ObjectName <NAME> -CustomUrl "{custom_url}"
```

Exit code `1` = VIOLATION → append a row to **RESULT_FILE** with:
- `Code`: `OBJECT_NAMING`
- `Severity`: `WARNING`
- `Variable`: the offending name
- `Detail`: the validator's stdout line
- `Fix Advice`: "Rename to follow `<expected pattern>` (e.g. `<example>`), or override the rule in `{custom_url}\sap_object_naming_rules.tsv`."

Exit code `0` = OK (no row written). Exit code `2` = UNKNOWN_TYPE / RULES_NOT_FOUND → log a single INFO note and skip (do not block).

> Note: variable-level naming inside FORM/METHOD/FUNCTION bodies is still
> handled by the existing VBScript checker (Step 3). Step 1.5 only covers the
> *top-level* object declarations.

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — offline checker, but rule applies to downstream deploy skills the checked source feeds |
| `sap-dev-core/settings.json` | *(config)* | SAP connection parameters |
| `sap-dev-core/shared/tables/abap_naming_rules.tsv` | `%%NAMING_RULES%%` | ABAP variable naming prefix conventions |
| `sap-dev-core/shared/tables/sap_object_naming_rules.tsv` | *(read by helper)* | Top-level SAP object naming patterns (program / class / method / FORM). Custom override: `{custom_url}\sap_object_naming_rules.tsv` |
| `sap-dev-core/shared/scripts/sap_check_object_name.ps1` | *(helper)* | Shared validator invoked in Step 1.5 |
| `<SKILL_DIR>/references/sap_check_signatures.ps1` | *(helper, skill-local)* | Step 3.5 signature validator — struct-field + AUTHORITY-CHECK shape vs the live-SAP caches |
| `<SKILL_DIR>/references/sap_check_spec_coverage.ps1` | *(helper, skill-local)* | Step 3.6 spec-coverage validator — confirms the generated manifests cover the spec's deps / messages / text elements / selection fields |
| `<SKILL_DIR>/references/sap_check_conversion.ps1` | *(helper, skill-local)* | Step 3.7 conversion validator — flags CURR/QUAN file columns mapped without their currency/unit reference, and `CURRENCY_AMOUNT_DISPLAY_TO_SAP` feeding a BAPI amount type (double-shift). Reads `*_file_mapping_*.txt` + `_struct_signatures.txt` (§28). |
| `sap-dev-core/shared/rules/abap_code_quality_rules.md` | *(rule)* | **Mandatory** ABAP code-quality rules. The VBS engine emits the offline-checkable rules in two phases. **Phase 5f** (per-line): `LITERAL_MESSAGE` + `MESSAGE_NUM_UNDECLARED` (§20), `TEXT_NNN_ASSIGN` + `TEXT_SYMBOL_UNDECLARED` (§21), `CLASS_DEF_AFTER_EVENT` (§10), `LOOP_WHERE_EXIT` (§19), `SPLIT_INTO_NUMERIC` (§25), `SELECT_STAR` (§12), `LINE_TOO_LONG`/`LINE_HARD_LIMIT`, plus `SQL_STRICT_COMMA` (§9). **Phase 5g** (scope-tracked): `MESSAGE_E_IN_METHOD` (§11), `SELECT_IN_LOOP` + `FOR_ALL_ENTRIES_NO_GUARD` (§12), `METHOD_TOO_LONG` (§18). These mirror the CI gate `scripts/lint-abap-contract.mjs` (same contract, two engines). The remaining heuristic rules — `MISSING_AT_HOST_VAR`/`STRING_CONCAT_SQL` (§13), `MISSING_AUTHZ_CHECK` (§14) — carry a higher false-positive risk and are reviewed by the orchestrator against this rule file rather than emitted by the engine. |
| `sap-dev-core/shared/templates/customer_brief.md` | *(config)* | Project Profile — used to set the quality bar (e.g. method length limit, modern-ABAP required, ATC priority gating) |

---

## Step 2 — Read SAP Connection Parameters

Read SAP connection parameters from the merged sap-dev-core settings (per `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`). The `sap_password` value typically comes from `settings.local.json` and is a `dpapi:...` blob — decrypt via `sap_dpapi.ps1` before use.
Resolve path: go 3 levels up from `<SKILL_DIR>` (skill → skills/ → plugin dir → plugins root),
then into `sap-dev-core\settings.json`.

| Setting key | Maps to | Example |
|---|---|---|
| `sap_application_server` | `%%SAP_SERVER%%` | `10.0.0.1` |
| `sap_system_number` | `%%SAP_SYSNR%%` | `00` |
| `sap_client` | `%%SAP_CLIENT%%` | `100` |
| `sap_user` | `%%SAP_USER%%` | `DEVELOPER` |
| `sap_password` | `%%SAP_PASSWORD%%` | *(masked)* |
| `sap_language` | `%%SAP_LANGUAGE%%` | `EN` |

**If `sap_application_server` is not configured**, ask the user:
> "Do you want to configure SAP connection in sap-dev-core settings.json for type validation,
> or run in offline mode (naming + unused checks only)?"

If offline mode, set `%%SAP_SERVER%%` to empty string and skip to Step 3.

---

## Step 3 — Generate and Run the Check VBScript

The VBScript template is at `./references/sap_check_abap.vbs` (relative to this skill directory).
RFC type lookups are delegated to the sidecar PowerShell helper at
`<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_ddic.ps1` (uses SAP NCo 3.1).

### 3a. Generate the filled DDIC helper PS1

The helper template has tokens: `%%SAP_*%%`, `%%REQUEST_FILE%%`, `%%RESULT_FILE%%`.
Token-substitute and write to `{RUN_TEMP}\sap_checkabap_ddic_helper.ps1`:

```powershell
$h = Get-Content '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_ddic.ps1' -Raw
$h = $h -replace '%%SAP_SERVER%%',   ''
$h = $h -replace '%%SAP_SYSNR%%',    ''
$h = $h -replace '%%SAP_CLIENT%%',   ''
$h = $h -replace '%%SAP_USER%%',     ''
$h = $h -replace '%%SAP_PASSWORD%%', ''
$h = $h -replace '%%SAP_LANGUAGE%%', ''
$h = $h -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$h = $h -replace '%%REQUEST_FILE%%', '{RUN_TEMP}\sap_checkabap_ddic_request.txt'
$h = $h -replace '%%RESULT_FILE%%',  '{RUN_TEMP}\sap_checkabap_ddic_result.tsv'
Set-Content '{RUN_TEMP}\sap_checkabap_ddic_helper.ps1' $h -Encoding UTF8
```

### 3b. Generate the filled VBScript

Write `{RUN_TEMP}\sap_checkabap_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_check_abap.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%SAP_SERVER%%',         'THE_SERVER'
$content = $content -replace '%%SAP_SYSNR%%',          'THE_SYSNR'
$content = $content -replace '%%SAP_CLIENT%%',         'THE_CLIENT'
$content = $content -replace '%%SAP_USER%%',           'THE_USER'
$content = $content -replace '%%SAP_PASSWORD%%',       'THE_PASSWORD'
$content = $content -replace '%%SAP_LANGUAGE%%',       'THE_LANGUAGE'
$content = $content -replace '%%ABAP_FILE%%',          'THE_ABAP_FILE'
$content = $content -replace '%%RESULT_FILE%%',        'THE_RESULT_FILE'
$content = $content -replace '%%NAMING_RULES%%',       'THE_NAMING_RULES_PATH'
$content = $content -replace '%%DDIC_HELPER_PS1%%',    '{RUN_TEMP}\sap_checkabap_ddic_helper.ps1'
$content = $content -replace '%%DDIC_REQUEST_FILE%%',  '{RUN_TEMP}\sap_checkabap_ddic_request.txt'
$content = $content -replace '%%DDIC_RESULT_FILE%%',   '{RUN_TEMP}\sap_checkabap_ddic_result.tsv'
$content = $content -replace '%%MAX_METHOD_LINES%%',   'THE_MAX_METHOD_LINES'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_checkabap_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>` / `<SAP_DEV_CORE_SHARED_DIR>` with absolute paths.
`THE_MAX_METHOD_LINES` = the customer brief's "Maximum method length" (`MODE_MAX_METHOD_LINES`); use `50` if the brief doesn't set it. The VBS defaults to 50 if the token is left unsubstituted or blank, so this is safe to omit.

For **offline mode**, set `THE_SERVER` to empty string (`''`); the VBS will skip the helper invocation entirely.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_checkabap_run.ps1"
```

### 3c. Execute the VBScript

Run via standard cscript (the VBS itself no longer needs 32-bit; the helper PS1 runs 32-bit PowerShell internally):
```bash
cscript.exe //NoLogo {RUN_TEMP}\sap_checkabap_run.vbs
```

Show the full script output as it runs. Then read the result file.

Delete the filled scripts (they contain plaintext credentials):
```bash
cmd /c del {RUN_TEMP}\sap_checkabap_run.vbs
cmd /c del {RUN_TEMP}\sap_checkabap_ddic_helper.ps1
```

---

## Step 3.5 — Validate against live-SAP signature caches (struct + AUTHX)

**Why:** the offline parser in Step 3 can't catch two error classes that show
up at SE38 upload / ATC time:

- **STRUCT field references** like `ls_clientdata-gross_wt = …` where
  `gross_wt` doesn't exist on `BAPI_MARA` on this S/4HANA build (was the 8
  syntax errors of round 5).
- **AUTHORITY-CHECK shape mismatches** vs the live SU21 field list (was the
  P2=10 SLIN storm of round 6).

`/sap-gen-abap` already populates two cache files in the work folder when
RFC is available:

- `<work_folder>/_struct_signatures.txt` (from Step 1.5e — DDIF_FIELDINFO_GET)
- `<work_folder>/_authz_signatures.txt`  (from Step 1.5b' — RFC_READ_TABLE on AUTHX)

This step runs a shared post-parser validator that reads those caches and
appends new finding rows to the same `THE_RESULT_FILE` the Step 3 VBS wrote.
The combined report at Step 4 then shows naming/type/SQL findings AND
struct-field/authz findings in one place.

### 3.5a — Locate signature cache files

The ABAP source lives in `<work_folder>/<NAME>.abap`. Both signature files
are emitted alongside it by `/sap-gen-abap`. Compute:

```
STRUCT_SIG = <directory of ABAP_FILE>\_struct_signatures.txt
AUTHZ_SIG  = <directory of ABAP_FILE>\_authz_signatures.txt
```

If neither file exists (the upstream gen didn't run RFC, or the ABAP is
hand-written and gen never ran), the validator cannot run — **that is a
coverage gap, not a clean pass**. Do all three, then continue:

1. Tell the user explicitly: `INFO: struct/authz signature caches not found
   — STRUCT_FIELD_MISSING and AUTHORITY-CHECK shape checks SKIPPED (reduced
   coverage). They require /sap-gen-abap Step 1.5 (RFC) to have populated
   _struct_signatures.txt / _authz_signatures.txt in this work folder.`
2. Append one honesty row to `THE_RESULT_FILE` so the written report carries
   the reduced-coverage marker (same 5-column schema as every other row):
   `Code=SIGNATURE_CHECKS_SKIPPED`, `Severity=WARNING`, `Variable=-`,
   `Detail=struct+authz signature caches absent; struct-field and
   AUTHORITY-CHECK shape validation not performed`,
   `Fix Advice=run /sap-gen-abap Step 1.5 (RFC) on this work folder, or
   accept the reduced check scope for hand-written code`.
3. Skip 3.5b/3.5c. The validator is purely additive — its absence doesn't
   break the existing checks, but the verdict line must count this WARNING
   like any other (a PASS with this row present is a *qualified* pass).

### 3.5b — Token-replace and run the validator

Template at `<SKILL_DIR>\references\sap_check_signatures.ps1`.

```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_check_signatures.ps1' -Raw
$content = $content.Replace('%%ABAP_FILE%%',       'THE_ABAP_FILE')
$content = $content.Replace('%%STRUCT_SIG_FILE%%', 'THE_STRUCT_SIG')   # may be '' if absent
$content = $content.Replace('%%AUTHZ_SIG_FILE%%',  'THE_AUTHZ_SIG')    # may be '' if absent
$content = $content.Replace('%%RESULT_FILE%%',     'THE_RESULT_FILE')  # SAME file Step 3 wrote
Set-Content '{RUN_TEMP}\sap_checkabap_signatures.ps1' $content -Encoding UTF8
```

Run via standard PowerShell (no SAP / no NCo — pure file I/O over cached
TSVs):

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_checkabap_signatures.ps1"
```

Expected stdout (when caches are present):
```
INFO: Struct cache loaded — 7 struct(s) with field lists, 0 NOT_FOUND.
INFO: AUTHX cache loaded — 3 object(s), 0 NOT_FOUND.
INFO: Checked 142 struct field reference(s); 8 error(s) found.
INFO: Checked 3 AUTHORITY-CHECK statement(s); 1 error(s) found.
INFO: Appended 9 finding(s) to THE_RESULT_FILE
```

### 3.5c — New finding classes added to the report

These are emitted by the signature validator (in addition to the codes Step 3 produces):

| Code | Severity | Meaning |
|---|---|---|
| `STRUCT_FIELD_MISSING` | ERROR | `<var>-<field>` references a field that doesn't exist on `<var>`'s structure type (per live DDIF_FIELDINFO_GET). Fix advice points at SE11 lookup or the correct BAPI parameter (e.g. `marmdata` for MARM-resident fields per §22). |
| `STRUCT_TYPE_MISSING` | ERROR | The struct type itself is in the cache with `NOT_FOUND` — typo or removed-in-this-release. |
| `AUTHZ_OBJECT_MISSING` | ERROR | `AUTHORITY-CHECK OBJECT '<X>'` references an object the SU21 lookup returned `NOT_FOUND` for. |
| `AUTHZ_FIELD_COUNT` | ERROR | The source's ID-clause count doesn't match the SU21 field count. SLIN would flag this as Priority 2 post-deploy; this catches it offline. |
| `AUTHZ_FIELD_NAME` | ERROR | ID-clause names don't match SU21 (missing fields, extra fields, or wrong names). |

Clean up:
```bash
cmd /c del {RUN_TEMP}\sap_checkabap_signatures.ps1
```

---

## Step 3.6 — Spec-coverage check (did the generated code cover the spec?)

**Why:** Steps 3 / 3.5 check that the code is internally well-formed. They do
NOT check that it COVERS the spec it was generated from — a dropped dependency,
a missing error message, or a selection field that never reached the screen all
pass those steps. This step derives the EXPECTED coverage from the spec
extraction files (`/sap-docs-extract` output) and confirms the generator's own
manifest siblings honoured it. It is the user-facing twin of the CI regression
net `scripts/diff-abap-skeleton.mjs`.

It compares (all in the work folder next to the `.abap`):

| Spec file (`<doc>_` prefix) | Generated manifest (`<stem>.` prefix) | Coverage |
|---|---|---|
| `<doc>_deps.txt` | `<stem>.deps.txt` | every spec dependency present |
| `<doc>_errorMsgs.txt` | `<stem>.messages.txt` | every spec message id emitted |
| `<doc>_textElements.txt` | `<stem>.text_elements.txt` `[TEXT_SYMBOLS]` | every spec text symbol present |
| `<doc>_selection_definition.txt` | `[SELECTION_TEXTS]` | field count matches |
| — | `<stem>.traceability.txt` | category rollup (informational) |

### 3.6a — Token-replace and run

Template at `<SKILL_DIR>\references\sap_check_spec_coverage.ps1`.

```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_check_spec_coverage.ps1' -Raw
$content = $content.Replace('%%ABAP_FILE%%',   'THE_ABAP_FILE')
$content = $content.Replace('%%RESULT_FILE%%', 'THE_RESULT_FILE')   # SAME file Step 3 wrote
Set-Content '{RUN_TEMP}\sap_checkabap_speccov.ps1' $content -Encoding UTF8
```

Run via standard PowerShell (no SAP — pure file I/O over the work folder):

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_checkabap_speccov.ps1"
```

If the work folder has no `*_deps.txt` / `*_errorMsgs.txt` / `*_textElements.txt`
/ `*_selection_definition.txt` (e.g. hand-written ABAP, or the spec lives
elsewhere), the script prints a single INFO line and appends nothing — the
check is purely additive.

### 3.6b — New finding classes

| Code | Severity | Meaning |
|---|---|---|
| `SPEC_DEP_MISSING` | WARNING | A dependency declared in the spec `_deps.txt` is absent from the generated `.deps.txt`. Best-effort name match. |
| `SPEC_MESSAGE_MISSING` | WARNING | A spec error-message id (`_errorMsgs.txt`) was not emitted in `.messages.txt`. |
| `SPEC_TEXTSYM_MISSING` | WARNING | A spec text element (`_textElements.txt`) is absent from `[TEXT_SYMBOLS]`. |
| `SPEC_SELECTION_COUNT` | WARNING | The spec selection-field count differs from `[SELECTION_TEXTS]`. |
| `SPEC_TRACEABILITY_INFO` | INFO | Category rollup of `.traceability.txt` entries (validation / processing / file-mapping). |

> **Boundary:** this is a STRUCTURAL coverage check (presence + counts). It does
> not verify the logic INSIDE a validation (right field, right operator) — that
> is the live ABAP Unit run (`/sap-run-abap-unit`) on the `_golden.txt` rows.

Clean up:
```bash
cmd /c del {RUN_TEMP}\sap_checkabap_speccov.ps1
```

---

## Step 3.7 — Internal/external conversion checks (CONVEXIT + CURR/QUAN)

**Why:** amounts / quantities and external-key fields convert between internal and
external representation at file boundaries (`GUI_UPLOAD` / `GUI_DOWNLOAD`,
`READ` / `TRANSFER DATASET`). Getting it wrong survives syntax + activation + ATC
and only shows as wrong data at runtime — the class `abap_code_quality_rules.md`
§28 governs. This step flags two such defects offline.

Template at `<SKILL_DIR>\references\sap_check_conversion.ps1`.

```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_check_conversion.ps1' -Raw
$content = $content.Replace('%%ABAP_FILE%%',   'THE_ABAP_FILE')
$content = $content.Replace('%%RESULT_FILE%%', 'THE_RESULT_FILE')   # SAME file Step 3 wrote
Set-Content '{RUN_TEMP}\sap_checkabap_conv.ps1' $content -Encoding UTF8
```

Run via standard PowerShell (no SAP — pure file I/O over the work folder):

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_checkabap_conv.ps1"
```

It cross-checks the spec `*_file_mapping_in.txt` / `*_file_mapping_out.txt`
(`/sap-docs-extract`) against `_struct_signatures.txt`. With the 13-column struct
signatures (`DATATYPE` / `CONVEXIT` / `REFTABLE` / `REFFIELD` — present after an RFC
run) the reference check is PRECISE (names the exact missing currency / unit
field); without them it falls back to a coarse program-level check. If neither the
mapping nor the struct cache is present it prints one INFO line and appends
nothing — purely additive.

### 3.7a — New finding classes

| Code | Severity | Meaning |
|---|---|---|
| `CONV_CURR_MISSING_REF` | WARNING | A `CURR` / `QUAN` file column is mapped to a SAP field but its reference currency (`CUKY`) / unit (`UNIT`) field is not — the amount's decimal count is undefined (TCURX-CURRDEC / T006-DECAN). e.g. `VBAP-NETPR` needs `VBAP-WAERK`. |
| `CONV_CURR_DISPLAY_TO_BAPI` | WARNING | `CURRENCY_AMOUNT_DISPLAY_TO_SAP` co-occurs with a BAPI amount type (`BAPICURR` / `BAPICUREXT` / `BAPICURR_D`) — verify the converted *internal* amount is not fed into a BAPI amount field (double-shift, e.g. 100× for JPY). |

Clean up:
```bash
cmd /c del {RUN_TEMP}\sap_checkabap_conv.ps1
```

---

## Step 4 — Interpret and Report Results

Read the result TSV file. The file has a header section (STATUS, ABAP_FILE, NAMING_RULES, TIMESTAMP, TOTAL_DECLARATIONS, TOTAL_SQL_STATEMENTS, TOTAL_ISSUES) followed by a column header row and tab-delimited findings.

### Summary table:

| Check Type | Count | Severity |
|---|---|---|
| NAMING | N | WARNING |
| TYPE_NOT_FOUND | N | ERROR |
| TYPE_RESOLVED | N | INFO |
| UNUSED | N | WARNING |
| SQL_TABLE_NOT_FOUND | N | ERROR |
| SQL_FIELD_NOT_FOUND | N | ERROR |

### Finding codes and their meaning:

| Code | Severity | Meaning |
|---|---|---|
| `NAMING` | WARNING | Variable name doesn't follow naming convention — wrong prefix |
| `TYPE_NOT_FOUND` | ERROR | Data type not found in local TYPES or SAP Dictionary |
| `TYPE_RESOLVED` | INFO | Data type successfully resolved (structure or data element) |
| `UNUSED` | WARNING | Variable declared but never referenced in the source |
| `SQL_TABLE_NOT_FOUND` | ERROR | SQL table not found in SAP Dictionary |
| `SQL_FIELD_NOT_FOUND` | ERROR | SQL field not found in the referenced table |
| `SQL_STRICT_COMMA` | ERROR | (Phase 5f) Strict-mode SQL (`@` host variables) with a space-separated field list — the SELECT list must be comma-separated (§9) |
| `METHOD_PARAM_NOT_FOUND` | ERROR | Named parameter in a method call does not exist in the local class's method signature |
| `SELECT_IN_LOOP` | ERROR | `SELECT` inside `LOOP AT itab` — pre-select instead (quality rule §12) |
| `FOR_ALL_ENTRIES_NO_GUARD` | ERROR | `FOR ALL ENTRIES` without `IF lt_keys IS NOT INITIAL` — empty driver reads ALL rows (§12) |
| `MESSAGE_E_IN_METHOD` | ERROR | `MESSAGE e/a/x` inside CLASS method — causes UNCAUGHT_EXCEPTION short dump (§11) |
| `MISSING_AT_HOST_VAR` | WARNING | Open-SQL host variable used without `@` prefix on release ≥ 7.50 (§13) |
| `STRING_CONCAT_SQL` | ERROR | Dynamic SQL via string concatenation without whitelist (§13) |
| `MISSING_AUTHZ_CHECK` | WARNING | Persistence (`UPDATE`/`INSERT`/`MODIFY`/`DELETE`/BAPI write) without preceding `AUTHORITY-CHECK` (§14) |
| `METHOD_TOO_LONG` | WARNING | Method exceeds `MODE_MAX_METHOD_LINES` from brief (default 50) (§18) |
| `OBJECT_NAMING` | WARNING | Top-level object name (program / FORM / global class / method) does not match `sap_object_naming_rules.tsv` |
| `LITERAL_MESSAGE` | ERROR | (Phase 5f) Hard-coded `MESSAGE '...'` / `MESSAGE \|...\|` text — route via a message class (§20). |
| `TEXT_NNN_ASSIGN` | ERROR | (Phase 5f) Assignment to a read-only `TEXT-NNN` symbol; populate via `.text_elements.txt` (§21). |
| `SELECT_STAR` | WARNING | (Phase 5f) `SELECT *` — list only the columns you use (§12). |
| `CLASS_DEF_AFTER_EVENT` | ERROR | (Phase 5f) Global `CLASS … DEFINITION` after an event block — the DECL_ORDER activation bug; move global decls before the event blocks (§10). |
| `LOOP_WHERE_EXIT` | WARNING | (Phase 5f) `LOOP AT … WHERE … EXIT` first-match; use `READ TABLE … TRANSPORTING NO FIELDS` (§19). |
| `SPLIT_INTO_NUMERIC` | ERROR | (Phase 5f) A `SPLIT … INTO` receiver is an elementary numeric variable; text-parse targets must be character-type (§25). |
| `LINE_TOO_LONG` / `LINE_HARD_LIMIT` | WARNING / ERROR | (Phase 5f) Source line > 72 cols (generation style rule) / > 255 cols (hard ABAP limit). |
| `TEXT_SYMBOL_UNDECLARED` | ERROR | (Phase 5f) `TEXT-NNN` referenced but absent from `[TEXT_SYMBOLS]` in the `.text_elements.txt` sibling (§21). Only when the sibling exists. |
| `MESSAGE_NUM_UNDECLARED` | ERROR | (Phase 5f) `MESSAGE eNNN(class)` referenced but absent from the `.messages.txt` sibling (§20). Only when the sibling exists. |
| `SPEC_DEP_MISSING` / `SPEC_MESSAGE_MISSING` / `SPEC_TEXTSYM_MISSING` / `SPEC_SELECTION_COUNT` | WARNING | (Step 3.6) Spec-coverage gaps — a spec dependency / message / text element / selection field is not covered by the generated manifests. |
| `SPEC_TRACEABILITY_INFO` | INFO | (Step 3.6) Category rollup of `.traceability.txt` entries. |
| `STRUCT_FIELD_MISSING` | ERROR | (Step 3.5) `<var>-<field>` references a field not on the variable's structure type, per `_struct_signatures.txt`. Catches BAPI_MARA-style typos before deploy. |
| `STRUCT_TYPE_MISSING` | ERROR | (Step 3.5) Struct type marked `NOT_FOUND` in cache — typo or release-removed. |
| `AUTHZ_OBJECT_MISSING` | ERROR | (Step 3.5) AUTHORITY-CHECK OBJECT name `NOT_FOUND` in SU21 cache. |
| `AUTHZ_FIELD_COUNT` | ERROR | (Step 3.5) AUTHORITY-CHECK ID-clause count ≠ SU21 field count. Pre-empts SLIN P2 "Wrong number of authorization fields". |
| `AUTHZ_FIELD_NAME` | ERROR | (Step 3.5) AUTHORITY-CHECK ID-clause names don't match SU21. Pre-empts SLIN P2 "Authorization field missing". |
| `CONV_CURR_MISSING_REF` | WARNING | (Step 3.7) A CURR/QUAN file column is mapped without its currency (CUKY) / unit (UNIT) reference — decimal count undefined (TCURX-CURRDEC / T006-DECAN) (§28). |
| `CONV_CURR_DISPLAY_TO_BAPI` | WARNING | (Step 3.7) `CURRENCY_AMOUNT_DISPLAY_TO_SAP` co-occurs with a BAPI amount type — double-shift smell; pass external amounts to BAPI fields (§28). |

### Detail — show all WARNING and ERROR findings:

For each finding, show: Line, Variable, Detail, Fix Advice.

**On `STATUS: SUCCESS`** — all declarations pass all checks. Congratulate the user.

**On `STATUS: SUCCESS_WITH_ISSUES`** — show findings grouped by severity (ERROR first, then WARNING). Suggest:
> "Run `/sap-fix-abap <file> <result-file>` to apply automatic fixes."

**On `STATUS: ERROR`:**

| Error message | Cause | Fix |
|---|---|---|
| `Cannot create SAP.Functions` | SAP GUI not installed or OCX not registered | Install SAP GUI; verify `wdtfuncs.ocx` |
| `RFC logon failed` | Wrong server/credentials | Verify connection parameters |
| `ABAP file not found` | Wrong path | Verify the file path |
| `Naming rules file not found` | Missing `sap-dev-core/shared/tables/abap_naming_rules.tsv` | Verify sap-dev-core plugin is installed |

---

## Step 5 — Clean Up

```bash
cmd /c del {RUN_TEMP}\sap_checkabap_run.ps1
cmd /c del {RUN_TEMP}\sap_checkabap_conv.ps1
```

Keep the result TSV so the user can review it or pass it to `sap-fix-abap`. To remove:
```bash
cmd /c del "THE_RESULT_FILE"
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_check_abap_run.json" -Status SUCCESS -ExitCode 0 -MetricsJson '{"gate":"CHECK","verdict":"PASS","errors":0,"warnings":0}'
```

**Build-KPI enrichment (best-effort).** Add `-MetricsJson` populated from the
`.check.tsv` summary: `verdict` is `PASS` when the ERROR-severity count is 0
else `FAIL`; `errors`/`warnings` are the severity counts. The offline aggregator
(`shared/rules/build_metrics.md`) reads it for `gen_first_pass_pct` and derives
the per-build fix-iteration count by counting how many CHECK end-records appear
in the build cluster — so you do not report iterations here. Best-effort: omit
if you cannot read the counts.

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_check_abap_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `CHECK_ABAP_FAILED`, `RFC_LOGON_FAILED`.

---

## Security Note

The generated `.vbs` file contains the SAP password in plain text and is deleted automatically after execution.
Connection parameters are stored in sap-dev-core settings.json. The password field is marked as
`sensitive` and masked in the Claude Code UI.

---

## ABAP Parsing Limitations

- **Local classes**: Variables declared inside `CLASS ... IMPLEMENTATION` / `ENDCLASS` blocks are **not currently validated** for naming or type checks. This is a known gap — code generated by sap-gen-abap that uses local classes should be manually reviewed for type correctness before deployment.
- **Scope tracking**: FORM/ENDFORM, METHOD/ENDMETHOD, FUNCTION/ENDFUNCTION only. Nested scopes (IF/LOOP etc.) do not affect scope detection.
- **Chain declarations**: Handled for DATA, TYPES, CONSTANTS, FIELD-SYMBOLS.
- **FORM parameters**: Parsed from the FORM line only. Multi-line FORM signatures may miss parameters after the first continuation line.
- **Structure vs. scalar**: Without SAP connection, cannot distinguish STRUCTURE from VARIABLE for SAP-standard types. Local TYPES (BEGIN OF / TYPES tt_x TYPE TABLE OF ...) are tracked and propagated to variables typed by them, so naming-rule checks honour the right kind even offline.
- **TYPES declarations**: Local TYPES are tracked as valid types but are not checked for naming conventions by default. Users can add TYPES rules to the naming file.
- **Selection screen**: PARAMETERS and SELECT-OPTIONS are detected. SELECTION-SCREEN BEGIN OF BLOCK, etc. are ignored.
- **Inline DATA()**: Inline declarations like `DATA(lv_x) = ...`, `READ TABLE … INTO DATA(ls_row)`, `LOOP AT … INTO DATA(ls_row)`, `SELECT … INTO TABLE @DATA(lt_data)` are scanned and added to the declaration table with type unknown. They are NOT subject to TYPE_NOT_FOUND (no type to check) and NOT subject to UNUSED (the inline-declaration line IS the first-use line). Naming-rule checks still apply.
- **Table-field type syntax**: `TYPE mara-matnr`, `TYPE rlgrap-filename`, etc. are accepted silently — the type validator skips them rather than emitting a false TYPE_NOT_FOUND. A future enhancement may split on `-` and validate the field via DD03L.
- **SQL validation**: SELECT, UPDATE, DELETE statements are parsed. JOINs with aliases are supported. Aggregate functions (COUNT, SUM, etc.) skip field checking. Dynamic SQL, CDS views, subqueries, UNION, GROUP BY/ORDER BY/HAVING field validation are not supported. Only field existence is checked, not INTO-variable type compatibility. Requires SAP connection (skipped in offline mode).
- **Custom Z-tables in SQL**: If the ABAP code references custom Z-tables (e.g., `ZHKFIXEDVALS`), the SQL check will report `SQL_TABLE_NOT_FOUND` until the table is created in SAP. This is expected behavior — create the table via sap-se11 first, then re-run the check.
- **MESSAGE e/a/x in local class methods**: `MESSAGE` types E, A, X inside `CLASS ... IMPLEMENTATION` methods will cause `UNCAUGHT_EXCEPTION` at runtime. Replace with exception classes or result table pattern. Flag these as potential short dump causes during static analysis.
- **Custom types in BAPI TABLES parameters**: When a `CALL FUNCTION` for a BAPI uses a local table typed differently from the BAPI's expected structure, flag as potential `CALL_FUNCTION_CONFLICT_LENG`. Example: `DATA lt TYPE TABLE OF ty_custom` passed to `materialdescription` which expects `bapi_makt`. Always use the exact BAPI structure type for TABLES and EXPORTING/IMPORTING parameters.
- **GUI_UPLOAD `has_field_separator` with flat char tables**: `has_field_separator = 'X'` with `TABLE OF charNNNN` (single-field flat table) strips tab delimiters and only reads the first column. Remove `has_field_separator` when using flat char tables and parse tab separators manually with `SPLIT`.

---

## Pipeline Integration

This skill is part of the ABAP quality pipeline:

1. **sap-gen-abap** — generates ABAP source code from design documents
2. **sap-check-abap** ← you are here — offline + RFC validation (naming, types, SQL fields, basic patterns)
3. **sap-atc** — in-system SCI / ATC run, priority-gated via the customer brief's `MAX_PRIORITY`
4. **sap-fix-abap** — applies automatic fixes from check results
5. **abap-deploy** — deploys to SAP system (sap-se38 / sap-se37 / sap-se24 / sap-se11 / sap-se91)
