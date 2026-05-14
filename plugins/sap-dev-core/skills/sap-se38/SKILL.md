---
name: sap-se38
description: |
  Deploys ABAP source code to a SAP system via SE38 using SAP GUI Scripting.
  Creates new programs or updates existing ones. Includes program
  existence check (SE16N on TRDIR), source upload, syntax check, save, and
  activation. For Report programs (type 1), also updates selection text
  elements after activation. Source can be a file path or pasted ABAP code.
  Also supports check-and-fix mode: when no source file is provided and the
  task is "fix PGM" or "check and fix PGM", opens the program in SE38, runs
  a syntax check (Ctrl+F2), downloads the source, fixes all errors,
  re-uploads, and activates the program (Ctrl+F3).
  Also supports change-attributes mode: when the user asks to change a
  program's Title, Status, Type, or other header attributes (no source
  involved), opens the SE38 Attributes dialog and updates only the supplied
  fields. Handles the SAPLSETX original-language popup (only shown when
  logon language differs from MASTERLANG) and the post-save Workbench
  request popup per `/sap-transport-request`.
  Also supports delete mode: when the user asks to delete a program
  (e.g. "delete program <X>", "drop report <X>", "remove pgm <X>"),
  navigates to SE38, fills the program-name field, presses Shift+F2
  (sendVKey 14) from the initial screen, confirms the deletion popup,
  handles the optional post-delete TR popup, and verifies removal via
  Display. Deletion is irreversible — the skill asks for explicit
  confirmation before running the VBS.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<program-name> [path-to-source]"
---

# SAP SE38 Deploy Skill

You deploy ABAP source code to a live SAP system via SE38 using SAP GUI Scripting.
The skill checks if the program exists, then creates or updates it.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` (Step 1b) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_lib.ps1` | Structured logger. Driven via the shared `sap_log_helper.ps1` wrapper that persists `run_id` between skill steps. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | Shared start/step/end wrapper around `sap_log_lib.ps1`. Persists run state to `{WORK_TEMP}\sap_se38_run.json` so this skill's discrete bash blocks share one logical run. Logging is best-effort and never breaks the skill. |

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

Start a structured log run for this skill invocation. The helper persists
the `run_id` to a state file so subsequent steps and Step 7 can append to
the same run. Logging is best-effort: if `userConfig.log_enabled` is
`false` or the lib can't load, the helper silently no-ops.

State file: `{WORK_TEMP}\sap_se38_run.json`

Build a JSON params object with the values gathered in Step 1 (omit any
that are blank). Always include `program`. Include `mode` (`create` /
`update` / `fix` / `change_attrs`), and optionally `package`, `transport`,
`source_path`. **Never** include passwords or other secrets — the log lib
will mask known-sensitive keys, but don't add them in the first place.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se38_run.json" -Skill sap-se38 -ParamsJson "{\"program\":\"<PROGRAM_NAME>\",\"mode\":\"<MODE>\",\"package\":\"<PACKAGE>\",\"transport\":\"<TRANSPORT>\"}"
```

(Replace `<PACKAGE>` / `<TRANSPORT>` with empty strings if not yet known — 
Step 1b will log the resolved TR separately.)

---

## Step 1 — Collect Parameters

**Program Details**

| Parameter | Description | Example |
|---|---|---|
| Program name | ABAP name (Z/Y namespace, max 40 chars) | `ZMYREPORT` |
| Program type | Type code (only for new programs): `1`=Executable, `I`=Include, `M`=Module Pool, `F`=Function Group, `K`=Class, `S`=Subroutine Pool | `1` |
| Program title | Short description, max 70 chars (only for new programs) | `My Hello World Report` |
| Source | Either: absolute path to an existing `.abap` file, OR paste the ABAP code directly | |
| Package | SAP package for transport (optional; blank = local object $TMP) | `ZHKA001` |
| Transport | Transport request number (optional; resolved by `/sap-transport-request` per `way_to_get_transport_request` if not supplied) | `S4DK940992` |

**Mode selection:**

| Task | Source provided? | Flow |
|---|---|---|
| Deploy new or updated code | Yes (file path or pasted) | Steps 2 → 3 → 4 → 5a/5b → [5c] → 6 → 7 |
| Fix / check existing program | No | Steps 3 → A → B → C → 6 → 7 |
| Change program **attributes** (Title / Status / Type / …) | No | Steps 1b → 3 → 5d → 6 → 7 |
| **Delete** program | No | Steps 1b → 3 → 5e → 6 → 7 |

If the user says **"fix `<PGM>`"**, **"check `<PGM>`"**, or **"check and fix `<PGM>`"** and provides no source code, skip directly to **Step A**.

If the user says **"change attributes of `<PGM>`"**, **"set title/status/type of `<PGM>`"**, or otherwise asks to modify program header fields (no source involved), skip directly to **Step 5d**.

If the user says **"delete program `<PGM>`"**, **"drop report `<PGM>`"**, or **"remove pgm `<PGM>`"**, skip directly to **Step 5e**. Deletion is **irreversible** — the skill MUST confirm with the user before running the VBS.

---

## Step 1b — Resolve Transport Request

If `Package` is empty or starts with `$` (e.g. `$TMP`), this is a local
object; **skip this step** (`%%TRANSPORT%%` will be empty).

Otherwise a TR is needed. **Do NOT prompt the user directly and do NOT call
`/sap-se01`.** Delegate to `/sap-transport-request`:

```
/sap-transport-request [<TR-from-args-if-any>] OBJECT_TYPE=REPORT OBJECT_DESCRIPTION=<PROGRAM_NAME>
```

Use the returned modifiable TRKORR as the `%%TRANSPORT%%` token value in all
subsequent VBS templates. If `/sap-transport-request` reports `ERROR`, stop
and surface it to the user.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action step -StateFile "{WORK_TEMP}\sap_se38_run.json" -Step "transport" -Message "resolved TR=<TRKORR>"
```

If the TR resolution failed, end the log run with FAILED before stopping:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se38_run.json" -Status FAILED -ExitCode 2 -ErrorClass TR_RESOLUTION_FAILED -ErrorMsg "<short error>"
```

See `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for the full policy.

---

## Step 2 — Prepare ABAP Source File

**If the user pasted source code directly:**

1. Write the source to: `{WORK_TEMP}\<PROGRAM_NAME>.abap`
   - Use the Write tool with the exact ABAP source as content.
2. Confirm the file by reading back the first 5 lines.

**If the user provided a file path:**

- Use that path as-is. Verify it exists:
  ```bash
  cmd /c if exist "<path>" (echo EXISTS) else (echo NOT FOUND)
  ```

**Extract Program Name from source if not provided:**

Look for the `REPORT` or `PROGRAM` statement in the first few lines of the ABAP source:
```
REPORT ZMYREPORT.
```
or
```
PROGRAM ZMYREPORT.
```
Use the identifier after `REPORT`/`PROGRAM` as the program name (force UPPERCASE).

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Program Exists

The check VBScript template is at `./references/sap_se38_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se38_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se38_check.vbs' -Raw
$content = $content -replace '%%PROGRAM_NAME%%','THE_PROGRAM_NAME'
# Phase 3.5 session-attach plumbing. SESSION_PATH empty -> attach lib falls
# through to SAPDEV_PIN_FILE -> sole-connection -> refuse. Pass --session
# for explicit targeting in parallel/multi-connection contexts.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se38_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_PROGRAM_NAME` with the actual program name (UPPERCASE) and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se38_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se38_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → program exists → proceed to Step 5a (Update).
- `NOT_EXIST` → program does not exist → proceed to Step 5b (Create).
- `ERROR:` → show full output and stop.

Log the result:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action step -StateFile "{WORK_TEMP}\sap_se38_run.json" -Step "check" -Message "<EXIST|NOT_EXIST>"
```

If the check returned `ERROR:`, end the run with FAILED:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se38_run.json" -Status FAILED -ExitCode 1 -ErrorClass SE38_CHECK_FAILED -ErrorMsg "<short error>"
```

---

## Step 4.5 — Naming Pre-Check

Validate the program name against `sap_object_naming_rules.tsv` (custom override → default) **before** launching any create / update flow:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType PROGRAM -ObjectName THE_PROGRAM_NAME -CustomUrl "{custom_url}"
```

Behaviour:
- Exit `0` (`OK ...`) → silently continue.
- Exit `1` (`VIOLATION ...`) → show the violation line to the user and ask:
  *"The program name does not match the configured naming rule. Proceed anyway, or abort?"*
  - **Abort** → end the run with `Status SKIPPED`, `ErrorClass OBJECT_NAMING_VIOLATION`.
  - **Proceed** → continue (the customer's project may legitimately diverge mid-stream; record the choice via `sap_log_helper.ps1 -Action step`).
- Exit `2` (`UNKNOWN_TYPE` / `RULES_NOT_FOUND`) → log a step note and continue.

To customise the rule, the user edits `{custom_url}\sap_object_naming_rules.tsv`.

---

## Step 5a — Update Existing Program

The update VBScript template is at `./references/sap_se38_update.vbs`.

**Update flow (Original-language popup handling):** The template inspects
`wnd[1]` immediately after pressing the Change button (`btnCHAP`). If the
popup is the SAPLSETX "Different original and logon languages" dialog
(fingerprint: `wnd[1]/usr/ctxtRSETX-MASTERLANG` is present), the template
presses `wnd[1]/usr/btnPUSH1` ("Maint. in orig. lang.") — the safe choice
that lets us edit translations without overwriting `TADIR-MASTERLANG`. This
popup appears when `sap_language` differs from the object's MASTERLANG.

**Update flow (TR popup handling):** The template now sends `Ctrl+S` immediately
after entering change mode (before uploading any source) to provoke the
"Prompt for local Workbench request" popup. If `wnd[1]` shows a TR field
(`ctxtKO008-TRKORR`), the template fills `SAP_TRANSPORT` and presses Enter,
locking the object to that TR. If no popup appears, the object is local
(`$TMP`) or already locked to a modifiable TR — proceed without prompting.
If the popup appears but `SAP_TRANSPORT` is empty, the VBS aborts; the caller
must run `/sap-transport-request` (Step 1b) first. Diagnostics on unexpected
behaviour: query `TADIR` for `DEVCLASS` (starts with `$` → local), `E071`
for object →TR linkage, `E070-TRSTATUS` for TR modifiable state.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se38_update_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se38_update.vbs' -Raw
$content = $content -replace '%%PROGRAM_NAME%%','THE_PROGRAM_NAME'
$content = $content -replace '%%ABAP_SOURCE_FILE%%','THE_SOURCE_PATH'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
$content = $content -replace '%%FOREGROUND_GUARD_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_foreground_guard.ps1'
Set-Content '{WORK_TEMP}\sap_se38_update_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_PROGRAM_NAME` (UPPERCASE), `THE_SOURCE_PATH` (absolute path with backslashes), `THE_PACKAGE` (SAP package or empty string), `THE_TRANSPORT` (transport number or empty string), `<SKILL_DIR>`, and `<SAP_DEV_CORE_SHARED_DIR>` (absolute path to `plugins/sap-dev-core/shared/`).

**Package/Transport behavior:**
- If both `%%PACKAGE%%` and `%%TRANSPORT%%` are non-empty: saves to that package with the transport request
- If either is empty: saves as Local Object ($TMP)

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se38_update_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se38_update_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Program

If this is a new program, you need Program Type and Program Title in addition to
the source file. Ask the user if not already provided:
> "This is a new program. Please provide the program type and title."

Program type codes: `1`=Executable, `I`=Include, `M`=Module Pool, `F`=Function Group, `K`=Class, `S`=Subroutine Pool.

The create VBScript template is at `./references/sap_se38_create.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se38_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se38_create.vbs' -Raw
$content = $content -replace '%%PROGRAM_NAME%%','THE_PROGRAM_NAME'
$content = $content -replace '%%PROGRAM_TYPE%%','THE_PROGRAM_TYPE'
$content = $content -replace '%%PROGRAM_TITLE%%','THE_PROGRAM_TITLE'
$content = $content -replace '%%ABAP_SOURCE_FILE%%','THE_SOURCE_PATH'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
$content = $content -replace '%%FOREGROUND_GUARD_PS1%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_foreground_guard.ps1'
Set-Content '{WORK_TEMP}\sap_se38_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`. `THE_PACKAGE` and `THE_TRANSPORT` follow the same rules as Step 5a.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se38_create_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se38_create_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5c — Update Text Elements (Report Programs Only)

**When to run:** After successful activation (Step 5a or 5b), if the program type is `1`
(Executable Report / 螳溯｡悟庄閭ｽ繝励Ο繧ｰ繝ｩ繝) AND the ABAP source contains `PARAMETERS` or
`SELECT-OPTIONS` statements with Japanese selection texts to set.

**Skip this step** if:
- Program type is not `1` (Include, Module Pool, etc.)
- No `PARAMETERS` / `SELECT-OPTIONS` AND no `TEXT-NNN` references AND no sibling `.text_elements.txt` file

### Source 1 (preferred) — read `<PROGRAM_NAME>.text_elements.txt`

`/sap-gen-abap` emits this sibling file alongside the `.abap` source per
`abap_code_quality_rules.md` §21. Format (tab-separated, two blocks):

```
[SELECTION_TEXTS]
P_BUKRS	Company Code
P_WERKS	Plant
P_MATNR	Material
P_FILE	Input file path

[TEXT_SYMBOLS]
001	Selection
002	Result Output
T01	Seq
T02	Type
```

When converting to the VBS tokens:

- `[SELECTION_TEXTS]` → `%%SELECTION_TEXTS%%`: each line `<PARAM>\t<text>`
  becomes `PARAM=text`, joined with `|`.
- `[TEXT_SYMBOLS]` → `%%TEXT_SYMBOLS%%`: each line `<NNN>\t<text>` becomes
  `NNN=text`, joined with `|`. Symbol IDs may be all-digit or mixed
  (`T01`, `S01`); SAP T100A is CHAR3.

When the sibling file exists, USE IT as the canonical source — do NOT
extract from inline comments. The sibling file already covers both
Selection Texts and Text Symbols; the VBS now applies both in one save.

### Source 2 (fallback) — extract Selection Texts from the ABAP source

Used only when no `.text_elements.txt` sibling exists. Walk the ABAP
source for every `PARAMETERS:` / `SELECT-OPTIONS:` line, build the
`PARAM=text` pairs from inline comments or the design doc. Set
`%%TEXT_SYMBOLS%%` to empty in this case.

### Collect Selection Texts (legacy path — used only by Source 2)

Extract selection text definitions from the ABAP source or design document:
- Each PARAMETERS/SELECT-OPTIONS field can have a descriptive text
- Format: `PARAM_NAME=Selection Text` separated by `|`
- Example: `P_BUKRS=莨夂､ｾ繧ｳ繝ｼ繝榎P_WERKS=繝励Λ繝ｳ繝・P_MATNR=蜩∫岼繧ｳ繝ｼ繝榎P_FILE=繝輔ぃ繧､繝ｫ`

**Parameter name rules:**
- Use the ABAP parameter name as declared (e.g., `P_BUKRS`, `S_MATNR`)
- UPPERCASE
- For SELECT-OPTIONS, the param name in the text table shows without the `S_` being changed

The text element VBScript template is at `./references/sap_se38_text_elements.vbs`.

### Generate the filled-in VBScript

Write the selection texts to a separate UTF-8 file first (avoids encoding issues when the
PowerShell script itself contains multibyte characters like Japanese):

Write `{WORK_TEMP}\sap_se38_textelm_seltexts.txt` with just the pipe-delimited selection texts:
```
PARAM1=Text1|PARAM2=Text2
```

If the source `.text_elements.txt` had a `[TEXT_SYMBOLS]` block, also write
`{WORK_TEMP}\sap_se38_textelm_symbols.txt` with the pipe-delimited symbols:
```
001=Selection|002=Result Output|T01=Seq
```

The symbols file is OPTIONAL — when absent, the VBS still applies Selection
Texts as before. Both files use UTF-8 (no BOM).

Write `{WORK_TEMP}\sap_se38_textelm_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se38_text_elements.vbs', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%PROGRAM_NAME%%','THE_PROGRAM_NAME')
$selTexts = [System.IO.File]::ReadAllText('{WORK_TEMP}\sap_se38_textelm_seltexts.txt', [System.Text.Encoding]::UTF8).Trim()
$content = $content.Replace('%%SELECTION_TEXTS%%', $selTexts)
$txtSyms = ''
if (Test-Path '{WORK_TEMP}\sap_se38_textelm_symbols.txt') {
    $txtSyms = [System.IO.File]::ReadAllText('{WORK_TEMP}\sap_se38_textelm_symbols.txt', [System.Text.Encoding]::UTF8).Trim()
}
$content = $content.Replace('%%TEXT_SYMBOLS%%', $txtSyms)
$content = $content.Replace('%%PACKAGE%%','THE_PACKAGE')
$content = $content.Replace('%%TRANSPORT%%','THE_TRANSPORT')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_se38_textelm_run.vbs', $content, [System.Text.Encoding]::Unicode)
Write-Host 'Done'
```
Replace `THE_PROGRAM_NAME` (UPPERCASE), `THE_PACKAGE`, `THE_TRANSPORT`, and `<SKILL_DIR>`.

**Important:**
- Use `.Replace()` method (not `-replace` operator) because `|` is a regex metacharacter.
- The selection texts **must** be in a separate text file (written by the Write tool as UTF-8).
  Embedding multibyte characters directly in the `.ps1` script causes encoding corruption.
- Use `[System.IO.File]::ReadAllText/WriteAllText` with explicit encoding — `Get-Content -Raw`
  + `Set-Content -Encoding Unicode` double-encodes the file.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se38_textelm_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se38_textelm_run.vbs
```

**On success** (output contains `SUCCESS:`): proceed to Step 6. The VBS template now handles
activation internally — after saving, it re-enters Change mode, navigates to the Selection Texts
tab, and presses Activate (Ctrl+F3), including SAPLSPO1 worklist handling.
**On failure** (output contains `ERROR:`): show full output and diagnose.

### Text Elements Activation (Handled by VBS Template)

Text elements are a **separate object** from the source code. After saving selection texts
via the VBS template, they exist as an **inactive version**. Without activation, the SAP
runtime shows an "Inactive objects exist" dialog every time the program is executed via F8.

**The VBS template now handles activation automatically** by:
1. Saving the text elements (Ctrl+S)
2. Re-navigating to SE38 > Text Elements > Change > Selection Texts tab
3. Pressing Activate (Ctrl+F3 = `tbar[1]/btn[27]`)
4. Handling SAPLSPO1 activation worklist (Select All F9 + Enter)

This resolves the issue where text elements remained "Inactive" after save because the
screen reverted to Display mode and the Activate button was disabled.

**Why separate activation is needed:**
- The VBS template saves text elements (Step 5c) but does NOT activate them
- Source code activation (Step 5a/5b) does NOT activate text elements
- Text elements must be activated via the text elements editor's own Activate button

**VBS activation sequence:**
```vbs
' Navigate to SE38 > Text Elements > Change > Selection Texts tab
oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE38"
oSession.findById("wnd[0]").sendVKey 0
oSession.findById("wnd[0]/usr/ctxtRS38M-PROGRAMM").Text = "PROGRAM_NAME"
oSession.findById("wnd[0]/usr/radRS38M-FUNC_TEXT").select
oSession.findById("wnd[0]/usr/btnCHAP").press
WScript.Sleep 2000
oSession.findById("wnd[0]/usr/tabsTX_TABSTR_CONTROL/tabpSSSS").select
WScript.Sleep 1000

' Press Activate (Ctrl+F3) = tbar[1]/btn[27]
oSession.findById("wnd[0]/tbar[1]/btn[27]").press
WScript.Sleep 4000

' Handle activation worklist (appears as wnd[1] with ALV grid)
' Must Select All (F9) then Continue (Enter)
Dim oW1
Set oW1 = oSession.findById("wnd[1]")
If Not oW1 Is Nothing Then
    oW1.sendVKey 9      ' F9 = Select All
    WScript.Sleep 500
    oW1.sendVKey 0      ' Enter = Continue/Activate
    WScript.Sleep 5000
End If
' Handle any post-activation dialog
Set oW1 = oSession.findById("wnd[1]")
If Not oW1 Is Nothing Then oW1.sendVKey 0
```

**Worklist buttons (wnd[1]):**
| Button | VKey | Action |
|---|---|---|
| `tbar[0]/btn[0]` | Enter (0) | Continue — activate selected objects |
| `tbar[0]/btn[9]` | F9 (9) | Select All — check all objects in the list |
| `tbar[0]/btn[12]` | F12 (12) | Cancel |

**ALV grid path:** `wnd[1]/usr/cntlGRID1/shellcont/shell`
(Note: grid RowCount/ColumnCount may appear empty via cscript — use sendVKey instead of grid API)

**Status bar after successful activation:** `Active object generated`
(May be empty due to AbapEditor status bar swallowing — see Known Limitations)

**Alternative: `%_xxx_%_app_%-text` in INITIALIZATION (no activation needed)**

If text element activation proves problematic, selection texts can be set via code:
```abap
INITIALIZATION.
  %_p_bukrs_%_app_%-text = '莨夂､ｾ繧ｳ繝ｼ繝・.
  %_rb_up_%_app_%-text   = '繧｢繝・・繝ｭ繝ｼ繝・.
```
These dynpro text variables (`%_<param>_%_app_%-text`) override selection texts at runtime.
Frame titles use `FRAME TITLE gv_xxx` + `gv_xxx = '...'` in INITIALIZATION (auto-declared).

### Text Elements Table Structure

The SE38 text elements screen uses tab control `tabsTX_TABSTR_CONTROL`:
- **Text Symbols tab** (`tabpSSST`) — `TEXT-001`, `TEXT-002`, etc.
- **Selection Texts tab** (`tabpSSSS`) — selection screen parameter texts

Selection texts table (`tblSAPLSETXPSELPAR`) columns:
| Column | ID pattern | Description |
|---|---|---|
| Parameter name | `txtRS38M-STEXTI[0,row]` | Read-only, shows ABAP param name |
| Selection text | `txtRS38M-STEXTT[1,row]` | Editable text field |
| Dict. reference | `chkRS38M-STEXTA[2,row]` | Checkbox for data element text |

**Note:** Row indices are 0-based and relative to the visible viewport. If there are
more parameters than visible rows, the template scrolls using `VerticalScrollbar.Position`.

---

## Step 5d — Change Program Attributes (Title / Status / Type)

**When to run:** The user wants to modify a program's header attributes
(Title, Status, Type, …) **without** uploading source. Examples:

- "Change the title of `ZHKTEST003` to '…'"
- "Set status of `ZMYREPORT` to K (Customer Production)"
- "Change `ZMYREPORT` type to Module Pool"

The change-attributes VBScript template is at `./references/sap_se38_change_attrs.vbs`.

### Collect Inputs

| Token | Description | Allowed values | Empty? |
|---|---|---|---|
| `%%PROGRAM_NAME%%` | Program (UPPERCASE) | `ZMYREPORT` | required |
| `%%TITLE%%` | New title (max 70 chars) | any text | empty = leave unchanged |
| `%%STATUS%%` | `TRDIR-RSTAT` code | `P`=SAP Standard, `K`=Customer Production, `S`=System, `T`=Test, `X`=SAP Example | empty = leave unchanged |
| `%%TYPE%%` | `TRDIR-SUBC` code | `1`=Executable, `I`=Include, `M`=Module Pool, `F`=Function Group, `K`=Class, `S`=Subroutine Pool, `J`=Interface Pool | empty = leave unchanged |
| `%%TRANSPORT%%` | TR for the post-save popup | TR number | empty when local (`$TMP`) or already locked to a modifiable TR |

If `Package` (look up in `TADIR-DEVCLASS`) is transportable (does not start
with `$`), resolve a TR via Step 1b before generating the VBS. Pass the
returned TRKORR as `%%TRANSPORT%%`. If the object is local or already
locked to an open TR, `%%TRANSPORT%%` may be empty — the VBS will only
abort if SAP actually prompts.

If only the program name is supplied and all three of `TITLE`, `STATUS`,
`TYPE` are empty, ask the user which attribute to change. Do not run the
VBS with no values (it will exit `DONE: NO_CHANGE`).

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se38_change_attrs_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se38_change_attrs.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%PROGRAM_NAME%%','THE_PROGRAM_NAME')
$content  = $content.Replace('%%TITLE%%',       'THE_TITLE')
$content  = $content.Replace('%%STATUS%%',      'THE_STATUS')
$content  = $content.Replace('%%TYPE%%',        'THE_TYPE')
$content  = $content.Replace('%%TRANSPORT%%',   'THE_TRANSPORT')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se38_change_attrs_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Use `.Replace()` (literal) — title/status texts may contain regex
metacharacters. Replace `<SKILL_DIR>` and the `THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se38_change_attrs_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se38_change_attrs_run.vbs
```

### Behaviour Notes

- The Attributes screen is opened by selecting the **Attributes** radio
  (`radRS38M-FUNC_HEAD`) on the SE38 initial screen, then pressing
  **Change** (`btnCHAP`). This opens a modal dialog (`wnd[1]`) with the
  attribute fields.
- **Original-language popup is conditional.** SAPLSETX
  ("Different original and logon languages", fingerprint
  `wnd[1]/usr/ctxtRSETX-MASTERLANG`) only appears when the logon language
  differs from the program's `TADIR-MASTERLANG`. The VBS detects it by
  fingerprint and presses `wnd[1]/usr/btnPUSH1`
  ("Maint. in orig. lang.") so `MASTERLANG` is preserved. If logon
  language matches `MASTERLANG`, this popup is silently skipped.
- **Field IDs in the Attributes dialog (wnd[1]):**
  | Field | ID |
  |---|---|
  | Title | `wnd[1]/usr/txtRS38M-REPTI` |
  | Status | `wnd[1]/usr/cmbTRDIR-RSTAT` (set via `.Key`) |
  | Type | `wnd[1]/usr/cmbTRDIR-SUBC` (set via `.Key`) |
  | Save | `wnd[1]/tbar[0]/btn[0]` |
  | Cancel | `wnd[1]` `sendVKey 12` |
- **Post-save TR popup.** After Save, SAP may prompt for a Workbench
  request via `wnd[1]/usr/ctxtKO008-TRKORR`. The VBS fills it with
  `%%TRANSPORT%%` and presses Enter. If the popup appears but
  `%%TRANSPORT%%` is empty, the VBS aborts with `ERROR: SAP prompted for
  a transport request but TRANSPORT is empty` — resolve a TR via
  `/sap-transport-request` and re-run.
- **Lock-error popup.** If the object is locked by another modifiable
  task, SAP shows an Error popup (`txtMESSTXT1`/`txtMESSTXT2` containing
  `locked`). The VBS detects this and exits 1 with
  `ERROR: SAP popup [Error] …`.
- **No-change path.** If all of TITLE / STATUS / TYPE are empty, the VBS
  cancels the dialog and exits 0 with `DONE: NO_CHANGE`.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Attributes updated for <PGM>.` | Save succeeded. Status bar message also echoed. |
| `DONE: NO_CHANGE` | No values supplied; dialog cancelled. |
| `ERROR: …` | Dialog couldn't open, invalid status/type code, lock error, or missing TR. Show full output. |

After success, proceed to Step 7 (cleanup). Skip Step 6 — no source-code
status table applies.

---

## Step 5e — Delete Program

**When to run:** The user wants to delete a program. Examples:

- "Delete program `ZHKCM008R01`"
- "Drop report `ZMYREPORT`"
- "Remove pgm `Z_OBSOLETE`"

**Deletion is irreversible.** Before generating the VBS, confirm with the
user explicitly: state the program name, look up `TADIR-DEVCLASS` for
the locality (transportable vs `$TMP`), and ask "Are you sure you want
to delete this program? (yes/no)". Do not proceed without an explicit
yes.

The delete VBScript template is at `./references/sap_se38_delete.vbs`.

### Preconditions

- The program must already exist (run Step 4 check first; if `NOT_EXIST`,
  tell the user and stop — nothing to delete).
- If the program is in a transportable package, resolve a TR via Step 1b
  and pass it as `%%TRANSPORT%%`. SAP's post-delete TR popup needs it.
  If the program is local (`$TMP`) or already locked to a modifiable TR,
  leave it empty — the VBS only aborts if SAP actually prompts.

### Collect Inputs

| Token | Description | Empty? |
|---|---|---|
| `%%PROGRAM_NAME%%` | Program name (UPPERCASE) | required |
| `%%TRANSPORT%%` | TR for the post-delete prompt | empty when local or already locked |
| `%%SESSION_LOCK_VBS%%` | path to `sap_session_lock.vbs` | required |

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se38_delete_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se38_delete.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%PROGRAM_NAME%%',    'THE_PROGRAM_NAME')
$content  = $content.Replace('%%TRANSPORT%%',       'THE_TRANSPORT')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
Set-Content '{WORK_TEMP}\sap_se38_delete_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `<SKILL_DIR>` and the `THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se38_delete_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se38_delete_run.vbs
```

### Behaviour Notes

- **Delete is invoked from the SE38 initial screen.** The script does
  NOT open the program editor first; it fills the program-name field
  (`ctxtRS38M-PROGRAMM`) and sends Shift+F2 (`sendVKey 14`) directly.
- **Generic popup walker.** After Delete, the VBS loops on
  `oSession.ActiveWindow` (up to 8 iterations) and dispatches each
  modal by component ID — handles any combination of confirmation
  popups, dependent-object lists, and post-delete TR prompts in any
  order. For each popup it tries (in order):
  1. `<wnd>/usr/ctxtKO008-TRKORR` — fill `%%TRANSPORT%%` + Enter.
     If `%%TRANSPORT%%` is empty, abort with
     `ERROR: SAP prompted for a transport request but TRANSPORT is empty`.
  2. `<wnd>/usr/btnSPOP-OPTION1` (Yes) — for Yes/No SPOPs.
  3. `<wnd>/tbar[0]/btn[0]` (Continue) — for SAP info-style popups
     with a Continue button on the popup's own toolbar (this is what
     function-group deletion uses; the recording shows
     `wnd[1]/tbar[0]/btn[0]` then `wnd[2]/tbar[0]/btn[0]`).
  4. `sendVKey 0` (Enter) on the active window — last resort.
- **Function-group main programs.** The program name `SAPL<FUGR>` is
  the function group's main include — deleting it removes the entire
  function group (all FMs, screens, GUI statuses, etc.). The recording
  for this case shows two stacked popups (`wnd[1]` listing dependents
  while `wnd[2]` asks for confirmation); the popup walker handles both
  via `tbar[0]/btn[0]`. See `/sap-function-group` Step 3e for the FG-delete
  entry point that calls this skill with `SAPL<FUGR>`.
- **Verification.** After deletion the script re-fills the program
  name and presses Display (`btnSHOP`). If the editor opens (the
  program-name field on the initial screen disappears), the program
  still exists and the VBS reports `ERROR: Program still exists after
  delete`.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Program <NAME> deleted.` | Program is gone — sbar status echoed above. |
| `ERROR: …` | Deletion did not complete — see full output. Common causes: program locked by another user (SM12), supplied TR is released, dependent objects refused deletion, or the operator aborted by pressing No. |

### Post-delete RFC verification (recommended)

Query `TRDIR` via `/sap-se16n` filtered by `NAME = <PGM>`; expect zero
rows. Also check `TADIR` (`OBJECT = 'PROG' AND OBJ_NAME = <PGM>`); a
row left there with no TRDIR entry indicates a half-deletion and the
object directory needs manual cleanup via SE03.

After success, proceed to Step 7 (cleanup). Skip Step 6 — no
create/update reporting applies.

---

## Step 6 — Report Result

The create / update VBS emits **three parseable lines** in addition to the
human-readable `INFO:` / `ERROR:` echoes. Callers should rely on these
lines, not on substring-grepping the per-finding text:

| Line | Meaning |
|---|---|
| `SYNTAX_ERRORS: <N>` | Count of real syntax errors found after Ctrl+F2 (excludes warnings). Always emitted. `0` = clean. |
| `SUCCESS: Program <NAME> created and activated in SAP.` (or `updated and activated`) | Final SUCCESS — emitted ONLY when post-activation verification reached an active SE38 screen (1000/120/200). Followed by `WScript.Quit 0`. |
| `ERROR: activation_uncertain — …` | The paste pipeline didn't error but verification didn't reach an active screen. Followed by `WScript.Quit 1`. The program is likely still INACTIVE — recovery: open SE38 manually + `/sap-activate-object`. |

**Important — never trust just the final SUCCESS line.** Earlier versions
of these scripts (pre-2026-05) printed `SUCCESS:` even when activation
verification emitted an "Unexpected screen" warning. The scripts now
fail-closed: anything other than a recognised-active verification screen
exits 1 with `ERROR: activation_uncertain`. Callers that pre-date this
fix should be updated to gate on the exit code, not on parsing the
SUCCESS line.

**On success** (output contains `SUCCESS:` AND exit code 0):
- Tell the user the program was deployed and activated.
- Show the full script output as a code block.
- Log the SUCCESS end record:
  ```bash
  powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se38_run.json" -Status SUCCESS -ExitCode 0
  ```

**On failure** (output contains `ERROR:` OR `SYNTAX_ERRORS:` > 0 OR exit code non-zero):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `SE38 program name field not found` | Component ID mismatch | Use SAP Scripting Recorder to find correct ID |
| `Could not open Upload menu` | Menu path differs by SAP version | Use Scripting Recorder to record correct menu path |
| `Upload dialog interaction failed` | Upload dialog IDs differ | Re-record the upload step |
| `Syntax check failed` / `SYNTAX_ERRORS: <N>` (N > 0) | ABAP syntax errors | Show error message, ask user to fix code |
| `Source file not found` | Wrong path or file not written | Verify path, re-run Step 2 |
| `Could not reach ABAP source editor` | Create dialogs failed | Check SAP status bar for details |
| `Could not open program in change mode` | Program locked or no auth | Check locks (SM12) or authorization |
| `Program is still INACTIVE` | Activation silently failed | Check SE38 manually; AbapEditor may have swallowed the error. Common causes: missing dictionary types, missing message class, syntax errors in local classes |
| `ERROR: activation_uncertain` | Post-activation verification did not reach an active SE38 screen (1000/120/200) | Open SE38 for the program manually, inspect the activation log, then run `/sap-activate-object PROGRAM <NAME>` |
| `Status bar empty (AbapEditor swallows messages)` | Front-end editor limitation | This is expected behavior; activation is verified by test-executing the program |

Log the FAILED end record (pick `ErrorClass` from the matched row, e.g.
`SE38_SYNTAX`, `SE38_INACTIVE`, `SE38_UPLOAD`, `SE38_LOCKED`, `SE38_AUTH`,
`SE38_GENERIC`):
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se38_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<one-line message from script output>"
```

---

---

## Step A — Check Syntax and Download Source (Fix Mode)

Use this step when no source file was provided and the task is to check or fix an existing program.

The check-and-download VBScript template is at `./references/sap_se38_check_and_download.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se38_check_and_download_run.ps1`:
```powershell
$pgmName  = 'THE_PROGRAM_NAME'
$outFile  = 'THE_OUTPUT_FILE'
$skillDir = 'THE_SKILL_DIR'
$workTemp = 'THE_WORK_TEMP'

$content = Get-Content "$skillDir\references\sap_se38_check_and_download.vbs" -Raw
$content = $content -replace '%%PROGRAM_NAME%%', $pgmName
$content = $content -replace '%%OUTPUT_FILE%%',  $outFile
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%',   $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = "$workTemp\sap_active_session.json"
Set-Content "$workTemp\sap_se38_check_and_download_run.vbs" $content -Encoding Unicode
Write-Host 'Done'
```

| Placeholder | Value |
|---|---|
| `THE_PROGRAM_NAME` | Program name (UPPERCASE) |
| `THE_OUTPUT_FILE` | `{WORK_TEMP}\<PROGRAM_NAME>_from_sap.txt` |
| `THE_SKILL_DIR` | Absolute path to this skill directory |
| `THE_WORK_TEMP` | `{WORK_TEMP}` resolved value |

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se38_check_and_download_run.ps1"
```

### Execute
```bash
powershell -Command "& 'C:\Windows\SysWOW64\cscript.exe' //NoLogo '{WORK_TEMP}\sap_se38_check_and_download_run.vbs' 2>&1"
```

**Parse the output:**

| Last output line | Meaning | Next step |
|---|---|---|
| `RESULT: SYNTAX_OK` | No syntax errors | Tell the user — skip to Step 7 |
| `RESULT: SYNTAX_ERRORS` | Errors found (shown above the RESULT line) | Proceed to Step B |
| `ERROR:` | Fatal failure | Show full output, stop |

---

## Step B — Analyze and Fix Source

The source was downloaded to `{WORK_TEMP}\<PROGRAM_NAME>_from_sap.txt` (UTF-16 LE).

> **CAVEAT — `_from_sap.txt` may differ structurally from the disk source.**
> The download uses `AbapEditor.GetLineText(i)` which reads what the editor
> *displays*, not what is stored. SAP applies pretty-printer formatting
> between storage and display. Verified divergence: TYPES declared inside
> a local class PUBLIC SECTION can appear at PROGRAM scope in the
> `_from_sap.txt` download (would break re-deploy if used as a basis).
>
> **Rule:** if a disk copy of the source exists (e.g. the original
> `<PROGRAM_NAME>.abap` from the spec/build pipeline), apply your fixes
> there instead and re-deploy. Use `_from_sap.txt` only as a *reference*
> for what the live system has — never as the deploy basis when a
> structurally-correct disk copy is available.
>
> A more robust download path via RFC `RPY_PROGRAM_READ` is on the
> roadmap; until then, prefer disk-copy editing.

**1. Read the file:**
```powershell
$srcFile = '{WORK_TEMP}\<PROGRAM_NAME>_from_sap.txt'
$bytes = [System.IO.File]::ReadAllBytes($srcFile)
$text  = [System.Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF)
Write-Host $text
```
Write this to a `.ps1` file and run it — do not pass inline to `powershell -Command` (quoting issues).

**2. Analyze each error:** Use the line numbers and `[T]` types from the Step A output to locate the bad code.

**3. Apply fixes and write fixed file:**
```powershell
$srcFile   = '{WORK_TEMP}\<PROGRAM_NAME>_from_sap.txt'
$fixedFile = '{WORK_TEMP}\<PROGRAM_NAME>_fixed.txt'
$bytes = [System.IO.File]::ReadAllBytes($srcFile)
$text  = [System.Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF)
# Apply fixes — example:
$text = $text -replace '(?i)bad_pattern', 'correct_replacement'
[System.IO.File]::WriteAllText($fixedFile, $text, [System.Text.Encoding]::Unicode)
Write-Host "Fixed file written: $fixedFile"
```
Write this to a `.ps1` file and run it.

After all fixes are applied, proceed to Step C.

---

## Step C — Re-upload Fixed Source

Run the **Step 5a (Update)** flow with `{WORK_TEMP}\<PROGRAM_NAME>_fixed.txt` as `THE_SOURCE_PATH`.

The update VBS saves, activates, runs syntax check, and verifies activation via SA38 F8.

| Output | Action |
|---|---|
| `SUCCESS:` | Program is fixed and active — tell the user, proceed to Step 7 |
| `ERROR: Syntax errors found` | Errors remain — return to Step B and fix remaining errors |
| Other `ERROR:` | Diagnose using the Step 6 error table |

---

## Step 7 — Clean Up

If the log run hasn't already been ended (Step 6 success/failure path or
Step 1b TR-failure path), end it now as a safety net:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se38_run.json" -Status SUCCESS -ExitCode 0
```
(The helper deletes the state file on `end` and silently no-ops if the
file is already gone, so this is safe to call unconditionally.)

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_se38_check_run.vbs & del {WORK_TEMP}\sap_se38_check_run.ps1 & del {WORK_TEMP}\sap_se38_create_run.vbs & del {WORK_TEMP}\sap_se38_create_run.ps1 & del {WORK_TEMP}\sap_se38_update_run.vbs & del {WORK_TEMP}\sap_se38_update_run.ps1 & del {WORK_TEMP}\sap_se38_textelm_run.vbs & del {WORK_TEMP}\sap_se38_textelm_run.ps1 & del {WORK_TEMP}\sap_se38_textelm_seltexts.txt & del {WORK_TEMP}\sap_se38_check_and_download_run.vbs & del {WORK_TEMP}\sap_se38_check_and_download_run.ps1 & del {WORK_TEMP}\sap_se38_change_attrs_run.vbs & del {WORK_TEMP}\sap_se38_change_attrs_run.ps1 & del {WORK_TEMP}\sap_se38_delete_run.vbs & del {WORK_TEMP}\sap_se38_delete_run.ps1
```

For fix mode, also delete:
```bash
cmd /c del {WORK_TEMP}\<PROGRAM_NAME>_from_sap.txt & del {WORK_TEMP}\<PROGRAM_NAME>_fixed.txt
```

Also delete `{WORK_TEMP}\<PROGRAM_NAME>.abap` if the user pasted code (not a user-supplied file).

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters
(e.g. Japanese program titles). UTF-8 with BOM causes a cscript compile error.

### ABAP Source File Encoding (譁・ｭ怜喧縺・Fix)

The VBS templates automatically handle ABAP source file encoding:
- Claude's Write tool saves `.abap` files in **UTF-8**
- The templates detect whether the SAP system is **Unicode** using `oSession.Info.Codepage`
  - **Unicode SAP** (codepage 4110/4103): Upload the UTF-8 file **directly** — no conversion needed
  - **Non-Unicode SAP**: Convert UTF-8 to the **Windows system ANSI codepage** (e.g. Shift-JIS on Japanese Windows) via `ADODB.Stream`, then upload the converted `.upload.txt` file
- The temp `.upload.txt` file (non-Unicode path only) is automatically cleaned up after deployment

---

## Upload Menu Path Note

The source upload menu path (`menu[3]/menu[9]/menu[3]/menu[0]`) was recorded on
SAP GUI 7.60 / S/4HANA 1909 (Japanese). Menu indices **may differ** by SAP release
and logon language. If the upload step fails:

1. Open SE38 in your SAP system
2. Use SAP Logon > Help > Scripting Recorder and Playback
3. Record the "Upload from local file" menu action
4. Note the menu path from the recording and update the VBS template

---

## Troubleshooting Component IDs / Stuck Screen

**FIRST RESORT — invoke `/sap-gui-diagnose full`.** Captures every visible
window as one annotated PNG via the SAP GUI Scripting `HardCopy` API, plus
`/sap-gui-object-details` for the topmost window. Read the PNG with the
Read tool to see what's on screen, then act based on both the visual and
the structural dump.

**SECOND RESORT — `/sap-gui-object-details` alone.** Use this when
`/sap-gui-diagnose` itself fails (SAP GUI minimised, HardCopy blocked) or
when you only need a quick structural confirmation. When a VBS step fails
with `The control could not be found by id`, an unexpected popup appears,
or the script hangs because the screen flow diverged from what was
expected, do NOT guess. Call the `sap-gui-object-details` skill
immediately to discover the actual component layout in the current SAP
GUI session, then fix the VBS or dismiss the popup based on the dump.

Recommended diagnostic sequence:

| Step | Mode | Filter | Purpose |
|---|---|---|---|
| 1 | `tree` | (none) | List every open window (`wnd[0]`, `wnd[1]`, …) and their titles — confirms whether an unexpected popup is open |
| 2 | `wnd` | `1` (or `2`) | Full component tree of the unexpected popup — shows its OK/Cancel buttons |
| 3 | `id` | `wnd[0]/sbar` | Status-bar message (type/id/number/text). NOTE: AbapEditor swallows status messages — fall back to the syntax-check grid (see Limitations) |
| 4 | `type` | `GuiButton` | List every button with text + tooltip when you don't know which to press |
| 5 | `id` | `wnd[0]/usr/cntlEDITOR/shellcont/shell` | Inspect AbapEditor `SubType`, `LineCount`, `FirstVisibleLine` |

After the dump, decide:
- Unexpected popup (e.g. "Inactive objects", "Save changes?") → press its dismiss button (`wnd[N]/tbar[0]/btn[0]` or `btn[12]`) and retry.
- Component ID changed between SAP releases → update the VBS template with the discovered ID.
- AbapEditor stuck silent → use the syntax-check error grid pattern documented below.

**Last resort (only if `sap-gui-object-details` cannot help):**
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs

---

## Known Limitations: AbapEditor Status Bar Swallowing

The new front-end ABAP Editor (`cntlEDITOR/shellcont/shell`) **swallows ALL status bar
messages**. When the editor is active, `wnd[0]/sbar` always returns empty `.MessageType`
and `.Text`. This affects:

- **Save confirmation** — save may succeed but status bar appears empty
- **Activation result** — activation may silently fail with no error reported

### Syntax Check — Solved via Error Grid

Although the status bar is unreliable, **syntax check results ARE accessible** through the
error grid control at:

```
wnd[0]/shellcont/shell/shellcont[1]/shell
```

This is a GuiShell (ALV grid) with columns:
- `MSGTYPE` — error type (`1` or `E` = Error, `2` or `W` = Warning)
- `LINE` — source line number
- `TEXT` — error description

The VBS templates read errors using `getCellValue(row, column)` and `RowCount`. If the
grid has zero rows, syntax check passed. If any row has `MSGTYPE = "1"` (Error), deployment
is aborted with full error details.

Reference: SAP GUI Scripting API `doubleClickCurrentCell` can navigate to error lines.
Toolbar buttons on the grid: `WB_EDIT` (switch to edit mode), `WB_DISPLAY` (display mode).

### Impact

The VBS templates work around sbar swallowing by:
1. **Reading syntax errors from the grid control** (reliable — not affected by AbapEditor)
2. **Verifying activation** by navigating to SA38 and attempting to execute (F8)
   — if the selection screen (1000) appears, the program is confirmed active

### Workaround for Persistent Activation Failures

If activation keeps failing silently:
1. Open SE38 manually in SAP GUI
2. Enter the program name and press Check (Ctrl+F2) — the error grid shows details
3. Fix errors manually, then activate (Ctrl+F3)
4. If SAPLSPO1 screen 500 (activation worklist) appears, select all objects and press Enter

---

## Known Limitation: SAPLSPO1 Activation Worklist

When activating from the SE38 initial screen (Shift+F9 / btn[21]), SAP may navigate to
the SAPLSPO1 screen 500 (activation worklist). This screen lists inactive objects to activate.

**Problem:** All children in SAPLSPO1/500 have empty Id and Type, making it difficult to
interact with via SAP GUI Scripting.

**VBS template handling:** The templates detect SAPLSPO1 and press btn[0] (Continue/checkmark)
to confirm activation of all listed objects. If this fails, manual activation is needed.

**Activation worklist as wnd[1] dialog:** When the worklist appears as a dialog (wnd[1])
rather than a full screen — e.g., when activating text elements — it contains an ALV grid
and toolbar buttons:
- `tbar[0]/btn[9]` = Select All (F9) — must be pressed BEFORE Continue
- `tbar[0]/btn[0]` = Continue (Enter) — activates selected objects
- Use `oW1.sendVKey 9` then `oW1.sendVKey 0` (more reliable than button presses)
- The ALV grid's RowCount/ColumnCount may appear empty via cscript; use sendVKey instead

---

## Unit Test Execution

To run ABAP Unit Tests for the deployed program from SE38:

- **Menu path:** Program (menu[0]) > Execute (menu[9]) > Unit Tests (menu[2])
- **VBS:** `oSession.findById("wnd[0]/mbar/menu[0]/menu[9]/menu[2]").select`
- **Success indicator:** Status bar type `S`, message contains `Processed: N programs, N test classes, N test methods`

---

## Known Limitation: Reading Basic List Output via VBS

WRITE output displayed on the list screen (screen 120) produces 55+ `GuiLabel` children whose
`.Text` property returns **empty** when read via VBS (cscript). This means program output
cannot be reliably captured through SAP GUI Scripting.

**Workaround:** Always add `GUI_DOWNLOAD` in the ABAP code to export results to a local file
(e.g. `{WORK_TEMP}\<program>_result.txt`). Read the file after execution instead of attempting
to scrape the list screen.

---

## SE16N Check Script Behavior

The SE16N check script (`sap_se38_check.vbs`) queries table TRDIR for the program name.
Different SAP configurations may show results differently:

1. **Popup with count** — `wnd[1]/usr/txtGD-NUMBER` shows the result count (most common)
2. **Direct navigation** — No popup; SE16N navigates directly to the data browser (screen 200)
3. **Status bar message** — "no entries found" or "N entries selected" in status bar

The check script handles all three cases by checking popup first, then status bar, then screen number.

---

## Object Directory Entry Dialog (Package/Transport)

When creating a new program with a package and transport:

1. **Attributes dialog** (`wnd[1]`, SAPLSEDTATTR/200) — program type, title
2. **Object Directory Entry** (`wnd[2]`, SAPLSTRD/100) — appears AFTER the attributes dialog
   - Package field varies by SAP release:
     - S/4HANA 1909: `ctxtKO007-L_DEVCLASS`
     - Other systems: `ctxtSEUK-DEVCLASS`
   - The VBS templates try both field names as fallbacks
   - Press Enter → transport dialog at the same `wnd[2]` (SAPLSTRD/300)
3. **Transport dialog** (`wnd[2]`, SAPLSTRD/300) — may appear at same window
   - Transport field varies by SAP release:
     - S/4HANA 1909: `ctxtKO008-TRKORR` (may be pre-filled if package already has an open transport)
     - Other systems: `ctxtKORR_TXT-REQ_NUM` or `ctxtKO007-L_REQ`
   - The VBS templates try all three field names as fallbacks
   - If the transport is auto-assigned (package already has an open request), the dialog may close immediately after Enter on the package field — no explicit transport entry needed

When saving an existing program to a package, the transport dialog appears at `wnd[1]` (not `wnd[2]`), using the same field name fallbacks.

**Note:** Updating an existing $TMP object does NOT trigger the transport dialog — package
reassignment requires SE03 or manual intervention.

### SE38 Initial Screen Controls

| Button/Radio | ID | Description |
|---|---|---|
| Create | `btnNEW` | Creates a new program |
| Display | `btnSHOP` | Opens program in display mode |
| Change | `btnCHAP` | Opens program in change mode |
| Source Code | `radRS38M-FUNC_EDIT` | Source Code subobject radio |
| Attributes | `radRS38M-FUNC_HEAD` | Attributes subobject radio |
| Delete | `mbar/menu[0]/menu[12]` | Program > Delete... menu |

### SE38 Delete Flow

From the SE38 initial screen with program name entered:
1. Select `Program > Delete...` (`mbar/menu[0]/menu[12]`)
2. Confirmation dialog (`wnd[1]`, screen 201) shows checkboxes for Source, Text Elements, etc.
3. Press `btn[0]` (Delete) on the confirmation toolbar to confirm deletion

