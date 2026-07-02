---
name: sap-slg1
description: |
  /sap-diagnose reader: application-log evidence from SLG1 (table BALHDR) via RFC.
  Read-only. Surfaces logs carrying problems (Abort/Error/Warning message counts)
  in the incident window — this is where standard and custom processes (goods
  movement, billing, interfaces) record the business-level failure reason. Emits
  the shared diagnose evidence contract. Usually invoked by /sap-diagnose; runs
  standalone.
  Prerequisites: a saved profile via /sap-login (RFC password); SAP NCo 3.1
  (32-bit, .NET 4.0) in GAC.
argument-hint: "[--anchor PATH] [--user U] [--date today|YYYYMMDD] [--window MIN] [--out PATH] [--top-n N]"
---

# SAP SLG1 Application-Log Reader (Diagnose)

You read application-log headers (BALHDR) over RFC and emit one evidence event
per problem-bearing log in the window. Read-only.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo connect; pinned-profile cred fallback. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_diagnose_reader_lib.ps1` | `%%DIAG_READER_LIB_PS1%%` | Shared reader helpers. |
| `<SKILL_DIR>/references/sap_slg1_read.ps1` | *(reader)* | BALHDR reader. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(lib)* | start/end logging. |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```
Set `{WORK_TEMP}` / `{RUN_DIR}` as in `/sap-sm37`.

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_slg1_run.json" -Skill sap-slg1 -ParamsJson "{}"
```

## Step 1 — Resolve the Anchor
`--anchor <path>` (orchestrator) or build `{RUN_DIR}\anchor.json` from flags.

## Step 2 — Run the Reader (32-bit PowerShell)

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$ps = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_slg1_read.ps1', [Text.Encoding]::UTF8)
$ps = $ps.Replace('%%RFC_LIB_PS1%%',         "$shared\sap_rfc_lib.ps1")
$ps = $ps.Replace('%%DIAG_READER_LIB_PS1%%', "$shared\sap_diagnose_reader_lib.ps1")
[IO.File]::WriteAllText('{RUN_DIR}\slg1_run.ps1', $ps, (New-Object Text.UTF8Encoding($false)))
```

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_DIR}\slg1_run.ps1" -AnchorJson "{RUN_DIR}\anchor.json" -OutFile "{RUN_DIR}\evidence_slg1.json"
```

## Step 3 — Report
Summarize `problem_logs=` from the `EVIDENCE:` line.

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_slg1_run.json" -Status SUCCESS -ExitCode 0
```

## Known Issues
- **Header-level only (v1).** BALDAT (message text) is a cluster table; v1 reads
  BALHDR (object/subobject/extnumber/time/user + per-severity message counts),
  which already localizes the failure. Message-text drill-down via the BAL_* API
  (through the generic wrapper) is a v2 enhancement.
- **Business key.** `EXTNUMBER` is captured as `object_keys.EXTNUMBER` when short
  enough — it often holds the document number, enabling business-key correlation.
- Only logs with Abort/Error/Warning counts > 0 are emitted (pure-info logs are
  skipped to reduce noise).
