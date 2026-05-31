# SAP GUI Security dialog handling (mandatory for any skill that does SAP-GUI local file IO)

## The problem

SAP GUI raises a modal **"SAP GUI Security"** dialog whenever **SAP GUI itself**
performs a local-file operation (download, upload, export-to-file, `Hardcopy`,
activation-log "Save Local File", spool export, …) on a path that is **not
covered by an Allow rule**, when the Security Module's *Default Action* is
`Ask` (the common default).

While that dialog is modal, **the SAP GUI Scripting COM API is fully
suspended** — even `oSess.findById("wnd[0]")` returns nothing. So:

- A cscript-driven skill that triggered the file IO **blocks** (its `findById`
  call hangs) and cannot dismiss the dialog itself.
- Any *other* cscript status check (login status, screen dump) **also goes
  blind** — which is why the stuck state is invisible to VBS/COM tooling.

Detection and dismissal therefore **must** happen at the OS level (Windows UI
Automation), in a **separate background process** that is not blocked by the
modal.

## What triggers it (audit your skill for these)

Any SAP-GUI-initiated local file IO: SE16N / ALV **export to file**, source
**download** (SE38/SE37/SE24 "check & download", `RPY_*` to file),
source/data **upload** from a local file, `GuiFrameWindow.Hardcopy`
(screenshots), SE11 **activation-log → Save Local File**, SP01/SP02 spool
download. Driving the GUI by control IDs (the normal probe/deploy path) does
**not** trigger it — only SAP-GUI-side file IO does.

**Prefer to avoid the trigger** where a non-file path exists: verify objects
via **RFC** (`sap_rfc_lib.ps1`) or the **Display** screen instead of SE16N
export; read tables via `RFC_READ_TABLE` instead of SE16N download; enter ABAP
source via the **editor control** instead of file Upload. If you can avoid
SAP-GUI file IO entirely, you need neither helper below.

## The guard (when file IO is unavoidable)

Two shared helpers in `shared/scripts/`:

| Helper | Role |
|---|---|
| `sap_gui_security_precheck.ps1` | **Pre-check** (read-only): is the target `Path` + `Access` (r/w/x) + context (`System`/`Client`/`Transaction`) already covered by an Allow rule in `%APPDATA%\SAP\Common\saprules.xml`? `ALLOWED` (exit 0) / `NOT_COVERED` (exit 1). |
| `sap_gui_security_sidecar.ps1` | **Watcher** (OS-level **Win32**): the dialog is a standard `#32770` window titled "SAP GUI Security", **owned** by saplogon — invisible to `FindWindow`-exact (owned) and to UIA descendant scans (SAP GUI doesn't expose it to UIA). The watcher finds it via `EnumWindows` (caption match, or the locale-proof structural test "has both an Allow and a Deny child button"), then ticks **Remember My Decision** (`BM_SETCHECK`) + clicks **Allow** (`BM_CLICK`) via `EnumChildWindows` — no focus/foreground dependency. Run as a background process *before* the file-IO action. Ticking Remember persists an Allow rule into `saprules.xml` **live** (no GUI restart). `DISMISSED:WIN32` / `TIMEOUT` / `NO_SAP_GUI`. |
| `sap_gui_security_grant.ps1` | **Broad grant** (writes `saprules.xml` directly): idempotently merges one well-formed `<directories>` Allow rule with **combined permissions** (e.g. `rw`) and **empty context fields** (= "any" transaction/program), in SAP's native serialization. The *only* way to pre-cover reads/writes from **arbitrary future programs** — see "Reads from arbitrary programs" below. `GRANTED: id=<n> …` / `ALREADY: …` (exit 0) / `ERROR:` (exit 2). Caller backs up `saprules.xml` first. This is a deliberate weakening of the prompt for the granted path. For the operator's own `{work_dir}` sandbox, granting **any-system** (empty `-System`/`-Client`) is the intended scope; pin `-System`/`-Client` only when a least-privilege policy requires it. Any-system grants are a Security-Weaken action the Claude auto-mode classifier guards — they need explicit operator authorization on first write. |

### Canonical pattern (PowerShell, inside the skill wrapper)

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$target = 'C:\sap_dev_work\temp\export.txt'   # the path SAP GUI will write/read

# 1. Pre-check the allow-list (informational + lets us skip the watcher).
$pc = & "$shared\sap_gui_security_precheck.ps1" -Path $target -Access w `
        -System 'S4D' -Client '100' -Transaction 'SE16N'
$allowed = ($LASTEXITCODE -eq 0)

# 2. If NOT already allowed, launch the watcher in the BACKGROUND *before*
#    the (blocking) cscript action that triggers the file IO. The watcher
#    runs in its own process, so the modal does not block it.
$watcher = $null
if (-not $allowed) {
    $watcher = Start-Process -FilePath 'powershell' -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass',
                        '-File',"$shared\sap_gui_security_sidecar.ps1",
                        '-TimeoutSeconds','30',
                        '-LogPath',"$env:TEMP\sap_secdlg.log")
}

# 3. Now drive the SAP GUI action that does the file IO (cscript ...). If a
#    dialog appears it blocks here until the watcher dismisses it; ticking
#    Remember persists a rule, so the NEXT precheck for this path returns
#    ALLOWED and the watcher is skipped.
& 'C:/Windows/SysWOW64/cscript.exe' //NoLogo "$runtimeVbs"

# 4. Reap the watcher.
if ($watcher) { $watcher | Wait-Process -Timeout 35 -ErrorAction SilentlyContinue }
```

### Reads from arbitrary programs — why the watcher isn't enough

SAP keys every "Remember My Decision" rule on the **current dynpro**. For a
report executed via SE38/SA38 that calls `GUI_UPLOAD`/`GUI_DOWNLOAD`, the dynpro
is the **program's own screen** — `dynpro_name = <PROGRAM NAME>`, `dynpro_num =
1000` (confirmed in live `saprules.xml`: separate `r` rules for `ZMMRMAT039R01`,
`ZMMRMAT040R01`, `ZMMRMAT050R01`, …). So:

- A narrow Remember rule (whether the user clicks Allow or the **watcher** does)
  only ever covers the **one program that already ran**. The *next* generated
  program is a new context and trips a fresh dialog.
- The Hardcopy **warmup** only exercises a *write*, so it never establishes an
  `r` rule at all.

When the trigger is your *own* skill driving SAP-GUI file IO under a **stable**
dynpro (ALV export under `SAPLKKBL`, source upload under `SAPLSFES`), the
precheck + watcher pattern above is correct — one Remember covers that stable
context for good. But when the trigger is an **end-user ABAP program** doing
`GUI_UPLOAD`/`GUI_DOWNLOAD` (e.g. running generated material-upload reports),
the per-program dynpro makes narrow rules unusable. The only fix that scales is
a **broad rule** via `sap_gui_security_grant.ps1` — combined `rw` permissions,
`<directories>` prefix match on `{work_dir}`, and empty context (= "any") for
`transaction`/`dynpro_name`/`dynpro_num` (mandatory — program name varies) and,
for the operator's own work dir, `system`/`client` too. `/sap-dev-init` Step 1b
writes this once per workstation. Pin `system`/`client` only when a
least-privilege policy requires it.

> A malformed hand-edit is worse than none: an early attempt used backslash
> paths (`C:\…` — SAP stores `C:/…`), literal `*` wildcards (SAP treats *empty*
> as "any", not `*`), and omitted `<permissions>`. SAP silently ignored it and
> kept prompting. Always go through `sap_gui_security_grant.ps1`, which emits the
> exact native structure and re-parses the file after writing.

### Rules of thumb

- **Always** launch the watcher when `precheck` returns `NOT_COVERED`. The
  watcher is the actual safety net — `precheck` is best-effort (the action-code
  semantics in `saprules.xml` are inferred), so never *skip* the watcher on a
  guess that a dialog won't appear unless `precheck` said `ALLOWED`.
- Launch the watcher **before** starting the blocking cscript action, not
  after — once the modal is up, the cscript call is already hung.
- The first run for a given path/context will show the dialog (watcher
  dismisses it + Remember persists the rule); subsequent runs precheck as
  `ALLOWED` and run dialog-free.
- `saprules.xml` rules are **context-specific** (system + client + transaction
  + dynpro). "Remember My Decision" creates a narrow rule for exactly that
  context; do not assume one Allow covers a different transaction.
- These helpers need the **interactive desktop** (UIA). They run from the
  skill's normal PowerShell context, which shares the session that drives SAP
  GUI. They are not VBS — never try to dismiss this dialog from cscript.

## Skills that must observe this rule

Wired with the guard (2026-05-22): `sap-se16n` (export), `sap-se38` / `sap-se37`
/ `sap-se24` (check-and-fix source download), `sap-se11` (activation-log "Save
Local File" on create/update), `sap-sp02` (spool download). `/sap-dev-init`
Step 1b already uses the watcher as a warmup.

`sap-gui-diagnose` uses `GuiFrameWindow.Hardcopy`, which was **observed NOT to
prompt** on SAP GUI 7.70 / S/4HANA 1909 (Hardcopy is governed by SAP/Admin
built-in rules, not the user file rules) — so it is intentionally left unwired.
Wire it only if Hardcopy prompts on your release.
