---
name: sap-job
description: |
  Manages ABAP background jobs on a live SAP system — schedule, list, status, log,
  spool, cancel, delete. Mode-aware: prefers the RFC fast-path (schedule via the
  RFC-enabled Z_RUN_REPORT; list/status via TBTCO; spool id via TBTCP; delete via
  BP_JOB_DELETE) and falls through to GUI (SM36 schedule / SM37 operations) when
  RFC is unavailable, honouring userConfig.sap_dev_mode. Scheduling a report EXECUTES
  it (possibly recurring), and cancel/delete are destructive — the skill ALWAYS
  confirms those before acting, per skill_operating_rules Rule 5. Reads (list/status/
  log/spool) run without confirmation. Reuses Z_RUN_REPORT (deployed by /sap-dev-init)
  and delegates spool text to /sap-sp02 and abort detail to /sap-st22.
  Prerequisites: active SAP GUI session (/sap-login). The RFC path additionally needs
  SAP NCo 3.1 (32-bit) + Z_RUN_REPORT; without them the skill uses the SM36/SM37 GUI paths.
argument-hint: "schedule <PROGRAM> [--variant=V] [--start=immediate|YYYYMMDDHHMMSS|event:E] [--period=daily|weekly|monthly] [--jobname=N]   |   list [--user=U] [--jobname=Z*] [--from=YYYYMMDD] [--to=YYYYMMDD] [--status=R|Y|P|S|A|F]   |   <status|log|spool|cancel|delete> <JOBNAME> <JOBCOUNT> [--save-output=PATH]"
---

# SAP Job Skill

You manage ABAP background jobs on a live SAP system. **Scheduling** a report runs
it (possibly on a recurrence) and **cancel/delete** are destructive — those three
verbs share the report-execution risk class, so this skill ALWAYS confirms them
(Step 2.5) and never acts as an unconfirmed side effect of another skill. The
monitoring verbs (**list / status / log / spool**) are read-only and run without a
prompt.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules — **Rule 5 (report execution + destructive job ops require confirmation)** governs `schedule`, `cancel`, `delete` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — component ID + DDIC field name, status via `MessageType` (S/W/E/I/A), VKey over menu-text, no `.Text`/`.Tooltip` branching |
| `<SKILL_DIR>/references/sap_job_rfc.ps1` | RFC backend (32-bit PS): schedule (Z_RUN_REPORT), list/status (TBTCO), spool (TBTCP), delete (BP_JOB_DELETE); emits `JOB:` lines |
| `<SKILL_DIR>/references/sap_sm36_schedule.vbs` | GUI schedule fallback — SM36 wizard (job → step → start condition → save); emits `JOB:` lines |
| `<SKILL_DIR>/references/sap_sm37_ops.vbs` | GUI operations fallback — SM37 list/status/log/spool/cancel/delete; emits `JOB:` lines |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | NCo 3.1 connect + `New-RfcReadTable` / `Add-RfcField` / `Add-RfcOption` (dot-sourced by the backend) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_precheck.ps1` | Read-only allow-list pre-check (`saprules.xml`) before a GUI job-log `%PC` save |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_sidecar.ps1` | OS-level watcher that auto-dismisses the SAP GUI Security dialog on the log save |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | `New-SapScopeKey` / `Register-SapArtifact` — register captured spool/log output for `/sap-evidence-pack`. Best-effort; never changes the verdict. |

**Delegated skills** (invoke via the Skill tool — do not re-implement):
`/sap-login` (session), `/sap-sp02` (spool → file), `/sap-st22` (dump detail on an
aborted job), `/sap-run-report` (to execute a report *foreground* / for variant
maintenance), `/sap-gui-probe --record` (capture the SM36/SM37 control IDs live).

**Reuses `Z_RUN_REPORT`** — the RFC-enabled scheduling FM deployed by `/sap-dev-init`
(Phase B, shared with `/sap-run-report`). No new FM; `/sap-job schedule` calls it by
name over RFC for immediate scheduling.

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
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_job_run.json" -Skill sap-job -ParamsJson "{\"mode\":\"<schedule|list|status|log|spool|cancel|delete>\",\"program\":\"<P|>\",\"backend\":\"<rfc|gui>\"}"
```

State file: `{RUN_TEMP}\sap_job_run.json`. Best-effort (Rule 4: never skip the call).

---

## Step 1 — Parse Arguments + Resolve Mode + Resolve Backend

**Mode** — the first token selects it:

| Invocation | Mode | Write? |
|---|---|---|
| `schedule <PROGRAM> …` | **schedule** | ✅ executes a report (confirm) |
| `list …` | **list** | read-only |
| `status <JOBNAME> <JOBCOUNT>` | **status** | read-only |
| `log <JOBNAME> <JOBCOUNT>` | **log** | read-only |
| `spool <JOBNAME> <JOBCOUNT>` | **spool** | read-only |
| `cancel <JOBNAME> <JOBCOUNT>` | **cancel** | ✅ destructive (confirm) |
| `delete <JOBNAME> <JOBCOUNT>` | **delete** | ✅ destructive (confirm) |

**`schedule` switches:** `--variant=V`, `--start=immediate|YYYYMMDDHHMMSS|event:<EVT>`
(default `immediate`), `--period=daily|weekly|monthly`, `--jobname=N` (default =
program), `--class=A|B|C` (default `C`), `--session=…`.

**`list` filters:** `--user=U`, `--jobname=Z*` (`*`→`%` LIKE), `--from=YYYYMMDD`,
`--to=YYYYMMDD` (SDLSTRTDT window — best-effort; immediate-start jobs may carry a blank
SDLSTRTDT), `--status=R|Y|P|S|A|F`, `--max=N` (ROWCOUNT cap, default 100).

**`status|log|spool|cancel|delete`** take `<JOBNAME> <JOBCOUNT>` positionally
(`JOBCOUNT` = the 8-char job number; get it from `list`). `log`/`spool` accept
`--save-output=PATH`.

**Backend resolution** — read `userConfig.sap_dev_mode`:
- `GUI` → GUI branch only (SM36/SM37; never attempt RFC).
- `RFC` / unset → prefer RFC; on any `RFC_ERROR` / `*_NEEDS_GUI` / missing `Z_RUN_REPORT`,
  **degrade to GUI, never block** (same contract as `sap-run-report` Step 3B→3C).

Log the resolved `mode` / `backend`.

**TBTCO status codes** (used throughout): `R`=Active `Y`=Ready `P`=Scheduled
`S`=Released `A`=Cancelled/aborted `F`=Finished.

---

## Step 2 — Ensure Session

The GUI paths need an active SAP GUI session — run `/sap-login` first if none. The RFC
backend needs NCo + the pinned profile; if RFC is unavailable it degrades to the GUI
path, which still needs the GUI session.

---

## Step 2.5 — CONFIRM Gate (MANDATORY for schedule / cancel / delete)

**Applies to `schedule`, `cancel`, `delete`.** Skip for `list` / `status` / `log` /
`spool` (read-only). Per `skill_operating_rules.md` **Rule 5**.

**schedule** — the skill cannot know whether the report only reads or also mutates data,
and a `--period` job runs *repeatedly* on a shared system:

> "I will **SCHEDULE** report `<PROGRAM>` as a background job (`<start>`, period
> `<period|once>`, variant `<V|—>`, job `<jobname>`) on `<SID>/<CLIENT>`. It will
> execute — possibly changing data, and possibly on a recurrence. Proceed? (yes / no)"

**cancel / delete** — irreversible:

> "I will **<CANCEL the running|DELETE the>** job `<JOBNAME>` / `<JOBCOUNT>` on
> `<SID>/<CLIENT>`. This cannot be undone. Proceed? (yes / no)"

Proceed only on explicit `yes`. On `no` / no answer → stop (log `SKIPPED`). Record the
confirmation: `sap_log_helper.ps1 -Action step -Step confirm -Message "user approved <mode>"`.

---

## Step 3 — Dispatch

### RFC branch (`backend=RFC`) — run the backend once, parse the last `JOB:` line

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_job_rfc.ps1" -Action <mode> -Program "<P>" -Variant "<V>" -JobName "<NAME>" -JobCount "<COUNT>" -User "<U>" -Status "<S>" -FromDate "<YYYYMMDD>" -ToDate "<YYYYMMDD>" -MaxRows <max> -Start "<start>" -Period "<period>" -RfcLib "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1"
```

Pass only the args the mode uses (empty string otherwise). Interpret the exit code:

| Exit | Meaning | Action |
|---|---|---|
| `0` | op succeeded | parse the `JOB:` line (Step 5); `spool` → Step 4 capture |
| `1` | negative result (`NOT_FOUND` / `SCHEDULE_FAILED`) | report per Step 5, verdict `ERROR` |
| `2` | infra (RFC connect / lib / FM missing) | **degrade to the GUI branch** for this mode |
| `3` | RFC path unavailable for this op (`*_NEEDS_GUI`) | **degrade to the GUI branch** for this mode |

`log` and `cancel` always return `3` from the RFC backend (job-log text lives in TemSe;
aborting a running job needs the server/PID SM37 resolves) — they go straight to the GUI
branch. `schedule` with `--start≠immediate` or `--period` returns `3` (`SCHEDULE_NEEDS_GUI`)
→ SM36. `list` renders the `JOBROW:` tab-rows into a table plus the `JOB: LISTED n=<k>` line.

### GUI branch (`backend=GUI`, or after an RFC degrade)

Generate the filled-in VBS (read UTF-8 → substitute tokens → write UTF-16 LE BOM; never
`Get-Content -Raw` + `Set-Content -Encoding Unicode`). **schedule → `sap_sm36_schedule.vbs`;
every other mode → `sap_sm37_ops.vbs`.**

*Schedule generator* — write `{RUN_TEMP}\sap_sm36_schedule_run.ps1`:

```powershell
$skillDir = '<SKILL_DIR>'
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_sm36_schedule.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%PROGRAM%%',  'THE_PROGRAM')      # UPPERCASE
$content  = $content.Replace('%%VARIANT%%',  'THE_VARIANT')      # '' if none
$content  = $content.Replace('%%JOBNAME%%',  'THE_JOBNAME')      # '' = program
$content  = $content.Replace('%%START%%',    'THE_START')        # immediate|YYYYMMDDHHMMSS|event:E
$content  = $content.Replace('%%PERIOD%%',   'THE_PERIOD')       # '' | daily|weekly|monthly
$content  = $content.Replace('%%JOBCLASS%%', 'THE_CLASS')        # A|B|C ('' -> C)
# Tier-3 session-attach plumbing.
$sessionPath = ''   # set to the parsed --session value if supplied
$content  = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%', "$shared\scripts\sap_attach_lib.vbs")
. "$shared\scripts\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_sm36_schedule.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

*Operations generator* — write `{RUN_TEMP}\sap_sm37_ops_run.ps1` (same shape):

```powershell
$skillDir = '<SKILL_DIR>'
$shared   = '<SAP_DEV_CORE_SHARED_DIR>'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_sm37_ops.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%OP%%',            'THE_OP')          # LIST|STATUS|LOG|SPOOL|CANCEL|DELETE
$content  = $content.Replace('%%JOBNAME%%',       'THE_JOBNAME')
$content  = $content.Replace('%%JOBCOUNT%%',      'THE_JOBCOUNT')    # '' = first match
$content  = $content.Replace('%%USER%%',          'THE_USER')        # '' -> * on screen
$content  = $content.Replace('%%FROM_DATE%%',     'THE_FROM')        # '' = screen default
$content  = $content.Replace('%%TO_DATE%%',       'THE_TO')
$content  = $content.Replace('%%STATUS_FILTER%%', 'THE_STATUSES')    # e.g. 'RF'; '' = all
$content  = $content.Replace('%%SAVE_PATH%%',     'THE_SAVE_PATH')   # log %PC target, '' to skip
$sessionPath = ''
$content  = $content.Replace('%%SESSION_PATH%%',   $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%', "$shared\scripts\sap_attach_lib.vbs")
. "$shared\scripts\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_sm37_ops.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run the generator, then the VBS via the **32-bit** cscript host (SAP GUI COM needs 32-bit):

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_sm37_ops_run.ps1"
C:\Windows\SysWOW64\cscript.exe //NoLogo {RUN_TEMP}\sap_sm37_ops.vbs
```

For the GUI **log** save-output, wrap the cscript with the SAP GUI Security guard exactly
as `/sap-sp02` Step 3 / `sap-run-report` Step 4 do (pre-check → launch
`sap_gui_security_sidecar.ps1` if not allow-listed → run → reap).

> **GUI IDs are CAPTURED live** (S4G S/4HANA + EC2 ECC 7.31/JA, 2026-07-09; see the
> Component IDs table). SM37 `list`/`log` and the full SM36 immediate wizard were verified
> live on both releases. Each transition is still guarded by `JOB: NEEDS_RECORDING`, so a
> future release that moves a control is caught, never false-greened — re-capture it with
> `/sap-gui-probe --record`. The RFC path remains the route for
> `list`/`status`/`spool`/`schedule`(immediate)/`delete` when NCo + `Z_RUN_REPORT` are present.

**GUI schedule — resolving the job count.** SM36 does not surface the job NUMBER, so the
VBS emits `count=?`. If RFC is available, resolve the newest count for this `(jobname, user)`
via a follow-up `sap_job_rfc.ps1 -Action list -JobName <name> -User <me>`; otherwise report
`count=?` and point the user to `/sap-job list`.

---

## Step 4 — Capture (spool / log)

- **spool** (`JOB: SPOOL spool=<LISTIDENT>` with `<LISTIDENT>` ≠ `NONE` and `--save-output`
  set): capture the text by delegating to the verified spool skill —

  ```
  /sap-sp02 <LISTIDENT> <--save-output>
  ```
  Append `out=<path>` to the report. `spool=NONE` = the job produced no list output.
- **log** (GUI): the VBS best-effort `%PC`-saves the job log to `--save-output`; report the
  saved path (or `NONE`). The RFC path does not read the job log (TemSe) — use the GUI log
  or SM37 directly.
- **aborted job** (`status=A`, or a `JOB: STATUS status=A`): drill the short dump with
  `/sap-st22` (deep) and surface the top error line.

---

## Step 5 — Parse Result + Verdict

The last `JOB:` line is authoritative:

| Line | Meaning | Verdict |
|---|---|---|
| `JOB: SCHEDULED job=<name> count=<n\|?>` | Job scheduled (RFC immediate, or GUI SM36) | `OK` |
| `JOB: LISTED n=<k> truncated=<0\|1>` (+ `JOBROW:` rows) | Job list returned `k` rows (render the table; `truncated=1` → raise `--max`) | `OK` |
| `JOB: STATUS status=<code> statustext=<t> count=<n>` | Single-job status (`A` → aborted) | `OK` (`A` → drill ST22) |
| `JOB: SPOOL spool=<id\|NONE> count=<n>` | Spool id for the job; Step 4 captures via `/sap-sp02` | `OK` |
| `JOB: LOG lines=<k> saved=<path\|NONE>` | Job log opened (GUI); optionally saved | `OK` |
| `JOB: CANCELLED count=<n>` / `JOB: DELETED count=<n>` | Destructive op succeeded | `OK` |
| `JOB: NOT_FOUND job=<name> count=<n>` | `(jobname, jobcount)` not in `TBTCO` | `ERROR` (`JOB_NOT_FOUND`) |
| `JOB: SCHEDULE_FAILED program=<P> status=<s>` | `Z_RUN_REPORT` could not schedule | `ERROR` (`JOB_SCHEDULE_FAILED`) |
| `JOB: NEEDS_RECORDING step=<s> screen=<S>` | A release-specific SM36/SM37 screen didn't resolve | not done — record & retry |
| `JOB: *_NEEDS_GUI …` (exit 3) | RFC path unavailable — handled by the Step 3 degrade | (internal) |
| `ERROR: …` | Fatal (attach / auth / bad args) | surface + stop |

Emit `JOB_VERDICT: OK | ERROR`. On `NEEDS_RECORDING`, do **not** claim the op ran —
capture the control path via `/sap-gui-probe --record` and add it to the VBS.

---

## Step 5b — Register Artifact (best-effort)

For `spool` / `log` with a captured path, register it for `/sap-evidence-pack` (Kind
`job_output`) via `sap_artifact_lib.ps1`. Wrap in try/catch; NEVER change the verdict if
registration fails (pattern from `sap-run-abap-unit` Step 4b). Skip on `NEEDS_RECORDING`.

---

## Step 6 — Report

State: mode, backend (rfc/gui), the job (name/count), target SID/client, and the verdict.
`schedule`: the scheduled job name/count + how to monitor it (`/sap-job status … …`).
`list`: the rendered table + row count (+ truncation note). `spool`/`log`: the captured
output path (+ size). On an aborted job: lead with the ST22 id + top error line.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_job_run.json" -Status SUCCESS -ExitCode 0
```

| Outcome | Status / ExitCode / ErrorClass |
|---|---|
| Scheduled / listed / status / log / spool / cancelled / deleted OK | `SUCCESS / 0` |
| Schedule failed (`Z_RUN_REPORT` / SM36) | `FAILED / 1 / JOB_SCHEDULE_FAILED` |
| Job not found (`status`/`log`/`spool`/`cancel`/`delete`) | `FAILED / 1 / JOB_NOT_FOUND` |
| Cancel/delete failed (`BP_JOB_DELETE` / SM37) | `FAILED / 1 / JOB_CANCEL_FAILED` |
| SM36/SM37 screen unresolved | `FAILED / 2 / RUN_GUI_PARSE_FAILED` (emit `NEEDS_RECORDING`, never false-green) |
| User declined at the confirm gate | `SKIPPED / 0` |

(Error classes are already defined in `shared/rules/error_classes.md` — the "Report
execution" section: `JOB_SCHEDULE_FAILED`, `JOB_NOT_FOUND`, `JOB_CANCEL_FAILED`,
`RUN_DUMP`, `RUN_GUI_PARSE_FAILED`.)

---

## Component IDs (CAPTURED live 2026-07-09 — S4G S/4HANA + EC2 ECC 7.31/JA)

The GUI drivers ship with these **live-captured** IDs (`.screens.json` checkpoints =
`captured`), each still guarded by `JOB: NEEDS_RECORDING` so any future release drift is
caught, never false-greened. Verified identical on S/4HANA (EN) and ECC 7.31 (JA) — core
`SAPLBTCH` / `SAPMSSY0` kernel dialogs, stable across release and logon language.

| Screen | Element | ID |
|---|---|---|
| SM37 selection (`SAPLBTCH/2170`) | Job name / user | `wnd[0]/usr/txtBTCH2170-JOBNAME` / `txtBTCH2170-USERNAME` — **`txt` (GuiTextField), not `ctxt`** |
| SM37 selection | Status checkboxes | `chkBTCH2170-PRELIM`(P/sched) `-SCHEDUL`(S/rel) `-READY`(Y) `-RUNNING`(R/active) `-FINISHED`(F) `-ABORTED`(A/cancelled) |
| SM37 selection | Dates / Execute | `ctxtBTCH2170-FROM_DATE` `-TO_DATE` / `sendVKey 8` (F8) |
| SM37 list (`SAPMSSY0/120`, **classic list**) | Row select | job row = a `GuiLabel` whose Text = job name (col 4); `.setFocus` positions the cursor (verified) |
| SM37 list | Job log / Spool | `wnd[0]/tbar[1]/btn[47]` / `wnd[0]/tbar[1]/btn[44]` |
| SM37 list | Delete / Cancel active job | Delete = **`sendVKey 14`** (Shift+F2) → SPOP `btnSPOP-OPTION1`=Yes — a VKey, release/locale-independent (the Job-menu index for Delete differs across releases: menu[9] on S/4HANA, menu[2] on ECC 7.31). Cancel-active = Job menu, resolved by **localized-text match** ("Cancel active job" EN / `有効ジョブ中止` JA via `ChrW`) in `wnd[0]/mbar/menu[0]`, `menu[1]` fallback — matcher live-confirmed on S4G+EC2; then re-query Active-only to verify the abort. Back `tbar[0]/btn[3]` |
| SM36 initial (`SAPLBTCH/1140`) | Job name / class | `wnd[0]/usr/txtBTCH1140-JOBNAME` (txt) / `ctxtBTCH1140-JOBCLASS` |
| SM36 initial | Step / Start condition / Save | `wnd[0]/tbar[1]/btn[6]` / `wnd[0]/tbar[1]/btn[5]` / `sendVKey 11` (Ctrl+S) |
| SM36 step (`SAPLBTCH/1120`, wnd[1]) | Program / variant / Save | `ctxtBTCH1120-ABAPNAME` / `ctxtBTCH1120-VARIANT` / `wnd[1]/tbar[0]/btn[11]` — Save lands on the step-LIST (`SAPMSSY0/120`); **Back (sendVKey 3) to the 1140 initial** |
| SM36 start (`SAPLBTCH/1010`, wnd[1]) | Immediate / Date-Time / Periodic | `btnSOFORT_PUSH` / `btnDATE_PUSH` → `ctxtBTCH1010-SDLSTRTDT` `-SDLSTRTTM` / `chkBTCH1010-PERIODIC` + Period Values `wnd[1]/tbar[0]/btn[5]` |
| SM36 period (`SAPLBTCH/1060`, wnd[2]) | Daily / Weekly / Monthly / Save | `btnDAILYBUTTON` / `btnWEEKLYBUTTON` / `btnMONTHLYBUTTON` / `wnd[2]/tbar[0]/btn[11]` |

---

## Limitations (v1)

- **RFC path is the verified route** for `schedule`(immediate), `list`, `status`, `spool`,
  and `delete` — it reuses the Phase-B `Z_RUN_REPORT` + `TBTCO`/`TBTCP` reads
  (`sap_job_rfc.ps1`). `delete` via `BP_JOB_DELETE` is best-effort over direct RFC and
  degrades to SM37 if the FM is not remote-enabled on the system.
- **GUI SM36/SM37 verified live** (S4G S/4HANA EN + EC2 ECC 7.31 JA, 2026-07-09). Verified
  end-to-end: `schedule` **immediate / date-time / periodic** (S4G `TBTCS`-confirmed:
  `PERIODIC=X` + day/week counts), `list` / `status` / `log`, `delete` (SM37 Shift+F2), and
  `cancel` — a running WAIT job **aborted and RFC-confirmed `A` on S4G**; on EC2 every cancel
  component is verified (localized menu matcher live-confirmed finds `有効ジョブ中止`, SAPLSPO1
  confirm + the SM37 re-query both proven via the delete round-trip). Both destructive ops
  **self-verify** before reporting (delete: job left the list; cancel: job left the Active
  status via a re-query) — never a false success; any release drift → `NEEDS_RECORDING`. The
  only step not run literally on EC2 is aborting a live job there (would need a flaky ECC
  clipboard-paste fixture deploy); the mechanism is identical and every component is verified.
- **GUI job ops target by job NAME** (first matching row). The SM37 classic list does not
  show `JOBCOUNT`, so exact-jobcount disambiguation among same-named runs is the RFC path's
  job; the GUI acts on the first row of that name.
- **`log` and `cancel` are GUI-primary.** Job-log text lives in TemSe (read via the SM37
  GUI list, not RFC); aborting a *running* job needs the executing server/PID that SM37's
  "Cancel active job" resolves. Both drive `sap_sm37_ops.vbs`.
- **Start-time / periodic scheduling is GUI-only** (SM36) — `Z_RUN_REPORT` submits
  immediately. `--start≠immediate` / `--period` route to the SM36 wizard.
- **Foreground execution** of a report is `/sap-run-report --foreground` (this skill is
  background jobs only). Variant maintenance is `/sap-run-report variant …`.
