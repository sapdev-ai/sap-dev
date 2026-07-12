' sap_se14_unlock.vbs  --  NEEDS_RECORDING placeholder for the SE14 conversion-
' recovery write leg (unlock / continue-adjustment / restart-conversion).
'
' This leg cannot be captured yet, and the reason is STRUCTURAL, not a scheduling
' gap: the SE14 unlock / "continue adjustment" / "restart conversion" controls
' only materialize when the table is in a CONVERSION_TERMINATED state. On a
' healthy table (CONSISTENT or ADJUST_NEEDED) SE14 exposes NO static unlock
' function -- there is simply no button / menu to record against. Reaching
' CONVERSION_TERMINATED requires deliberately starting a database conversion and
' killing it mid-flight (aborting the running conversion work process / job) on a
' shared development system, which is neither safe nor reliably reproducible. So
' this flow needs SAP's built-in Script Recorder run against a GENUINELY
' terminated conversion -- captured opportunistically if a real terminated
' conversion appears, never manufactured on a shared box. (Same class of gap as
' the pfcg menu-add GuiShell-toolbar control that is not dump-discoverable.)
'
' Until captured, the owning SKILL.md keeps the `unlock` mode marked
' NEEDS_RECORDING and NEVER guesses a click.
'
' Intentionally a plain (non-driving) script: it declares no session path,
' includes no attach library, and binds no Scripting engine, so it carries no
' golden-screen baseline.
WScript.Echo "SE14: NEEDS_RECORDING -- unlock/continue-conversion controls exist only in a CONVERSION_TERMINATED state; capture via /sap-gui-probe --record against a genuinely terminated conversion (see SKILL.md)"
WScript.Quit 3
