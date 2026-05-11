---
name: sap-se21
description: |
  Creates, checks, or deletes SAP development packages via transaction
  SE21 using SAP GUI Scripting (VBS). First verifies package existence
  using RFC_READ_TABLE on TDEVC, then creates it via the live GUI
  session. Delegates transport-request resolution to
  /sap-transport-request — never prompts the user for a TR or calls
  /sap-se01 directly.
  Also supports delete mode: when the user explicitly asks to delete
  a package (e.g. "delete package <X>", "drop package <X>"), navigates
  to SE21, fills the package name, presses Shift+F2 (sendVKey 14)
  from the initial screen, walks the confirmation popup chain, and
  verifies removal. Deletion is irreversible — the skill MUST confirm
  with the user (showing TADIR child count from the existence check)
  before launching the VBS.
  Connection parameters from settings.json (sap-dev-core plugin).
  Prerequisites: SAP GUI installed, SAP GUI Scripting enabled, an active
  logged-in session (run /sap-login first).
argument-hint: "[package-name] [OBJECT_TYPE=PACKAGE OBJECT_DESCRIPTION=<name>] [--delete]"
---

# SAP Package (SE21) Skill

You create or check SAP development packages. First you verify whether the
package already exists via RFC, then drive the live SAP GUI session to create
it through SE21. The transport request is resolved by `/sap-transport-request`
(never asked or created here).

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_se21_create.vbs` | `%%PACKAGE%%`, `%%DESCRIPTION%%`, `%%TRANSPORT%%`, `%%SESSION_LOCK_VBS%%` | GUI-scripting template that drives SE21 to create the package |
| `<SKILL_DIR>/references/sap_check_package.ps1` | `%%PACKAGE%%`, `%%SAP_*%%` | RFC_READ_TABLE check for package existence on TDEVC |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | — | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | — | TR resolution policy implemented by `/sap-transport-request` |

---

## Step 0 — Resolve Work Directory

Read sap-dev-core's settings.json (go 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json`). Read `work_dir`, `custom_url`.

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

Start a structured log run. State file: `{WORK_TEMP}\sap_se21_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se21_run.json" -Skill sap-se21 -ParamsJson "{\"package\":\"<PACKAGE>\"}"
```

---

## Step 1 — Parse Arguments

Extract the **package name** from one of these sources, in priority order:

1. `$ARGUMENTS` — if the user provided a package name directly
2. `$USER_CONFIG.sap_dev_package` — from settings.json
3. Default: `ZCMDEVAI`

**Validation:**
- Package name must start with `Y` or `Z` (customer namespace).
- Convert to uppercase.
- If the name does not start with `Y` or `Z`, tell the user:
  > "Package name must start with Y or Z (customer namespace). Please provide a valid name."
  **Stop here.**

At the end of this step you have the **package name** (uppercase, starts with Y or Z).

---

## Step 2 — Read SAP Connection Parameters

Read SAP connection parameters from `$USER_CONFIG` (settings.json of sap-dev-core):

| Setting key | Maps to | Example |
|---|---|---|
| `sap_application_server` | `%%SAP_APPLICATION_SERVER%%` | `10.0.0.1` |
| `sap_system_number` | `%%SAP_SYSTEM_NUMBER%%` | `00` |
| `sap_client` | `%%SAP_CLIENT%%` | `100` |
| `sap_user` | `%%SAP_USER%%` | `DEVELOPER` |
| `sap_password` | `%%SAP_PASSWORD%%` | *(masked)* |
| `sap_language` | `%%SAP_LANGUAGE%%` | `EN` |

**If settings are not configured**, ask the user to provide the values and suggest
they configure settings.json for future use.

---

## Step 3 — Check If Package Exists

Use RFC_READ_TABLE via the PowerShell template at `<SKILL_DIR>/references/sap_check_package.ps1`.

**Write `{WORK_TEMP}\sap_check_package_run.ps1`:**
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_check_package.ps1', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_APPLICATION_SERVER%%', 'THE_SERVER')
$content = $content.Replace('%%SAP_SYSTEM_NUMBER%%',      'THE_SYSNR')
$content = $content.Replace('%%SAP_CLIENT%%',   'THE_CLIENT')
$content = $content.Replace('%%SAP_USER%%',     'THE_USER')
$content = $content.Replace('%%SAP_PASSWORD%%', 'THE_PASSWORD')
$content = $content.Replace('%%SAP_LANGUAGE%%', 'THE_LANGUAGE')
$content = $content.Replace('%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$content = $content.Replace('%%PACKAGE%%',      'THE_PACKAGE')
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_check_package_filled.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Replace all `THE_*` placeholders and `<SKILL_DIR>` with actual values. Run it:

```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_check_package_run.ps1"
```

Execute via 32-bit PowerShell (SAP NCo 3.1 is registered in the 32-bit GAC):
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_check_package_filled.ps1"
```

**Parse output:**

| Output | Meaning | Action |
|---|---|---|
| `PACKAGE_EXISTS: <name>` | Package already exists in TDEVC | Report: "Package `<name>` already exists." **Done — skip Steps 4-6.** |
| `PACKAGE_NOT_FOUND: <name>` | Package does not exist | Proceed to Step 4. |
| `ERROR: ...` | RFC call failed | Show error, diagnose per table below. **Stop.** |

**Error diagnosis:**

| Error | Cause | Fix |
|---|---|---|
| `NCo 3.1 not found in GAC_32` | SAP NCo 3.1 not installed for .NET 4.0 32-bit | Install SAP NCo 3.1 for .NET 4.0 (32-bit) per SAP Note |
| `RFC connection failed` | Wrong server/credentials | Verify SAP connection details in settings.json |
| `RFC_READ_TABLE call failed` | Authorization or table issue | Check S_RFC authorization for RFC_READ_TABLE |

> **Note:** If SAP password is not configured, you may skip the RFC pre-check
> and rely on SE21's own duplicate-name detection in Step 5 (the GUI script
> will report `Package already exists` via the status bar).

---

## Step 4 — Resolve Transport Request

Invoke `/sap-transport-request` to obtain a modifiable TR according to the
user's `way_to_get_transport_request` policy. **Do NOT ask the user for a TR
or call `/sap-se01` from this skill.** Pass the object context so the
description (if a new TR is created) reflects this package:

```
/sap-transport-request OBJECT_TYPE=PACKAGE OBJECT_DESCRIPTION=<package-name>
```

Capture the resolved TR number (e.g. `S4DK941110`). If `/sap-transport-request`
returns an error or empty value, **stop** — do not attempt to create the
package. A transportable Y/Z package always requires a TR.

---

## Step 5 — Create Package via GUI Scripting

The GUI-scripting template is at `<SKILL_DIR>/references/sap_se21_create.vbs`.
It attaches to the currently logged-in SAP GUI session, navigates to SE21,
fills in the package name + description, and assigns the TR.

**Prerequisite:** The user must already be logged in (run `/sap-login` first).
This script does **not** open a new connection.

**Write `{WORK_TEMP}\sap_se21_run.ps1`:**
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se21_create.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%PACKAGE%%',          'THE_PACKAGE')
$content = $content.Replace('%%DESCRIPTION%%',      'THE_DESCRIPTION')
$content = $content.Replace('%%TRANSPORT%%',        'THE_TRANSPORT')
$content = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_se21_filled.vbs', $content, [System.Text.Encoding]::Unicode)
Write-Host 'Done'
```

The `%%SESSION_LOCK_VBS%%` token is required because `sap_se21_create.vbs`
includes the shared session-lock helpers via `ExecuteGlobal CreateObject(
"Scripting.FileSystemObject").OpenTextFile("%%SESSION_LOCK_VBS%%", 1)
.ReadAll()` near the top. Omit the substitution and the VBS aborts with
"File not found" at the include line before doing anything.

| Token | Value |
|---|---|
| `THE_PACKAGE` | Package name from Step 1 |
| `THE_DESCRIPTION` | Short description (default: `"sap-dev package <name>"`) |
| `THE_TRANSPORT` | TR number from Step 4 |

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se21_run.ps1"
```

Execute via regular cscript (SAP GUI Scripting works in either bitness):
```bash
cscript //NoLogo "{WORK_TEMP}\sap_se21_filled.vbs"
```

---

## Step 6 — Interpret Results

Read the script output line-by-line.

**On success** (output contains `RESULT: PACKAGE_CREATED: <name>`):
- Tell the user: "Package `<name>` created successfully in TR `<TR>`."
- Suggest: "You can now use this package for development objects. Set
  `sap_dev_package` in settings.json to `<name>` for automatic use."

**On failure** (output starts with `ERROR:` or includes `WARN:` for unexpected
final state):

| Error / status-bar message | Cause | Fix |
|---|---|---|
| `SAP GUI is not running` / `No SAP GUI session found` | Not logged in | Run `/sap-login` then retry |
| `Did not reach SE21 initial screen` | Wrong transaction routing | Verify user has S_TCODE auth for SE21 |
| `Description popup field SCOMPKDTLN-CTEXT not found` | Different SAP build (older release uses `PBSRVSCR`; newer uses `PBENSCREEN` / `SCOMPKDTLN`) | Re-record via SAP Logon > Help > Scripting Recorder |
| `TR popup appeared but no TRANSPORT was supplied` | Skill bug — Step 4 was skipped | Run `/sap-transport-request` first |
| sbar `E` "Package already exists" | Race condition with another user | Skip Step 5; report success |
| sbar `E` authorization error | Missing S_DEVELOP for `DEVC` | Grant S_DEVELOP authorisation |

---

## Step 8 — Delete Package (optional, opt-in)

**When to run:** The user explicitly asks to delete a package.
Examples:

- "Delete package `ZHKPKG00001`"
- "Drop package `ZCMPKG018`"
- "Remove development package `Z_OBSOLETE`"

**Deletion is irreversible.** This skill MUST NOT delete a package
without an explicit, deliberate confirmation. The required confirmation
flow is:

1. **Run Step 3 (existence check) first.** The check returns the
   `TDEVC` row + a count of `TADIR` children. If the package does not
   exist, tell the user and stop — nothing to delete.
2. **Show the operator the dependent-object list.** Query `TADIR`
   filtered by `DEVCLASS = <PKG>` and print the rows (one per
   `OBJECT/OBJ_NAME` pair). For more than ~20 children, summarise by
   object type. Anything in this list will block the deletion at SAP's
   side; the operator must move them to a different package first.
3. **Resolve the TR.** Query `TADIR` for
   `PGMID='R3TR' AND OBJECT='DEVC' AND OBJ_NAME=<PKG>`; if `DEVCLASS`
   starts with `$` it's local — TR not needed. Otherwise resolve a
   modifiable TR via `/sap-transport-request`.
4. **Mandatory confirmation prompt:**

   > Deleting development package `<PKG>` is irreversible.
   > Children in TADIR (`<count>`): `<list-or-summary>`.
   > Linked TR (if transportable): `<TR>`.
   > Type **yes** to proceed, anything else to abort.

   Do not launch the VBS without an explicit yes. A reply of "y", "yep",
   "ok", "go", "delete", or anything other than the literal `yes`
   counts as aborted.

### Tokens

| Token | Description | Empty? |
|---|---|---|
| `%%PACKAGE%%` | Package name (UPPERCASE) | required |
| `%%TRANSPORT%%` | TR for the post-delete prompt | empty when local or already locked |
| `%%SESSION_LOCK_VBS%%` | path to `sap_session_lock.vbs` | required |

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se21_delete_run.ps1`:

```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se21_delete.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%PACKAGE%%',         'THE_PACKAGE')
$content  = $content.Replace('%%TRANSPORT%%',       'THE_TRANSPORT')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
Set-Content '{WORK_TEMP}\sap_se21_delete_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```

Run:

```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se21_delete_run.ps1"
cscript //NoLogo "{WORK_TEMP}\sap_se21_delete_run.vbs"
```

### Behaviour Notes

- **Delete is invoked from the SE21 initial screen.** The script does
  NOT open the package editor first — it fills
  `ctxtPBENSCREEN-PACKNAME` and sends Shift+F2 (`sendVKey 14`)
  directly.
- **Confirmation popup style.** The recording uses
  `wnd[1]/usr/btnBUTTON_1` (a generic info-popup button), not the
  Yes/No `btnSPOP-OPTION1`. The VBS tries both, plus
  `tbar[0]/btn[0]` (Continue) and `sendVKey 0` (Enter), via a
  generic active-window walker.
- **Post-delete TR popup.** For transportable packages, SAP prompts
  via `ctxtKO008-TRKORR`. The VBS fills `%%TRANSPORT%%` and presses
  Enter. If the popup appears with `%%TRANSPORT%%` empty, the VBS
  exits 1 with `ERROR: SAP prompted for a transport request but
  TRANSPORT is empty`.
- **Verification.** After the deletion path the script re-fills the
  name field and presses `btnDISPLAY`. If the editor opens (the
  `ctxtPBENSCREEN-PACKNAME` field on the initial screen disappears),
  the package still exists and the VBS reports
  `ERROR: Package still exists after delete` with a hint about
  TADIR children blocking deletion.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Package <PKG> deleted.` | Package is gone — sbar status echoed above. |
| `ERROR: Package still exists after delete (Display opened the editor).` | Most often: package still has TADIR children. Move them to another package and retry. |
| `ERROR: SAP prompted for a transport request but TRANSPORT is empty.` | Transportable package; resolve a modifiable TR via `/sap-transport-request` and re-run. |
| Other `ERROR: …` | Surface verbatim. |

### Post-delete RFC verification (recommended)

Re-run the existence check from Step 3 (`RFC_READ_TABLE` on `TDEVC`);
expect zero rows. Also check `TADIR` (`PGMID='R3TR' AND OBJECT='DEVC'
AND OBJ_NAME=<PKG>`) — a row left there indicates a half-deletion
(TDEVC gone but object directory still references it); clean up via
SE03.

After success, proceed to Step 7 (cleanup). Skip Step 6 — no
create reporting applies.

---

## Step 7 — Clean Up

```bash
cmd /c del "{WORK_TEMP}\sap_check_package_run.ps1" "{WORK_TEMP}\sap_check_package_filled.ps1" "{WORK_TEMP}\sap_se21_run.ps1" "{WORK_TEMP}\sap_se21_filled.vbs" "{WORK_TEMP}\sap_se21_delete_run.vbs" "{WORK_TEMP}\sap_se21_delete_run.ps1"
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se21_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se21_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE21_FAILED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `sap_check_package_filled.ps1` contains the SAP password in
plain text and is deleted after Step 7. The GUI-scripting file
`sap_se21_filled.vbs` does **not** contain a password — it attaches to an
already-logged-in session.

---

## Component IDs (S/4HANA 1909, verified 2026-04-30)

| Screen | Program / Dynpro | Field IDs |
|---|---|---|
| SE21 initial | `SAPLPB_ENTRY` / 100 | `radPBENSCREEN-CHECKPACK`, `ctxtPBENSCREEN-PACKNAME`, `btnCREATE` |
| Description popup (`wnd[1]` "Create Package") | wrapper `SAPLPB_SERVICE` / 170 | `txtSCOMPKDTLN-CTEXT`; toolbar `tbar[0]/btn[0]` (Continue) |
| TR-prompt popup (`wnd[1]` "Prompt for transportable workbench request") | — | `ctxtKO008-TRKORR`; toolbar `tbar[0]/btn[0]` (Continue) |
| Final screen | `SAPLPB_PACKAGE` / 1000 "Change Package" | — |

If component IDs differ on your build, re-record via SAP Logon > Help >
Scripting Recorder and update `sap_se21_create.vbs`.
