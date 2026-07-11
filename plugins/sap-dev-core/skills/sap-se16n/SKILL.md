---
name: sap-se16n
description: |
  Queries any SAP table via SE16N using SAP GUI Scripting and downloads the
  result set as a tab-delimited text file. Supports filtering by any combination
  of table fields with single value, multi-value (IN list), or range (BT)
  selection, and any of the standard SE16N operators (EQ, NE, GT, LT, GE, LE,
  BT, NB, CP, NP, IN). Optionally restricts the output columns to a specific
  set of fields; if no SELECT list is given, all fields are returned. Detects
  the "no values found" path and writes a marker file instead of an empty
  download. Typical use: dump rows from any SAP table for inspection or as
  reference data for development. Snapshot modes add a table-state assertion
  primitive: `snapshot save <name>` captures a query result under
  {artifact_dir}\snapshots; `snapshot diff <a> <b>` row-diffs two snapshots on
  declared key columns (ignoring volatile columns) via the shared keyed-diff
  engine — ADDED/REMOVED/CHANGED/SAME; `snapshot list` enumerates them.
  Prerequisites: Active SAP GUI session (use /sap-login first). `snapshot diff` /
  `snapshot list` are pure-local and need no SAP session.
argument-hint: "<TABLE> [field=value ...] [select=F1,F2,...]  |  snapshot save <name> <TABLE> [filters] --keys=K1,K2 [--ignore=V1,V2]  |  snapshot diff <a> <b> [--keys=..] [--ignore=..]  |  snapshot list"
---

# SAP SE16N Table Query Skill

You query a SAP table via transaction SE16N and download the result set as a
tab-delimited text file. Filters and the optional output-field list are passed
to the underlying VBScript via a side-channel parameters file so that an
arbitrary number of filter fields and values can be specified.

Task: $ARGUMENTS

**Mode dispatch.** If the first token is `snapshot`, go to **Snapshot Modes**
(below): `save` runs the normal query flow (Steps 0–6) then captures the result;
`diff` / `list` are pure-local and skip the SAP query. If the first token is
`agg`, go to **Aggregation Mode (SE16H)** — server-side GROUP BY + MIN/MAX/AVG +
per-group count, a separate SAP flow (transaction SE16H) that does NOT run
Steps 3–6. Any other first token is the **normal query flow** (Steps 0–6,
default — unchanged).

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SKILL_DIR>/references/sap_se16n_snapshot.ps1` | Snapshot `save`/`diff`/`list` (pure-local); the diff delegates to the shared keyed-diff engine. |
| `<SKILL_DIR>/references/sap_se16h_agg.vbs` | `agg` mode — drives SE16H (program `SAPLSE16N`, advanced screen) for server-side GROUP BY + MIN/MAX/AVG; reads the grouped ALV via the GridView API (no export dialog). Tokens: `%%TABLE_NAME%%`, `%%PARAMS_FILE%%`, `%%OUTPUT_FILE%%`, `%%MAX_GROUPS%%`, `%%MIN_COUNT%%`, `%%SESSION_PATH%%`, `%%ATTACH_LIB_VBS%%`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_keyed_diff_lib.ps1` | The ONE keyed row-diff engine (`Get-SapKeyedDiff` / `Write-SapKeyedDiffTsv`), shared with /sap-config-compare + /sap-compare `--table-content`. |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
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

Set `{RUN_TEMP}` = the `RUN_TEMP=` value printed above — a fresh per-run scratch
directory `{work_dir}\temp\run_<id>`, already created by `Get-SapRunTemp`.
Resolve it **once here** and reuse the same value for the rest of this
invocation; it isolates this run's generated wrappers / state / scratch files so
concurrent runs (parallel sub-agents, multi-connection deploys) never collide.
**`{WORK_TEMP}` stays the base temp dir** and is used ONLY for
`Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'` (the session-attach plumbing
derives `{work_dir}\runtime` from its parent, so it must see the base path, not
the run dir). Everything the skill writes itself goes under `{RUN_TEMP}`.

---

## Step 0.5 — Start Logging

Start a structured log run. State file: `{RUN_TEMP}\sap_se16n_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_se16n_run.json" -Skill sap-se16n -ParamsJson "{\"table\":\"<TABLE>\"}"
```

---

## Step 1 — Collect Parameters

| Parameter | Description | Example |
|---|---|---|
| Table name | SAP transparent / pooled / cluster table | `T001` |
| Filter fields | Zero or more `field op value(s)` triples — see operator table | `LAND1 IN CN,JP` |
| Select fields | Optional comma-separated list of output columns; empty = all fields | `BUKRS,BUTXT,LAND1,WAERS` |
| Output file | Absolute path of the resulting `.txt` file (default: `{RUN_TEMP}\se16n_<TABLE>.txt`) | |

**Operators** (column 2 of each FILTER row):

| Op | Meaning | Values column count |
|---|---|---|
| `EQ` | equals | 1 |
| `NE` | not equal | 1 |
| `GT` / `LT` / `GE` / `LE` | comparison | 1 |
| `BT` | between (LOW..HIGH) | 2 |
| `NB` | not between | 2 |
| `CP` | matches pattern (`*`, `+`) | 1 |
| `NP` | does not match pattern | 1 |
| `IN` | one of the listed values | 2..N (auto-uses multi-select popup) |

**Routing rule:** an `IN` operator OR a single filter with more than one value
opens the SE16N multi-select popup (`btnPUSH`) and fills the LOW column of
`tblSAPLSE16NMULTI_TC`. A single value with any other operator is set directly
on `ctxtGS_SELFIELDS-LOW` of the criteria row.

If the user gives the criteria as natural language (e.g. *"T001 where Country
is CN or JP and Currency is CNY"*), parse to:

| Field | Op | Values |
|---|---|---|
| `LAND1` | `IN` | `CN`, `JP` |
| `WAERS` | `EQ` | `CNY` |

---

## Step 2 — Ensure SAP GUI Login

This skill requires an active SAP GUI session. If not already logged in, use
the `/sap-login` skill first, then return here.

---

## Step 3 — Write the PARAMS_FILE

Write `{RUN_TEMP}\se16n_params.txt` with two literal section headers, **`SELECT`**
and **`FILTER`**, each followed by its rows. Either section may be empty.

Format:

```
SELECT
<FIELDNAME>
<FIELDNAME>
FILTER
<FIELDNAME><TAB><OP><TAB><VAL1>[<TAB><VAL2>...]
<FIELDNAME><TAB><OP><TAB><VAL1>[<TAB><VAL2>...]
```

**Field columns are separated by a real tab character (`\t`) — not spaces.**

Example for `T001` filter `LAND1 ∈ {CN, JP}` AND `WAERS = CNY`, returning all
fields:

```
SELECT
FILTER
LAND1	IN	CN	JP
WAERS	EQ	CNY
```

Same query but only outputting `BUKRS, BUTXT, LAND1, WAERS`:

```
SELECT
BUKRS
BUTXT
LAND1
WAERS
FILTER
LAND1	IN	CN	JP
WAERS	EQ	CNY
```

Use the Write tool to create the file. The VBS reads it as system default
codepage; ASCII is always safe.

---

## Step 4 — Generate and Run the VBS

The VBS template is at `./references/sap_se16n.vbs`.

### Generate the filled-in VBScript

Write `{RUN_TEMP}\sap_se16n_run.ps1`:
```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se16n.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%TABLE_NAME%%','THE_TABLE'
$content = $content -replace '%%PARAMS_FILE%%','{RUN_TEMP}\se16n_params.txt'
$content = $content -replace '%%OUTPUT_FILE%%','{RUN_TEMP}\se16n_THE_TABLE.txt'
# Session-attach plumbing (Phase 4.2: pin file eliminated). The shared
# AttachSapSession helper resolves the target session in this order:
#   1. SESSION_PATH constant (set from the parsed --session argument)
#   2. SAPDEV_SESSION_PATH env var
#   3. Sole-connection + sole-session auto-default
#   4. Refuse with helpful error (multiple connections, no resolver)
$sessionPath = ''   # set to the parsed --session value if supplied
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
# Resolve the AI-session's pinned session path and pass via env var so
# AttachSapSession's Strategy 2 picks it up. Falls back to sole-connection
# default for the single-conn case.
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se16n_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```
Replace `THE_TABLE` with the actual table name (UPPERCASE) and `<SKILL_DIR>` /
`{WORK_TEMP}` with their absolute paths.

Run:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_se16n_run.ps1"
```

### Execute (with SAP GUI Security guard)

SE16N's "download to local file" is **SAP-GUI-side file IO**, so it raises the
modal **SAP GUI Security** dialog when the output path isn't allow-listed (Default
Action = Ask) — and that modal suspends the Scripting API, hanging the cscript.
Per `shared/rules/sap_gui_security_handling.md`, pre-check the rules and run the
OS-level watcher around the export. Run as one PowerShell block (the 32-bit
cscript is inside it). Substitute `THE_SID` / `THE_CLIENT` with the pinned
system / client:

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
$out    = '{RUN_TEMP}\se16n_THE_TABLE.txt'
# 1. Pre-check the allow-list (read-only; informational + lets us skip the watcher).
& "$shared\sap_gui_security_precheck.ps1" -Path $out -Access w -System 'THE_SID' -Client 'THE_CLIENT' -Transaction 'SE16N' | Out-Host
$allowed = ($LASTEXITCODE -eq 0)
# 2. If not already allow-listed, launch the OS-level watcher BEFORE the
#    (blocking) export. It detects the #32770 dialog and clicks Remember+Allow,
#    which also persists a rule so subsequent runs pre-check ALLOWED.
$watcher = $null
if (-not $allowed) {
    $watcher = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"$shared\sap_gui_security_sidecar.ps1",'-TimeoutSeconds','40')
    Start-Sleep -Milliseconds 800
}
# 3. Run the export (32-bit cscript). If the dialog appears it blocks here until
#    the watcher dismisses it; then the export completes.
& 'C:/Windows/SysWOW64/cscript.exe' //NoLogo '{RUN_TEMP}\sap_se16n_run.vbs'
# 4. Reap the watcher.
if ($watcher) { $watcher | Wait-Process -Timeout 45 -ErrorAction SilentlyContinue }
```

---

## Step 5 — Interpret the Output

**Last line of stdout:**

| Last line | Meaning |
|---|---|
| `ROWS=<n>` (n ≥ 1) | Query returned `n` data rows. Output file is tab-delimited with a header line. |
| `ROWS=0 (NO_DATA)` | **Genuine empty result set** ("no values found"). Exit 0. Output file contains a single line `NO_DATA<TAB><status text>`. |
| `QUERY_FAILED` | **The query FAILED** — authorization error, invalid/forbidden table, or any status-bar error (`MessageType` `E`/`A`) after the table-name Enter or F8. Exit 1. Output file's first line is `QUERY_FAILED<TAB><status text>`. **This is NOT "0 rows".** Consumers MUST treat it as an error, never as "row/object absent" (see the consumer note below). |
| `ERROR: …` | Navigation / layout / file-write failure — show the full output and stop. |

**QUERY_FAILED vs NO_DATA — the critical distinction.** An authorization failure,
a forbidden table, or an sbar error leaves no result ALV — exactly like a genuine
empty result set does. The VBS branches on the locale-independent `sbar.MessageType`
(`E`/`A` → `QUERY_FAILED` + exit 1; otherwise → `NO_DATA` + exit 0), never on the
translated status text. Callers that read `E070`/`E071` via this skill (e.g.
`/sap-transport-request` Step 1b, `/sap-se01` release/delete pre-checks,
`/sap-cc-inventory` GUI ingest) previously read an auth failure as "TR/object not
found" and could steer to a new TR or proceed on an empty inventory — they now
distinguish `QUERY_FAILED` and fail closed.

**Output file** (`{RUN_TEMP}\se16n_<TABLE>.txt`):
- First line = header (technical field names)
- Subsequent lines = data rows
- Field separator = TAB

If you need to summarise the result for the user, read the first ~20 lines and
report the row count and a few sample rows.

---

## Step 6 — Report Results

Report back to the user:
- The table queried, the filter spec, and the SELECT list (if any)
- The total row count
- The output file path
- For NO_DATA: the SAP status bar text from the marker file

---

## Snapshot Modes (table-state assertions)

Pure-local aside from `save`'s underlying query. Resolve `{artifact_dir}` (default
`{work_dir}\artifacts`) in Step 0 and set `{SNAP_ROOT}` = `{artifact_dir}\snapshots`.
Helper: `references/sap_se16n_snapshot.ps1`; diff engine: the shared
`sap_keyed_diff_lib.ps1`.

### `snapshot save <name> <TABLE> [filters] --keys=K1,K2 [--ignore=V1,V2] [select=...]`
1. Run the **normal query flow** (Steps 0–6) for `<TABLE>` + filters to produce the
   TSV at `{RUN_TEMP}\se16n_<TABLE>.txt`. Ensure the `--keys` (and any `--ignore`
   volatile) columns are in the `select=` list so they are present to diff on.
2. Capture it (refuses a `QUERY_FAILED` / `NO_DATA` export — fix the query first):
   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_se16n_snapshot.ps1" -Action save -SnapshotRoot "{SNAP_ROOT}" -Name "<name>" -DataTsv "{RUN_TEMP}\se16n_<TABLE>.txt" -Table "<TABLE>" -Filters "<filters>" -KeyColumns "K1,K2" -IgnoreColumns "V1,V2" -Sid "<SID>" -Client "<client>"
   ```
   Report the `STATUS: SAVED …` line.

### `snapshot diff <a> <b> [--keys=..] [--ignore=..]`
Pure-local — no SAP session. Keys/ignore default to the snapshots' saved metadata when omitted:
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_se16n_snapshot.ps1" -Action diff -SnapshotRoot "{SNAP_ROOT}" -Left "<a>" -Right "<b>" -KeyColumns "K1,K2" -IgnoreColumns "V1,V2" -KeyedDiffLib "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_keyed_diff_lib.ps1"
```
Surface the `KEYED_DIFF: added=.. removed=.. changed=.. same=..` line and the `diff_<a>_vs_<b>.tsv` path; register it via `Register-SapArtifact -Kind diff`. A `schema_drift=` / `dup_keys=` tail is a data-quality flag to report, never hide. It refuses a cross-table diff.

### `snapshot list`
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_se16n_snapshot.ps1" -Action list -SnapshotRoot "{SNAP_ROOT}"
```

## Aggregation Mode (SE16H)

`agg <TABLE> --group-by=F1[,F2…] [--avg=A] [--min=B] [--max=C] [--count] [--sum=D] [--filter FIELD OP VALUE …] [--max-groups=N] [--min-count=M]`

Pushes the aggregation **down to the database** via transaction SE16H (program
`SAPLSE16N`, the "General Table Display" advanced screen) so the raw rows are
never downloaded. Drives `references/sap_se16h_agg.vbs`, which ticks GROUP BY on
the `--group-by` fields, sets the aggregate combo on each `--avg`/`--min`/`--max`
field, executes, and reads the grouped ALV directly through the GridView API — so
**no ALV export dialog fires, hence no SAP GUI Security file-IO prompt**.

**Capability — verified live (S/4HANA 1909, SAP_BASIS 754, 2026-07-11):** SE16H's
per-field aggregate combo offers **only `MIN` / `MAX` / `AVG`**. There is **no
Sum/Total** in the combo on this build, across CHAR / NUMC / INT / CURR fields and
whether or not a GROUP BY is active. **COUNT is implicit** — a grouped result
always carries a `LINE_INDEX` ("Number of Entries") column, which `--count` simply
surfaces (it is always present; the flag only documents intent).

- **`--sum` is NOT server-side here.** SE16H cannot sum. Route `--sum=<field>` to a
  **local-aggregation fallback**: run the **normal query flow** (Steps 0–6) for
  `<TABLE>` + the same `--group-by`/`--filter` (with the sum field + group keys in
  `select=`), then sum locally per group — and **print the raw row count with an
  explicit "summed locally over N downloaded rows (server-side SUM unavailable in
  SE16H)" warning**, since a large table means a large download. Never silently
  approximate SUM from `AVG × COUNT` (SQL AVG is rounded → wrong for currency).

**Flow:**

1. **Parse args.** Collect `--group-by` (comma list), the aggregate specs
   (`--avg`/`--min`/`--max` → field:func with func ∈ MIN/MAX/AVG), `--filter`
   triples, `--max-groups` (default `100000`), `--min-count` (grouping minimum).
   If `--sum` is present, peel it off and handle it via the local fallback above
   (the SE16H run still handles any MIN/MAX/AVG/group asked alongside it).
2. **Write the params file** `{RUN_TEMP}\se16h_agg_params.txt` (system codepage),
   sections introduced by the literal lines `GROUP` / `AGG` / `FILTER`:
   ```
   GROUP
   WERKS
   BWART
   AGG
   MENGE	AVG
   FILTER
   BWART	EQ	101
   ```
   (`AGG` rows are `FIELD<TAB>FUNC`; `FILTER` rows are `FIELD<TAB>OP<TAB>value…`
   with SE16N operators EQ/NE/GT/LT/GE/LE/BT/NB/CP/NP/IN.)
3. **Fill + run the VBS** (same token/encoding idiom as Step 4 of the normal flow —
   resolve `$sessionPath`, set `$env:SAPDEV_SESSION_PATH`, write UTF-16LE, run
   32-bit cscript):
   ```powershell
   $c = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_se16h_agg.vbs', [System.Text.Encoding]::UTF8)
   $c = $c -replace '%%TABLE_NAME%%','<TABLE>'
   $c = $c -replace '%%PARAMS_FILE%%','{RUN_TEMP}\se16h_agg_params.txt'
   $c = $c -replace '%%OUTPUT_FILE%%','{RUN_TEMP}\se16h_agg_<TABLE>.txt'
   $c = $c -replace '%%MAX_GROUPS%%','100000'
   $c = $c -replace '%%MIN_COUNT%%',''
   $c = $c -replace '%%SESSION_PATH%%', $sessionPath
   $c = $c -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
   $env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
   [System.IO.File]::WriteAllText('{RUN_TEMP}\sap_se16h_agg_run.vbs', $c, [System.Text.UnicodeEncoding]::new($false,$true))
   ```
   ```bash
   C:/Windows/SysWOW64/cscript.exe //NoLogo '{RUN_TEMP}\sap_se16h_agg_run.vbs'
   ```
4. **Parse the last stdout lines** and report:
   - `SE16H_AGG: table=.. groups=<n> cols=<c> truncated=<0|1> group_by=[..] agg=[..]`
     then `ROWS=<n>` then `STATUS: OK` — the grouped TSV is at the output path
     (columns = group dims + aggregated measures + `LINE_INDEX` count). Register it
     via `Register-SapArtifact -Kind agg`.
   - **`truncated=1`** ⇒ the group set was capped at `--max-groups`; **say so
     explicitly** (some groups are missing — raise `--max-groups` for the full set).
     `GD-MAX_LINES` caps the number of returned GROUPS, not the input: every
     returned aggregate is still computed over the whole table, but excess groups
     are dropped, so a silent partial pass is never acceptable.
   - `STATUS: TABLE_NOT_FOUND` / `FIELD_NOT_FOUND` / `AGG_NOT_APPLICABLE`
     (field type rejects the func, or a SUM/COUNT reached the VBS) / `NO_RESULT_GRID`
     — surface the specific failure; do not read any of these as "0 groups".
   - `STATUS: COULD_NOT_CHECK reason=SE16H_outline_controls_absent` (or
     `_selection_screen_absent`) — SE16H or its outline model is unavailable on this
     release/auth. Do **not** fail silently: offer the `--sum`-style local-
     aggregation fallback (download via the normal flow, group locally, warn on row
     count) for the whole request.

## Final — Log End

Log the run-end record. Best-effort.

On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se16n_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se16n_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `SE16N_FAILED`, `TABLE_NOT_FOUND`, `GUI_TIMEOUT`.

---

## Component IDs (for reference / debugging)

Selection-criteria table control: `wnd[0]/usr/tblSAPLSE16NSELFIELDS_TC`

| Col | ID prefix | Purpose |
|---|---|---|
| 0 | `txtGS_SELFIELDS-SCRTEXT_M` | Field description ("Fld name") |
| 1 | `btnOPTION` | Operator icon button |
| 2 | `ctxtGS_SELFIELDS-LOW` | From value |
| 3 | `ctxtGS_SELFIELDS-HIGH` | To value |
| 4 | `btnPUSH` | Multi-select popup launcher |
| 5 | `chkGS_SELFIELDS-MARK` | Output column checkbox |
| 6 | `txtGS_SELFIELDS-FIELDNAME` | Technical field name |

Multi-select popup: `wnd[1]/usr/tblSAPLSE16NMULTI_TC/ctxtGS_MULTI_SELECT-LOW[1,n]`,
applied with `wnd[1]/tbar[0]/btn[8]` (Copy).

Execute: `wnd[0]/tbar[1]/btn[8]` (F8).

ALV export: `pressToolbarContextButton "&MB_EXPORT"` then
`selectContextMenuItem "&PC"`. Format radios are at
`wnd[1]/usr/subSUBSCREEN_STEPLOOP:SAPLSPO5:0150/sub:SAPLSPO5:0150/radSPOPLI-SELFLAG[col,0]`
(note: `[col,0]`, not `[col,row]`):

| col | Label (S/4HANA 1909, EN) |
|---|---|
| 0 | Unconverted |
| 1 | Text with Tabs ← tab-delimited |
| 2 | Rich text format |
| 3 | HTML Format |
| 4 | In the clipboard |

Older releases label `[1,0]` as "Spreadsheet". The VBS walks the radios at
runtime and matches `Tab` or `preadsheet` substrings, then falls back to
`[1,0]`. File dialog: `wnd[1]/usr/ctxtDY_PATH` and `wnd[1]/usr/ctxtDY_FILENAME`.

### SE16H (`agg` mode) — same TC, different columns

Transaction **SE16H** shares program `SAPLSE16N` but its selection-field table
control (`wnd[0]/usr/tblSAPLSE16NSELFIELDS_TC`) exposes MORE columns than SE16N,
so the column indices differ — captured live on S/4HANA 1909, kernel 754:

| Col | ID prefix | Purpose |
|---|---|---|
| 2 | `ctxtGS_SELFIELDS-LOW` | From value (filter) |
| 3 | `ctxtGS_SELFIELDS-HIGH` | To value (filter) |
| 4 | `btnPUSH` | Multi-select popup launcher |
| 6 | `chkGS_SELFIELDS-MARK` | Output column checkbox |
| 8 | `chkGS_SELFIELDS-GROUP_BY` | **Group-by checkbox** |
| 10 | `chkGS_SELFIELDS-ORDER_BY` | Order-by checkbox |
| 12 | `cmbGS_SELFIELDS-AGGREGATE` | **Aggregate combo** — keys `MIN`/`MAX`/`AVG` (no SUM) |
| 13 | `txtGS_SELFIELDS-FIELDNAME` | **Technical field name** (col 6 in plain SE16N) |

Selection-screen scalars: table `wnd[0]/usr/ctxtGD-TAB`, returned-group cap
`wnd[0]/usr/txtGD-MAX_LINES`, grouping minimum `wnd[0]/usr/txtGD-MIN_COUNT`.
Execute `wnd[0]/tbar[1]/btn[8]` (F8) → result ALV `wnd[0]/usr/cntlRESULT_LIST/shellcont/shell`
(read via `ColumnOrder` + `GetCellValue`; the `LINE_INDEX` column is the implicit
per-group count). The field-list TC scrolls (verified to 30 rows); the VBS pages
`verticalScrollbar` to reach fields past the visible ~14.

---

## Limitations

- The normal query flow does not support sort orders or saved variants — use
  SE16N directly for those. **Aggregation** is supported via **`agg` mode**
  (SE16H: GROUP BY + MIN/MAX/AVG + per-group count); **SUM is not server-side in
  SE16H** and falls back to a local sum over a full download (row-count warning).
- The `SELECT` list filters output columns by toggling MARK checkboxes; column
  ordering in the output file follows SAP's natural ordering, not the order in
  the SELECT list.
- Pooled / cluster tables that SE16N forbids reading, and tables the user is not
  authorized to read, surface as `QUERY_FAILED` (sbar `MessageType` `E`/`A`,
  exit 1) — **not** `NO_DATA`. Surface the message to the user; do not treat it
  as "0 rows".
- **ECC6 / 7.31 limitation.** SE16N availability and screen layout differ on
  older releases: on some ECC6 systems SE16N is not installed (only `SE16`) or
  the selection-criteria table control / export dialog uses different control
  IDs, so this skill may not be portable there. `/sap-se01`'s create + verify
  chain depends on SE16N (`E070`/`E07T` reads) — on ECC6 prefer the RFC path
  (`RFC_READ_TABLE` / `sap_tr_object_entries.ps1`) where a helper exists, and
  re-record the SE16N control IDs with `/sap-gui-probe --record` if the GUI path is
  required.
- Date values must be passed as 8-digit `YYYYMMDD` (e.g. `20240131`) — SAP DATS
  fields accept this regardless of the logon user's date personalization
  (`USR01-DATFM`), so it is locale-independent. Do NOT use a separator form such
  as `YYYY.MM.DD`, which is only accepted when it matches the user's DATFM.
  Numeric values must have no thousand separators.
- Some long-text / non-selectable fields (e.g. `AS4TEXT` on `E070`, `STEXT` on
  many tables) cannot be filtered via SE16N at all — SAP renders the row
  greyed-out (no operator, no input, no multi-select). The skill detects this
  via `Changeable=False`, prints a `WARN:` message, automatically adds the
  field to the SELECT list, and continues with the remaining filters. The user
  must post-filter the output file for the skipped condition.
