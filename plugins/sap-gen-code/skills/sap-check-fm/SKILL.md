---
name: sap-check-fm
description: |
  Validates ABAP CALL FUNCTION statements in ABAP source code against the
  actual function module parameter definitions retrieved via RFC.
  Checks parameter names (unknown, missing mandatory, wrong section) and
  data types (compatibility of the passed variable's type with the FM
  parameter type). For structure parameters, validates every component
  field by field. Uses RPY_FUNCTIONMODULE_READ_NEW to get FM definitions,
  DDIF_FIELDINFO_GET for structure/table type details, and DDIF_DTEL_GET
  for data element details.
  Prerequisites: SAP GUI installed (provides SAP.Functions 32-bit COM object).
argument-hint: "<path-to-abap-source-file>"
---

# SAP Check FM Skill

You validate ABAP `CALL FUNCTION` statements in a source file against live SAP function module definitions via RFC. You check parameter names and data types, and report unknown parameters, missing mandatory parameters, wrong-section parameters, and type compatibility issues.

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

Start a structured log run. State file: `{WORK_TEMP}\sap_check_fm_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_check_fm_run.json" -Skill sap-check-fm -ParamsJson "{\"abap_file\":\"<ABAP_FILE>\"}"
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

Set **RESULT_FILE** = same directory as the ABAP file, with `.check_fm.tsv`
extension (e.g. `ztest.abap` → `ztest.abap.check_fm.tsv`). This per-input
path is what `/sap-fix-fm` reads by default, keeps parallel sessions from
clobbering each other, and cannot collide with sap-check-abap's `.check.tsv`.

---

## Step 1.5 — Validate FM and FG Names

Resolve the object naming rules path (custom override → default):

```bash
powershell -Command "if (Test-Path '{custom_url}\sap_object_naming_rules.tsv') { 'CUSTOM' } else { 'DEFAULT' }"
```

Parse the ABAP source file:
- Every `^\s*FUNCTION\s+(\w+)\s*\.` line → `FUNCTION_MODULE` candidate.
- A `FUNCTION-POOL\s+(\w+)` line, if present → `FUNCTION_GROUP` candidate.
  When only an FM include is provided (no FUNCTION-POOL header), ask the user
  for the target function group name and validate that.

For each candidate, call:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType <TYPE> -ObjectName <NAME> -CustomUrl "{custom_url}"
```

Exit code `1` → append a finding to **RESULT_FILE** (`<abap-file>.check_fm.tsv`,
set in Step 1) with code `OBJECT_NAMING` and the validator's stdout line. Exit
`0` is silent. Exit `2` (no rule for that type / rules file missing) is logged
once and skipped.

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — offline checker, but rule applies to downstream deploy skills the checked source feeds |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | *(rule)* | ABAP code-quality rules — informs CALL FUNCTION signature checks against modern-ABAP conventions (e.g. MESSAGE_E_IN_METHOD, MISSING_AT_HOST_VAR, STRING_CONCAT_SQL) |
| `sap-dev-core/settings.json` | *(config)* | SAP connection parameters |
| `sap-dev-core/shared/tables/sap_object_naming_rules.tsv` | *(read by helper)* | FM / FG naming patterns. Custom override: `{custom_url}\sap_object_naming_rules.tsv` |
| `sap-dev-core/shared/scripts/sap_check_object_name.ps1` | *(helper)* | Shared name validator invoked in Step 1.5 |

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

**If settings are not configured**, ask the user to provide the values and suggest
they configure sap-dev-core settings.json for future use.

---

## Step 2.5 — Detect pre-populated signature caches (optional, fail-soft)

`/sap-gen-abap` (Step 1.5e) and `/sap-docs-check-process` (Step 4.5) both
populate `_struct_signatures.txt` in the work folder alongside the ABAP
source. When this file is present, the operator already has live DDIF
field lists for every BAPI structure type the FM signatures reference —
and the per-system disk cache at `{work_dir}\cache\struct_signatures\`
is warm.

Detect the cache and log it so the operator sees the chain at work:

```bash
powershell -Command "$s = Split-Path 'THE_ABAP_FILE'; $f = Join-Path $s '_struct_signatures.txt'; if (Test-Path $f) { 'STRUCT_CACHE: ' + $f + ' (' + ((Get-Content $f).Count) + ' rows)' } else { 'STRUCT_CACHE: not present (will fall back to direct DDIF_FIELDINFO_GET via ddic helper)' }"
```

The Step 3 ddic helper (`sap_rfc_lookup_ddic.ps1`) already RFCs live for
type resolution; the work-folder cache is informational here. A future
enhancement would feed `_struct_signatures.txt` directly into the VBS to
skip RFC roundtrips for cache hits — tracked but not yet implemented.

### Coverage relationship with sap-check-abap Step 3.5

These two checks are **complementary, not redundant**:

| Reference shape in source | Caught by sap-check-fm | Caught by sap-check-abap Step 3.5 |
|---|---|---|
| `CALL FUNCTION 'BAPI_X' EXPORTING param = ls_x.` (parameter name + struct type) | ✓ (deep field-by-field check inside Step 4) | partial (validates `ls_x-field` refs elsewhere in source) |
| `ls_x-field = ...` (any struct field assignment / read in source) | ✗ (only inspects CALL FUNCTION contexts) | ✓ (consumes `_struct_signatures.txt`) |
| `AUTHORITY-CHECK OBJECT '<X>' ID '<F>' …` | ✗ | ✓ (consumes `_authz_signatures.txt`) |
| `SELECT field FROM <table>` | ✗ | ✓ (existing SQL field validation) |
| Inline `VALUE bapi_mara( field = … )` constructor with bad field | ✗ (constructor parsing is out of scope) | ✗ (regex-only scanner doesn't follow `VALUE` typed constructors) |

**Recommended order**: run `/sap-check-fm <file>` then `/sap-check-abap <file>`.
The FM check catches CALL FUNCTION mistakes early; the ABAP check catches
the broader field-reference / AUTHORITY-CHECK class. Both write to
different result files (`.check_fm.tsv` vs `.check.tsv`) so neither
overwrites the other.

The inline VALUE-constructor gap remains — neither checker walks typed
constructors today. Generator rule §22 documents the trap; ATC would
catch wrong-field constructors at deploy time. Worth flagging for a
future check enhancement.

---

## Step 3 — Generate and Run the Validation VBScript

The VBScript template is at `./references/sap_check_fm.vbs` (relative to this skill directory).
It delegates RFC calls to two PowerShell sidecar helpers (NCo 3.1 based), both
shared across multiple skills:
- `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lookup_fm.ps1` — fetches FM parameter signatures (with **per-system disk cache**)
- `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lookup_ddic.ps1` — resolves DDIC types

### 3a. Generate the filled FM helper PS1

The FM helper template is at `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_fm.ps1`.

Resolve cache directory + system ID (see "Step 0 — Resolve Work Directory"):
- `{FM_CACHE_DIR}` = `userConfig.fm_cache_dir`, or if blank: `{work_dir}\cache\fm_signatures`
- `{SYSTEM_ID}` = `{sap_application_server}_{sap_system_number}_{sap_client}` (e.g. `saphost.example.com_00_100`)

```powershell
$h = Get-Content '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_fm.ps1' -Raw
$h = $h -replace '%%SAP_SERVER%%',     ''
$h = $h -replace '%%SAP_SYSNR%%',      ''
$h = $h -replace '%%SAP_CLIENT%%',     ''
$h = $h -replace '%%SAP_USER%%',       ''
$h = $h -replace '%%SAP_PASSWORD%%',   ''
$h = $h -replace '%%SAP_LANGUAGE%%',   ''
$h = $h -replace '%%RFC_LIB_PS1%%',    '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$h = $h -replace '%%REQUEST_FILE%%',   '{RUN_TEMP}\sap_checkfm_fm_names.txt'
$h = $h -replace '%%RESULT_FILE%%',    '{RUN_TEMP}\sap_checkfm_fm_result.tsv'
$h = $h -replace '%%CACHE_DIR%%',      '{FM_CACHE_DIR}'
$h = $h -replace '%%SYSTEM_ID%%',      '{SYSTEM_ID}'
$h = $h -replace '%%TTL_STD_DAYS%%',   '30'      # or userConfig.fm_cache_ttl_std_days
$h = $h -replace '%%TTL_Z_DAYS%%',     '1'       # or userConfig.fm_cache_ttl_z_days
$h = $h -replace '%%REFRESH_CACHE%%',  'false'   # 'true' to bypass cache for this run
Set-Content '{RUN_TEMP}\sap_checkfm_fm_helper.ps1' $h -Encoding UTF8
```

The cache layer means: if a customer ran `sap-gen-abap` (which now also pre-fetches signatures) and `sap-check-fm` against the same SAP system, the second skill reuses the first skill's cached signatures — no redundant RFC roundtrips.

### 3b. Generate the filled DDIC helper PS1

```powershell
$d = Get-Content '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_ddic.ps1' -Raw
$d = $d -replace '%%SAP_SERVER%%',   ''
$d = $d -replace '%%SAP_SYSNR%%',    ''
$d = $d -replace '%%SAP_CLIENT%%',   ''
$d = $d -replace '%%SAP_USER%%',     ''
$d = $d -replace '%%SAP_PASSWORD%%', ''
$d = $d -replace '%%SAP_LANGUAGE%%', ''
$d = $d -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$d = $d -replace '%%REQUEST_FILE%%', '{RUN_TEMP}\sap_checkfm_ddic_request.txt'
$d = $d -replace '%%RESULT_FILE%%',  '{RUN_TEMP}\sap_checkfm_ddic_result.tsv'
Set-Content '{RUN_TEMP}\sap_checkfm_ddic_helper.ps1' $d -Encoding UTF8
```

### 3c. Generate the filled VBScript

Write `{RUN_TEMP}\sap_checkfm_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_check_fm.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%SAP_SERVER%%',         'THE_SERVER'
$content = $content -replace '%%SAP_SYSNR%%',          'THE_SYSNR'
$content = $content -replace '%%SAP_CLIENT%%',         'THE_CLIENT'
$content = $content -replace '%%SAP_USER%%',           'THE_USER'
$content = $content -replace '%%SAP_PASSWORD%%',       'THE_PASSWORD'
$content = $content -replace '%%SAP_LANGUAGE%%',       'THE_LANGUAGE'
$content = $content -replace '%%ABAP_FILE%%',          'THE_ABAP_FILE'
$content = $content -replace '%%RESULT_FILE%%',        'THE_RESULT_FILE'
$content = $content -replace '%%FM_HELPER_PS1%%',      '{RUN_TEMP}\sap_checkfm_fm_helper.ps1'
$content = $content -replace '%%FM_NAMES_FILE%%',      '{RUN_TEMP}\sap_checkfm_fm_names.txt'
$content = $content -replace '%%FM_RESULT_FILE%%',     '{RUN_TEMP}\sap_checkfm_fm_result.tsv'
$content = $content -replace '%%DDIC_HELPER_PS1%%',    '{RUN_TEMP}\sap_checkfm_ddic_helper.ps1'
$content = $content -replace '%%DDIC_REQUEST_FILE%%',  '{RUN_TEMP}\sap_checkfm_ddic_request.txt'
$content = $content -replace '%%DDIC_RESULT_FILE%%',   '{RUN_TEMP}\sap_checkfm_ddic_result.tsv'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_checkfm_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>` / `<SAP_DEV_CORE_SHARED_DIR>` / `<FM_HELPER_TEMPLATE>` with absolute paths.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_checkfm_run.ps1"
```

### 3d. Execute the VBScript

Run via standard cscript (the helpers internally invoke 32-bit PowerShell):
```bash
cscript.exe //NoLogo {RUN_TEMP}\sap_checkfm_run.vbs
```

Show the full script output as it runs. Then read and display **RESULT_FILE** (`<abap-file>.check_fm.tsv`).

Delete the filled scripts (they contain plaintext credentials):
```bash
cmd /c del {RUN_TEMP}\sap_checkfm_run.vbs
cmd /c del {RUN_TEMP}\sap_checkfm_fm_helper.ps1
cmd /c del {RUN_TEMP}\sap_checkfm_ddic_helper.ps1
```

---

## Step 4 — Interpret and Report Results

Read **RESULT_FILE** (`<abap-file>.check_fm.tsv`). The result file has a status line followed by one tab-delimited entry per finding.

### Summary table — one row per CALL FUNCTION found:

| FM Name | Line | Issues |
|---|---|---|

### Per-FM detail — group findings under each CALL FUNCTION:

**Finding codes and their meaning:**

| Code | Meaning |
|---|---|
| `PARAM_NAME_OK` | Parameter name is valid and in the correct section |
| `UNKNOWN_PARAM` | Parameter name does not exist in the FM definition |
| `WRONG_SECTION` | Parameter exists in the FM but was placed under the wrong keyword |
| `MISSING_MANDATORY` | A mandatory FM parameter was not passed in the CALL |
| `TYPE_MATCH` | Passed variable type exactly matches the FM parameter type |
| `TYPE_COMPATIBLE` | Different type names but compatible (e.g. same DATATYPE and length) |
| `TYPE_WARNING` | Compatible but with risk — e.g. length mismatch may cause truncation |
| `TYPE_INCOMPATIBLE` | Types are not compatible |
| `TYPE_UNKNOWN` | Variable type could not be resolved from local declarations |
| `FM_NOT_FOUND` | FM does not exist in SAP or RFC call failed |
| `OBJECT_NAMING` | FM or function-group name does not match `sap_object_naming_rules.tsv` (Step 1.5) |

**On `STATUS: SUCCESS`** — all CALL FUNCTION statements are valid.

**On `STATUS: SUCCESS_WITH_ISSUES`** — show all issues grouped by CALL FUNCTION.

**On `STATUS: ERROR`:**

| Error message | Cause | Fix |
|---|---|---|
| `Cannot create SAP.Functions` | SAP GUI not installed or OCX not registered | Install SAP GUI; verify `wdtfuncs.ocx` in SAP GUI install dir |
| `RFC connection failed` | Wrong server/credentials | Verify server, SysNr, client, user, password |
| `ABAP file not found` | Wrong path | Verify the file path |
| `No CALL FUNCTION statements found` | Not an ABAP file or file is empty | Verify correct file was provided |
| `RPY_FUNCTIONMODULE_READ_NEW failed` | FM not in SAP or missing S_RFC auth | Check FM name; check S_RFC authorization |
| `DDIF_FIELDINFO_GET failed` | Type not in SAP or missing auth | Check type name; check S_RFC auth |

---

## Step 5 — Clean Up

```bash
cmd /c del {RUN_TEMP}\sap_checkfm_run.ps1
```

Keep **RESULT_FILE** (`<abap-file>.check_fm.tsv`) so the user can review it or pass it to `/sap-fix-fm`. To remove:
```bash
cmd /c del "THE_RESULT_FILE"
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_check_fm_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_check_fm_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `CHECK_FM_FAILED`, `RFC_LOGON_FAILED`.

---

## Security Note

The generated `.vbs` file contains the SAP password in plain text and is deleted automatically after execution.
Connection parameters are stored in sap-dev-core settings.json. The password field is marked as
`sensitive` and masked in the Claude Code UI.

---

## ABAP Parsing Limitations

- **Dynamic CALL FUNCTION** (`CALL FUNCTION fm_variable`) — silently skipped; FM name must be a quoted literal
- **`LIKE` clauses** in DATA declarations — variable type marked `TYPE_UNKNOWN`; manual check required
- **Global variables / constants / system fields** not declared in this source file — type marked `TYPE_UNKNOWN`
- **FM parameter on a separate line from CALL FUNCTION** — FM name must be on the same line as `CALL FUNCTION`

---

## SE37 Syntax Check Errors (from sap-se37 deployment)

This skill checks CALL FUNCTION parameter correctness, but **not** ABAP syntax. If the
user deployed a function module via sap-se37 and the deployment reported syntax errors,
those are different from this skill's findings.

### How to read SE37 syntax errors

When sap-se37 deploy fails with syntax errors, the output looks like:
```
ERROR: Syntax check found 1 error(s):
  Line 5: Function Module ZHKFM_TEST004
    -> The last statement is not complete (period missing).
```

The error grid has paired rows: the first row shows the line number and FM name, the
second row shows the error description.

### Common SE37 syntax errors and fixes

| Error | Cause | Fix |
|---|---|---|
| `Statement is not accessible` | Function group has inactive version, OR source file missing `FUNCTION <name>.` / `ENDFUNCTION.` wrapper | The sap-se37 templates activate before syntax check to resolve inactive versions. If it persists, check the upload file includes the full FUNCTION include — see sap-se37 SKILL.md Step 2 |
| `The last statement is not complete (period missing)` | Missing period at end of a statement | Add `.` at end of the offending line |
| `"X" is not defined` | Undeclared variable or typo | Add `DATA:` declaration or fix the name |
| `"X" is not a type` | Wrong TYPE in DATA declaration | Check SAP data element spelling |
| `Field "X" is unknown` | Wrong structure field name | Check field name against SE11 definition |

### Workflow for syntax errors

1. Fix the ABAP source file locally
2. Re-deploy via sap-se37 (which will re-run syntax check automatically)
3. If the error is a CALL FUNCTION parameter issue, run sap-check-fm for detailed validation
