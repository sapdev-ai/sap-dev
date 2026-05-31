---
name: sap-se91
description: |
  Manages SAP message classes via SE91 using SAP GUI Scripting. Creates new
  message classes or updates messages in existing ones. Existence check
  (SE91 Display), message text editing via inline table,
  and save. Messages are provided as tab-separated number/text pairs in a file.
  Also supports change-properties mode: when the user asks to change a
  message class's header attributes (Short Text, Person Responsible, ...),
  opens SE91 with the Header radio (radRSDAG-MIDFLAG) in change mode,
  updates the supplied fields on tabpHEAD, then Saves. Handles the
  conditional original-language popup and the post-save Workbench-request
  popup (per /sap-transport-request).
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<message-class-name> [messages-to-add-or-update]"
---

# SAP SE91 Message Class Maintenance Skill

You manage SAP message classes and their messages via SE91 using SAP GUI
Scripting. The skill checks if the message class exists, then
creates or updates it with the provided messages. Supports assigning to
a specific package and transport request, or saving as local object ($TMP).

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` (Step 1b) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
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

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_se91_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se91_run.json" -Skill sap-se91 -ParamsJson "{\"message_class\":\"<MSGCLASS>\"}"
```

---

## Step 1 — Collect Parameters

**Message Class Details**

| Parameter | Description | Example |
|---|---|---|
| Message class name | Z/Y namespace, max 20 chars | `ZHKMSG01` |
| Short text | Short description, max 60 chars (only for new classes) | `My custom messages` |
| Messages | List of message number/text pairs, OR a file path | See below |
| Package | SAP development package (empty = $TMP local object) | `ZHKA002` |
| Transport | Transport request number (optional; resolved by `/sap-transport-request` per `way_to_get_transport_request` if not supplied) | `S4DK940994` |

**Messages format** — either:
- A list in the conversation: `000: First message`, `001: Second &1`, etc.
- A tab-separated file with one message per line. Two layouts are accepted:
  - 2-column (canonical): `<3-digit-number>\t<text>`
  - 3-column (as emitted by sap-docs-extract): `<3-digit-number>\t<type>\t<text>` where `<type>` is one of `E/W/I/A/S` and is ignored (T100 stores text only). The VBS takes the first column as the number and the LAST column as the text.

---

## Step 1b — Resolve Transport Request

If `Package` is empty or starts with `$` (e.g. `$TMP`), this is a local
object; **skip this step**.

Otherwise a TR is needed. **Do NOT prompt the user directly and do NOT call
`/sap-se01`.** Delegate to `/sap-transport-request`:

```
/sap-transport-request [<TR-from-args-if-any>] OBJECT_TYPE=MSGCLASS OBJECT_DESCRIPTION=<MSG_CLASS_NAME>
```

Use the returned modifiable TRKORR as the `%%TRANSPORT%%` value. If
`/sap-transport-request` reports `ERROR`, stop and surface it to the user.

See `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for the full policy.

---

## Step 2 — Prepare Messages File

**If adding messages to an existing class and the next message number is unknown:**

Query table T100 via SE16 to find the current maximum message number:
1. Navigate to `/nSE16`, enter table `T100`.
2. Set selection: `SPRSL` (language) blank, `ARBGB` = the message class name.
3. Execute (F8) and read the ALV grid `MSGNR` column for all rows.
4. Take the maximum `MSGNR` value and add 1 (pad to 3 digits) for the next message number.
5. If no entries found, start at `000`.

**If the user provided messages inline** (in the conversation):

1. Write the messages to: `{WORK_TEMP}\<MSG_CLASS>_messages.txt`
   - Tab-separated format: `<3-digit-number>\t<message text>` per line.
   - Pad message numbers to 3 digits (e.g. `001`, `050`).
   - Message placeholders use `&1`, `&2`, `&3`, `&4` (max 4 per message).
   - Maximum message text length: 73 characters.
3. Confirm the file by reading it back.

**If the user provided a file path:**
- Verify it exists and is in the correct tab-separated format.

**If no messages are provided (Create only):**
- The message class will be created with the short text but no messages.
- Messages can be added later via the Update flow.

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Message Class Exists

The check VBScript template is at `./references/sap_se91_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se91_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se91_check.vbs' -Raw
$content = $content -replace '%%MSG_CLASS%%','THE_MSG_CLASS'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se91_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_MSG_CLASS` with the actual message class name (UPPERCASE) and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se91_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se91_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → message class exists → proceed to Step 5a (Update).
- `NOT_EXIST` → message class does not exist → proceed to Step 5b (Create).
- `ERROR:` → show full output and stop.

---

## Step 4b — Check for Duplicate Message Texts (Update flow only)

Before inserting new messages into an existing message class, check if any message
text already exists in T100. If a duplicate is found, reuse the existing message
number instead of creating a new entry.

**Skip this step if:**
- Creating a brand-new message class (Step 5b) — no existing messages to duplicate.
- The user explicitly says to insert regardless of duplicates.

The check PowerShell template is at `./references/sap_se91_check_messages.ps1`.
It uses RFC_READ_TABLE via SAP NCo 3.1 (requires 32-bit PowerShell).

### Sub-step A: Get SAP connection details

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

### Sub-step B: Run the duplicate check

Write `{WORK_TEMP}\sap_se91_checkmsg_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se91_check_messages.ps1' -Raw
$content = $content -replace '%%MSG_CLASS%%','THE_MSG_CLASS'
$content = $content -replace '%%MESSAGES_FILE%%','THE_MESSAGES_FILE'
$content = $content -replace '%%SAP_SERVER%%','THE_SERVER'
$content = $content -replace '%%SAP_SYSNR%%','THE_SYSNR'
$content = $content -replace '%%SAP_CLIENT%%','THE_CLIENT'
$content = $content -replace '%%SAP_USER%%','THE_USER'
$content = $content -replace '%%SAP_PASSWORD%%','THE_PASSWORD'
$content = $content -replace '%%SAP_LANGUAGE%%','THE_LANGUAGE'
$content = $content -replace '%%RFC_LIB_PS1%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_se91_checkmsg_run.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`.

Execute (must use 32-bit PowerShell for SAP NCo 3.1):
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se91_checkmsg_run.ps1"
```

### Sub-step C: Parse results and update messages file

**Output format:**
- `FOUND:<requested_num>:<existing_MSGNR>:<text>` — text already exists at `<existing_MSGNR>`
- `NEW:<requested_num>:<text>` — text is new, safe to insert

**For each `FOUND:` line:**
1. **Remove** that message from the messages file (do not insert it via SE91).
2. **Update the ABAP source** to use the existing message number (`<existing_MSGNR>`)
   instead of the originally planned number (`<requested_num>`).
   - Search for `MESSAGE ... <requested_num>` or `message_number = '<requested_num>'`
     in the ABAP source and replace with `<existing_MSGNR>`.
   - Report each substitution to the user.

**If all messages are `FOUND:`** — skip Step 5a entirely (nothing to insert).
Only update the ABAP source with the existing message numbers.

**If some messages are `NEW:`** — rewrite the messages file with only the `NEW:`
entries and proceed to Step 5a (Update) with the filtered file.

---

## Step 5a — Update Existing Message Class

**Update flow (Original-language popup handling):** Right after pressing
the Change button (`btnMODTASTE`), the template inspects `wnd[1]` for the
SAPLSETX "Different original and logon languages" dialog (fingerprint:
`wnd[1]/usr/ctxtRSETX-MASTERLANG` present). If found, it presses
`wnd[1]/usr/btnPUSH1` ("Maint. in orig. lang.") to keep `TADIR-MASTERLANG`
unchanged so we edit message texts in the logon language without
overwriting the master language.

The update VBScript template is at `./references/sap_se91_update.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se91_update_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se91_update.vbs' -Raw
$content = $content -replace '%%MSG_CLASS%%','THE_MSG_CLASS'
$content = $content -replace '%%MESSAGES_FILE%%','THE_MESSAGES_FILE'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se91_update_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_MSG_CLASS` (UPPERCASE), `THE_MESSAGES_FILE` (absolute path with backslashes), `THE_PACKAGE`, `THE_TRANSPORT`, and `<SKILL_DIR>`. If package/transport not provided, replace with empty strings.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se91_update_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se91_update_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Message Class

If this is a new message class, you need the Short Text. Ask the user if not already provided:
> "This is a new message class. Please provide a short description."

The create VBScript template is at `./references/sap_se91_create.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se91_create_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se91_create.vbs' -Raw
$content = $content -replace '%%MSG_CLASS%%','THE_MSG_CLASS'
$content = $content -replace '%%SHORT_TEXT%%','THE_SHORT_TEXT'
$content = $content -replace '%%MESSAGES_FILE%%','THE_MESSAGES_FILE'
$content = $content -replace '%%PACKAGE%%','THE_PACKAGE'
$content = $content -replace '%%TRANSPORT%%','THE_TRANSPORT'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se91_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```

> **Messages-file encoding (important):** The `%%MESSAGES_FILE%%` referenced
> here MUST be **UTF-8** (the VBS reads with `OpenTextFile(..., False)` =
> ASCII Tristate, which handles UTF-8 correctly with optional BOM).
> Writing the file as **UTF-16** (PowerShell `-Encoding Unicode`) silently
> truncates the message list — the SE91 reader misinterprets the byte
> stream and reports a low message count. Use `-Encoding UTF8` for the
> messages file specifically:
>
> ```powershell
> Set-Content '<messages.txt>' $messageContent -Encoding UTF8
> ```
>
> Note this contradicts the SE11 definition-file convention (which IS
> UTF-16). The two skills' VBS scripts use different `OpenTextFile`
> Tristate values; until that's harmonised, follow each SKILL.md.

```powershell
# placeholder to keep the markdown code-block parse aligned
```
Replace all `THE_*` placeholders and `<SKILL_DIR>`. If package/transport not provided, replace with empty strings.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se91_create_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se91_create_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user the message class was created/updated.
- Show the full script output as a code block.
- If Step 4b found duplicates, also report which message numbers were reused.

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `Still on Initial Screen` | Message class already exists (Create) or not found | Check name or use correct flow |
| `Message class not found` | Class doesn't exist (Update) | Create first or check name |
| `Messages table not found` | Table control not initialized | Re-run; ensure class was saved first |
| `Messages file not found` | Wrong path or file not written | Verify path, re-run Step 2 |
| `Could not set message` | Table cell not accessible | Check message number is 000-999 |
| `No SAP GUI session found` | Not logged in | Run login step first |
| `Package/transport dialog` | Needs transport assignment | Provide package + transport, or auto-assigned to $TMP |
| `Language mismatch popup` | Logon language differs from T100A master language | VBS auto-clicks "Maint. in orig. lang." |

---

## Step 5d — Change Message Class Header (Short Text / Person Responsible)

**When to run:** The user wants to modify a message class's **header**
attributes (Short Text, Person Responsible, ...) **without** adding or
editing message texts. Examples:

- "Change the short text of `ZHKA01` to '…'"
- "Set person responsible of `ZHKMSG01` to JDOE"
- "Rename description of message class `ZHKA01`"

The change-properties VBScript template is at `./references/sap_se91_change_props.vbs`.

### Collect Inputs

| Token | Description | Empty? |
|---|---|---|
| `%%MSG_CLASS%%` | Message class name (UPPERCASE), max 20 chars | required |
| `%%SHORT_TEXT%%` | New `T100A-STEXT` (max 60 chars) | empty = leave unchanged |
| `%%RESPONSIBLE%%` | New `T100A-RESPUSER` (SAP user name) | empty = leave unchanged |
| `%%TRANSPORT%%` | TR for the post-save TR popup | empty when local (`$TMP`) or already locked to a modifiable TR |

If the message class's package is transportable (TADIR-DEVCLASS not
starting with `$`), resolve a TR via Step 1b and pass it as
`%%TRANSPORT%%`. If local or already locked, leave it empty — the VBS
only aborts if SAP actually prompts.

If only the message-class name is supplied and both `SHORT_TEXT` and
`RESPONSIBLE` are empty, ask the user which header field to change.
Do not run the VBS with no values (it will exit `DONE: NO_CHANGE`).

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se91_change_props_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se91_change_props.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%MSG_CLASS%%',   'THE_MSG_CLASS')
$content  = $content.Replace('%%SHORT_TEXT%%',  'THE_SHORT_TEXT')
$content  = $content.Replace('%%RESPONSIBLE%%', 'THE_RESPONSIBLE')
$content  = $content.Replace('%%TRANSPORT%%',   'THE_TRANSPORT')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_se91_change_props_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Use `.Replace()` (literal) — short-text values may contain regex
metacharacters. Replace `<SKILL_DIR>` and the `THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se91_change_props_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se91_change_props_run.vbs
```

### Behaviour Notes

- The VBS opens SE91, fills `wnd[0]/usr/ctxtRSDAG-ARBGB`, selects the
  **Message Class** radio `radRSDAG-MIDFLAG`, then presses Change
  (`btnMODTASTE`) — different from Step 5a which uses the Messages radio
  (`radRSDAG-MSGFLAG`).
- **Original-language popup is conditional.** SAPLSETX
  (`wnd[1]/usr/ctxtRSETX-MASTERLANG`) only appears when logon language
  differs from `MASTERLANG`. The VBS detects via the MASTERLANG
  fingerprint and presses `wnd[1]/usr/btnPUSH1` ("Maint. in orig. lang.")
  so MASTERLANG is preserved.
- **Field IDs (subscreen `SAPLWBMESSAGES:0102` under tabpHEAD):**
  | Field | ID (relative to `wnd[0]/usr/tabsCONTROL1000/tabpHEAD/ssubSUB:SAPLWBMESSAGES:0102`) |
  |---|---|
  | Short Text | `txtT100A-STEXT` |
  | Person Responsible | `ctxtT100A-RESPUSER` (or `txtT100A-RESPUSER` on some releases) |
- **Save.** `wnd[0]/tbar[0]/btn[11]` (Save).
- **Post-save TR popup.** If SAP prompts via
  `wnd[1]/usr/ctxtKO008-TRKORR`, the VBS fills `%%TRANSPORT%%` and
  presses Enter. If the popup appears but `%%TRANSPORT%%` is empty, the
  VBS aborts with `ERROR: SAP prompted for a transport request but
  TRANSPORT is empty` — resolve a TR via `/sap-transport-request` and
  re-run.
- **Lock-error popup.** If the message class is locked by another
  modifiable task, SAP shows an Error popup (`txtMESSTXT1`/`txtMESSTXT2`
  containing `locked`). The VBS detects this and exits 1 with
  `ERROR: SAP popup [Error] …`.
- **No-change path.** If both SHORT_TEXT and RESPONSIBLE are empty, the
  VBS backs out (F3) and exits 0 with `DONE: NO_CHANGE`.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Header updated for <MSG_CLASS>.` | Save succeeded. Status bar message also echoed. |
| `DONE: NO_CHANGE` | No values supplied; backed out. |
| `ERROR: …` | Couldn't open header tab, lock error, or missing TR. Show full output. |

After success, proceed to Step 7 (cleanup). Skip Step 6.

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
| 1 | `tree` | (none) | List every open window (`wnd[0]`, `wnd[1]`, …) and their titles |
| 2 | `wnd` | `1` (or `2`) | Full component tree of the unexpected popup — shows its OK/Cancel buttons |
| 3 | `id` | `wnd[0]/sbar` | Read the status-bar message (type/id/number/text) |
| 4 | `type` | `GuiButton` | List every button with text + tooltip when you don't know which to press |
| 5 | `id` | the failing component path | Inspect `Changeable`, `Required`, `Value` to understand why an assignment fails |

After the dump, decide:
- Unexpected popup (e.g. "Language mismatch", "Package assignment") → press its dismiss button (`wnd[N]/tbar[0]/btn[0]` or `btn[12]`) and retry.
- Component ID changed between SAP releases → update the VBS template with the discovered ID.

**Last resort (only if `sap-gui-object-details` cannot help):**
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs

---
## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_se91_check_run.vbs & del {WORK_TEMP}\sap_se91_check_run.ps1 & del {WORK_TEMP}\sap_se91_create_run.vbs & del {WORK_TEMP}\sap_se91_create_run.ps1 & del {WORK_TEMP}\sap_se91_update_run.vbs & del {WORK_TEMP}\sap_se91_update_run.ps1 & del {WORK_TEMP}\sap_se91_checkmsg_run.ps1 & del {WORK_TEMP}\sap_se91_change_props_run.vbs & del {WORK_TEMP}\sap_se91_change_props_run.ps1
```

Also delete `{WORK_TEMP}\<MSG_CLASS>_messages.txt` if messages were created from inline input.

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se91_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se91_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE91_FAILED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).
