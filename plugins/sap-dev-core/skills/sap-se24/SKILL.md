---
name: sap-se24
description: |
  Deploys ABAP class source code to a SAP system via SE24 using
  SAP GUI Scripting. Creates new classes or updates existing ones.
  Existence check (SE24 Display), source upload via
  source-code-based view, save, and activation. Source is the complete
  class definition and implementation (CLASS ... DEFINITION through
  CLASS ... IMPLEMENTATION ... ENDCLASS).
  Also supports check-and-fix mode: when no source file is provided and the
  task is "fix Class" or "check and fix Class", opens the class in SE24,
  runs a syntax check (Ctrl+F2), downloads the source, fixes all errors,
  re-uploads, and activates the class (Ctrl+F3).
  Also supports change-properties mode: when the user asks to change a
  class's Description, Program Status, Category, or other Properties-dialog
  fields, opens SE24 in Display, opens the Properties dialog (Goto >
  Properties), toggles to change mode, updates the supplied fields, then
  Continues + Saves. Handles the conditional original-language popup and
  the post-save Workbench-request popup per `/sap-transport-request`.
  Also supports delete mode: when the user asks to delete a class or
  interface (e.g. "delete class <X>", "drop class <X>", "remove
  interface <X>"), navigates to SE24, fills the class-name field,
  presses Shift+F2 (sendVKey 14) from the initial screen, confirms via
  btnSPOP-OPTION1 (Yes), handles dependent-object and post-delete TR
  popups, and verifies removal via Display. Deletion is irreversible —
  the skill asks for explicit confirmation before running the VBS.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<class-name> [path-to-source]"
---

# SAP SE24 Class Builder Deploy Skill

You deploy ABAP class source code to a live SAP system via SE24
using SAP GUI Scripting. The skill checks if the class
exists, then creates or updates it.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` (Step 1b) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — deployed class/interface source must follow modern syntax, exception-class conventions, no literal MESSAGE strings. Run `/sap-check-abap` before deploy when the source isn't generator-emitted. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/sap_gui_security_handling.md` | SAP GUI Security dialog handling — the check-and-fix **class source download** (Step A) is SAP-GUI-side file IO, so it can raise the modal "SAP GUI Security" dialog (which suspends the Scripting API and hangs cscript). Pre-check + OS-level watcher wrap that download. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_precheck.ps1` | Read-only allow-list pre-check (`saprules.xml`) — `ALLOWED` (exit 0) / `NOT_COVERED` (exit 1). Used by Step A before the source download. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_sidecar.ps1` | OS-level (Win32) watcher that auto-dismisses the SAP GUI Security dialog (ticks Remember + clicks Allow). Launched as a background process before the Step A download. |

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `work_dir`, `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_se24_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se24_run.json" -Skill sap-se24 -ParamsJson "{\"class\":\"<CLASS_NAME>\"}"
```

---

## Step 1 — Collect Parameters

**Class Details**

| Parameter | Description | Example |
|---|---|---|
| Class name | Z/Y namespace, max 30 chars | `ZCL_HK_TEST001` |
| Short description | Short description, max 60 chars (only for new classes) | `My test class` |
| Source | Complete class source: either absolute path to `.abap` file, OR paste the code directly. This is the FULL class including `CLASS ... DEFINITION` and `CLASS ... IMPLEMENTATION` sections. | |
| Package | SAP package (optional, blank = local $TMP) | `ZHKA001` |
| Transport | Transport request (optional; resolved by `/sap-transport-request` per `way_to_get_transport_request` if not supplied) | `S4DK940992` |

**Mode selection:**

| Task | Source provided? | Flow |
|---|---|---|
| Deploy new or updated code | Yes (file path or pasted) | Steps 2 → 3 → 4 → 5a/5b → 6 → 7 |
| Fix / check existing class | No | Steps 3 → A → B → C → 6 → 7 |
| Change class **properties** (Description / Program Status / Category) | No | Steps 1b → 3 → 5d → 6 → 7 |
| **Delete** class or interface | No | Steps 1b → 3 → 5e → 6 → 7 |

If the user says **"fix `<Class>`"**, **"check `<Class>`"**, or **"check and fix `<Class>`"** and provides no source code, skip directly to **Step A**.

If the user says **"change properties of `<Class>`"**, **"set description of `<Class>`"**, **"set program status of `<Class>`"**, or otherwise asks to modify class header attributes (no source involved), skip directly to **Step 5d**.

If the user says **"delete class `<X>`"**, **"drop class `<X>`"**, **"remove class `<X>`"**, or the same phrasing with `interface` instead of `class`, skip directly to **Step 5e**. Deletion is **irreversible** — the skill MUST confirm with the user before running the VBS.

---

## Step 1b — Resolve Transport Request

If `Package` is empty or starts with `$` (e.g. `$TMP`), this is a local
object; **skip this step**.

Otherwise a TR is needed. **Do NOT prompt the user directly and do NOT call
`/sap-se01`.** Delegate to `/sap-transport-request`:

```
/sap-transport-request [<TR-from-args-if-any>] OBJECT_TYPE=CLASS OBJECT_DESCRIPTION=<CLASS_NAME>
```

Use the returned modifiable TRKORR as the `%%TRANSPORT%%` value. If
`/sap-transport-request` reports `ERROR`, stop and surface it to the user.

See `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for the full policy.

---

## Step 2 — Prepare ABAP Source File

**Important:** The source file must contain the COMPLETE class source code including:
- `CLASS <name> DEFINITION PUBLIC ...` through `ENDCLASS.`
- `CLASS <name> IMPLEMENTATION.` through `ENDCLASS.`

Unlike SE37 function modules, SE24 source-code-based view expects the full class
definition and implementation in one file.

**Critical — Encoding:** The ABAP source file MUST be written as UTF-8 **without BOM**.
PowerShell's default `Set-Content -Encoding UTF8` adds a BOM which SAP interprets as
an invalid `#` character, causing "The statement # is unexpected" on activation.

Use this pattern to write BOM-free UTF-8:
```powershell
$content = @"
CLASS zcl_example DEFINITION PUBLIC FINAL CREATE PUBLIC.
  PUBLIC SECTION.
    METHODS get_message RETURNING VALUE(rv_msg) TYPE string.
ENDCLASS.

CLASS zcl_example IMPLEMENTATION.
  METHOD get_message.
    rv_msg = 'Hello from ZCL_EXAMPLE'.
  ENDMETHOD.
ENDCLASS.
"@
[System.IO.File]::WriteAllText("{WORK_TEMP}\zcl_example.abap", $content, (New-Object System.Text.UTF8Encoding $false))
```

**If the user pasted source code directly:**

1. Write the source using the BOM-free method above to: `{WORK_TEMP}\<CLASS_NAME>.abap`
2. Confirm the file by reading back the first 5 lines.

**If the user provided a file path:**

- Use that path as-is. Verify it exists:
  ```bash
  cmd /c if exist "<path>" (echo EXISTS) else (echo NOT FOUND)
  ```
- Verify no BOM:
  ```powershell
  $bytes = [System.IO.File]::ReadAllBytes("<path>"); if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Write-Host "WARNING: File has UTF-8 BOM - rewriting without BOM"; $text = [System.IO.File]::ReadAllText("<path>"); [System.IO.File]::WriteAllText("<path>", $text, (New-Object System.Text.UTF8Encoding $false)) } else { Write-Host "OK: No BOM" }
  ```

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Class Exists

The check VBScript template is at `./references/sap_se24_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se24_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se24_check.vbs' -Raw
$content = $content -replace '%%CLASS_NAME%%','THE_CLASS_NAME'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se24_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_CLASS_NAME` with the actual class name (UPPERCASE) and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se24_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se24_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → class exists → proceed to Step 5a (Update).
- `NOT_EXIST` → class does not exist → proceed to Step 5b (Create), then Step 5a (Update) for source upload.
- `ERROR:` → show full output and stop.

---

## Step 4.5 — Naming Pre-Check

Validate the class name against `sap_object_naming_rules.tsv` (custom override → default) **before** launching any create / update flow:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType GLOBAL_CLASS -ObjectName THE_CLASS_NAME -CustomUrl "{custom_url}"
```

Behaviour:
- Exit `0` → silently continue.
- Exit `1` → show the violation line and ask:
  *"The class name does not match the configured naming rule. Proceed anyway, or abort?"*
  - **Abort** → end the run with `Status SKIPPED`, `ErrorClass OBJECT_NAMING_VIOLATION`.
  - **Proceed** → continue, recording the choice via `sap_log_helper.ps1 -Action step`.
- Exit `2` → log a step note and continue.

Method names inside the class are validated upstream by `/sap-check-abap`
(Step 1.5). The user can customise the rule at
`{custom_url}\sap_object_naming_rules.tsv`.

---

## Step 5a — Update Existing Class (Upload Source)

**Update flow (Original-language popup handling):** Right after pressing
the Change button (`btnPUSH_CHANGE`), if `wnd[1]` is the SAPLSETX
"Different original and logon languages" dialog (fingerprint:
`wnd[1]/usr/ctxtRSETX-MASTERLANG` present), the template presses
`wnd[1]/usr/btnPUSH1` ("Maint. in orig. lang.") — keeps `TADIR-MASTERLANG`
unchanged.

**Update flow (TR popup handling):** The template sends `Ctrl+S` immediately
after entering source-code-based change mode (before uploading source) to
provoke the "Prompt for local Workbench request" popup. If `wnd[1]` shows a
TR field (`ctxtKO008-TRKORR`), the template fills `SAP_TRANSPORT` and Enter,
locking the class to that TR. If no popup appears, the class is local or
already locked to a modifiable TR. If the popup appears but `SAP_TRANSPORT`
is empty, the VBS aborts; the caller must run `/sap-transport-request` first.
Diagnostics: TADIR-DEVCLASS, E071, E070-TRSTATUS.


The update VBScript template is at `./references/sap_se24_update.vbs`.

**Prerequisite:** The class must already be in source-code-based view. If the class
was just created (Step 5b), it will be in form-based view by default. You need to
switch it: open in SE24 Change, go to `Utilities > Settings > Class Builder tab`,
select "Source Code-Based" view, then press Enter. The view setting is remembered
per class.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se24_update_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se24_update.vbs' -Raw
$content = $content -replace '%%CLASS_NAME%%','THE_CLASS_NAME'
$content = $content -replace '%%ABAP_SOURCE_FILE%%','THE_SOURCE_PATH'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se24_update_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_CLASS_NAME` (UPPERCASE), `THE_SOURCE_PATH` (absolute path with backslashes),
`THE_PACKAGE` and `THE_TRANSPORT` (blank if local $TMP), and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se24_update_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se24_update_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Class

If this is a new class, you need a Short Description. Ask the user if not already provided:
> "This is a new class. Please provide a short description."

The create VBScript template is at `./references/sap_se24_create.vbs`.

**Important:** The create script only creates the class shell (name + description).
It does NOT upload source code. After creation, you must:

1. Switch to source-code-based view (see note in Step 5a).
2. Run Step 5a (Update) to upload the actual source.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se24_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se24_create.vbs' -Raw
$content = $content -replace '%%CLASS_NAME%%','THE_CLASS_NAME'
$content = $content -replace '%%CLASS_DESCRIPTION%%','THE_DESCRIPTION'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se24_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace all `THE_*` placeholders (PACKAGE/TRANSPORT blank if local $TMP) and `<SKILL_DIR>`.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se24_create_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se24_create_run.vbs
```

**On success** (output contains `SUCCESS:`):
- Tell user: "Class shell created. Now switching to source-code-based view and uploading source."
- The class will be in form-based view. The user (or a follow-up script) must switch to
  source-code-based view before running the update. See "Source-Code-Based View Setup" below.
- Then proceed to Step 5a (Update) to upload the source.

---

## Source-Code-Based View Setup

SE24 has two editor modes:
- **Form-based view** (default): Tabs for Properties, Interfaces, Methods, etc.
- **Source-code-based view**: Full ABAP editor with Upload/Download capability.

The **source-code-based view is required** for source upload. To switch:

1. Open the class in SE24 Change mode
2. Menu: `Utilities > Settings`
3. In the settings dialog, select "Source Code-Based" under the Class Builder tab
4. Press Enter

The view setting is remembered per class. Once switched, the class always opens
in source-code-based view.

**Note:** For newly created classes, you must manually switch the view before
the update script can upload source. The create script leaves you in form-based view.

---

## Step 5d — Change Class Properties (Description / Program Status / Category)

**When to run:** The user wants to modify a class's Properties-dialog
fields (Description, Program Status, Category, …) **without** uploading
source. Examples:

- "Change the description of `ZCL_IM_ZHK_PO_001` to '…'"
- "Set program status of `ZCL_HK_TEST001` to T (Test Class)"
- "Mark `ZCL_HK_TEST001` as a customer production class"

The change-properties VBScript template is at `./references/sap_se24_change_props.vbs`.

### Collect Inputs

| Token | Description | Allowed values | Empty? |
|---|---|---|---|
| `%%CLASS_NAME%%` | Class name (UPPERCASE) | `ZCL_IM_ZHK_PO_001` | required |
| `%%DESCRIPTION%%` | New description (max 60 chars) | any text | empty = leave unchanged |
| `%%STATUS%%` | `VSEOCLASS-RSTAT` code | `P`=SAP Standard Production, `K`=Customer Production, `S`=System, `T`=Test, `X`=SAP Example | empty = leave unchanged |
| `%%CATEGORY%%` | `VSEOCLASS-CLSCATEG` code | `0`=General object type (other codes per SE24 dropdown) | empty = leave unchanged |
| `%%TRANSPORT%%` | TR for the post-save TR popup | TR number | empty when local (`$TMP`) or already locked to a modifiable TR |

If the class's package is transportable (look up `TADIR-DEVCLASS` for
`R3TR CLAS <class>`; not starting with `$`), resolve a TR via Step 1b and
pass it as `%%TRANSPORT%%`. If the object is local or already locked,
leave it empty — the VBS will only abort if SAP actually prompts.

If only the class name is supplied and all of `DESCRIPTION`, `STATUS`,
`CATEGORY` are empty, ask the user which property to change. Do not run
the VBS with no values (it will exit `DONE: NO_CHANGE`).

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se24_change_props_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se24_change_props.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%CLASS_NAME%%',  'THE_CLASS_NAME')
$content  = $content.Replace('%%DESCRIPTION%%', 'THE_DESCRIPTION')
$content  = $content.Replace('%%STATUS%%',      'THE_STATUS')
$content  = $content.Replace('%%CATEGORY%%',    'THE_CATEGORY')
$content  = $content.Replace('%%TRANSPORT%%',   'THE_TRANSPORT')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se24_change_props_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Use `.Replace()` (literal) — description text may contain regex
metacharacters (e.g. colons, dots). Replace `<SKILL_DIR>` and the
`THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se24_change_props_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se24_change_props_run.vbs
```

### Behaviour Notes

- The Properties dialog is opened by SE24 main menu **Goto > Properties**
  (`wnd[0]/mbar/menu[2]/menu[2]`). It opens as a modal `wnd[1]` rendered
  by program `SAPLSEO_CLASS_EDITOR` subscreen 0152.
- After the dialog opens, it is initially in **display** mode. The VBS
  presses `wnd[1]/tbar[0]/btn[25]` (Display↔Change toggle) to enable
  editing of fields.
- **Original-language popup is conditional.** SAPLSETX
  (`*/usr/ctxtRSETX-MASTERLANG`) only appears when the logon language
  differs from `MASTERLANG`. The VBS checks both `wnd[2]` and `wnd[1]`
  for the popup (the layer it appears on varies by SAP version) and
  presses `btnPUSH1` ("Maint. in orig. lang.") so MASTERLANG is
  preserved. If logon language matches, this popup is silently skipped.
- **Field IDs (subscreen `SAPLSEO_CLASS_EDITOR:0152` under wnd[1]/usr/subDY_0500-SUBSCR):**
  | Field | ID |
  |---|---|
  | Description | `txtVSEOCLASS-DESCRIPT` |
  | Program Status | `cmbVSEOCLASS-RSTAT` (set via `.Key`) |
  | Category | `cmbVSEOCLASS-CLSCATEG` (set via `.Key`) |
  | Continue | `wnd[1]/tbar[0]/btn[0]` |
  | Toggle Display↔Change | `wnd[1]/tbar[0]/btn[25]` |
  | Cancel dialog | `wnd[1]` `sendVKey 12` |
- **Save.** After Continue closes the dialog, the VBS sends Ctrl+S
  (`sendVKey 11`) on `wnd[0]` to commit the change.
- **Post-save TR popup.** If SAP prompts via
  `wnd[1]/usr/ctxtKO008-TRKORR`, the VBS fills `%%TRANSPORT%%` and
  presses Enter. If the popup appears but `%%TRANSPORT%%` is empty, the
  VBS aborts with `ERROR: SAP prompted for a transport request but
  TRANSPORT is empty` — resolve a TR via `/sap-transport-request` and
  re-run.
- **Lock-error popup.** If the class is locked by another modifiable
  task, SAP shows an Error popup (`txtMESSTXT1`/`txtMESSTXT2`
  containing `locked`). The VBS detects this and exits 1 with
  `ERROR: SAP popup [Error] …`.
- **No-change path.** If all of DESCRIPTION / STATUS / CATEGORY are
  empty, the VBS cancels the dialog and exits 0 with `DONE: NO_CHANGE`.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Properties updated for <CLASS>.` | Save succeeded. Status bar message also echoed. |
| `DONE: NO_CHANGE` | No values supplied; dialog cancelled. |
| `ERROR: …` | Couldn't open Properties dialog, invalid value, lock error, or missing TR. Show full output. |

After success, proceed to Step 7 (cleanup). Skip Step 6 — no source/activation
status applies.

---

## Step 5e — Delete Class or Interface

**When to run:** The user wants to delete a class or interface. Examples:

- "Delete class `ZCL_HK_TEST001`"
- "Drop class `ZCL_OBSOLETE`"
- "Remove interface `ZIF_HK_TEMP`"

**Deletion is irreversible.** Before generating the VBS, confirm with
the user explicitly: state the object name, look up `TADIR-DEVCLASS`
for the locality (transportable vs `$TMP`), and ask "Are you sure you
want to delete this class/interface? (yes/no)". Do not proceed without
an explicit yes.

The delete VBScript template is at `./references/sap_se24_delete.vbs`.
SE24 routes both classes and interfaces through the same name field
(`ctxtSEOCLASS-CLSNAME`); SAP picks the object kind from the actual
name, so a single VBS handles both.

### Preconditions

- The class / interface must already exist (run Step 4 check first; if
  `NOT_EXIST`, tell the user and stop — nothing to delete).
- If the object is in a transportable package, resolve a TR via Step 1b
  and pass it as `%%TRANSPORT%%`. SAP's post-delete TR popup needs it.
  If the object is local (`$TMP`) or already locked to a modifiable TR,
  leave it empty — the VBS only aborts if SAP actually prompts.
- Beware of inheritance / friend / interface-implementor relationships:
  deleting a parent class with active children, an interface with active
  implementors, or a friend with active friend-of-classes will fail
  with a SAP error popup. Resolve those dependencies first.

### Collect Inputs

| Token | Description | Empty? |
|---|---|---|
| `%%CLASS_NAME%%` | Class or interface name (UPPERCASE) | required |
| `%%TRANSPORT%%` | TR for the post-delete prompt | empty when local or already locked |
| `%%SESSION_LOCK_VBS%%` | path to `sap_session_lock.vbs` | required |

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se24_delete_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se24_delete.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%CLASS_NAME%%',      'THE_CLASS_NAME')
$content  = $content.Replace('%%TRANSPORT%%',       'THE_TRANSPORT')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se24_delete_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `<SKILL_DIR>` and the `THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se24_delete_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se24_delete_run.vbs
```

### Behaviour Notes

- **Delete is invoked from the SE24 initial screen.** The script does
  NOT open the Class Builder editor first; it fills the class-name
  field (`ctxtSEOCLASS-CLSNAME`) and sends Shift+F2 (`sendVKey 14`)
  directly.
- **Confirmation popup.** The VBS confirms via
  `wnd[1]/usr/btnSPOP-OPTION1` (Yes), with a fallback to `sendVKey 0`
  (Enter) for single-button info dialogs.
- **Dependent-object popup.** When SAP shows a second popup asking
  whether to also delete dependent objects (e.g. test classes inside
  the class include, friend declarations, etc.), the VBS confirms
  again with Yes / Enter.
- **Post-delete TR popup.** For transportable objects, SAP prompts via
  `ctxtKO008-TRKORR`. The VBS fills `%%TRANSPORT%%` and presses Enter.
  If the popup appears with `%%TRANSPORT%%` empty, the VBS exits 1
  with `ERROR: SAP prompted for a transport request but TRANSPORT is
  empty`.
- **Verification.** After the deletion path the script re-fills the
  name field and presses Display (`btnPUSH_DISPLAY`). If the editor
  opens (the class-name field on the initial screen disappears), the
  object still exists and the VBS reports
  `ERROR: Object still exists after delete`.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Class <NAME> deleted.` | Object is gone — sbar status echoed above. |
| `ERROR: …` | Deletion did not complete — see full output. Common causes: object locked by another user (SM12), supplied TR is released, dependent objects (subclasses, implementors, friends) refused deletion, or the operator aborted by pressing No. |

### Post-delete RFC verification (recommended)

Query the SE24 catalog via `/sap-se16n` filtered by `CLSNAME = <NAME>`;
expect zero rows.

| Class kind | Catalog table | Key column |
|---|---|---|
| CLASS / INTERFACE | `SEOCLASS` | `CLSNAME` |
| Class header (DDIC view) | `SEOCLASSDF` | `CLSNAME` |

Also check `TADIR` (`OBJECT IN ('CLAS','INTF') AND OBJ_NAME = <NAME>`);
a row left there with no SEOCLASS entry indicates a half-deletion and
the object directory needs manual cleanup via SE03.

After success, proceed to Step 7 (cleanup). Skip Step 6 — no
create/update reporting applies.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user the class was deployed and activated.
- Show the full script output as a code block.

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `SE24 class name field not found` | Component ID mismatch | Use SAP Scripting Recorder to find correct ID |
| `Create dialog did not appear` | Class already exists or wrong name | Check name or use update flow |
| `Could not open Upload menu` | Menu path differs by SAP version | Use Scripting Recorder to record correct menu path |
| `Upload file dialog did not appear` | SAP GUI Security blocking | Go to SAP Logon > Options > Security > set 'Open file' to Allow |
| `Upload dialog interaction failed` | Upload dialog IDs differ | Re-record the upload step |
| `Upload may have failed` | File not uploaded successfully | Check file path and encoding |
| `Class is in form-based view` | Source-code view required | Switch to source-code-based view (see Source-Code-Based View Setup) |
| `Source file not found` | Wrong path or file not written | Verify path, re-run Step 2 |
| `Could not reach Class Builder editor` | Create dialogs failed | Check SAP status bar for details |
| `Could not open class in change mode` | Class locked or no auth | Check locks (SM12) or authorization |
| `The statement # is unexpected` | ABAP file has UTF-8 BOM | Rewrite file without BOM (see Step 2) |
| `Syntax check found N error(s)` | ABAP syntax errors in source | Show error details (line numbers + messages), fix code and retry |
| `"SECTION" expected, not "SECTION2"` | Typo in class definition section keyword | Fix `protected section2.` → `protected section.` (or similar) |
| `Statement is not accessible` | Class has inactive version, or source file structure is wrong | The VBS templates activate before syntax check to fix inactive versions. If it persists, check source file structure |

---

## Syntax Check Error Grid (SE24)

The SE24 source-code-based editor (AbapEditor) **swallows all status bar messages** —
identical behavior to SE37 and SE38. After syntax check (Ctrl+F2), `wnd[0]/sbar`
returns empty `.MessageType` and `.Text`.

The VBS templates read errors from the error grid instead:
- **Grid path**: `wnd[0]/shellcont/shell/shellcont[1]/shell`
- **Columns**: `MSGTYPE`, `LINE`, `TEXT`
- **Error format**: Pairs of rows — row N has MSGTYPE=`@5C\QError@`, LINE=number, TEXT=class/section name; row N+1 has TEXT=error description
- **No errors**: Grid not found (RowCount throws error 424) = syntax check passed

### Activate-Before-Check Order

The VBS templates activate the class **before** running the syntax check. If a class
has an inactive version, the syntax checker may report false errors — activating first
resolves this (same pattern as SE37/SE38).

### Common Syntax Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| `"SECTION" expected, not "SECTION2"` | Typo in section keyword | Fix `section2` → `section` |
| `Statement is not accessible` | Inactive version or wrong source structure | Ensure source includes full CLASS DEFINITION and IMPLEMENTATION |
| `The last statement is not complete (period missing)` | Missing period | Add `.` to the incomplete statement |
| `"X" is not defined` | Undeclared variable or typo | Add `DATA:` declaration or fix the name |
| `"X" is not a type` | Wrong TYPE in DATA declaration | Check SAP data element spelling in SE11 |
| `Field "X" is unknown` | Wrong structure field name | Check field name against SE11 definition |

---

---

## Step A — Check Syntax and Download Source (Fix Mode)

Use this step when no source file was provided and the task is to check or fix an existing class.

The class must already be in **source-code-based view** in SE24. If it is in form-based view, the VBS will report an error — switch the view first (see Source-Code-Based View Setup).

The check-and-download VBScript template is at `./references/sap_se24_check_and_download.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se24_check_and_download_run.ps1`:
```powershell
$className = 'THE_CLASS_NAME'
$outFile   = 'THE_OUTPUT_FILE'
$skillDir  = 'THE_SKILL_DIR'
$workTemp  = 'THE_WORK_TEMP'

$content = Get-Content "$skillDir\references\sap_se24_check_and_download.vbs" -Raw
$content = $content -replace '%%CLASS_NAME%%',  $className
$content = $content -replace '%%OUTPUT_FILE%%', $outFile
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%',   $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp $workTemp
Set-Content "$workTemp\sap_se24_check_and_download_run.vbs" $content -Encoding Unicode
Write-Host 'Done'
```

| Placeholder | Value |
|---|---|
| `THE_CLASS_NAME` | Class name (UPPERCASE) |
| `THE_OUTPUT_FILE` | `{WORK_TEMP}\<CLASS_NAME>_from_sap.txt` |
| `THE_SKILL_DIR` | Absolute path to this skill directory |
| `THE_WORK_TEMP` | `{WORK_TEMP}` resolved value |

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se24_check_and_download_run.ps1"
```

### Execute (with SAP GUI Security guard)

The check-and-download step makes SAP GUI write the class source to a local
file — **SAP-GUI-side file IO**, so it raises the modal **SAP GUI Security**
dialog when the output path isn't allow-listed (Default Action = Ask), and that
modal suspends the Scripting API, hanging the cscript. Per
`shared/rules/sap_gui_security_handling.md`, pre-check the rules and run the
OS-level watcher around the download. Run as one PowerShell block (the 32-bit
cscript is inside it). Substitute `THE_SID` / `THE_CLIENT` with the pinned
system / client:

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$out    = '{WORK_TEMP}\THE_CLASS_NAME_from_sap.txt'   # the path SAP GUI will write
# 1. Pre-check the allow-list (read-only; informational + lets us skip the watcher).
& "$shared\sap_gui_security_precheck.ps1" -Path $out -Access w -System 'THE_SID' -Client 'THE_CLIENT' -Transaction 'SE24' | Out-Host
$allowed = ($LASTEXITCODE -eq 0)
# 2. If not already allow-listed, launch the OS-level watcher BEFORE the
#    (blocking) download. It detects the #32770 dialog and clicks Remember+Allow,
#    which also persists a rule so subsequent runs pre-check ALLOWED.
$watcher = $null
if (-not $allowed) {
    $watcher = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','40')
    Start-Sleep -Milliseconds 800
}
# 3. Run the check + download (32-bit cscript). If the dialog appears it blocks
#    here until the watcher dismisses it; then the download completes.
& 'C:/Windows/SysWOW64/cscript.exe' //NoLogo '{WORK_TEMP}\sap_se24_check_and_download_run.vbs'
# 4. Reap the watcher.
if ($watcher) { $watcher | Wait-Process -Timeout 45 -ErrorAction SilentlyContinue }
```

**Parse the output:**

| Last output line | Meaning | Next step |
|---|---|---|
| `RESULT: SYNTAX_OK` | No syntax errors | Tell the user — skip to Step 7 |
| `RESULT: SYNTAX_ERRORS` | Errors found (shown above the RESULT line) | Proceed to Step B |
| `ERROR: Class is in form-based view` | Wrong view mode | Switch to source-code-based view in SE24 (see Source-Code-Based View Setup) |
| Other `ERROR:` | Fatal failure | Show full output, stop |

---

## Step B — Analyze and Fix Source

The source was downloaded to `{WORK_TEMP}\<CLASS_NAME>_from_sap.txt` (**UTF-8, no BOM** — SE24 Download menu saves in UTF-8).

**Important — file format:** SE24 Download saves the class in "class pool" format (compact lowercase ABAP OO syntax), not the full `CLASS ... DEFINITION PUBLIC ...` form. This is normal and correct for SE24.

**1. Read the file:**
```powershell
$srcFile = '{WORK_TEMP}\<CLASS_NAME>_from_sap.txt'
$text = [System.IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
Write-Host $text
```
Write this to a `.ps1` file and run it — do not pass inline to `powershell -Command` (quoting issues).

**2. Analyze each error:** Use the line numbers from the Step A output to locate the bad code.

**3. Apply fixes and write fixed file (UTF-8 without BOM):**
```powershell
$srcFile   = '{WORK_TEMP}\<CLASS_NAME>_from_sap.txt'
$fixedFile = '{WORK_TEMP}\<CLASS_NAME>_fixed.txt'
$text = [System.IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
# Apply fixes — example:
$text = $text -replace '(?i)bad_pattern', 'correct_replacement'
# Write as UTF-8 WITHOUT BOM (required by SE24 upload — BOM causes "The statement # is unexpected")
[System.IO.File]::WriteAllText($fixedFile, $text, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Fixed file written: $fixedFile"
```
Write this to a `.ps1` file and run it.

After all fixes are applied, proceed to Step C.

---

## Step C — Re-upload Fixed Source

Run the **Step 5a (Update)** flow with `{WORK_TEMP}\<CLASS_NAME>_fixed.txt` as `THE_SOURCE_PATH`.

The update VBS uploads the fixed source, saves, activates (Ctrl+F3), and runs the syntax check.

| Output | Action |
|---|---|
| `SUCCESS:` | Class is fixed and active — tell the user, proceed to Step 7 |
| `ERROR: Syntax check found` | Errors remain — return to Step B and fix remaining errors |
| Other `ERROR:` | Diagnose using the Step 6 error table |

**Note on encoding for the fixed file:** The fixed file must be **UTF-8 without BOM** (same as what SE24 Download produces). The SE24 update VBS detects SAP codepage (4110 = Unicode) and uploads UTF-8 directly. Do NOT use `Set-Content -Encoding UTF8` or `[System.Text.Encoding]::Unicode` — use `New-Object System.Text.UTF8Encoding $false` to avoid BOM.

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_se24_check_run.vbs & del {WORK_TEMP}\sap_se24_check_run.ps1 & del {WORK_TEMP}\sap_se24_create_run.vbs & del {WORK_TEMP}\sap_se24_create_run.ps1 & del {WORK_TEMP}\sap_se24_update_run.vbs & del {WORK_TEMP}\sap_se24_update_run.ps1 & del {WORK_TEMP}\sap_se24_check_and_download_run.vbs & del {WORK_TEMP}\sap_se24_check_and_download_run.ps1 & del {WORK_TEMP}\sap_se24_change_props_run.vbs & del {WORK_TEMP}\sap_se24_change_props_run.ps1 & del {WORK_TEMP}\sap_se24_delete_run.vbs & del {WORK_TEMP}\sap_se24_delete_run.ps1
```

For fix mode, also delete:
```bash
cmd /c del {WORK_TEMP}\<CLASS_NAME>_from_sap.txt & del {WORK_TEMP}\<CLASS_NAME>_fixed.txt
```

Also delete `{WORK_TEMP}\<CLASS_NAME>.abap` if the user pasted code (not a user-supplied file).

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se24_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se24_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE24_FAILED`, `SE24_INACTIVE`, `SE24_LOCKED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters.

### ABAP Source File Encoding (文字化け Fix)

The VBS update template automatically handles ABAP source file encoding:
- The template detects whether the SAP system is **Unicode** using `oSession.Info.Codepage`
  - **Unicode SAP** (codepage 4110/4103): Upload the UTF-8 file **directly** — no conversion needed
  - **Non-Unicode SAP**: Convert UTF-8 to the Windows system ANSI codepage via ADODB.Stream
- A temp file `<source>.upload.txt` is created (non-Unicode path only) and cleaned up automatically.

When writing ABAP source files, always use **UTF-8 without BOM**:
```powershell
[System.IO.File]::WriteAllText("{WORK_TEMP}\file.abap", $content, (New-Object System.Text.UTF8Encoding $false))
```
Do NOT use `Set-Content -Encoding UTF8` — it adds a BOM that causes SAP activation errors.

---

## Upload Menu Path Note

The source upload menu path varies by SAP version and logon language. The VBS template
tries multiple known paths:

1. `menu[3]/menu[8]/menu[2]/menu[0]` — Utilities > More Utilities > Upload/Download > Upload (S/4HANA source-code view)
2. `menu[3]/menu[9]/menu[2]/menu[0]` — alternate index for "More Utilities"
3. `menu[3]/menu[2]/menu[0]` — Utilities > Upload/Download > Upload (no "More Utilities")

If none work on your system:
1. Open SE24, navigate to a class in source-code-based Change mode
2. Use SAP GUI > More > Script Recording and Playback
3. Record the "Upload from local file" menu action
4. Note the menu path from the recording and update the VBS template

**Note:** Some SAP versions may not expose the Upload/Download menu in SE24's
source-code-based view. In that case, the upload may need to be done differently
(e.g., using the form-based view's import function, or using clipboard paste).

---

## SE24 Component IDs Reference

| Element | Component ID | Notes |
|---|---|---|
| Class name field (initial) | `wnd[0]/usr/ctxtSEOCLASS-CLSNAME` | GuiCTextField |
| Display button | `wnd[0]/usr/btnPUSH_DISPLAY` | |
| Change button | `wnd[0]/usr/btnPUSH_CHANGE` | |
| Create button | `wnd[0]/usr/btnPUSH_CREATE` | |
| Create popup - Description | `wnd[1]/usr/txtVSEOCLASS-DESCRIPT` | |
| Form-based tab strip | `wnd[0]/usr/tabsCTS` | Form-based view indicator |
| Source-code status field | `wnd[0]/usr/txtDY0400_STATUS` | Source-code view indicator |
| Editor shell | `wnd[0]/shellcont/shell/shellcont[0]/shell` | AbapEditor |
| Error grid (syntax check) | `wnd[0]/shellcont/shell/shellcont[1]/shell` | GuiShell (ALV grid) |
| Check (Ctrl+F2) | `wnd[0]/tbar[1]/btn[26]` | sendVKey 26 |
| Activate (Ctrl+F3) | `wnd[0]/tbar[1]/btn[27]` | sendVKey 27 |
| Toggle Form/Source view | `wnd[0]/tbar[1]/btn[22]` | Shift+Ctrl+0 |
| Pretty Printer | `wnd[0]/tbar[1]/btn[13]` | Shift+F1 |

---

## Troubleshooting Component IDs / Stuck Screen

**FIRST RESORT — invoke `/sap-gui-diagnose full`.** Captures every visible
window as one annotated PNG via the SAP GUI Scripting `HardCopy` API, plus
`/sap-gui-object-details` for the topmost window. Read the PNG with the
Read tool to see what's on screen, then decide based on both the visual
and the structural dump.

**SECOND RESORT — `/sap-gui-object-details` alone.** Use this when
`/sap-gui-diagnose` itself fails (SAP GUI minimised, HardCopy blocked) or
when you only need a quick structural confirmation.

When a VBS step fails with `The control could not be found by id`, an unexpected
popup appears, or the script hangs because the screen flow diverged from what was
expected, do NOT guess. Call the `sap-gui-object-details` skill immediately to
discover the actual component layout in the current SAP GUI session, then fix the
VBS or dismiss the popup based on the dump.

Recommended diagnostic sequence:

| Step | Mode | Filter | Purpose |
|---|---|---|---|
| 1 | `tree` | (none) | List every open window (`wnd[0]`, `wnd[1]`, …) and their titles — confirms whether an unexpected popup is open |
| 2 | `wnd` | `1` (or `2`) | Full component tree of the unexpected popup — shows its OK/Cancel buttons and any input fields |
| 3 | `id` | `wnd[0]/sbar` | Read the status-bar message when the script appears to do nothing |
| 4 | `type` | `GuiButton` | When you don't know which button to press to dismiss a popup, list every button with text + tooltip |
| 5 | `id` | the failing component path | Inspect `Changeable`, `Required`, `Value` to understand why an assignment fails |

After the dump, decide:
- Unexpected popup → press its dismiss button (usually `wnd[N]/tbar[0]/btn[12]` for Cancel or `btn[0]` for Continue) and retry.
- Component ID changed between SAP releases → update the VBS template with the discovered ID.
- AbapEditor stuck → use SE24's grid-based syntax-check workaround (see Limitations).

**Last resort (only if `sap-gui-object-details` cannot help):**
1. SAP GUI > More > Script Recording and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs
