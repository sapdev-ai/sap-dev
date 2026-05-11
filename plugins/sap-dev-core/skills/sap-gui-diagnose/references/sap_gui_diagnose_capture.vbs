' =============================================================================
' sap_gui_diagnose_capture.vbs  -  Capture BMP screenshots of every visible
'                                  SAP GUI window in the active session.
'
' Iterates wnd[0]..wnd[5] in the active session, calls HardCopy on each that
' exists, and writes a TSV manifest with one row per window:
'
'   WND  PATH  TITLE  LEFT  TOP  WIDTH  HEIGHT
'
' The PowerShell compose step (sap_gui_diagnose_compose.ps1) reads this
' manifest and stacks the BMPs in screen-space order to produce a single
' composite PNG that mimics what the operator actually sees.
'
' Tokens (replaced by the calling PowerShell wrapper):
'   %%OUTPUT_DIR%%   Directory to write per-window BMPs into. Created if
'                    missing. Existing wnd_*.bmp files are overwritten.
'   %%MANIFEST%%     Absolute path of the TSV manifest file (UTF-16 LE).
'
' Caveats per SAP GUI Scripting docs:
'   - HardCopy is "not for productive use"; treat as best-effort diagnostic.
'   - HardCopy fails on minimized / off-screen windows. We log the failure
'     for that window and keep going.
'   - Tooltips, dropdowns, and balloon dialogs are not always captured.
'
' Output (last line, parseable):
'   DONE: <N> window(s) captured.
'   ERROR: <text>
' =============================================================================
Option Explicit

Const MAX_WND     = 5
Const IMG_FORMAT  = 0   ' 0 = unspecified (BMP, broadest compat across releases)

Dim OUTPUT_DIR : OUTPUT_DIR = "%%OUTPUT_DIR%%"
Dim MANIFEST   : MANIFEST   = "%%MANIFEST%%"

If Trim(OUTPUT_DIR) = "" Or Trim(MANIFEST) = "" Then
    WScript.Echo "ERROR: OUTPUT_DIR or MANIFEST token not filled in."
    WScript.Quit 1
End If

Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
If Not oFSO.FolderExists(OUTPUT_DIR) Then
    On Error Resume Next
    oFSO.CreateFolder(OUTPUT_DIR)
    If Err.Number <> 0 Then
        WScript.Echo "ERROR: Could not create output dir " & OUTPUT_DIR & ": " & Err.Description
        WScript.Quit 1
    End If
    Err.Clear
    On Error GoTo 0
End If

' --- Attach to SAP GUI -------------------------------------------------------
Dim oSAPGUI, oApplication, oSession
Dim oCandidate, oSessIter

On Error Resume Next
Set oSAPGUI = GetObject("SAPGUI")
If Err.Number <> 0 Or oSAPGUI Is Nothing Then
    WScript.Echo "ERROR: SAP GUI is not running."
    WScript.Quit 1
End If
Err.Clear
On Error GoTo 0

Set oApplication = oSAPGUI.GetScriptingEngine
If oApplication Is Nothing Then
    WScript.Echo "ERROR: Could not get SAP Scripting Engine."
    WScript.Quit 1
End If

Set oSession = Nothing
On Error Resume Next
For Each oCandidate In oApplication.Children
    For Each oSessIter In oCandidate.Children
        Set oSession = oSessIter
        Exit For
    Next
    If Not (oSession Is Nothing) Then Exit For
Next
On Error GoTo 0

If oSession Is Nothing Then
    WScript.Echo "ERROR: No SAP GUI session found. Run /sap-login first."
    WScript.Quit 1
End If

' --- Open manifest as UTF-16 LE (consistent with other skills) ---------------
Dim oManifest
Set oManifest = oFSO.CreateTextFile(MANIFEST, True, True)   ' overwrite, Unicode
oManifest.WriteLine "WND" & vbTab & "PATH" & vbTab & "TITLE" & vbTab & _
                    "LEFT" & vbTab & "TOP" & vbTab & "WIDTH" & vbTab & "HEIGHT"

' --- Iterate wnd[0]..wnd[MAX_WND] -------------------------------------------
Dim i, sId, oWnd, sBmpPath, sTitle, lLeft, lTop, lWidth, lHeight, captured
captured = 0

For i = 0 To MAX_WND
    sId = "wnd[" & i & "]"
    On Error Resume Next
    Set oWnd = Nothing
    Set oWnd = oSession.findById(sId)
    If Err.Number <> 0 Or oWnd Is Nothing Then
        ' Window doesn't exist - skip silently.
        Err.Clear
    Else
        Err.Clear
        sTitle = ""  : sTitle = oWnd.Text
        If Err.Number <> 0 Then sTitle = "(unreadable)" : Err.Clear
        lLeft = -1   : lLeft  = oWnd.ScreenLeft
        If Err.Number <> 0 Then lLeft = -1 : Err.Clear
        lTop = -1    : lTop   = oWnd.ScreenTop
        If Err.Number <> 0 Then lTop = -1 : Err.Clear
        lWidth = 0   : lWidth = oWnd.Width
        If Err.Number <> 0 Then lWidth = 0 : Err.Clear
        lHeight = 0  : lHeight = oWnd.Height
        If Err.Number <> 0 Then lHeight = 0 : Err.Clear

        sBmpPath = oFSO.BuildPath(OUTPUT_DIR, "wnd_" & i & ".bmp")

        ' HardCopy: oWnd.HardCopy(filename, imageFormat). Returns the path
        ' on success; raises on failure (e.g. minimized window).
        oWnd.HardCopy sBmpPath, IMG_FORMAT
        If Err.Number <> 0 Then
            WScript.Echo "WARN: HardCopy failed on " & sId & ": " & Err.Description
            Err.Clear
            ' Still record the manifest row with empty PATH so the composer
            ' can echo the title even when the BMP is unavailable.
            sBmpPath = ""
        Else
            captured = captured + 1
            WScript.Echo "INFO: Captured " & sId & " -> " & sBmpPath & _
                         " title='" & sTitle & "'" & _
                         " rect=(" & lLeft & "," & lTop & " " & lWidth & "x" & lHeight & ")"
        End If

        oManifest.WriteLine i & vbTab & sBmpPath & vbTab & sTitle & vbTab & _
                            lLeft & vbTab & lTop & vbTab & _
                            lWidth & vbTab & lHeight
    End If
    On Error GoTo 0
Next

oManifest.Close

If captured = 0 Then
    WScript.Echo "ERROR: No windows captured. SAP GUI may be minimized or HardCopy is blocked."
    WScript.Quit 1
End If

WScript.Echo "DONE: " & captured & " window(s) captured."
WScript.Quit 0
