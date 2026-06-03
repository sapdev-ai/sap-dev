---
name: sap-st22
description: |
  /sap-diagnose reader: ABAP runtime-error (short dump) evidence from ST22 in
  GUI mode (ADT is NOT used). SNAP is a cluster table, so dumps are read by
  driving ST22 via SAP GUI Scripting. Read-only: sets the date/user selection,
  displays the dump list, and scrapes it into the shared diagnose evidence
  contract. Deep per-dump extraction (call stack / variables) is a v2
  enhancement. Usually invoked by /sap-diagnose; runs standalone.
  Component IDs for the ST22 selection/grid vary by release — the reader tries
  candidates and degrades to a clean 'skipped' with a /sap-gui-record hint if it
  cannot locate the list (same policy as /sap-atc).
  Prerequisites: active SAP GUI session (use /sap-login first); RZ11
  sapgui/user_scripting = TRUE.
argument-hint: "[--anchor PATH] [--user U] [--date today|YYYYMMDD] [--window MIN] [--session PATH] [--out PATH] [--top-n N]"
---

# SAP ST22 Dump Reader (Diagnose, GUI)

You drive ST22 read-only, display the dump list for the incident window, and
emit one evidence event per dump. GUI mode — no ADT.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | Address controls by ID; status via MessageType; VKey navigation; no text branching. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_attach_lib.vbs` | `%%ATTACH_LIB_VBS%%` | Parallel-safe session attach (`AttachSapSession`). |
| `<SKILL_DIR>/references/sap_st22_read.vbs` | *(reader)* | ST22 navigation + dump-list scrape → evidence JSON. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(lib)* | start/end logging. |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```
Set `{WORK_TEMP}` / `{RUN_DIR}` as in `/sap-sm37`.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_st22_run.json" -Skill sap-st22 -ParamsJson "{}"
```

## Step 1 — Resolve the Anchor + Build the Params File

`--anchor <path>` (orchestrator) or build `{RUN_DIR}\anchor.json` from flags.
Derive the ST22 params file from the anchor:

```powershell
$a = Get-Content '{RUN_DIR}\anchor.json' -Raw | ConvertFrom-Json
$from = "$($a.window.from_ts)"; $to = "$($a.window.to_ts)"
@(
  "FROMDATE=" + $from.Substring(0,8),
  "TODATE="   + $to.Substring(0,8),
  "USER="     + "$($a.user)",
  "TOPN=200"
) | Set-Content '{RUN_DIR}\st22_params.txt' -Encoding Default
```

## Step 2 — Run the Reader (32-bit cscript)

Substitute the attach tokens + IO paths. Set `SAPDEV_SESSION_PATH` so the
attach helper targets this AI session's pinned connection (per the parallel-safe
attach contract).

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
. "$shared\sap_connection_lib.ps1"
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
$vbs = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_st22_read.vbs', [Text.Encoding]::UTF8)
$vbs = $vbs.Replace('%%ATTACH_LIB_VBS%%', "$shared\sap_attach_lib.vbs")
$vbs = $vbs.Replace('%%SESSION_PATH%%',   '')   # or the --session value
$vbs = $vbs.Replace('%%PARAMS_FILE%%',    '{RUN_DIR}\st22_params.txt')
$vbs = $vbs.Replace('%%OUTPUT_FILE%%',    '{RUN_DIR}\evidence_st22.json')
[IO.File]::WriteAllText('{RUN_DIR}\st22_run.vbs', $vbs, [Text.Encoding]::Unicode)
```

```bash
C:\Windows\SysWOW64\cscript.exe //NoLogo "{RUN_DIR}\st22_run.vbs"
```

(32-bit `cscript` is mandatory — SAP GUI Scripting COM is 32-bit. Never `cmd /c`.)

## Step 3 — Report
Parse `EVIDENCE: source=ST22 ...` + `evidence_st22.json`. If `status=skipped`,
report the reason (likely "grid not found — run /sap-gui-record on ST22").

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_st22_run.json" -Status SUCCESS -ExitCode 0
```

## Known Issues / Failure Modes
- **Recording debt.** ST22 selection-field + result-grid IDs vary by release. The
  reader tries candidate IDs then scans for the grid; if it cannot locate the
  list it emits `status=skipped` with a hint to run `/sap-gui-record` on ST22 and
  update the candidates in `sap_st22_read.vbs`.
- **List-level only (v1).** Emits date/time/user/program/exception/short-text +
  a synthetic `dump_key` (date+time+program) so SM13 can link to it. Call-stack
  and variable extraction (opening each dump) is a v2 enhancement.
- **Requires an active GUI session** and `sapgui/user_scripting = TRUE`.
- **Modal SAP GUI Security dialog** suspends scripting; if a file-IO dialog
  appears, the orchestrator's sidecar pattern applies (this reader does no file
  IO inside SAP, so it normally won't trigger it).
