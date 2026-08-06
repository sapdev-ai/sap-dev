---
name: sap-where-used-list
description: |
  Runs SAP's Where-Used List (Verwendungsnachweis, Ctrl+Shift+F3) for any
  ABAP repository object across SE11, SE38, SE37, SE24, and SE91 — i.e.
  before deleting an object, find every program / class / FM / DDIC
  reference. Routes to the right initial screen by OBJECT_TYPE, fills
  the name, sends Ctrl+Shift+F3, ticks every scope on the popup, then
  branches: NOT_FOUND when SAP says no usages, FOUND_LIST when a list is
  rendered and the status bar is clean, SPOOL_CREATED:<num> when called
  with TO_SPOOL=X (so the operator can chain into /sap-sp02 to download
  the list), or INCONCLUSIVE when SAP answers with a message instead of
  a list — which is never reported as a usage verdict in either direction.
  Pure read-only — never modifies the SAP system.
  Prerequisites: Active SAP GUI session (use /sap-login first).
argument-hint: "<OBJECT_TYPE> <OBJECT_NAME> [--to-spool]"
---

# SAP Where-Used List Skill

You run a Where-Used List against an ABAP repository object so the
operator can see every reference before deleting / refactoring it. The
skill is a thin GUI driver: it picks the right transaction by
OBJECT_TYPE, fills the name field, sends `Ctrl+Shift+F3`, ticks "Select
all" on the scope popup, and reports NOT_FOUND, FOUND_LIST,
SPOOL_CREATED:<num>, or INCONCLUSIVE.

**A rendered screen is not evidence of usages.** Both verdicts this skill
can get wrong are expensive: a false NOT_FOUND gets a referenced object
deleted, a false FOUND_LIST tells a developer an object is still in use
when it is not. So the reader only claims a usage list when the status bar
is silent or `S`; every other MessageType is reported as INCONCLUSIVE with
SAP's own message attached.

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
# Session-attach plumbing (Phase 4.2). Resolution: explicit --session > this AI
# session's pin, BAKED into %%SESSION_PATH%% (attach Strategy 1). Do NOT export
# $env:SAPDEV_SESSION_PATH instead: this generator is a SEPARATE process from the
# one that runs cscript, so the env var would already be gone and the helper would
# silently fall through to its sole-connection default -- which would list the
# callers found on a DIFFERENT SAP system than the one asked about (2026-08-06).
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$sessionPath = ''  # set to the parsed --session value if supplied
if (-not $sessionPath) { $sessionPath = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}' }
$content  = $content.Replace('%%SESSION_PATH%%',     $sessionPath)
$content  = $content.Replace('%%ATTACH_LIB_VBS%%',   '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_where_used_list_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host ("Done (session_path='" + $sessionPath + "')")
```

Run via 32-bit cscript:

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_where_used_list_run.ps1"
C:\Windows\SysWOW64\cscript.exe //NoLogo {RUN_TEMP}\sap_where_used_list_run.vbs
```

---

## Step 4 — Interpret the Output

| Last line | Meaning |
|---|---|
| `NOT_FOUND: <TYPE> <NAME> has no usages in the selected scope.` | SAP returned the "no occurrences" popup. Object is **safe to delete** as far as the workbench knows (cross-system / Z-table-based / RTTI usages still need a manual check). |
| `FOUND_LIST: <TYPE> <NAME> has usages — list shown on screen (no spool requested).` | A list is rendered **and** the status bar is silent or `S`, so the object really is referenced. No spool was requested (operator passed no `--to-spool`); the operator can read the list interactively. |
| `SPOOL_CREATED: <NUM>` | List was written to spool `<NUM>`. To download as a text file, chain into `/sap-sp02 <NUM> <PATH>`. |
| `INCONCLUSIVE: [<MSGTYPE>] <TYPE> <NAME> — <SAP's message>` | SAP answered with a message (`I`, `W`, …) instead of a usage list. **Not a verdict in either direction** — neither delete-safe nor "has usages". Surface SAP's own message verbatim; it usually states the outcome plainly (e.g. an `I` reading "not found in selected search area" = no usages on S/4HANA 1909). |
| `ERROR: Where-Used List did not start … the object may not exist …` | The object name was not found (SAP stayed on the initial screen, no scope popup). This is **not** a delete-safe result — verify the name / type, do **not** treat it as NOT_FOUND. |
| `ERROR: Where-Used List reported a E/A-message …` | The list step raised an error (object not readable / not found). Cannot determine usages — surface verbatim; never a delete-safe verdict. |
| `ERROR: Unexpected popup after scope selection …` | A modal with OPTION1 appeared that is not the confirmed "no usages" popup. Cannot confirm "no usages" safely — re-run or inspect via `/sap-gui-inspect`. |
| `ERROR: Could not parse spool number from sbar: '...'` | Print succeeded but the sbar message did not contain a 4+ digit spool number (unusual locale / SAP version). Open SP02 manually, take the most recent spool, then run `/sap-sp02`. |
| Other `ERROR: …` | Surface verbatim and consult Step 7. |

**Delete-safety:** only `NOT_FOUND` is a (workbench-scope) delete-safe verdict.
`ERROR:` and `INCONCLUSIVE:` are **never** delete-safe — a nonexistent object, a
read error, or a run SAP declined to answer must never be reported as "safe to
delete". Callers that gate a deletion on this skill (`/sap-cc-decommission`,
`/sap-cc-usage`) treat `INCONCLUSIVE` like an unresolved reference: SKIP the
object and tell the operator, never retire it.

**`INCONCLUSIVE` is equally not a "has usages" verdict.** Don't paraphrase it as
"the object is still referenced" — report what SAP said. On S/4HANA 1909 an `I`
here has been observed to mean the exact opposite (no usages at all). Mapping `I`
to NOT_FOUND is deliberately **not** hard-coded in the reader: the MessageType
code alone does not carry that meaning on every release, and the mapping needs
confirming on a second release first.

---

## Step 5 — Report

For NOT_FOUND, tell the user the object has no usages in the standard
ABAP-Workbench scope and is therefore (probably) safe to delete. Add
the caveat that **dynamic references** (CALL FUNCTION '...', CREATE
DATA dyn, GENERATE SUBROUTINE POOL, RFCs from external systems) are
NOT covered by where-used and must be checked separately.

For FOUND_LIST, tell the user the list is on screen and recommend
re-running with `--to-spool` if they want a saved copy.

For INCONCLUSIVE, quote SAP's own message and its type, and say plainly
that the run produced **no** usage verdict — the object is neither
confirmed used nor confirmed safe to delete. Read the message before
recommending anything: it usually states the outcome directly, and on the
observed 1909 case it meant "no usages" even though the reader refuses to
assert that itself. Offer the manual re-check (`--to-spool`, or driving
the where-used by hand in the mapped transaction).

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

Suggested `<CLASS>`: `WHERE_USED_FAILED`, `WHERE_USED_PRINT_FAILED`,
`WHERE_USED_INCONCLUSIVE`, `GUI_TIMEOUT`. An `INCONCLUSIVE:` last line logs as
`-Status FAILED -ExitCode 1 -ErrorClass WHERE_USED_INCONCLUSIVE` — the reader
ran fine, but the run yielded no usage verdict, and logging it as SUCCESS would
hide exactly the case this contract exists to surface.

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
| `INCONCLUSIVE: [I] …` on an object you expect to be unused | SAP reported the outcome as an information message rather than the "no usages" SPOP popup. Observed on S/4HANA 1909 with `PROGRAM ZCMRUPDATE_ADDON_TABLE`: `[I] … not found in selected search area` | Read SAP's message — here it means no usages. The reader will not translate `I` into NOT_FOUND for you; if you confirm the same mapping on a second release, narrow the step-7 branch in the VBS and update this contract in the same commit |
| `INCONCLUSIVE: [W] …` on an object that does have usages | A warning accompanied a genuinely rendered list. The gate is deliberately conservative: it trades this false INCONCLUSIVE for never emitting a false FOUND_LIST | Re-run with `--to-spool` and read the spool, or read the list on screen. Report the warning text if it recurs — a confirmed benign W could earn an explicit allow |
| SE11 `TABLE` where-used ends in `ERROR: Unexpected popup after scope selection` | Verified live on S/4HANA 1909 with `TABLE MARA`: SE11 interposes one more modal after scope selection — the pre-unlock sweep logged its title as "Use of a Table" on an EN logon — and it carries `btnSPOP-OPTION1` too, so the reader refuses rather than press an unfingerprinted button. **Open question:** whether this is TABLE-specific (likely) or specific to a table of MARA's size — probe a small `Z` table to find out | Correct refusal — do **not** read it as a verdict in either direction. To handle it explicitly: record the dialog once with `/sap-gui-probe --record`, branch on a *discriminating* control ID (never OPTION1 alone — that's the id the real "no usages" popup uses), and add a checkpoint to `sap_where_used_list.screens.json` in the same commit. Until then, drive TABLE where-used by hand in SE11 |
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
