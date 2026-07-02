---
name: sap-fix-fm
description: |
  Fixes ABAP CALL FUNCTION parameter issues found by sap-check-fm.
  Reads the sap-check-fm result file, reconnects to SAP to retrieve correct
  FM parameter definitions, then proposes and applies fixes:
  - UNKNOWN_PARAM: renames wrong parameter names to the correct FM parameter names
  - MISSING_MANDATORY: inserts stub lines for missing mandatory parameters
  - WRONG_SECTION: moves parameter assignments to the correct keyword section
  Creates a timestamped backup (.bak) before modifying the ABAP source file.
  Prerequisites: SAP NCo 3.1 (32-bit, .NET 4.0) installed in GAC. Run sap-check-fm first to produce the result file.
argument-hint: "<path-to-abap-source-file> [<path-to-result-file>]"
---

# SAP Fix FM Skill

You fix ABAP `CALL FUNCTION` parameter issues detected by sap-check-fm. You rename wrong parameters, add missing mandatory parameters, and move parameters placed in the wrong section. You always back up the file before making changes.

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

Start a structured log run. State file: `{RUN_TEMP}\sap_fix_fm_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_fix_fm_run.json" -Skill sap-fix-fm -ParamsJson "{\"abap_file\":\"<ABAP_FILE>\",\"result_tsv\":\"<TSV>\"}"
```

---

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:
- **ABAP source file path** — required. Ask if not provided.
- **Result file path** — optional; default is `<abap-file>.check_fm.tsv` (the per-input result `/sap-check-fm` writes next to the ABAP source — parallel-session safe, unlike the old shared fixed-name file under the temp base).

Verify both files exist:
```bash
powershell -Command "if (Test-Path 'ABAP_FILE') { 'OK' } else { 'NOT FOUND' }"
powershell -Command "if (Test-Path 'RESULT_FILE') { 'OK' } else { 'NOT FOUND' }"
```

If either file does not exist, tell the user and stop.

---

## Step 2 — Read and Parse the Result File

Read the result file and extract all fixable issues. The file is tab-delimited. Each CALL FUNCTION block starts with a `CALL_FUNCTION` line, followed by child lines (two leading spaces) for that block.

**Fixable issue codes:**

| Code | Tab-fields after code | Action |
|---|---|---|
| `UNKNOWN_PARAM` | FM \| LINE:n \| SECTION \| `PARAM_NAME not in FM definition` | Rename parameter |
| `MISSING_MANDATORY` | FM \| LINE:n \| SECTION \| PARAM_NAME | Add parameter stub |
| `WRONG_SECTION` | FM \| LINE:n \| PARAM_NAME \| `used:SECT defined-in:SECT` | Move to correct section |
| `FM_NOT_FOUND` | FM \| LINE:n \| message | Cannot fix — skip, note for user |

**Ignore:** `PARAM_NAME_OK`, `TYPE_MATCH`, `TYPE_COMPATIBLE`, `TYPE_WARNING`, `TYPE_INCOMPATIBLE`, `TYPE_UNKNOWN`, `OK`.

Build a list of unique FM names that have `UNKNOWN_PARAM`, `MISSING_MANDATORY`, or `WRONG_SECTION` issues.

If the list is empty, tell the user "No fixable issues found in result file." and stop.

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — offline fixer, but rule applies to downstream deploy skills the fixed source feeds |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | *(rule)* | ABAP code-quality rules — fixed CALL FUNCTION blocks must remain compatible with modern-ABAP conventions |
| `sap-dev-core/settings.json` | *(config)* | SAP connection parameters |

---

## Step 3 — Read SAP Connection Parameters

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

## Step 4 — Fetch FM Parameter Definitions

The lookup PowerShell template is `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_fm.ps1`
— the **shared** helper used by `sap-gen-abap`, `sap-check-fm`, and this skill.
Includes per-system disk caching, so signatures fetched by an earlier skill run
are reused without re-querying RFC.

Resolve cache directory + system ID (see "Step 0 — Resolve Work Directory"):
- `{FM_CACHE_DIR}` = `userConfig.fm_cache_dir`, or if blank: `{work_dir}\cache\fm_signatures`
- `{SYSTEM_ID}` = `{sap_application_server}_{sap_system_number}_{sap_client}` (e.g. `saphost.example.com_00_100`)

Build a one-name-per-line file of the unique FM names with fixable issues (from Step 2):

```powershell
'FM1','FM2','FM3' | Set-Content '{RUN_TEMP}\sap_getfmparams_names.txt' -Encoding UTF8
```

Then write `{RUN_TEMP}\sap_getfmparams_run.ps1`:
```powershell
$content = Get-Content '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_fm.ps1' -Raw
$content = $content -replace '%%SAP_SERVER%%',     ''
$content = $content -replace '%%SAP_SYSNR%%',      ''
$content = $content -replace '%%SAP_CLIENT%%',     ''
$content = $content -replace '%%SAP_USER%%',       ''
$content = $content -replace '%%SAP_PASSWORD%%',   ''
$content = $content -replace '%%SAP_LANGUAGE%%',   ''
$content = $content -replace '%%RFC_LIB_PS1%%',    '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$content = $content -replace '%%REQUEST_FILE%%',   '{RUN_TEMP}\sap_getfmparams_names.txt'
$content = $content -replace '%%RESULT_FILE%%',    '{RUN_TEMP}\getfmparams_result.txt'
$content = $content -replace '%%CACHE_DIR%%',      '{FM_CACHE_DIR}'
$content = $content -replace '%%SYSTEM_ID%%',      '{SYSTEM_ID}'
$content = $content -replace '%%TTL_STD_DAYS%%',   '30'      # or userConfig.fm_cache_ttl_std_days
$content = $content -replace '%%TTL_Z_DAYS%%',     '1'       # or userConfig.fm_cache_ttl_z_days
$content = $content -replace '%%REFRESH_CACHE%%',  'false'   # 'true' to bypass cache for this run
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_getfmparams_run.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SAP_DEV_CORE_SHARED_DIR>` with absolute paths.

Run:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_getfmparams_run.ps1"
```

Read `{RUN_TEMP}\getfmparams_result.txt`. Each line is:
```
FM_NAME<TAB>SECTION<TAB>PARAM_NAME<TAB>OPTIONAL<TAB>TYPE_REF<TAB>TYPE_KIND
```
Where:
- `OPTIONAL` = ` ` (mandatory) or `X` (optional)
- `TYPE_KIND` = `TAB` | `TDEF` | `TYP` | `""` (none / exception)
- Special `SECTION` values: `NOT_FOUND` (FM doesn't exist in target SAP), `UNAVAILABLE` (RFC was unreachable AND no prior cache)

Delete the filled-in PowerShell (contains credentials):
```bash
cmd /c del {RUN_TEMP}\sap_getfmparams_run.ps1
```

---

## Step 5 — Build Fix Plan

Using the issues from Step 2 and the FM param definitions from Step 4, build a fix plan grouped by CALL FUNCTION (FM name + line number).

### Fix type: RENAME (UNKNOWN_PARAM)

For each `UNKNOWN_PARAM` in a given FM + section:
1. Look for a `MISSING_MANDATORY` in the **same FM + same section** that is not already paired.
   - If found → propose **rename**: `OLD_PARAM → NEW_PARAM` (line N, section SECT).
2. If no MISSING_MANDATORY pairing → look in the FM definitions (from Step 4) for the closest actual parameter in that section using fuzzy/prefix matching (e.g. `CENTRALDATA2` → `CENTRALDATA`, `CENTRALDATAORG` → `CENTRALDATAORGANISATION`).
   - If a close match is found → propose rename with confidence note.
   - If ambiguous → list all actual params for that FM + section and ask the user which one the UNKNOWN_PARAM should be renamed to (or "remove").

### Fix type: ADD STUB (MISSING_MANDATORY)

For each `MISSING_MANDATORY` that was **not** already paired with an UNKNOWN_PARAM rename:
- Propose adding a new parameter line under the correct section keyword in the CALL FUNCTION block:
  ```
        NEW_PARAM   = space   " TODO: provide value
  ```
  (`space` — not `" "`: in ABAP the first `"` would start a comment, making
  the stub invalid syntax.)
  Note the TYPE_REF from the FM definition to help the user understand what value is needed.

### Fix type: MOVE (WRONG_SECTION)

For each `WRONG_SECTION`:
- Propose moving the parameter assignment line from its current section to the correct section.

### FM_NOT_FOUND

List these FMs separately with a note: "Cannot fix — FM does not exist in this SAP system."

### Present the plan

Show the complete fix plan as a numbered list, grouped by CALL FUNCTION block:

```
Fix plan for ABAP file: <path>
(backup will be created as <path>.<YYYYMMDD_HHMMSS>.bak)

[1] BAPI_BUPA_CREATE_FROM_DATA (LINE:200)
    RENAME  EXPORTING  CENTRALDATA2  →  CENTRALDATA
    RENAME  EXPORTING  CENTRALDATAORG  →  CENTRALDATAORGANISATION
    ADD     EXPORTING  ROLES  →  "TODO: tables param, type BAPIBUS1006_ROLES"

[2] ...

Skipped (FM not found): BAPI_BUPA_ROLES_ADD, BAPI_ADDRESS_SETDETAIL
```

---

## Step 6 — Confirm with User

Ask:
> "Apply this fix plan? (yes / no / select numbers to apply only specific fixes)"

- **yes** → proceed with all fixes
- **no** → stop
- **numbers** → apply only the listed fix numbers

---

## Step 7 — Backup the ABAP Source File

Create a timestamped backup before making any changes:
```bash
powershell -Command "Copy-Item 'THE_ABAP_FILE' 'THE_ABAP_FILE.<TIMESTAMP>.bak'"
```
Replace `<TIMESTAMP>` with the current date-time in `YYYYMMDD_HHmmss` format.

Confirm the backup was created successfully before proceeding.

---

## Step 8 — Apply Fixes

Read the ABAP source file. Apply each confirmed fix using the Edit tool.

### Applying RENAME

Find the line containing `OLD_PARAM_NAME   =` (or `OLD_PARAM_NAME=`) inside the target CALL FUNCTION block (starting at LINE:n, ending at the block terminator). Replace the parameter name:

Before:
```
      CENTRALDATA2       = ls_central
```
After:
```
      CENTRALDATA        = ls_central
```

### Applying ADD STUB

Locate the correct section keyword within the CALL FUNCTION block. Insert the new parameter line immediately after the section keyword, with consistent indentation matching the existing lines:

Before:
```
  CALL FUNCTION 'BAPI_BUPA_CREATE_FROM_DATA'
    EXPORTING
      PARTNERCATEGORY   = p_cat
```
After (if adding `CENTRALDATA`):
```
  CALL FUNCTION 'BAPI_BUPA_CREATE_FROM_DATA'
    EXPORTING
      PARTNERCATEGORY   = p_cat
      CENTRALDATA        = space   " TODO: ls_central (type BAPIBUS1006_CENTRAL)
```

If the section keyword does not yet exist in the block, add the section keyword and parameter line before the next section keyword or the closing `.`:

```
    EXPORTING
      CENTRALDATA        = space   " TODO: provide value (type BAPIBUS1006_CENTRAL)
```

### Applying MOVE (WRONG_SECTION)

Remove the parameter assignment line from its current section and insert it under the correct section. If the correct section keyword does not exist, add it.

---

## Step 9 — Summary

Report:
- Number of fixes applied (renames / stubs added / moved)
- Path of the backup file
- Any skipped fixes (FM_NOT_FOUND or user-excluded)
- Suggestion: run `/sap-check-fm <abap-file> [<logon-desc>]` again to verify the remaining issues.

---

## Step 10 — Clean Up

```bash
cmd /c del {RUN_TEMP}\getfmparams_result.txt
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_fix_fm_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_fix_fm_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `FIX_FM_FAILED`, `BACKUP_FAILED`, `RFC_LOGON_FAILED`.

---

## Security Note

The generated `.ps1` file contains the SAP password in plain text and is deleted automatically after execution.
Connection parameters are stored in sap-dev-core settings.json. The password field is marked as
`sensitive` and masked in the Claude Code UI.

---

## Fix Limitations

- **Dynamic CALL FUNCTION** — not parsed; cannot fix
- **PARAMETERS / global variables** flagged as `TYPE_UNKNOWN` — not fixable by this skill; type issues only
- **`FM_NOT_FOUND`** — cannot fix parameter names when the FM itself does not exist
- **Ambiguous renames** — when multiple FM params share a prefix, user confirmation is required before applying

---

## SE37 Syntax Errors (from sap-se37 deployment)

This skill fixes CALL FUNCTION **parameter** issues. If the user has SE37 **syntax
check** errors (from sap-se37 deployment), handle those differently:

### When sap-se37 reports syntax errors

The sap-se37 deployment output shows errors like:
```
ERROR: Syntax check found 1 error(s):
  Line 5: Function Module ZHKFM_TEST004
    -> The last statement is not complete (period missing).
```

### How to fix SE37 syntax errors

1. **Read the error output** — extract line number and error description
2. **Read the ABAP source file** around the error line
3. **Apply fix** based on error type:
   - `Statement is not accessible` → function group has inactive version (sap-se37 templates activate before syntax check to fix this), OR source file missing `FUNCTION <name>.` / `ENDFUNCTION.` wrapper (see sap-se37 SKILL.md Step 2)
   - `period missing` → add `.` to the incomplete statement
   - `"X" is not defined` → add `DATA:` declaration or fix typo
   - `"X" is not a type` → fix TYPE reference (check SE11)
   - `Field "X" is unknown` → fix structure field name (check SE11)
4. **Re-deploy via sap-se37** — it will re-run syntax check automatically

### FUNCTION/ENDFUNCTION wrapper requirement (critical)

SE37 source files **must** include the full function include:
```abap
FUNCTION ZHKFM_TEST001.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_INPUT) TYPE  STRING
*"----------------------------------------------------------------------
  " body code here
ENDFUNCTION.
```

If the source file only contains the body (no FUNCTION/ENDFUNCTION), ALL lines
will get `Statement is not accessible` errors. This differs from SE38 where the
upload file contains only the program body. Also, if the function group has
inactive versions, the same error appears for all lines — the sap-se37 templates
now activate before running syntax check to resolve this.
