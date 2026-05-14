---
name: sap-se37
description: |
  Deploys ABAP function module source code to a SAP system via SE37 using
  SAP GUI Scripting. Creates new function modules or updates existing ones.
  Existence check (SE37 Display), source upload to the
  Source code tab, save, and activation. Source is the full function include
  (FUNCTION <name>. through ENDFUNCTION.).
  Also supports check-and-fix mode: when no source file is provided and the
  task is "fix FM" or "check and fix FM", opens the FM in SE37, runs a syntax
  check (Ctrl+F2), downloads the source, fixes all errors, re-uploads, and
  activates the FM.
  Also supports change-attributes mode: when the user asks to change a
  function module's Short Text or Processing Type (Regular / Remote-Enabled
  / Update Module + update kind), opens SE37 in change mode, selects the
  Attributes tab, updates the supplied fields and saves. Handles the
  conditional original-language popup and the post-save Workbench-request
  popup per `/sap-transport-request`.
  Also supports reassign-function-group mode: when the user asks to move a
  function module to a different function group (e.g. "reassign FM <X> to
  function group <FG>"), opens SE37, presses Reassign (toolbar btn[31]),
  fills the new function group, handles the post-reassign TR popup, then
  re-activates the FM (reassign leaves it inactive).
  Also supports delete mode: when the user asks to delete an FM (e.g.
  "delete <FM>", "remove FM <FM>"), opens SE37, presses Delete
  (Shift+F2 / tbar[1]/btn[14]), confirms via btnSPOP-OPTION1 (Yes),
  handles the post-delete TR popup if the FM was transportable, and
  verifies removal via Display. Deletion is irreversible — the skill
  asks for explicit confirmation before running the VBS.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<function-module-name> [path-to-source]"
---

# SAP SE37 Function Module Deploy Skill

You deploy ABAP function module source code to a live SAP system via SE37
using SAP GUI Scripting. The skill checks if the function module
exists, then creates or updates it.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` (Step 1b) |

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `work_dir`, `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_se37_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_se37_run.json" -Skill sap-se37 -ParamsJson "{\"function_module\":\"<FM>\"}"
```

---

## Step 1 — Collect Parameters

**Function Module Details**

| Parameter | Description | Example |
|---|---|---|
| Function module name | Z/Y namespace, max 30 chars | `ZHKFM_TEST001` |
| Function group | Existing function group name (only for new FMs) | `ZHKFG01` |
| Short text | Short description, max 70 chars (only for new FMs) | `My test function` |
| Source | Full function include: absolute path to `.abap` file, OR paste code directly. **MUST** include `FUNCTION <name>.`, the Local Interface comment block, the body, and `ENDFUNCTION.` — the upload replaces the entire function include. |  |
| Package | SAP package (optional, blank = local $TMP) | `ZHKA001` |
| Transport | Transport request (optional; resolved by `/sap-transport-request` per `way_to_get_transport_request` if not supplied) | `S4DK940992` |

**Mode selection:**

| Task | Source provided? | Flow |
|---|---|---|
| Deploy new or updated code | Yes (file path or pasted) | Steps 1.5 → 2 → 3 → 4 → 5a/5b → 6 → 7 |
| Fix / check existing FM | No | Steps 3 → A → B → C → 6 → 7 |
| Change FM **attributes** (Short Text / Processing Type / …) | No | Steps 1b → 3 → 5d → 6 → 7 |
| **Reassign** FM to a different function group | No | Steps 1b → 3 → 5e → 6 → 7 |
| **Delete** FM | No | Steps 1b → 3 → 5f → 6 → 7 |

If the user says **"fix `<FM>`"**, **"check `<FM>`"**, or **"check and fix `<FM>`"** and provides no source code, skip directly to **Step A**.

If the user says **"change attributes of `<FM>`"**, **"set short text of `<FM>`"**, **"make `<FM>` remote-enabled"**, or otherwise asks to modify FM header attributes (no source involved), skip directly to **Step 5d**.

If the user says **"reassign `<FM>` to function group `<FG>`"**, **"move `<FM>` to FUGR `<FG>`"**, or otherwise asks to change which function group an existing FM belongs to, skip directly to **Step 5e**.

If the user says **"delete `<FM>`"**, **"remove FM `<FM>`"**, or **"drop function module `<FM>`"**, skip directly to **Step 5f**. Deletion is **irreversible** — the skill MUST confirm with the user before running the VBS.

---

## Step 1b — Resolve Transport Request

If `Package` is empty or starts with `$` (e.g. `$TMP`), this is a local
object; **skip this step**.

Otherwise a TR is needed. **Do NOT prompt the user directly and do NOT call
`/sap-se01`.** Delegate to `/sap-transport-request`:

```
/sap-transport-request [<TR-from-args-if-any>] OBJECT_TYPE=FM OBJECT_DESCRIPTION=<FM_NAME>
```

Use the returned modifiable TRKORR as the `%%TRANSPORT%%` value. If
`/sap-transport-request` reports `ERROR`, stop and surface it to the user.

See `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for the full policy.

---

## Step 1.5 — Parse FM Source File

If the user provided a path to an FM source file, use it directly — the full parsing
(FM name, interface sections, source body) is embedded in the Step 5b PS1.

**What the parse extracts:**

| Field | Source |
|---|---|
| FM name | `FUNCTION <name>.` line |
| IMPORTING/EXPORTING/CHANGING/TABLES params | Lines inside `*"*"Local Interface:` block |
| EXCEPTIONS | Lines after `*"  EXCEPTIONS` in interface block |
| Pass-by | `VALUE(...)` → pass by value; `REFERENCE(...)` or bare name → pass by reference |
| OPTIONAL | Trailing `OPTIONAL` keyword on parameter line |

**Supported source file formats:**
- SE37 download (UTF-16 LE, BOM `FF FE`) — standard SAP export
- UTF-8 (no BOM or with BOM) — manually edited files

**Skip this step** if the user pasted source code directly (go to Step 2).

---

## Step 2 — Prepare ABAP Source File

**Critical:** The source file must contain the **full function include** — including the
`FUNCTION <name>.` header, the Local Interface comment block, the body code, and
`ENDFUNCTION.` at the end. Unlike SE38 (which uploads just the program body), SE37's
upload replaces the entire function include file.

**Example source file format:**
```abap
FUNCTION ZHKFM_TEST001.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_INPUT) TYPE  STRING
*"  EXPORTING
*"     VALUE(EV_OUTPUT) TYPE  STRING
*"----------------------------------------------------------------------
  ev_output = iv_input.
  WRITE: / 'Function executed'.
ENDFUNCTION.
```

**If the user pasted source code directly:**

1. If the code does NOT start with `FUNCTION`, wrap it:
   - Add `FUNCTION <FM_NAME>.` as the first line
   - Add the `*"---` Local Interface comment block (copy from existing FM or generate minimal)
   - Add `ENDFUNCTION.` as the last line
2. Write the source to: `{WORK_TEMP}\<FM_NAME>.abap`
3. Confirm the file by reading back the first 5 lines.

**If the user provided a file path:**

- Use that path as-is. Verify it exists:
  ```bash
  cmd /c if exist "<path>" (echo EXISTS) else (echo NOT FOUND)
  ```

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if Function Module Exists

The check VBScript template is at `./references/sap_se37_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se37_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_se37_check.vbs' -Raw
$content = $content -replace '%%FM_NAME%%','THE_FM_NAME'
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se37_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_FM_NAME` with the actual function module name (UPPERCASE) and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se37_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se37_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → function module exists → proceed to Step 5a (Update).
- `NOT_EXIST` → function module does not exist → proceed to Step 5b (Create).
- `ERROR:` → show full output and stop.

---

## Step 4.5 — Naming Pre-Check

Validate the FM name (and the function group name when creating) against
`sap_object_naming_rules.tsv` (custom override → default) **before** launching
any create / update flow.

For the FM:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType FUNCTION_MODULE -ObjectName THE_FM_NAME -CustomUrl "{custom_url}"
```

Additionally, when the previous step returned `NOT_EXIST` AND a target function
group was supplied (create mode):
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType FUNCTION_GROUP -ObjectName THE_FG_NAME -CustomUrl "{custom_url}"
```

Behaviour for each call:
- Exit `0` → silently continue.
- Exit `1` → show the violation line and ask:
  *"The name does not match the configured naming rule. Proceed anyway, or abort?"*
  - **Abort** → end the run with `Status SKIPPED`, `ErrorClass OBJECT_NAMING_VIOLATION`.
  - **Proceed** → continue, recording the choice via `sap_log_helper.ps1 -Action step`.
- Exit `2` → log a step note and continue.

The user can customise the rule at `{custom_url}\sap_object_naming_rules.tsv`.

---

## Step 5a — Update Existing Function Module

**Update flow (Original-language popup handling):** Right after pressing
the Change button (`btnBUT4`), if `wnd[1]` is the SAPLSETX
"Different original and logon languages" dialog (fingerprint:
`wnd[1]/usr/ctxtRSETX-MASTERLANG` present), the template presses
`wnd[1]/usr/btnPUSH1` ("Maint. in orig. lang.") — keeps `TADIR-MASTERLANG`
unchanged so we edit translations without overwriting the master language.

**Update flow (TR popup handling):** The template sends `Ctrl+S` immediately
after entering change mode (before uploading source) to provoke the
"Prompt for local Workbench request" popup. If `wnd[1]` shows a TR field
(`ctxtKO008-TRKORR`), the template fills `SAP_TRANSPORT` and Enter, locking
the FM to that TR. If no popup appears, the FM is local or already locked
to a modifiable TR. If the popup appears but `SAP_TRANSPORT` is empty, the
VBS aborts; the caller must run `/sap-transport-request` first.
Diagnostics: TADIR-DEVCLASS, E071, E070-TRSTATUS.


The update VBScript template is at `./references/sap_se37_update.vbs`.

### Generate the filled-in VBScript

The update flow uploads the new source then **defensively re-writes the
Import / Export / Changing / Tables / Exceptions tabs** from the parsed FM
interface. Source upload + save normally syncs the tabs from the
`*" Local Interface:` comment block, but the override below guarantees the
tabs match the new source even if the sync misbehaves. On activation SAP
regenerates the `*" Local Interface:` comment from the tabs (FUNCT /
FUPARAREF), so the tabs are the source of truth.

The override uses **Phase 2 only** (write each new row) — no Phase-1
clearing of existing rows, because blanking a parameter name triggers an
unanswerable "Rename Parameter to <blank>" popup.

After each row is written and committed:
- If a `wnd[1]` "Copy or Rename Parameter" popup appears, press
  **Rename** (`btnSPOP-VAROPTION1`).

Note: the previous version of this skill also tried to "dismiss" the
status-bar `TABLES parameters are obsolete!` warning with a second
ENTER. That doesn't work — the warning is passive sbar text, not a
popup, and ENTER does not clear it (confirmed 2026-05-12). The deploy
succeeds anyway because the next Save / Activate writes a different
sbar message over the warning. The real way to remove the warning is
to drop the TABLES section from the FM signature.

The uploaded source file MUST contain the full `FUNCTION <name>. ...
ENDFUNCTION.` wrapper with the `*"  Local Interface:` comment block listing
all current parameters in the desired final state (used by the source
upload and parsed by the PS1 generator below).

Write a single self-contained PS1 to `{WORK_TEMP}\sap_se37_update_run.ps1`:

```powershell
# ================================================================
# sap_se37_update_run.ps1  —  auto-generated by sap-se37 skill
# ================================================================
$fmFilePath = 'THE_SOURCE_PATH'     # absolute path to FM source file (UTF-16 or UTF-8)
$package    = 'THE_PACKAGE'         # SAP package (blank = local $TMP)
$transport  = 'THE_TRANSPORT'       # transport request (blank = local)
$skillDir   = 'THE_SKILL_DIR'       # absolute path to sap-se37 skill directory
$workTemp   = 'THE_WORK_TEMP'       # work temp directory

# ── 1. Parse FM source file (same parser as create flow) ────────
$bytes = [System.IO.File]::ReadAllBytes($fmFilePath)
if ($bytes.Count -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $enc = [System.Text.Encoding]::Unicode
} else {
    $enc = [System.Text.Encoding]::UTF8
}
$raw   = $enc.GetString($bytes).TrimStart([char]0xFEFF)
$lines = [System.Text.RegularExpressions.Regex]::Split($raw, "\r\n|\r|\n")

$fmName = ""
foreach ($line in $lines) {
    if ($line -match '^\s*FUNCTION\s+(\w+)\s*\.') { $fmName = $Matches[1]; break }
}
if ($fmName -eq "") { Write-Host "ERROR: Cannot detect FM name."; exit 1 }

$section = ""; $seenSep = $false; $inIface = $false
$importing  = [System.Collections.Generic.List[hashtable]]::new()
$exporting  = [System.Collections.Generic.List[hashtable]]::new()
$changing   = [System.Collections.Generic.List[hashtable]]::new()
$tables     = [System.Collections.Generic.List[hashtable]]::new()
$exceptions = [System.Collections.Generic.List[string]]::new()

foreach ($line in $lines) {
    $t = $line.TrimStart()
    if ($t -match '^\*"-{10,}') {
        if (-not $seenSep) { $seenSep = $true }
        elseif ($inIface)  { $inIface = $false; break }
        continue
    }
    if ($t -match '^\*"\*"Local Interface:') { $inIface = $true; continue }
    if (-not $inIface) { continue }
    if ($t -match '^\*"\s+IMPORTING')  { $section = "I"; continue }
    if ($t -match '^\*"\s+EXPORTING')  { $section = "E"; continue }
    if ($t -match '^\*"\s+CHANGING')   { $section = "C"; continue }
    if ($t -match '^\*"\s+TABLES')     { $section = "T"; continue }
    if ($t -match '^\*"\s+EXCEPTIONS') { $section = "X"; continue }
    if ($t -notmatch '^\*"(.+)$') { continue }
    $pline = $Matches[1].Trim()
    if ($pline -eq "") { continue }
    if ($section -eq "X") { $exceptions.Add($pline); continue }
    $passBy = "VALUE"; $pName = ""
    if      ($pline -match '^VALUE\((\w+)\)\s+(.+)$')     { $passBy = "VALUE";     $pName = $Matches[1]; $pline = $Matches[2] }
    elseif  ($pline -match '^REFERENCE\((\w+)\)\s+(.+)$') { $passBy = "REFERENCE"; $pName = $Matches[1]; $pline = $Matches[2] }
    elseif  ($pline -match '^(\w+)\s+(.+)$')               { $passBy = "VALUE";     $pName = $Matches[1]; $pline = $Matches[2] }
    else { continue }
    $typeField = "TYPE"; $typeName = ""; $optional = $false
    if ($pline -match '^(TYPE|LIKE|STRUCTURE)\s+(\S+)(\s+OPTIONAL)?') {
        $typeField = if ($Matches[1] -eq "STRUCTURE") {"LIKE"} else {$Matches[1]}
        $typeName  = $Matches[2]
        $optional  = ($null -ne $Matches[3] -and $Matches[3].Trim() -eq "OPTIONAL")
    }
    $param = @{Name=$pName; TypeField=$typeField; TypeName=$typeName; PassBy=$passBy; Optional=$optional}
    switch ($section) {
        "I" { $importing.Add($param)  }
        "E" { $exporting.Add($param)  }
        "C" { $changing.Add($param)   }
        "T" { $tables.Add($param)     }
    }
}
Write-Host "FM       : $fmName"
Write-Host ("IMPORTING ({0}): {1}" -f $importing.Count, (($importing | ForEach-Object { $_.Name }) -join ', '))
Write-Host ("EXPORTING ({0}): {1}" -f $exporting.Count, (($exporting | ForEach-Object { $_.Name }) -join ', '))
Write-Host ("CHANGING  ({0}): {1}" -f $changing.Count,  (($changing  | ForEach-Object { $_.Name }) -join ', '))
Write-Host ("TABLES    ({0}): {1}" -f $tables.Count,    (($tables    | ForEach-Object { $_.Name }) -join ', '))
Write-Host ("EXCEPTIONS({0}): {1}" -f $exceptions.Count, ($exceptions -join ', '))

# ── 2. Build interface VBS code (Phase 2 only — defensive overlay) ─
# Each row: write fields → sendVKey 0 to commit. After commit:
#   - if wnd[1] "Copy or Rename Parameter" popup: press Rename
#     (btnSPOP-VAROPTION1); fall back to sendVKey 0 for any other popup.
# NOTE: the previous sbar W/I "second ENTER" branch has been removed —
# the "TABLES parameters are obsolete!" warning is passive sbar text
# that ENTER cannot clear (confirmed 2026-05-12). The Save/Activate
# that follows naturally writes a new sbar message; the warning is
# benign. To eliminate the warning, drop TABLES from the FM signature.
function Get-DismissBlock {
    $b  = "    oSession.findById(`"wnd[0]`").sendVKey 0`r`n"
    $b += "    WScript.Sleep 300`r`n"
    $b += "    Do While InStr(oSession.ActiveWindow.Id, `"wnd[1]`") > 0`r`n"
    $b += "        Err.Clear`r`n"
    $b += "        oSession.findById(`"wnd[1]/usr/btnSPOP-VAROPTION1`").press`r`n"
    $b += "        If Err.Number <> 0 Then`r`n"
    $b += "            Err.Clear`r`n"
    $b += "            oSession.findById(`"wnd[1]`").sendVKey 0`r`n"
    $b += "        End If`r`n"
    $b += "        WScript.Sleep 300`r`n"
    $b += "    Loop`r`n"
    $b += "    Err.Clear`r`n"
    return $b
}

function Build-ParamTabCode {
    param([string]$tabId,[string]$subId,[string]$tblName,$params,[bool]$hasValue)
    $pfx = "wnd[0]/usr/tabsFUNC_TAB_STRIP/$tabId/ssubSCREEN_HEADER:$subId/$tblName"
    $c  = "oSession.findById(`"wnd[0]/usr/tabsFUNC_TAB_STRIP/$tabId`").select`r`n"
    $c += "WScript.Sleep 500`r`n"
    $c += "On Error Resume Next`r`n"
    for ($r = 0; $r -lt $params.Count; $r++) {
        $p = $params[$r]
        $c += "oSession.findById(`"$pfx/txtRSFBPARA-PARAMETER[0,$r]`").text = `"$($p.Name)`"`r`n"
        $c += "oSession.findById(`"$pfx/ctxtRSFBPARA-TYPEFIELD[1,$r]`").text = `"$($p.TypeField)`"`r`n"
        if ($p.TypeName -ne "") {
            $c += "oSession.findById(`"$pfx/ctxtRSFBPARA-STRUCTURE[2,$r]`").text = `"$($p.TypeName)`"`r`n"
        }
        if ($p.Optional) {
            $c += "oSession.findById(`"$pfx/chkRSFBPARA-OPTIONAL[4,$r]`").selected = true`r`n"
        }
        if ($hasValue -and $p.PassBy -eq "VALUE") {
            $c += "oSession.findById(`"$pfx/chkRSFBPARA-VALUE[5,$r]`").selected = true`r`n"
        }
        $c += (Get-DismissBlock)
    }
    return $c
}

function Build-ExceptTabCode {
    param($params)
    $pfx = "wnd[0]/usr/tabsFUNC_TAB_STRIP/tabpEXCEPT/ssubSCREEN_HEADER:SAPLSFUNCTION_BUILDER:3062/tblSAPLSFUNCTION_BUILDEREXCEPT"
    $c  = "oSession.findById(`"wnd[0]/usr/tabsFUNC_TAB_STRIP/tabpEXCEPT`").select`r`n"
    $c += "WScript.Sleep 500`r`n"
    $c += "On Error Resume Next`r`n"
    for ($r = 0; $r -lt $params.Count; $r++) {
        $c += "oSession.findById(`"$pfx/txtRSFBPARA-PARAMETER[0,$r]`").text = `"$($params[$r])`"`r`n"
        $c += (Get-DismissBlock)
    }
    return $c
}

$ifaceCode = "On Error Resume Next`r`n"
if ($importing.Count  -gt 0) { $ifaceCode += Build-ParamTabCode "tabpIMPORT" "SAPLSFUNCTION_BUILDER:3050" "tblSAPLSFUNCTION_BUILDERIMPORT" $importing  $true  }
if ($exporting.Count  -gt 0) { $ifaceCode += Build-ParamTabCode "tabpEXPORT" "SAPLSFUNCTION_BUILDER:3052" "tblSAPLSFUNCTION_BUILDEREXPORT" $exporting  $true  }
if ($changing.Count   -gt 0) { $ifaceCode += Build-ParamTabCode "tabpCHANGE" "SAPLSFUNCTION_BUILDER:3054" "tblSAPLSFUNCTION_BUILDERCHANGE" $changing   $true  }
if ($tables.Count     -gt 0) { $ifaceCode += Build-ParamTabCode "tabpTABLES" "SAPLSFUNCTION_BUILDER:3060" "tblSAPLSFUNCTION_BUILDERTABLES" $tables     $false }
if ($exceptions.Count -gt 0) { $ifaceCode += Build-ExceptTabCode $exceptions }
$ifaceCode += "Err.Clear : On Error GoTo 0`r`n"

# ── 3. Fill template tokens and write VBS ───────────────────────
$content = [System.IO.File]::ReadAllText("$skillDir\references\sap_se37_update.vbs")
$content = $content.Replace('%%FM_NAME%%',         $fmName)
$content = $content.Replace('%%ABAP_SOURCE_FILE%%', $fmFilePath)
$content = $content.Replace('%%PACKAGE%%',         $package)
$content = $content.Replace('%%TRANSPORT%%',       $transport)
$content = $content.Replace('%%INTERFACE_CODE%%',  $ifaceCode)
$content = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
[System.IO.File]::WriteAllText("$workTemp\sap_se37_update_run.vbs", $content, [System.Text.Encoding]::Unicode)
Write-Host "VBS written: $workTemp\sap_se37_update_run.vbs"
Write-Host 'Done'
```

> **Important**: Use `[System.IO.File]::WriteAllText(..., Unicode)` (UTF-16
> LE w/BOM). `Set-Content -Encoding Unicode` works too.

Fill these placeholders before writing:

| Placeholder | Value |
|---|---|
| `THE_SOURCE_PATH` | Absolute path to FM source file |
| `THE_PACKAGE` | SAP package — blank for local $TMP |
| `THE_TRANSPORT` | Transport request from Step 1b — blank for local |
| `THE_SKILL_DIR` | Absolute path to this skill directory |
| `THE_WORK_TEMP` | `{WORK_TEMP}` resolved value |

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se37_update_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se37_update_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5b — Create New Function Module

If this is a new function module, you need Function Group and Short Text in addition
to the source file. Ask the user if not already provided:
> "This is a new function module. Please provide the function group and short text."

The create VBScript template is at `./references/sap_se37_create.vbs`.

### Generate and run the complete PS1

Write a single self-contained PS1 to `{WORK_TEMP}\sap_se37_create_run.ps1`.
Fill every `THE_*` placeholder with the actual value before writing.

```powershell
# ================================================================
# sap_se37_create_run.ps1  —  auto-generated by sap-se37 skill
# ================================================================
$fmFilePath = 'THE_SOURCE_PATH'     # absolute path to FM source file (UTF-16 or UTF-8)
$funcGroup  = 'THE_FUNC_GROUP'      # function group name
$shortText  = 'THE_SHORT_TEXT'      # FM short description
$package    = 'THE_PACKAGE'         # SAP package (blank = local $TMP)
$transport  = 'THE_TRANSPORT'       # transport request (blank = local)
$skillDir   = 'THE_SKILL_DIR'       # absolute path to sap-se37 skill directory
$workTemp   = 'THE_WORK_TEMP'       # work temp directory

# ── 1. Parse FM source file ──────────────────────────────────────
$bytes = [System.IO.File]::ReadAllBytes($fmFilePath)
if ($bytes.Count -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $enc = [System.Text.Encoding]::Unicode
} else {
    $enc = [System.Text.Encoding]::UTF8
}
$raw   = $enc.GetString($bytes).TrimStart([char]0xFEFF)
$lines = [System.Text.RegularExpressions.Regex]::Split($raw, "\r\n|\r|\n")

$fmName = ""
foreach ($line in $lines) {
    if ($line -match '^\s*FUNCTION\s+(\w+)\s*\.') { $fmName = $Matches[1]; break }
}
if ($fmName -eq "") { Write-Host "ERROR: Cannot detect FM name from file."; exit 1 }

$section = ""; $seenSep = $false; $inIface = $false; $li = -1
$importing  = [System.Collections.Generic.List[hashtable]]::new()
$exporting  = [System.Collections.Generic.List[hashtable]]::new()
$changing   = [System.Collections.Generic.List[hashtable]]::new()
$tables     = [System.Collections.Generic.List[hashtable]]::new()
$exceptions = [System.Collections.Generic.List[string]]::new()

foreach ($line in $lines) {
    $li++; $t = $line.TrimStart()
    if ($t -match '^\*"-{10,}') {
        if (-not $seenSep) { $seenSep = $true }
        elseif ($inIface)  { $inIface = $false; break }
        continue
    }
    if ($t -match '^\*"\*"Local Interface:') { $inIface = $true; continue }
    if (-not $inIface) { continue }
    if ($t -match '^\*"\s+IMPORTING')  { $section = "I"; continue }
    if ($t -match '^\*"\s+EXPORTING')  { $section = "E"; continue }
    if ($t -match '^\*"\s+CHANGING')   { $section = "C"; continue }
    if ($t -match '^\*"\s+TABLES')     { $section = "T"; continue }
    if ($t -match '^\*"\s+EXCEPTIONS') { $section = "X"; continue }
    if ($t -notmatch '^\*"(.+)$') { continue }
    $pline = $Matches[1].Trim()
    if ($pline -eq "") { continue }
    if ($section -eq "X") { $exceptions.Add($pline); continue }
    $passBy = "VALUE"; $pName = ""
    if      ($pline -match '^VALUE\((\w+)\)\s+(.+)$')     { $passBy = "VALUE";     $pName = $Matches[1]; $pline = $Matches[2] }
    elseif  ($pline -match '^REFERENCE\((\w+)\)\s+(.+)$') { $passBy = "REFERENCE"; $pName = $Matches[1]; $pline = $Matches[2] }
    elseif  ($pline -match '^(\w+)\s+(.+)$')               { $passBy = "VALUE";     $pName = $Matches[1]; $pline = $Matches[2] }
    else { continue }
    $typeField = "TYPE"; $typeName = ""; $optional = $false
    if ($pline -match '^(TYPE|LIKE|STRUCTURE)\s+(\S+)(\s+OPTIONAL)?') {
        $typeField = if ($Matches[1] -eq "STRUCTURE") {"LIKE"} else {$Matches[1]}
        $typeName  = $Matches[2]
        $optional  = ($null -ne $Matches[3] -and $Matches[3].Trim() -eq "OPTIONAL")
    }
    $param = @{Name=$pName; TypeField=$typeField; TypeName=$typeName; PassBy=$passBy; Optional=$optional}
    switch ($section) {
        "I" { $importing.Add($param)  }
        "E" { $exporting.Add($param)  }
        "C" { $changing.Add($param)   }
        "T" { $tables.Add($param)     }
    }
}

Write-Host "Parsed FM    : $fmName"
Write-Host "IMPORTING ($($importing.Count)): $($importing | ForEach-Object {"$($_.Name) $($_.TypeField) $($_.TypeName) $($_.PassBy)$(if($_.Optional){' OPT'}else{''})"} | Join-String -Separator ', ')"
Write-Host "EXPORTING ($($exporting.Count)): $($exporting | ForEach-Object {"$($_.Name) $($_.TypeField) $($_.TypeName)"} | Join-String -Separator ', ')"
Write-Host "CHANGING  ($($changing.Count)): $($changing  | ForEach-Object {"$($_.Name) $($_.TypeField) $($_.TypeName)"} | Join-String -Separator ', ')"
Write-Host "TABLES    ($($tables.Count)): $($tables    | ForEach-Object {"$($_.Name) $($_.TypeField) $($_.TypeName)"} | Join-String -Separator ', ')"
Write-Host "EXCEPTIONS($($exceptions.Count)): $($exceptions -join ', ')"

# ── 2. Build interface VBS code ──────────────────────────────────
# hasOptVal = true  → generates Optional[4,r] and Value[5,r] checkbox lines
# IMPORTING, EXPORTING, CHANGING: hasOptVal true
# TABLES: no Value checkbox (col 4 = Optional only, no col 5)
# EXCEPTIONS: separate function (different column layout)

function Build-ParamTabCode {
    param(
        [string]$tabId,
        [string]$subId,
        [string]$tblName,
        $params,
        [bool]$hasValue    # whether this tab has a Pass by Value checkbox at col 5
    )
    $pfx = "wnd[0]/usr/tabsFUNC_TAB_STRIP/$tabId/ssubSCREEN_HEADER:$subId/$tblName"
    # Defensive overlay: keep On Error Resume Next ACROSS the entire block.
    # If a tab subscreen fails to render on this SAP version (e.g. EXCEPTIONS
    # tab on S/4HANA 1909 when the FM is in an obsolete-TABLES warning state),
    # findById raises a hard error. Without resilience, the whole script
    # crashes and leaves the FM half-deployed. We swallow per-write errors
    # here and trust SAP's *"Local Interface:* comment-block parsing on save
    # for the parameters; the post-deploy RFC verifier (FUPARAREF check)
    # surfaces any real interface drop.
    $c  = "On Error Resume Next`r`n"
    $c += "oSession.findById(`"wnd[0]/usr/tabsFUNC_TAB_STRIP/$tabId`").select" + "`r`n"
    $c += "Err.Clear`r`n"
    $c += "WScript.Sleep 500`r`n"
    $clearLimit = $params.Count + 20
    for ($r = $params.Count; $r -lt $clearLimit; $r++) {
        $c += "oSession.findById(`"$pfx/txtRSFBPARA-PARAMETER[0,$r]`").text = `"`"`r`n"
        $c += "oSession.findById(`"$pfx/ctxtRSFBPARA-TYPEFIELD[1,$r]`").text = `"`"`r`n"
        $c += "oSession.findById(`"$pfx/ctxtRSFBPARA-STRUCTURE[2,$r]`").text = `"`"`r`n"
        $c += "oSession.findById(`"$pfx/chkRSFBPARA-OPTIONAL[4,$r]`").selected = false`r`n"
        if ($hasValue) {
            $c += "oSession.findById(`"$pfx/chkRSFBPARA-VALUE[5,$r]`").selected = false`r`n"
        }
        $c += "Err.Clear`r`n"
    }
    for ($r = 0; $r -lt $params.Count; $r++) {
        $p = $params[$r]
        $c += "oSession.findById(`"$pfx/txtRSFBPARA-PARAMETER[0,$r]`").text = `"$($p.Name)`"`r`n"
        $c += "If Err.Number <> 0 Then WScript.Echo `"WARNING: $tabId row $r findById failed: `" & Err.Description : Err.Clear`r`n"
        $c += "oSession.findById(`"$pfx/ctxtRSFBPARA-TYPEFIELD[1,$r]`").text = `"$($p.TypeField)`"`r`n"
        if ($p.TypeName -ne "") {
            $c += "oSession.findById(`"$pfx/ctxtRSFBPARA-STRUCTURE[2,$r]`").text = `"$($p.TypeName)`"`r`n"
        }
        if ($p.Optional) {
            $c += "oSession.findById(`"$pfx/chkRSFBPARA-OPTIONAL[4,$r]`").selected = true`r`n"
        }
        if ($hasValue -and $p.PassBy -eq "VALUE") {
            $c += "oSession.findById(`"$pfx/chkRSFBPARA-VALUE[5,$r]`").selected = true`r`n"
        }
        $c += "Err.Clear`r`n"
    }
    # Commit + dismiss sequence.
    # Step 1: First ENTER commits the row(s).
    # Step 2: If a wnd[1] popup appears (e.g. Copy-or-Rename), send ENTER to dismiss.
    #
    # NOTE: Earlier revisions of this generator emitted a third step that
    # checked sbar.MessageType=W/I and sent a second ENTER on the theory
    # that warnings like "TABLES parameters are obsolete!" needed
    # acknowledgement. That was incorrect: this warning is a passive
    # status-bar text SAP keeps painting whenever the Tables tab is on
    # screen — ENTER does not clear it (confirmed 2026-05-12 — the
    # operator pressed ENTER repeatedly and the message stayed). The
    # deploy succeeds anyway because the next Save / Activate writes a
    # different sbar message over the warning. The right fix for the
    # warning is to drop the TABLES section from the FM signature; see
    # Z_GENERIC_RFC_WRAPPER_TBL.abap for that migration.
    $c += "oSession.findById(`"wnd[0]`").sendVKey 0`r`n"
    $c += "Err.Clear`r`n"
    $c += "WScript.Sleep 500`r`n"
    $c += "If InStr(oSession.ActiveWindow.Id, `"wnd[1]`") > 0 Then`r`n"
    $c += "    oSession.findById(`"wnd[1]`").sendVKey 0`r`n"
    $c += "    Err.Clear`r`n"
    $c += "    WScript.Sleep 300`r`n"
    $c += "End If`r`n"
    $c += "On Error GoTo 0`r`n"
    return $c
}

function Build-ExceptTabCode {
    param($params)
    $pfx = "wnd[0]/usr/tabsFUNC_TAB_STRIP/tabpEXCEPT/ssubSCREEN_HEADER:SAPLSFUNCTION_BUILDER:3062/tblSAPLSFUNCTION_BUILDEREXCEPT"
    # Defensive overlay (same rationale as Build-ParamTabCode). On S/4HANA
    # the EXCEPTIONS tab subscreen sometimes fails to render until the FM is
    # saved cleanly; without per-write resilience the script crashes here
    # and leaves the FM half-deployed (no FUPARAREF / no FUNC_EXCEPTION).
    $c  = "On Error Resume Next`r`n"
    $c += "oSession.findById(`"wnd[0]/usr/tabsFUNC_TAB_STRIP/tabpEXCEPT`").select`r`n"
    $c += "Err.Clear`r`n"
    $c += "WScript.Sleep 500`r`n"
    for ($r = $params.Count; $r -lt ($params.Count + 20); $r++) {
        $c += "oSession.findById(`"$pfx/txtRSFBPARA-PARAMETER[0,$r]`").text = `"`"`r`n"
        $c += "Err.Clear`r`n"
    }
    for ($r = 0; $r -lt $params.Count; $r++) {
        $c += "oSession.findById(`"$pfx/txtRSFBPARA-PARAMETER[0,$r]`").text = `"$($params[$r])`"`r`n"
        $c += "If Err.Number <> 0 Then WScript.Echo `"WARNING: tabpEXCEPT row $r findById failed: `" & Err.Description : Err.Clear`r`n"
    }
    # Commit + popup-dismiss. See Build-ParamTabCode for why the
    # earlier sbar W/I "second ENTER" branch was removed.
    $c += "oSession.findById(`"wnd[0]`").sendVKey 0`r`n"
    $c += "Err.Clear`r`n"
    $c += "WScript.Sleep 500`r`n"
    $c += "If InStr(oSession.ActiveWindow.Id, `"wnd[1]`") > 0 Then`r`n"
    $c += "    oSession.findById(`"wnd[1]`").sendVKey 0`r`n"
    $c += "    Err.Clear`r`n"
    $c += "    WScript.Sleep 300`r`n"
    $c += "End If`r`n"
    $c += "On Error GoTo 0`r`n"
    return $c
}

$ifaceCode = "On Error Resume Next`r`n"
if ($importing.Count  -gt 0) { $ifaceCode += Build-ParamTabCode "tabpIMPORT" "SAPLSFUNCTION_BUILDER:3050" "tblSAPLSFUNCTION_BUILDERIMPORT" $importing  $true  }
if ($exporting.Count  -gt 0) { $ifaceCode += Build-ParamTabCode "tabpEXPORT" "SAPLSFUNCTION_BUILDER:3052" "tblSAPLSFUNCTION_BUILDEREXPORT" $exporting  $true  }
if ($changing.Count   -gt 0) { $ifaceCode += Build-ParamTabCode "tabpCHANGE" "SAPLSFUNCTION_BUILDER:3054" "tblSAPLSFUNCTION_BUILDERCHANGE" $changing   $true  }
if ($tables.Count     -gt 0) { $ifaceCode += Build-ParamTabCode "tabpTABLES" "SAPLSFUNCTION_BUILDER:3060" "tblSAPLSFUNCTION_BUILDERTABLES" $tables     $false }
if ($exceptions.Count -gt 0) { $ifaceCode += Build-ExceptTabCode $exceptions }
$ifaceCode += "Err.Clear : On Error GoTo 0`r`n"

# ── 3. Fill template tokens and write VBS ───────────────────────
$content = Get-Content "$skillDir\references\sap_se37_create.vbs" -Raw
$content = $content -replace '%%FM_NAME%%',        $fmName
$content = $content -replace '%%FUNC_GROUP%%',     $funcGroup
$content = $content -replace '%%FM_SHORT_TEXT%%',  $shortText
$content = $content -replace '%%ABAP_SOURCE_FILE%%', $fmFilePath
$content = $content -replace '%%PACKAGE%%',        $package
$content = $content -replace '%%TRANSPORT%%',      $transport
$content = $content.Replace('%%INTERFACE_CODE%%',  $ifaceCode)
$content = $content -replace '%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'
Set-Content "$workTemp\sap_se37_create_run.vbs" $content -Encoding Unicode
Write-Host "VBS written: $workTemp\sap_se37_create_run.vbs"
Write-Host 'Done'
```

Fill these placeholders before writing:

| Placeholder | Value |
|---|---|
| `THE_SOURCE_PATH` | Absolute path to FM source file (e.g. `C:\Temp\Z_HKFM_TEST006.txt`) |
| `THE_FUNC_GROUP` | Function group (ask user if not in source) |
| `THE_SHORT_TEXT` | FM short description (ask user if not in source) |
| `THE_PACKAGE` | SAP package — blank for local $TMP |
| `THE_TRANSPORT` | Transport request — blank for local |
| `THE_SKILL_DIR` | Absolute path to this skill directory |
| `THE_WORK_TEMP` | `{WORK_TEMP}` resolved value |

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se37_create_run.ps1"
```

Confirm the parse output matches the expected interface before proceeding.

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se37_create_run.vbs
```

Proceed to Step 6 to evaluate the result.

---

## Step 5d — Change Function Module Attributes (Short Text / Processing Type)

**When to run:** The user wants to modify a function module's header
attributes (Short Text, Processing Type, optionally the Update Kind for
Update Modules) **without** uploading source. Examples:

- "Change the short text of `Z_HKFM_TEST007` to '…'"
- "Make `Z_HKFM_TEST007` remote-enabled"
- "Change `Z_MY_UPDATE_FM` to a delayed update module"

The change-attributes VBScript template is at `./references/sap_se37_change_attrs.vbs`.

### Collect Inputs

| Token | Description | Allowed values | Empty? |
|---|---|---|---|
| `%%FM_NAME%%` | Function module (UPPERCASE) | `Z_HKFM_TEST007` | required |
| `%%SHORT_TEXT%%` | New short text (max 70 chars) | any text | empty = leave unchanged |
| `%%PROCESSING_TYPE%%` | Processing type | `NORMAL` (Regular) / `REMOTE` (Remote-Enabled) / `UPDATE` (Update Module) | empty = leave unchanged |
| `%%UPDATE_KIND%%` | Sub-radio for Update Module only | `UKIND1` (Start immed.) / `UKIND2` (Start Delayed) / `UKIND3` (Immediate, not updateable) / `UKIND4` (Coll. run) | empty = leave unchanged or N/A |
| `%%TRANSPORT%%` | TR for the post-save popup | TR number | empty when local (`$TMP`) or already locked to a modifiable TR |

If the FM's function group is transportable (look up `TADIR-DEVCLASS` for
`R3TR FUGR <function_group>`; not starting with `$`), resolve a TR via
Step 1b before generating the VBS and pass it as `%%TRANSPORT%%`. If the
object is local or already locked, leave it empty — the VBS will only
abort if SAP actually prompts.

If only the FM name is supplied and all of `SHORT_TEXT`, `PROCESSING_TYPE`,
`UPDATE_KIND` are empty, ask the user which attribute to change. Do not
run the VBS with no values (it will exit `DONE: NO_CHANGE`).

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se37_change_attrs_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se37_change_attrs.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%FM_NAME%%',         'THE_FM_NAME')
$content  = $content.Replace('%%SHORT_TEXT%%',      'THE_SHORT_TEXT')
$content  = $content.Replace('%%PROCESSING_TYPE%%', 'THE_PROCESSING_TYPE')
$content  = $content.Replace('%%UPDATE_KIND%%',     'THE_UPDATE_KIND')
$content  = $content.Replace('%%TRANSPORT%%',       'THE_TRANSPORT')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se37_change_attrs_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Use `.Replace()` (literal) — short text may contain regex metacharacters.
Replace `<SKILL_DIR>` and the `THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se37_change_attrs_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se37_change_attrs_run.vbs
```

### Behaviour Notes

- The Attributes screen lives in the SE37 main editor as the
  `tabsFUNC_TAB_STRIP/tabpHEADER` tab — **not** a modal dialog. The VBS
  enters change mode via `wnd[0]/usr/btnBUT4`, then selects the tab.
- **Original-language popup is conditional.** SAPLSETX
  (`wnd[1]/usr/ctxtRSETX-MASTERLANG`) only appears when the logon
  language differs from the FM's `MASTERLANG`. The VBS detects it by
  fingerprint and presses `wnd[1]/usr/btnPUSH1`
  ("Maint. in orig. lang."). If logon language matches, it's silently
  skipped.
- **Field IDs (subscreen `SAPLSFUNCTION_BUILDER:3030` under `tabpHEADER`):**
  | Field | ID (relative to tab subscreen) |
  |---|---|
  | Short Text | `txtTFTIT-STEXT` |
  | Regular Function Module | `radRS38L-NORMAL` |
  | Remote-Enabled Module | `radRS38L-REMOTE` |
  | Update Module | `radRS38L-VERBUCHER` |
  | UKIND1–4 | `radRS38L-UKIND1` … `radRS38L-UKIND4` |
  | Save | `wnd[0]/tbar[0]/btn[11]` (Ctrl+S) |
- **Post-save TR popup.** If SAP prompts via
  `wnd[1]/usr/ctxtKO008-TRKORR`, the VBS fills `%%TRANSPORT%%` and
  presses Enter. If the popup appears but `%%TRANSPORT%%` is empty, the
  VBS aborts with `ERROR: SAP prompted for a transport request but
  TRANSPORT is empty` — resolve a TR via `/sap-transport-request` and
  re-run.
- **Lock-error popup.** If the FM is locked by another modifiable task,
  SAP shows an Error popup (`txtMESSTXT1`/`txtMESSTXT2` containing
  `locked`). The VBS detects this and exits 1 with
  `ERROR: SAP popup [Error] …`.
- **No-change path.** If all of SHORT_TEXT / PROCESSING_TYPE /
  UPDATE_KIND are empty, the VBS backs out without saving (F3 + No on
  the "Data was changed" prompt) and exits 0 with `DONE: NO_CHANGE`.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Attributes updated for <FM>.` | Save succeeded. Status bar message also echoed. |
| `DONE: NO_CHANGE` | No values supplied; backed out without saving. |
| `ERROR: …` | Couldn't reach Attributes tab, invalid value, lock error, or missing TR. Show full output. |

After success, proceed to Step 7 (cleanup). Skip Step 6 — no source/activation
status applies.

---

## Step 5e — Reassign Function Module to Another Function Group

**When to run:** The user wants to move an existing FM from its current
function group to a different one. Examples:

- "Reassign `Z_HKFM_TEST007` to function group `ZHKFG02`"
- "Move `Z_HK_RFC_TEST` from `ZHKFG01` to `ZHKFG_NEW`"

**Preconditions (verify before running):**

- The FM must be currently **active** (no inactive version pending). If
  it's inactive, activate it first (toolbar Activate, Ctrl+F3) or run the
  fix flow.
- Both the **old and the new function group** must exist and be active.
  Use `/sap-function-group` to create the target group first if needed.
- The FM (and the target FUGR) must be assignable to the same package /
  TR scope; the post-reassign TR popup needs a modifiable TR for both
  objects.

The reassign VBScript template is at `./references/sap_se37_reassign_fugr.vbs`.

### Collect Inputs

| Token | Description | Empty? |
|---|---|---|
| `%%FM_NAME%%` | Function module name (UPPERCASE) | required |
| `%%NEW_FUNC_GROUP%%` | Target function group (UPPERCASE), must already exist & be active | required |
| `%%TRANSPORT%%` | TR for the post-reassign TR popup | empty when local (`$TMP`) or already locked to a modifiable TR |

If the FM's package is transportable, resolve a TR via Step 1b and pass
it as `%%TRANSPORT%%`. If local or already locked, leave it empty — the
VBS only aborts if SAP actually prompts.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se37_reassign_fugr_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se37_reassign_fugr.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%FM_NAME%%',        'THE_FM_NAME')
$content  = $content.Replace('%%NEW_FUNC_GROUP%%', 'THE_NEW_FUNC_GROUP')
$content  = $content.Replace('%%TRANSPORT%%',      'THE_TRANSPORT')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'
Set-Content '{WORK_TEMP}\sap_se37_reassign_fugr_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `<SKILL_DIR>` and the `THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se37_reassign_fugr_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se37_reassign_fugr_run.vbs
```

### Behaviour Notes

- Reassign is opened from the SE37 initial screen via
  `wnd[0]/tbar[1]/btn[31]` (Reassign icon). The dialog is
  `wnd[1]/usr/ctxtRS38L_FUNC-AREA` for the new function group; confirm
  with `wnd[1]/tbar[0]/btn[0]`.
- **Post-reassign TR popup.** SAP usually opens `ctxtKO008-TRKORR` on
  either `wnd[1]` or `wnd[2]`; the VBS handles both. If the popup
  appears with `%%TRANSPORT%%` empty, the VBS aborts with `ERROR: SAP
  prompted for a transport request but TRANSPORT is empty`.
- **Lock-error popup.** Detected via `wnd[N]` Error title and/or
  `txtMESSTXT1`/`txtMESSTXT2` containing `locked` — VBS exits 1 with
  `ERROR: SAP popup [Error] …`.
- **Re-activate after reassign.** The reassign leaves the FM **inactive**
  in the new function group. The VBS automatically presses Activate
  (`wnd[0]/tbar[1]/btn[27]` = Ctrl+F3) and dismisses the inactive-objects
  worklist popup with Select All (`wnd[1]/tbar[0]/btn[20]`) + Enter.
- Successful sbar messages: `Function module <FM> reassigned` then
  `Object(s) activated`.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: <FM> reassigned to <NEW_FG> and activated.` | Reassign + activation both succeeded. |
| `ERROR: …` | Reassign dialog didn't open, target FUGR invalid/inactive, lock error, missing TR, or activation failed. Show full output. |

After success, proceed to Step 7 (cleanup). Skip Step 6.

---

## Step 5f — Delete Function Module

**When to run:** The user wants to delete a function module. Examples:

- "Delete `Z_HKFM_TEST007`"
- "Remove FM `Z_GENERIC_RFC_WRAPPER_TBL`"
- "Drop function module `Z_OBSOLETE`"

**Deletion is irreversible.** Before generating the VBS, confirm with the
user explicitly: state the FM name, its function group (look up `TFDIR-PNAME`
via `/sap-se16n` if useful), the package locality (transportable vs $TMP),
and ask "Are you sure you want to delete this function module? (yes/no)".
Do not proceed without an explicit yes.

The delete VBScript template is at `./references/sap_se37_delete.vbs`.

### Preconditions

- The FM must already exist (run Step 4 check first; if `NOT_EXIST`, tell
  the user and stop — nothing to delete).
- If the FM is in a transportable package, resolve a TR via Step 1b and
  pass it as `%%TRANSPORT%%`. SAP's post-delete TR popup needs it. If the
  FM is local (`$TMP`) or already locked to a modifiable TR, leave it empty.

### Collect Inputs

| Token | Description | Empty? |
|---|---|---|
| `%%FM_NAME%%` | Function module name (UPPERCASE) | required |
| `%%TRANSPORT%%` | TR for the post-delete prompt | empty when local or already locked |
| `%%SESSION_LOCK_VBS%%` | path to `sap_session_lock.vbs` | required |

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se37_delete_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_se37_delete.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%FM_NAME%%',         'THE_FM_NAME')
$content  = $content.Replace('%%TRANSPORT%%',       'THE_TRANSPORT')
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
Set-Content '{WORK_TEMP}\sap_se37_delete_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `<SKILL_DIR>` and the `THE_*` placeholders.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se37_delete_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_se37_delete_run.vbs
```

### Behaviour Notes

- The Delete button is `wnd[0]/tbar[1]/btn[14]` (Shift+F2) on the SE37
  initial screen after entering the FM name and pressing Enter.
- The "Should the function module be deleted?" confirmation popup is
  dismissed with `wnd[1]/usr/btnSPOP-OPTION1` (Yes). The other button
  is `btnSPOP-OPTION2` (No).
- For transportable FMs, SAP shows a TR-prompt popup
  (`wnd[1]/usr/ctxtKO008-TRKORR`) after the Yes confirmation. The VBS
  fills `%%TRANSPORT%%` and presses Enter. If the popup appears with
  `%%TRANSPORT%%` empty, the VBS exits 1 with `ERROR: SAP prompted for
  a transport request but TRANSPORT is empty`.
- After deletion, the script verifies removal by trying Display
  (`btnBUT3`). If the Function Builder editor opens (i.e., FUNC_TAB_STRIP
  exists), the FM still exists and the VBS reports
  `ERROR: FM still exists after delete`.
- Post-delete RFC verification (recommended): query `TFDIR` via
  `/sap-se16n` filtered by `FUNCNAME = <FM>`; expect zero rows.

### Outputs

| Last line | Meaning |
|---|---|
| `SUCCESS: Function module <FM> deleted.` | FM is gone — sbar status echoed above. |
| `ERROR: …` | Deletion did not complete — see full output. Common causes: FM was locked by another user (SM12), the supplied TR is released, or the operator aborted by pressing No. |

After success, proceed to Step 7 (cleanup). Skip Step 6.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user the function module was deployed and activated.
- Show the full script output as a code block.

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `SE37 function module name field not found` | Component ID mismatch | Use SAP Scripting Recorder to find correct ID |
| `Create dialog did not appear` | FM already exists or wrong name | Check name or use update flow |
| `Could not open Upload menu` | Menu path differs by SAP version | Use Scripting Recorder to record correct menu path |
| `Upload dialog interaction failed` | Upload dialog IDs differ | Re-record the upload step |
| `Syntax check failed` | ABAP syntax errors | See **Step 6a** below |
| `Statement is not accessible` | Source file missing FUNCTION/ENDFUNCTION wrapper, or inactive versions in function group | Ensure source includes `FUNCTION <name>.` ... `ENDFUNCTION.` |
| `Source file not found` | Wrong path or file not written | Verify path, re-run Step 2 |
| `Could not reach Function Builder editor` | Create dialogs failed | Check SAP status bar for details |
| `Could not open function module in change mode` | FM locked or no auth | Check locks (SM12) or authorization |
| `Function group XXX does not exist` | Function group not created | Create the function group first via SE37 menu: Goto > Function Groups > Create Group |

---

## Step 6a — Fix Syntax Errors and Re-Activate

When the VBS reports `ERROR: Syntax check found N error(s)`, the FM exists in SAP but
has ABAP syntax errors. The FM is deployed but cannot be used until errors are fixed.

### Read source from SAP (if original file is unavailable)

If the source file is no longer available locally, read it from the live SAP editor:

```vbscript
' Read DEEP4 source from SAP AbapEditor
' (run via cscript //NoLogo from sap_se37_read_src.vbs)
oSession.findById("wnd[0]/usr/ctxtRS38L-NAME").Text = "THE_FM_NAME"
oSession.findById("wnd[0]/usr/btnBUT3").press   ' Display
WScript.Sleep 2000
oSession.findById("wnd[0]/usr/tabsFUNC_TAB_STRIP/tabpSOURCE").select
WScript.Sleep 1500
Dim oShell
Set oShell = oSession.findById("wnd[0]/usr/tabsFUNC_TAB_STRIP/tabpSOURCE/ssubSCREEN_HEADER:SAPLEDITOR_START:8430/cntlEDITOR/shellcont/shell")
' Read lines via GetLineText(n), 0-indexed, stop on error
Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
Dim oFile : Set oFile = oFSO.CreateTextFile("{WORK_TEMP}\fm_src_from_sap.txt", True, True)
On Error Resume Next
Dim i : For i = 0 To 500
    Dim s : s = oShell.GetLineText(i)
    If Err.Number <> 0 Then Err.Clear : Exit For
    oFile.WriteLine s
Next
oFile.Close
```

The resulting file is UTF-16 LE (because `CreateTextFile(..., True, True)` writes Unicode).

### Fix the source and re-upload

```powershell
# Fix source file (UTF-16 LE), write fixed UTF-16 LE copy
$bytes = [System.IO.File]::ReadAllBytes('{WORK_TEMP}\fm_src_from_sap.txt')
$enc = [System.Text.Encoding]::Unicode
$text = $enc.GetString($bytes).TrimStart([char]0xFEFF)
# Apply fixes — example: replace typo
$text = $text -replace '(?i)bad_variable_name','correct_name'
[System.IO.File]::WriteAllText('{WORK_TEMP}\fm_src_fixed.txt', $text, [System.Text.Encoding]::Unicode)
```

Then run the **Step 5a update flow** with `%%ABAP_SOURCE_FILE%%` pointing to `{WORK_TEMP}\fm_src_fixed.txt`.

---

## Step A — Check Syntax and Download Source (Fix Mode)

Use this step when no source file was provided and the task is to check or fix an existing function module.

The check-and-download VBScript template is at `./references/sap_se37_check_and_download.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_se37_check_and_download_run.ps1`:
```powershell
$fmName   = 'THE_FM_NAME'
$outFile  = 'THE_OUTPUT_FILE'
$skillDir = 'THE_SKILL_DIR'
$workTemp = 'THE_WORK_TEMP'

$content = Get-Content "$skillDir\references\sap_se37_check_and_download.vbs" -Raw
$content = $content -replace '%%FM_NAME%%',     $fmName
$content = $content -replace '%%OUTPUT_FILE%%', $outFile
# Phase 3.5 session-attach plumbing.
$sessionPath = ''
$content = $content -replace '%%SESSION_PATH%%',   $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = "$workTemp\sap_active_session.json"
Set-Content "$workTemp\sap_se37_check_and_download_run.vbs" $content -Encoding Unicode
Write-Host 'Done'
```

| Placeholder | Value |
|---|---|
| `THE_FM_NAME` | Function module name (UPPERCASE) |
| `THE_OUTPUT_FILE` | `{WORK_TEMP}\<FM_NAME>_from_sap.txt` |
| `THE_SKILL_DIR` | Absolute path to this skill directory |
| `THE_WORK_TEMP` | `{WORK_TEMP}` resolved value |

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_se37_check_and_download_run.ps1"
```

### Execute
```bash
cscript //NoLogo {WORK_TEMP}\sap_se37_check_and_download_run.vbs
```

**Parse the output:**

| Last output line | Meaning | Next step |
|---|---|---|
| `RESULT: SYNTAX_OK` | No syntax errors | Tell the user — skip to Step 7 |
| `RESULT: SYNTAX_ERRORS` | Errors found (shown above the RESULT line) | Proceed to Step B |
| `ERROR:` | Fatal failure | Show full output, stop |

---

## Step B — Analyze and Fix Source

The source was downloaded to `{WORK_TEMP}\<FM_NAME>_from_sap.txt` (UTF-16 LE).

**1. Read the file:**
```powershell
$bytes = [System.IO.File]::ReadAllBytes('{WORK_TEMP}\<FM_NAME>_from_sap.txt')
$text  = [System.Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF)
Write-Host $text
```

**2. Analyze each error:** Use the line numbers and descriptions from the Step A output to locate the bad code in `$text`.

**3. Apply fixes:**
```powershell
# Example — replace a bad variable name
$text = $text -replace '(?i)bad_pattern', 'correct_replacement'
```

**4. Write the fixed file:**
```powershell
[System.IO.File]::WriteAllText('{WORK_TEMP}\<FM_NAME>_fixed.txt', $text, [System.Text.Encoding]::Unicode)
```

Repeat until all errors identified in Step A are addressed, then proceed to Step C.

---

## Step C — Re-upload Fixed Source

Run the **Step 5a (Update)** flow with `{WORK_TEMP}\<FM_NAME>_fixed.txt` as `THE_SOURCE_PATH`.

The update VBS saves, activates, runs syntax check, and reports the result:

| Output | Action |
|---|---|
| `SUCCESS:` | FM is fixed and active — tell the user, proceed to Step 7 |
| `ERROR: Syntax check found` | Errors remain — return to Step B and fix remaining errors |
| Other `ERROR:` | Diagnose using the Step 6 error table |

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_se37_check_run.vbs & del {WORK_TEMP}\sap_se37_check_run.ps1 & del {WORK_TEMP}\sap_se37_create_run.vbs & del {WORK_TEMP}\sap_se37_create_run.ps1 & del {WORK_TEMP}\sap_se37_update_run.vbs & del {WORK_TEMP}\sap_se37_update_run.ps1 & del {WORK_TEMP}\sap_se37_check_and_download_run.vbs & del {WORK_TEMP}\sap_se37_check_and_download_run.ps1 & del {WORK_TEMP}\sap_se37_change_attrs_run.vbs & del {WORK_TEMP}\sap_se37_change_attrs_run.ps1 & del {WORK_TEMP}\sap_se37_reassign_fugr_run.vbs & del {WORK_TEMP}\sap_se37_reassign_fugr_run.ps1 & del {WORK_TEMP}\sap_se37_delete_run.vbs & del {WORK_TEMP}\sap_se37_delete_run.ps1
```

For fix mode, also delete:
```bash
cmd /c del {WORK_TEMP}\<FM_NAME>_from_sap.txt & del {WORK_TEMP}\<FM_NAME>_fixed.txt
```

Also delete `{WORK_TEMP}\<FM_NAME>.abap` if the user pasted code (not a user-supplied file).

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se37_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_se37_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE37_FAILED`, `SE37_INACTIVE`, `SE37_LOCKED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).

---

## Important: Encoding

When filling VBS templates, always write with **`-Encoding Unicode`** (UTF-16 LE) in PowerShell.
UTF-16 LE is what `cscript` supports natively and preserves non-ASCII characters.
UTF-8 with BOM causes a cscript compile error.

### ABAP Source File Encoding (文字化け Fix)

The VBS templates automatically handle ABAP source file encoding:
- The templates detect whether the SAP system is **Unicode** using `oSession.Info.Codepage`
  - **Unicode SAP** (codepage 4110/4103): Upload the UTF-8 file **directly** — no conversion needed
  - **Non-Unicode SAP**: Convert UTF-8 to the Windows system ANSI codepage via ADODB.Stream
- A temp file `<source>.upload.txt` is created (non-Unicode path only) and cleaned up automatically.

---

## Syntax Check Error Grid (SE37)

The SE37 AbapEditor (new front-end editor) **swallows all status bar messages**.
After syntax check (Ctrl+F2), `wnd[0]/sbar` returns empty MessageType and Text.

The VBS templates read errors from the error grid instead:
- **Grid path**: `wnd[0]/shellcont/shell/shellcont[1]/shell`
- **Columns**: `MSGTYPE`, `LINE`, `TEXT`
- **Error format**: Pairs of rows — row N has MSGTYPE=`@5C\QError@`, LINE=number, TEXT=FM name; row N+1 has TEXT=error description
- **No errors**: Grid not found (RowCount throws error 424) = syntax check passed

### Activate-Before-Check Order

The VBS templates activate the FM **before** running the syntax check. If a function
group has inactive versions, the syntax checker may report "Statement is not accessible"
on all lines — a false positive resolved by activating first.

### `Inactive Objects for <USER>` Popup on Activate

After Ctrl+F3 (`wnd[0]/tbar[1]/btn[27]`) SAP may show modal `wnd[1]` titled
`Inactive Objects for <USER>` listing the FM and any inactive siblings in the
function group. The popup has only a single toolbar button
(`wnd[1]/tbar[0]/btn[0]` = Continue) — there is no Select-All button. Pressing
Continue with no rows selected does nothing and the popup hangs.

**Required dismissal** (used by `sap_se37_update.vbs` and
`sap_se37_reassign_fugr.vbs`):

```vbs
oSession.findById("wnd[1]").sendVKey 26   ' Ctrl+A = select all worklist rows
WScript.Sleep 500
oSession.findById("wnd[1]/tbar[0]/btn[0]").press   ' Continue
```

The popup may take up to ~10 s to appear after pressing btn[27]; poll the
active window before assuming it didn't appear.

---

## Upload Menu Path Note

The source upload menu path (`menu[3]/menu[9]/menu[3]/menu[0]`) was recorded on
SAP GUI 7.60 / S/4HANA 1909. Menu indices **may differ** by SAP release
and logon language. If the upload step fails:
1. Open SE37 in your SAP system and navigate to the Source code tab
2. Use SAP Logon > Help > Scripting Recorder and Playback
3. Record the "Upload from local file" menu action
4. Note the menu path from the recording and update the VBS template

---

## Interface Tab Filling Order (Create Flow)

In `sap_se37_create.vbs`, interface tabs are filled **after** the source upload, not before.

**Reason:** When SE37 uploads a full function include (containing `*"` Local Interface
comment lines), SAP may parse those comments and update the interface tables. This can
reset or clear the Exceptions tab if the comment format is not recognized. By filling
all interface tabs (Import / Export / Changing / Tables / Exceptions) **after** the
source upload, the GUI-driven values are always applied last — guaranteeing they match
the parsed FM definition regardless of what the upload set.

**Popup dismissal:** Each tab's `sendVKey 0` (Enter to confirm) is followed by a popup
check — if `wnd[1]` appears, it is dismissed with Enter before navigating to the next
tab. This prevents silent failures from dialogs that block subsequent tab operations.

---

## SE37 Component IDs Reference

| Element | Component ID | Notes |
|---|---|---|
| FM name field (initial) | `wnd[0]/usr/ctxtRS38L-NAME` | GuiCTextField |
| Display button | `wnd[0]/usr/btnBUT3` | |
| Change button | `wnd[0]/usr/btnBUT4` | |
| Create button | `wnd[0]/usr/btnBUT2` | |
| Create popup - FM name | `wnd[1]/usr/ctxtRS38L-NAME` | Pre-filled |
| Create popup - Func group | `wnd[1]/usr/ctxtRS38L-AREA` | |
| Create popup - Short text | `wnd[1]/usr/txtTFTIT-STEXT` | |
| Tab strip | `wnd[0]/usr/tabsFUNC_TAB_STRIP` | |
| Attributes tab | `tabpHEADER` | |
| Import tab | `tabpIMPORT` | |
| Export tab | `tabpEXPORT` | |
| Changing tab | `tabpCHANGE` | |
| Tables tab | `tabpTABLES` | |
| Exceptions tab | `tabpEXCEPT` | |
| Source code tab | `tabpSOURCE` | |
| Source editor | `tabpSOURCE/ssubSCREEN_HEADER:SAPLEDITOR_START:8430/cntlEDITOR/shellcont/shell` | AbapEditor |
| Check (Ctrl+F2) | `wnd[0]/tbar[1]/btn[26]` | |
| Activate (Ctrl+F3) | `wnd[0]/tbar[1]/btn[27]` | |

### Object Directory Entry dialog (wnd[2], SAPLSTRD/100) — Create flow

Package and transport prompts appear after the create popup is confirmed.
Field names vary by SAP release — try S/4HANA fields first, fall back to classic:

| Element | S/4HANA 1909 | Classic / older |
|---|---|---|
| Package field | `wnd[2]/usr/ctxtKO007-L_DEVCLASS` | `wnd[2]/usr/ctxtSEUK-DEVCLASS` |
| Transport field | `wnd[2]/usr/ctxtKO008-TRKORR` | `wnd[2]/usr/ctxtKORR_TXT-REQ_NUM` → `wnd[2]/usr/ctxtKO007-L_REQ` |
| Local Object button | `wnd[2]/tbar[0]/btn[7]` | same |

The same field name fallback applies to the save-time TR popup (`wnd[1]`).

### Interface parameter tabs (S/4HANA 1909, verified on a reference test system)

> **Important:** On S/4HANA the Function Builder uses program `SAPLSFUNCTION_BUILDER`.
> Classic releases use `SAPLPARA`. The IDs below are for S/4HANA — do NOT use `SAPLPARA:1400`
> or `tblSAPLPARA1400TC_PARAMS` on S/4HANA systems.

| Tab | Tab ID | Subscreen | Table control |
|---|---|---|---|
| Import | `tabpIMPORT` | `SAPLSFUNCTION_BUILDER:3050` | `tblSAPLSFUNCTION_BUILDERIMPORT` |
| Export | `tabpEXPORT` | `SAPLSFUNCTION_BUILDER:3052` | `tblSAPLSFUNCTION_BUILDEREXPORT` |
| Changing | `tabpCHANGE` | `SAPLSFUNCTION_BUILDER:3054` | `tblSAPLSFUNCTION_BUILDERCHANGE` |
| Tables | `tabpTABLES` | `SAPLSFUNCTION_BUILDER:3060` | `tblSAPLSFUNCTION_BUILDERTABLES` |
| Exceptions | `tabpEXCEPT` | `SAPLSFUNCTION_BUILDER:3062` | `tblSAPLSFUNCTION_BUILDEREXCEPT` |

Parameter row column indices (zero-based):

| Column | Index | Field ID pattern |
|---|---|---|
| Parameter name | 0 | `txtRSFBPARA-PARAMETER[0,row]` |
| Type flag (TYPE / LIKE) | 1 | `ctxtRSFBPARA-TYPEFIELD[1,row]` |
| Type / structure name | 2 | `ctxtRSFBPARA-STRUCTURE[2,row]` |
| Default value | 3 | `txtRSFBPARA-DEFAULTVAL[3,row]` |
| Optional checkbox | 4 | `chkRSFBPARA-OPTIONAL[4,row]` |
| Pass by Value checkbox | 5 | `chkRSFBPARA-VALUE[5,row]` (Import/Export/Changing only) |

---

## Troubleshooting Component IDs / Stuck Screen

**FIRST RESORT — invoke `/sap-gui-diagnose full`.**

`sap-gui-diagnose` screenshots every visible window via the SAP GUI
Scripting `HardCopy` API, composes them into one annotated PNG, and
chains to `/sap-gui-object-details` for the topmost window. Read the
PNG with the Read tool to see what's on screen, then decide what to
do based on both the visual and the structural dump.

**SECOND RESORT — `/sap-gui-object-details` alone.** Use this when
`/sap-gui-diagnose` itself fails (GUI minimised, HardCopy blocked) or
when you only need a quick structural confirmation.

When a VBS step fails with `The control could not be found by id`, an unexpected
popup appears, or the script hangs because the screen flow diverged from what was
expected, do NOT guess. Call the `sap-gui-object-details` skill immediately to
discover the actual component layout in the current SAP GUI session, then fix the
VBS or dismiss the popup based on the dump.

Recommended diagnostic sequence:

| Step | Mode | Filter | Purpose |
|---|---|---|---|
| 1 | `tree` | (none) | List every open window (`wnd[0]`, `wnd[1]`, …) and their titles |
| 2 | `wnd` | `1` (or `2`) | Full component tree of the unexpected popup — shows its buttons/fields |
| 3 | `id` | `wnd[0]/sbar` | Read the status-bar message when the script appears to do nothing |
| 4 | `type` | `GuiButton` | List every button with text + tooltip when you don't know which to press |
| 5 | `id` | the failing component path | Inspect `Changeable`, `Required`, `Value` to understand why an assignment fails |

After the dump, decide:
- Unexpected popup (e.g. "Function group does not exist — create?") → press its OK/Cancel button (`wnd[N]/tbar[0]/btn[0]` or `btn[12]`) and retry.
- Component ID changed between SAP releases → update the VBS template with the discovered ID.
- Source-code editor not accepting input → check `SubType` (AbapEditor vs TextEdit) via `id` mode.

**Last resort (only if `sap-gui-object-details` cannot help):**
1. SAP Logon > Help > Scripting Recorder and Playback
2. Click Record, perform the failing step manually, stop recording
3. The recorded script shows the correct component IDs

---

## VBScript Pitfalls

### Stale object reference under `On Error Resume Next`

When `On Error Resume Next` is active and a `findById` call fails, VBScript
suppresses the error **but does not set the target variable to `Nothing`** —
it keeps its previous value. The next `If Not (oObj Is Nothing)` check then
passes on a stale object from the previous iteration, causing incorrect writes.

**Fix:** Always `Set oObj = Nothing` immediately before each `Set oObj = oSession.findById(...)`:

```vbs
' WRONG — oGrid may hold last iteration's value if findById fails:
Set oGrid = oSession.findById(sBase & "/someId")
If Err.Number = 0 And Not (oGrid Is Nothing) Then ...

' CORRECT:
Set oGrid = Nothing
Set oGrid = oSession.findById(sBase & "/someId")
If Err.Number = 0 And Not (oGrid Is Nothing) Then ...
```

This pattern is especially important inside loops where the same variable is
reused across iterations.

### `iF` is a reserved word

VBScript is case-insensitive, so `Dim iF` declares a variable named `IF` —
the keyword. This causes runtime error 619 on any line that uses `iF`.
Use `idxFld`, `iFld`, `idx`, etc. instead.

### Inactive Objects popup: Select All required before Continue

The "Inactive Objects" worklist popup (`wnd[1]`) appears after pressing
Activate (`tbar[1]/btn[27]`). Pressing `btn[0]` (Continue) **with nothing
selected** leaves the popup open — no objects are activated. Always send
`sendVKey 26` (Ctrl+A = Select All) before pressing Continue:

```vbs
oSession.findById("wnd[1]").sendVKey 26   ' Select All
WScript.Sleep 500
oSession.findById("wnd[1]/tbar[0]/btn[0]").press  ' Continue
```

The popup may also appear several seconds after pressing Activate (especially
when sibling function-group objects are also inactive). Poll for up to ~10s
before concluding the popup did not appear.
