---
name: sap-note-status
description: |
  Answers "is SAP Note N implemented, where, and will it clash with our mods?" across every
  saved /sap-login profile in one read-only RFC pass. For each note x system it reports a
  download/implementation verdict (CWBNTHEAD + CWBNTCUST), component-level skew (CVERS), and a
  mod-collision check that joins the note's touched repository objects (CWBNTCI -> CWBCIOBJ)
  against the customer modification/adjustment log (SMODILOG) and object existence (TADIR).
  Registers CAB/audit-grade evidence. Pure RFC_READ_TABLE (all FMODE=R), so it runs against
  PRD/QA systems with no dev-init artefacts, no GUI, no Z object. Tri-state honest: a system
  with no RFC password or unreachable is COULD_NOT_CHECK (never rendered clean); a note absent
  from CWBNTHEAD is UNKNOWN_NOT_DOWNLOADED (never NOT_IMPLEMENTED -- SP/TCI-delivered fixes are
  invisible to CWB tables). Note status codes (NTSTATUS/PRSTATUS) have NO DDIC fixed values,
  so decode comes from a shipped, customer-overridable map with a confidence flag and the raw
  code always shown. Prerequisites: >=1 saved /sap-login profile with an RFC password; NCo 3.1
  (32-bit). Landscape coverage == saved profiles on THIS Windows account (DPAPI CurrentUser).
argument-hint: "<NOTE> [<NOTE> ...] [--systems <SID,SID/CLIENT,...|ALL>] [--no-collisions] [--ticket <ID>] [--json]"
---

# SAP Note Status Skill

You answer a note-implementation question across a whole landscape with ONE read-only RFC
fan-out: per-note per-system verdict + component skew + mod-collision, rendered as a matrix
and registered as evidence. You never open a GUI, never write, never claim NOT_IMPLEMENTED
without evidence.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_note_status_rfc.ps1` | `-Notes -Systems -OutDir` | The whole backend (multi-profile fan-out, matrix + collisions) |
| `<SKILL_DIR>/references/note_status_codes.tsv` | read by backend | Curated NTSTATUS/PRSTATUS decode (confidence-flagged; customer-overridable at `{custom_url}`) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_connection_lib.ps1` | dot-source | Profile store + `Resolve-SapProfileHint` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_dpapi.ps1` | dot-source / call | RFC connect + password decrypt |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` · `sap_finding_lib.ps1` | dot-source | Evidence registration + finding/coverage model |
| `/sap-login` · `/sap-compare` · `/sap-evidence-pack` | sub-skills | Profile onboarding / cross-system source diff follow-up / evidence collection |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_note_status_run.json`, skill `sap-note-status`). Pure RFC — no GUI, no
session attach, no golden-screen baseline.

## Step 1 — Parse Arguments

- **Notes** (positional, >=1): note numbers, any of `3123456` / `0003123456` / with spaces.
  The backend strips non-digits and zero-pads to NUMC(10). No note given -> hard `ERROR`
  (`NOTE_INPUT_INVALID`).
- `--systems <hints>` — comma list of `Resolve-SapProfileHint` tokens (`<SID>`,
  `<SID>/<CLIENT>`, `<SID>/<CLIENT>/<USER>`, `last`, `default`, description substring) or `ALL`.
  Default (omitted) = **every saved profile** (each with a password is queried; each without
  becomes a COULD_NOT_CHECK row). An unresolvable hint -> hard `ERROR` listing the store.
- `--no-collisions` — skip the object/mod join (faster; verdict-only).
- `--ticket <ID>` — stamp artifact registrations for `/sap-evidence-pack`.
- `--json` — also emit `note_status.json`.

## Step 2 — Run the Backend (single call, 32-bit)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File "<SKILL_DIR>\references\sap_note_status_rfc.ps1" \
  -Notes "<n1,n2>" -Systems "<hints|ALL>" [-NoCollisions] -OutDir "{RUN_TEMP}\note_status" -RunId "<run_id>"
```

Per system it prints `SYSTEM: id=.. sid=.. client=.. reachable=YES|NO release=.. comps="C:R:SP;.."`,
then per note `NOTE: sid=SID/C note=.. downloaded=.. versions=.. ntstatus=.. prstatus=..
verdict=.. confidence=D|I|U objects=.. mods=.. missing=.. flags=.. coverage=..`, then
`STATUS: OK|PARTIAL|ERROR systems=.. reachable=.. notes=..` (exit 0/1/2). It writes
`note_status_rows.tsv` + `collisions.tsv` in the OutDir. Exit 2 / STATUS ERROR = no
RFC-capable profile or all unreachable — surface and stop.

**Verdicts:** `IMPLEMENTED` · `INCOMPLETE` · `NOT_IMPLEMENTED` (downloaded, not implemented) ·
`OBSOLETE` · `CANNOT_BE_IMPLEMENTED` · `UNKNOWN_STATUS` (code has no confident decode — raw
shown) · `UNKNOWN_NOT_DOWNLOADED` (no CWBNTHEAD row) · `COULD_NOT_CHECK` (unreachable / no
password). `confidence` D=documented, I=inferred, U=unknown — surface it; never upgrade an
I/U code to a certain claim.

## Step 3 — Render the Matrix

From `note_status_rows.tsv` write:
- `note_status_matrix.md` — a **notes x systems grid** (one verdict cell each, flags appended),
  a legend, and an AI **skew/risk** summary: skew = differing verdict or component level across
  systems for a note; risk = `MOD_COLLISION` objects (from `collisions.tsv`, listed by name with
  SMODILOG user/date) and `OBJ_MISSING` objects. Every cell cites the raw status code; INFERRED /
  UNKNOWN decodes and COULD_NOT_CHECK cells are called out, never smoothed over. Recommend
  `/sap-compare` on MOD_COLLISION objects as the source-diff follow-up.
- `note_status_matrix.tsv` (copy of rows) and, with `--json`, `note_status.json`.

## Step 4 — Findings + Artifacts

- Each note with `MOD_COLLISION` -> `New-SapFinding` (severity HIGH, category `note-collision`,
  coverage CHECKED; a note with `coverage=NO_OBJECT_DATA` -> COULD_NOT_CHECK, never "clean").
  `Export-SapFindingsTsv` -> `findings.tsv`.
- `Register-SapArtifact` once per note (ScopeKey `NOTE_<number>`, Kind `note_status`,
  Verdict = worst verdict across systems, `-Ticket` if given) + the combined matrix under the
  first note's scope, so `/sap-evidence-pack --ticket <ID>` collects them.

## Final — Log End

Log end (`SUCCESS` / `PARTIAL` maps to SUCCESS with a note / `FAILED` + error_class). Echo the
matrix path + one-line verdict per note. Error classes: `NOTE_INPUT_INVALID`,
`NOTE_NO_RFC_PROFILE`, `RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **Live-verified** S4D (S/4HANA 1909, rel 754) + EC2 (ECC 6, rel 731) 2026-07-11: multi-profile
  fan-out; a real implemented note (S/4 note, `NTSTATUS=I` -> IMPLEMENTED) with 32 touched TADIR
  objects, 16 with SMODILOG history, 0 genuinely missing; the same note UNKNOWN_NOT_DOWNLOADED on
  EC2; a fake note UNKNOWN_NOT_DOWNLOADED both systems; component skew from CVERS (150 vs 168
  comps). Identical object set + code path on both releases.
- **Status decode is curated, not authoritative.** CWBNTSTAT/CWBPRSTAT are CHAR1 domains with
  **no DDIC fixed values** (probed: DD01L VALEXI blank, DD07L empty) — SNOTE decodes them via
  program constants. `note_status_codes.tsv` maps I/E/N/O/V as DOCUMENTED and A/R/others as
  INFERRED/UNKNOWN; the **raw code is always shown** and the confidence flag rides every verdict.
  Override the map at `{custom_url}\note_status_codes.tsv`.
- **MOD_COLLISION = "object has SMODILOG modification/adjustment history"** at TADIR (R3TR) object
  granularity — this includes note-driven corrections, not only hand modifications, so on a
  heavily-patched DEV the count is naturally high; it is a *potential*-conflict signal for
  /sap-compare, not proof of a hand-mod. LIMU sub-objects are aggregated to their R3TR parent;
  documentation/text types (MTXT/DOCU/...) are excluded from OBJ_MISSING (GUID-keyed, not a real
  applicability signal). Distinguishing hand-mod from note-mod via SMODILOG OPERATION is v1.5.
- **Never NOT_IMPLEMENTED without evidence:** no CWBNTHEAD row -> UNKNOWN_NOT_DOWNLOADED. SP/TCI-
  delivered corrections leave no CWB customer status, so a truly-fixed note can read UNKNOWN — a
  documented honest limit (v2 open question: a reliable TCI-implemented signal via OCS tables).
- **Landscape coverage == saved /sap-login profiles with an RFC password on THIS Windows account**
  (DPAPI CurrentUser). Absent systems are shown, never silently omitted.
- **v1.5:** `--validity` (CWBNTVALID ranges vs component levels: APPLIES / MAY_NOT_APPLY /
  COULD_NOT_CHECK); SMODILOG OPERATION-based hand-mod discrimination. **v2:** DBTABLOG customizing
  history; TCI/SP-implemented detection.
