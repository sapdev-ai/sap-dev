---
name: sap-run-report
description: |
  Executes an ABAP report/program on a live SAP system and captures the output —
  foreground (SA38 F8, interactive list) or background (scheduled job), with or
  without a variant, or ad-hoc selection values. Also maintains variants —
  create/overwrite (set) and delete via the SAPLSVAR GUI dialogs, list/show via RFC. Mode-aware:
  prefers the RFC fast-path where present and falls through to GUI (SA38 F8 /
  Execute-in-Background) when RFC is unavailable, honouring userConfig.sap_dev_mode.
  Executing a report can change data (UPDATE / COMMITting BAPI / job submit / IDoc /
  mail) — the skill ALWAYS confirms before it runs, per skill_operating_rules Rule 5.
  Prerequisites: active SAP GUI session (use /sap-login first). The RFC background
  path (Phase B) additionally needs SAP NCo 3.1 (32-bit) + Z_RUN_REPORT (deploy via
  /sap-dev-init); variant list/show/delete route through /sap-rfc-wrapper.
argument-hint: "<PROGRAM> [--variant=V] [--foreground|--background] [--values=\"P_A=1;S_B=BT:10,20\"] [--save-output=PATH]   |   variant <list|show|set|delete> <PROGRAM> [VARIANT] [--values=\"...\"] [--desc=\"...\"]"
---

# SAP Run Report Skill

You execute an ABAP report/program on a live SAP system, or maintain its variants.
Running a report is a **distinct risk class from deploying** it — a report may
mutate data — so this skill ALWAYS confirms before it runs (Step 2.5) and never
runs as an unconfirmed side effect of another skill.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules — **Rule 5 (report execution requires confirmation)** governs this skill |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status via `MessageType` (S/W/E/I/A), VKey over menu-text, no `.Text`/`.Tooltip` branching |
| `<SKILL_DIR>/references/sap_sa38_run.vbs` | SA38 driver: fill program → F8 → (load variant) → execute (FG) or schedule background (BG); emits `RUN_REPORT:` lines |
| `<SKILL_DIR>/references/sap_sa38_variant.vbs` | Variant maintenance driver (SET create/overwrite, DELETE) via the SAPLSVAR dialogs; emits `VARIANT:` lines |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/sap_gui_security_handling.md` | The foreground **list save** (Step 4) is SAP-GUI-side file IO → can raise the modal "SAP GUI Security" dialog. Pre-check + OS-level watcher wrap that save. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_precheck.ps1` | Read-only allow-list pre-check (`saprules.xml`) before the list save |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_sidecar.ps1` | OS-level watcher that auto-dismisses the SAP GUI Security dialog |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | `New-SapScopeKey` / `Register-SapArtifact` — register the run output for `/sap-evidence-pack` (Kind `run_output`). Best-effort; never changes the verdict. |

**Delegated skills** (invoke via the Skill tool — do not re-implement):
`/sap-login` (session), `/sap-rfc-wrapper fm RS_VARIANT_*` (variant list/show/delete),
`/sap-sp02` (spool → file, background capture), `/sap-st22` (dump detail on an aborted run).

---

## Step 0 — Resolve Work Directory

Resolve `work_dir` via the env-aware helper (NOT a direct `settings.json` read):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

`{WORK_TEMP} = work_dir\temp`. Settings reads follow `shared/rules/settings_lookup.md`.

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the `RUN_TEMP=` value printed above (a fresh per-run scratch dir).
Write the skill's generated scratch there; keep `{WORK_TEMP}` (base) only for
`Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_run_report_run.json" -Skill sap-run-report -ParamsJson "{\"program\":\"<PROGRAM>\",\"mode\":\"<run|variant>\",\"engine\":\"<fg|bg>\"}"
```

State file: `{RUN_TEMP}\sap_run_report_run.json`. Best-effort (Rule 4: never skip the call).

---

## Step 1 — Parse Arguments + Resolve Mode + Resolve Backend

**Mode** — the first token selects it:

| Invocation | Mode |
|---|---|
| `<PROGRAM> …` | **run** (default; no keyword) |
| `variant <list\|show\|set\|delete> <PROGRAM> [VARIANT]` | **variant** maintenance (`set` takes `--values`/`--desc`) |

**`run` switches:**

| Arg | Required | Default | Notes |
|---|---|---|---|
| `PROGRAM` | yes | — | UPPERCASE. The executable report name. |
| `--foreground` / `--background` | no | **`--foreground`** (Phase A) | Foreground = SA38 F8, synchronous, list captured. Background = scheduled job (monitor via SM37 / `/sap-job`). The clean background+spool capture is the RFC Phase-B path (`Z_RUN_REPORT`). |
| `--variant=V` | no | — | Named selection-set. Orthogonal to the engine (see design doc). |
| `--values="P_A=1;S_B=BT:10,20"` | no | — | Ad-hoc selection values, filled on the live selection screen (foreground). Alternative input source to `--variant`. |
| `--save-output=PATH` | no | `{RUN_TEMP}\run_<PROGRAM>.txt` | Foreground classic-list capture target. |
| `--session=…` | no | — | Explicit `/app/con[N]/ses[M]` for multi-connection contexts. |

**Backend resolution** — read `userConfig.sap_dev_mode`:
- `GUI` → GUI branch only (never attempt RFC).
- `RFC` / unset → prefer RFC where a path exists; on any `RFC_ERROR` / missing wrapper,
  **degrade to GUI, never block** (same contract as `sap-se38` Step 4.6/4.7).

Phase A implements the **GUI** paths for `run`; `variant list/show/delete` route through
`/sap-rfc-wrapper` (RFC). Log the resolved `mode` / `engine` / `backend`.

---

## Step 2 — Ensure Session

The `run` GUI paths need an active SAP GUI session — run `/sap-login` first if none.
The `variant` sub-command (RFC) needs the pinned profile + NCo; if RFC is unavailable,
see Step 3V (degrade).

---

## Step 2.5 — CONFIRM-TO-RUN Gate (MANDATORY)

**Applies to every `run` and to `variant delete`.** Skip only for `variant list/show`
(read-only). Per `skill_operating_rules.md` **Rule 5**, the skill cannot know whether a
report only reads or also mutates data — a report is **not** assumed read-only.

Show the user, then require an explicit `yes`:

> "I will **EXECUTE** report `<PROGRAM>` (`<foreground|background>`, variant
> `<V|—>`, values `<…|—>`) on `<SID>/<CLIENT>`. This may change data. Proceed?
> (yes / no / foreground / show selection)"

- Proceed only on explicit `yes`. On `no` / no answer → stop (log `SKIPPED`).
- On `foreground` → switch engine and re-confirm. On `show selection` → run foreground
  to the selection screen only, show the fields, and re-ask.
- Record the confirmation: `sap_log_helper.ps1 -Action step -Step confirm -Message "user approved <engine>"`.

**Never** auto-run. This gate is the reason report execution is its own skill.

---

## Step 3 — Execute (dispatch)

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_sa38_run_run.ps1` (read UTF-8 -> substitute tokens -> write UTF-16 LE
BOM; never `Get-Content -Raw` + `Set-Content -Encoding Unicode`):

```powershell
$skillDir = '<SKILL_DIR>'
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_sa38_run.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%PROGRAM%%',   'THE_PROGRAM')     # UPPERCASE
$content  = $content.Replace('%%VARIANT%%',   'THE_VARIANT')     # '' if none
$content  = $content.Replace('%%VALUES%%',    'THE_VALUES')      # '' if none
$content  = $content.Replace('%%MODE%%',      'THE_MODE')        # FG | BG
$content  = $content.Replace('%%SAVE_PATH%%', 'THE_SAVE_PATH')   # '' to skip capture
# Tier-3 session-attach plumbing.
$sessionPath = ''   # set to the parsed --session value if supplied
$content  = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%', "$shared\scripts\sap_attach_lib.vbs")
. "$shared\scripts\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_sa38_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run the generator:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_sa38_run_run.ps1"
```

### Execute

**No capture (background, or foreground without `--save-output`)** — run the VBS via the
**32-bit** cscript host (SAP GUI COM needs 32-bit):
```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo {RUN_TEMP}\sap_sa38_run.vbs
```

**Foreground with `--save-output`** — the `%PC` list download is SAP-GUI-side file IO, so
wrap the same cscript with the SAP GUI Security guard exactly as `/sap-sp02` Step 3 does.
Substitute `THE_SAVE_PATH` (= `--save-output`) and `THE_SID` / `THE_CLIENT` (pinned):
```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$out    = 'THE_SAVE_PATH'
& "$shared\sap_gui_security_precheck.ps1" -Path $out -Access w -System 'THE_SID' -Client 'THE_CLIENT' -Transaction 'SA38' | Out-Host
$watcher = $null
if ($LASTEXITCODE -ne 0) {
    $watcher = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','40')
    Start-Sleep -Milliseconds 800
}
& 'C:\Windows\SysWOW64\cscript.exe' //NoLogo '{RUN_TEMP}\sap_sa38_run.vbs'
if ($watcher) { $watcher | Wait-Process -Timeout 45 -ErrorAction SilentlyContinue }
```

### 3A — Foreground (`--foreground`, or `sap_dev_mode=GUI`)
`%%MODE%%=FG`. The VBS fills `RS38M-PROGRAMM`, F8 to the selection screen, loads
`--variant` (Get Variant) or notes `--values`, then F8 to execute. Foreground list capture
(Step 4) uses the guarded run above.

### 3B — Background GUI fallback (`--background` without RFC)
`%%MODE%%=BG`. The VBS reaches the selection screen, loads the variant, then triggers
**Program · Execute in Background**, accepts the print-params + start-immediate popups,
and reads the scheduled job name from the status bar (`MessageType=S`). Monitoring is
delegated to SM37 / `/sap-job` (Phase A does not poll GUI-only).

> **Phase B (RFC):** when `Z_RUN_REPORT` is deployed and RFC is available, background
> runs go headless through it (`sap_run_report_rfc.ps1`) → `TBTCO` poll → `TBTCP` spool
> → `/sap-sp02` capture → `/sap-st22` on abort. Until then, background = 3B.

### 3V — Variant sub-command
For **set** / **delete**, generate `./references/sap_sa38_variant.vbs` (tokens
`%%MODE%%(SET|DELETE) %%PROGRAM%% %%VARIANT%% %%VDESC%% %%VALUES%% %%BG_ONLY%%
%%SESSION_PATH%% %%ATTACH_LIB_VBS%%`) with the same generator + 32-bit cscript pattern as
Step 3. Verified live on S/4HANA 1909 (S4D), 2026-07-09 (SAPLSVAR kernel dialogs).

- **set** (create/overwrite — write, **confirm via Step 2.5**): `%%MODE%%=SET`. Fills
  `--values` on the report's selection screen (best-effort field + type derivation:
  `ctxt<F>` / `txt<F>` / `ctxt<F>-LOW[/-HIGH]` get `.Text`, `chk<F>` gets `.Selected` from a
  boolean, `rad<F>` is `.Select`-ed, a dropdown `cmb<F>` gets `.Key`; a range is
  `FIELD=BT:low,high`, and multiple single values are `FIELD=IN:v1,v2,...` via the SAPLALDB
  multiple-selection dialog), then
  Save-as-Variant (`ctxtRSVAR-VARIANT` + `txtRSVAR-VTEXT` + Save `tbar[0]/btn[11]`; the
  overwrite confirmation is handled). Any field it can't resolve is reported in
  `unresolved=` — **never silently dropped**. For a complex selection screen, prefer a
  human-authored variant or `/sap-gui-probe` the screen.
- **delete** (destructive — **confirm via Step 2.5**): `%%MODE%%=DELETE`. Find popup
  (`txtV-LOW` + `btn[8]`) → scope popup Continue (`tbar[0]/btn[5]`) → SPOP Yes
  (`btnSPOP-OPTION1`); verifies the `Variant … deleted` status.
- **list / show** (read-only, no confirm): delegate to `/sap-rfc-wrapper fm
  RS_VARIANT_CATALOG` (list) / `RS_VARIANT_CONTENTS` (show) — RFC is cleaner than scraping
  the GUI directory. If the dev wrapper is unavailable, drive the SAPLSVAR Find popup
  (`txtV-LOW` + `btn[8]`) to at least confirm a variant exists.
- **load for a run** is not a variant sub-command — it is `--variant` on a `run` (Step 3A),
  which loads the variant onto the selection screen before executing.

> **Verified live (2026-07-09)** on S4D (S/4HANA 1909, `ZMMRMAT037R02`) and EC2 (ECC,
> `ZMMRMAT0A6R01`): create → load-readback → delete with real `--values` (params, `-LOW`/`-HIGH`
> select-options, `BT:` ranges; read back off the loaded screen, VARID=0 after). Checkboxes/radios
> verified on S4G (fixture `ZZRUNREP_CBTEST`): `chk<F>.Selected` on/off + `rad<F>.Select` read back
> `P_FLAG=True`/`P_TEST=False`/`P_RAD2=True`. Dropdowns + multi-value select-options verified on
> **S4D (S/4HANA 1909) and EC2 (ECC 7.31)** (fixture `ZZRUNREP_MSTEST`, 2026-07-09): a LISTBOX
> `P_MODE=B` (`cmb<F>.Key`) and `S_MATNR=IN:MATA,MATB,MATC` read back `B` and `MATA,MATB,MATC`, all
> with `unresolved=0`. Two behaviours baked into the VBS: (1) the variant selector is
> **report-dependent** — classic Find (`SAPLSVAR` 100) or ALV directory (`SAPLSVAR` 600) — and both
> load/delete handle either (unresolved → `NEEDS_RECORDING`, never a false success); (2) `--values`
> field-fill dispatches on control **type** — `ctxt`/`txt` inputs + `BT:` ranges get `.Text`,
> checkboxes get `.Selected`, radiobuttons get `.Select`, dropdowns (`cmb<F>`) get `.Key`, and
> `IN:v1,v2,...` enters multiple single values via the SAPLALDB dialog (`btn%_<F>_%_APP_%-VALU_PUSH`
> → tab `tabpSIVA` → Copy F8; ids identical on S4D + EC2). A boolean value is `X`/`TRUE`/`1`/`Y`/`YES`
> = on, empty = off. Delete fills `--values` first so obligatory-field reports don't error with
> "fill required fields".

---

## Step 4 — Capture Output (foreground)

If `--save-output` is set and the run produced a classic list, the VBS attempts a
`%PC` list-download (format = Unconverted plain text) to `--save-output`. Because that
writes a local file via SAP GUI, wrap the cscript with the security guard exactly as
`/sap-sp02` Step 3 does (pre-check → launch `sap_gui_security_sidecar.ps1` if not
allow-listed → run → reap). ALV / interactive lists are **best-effort** — when the list
can't be captured, the VBS emits `list_saved=NONE` and the report says so; use the
background+spool path (Phase B) for reliable capture.

---

## Step 5 — Parse Result + Verdict

The last `RUN_REPORT:` / `VARIANT:` line is authoritative:

| Line | Meaning | Verdict |
|---|---|---|
| `RUN_REPORT: EXECUTED_FG list_saved=<path\|NONE> sbar=<S\|I>` | Foreground run completed | `OK` |
| `RUN_REPORT: SUBMITTED job=<name> count=<n>` | Background job scheduled | `OK` (async — not yet waited) |
| `RUN_REPORT: DUMP job=<name> <short>` | Runtime short dump | `DUMP` → drill with `/sap-st22` |
| `RUN_REPORT: NEEDS_RECORDING step=<s> program=<P> screen=<S>` | A release-specific popup/screen didn't resolve | not a run — see below |
| `VARIANT: <LISTED\|SHOWN\|DELETED\|NEEDS_RFC> …` | Variant op result | `OK` / degrade |
| `ERROR: …` | Fatal (program missing / no auth / attach) | surface + stop |

Emit `RUN_VERDICT: OK | DUMP | ERROR`. On `NEEDS_RECORDING`, do **not** claim the report
ran — record the control path via `/sap-gui-probe --record` and add it to
`sap_sa38_run.vbs` (same one-time-per-release model as `/sap-atc`, `/sap-run-abap-unit`).

---

## Step 5b — Register Artifact (best-effort)

Register `--save-output` for `/sap-evidence-pack` (Kind `run_output`). Wrap in try/catch;
NEVER change the verdict if registration fails (pattern from `sap-run-abap-unit` Step 4b).
Skip on `NEEDS_RECORDING` / variant-list/show.

---

## Step 6 — Report

State: program, engine (fg/bg), variant/values, target SID/client, and the verdict.
Foreground: the captured output path (+ size) or that capture was best-effort/NONE.
Background: the scheduled job name/count and how to monitor it (SM37 / `/sap-job`).
On `DUMP`: lead with the ST22 id + top error line.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_run_report_run.json" -Status SUCCESS -ExitCode 0
```

| Outcome | Status / ExitCode / ErrorClass |
|---|---|
| Ran clean / job scheduled | `SUCCESS / 0` |
| Runtime dump | `FAILED / 1 / RUN_DUMP` |
| Submit / schedule failed | `FAILED / 1 / RUN_SUBMIT_FAILED` |
| GUI screen/popup unresolved | `FAILED / 2 / RUN_GUI_PARSE_FAILED` (emit `NEEDS_RECORDING`, never false-green) |
| Variant create/edit needs RFC | `SKIPPED / 0 / RUN_VARIANT_NEEDS_RFC` |
| User declined at the confirm gate | `SKIPPED / 0` |

---

## Component IDs (captured live — S/4HANA 1909 (S4D) + ECC (EC2), 2026-07-09)

| Element | ID | Status |
|---|---|---|
| Program field (SA38/SE38) | `wnd[0]/usr/ctxtRS38M-PROGRAMM` | confirmed (shared with `sap_se38_run_aunit.vbs`) |
| Execute (selection screen) | `sendVKey 8` (F8) | confirmed |
| Get Variant trigger | `sendVKey 17` (Shift+F5), or `wnd[0]/tbar[1]/btn[17]`, or menu `wnd[0]/mbar/menu[2]/menu[0]/menu[0]` | captured |
| Find Variant popup | `SAPLSVAR` 100 — name `wnd[1]/usr/txtV-LOW`, apply `wnd[1]/tbar[0]/btn[8]`, cancel `btn[12]` | captured |
| Variant directory (ALV) | `SAPLSVAR` 600 — report-dependent alternative to the Find popup: match the row in `wnd[1]/usr/cntlALV_CONTAINER_1/shellcont/shell`, Choose `wnd[1]/tbar[0]/btn[2]` | captured |
| Execute in Background | `wnd[0]/mbar/menu[0]/menu[2]` | captured |
| Print-params popup | `SAPLSPRI` 100 — Continue `wnd[1]/tbar[0]/btn[13]`, device `wnd[1]/usr/ctxtPRI_PARAMS-PDEST` | captured |
| Start-Time popup | `SAPLBTCH` 1010 — Immediate `wnd[1]/usr/btnSOFORT_PUSH`, Save `wnd[1]/tbar[0]/btn[11]` | captured |
| Save as Variant (create) | `mbar/menu[2]/menu[0]/menu[3]` → `SAPLSVAR` 281: name `usr/ctxtRSVAR-VARIANT`, text `usr/txtRSVAR-VTEXT`, bg-only `usr/chkRSVAR-VBATCH`, Save `tbar[0]/btn[11]` | captured |
| Delete Variant | `mbar/menu[2]/menu[0]/menu[2]` → Find (`wnd[1]/usr/txtV-LOW`+`tbar[0]/btn[8]`) → scope `SAPLSVAR` 322 Continue `wnd[1]/tbar[0]/btn[5]` → SPOP Yes `wnd[1]/usr/btnSPOP-OPTION1` | captured |
| List download (`%PC`) | format popup → `DY_PATH`/`DY_FILENAME` | **best-effort** — `%PC` N/A on S/4HANA/ECC ALV output; use background→spool (`/sap-sp02`) |

Get-Variant and Execute-in-Background paths were **identical** on S/4HANA 1909 and ECC (EC2
verified under a JA logon) — core `SAPLSVAR` / `SAPLSPRI` / `SAPLBTCH` kernel dialogs, stable
across release and language, so one set covers both. Each step is still guarded with
`On Error` + `RUN_REPORT: NEEDS_RECORDING` so an unresolved control never reports a false
success. The `%PC` classic-list path stays a seed (both test reports rendered ALV); the
reliable foreground capture is background→spool via `/sap-sp02`.

---

## Limitations (Phase A)

- **GUI backend only.** The RFC background path (`Z_RUN_REPORT` → spool capture) and the
  dedicated `sap_variant_rfc.ps1` variant create/edit are Phase B.
- **Foreground output capture is best-effort** for classic lists (`%PC`); ALV /
  interactive lists need manual capture or the Phase-B background+spool path.
- **Background is fire-and-schedule** in GUI-only mode — no completion poll; monitor via
  `/sap-job` (when built) or SM37.
- **GUI IDs captured** (2026-07-09) for Get-Variant + Execute-in-Background — identical on
  S/4HANA 1909 (S4D) and ECC (EC2), so one path set covers both. The `%PC` classic-list save
  stays a best-effort seed (both probe reports rendered ALV); reliable foreground capture is
  background→spool via `/sap-sp02`.
