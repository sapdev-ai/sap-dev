# /sap-trace — `/sap-gui-record` capture checklist for the `PH_*` IDs

The two GUI templates (`sap_trace_st05.vbs`, `sap_trace_sat.vbs`) ship with
`PH_*` placeholder control IDs. This checklist captures the real IDs on your SAP
release so the `--source st05|sat` path runs. The ALV-export block is already
complete (reused from `/sap-se16n`) — you only need the transaction-specific IDs.

## 0. Preconditions
- Logged in (`/sap-login`); server scripting on (`sapgui/user_scripting = TRUE`).
- A trace must already EXIST (v1 displays, it does not record):
  - **ST05**: activate SQL Trace → run a small workload → deactivate.
  - **SAT**: run any program once under SAT measurement so a saved result exists.

## 1. Three tools — use them together
| Tool | Use for |
|---|---|
| `/sap-gui-record` | Capture the **click order** + the exact `findById` paths/actions as you click through. |
| `/sap-gui-object-details` | On a given screen, dump **all controls of a type** (filter `GuiButton`, `GuiShell`, `GuiTab`, `GuiToolbar`) with their IDs + tooltips — the fastest way to nail the grid and toolbar IDs without guessing. |
| `/sap-gui-probe` | Optional all-in-one: drives the txn step-by-step and dumps the property tree (IDs, types, Changeable, popup transitions) at every screen. |

Recommended: one `/sap-gui-record` pass for the *sequence* + a `/sap-gui-object-details`
dump on each screen for the *grid + button IDs*.

## 2. ST05 capture sequence
| # | Do this in SAP GUI | Fills constant | Expected ID shape / type | Notes |
|---|---|---|---|---|
| 1 | `/nST05` | — (okcd) | — | already in template |
| 2 | Ensure **SQL Trace** is the selected trace type | — | checkbox/toggle | so Display shows SQL |
| 3 | Click **Display Trace** | `PH_DISPLAY_TRACE_BTN` | `wnd[0]/tbar[1]/btn[N]` (GuiButton); may instead be a menu `wnd[0]/mbar/...` | record reveals btn index |
| 4 | On the **restriction screen**, set User / From / To, press **Execute (F8)** | `PH_USER_FIELD`, `PH_FROM_FIELD`, `PH_TO_FIELD` | `ctxt...` (GuiCTextField) | **window index caveat ↓** |
| 5 | On the basic trace list, click **Summarize SQL Statements** (a.k.a. "Summarize Trace" / "Compress") | `PH_SUMMARIZE_BTN` | `wnd[0]/tbar[1]/btn[N]` or a menu select | |
| 6 | With the summarized grid shown, dump `GuiShell` via `/sap-gui-object-details` | `RESULT_GRID` | `wnd[0]/usr/cntl<NAME>/shellcont/shell` (GuiGridView) | **classic-list caveat ↓** |

### ST05 caveats
- **Restriction window index.** On modern ST05 (likely on 1909) step 4 is a
  **full selection screen = `wnd[0]`**. If so: set the field IDs to `wnd[0]/usr/...`,
  and in the template **remove the `If Not oSession.findById("wnd[1]") …` popup
  guard**, replacing it with direct field fills + `sendVKey 8` (F8). If your
  release shows a **popup = `wnd[1]`**, keep the guard and just paste the field IDs.
- **Summarize may be a menu, not a toolbar button.** If so, capture the
  `wnd[0]/mbar/menu[i]/menu[j]…` path and change `PressIfExists` to a `.select`
  on that menu node (or find the equivalent application-toolbar button).
- **Classic-list contingency.** If the summarized view is a classic list (no
  `GuiShell` appears in the dump), export via menu **System → List → Save →
  Local File** (`wnd[0]/mbar/…`) choosing "Text with Tabs"/"unconverted" instead
  of the ALV context export. Tell me and I'll swap `ExportGrid` for a list-export sub.

## 3. SAT capture sequence
| # | Do this in SAP GUI | Fills constant | Expected ID shape / type | Notes |
|---|---|---|---|---|
| 1 | `/nSAT` | — (okcd) | — | template |
| 2 | Click the **Evaluate** tab | `PH_EVALUATE_BTN` | tabstrip tab `wnd[0]/usr/tabs<NAME>/tabp<EVAL>` (GuiTab) — **`.select`, not `.press`** | tab ≠ button |
| 3 | Note the **measurements list** (tree/grid) | `PH_MEAS_LIST` | `wnd[0]/usr/cntl<NAME>/shellcont/shell` (GuiShell tree/grid) | |
| 4 | Select your measurement + **Display/Evaluate** (often a **double-click**) | `PH_OPEN_MEASUREMENT` | button `tbar[1]/btn[N]` OR tree `oTree.doubleClickNode "<key>"` | "latest" = top node |
| 5 | Open **Hit List** in the evaluation desktop | `PH_HITLIST_BTN` | tool/toolbar button id | release-specific |
| 6 | Dump `GuiShell` on the hit list | `RESULT_GRID` | `.../shellcont/shell` (GuiGridView) | |

### SAT caveats
- **Evaluate is a tabstrip tab** → `.select` and a `tabp…` ID. `PressIfExists`
  uses `.press`; for a tab I'll switch it to `.select` once you give me the ID.
- **Opening a measurement is usually a tree double-click**
  (`oTree.doubleClickNode "<nodeKey>"`), not a button. Capture the node key; for
  "latest", capture the first/top node key (e.g. via `getNodeKeyByPath`).
- The **Hit List** is one tool inside the SAT evaluation desktop; its button ID
  is release-specific — `/sap-gui-object-details` (GuiButton/GuiToolbar) on that
  screen lists it.

## 4. ID worksheet (fill, then paste back)
```
ST05
  PH_DISPLAY_TRACE_BTN = wnd[0]/...
  PH_USER_FIELD        = wnd[?]/usr/...      (window index: 0 full-screen / 1 popup)
  PH_FROM_FIELD        = wnd[?]/usr/...
  PH_TO_FIELD          = wnd[?]/usr/...
  PH_SUMMARIZE_BTN     = wnd[0]/...          (button or menu path)
  RESULT_GRID          = wnd[0]/usr/cntl.../shellcont/shell
SAT
  PH_EVALUATE_BTN      = wnd[0]/usr/tabs.../tabp...   (.select)
  PH_MEAS_LIST         = wnd[0]/usr/cntl.../shellcont/shell
  PH_OPEN_MEASUREMENT  = <button id>  OR  doubleClickNode "<key>"
  PH_HITLIST_BTN       = <button id>
  RESULT_GRID          = wnd[0]/usr/cntl.../shellcont/shell
```

## 5. Fill + re-test
1. Paste each captured ID into the matching `PH_*` constant in the VBS.
2. Apply the caveats (window index; `.press`→`.select` for tabs; menu-vs-button;
   double-click for the measurement; classic-list export if needed).
3. Dry-run the GUI path on a recorded trace → expect `EXPORTED=<path> rows=<n>`.
4. Run `/sap-trace --source st05` end to end (the analyzer half is already proven).

> Fastest route: paste the recorded `.vbs` (or the `/sap-gui-object-details`
> dumps) back and I'll fill every `PH_*` constant and apply the window-index /
> tab-select / menu / double-click adaptations in both templates for you.
