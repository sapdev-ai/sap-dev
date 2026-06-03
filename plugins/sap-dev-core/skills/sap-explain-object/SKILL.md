---
name: sap-explain-object
description: |
  Read-only comprehension aid for an EXISTING ABAP object. Auto-detects the
  object type (program / include / function module / class) via RFC, acquires
  its active source (RFC RPY for programs/includes/FMs; SE24 GUI download for
  classes), resolves the include tree, builds a structure + call map
  (FORM/METHOD/FUNCTION units; PERFORM / CALL FUNCTION / CALL METHOD edges;
  SELECT/UPDATE/MODIFY/DELETE targets; SUBMIT / CALL TRANSACTION; selection
  screen), optionally pulls callers via /sap-where-used-list, then emits an
  explanation dossier (dossier.md) plus a machine-readable map.json. Never
  modifies the SAP system.
  Prerequisites: pinned connection (/sap-login). Class source download needs
  an active SAP GUI session; programs/includes/FMs read over RFC (no GUI).
argument-hint: "<OBJECT_NAME> [--type program|include|fm|class|auto] [--callers] [--no-gui] [--depth N]"
---

# SAP Explain Object Skill

Produces a read-only "object dossier" for an existing ABAP object: what it does,
its internal structure and call graph, the data it touches, its dependencies,
and a change-impact note. Pure read — never deploys, activates, or edits.

This skill observes `shared/rules/skill_operating_rules.md` (reads only — no SQL
writes, no unsolicited deployment).

## Shared Resources

| File / token | Path | Purpose |
|---|---|---|
| `sap_settings_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1` | `Get-SapSettingValue`, settings merge |
| `sap_connection_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1` | `Get-SapWorkDir`, `Get-SapCurrentSessionPath` |
| `sap_rfc_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1` | `Connect-SapRfc` (+ the `New-RfcReadTable` / `Add-RfcOption` / `Add-RfcField` primitives) |
| `sap_object_resolver.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1` | `Read-SapTableRows` (validated RFC_READ_TABLE reader for the type probe; CLI body self-guarded on dot-source) |
| `sap_rfc_read_source.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_read_source.ps1` | `Read-SapAbapSource` (RPY source + include tree) |
| `sap_explain_parse.ps1` | `<SKILL_DIR>\references\sap_explain_parse.ps1` | offline source -> `map.json` |
| `sap_attach_lib.vbs` (`%%ATTACH_LIB_VBS%%`) | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs` | `AttachSapSession` (GUI download / where-used) |
| SE24 download VBS | `<SKILL_DIR>\..\sap-se24\references\sap_se24_check_and_download.vbs` | class source (GUI) |
| where-used VBS | `<SKILL_DIR>\..\sap-where-used-list\references\sap_where_used_list.vbs` | callers (GUI) |
| `sap_log_helper.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1` | structured logging |

## Step 0 — Resolve Work Directory

Resolve `work_dir` via the env-aware helper (do NOT read `settings.json`
directly — that ignores `SAPDEV_AI_WORK_DIR` / `userconfig.json`):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Settings reads/writes follow `shared/rules/settings_lookup.md`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Set `{WORK_TEMP}` = `{work_dir}\temp` and `{OUT}` = `{WORK_TEMP}\explain\{OBJECT}`. Ensure `{OUT}` exists:

```bash
cmd /c if not exist "{OUT}" mkdir "{OUT}"
```

## Step 0.5 — Start Logging (best-effort)

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Event start -Skill sap-explain-object -Args "{RAW_ARGS}"
```
Capture the printed `RUN_ID=` and reuse it on the end event.

## Step 1 — Parse Arguments

- `{OBJECT}` = first positional, uppercased.
- `--type` -> `{TYPE}` (default `auto`).
- `--callers` -> `{CALLERS}` = true (default false; requires GUI session).
- `--no-gui` -> `{NOGUI}` = true (RFC-only; classes degrade to signature only).
- `--depth N` -> `{DEPTH}` (default 3).

## Step 2 — Ensure Connection / Session

- Always need a pinned RFC connection (`/sap-login`). Verify by attempting
  `Connect-SapRfc` (empty params -> pinned-profile fallback).
- A **GUI session** is required ONLY when `{TYPE}` resolves to `class` (source
  download) or `{CALLERS}` is true. If needed and absent, instruct the user to
  run `/sap-login`. If `{NOGUI}` is set, skip GUI entirely.

## Step 3 — Detect Object Type (RFC, no GUI)

If `{TYPE}` is `auto`, probe these tables in order via `Read-SapTableRows` and
stop at the first hit (the underlying `New-RfcReadTable` auto-applies
`Assert-RfcReadTableAllowed`):

| Table | Filter | -> Type |
|---|---|---|
| `TRDIR` | `NAME = '{OBJECT}'` (`SUBC`: `1`=report, `I`=include, `M`=module pool, `F`=FUGR main) | `program` / `include` |
| `TFDIR` | `FUNCNAME = '{OBJECT}'` | `fm` |
| `SEOCLASS` | `CLSNAME = '{OBJECT}'` | `class` / `interface` |
| `DD02L` | `TABNAME = '{OBJECT}'` | table/structure (out of scope -> suggest `/sap-se11`; stop) |
| `DD01L` / `DD04L` / `DD40L` | name match | domain / data element / table type (out of scope -> note) |

```powershell
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1'   # Read-SapTableRows (CLI body self-guarded on dot-source)
$dest = Connect-SapRfc -DestName "EXPLAIN"
if (-not $dest) { Write-Output "ERROR: no RFC connection (run /sap-login)"; exit 2 }
# Use the validated reader Read-SapTableRows -Destination/-Table/-Where/-Fields. Do NOT
# hand-roll New-RfcReadTable -QueryTable/-Where/-Fields — that is not its signature
# (New-RfcReadTable takes only -Destination/-Table; WHERE/fields are added via
# Add-RfcOption/Add-RfcField). The underlying reader auto-applies Assert-RfcReadTableAllowed.
$rows = Read-SapTableRows -Destination $dest -Table "TRDIR" -Where "NAME = '{OBJECT}'" -Fields @("NAME","SUBC")
# $null -eq $rows -> RFC could-not-check ; $rows.Count -eq 0 -> not this type
# ...branch per the table above; emit TYPE={resolved}
```
If nothing matches -> `ERROR: {OBJECT} not found as program/include/FM/class.` and stop.

## Step 4 — Acquire Source + Includes

**Programs / includes / FMs (RFC, preferred):**
```powershell
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_read_source.ps1'
$r = Read-SapAbapSource -Name '{OBJECT}' -Type '{TYPE}' -OutDir '{OUT}' -WithIncludes -Depth {DEPTH}
# $r.Status in OK | NOT_FOUND | UNSUPPORTED | ERROR
# $r.SourceFile = {OUT}\source.txt ; $r.Includes = @(@{Name;File}, ...)
```

**Class / interface:** RFC class source is not supported by the reader -> use the
SE24 GUI download VBS (skip if `{NOGUI}`):
```powershell
$skillSe24 = '<SKILL_DIR>\..\sap-se24'
$vbs = (Get-Content "$skillSe24\references\sap_se24_check_and_download.vbs" -Raw).
  Replace('%%CLASS_NAME%%','{OBJECT}').
  Replace('%%OUTPUT_FILE%%','{OUT}\source.txt').
  Replace('%%SESSION_PATH%%','').
  Replace('%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
Set-Content '{WORK_TEMP}\explain_dl.vbs' $vbs -Encoding Unicode
```
```bash
"C:/Windows/SysWOW64/cscript.exe" //NoLogo "{WORK_TEMP}\explain_dl.vbs"
```
> Note: GUI download returns the pretty-printed *display* view (local `TYPES`
> may appear at outer scope). Adequate for comprehension; flag it in the dossier.

## Step 5 — Build the Structure / Call Map

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_explain_parse.ps1" -SourceDir "{OUT}" -OutFile "{OUT}\map.json"
```
`map.json` (best-effort; per-unit DB attribution is a refinement):
```json
{ "object":"{OBJECT}","type":"{TYPE}","includes":["..."],
  "units":[{"kind":"FORM|METHOD|FUNCTION","name":"..."}],
  "externals":{"function_modules":["..."],"performs":["..."],
               "submits":["..."],"transactions":["..."]},
  "db_reads":["MARA"],"db_writes":["ZTAB"],
  "selection_screen":[{"name":"P_WERKS","kind":"PARAMETER"}] }
```

## Step 6 — Callers (optional, `--callers`)

Instantiate the where-used VBS (TXN by `{TYPE}`: SE38/SE37/SE24), tokens
`%%TXN%% %%OBJECT_TYPE%% %%OBJECT_NAME%% %%TO_SPOOL%% %%SESSION_LOCK_VBS%%
%%SESSION_PATH%% %%ATTACH_LIB_VBS%%`; substitute `$env:SAPDEV_SESSION_PATH` via
`Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'`; parse last line:
- `NOT_FOUND:` -> no callers
- `FOUND_LIST:` -> list on screen (note to user)
- `SPOOL_CREATED:<n>` -> chain `/sap-sp02 <n> {OUT}\callers.txt` to download
Merge results into `map.json` under `callers`.

## Step 7 — Synthesize `dossier.md`

Read `{OUT}\map.json` and `{OUT}\source.txt`. Write `{OUT}\dossier.md`:
1. **Purpose** — inferred from names, comments, selection screen, DB tables.
2. **How it runs** — entry point -> flow walkthrough following the call graph.
3. **Data touched** — tables read vs. written.
4. **Dependencies** — FMs, classes, SUBMITs, CALL TRANSACTIONs; callers if `--callers`.
5. **Change-impact note** — "if you change X, re-check Y" from the graph + callers.
6. **Caveats** — pretty-print view for classes; unparsed macros.

## Step 8 — Report & Clean Up
Print the `{OUT}` path and a 5-line summary. Leave `{OUT}` artifacts in place
(read-only deliverable). Remove only scratch VBS in `{WORK_TEMP}`.

## Final — Log End
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Event end -RunId "{RUN_ID}" -Status "{success|error}"
```

## Troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: no RFC connection` | not logged in / RFC creds missing | run `/sap-login` |
| `Read-SapAbapSource` Status=UNSUPPORTED | class over RFC | omit `--no-gui`; ensure GUI session |
| include tree shallow | depth cap | raise `--depth` |
| class source scope looks off | pretty-print display view | expected; treat source as informational |

## Limitations
- DDIC objects (table/structure/DE/domain) are out of scope -> redirect to `/sap-se11` display.
- Macro-/generated-code parsing is best-effort; dossier degrades to "raw + summary".
- Dynamic calls (`CALL FUNCTION lv_name`, `CALL METHOD (lv_meth)`) and dynamic where-used refs aren't resolved — noted in the dossier.
- Class method source over RFC unsupported until ADT mode (planned).
