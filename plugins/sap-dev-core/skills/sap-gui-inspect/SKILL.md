---
name: sap-gui-inspect
description: |
  Inspects the currently active SAP GUI session — structurally and/or visually —
  so a stuck GUI script (unexpected popup, a control ID that moved between
  releases, a greyed-out field, a hung transition) can be understood. Two mode
  families: STRUCTURAL dumps component IDs + properties — `tree` (component tree
  of all/one window), `menu` (menu bar), `type` (every component of a type, e.g.
  GuiButton/GuiShell), `id` (full property dump of one findById path), `wnd` (one
  window); VISUAL `screenshot` HardCopies every window into one annotated PNG
  (sub-modes topmost | composite | full, where full also dumps the topmost
  window's tree). The orchestrator reads the PNG with the Read tool. Other skills
  call this mid-flow to discover the current screen state. Replaces the former
  /sap-gui-object-details and /sap-gui-diagnose.
  Prerequisites: active SAP GUI session (/sap-login first); RZ11
  sapgui/user_scripting = TRUE on the server.
argument-hint: "<mode> [filter] [wnd=<n>]   modes: tree | menu | type | id | wnd | screenshot [topmost|composite|full] [--with-details]"
---

# SAP GUI Inspect Skill

You inspect the currently active SAP GUI screen. Two families of modes:

- **Structural** (`tree` / `menu` / `type` / `id` / `wnd`) — dump the component
  tree, menu bar, all components of a chosen type, or the full property set of a
  single component identified by its `findById` path.
- **Visual** (`screenshot`) — capture every visible window as a screenshot,
  compose them into one annotated PNG, and hand it to the orchestrator (which
  reads the PNG with the Read tool). Use this when the structural dump alone
  isn't enough to see what's on screen.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SKILL_DIR>/references/sap_gui_object_details.vbs` | `%%MODE%%`, `%%FILTER%%`, `%%WINDOW%%`, `%%MAX_DEPTH%%`, `%%OUTPUT_FILE%%` | Structural inspection: component tree / menu / type dump / property dump |
| `<SKILL_DIR>/references/sap_gui_diagnose_capture.vbs` | `%%OUTPUT_DIR%%`, `%%MANIFEST%%` | Visual inspection: HardCopy each window's BMP + emit TSV manifest |
| `<SKILL_DIR>/references/sap_gui_diagnose_compose.ps1` | `%%MANIFEST%%`, `%%COMPOSITE_PNG%%`, `%%TOPMOST_PNG%%` | Visual inspection: stack BMPs in screen-space order → composite PNG + topmost PNG |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_sidecar.ps1` | *(launched)* | OS-level (Win32) auto-dismiss for the "SAP GUI Security" dialog. Launched in parallel with the `screenshot` capture: `HardCopy` writes BMPs through SAP GUI (SAP-GUI-side file IO) and would otherwise hang `cscript` on the modal when the output dir isn't trusted. |

---

## When to Invoke (auto-trigger contract)

Other skills SHOULD invoke `/sap-gui-inspect` as the **first resort** — before
falling back to manual scripting-recorder probes — when their VBS hits any of:

1. **Hard crash** — `findById` raises `The control could not be found by id`.
2. **Stuck progression** — the script has been waiting on a screen transition
   for noticeably longer than expected (>5s).
3. **Unexpected popup** — `oSession.ActiveWindow.Id` is `wnd[N]` for N >= 1 and
   the dispatcher doesn't recognise the popup's component markers.
4. **Failed post-condition** — sbar `MessageType = "E"` or a known verifier (e.g.
   SE11's RFC verifier) reports `MISSING` / `INACTIVE` when the GUI claimed success.

The dispatch is **visual first** (`/sap-gui-inspect screenshot full`) → **structural**
(`/sap-gui-inspect tree` or `wnd <N>`) → recorded fallback (`/sap-gui-record`).
`screenshot full` does both in one call (composite PNG + a structural dump of the
topmost window), so it is the recommended first move for a stuck flow.

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`.
| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` / `*_run.vbs` and the `_run.json` state) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

For the `screenshot` mode, also generate a per-run output directory using a sortable timestamp:

```
{DIAG_DIR} = {WORK_TEMP}\sap_inspect_<YYYYMMDD_HHMMSS>
```

Keep `{DIAG_DIR}` so you can reference the PNGs in the summary back to the user.

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{RUN_TEMP}\sap_gui_inspect_run.json`) so subsequent steps and the final
log-end call append to the same run. Best-effort: silently no-ops if
`userConfig.log_enabled=false` or the lib can't load.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_gui_inspect_run.json" -Skill sap-gui-inspect -ParamsJson "{\"mode\":\"<MODE>\"}"
```

---

## Step 1 — Parse Arguments & Dispatch

| Parameter | Required | Notes |
|---|---|---|
| Mode | yes | `tree` / `menu` / `type` / `id` / `wnd` (structural) **or** `screenshot` (visual) |
| Filter | depends | Required for `type` (e.g. `GuiButton`), `id` (full path), `wnd` (window index). For `screenshot`, an optional sub-mode `topmost` \| `composite` \| `full`. |
| Window scope | optional | `wnd=<n>` to restrict `tree`/`menu`/`type` to a single window; default = scan `wnd[0]` through `wnd[5]` |
| `--with-details` | optional | `screenshot` only — force the structural dump even in `topmost`/`composite` sub-modes |

Then dispatch:

- Mode `screenshot` → **Visual inspection** section below.
- Any of `tree` / `menu` / `type` / `id` / `wnd` → **Structural inspection** section below.

## Step 2 — Ensure SAP GUI Session

This skill requires an active SAP GUI session. Run `/sap-login` first if
necessary. The skill never re-creates the session — it only inspects what is on
screen right now. If `/sap-login` reports `STATUS: NO_SESSION`, abort with
`ERROR: No SAP GUI session — run /sap-login first`.

---

# Structural inspection (`tree` / `menu` / `type` / `id` / `wnd`)

### Mode summary

| Mode | What it does | Filter example |
|---|---|---|
| `tree` | Full component tree (Type / Id / short summary) of every visible window | — |
| `menu` | Menu bar (`mbar`) tree including titles and IDs | — |
| `type` | Walks the tree and emits **full property dump** for every component whose `Type` matches the filter | `GuiButton`, `GuiStatusbar`, `GuiShell`, `GuiTableControl`, `GuiMenu`, `GuiToolbar`, `GuiUserArea`, `GuiCheckBox`, `GuiRadioButton` |
| `id` | Full property dump of one component plus its immediate children | `wnd[0]/sbar`, `wnd[1]/usr/btnSPOP-OPTION1` |
| `wnd` | Full component tree of a single window (alias for `tree wnd=<n>`) | `1` for the first popup |

Synonyms accepted: `Statusbar` → `GuiStatusbar`, `Button` → `GuiButton`,
`Tablecontrol` → `GuiTableControl`, `Toolbar` → `GuiToolbar`, `Menu` → `GuiMenu`,
`Shell` → `GuiShell`. Always normalize to the official `Gui*` name before passing
to the VBS.

### S1 — Generate and Run the VBS

Template: `./references/sap_gui_object_details.vbs`. Tokens:

| Token | Replace with |
|---|---|
| `%%MODE%%` | `tree` / `menu` / `type` / `id` / `wnd` |
| `%%FILTER%%` | The filter value (empty for plain `tree` / `menu`) |
| `%%WINDOW%%` | Window index (`0`..`5`), or empty for all windows |
| `%%MAX_DEPTH%%` | Optional recursion cap; default `10` |
| `%%OUTPUT_FILE%%` | Absolute path of the output file (UTF-16 LE) |

Default output file: `{RUN_TEMP}\sap_gui_objects_<MODE>.txt`.

Write `{RUN_TEMP}\sap_gui_inspect_struct_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$workTemp = '{WORK_TEMP}'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_gui_object_details.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%MODE%%','THE_MODE')
$content  = $content.Replace('%%FILTER%%','THE_FILTER')
$content  = $content.Replace('%%WINDOW%%','THE_WINDOW')
$content  = $content.Replace('%%MAX_DEPTH%%','10')
$content  = $content.Replace('%%OUTPUT_FILE%%','THE_OUTPUT_FILE')
[System.IO.File]::WriteAllText("{RUN_TEMP}\sap_gui_inspect_struct_run.vbs", $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run via 32-bit cscript:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_gui_inspect_struct_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\sap_gui_inspect_struct_run.vbs
```

### S2 — Interpret the Output

| Last line of stdout | Meaning |
|---|---|
| `DONE` | Success. Result file is at `OUTPUT_FILE` (Unicode). |
| `ERROR: …` | Failure (no SAP GUI / no session / bad mode / bad filter). |

The output file always starts with a header block (date, mode, transaction,
program, screen, user/client/system) followed by mode-specific sections. Open it:

```bash
powershell -Command "Get-Content '{RUN_TEMP}\sap_gui_objects_<MODE>.txt' -Encoding Unicode"
```

Or read selected lines directly with the `read_file` tool.

### S3 — Report

Summarise: mode and filter used, output file path, key findings (number of
windows, popup titles, count of matched components for `type` mode, status-bar
message text, etc.).

When invoked by another skill that is "stuck", provide just the IDs the caller
needs (e.g. "popup `wnd[1]` is open with title 'Information'; click
`wnd[1]/tbar[0]/btn[0]` to dismiss") rather than the full file contents.

### Common Recipes (structural)

| Goal | Mode | Filter |
|---|---|---|
| What windows are open right now? | `tree` | — |
| What's the current status-bar message? | `id` | `wnd[0]/sbar` |
| List every clickable button on screen | `type` | `GuiButton` |
| Inspect the popup `wnd[1]` that appeared unexpectedly | `wnd` | `1` |
| Discover the menu path for a transaction | `menu` | — |
| Why is field X greyed out? | `id` | the field's full path (look at `Changeable`) |
| What columns does this ALV grid have? | `type` | `GuiShell` (then look for SubType=GridView) |
| What's inside this table control? | `id` | `wnd[0]/usr/tblSAPL...` |

---

# Visual inspection (`screenshot`)

Capture a visual snapshot of the live SAP GUI session — every open window — and
hand the resulting PNG to the orchestrator. Use it when the structural dump alone
isn't enough to figure out what's on screen.

### Sub-mode & cost gate

| Sub-mode | Meaning |
|---|---|
| `topmost` | Only the highest-numbered window's PNG (cheapest — one image to the vision call). |
| `composite` (default) | Composite PNG (all windows, screen-space order) + topmost PNG. |
| `full` | composite + topmost + the structural `wnd` dump for the topmost window. |

`--with-details` forces the structural dump even in `topmost`/`composite`.
Pick `topmost` for routine auto-invocations; `full` when actively fixing a stuck flow.

### V1 — Capture BMPs via VBS

Fill the capture template:

```powershell
$skillDir   = '<SKILL_DIR>'
$diagDir    = '{DIAG_DIR}'
$manifest   = "$diagDir\manifest.tsv"
$content    = [System.IO.File]::ReadAllText("$skillDir\references\sap_gui_diagnose_capture.vbs", [System.Text.Encoding]::UTF8)
$content    = $content.Replace('%%OUTPUT_DIR%%', $diagDir)
$content    = $content.Replace('%%MANIFEST%%',   $manifest)
# Session-attach plumbing (Phase 3.5 multi-connection aware). Resolution:
# explicit --session > SAPDEV_SESSION_PATH > sole-connection auto-default > refuse.
$sessionPath = ''  # set to the parsed --session value if supplied
$content    = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content    = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText("{RUN_TEMP}\sap_gui_inspect_capture_run.vbs", $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run via `cscript`, **with the SAP GUI Security watcher in parallel**. `HardCopy`
writes each window's BMP through SAP GUI — SAP-GUI-side file IO that **can raise**
the modal "SAP GUI Security" (write-permission) dialog (which suspends the
Scripting API and **hangs cscript**) when `$diagDir` isn't already write-trusted.
Because `/sap-gui-inspect screenshot` is a first-resort troubleshooting tool, it
must never hang on that dialog, so launch `sap_gui_security_sidecar.ps1` alongside
the capture (it clicks Allow + ticks Remember, persisting the rule so later runs
are clean):

```powershell
$shared  = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$watcher = Start-Process powershell -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput "{RUN_TEMP}\sap_gui_inspect_sidecar.out" `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
                    "$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','45')
Start-Sleep -Milliseconds 800
& 'C:\Windows\SysWOW64\cscript.exe' //NoLogo "{RUN_TEMP}\sap_gui_inspect_capture_run.vbs"
if (-not $watcher.HasExited) { Stop-Process -Id $watcher.Id -Force -ErrorAction SilentlyContinue }
```

| Last line | Meaning |
|---|---|
| `DONE: <N> window(s) captured.` | At least one BMP written; proceed. |
| `WARN: HardCopy failed on wnd[N]` | One window unavailable — others may still be captured; check `<N>` in DONE line. |
| `ERROR: …` | Total failure — most often SAP GUI is minimised or scripting is disabled. Surface to caller. |

### V2 — Compose into PNG via PowerShell

Fill the compose template:

```powershell
$skillDir       = '<SKILL_DIR>'
$diagDir        = '{DIAG_DIR}'
$manifest       = "$diagDir\manifest.tsv"
$compositePng   = "$diagDir\composite.png"
$topmostPng     = "$diagDir\topmost.png"
$content        = Get-Content "$skillDir\references\sap_gui_diagnose_compose.ps1" -Raw -Encoding UTF8
$content        = $content.Replace('%%MANIFEST%%',      $manifest)
$content        = $content.Replace('%%COMPOSITE_PNG%%', $compositePng)
$content        = $content.Replace('%%TOPMOST_PNG%%',   $topmostPng)
[System.IO.File]::WriteAllText("{RUN_TEMP}\sap_gui_inspect_compose_run.ps1", $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Run via Windows PowerShell (composition uses `System.Drawing`, available in both
32-bit and 64-bit):
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_gui_inspect_compose_run.ps1"
```

| Last line | Meaning |
|---|---|
| `DONE: composite=<path>  topmost=<path>` | Both PNGs written. |
| `ERROR: …` | Manifest unreadable / no usable BMPs. Surface to caller. |

### V3 — (Optional) Structural Dump

When the sub-mode is `full` or `--with-details` was passed, also run the
**structural `wnd` mode** (above) for the topmost window so the orchestrator gets
both views of the same state — i.e. run `sap_gui_object_details.vbs` with
`%%MODE%%=wnd` and `%%WINDOW%%=<N>` (the highest-numbered captured window from the
manifest), redirecting the dump into `{DIAG_DIR}\object_details.txt` so it lives
next to the PNGs.

### V4 — Hand Back to the Orchestrator

This is the contract for the calling agent: read the PNG and reason. Emit a
single summary line that the orchestrator parses:

```
INSPECT_OK
  composite : {DIAG_DIR}\composite.png
  topmost   : {DIAG_DIR}\topmost.png
  details   : {DIAG_DIR}\object_details.txt   (only when sub-mode=full)
  manifest  : {DIAG_DIR}\manifest.tsv
```

The orchestrator THEN uses the **Read tool** on the PNG to actually look at the
screen content (Read renders images for vision-capable models), and uses Read on
`object_details.txt` for the component tree. Do **not** print the PNG bytes to
stdout or base64-encode them — the Read-tool handoff is the cheapest path to
vision tokens.

### V5 — Clean Up

Per-run directories accumulate fast in `{WORK_TEMP}`. Recommend a sweep (older
than 7 days, removed; don't sweep the current run's `{DIAG_DIR}`):

```bash
cmd /c forfiles /P "{WORK_TEMP}" /D -7 /M sap_inspect_* /C "cmd /c if @isdir==TRUE rmdir /s /q @path"
```

Delete the per-invocation generated scripts:
```bash
cmd /c del {RUN_TEMP}\sap_gui_inspect_capture_run.vbs & del {RUN_TEMP}\sap_gui_inspect_compose_run.ps1 & del {RUN_TEMP}\sap_gui_inspect_sidecar.out
```

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_gui_inspect_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_gui_inspect_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `INSPECT_FAILED`, `GUI_TIMEOUT`, `INSPECT_NO_SESSION`,
`INSPECT_HARDCOPY_FAILED`, `INSPECT_COMPOSE_FAILED`.

---

## How callers should integrate this

Skills that drive SAP GUI should carry this first-resort troubleshooting block:

> **FIRST RESORT — invoke `/sap-gui-inspect screenshot full`.** It captures every
> visible window as a screenshot, composes them into one annotated PNG, and also
> dumps the topmost window's component tree. Read the PNG with the Read tool, then
> decide:
>
> - Unexpected popup → identify the dismiss button from the visual + the component
>   dump and dismiss.
> - Component ID changed between releases → the dump shows the new ID; patch the VBS.
> - Field is `Changeable=False` → take a different SAP path.
>
> If `/sap-gui-inspect screenshot` itself fails (`SAP GUI minimised`, HardCopy
> blocked), fall back to `/sap-gui-inspect tree` (structural only), then to
> `/sap-gui-record` (Scripting Recorder).

Skills that should carry this block: sap-se11, sap-se24, sap-se37, sap-se38,
sap-se91, sap-transport-request, sap-cmod, sap-se19, sap-se21, sap-se41, sap-se51,
sap-se54, sap-snro, plus any future GUI-driving skill. The block is ~8 lines so
it's cheap to repeat.

---

## Component IDs (for reference)

| Element | ID |
|---|---|
| Main window | `wnd[0]` |
| Menu bar | `wnd[0]/mbar` |
| Application toolbar | `wnd[0]/tbar[1]` |
| System toolbar | `wnd[0]/tbar[0]` |
| Title bar | `wnd[0]/titl` |
| Status bar | `wnd[0]/sbar` |
| User area | `wnd[0]/usr` |
| Modal popup | `wnd[1]`, `wnd[2]`, … (up to 5) |

---

## Limitations & caveats

- **Structural.** The VBS uses a fixed property whitelist; custom controls with
  unique properties (e.g. `GuiCalendar.SelectedDate`) aren't dumped — extend the
  `Eval2` switch in the VBS. `MAX_DEPTH` defaults to 10; deeply nested split
  containers may need higher. Read-only — the skill never clicks anything. For
  full ALV grid **row** contents use `/sap-se16n`; this skill prints column
  headers only.
- **Visual.** `HardCopy` is documented by SAP as **not for productive use** — we
  treat it as best-effort and accept partial captures. It **fails on minimised
  windows** (the capture VBS records a WARN and continues). Tooltips, dropdown
  lists, balloon dialogs, and right-click context menus are NOT in the bitmap — if
  the diagnosis hinges on one, fall through to `/sap-gui-record`. Screen
  coordinates are pixels on modern SAP GUI builds; on older (dialog-unit) builds
  the composite layout may look stacked, but the topmost PNG is unaffected.
- **Cost.** A composite PNG of a 1920x1080 session is ~200–400 KB (~O(1k) vision
  tokens when read). `topmost` is cheaper — the right default when auto-invoked.
  Reserve `full` for hands-on debugging.
