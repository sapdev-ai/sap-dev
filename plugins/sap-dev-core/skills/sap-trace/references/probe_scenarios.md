# /sap-trace — `/sap-gui-probe` scenarios to auto-capture the `PH_*` IDs

These are **read-only / dry** probe scenarios: they only DISPLAY an existing
trace/measurement (no activate, deactivate, delete, or measure), so every step
is auto-proceed in `/sap-gui-probe`'s default `confirm` mode — nothing pauses,
nothing is mutated. The probe dumps each screen's full property tree (IDs,
types, Changeable, tooltips, popup transitions) and emits a recording-style VBS,
which gives you every `PH_*` value.

## Preconditions
- `/sap-login` done (active SAP GUI session, scripting on).
- A trace/measurement already exists:
  - ST05: SQL Trace activated → small workload → deactivated.
  - SAT: one saved measurement.

## Run 1 — ST05
Paste this whole block as the `/sap-gui-probe` scenario:

```
/sap-gui-probe Probe transaction ST05 to capture control IDs for a READ-ONLY SQL-trace display flow. Do NOT activate, deactivate, or delete any trace — display only. Steps: (1) Open ST05. (2) On the initial Performance Trace screen, dump the full property tree; I need the application-toolbar buttons, especially "Display Trace" (note "Activate Trace"/"Deactivate Trace" but do NOT press them). (3) Ensure the trace type "SQL Trace" is selected; do not toggle activation. (4) Press the "Display Trace" button. (5) On the trace-records restriction/selection screen, dump the property tree; I need the "User", "From time/date" and "To time/date" input fields, and tell me the window index (wnd[0] full screen vs wnd[1] popup). Leave the fields at their defaults. (6) Press Execute (F8) to show the basic trace list. (7) Dump the basic trace list screen. (8) Press "Summarize SQL Statements" (may be labelled "Summarize Trace" or "Compress"). (9) Dump the summarized SQL-statements screen; I need the ALV grid shell id (the .../shellcont/shell control) and its toolbar. (10) Stop here — do NOT export to file and do NOT change anything.
```

What each dump yields:
| Screen dumped | Constant(s) |
|---|---|
| initial ST05 toolbar | `PH_DISPLAY_TRACE_BTN` |
| restriction/selection screen | `PH_USER_FIELD`, `PH_FROM_FIELD`, `PH_TO_FIELD` + window index |
| basic trace list toolbar | `PH_SUMMARIZE_BTN` |
| summarized SQL grid | `RESULT_GRID` |

## Run 2 — SAT
```
/sap-gui-probe Probe transaction SAT to capture control IDs for a READ-ONLY runtime-analysis (ABAP trace) evaluation flow. Do NOT start a new measurement and do NOT delete anything — open an existing measurement and display its Hit List only. Steps: (1) Open SAT. (2) On the initial screen, dump the property tree; I need the tabstrip tabs, especially "Evaluate" (and "Measure"). (3) Select the "Evaluate" tab (tab .select, not .press). (4) Dump the Evaluate tab; I need the measurements list/tree shell id (.../shellcont/shell). (5) Select the most recent measurement (top entry) and open it for evaluation — usually a double-click on the tree node; capture the open action AND the node key. (6) Dump the evaluation desktop; I need the tool buttons, especially "Hit List". (7) Open the "Hit List". (8) Dump the Hit List screen; I need the ALV grid shell id (.../shellcont/shell). (9) Stop here — do NOT delete or re-measure.
```

What each dump yields:
| Screen dumped | Constant(s) |
|---|---|
| initial SAT tabstrip | `PH_EVALUATE_BTN` (a GuiTab → `.select`) |
| Evaluate tab | `PH_MEAS_LIST` |
| open action | `PH_OPEN_MEASUREMENT` (button id OR `doubleClickNode "<key>"`) |
| evaluation desktop | `PH_HITLIST_BTN` |
| Hit List grid | `RESULT_GRID` |

## After the probe
1. The probe writes per-screen property dumps + a synthesized `.vbs`.
2. Paste those back (or the `.vbs`) and I'll fill every `PH_*` constant and apply
   the adaptations (window index, tab `.select`, menu-vs-button, measurement
   double-click, classic-list export) in `sap_trace_st05.vbs` / `sap_trace_sat.vbs`.
3. Dry-run the GUI path → expect `EXPORTED=<path> rows=<n>`, then
   `/sap-trace --source st05` end to end.

## Notes
- Default `confirm` mode is correct here — none of these steps are Save/Activate/
  Delete or VKey 11/14/27/28/33, so the probe auto-proceeds without pausing. (F8
  = VKey 8 is read-only.) No `--auto` needed.
- If ST05's restriction step is a full screen (`wnd[0]`) rather than a popup, the
  template's `wnd[1]` guard must be removed — the dump's window index tells us which.
- If the summarized list has no `GuiShell` (classic list on older kernels), we
  switch the export to System → List → Save → Local File.
