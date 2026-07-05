# SAP GUI Scripting — Component & API Reference

Authoring reference for every SAP-driving VBS in the sap-dev plugins:
component-ID path grammar, type prefixes, actions/methods, VKey codes,
toolbar positions, and the load-bearing runtime gotchas.

Read this when writing or repairing a `references/*.vbs`, when decoding a
recorded/probed script into findById paths, or when a control ID doesn't
resolve on a new release. Pairs with
[`language_independence_rules.md`](language_independence_rules.md) — that rule
governs *how* you may use these IDs (identify by ID + DDIC field name, never
by displayed `.Text`/`.Tooltip`/title); this doc is the ID/API vocabulary
itself.

> Promoted from the former `sap-gui-record` skill so the knowledge is shared
> across `sap-gui-probe`, `sap-gui-skill-scaffold`, and every workbench skill,
> rather than trapped inside one invocable skill.

---

## Component ID path format

SAP GUI component IDs are a hierarchical path:

```
wnd[N] / usr / TYPE<FIELD_NAME>
  |       |      |     |
  |       |      |     +-- SAP field name (e.g. RS38L-NAME)
  |       |      +-------- Type prefix (ctxt, txt, btn, rad, ...)
  |       +--------------- User area (main screen content)
  +----------------------- Window index (0=main, 1=popup, 2=nested popup)
```

### Window and area segments

| Segment | Description |
|---|---|
| `wnd[0]` | Main window |
| `wnd[1]` | First popup / dialog window |
| `wnd[2]` | Second popup / dialog (nested) |
| `usr` | User area (main screen content) |
| `tbar[0]` | System toolbar (topmost — Enter, Back, Save, etc.) |
| `tbar[1]` | Application toolbar (below system toolbar — F5–F12 functions) |
| `sbar` | Status bar (bottom of screen) |
| `mbar` | Menu bar |
| `titl` | Title bar |

### Subscreen notation

Subscreens use the format `ssubSCREEN_NAME:PROGRAM_NAME:DYNPRO_NUMBER`.

Example: `ssubTS_SCREEN:SAPLSD11:1201` = subscreen `TS_SCREEN` in program
`SAPLSD11`, dynpro `1201`.

---

## Component type prefix table

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

## Common actions and methods

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

## Shell control methods (grid, tree, editor)

These work on shell controls (ALV grid, tree, ABAP editor):

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

## VKey code reference

Prefer VKey over menu-text navigation (locale-independent, per
`language_independence_rules.md`).

| VKey | Keyboard | SAP Function |
|---|---|---|
| 0 | Enter | Confirm / Execute |
| 1 | F1 | Help |
| 2 | F2 | Details / Pick |
| 3 | F3 | Back |
| 4 | F4 | F4 Help / Value List |
| 5 | F5 | Create / New |
| 8 | F8 | Execute / Run |
| 11 | Ctrl+S | Save |
| 12 | F12 | Cancel |
| 14 | Shift+F2 | Delete (context-dependent) |
| 15 | Shift+F3 | Exit |
| 26 | Ctrl+F2 | Syntax Check |
| 27 | Ctrl+F3 | Activate |
| 28 | Ctrl+F4 | (varies) |
| 33 | Ctrl+Shift+F5 | (varies) |

(F6/F7/F9/F10 and the Shift/Ctrl-Shift combinations vary by transaction —
confirm against a live dump before relying on them.)

---

## Common toolbar button positions

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

**Note:** Application-toolbar (`tbar[1]`) button positions vary by
transaction. Confirm the exact positions from a live dump
(`/sap-gui-inspect`) or a probe/record capture (`/sap-gui-probe`).

---

## Known runtime limitations

### AbapEditor swallows status-bar messages

The front-end AbapEditor control (`cntlEDITOR/shellcont/shell`) swallows all
status-bar messages in SE38 and SE37. After a syntax check or save,
`wnd[0]/sbar` returns empty `.MessageType` and `.Text`. Read the error grid at
`wnd[0]/shellcont/shell/shellcont[1]/shell` instead (see the sap-se37 /
sap-se38 SKILL.md for the exact parse).

### Status-bar properties

| Property | Description |
|---|---|
| `.Text` | Status-bar message text (translated — never branch on it) |
| `.MessageType` | `S` Success · `W` Warning · `E` Error · `I` Info · `A` Abort |

### Detecting popups at runtime

`oSession.ActiveWindow.Id` returns the currently focused window's ID. Detect a
popup with `If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then ...`, then
address the next action to `wnd[1]/...` rather than `wnd[0]/...`.

---

## Official SAP documentation

SAP GUI Scripting API reference:
https://help.sap.com/docs/sap_gui_for_windows/b47d018c3b9b45e897faf66a6c0885a8/babdf65f4d0a4bd8b40f5ff132cb12fa.html
