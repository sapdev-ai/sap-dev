---
name: sap-gui-record
description: |
  Guides the user to record SAP GUI interactions using the built-in Script
  Recording and Playback feature, then reads the recorded VBS file to extract
  component IDs (findById paths), actions, and field names. Includes a
  comprehensive SAP GUI Scripting API quick reference with component type
  prefixes, VKey code mappings, and common shell control methods.
  No SAP login or VBS templates required — the user performs recording manually.
argument-hint: "[path-to-recorded-vbs-file]"
---

# SAP GUI Script Recording Skill

You help users discover SAP GUI component IDs by guiding them through the
built-in Script Recording and Playback feature, then reading and analyzing
the recorded VBS file. You also provide SAP GUI Scripting API reference.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — when analyzing recorded VBS, surface any `.Text`/`.Tooltip`/title-string branches as defects; identifiers must be component IDs + DDIC field names |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

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

Start a structured log run. State file: `{WORK_TEMP}\sap_gui_record_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_gui_record_run.json" -Skill sap-gui-record -ParamsJson "{\"name\":\"<RECORDING_NAME>\"}"
```

---

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:
- **Recorded VBS file path** — optional. If provided, verify it exists and skip to Step 3.
- **Question about component IDs or API** — if the user is asking a reference question (e.g.
  "what VKey is F8?"), skip to the API Reference sections below and answer directly.

If a file path is provided, verify it exists:
```bash
powershell -Command "if (Test-Path 'THE_FILE_PATH') { 'EXISTS' } else { 'NOT FOUND' }"
```

If the file exists, skip to Step 3. If no file path is provided, proceed to Step 2.

---

## Step 2 — Guide the User to Start Recording

Present these instructions to the user:

### How to Record

1. **Open SAP GUI** and log in to the target system. Navigate to the screen where you
   want to discover component IDs.

2. **Open the recorder** — use one of these methods:
   - Click the **"More"** dropdown button in the top toolbar area, then select
     **"SAP GUI settings and actions"** > **"Script Recording and Playback..."**
   - OR press **Alt+F12** (Customize Local Layout) and select **"Script Recording and Playback..."**

3. **In the Record and Playback dialog:**
   - Under **Record**, set **"Save To:"** to `{WORK_TEMP}\sap_recording.vbs`
     (or any preferred path)
   - Set **Encoding** to **Unicode**
   - Click the **red circle button** (Record) to start recording

4. **Perform actions** in SAP GUI — click fields, enter values, press buttons, navigate
   tabs, open menus. Every interaction is captured as VBScript code.

5. **Stop recording** — click the **orange square button** (Stop Recording) in the
   Record and Playback dialog.

6. Tell me the path to the saved recording file (or confirm `{WORK_TEMP}\sap_recording.vbs`).

Wait for the user to provide the file path before continuing.

---

## Step 3 — Read and Analyze the Recorded VBS

Read the recorded VBS file using the Read tool.

### Parsing rules

1. **Skip the boilerplate header** — the first ~14 lines are SAP GUI session setup code
   (`GetObject("SAPGUI")`, `application.Children(0)`, `WScript.ConnectObject`, etc.).
   Skip all lines until you reach the first `session.findById(...)` line.

2. **Extract each `session.findById("...")` line.** For each line, capture:
   - **Component ID**: the string inside `findById("...")` — e.g. `wnd[0]/usr/ctxtRSRD1-DOMA_VAL`
   - **Action**: the method/property after the closing `)` — e.g. `.text = "ZHKTEST003"`,
     `.press`, `.select`, `.sendVKey 4`, `.doubleClick`, `.caretPosition = 10`
   - **Value**: any value assigned (for `.text = "..."`) or VKey number (for `.sendVKey N`)

3. **Decode the component type** from the ID path using the Component Type Prefix Table below.

### Present a summary table

| # | Component ID | Type | Action | Value |
|---|---|---|---|---|
| 1 | `wnd[0]/usr/radRSRD1-DOMA` | Radio button | `.select` | |
| 2 | `wnd[0]/usr/ctxtRSRD1-DOMA_VAL` | Context field | `.text =` | `ZHKTEST003` |
| 3 | `wnd[0]/usr/btnPUSHADD` | Button | `.press` | |
| 4 | `wnd[0]/usr/txtDD01D-DDTEXT` | Text field | `.text =` | `test` |
| 5 | `wnd[0]/tbar[0]/btn[11]` | Toolbar button | `.press` | Save (Ctrl+S) |
| 6 | `wnd[0]` | Window | `.sendVKey` | 4 (F4 Help) |

Ignore `.caretPosition` and `.setFocus` lines — these are cursor positioning, not meaningful actions.

---

## Step 4 — Provide Usage Guidance

Explain how to use the discovered component IDs:

- **In VBScript automation:**
  ```vbs
  oSession.findById("wnd[0]/usr/ctxtRSRD1-DOMA_VAL").Text = "VALUE"
  oSession.findById("wnd[0]/usr/btnPUSHADD").press
  ```

- **In existing sap-dev skills:** When a VBS template's menu path or component ID doesn't
  work on the user's system, replace it with the correct ID from the recording.

- **For new automation:** Build VBS templates following the patterns in sap-se38 or sap-se37
  skill references.

---

## Component ID Path Format

SAP GUI component IDs use a hierarchical path:

```
wnd[N] / usr / TYPE<FIELD_NAME>
  |       |      |     |
  |       |      |     +-- SAP field name (e.g. RS38L-NAME)
  |       |      +-------- Type prefix (ctxt, txt, btn, rad, etc.)
  |       +--------------- User area (main screen content)
  +----------------------- Window index (0=main, 1=popup, 2=2nd popup)
```

### Window and area segments

| Segment | Description |
|---|---|
| `wnd[0]` | Main window |
| `wnd[1]` | First popup/dialog window |
| `wnd[2]` | Second popup/dialog (nested) |
| `usr` | User area (main screen content) |
| `tbar[0]` | System toolbar (topmost — Enter, Back, Save, etc.) |
| `tbar[1]` | Application toolbar (below system toolbar — F5-F12 functions) |
| `sbar` | Status bar (bottom of screen) |
| `mbar` | Menu bar |
| `titl` | Title bar |

### Subscreen notation

Subscreens use the format: `ssubSCREEN_NAME:PROGRAM_NAME:DYNPRO_NUMBER`

Example: `ssubTS_SCREEN:SAPLSD11:1201` = subscreen TS_SCREEN in program SAPLSD11, dynpro 1201.

---

## Component Type Prefix Table

| Prefix | SAP GUI Type | Description | Example |
|---|---|---|---|
| `ctxt` | `GuiCTextField` | Context/input field (with F4 help) | `ctxtRS38L-NAME` |
| `txt` | `GuiTextField` | Text/input field | `txtDD01D-DDTEXT` |
| `btn` | `GuiButton` | Button | `btnPUSHADD` |
| `rad` | `GuiRadioButton` | Radio button | `radRSRD1-DOMA` |
| `chk` | `GuiCheckBox` | Checkbox | `chkRS38L-ACTIVE` |
| `lbl` | `GuiLabel` | Label (read-only text) | `lbl[1,4]` |
| `tabs` | `GuiTabStrip` | Tab strip container | `tabsFUNC_TAB_STRIP` |
| `tabp` | `GuiTab` | Tab page (child of tab strip) | `tabpSOURCE` |
| `cntl` | `GuiContainerShell` | Container control | `cntlEDITOR` |
| `shell` | `GuiShell` | Shell control (tree, grid, editor) | `shell` |
| `shellcont` | `GuiContainerShell` | Shell container | `shellcont` |
| `ssub` | `GuiSimpleContainer` | Subscreen area | `ssubTS_SCREEN:SAPLSD11:1201` |
| `mbar` | `GuiMenubar` | Menu bar | `mbar` |
| `menu` | `GuiMenu` | Menu item (0-indexed) | `menu[3]/menu[9]` |
| `tbar` | `GuiToolbar` | Toolbar | `tbar[0]` |
| `usr` | `GuiUserArea` | Screen content area | `usr` |
| `sbar` | `GuiStatusbar` | Status bar | `sbar` |
| `titl` | `GuiTitlebar` | Title bar | `titl` |

---

## Common Actions and Methods

| Method / Property | Description | Example |
|---|---|---|
| `.Text = "value"` | Set field value | `oSess.findById("...ctxtFIELD").Text = "ABC"` |
| `.Text` (read) | Get current field value | `sVal = oSess.findById("...ctxtFIELD").Text` |
| `.press` | Click a button | `oSess.findById("...btn[11]").press` |
| `.select` | Select radio button / tab / list item | `oSess.findById("...radOPTION").select` |
| `.Selected` (read) | Check if radio/checkbox is selected | `bSel = oSess.findById("...chkOPT").Selected` |
| `.setFocus` | Move keyboard focus to element | `oSess.findById("...txtFIELD").setFocus` |
| `.caretPosition = N` | Set cursor position in text field | (usually ignorable in automation) |
| `.sendVKey N` | Send virtual key (see VKey table) | `oSess.findById("wnd[0]").sendVKey 11` |
| `.doubleClick` | Double-click the element | `oSess.findById("...sbar").doubleClick` |
| `.doubleClickNode "key"` | Double-click a tree node | `oSess.findById("...shell").doubleClickNode "F00005"` |
| `.selectedNode = "key"` | Select a tree node | `oSess.findById("...shell").selectedNode = "F00005"` |
| `.maximize` | Maximize the window | `oSess.findById("wnd[0]").maximize` |

---

## Shell Control Methods (Grid, Tree, Editor)

These methods work on shell controls (ALV grid, tree, ABAP editor):

| Method / Property | Description |
|---|---|
| `.getCellValue(row, "COL_NAME")` | Get cell value in ALV grid (0-indexed rows) |
| `.RowCount` | Number of rows in grid |
| `.GetLineText(n)` | Read source line from AbapEditor (0-indexed) |
| `.setCurrentCell row, "COL_NAME"` | Set current cell in grid |
| `.doubleClickCurrentCell` | Double-click the current cell |
| `.pressToolbarButton "BUTTON_ID"` | Press a toolbar button in a shell |
| `.selectNode "key"` | Select a node in tree control |
| `.expandNode "key"` | Expand a tree node |
| `.pressButton "BUTTON_ID"` | Press a button inside a shell |
| `.Children` | Collection of child elements |
| `.Id` | Full component ID path of the element |
| `.Type` | SAP GUI type name of the element |
| `.Name` | Short name of the element |

---

## VKey Code Reference

| VKey | Keyboard | SAP Function |
|---|---|---|
| 0 | Enter | Confirm / Execute |
| 1 | F1 | Help |
| 2 | F2 | Details / Pick |
| 3 | F3 | Back |
| 4 | F4 | F4 Help / Value List |
| 5 | F5 | Create / New |
| 6 | F6 | (varies by transaction) |
| 7 | F7 | (varies by transaction) |
| 8 | F8 | Execute / Run |
| 9 | F9 | (varies by transaction) |
| 10 | F10 | (varies by transaction) |
| 11 | Ctrl+S | Save |
| 12 | F12 | Cancel |
| 15 | Shift+F3 | Exit |
| 16 | Shift+F4 | (varies) |
| 17 | Shift+F5 | (varies) |
| 26 | Ctrl+F2 | Syntax Check |
| 27 | Ctrl+F3 | Activate |
| 28 | Ctrl+F4 | (varies) |
| 33 | Ctrl+Shift+F5 | (varies) |
| 70 | Ctrl+Shift+F1 | (varies) |
| 71 | Ctrl+Shift+F2 | (varies) |
| 73 | Ctrl+Shift+F4 | (varies) |

---

## Common Toolbar Button Positions

| Component ID | Common Function |
|---|---|
| `tbar[0]/btn[0]` | Enter / Continue |
| `tbar[0]/btn[3]` | Back (F3) |
| `tbar[0]/btn[11]` | Save (Ctrl+S) |
| `tbar[0]/btn[12]` | Cancel (F12) |
| `tbar[0]/btn[15]` | Exit (Shift+F3) |
| `tbar[1]/btn[8]` | Execute (F8) |
| `tbar[1]/btn[26]` | Check / Syntax Check (Ctrl+F2) |
| `tbar[1]/btn[27]` | Activate (Ctrl+F3) |

Note: Application toolbar (`tbar[1]`) button positions vary by transaction. Use Script
Recording to find the exact positions for your transaction.

---

## SAP GUI Scripting API Reference

Full API documentation:
https://help.sap.com/docs/sap_gui_for_windows/b47d018c3b9b45e897faf66a6c0885a8/babdf65f4d0a4bd8b40f5ff132cb12fa.html

---

## Known Limitations

### AbapEditor Status Bar Swallowing

The new front-end AbapEditor control (`cntlEDITOR/shellcont/shell`) swallows all status bar
messages in SE38 and SE37. After syntax check or save, `wnd[0]/sbar` returns empty
`.MessageType` and `.Text`. Use the error grid at `wnd[0]/shellcont/shell/shellcont[1]/shell`
instead (see sap-se37 and sap-se38 SKILL.md for details).

### Status Bar Properties

| Property | Description |
|---|---|
| `.Text` | Status bar message text |
| `.MessageType` | Message type: `S` (Success), `W` (Warning), `E` (Error), `I` (Info) |

### ActiveWindow

`oSession.ActiveWindow.Id` returns the ID of the currently focused window. Use this to detect
popups: `If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then ...`

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_gui_record_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_gui_record_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `GUI_RECORD_FAILED`, `RECORDER_NOT_AVAILABLE`.

---

## Prerequisites

- **SAP GUI for Windows** installed
- **SAP GUI Scripting enabled** — SAP Logon > Options (Alt+F7) > Scripting > Enable Scripting
- **Already logged into SAP** — this skill does not handle login
