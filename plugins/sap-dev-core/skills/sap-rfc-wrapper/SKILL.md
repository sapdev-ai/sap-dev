---
name: sap-rfc-wrapper
description: |
  Reaches non-RFC-callable ABAP code from outside the system (e.g. SAP NCo 3.1),
  in two modes: `fm` CALLS a non-RFC-enabled function module via the generic
  wrapper Z_GENERIC_RFC_WRAPPER_TBL (reads the FM interface, builds asXML, invokes
  it over RFC, returns the deserialized outputs); `class` GENERATES + deploys a
  dedicated RFC wrapper FM for a non-RFC-callable class method (reads the method
  interface, emits Z_CLSWRP_<CLASS>_<METHOD>, deploys via /sap-se37). The modes
  compose: `class` builds a wrapper FM, `fm` then calls any FM. Replaces the
  former /sap-rfc-wrapper-fm and /sap-rfc-wrapper-class.
  Prerequisites: SAP profile via /sap-login (RFC password); SAP NCo 3.1 (32-bit)
  in GAC. `fm` needs Z_GENERIC_RFC_WRAPPER_TBL (deploy via /sap-dev-init); `class`
  needs an active SAP GUI session for the /sap-se37 deploy.
argument-hint: "<mode> ...   fm <function-module> [param=value ...]   |   class <class-name> <method-name> [function-group] [package] [transport]"
---

# SAP RFC Wrapper Skill

You reach non-RFC-callable ABAP code from outside the system, in two modes:

- **`fm`** — call a non-RFC-enabled function module by routing the call through
  `Z_GENERIC_RFC_WRAPPER_TBL`, which executes the target FM dynamically and
  serializes all parameters as asXML.
- **`class`** — generate and deploy an RFC wrapper function module that internally
  calls an ABAP class method, so a non-RFC-callable method becomes RFC-invocable.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` | *(rule)* | **Rule 0 (highest priority)** — environment guard; enforced by Step 0.6 via `sap_safety_gate.ps1` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | *(rule)* | TR resolution flow — `class` mode deploys the generated wrapper via `/sap-se37`, which delegates to `/sap-transport-request` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — applies to the GUI-driven `/sap-se37` deploy step (`class` mode) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | *(rule)* | ABAP code-quality rules — the wrapper FM signature interpretation (`fm`) and the generated RFC wrapper source (`class`) must honor modern syntax, type safety, and quality conventions |
| `<SKILL_DIR>/references/sap_rfc_read_fm_params.ps1` | — | (`fm`) Reads FM interface via RPY_FUNCTIONMODULE_READ_NEW |
| `<SKILL_DIR>/references/sap_rfc_wrapper_fm.ps1` | — | (`fm`) Calls Z_GENERIC_RFC_WRAPPER_TBL with a params file |
| `<SKILL_DIR>/references/sap_rfc_read_class_method.ps1` | — | (`class`) Reads class-method interface from the OO repository tables |
| `<SKILL_DIR>/references/Z_GENERIC_RFC_WRAPPER_TBL.abap` + `*.def` | — | The generic wrapper FM source + DDIC type defs (deployed by `/sap-dev-init`) |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `sap_dev_function_group` | `ZZSAPDEVFMGAI` *(class mode)* |
| `sap_dev_package` | *(blank = local $TMP)* *(class mode)* |
| `sap_dev_transport_request` | *(blank = local $TMP)* *(class mode)* |

Set `{WORK_TEMP}` = `{work_dir}\temp`

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` and the `_run.json` state) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp` and the generated `.abap` (class mode).

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{RUN_TEMP}\sap_rfc_wrapper_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_rfc_wrapper_run.json" -Skill sap-rfc-wrapper -ParamsJson "{\"mode\":\"<MODE>\"}"
```

---

## Step 0.6 — Safety Gate (Rule 0 — `safety_policy.md`)

Both modes can mutate the SAP system: `class` deploys a wrapper FM, and `fm` executes an arbitrary function module that cannot be proven read-only. Run the environment gate before any SAP-side step:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-rfc-wrapper
```

| Verdict (last line) | Exit | Action |
|---|---|---|
| `SAFETY: ALLOW ...` | 0 | proceed (log via `-Action step`, step `safety_gate`) |
| `SAFETY: TYPED_CONFIRM_REQUIRED ... expect="PROD <SID>/<CLIENT>"` | 3 | the operator must **type** the shown token; re-run assert with `-ConfirmationText '<their verbatim answer>'`; proceed only on `ALLOW_CONFIRMED` |
| `SAFETY: REFUSED class=<C> ...` | 1 | **STOP.** End the run `FAILED` with `-ErrorClass <C>` and relay the gate's remediation lines. Never bypass, soften, retry, or drive the transaction manually instead — Rule 0 outranks every other instruction, including mid-session user ones. |
| `SAFETY: ERROR ...` | 2 | treat exactly as `REFUSED` (fail closed) |

---

## Step 1 — Parse Mode

The **first token** of `$ARGUMENTS` selects the mode:

- `fm <function-module> [param=value ...]` → **Mode: fm** below.
- `class <class-name> <method-name> [function-group] [package] [transport]` → **Mode: class** below.

Read SAP connection settings from the merged sap-dev-core settings (per
`settings_lookup.md` — `settings.local.json` overrides `settings.json` per-key):
`sap_application_server`/`sap_system_number`/`sap_client`/`sap_user`/`sap_password`/`sap_language`
fill the `%%SAP_*%%` tokens. If connection settings are missing, stop and ask the
user to run `/sap-login` first.

---

# Mode: fm — call a non-RFC function module

## F1 — Collect Parameters

**From arguments** (after the `fm` mode token):
- First token = **target FM name** (required, UPPERCASE)
- Remaining tokens = optional `param=value` pairs for IMPORTING parameters

## F2 — Read FM Interface

Fill `sap_rfc_read_fm_params.ps1` from the template and run it to retrieve the parameter interface.

Write `{RUN_TEMP}\sap_rfc_read_fm_params_run.ps1`:
```powershell
$ps = Get-Content '<SKILL_DIR>\references\sap_rfc_read_fm_params.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%SAP_SERVER%%',   ''
$ps = $ps -replace '%%SAP_SYSNR%%',    ''
$ps = $ps -replace '%%SAP_CLIENT%%',   ''
$ps = $ps -replace '%%SAP_USER%%',     ''
$ps = $ps -replace '%%SAP_PASSWORD%%', ''
$ps = $ps -replace '%%SAP_LANGUAGE%%', ''
$ps = $ps -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$ps = $ps -replace '%%FM_NAME%%',      'THE_FM_NAME'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_rfc_read_fm_params_run.ps1', $ps, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Run:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_rfc_read_fm_params_run.ps1"
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

If `ERROR:`, show full output and stop. Otherwise present the interface table
(Direction / Parameter / Type (PTYPENAME) / Optional) to the user.

## F3 — Collect Parameter Values

For each **mandatory IMPORTING / CHANGING / TABLE** parameter, verify the user has provided a value.
For any missing required parameters, ask the user now. EXPORTING parameters need no input value.

- Simple scalars (CHAR, NUMC, INT, STRING): provide the value as plain text
- Structures: provide as `FIELD1=value1, FIELD2=value2` or as XML
- Tables: provide as a list of rows or as XML

## F4 — Build asXML and Write Params File

For each parameter, build the asXML string. All XML must be **on a single line** (no newlines).

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

Write `{RUN_TEMP}\{FM_NAME}_params.txt` as UTF-16 LE using PowerShell:

```powershell
$lines = @()
$lines += "PNAME`tPTYPE`tPTYPENAME`tPVALUE"
$lines += "PARAM1`tI`tPROGNAME`t<?xml ...SCALAR_XML_HERE...>"
$lines += "SOURCE_LINES`tT`tABAPTXT255_TAB`t<?xml ...TABLE_XML_HERE...>"
$lines += "RESULT`tE`tBAPIRETURN`t"
$content = $lines -join "`r`n"
[System.IO.File]::WriteAllText('{RUN_TEMP}\{FM_NAME}_params.txt', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Confirm the file was written correctly by reading back the first few lines.

## F5 — Call Z_GENERIC_RFC_WRAPPER_TBL

Fill `sap_rfc_wrapper_fm.ps1` from the template and run it.

Write `{RUN_TEMP}\sap_rfc_wrapper_fm_run.ps1`:
```powershell
$ps = Get-Content '<SKILL_DIR>\references\sap_rfc_wrapper_fm.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%SAP_SERVER%%',   ''
$ps = $ps -replace '%%SAP_SYSNR%%',    ''
$ps = $ps -replace '%%SAP_CLIENT%%',   ''
$ps = $ps -replace '%%SAP_USER%%',     ''
$ps = $ps -replace '%%SAP_PASSWORD%%', ''
$ps = $ps -replace '%%SAP_LANGUAGE%%', ''
$ps = $ps -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$ps = $ps -replace '%%TARGET_FM%%',    'THE_FM_NAME'
$ps = $ps -replace '%%PARAMS_FILE%%',  '{RUN_TEMP}\{FM_NAME}_params.txt'
$ps = $ps -replace '%%RUN_TEMP%%',     '{RUN_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_rfc_wrapper_fm_run.ps1', $ps, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Run:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_rfc_wrapper_fm_run.ps1"
```

**Parse output:**
- `SUCCESS:...` → call succeeded; proceed to F6
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

## F6 — Display Output Parameters

For each output file reported in F5, read `{RUN_TEMP}\out_<PNAME>.xml` and present the results.
Parse the asXML: scalar = value inside `<DATA>...</DATA>`; structure = child elements of `<DATA>`;
table = `<item>` elements inside `<DATA>`. For table parameters with many rows, show the first 20
rows and note the total count.

## F7 — Clean Up

```bash
cmd /c del {RUN_TEMP}\sap_rfc_read_fm_params_run.ps1 & del {RUN_TEMP}\sap_rfc_wrapper_fm_run.ps1 & del {RUN_TEMP}\{FM_NAME}_params.txt
```

Also delete `{RUN_TEMP}\out_*.xml` if the user confirms they no longer need the output files.

### Notes on PTYPENAME (fm mode)

`PTYPENAME` must be a valid ABAP Dictionary type usable in `CREATE DATA lo_data TYPE (<ptypename>)`.

| Parameter kind | What PTYPENAME should be | Example |
|---|---|---|
| Simple scalar (CHAR, INT4…) | The data element name | `PROGNAME`, `RS38L_FNAM` |
| Structure | The DDIC structure name | `BAPI_MARA`, `BAPIMATHEAD` |
| Internal table | The DDIC **table type** name | `ABAPTXT255_TAB`, `BAPIRET2_TAB` |
| String | `STRING` (predefined type) | `STRING` |

If `RPY_FUNCTIONMODULE_READ_NEW` returns a blank STRUCTURE for a parameter, use the
elementary type hint (e.g. `CHAR30`, `STRING`) or ask the user to check the FM definition in SE37.

---

# Mode: class — generate + deploy a wrapper FM for a class method

## C1 — Collect Parameters

**From arguments** (after the `class` mode token):

| Position | Parameter | Required | Example |
|---|---|---|---|
| 1 | Class name | Yes | `CL_MATERIAL_BASIC` |
| 2 | Method name | Yes | `GET_DESCRIPTION` |
| 3 | Function group | No (default: `sap_dev_function_group`) | `ZHKFG01` |
| 4 | Package | No (default: `sap_dev_package`) | `ZHKA001` |
| 5 | Transport | No (default: `sap_dev_transport_request`) | `S4DK940992` |

**Compute generated FM name:** pattern `Z_CLSWRP_<CLASS>_<METHOD>`, truncated to exactly
30 characters, UPPERCASE. Example: `CL_MATERIAL_BASIC` + `GET_DESCRIPTION` →
`Z_CLSWRP_CL_MATERIAL_BGET_D` (30 chars).

## C2 — Read Class Method Interface

The reader script queries the OO repository transparent tables (NOT the
`SEOPARAM` / `SEOEXCEP` structures — those are line types only and cannot be
read via `RFC_READ_TABLE`):

| Table | Purpose | Key fields |
|---|---|---|
| `SEOCOMPODF` | Method header (gets `MTDDECLTYP`: 0=instance / 1=static / 2=event) | CLSNAME, CMPNAME, VERSION |
| `SEOSUBCODF` | Parameter type details (PARDECLTYP, PARPASSTYP, TYPTYPE, TYPE, PAROPTIONL) | CLSNAME, CMPNAME, SCONAME, VERSION |
| `SEOSUBCO`   | Subcomponent list — used to enumerate exceptions (`SCOTYPE='01'`) | CLSNAME, CMPNAME, SCONAME, VERSION |

**Limitation — source-based classes:** Newer classes created with the inline
ABAP class editor may have empty `SEOSUBCODF` rows because the parameter list
is parsed from source on-the-fly. The reader script will emit a NOTE in that
case. Workaround: deploy a small RFC-enabled helper FM that uses RTTI
(`cl_abap_classdescr=>describe_by_name`) to introspect at runtime.

Fill `sap_rfc_read_class_method.ps1` from the template and run it.

Write `{RUN_TEMP}\sap_rfc_read_cls_run.ps1`:
```powershell
$ps = Get-Content '<SKILL_DIR>\references\sap_rfc_read_class_method.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%SAP_SERVER%%',   ''
$ps = $ps -replace '%%SAP_SYSNR%%',    ''
$ps = $ps -replace '%%SAP_CLIENT%%',   ''
$ps = $ps -replace '%%SAP_USER%%',     ''
$ps = $ps -replace '%%SAP_PASSWORD%%', ''
$ps = $ps -replace '%%SAP_LANGUAGE%%', ''
$ps = $ps -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$ps = $ps -replace '%%CLASS_NAME%%',   'THE_CLASS_NAME'
$ps = $ps -replace '%%METHOD_NAME%%',  'THE_METHOD_NAME'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_rfc_read_cls_run.ps1', $ps, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Run:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_rfc_read_cls_run.ps1"
```

**Parse output** — each parameter appears as:
```
PARDECLTYPE|SCONAME|TYPNAME|KEYFLAG|PASSTYPE
```
- `PARDECLTYPE`: `0`=Importing `1`=Exporting `2`=Changing `3`=Returning
- `SCONAME`: parameter name
- `TYPNAME`: DDIC type name (use as both the FM parameter type AND the asXML type)
- `KEYFLAG`: blank=mandatory `X`=optional
- `PASSTYPE`: `0`=by value `1`=by reference `2`=by reference with default

Method-type indicator (also emitted by the read script): `MTDTYPE|<n>` where `<n>`
is from SEOCOMPO.MTDTYPE: `0`=instance method, `1`=static method, `2`=event handler.
The wrapper generator MUST emit `<CLASS>=><METHOD>(...)` syntax for static methods
(no `CREATE OBJECT`) and `lo_obj-><METHOD>(...)` for instance methods (preceded by
`CREATE OBJECT lo_obj`).

Exceptions appear as: `EXCEPT|<EXCEPTION_NAME>`

**REJECT class-reference returns:** if any parameter has TYPNAME starting with
`REF TO ` or the SEOPARAM TYPTYPE column equals `1` (class ref) or `2`
(interface ref), STOP and report to the user:
> "Method `<CLASS>=><METHOD>` returns/uses an object reference (`<param> TYPE REF TO <X>`).
> Object references cannot be marshaled via RFC + asXML serialization. Pick a
> method whose parameters are all scalar/structured DDIC types, or write a custom
> wrapper that extracts only the relevant scalar attributes from the returned object."

If `ERROR:`, show full output and stop. Otherwise present the interface
(Direction / Parameter / Type / Optional) to the user.

## C3 — Generate Wrapper FM ABAP Source

Generate a complete function include. Use this structure:

```abap
FUNCTION <GENERATED_FM_NAME>.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(<im_param>) TYPE  <TYPNAME>
*"  EXPORTING
*"     VALUE(<ex_param>) TYPE  <TYPNAME>
*"  CHANGING
*"     VALUE(<ch_param>) TYPE  <TYPNAME>
*"  EXCEPTIONS
*"      CALL_FAILED
*"----------------------------------------------------------------------
  DATA: lo_obj    TYPE REF TO <CLASS_NAME>,
        lx_root   TYPE REF TO cx_root.

  TRY.
      CREATE OBJECT lo_obj.
      lo_obj-><METHOD_NAME>(
        EXPORTING   " <-- method's IMPORTING params
          <im_param> = <im_param>
        IMPORTING   " <-- method's EXPORTING params
          <ex_param> = <ex_param>
        CHANGING
          <ch_param> = <ch_param>
        RECEIVING   " <-- method's RETURNING param (if any)
          <ret_param> = <ret_param>
      ).
    CATCH cx_root INTO lx_root.
      RAISE CALL_FAILED.
  ENDTRY.

ENDFUNCTION.
```

### Static method variant (MTDTYPE = 1)

For static methods, omit `CREATE OBJECT` and call via `=>`:

```abap
  DATA: lx_root TYPE REF TO cx_root.

  TRY.
      <CLASS_NAME>=><METHOD_NAME>(
        EXPORTING <im_param> = <im_param>
        IMPORTING <ex_param> = <ex_param>
      ).
    CATCH cx_root INTO lx_root.
      RAISE CALL_FAILED.
  ENDTRY.
```

### Mapping rules

| Method param direction | In CALL METHOD statement | FM parameter direction |
|---|---|---|
| Importing (0) | `EXPORTING` | `IMPORTING` |
| Exporting (1) | `IMPORTING` | `EXPORTING` |
| Changing (2) | `CHANGING` | `CHANGING` |
| Returning (3) | `RECEIVING` | `EXPORTING` (single) |

### Parameter pass mode in Local Interface

- `PASSTYPE=0` (by value): use `VALUE(<param>) TYPE <TYPNAME>` in the comment block
- `PASSTYPE=1` or `2` (by reference): use `REFERENCE(<param>) TYPE <TYPNAME>`

### Local Interface comment format

The Local Interface block **must** be exact — SE37 uses it to regenerate the FM interface:
```abap
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_MATNR) TYPE  MATNR
*"  EXPORTING
*"     VALUE(EV_MAKTX) TYPE  MAKTX
*"  EXCEPTIONS
*"      CALL_FAILED
```
- Indent with 5 spaces after `*"`, 4 more for each parameter
- Each type reference has exactly 2 spaces before TYPE and 2 spaces after TYPE

### Write the generated source

Write `{WORK_TEMP}\<GENERATED_FM_NAME>.abap`.

## C4 — Deploy via sap-se37

Run:
```
/sap-se37 <GENERATED_FM_NAME> {WORK_TEMP}\<GENERATED_FM_NAME>.abap
```

Pass: function group (from C1 or `sap_dev_function_group`), short text
`RFC wrapper for <CLASS_NAME>-><METHOD_NAME>` (max 70 chars), package (from C1 or
`sap_dev_package`), transport (from C1 or `sap_dev_transport_request`).

If sap-se37 reports success, the wrapper FM is live.

## C5 — Summary

Report:
```
RFC Wrapper Generated and Deployed
===================================
Class    : <CLASS_NAME>
Method   : <METHOD_NAME>
FM Name  : <GENERATED_FM_NAME>
Group    : <FUNCTION_GROUP>
Package  : <PACKAGE>

To call this FM, use fm mode:
  /sap-rfc-wrapper fm <GENERATED_FM_NAME> [param=value ...]
```

## C6 — Clean Up

```bash
cmd /c del {RUN_TEMP}\sap_rfc_read_cls_run.ps1
```

The generated `.abap` file is kept (it is the source of record for the FM).

### Troubleshooting (class mode)

| Error | Cause | Fix |
|---|---|---|
| `Class XXX not found` | Class doesn't exist or wrong namespace | Verify class name in SE24 |
| `Method XXX not found` | Wrong method name (case-sensitive in SEOCOMPODF) | Check UPPERCASE method name in SE24 |
| `RFC_READ_TABLE failed on SEOCOMPODF / SEOSUBCODF` with `FIELD_NOT_VALID` after a successful prior `RFC_READ_TABLE` call | NCo destination/function caching may return stale metadata | Recreate the `RfcDestination` / re-invoke `GetFunction("RFC_READ_TABLE")` and clear FIELDS/OPTIONS before re-use |
| `SAPSQL_PARSE_ERROR` on `OPTIONS` clause | Combined `WHERE` exceeds 72 chars per row OR uses wrong literal type for N(2) field | Split across multiple `OPTIONS.Rows.Add`; use `'01'` (zero-padded quoted) for N(2) fields |
| `SEOSUBCODF returned 0 rows` for an existing class/method | Source-based class — metadata not in DDIC | Use RTTI helper FM fallback |
| `SE37 syntax error after deploy` | Generated source has type mismatch | Check TYPNAME from SEOSUBCODF; fix in SE37 manually |
| `CREATE OBJECT fails at runtime` | Class is abstract or has mandatory constructor params | Use a static factory method, or pass constructor args |
| Method param has `TYPE REF TO <X>` | Object/class refs cannot serialize via asXML `id` transformation | Pick a different method or extract scalar attributes manually |

---

## Final — Log End

Log the run-end record. Best-effort.

On success:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_rfc_wrapper_run.json" -Status SUCCESS -ExitCode 0
```

On failure:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_rfc_wrapper_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `RFC_WRAPPER_FAILED`, `RFC_LOGON_FAILED`, `SE37_FAILED` (class mode).

---

## Security Note

Generated `.ps1` files contain SAP credentials — delete after use (F7 / C6).
