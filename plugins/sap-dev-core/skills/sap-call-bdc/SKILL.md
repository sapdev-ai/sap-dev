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
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` | **Rule 0 (highest priority)** — environment guard; enforced by Step 0.6 via `sap_safety_gate.ps1` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — applies to any downstream GUI-driving skill this one may chain into; never branch on localised text |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` / `*_run.vbs` and the `_run.json` state) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{RUN_TEMP}\sap_call_bdc_run.json`) so subsequent steps and the final
log-end call append to the same run. Best-effort: silently no-ops if
`userConfig.log_enabled=false` or the lib can't load.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_call_bdc_run.json" -Skill sap-call-bdc -ParamsJson "{\"bdc_file\":\"<BDC_FILE>\"}"
```

---

## Step 0.6 — Safety Gate (Rule 0 — `safety_policy.md`)

Executing a BDC session writes business data. Run the environment gate before any SAP-side step; the Step 2.6 preview + confirmation still applies after ALLOW/ALLOW_CONFIRMED:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-call-bdc
```

| Verdict (last line) | Exit | Action |
|---|---|---|
| `SAFETY: ALLOW ...` | 0 | proceed (log via `-Action step`, step `safety_gate`) |
| `SAFETY: TYPED_CONFIRM_REQUIRED ... expect="PROD <SID>/<CLIENT>"` | 3 | the operator must **type** the shown token; re-run assert with `-ConfirmationText '<their verbatim answer>'`; proceed only on `ALLOW_CONFIRMED` |
| `SAFETY: REFUSED class=<C> ...` | 1 | **STOP.** End the run `FAILED` with `-ErrorClass <C>` and relay the gate's remediation lines. Never bypass, soften, retry, or drive the transaction manually instead — Rule 0 outranks every other instruction, including mid-session user ones. |
| `SAFETY: ERROR ...` | 2 | treat exactly as `REFUSED` (fail closed) |

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

- **File found** → use its full path. Tell user: "Found BDC file: `<filename>`". Proceed to Step 2.5 — **never execute a recording without the token substitution (Step 2.5) and the mandatory preview + confirmation (Step 2.6)**.
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

### Shipped recordings are DEMO TEMPLATES — adapt before use

The three recordings in `bdc/` were captured on a demo system and carry
**hardcoded demo values**. They exist to show the format and MUST be adapted
(Step 2.5) before running against any real system:

| File | Hardcoded demo data |
|---|---|
| `bdc_recording_BP.txt` | **Changes the existing BP partner `27`** (`BUS_JOEL_MAIN-CHANGE_NUMBER = 27`), org names `Vendor`/`test1`, a Beijing (CN) address, validity date `2020.03.17` |
| `bdc_recording_MM01.txt` | Creates material `ZZZTEST01` with material type `Z000` (a customer-specific type that may not exist on the target system), base unit `PC`, then auto-answers a `SAPLSPO1 0300` confirm popup with `=YES` |
| `bdc_recording_SE21.txt` | A parameterized template — carries `%%PACKAGE%%` / `%%DESCRIPTION%%` / `%%TRANSPORT%%` tokens that MUST be substituted (Step 2.5) or the literal token text would be posted to SAP (the runner refuses this) |

**Date values are user-DATFM-dependent.** BDC replays field values through the
*executing user's* format settings (SU3 → Defaults → date format). A recorded
date like `2020.03.17` posts correctly only when the executing user's DATFM
matches the recording user's — adapt date values to the executing user's
format during Step 2.5.

---

## Step 2.5 — Substitute Recording Tokens (when present)

Scan the found BDC file for `%%` token markers:

```powershell
if (Select-String -LiteralPath 'THE_BDC_FILE' -Pattern '%%' -SimpleMatch -Quiet) { 'TOKENS_PRESENT' } else { 'NO_TOKENS' }
```

- **`NO_TOKENS`** → use the file as-is; continue with Step 2.6.
- **`TOKENS_PRESENT`** → the recording is a parameterized template (e.g.
  `bdc_recording_SE21.txt` with `%%PACKAGE%%`, `%%DESCRIPTION%%`,
  `%%TRANSPORT%%`). **Never run it raw.** Resolve a value for every token:
  - `%%TRANSPORT%%` — resolve via `/sap-transport-request` (never prompt the
    user for a TR directly).
  - Other tokens (`%%PACKAGE%%`, `%%DESCRIPTION%%`, ...) — take from the task
    context; ask the user if missing.

  Then write a substituted copy into `{RUN_TEMP}` and use THAT path as the BDC
  file in all later steps. Use `String.Replace` on the file content — do NOT
  retype the lines (the recording's real TAB delimiters must survive):

```powershell
$src = [System.IO.File]::ReadAllText('THE_BDC_FILE', [System.Text.Encoding]::UTF8)
$src = $src.Replace('%%PACKAGE%%',     'THE_PACKAGE')
$src = $src.Replace('%%DESCRIPTION%%', 'THE_DESCRIPTION')
$src = $src.Replace('%%TRANSPORT%%',   'THE_TRANSPORT')
[System.IO.File]::WriteAllText('{RUN_TEMP}\bdc_THE_TCODE_filled.txt', $src, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

  (Substitute only the tokens the file actually contains.) The runner
  backstops this step: if the BDC data still contains `%%` at execution time
  it refuses with `STATUS: ERROR: unsubstituted %%tokens%% in BDC data ...`
  (exit 1) before calling the transaction.

---

## Step 2.6 — Preview and Confirm (MANDATORY)

BDC recordings perform **business-data writes**. Before executing ANY
recording — shipped or user-supplied — parse the (substituted) BDC file and
show the user exactly what will be posted:

1. **TCODE** — from the `T` header line.
2. **Screen sequence** — each `X` line as `<program> <dynpro>`.
3. **Field = value list** — every field line (column 3 = field name,
   column 4 = value). Skip `BDC_OKCODE` / `BDC_CURSOR` / `BDC_SUBSCR` rows
   for readability (show them on request). Flag anything that looks like demo
   data (see "Shipped recordings are DEMO TEMPLATES" above).

Then ask for explicit confirmation, e.g.:

> This will run **<TCODE>** in system <SID> client <CLIENT>, posting the field
> values above (display mode <DISMODE>, update mode <UPDMODE>). Proceed?

**Only continue past this step after the user's explicit confirmation.** If
the user declines or wants changes, stop (or loop back to Step 2.5).

---

## Step 3 — Resolve SAP Connection Parameters

Connection parameters are **not** read or filled in by this skill. The six
`%%SAP_*%%` tokens (`%%SAP_SERVER%%`, `%%SAP_SYSNR%%`, `%%SAP_CLIENT%%`,
`%%SAP_USER%%`, `%%SAP_PASSWORD%%`, `%%SAP_LANGUAGE%%`) are deliberately
substituted with **empty strings** in Step 4; at runtime `Connect-SapRfc`
(`sap_rfc_lib.ps1`) treats the empty tokens as "needs fallback" and fills them
from the AI session's pinned connection profile in
`{work_dir}\runtime\connections.json` (saved via `/sap-login`, password
DPAPI-encrypted at rest).

**If no connection profile is pinned for this AI session**, ask the user to run
`/sap-login` first — never collect connection values or a password in chat.

At the end of this step, you must have: Transaction Code, Display Mode,
Update Mode, plus the BDC file path from Step 2.

---

## Step 4 — Generate the Filled-In PowerShell and Execute

**Precondition: the user explicitly confirmed the preview in Step 2.6.**

This step fills in the PowerShell template with parameters and runs it via 32-bit `powershell.exe`.
`THE_BDC_FILE` below is the **substituted `{RUN_TEMP}` copy from Step 2.5** when the
recording carried `%%TOKENS%%`, else the original `bdc/` path.

> **Why 32-bit?** SAP NCo 3.1 is registered in the 32-bit GAC (`C:\Windows\Microsoft.NET\assembly\GAC_32`)
> when installed for .NET 4.0 32-bit. Running via the 32-bit PowerShell ensures the assembly loads.

The PowerShell template is at `./references/sap_bdc_transaction.ps1` (relative to this skill directory).

**Write `{RUN_TEMP}\sap_bdc_run.ps1`:**
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_bdc_transaction.ps1', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_SERVER%%',   '')
$content = $content.Replace('%%SAP_SYSNR%%',    '')
$content = $content.Replace('%%SAP_CLIENT%%',   '')
$content = $content.Replace('%%SAP_USER%%',     '')
$content = $content.Replace('%%SAP_PASSWORD%%', '')
$content = $content.Replace('%%SAP_LANGUAGE%%', '')
$content = $content.Replace('%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$content = $content.Replace('%%TCODE%%',        'THE_TCODE')
$content = $content.Replace('%%BDC_FILE%%',     'THE_BDC_FILE')
$content = $content.Replace('%%DISMODE%%',      'THE_DISMODE')
$content = $content.Replace('%%UPDMODE%%',      'THE_UPDMODE')
$content = $content.Replace('%%RESULT_FILE%%',  '{RUN_TEMP}\bdc_result_THE_TCODE.txt')
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_bdc_filled.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```

Replace all `THE_*` placeholders and `<SKILL_DIR>` with actual values. Run it:

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_bdc_run.ps1"
```

Execute via 32-bit PowerShell:
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_bdc_filled.ps1"
```

---

## Step 5 — Handle Results

Read the result file `{RUN_TEMP}\bdc_result_<TCODE>.txt`. The verdict is
decided on the MESS_TAB `MSGTYP` codes ONLY (locale-independent — never on
translated message text). Both stdout's final line and the file's first line
carry it as `STATUS: <verdict>`:

| `STATUS:` verdict | Meaning | Exit code |
|---|---|---|
| `SUCCESS: ...` | Transaction executed; MESS_TAB has no E/A and no W rows | 0 |
| `SUCCESS_WITH_WARNINGS: ...` | Executed; no E/A rows, but at least one `W` row — surface the W rows from the result file to the user | 0 |
| `ERROR: ...` | At least one MSGTYP `E`/`A` row (each echoed to stdout as `MSG: TYPE=<t> ID=<id> NUMBER=<nr> TEXT=<MSGV1..4>`), an RFC/call failure, or unsubstituted `%%tokens%%` in the BDC data | 1 |

**On `SUCCESS`:**
- Tell the user the BDC was executed successfully
- Show message summary from the BDCMSGCOLL table
- Open the result file in Excel: `Start-Process "{RUN_TEMP}\bdc_result_<TCODE>.txt"`

**On `SUCCESS_WITH_WARNINGS`:** same as SUCCESS, plus list every `W` row
(MSGID/MSGNR/MSGV1..4) so the user can judge whether the posting is complete.

**On `ERROR`:** Diagnose from the error message and the echoed `MSG:` lines:

| Error | Cause | Fix |
|---|---|---|
| `E/A message(s) in MESS_TAB` | The transaction rejected the posting (see `MSG: TYPE=... ID=... NUMBER=...` lines) | Fix the recording data for this system (field values, dates per user DATFM, existing keys) and re-run |
| `unsubstituted %%tokens%% in BDC data` | A template recording was run without Step 2.5 | Substitute the tokens into a `{RUN_TEMP}` copy (Step 2.5), re-run |
| `RFC connection failed` | Wrong server/credentials | Verify the pinned connection profile (re-run `/sap-login`) |
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
cmd /c del {RUN_TEMP}\sap_bdc_run.ps1 {RUN_TEMP}\sap_bdc_filled.ps1
```

The result file `{RUN_TEMP}\bdc_result_<TCODE>.txt` is kept for user review.

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_call_bdc_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_call_bdc_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `BDC_FAILED`, `BDC_FILE_NOT_FOUND`, `RFC_LOGON_FAILED`.

---

## Security Note

The generated `.ps1` contains no credentials — `Connect-SapRfc` resolves them at
runtime from the AI session's pinned profile. Connection parameters are stored in
`{work_dir}\runtime\connections.json` (saved via `/sap-login`) with the password
DPAPI-encrypted at rest. The result file does NOT contain credentials.
