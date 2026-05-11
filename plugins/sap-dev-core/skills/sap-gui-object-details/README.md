# SAP GUI Object Details Skill

Inspects components in the currently active SAP GUI session and dumps their
IDs and properties. Useful when SAP GUI scripts get stuck because the screen
flow did not go as expected — an unexpected popup appeared, a control ID
changed between releases, or a field is greyed-out for unclear reasons.

Other skills can call this skill mid-flow to discover the actual current
screen state.

## Skill Overview

Five inspection modes:

| Mode | What it dumps |
|---|---|
| `tree` | Full component tree of all open windows |
| `wnd=<n>` | Component tree of one specific window (e.g. `wnd=1` for a popup) |
| `menu` | Menu-bar tree (mbar children, recursive) |
| `type` | All components of a chosen type (`GuiButton`, `GuiShell`, `GuiStatusbar`, `GuiTableControl`, `GuiMenu`, `GuiToolbar`, …) |
| `id` | Full property dump of a single component by its `findById` path |

## Auto-Trigger Keywords

- `dump screen`, `dump window`, `inspect screen`
- `what's on the current screen`, `show all buttons on this popup`
- `gui object details`, `inspect sap gui`

## Usage

```text
/sap-gui-object-details tree
/sap-gui-object-details wnd 1
/sap-gui-object-details menu
/sap-gui-object-details type GuiButton
/sap-gui-object-details type GuiStatusbar
/sap-gui-object-details id wnd[1]/usr/ctxtKO008-TRKORR
```

Conversational forms:

- "Dump the current screen — I want to see every component"
- "Show all GuiButton elements on the active window"
- "What does the field `wnd[1]/usr/ctxtKO008-TRKORR` contain?"
- "List the menu items of the application toolbar"

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- `RZ11` parameter `sapgui/user_scripting` set to TRUE on the SAP server

## Output

Writes the dump to `{WORK_TEMP}\sap_gui_dump_<timestamp>.txt`. Designed to be
read by Claude (compact, structured) — not by humans (terse, no prose).

## Limitations

- Read-only — never modifies the screen state
- Dumps the **current** screen only; cannot navigate forward to inspect future
  screens. Run after each step in your manual repro.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
