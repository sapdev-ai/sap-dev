---
name: sap-sm12
description: |
  /sap-diagnose reader: lock-entry evidence from SM12 via the ENQUEUE_READ
  function module (the enqueue table is in memory — never RFC_READ_TABLE on
  SEQG3). Read-only. Emits one evidence event per lock in the window. If
  ENQUEUE_READ is not RFC-enabled on the target system, the reader records a
  clean 'skipped' and suggests the Z_GENERIC_RFC_WRAPPER_TBL route. Usually
  invoked by /sap-diagnose; runs standalone.
  Prerequisites: a saved profile via /sap-login (RFC password); SAP NCo 3.1
  (32-bit, .NET 4.0) in GAC.
argument-hint: "[--anchor PATH] [--user U] [--date today|YYYYMMDD] [--window MIN] [--out PATH] [--top-n N]"
---

# SAP SM12 Lock Reader (Diagnose)

You read the live enqueue table via ENQUEUE_READ and emit one evidence event per
lock in the window. Read-only.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo connect; pinned-profile cred fallback. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_diagnose_reader_lib.ps1` | `%%DIAG_READER_LIB_PS1%%` | Shared reader helpers. |
| `<SKILL_DIR>/references/sap_sm12_read.ps1` | *(reader)* | ENQUEUE_READ → SEQG3 reader. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(lib)* | start/end logging. |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```
Set `{WORK_TEMP}` / `{RUN_DIR}` as in `/sap-sm37`.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_sm12_run.json" -Skill sap-sm12 -ParamsJson "{}"
```

## Step 1 — Resolve the Anchor
`--anchor <path>` (orchestrator) or build `{RUN_DIR}\anchor.json` from flags.

## Step 2 — Run the Reader (32-bit PowerShell)

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$ps = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_sm12_read.ps1', [Text.Encoding]::UTF8)
$ps = $ps.Replace('%%RFC_LIB_PS1%%',         "$shared\sap_rfc_lib.ps1")
$ps = $ps.Replace('%%DIAG_READER_LIB_PS1%%', "$shared\sap_diagnose_reader_lib.ps1")
[IO.File]::WriteAllText('{RUN_DIR}\sm12_run.ps1', $ps, (New-Object Text.UTF8Encoding($false)))
```

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_DIR}\sm12_run.ps1" -AnchorJson "{RUN_DIR}\anchor.json" -OutFile "{RUN_DIR}\evidence_sm12.json"
```

## Step 3 — Report
Summarize `locks=` (or the `skipped` reason if ENQUEUE_READ is not RFC-callable).

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_sm12_run.json" -Status SUCCESS -ExitCode 0
```

## Known Issues
- **ENQUEUE_READ RFC availability** varies by system. On failure the reader emits
  `skipped` (orchestrator continues) with a hint to read locks via the generic
  wrapper FM `Z_GENERIC_RFC_WRAPPER_TBL`.
- **Lock argument → business key.** `GARG` (client + key) is captured as
  `object_keys.LOCKARG`; it correlates lock-to-lock but is not decoded into a
  named business key.
- **Releasing a lock is gated.** This reader never dequeues; `/sap-diagnose
  --remediate` proposes the command for confirmation.
