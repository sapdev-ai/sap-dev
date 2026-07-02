---
name: sap-document-object
description: |
  Reverse of the spec-to-code pipeline: turns an EXISTING ABAP object into a
  formal, review-ready specification document. Builds on /sap-explain-object's
  comprehension engine (active source + structure + call/data map), then ENRICHES
  it over RFC — DDIC table short texts + key fields (DD02T/DD03L), message-class
  texts (T100), and optional where-used callers — and renders a sectioned spec:
  Markdown by default, Word (--format docx) for sign-off, or a filled
  spec_template.xlsx workbook (--format xlsx) that round-trips back through
  /sap-docs-extract. Every section is marked CONFIRMED (read from the system) vs
  INFERRED (reasoned from names/comments), and an honest "Assumptions & open
  questions" section never lets a guess masquerade as fact. Pairs with
  /sap-explain-object (comprehension) and /sap-activate-object via the -object
  suffix. Read-only: never modifies the SAP system.
  Prerequisites: pinned connection (/sap-login) for object input; class source
  download and --callers additionally need an active SAP GUI session. An existing
  explain output folder can be passed instead (no re-acquisition).
argument-hint: "<OBJECT_NAME | explain-out-folder> [--format md|docx|xlsx] [--callers] [--depth N] [--audience functional|technical] [--no-gui]"
---

# SAP Document Object Skill

You produce a **formal specification document for an existing ABAP object** — the
inverse of `/sap-gen-abap`'s spec-to-code flow, and a customer-grade upgrade of the
`/sap-explain-object` dossier. You reuse the comprehension engine, enrich it with
DDIC / message detail over RFC, and render a sectioned deliverable. You are
**read-only**.

This skill observes `shared/rules/skill_operating_rules.md` (reads only).

Task: $ARGUMENTS

> **Relationship to `/sap-explain-object`.** That skill answers "what is this and
> how does it work" for a developer (a `dossier.md`). This skill produces a
> *deliverable* — a sign-off-grade functional/technical spec, optionally as Word or
> a reverse-engineered spec workbook. It reuses explain-object's map rather than
> re-deriving it.

---

## Shared Resources

| File / token | Path | Purpose |
|---|---|---|
| `sap_settings_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1` | settings merge |
| `sap_connection_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1` | `Get-SapWorkDir` |
| `sap_rfc_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1` | `Connect-SapRfc` |
| `sap_object_resolver.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1` | `Read-SapTableRows` (DD02T/DD03L/T100 enrichment) |
| explain engine | `<SKILL_DIR>\..\sap-explain-object` | invoked as `/sap-explain-object` (skills-first) for `map.json` + `source.txt` + `dossier.md` |
| `spec_template.xlsx` | `<SAP_DEV_CORE_SHARED_DIR>\templates\spec_template.xlsx` | the 17-sheet layout `--format xlsx` fills (round-trips into `/sap-docs-extract`) |
| `sap_log_helper.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1` | structured logging |

**Skills this one orchestrates** (skills-first): `/sap-explain-object`
(comprehension + optional `--callers`), `anthropic-skills:docx` (`--format docx`),
`anthropic-skills:xlsx` (`--format xlsx`).

`<SAP_DEV_CORE_SHARED_DIR>` = `plugins/sap-dev-core/shared` — 2 levels up from
`<SKILL_DIR>` then into `shared` (this skill lives in sap-dev-core).

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp`, `{OUT}` = `{WORK_TEMP}\document\{OBJECT}`.

```bash
cmd /c if not exist "{OUT}" mkdir "{OUT}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's `_run.json` log state under `{RUN_TEMP}`; `{OUT}` stays the durable output folder.

---

## Step 0.5 — Start Logging (best-effort)

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_document_object_run.json" -Skill sap-document-object -ParamsJson "{\"target\":\"<OBJECT>\"}"
```

---

## Step 1 — Parse Arguments

| Arg | Default | Notes |
|---|---|---|
| positional | — | Object name (uppercase) OR a path to an existing `/sap-explain-object` output folder (contains `map.json`). |
| `--format` | `md` | `md` (Markdown), `docx` (Word, via the docx skill), `xlsx` (filled spec workbook, via the xlsx skill). |
| `--callers` | false | Include where-used callers (passed through to explain-object; GUI session). |
| `--depth N` | `3` | Include-tree depth (passed to explain-object). |
| `--audience` | `technical` | `functional` (business-facing, lighter on internals) or `technical` (full structure). |
| `--no-gui` | false | RFC-only; class bodies degrade to signature; `--callers` ignored. |

If the positional is missing, ask and stop.

---

## Step 2 — Acquire the Comprehension Base

- **If an explain output folder was passed** → reuse it: read `map.json`,
  `source.txt`, and `dossier.md` from it. Skip to Step 3.
- **Else (object name)** → invoke **`/sap-explain-object {OBJECT} [--callers]
  [--depth N] [--no-gui]`** (skills-first — do not re-implement acquisition). It
  writes `{WORK_TEMP}\explain\{OBJECT}\` with `map.json` + `source.txt` (+
  `dossier.md`). Use that folder as `{EXPLAIN_OUT}`.

If explain-object reports the object is not a program/include/FM/class (e.g. a
DDIC table), redirect per its guidance and stop.

---

## Step 3 — Enrich over RFC (best-effort)

Deepen `map.json` with system-confirmed detail. RFC-optional — a read failure
degrades that section to `COULD_NOT_CHECK`, never a silent gap.

Use **`Read-SapTableRows`** (from `sap_object_resolver.ps1`) — the validated
reader: `Read-SapTableRows -Destination $dest -Table <T> -Where "<sql>" -Fields @(...) [-RowCount n]`.
Do NOT hand-roll `New-RfcReadTable -QueryTable/-Where/-Fields` (that is not the
helper's signature — `New-RfcReadTable` takes only `-Destination`/`-Table`, with
`Add-RfcOption`/`Add-RfcField` for the WHERE/field list).

```powershell
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1'   # Read-SapTableRows
$dest = Connect-SapRfc -DestName "DOCOBJ"   # creds fall back to pinned profile
$keys = Read-SapTableRows -Destination $dest -Table 'DD03L' `
          -Where "TABNAME = '<T>' AND KEYFLAG = 'X'" -Fields @('FIELDNAME','ROLLNAME')
```

| Enrichment | Source | Use |
|---|---|---|
| Table short text | `DD02T` (`TABNAME`, `DDLANGUAGE`) | Data-model section: human name per table. **Language fallback required** — try the logon language first, then any (`SELECT … WHERE TABNAME = '<T>'` and pick the first row). Custom tables on multilingual systems often carry text only in the author's language (e.g. JA/ZH), so an EN-only lookup returns empty; mark `COULD_NOT_CHECK` only if *no* language row exists. |
| Table key fields | `DD03L` (`TABNAME`, `KEYFLAG='X'`) | Data-model section: keys per table |
| Message texts | `T100` (`SPRSL`, `ARBGB` = msg class, `MSGNR`) | Messages section: text per `MESSAGE` referenced in source |
| Authorization objects | the `AUTHORITY-CHECK OBJECT '…'` literals in `source.txt` | Authorizations section |
| Callers | from explain-object `--callers` (`map.json.callers`) | Dependencies / change-impact |

Write the merged view to `{OUT}\enriched.json`. (`Read-SapTableRows` / the
underlying `New-RfcReadTable` auto-apply `Assert-RfcReadTableAllowed` — never read
`REPOSRC`.)

---

## Step 4 — Synthesize the Spec (Markdown canonical)

Write `{OUT}\{OBJECT}.spec.md`. Mark each section **CONFIRMED** (read from the
system) or **INFERRED** (reasoned). Sections (omit those N/A for the object type;
trim internals for `--audience functional`):

1. **Overview / Purpose** — *inferred* from names, comments, selection screen, DB tables.
2. **Interface contract & selection screen** — parameters / select-options / FM signature (*confirmed*).
3. **Processing logic** — step-by-step narrative walked from `map.json` units + call graph.
4. **Data model** — tables read vs written, with DD02T short texts + DD03L keys (*confirmed*).
5. **Dependencies** — FMs / classes / includes / SUBMIT / CALL TRANSACTION; callers if `--callers`.
6. **Authorizations** — every `AUTHORITY-CHECK` object found.
7. **Messages** — message class + number + T100 text.
8. **Enhancements** — BAdIs / exits invoked (from the call graph).
9. **Error handling** — exception classes, `SY-SUBRC` handling, `MESSAGE` types.
10. **Assumptions & open questions** *(honesty section, never omit)* — what is
    inferred vs confirmed; dynamic dispatch not resolved (`CALL FUNCTION lv_`,
    dynamic `SELECT`, `SUBMIT (rep)`); class source is the pretty-print display
    view; any `COULD_NOT_CHECK` enrichment.

---

## Step 5 — Render (`--format`)

- **`md`** (default) — the `.spec.md` from Step 4 is the deliverable.
- **`docx`** — invoke `anthropic-skills:docx` to render `{OBJECT}.spec.md` into
  `{OUT}\{OBJECT}.spec.docx` (sign-off-grade Word: heading styles, the tables from
  the data-model / messages / dependencies sections).
- **`xlsx`** — invoke `anthropic-skills:xlsx` to copy `spec_template.xlsx` and fill
  it from `enriched.json`, mapping into the matching sheets so the result
  round-trips through `/sap-docs-extract`:

  | spec_template sheet | Filled from |
  |---|---|
  | Cover | object name / type / package / system |
  | Selection Definition / Selection Screen | `map.json.selection_screen` |
  | Tables | `db_reads` / `db_writes` + DD02T text |
  | Data Elements | data elements behind selection params / key fields |
  | Error Messages | T100 enrichment |
  | Processing Flow | the Step-4 §3 narrative |
  | Dependencies | externals + callers |

  Sheets with no source data are left as the template prompts; **list every
  unmapped sheet** in the run summary (do not imply a full spec).

---

## Step 6 — Report

Print the `{OUT}` path and a ≤6-line summary: object/type, format produced, the
confirmed-vs-inferred balance (how much is system-read vs reasoned), and any
`COULD_NOT_CHECK` enrichment or unmapped `xlsx` sheets. State plainly that this is
a **draft for human review**, not authoritative.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_document_object_run.json" -Status SUCCESS -ExitCode 0
```

(Object not found → `-ExitCode 1 -ErrorClass OBJECT_NOT_FOUND`; RFC enrichment
unavailable is non-fatal — finish with the sections marked `COULD_NOT_CHECK`.)

---

## Limitations

- **A draft, not ground truth.** Purpose and processing narrative are *inferred*
  and flagged as such — for human review, not sign-off without it.
- **Inherits explain-object's caveats** — class source is the pretty-print display
  view; macros / generated code are best-effort; dynamic dispatch is disclosed, not
  resolved.
- **`--format xlsx` fidelity is best-effort** — only sheets with a clear map source
  are filled; unmapped sheets are reported, never silently left looking complete.
- **DDIC / message enrichment is RFC-optional** — degrades to `COULD_NOT_CHECK`.
- **Read-only.** Never modifies SAP.

---

## Pipeline Integration

```
/sap-explain-object ──► [ sap-document-object ] ──► .spec.md | .spec.docx | spec_template.xlsx
   (comprehension)         (enrich + render)                                        │
                                                                                    └──► /sap-docs-extract  (round-trip)
```

The inverse of `/sap-gen-abap` (spec → code). `--format xlsx` closes the loop: an
undocumented brownfield object becomes a design workbook that the forward pipeline
can re-consume.
