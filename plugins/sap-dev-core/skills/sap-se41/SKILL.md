---
name: sap-se41
description: |
  Manages PF-STATUS (GUI status) subobjects of an SE41 Menu Painter interface
  (program / function pool) on a live SAP system via SAP GUI Scripting.
  Supports the operations CREATE, UPDATE, DISPLAY, DELETE, ACTIVATE,
  DEACTIVATE, COPY and an existence CHECK. SE41 has no Upload/Download for
  status definitions — function codes are entered field by field from a
  pipe-delimited definition file. Package (development class) changes are
  delegated to /sap-change-package.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<operation> <program-name> <status-name> [options]"
---

# SAP SE41 Menu Painter Skill

You manage PF-STATUS (GUI status) subobjects of an interface (program /
function pool) on a live SAP system via SE41 using SAP GUI Scripting.

A single self-contained VBScript (embedded in **Step 4**) performs **one**
operation per run, selected by the `OPERATION` token:

| Operation | What it does |
|---|---|
| `CHECK` | Reports `EXIST` / `NOT_EXIST` for a status (no UI change) |
| `DISPLAY` | Opens the status read-only |
| `CREATE` | Creates a new status from a definition file, saves, activates |
| `UPDATE` | Opens an existing status in change mode, re-applies the definition file, saves, activates |
| `DELETE` | Deletes the status (confirmation), then activates to commit |
| `ACTIVATE` | Activates the interface / status |
| `DEACTIVATE` | Reports `NOT_SUPPORTED` — SE41 has no deactivate (see note) |
| `COPY` | Copies the status to a target program/status (same subobjects) |

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow (used indirectly via `/sap-change-package`) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |

**Delegations:**

| Need | Delegate to |
|---|---|
| Change the package (development class) of the interface | `/sap-change-package` (see [Package Changes](#package-changes)) |
| Resolve a transport request | handled inside `/sap-change-package` |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` / `*_run.vbs` and the `_run.json` state) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_se41_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se41_run.json" -Skill sap-se41 -ParamsJson "{\"operation\":\"<OPERATION>\",\"program\":\"<PROGRAM>\",\"status\":\"<STATUS>\"}"
```

---

## Step 1 — Parse the Operation and Parameters

Resolve `OPERATION` (uppercase) from the request, then collect only the
parameters that operation needs.

| Parameter | Description | Required for |
|---|---|---|
| `OPERATION` | `CREATE`/`UPDATE`/`DISPLAY`/`DELETE`/`ACTIVATE`/`DEACTIVATE`/`COPY`/`CHECK` | all |
| `PROGRAM` | Program / function pool (interface) name, e.g. `SAPLZHKT05` | all |
| `STATUS` | PF-STATUS name (Z/Y namespace), e.g. `ZTEST01` | all except pure interface `ACTIVATE` |
| `STATUS_TYPE` | `DIAL` (Normal Screen), `POPUP` (Dialog Box), `CONTEXT` (Context Menu) | `CREATE` |
| `SHORT_TEXT` | Short description, max 70 chars | `CREATE` |
| `DEF_FILE` | Path to the pipe-delimited definition file (Step 2) | `CREATE`, `UPDATE` |
| `TARGET_PROGRAM` | Target interface for the copy | `COPY` |
| `TARGET_STATUS` | Target status name for the copy | `COPY` |

If a required parameter is missing, ask the user for it before continuing.
For `CREATE`, if status type / short text are not provided, ask:
> "This is a new status. Please confirm the status type (DIAL/POPUP/CONTEXT) and short text."

If the request is to **change the package** of the interface, do **not** use
this VBS — jump to [Package Changes](#package-changes).

---

## Step 2 — Prepare the Status Definition File (CREATE / UPDATE only)

Skip this step for `CHECK`, `DISPLAY`, `DELETE`, `ACTIVATE`, `DEACTIVATE`, `COPY`.

SE41 has **no Upload/Download** for status definitions. Function code
assignments are entered field by field. The VBS reads definitions from a
pipe-delimited text file.

### Definition File Format

Each line: `TYPE|POSITION|CODE|TEXT`

| Line type | Position | Code | Text |
|---|---|---|---|
| `STD` | Toolbar slot 1-13 | Function code | Function text |
| `FK` | Key name (F5, Shift-F1, etc.) | Function code | Function text |

Lines starting with `#` are comments. Empty lines are ignored.

### Standard Toolbar Positions

| Position | Standard Use | SAP Control |
|---|---|---|
| 1 | Enter / Execute | `txt[1,9]` |
| 2 | (varies) | `txt[12,9]` |
| 3 | Back | `txt[23,9]` |
| 4 | Exit | `txt[34,9]` |
| 5 | Cancel | `txt[45,9]` |
| 6 | Print | `txt[56,9]` |
| 7 | Find | `txt[67,9]` |
| 8 | Find Next | `txt[78,9]` |
| 9 | First Page | `txt[89,9]` |
| 10 | Previous Page | `txt[100,9]` |
| 11 | Next Page | `txt[111,9]` |
| 12 | Last Page | `txt[122,9]` |
| 13 | (custom) | `txt[133,9]` |

### Available Function Keys

**Recommended keys** (SAP suggests standard usage):

| Key name | Typical Use | Grid row |
|---|---|---|
| `F2` | Choose / Select | 14 |
| `F9` | Select | 15 |
| `Shift-F2` | Delete | 16 |
| `Shift-F4` | Save without check | 17 |
| `Shift-F5` | Other object | 18 |

**Freely assigned keys**:

| Key name | Grid row | Key name | Grid row |
|---|---|---|---|
| `F5` | 21 | `Shift-F1` | 25 |
| `F6` | 22 | `Shift-F6` | 26 |
| `F7` | 23 | `Shift-F7` | 27 |
| `F8` | 24 | `Shift-F8` | 28 |
| | | `Shift-F9` | 29 |
| | | `Shift-F11` | 30 |
| | | `Shift-F12` | 31 |

**System-reserved keys** (cannot be assigned): F1, F3, F4, F10, F11, F12, Shift-F3, Shift-F10

### Example Definition File

```
# Standard toolbar
STD|3|BACK|Back
STD|4|RW|Exit
STD|5|CANC|Cancel
# Function keys
FK|F5|ZEXEC|Execute Report
FK|F6|ZREFR|Refresh
FK|F8|ZPRINT|Print List
FK|Shift-F1|ZATTR|Attributes
```

### Create the Definition File

1. Write the definition file to: `{WORK_TEMP}\<STATUS_NAME>.def`
   - Use the Write tool with the pipe-delimited content.
2. Confirm by reading back the first few lines.

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Run the Operation

### 4a. Write the VBScript

Copy the VBScript below **verbatim** into `{RUN_TEMP}\sap_se41_ops.vbs`
(use the Write tool). It is the single source of truth for all operations.

```vbscript
' =============================================================================
' sap_se41_ops.vbs  -  SAP GUI Scripting: SE41 Menu Painter subobject operations
'
' Attaches to an existing SAP GUI session and performs ONE operation on a
' PF-STATUS (GUI status) subobject of an interface (program / function pool)
' via SE41.
'
' Supported operations (token %%OPERATION%%):
'   CHECK       Report EXIST / NOT_EXIST for the status (no UI change)
'   DISPLAY     Open the status in display mode (read-only)
'   CREATE      Create a new status from a definition file
'   UPDATE      Open an existing status in change mode and re-apply definitions
'   DELETE      Delete the status (with confirmation), then activate to commit
'   ACTIVATE    Activate the interface / status
'   DEACTIVATE  Not supported by SE41 - reports NOT_SUPPORTED
'   COPY        Copy the status to a target program/status (same subobjects)
'
' Tokens replaced at run time:
'   %%OPERATION%%       One of the operations above
'   %%PROGRAM%%         Program / interface name      e.g. "ZHKTESTSE51002"
'   %%STATUS%%          PF-STATUS name                e.g. "ZTEST01"
'   %%STATUS_TYPE%%     CREATE only: DIAL | POPUP | CONTEXT
'   %%SHORT_TEXT%%      CREATE only: short description (<=70 chars)
'   %%DEF_FILE%%        CREATE/UPDATE: absolute path to the .def file
'   %%TARGET_PROGRAM%%  COPY only: target interface name
'   %%TARGET_STATUS%%   COPY only: target status name
'   %%SESSION_PATH%%    Optional explicit session path; empty = auto-resolve
'   %%ATTACH_LIB_VBS%%  Absolute path to sap_attach_lib.vbs
'
' Definition file format (pipe-delimited, one entry per line):
'   STD|position|code|text     Standard toolbar slot (1-13)
'   FK|keyname|code|text       Function key (F2,F5-F9,Shift-F1,Shift-F2,etc.)
'
' Component IDs recorded from SAP GUI 7.60 on S/4HANA 1909.
' =============================================================================

Option Explicit

Const OPERATION      = "%%OPERATION%%"
Const PROGRAM_NAME   = "%%PROGRAM%%"
Const STATUS_NAME    = "%%STATUS%%"
Const STATUS_TYPE    = "%%STATUS_TYPE%%"
Const SHORT_TEXT     = "%%SHORT_TEXT%%"
Const DEF_FILE       = "%%DEF_FILE%%"
Const TARGET_PROGRAM = "%%TARGET_PROGRAM%%"
Const TARGET_STATUS  = "%%TARGET_STATUS%%"
Const SESSION_PATH   = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER    = 0
Const VKEY_F2       = 2
Const VKEY_F11_SAVE = 11
Const VKEY_CANCEL   = 12

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

' ---- Function code storage arrays (max 30 entries) ----
Dim arrType(29), arrPos(29), arrCode(29), arrText(29)
Dim iDefCount

' ---- Function key name to grid row mapping ----
Function FKRow(sKey)
    Select Case UCase(sKey)
        Case "F2"        : FKRow = 14
        Case "F9"        : FKRow = 15
        Case "SHIFT-F2"  : FKRow = 16
        Case "SHIFT-F4"  : FKRow = 17
        Case "SHIFT-F5"  : FKRow = 18
        Case "F5"        : FKRow = 21
        Case "F6"        : FKRow = 22
        Case "F7"        : FKRow = 23
        Case "F8"        : FKRow = 24
        Case "SHIFT-F1"  : FKRow = 25
        Case "SHIFT-F6"  : FKRow = 26
        Case "SHIFT-F7"  : FKRow = 27
        Case "SHIFT-F8"  : FKRow = 28
        Case "SHIFT-F9"  : FKRow = 29
        Case "SHIFT-F11" : FKRow = 30
        Case "SHIFT-F12" : FKRow = 31
        Case Else : FKRow = -1
    End Select
End Function

' ---- Standard toolbar position to column mapping ----
Function STBCol(iPos)
    STBCol = 1 + (CInt(iPos) - 1) * 11
End Function

' ---- Lookup function code text from definitions ----
Function LookupText(sCode)
    Dim i
    For i = 0 To iDefCount - 1
        If UCase(arrCode(i)) = UCase(sCode) Then
            LookupText = arrText(i)
            Exit Function
        End If
    Next
    LookupText = sCode
End Function

' ---- Does a control id exist? (language independent) ----
Function CtrlExists(sId)
    Dim o
    On Error Resume Next
    Set o = oSession.findById(sId)
    CtrlExists = (Err.Number = 0)
    Err.Clear
    On Error GoTo 0
End Function

' ---- Dismiss the "logon language differs from original language" popup ----
' When the logon language differs from the object's master/original language
' SAP prompts before letting you maintain the object. Component IDs are
' language independent: btnPUSH1 = maintain in original language (the safe
' default - keeps the master language untouched), btnPUSH2 = change original
' language, btnPUSH_TEXT_3 = cancel. Identify the popup by the unique pair
' btnPUSH1 + btnPUSH_TEXT_3 so we never mistake another dialog for it.
Sub HandleMasterLangPopup()
    If CtrlExists("wnd[1]/usr/btnPUSH1") And CtrlExists("wnd[1]/usr/btnPUSH_TEXT_3") Then
        oSession.findById("wnd[1]/usr/btnPUSH1").Press
        WScript.Sleep 800
        WScript.Echo "INFO: Logon language differs from original language - maintaining in original language."
    End If
End Sub

' ---- Read the pipe-delimited definition file into arrays ----
Sub ReadDefFile()
    Dim oFSO, oFile, sLine, aParts
    Set oFSO = CreateObject("Scripting.FileSystemObject")
    If Not oFSO.FileExists(DEF_FILE) Then
        WScript.Echo "ERROR: Definition file not found: " & DEF_FILE
        WScript.Quit 1
    End If
    iDefCount = 0
    Set oFile = oFSO.OpenTextFile(DEF_FILE, 1)
    Do While Not oFile.AtEndOfStream
        sLine = Trim(oFile.ReadLine)
        If sLine <> "" And Left(sLine, 1) <> "#" Then
            aParts = Split(sLine, "|")
            If UBound(aParts) >= 3 Then
                arrType(iDefCount) = UCase(Trim(aParts(0)))
                arrPos(iDefCount)  = Trim(aParts(1))
                arrCode(iDefCount) = Trim(aParts(2))
                arrText(iDefCount) = Trim(aParts(3))
                iDefCount = iDefCount + 1
            End If
        End If
    Loop
    oFile.Close
    WScript.Echo "INFO: Read " & iDefCount & " definitions from " & DEF_FILE
End Sub

' ---- Navigate to a fresh SE41 initial screen ----
Sub GotoSE41Initial()
    oSession.findById("wnd[0]").maximize
    oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE41"
    oSession.findById("wnd[0]").sendVKey VKEY_ENTER
    WScript.Sleep 1000
End Sub

' ---- Fill program + Status radio + status on the initial screen ----
Sub FillInitial(sProg, sStat)
    oSession.findById("wnd[0]/usr/radRSMPE-B_STATUS").Select
    oSession.findById("wnd[0]/usr/ctxtRSMPE-PROGRAM").Text = UCase(sProg)
    oSession.findById("wnd[0]/usr/ctxtRSMPE-STATUS").Text  = UCase(sStat)
End Sub

' ---- Apply the loaded definitions into the open editor grid ----
Sub ApplyDefinitions()
    Dim i, iRow, iCol, sId
    oSession.findById("wnd[0]/usr/lbl[0,6]").SetFocus
    WScript.Sleep 200
    oSession.findById("wnd[0]").sendVKey VKEY_F2
    WScript.Sleep 500
    WScript.Echo "INFO: Expanded Function Keys detail view."
    For i = 0 To iDefCount - 1
        If arrType(i) = "STD" Then
            iCol = STBCol(arrPos(i))
            sId = "wnd[0]/usr/txt[" & iCol & ",9]"
            On Error Resume Next
            oSession.findById(sId).Text = arrCode(i)
            If Err.Number <> 0 Then
                WScript.Echo "WARNING: Could not set STD slot " & arrPos(i) & ": " & Err.Description
                Err.Clear
            Else
                WScript.Echo "INFO: STD slot " & arrPos(i) & " = " & arrCode(i) & " (" & arrText(i) & ")"
            End If
            On Error GoTo 0
        ElseIf arrType(i) = "FK" Then
            iRow = FKRow(arrPos(i))
            If iRow < 0 Then
                WScript.Echo "WARNING: Unknown function key: " & arrPos(i)
            Else
                On Error Resume Next
                oSession.findById("wnd[0]/usr/txt[32," & iRow & "]").Text = arrCode(i)
                oSession.findById("wnd[0]/usr/txt[43," & iRow & "]").Text = arrText(i)
                If Err.Number <> 0 Then
                    WScript.Echo "WARNING: Could not set FK " & arrPos(i) & ": " & Err.Description
                    Err.Clear
                Else
                    WScript.Echo "INFO: FK " & arrPos(i) & " = " & arrCode(i) & " (" & arrText(i) & ")"
                End If
                On Error GoTo 0
            End If
        End If
    Next
End Sub

' ---- Save the open editor, handling "Enter Function Text" popups ----
Sub SaveEditor()
    WScript.Echo "INFO: Saving..."
    oSession.findById("wnd[0]").sendVKey VKEY_F11_SAVE
    WScript.Sleep 1500
    Dim sPopup, sFuncCode, sFuncText, bHasRadio, iPopLoop
    iPopLoop = 0
    Do
        On Error Resume Next
        sPopup = ""
        sPopup = oSession.findById("wnd[1]").Text
        If Err.Number <> 0 Or sPopup = "" Then
            Err.Clear
            On Error GoTo 0
            Exit Do
        End If
        Err.Clear
        On Error GoTo 0
        iPopLoop = iPopLoop + 1
        If iPopLoop > 30 Then
            WScript.Echo "ERROR: Too many popups during save. Aborting."
            WScript.Quit 1
        End If
        bHasRadio = False
        On Error Resume Next
        oSession.findById("wnd[1]/usr/radRSMPE-B_TXT_STAT").Text
        If Err.Number = 0 Then bHasRadio = True
        Err.Clear
        On Error GoTo 0
        If bHasRadio Then
            oSession.findById("wnd[1]/usr/radRSMPE-B_TXT_STAT").Select
            oSession.findById("wnd[1]").sendVKey VKEY_ENTER
            WScript.Sleep 500
        Else
            On Error Resume Next
            sFuncCode = oSession.findById("wnd[1]/usr/txtRSMPE-FUNC").Text
            Err.Clear
            On Error GoTo 0
            sFuncText = LookupText(sFuncCode)
            WScript.Echo "INFO: Setting function text for " & sFuncCode & " = " & sFuncText
            On Error Resume Next
            oSession.findById("wnd[1]/usr/txtRSMPE-MENU").Text = sFuncText
            Err.Clear
            On Error GoTo 0
            oSession.findById("wnd[1]").sendVKey VKEY_ENTER
            WScript.Sleep 500
        End If
    Loop
    Dim sSaveType
    On Error Resume Next
    sSaveType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    If sSaveType = "E" Then
        WScript.Echo "ERROR: Save failed - " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    WScript.Echo "INFO: " & oSession.findById("wnd[0]/sbar").Text
End Sub

' ---- Activate the interface (Ctrl+F3), handling activation popups ----
Sub ActivateInterface()
    WScript.Echo "INFO: Activating..."
    On Error Resume Next
    oSession.findById("wnd[0]/tbar[1]/btn[27]").Press
    WScript.Sleep 3000
    HandleMasterLangPopup
    If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
        WScript.Echo "INFO: Inactive objects list - confirming activation..."
        oSession.findById("wnd[1]").sendVKey VKEY_ENTER
        WScript.Sleep 3000
    End If
    If InStr(oSession.ActiveWindow.Id, "wnd[2]") > 0 Then
        WScript.Echo "WARNING: Activation errors - pressing Activate anyway..."
        oSession.findById("wnd[2]/usr/btnBUTTON_1").Press
        WScript.Sleep 3000
    End If
    If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then
        oSession.findById("wnd[1]").sendVKey VKEY_CANCEL
        WScript.Sleep 1000
    End If
    Err.Clear
    On Error GoTo 0
End Sub

' ============================================================================
'  MAIN
' ============================================================================
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

Dim sFinalMsg, sFinalType

Select Case UCase(OPERATION)

' --------------------------------------------------------------------------
Case "CHECK"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    oSession.findById("wnd[0]/usr/btn%#AUTOTEXT003").Press   ' Display
    WScript.Sleep 800
    HandleMasterLangPopup
    ' Still on the initial screen (program field present) => not created.
    If CtrlExists("wnd[0]/usr/ctxtRSMPE-PROGRAM") Then
        WScript.Echo "INFO: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Echo "NOT_EXIST"
    Else
        WScript.Echo "EXIST"
    End If
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "DISPLAY"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    oSession.findById("wnd[0]/usr/btn%#AUTOTEXT003").Press   ' Display
    WScript.Sleep 800
    HandleMasterLangPopup
    If CtrlExists("wnd[0]/usr/ctxtRSMPE-PROGRAM") Then
        WScript.Echo "ERROR: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " does not exist - " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    WScript.Echo "INFO: Displaying " & oSession.findById("wnd[0]").Text
    WScript.Echo "SUCCESS: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " is displayed."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "CREATE"
    ReadDefFile
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    WScript.Echo "INFO: Creating status: " & UCase(PROGRAM_NAME) & " / " & UCase(STATUS_NAME)
    oSession.findById("wnd[0]/usr/btn%#AUTOTEXT005").Press   ' Create
    WScript.Sleep 1000
    HandleMasterLangPopup
    If Not CtrlExists("wnd[1]/usr/txtRSMPE-MENUDOC") Then
        WScript.Echo "ERROR: Create Status popup did not appear. Status may already exist."
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    Select Case UCase(STATUS_TYPE)
        Case "DIAL"    : oSession.findById("wnd[1]/usr/radRSMPE-B_DIAL").Select
        Case "POPUP"   : oSession.findById("wnd[1]/usr/radRSMPE-B_POPUP").Select
        Case "CONTEXT" : oSession.findById("wnd[1]/usr/radRSMPE-B_CONTEXT").Select
        Case Else
            WScript.Echo "ERROR: Invalid STATUS_TYPE: " & STATUS_TYPE & ". Use DIAL, POPUP, or CONTEXT."
            WScript.Quit 1
    End Select
    oSession.findById("wnd[1]/usr/txtRSMPE-MENUDOC").Text = SHORT_TEXT
    oSession.findById("wnd[1]").sendVKey VKEY_ENTER
    WScript.Sleep 1000
    If Not CtrlExists("wnd[0]/usr/lbl[0,6]") Then
        WScript.Echo "ERROR: Did not reach editor. Title: " & oSession.findById("wnd[0]").Text
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    WScript.Echo "INFO: In editor: " & oSession.findById("wnd[0]").Text
    ApplyDefinitions
    SaveEditor
    ActivateInterface
    On Error Resume Next
    sFinalMsg  = oSession.findById("wnd[0]/sbar").Text
    sFinalType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    If sFinalType = "E" Then
        WScript.Echo "WARNING: Activation may have errors - " & sFinalMsg
    Else
        WScript.Echo "INFO: SAP status: " & sFinalMsg
    End If
    WScript.Echo "SUCCESS: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " created and activated in SAP."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "UPDATE"
    ReadDefFile
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    WScript.Echo "INFO: Opening status for change: " & UCase(PROGRAM_NAME) & " / " & UCase(STATUS_NAME)
    oSession.findById("wnd[0]/usr/btn%#AUTOTEXT004").Press   ' Change
    WScript.Sleep 1000
    HandleMasterLangPopup
    If Not CtrlExists("wnd[0]/usr/lbl[0,6]") Then
        WScript.Echo "ERROR: Could not open status for change. Title: " & oSession.findById("wnd[0]").Text
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    WScript.Echo "INFO: In editor: " & oSession.findById("wnd[0]").Text
    ApplyDefinitions
    SaveEditor
    ActivateInterface
    On Error Resume Next
    sFinalMsg  = oSession.findById("wnd[0]/sbar").Text
    sFinalType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    If sFinalType = "E" Then
        WScript.Echo "WARNING: Activation may have errors - " & sFinalMsg
    Else
        WScript.Echo "INFO: SAP status: " & sFinalMsg
    End If
    WScript.Echo "SUCCESS: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " updated and activated in SAP."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "DELETE"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    WScript.Echo "INFO: Deleting status: " & UCase(PROGRAM_NAME) & " / " & UCase(STATUS_NAME)
    oSession.findById("wnd[0]/tbar[1]/btn[24]").Press   ' Delete status (Shift+F12)
    WScript.Sleep 1000
    HandleMasterLangPopup
    If Not CtrlExists("wnd[1]/usr/btn%#AUTOTEXT002") Then
        WScript.Echo "ERROR: Delete confirmation popup did not appear. Status may not exist."
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    oSession.findById("wnd[1]/usr/btn%#AUTOTEXT002").Press   ' Yes
    WScript.Sleep 1200
    On Error Resume Next
    WScript.Echo "INFO: " & oSession.findById("wnd[0]/sbar").Text
    On Error GoTo 0
    ' The delete removes the inactive version; an existing active version is
    ' only dropped when the interface is regenerated. Activate to commit.
    ActivateInterface
    WScript.Echo "SUCCESS: Status " & UCase(STATUS_NAME) & " of " & UCase(PROGRAM_NAME) & " deleted."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "ACTIVATE"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    ActivateInterface
    On Error Resume Next
    sFinalMsg  = oSession.findById("wnd[0]/sbar").Text
    sFinalType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    If sFinalType = "E" Then
        WScript.Echo "ERROR: Activation failed - " & sFinalMsg
        WScript.Quit 1
    End If
    WScript.Echo "INFO: SAP status: " & sFinalMsg
    WScript.Echo "SUCCESS: Interface " & UCase(PROGRAM_NAME) & " activated."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "DEACTIVATE"
    WScript.Echo "INFO: SE41 Menu Painter has no native deactivate function for a GUI"
    WScript.Echo "      status. A status is a static repository object; to remove it"
    WScript.Echo "      from runtime use DELETE, or change the program that references"
    WScript.Echo "      it. There is no Deactivate entry in any SE41 menu."
    WScript.Echo "NOT_SUPPORTED: DEACTIVATE is not available for SE41 PF-STATUS."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case "COPY"
    GotoSE41Initial
    FillInitial PROGRAM_NAME, STATUS_NAME
    WScript.Echo "INFO: Copying status " & UCase(PROGRAM_NAME) & "/" & UCase(STATUS_NAME) _
        & " -> " & UCase(TARGET_PROGRAM) & "/" & UCase(TARGET_STATUS)
    oSession.findById("wnd[0]/tbar[1]/btn[30]").Press   ' Copy status (Ctrl+F6)
    WScript.Sleep 1000
    HandleMasterLangPopup
    If Not CtrlExists("wnd[1]/usr/ctxtRSMPE-CP_PROGRAM") Then
        WScript.Echo "ERROR: Copy Status popup did not appear. Source status may not exist."
        WScript.Echo "       Sbar: " & oSession.findById("wnd[0]/sbar").Text
        WScript.Quit 1
    End If
    oSession.findById("wnd[1]/usr/ctxtRSMPE-CP_PROGRAM").Text = UCase(TARGET_PROGRAM)
    oSession.findById("wnd[1]/usr/txtRSMPE-CP_STATUS").Text   = UCase(TARGET_STATUS)
    oSession.findById("wnd[1]/tbar[0]/btn[0]").Press          ' Copy
    WScript.Sleep 1000
    ' Subsequent popups: subobjects choice (keep "same subobjects" default) and
    ' the "objects will be recreated" confirmation. Press Copy (btn[0]) on the
    ' top-most popup until none remain. Guard against an infinite loop.
    Dim iGuard
    iGuard = 0
    Do While iGuard < 6
        Dim iHi, k
        iHi = 0
        For k = 4 To 1 Step -1
            If CtrlExists("wnd[" & k & "]") Then
                iHi = k
                Exit For
            End If
        Next
        If iHi = 0 Then Exit Do
        On Error Resume Next
        oSession.findById("wnd[" & iHi & "]/tbar[0]/btn[0]").Press
        If Err.Number <> 0 Then
            Err.Clear
            oSession.findById("wnd[" & iHi & "]").sendVKey VKEY_ENTER
        End If
        On Error GoTo 0
        WScript.Sleep 900
        iGuard = iGuard + 1
    Loop
    On Error Resume Next
    sFinalMsg  = oSession.findById("wnd[0]/sbar").Text
    sFinalType = oSession.findById("wnd[0]/sbar").MessageType
    On Error GoTo 0
    If sFinalType = "E" Then
        WScript.Echo "ERROR: Copy failed - " & sFinalMsg
        WScript.Quit 1
    End If
    WScript.Echo "INFO: " & sFinalMsg
    WScript.Echo "SUCCESS: Status copied to " & UCase(TARGET_PROGRAM) & "/" & UCase(TARGET_STATUS) & "."
    WScript.Quit 0

' --------------------------------------------------------------------------
Case Else
    WScript.Echo "ERROR: Unknown OPERATION '" & OPERATION & "'. Use CHECK/DISPLAY/CREATE/UPDATE/DELETE/ACTIVATE/DEACTIVATE/COPY."
    WScript.Quit 1

End Select
```

### 4b. Substitute Tokens and Run

Write `{RUN_TEMP}\sap_se41_ops_run.ps1`, replacing the `THE_*` placeholders
below with the values from Step 1 (UPPERCASE program/status). Leave a token's
replacement value as an empty string when the operation does not use it.

```powershell
$content = [System.IO.File]::ReadAllText('{RUN_TEMP}\sap_se41_ops.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%OPERATION%%','THE_OPERATION'
$content = $content -replace '%%PROGRAM%%','THE_PROGRAM'
$content = $content -replace '%%STATUS%%','THE_STATUS'
$content = $content -replace '%%STATUS_TYPE%%','THE_STATUS_TYPE'
$content = $content -replace '%%SHORT_TEXT%%','THE_SHORT_TEXT'
$content = $content -replace '%%DEF_FILE%%','{WORK_TEMP}\THE_STATUS.def'
$content = $content -replace '%%TARGET_PROGRAM%%','THE_TARGET_PROGRAM'
$content = $content -replace '%%TARGET_STATUS%%','THE_TARGET_STATUS'
# Phase 3.5 session-attach plumbing.
$content = $content -replace '%%SESSION_PATH%%', ''
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se41_ops_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se41_ops_run.ps1"
```

### Execute

```bash
cscript //NoLogo {RUN_TEMP}\sap_se41_ops_run.vbs
```

---

## Step 5 — Report Result

Parse the **last meaningful line** of the script output:

| Output token | Meaning | Action |
|---|---|---|
| `SUCCESS:` | Operation completed | Report success; show the full output as a code block |
| `EXIST` (CHECK) | Status exists | Report "exists" |
| `NOT_EXIST` (CHECK) | Status does not exist | Report "does not exist" |
| `NOT_SUPPORTED:` (DEACTIVATE) | Operation not available in SE41 | Explain (see [Deactivate](#deactivate-note)) |
| `ERROR:` / `WARNING:` | Failure | Show full output and diagnose with the table below |

### Failure Diagnosis

| Error message | Cause | Fix |
|---|---|---|
| `Create Status popup did not appear` | Status already exists or program name wrong | Use UPDATE or fix the name |
| `Did not reach editor` | Create popup handling failed | Check the SAP status bar message |
| `Could not open status for change` | Status doesn't exist or is locked | Run CHECK; check locks in SM12 |
| `Delete confirmation popup did not appear` | Status does not exist | Run CHECK first |
| `Copy Status popup did not appear` | Source status does not exist | Run CHECK on the source first |
| `Could not set STD slot` | Standard toolbar field ID mismatch | Verify toolbar positions with Scripting Recorder |
| `Could not set FK` | Function key field ID mismatch | Verify FK grid row mappings |
| `Too many popups during save` | Stuck in function-text entry loop | Check the definition file for missing texts |
| `Save failed` / `Activation failed` | SAP save/activation error | Check the status bar message / activation log |
| `Definition file not found` | Wrong path or file not written | Verify path; re-run Step 2 |

### "Enter Function Text" Popup (CREATE / UPDATE)

During save, SAP may show an "Enter Function Text" popup for standard toolbar
codes that need text. The VBS handles this automatically using the text from
the definition file. If a function code is not in the file, the code name
itself is used. The popup cycle per code:
1. **Choose Text Type** popup → VBS selects "Static Text" and confirms
2. **Function text entry** popup → VBS fills in the text and confirms

---

## Package Changes

SE41 exposes the interface's package via **Goto > Object Directory Entry**
(`mbar/menu[2]/menu[0]`). **Do not** drive that dialog from this skill — a
PF-STATUS shares the development class of its host program/function group, so a
package change applies to the whole interface. Delegate to `/sap-change-package`:

```
/sap-change-package <OBJECT_TYPE> <PROGRAM_OR_FUGR> <NEW_PACKAGE>
```

- For a status in a function pool / function group, use `OBJECT_TYPE = FUGR`
  and the function group name.
- For a status in an executable program, use `OBJECT_TYPE = REPORT` and the
  program name.

`/sap-change-package` handles `$TMP → transportable`, `transportable →
transportable`, and `transportable → $TMP`, resolving a transport request when
needed and verifying via TADIR.

---

## Deactivate Note

SE41 has **no native deactivate** for a GUI status — there is no "Deactivate"
entry in any SE41 menu (User Interface, Edit, Goto, Utilities, Environment were
all probed). The `DEACTIVATE` operation therefore returns `NOT_SUPPORTED`. To
take a status out of use, either **DELETE** it, or remove the `SET PF-STATUS`
reference from the program that uses it.

---

## Step 6 — Clean Up

Delete temporary files:
```bash
cmd /c del {RUN_TEMP}\sap_se41_ops.vbs & del {RUN_TEMP}\sap_se41_ops_run.vbs & del {RUN_TEMP}\sap_se41_ops_run.ps1
```

For CREATE / UPDATE also delete the definition file `{WORK_TEMP}\<STATUS_NAME>.def`.

---

## Final — Log End

Log the run-end record. Best-effort.

On success:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se41_run.json" -Status SUCCESS -ExitCode 0
```

On failure:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se41_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE41_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 6).

---

## Important: Encoding

When filling the VBS template, always write with **`-Encoding Unicode`**
(UTF-16 LE) in PowerShell. UTF-16 LE is what `cscript` supports natively and
preserves non-ASCII characters. UTF-8 with BOM causes a cscript compile error.

---

## SE41 No Upload/Download Note

Unlike SE37/SE38 which support source upload from local files, **SE41 has no
Upload/Download functionality** for status definitions. The Utilities, Extras,
Edit, and Environment menus were exhaustively probed — no import/export option
exists. The VBS enters function codes field by field into the SE41 editor grid.

---

## SE41 Component IDs Reference

### Initial Screen — "Menu Painter: Initial Screen"

| Element | Component ID | Notes |
|---|---|---|
| Program field | `wnd[0]/usr/ctxtRSMPE-PROGRAM` | GuiCTextField |
| Status radio | `wnd[0]/usr/radRSMPE-B_STATUS` | Subobject = Status |
| Status name field | `wnd[0]/usr/ctxtRSMPE-STATUS` | GuiCTextField |
| Test button | `wnd[0]/usr/btn%#AUTOTEXT002` | |
| Display button | `wnd[0]/usr/btn%#AUTOTEXT003` | Used for CHECK/DISPLAY |
| Change button | `wnd[0]/usr/btn%#AUTOTEXT004` | Used for UPDATE |
| Create button | `wnd[0]/usr/btn%#AUTOTEXT005` | Used for CREATE |
| Delete status | `wnd[0]/tbar[1]/btn[24]` | Shift+F12 |
| Activate | `wnd[0]/tbar[1]/btn[27]` | Ctrl+F3 |
| Copy status | `wnd[0]/tbar[1]/btn[30]` | Ctrl+F6 |
| Copy user interface | `wnd[0]/tbar[1]/btn[29]` | Ctrl+F5 |
| Check syntax | `wnd[0]/tbar[1]/btn[26]` | Ctrl+F2 |

Subobject radios (other subobject kinds on the initial screen):
`radRSMPE-B_STATUS` (Status), `B_OBJECTS` (Interface Objects), `B_STATEXT`
(Status List), `B_BAR` (Menu bars), `B_MEN` (Menu list), `B_PFK` (F-Key
Settings), `B_FUN` (Function list), `B_TITLE` (Title List).

### User Interface menu — `wnd[0]/mbar/menu[0]`

| Item | Path |
|---|---|
| Create | `menu[0]/menu[0]` |
| Change | `menu[0]/menu[1]` |
| Display | `menu[0]/menu[2]` |
| Activate | `menu[0]/menu[6]` |
| Copy > Status | `menu[0]/menu[10]/menu[1]` |
| Delete > Status | `menu[0]/menu[12]/menu[1]` |
| Object Directory Entry (package) | `mbar/menu[2]/menu[0]` (Goto menu) |

### Create Status Popup — "Create Status" (`wnd[1]`)

| Element | Component ID | Notes |
|---|---|---|
| Short description | `wnd[1]/usr/txtRSMPE-MENUDOC` | Presence = popup appeared |
| Normal Screen (DIAL) | `wnd[1]/usr/radRSMPE-B_DIAL` | |
| Dialog Box (POPUP) | `wnd[1]/usr/radRSMPE-B_POPUP` | |
| Context Menu (CONTEXT) | `wnd[1]/usr/radRSMPE-B_CONTEXT` | |

### Editor — "Edit Status XXXX of Interface YYYY"

| Element | Component ID | Notes |
|---|---|---|
| Function Keys section | `wnd[0]/usr/lbl[0,6]` | SetFocus + F2 to expand |
| Standard Toolbar code fields | `wnd[0]/usr/txt[col,9]` | col = 1 + (pos-1)*11, 13 slots |
| FK code field | `wnd[0]/usr/txt[32,row]` | See FK row mapping |
| FK text field | `wnd[0]/usr/txt[43,row]` | See FK row mapping |
| Save | `sendVKey 11` | |

### "Enter Function Text" Popup (`wnd[1]`)

| Element | Component ID | Notes |
|---|---|---|
| Static Text radio | `wnd[1]/usr/radRSMPE-B_TXT_STAT` | Choose Text Type popup |
| Function code | `wnd[1]/usr/txtRSMPE-FUNC` | Function text entry popup |
| Function text | `wnd[1]/usr/txtRSMPE-MENU` | Function text entry popup |

### Delete Confirmation Popup — "Delete Status" (`wnd[1]`)

| Element | Component ID | Notes |
|---|---|---|
| Yes | `wnd[1]/usr/btn%#AUTOTEXT002` | Confirm delete |
| No | `wnd[1]/usr/btn%#AUTOTEXT003` | |
| Cancel | `wnd[1]/usr/btn%#AUTOTEXT004` | |

### Copy Status Popups

| Popup | Element | Component ID |
|---|---|---|
| `wnd[1]` "Copy Status" | Target program | `wnd[1]/usr/ctxtRSMPE-CP_PROGRAM` |
| `wnd[1]` | Target status | `wnd[1]/usr/txtRSMPE-CP_STATUS` |
| `wnd[1]` | Copy | `wnd[1]/tbar[0]/btn[0]` |
| `wnd[2]` "Copy Status" | Same subobjects (default) | `wnd[2]/usr/radRSMPE-B_TXT_REF` |
| `wnd[2]` | Copy | `wnd[2]/tbar[0]/btn[0]` |
| `wnd[3]` "Copy Status" | Confirm recreate | `wnd[3]/tbar[0]/btn[0]` |

### Logon Language ≠ Original Language Popup (`wnd[1]`)

Appears when the **logon language differs from the object's master/original
language** (e.g. logged on in `ZH` while interface master language is `EN`).
It can pop up on entry to CREATE / UPDATE / DISPLAY / DELETE / COPY / ACTIVATE.
The inline VBS handles it automatically via `HandleMasterLangPopup`, which
presses **Maintain in original language** so the master language is preserved.

| Element | Component ID | Notes |
|---|---|---|
| Maintain in original language | `wnd[1]/usr/btnPUSH1` | Chosen automatically (safe default) |
| Change original language | `wnd[1]/usr/btnPUSH2` | Not used — would rewrite master language |
| Cancel | `wnd[1]/usr/btnPUSH_TEXT_3` | Used together with `btnPUSH1` to identify the popup |

The popup is identified language-independently by the presence of **both**
`btnPUSH1` and `btnPUSH_TEXT_3`, so it is never confused with another dialog.

### Existence Detection (language independent)

After pressing **Display**, the script checks whether
`wnd[0]/usr/ctxtRSMPE-PROGRAM` is still present:

| Condition | Meaning |
|---|---|
| Field still present (still on initial screen, status-bar type `E`) | `NOT_EXIST` |
| Field gone (navigated into the display editor) | `EXIST` |

---

## Troubleshooting Component IDs

If menu paths or component IDs fail on the user's system:
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs

### "Create/Change popup did not appear" while logged on in a non-original language

If an operation stalls right after pressing Create/Change/Display/Delete/Copy
and the status bar is empty, a **"logon language differs from original
language"** popup (`wnd[1]/usr/btnPUSH1`) is most likely blocking the screen.
The inline VBS dismisses it automatically with `HandleMasterLangPopup`
(pressing *Maintain in original language*). If you extend the script with new
navigation steps, call `HandleMasterLangPopup` immediately after the
navigation press and before checking for the next expected screen/popup.
