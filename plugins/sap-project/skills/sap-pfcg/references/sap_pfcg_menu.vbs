' sap_pfcg_menu.vbs  --  NEEDS_RECORDING (Mode R): the PFCG Menu tab genuinely cannot be drive-captured.
'
' Adding a transaction on the PFCG Menu tab (tabsTABSTRIP1/tabpTAB9, subscreen
' SAPLPRGN_TREE:0321) is driven through a GuiShell Toolbar control
' (.../cntlTOOL_CONTROL/shellcont/shell, OLE class "SAP.Toolbar.1"), NOT through
' an ordinary GuiButton or menu entry. The "add transaction" action is a toolbar
' button fired via shell.pressButton("<fcode>"). That <fcode> is a VIRTUAL
' toolbar button: it is not exposed anywhere in the dumped property tree (GuiShell
' toolbar buttons are not child components with stable, discoverable ids). So
' drive-mode -- which learns a flow by dumping findById paths screen by screen --
' cannot discover the function code and therefore cannot reproduce the click.
'
' This is exactly the "write-heavy transaction where a real operator's exact
' clicks are wanted as ground truth" case that /sap-gui-probe flags for Mode R
' (--record): it needs a human to drive SAP's OWN built-in Script Recording and
' Playback so the recorder emits the real shell.pressButton fcode. Capture it
' that way (/sap-gui-probe --record), then replace this stub with the recorded,
' token-substituted driver (Tier-3 attach + session-lock + a golden-screen
' baseline), per the skill plan.
'
' Until then this stays a plain (non-driving) stub: it declares no session path,
' includes no attach library, and binds no scripting engine, so it carries no
' golden-screen baseline and never guesses a click. The owning SKILL.md emits
' PFCG_NEEDS_RECORDING for the add-tcodes / remove-tcodes legs that route here.
WScript.Echo "PFCG: NEEDS_RECORDING -- capture this GUI flow via /sap-gui-probe --record (see SKILL.md)"
WScript.Quit 3
