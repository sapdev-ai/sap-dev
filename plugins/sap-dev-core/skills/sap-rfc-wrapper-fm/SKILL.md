---
name: sap-rfc-wrapper-fm
description: |
  Calls a non-RFC-enabled SAP function module via Z_GENERIC_RFC_WRAPPER_TBL.
  Reads the target FM's interface using RPY_FUNCTIONMODULE_READ_NEW, validates
  user-supplied parameter values, builds asXML payloads, invokes the wrapper FM
  via direct RFC, and returns the deserialized output parameters.
  Prerequisites: SAP profile saved via /sap-login (RFC password required).
  SAP NCo 3.1 (32-bit, .NET 4.0) in GAC.
  Z_GENERIC_RFC_WRAPPER_TBL must already exist in the SAP system (deploy via /sap-dev-init).
argument-hint: "<function-module-name> [param=value ...]"
---

# SAP RFC Wrapper — Function Module Skill

You call a non-RFC-enabled ABAP function module by routing the call through
`Z_GENERIC_RFC_WRAPPER_TBL`, which executes the target FM dynamically and
serializes all parameters as asXML.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — pure RFC skill, but rule applies to any downstream deploy skill |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | *(rule)* | ABAP code-quality rules — the wrapper FM signature interpretation must honor modern syntax, type safety, and code-quality conventions |
| `<SKILL_DIR>/references/sap_rfc_read_fm_params.ps1` | — | Reads FM interface via RPY_FUNCTIONMODULE_READ_NEW |
| `<SKILL_DIR>/references/sap_rfc_wrapper_fm.ps1` | — | Calls Z_GENERIC_RFC_WRAPPER_TBL with params file |

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve cross-plugin paths: 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\settings.json` and (if present) `sap-dev-core\settings.local.json`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_rfc_wrapper_fm_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_rfc_wrapper_fm_run.json" -Skill sap-rfc-wrapper-fm -ParamsJson "{\"function_module\":\"<FM>\"}"
```

---

## Step 1 — Collect Parameters

**From arguments** (`$ARGUMENTS`):
- First token = **target FM name** (required, UPPERCASE)
- Remaining tokens = optional `param=value` pairs for IMPORTING parameters

Read SAP connection settings from the merged sap-dev-core settings (per `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` — `settings.local.json` overrides `settings.json` per-key):

| Setting key | Fills token |
|---|---|
| `sap_application_server` | `%%SAP_SERVER%%` |
| `sap_system_number` | `%%SAP_SYSNR%%` |
| `sap_client` | `%%SAP_CLIENT%%` |
| `sap_user` | `%%SAP_USER%%` |
| `sap_password` | `%%SAP_PASSWORD%%` |
| `sap_language` | `%%SAP_LANGUAGE%%` |

If connection settings are missing, stop and ask the user to run `/sap-login` first.

---

## Step 2 — Read FM Interface

Fill `sap_rfc_read_fm_params.ps1` from the template and run it to retrieve the parameter interface.

Write `{WORK_TEMP}\sap_rfc_read_fm_params_run.ps1`:
```powershell
$ps = Get-Content '<SKILL_DIR>\references\sap_rfc_read_fm_params.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%SAP_SERVER%%',   'THE_SERVER'
$ps = $ps -replace '%%SAP_SYSNR%%',    'THE_SYSNR'
$ps = $ps -replace '%%SAP_CLIENT%%',   'THE_CLIENT'
$ps = $ps -replace '%%SAP_USER%%',     'THE_USER'
$ps = $ps -replace '%%SAP_PASSWORD%%', 'THE_PASSWORD'
$ps = $ps -replace '%%SAP_LANGUAGE%%', 'THE_LANGUAGE'
$ps = $ps -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$ps = $ps -replace '%%FM_NAME%%',      'THE_FM_NAME'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_rfc_read_fm_params_run.ps1', $ps, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Run:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_rfc_read_fm_params_run.ps1"
```

**Parse output** — each parameter appears as a pipe-delimited line:
```
PTYPE|PNAME|STRUCTURE|OPTIONAL
```
- `PTYPE`: `I`=Importing `E`=Exporting `C`=Changing `T`=Tables
- `PNAME`: parameter name
- `STRUCTURE`: DDIC type name → use as **PTYPENAME** in the call
  - For TABLE (`T`) parameters: STRUCTURE should be the table type (e.g. `ABAPTXT255_TAB`).
    If it looks like a structure name (e.g. `BAPI_RETURN`) rather than a table type, the actual
    table type is often `<STRUCTURE>_TAB` — confirm with the user before proceeding.
- `OPTIONAL`: `X`=optional, blank=mandatory
- Last line is `SUCCESS` or `ERROR:...`

If `ERROR:`, show full output and stop.

Present the interface table to the user:

```
FM Interface: <FM_NAME>
======================
Direction  Parameter          Type (PTYPENAME)          Optional
---------  -----------------  ------------------------  --------
IMPORTING  PARAM1             PROGNAME                  mandatory
EXPORTING  RESULT             BAPIRETURN                optional
TABLES     SOURCE_LINES       ABAPTXT255_TAB            optional
```

---

## Step 3 — Collect Parameter Values

For each **mandatory IMPORTING / CHANGING / TABLE** parameter, verify the user has provided a value.
For any missing required parameters, ask the user now.

For EXPORTING parameters, no input value is needed (they are output-only).

Explain to the user that:
- Simple scalars (CHAR, NUMC, INT, STRING): provide the value as plain text
- Structures: provide as `FIELD1=value1, FIELD2=value2` or as XML
- Tables: provide as a list of rows or as XML

---

## Step 4 — Build asXML and Write Params File

For each parameter, build the asXML string. All XML must be **on a single line** (no newlines).

### XML formats

**Scalar / simple type** (e.g. CHAR, NUMC, STRING, INT4):
```xml
<?xml version="1.0" encoding="utf-16"?><asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>VALUE_HERE</DATA></asx:values></asx:abap>
```

**Structure** (e.g. BAPIMATHEAD with fields MATERIAL, MATL_TYPE):
```xml
<?xml version="1.0" encoding="utf-16"?><asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA><MATERIAL>MAT001</MATERIAL><MATL_TYPE>FERT</MATL_TYPE></DATA></asx:values></asx:abap>
```

**Internal table** (e.g. BAPI_MAKT_TAB with rows):
```xml
<?xml version="1.0" encoding="utf-16"?><asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA><item><SPRAS>EN</SPRAS><MAKTX>Test Material</MAKTX></item><item><SPRAS>JA</SPRAS><MAKTX>テスト資材</MAKTX></item></DATA></asx:values></asx:abap>
```

**EXPORTING / output-only parameters**: leave PVALUE blank in the params file.

### Write params file

Write `{WORK_TEMP}\{FM_NAME}_params.txt` as UTF-16 LE using PowerShell:

```powershell
$lines = @()
$lines += "PNAME`tPTYPE`tPTYPENAME`tPVALUE"
$lines += "PARAM1`tI`tPROGNAME`t<?xml ...SCALAR_XML_HERE...>"
$lines += "SOURCE_LINES`tT`tABAPTXT255_TAB`t<?xml ...TABLE_XML_HERE...>"
$lines += "RESULT`tE`tBAPIRETURN`t"
$content = $lines -join "`r`n"
[System.IO.File]::WriteAllText('{WORK_TEMP}\{FM_NAME}_params.txt', $content, [System.Text.Encoding]::Unicode)
Write-Host 'Done'
```

Confirm the file was written correctly by reading back the first few lines.

---

## Step 5 — Call Z_GENERIC_RFC_WRAPPER_TBL

Fill `sap_rfc_wrapper_fm.ps1` from the template and run it.

Write `{WORK_TEMP}\sap_rfc_wrapper_fm_run.ps1`:
```powershell
$ps = Get-Content '<SKILL_DIR>\references\sap_rfc_wrapper_fm.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%SAP_SERVER%%',   'THE_SERVER'
$ps = $ps -replace '%%SAP_SYSNR%%',    'THE_SYSNR'
$ps = $ps -replace '%%SAP_CLIENT%%',   'THE_CLIENT'
$ps = $ps -replace '%%SAP_USER%%',     'THE_USER'
$ps = $ps -replace '%%SAP_PASSWORD%%', 'THE_PASSWORD'
$ps = $ps -replace '%%SAP_LANGUAGE%%', 'THE_LANGUAGE'
$ps = $ps -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$ps = $ps -replace '%%TARGET_FM%%',    'THE_FM_NAME'
$ps = $ps -replace '%%PARAMS_FILE%%',  '{WORK_TEMP}\{FM_NAME}_params.txt'
$ps = $ps -replace '%%WORK_TEMP%%',    '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_rfc_wrapper_fm_run.ps1', $ps, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Run:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_rfc_wrapper_fm_run.ps1"
```

**Parse output:**
- `SUCCESS:...` → call succeeded; proceed to Step 6
- `OUTPUT_FILE: <PNAME> [<PTYPE>] -> <PATH>` → one line per output parameter file written
- `ERROR:...` → call failed; show full output and diagnose using the table below

| Error | Cause | Fix |
|---|---|---|
| `SAP Logon failed` | Wrong credentials or server unreachable | Check sap-dev-core settings, run `/sap-login` |
| `Z_GENERIC_RFC_WRAPPER_TBL call failed` | Wrapper FM not deployed or FM_NOT_FOUND | Run `/sap-dev-init` to deploy the wrapper |
| `CT_PARAMS table not exposed` | Old `_DEEP` wrapper deployed (CHANGING ZCMCT_RFC_PARAM is invisible to NCo) | Re-run `/sap-dev-init` to deploy the new TABLES-based `_TBL` wrapper |
| `No parameters loaded` | Params file empty or wrong encoding | Check params file path and ensure UTF-16 LE encoding |
| `DESERIALIZATION_FAILED` | Bad XML for an input parameter | Fix the XML format (check field names and structure) |
| `DYNAMIC_CALL_FAILED` | Target FM raised an exception | The target FM signalled OTHERS — check FM prerequisites |
| `FM_NOT_FOUND` | Target FM does not exist | Verify FM name (UPPERCASE) |

---

## Step 6 — Display Output Parameters

For each output file reported in Step 5, read the XML and present the results to the user.

Read `{WORK_TEMP}\out_<PNAME>.xml` for each reported output parameter.

Parse the asXML to extract values:
- Scalar: value inside `<DATA>...</DATA>`
- Structure: child elements of `<DATA>`
- Table: `<item>` elements inside `<DATA>`

Present results in a readable format:
```
Result: <PNAME> [E/C/T]
=======================
FIELD1 : value1
FIELD2 : value2
...
```

For table parameters with many rows, show the first 20 rows and note the total count.

---

## Step 7 — Clean Up

```bash
cmd /c del {WORK_TEMP}\sap_rfc_read_fm_params_run.ps1 & del {WORK_TEMP}\sap_rfc_wrapper_fm_run.ps1 & del {WORK_TEMP}\{FM_NAME}_params.txt
```

Also delete `{WORK_TEMP}\out_*.xml` if the user confirms they no longer need the output files.

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_rfc_wrapper_fm_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_rfc_wrapper_fm_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `RFC_WRAPPER_FAILED`, `RFC_LOGON_FAILED`.

---

## Security Note

Generated `.ps1` files contain SAP credentials — delete after use (Step 7).

---

## Notes on PTYPENAME

`PTYPENAME` must be a valid ABAP Dictionary type that can be used in `CREATE DATA lo_data TYPE (<ptypename>)`.

| Parameter kind | What PTYPENAME should be | Example |
|---|---|---|
| Simple scalar (CHAR, INT4…) | The data element name | `PROGNAME`, `RS38L_FNAM` |
| Structure | The DDIC structure name | `BAPI_MARA`, `BAPIMATHEAD` |
| Internal table | The DDIC **table type** name | `ABAPTXT255_TAB`, `BAPIRET2_TAB` |
| String | `STRING` (predefined type) | `STRING` |

If `RPY_FUNCTIONMODULE_READ_NEW` returns a blank STRUCTURE for a parameter, use the
elementary type hint (e.g. `CHAR30`, `STRING`) or ask the user to check the FM definition in SE37.
