---
name: sap-sp02
description: |
  Downloads a SAP spool request to a local text file via transaction
  SP02 (Output Controller — own spool requests). Drives the GUI in
  three steps: locate the spool by number on the SP02 list, F2 to
  open contents, then Save (tbar[1]/btn[48]) — picking the export
  format radio (default Unconverted = plain text) and entering the
  target path/filename.
  Works for any list-style spool that SP02 can render (executable
  reports, ALV grids printed to spool, etc.). Format defaults to
  Unconverted plain text but accepts Spreadsheet / Rich text / HTML
  via the FORMAT_INDEX argument.
  Prerequisites: Active SAP GUI session (use /sap-login first), and
  the target spool must belong to the logged-in user (or appear in
  the user's default SP02 selection).
argument-hint: "<SPOOL_NUMBER> <OUTPUT_PATH> [--format=text|csv|rtf|html] [--row=<N>]"
---

# SAP SP02 — Spool Download Skill

You download a SAP spool request to a local text file using SP02 GUI
scripting. The spool number is the SAP-assigned `TSP01-RQIDENT` (e.g.
`397`) — the same number ABAP reports print to the joblog as
"Spool request <NNN> created."

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SKILL_DIR>/references/sap_sp02_download.vbs` | many | SP02 driver: list scan + F2 + tbar[1]/btn[48] + format radio + DY_PATH/DY_FILENAME |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/sap_gui_security_handling.md` | *(rule)* | SAP GUI Security dialog handling — the spool **download to a local file** (Step 3, via DY_PATH/DY_FILENAME) is SAP-GUI-side file IO, so it can raise the modal "SAP GUI Security" dialog (which suspends the Scripting API and hangs cscript). Pre-check + OS-level watcher wrap that download. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_precheck.ps1` | *(script)* | Read-only allow-list pre-check (`saprules.xml`) — `ALLOWED` (exit 0) / `NOT_COVERED` (exit 1). Used by Step 3 before the spool download. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_sidecar.ps1` | *(script)* | OS-level (Win32) watcher that auto-dismisses the SAP GUI Security dialog (ticks Remember + clicks Allow). Launched as a background process before the Step 3 download. |

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `work_dir`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_sp02_run.json" -Skill sap-sp02 -ParamsJson "{\"spool\":\"<SPOOL_NUMBER>\"}"
```

State file: `{WORK_TEMP}\sap_sp02_run.json`. Best-effort.

---

## Step 1 — Parse Arguments

| Arg | Required | Notes |
|---|---|---|
| `SPOOL_NUMBER` | yes (or `--row=<N>`) | SAP spool request number, numeric, e.g. `397`. Matches `TSP01-RQIDENT`. |
| `OUTPUT_PATH` | yes | Full local path, e.g. `C:\Temp\SP02_397.txt`. The skill splits this into `OUTPUT_DIR` (parent + trailing `\`) and `OUTPUT_FILE` (basename). |
| `--format=<fmt>` | no | `text` (default = Unconverted, index 0), `csv` (Spreadsheet, index 1), `rtf` (Rich text, index 2), `html` (HTML, index 3). The exact mapping depends on SAP GUI version — verify with a one-time recording on a new release. |
| `--row=<N>` | no | Bypass the list scan and tick row `<N>` directly (0-based on the user-area). Use this when the auto-scan can't find the spool because it's on a non-default column position. |
| `--col=<N>` | no | Override the spool-number column index used by the list scan (default `4`, S/4HANA 1909). |

**Validation:**

- `SPOOL_NUMBER`: numeric, no leading zeros (the VBS list-scan trims
  whitespace before comparing).
- `OUTPUT_PATH`: parent directory must exist on the local machine. If it
  doesn't, create it with `cmd /c mkdir <dir>` first.
- `OUTPUT_FILE` extension: `.txt` for `--format=text`, `.csv` for
  `--format=csv`, etc. The VBS does NOT enforce a match; SAP writes
  whatever extension you supply.

**If neither SPOOL_NUMBER nor --row is supplied**, ask the user.

---

## Step 2 — Ensure SAP GUI Session

Run `/sap-login` if no session is active. The skill never recreates the
session; it only drives the existing one.

---

## Step 3 — Generate and Run the VBS

Split `OUTPUT_PATH` into `OUTPUT_DIR` (must end with `\`) and
`OUTPUT_FILE`. Map `--format=<fmt>` to `FORMAT_INDEX` (`text`→0,
`csv`→1, `rtf`→2, `html`→3).

Write `{WORK_TEMP}\sap_sp02_download_run.ps1`:

```powershell
$skillDir = '<SKILL_DIR>'
$content  = Get-Content "$skillDir\references\sap_sp02_download.vbs" -Raw
$content  = $content.Replace('%%SPOOL_NUMBER%%',  'THE_SPOOL_NUMBER')
$content  = $content.Replace('%%ROW_INDEX%%',     'THE_ROW_INDEX')      # empty if auto-scan
$content  = $content.Replace('%%SPOOL_NUM_COL%%', 'THE_SPOOL_NUM_COL')  # empty for default 4
$content  = $content.Replace('%%FORMAT_INDEX%%',  'THE_FORMAT_INDEX')   # empty for default 0
$content  = $content.Replace('%%OUTPUT_DIR%%',    'THE_OUTPUT_DIR')     # MUST end with '\'
$content  = $content.Replace('%%OUTPUT_FILE%%',   'THE_OUTPUT_FILE')
# Session-attach plumbing (Phase 3.5 multi-connection aware). Resolution:
# explicit --session > SAPDEV_SESSION_PATH > sole-
# connection auto-default > refuse. See sap_attach_lib.vbs for details.
$sessionPath = ''  # set to the parsed --session value if supplied
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\sap_sp02_download_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```

Run the generator:

```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_sp02_download_run.ps1"
```

### Execute (with SAP GUI Security guard)

The spool download writes the rendered list to a local file via SP02's
`DY_PATH` / `DY_FILENAME` save dialog — **SAP-GUI-side file IO**, so it raises
the modal **SAP GUI Security** dialog when the output path isn't allow-listed
(Default Action = Ask), and that modal suspends the Scripting API, hanging the
cscript. Per `shared/rules/sap_gui_security_handling.md`, pre-check the rules and
run the OS-level watcher around the download. Run as one PowerShell block (the
32-bit cscript is inside it). Substitute `THE_OUTPUT_PATH` with the full output
path (`OUTPUT_DIR` + `OUTPUT_FILE`) and `THE_SID` / `THE_CLIENT` with the pinned
system / client:

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$out    = 'THE_OUTPUT_PATH'   # the local path SAP GUI will write (OUTPUT_DIR + OUTPUT_FILE)
# 1. Pre-check the allow-list (read-only; informational + lets us skip the watcher).
& "$shared\sap_gui_security_precheck.ps1" -Path $out -Access w -System 'THE_SID' -Client 'THE_CLIENT' -Transaction 'SP02' | Out-Host
$allowed = ($LASTEXITCODE -eq 0)
# 2. If not already allow-listed, launch the OS-level watcher BEFORE the
#    (blocking) download. It detects the #32770 dialog and clicks Remember+Allow,
#    which also persists a rule so subsequent runs pre-check ALLOWED.
$watcher = $null
if (-not $allowed) {
    $watcher = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','40')
    Start-Sleep -Milliseconds 800
}
# 3. Run the spool download (32-bit cscript). If the dialog appears it blocks
#    here until the watcher dismisses it; then the download completes.
& 'C:/Windows/SysWOW64/cscript.exe' //NoLogo '{WORK_TEMP}\sap_sp02_download_run.vbs'
# 4. Reap the watcher.
if ($watcher) { $watcher | Wait-Process -Timeout 45 -ErrorAction SilentlyContinue }
```

---

## Step 4 — Interpret the Output

| Last line | Meaning |
|---|---|
| `SUCCESS: Spool <NUM> written to <PATH>.` | Spool downloaded. The script also echoes `INFO: File written: <path> (<bytes> bytes)` for verification. |
| `ERROR: Spool <NUM> not found in SP02 list (scanned <N> rows in col <C>).` | The auto-scan didn't find a row matching the spool number. Most common causes: the spool belongs to another user, it's older than the default selection window, the list shows a different layout (column index ≠ 4), or the number was mistyped. See **Troubleshooting** below. |
| `ERROR: Could not press Save (tbar[1]/btn[48])` | Some SAP GUI builds put Save under the system toolbar — try the same flow with `tbar[0]/btn[11]` after recording with the Scripting Recorder. |
| `ERROR: Save dialog completed but file is not on disk` | Path was rejected silently (permissions / locked file / wrong DY_PATH separator). Check the path and retry. |
| Other `ERROR: …` | Surface verbatim and consult Step 7. |

---

## Step 5 — Report

Tell the user:
- Spool number and the local path the file ended up at
- File size (echoed by the VBS as `INFO: File written: <path> (<bytes> bytes)`)
- Format used (Unconverted / Spreadsheet / RTF / HTML)
- The SAP status bar message after save (echoed as `INFO: SAP status: [<TYPE>] <TEXT>`)

If the operator wants to inspect the contents, the file is plain text
(for `--format=text`) and can be `Read`d directly.

---

## Step 6 — Clean Up

```bash
cmd /c del {WORK_TEMP}\sap_sp02_download_run.vbs & del {WORK_TEMP}\sap_sp02_download_run.ps1
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_sp02_run.json" -Status SUCCESS -ExitCode 0
```

On failure, substitute `<CLASS>` and a short message:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_sp02_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SP02_NOT_FOUND`, `SP02_DOWNLOAD_FAILED`, `GUI_TIMEOUT`.

---

## Step 7 — Troubleshooting

When the auto-scan fails, the right next move is almost always
`/sap-gui-diagnose full` followed by `/sap-gui-object-details` to
inspect the live SP02 list:

| Symptom | Diagnose with | Fix |
|---|---|---|
| `Spool <NUM> not found` but the operator sees it on screen | `/sap-gui-object-details` mode `type` filter `GuiLabel` — find the row index where the spool number appears, and the column index | Re-run with `--row=<N>` and/or `--col=<C>` |
| Spool belongs to a different user | Check SP02's selection screen | Either change `User` filter on the SP02 selection screen (Settings…) or run as the spool's owner |
| F2 (Display) opens an empty window | Spool is binary (PDF/postscript) — Unconverted format won't help | Use `--format=html` or `--format=csv` if the report supports those, or download via SP01 binary path |
| Save toolbar button doesn't exist | SAP GUI version differs | Record `tbar[1]/btn[48]` vs `tbar[0]/btn[11]` with /sap-gui-record and patch the VBS |
| File-save dialog doesn't appear | A "List has been completely displayed" popup may be on top | Add an Enter dismiss in the popup-handling block; this can also be handled by running `/sap-gui-diagnose full` between steps |

If any GUI step fails with "control could not be found by id", invoke
`/sap-gui-diagnose full` first — it captures the live screen as a PNG
plus the structural component dump for the topmost window.

---

## Component IDs (for reference)

| Element | ID |
|---|---|
| OK code | `wnd[0]/tbar[0]/okcd` |
| SP02 list checkbox (column 1, row N) | `wnd[0]/usr/chk[1,N]` |
| SP02 list spool number (column 4 by default, row N) | `wnd[0]/usr/lbl[4,N]` |
| F2 = Display contents | `sendVKey 2` on `wnd[0]` |
| Save (export) | `wnd[0]/tbar[1]/btn[48]` |
| Format-selection radio | `wnd[1]/usr/subSUBSCREEN_STEPLOOP:SAPLSPO5:0150/sub:SAPLSPO5:0150/radSPOPLI-SELFLAG[1,<idx>]` |
| Format-selection Continue | `wnd[1]/tbar[0]/btn[0]` |
| Save dialog directory | `wnd[1]/usr/ctxtDY_PATH` |
| Save dialog filename | `wnd[1]/usr/ctxtDY_FILENAME` |
| Save dialog confirm | `sendVKey 0` on `wnd[1]` |
| Status bar | `wnd[0]/sbar` |

The `0150` subscreen number on the format popup is from S/4HANA 1909.
On older / newer SAP GUI builds it can shift by one or two — re-record
if the radio path fails.

---

## Limitations

- **Own-user spools only.** SP02 by default lists only the logged-in
  user's spool requests. To download another user's spool, switch to
  SP01 first or change SP02's selection criteria; this skill does not
  drive the selection-screen flow.
- **List-style spools only.** Binary spools (PDF / OTF / PS) are not
  meaningfully convertible via the Unconverted radio. Use the
  appropriate format index, or download via SP01 binary path.
- **No CHK[col,row] race-protection.** The VBS does not re-verify the
  spool number after ticking the checkbox — if the SP02 list re-ordered
  between the scan and the tick (rare, but possible if the user has
  background spool generation running), the wrong spool may be selected.
  Hash the row's spool number before F2 if this matters in your context.
- **Format index mapping is SAP-GUI-version-specific.** The skill
  documents `text`/`csv`/`rtf`/`html` as 0/1/2/3, which holds on
  S/4HANA 1909. On other releases verify with a one-time recording.
