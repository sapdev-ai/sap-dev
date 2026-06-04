---
name: sap-gui-object-details
description: |
  Inspects components in the currently active SAP GUI session and dumps their
  IDs and properties. Five modes: full component tree of all windows or a
  specific window, menu-bar tree, type filter (e.g. all GuiButton, GuiShell,
  GuiStatusbar, GuiTableControl, GuiMenu, GuiToolbar), or full property dump
  of a single component by ID. Useful when SAP GUI scripts get stuck because
  the screen flow did not go as expected (e.g. an unexpected popup appeared,
  a control ID changed between releases, or a field is greyed-out for unclear
  reasons). Other skills can call this skill mid-flow to discover the actual
  current screen state.
  Prerequisites: Active SAP GUI session (use /sap-login first). RZ11
  parameter `sapgui/user_scripting` must be TRUE on the SAP server.
argument-hint: "<mode> [filter] [wnd=<n>]   modes: tree | menu | type | id | wnd"
---

# SAP GUI Object Details Skill

You inspect the currently active SAP GUI screen and dump the component tree,
menu bar, all components of a chosen type, or the full property set of a
single component identified by its `findById` path.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`.
| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{WORK_TEMP}\sap_gui_object_details_run.json`) so subsequent steps and
the final log-end call append to the same run. Best-effort: silently
no-ops if `userConfig.log_enabled=false` or the lib can't load.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_gui_object_details_run.json" -Skill sap-gui-object-details -ParamsJson "{\"object_type\":\"<TYPE>\",\"object_name\":\"<NAME>\"}"
```

---

## Step 1 — Parse Arguments

| Parameter | Required | Notes |
|---|---|---|
| Mode | yes | `tree` / `menu` / `type` / `id` / `wnd` |
| Filter | depends | Required for `type` (e.g. `GuiButton`), `id` (full path), `wnd` (window index) |
| Window scope | optional | `wnd=<n>` to restrict `tree`/`menu`/`type` to a single window; default = scan `wnd[0]` through `wnd[5]` |

### Mode summary

| Mode | What it does | Filter example |
|---|---|---|
| `tree` | Full component tree (Type / Id / short summary) of every visible window | — |
| `menu` | Menu bar (`mbar`) tree including titles and IDs | — |
| `type` | Walks the tree and emits **full property dump** for every component whose `Type` matches the filter | `GuiButton`, `GuiStatusbar`, `GuiShell`, `GuiTableControl`, `GuiMenu`, `GuiToolbar`, `GuiUserArea`, `GuiCheckBox`, `GuiRadioButton` |
| `id` | Full property dump of one component plus its immediate children | `wnd[0]/sbar`, `wnd[1]/usr/btnSPOP-OPTION1` |
| `wnd` | Full component tree of a single window (alias for `tree wnd=<n>`) | `1` for the first popup |

Synonyms accepted: `Statusbar` → `GuiStatusbar`, `Button` → `GuiButton`,
`Tablecontrol` → `GuiTableControl`, `Toolbar` → `GuiToolbar`, `Menu` → `GuiMenu`,
`Shell` → `GuiShell`. Always normalize to the official `Gui*` name before
passing to the VBS.

---

## Step 2 — Ensure SAP GUI Session

This skill requires an active SAP GUI session. Run `/sap-login` first if
necessary. The skill never re-creates the session — it only inspects what is
on screen right now.

---

## Step 3 — Generate and Run the VBS

Template: `./references/sap_gui_object_details.vbs`. Tokens:

| Token | Replace with |
|---|---|
| `%%MODE%%` | `tree` / `menu` / `type` / `id` / `wnd` |
| `%%FILTER%%` | The filter value (empty for plain `tree` / `menu`) |
| `%%WINDOW%%` | Window index (`0`..`5`), or empty for all windows |
| `%%MAX_DEPTH%%` | Optional recursion cap; default `10` |
| `%%OUTPUT_FILE%%` | Absolute path of the output file (UTF-16 LE) |

Default output file: `{WORK_TEMP}\sap_gui_objects_<MODE>.txt`.

Write `{WORK_TEMP}\sap_gui_object_details_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$workTemp = '{WORK_TEMP}'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_gui_object_details.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%MODE%%','THE_MODE')
$content  = $content.Replace('%%FILTER%%','THE_FILTER')
$content  = $content.Replace('%%WINDOW%%','THE_WINDOW')
$content  = $content.Replace('%%MAX_DEPTH%%','10')
$content  = $content.Replace('%%OUTPUT_FILE%%','THE_OUTPUT_FILE')
[System.IO.File]::WriteAllText("$workTemp\sap_gui_object_details_run.vbs", $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run via 32-bit cscript:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_gui_object_details_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {WORK_TEMP}\sap_gui_object_details_run.vbs
```

---

## Step 4 — Interpret the Output

| Last line of stdout | Meaning |
|---|---|
| `DONE` | Success. Result file is at `OUTPUT_FILE` (Unicode). |
| `ERROR: …` | Failure (no SAP GUI / no session / bad mode / bad filter). |

The output file always starts with a header block (date, mode, transaction,
program, screen, user/client/system) followed by mode-specific sections.

Open it with:
```bash
powershell -Command "Get-Content '{WORK_TEMP}\sap_gui_objects_<MODE>.txt' -Encoding Unicode"
```

Or read selected lines directly with the `read_file` tool.

---

## Step 5 — Report

Summarise to the user:
- Mode and filter used
- Output file path
- Key findings: number of windows, popup titles, count of matched components
  for `type` mode, status-bar message text, etc.

When invoked by another skill that is "stuck", provide just the IDs the
caller needs (e.g. "popup `wnd[1]` is open with title 'Information'; click
`wnd[1]/tbar[0]/btn[0]` to dismiss") rather than the full file contents.

---

## Common Recipes

| Goal | Mode | Filter |
|---|---|---|
| What windows are open right now? | `tree` | — |
| What's the current status-bar message? | `id` | `wnd[0]/sbar` |
| List every clickable button on screen | `type` | `GuiButton` |
| Inspect the popup `wnd[1]` that appeared unexpectedly | `wnd` | `1` |
| Discover the menu path for a transaction | `menu` | — |
| Why is field X greyed out? | `id` | the field's full path (look at `Changeable`) |
| What columns does this ALV grid have? | `type` | `GuiShell` (then look for SubType=GridView) |
| What's inside this table control? | `id` | `wnd[0]/usr/tblSAPL...` |

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_gui_object_details_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_gui_object_details_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `OBJECT_DETAILS_FAILED`, `GUI_TIMEOUT`.

---

## Component IDs (for reference)

| Element | ID |
|---|---|
| Main window | `wnd[0]` |
| Menu bar | `wnd[0]/mbar` |
| Application toolbar | `wnd[0]/tbar[1]` |
| System toolbar | `wnd[0]/tbar[0]` |
| Title bar | `wnd[0]/titl` |
| Status bar | `wnd[0]/sbar` |
| User area | `wnd[0]/usr` |
| Modal popup | `wnd[1]`, `wnd[2]`, … (up to 5) |

---

## Limitations

- The VBS uses a fixed property whitelist. Custom controls that expose unique
  properties (e.g. `GuiCalendar.SelectedDate`) are not dumped — extend the
  `Eval2` switch in the VBS to add more.
- `MAX_DEPTH` defaults to 10. Deeply nested split containers may need a
  higher value — pass `%%MAX_DEPTH%%` accordingly.
- The skill does not click anything. It is read-only inspection.
- For full ALV grid contents, use `/sap-se16n` or the existing screen-dump
  helper — this skill only prints column headers, not row data.
