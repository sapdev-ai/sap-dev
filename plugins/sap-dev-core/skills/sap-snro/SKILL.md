---
name: sap-snro
description: |
  Creates, maintains, and manages SAP Number Range Objects (NRO) via SNRO using
  SAP GUI Scripting. Number Range Objects are crucial for generating unique
  identifiers for SAP master data and document numbers (e.g. material numbers,
  document numbers, custom Z document IDs). Supports existence check, create
  new NRO with short text / long text / domain (number length) / warning
  percentage, update header attributes, and maintain number range intervals
  (sub-objects with FROMNUMBER / TONUMBER / current number / external flag).
  Handles the package + transport request popup (3-way pattern: explicit TR,
  $TMP local object, or new transport).
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<nro-name> [short-text] [domain] [warn-pct] [intervals-file]"
---

# SAP SNRO Number Range Object Maintenance Skill

You create, update and maintain SAP Number Range Objects (NRO) and their
intervals via SNRO using SAP GUI Scripting. The skill checks if the NRO
exists, then creates or updates it. Optionally maintains number range
intervals (sub-objects) via the same NRO.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution flow — this skill delegates to `/sap-transport-request` (Step 1b) |

---

## Step 0 — Resolve Work Directory

Read sap-dev-core's settings.json (go 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json`). Read `work_dir`, `custom_url`.

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

Start a structured log run. State file: `{WORK_TEMP}\sap_snro_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_snro_run.json" -Skill sap-snro -ParamsJson "{\"nro_name\":\"<NRO_NAME>\"}"
```

---

## Step 1 — Collect Parameters

**Number Range Object Details**

| Parameter | Description | Example |
|---|---|---|
| NRO name | Z/Y namespace, max 10 chars, allowed chars `A–Z 0–9 _` | `ZMM_0004` |
| Short text | TNROT-TXTSHORT, max 20 chars (only for new NRO) | `MM SEQ004` |
| Long text  | TNROT-TXT, max 60 chars (only for new NRO; defaults to short text if blank) | `MM Sequence 004` |
| Domain     | TNRO-DOMLEN: domain name with optional length, e.g. `NUMC15`, `CHAR10`. The numeric suffix (1–20) defines the maximum number length. Domain must exist or be creatable for the chosen data type. | `NUMC15` |
| Warning %  | TNRO-PERCENTAGE: warning threshold (0.0–99.9). When the consumed share of an interval crosses this %, SAP issues a warning. | `10.0` |
| To-year flag | (optional) tab FC2: maintain intervals per fiscal year. Default unchecked. | unchecked |
| Number length domain check | (optional) tab FC3: number range groups. Default not set. | not set |
| Package | SAP development package (empty = `$TMP` local object) | `ZHKA014` |
| Transport | Transport request number (optional; resolved by `/sap-transport-request` if not supplied and package is transportable) | `S4DK940992` |

**Intervals (optional, used by Step 5c)**

| Parameter | Description | Example |
|---|---|---|
| Intervals file | Tab-separated: `<NR>\t<FROMNUMBER>\t<TONUMBER>\t<EXT>` per line. `<NR>` is a 2-char range key (e.g. `01`). `<EXT>` is `X` for external numbering, blank for internal. | see Step 2 |

---

## Step 1b — Resolve Transport Request

If `Package` is empty or starts with `$` (e.g. `$TMP`), this is a local
object; **skip this step** (`%%TRANSPORT%%` will be empty).

Otherwise a TR is needed. **Do NOT prompt the user directly and do NOT call
`/sap-se01`.** Delegate to `/sap-transport-request`:

```
/sap-transport-request [<TR-from-args-if-any>] OBJECT_TYPE=NRO OBJECT_DESCRIPTION=<NRO_NAME>
```

Use the returned modifiable TRKORR as the `%%TRANSPORT%%` value. If
`/sap-transport-request` reports `ERROR`, stop and surface it to the user.

See `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` for the full policy.

---

## Step 2 — Prepare Intervals File (only when maintaining intervals)

**Skip this step** if the user did not ask to maintain intervals.

If the user provided intervals inline (e.g. `01: 0000000001 – 0099999999`):

1. Write the intervals to: `{WORK_TEMP}\<NRO_NAME>_intervals.txt`
   - Tab-separated, one interval per line: `<NR>\t<FROMNUMBER>\t<TONUMBER>\t<EXT>`
   - `<NR>` is the 2-character interval key (`01`–`ZZ`).
   - `<FROMNUMBER>` / `<TONUMBER>` must fit within the NRO's domain length
     (e.g. NUMC15 ⇒ max 15 digits).
   - `<EXT>` = `X` for external numbering, blank for internal (default).
2. Re-encode as Unicode (UTF-16 LE):
   ```powershell
   $c = Get-Content '{WORK_TEMP}\<NRO_NAME>_intervals.txt' -Raw
   Set-Content '{WORK_TEMP}\<NRO_NAME>_intervals.txt' $c -Encoding Unicode
   ```
3. Confirm by reading the first few lines back.

If the user provided a file path, verify it exists and matches the format.

---

## Step 3 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use the `/sap-login` skill first, then return here.

---

## Step 4 — Check if NRO Exists

The check VBScript template is at `./references/sap_snro_check.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_snro_check_run.ps1`:
```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_snro_check.vbs' -Raw
$content = $content.Replace('%%NRO_NAME%%','THE_NRO_NAME')
Set-Content '{WORK_TEMP}\sap_snro_check_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Replace `THE_NRO_NAME` with the actual NRO name (UPPERCASE) and `<SKILL_DIR>` with the absolute path to this skill directory.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_snro_check_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_snro_check_run.vbs
```

**Parse the last line of output:**
- `EXIST` → NRO exists → proceed to Step 5a (Update) or Step 5c (Intervals).
- `NOT_EXIST` → NRO does not exist → proceed to Step 5b (Create).
- `ERROR:` → show full output and stop.

---

## Step 5b — Create New Number Range Object

If this is a new NRO, the user must supply Short Text and Domain (with length suffix). Ask for any missing values:
> "This is a new Number Range Object. Please provide: Short text (≤20 chars), Domain (e.g. NUMC15), Warning % (default 10.0)."

The create VBScript template is at `./references/sap_snro_create.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_snro_create_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_snro_create.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%NRO_NAME%%',   'THE_NRO_NAME')
$content  = $content.Replace('%%SHORT_TEXT%%', 'THE_SHORT_TEXT')
$content  = $content.Replace('%%LONG_TEXT%%',  'THE_LONG_TEXT')
$content  = $content.Replace('%%DOMLEN%%',     'THE_DOMLEN')
$content  = $content.Replace('%%PERCENTAGE%%', 'THE_PERCENTAGE')
$content  = $content.Replace('%%PACKAGE%%',    'THE_PACKAGE')
$content  = $content.Replace('%%TRANSPORT%%',  'THE_TRANSPORT')
Set-Content '{WORK_TEMP}\sap_snro_create_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Use `.Replace()` (literal). Replace `<SKILL_DIR>` and all `THE_*` placeholders. If `LONG_TEXT` is blank, pass the short text. If `PERCENTAGE` is blank, pass `10.0`. If package/transport not provided, pass empty strings.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_snro_create_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_snro_create_run.vbs
```

Proceed to Step 6 to evaluate the result. If the user also supplied intervals, continue with Step 5c after a successful create.

---

## Step 5a — Update Existing NRO Header

Use this when the user wants to change Short text, Long text, Domain (length) or Warning %, **without** touching intervals.

The update VBScript template is at `./references/sap_snro_update.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_snro_update_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_snro_update.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%NRO_NAME%%',   'THE_NRO_NAME')
$content  = $content.Replace('%%SHORT_TEXT%%', 'THE_SHORT_TEXT')
$content  = $content.Replace('%%LONG_TEXT%%',  'THE_LONG_TEXT')
$content  = $content.Replace('%%DOMLEN%%',     'THE_DOMLEN')
$content  = $content.Replace('%%PERCENTAGE%%', 'THE_PERCENTAGE')
$content  = $content.Replace('%%PACKAGE%%',    'THE_PACKAGE')
$content  = $content.Replace('%%TRANSPORT%%',  'THE_TRANSPORT')
Set-Content '{WORK_TEMP}\sap_snro_update_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```
Pass empty strings for fields the user does not want to change. The VBS only touches fields whose token is non-empty.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_snro_update_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_snro_update_run.vbs
```

Proceed to Step 6.

---

## Step 5c — Maintain Number Range Intervals

Run this step **after** Step 5b (Create) succeeded, or **independently** when
the user only wants to add/change intervals on an existing NRO. The intervals
sub-screen is reached from SNRO via the **Number Ranges** button (`btnINTV`)
which calls SNUM transaction internally.

Intervals are **client-dependent and not transportable** — they live in
`NRIV` (table) and are maintained per client. SAP does not prompt for a
transport when saving intervals (it does, however, log a customising change
record).

The intervals VBScript template is at `./references/sap_snro_intervals.vbs`.

### Generate the filled-in VBScript

Write `{WORK_TEMP}\sap_snro_intervals_run.ps1`:
```powershell
$skillDir = '<SKILL_DIR>'
$tpl      = "$skillDir\references\sap_snro_intervals.vbs"
$content  = Get-Content $tpl -Raw
$content  = $content.Replace('%%NRO_NAME%%',     'THE_NRO_NAME')
$content  = $content.Replace('%%INTERVALS_FILE%%','THE_INTERVALS_FILE')
Set-Content '{WORK_TEMP}\sap_snro_intervals_run.vbs' $content -Encoding Unicode
Write-Host 'Done'
```

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_snro_intervals_run.ps1"
```

### Execute

```bash
cscript //NoLogo {WORK_TEMP}\sap_snro_intervals_run.vbs
```

Proceed to Step 6.

---

## Step 6 — Report Result

**On success** (output contains `SUCCESS:`):
- Tell the user the NRO was created/updated/intervals saved.
- Show the full script output as a code block.
- Mention the assigned package/TR (or `$TMP` local object) when relevant.

**On failure** (output contains `ERROR:`):
- Show the full output and diagnose using this table:

| Error message | Cause | Fix |
|---|---|---|
| `Object does not exist` | NRO not found (Update/Intervals) | Create first (Step 5b) |
| `Object already exists` | NRO present (Create) | Use Update (Step 5a) instead |
| `Domain ... does not exist` | Invalid TNRO-DOMLEN value | Use a valid domain + length, e.g. `NUMC15` |
| `Number length too long` | Length suffix > 20 | Reduce length (max 20 digits) |
| `Percentage out of range` | Warning % not in 0.0–99.9 | Use a valid percentage |
| `Interval overlaps existing` | FROMNUMBER/TONUMBER conflicts with existing range | Pick non-overlapping ranges |
| `Number length exceeds domain` | Interval number > domain length | Shorten numbers or widen domain |
| `Package/transport dialog` | Needs transport assignment | Provide package + transport, or accept `$TMP` |
| `No SAP GUI session found` | Not logged in | Run `/sap-login` first |

---

## Troubleshooting Component IDs / Stuck Screen

**FIRST RESORT — invoke `/sap-gui-diagnose full`.** Captures every visible
window as one annotated PNG via the SAP GUI Scripting `HardCopy` API, plus
`/sap-gui-object-details` for the topmost window. Read the PNG with the
Read tool to see what's on screen, then decide based on both the visual
and the structural dump.

**SECOND RESORT — `/sap-gui-object-details` alone.** Use this when
`/sap-gui-diagnose` itself fails (SAP GUI minimised, HardCopy blocked) or
when you only need a quick structural confirmation.

When a VBS step fails with `The control could not be found by id`, an unexpected
popup appears, or the script hangs because the screen flow diverged from what was
expected, do NOT guess. Call the `sap-gui-object-details` skill immediately to
discover the actual component layout in the current SAP GUI session, then fix the
VBS or dismiss the popup based on the dump.

Recommended diagnostic sequence:

| Step | Mode | Filter | Purpose |
|---|---|---|---|
| 1 | `tree` | (none) | List every open window (`wnd[0]`, `wnd[1]`, …) and their titles |
| 2 | `wnd` | `1` (or `2`) | Full component tree of the unexpected popup — shows its OK/Cancel buttons |
| 3 | `id` | `wnd[0]/sbar` | Read the status-bar message (type/id/number/text) |
| 4 | `type` | `GuiButton` | List every button with text + tooltip when you don't know which to press |
| 5 | `id` | the failing component path | Inspect `Changeable`, `Required`, `Value` to understand why an assignment fails |

After the dump, decide:
- Unexpected popup → press its dismiss button (`wnd[N]/tbar[0]/btn[0]` or `btn[12]`) and retry.
- Component ID changed between SAP releases → update the VBS template with the discovered ID.

**Last resort:** SAP Logon > Help > Scripting Recorder and Playback to record the
correct sequence manually.

---

## Step 7 — Clean Up

Delete all temporary files:
```bash
cmd /c del {WORK_TEMP}\sap_snro_check_run.vbs & del {WORK_TEMP}\sap_snro_check_run.ps1 & del {WORK_TEMP}\sap_snro_create_run.vbs & del {WORK_TEMP}\sap_snro_create_run.ps1 & del {WORK_TEMP}\sap_snro_update_run.vbs & del {WORK_TEMP}\sap_snro_update_run.ps1 & del {WORK_TEMP}\sap_snro_intervals_run.vbs & del {WORK_TEMP}\sap_snro_intervals_run.ps1
```

Also delete `{WORK_TEMP}\<NRO_NAME>_intervals.txt` if it was written from inline input.

---

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_snro_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_snro_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SNRO_FAILED`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Security Note

The generated `.vbs` files may contain sensitive data — delete after use (Step 7).
