---
name: sap-stms
description: |
  Moves a released transport request through the landscape (DEV -> QAS -> PRD)
  and reads its import status / return code via STMS. Four modes:
    (a) status (default, READ-ONLY) - show a target system's import queue, or
        where a given TR sits on the route.
    (b) logs (READ-ONLY) - the import log + step return code (RC 0/4/8/12) for a
        TR in a system, mapped to OK / OK_WITH_WARNINGS / ERROR / FATAL.
    (c) import (WRITE, gated) - import one released TR into a target system.
        Tiered confirmation; a PRODUCTION target requires a typed SID echo + a
        second confirmation (most outward-facing, least-reversible action in the
        toolset). Never imports an unreleased or NO-GO TR without --force.
    (d) import-all (WRITE, double-gated) - import a whole queue; off without --all.
  Honesty contract: missing import authorization -> COULD_NOT_IMPORT (never a
  faked success); RC 8/12 = failure even if the queue row looks "done." GUI for
  the action, RFC (E070) for the released-status read. The import VBS ships as a
  recording-gated scaffold (PLACEHOLDER destructive control IDs + strict
  pre-flight TR/target verification) so an uncalibrated run fails SAFE, never
  mis-imports - run /sap-gui-record on STMS_IMPORT once per release first.
  Prerequisites: active SAP GUI session (/sap-login); for QA/PROD imports, TMS
  import authorization (often Basis-gated - status/logs work without it).
argument-hint: "[status] [<TR>] [--system SID] [--route] | logs <TR> --system SID | import <TR> --to SID [--client NNN] [--immediate] [--leave-in-queue] [--force] | import-all --to SID --all  [--connection PROFILE] [--report] [--out PATH]"
---

# SAP STMS - Transport Landscape Movement Skill

You move a **released** transport request through the transport landscape and
read its import status. You are READ-ONLY by default; any import is opt-in,
gated, and — for a production target — the most strongly-guarded action in the
whole toolset. You never import an unreleased or NO-GO TR without `--force`, and
you report return codes truthfully (RC 8/12 = failure, even if the row looks
done).

Task: $ARGUMENTS

This skill observes `shared/rules/skill_operating_rules.md` (Rule 2 — no
unsolicited write). It is the downstream of the release chain:
`/sap-transport-readiness` (GO/NO-GO) -> `/sap-se01 release` -> **`/sap-stms`**.
`/sap-fix-incident` hands off here after a DEV fix.

---

## Shared Resources

| File / token | Path | Purpose |
|---|---|---|
| `skill_operating_rules.md` | `<SAP_DEV_CORE_SHARED_DIR>\rules\skill_operating_rules.md` | Rule 2 confirmation gate |
| `language_independence_rules.md` | `<SAP_DEV_CORE_SHARED_DIR>\rules\language_independence_rules.md` | IDs + `MessageType`, never displayed text |
| `settings_lookup.md` | `<SAP_DEV_CORE_SHARED_DIR>\rules\settings_lookup.md` | per-key settings merge; per-connection pin |
| `sap_settings_lib.ps1` + `sap_connection_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\` | `Get-SapWorkDir`, `Get-SapCurrentSessionPath` |
| `sap_rfc_lib.ps1` (`%%RFC_LIB_PS1%%`) | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1` | E070 released-status read (RFC) |
| `sap_attach_lib.vbs` (`%%ATTACH_LIB_VBS%%`) | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs` | `AttachSapSession` for every VBS |
| `sap_session_lock.vbs` (`%%SESSION_LOCK_VBS%%`) | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs` | lock the session around the import write |
| `<SKILL_DIR>\references\sap_stms_queue_read.vbs` | *(reader)* | STMS import-queue scrape (read-only) |
| `<SKILL_DIR>\references\sap_stms_log_read.vbs` | *(reader)* | import log + RC scrape (read-only) |
| `<SKILL_DIR>\references\sap_stms_import.vbs` | *(writer)* | import one TR into a target (gated; recording-calibrated) |
| `sap_log_helper.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1` | structured logging |

**Skills referenced**: `/sap-transport-readiness` (optional pre-flight gate),
`/sap-se01` (release — the step before import), `/sap-se16n` (manual E070 check).

`<SAP_DEV_CORE_SHARED_DIR>` = `plugins/sap-dev-core/shared` — 3 levels up from
`<SKILL_DIR>`, then into `sap-dev-core\shared`.

---

## Step 0 — Resolve Work Directory and Settings

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('PROD_IDS=' + (Get-SapSettingValue 'prod_system_ids' ''))"
```

Settings reads follow `settings_lookup.md`. Read `prod_system_ids` (optional
comma-separated allow-list of production SIDs — see PROD detection in Step 3).
Set `{WORK_TEMP}` = `{work_dir}\temp`; `{RUN}` = `{WORK_TEMP}\stms\<run>`:

```bash
cmd /c if not exist "{WORK_TEMP}\stms" mkdir "{WORK_TEMP}\stms"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's `_run.json` log state under `{RUN_TEMP}` (the working files already live in the per-run `{RUN}`); keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

## Step 0.5 — Start Logging (best-effort)

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_stms_run.json" -Skill sap-stms -ParamsJson "{}"
```

---

## Step 1 — Mode Dispatch

| First token / flags | Mode | Section |
|---|---|---|
| `import-all --all` | IMPORT-ALL | Import-All Mode |
| `import <TR> --to <SID>` | IMPORT | Import Mode |
| `logs <TR> --system <SID>` | LOGS | Logs Mode |
| `status` / none | STATUS | Status Mode (default) |

`--to` / `--system` is **mandatory for any write** — there is no default target.
Validate the TR format (`<SID>K<digits>`).

---

# Status Mode (default, read-only)

## S1 — Resolve target(s)

`--system <SID>` for one system; `--route` to walk every system on the TR's
transport route. If a `<TR>` is given, also locate where it sits.

## S2 — Read the queue (GUI)

Substitute + run `sap_stms_queue_read.vbs` (32-bit cscript; attach tokens as in
Step W3 below). Tokens: `%%TARGET_SID%%`, `%%TR%%` (or empty), `%%OUTPUT_FILE%%`.
It navigates `/nSTMS_IMPORT`, opens the target queue, and scrapes each row
(`TRKORR`, owner, short text, status, RC if shown) to `{RUN}\queue.json`.

> **RFC alternative (preferred when available).** `TMS_MGR_READ_TRANSPORT_QUEUE`
> reads the queue over RFC without GUI; it needs the target's TMS RFC + auth.
> v1 ships the GUI reader (universally available to a dialog user); the RFC path
> is a documented Phase-2 optimization.

## S3 — Report

Print the queue (or the TR's position) and whether the TR is already imported.
`STATUS: QUEUE system=<SID> rows=<n> tr=<TR?> position=<n|not-in-queue|imported>`.

---

# Logs Mode (read-only)

## L1 — Read the import log

Substitute + run `sap_stms_log_read.vbs`. Tokens: `%%TARGET_SID%%`, `%%TR%%`,
`%%OUTPUT_FILE%%`. It **navigates into the named target system's import queue**
(double-clicks the `%%TARGET_SID%%` row on the STMS_IMPORT overview) before
reading, so the RC is read from the RIGHT system — not whatever queue
`/nSTMS_IMPORT` happened to land on. Then it reads the **return code**.

## L2 — Map RC -> verdict and report

| RC | Verdict |
|---|---|
| `0` | OK |
| `4` | OK_WITH_WARNINGS |
| `8` | ERROR (import errors — activation / generation failures) |
| `12` | FATAL (cancelled / system error) |
| (none / not found) | NOT_IMPORTED |
| (target queue not reachable) | QUEUE_NOT_REACHED |

`STATUS: LOG tr=<TR> system=<SID> rc=<0|4|8|12|-> verdict=<...>`. **RC 8/12 is a
failure even if the queue row shows "done"** — say so plainly. A
`verdict=QUEUE_NOT_REACHED` means the reader could **not** open the
`%%TARGET_SID%%` queue (system not in the overview, or the queue view differs on
this release) — it deliberately did **not** read another queue's RC and did not
stamp the SID as verified. Re-record `OpenTargetQueue` candidate IDs via
`/sap-gui-record` on STMS_IMPORT; do not treat it as a successful import.

---

# Import Mode (WRITE — gated)

## W1 — Parse + resolve the route

`import <TR> --to <SID> [--client NNN] [--immediate] [--leave-in-queue]
[--force]`. Read the TMS route so the target can be classified DEV / QA / PROD
(route position + the `prod_system_ids` allow-list).

## W2 — Pre-flight gate (each a hard stop unless noted)

| Check | How | Stop unless |
|---|---|---|
| TR is **released** | RFC read `E070-TRSTATUS = R` (via `sap_rfc_lib.ps1`; or `/sap-se16n E070`) | not `R` -> "release it first via `/sap-se01 release <TR>`" |
| Already imported in target | Logs Mode read (RC present) | already imported -> report + stop (no double import) |
| Readiness verdict | optional `/sap-transport-readiness <TR>` | `NO_GO` -> stop unless `--force` (and say `--force` was used) |
| Target is PROD? | route position / `prod_system_ids` | escalate to the PROD gate in W3 |

Echo each: `PREFLIGHT: released=<Y/N> imported=<Y/N> readiness=<GO|NO_GO|skipped> target_class=<DEV|QA|PROD>`.

## W3 — Confirmation (tiered, mandatory)

- **QA / test target**: ask once — *"Import `<TR>` into `<SID>`/`<client>`?
  (yes / no)"*. Proceed only on `yes`.
- **PRODUCTION target**: show the TR's object inventory summary, then require
  **two** signals: (1) the user **types the target SID back**, and (2) confirms
  *"yes, import to production"*. Anything else aborts. Log the confirmation
  explicitly. This is irreversible-in-effect — you cannot un-import.

Never skip W3. There is no `--apply`-style bypass for a production import.

## W4 — Run the import (GUI, recording-calibrated)

> **Calibration gate.** `sap_stms_import.vbs` ships with PLACEHOLDER control IDs
> for the destructive Import-Request + import-options dialog (the STMS queue/tree
> + dialog IDs vary by release and were NOT recorded against a live system). On
> first use per release, run `/sap-gui-record` on the `STMS_IMPORT` import flow
> and replace the `PLACEHOLDER_*` constants. Until then the VBS **fails loud**
> (`ERROR: import controls not calibrated`) rather than clicking anything — a
> safe no-op, never a mis-import.

Substitute the VBS and run it (32-bit cscript). It locks the session
(`%%SESSION_LOCK_VBS%%`), navigates to the target queue, and — **only after
positively verifying the selected row's `TRKORR` equals `<TR>` and the screen is
the intended target's queue** — presses Import Request, fills the target
`--client`, and confirms. If it cannot verify the row == `<TR>`, it ABORTS
without importing (exit 1).

> **`--immediate` / `--leave-in-queue` are not yet wired.** The import-options
> checkboxes are release-specific and have **no recorded control IDs** in the VBS.
> If either `%%IMMEDIATE%%` or `%%LEAVE_IN_QUEUE%%` is passed as a truthy value
> (`1`/`X`/`true`), the VBS **fails loud** with `ERROR: STMS_OPTION_UNSUPPORTED`
> (exit 1) rather than silently importing with the queue default. Leave both `0`
> (the example below) until you record the checkbox IDs via `/sap-gui-record` on
> the STMS_IMPORT options dialog and wire them in. **All abort/error paths now
> exit 1** (were exit 0) so the caller never reads a failed import as success.

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
. "$shared\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
$vbs = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_stms_import.vbs', [Text.Encoding]::UTF8)
$vbs = $vbs.Replace('%%ATTACH_LIB_VBS%%',  "$shared\sap_attach_lib.vbs")
$vbs = $vbs.Replace('%%SESSION_LOCK_VBS%%',"$shared\sap_session_lock.vbs")
$vbs = $vbs.Replace('%%SESSION_PATH%%',    '')        # or the --session value
$vbs = $vbs.Replace('%%TR%%',              'THE_TR')
$vbs = $vbs.Replace('%%TARGET_SID%%',      'THE_SID')
$vbs = $vbs.Replace('%%TARGET_CLIENT%%',   'THE_CLIENT')
$vbs = $vbs.Replace('%%IMMEDIATE%%',       '0')       # MUST be 0 until the options checkboxes are calibrated (a truthy value -> STMS_OPTION_UNSUPPORTED)
$vbs = $vbs.Replace('%%LEAVE_IN_QUEUE%%',  '0')       # MUST be 0 until calibrated (see note above)
$vbs = $vbs.Replace('%%OUTPUT_FILE%%',     '{RUN}\import.json')
[IO.File]::WriteAllText('{RUN}\stms_import_run.vbs', $vbs, [System.Text.UnicodeEncoding]::new($false, $true))
```

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo "{RUN}\stms_import_run.vbs"
```

## W5 — Verify (RC) and report

After the import, read the RC via Logs Mode (`sap_stms_log_read.vbs`) — do NOT
trust the queue row. Map RC -> verdict (Logs Mode table). Register an import
evidence artifact for `/sap-evidence-pack` if the artifact lib is in use.

Report the TR, target, RC, verdict, and the next route hop (e.g. "imported to
QAS RC 4; next hop is PRD — re-run `/sap-stms import <TR> --to PRD` after QA
sign-off").

### Status line

```
STATUS: IMPORTED tr=<TR> target=<SID>/<client> rc=<0|4|8|12> verdict=<OK|OK_WITH_WARNINGS|ERROR|FATAL>
STATUS: QUEUED tr=<TR> target=<SID>            (scheduled, not yet run)
STATUS: ALREADY_IMPORTED tr=<TR> target=<SID>
STATUS: COULD_NOT_IMPORT reason=<no-auth|not-released|no-go|not-in-queue|not-calibrated|STMS_OPTION_UNSUPPORTED|verify-failed|queue-not-found>
STATUS: BLOCKED reason=<prod-not-confirmed|tr-not-released>
```

The import VBS exits **1** on every abort/error (`ABORTED` / `IMPORT_ERROR` in
`import.json`) and **0** only on `IMPORT_SUBMITTED`. Treat a non-zero exit (or an
`import.json` `result` other than `IMPORT_SUBMITTED`) as `COULD_NOT_IMPORT` — the
`detail` field carries the reason code (e.g. `STMS_OPTION_UNSUPPORTED`,
`verify-failed`, `not-in-queue`, `not-calibrated`).

---

# Import-All Mode (WRITE — double-gated)

Off unless `import-all --to <SID> --all` is given **and** the user double-confirms
(and types the SID for a PROD target). Imports the whole queue into the target.
Reuses W1–W5 over every queued TR; reports per-TR RC. Recommended only for
DEV/QA refresh — discourage for production (import individual TRs there).

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_stms_run.json" -Status SUCCESS -ExitCode 0
```

| Outcome | Status / ExitCode / ErrorClass |
|---|---|
| Imported, RC 0/4 | `-Status SUCCESS -ExitCode 0` |
| Status / logs read | `-Status SUCCESS -ExitCode 0` |
| Imported, RC 8/12 | `-Status FAILED -ExitCode 1 -ErrorClass STMS_IMPORT_RC_ERROR -ErrorMsg "rc=<n>"` |
| Blocked (not released / prod not confirmed) | `-Status SKIPPED -ExitCode 1 -ErrorClass STMS_BLOCKED` |
| No import authorization | `-Status SKIPPED -ExitCode 1 -ErrorClass STMS_NO_AUTH` |
| Import controls not calibrated | `-Status SKIPPED -ExitCode 1 -ErrorClass STMS_NOT_CALIBRATED` |

---

## Component IDs (for reference / recording)

| Element | Candidate ID | Note |
|---|---|---|
| OK code | `wnd[0]/tbar[0]/okcd` | stable |
| STMS Import Overview | okcd `/nSTMS_IMPORT` | system-overview list |
| Import queue grid/tree | `wnd[0]/usr/cntlCTRL_IMPORT_QUEUE/shellcont/shell` (candidate) | **RECORD** — varies by release |
| Import Request button | `PLACEHOLDER_IMPORT_BTN` | **RECORD** — destructive; PLACEHOLDER until calibrated |
| Import-options dialog | `PLACEHOLDER_OPTS_DIALOG` (target client / date tab / options tab) | **RECORD** |
| Confirm import | `PLACEHOLDER_OPTS_CONFIRM` | **RECORD** |
| Status bar | `wnd[0]/sbar` | `MessageType` for S/W/E |

## Known Issues / Failure Modes

| Symptom | Cause | Recovery |
|---|---|---|
| `COULD_NOT_IMPORT not-calibrated` | the import VBS PLACEHOLDER IDs are not yet recorded for this release | `/sap-gui-record` the STMS_IMPORT flow; replace `PLACEHOLDER_*` in `sap_stms_import.vbs` |
| `COULD_NOT_IMPORT no-auth` | dialog user lacks TMS import authorization (often Basis-gated) | run status/logs only, or have Basis import; this is expected in many shops |
| `BLOCKED tr-not-released` | TR is still modifiable (`E070-TRSTATUS != R`) | `/sap-se01 release <TR>` first |
| queue grid not found | STMS queue control ID drift | `/sap-gui-record` STMS_IMPORT; update the candidate in `sap_stms_queue_read.vbs` |
| row "done" but failures | RC 8/12 not surfaced in the row | always confirm via Logs Mode RC, never the row |

## Limitations

- **Read-first.** Status/logs are the most-used (and universally authorized)
  modes; import requires TMS auth that is frequently Basis-only.
- **Import VBS is recording-gated.** It ships as a fail-safe scaffold (PLACEHOLDER
  destructive IDs + mandatory row==TR verification); it does nothing until
  `/sap-gui-record`-calibrated. By design it cannot mis-import on an uncalibrated
  system.
- **Production import** is the most outward-facing action in the toolset — typed
  SID echo + second confirmation, always; no bypass flag.
- **RC is truth.** Verdicts come from the import RC (0/4/8/12), never the queue
  row's appearance.
- **No scheduling windows** in v1 (immediate / next-run only).
- **RFC queue read** (`TMS_MGR_READ_TRANSPORT_QUEUE`) is a documented Phase-2
  path; v1 reads the queue via GUI.

---

## Pipeline Integration

```
/sap-fix-incident (DEV fix) ─┐
                             ├─► /sap-transport-readiness <TR>  (GO/NO-GO)
                             └─►        └─► /sap-se01 release <TR>  (irreversible)
                                                  └─► /sap-stms import <TR> --to QAS ─► test ─► --to PRD
```

The skill that finally moves a change to QA / production — the last link in the
delivery chain. Release stays a deliberate `/sap-se01` step; this skill never
releases, and never imports without its gates.
