---
name: sap-transport-request
description: |
  Resolves a modifiable SAP transport request, applying the
  way_to_get_transport_request policy from sap-dev-core settings.json.
  This is the single entry point that all deploy skills (sap-se11, sap-se38,
  sap-se37, sap-se24, sap-se91) call when they need a TR — it centralises the
  DEFAULT / ASK / CREATE_NEW flow so callers never have to ask the user
  themselves. When a new TR is required, delegates creation to /sap-se01
  (GUI mode) or to its built-in RFC creator (CTS_API_CREATE_CHANGE_REQUEST).
  Honours rule_of_tr_description for the description text.
  Prerequisites: SAP NCo 3.1 (32-bit, .NET 4.0) installed in GAC.
argument-hint: "[transport-request-number] [OBJECT_TYPE=<...>] [OBJECT_DESCRIPTION=<...>]"
---

# SAP Transport Request Skill

You resolve a modifiable SAP transport request for the caller, applying the
`way_to_get_transport_request` policy from sap-dev-core `settings.json`.
This skill is the **single TR-resolution entry point** that all deploy skills
must use; they MUST NOT prompt the user for a TR or call `/sap-se01`
themselves.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules (no SQL writes on standard tables; no unsolicited deploys) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | Defines `way_to_get_transport_request`, `rule_of_tr_description`, the description placeholders, and the 60-char compression rules. **This skill IS the implementation of that rule.** |

---

## Step 0 — Resolve Work Directory

Read sap-dev-core's settings.json (go 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json`). Read `work_dir`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{WORK_TEMP}\sap_tr_run.json`. Best-effort. Honours `SAPDEV_PARENT_RUN_ID` env var so parent skill calls can be linked.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_tr_run.json" -Skill sap-transport-request -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments and Read Policy Settings

Parse `$ARGUMENTS`:

| Token | Meaning |
|---|---|
| A `<SID>K<digits>` token | Caller-supplied TR number override (rare; `DEFAULT`/`ASK` policies still apply on top) |
| `OBJECT_TYPE=<...>` | Object type the caller is deploying (`REPORT`, `TABLE`, `FM`, `CLASS`, `MSGCLASS`, …). Forwarded to `/sap-se01` for description rendering. |
| `OBJECT_DESCRIPTION=<...>` | Object name being deployed. Forwarded to `/sap-se01`. |

Read from sap-dev-core `settings.json` `userConfig`:

| Setting | Default if blank/unknown |
|---|---|
| `way_to_get_transport_request` | `DEFAULT` |
| `sap_dev_transport_request` | (blank) |
| `sap_dev_mode` | `GUI` |

Validate `way_to_get_transport_request`. Allowed: `DEFAULT`, `ASK`,
`CREATE_NEW`. Anything else → fall back to `DEFAULT` and warn the user.

---

## Step 1a — Apply the way_to_get_transport_request Policy

Pick a candidate TR per the table below, then proceed to Step 2 to verify it
(or to creation if "create new").

### `DEFAULT`

1. Candidate = `$ARGUMENTS` TR if supplied, else `sap_dev_transport_request`.
2. If candidate is blank → ask the user:
   > "No default transport request is set. Provide a modifiable TR number, or
   > type `new` to create one."
   - User supplies TR → candidate = that TR.
   - User types `new` → skip to **Create Path**.
3. Verify candidate (Step 2). If not modifiable, repeat the prompt above.
4. On success, **persist** the resolved TR to `sap_dev_transport_request` via
   `/update-config` (so future `DEFAULT` calls reuse it).

### `ASK`

1. Ignore `sap_dev_transport_request`.
2. Ask the user:
   > "Which transport request should I use? (TR number, or `new` to create one)"
   - TR number → candidate = that TR.
   - `new` → Create Path.
3. Verify candidate (Step 2). If not modifiable, repeat.
4. After success, ask once:
   > "Save `<TR>` as the default for future requests? (y/N)"
   - On `y` → persist to `sap_dev_transport_request`.

### `CREATE_NEW`

1. Do NOT read `sap_dev_transport_request`. Do NOT ask.
2. Go straight to **Create Path**.
3. Do NOT persist the new TR.

### Create Path

The Create Path is a **branching gate**. Pick exactly ONE branch based on
`sap_dev_mode`, execute it end-to-end, then return the resolved TR to the
caller. Do NOT fall through to Steps 2-4 from the GUI branch.

#### GUI branch (when `sap_dev_mode = GUI`, the default)

1. Invoke `/sap-se01` with the request type left to default (W) plus the
   forwarded `OBJECT_TYPE=` and `OBJECT_DESCRIPTION=` arguments.
   `/sap-se01` honours `rule_of_tr_description` for the text.
2. Capture the new TR number from `/sap-se01`'s output (`RESULT_TR:` line).
3. Apply the persistence policy from Step 1a (`DEFAULT` saves automatically;
   `ASK` asks once; `CREATE_NEW` does NOT save).
4. **STOP** — return the TR to the caller. Skip Steps 2-4 below entirely.
   Steps 2-4 are for the verification path (existing TR check) and the
   RFC/BDC create branch only; running them in GUI mode would either
   pointlessly RFC-verify a TR `/sap-se01` already verified, or worse,
   accidentally create a SECOND TR via the RFC creator.

#### RFC / BDC branch (when `sap_dev_mode` ∈ {`RFC`, `BDC`})

1. Build the description locally using the same `rule_of_tr_description`
   algorithm (see `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` §3).
2. Fall through to Steps 2-4 below — they use the RFC
   `CTS_API_CREATE_CHANGE_REQUEST` path. Pass `%%TR_INPUT%%` empty and
   `%%SAP_DEV_MODE%%` set to `RFC` (or `BDC`) so the PS1's guardrail
   permits creation.

### Mid-session policy change

If during a session the user explicitly says e.g. "switch to ask mode",
"always create new from now on", or "use the default TR every time", update
`way_to_get_transport_request` immediately via `/update-config` and follow
the new policy for the rest of the session.

---

## Step 2 — Read SAP Connection Parameters

Read SAP connection parameters from `$USER_CONFIG` (settings.json of sap-dev-core):

| Setting key | Maps to token | Example |
|---|---|---|
| `sap_application_server` | `%%SAP_APPLICATION_SERVER%%` | `10.0.0.1` |
| `sap_system_number` | `%%SAP_SYSTEM_NUMBER%%` | `00` |
| `sap_client` | `%%SAP_CLIENT%%` | `100` |
| `sap_user` | `%%SAP_USER%%` | `DEVELOPER` |
| `sap_password` | `%%SAP_PASSWORD%%` | *(masked)* |
| `sap_language` | `%%SAP_LANGUAGE%%` | `EN` |

**If settings are not configured**, ask the user to provide the values and suggest
they configure settings.json for future use:
> "SAP connection settings are not configured. Please provide the connection details,
> or configure them in sap-dev-core settings.json for automatic use."

---

## Step 3 — Generate and Run PowerShell

The PowerShell template is at `<SKILL_DIR>/references/sap_transport_request.ps1`.

Write `{WORK_TEMP}\sap_tr_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_transport_request.ps1', [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%SAP_APPLICATION_SERVER%%', 'THE_SERVER')
$content = $content.Replace('%%SAP_SYSTEM_NUMBER%%',      'THE_SYSNR')
$content = $content.Replace('%%SAP_CLIENT%%',             'THE_CLIENT')
$content = $content.Replace('%%SAP_USER%%',               'THE_USER')
$content = $content.Replace('%%SAP_PASSWORD%%',           'THE_PASSWORD')
$content = $content.Replace('%%SAP_LANGUAGE%%',           'THE_LANGUAGE')
$content = $content.Replace('%%RFC_LIB_PS1%%',            '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$content = $content.Replace('%%TRANSPORT_REQUEST%%',      'THE_TR')
$content = $content.Replace('%%SAP_DEV_MODE%%',           'THE_MODE')
[System.IO.File]::WriteAllText('{WORK_TEMP}\sap_tr_run.ps1', $content, [System.Text.Encoding]::UTF8)
Write-Host 'Done'
```
Replace all `THE_*` placeholders with actual values from Steps 1-2.
Replace `<SKILL_DIR>` with the absolute path to this skill directory.
Set `THE_TR` to the TR number from Step 1, or empty string `""` if none.
Set `THE_MODE` to the resolved `sap_dev_mode` value (`GUI` / `RFC` / `BDC`).
The PS1 has a guardrail: if `THE_TR` is empty (i.e. create path) AND
`THE_MODE` is `GUI`, the script refuses and exits with an error directing
the caller back to `/sap-se01`. This is intentional — it catches the case
where the dispatch in Step 1a Create Path was missed and the agent
accidentally runs the RFC creator under GUI mode.

Execute via **32-bit PowerShell** (SAP NCo 3.1 is registered in the 32-bit GAC):
```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_tr_run.ps1"
```

---

## Step 4 — Interpret Results

Parse the script output for `RESULT_TR:` and `RESULT_STATUS:` lines.

| RESULT_STATUS | Meaning | Action |
|---|---|---|
| `EXISTING_MODIFIABLE` | Provided TR is still modifiable | Report: "Transport request `<TR>` is modifiable and ready to use." Persistence per Step 1a (policy-driven). |
| `NEWLY_CREATED` | New TR was created | Report: "Created new transport request `<TR>`." Persistence per Step 1a: `DEFAULT` → save automatically; `ASK` → ask the user once; `CREATE_NEW` → do NOT save. Use `/update-config` to write `sap_dev_transport_request` when persisting. |
| `ERROR` | Something went wrong | Show full output and diagnose (see error table below). |

### Error Diagnosis

| Error | Cause | Fix |
|---|---|---|
| `NCo 3.1 not found in GAC_32` | SAP NCo 3.1 not installed for .NET 4.0 32-bit | Install SAP NCo 3.1 for .NET 4.0 (32-bit) per SAP Note |
| `RFC logon failed` | Wrong server/credentials | Check SAP connection parameters in settings.json |
| `TR_READ_REQUEST call exception` | FM not accessible or TR format wrong | Verify S_RFC authorization; check TR number format |
| `CTS_API_CREATE_CHANGE_REQUEST call failed` | Missing authorization or CTS not configured | Check S_CTS_ADMI and S_TRANSPRT authorizations |
| `returned empty request number` | TR created but number not returned | Check SE10 manually for recently created requests |

---

## Step 5 — Clean Up

```bash
cmd /c del "{WORK_TEMP}\sap_tr_run.ps1"
```

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_tr_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_tr_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `TR_RESOLUTION_FAILED`, `TR_NOT_MODIFIABLE`, `RFC_LOGON_FAILED`.

---

## Security Note

The generated `.ps1` file contains the SAP password in plain text. It is deleted
automatically after execution (Step 5). Connection parameters are stored in
settings.json. The password field is marked as `sensitive` and masked in the Claude Code UI.

---

## 32-bit Note

SAP NCo 3.1 is registered in the 32-bit GAC (`C:\Windows\Microsoft.NET\assembly\GAC_32`)
when installed for .NET 4.0 32-bit. Always execute via
`C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe` to ensure 32-bit assembly load.

---

## Important: Encoding

PowerShell scripts are written as UTF-8 (no BOM); NCo handles SAP unicode automatically.
