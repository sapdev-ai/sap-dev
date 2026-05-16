---
name: sap-gui-diagnose
description: |
  Visual triage for SAP GUI scripts that hit unexpected screens (script
  hung, "control could not be found by id", or an unrecognised popup).
  Captures a BMP screenshot of every visible window in the active SAP
  GUI session via the Scripting API's HardCopy method, composes them
  into a single annotated PNG that mimics the operator's screen, and
  optionally chains to /sap-gui-object-details so the orchestrator gets
  both a visual and a structural view of the same state.
  The orchestrator (Claude) reads the resulting PNG with the Read tool
  and reasons about the next action.
  Pairs with /sap-gui-object-details: this skill is the visual view,
  that one is the structural view.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "[topmost|composite|full] [--with-details]"
---

# SAP GUI Diagnose Skill

You capture a visual snapshot of the live SAP GUI session — every open
window — and hand the resulting PNG to the orchestrator. Use it when
another skill is stuck and the structural component dump from
/sap-gui-object-details alone isn't enough to figure out what's on screen.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SKILL_DIR>/references/sap_gui_diagnose_capture.vbs` | `%%OUTPUT_DIR%%`, `%%MANIFEST%%` | HardCopy each window's BMP + emit TSV manifest |
| `<SKILL_DIR>/references/sap_gui_diagnose_compose.ps1` | `%%MANIFEST%%`, `%%COMPOSITE_PNG%%`, `%%TOPMOST_PNG%%` | Stack BMPs in screen-space order to produce composite PNG + topmost PNG |

---

## When to Invoke (auto-trigger contract)

Other skills SHOULD invoke `/sap-gui-diagnose` as the **first resort** —
before falling back to manual scripting-recorder probes — when their VBS
hits any of:

1. **Hard crash** — `findById` raises `The control could not be found by id`.
2. **Stuck progression** — the script has been waiting on a screen
   transition for noticeably longer than expected (>5s).
3. **Unexpected popup** — `oSession.ActiveWindow.Id` is `wnd[N]` for
   N >= 1 and the dispatcher doesn't recognise the popup's component
   markers.
4. **Failed post-condition** — sbar `MessageType = "E"` or a known
   verifier (e.g. SE11's RFC verifier) reports `MISSING` / `INACTIVE`
   when the GUI claimed success.

Skills that already document this flow:

- sap-se11 — "Troubleshooting Component IDs / Stuck Screen"
- sap-se37 — "Troubleshooting Component IDs / Stuck Screen"
- sap-se38, sap-se24, sap-se91 — same block (extend)
- sap-transport-request — same block (extend)

The dispatch is: visual first (`/sap-gui-diagnose`) → structural
(`/sap-gui-object-details`) → recorded fallback.

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

Generate a per-run output directory using a sortable timestamp:

```
{DIAG_DIR} = {WORK_TEMP}\sap_diagnose_<YYYYMMDD_HHMMSS>
```

The orchestrator must keep `{DIAG_DIR}` so it can reference the PNGs in
its summary back to the user.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_gui_diagnose_run.json" -Skill sap-gui-diagnose -ParamsJson "{\"mode\":\"<MODE>\"}"
```

Best-effort: silently no-ops if `userConfig.log_enabled=false`.

---

## Step 1 — Parse Arguments

| Arg | Default | Meaning |
|---|---|---|
| `MODE` | `composite` | `topmost` = only the highest-numbered window's PNG. `composite` = composite PNG + topmost PNG. `full` = composite + topmost + chain to /sap-gui-object-details for the topmost window. |
| `--with-details` | off | Force the structural dump even in `topmost`/`composite` modes. |

Cost gate: `topmost` is the cheapest (one image to the vision call);
`composite` is one image but bigger; `full` adds an extra structural
dump which is almost free in tokens. Pick `topmost` for routine
auto-invocations and `full` when you actively need to fix a stuck flow.

---

## Step 2 — Ensure SAP GUI Session

This skill never re-creates the session — it only inspects what is on
screen right now. If `/sap-login` reports `STATUS: NO_SESSION`, abort
with `ERROR: No SAP GUI session — run /sap-login first`.

---

## Step 3 — Capture BMPs via VBS

Fill the capture template:

```powershell
$skillDir   = '<SKILL_DIR>'
$diagDir    = '{DIAG_DIR}'
$manifest   = "$diagDir\manifest.tsv"
$content    = Get-Content "$skillDir\references\sap_gui_diagnose_capture.vbs" -Raw
$content    = $content.Replace('%%OUTPUT_DIR%%', $diagDir)
$content    = $content.Replace('%%MANIFEST%%',   $manifest)
# Session-attach plumbing (Phase 3.5 multi-connection aware). Resolution:
# explicit --session > SAPDEV_SESSION_PATH > sole-
# connection auto-default > refuse. See sap_attach_lib.vbs for details.
$sessionPath = ''  # set to the parsed --session value if supplied
$content    = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content    = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content "{WORK_TEMP}\sap_gui_diagnose_capture_run.vbs" $content -Encoding Unicode
Write-Host 'Done'
```

Run via `cscript`:

```bash
cscript //NoLogo {WORK_TEMP}\sap_gui_diagnose_capture_run.vbs
```

| Last line | Meaning |
|---|---|
| `DONE: <N> window(s) captured.` | At least one BMP written; proceed. |
| `WARN: HardCopy failed on wnd[N]` | One window unavailable — others may still be captured; check `<N>` in DONE line. |
| `ERROR: …` | Total failure — most often SAP GUI is minimised or scripting is disabled. Surface to caller. |

---

## Step 4 — Compose into PNG via PowerShell

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
[System.IO.File]::WriteAllText("{WORK_TEMP}\sap_gui_diagnose_compose_run.ps1", $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Run via Windows PowerShell (composition uses `System.Drawing` which is
available in both 32-bit and 64-bit, no preference needed):

```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_gui_diagnose_compose_run.ps1"
```

| Last line | Meaning |
|---|---|
| `DONE: composite=<path>  topmost=<path>` | Both PNGs written. |
| `ERROR: …` | Manifest unreadable / no usable BMPs. Surface to caller. |

---

## Step 5 — (Optional) Structural Dump

When `MODE=full` or `--with-details` was passed, also call
`/sap-gui-object-details` for the topmost window so the orchestrator gets
both views of the same state:

```
/sap-gui-object-details wnd <N>
```

…where `<N>` is the highest-numbered captured window from the manifest.
Have the dump output redirected into `{DIAG_DIR}\object_details.txt` so
the file lives next to the PNGs.

---

## Step 6 — Hand Back to the Orchestrator

This is the contract for the calling agent: read the PNG and reason.

Emit a single summary line that the orchestrator parses:

```
DIAGNOSE_OK
  composite : {DIAG_DIR}\composite.png
  topmost   : {DIAG_DIR}\topmost.png
  details   : {DIAG_DIR}\object_details.txt   (only when MODE=full)
  manifest  : {DIAG_DIR}\manifest.tsv
```

The orchestrator THEN uses the **Read tool** on the PNG to actually look
at the screen content (Read renders images for vision-capable models),
and uses Read on `object_details.txt` for the component tree.

Do **not** print the PNG bytes to stdout. Do not base64-encode them.
The Read-tool handoff is the cheapest path to vision tokens.

---

## Step 7 — Clean Up

Per-run directories accumulate fast in `{WORK_TEMP}`. Recommend a sweep:

```bash
cmd /c forfiles /P "{WORK_TEMP}" /D -7 /M sap_diagnose_* /C "cmd /c if @isdir==TRUE rmdir /s /q @path"
```

(Older than 7 days, removed.) Don't sweep the current run's `{DIAG_DIR}` —
the orchestrator may still want to attach the PNGs to its final summary.

Delete the per-invocation generated scripts:

```bash
cmd /c del {WORK_TEMP}\sap_gui_diagnose_capture_run.vbs & del {WORK_TEMP}\sap_gui_diagnose_compose_run.ps1
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_gui_diagnose_run.json" -Status SUCCESS -ExitCode 0
```

Suggested failure `ErrorClass`: `DIAGNOSE_NO_SESSION`,
`DIAGNOSE_HARDCOPY_FAILED`, `DIAGNOSE_COMPOSE_FAILED`.

---

## How callers should integrate this

Replace any "FIRST RESORT — invoke /sap-gui-object-details" block in
existing skills with:

> **FIRST RESORT — invoke `/sap-gui-diagnose full`.** It captures every
> visible window as a screenshot, composes them into one annotated PNG,
> and chains to /sap-gui-object-details for the topmost window. Read the
> PNG with the Read tool, then decide:
>
> - Unexpected popup → identify the dismiss button from the visual + the
>   component dump and dismiss.
> - Component ID changed between releases → the dump shows the new ID;
>   patch the VBS template.
> - Field is `Changeable=False` → take a different SAP path.
>
> If `/sap-gui-diagnose` itself fails (`SAP GUI minimised`, HardCopy
> blocked), fall back to `/sap-gui-object-details` alone, then to
> Scripting Recorder.

Skills that should carry this block: sap-se11, sap-se24, sap-se37,
sap-se38, sap-se91, sap-transport-request, sap-cmod, sap-se19,
sap-se21, sap-se41, sap-se51, sap-se54, sap-snro, plus any future
GUI-driving skill. The block is roughly 8 lines so it's cheap to repeat.

---

## Caveats per SAP GUI Scripting docs

- `HardCopy` is documented by SAP as **not for productive use**. We treat
  it as a best-effort diagnostic and accept partial captures.
- `HardCopy` **fails on minimised windows**. The capture VBS records a
  WARN line and continues so a single bad window doesn't abort the run.
- Tooltips, dropdown lists, balloon dialogs, and right-click context
  menus are NOT included in the bitmap. If the operator's diagnosis
  hinges on one of those, fall through to Scripting Recorder.
- Screen coordinates returned by `ScreenLeft / ScreenTop / Width /
  Height` are in pixels in modern SAP GUI builds; the composer treats
  them as such. On older builds (dialog units) the composite layout
  may look stacked rather than spatially correct — the topmost PNG is
  unaffected.

---

## Cost note

A composite PNG of a 1920x1080 SAP GUI session is typically ~200-400 KB
and consumes O(1k) vision tokens when read. The topmost-only mode is
cheaper (~one popup) and is the right default when this skill is
auto-invoked. Reserve `full` for hands-on debugging.
