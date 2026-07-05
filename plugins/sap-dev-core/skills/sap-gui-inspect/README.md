# SAP GUI Inspect Skill

Inspects the currently active SAP GUI session — **structurally** (dumps component
IDs + properties) and/or **visually** (screenshots) — so a stuck GUI script can be
understood: an unexpected popup appeared, a control ID changed between releases, a
field is greyed-out, or a screen transition hung.

Other skills call this mid-flow to discover the actual current screen state.

> Replaces the former `/sap-gui-object-details` (structural) and
> `/sap-gui-diagnose` (visual) skills, folded into one inspection skill.

## Skill Overview

**Structural modes** (via `sap_gui_object_details.vbs`):

| Mode | What it dumps |
|---|---|
| `tree` | Full component tree of all open windows |
| `wnd <n>` | Component tree of one specific window (e.g. `wnd 1` for a popup) |
| `menu` | Menu-bar tree (mbar children, recursive) |
| `type` | All components of a chosen type (`GuiButton`, `GuiShell`, `GuiStatusbar`, `GuiTableControl`, `GuiMenu`, `GuiToolbar`, …) |
| `id` | Full property dump of a single component by its `findById` path |

**Visual mode** (`screenshot`, via HardCopy + compose):

| Sub-mode | What it produces |
|---|---|
| `topmost` | Just the highest-numbered window's PNG (cheapest for the vision call) |
| `composite` (default) | Composite PNG of all windows + topmost PNG |
| `full` | composite + topmost + the structural `wnd` dump of the topmost window |

## Auto-Trigger Keywords

- `dump screen`, `inspect screen`, `inspect sap gui`, `what's on the current screen`
- `show all buttons on this popup`, `gui object details`
- `screenshot the sap gui`, `visual diagnose`, `capture the stuck screen`

## Usage

```text
/sap-gui-inspect tree
/sap-gui-inspect wnd 1
/sap-gui-inspect menu
/sap-gui-inspect type GuiButton
/sap-gui-inspect id wnd[1]/usr/ctxtKO008-TRKORR
/sap-gui-inspect screenshot            # composite + topmost PNG
/sap-gui-inspect screenshot full       # + structural dump of the topmost window
/sap-gui-inspect screenshot topmost    # cheapest visual
```

Conversational forms:

- "Dump the current screen — I want to see every component"
- "Show all GuiButton elements on the active window"
- "Screenshot the stuck SAP GUI so you can see what popup is open"

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- `RZ11` parameter `sapgui/user_scripting` set to TRUE on the SAP server

## Output

- Structural modes write a compact, structured dump to `{RUN_TEMP}\sap_gui_objects_<mode>.txt`.
- `screenshot` writes `composite.png` / `topmost.png` (+ optional `object_details.txt`)
  into a per-run `{WORK_TEMP}\sap_inspect_<timestamp>\` directory; the orchestrator
  reads the PNG with the Read tool.

## Limitations

- Read-only — never modifies the screen state.
- Dumps the **current** screen only; cannot navigate forward. Run after each step.
- `HardCopy` (visual) is best-effort — fails on minimised windows, and omits
  tooltips / dropdowns / context menus. Fall back to `/sap-gui-probe --record` if the
  diagnosis hinges on one of those.

## Version

- Skill Version: 2.0.0
- Last Updated: 2026-07-05

## License

GPL-3.0 License - See LICENSE file in repository root.
