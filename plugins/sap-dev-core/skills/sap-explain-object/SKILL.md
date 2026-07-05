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
  With --spec it goes further: enriches the map over RFC (DDIC table short texts
  + key fields via DD02T/DD03L, message texts via T100, authorization objects)
  and renders a formal, review-ready specification document — Markdown by default,
  Word (--format docx) for sign-off, or a filled spec_template.xlsx workbook
  (--format xlsx) that round-trips back through /sap-docs-extract. Every spec
  section is marked CONFIRMED (read from the system) vs INFERRED (reasoned), with
  an honest "Assumptions & open questions" section. --spec folds in the former
  /sap-document-object skill (the inverse of /sap-gen-abap's spec-to-code flow).
  Prerequisites: pinned connection (/sap-login). Class source download, --callers,
  and --format docx/xlsx need an active SAP GUI session / the anthropic-skills
  docx|xlsx skills; programs/includes/FMs read over RFC (no GUI).
argument-hint: "<OBJECT_NAME> [--type program|include|fm|class|auto] [--callers] [--no-gui] [--depth N] [--spec] [--format md|docx|xlsx] [--audience functional|technical]"
---

# SAP Explain Object Skill

Produces a read-only "object dossier" for an existing ABAP object: what it does,
its internal structure and call graph, the data it touches, its dependencies,
and a change-impact note. Pure read — never deploys, activates, or edits.

With **`--spec`** the same comprehension base is upgraded into a **formal,
review-ready specification document** (Markdown / Word / a filled
`spec_template.xlsx`) — the inverse of `/sap-gen-abap`'s spec-to-code flow. That
mode (Step 7.5) folds in the former `/sap-document-object` skill.

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
| `sap_object_resolver.ps1` (again) | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1` | `Read-SapTableRows` for the `--spec` DD02T/DD03L/T100 enrichment |
| `spec_template.xlsx` | `<SAP_DEV_CORE_SHARED_DIR>\templates\spec_template.xlsx` | (`--spec --format xlsx`) the 17-sheet layout filled from the enriched map — round-trips into `/sap-docs-extract` |
| `sap_log_helper.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1` | structured logging |

**Skills orchestrated in `--spec` mode** (skills-first): `anthropic-skills:docx`
(`--format docx`), `anthropic-skills:xlsx` (`--format xlsx`).

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

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Write this run's generated scratch (`explain_dl.vbs`) and the `_run.json` log state under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) for `{OUT}` and `Get-SapCurrentSessionPath -WorkTemp`.

## Step 0.5 — Start Logging (best-effort)

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_explain_object_run.json" -Skill sap-explain-object -ParamsJson "{\"args\":\"{RAW_ARGS}\"}"
```
The `-StateFile` carries the `run_id` between this start and the Final end event — pass the same path to both; no `RUN_ID=` capture is needed.

## Step 1 — Parse Arguments

- `{OBJECT}` = first positional, uppercased.
- `--type` -> `{TYPE}` (default `auto`).
- `--callers` -> `{CALLERS}` = true (default false; requires GUI session).
- `--no-gui` -> `{NOGUI}` = true (RFC-only; classes degrade to signature only).
- `--depth N` -> `{DEPTH}` (default 3).
- `--spec` -> `{SPEC}` = true (default false; activates the **spec-document mode**, Step 7.5).
- `--format` -> `{FORMAT}` (default `md`; `md` | `docx` | `xlsx`; only meaningful with `--spec`).
- `--audience` -> `{AUDIENCE}` (default `technical`; `functional` | `technical`; only with `--spec`).

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
$vbs = ([System.IO.File]::ReadAllText("$skillSe24\references\sap_se24_check_and_download.vbs", [System.Text.Encoding]::UTF8)).
  Replace('%%CLASS_NAME%%','{OBJECT}').
  Replace('%%OUTPUT_FILE%%','{OUT}\source.txt').
  Replace('%%SESSION_PATH%%','').
  Replace('%%SYNTAX_CHECK_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_syntax_check_lib.vbs').
  Replace('%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\explain_dl.vbs', $vbs, [System.Text.UnicodeEncoding]::new($false, $true))
```
```bash
"C:/Windows/SysWOW64/cscript.exe" //NoLogo "{RUN_TEMP}\explain_dl.vbs"
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

## Step 7.5 — Spec-Document Mode (`--spec` only)

**Skip this entire section unless `--spec` was passed.** In spec mode you upgrade
the Step-7 dossier into a **formal, review-ready specification document** — the
inverse of `/sap-gen-abap`'s spec-to-code flow, and a customer-grade deliverable
rather than a developer dossier. (This folds in the former `/sap-document-object`
skill.) Still **read-only**.

### 7.5a — Enrich over RFC (best-effort)

Deepen `{OUT}\map.json` with system-confirmed detail, writing `{OUT}\enriched.json`.
RFC-optional — a read failure degrades that section to `COULD_NOT_CHECK`, never a
silent gap. Use **`Read-SapTableRows`** (from `sap_object_resolver.ps1`, already
dot-sourced in Step 3) — do NOT hand-roll `New-RfcReadTable -QueryTable/-Where/-Fields`
(not its signature; WHERE/fields go through `Add-RfcOption`/`Add-RfcField`).

```powershell
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1'   # Read-SapTableRows
$dest = Connect-SapRfc -DestName "EXPLAIN"   # creds fall back to pinned profile
$keys = Read-SapTableRows -Destination $dest -Table 'DD03L' `
          -Where "TABNAME = '<T>' AND KEYFLAG = 'X'" -Fields @('FIELDNAME','ROLLNAME')
```

| Enrichment | Source | Use |
|---|---|---|
| Table short text | `DD02T` (`TABNAME`, `DDLANGUAGE`) | Data-model section: human name per table. **Language fallback required** — try the logon language first, then any (`… WHERE TABNAME = '<T>'`, first row). Custom tables often carry text only in the author's language (JA/ZH); mark `COULD_NOT_CHECK` only if *no* language row exists. |
| Table key fields | `DD03L` (`TABNAME`, `KEYFLAG='X'`) | Data-model section: keys per table |
| Message texts | `T100` (`SPRSL`, `ARBGB` = msg class, `MSGNR`) | Messages section: text per `MESSAGE` referenced in source |
| Authorization objects | the `AUTHORITY-CHECK OBJECT '…'` literals in `source.txt` | Authorizations section |
| Callers | from `--callers` (`map.json.callers`) | Dependencies / change-impact |

(`Read-SapTableRows` / the underlying `New-RfcReadTable` auto-apply
`Assert-RfcReadTableAllowed` — never read `REPOSRC`.)

### 7.5b — Synthesize the Spec (Markdown canonical)

Write `{OUT}\{OBJECT}.spec.md`. Mark each section **CONFIRMED** (read from the
system) or **INFERRED** (reasoned). Omit sections N/A for the object type; trim
internals for `--audience functional`:

1. **Overview / Purpose** — *inferred* from names, comments, selection screen, DB tables.
2. **Interface contract & selection screen** — parameters / select-options / FM signature (*confirmed*).
3. **Processing logic** — step-by-step narrative walked from `map.json` units + call graph.
4. **Data model** — tables read vs written, with DD02T short texts + DD03L keys (*confirmed*).
5. **Dependencies** — FMs / classes / includes / SUBMIT / CALL TRANSACTION; callers if `--callers`.
6. **Authorizations** — every `AUTHORITY-CHECK` object found.
7. **Messages** — message class + number + T100 text.
8. **Enhancements** — BAdIs / exits invoked (from the call graph).
9. **Error handling** — exception classes, `SY-SUBRC` handling, `MESSAGE` types.
10. **Assumptions & open questions** *(honesty section, never omit)* — inferred vs
    confirmed; dynamic dispatch not resolved (`CALL FUNCTION lv_`, dynamic `SELECT`,
    `SUBMIT (rep)`); class source is the pretty-print display view; any
    `COULD_NOT_CHECK` enrichment.

### 7.5c — Render (`--format`)

- **`md`** (default) — the `.spec.md` from 7.5b is the deliverable.
- **`docx`** — invoke `anthropic-skills:docx` to render `{OBJECT}.spec.md` into
  `{OUT}\{OBJECT}.spec.docx` (sign-off Word: heading styles + the data-model /
  messages / dependencies tables).
- **`xlsx`** — invoke `anthropic-skills:xlsx` to copy `spec_template.xlsx` and fill
  it from `enriched.json` so the result round-trips through `/sap-docs-extract`:

  | spec_template sheet | Filled from |
  |---|---|
  | Cover | object name / type / package / system |
  | Selection Definition / Selection Screen | `map.json.selection_screen` |
  | Tables | `db_reads` / `db_writes` + DD02T text |
  | Data Elements | data elements behind selection params / key fields |
  | Error Messages | T100 enrichment |
  | Processing Flow | the 7.5b §3 narrative |
  | Dependencies | externals + callers |

  Sheets with no source data are left as the template prompts; **list every
  unmapped sheet** in the run summary (do not imply a full spec).

The spec is a **draft for human review**, not authoritative — say so in the summary.

## Step 8 — Report & Clean Up
Print the `{OUT}` path and a 5-line summary. In `--spec` mode also name the spec
deliverable (`.spec.md` / `.spec.docx` / filled `spec_template.xlsx`), the
confirmed-vs-inferred balance, and any `COULD_NOT_CHECK` enrichment or unmapped
xlsx sheets — stating plainly it is a draft for human review. Leave `{OUT}`
artifacts in place (read-only deliverable). Remove only scratch VBS in `{RUN_TEMP}`.

## Final — Log End
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_explain_object_run.json" -Status SUCCESS -ExitCode 0
```
(On failure use `-Status FAILED -ExitCode 1`; for the not-found path add `-ErrorClass OBJECT_NOT_FOUND`. `-Status` must be one of `SUCCESS|FAILED|SKIPPED|EXISTED|ABANDONED`.)

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
- **`--spec` produces a DRAFT, not ground truth.** Purpose and processing narrative
  are *inferred* and flagged as such — for human review, not sign-off without it.
- **`--spec` DDIC / message enrichment is RFC-optional** — degrades to `COULD_NOT_CHECK`.
- **`--spec --format xlsx` fidelity is best-effort** — only sheets with a clear map
  source are filled; unmapped sheets are reported, never silently left looking complete.
