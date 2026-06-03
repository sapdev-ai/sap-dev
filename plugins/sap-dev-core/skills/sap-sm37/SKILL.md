---
name: sap-sm37
description: |
  /sap-diagnose reader: background-job evidence from SM37 (table TBTCO) via RFC.
  Read-only. Lists jobs in an incident window (aborted jobs flagged), emitting
  the shared diagnose evidence contract. Usually invoked by /sap-diagnose, but
  runs standalone too. Aborted ("cancelled") jobs are the high-signal events.
  Prerequisites: a saved profile via /sap-login (RFC password); SAP NCo 3.1
  (32-bit, .NET 4.0) in GAC.
argument-hint: "[--anchor PATH] [--job NAME] [--user U] [--date today|YYYYMMDD] [--window MIN] [--out PATH] [--top-n N]"
---

# SAP SM37 Job Reader (Diagnose)

You read background-job status from TBTCO over RFC and emit one evidence event
per job in the window. Read-only.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo connect + RFC_READ_TABLE guard. Resolves creds from the pinned profile when cred tokens are left literal (Phase 4.3). |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_diagnose_reader_lib.ps1` | `%%DIAG_READER_LIB_PS1%%` | Shared reader helpers (anchor, read-table, evidence emit). |
| `<SKILL_DIR>/references/sap_sm37_read.ps1` | *(reader)* | The TBTCO reader (TopN-capped; truncation flagged). |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(lib)* | start/end logging. |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```
Set `{WORK_TEMP}` = `{work_dir}\temp`; `{RUN_DIR}` = a fresh `{WORK_TEMP}\diagnose\<run>` (or the orchestrator's run dir when `--anchor` points into it).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_sm37_run.json" -Skill sap-sm37 -ParamsJson "{}"
```

## Step 1 — Resolve the Anchor

If `--anchor <path>` is supplied (orchestrator flow), use it. Otherwise build
`{RUN_DIR}\anchor.json` from `--user`/`--date`/`--time`/`--window`/`--job`
(shape: `diagnose_evidence_schema.json` anchor — `{ window:{from_ts,to_ts}, user,
client, job, ... }`). For server-accurate windows prefer `/sap-diagnose`, which
resolves the window against the SAP server clock.

## Step 2 — Run the Reader (32-bit PowerShell)

Substitute only the two library paths; leave the `%%SAP_*%%` credential tokens
literal so `Connect-SapRfc` fills them from the pinned connection profile.

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$ps = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_sm37_read.ps1', [Text.Encoding]::UTF8)
$ps = $ps.Replace('%%RFC_LIB_PS1%%',         "$shared\sap_rfc_lib.ps1")
$ps = $ps.Replace('%%DIAG_READER_LIB_PS1%%', "$shared\sap_diagnose_reader_lib.ps1")
[IO.File]::WriteAllText('{RUN_DIR}\sm37_run.ps1', $ps, (New-Object Text.UTF8Encoding($false)))
```

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_DIR}\sm37_run.ps1" -AnchorJson "{RUN_DIR}\anchor.json" -OutFile "{RUN_DIR}\evidence_sm37.json"
```

## Step 3 — Report

Parse the `EVIDENCE: source=SM37 ...` line and `evidence_sm37.json`. Summarize
job count, aborted count, and `truncated`. In the orchestrator flow this file is
consumed by `sap_diagnose_correlate.ps1`.

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_sm37_run.json" -Status SUCCESS -ExitCode 0
```

## Known Issues
- TBTCO STATUS codes: `A`=aborted/cancelled → severity A; `F`=finished → S;
  `R`=active → I. Job-log message drill-down (`BP_JOBLOG_READ`) is a v2
  enhancement; MVP surfaces status + program + time.
- Reads cap at `--top-n` (default 200) and flag `truncated` — never silent.
