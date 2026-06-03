---
name: sap-sm13
description: |
  /sap-diagnose reader: update-task failure evidence from SM13 (tables VBHDR +
  VBERROR) via RFC. Read-only. Surfaces failed asynchronous updates — the classic
  "the document didn't post but no error appeared on screen" incident — joining
  the failing update function module and message from VBERROR. Emits the shared
  diagnose evidence contract. Usually invoked by /sap-diagnose; runs standalone.
  Prerequisites: a saved profile via /sap-login (RFC password); SAP NCo 3.1
  (32-bit, .NET 4.0) in GAC.
argument-hint: "[--anchor PATH] [--user U] [--date today|YYYYMMDD] [--window MIN] [--out PATH] [--top-n N]"
---

# SAP SM13 Update-Failure Reader (Diagnose)

You read update-task headers (VBHDR) over RFC, join VBERROR by VBKEY, and emit
one evidence event per update record (failed ones flagged severity E). Read-only.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo connect; pinned-profile cred fallback when tokens left literal. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_diagnose_reader_lib.ps1` | `%%DIAG_READER_LIB_PS1%%` | Shared reader helpers. |
| `<SKILL_DIR>/references/sap_sm13_read.ps1` | *(reader)* | VBHDR + VBERROR reader. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(lib)* | start/end logging. |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```
Set `{WORK_TEMP}` / `{RUN_DIR}` as in `/sap-sm37`.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_sm13_run.json" -Skill sap-sm13 -ParamsJson "{}"
```

## Step 1 — Resolve the Anchor
`--anchor <path>` (orchestrator) or build `{RUN_DIR}\anchor.json` from flags. See `/sap-sm37` Step 1.

## Step 2 — Run the Reader (32-bit PowerShell)

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$ps = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_sm13_read.ps1', [Text.Encoding]::UTF8)
$ps = $ps.Replace('%%RFC_LIB_PS1%%',         "$shared\sap_rfc_lib.ps1")
$ps = $ps.Replace('%%DIAG_READER_LIB_PS1%%', "$shared\sap_diagnose_reader_lib.ps1")
[IO.File]::WriteAllText('{RUN_DIR}\sm13_run.ps1', $ps, (New-Object Text.UTF8Encoding($false)))
```

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_DIR}\sm13_run.ps1" -AnchorJson "{RUN_DIR}\anchor.json" -OutFile "{RUN_DIR}\evidence_sm13.json"
```

## Step 3 — Report
Summarize total update records and `failed_updates=` from the `EVIDENCE:` line.

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_sm13_run.json" -Status SUCCESS -ExitCode 0
```

## Known Issues
- **Date precision.** VBHDR carries `VBDATE` but no sub-second time, so SM13
  events are date-precision. Correlation relies on the engine's `context` edge
  (same day + user + program/tcode) and business keys, not the tight window.
- **N+1 VBERROR lookup.** One VBERROR read per VBHDR row; `--top-n` (default 100)
  bounds it. Narrow the window for busy systems.
- **Reprocess is gated.** Reprocessing an update is a write; this reader never
  does it — `/sap-diagnose --remediate` proposes the command for confirmation.
