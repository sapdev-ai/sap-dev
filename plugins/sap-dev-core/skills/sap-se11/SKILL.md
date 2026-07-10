---
name: sap-se11
description: |
  Creates and updates ABAP Dictionary objects in SAP via SE11 using SAP GUI Scripting.
  Supports all 9 DDIC object types: Database table, View, Data element, Structure,
  Table type, Type group, Domain, Search help, and Lock object. Uses tab-delimited
  definition files for structured input. Existence check, create or
  update, save, and activation.
  Also supports delete mode: when the user asks to delete a DDIC object
  (e.g. "delete table ZTABLE", "drop structure ZSTRUCT", "remove domain
  ZDOM"), routes by object type to the correct SE11 radio + name field,
  presses Shift+F2 from the initial screen, confirms via btnSPOP-OPTION1
  (Yes), handles dependent-object and post-delete TR popups, and
  verifies removal. Deletion is irreversible — the skill asks for
  explicit confirmation before running the VBS. For database tables,
  SE14 is the canonical drop path; this skill flags the SE14 fallback
  if the SE11 delete leaves the table in place.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<object-type> <object-name> [definition-file]"
---

# SAP SE11 ABAP Dictionary Skill

You create and update ABAP Dictionary objects in a live SAP system via SE11 using SAP GUI Scripting.
The skill checks if the object exists, then creates or updates it with full lifecycle
(define → check → save → activate).

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` (Step 1b) instead of asking for the TR itself |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/ddic_excel_layout_rules.md` | DDIC Excel-spec authoring rules — when the spec was extracted via `/sap-docs-extract`, check naming-suffix consistency, primitive-type-as-DTEL trap, currency reference, column order before deploying. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — informs DDIC choices that affect ABAP source quality downstream (data-element vs. primitive type, currency reference, length consistency); also applies when the user supplies hand-written DDIC ABAP code (search helps with exit FMs, lock-object Z modules). |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/sap_gui_security_handling.md` | SAP GUI Security dialog handling — the **activation-log "Save Local File"** path (`CaptureActivationLog`, fired on an activation error during create/update) is SAP-GUI-side file IO, so it can raise the modal "SAP GUI Security" dialog (which suspends the Scripting API and hangs cscript). The create/update Execute steps run the OS-level watcher around the cscript so the dialog is auto-dismissed if the activation-log save trips it. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_precheck.ps1` | Read-only allow-list pre-check (`saprules.xml`) — `ALLOWED` (exit 0) / `NOT_COVERED` (exit 1). Used by the create/update Execute steps for the activation-log path. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_sidecar.ps1` | OS-level (Win32) watcher that auto-dismisses the SAP GUI Security dialog (ticks Remember + clicks Allow). Launched as a background process before the create/update cscript, since the activation-log save fires conditionally on an activation error. |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the `RUN_TEMP=` value printed above — a fresh per-run scratch
directory `{work_dir}\temp\run_<id>`, already created by `Get-SapRunTemp`.
Resolve it **once here** and reuse the same value for the rest of this
invocation; it isolates this run's generated wrappers / state / scratch files so
concurrent runs (parallel sub-agents, multi-connection deploys) never collide.
**`{WORK_TEMP}` stays the base temp dir** and is used ONLY for
`Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'` (the session-attach plumbing
derives `{work_dir}\runtime` from its parent, so it must see the base path, not
the run dir). Everything the skill writes itself goes under `{RUN_TEMP}`.

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{RUN_TEMP}\sap_se11_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_se11_run.json" -Skill sap-se11 -ParamsJson "{\"object_type\":\"<TYPE>\",\"object_name\":\"<NAME>\"}"
```

---

## Step 1 — Collect Parameters

**Object Details**

| Parameter | Description | Example |
|---|---|---|
| Object type | One of: `TABLE`, `VIEW`, `DATAELEMENT`, `STRUCTURE`, `TABLETYPE`, `TYPEGROUP`, `DOMAIN`, `SEARCHHELP`, `LOCKOBJECT` | `TABLE` |
| Object name | DDIC object name (Z/Y namespace) | `ZTMYDATA` |
| Object description | Short description (only for new objects) | `Custom data table` |
| Definition source | Tab-delimited definition file path, OR paste the definition directly | |
| Package | SAP package for transport (optional; blank = local object $TMP) | `ZHKA001` |
| Transport | Transport request number (optional; resolved by `/sap-transport-request` per `way_to_get_transport_request` if not supplied) | `S4DK940992` |

**Type-specific parameters (only for certain types):**

| Type | Extra Parameters |
|---|---|
| TABLE | Delivery class (`A`/`C`/`L`/`G`/`E`/`S`/`W`), Data class (`APPL0`/`APPL1`/`APPL2`/`USR`/`USR1`), Size category (`0`-`4`), Enhancement category (default `NOT_EXTENSIBLE` — see below) |
| STRUCTURE | Enhancement category (default `NOT_EXTENSIBLE` — see below) |
| VIEW | View type (`D`=Database, `P`=Projection, `M`=Maintenance, `H`=Help) |

**Enhancement category (TABLE / STRUCTURE only)** — set proactively after
Save and before Activate so SAP doesn't pop up the forced ENHCAT dialog
and the activation log doesn't include the "not flagged for any
enhancement category" warning. Default is `NOT_EXTENSIBLE` ("Cannot Be
Enhanced") which is the safe choice for plain Z* objects. Override per
call:

| Value | SAP radio (S/4HANA 1909) | Effect |
|---|---|---|
| `NOT_EXTENSIBLE` (default) | `radDESED7-R_FINAL` | "Cannot Be Enhanced" — silences the activation warning, no extension hook |
| `FLAT` | `radDESED7-R_FLAT` | "Can be enhanced (character-like or numeric)" — append-structure with C/N fields allowed |
| `FLAT_NUMERIC` | `radDESED7-R_CHARONLY` | "Can be enhanced (character-like)" — character-only appends |
| `DEEP` | `radDESED7-R_DEEP` | "Can Be Enhanced (Deep)" — full flexibility, nested structures / table types in appends |
| `NOT_CLASSIFIED` | `radDESED7-R_NOCLASS` | "Not classified" — legacy state, generally avoid (the activation warning will keep coming back) |

**Trigger phrases for delete mode** — if the user says **"delete `<TYPE>` `<NAME>`"**,
**"drop `<TYPE>` `<NAME>`"**, **"remove `<TYPE>` `<NAME>`"**, or otherwise asks to
delete a DDIC object, skip the create/update flow and jump to **Step 6c**.
Deletion is **irreversible** — the skill MUST confirm with the user before
running the VBS.

---

## Step 1b — Resolve Transport Request

If `Package` is empty or starts with `$` (e.g. `$TMP`), the object is a local
object; **skip this step** (`%%TRANSPORT%%` will be empty).

Otherwise a TR is needed. **Do NOT prompt the user directly and do NOT call
`/sap-se01`.** Delegate to `/sap-transport-request`, which centralises the
`way_to_get_transport_request` policy:

```
/sap-transport-request [<TR-from-args-if-any>] OBJECT_TYPE=<OBJECT_TYPE> OBJECT_DESCRIPTION=<OBJECT_NAME>
```

Where `<OBJECT_TYPE>` is one of: `TABLE`, `VIEW`, `DTEL`, `STRUCTURE`,
`TABLETYPE`, `TYPEGROUP`, `DOMAIN`, `SEARCHHELP`, `LOCKOBJECT` — the value
from Step 1.

Use the returned modifiable TRKORR as the value for `%%TRANSPORT%%` in all
subsequent VBS templates. If `/sap-transport-request` reports `ERROR`, stop
and surface it to the user.

See `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for the full policy.

---

## Step 2 — Prepare Definition File

Each object type uses a specific tab-delimited definition file format. If the user
pastes definition data directly, write it to `{RUN_TEMP}\<OBJECT_NAME>.def`.

### Definition File Formats

#### Database Table
```
FIELDNAME	KEY	INITIAL	DATAELEMENT	ReferenceTable	Ref.Field
MANDT	X	X	MANDT
BUKRS	X	X	BUKRS
MATNR	X	X	MATNR
AMT			DZWERT	ZHKTBL001	WAERK
WAERK			WAERK
.INCLUDE			ZHKS_FOOTER
```
Each field uses a data element (column 4). Reference table/field (columns 5-6) are for CURR/QUAN amount-currency or quantity-unit relationships — leave blank if not needed.

**Include / Append substructures** — to embed another structure inside this table, add a row whose `FIELDNAME` is the literal `.INCLUDE` (embed an ordinary structure) or `.APPEND` (embed an append structure), and set `DATAELEMENT` (column 4) to the target structure name. `KEY`, `INITIAL`, `ReferenceTable`, and `Ref.Field` must be blank. SAP will resolve the included fields at activation; the data type column will display `STRU`. If SE11 shows a "Group name" popup after entering the include, the script accepts it with Enter (no group prefix).

#### Domain

**Domain definition file** — **one file per domain** (NOT one file with
multiple domains). Pass the domain name + description as the `OBJECT_NAME`
and `OBJECT_DESCRIPTION` arguments; the definition file carries only the
domain's type properties.

The file is 2 rows: a header row, then one data row.

```
DATATYPE	LENGTH	DECIMALS	SIGN	LOWERCASE	OUTPUT_LENGTH	CONV_ROUTINE
CHAR	10
```

Or with decimals + sign:

```
DATATYPE	LENGTH	DECIMALS	SIGN	LOWERCASE	OUTPUT_LENGTH	CONV_ROUTINE
DEC	15	2	X
```

Notes:
- The header row is skipped by the parser (`sap_se11_domain_create.vbs`
  line 19). The 7 column positions are fixed; unused columns must still
  be present as empty cells (real TAB bytes, not the literal `\t` escape).
- **DATATYPE**: consult `sap-dev-core/shared/tables/domain_datatypes.tsv`
  for the complete list of valid values. The `FIXED_LENGTH` column shows
  if the length is fixed (do not enter LENGTH); `MAX_LENGTH` shows the
  maximum user-specifiable length; `DECIMALS_ALLOWED` / `SIGN_ALLOWED`
  indicate which flags apply; `OBSOLETE` marks deprecated types.
- **LENGTH**: required for variable-length types (CHAR, DEC, NUMC, etc.).
  Optional for fixed-length types (INT1=3, INT4=10, DATS=8, etc.) — if
  provided, must match the fixed value.
- **DECIMALS**: blank for types where decimals are not applicable (CHAR,
  INT1, NUMC, etc.). For DEC/CURR/QUAN: 0 to min(LENGTH, 14). For FLTP:
  blank or 16.
- **SIGN**: only allowed for DEC, CURR, QUAN, INT2, INT4, FLTP.
  Forbidden for INT1.

> NOTE: an earlier version of this section showed a 10-column "table" with
> `No. / DomainName / ShortDescription` leading columns and multiple data
> rows. That format was **never** parsed by the VBS — it would fail with
> `ERROR: DATATYPE is empty`. The 7-column format above is the actual
> contract.

**Domain fixed values** — handled exclusively via the **update** template (not create). The update definition file includes an optional `FIXED_VALUES` section after the domain properties:
```
DATATYPE	LENGTH	DECIMALS	SIGN	LOWERCASE	OUTPUT_LENGTH	CONV_ROUTINE
CHAR	10
FIXED_VALUES
VALUE	DESCRIPTION
A	Active
I	Inactive
D	Deleted
```
The create template does not process fixed values — create the domain first, then update it to add fixed values.

**Package/transport handling** — three scenarios:
1. **Both package and transport provided**: Fills package field (`KO007-L_DEVCLASS`), presses Enter, fills transport field (`KO008-TRKORR`), presses Enter.
2. **No package or `$TMP`**: Presses Local Object button (`btn[7]`).
3. **Package provided, no transport**: Fills package, presses Enter, creates a new transport request via `btn[8]` with the domain name as the description.

#### Data Element
```
DOMNAME	LABEL_SHORT	LABEL_MEDIUM	LABEL_LONG	LABEL_HEADING
BUKRS	Company	Company Code	Company Code	Company Code
```
Single data line. `DOMNAME` is the SAP domain name. Labels are optional — leave blank to inherit from the domain.

#### Structure
```
COMPONENT	DATAELEMENT	DATATYPE	LENGTH	DECIMALS	DESCRIPTION
BUKRS	BUKRS				Company Code
WERKS	WERKS_D				Plant
CUSTOM1		CHAR	20		Custom Field
.INCLUDE	ZHKS_COMMON				
```
Each component uses EITHER a data element OR a direct type. Same pattern as table fields but without KEY/INITIAL columns.

**Include / Append substructures** — to embed another structure, add a row whose `COMPONENT` is `.INCLUDE` or `.APPEND`, with `DATAELEMENT` set to the target structure name and the remaining columns blank. SAP resolves the included components at activation; the data type column will display `STRU`.

#### Table Type
```
LINE_TYPE_CATEGORY	LINE_TYPE_NAME	ACCESS_MODE	KEY_DEF
STRUCTURE	ZSOMESTRUCT	S	
```
Single data line. Categories: `STRUCTURE`, `DATAELEMENT`, `BUILT_IN`. Access modes: `S`=Standard, `O`=Sorted, `H`=Hashed, `I`=Index.

#### View
```
TABLES
TABLE	ORDER
ZTABLE1	1
ZTABLE2	2
JOIN_CONDITIONS
TABLE1	FIELD1	TABLE2	FIELD2
ZTABLE1	MANDT	ZTABLE2	MANDT
ZTABLE1	DOCNR	ZTABLE2	DOCNR
VIEW_FIELDS
TABLE	FIELD
ZTABLE1	MANDT
ZTABLE1	DOCNR
ZTABLE2	DESCRIPTION
```
Multi-section: `TABLES` (base tables), `JOIN_CONDITIONS` (for database views with >1 table), `VIEW_FIELDS` (fields to include in the view).

#### Search Help
```
SELECTION_METHOD	ZTABLE
DIALOG_TYPE	C
HOT_KEY	
PARAMETERS
SHLP_PARAM	LPOS	SPOS	SDIS	IMP	EXP	DATA_ELEMENT
FIELD1	1	1	X	X	X	BUKRS
FIELD2	2	2	X		X	WERKS_D
```
Header key-value pairs, then `PARAMETERS` section with parameter grid. Dialog types: `A`=Display immediately, `C`=Dialog with restriction, `D`=Depends on values.

#### Lock Object
```
PRIMARY_TABLE	ZTABLE
LOCK_MODE	E
SECONDARY_TABLES
TABLE
ZTABLE2
LOCK_ARGUMENTS
TABLE	FIELD
ZTABLE	MANDT
ZTABLE	BUKRS
```
Header key-value pairs, then optional `SECONDARY_TABLES` and `LOCK_ARGUMENTS` sections. Lock modes: `E`=Write, `S`=Read, `X`=Exclusive.

#### Type Group
Type group uses raw ABAP source (NOT tab-delimited):
```abap
TYPE-POOL ztyp.
TYPES: ztyp_status TYPE c LENGTH 1.
CONSTANTS: ztyp_active TYPE ztyp_status VALUE 'A'.
```

### Write the definition file

If the user pasted definition data:
1. Write the definition to: `{RUN_TEMP}\<OBJECT_NAME>.def`
2. Either **UTF-8** (the Write tool default) or **UTF-16 LE** is fine — the
   reference VBS auto-detects the BOM via the inline `EnsureUnicodeFile`
   helper and converts UTF-8 → UTF-16 LE in a temp file before reading. No
   manual re-encoding step is required.
3. Confirm by reading back the first few lines.

If the user provided a file path, use it as-is. Verify it exists:
```bash
cmd /c if exist "<path>" (echo EXISTS) else (echo NOT FOUND)
```

> **⚠️ CRITICAL — column separators must be REAL TAB bytes (chr 9)**
>
> The VBS templates parse every definition line with `Split(sLine, vbTab)`,
> which only matches actual TAB bytes. If the .def file ends up containing
> the **two-character escape sequence `\t`** (backslash + the letter `t`)
> instead of a real TAB, every data row collapses to a single column — the
> resulting DDIC object is silently corrupted (empty data elements, types,
> lengths) and the GUI status bar still reports SUCCESS. There has been at
> least one live incident of this exact failure mode; Step 2.5 below
> auto-detects and repairs it, but the right thing is to not produce the
> corruption in the first place.
>
> Common causes:
> - Building the content string in Python/JS-style escape syntax (`"FIELD\tDATAELEMENT\n..."`)
>   and passing it to the Write tool. The Write tool writes bytes verbatim —
>   it does NOT interpret `\t` as a TAB.
> - Copy-pasting from a Markdown code block where TABs got rendered as the
>   literal characters `\t`.
>
> Correct patterns:
> - **Embed actual TAB characters in the string.** With the Write tool, place
>   a real TAB between each column. The TABs must be real bytes in the
>   `content` parameter, not escape sequences.
> - When in doubt, write the file via PowerShell with explicit `[char]9`:
>   ```powershell
>   $T = [char]9
>   $rows = @(
>     "FIELDNAME${T}KEY${T}INITIAL${T}DATAELEMENT${T}ReferenceTable${T}Ref.Field",
>     "MANDT${T}X${T}X${T}MANDT",
>     "AMT${T}${T}${T}DZWERT${T}ZHKTBL001${T}WAERK"
>   )
>   [System.IO.File]::WriteAllText('{RUN_TEMP}\<OBJECT_NAME>.def',
>     ($rows -join "`r`n"),
>     [System.Text.UTF8Encoding]::new($false))
>   ```
>
> The same caveat applies to literal `\n` / `\r` — use real newlines, not
> the two-character escapes.

---

## Step 2.5 — Validate / Auto-Repair Definition File

Run the column-separator integrity check **before** generating the VBS. This
gates against the silent half-deploy described in the warning above. The
script is idempotent and safe to run on any definition file (including
files the user supplied directly — they may have come from the same
upstream LLM pipeline).

```powershell
$ps = Get-Content '<SKILL_DIR>\references\sap_se11_normalize_def.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%DEFINITION_FILE%%', 'THE_DEFINITION_FILE_PATH'
$ps = $ps -replace '%%OBJECT_TYPE%%',     'THE_OBJECT_TYPE'
[System.IO.File]::WriteAllText("{RUN_TEMP}\sap_se11_normalize.ps1", $ps, [System.Text.Encoding]::UTF8)
```

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se11_normalize.ps1"
```

**Parse the last line of output:**
- `OK` → file is parseable, continue.
- `REPAIRED:<N>` → N escape sequences were auto-fixed. Show the preceding
  `WARNING:` lines to the operator so they understand what changed, then
  continue.
- `SKIPPED:<reason>` → file does not need TSV validation (e.g. `TYPEGROUP`
  raw ABAP, single-line header-only file). Continue.
- `ERROR: …` → unrecoverable corruption. **Stop**, surface the error, and
  ask the operator (or upstream agent) to regenerate the .def file with
  real TAB bytes.

This step also covers the case where the user supplied a file path
upstream — files from any source pass through the same gate.

Add the normalizer call to the temp-file cleanup list in Step 7.

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Object Exists

The check VBScript template is at `./references/sap_se11_check.vbs`. It works for ALL object types.

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se11_check_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se11_check.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%OBJECT_TYPE%%','THE_OBJECT_TYPE'
$content = $content -replace '%%OBJECT_NAME%%','THE_OBJECT_NAME'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se11_check_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_OBJECT_TYPE` with one of: `TABLE`, `VIEW`, `DATATYPE`, `TYPEGROUP`, `DOMAIN`, `SEARCHHELP`, `LOCKOBJECT`.

**Type mapping for the check script:**

| User-facing type | Check OBJECT_TYPE |
|---|---|
| TABLE | `TABLE` |
| VIEW | `VIEW` |
| DATAELEMENT | `DATATYPE` |
| STRUCTURE | `DATATYPE` |
| TABLETYPE | `DATATYPE` |
| TYPEGROUP | `TYPEGROUP` |
| DOMAIN | `DOMAIN` |
| SEARCHHELP | `SEARCHHELP` |
| LOCKOBJECT | `LOCKOBJECT` |

Note: DATAELEMENT, STRUCTURE, and TABLETYPE all use the `DATATYPE` radio button in SE11.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se11_check_run.ps1"
```

### Execute

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo {RUN_TEMP}\sap_se11_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → object exists → proceed to Step 5a (Update).
- `NOT_EXIST` → object does not exist → proceed to Step 5b (Create).
- `ERROR:` → show full output and stop.

---

## Step 4b — Pre-flight Existence Check for Referenced Objects

Before creating/updating certain object types, verify that all referenced domains or data elements exist in the SAP system. This prevents activation errors.

### When to run existence checks

| Object being created/updated | Check needed | What to check |
|---|---|---|
| Data Element (create/update) | Domain existence | The `DOMNAME` in the definition file must exist as an active domain |
| Table (create/update) | Data element existence | All `DATAELEMENT` values in the definition file must exist as active data elements |
| Structure (create/update) | Data element existence | All `DATAELEMENT` values in the definition file |
| View (create/update) | Table existence | Base tables must exist (checked by SE11 itself, no separate script needed) |

### Check domain existence

Template: `./references/sap_se11_check_domains.ps1`

Write a names file with one domain name per line, then fill and run the PS1:

```powershell
# Write domain names to check (one per line)
$names = "BUKRS`r`nWAERS`r`n"
[System.IO.File]::WriteAllText("{RUN_TEMP}\check_dom_names.txt", $names, [System.Text.UnicodeEncoding]::new($false, $true))

# Fill PS1 template
$ps = Get-Content '<SKILL_DIR>\references\sap_se11_check_domains.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%NAMES_FILE%%',   '{RUN_TEMP}\check_dom_names.txt'
$ps = $ps -replace '%%SAP_SERVER%%',   ''
$ps = $ps -replace '%%SAP_SYSNR%%',    ''
$ps = $ps -replace '%%SAP_CLIENT%%',   ''
$ps = $ps -replace '%%SAP_USER%%',     ''
$ps = $ps -replace '%%SAP_PASSWORD%%', ''
$ps = $ps -replace '%%SAP_LANGUAGE%%', ''
$ps = $ps -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
[System.IO.File]::WriteAllText("{RUN_TEMP}\sap_check_dom.ps1", $ps, [System.Text.Encoding]::UTF8)
```

Run:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_check_dom.ps1"
```

Output per domain: `EXIST:<NAME>` or `NOT_EXIST:<NAME>`. If any domain shows `NOT_EXIST`, create it first (via this skill's domain create flow) before proceeding.

### Check data element existence

Template: `./references/sap_se11_check_dataelements.ps1`

Same pattern — write names file, fill PS1, run:

```powershell
$names = "BUKRS`r`nMATNR`r`nWAERK`r`n"
[System.IO.File]::WriteAllText("{RUN_TEMP}\check_de_names.txt", $names, [System.Text.UnicodeEncoding]::new($false, $true))

$ps = Get-Content '<SKILL_DIR>\references\sap_se11_check_dataelements.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%NAMES_FILE%%',   '{RUN_TEMP}\check_de_names.txt'
$ps = $ps -replace '%%SAP_SERVER%%',   ''
$ps = $ps -replace '%%SAP_SYSNR%%',    ''
$ps = $ps -replace '%%SAP_CLIENT%%',   ''
$ps = $ps -replace '%%SAP_USER%%',     ''
$ps = $ps -replace '%%SAP_PASSWORD%%', ''
$ps = $ps -replace '%%SAP_LANGUAGE%%', ''
$ps = $ps -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
[System.IO.File]::WriteAllText("{RUN_TEMP}\sap_check_de.ps1", $ps, [System.Text.Encoding]::UTF8)
```

Run:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_check_de.ps1"
```

Output per data element: `EXIST:<NAME>:<DATATYPE>` or `NOT_EXIST:<NAME>`. If any shows `NOT_EXIST`, create it first. The `DATATYPE` value (e.g., `CHAR`, `NUMC`, `CURR`, `QUAN`, `CUKY`, `UNIT`) is used for Ref.Field validation below.

### Validate Ref.Field data types (Table/Structure only)

When a table or structure definition has **Ref.Table** and **Ref.Field** columns (columns 5-6), the
data element in column 4 (DATAELEMENT) of that field **must** have a data type of `CURR` or `QUAN`.

- `CURR` (currency amount) → Ref.Field must point to a field with data type `CUKY` (currency key)
- `QUAN` (quantity) → Ref.Field must point to a field with data type `UNIT` (unit of measure)

**Before running create/update VBS**, validate the definition file:

1. Parse the definition file and find all rows where columns 5-6 (Ref.Table, Ref.Field) are non-empty
2. For each such row, check the DATAELEMENT (column 4) via `RFC_READ_TABLE` on `DD04L`:
   - Query: `ROLLNAME = '<DATAELEMENT>' AND AS4LOCAL = 'A'`, fields: `DATATYPE`
   - If `DATATYPE` is not `CURR` and not `QUAN`, report an error:
     > "Field `<FIELDNAME>` has Ref.Table/Ref.Field but its data element `<DATAELEMENT>` has data type `<DATATYPE>` — Ref.Table/Ref.Field is only valid for CURR or QUAN types. Remove the reference or change the data element."
3. Also check the Ref.Field target: the data element of the Ref.Field must have data type `CUKY` (for CURR) or `UNIT` (for QUAN). Query the Ref.Field's data element from the Ref.Table definition.

**This validation uses the same RFC connection as the data element existence check** — no new
VBS template is needed. Add the `DATATYPE` check as an additional step after confirming the data
element exists. The `RFC_READ_TABLE` query on `DD04L` already returns the `DATATYPE` field.

If the data element does not have `CURR` or `QUAN` type, **stop and ask the user** to fix the
definition before proceeding to create/update. Do not pass invalid reference columns to SE11.

### Connection parameters for existence checks

These scripts use **RFC_READ_TABLE** via SAP NCo 3.1 (direct RFC connection, not SAP GUI).

Read SAP connection parameters from the merged sap-dev-core settings (per `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`). The `sap_password` value typically comes from `settings.local.json` and is a `dpapi:...` blob — decrypt via `sap_dpapi.ps1` before use.
Resolve path: go 2 levels up from `<SKILL_DIR>` (skill → skills/ → plugin root), then `settings.json`.

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

## Step 4.5 — Naming Pre-Check

Validate the DDIC object name against `sap_object_naming_rules.tsv` (custom
override → default) **before** launching any create / update flow.

Map the user-facing `OBJECT_TYPE` (collected in Step 1) to the validator's
rule key:

| User-facing type | Validator OBJECT_TYPE |
|---|---|
| DOMAIN | `DDIC_DOMAIN` |
| DATAELEMENT | `DDIC_DATAELEMENT` |
| TABLE | `DDIC_TABLE` |
| STRUCTURE | `DDIC_STRUCTURE` |
| VIEW | `DDIC_VIEW` |
| TABLETYPE | `DDIC_TABLETYPE` |
| TYPEGROUP | `DDIC_TYPEGROUP` |
| SEARCHHELP | `DDIC_SEARCHHELP` |
| LOCKOBJECT | `DDIC_LOCKOBJECT` |

Invoke the shared validator:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType <MAPPED_TYPE> -ObjectName THE_OBJECT_NAME -CustomUrl "{custom_url}"
```

Behaviour:
- Exit `0` → silently continue.
- Exit `1` → show the violation line and ask:
  *"The DDIC object name does not match the configured naming rule. Proceed anyway, or abort?"*
  - **Abort** → end the run with `Status SKIPPED`, `ErrorClass OBJECT_NAMING_VIOLATION`.
  - **Proceed** → continue, recording the choice via `sap_log_helper.ps1 -Action step`.
- Exit `2` (`UNKNOWN_TYPE` / `RULES_NOT_FOUND`) → log a step note and continue.

The user can customise the rule at `{custom_url}\sap_object_naming_rules.tsv`.

---

## Step 5a — Update Existing Object

**Update flow (Original-language popup handling):** Right after pressing
the Change button (`btnPUSHEDIT`), every SE11 update VBS inspects `wnd[1]`
for the SAPLSETX "Different original and logon languages" dialog
(fingerprint: `wnd[1]/usr/ctxtRSETX-MASTERLANG` present). If found, the
template presses `wnd[1]/usr/btnPUSH1` ("Maint. in orig. lang.") to keep
`TADIR-MASTERLANG` unchanged. The popup appears when `sap_language` differs
from the object's MASTERLANG — typical when an object was created in
English and we log in as Japanese (or vice versa).

**Update flow (TR popup handling):** All 9 SE11 update VBS templates (table,
view, dataelement, structure, tabletype, typegroup, domain, searchhelp,
lockobject) send `Ctrl+S` immediately after pressing the Change button
(`btnPUSHEDIT`) to provoke the "Prompt for local Workbench request" popup.
If `wnd[1]` shows a TR field (`ctxtKO008-TRKORR`), the template fills
`SAP_TRANSPORT` and Enter, locking the object to that TR; subsequent saves
no longer prompt. If no popup appears, the object is local (`$TMP`) or
already locked to a modifiable TR. If the popup appears but `SAP_TRANSPORT`
is empty, the VBS aborts; the caller must run `/sap-transport-request`
(Step 1b) first. Diagnostics on unexpected behaviour: query `TADIR` for
`DEVCLASS` (starts with `$` → local), `E071` for object→TR linkage,
`E070-TRSTATUS` for TR modifiable state.

**Update flow (data-element migration — STRUCTURE):** The structure update
template no longer only *appends* new components. When the definition file
names a **different data element** for an **existing** field, the template
overwrites that field's `ctxtDD03P_D-ROLLNAME` cell in place (read-back
verified) and reports `Migrated existing component … data element X -> Y`. If
a requested data-element change cannot be applied, the template prints `ERROR:`
and exits non-zero instead of a false `SUCCESS:`. (Direct-type changes on an
existing field — a DATATYPE with no data element — stay unsupported: those grid
cells are `Changeable=False`, and the template rejects such rows up front.)
This makes in-place single-source-DDIC migration work without a
`/sap-dev-clean` + `/sap-dev-init` recreate.

**Update flow (post-activate RFC gate — DOMAIN / STRUCTURE / TABLETYPE):**
These three update templates now shell out to
`sap_se11_post_activate_verify.ps1` AFTER Activate and **fail closed** if the
object is left non-activated — the same gate the create templates use, with one
update-specific refinement: an UPDATE always leaves the prior **active**
version in place, so the verifier flags **any pending (non-active) DDIC
version** (`AS4LOCAL <> 'A'`, e.g. the `'L'` saved-but-not-activated row) as a
failure rather than passing just because *an* active version exists. This
catches the silent false-success where Activate reported success on the status
bar but the change stayed inactive (observed on 7.31 + 1909, 2026-06-22). The
gate is best-effort: if RFC creds / NCo are unavailable it emits the
distinctive non-blocking line `WARNING: POST_ACTIVATE_VERIFY_UNAVAILABLE - <reason>`
and relies on the GUI status bar — **when that line appears, report the deploy
as SUCCESS_UNVERIFIED (not SUCCESS)** and suggest `/sap-dev-status` to confirm
the object; a verify failure (`INACTIVE` / `MISSING`) remains a hard `ERROR:`.
The other six update templates ignore the
`%%POST_ACTIVATE_VERIFY_*%%` tokens (no gate yet — adopt the same pattern when
needed).


Select the appropriate update VBScript based on the object type:

| Object type | VBS template |
|---|---|
| TABLE | `./references/sap_se11_table_update.vbs` |
| VIEW | `./references/sap_se11_view_update.vbs` |
| DATAELEMENT | `./references/sap_se11_dataelement_update.vbs` |
| STRUCTURE | `./references/sap_se11_structure_update.vbs` |
| TABLETYPE | `./references/sap_se11_tabletype_update.vbs` |
| TYPEGROUP | `./references/sap_se11_typegroup_update.vbs` |
| DOMAIN | `./references/sap_se11_domain_update.vbs` |
| SEARCHHELP | `./references/sap_se11_searchhelp_update.vbs` |
| LOCKOBJECT | `./references/sap_se11_lockobject_update.vbs` |

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se11_update_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se11_<TYPE>_update.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%OBJECT_NAME%%','THE_OBJECT_NAME'
$content = $content -replace '%%DEFINITION_FILE%%','THE_DEFINITION_FILE_PATH'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
# Object short text. Update leaves the short text UNCHANGED by default (empty =
# no change). Only DOMAIN and DATAELEMENT update templates reference this token;
# the others ignore it. Substituting '' (not leaving the literal token) keeps
# the literal "%%OBJECT_DESCRIPTION%%" out of the short text (fix 2026-06-22).
# To change the short text on an update, set a non-empty value here.
$content = $content -replace '%%OBJECT_DESCRIPTION%%',''
$content = $content -replace '%%ACTIVATION_LOG_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_activation_log.vbs'
$content = $content -replace '%%TEMP_DIR%%','{RUN_TEMP}'
# Enhancement-category proactive-set (TABLE / STRUCTURE only — other types
# ignore the token if it isn't present in their template).
$content = $content -replace '%%ENHANCEMENT_CATEGORY%%','THE_ENH_CATEGORY'
$content = $content -replace '%%ENH_CATEGORY_VBS%%','<SKILL_DIR>\references\sap_se11_set_enh_category.vbs'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
# Post-activate RFC verify plumbing (parity with create, Step 5b). The DOMAIN,
# STRUCTURE and TABLETYPE update templates shell out to the verify PS1 AFTER
# activation and FAIL CLOSED if a pending (non-active) DDIC version remains --
# this catches a non-activated update that the GUI status bar reported as
# success. Other update templates ignore these tokens.
$content = $content -replace '%%POST_ACTIVATE_VERIFY_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_se11_post_activate_verify.vbs'
$content = $content -replace '%%POST_ACTIVATE_VERIFY_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_se11_post_activate_verify.ps1'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se11_update_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `<TYPE>` with the lowercase object type (table, view, dataelement, structure, tabletype, typegroup, domain, searchhelp, lockobject). Replace all `THE_*` placeholders and `<SKILL_DIR>`. `THE_PACKAGE` and `THE_TRANSPORT` are optional — use empty string for local object.

`THE_ENH_CATEGORY` is the enhancement category for TABLE / STRUCTURE updates. Accepted values (case-insensitive):

| Value | SAP radio (S/4HANA 1909) | Effect |
|---|---|---|
| `NOT_EXTENSIBLE` (default) | `radDESED7-R_FINAL` | "Cannot Be Enhanced" — silences the activation warning without leaving any extension hook. Safe for plain Z* tables/structures that won't be extended by add-ons or customer-side projects. |
| `FLAT` | `radDESED7-R_FLAT` | "Can be enhanced (character-like or numeric)" — append structures with C/N fields allowed. Use when downstream code (add-ons, customer projects, BAdIs) needs to append fields. |
| `FLAT_NUMERIC` | `radDESED7-R_CHARONLY` | "Can be enhanced (character-like)" — character-only appends. |
| `DEEP` | `radDESED7-R_DEEP` | "Can Be Enhanced (Deep)" — full enhancement flexibility (allows nested structures / table types in appends). |
| `NOT_CLASSIFIED` | `radDESED7-R_NOCLASS` | "Not classified" — legacy state, generally avoid (the activation warning will keep coming back). |

If you don't know what to pick, default to `NOT_EXTENSIBLE`. The helper skips silently for non-TABLE / non-STRUCTURE object types.

**MANDATORY:** Always substitute `THE_ENH_CATEGORY` with one of the 4
accepted values (`NOT_EXTENSIBLE` / `FLAT` / `FLAT_NUMERIC` / `DEEP`).
Leaving the literal `%%ENHANCEMENT_CATEGORY%%` placeholder in the VBS
template breaks `SetEnhancementCategory` — the helper has a defensive
fallback that coerces unreplaced placeholders to `NOT_EXTENSIBLE` (so
the structure still activates cleanly), but the warning log
"Unrecognized Enhancement Category — coercing to NOT_EXTENSIBLE"
appears in the transcript. Substitute the value at template-fill time
to keep transcripts clean. Bug surfaced 2026-05-11 on first
ZCMST_RFC_PARAM create via `/sap-dev-init` Step 5.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se11_update_run.ps1"
```

### Execute (with SAP GUI Security guard)

If activation fails, the VBS calls `CaptureActivationLog`, which drives
**Utilities > Activation Log → Log > Save Local File** — **SAP-GUI-side file
IO** that can raise the modal **SAP GUI Security** dialog (Default Action = Ask),
suspending the Scripting API and hanging the cscript. The save only fires on an
activation error, so per `shared/rules/sap_gui_security_handling.md` we run the
OS-level watcher **unconditionally** around the cscript (it harmlessly times out
if no dialog appears). The pre-check targets the activation-log path so the
watcher is skipped once a rule has been persisted. Run as one PowerShell block
(the 32-bit cscript is inside it). Substitute `THE_OBJECT_NAME` /
`THE_SID` / `THE_CLIENT`:

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$log    = '{RUN_TEMP}\THE_OBJECT_NAME.activation_log.txt'   # path the activation-log save would write
# 1. Pre-check the allow-list (read-only; lets us skip the watcher once a rule exists).
& "$shared\sap_gui_security_precheck.ps1" -Path $log -Access w -System 'THE_SID' -Client 'THE_CLIENT' -Transaction 'SE11' | Out-Host
$allowed = ($LASTEXITCODE -eq 0)
# 2. Launch the OS-level watcher BEFORE the (potentially blocking) cscript. The
#    activation-log save is conditional, so the watcher is best-effort: it ticks
#    Remember+Allow if the dialog appears, else times out harmlessly.
$watcher = $null
if (-not $allowed) {
    $watcher = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','40')
    Start-Sleep -Milliseconds 800
}
# 3. Run the update + activate (32-bit cscript). If activation errors and the
#    activation-log save raises the dialog, it blocks here until the watcher
#    dismisses it; then the log is saved and the run completes.
& 'C:/Windows/SysWOW64/cscript.exe' //NoLogo '{RUN_TEMP}\sap_se11_update_run.vbs'
# 4. Reap the watcher.
if ($watcher) { $watcher | Wait-Process -Timeout 45 -ErrorAction SilentlyContinue }
```

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Object

For new objects, you need the Object description in addition to the definition file.
Ask the user if not already provided.

Select the appropriate create VBScript based on the object type:

| Object type | VBS template |
|---|---|
| TABLE | `./references/sap_se11_table_create.vbs` |
| VIEW | `./references/sap_se11_view_create.vbs` |
| DATAELEMENT | `./references/sap_se11_dataelement_create.vbs` |
| STRUCTURE | `./references/sap_se11_structure_create.vbs` |
| TABLETYPE | `./references/sap_se11_tabletype_create.vbs` |
| TYPEGROUP | `./references/sap_se11_typegroup_create.vbs` |
| DOMAIN | `./references/sap_se11_domain_create.vbs` |
| SEARCHHELP | `./references/sap_se11_searchhelp_create.vbs` |
| LOCKOBJECT | `./references/sap_se11_lockobject_create.vbs` |

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se11_create_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se11_<TYPE>_create.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%OBJECT_NAME%%','THE_OBJECT_NAME'
$content = $content -replace '%%OBJECT_DESCRIPTION%%','THE_OBJECT_DESCRIPTION'
$content = $content -replace '%%DEFINITION_FILE%%','THE_DEFINITION_FILE_PATH'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
$content = $content -replace '%%ACTIVATION_LOG_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_activation_log.vbs'
$content = $content -replace '%%TEMP_DIR%%','{RUN_TEMP}'
# Enhancement-category proactive-set (TABLE / STRUCTURE only — other types
# ignore the token if it isn't present in their template). See the
# `THE_ENH_CATEGORY` table in Step 5a for accepted values.
$content = $content -replace '%%ENHANCEMENT_CATEGORY%%','THE_ENH_CATEGORY'
$content = $content -replace '%%ENH_CATEGORY_VBS%%','<SKILL_DIR>\references\sap_se11_set_enh_category.vbs'
```

> **`%%ACTIVATION_LOG_VBS%%` and `%%TEMP_DIR%%`** are required by the
> activation-log capture helper invoked when `Activate (Ctrl+F3)` reports
> errors. The helper writes `<OBJECT_NAME>.activation_log.txt` to
> `{RUN_TEMP}` and echoes both the file path and the top error line so
> the operator sees the *specific* failing field/rule (e.g. "X-AMT
> (specify reference table AND reference field)") instead of the generic
> "refer to log" popup. Currently wired into `sap_se11_table_create.vbs`
> and `sap_se11_table_update.vbs`; other DDIC reference VBS files in this
> skill (dataelement / domain / structure / view / tabletype / typegroup /
> searchhelp / lockobject create + update) can adopt the same pattern by
> including `%%ACTIVATION_LOG_VBS%%` and calling `CaptureActivationLog`
> after their activate step. **Do not propagate to SE38/SE37/SE24/SE91** —
> the `Utilities > Activation Log` menu is DDIC-only; those transactions
> surface activation errors via the source-code editor's inline error
> markers + status bar (already captured by their existing skills).

> **Definition-file encoding:** The reference VBS reads the definition file
> through an inline `EnsureUnicodeFile` helper that auto-detects the BOM
> and accepts **UTF-8** (default), **UTF-8 with BOM**, **UTF-16 LE**, or
> **UTF-16 BE**. UTF-8 (the Write tool default) is the recommended path —
> no `-Encoding Unicode` step required. Historical guidance about needing
> UTF-16 LE no longer applies; the helper handles all four encodings
> transparently.


**Add type-specific token replacements:**

For TABLE, also add:
```powershell
$content = $content -replace '%%DELIVERY_CLASS%%','THE_DELIVERY_CLASS'
$content = $content -replace '%%DATA_CLASS%%','THE_DATA_CLASS'
$content = $content -replace '%%SIZE_CATEGORY%%','THE_SIZE_CATEGORY'
```

For VIEW, also add:
```powershell
$content = $content -replace '%%VIEW_TYPE%%','THE_VIEW_TYPE'
```

Then write:
```powershell
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
# Phase 4.3 post-activate RFC verify plumbing. The VBS shells out to the PS1
# AFTER activation; the PS1 reads the AI-session pinned connection from
# connections.json (DPAPI-decrypted password) and runs an RFC_READ_TABLE
# against the right DDIC catalog table (TYPEGROUP: TADIR + DWINACTIV -- it
# has no DD*L catalog table). Fail-closed on INACTIVE/MISSING. If the helper
# can't run, the output carries the non-blocking line
# WARNING: POST_ACTIVATE_VERIFY_UNAVAILABLE - <reason>  -> report the deploy
# as SUCCESS_UNVERIFIED (not SUCCESS) and suggest /sap-dev-status.
$content = $content -replace '%%POST_ACTIVATE_VERIFY_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_se11_post_activate_verify.vbs'
$content = $content -replace '%%POST_ACTIVATE_VERIFY_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_se11_post_activate_verify.ps1'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se11_create_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Replace all `THE_*` placeholders, `<TYPE>`, and `<SKILL_DIR>`. `THE_PACKAGE` and `THE_TRANSPORT` are optional — use empty string for local object.

**Package/Transport behavior** (same for create and update, all object types):
- If both `%%PACKAGE%%` and `%%TRANSPORT%%` are non-empty: fills package field (`KO007-L_DEVCLASS`), presses Enter, fills transport field (`KO008-TRKORR`), presses Enter.
- If `%%PACKAGE%%` is empty or `$TMP`: presses Local Object button (`btn[7]`).
- If `%%PACKAGE%%` is non-empty but `%%TRANSPORT%%` is empty: fills package, presses Enter, creates a new transport request via `btn[8]` with the object name as the description.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se11_create_run.ps1"
```

### Execute (with SAP GUI Security guard)

If activation fails, the VBS calls `CaptureActivationLog`, which drives
**Utilities > Activation Log → Log > Save Local File** — **SAP-GUI-side file
IO** that can raise the modal **SAP GUI Security** dialog (Default Action = Ask),
suspending the Scripting API and hanging the cscript. The save only fires on an
activation error, so per `shared/rules/sap_gui_security_handling.md` we run the
OS-level watcher **unconditionally** around the cscript (it harmlessly times out
if no dialog appears). The pre-check targets the activation-log path so the
watcher is skipped once a rule has been persisted. Run as one PowerShell block
(the 32-bit cscript is inside it). Substitute `THE_OBJECT_NAME` /
`THE_SID` / `THE_CLIENT`:

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$log    = '{RUN_TEMP}\THE_OBJECT_NAME.activation_log.txt'   # path the activation-log save would write
# 1. Pre-check the allow-list (read-only; lets us skip the watcher once a rule exists).
& "$shared\sap_gui_security_precheck.ps1" -Path $log -Access w -System 'THE_SID' -Client 'THE_CLIENT' -Transaction 'SE11' | Out-Host
$allowed = ($LASTEXITCODE -eq 0)
# 2. Launch the OS-level watcher BEFORE the (potentially blocking) cscript. The
#    activation-log save is conditional, so the watcher is best-effort: it ticks
#    Remember+Allow if the dialog appears, else times out harmlessly.
$watcher = $null
if (-not $allowed) {
    $watcher = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','40')
    Start-Sleep -Milliseconds 800
}
# 3. Run the create + activate (32-bit cscript). If activation errors and the
#    activation-log save raises the dialog, it blocks here until the watcher
#    dismisses it; then the log is saved and the run completes.
& 'C:/Windows/SysWOW64/cscript.exe' //NoLogo '{RUN_TEMP}\sap_se11_create_run.vbs'
# 4. Reap the watcher.
if ($watcher) { $watcher | Wait-Process -Timeout 45 -ErrorAction SilentlyContinue }
```

Proceed to Step 6 to evaluate the result.

---

## Step 5c — Check Behavior (Built Into Templates)

All create/update VBS templates (except Type Group) include an automatic **Check**
step. You do not need to do anything extra — the check is embedded in the VBS flow.

### Check behavior by object type

| Category | Object types | Template order |
|---|---|---|
| **Save → Check → Activate** | Domain, Data Element, Table | Save first (Ctrl+S), then Check (`tbar[1]/btn[26]`), then Activate. Status bar `type=E` after check indicates warning (object already saved). |
| **Check → Save → Activate** | Structure, Search Help, Lock Object, Table Type, View | Check runs before save on in-memory state. Status bar `type=E` indicates error. |
| **No Check** | Type Group | Type Group editor has no Check button. Errors are caught at activation. |

### How errors are detected

- **Status-bar check**: If `sbar.MessageType = "E"` after check, the script outputs `ERROR: Check failed - <message>` and exits with code 1.
- **On check pass**: The script continues to the next step (Save or Activate depending on order).

### Check error messages and fixes

| Check error message | Cause | Fix |
|---|---|---|
| `Fill out all required entry fields` | Required field empty (data type, name, etc.) | Fill all required fields in the definition file |
| `No active domain <name> available` | Data element references non-existent/inactive domain | Create and activate the domain first |
| `Data type is not supported` | Table field has no data element/type specified | Add DATAELEMENT or DATATYPE+LENGTH to field definition |
| `Key field has invalid type` | Key field type cannot be used as key | Use a valid key-compatible type (CHAR, NUMC, etc.) |
| `Enhancement category missing` | Table/structure missing enhancement category | Enhancement category popup is handled automatically by the template |
| `is inconsistent` | General: referenced objects missing or invalid | Check all referenced objects (domains, data elements, tables) exist and are active |

---

## Step 5d — Post-Activate RFC Verification (mandatory)

**Why this step exists.** The create/update VBS reports `SUCCESS:` based on
the SAP GUI status bar, but the GUI status bar can lie:

- A "Check Structure" / activation-error popup may have been force-dismissed
  by the session-lock pre-unlock sweep (F12), leaving DD02L / DD03L empty
  while TADIR still has the entry — a silent half-deploy.
- The supplied transport could be released, in which case SAP rejects the
  save without an error message type the script picks up.

We therefore verify the active version exists in the DDIC catalog via RFC
**before** declaring SUCCESS. This catches the silent failure modes.

Template: `./references/sap_se11_verify_active.ps1`. Fill from the standard
SAP credential tokens plus `%%OBJECT_TYPE%%` and `%%OBJECT_NAME%%`:

```powershell
$ps = Get-Content '<SKILL_DIR>\references\sap_se11_verify_active.ps1' -Raw -Encoding UTF8
$ps = $ps -replace '%%SAP_SERVER%%',   ''
$ps = $ps -replace '%%SAP_SYSNR%%',    ''
$ps = $ps -replace '%%SAP_CLIENT%%',   ''
$ps = $ps -replace '%%SAP_USER%%',     ''
$ps = $ps -replace '%%SAP_PASSWORD%%', ''
$ps = $ps -replace '%%SAP_LANGUAGE%%', ''
$ps = $ps -replace '%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
$ps = $ps -replace '%%OBJECT_TYPE%%',  'STRUCTURE'
$ps = $ps -replace '%%OBJECT_NAME%%',  'THE_OBJECT_NAME'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se11_verify.ps1', $ps, [System.Text.Encoding]::UTF8)
```

Run via 32-bit PowerShell:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se11_verify.ps1"
```

**Parse the last line:**
- `ACTIVE`   → object is active in DDIC; proceed to Step 6 with confirmed success.
- `INACTIVE` → a pending (non-active) DDIC version is present — the object is
  not active, or (on an **update**) the change was saved but not activated
  while the prior active version remains. Both verifiers treat **any**
  `AS4LOCAL <> 'A'` version as INACTIVE, so a non-activated update fails here
  even though an active version still exists. Treat as failure and surface the
  activation log (open SE11, Utilities > Activation Log) or re-activate via
  `/sap-activate-object`.
- `MISSING`  → silent half-deploy (TADIR exists but DDIC catalog is empty);
  treat as failure and ask the operator to clean up via SE03 or
  `RS_DD_DELETE_OBJ` before retrying.
- `ERROR:`   → RFC verification could not run; report it but do not block
  the run (treat as warning).

`OBJECT_TYPE` token map for the verifier: same as `Step 4` but use the
DDIC-catalog specific value: `TABLE`, `STRUCTURE`, `DATAELEMENT`,
`DOMAIN`, `TABLETYPE`, `VIEW`, `SEARCHHELP`, `LOCKOBJECT`, `TYPEGROUP`.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:` AND Step 5d returned `ACTIVE`):
- Tell the user the object was created/updated and activated.
- Show the full script output as a code block.

**On failure** (output contains `ERROR:` or `WARNING:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `Check failed - <message>` | Consistency check detected an error (status bar shows error) | Read the error message, fix the definition file, and re-run |
| `Could not press Create button` | Object may already exist or naming issue | Check name, re-run check step |
| `Could not fill table description` | Component ID mismatch | Use SAP Scripting Recorder to find correct ID |
| `Sub-type popup detected` | Data type radio needs sub-type selection | Ensure correct type is being created |
| `Definition file not found` | Wrong path or file not written | Verify path, re-run Step 2 |
| `Could not set field at row N` | Grid component ID differs | Re-record grid interaction |
| `ERROR: Activation failed - <message>` + `FAILED: <type> <name> was NOT activated.` | DDIC activation ended with status-bar `E`/`A` (missing dependencies, inconsistent definition); the update VBS exits 1 -- it no longer degrades this to a WARNING followed by SUCCESS | Check the SE11 activation log, fix the definition, and re-run |
| `Activation may have errors` | Legacy WARNING wording still emitted by some create-path scripts on status-bar `E` (their post-activate RFC verify supplies the fail-closed gate) | Check SE11 activation log for details |
| `Could not add table/field` | Grid full or component ID mismatch | Scroll grid or re-record IDs |

---

## Step 6b — Change Package Assignment (optional)

Use this step when the user wants to move an SE11 object from `$TMP` (local) to a
real development package. This can be done for any existing SE11 object type.

**Skip this step unless** the user explicitly asks to change the package.

The VBScript template is at `./references/sap_se11_change_package.vbs`.

### Supported object types

| Type code | SE11 object | Radio button ID |
|---|---|---|
| `TABL` | Database table / Structure | `radRSRD1-TBMA` |
| `VIEW` | View | `radRSRD1-VIMA` |
| `DTEL` | Data type (Data element) | `radRSRD1-DDTYPE` |
| `TTYP` | Type Group | `radRSRD1-TYMA` |
| `DOMA` | Domain | `radRSRD1-DOMA` |
| `SHLP` | Search Help | `radRSRD1-SHMA` |
| `ENQU` | Lock Object | `radRSRD1-ENQU` |

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se11_chgpkg_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se11_change_package.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%OBJECT_TYPE%%','THE_OBJECT_TYPE'
$content = $content -replace '%%OBJECT_NAME%%','THE_OBJECT_NAME'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se11_chgpkg_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_OBJECT_TYPE` (one of TABL/VIEW/DTEL/TTYP/DOMA/SHLP/ENQU), `THE_OBJECT_NAME`
(UPPERCASE), `THE_PACKAGE`, `THE_TRANSPORT` (empty string to create a new request), and
`<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se11_chgpkg_run.ps1"
```

### Execute

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo {RUN_TEMP}\sap_se11_chgpkg_run.vbs
```

**On success** (output contains `SUCCESS:`): report the package change to the user.
The VBS gates success on `sbar.MessageType` not `E`/`A` **and** no modal popup
left on screen, then emits `VERIFY_HINT: confirm TADIR-DEVCLASS=<pkg> ...` — the
move is sbar-confirmed only. For an authoritative check, re-query `TADIR`
(`DEVCLASS = <new package>`) via `/sap-se16n` or `/sap-dev-status`.

**On failure** (output contains `ERROR:`): show full output and diagnose:

| Error | Cause | Fix |
|---|---|---|
| `SAP refused the package change: <msg>` | Object locked in a modifiable TR (E071), authorization, or package does not exist | Release the blocking TR via `/sap-se01 release <TR>`, or fix the target package, then re-run. Message text is echoed for diagnostics. |
| `A modal popup is still open after the change` | Unexpected dialog the flow did not anticipate | Re-run; if it persists capture the screen with `/sap-gui-inspect` |
| `Object Directory Entry dialog did not appear` | Object doesn't exist or wrong type | Check object name and type |
| `Cannot find package field` | Dialog layout mismatch | Check component IDs on this SAP version |
| `Unsupported object type` | Invalid type code | Use one of: TABL, VIEW, DTEL, TTYP, DOMA, SHLP, ENQU |

The lock/refusal popup is detected **locale-independently** by DDIC control id
(`txtMESSTXT1` with no `txtKO013-AS4TEXT` and no `btnSPOP-OPTION1`), never by
window title — so it is caught under ZH/JA logons.

### Changing multiple objects

If the user wants to change the package for multiple objects (e.g. a domain, data
element, and table), run this step once for each object. The transport will be reused
across all objects if provided.

---

## Step 6c — Delete Object (optional)

**When to run:** The user wants to delete a DDIC object. Examples:

- "Delete table type `ZCMCT_RFC_PARAM`"
- "Drop structure `ZCMST_RFC_PARAM`"
- "Remove domain `ZDOM_OBSOLETE`"
- "Delete data element `ZDE_TEMP`"

**Deletion is irreversible.** Before generating the VBS, confirm with the
user explicitly: state the object type + name, look up
`TADIR-DEVCLASS` for the locality (transportable vs `$TMP`), and ask
"Are you sure you want to delete this DDIC object? (yes/no)". Do not
proceed without an explicit yes.

The delete VBScript template is at `./references/sap_se11_delete.vbs`.
It works for **all 9 SE11 object types**:

| User-facing OBJECT_TYPE | SE11 radio | Name field |
|---|---|---|
| `TABLE` | `radRSRD1-TBMA` | `ctxtRSRD1-TBMA_VAL` |
| `VIEW` | `radRSRD1-VIMA` | `ctxtRSRD1-VIMA_VAL` |
| `DATAELEMENT` / `STRUCTURE` / `TABLETYPE` | `radRSRD1-DDTYPE` | `ctxtRSRD1-DDTYPE_VAL` |
| `TYPEGROUP` | `radRSRD1-TYMA` | `ctxtRSRD1-TYMA_VAL` |
| `DOMAIN` | `radRSRD1-DOMA` | `ctxtRSRD1-DOMA_VAL` |
| `SEARCHHELP` | `radRSRD1-SHMA` | `ctxtRSRD1-SHMA_VAL` |
| `LOCKOBJECT` | `radRSRD1-ENQU` | `ctxtRSRD1-ENQU_VAL` |

The VBS uses **Shift+F2 (`sendVKey 14`)** from the SE11 initial screen
to trigger Delete, confirms via `wnd[1]/usr/btnSPOP-OPTION1` (Yes), and
handles two follow-on popups: a possible "delete dependent objects"
prompt (also Yes) and the post-delete TR popup (`ctxtKO008-TRKORR`).

### Preconditions

- The object must already exist. If `/sap-se11` Step 4 returned
  `NOT_EXIST`, tell the user and stop — nothing to delete.
- If the object is in a transportable package, resolve a TR via Step 1b
  and pass it as `%%TRANSPORT%%`. SAP's post-delete TR popup needs it.
  If the object is local (`$TMP`) or already locked to a modifiable TR,
  leave it empty — the VBS only aborts if SAP actually prompts.

### Collect Inputs

| Token | Description | Empty? |
|---|---|---|
| `%%OBJECT_TYPE%%` | One of TABLE / VIEW / DATAELEMENT / STRUCTURE / TABLETYPE / TYPEGROUP / DOMAIN / SEARCHHELP / LOCKOBJECT | required |
| `%%OBJECT_NAME%%` | DDIC object name (UPPERCASE) | required |
| `%%TRANSPORT%%` | TR for the post-delete prompt | empty when local or already locked |
| `%%SESSION_LOCK_VBS%%` | path to `sap_session_lock.vbs` | required |

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se11_delete_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se11_delete.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%OBJECT_TYPE%%','THE_OBJECT_TYPE'
$content = $content -replace '%%OBJECT_NAME%%','THE_OBJECT_NAME'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
# Optional ECC6 "Create Object Directory Entry" orphan-fill (default '' =>
# accept pre-filled package / Local Object; /sap-dev-clean passes sap_dev_package).
# THE_OBJDIR_LANG default '' => the VBS uses 'E'.
$content = $content -replace '%%PACKAGE%%','THE_OBJDIR_PACKAGE'
$content = $content -replace '%%ORIG_LANG%%','THE_OBJDIR_LANG'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se11_delete_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_OBJECT_TYPE`, `THE_OBJECT_NAME`, `THE_TRANSPORT`, and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se11_delete_run.ps1"
```

### Execute

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo {RUN_TEMP}\sap_se11_delete_run.vbs
```

### Behaviour Notes

- **Delete is invoked from the SE11 initial screen.** The script does
  NOT open the object editor first; it selects the type radio, fills
  the name field, and sends Shift+F2 directly. (The recording confirms
  this works for table types and other DDIC types.)
- **Confirmation popup.** The VBS confirms via
  `wnd[1]/usr/btnSPOP-OPTION1` (Yes). The other button is `OPTION2` (No).
- **Dependent-object popup.** When SAP shows a second popup asking
  whether to also delete dependent objects (e.g. a table's append
  structures or indexes), the VBS confirms with Yes again.
- **Post-delete TR popup.** For transportable objects, SAP prompts via
  `ctxtKO008-TRKORR`. The VBS fills `%%TRANSPORT%%` and presses Enter.
  If the popup appears with `%%TRANSPORT%%` empty, the VBS exits 1
  with `ERROR: SAP prompted for a transport request but TRANSPORT is
  empty`.
- **Verification.** After the deletion path, the script re-fills the
  name field and presses Display (`btnPUSHSHOW`). If the SE11 editor
  opens (title leaves "Initial Screen" / "ABAP Dictionary"), the
  object still exists and the VBS reports
  `ERROR: Object still exists after delete`.

### TABLE deletion — known limitation

SE11's Shift+F2 deletes the DDIC catalog entry but **may not drop the
underlying database table**. SAP's canonical path for fully removing a
database table is **SE14 (Database Utility)**:

1. SE14 → enter table name
2. Press `Edit`
3. Press `Delete Database Table`

Or run report `RS_DD_TABDEL` via SA38. The delete VBS prints a
`HINT:` line pointing to SE14 if the table-delete leaves the table
in place. Confirm with the operator before falling back to SE14 — that
flow is destructive at the DB layer.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: <TYPE> <NAME> deleted.` | Object is gone — sbar status echoed above. |
| `ERROR: …` | Deletion did not complete — see full output. Common causes: object locked by another user (SM12), supplied TR is released, dependent objects refused deletion, or table needs SE14. |

After success, proceed to Step 7 (cleanup). Skip Step 6 — no
create/update reporting applies.

### Post-delete RFC verification (recommended)

Query the appropriate DDIC catalog via `/sap-se16n` filtered by the
object name; expect zero rows.

| Object type | Catalog table | Key column |
|---|---|---|
| TABLE / STRUCTURE | `DD02L` | `TABNAME` |
| VIEW | `DD25L` | `VIEWNAME` |
| DATAELEMENT | `DD04L` | `ROLLNAME` |
| DOMAIN | `DD01L` | `DOMNAME` |
| TABLETYPE / TYPEGROUP | `DD40L` | `TYPENAME` |
| SEARCHHELP | `DD30L` | `SHLPNAME` |
| LOCKOBJECT | `DD25L` | `VIEWNAME` |

Also check `TADIR` (key: `OBJ_NAME`); a row left there with no
catalog entry indicates a half-deletion and the object directory needs
manual cleanup via SE03.

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {RUN_TEMP}\sap_se11_check_run.vbs & del {RUN_TEMP}\sap_se11_check_run.ps1 & del {RUN_TEMP}\sap_se11_create_run.vbs & del {RUN_TEMP}\sap_se11_create_run.ps1 & del {RUN_TEMP}\sap_se11_update_run.vbs & del {RUN_TEMP}\sap_se11_update_run.ps1 & del {RUN_TEMP}\sap_se11_chgpkg_run.vbs & del {RUN_TEMP}\sap_se11_chgpkg_run.ps1 & del {RUN_TEMP}\sap_se11_delete_run.vbs & del {RUN_TEMP}\sap_se11_delete_run.ps1 & del {RUN_TEMP}\sap_se11_normalize.ps1
```

Also delete `{RUN_TEMP}\<OBJECT_NAME>.def` if the user pasted definition data (not a user-supplied file).

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se11_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se11_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE11_FAILED`, `SE11_INACTIVE`, `SE11_LOCKED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters.
UTF-8 with BOM causes a cscript compile error.

---

## Component ID Note

All component IDs (radio buttons, input fields, grid controls, menu paths) were
recorded on SAP GUI 7.60 / S/4HANA 1909 (Japanese). IDs **may differ** by SAP release
and logon language. If any step fails:

1. Open SE11 in your SAP system
2. Use SAP Logon > Help > Scripting Recorder and Playback
3. Record the failing step manually, stop recording
4. The recorded script shows the correct component IDs

---

## Troubleshooting Component IDs / Stuck Screen

**FIRST RESORT — invoke `/sap-gui-inspect screenshot full`.**

The `screenshot` mode captures every visible window via the SAP GUI
Scripting `HardCopy` API, composes them into one annotated PNG that
mimics the operator's actual screen, and also dumps the topmost window's
component tree. Read the resulting PNG with the Read tool, then decide:

- Unexpected popup → identify the dismiss button visually + the correct
  component ID from the structural dump, then press it.
- Component ID changed between SAP releases → the dump shows the new ID;
  patch the VBS template.
- Field is `Changeable=False` → take a different SAP path (e.g. SE16N's
  AS4TEXT pattern).

**SECOND RESORT — `/sap-gui-inspect tree` (structural only).** Use this if
the screenshot fails (SAP GUI minimised, HardCopy blocked, or you only
need the structural view to confirm one ID). Recommended diagnostic
sequence:

| Step | Mode | Filter | Purpose |
|---|---|---|---|
| 1 | `tree` | (none) | List every open window (`wnd[0]`, `wnd[1]`, …) and their titles — confirms whether an unexpected popup is open |
| 2 | `wnd` | `1` (or `2`) | Full component tree of the unexpected popup — shows its OK/Cancel buttons and any input fields |
| 3 | `id` | `wnd[0]/sbar` | Read the status-bar message (type/id/number/text) when the script appears to do nothing |
| 4 | `type` | `GuiButton` | When you don't know which button to press to dismiss a popup, list every button with text + tooltip |
| 5 | `id` | the failing component path | Inspect `Changeable`, `Required`, `Value` to understand why an assignment fails (e.g. greyed-out field) |

**Last resort (only if `/sap-gui-inspect` cannot help):**
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs
4. Update the VBS template with the corrected IDs

---

## Known Limitation: Field Data Types Are Read-Only via Scripting (Tables AND Structures)

When creating or updating fields in SE11 — for both **tables** and
**structures** — the **DATATYPE** (`txtDD02D-DATATYPE` / `txtDD03D-DATATYPE`)
and **LENGTH** (`txtDD03P-LENG`) columns in the field grid (`tblSAPLSD41TC0`)
have `Changeable=False`. This means you **cannot set field types directly**
(e.g., CHAR, NUMC) via SAP GUI Scripting.

Verified live with `/sap-gui-inspect` on S/4HANA 1909:

- The `cmbDD03P_D-F_REFTYPE[1,row]` combobox accepts `2` (Predefined Type)
  but DD03P-DATATYPE remains `Changeable=False`.
- The "Component Type" toolbar button (`btnCUA_DYNTEXT`) does not unlock it.
- The Edit > Built-In Type menu (`mbar/menu[1]/menu[0]`) is a no-op until
  the row already has a built-in type.

The structure_create / structure_update / table_create VBS templates now
**pre-validate the .def file** and abort with a clear error message if any
non-`.INCLUDE`/`.APPEND` row supplies DATATYPE without DATAELEMENT. The
operator must predefine a data element via `/sap-se11 DATAELEMENT` and
reference it in the DATAELEMENT column. (This catches the bug class
"silent type-drop → activation rejected → SUCCESS still reported".)

**Workaround:** Always use **standard SAP data elements** via the `ctxtDD03D-ROLLNAME`
column instead of specifying DATATYPE and LENGTH directly. Data elements define both
the type and length, and the ROLLNAME column is writable.

Common data elements for custom tables:

| Data Element | Type | Length | Use |
|---|---|---|---|
| `MANDT` | CLNT | 3 | Client field |
| `PROGNAME` | CHAR | 40 | Program name |
| `TEXT40` | CHAR | 40 | Short text |
| `TEXT80` | CHAR | 80 | Medium text |
| `AS4TEXT` | CHAR | 60 | Description text |
| `CHAR1` | CHAR | 1 | Single character |
| `CHAR10` | CHAR | 10 | 10-char field |
| `NUMC4` | NUMC | 4 | 4-digit number |
| `INT4` | INT4 | 10 | Integer |

The current table definition file format uses data elements exclusively:
```
FIELDNAME	KEY	INITIAL	DATAELEMENT	ReferenceTable	Ref.Field
MANDT	X	X	MANDT
MYFIELD			TEXT40
```
(DATATYPE and LENG columns are not needed — they are derived from the data element.)

---

## Known Limitation: Enhancement Category Required for Activation

New tables **require an enhancement category** to be set before activation. Without it,
SAP returns the error: "Enhancement category for table ... missing".

**Handling:** The table create VBS template automatically sets the enhancement category
after filling tech settings, via:
- Menu: **Extras > Enhancement Category** (`wnd[0]/mbar/menu[4]/menu[7]`)
- Select: **Can be enhanced (character-type)** (`radDESED7-R_FLAT`)
- Press Enter to confirm

---

## Definition File Encoding (auto-detected)

Definition files (`.def`) may be written as **UTF-8** (the Write tool /
PowerShell `Set-Content` default), **UTF-8 with BOM**, **UTF-16 LE**, or
**UTF-16 BE**. The VBS templates wrap every read with the inline
`EnsureUnicodeFile` helper, which inspects the file's first two bytes,
returns the original path if it's already UTF-16 LE, and otherwise
re-encodes to a UTF-16 LE temp file before opening. No manual
`-Encoding Unicode` step is required.

```powershell
# Both work — pick whichever is convenient.
Set-Content '{RUN_TEMP}\mytable.def' $content                   # UTF-8 (default)
Set-Content '{RUN_TEMP}\mytable.def' $content -Encoding Unicode # UTF-16 LE
```

---

## Known Limitation: Table Technical Settings Screen (SAPMSEDS1)

The table create template automatically navigates to Technical Settings after the
first save (via `btn[45]`), fills Data Class and Size Category, saves, and returns.
The enhancement category is also set automatically via `menu[4]/menu[7]`.

**Technical Settings field IDs** (on the General Properties tab):

| Field | Component ID |
|---|---|
| Data Class | `ctxtDD09V-TABART` (e.g., `APPL0`) |
| Size Category | `ctxtDD09V-TABKAT` (e.g., `0`) |

**Enhancement category** is set via menu **Extras > Enhancement Category** (`menu[4]/menu[7]`):
- Radio button: `radDESED7-R_FLAT` (Can be enhanced, character-type)

These steps are fully automated in the table create template. No manual intervention needed.

---

## Package Reassignment from $TMP

To move an existing DDIC object from `$TMP` (local) to a transportable package:

1. Open the object in SE11 **change mode** (press Change / `btnPUSHEDIT`)
2. Menu: **Goto > Object Directory Entry** (`wnd[0]/mbar/menu[2]/menu[6]`)
3. In the ODE dialog, change the **Package** field (`ctxtKO007-L_DEVCLASS`) from `$TMP` to the target package
4. Press Enter → the **Transport Request** dialog appears
5. Fill the transport number (auto-filled if the package has an open request) and confirm

**Key fields in the ODE dialog:**

| Field | Component ID |
|---|---|
| Package | `wnd[1]/usr/ctxtKO007-L_DEVCLASS` |
| Person Responsible | `wnd[1]/usr/ctxtKO007-L_AUTHOR` |
| Original System | `wnd[1]/usr/txtKO007-L_SRCSYSTM` |

This works for all SE11 object types (tables, data elements, domains, structures, etc.).

**Limitations:**
- The package field in the ODE dialog must be `Changeable=True` (it is when in change mode)
- If the transport for the target package is already released, the reassignment will fail
- SE03 (Transport Organizer Tools) is an alternative for bulk reassignment

---

## Package/Transport Dialog Field Names

All VBS templates use a single set of field names for the package/transport dialogs:

| Field | Component ID | Location |
|---|---|---|
| Package | `ctxtKO007-L_DEVCLASS` | `wnd[1]/usr/ctxtKO007-L_DEVCLASS` |
| Transport | `ctxtKO008-TRKORR` | `wnd[1]/usr/ctxtKO008-TRKORR` |
| Local Object button | `btn[7]` | `wnd[1]/tbar[0]/btn[7]` |
| Create Request button | `btn[8]` | `wnd[1]/tbar[0]/btn[8]` |
| Transport description | `txtKO013-AS4TEXT` | `wnd[2]/usr/txtKO013-AS4TEXT` |

These IDs are verified on S/4HANA 1909. If they fail on a different SAP version, use the SAP Scripting Recorder to capture the correct IDs.

---

## Known Limitation: SE11 Has No Delete Function for Tables

SE11 does not have a Delete menu item for database tables. Shift+F2 does not work
from the table editor. To delete a table:

- Use **SE14** (Database Utility) > enter table name > press Edit > press "Delete Database Table"
- Or execute ABAP report `RS_DD_TABDEL` via SA38
