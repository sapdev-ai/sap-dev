---
name: sap-rfc-wrapper-class
description: |
  Generates an RFC wrapper function module for a non-RFC-callable ABAP class method.
  Reads the class method's parameter interface from SEOPARAM/SEOEXCEP via RFC_READ_TABLE,
  generates a deployable ABAP function module that internally calls the class method,
  and deploys it via /sap-se37.
  The generated FM name follows the pattern Z_CLSWRP_<CLASS>_<METHOD> (truncated to 30 chars).
  Prerequisites: SAP connection configured in sap-dev-core settings.
argument-hint: "<class-name> <method-name> [function-group] [package] [transport]"
---

# SAP RFC Wrapper — Class Method Skill

You generate and deploy an RFC wrapper function module that internally calls
an ABAP class method. This lets you invoke non-RFC-callable class methods
via the RFC protocol (e.g. using SAP NCo 3.1).

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SKILL_DIR>/references/sap_rfc_read_class_method.ps1` | Reads class method interface from SEOPARAM/SEOEXCEP |

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve cross-plugin paths: 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\settings.json` and (if present) `sap-dev-core\settings.local.json`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `sap_dev_function_group` | `ZZSAPDEVFMGAI` |
| `sap_dev_package` | *(blank = local $TMP)* |
| `sap_dev_transport_request` | *(blank = local $TMP)* |

Set `{WORK_TEMP}` = `{work_dir}\temp`

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_rfc_wrapper_class_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_rfc_wrapper_class_run.json" -Skill sap-rfc-wrapper-class -ParamsJson "{\"class\":\"<CLASS>\",\"method\":\"<METHOD>\"}"
```

---

## Step 1 — Collect Parameters

**From arguments** (`$ARGUMENTS`):

| Position | Parameter | Required | Example |
|---|---|---|---|
| 1 | Class name | Yes | `CL_MATERIAL_BASIC` |
| 2 | Method name | Yes | `GET_DESCRIPTION` |
| 3 | Function group | No (default: `sap_dev_function_group`) | `ZHKFG01` |
| 4 | Package | No (default: `sap_dev_package`) | `ZHKA001` |
| 5 | Transport | No (default: `sap_dev_transport_request`) | `S4DK940992` |

**Compute generated FM name:**
- Pattern: `Z_CLSWRP_<CLASS>_<METHOD>`
- Truncate the combined name to exactly 30 characters
- Convert to UPPERCASE
- Example: `CL_MATERIAL_BASIC` + `GET_DESCRIPTION` → `Z_CLSWRP_CL_MATERIAL_BGET_D` (30 chars)

Read SAP connection settings from the merged sap-dev-core settings (per `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` — `settings.local.json` overrides `settings.json` per-key):

| Setting key | Fills token |
|---|---|
| `sap_application_server` | `%%SAP_SERVER%%` |
| `sap_system_number` | `%%SAP_SYSNR%%` |
| `sap_client` | `%%SAP_CLIENT%%` |
| `sap_user` | `%%SAP_USER%%` |
| `sap_password` | `%%SAP_PASSWORD%%` |
| `sap_language` | `%%SAP_LANGUAGE%%` |

---

## Step 2 — Read Class Method Interface

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

Write `{WORK_TEMP}\sap_rfc_read_cls_run.ps1`:
```powershell
$ps = Get-Content '<SKILL_DIR>\references\sap_rfc_read_class_method.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%SAP_SERVER%%',   'THE_SERVER'
$ps = $ps -replace '%%SAP_SYSNR%%',    'THE_SYSNR'
$ps = $ps -replace '%%SAP_CLIENT%%',   'THE_CLIENT'
$ps = $ps -replace '%%SAP_USER%%',     'THE_USER'
$ps = $ps -replace '%%SAP_PASSWORD%%', 'THE_PASSWORD'
$ps = $ps -replace '%%SAP_LANGUAGE%%', 'THE_LANGUAGE'
$ps = $ps -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$ps = $ps -replace '%%CLASS_NAME%%',   'THE_CLASS_NAME'
$ps = $ps -replace '%%METHOD_NAME%%',  'THE_METHOD_NAME'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_rfc_read_cls_run.ps1', $ps, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Run:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_rfc_read_cls_run.ps1"
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

Method-type indicator (also emitted by the read script):
```
MTDTYPE|<n>
```
where `<n>` is from SEOCOMPO.MTDTYPE: `0`=instance method, `1`=static method,
`2`=event handler. The wrapper generator MUST emit `<CLASS>=><METHOD>(...)`
syntax for static methods (no `CREATE OBJECT`) and `lo_obj-><METHOD>(...)` for
instance methods (preceded by `CREATE OBJECT lo_obj`).

Exceptions appear as: `EXCEPT|<EXCEPTION_NAME>`

**REJECT class-reference returns:** if any parameter has TYPNAME starting with
`REF TO ` or the SEOPARAM TYPTYPE column equals `1` (class ref) or `2`
(interface ref), STOP and report to the user:
> "Method `<CLASS>=><METHOD>` returns/uses an object reference (`<param> TYPE REF TO <X>`).
> Object references cannot be marshaled via RFC + asXML serialization. Pick a
> method whose parameters are all scalar/structured DDIC types, or write a custom
> wrapper that extracts only the relevant scalar attributes from the returned object."

If `ERROR:`, show full output and stop.

Present the interface to the user:
```
Class: <CLASS_NAME> — Method: <METHOD_NAME>
============================================
Direction   Parameter       Type                 Optional
----------  --------------  -------------------  --------
Importing   IM_MATNR        MATNR                mandatory
Exporting   EX_MAKTX        MAKTX                optional
```

---

## Step 3 — Generate Wrapper FM ABAP Source

Generate the wrapper function module ABAP source code.

### FM source template

The generated source must be a complete function include. Use this structure:

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

---

## Step 4 — Deploy via sap-se37

Run:
```
/sap-se37 <GENERATED_FM_NAME> {WORK_TEMP}\<GENERATED_FM_NAME>.abap
```

Pass:
- Function group: the function group from Step 1 (or `sap_dev_function_group`)
- Short text: `RFC wrapper for <CLASS_NAME>-><METHOD_NAME>` (max 70 chars)
- Package: from Step 1 (or `sap_dev_package`)
- Transport: from Step 1 (or `sap_dev_transport_request`)

If sap-se37 reports success, the wrapper FM is live.

---

## Step 5 — Summary

Report:
```
RFC Wrapper Generated and Deployed
===================================
Class    : <CLASS_NAME>
Method   : <METHOD_NAME>
FM Name  : <GENERATED_FM_NAME>
Group    : <FUNCTION_GROUP>
Package  : <PACKAGE>

To call this FM via /sap-rfc-wrapper-fm:
  /sap-rfc-wrapper-fm <GENERATED_FM_NAME> [param=value ...]
```

---

## Step 6 — Clean Up

```bash
cmd /c del {WORK_TEMP}\sap_rfc_read_cls_run.ps1
```

The generated `.abap` file is kept (it is the source of record for the FM).

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_rfc_wrapper_class_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_rfc_wrapper_class_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `RFC_WRAPPER_FAILED`, `SE37_FAILED`, `RFC_LOGON_FAILED`.

---

## Troubleshooting

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
