' sap_se14_adjust.vbs  --  NEEDS_RECORDING placeholder for a release-sensitive SAP GUI write leg.
'
' This flow is captured live per release with /sap-gui-probe --record at install /
' build time, then this file is replaced with the recorded, token-substituted driver
' (Tier-3 attach + session-lock + golden-screen baseline) per the skill plan. Until
' captured, the owning SKILL.md emits NEEDS_RECORDING and NEVER guesses a click.
'
' Intentionally a plain (non-driving) script: it declares no session path, includes no
' attach library, and binds no Scripting engine, so it carries no golden-screen baseline.
WScript.Echo "SE14: NEEDS_RECORDING -- capture this GUI flow via /sap-gui-probe --record (see SKILL.md)"
WScript.Quit 3
