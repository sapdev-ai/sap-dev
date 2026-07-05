---
name: sap-where-used-list
description: |
  Runs SAP's Where-Used List (Verwendungsnachweis, Ctrl+Shift+F3) for any
  ABAP repository object across SE11, SE38, SE37, SE24, and SE91 — i.e.
  before deleting an object, find every program / class / FM / DDIC
  reference. Routes to the right initial screen by OBJECT_TYPE, fills
  the name, sends Ctrl+Shift+F3, ticks every scope on the popup, then
  branches: NOT_FOUND when SAP says no usages, FOUND_LIST when the list
  is rendered, or SPOOL_CREATED:<num> when called with TO_SPOOL=X
  (so the operator can chain into /sap-sp02 to download the list).
  Pure read-only — never modifies the SAP system.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<OBJECT_TYPE> <OBJECT_NAME> [--to-spool]"
---

# SAP Where-Used List Skill

You run a Where-Used List against an ABAP repository object so the
operator can see every reference before deleting / refactoring it. The
skill is a thin GUI driver: it picks the right transaction by
OBJECT_TYPE, fills the name field, sends `Ctrl+Shift+F3`, ticks "Select
all" on the scope popup, and reports either NOT_FOUND, FOUND_LIST, or
SPOOL_CREATED:<num>.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `<SKILL_DIR>/references/sap_where_used_list.vbs` | many | Multi-txn router + scope popup + optional Print-to-spool branch |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`.
| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists:

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

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_where_used_list_run.json" -Skill sap-where-used-list -ParamsJson "{\"object_type\":\"<TYPE>\",\"object_name\":\"<NAME>\"}"
```

Best-effort.

---

## Step 1 — Parse Arguments

| Arg | Required | Notes |
|---|---|---|
| `OBJECT_TYPE` | yes | One of: `TABLE`, `VIEW`, `DATAELEMENT`, `STRUCTURE`, `TABLETYPE`, `TYPEGROUP`, `DOMAIN`, `SEARCHHELP`, `LOCKOBJECT` (→ SE11), `PROGRAM` (→ SE38), `FM` (→ SE37), `CLASS` / `INTERFACE` (→ SE24), `MESSAGE_CLASS` (→ SE91). |
| `OBJECT_NAME` | yes | UPPERCASE repository name. |
| `--to-spool` | no | Send the rendered list to a SAP spool so a follow-up `/sap-sp02` can download it. Default: leave the list on screen and just count usages. |

**Map OBJECT_TYPE → TXN.** This determines which initial screen the
VBS opens and which name field it fills.

| OBJECT_TYPE | TXN | Name field |
|---|---|---|
| `TABLE` / `VIEW` / `DATAELEMENT` / `STRUCTURE` / `TABLETYPE` / `TYPEGROUP` / `DOMAIN` / `SEARCHHELP` / `LOCKOBJECT` | `SE11` | `ctxtRSRD1-<radio>_VAL` (radio + name field per type — same map as `/sap-se11` Step 6c) |
| `PROGRAM` | `SE38` | `ctxtRS38M-PROGRAMM` |
| `FM` | `SE37` | `ctxtRS38L-NAME` |
| `CLASS` / `INTERFACE` | `SE24` | `ctxtSEOCLASS-CLSNAME` |
| `MESSAGE_CLASS` | `SE91` | `ctxtRSDAG-ARBGB` |

**Trigger phrases:**

- "where used `<NAME>`" / "where-used list of `<NAME>`"
- "find references to `<NAME>`" / "who uses `<NAME>`"
- "check usages of `<NAME>` before delete" / "is `<NAME>` safe to delete"
- "save where-used to spool for `<NAME>`" → adds `--to-spool`

---

## Step 2 — Ensure SAP GUI Session

Run `/sap-login` if no session is active.

---

## Step 3 — Generate and Run the VBS

Map the operator's OBJECT_TYPE to the `TXN` token (see table above).
For SE11 also set `OBJECT_TYPE` so the VBS picks the right radio. For
all other transactions set `OBJECT_TYPE` empty.

Set `TO_SPOOL` to `X` if `--to-spool`, else leave empty.

Write `{RUN_TEMP}\sap_where_used_list_run.ps1`:

```powershell
$skillDir = '<SKILL_DIR>'
$content  = [System.IO.File]::ReadAllText("$skillDir\references\sap_where_used_list.vbs", [System.Text.Encoding]::UTF8)
$content  = $content.Replace('%%TXN%%',             'THE_TXN')
$content  = $content.Replace('%%OBJECT_TYPE%%',     'THE_OBJECT_TYPE')   # empty unless TXN=SE11
$content  = $content.Replace('%%OBJECT_NAME%%',     'THE_OBJECT_NAME')
$content  = $content.Replace('%%TO_SPOOL%%',        'THE_TO_SPOOL')      # 'X' or empty
$content  = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
# Session-attach plumbing (Phase 3.5 multi-connection aware). Resolution:
# explicit --session > SAPDEV_SESSION_PATH > sole-
# connection auto-default > refuse. See sap_attach_lib.vbs for details.
$sessionPath = ''  # set to the parsed --session value if supplied
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_where_used_list_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Run via cscript:

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_where_used_list_run.ps1"
cscript //NoLogo {RUN_TEMP}\sap_where_used_list_run.vbs
```

---

## Step 4 — Interpret the Output

| Last line | Meaning |
|---|---|
| `NOT_FOUND: <TYPE> <NAME> has no usages in the selected scope.` | SAP returned the "no occurrences" popup. Object is **safe to delete** as far as the workbench knows (cross-system / Z-table-based / RTTI usages still need a manual check). |
| `FOUND_LIST: <TYPE> <NAME> has usages — list shown on screen (no spool requested).` | List is rendered but no spool was requested (operator passed no `--to-spool`). The operator can read it interactively. |
| `SPOOL_CREATED: <NUM>` | List was written to spool `<NUM>`. To download as a text file, chain into `/sap-sp02 <NUM> <PATH>`. |
| `ERROR: Where-Used List did not start … the object may not exist …` | The object name was not found (SAP stayed on the initial screen, no scope popup). This is **not** a delete-safe result — verify the name / type, do **not** treat it as NOT_FOUND. |
| `ERROR: Where-Used List reported a E/A-message …` | The list step raised an error (object not readable / not found). Cannot determine usages — surface verbatim; never a delete-safe verdict. |
| `ERROR: Unexpected popup after scope selection …` | A modal with OPTION1 appeared that is not the confirmed "no usages" popup. Cannot confirm "no usages" safely — re-run or inspect via `/sap-gui-inspect`. |
| `ERROR: Could not parse spool number from sbar: '...'` | Print succeeded but the sbar message did not contain a 4+ digit spool number (unusual locale / SAP version). Open SP02 manually, take the most recent spool, then run `/sap-sp02`. |
| Other `ERROR: …` | Surface verbatim and consult Step 7. |

**Delete-safety:** only `NOT_FOUND` is a (workbench-scope) delete-safe verdict. An
`ERROR:` result is **never** delete-safe — a nonexistent object or a read error
must never be reported as "safe to delete".

---

## Step 5 — Report

For NOT_FOUND, tell the user the object has no usages in the standard
ABAP-Workbench scope and is therefore (probably) safe to delete. Add
the caveat that **dynamic references** (CALL FUNCTION '...', CREATE
DATA dyn, GENERATE SUBROUTINE POOL, RFCs from external systems) are
NOT covered by where-used and must be checked separately.

For FOUND_LIST, tell the user the list is on screen and recommend
re-running with `--to-spool` if they want a saved copy.

For SPOOL_CREATED, tell the user the spool number AND the exact
follow-up command:

```text
/sap-sp02 <SPOOL_NUM> <C:\path\to\where_used_<NAME>.txt>
```

That two-step composition (where-used to spool → SP02 download) is
the documented chain.

---

## Step 6 — Clean Up

```bash
cmd /c del {RUN_TEMP}\sap_where_used_list_run.vbs & del {RUN_TEMP}\sap_where_used_list_run.ps1
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_where_used_list_run.json" -Status SUCCESS -ExitCode 0
```

On failure:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_where_used_list_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `WHERE_USED_FAILED`, `WHERE_USED_PRINT_FAILED`, `GUI_TIMEOUT`.

---

## Step 7 — Troubleshooting

The VBS uses two shortcuts that can shift between SAP releases:

- **`sendVKey 39`** = Ctrl+Shift+F3 = "Where-Used List" — stable across
  every ABAP Workbench transaction we drive (SE11/SE24/SE37/SE38/SE91).
- **List > Print > Print** menu path
  (`mbar/menu[0]/menu[7]/menu[0]`) — the index path is stable across
  languages but can shift one slot between SAP releases. The VBS falls
  back to `tbar[1]/btn[32]` if the menu path fails.
- **Print params dialog** (`SAPLSPRI:0600`) — the field
  `cmbPRIPAR_DYN-PRIMM2` and the commit button `btn[13]` come from the
  S/4HANA 1909 recording. Older releases used different column layouts.

When any GUI step fails with "control could not be found by id", run
`/sap-gui-inspect screenshot full` first (visual + structural dump for the
topmost window) before guessing.

| Symptom | Diagnose | Fix |
|---|---|---|
| Scope popup never appears | The transaction may have inline scope (no popup) on this release | Surface the sbar message; the list may already be on screen |
| `Could not parse spool number from sbar` | Locale-specific message text | Open SP02 manually, look for the most recent spool by date/time; pass it to `/sap-sp02` |
| Print dialog has different field IDs | SAPLSPRI subscreen number changed | Re-record the print step on the new release; patch token positions in the VBS |

---

## Component IDs (for reference)

| Element | ID |
|---|---|
| OK code | `wnd[0]/tbar[0]/okcd` |
| SE11 sub-type radios | `wnd[0]/usr/radRSRD1-{TBMA,VIMA,DDTYPE,TYMA,DOMA,SHMA,ENQU}` |
| SE11 name fields | `wnd[0]/usr/ctxtRSRD1-{TBMA,VIMA,DDTYPE,TYMA,DOMA,SHMA,ENQU}_VAL` |
| SE38 program field | `wnd[0]/usr/ctxtRS38M-PROGRAMM` |
| SE37 FM field | `wnd[0]/usr/ctxtRS38L-NAME` |
| SE24 class field | `wnd[0]/usr/ctxtSEOCLASS-CLSNAME` |
| SE91 message-class field | `wnd[0]/usr/ctxtRSDAG-ARBGB` |
| Where-Used (Ctrl+Shift+F3) | `sendVKey 39` on `wnd[0]` |
| Scope popup: Select All | `wnd[1]/tbar[0]/btn[7]` |
| Scope popup: Continue | `wnd[1]/tbar[0]/btn[0]` |
| No-usages popup confirm | `wnd[1]/usr/btnSPOP-OPTION1` |
| List > Print > Print menu | `wnd[0]/mbar/menu[0]/menu[7]/menu[0]` |
| Print params dialog | `wnd[1]/usr/subSUBSCREEN:SAPLSPRI:0600/cmbPRIPAR_DYN-PRIMM2` |
| Print params commit | `wnd[1]/tbar[0]/btn[13]` |
| Status bar | `wnd[0]/sbar` |

---

## Composition with `/sap-sp02`

The intended chain is:

```text
/sap-where-used-list <TYPE> <NAME> --to-spool        # → SPOOL_CREATED:<NUM>
/sap-sp02 <NUM> C:\Temp\where_used_<NAME>.txt        # → local text file
```

Each skill owns one job; neither auto-invokes the other. This keeps
common "is X safe to delete?" runs cheap (no useless download when the
answer is NOT_FOUND) and makes the saved file available when the
operator wants it.

---

## Limitations

- **Standard scope only.** `tbar[0]/btn[7]` Select All ticks every
  scope SAP knows about, but **dynamic references** (`CALL FUNCTION
  '...'`, `CREATE OBJECT (cls)`, `GENERATE SUBROUTINE POOL`,
  external-system RFC calls) are not represented in the workbench
  index and won't appear in the list. A NOT_FOUND result is
  necessary-but-not-sufficient for safe deletion.
- **METHOD-level usage** is not directly supported — search the parent
  CLASS instead and grep the resulting list for the method name.
- **MESSAGE_CLASS** field-id assumption (`ctxtRSDAG-ARBGB`) is the
  default SE91 initial-screen field. If a customised SE91 layout uses
  a different field, override via the field-id table after recording
  with `/sap-gui-probe --record`.
- **Print params dialog** field positions vary by SAP release —
  S/4HANA 1909 verified; other releases may need a one-time recording
  to confirm `PRIMM2` and `btn[13]` paths.
