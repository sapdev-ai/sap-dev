---
name: sap-call-bdc
description: |
  Executes BDC (Batch Data Communication) sessions in SAP via RFC.
  Reads SHDB recording files from the bdc/ folder, connects via
  SAP NCo 3.1, calls ABAP4_CALL_TRANSACTION, and outputs
  full BDCMSGCOLL messages to a result file.
  Connection parameters resolved from the AI session's pinned profile in
  connections.json (saved via /sap-login).
  Prerequisites: SAP profile saved via /sap-login (RFC password required).
  SAP NCo 3.1 (32-bit, .NET 4.0) in GAC.
argument-hint: "<transaction-code> [<display-mode>] [<update-mode>]"
---

# SAP Call BDC Skill

You execute a BDC session in SAP by reading an SHDB recording file and calling the
transaction via RFC.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — applies to any downstream GUI-driving skill this one may chain into; never branch on localised text |

---

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `work_dir`, `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{WORK_TEMP}\sap_call_bdc_run.json`) so subsequent steps and the final
log-end call append to the same run. Best-effort: silently no-ops if
`userConfig.log_enabled=false` or the lib can't load.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_call_bdc_run.json" -Skill sap-call-bdc -ParamsJson "{\"bdc_file\":\"<BDC_FILE>\"}"
```

---

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:
- **Transaction code** — required (e.g., `MM01`, `BP`, `SE38`)
- **Display mode** — optional. Default `N`.
  - `A` = display all screens
  - `E` = display errors only
  - `N` = no display (default)
  - `P` = background processing
- **Update mode** — optional. Default `S`.
  - `A` = asynchronous
  - `S` = synchronous (default)
  - `L` = local (no update task)

If no transaction code is provided, ask the user for it.

---

## Step 2 — Find the BDC File

BDC files are stored in the plugin's `bdc/` folder (relative to this skill directory: `./bdc/`).

Search for a file whose name **starts with the transaction code** (case-insensitive):

```powershell
$tcode = "THE_TCODE"
$bdcDir = "<SKILL_DIR>\bdc"
$bdcFile = Get-ChildItem -Path $bdcDir -Filter "$tcode*" -File | Select-Object -First 1
if ($bdcFile) {
    Write-Output $bdcFile.FullName
} else {
    Write-Output "NOT_FOUND"
}
```

Replace `THE_TCODE` with the actual transaction code and `<SKILL_DIR>` with the absolute path
to this skill directory.

- **File found** → use its full path. Tell user: "Found BDC file: `<filename>`". Proceed to Step 3.
- **Not found** → tell user: "No BDC file found starting with `<tcode>` in the bdc/ folder."
  Offer to help create one (see BDC File Format below). **Stop here.**

### BDC File Format (SHDB Recording)

The skill uses **SAP SHDB recording format** — the native format downloaded from transaction SHDB.

To create a BDC file:
1. Run transaction **SHDB** in SAP GUI
2. Click **New Recording**, enter a recording name and the transaction code
3. Perform the transaction steps as needed
4. When done, go back to SHDB, select the recording, and click **Download**
5. Save the file as `<TCODE>_<description>.txt` in the `bdc/` folder

The file is **tab-delimited** with fixed-width columns:

| Column | Width | Content |
|---|---|---|
| 0 | 40 | Program name (screen records) or spaces (field records) |
| 1 | 4 | Dynpro number (screen records) or `0000` (field records) |
| 2 | 1 | `T` = transaction header, `X` = screen start, space = field |
| 3 | 120+ | Transaction code (T lines), empty (X lines), or field name |
| 4 | varies | Flags (T lines), empty (X lines), or field value |

---

## Step 3 — Read SAP Connection Parameters

Read SAP connection parameters from the merged sap-dev-core settings (per `shared/rules/settings_lookup.md` — `settings.local.json` overrides `settings.json` per-key on the `.value` field):

| Setting key | Maps to | Example |
|---|---|---|
| `sap_application_server` | `%%SAP_SERVER%%` | `10.0.0.1` |
| `sap_system_number` | `%%SAP_SYSNR%%` | `00` |
| `sap_client` | `%%SAP_CLIENT%%` | `100` |
| `sap_user` | `%%SAP_USER%%` | `DEVELOPER` |
| `sap_password` | `%%SAP_PASSWORD%%` | *(masked)* |
| `sap_language` | `%%SAP_LANGUAGE%%` | `EN` |

**If settings are not configured**, ask the user to provide the values and suggest
they configure settings.json for future use.

At the end of this step, you must have all 9 values: Server, SysNr, Client, User, Password,
Language, Transaction Code, Display Mode, Update Mode, plus the BDC file path from Step 2.

---

## Step 4 — Generate the Filled-In PowerShell and Execute

This step fills in the PowerShell template with parameters and runs it via 32-bit `powershell.exe`.

> **Why 32-bit?** SAP NCo 3.1 is registered in the 32-bit GAC (`C:\Windows\Microsoft.NET\assembly\GAC_32`)
> when installed for .NET 4.0 32-bit. Running via the 32-bit PowerShell ensures the assembly loads.

The PowerShell template is at `./references/sap_bdc_transaction.ps1` (relative to this skill directory).

**Write `{WORK_TEMP}\sap_bdc_run.ps1`:**
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_bdc_transaction.ps1', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_SERVER%%',   'THE_SERVER')
$content = $content.Replace('%%SAP_SYSNR%%',    'THE_SYSNR')
$content = $content.Replace('%%SAP_CLIENT%%',   'THE_CLIENT')
$content = $content.Replace('%%SAP_USER%%',     'THE_USER')
$content = $content.Replace('%%SAP_PASSWORD%%', 'THE_PASSWORD')
$content = $content.Replace('%%SAP_LANGUAGE%%', 'THE_LANGUAGE')
$content = $content.Replace('%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$content = $content.Replace('%%TCODE%%',        'THE_TCODE')
$content = $content.Replace('%%BDC_FILE%%',     'THE_BDC_FILE')
$content = $content.Replace('%%DISMODE%%',      'THE_DISMODE')
$content = $content.Replace('%%UPDMODE%%',      'THE_UPDMODE')
$content = $content.Replace('%%RESULT_FILE%%',  '{WORK_TEMP}\bdc_result_THE_TCODE.txt')
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_bdc_filled.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Replace all `THE_*` placeholders and `<SKILL_DIR>` with actual values. Run it:

```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_bdc_run.ps1"
```

Execute via 32-bit PowerShell:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_bdc_filled.ps1"
```

---

## Step 5 — Handle Results

Read the result file `{WORK_TEMP}\bdc_result_<TCODE>.txt`.

**On success** (output contains `STATUS: SUCCESS:`):
- Tell the user the BDC was executed successfully
- Show message summary from the BDCMSGCOLL table
- Open the result file in Excel: `Start-Process "{WORK_TEMP}\bdc_result_<TCODE>.txt"`

**On failure** (output contains `STATUS: ERROR:`): Diagnose from the error message:

| Error | Cause | Fix |
|---|---|---|
| `RFC connection failed` | Wrong server/credentials | Verify SAP connection details in settings.json |
| `NCo 3.1 not found in GAC_32` | SAP NCo 3.1 not installed for .NET 4.0 32-bit | Install SAP NCo 3.1 for .NET 4.0 (32-bit) per SAP Note |
| `BDC file not found` | File path wrong or moved | Verify BDC file exists in `bdc/` folder |
| `No valid BDC records` | Malformed SHDB file | Re-download from SHDB transaction |
| `Call exception` / `Call failed` | BDC data incorrect or auth issue | Check S_RFC and S_TCODE authorization; review SHDB recording |

### BDCMSGCOLL Output Fields

The result file contains all 13 fields of the BDCMSGCOLL structure:

| Field | Type | Description |
|---|---|---|
| TCODE | CHAR 20 | Transaction code |
| DYNAME | CHAR 40 | Program name of the BDC screen |
| DYNUMB | CHAR 4 | Screen number |
| MSGTYP | CHAR 1 | Message type: S(uccess), E(rror), W(arning), I(nfo), A(bort) |
| MSGSPRA | LANG 1 | Message language |
| MSGID | CHAR 20 | Message class |
| MSGNR | CHAR 3 | Message number |
| MSGV1 | CHAR 50 | Message variable 1 |
| MSGV2 | CHAR 50 | Message variable 2 |
| MSGV3 | CHAR 50 | Message variable 3 |
| MSGV4 | CHAR 50 | Message variable 4 |
| ENV | CHAR 4 | Environment (blank = online) |
| FLDNAME | CHAR 132 | Field name causing the message |

---

## Step 6 — Clean Up

```bash
cmd /c del {WORK_TEMP}\sap_bdc_run.ps1 {WORK_TEMP}\sap_bdc_filled.ps1
```

The result file `{WORK_TEMP}\bdc_result_<TCODE>.txt` is kept for user review.

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_call_bdc_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_call_bdc_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `BDC_FAILED`, `BDC_FILE_NOT_FOUND`, `RFC_LOGON_FAILED`.

---

## Security Note

The generated `.ps1` file contains the SAP password in plain text. It is deleted
automatically after execution. The result file does NOT contain credentials.
Connection parameters are stored in settings.json. The password field is marked as
`sensitive` and masked in the Claude Code UI.
