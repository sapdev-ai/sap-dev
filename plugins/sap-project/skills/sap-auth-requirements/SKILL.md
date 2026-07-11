---
name: sap-auth-requirements
description: |
  Derives the SAP authorization requirements a custom development actually needs — the
  deliverable Z-transactions never hand the security team. derive reads a program/FM source over
  RFC, extracts the EXPLICIT AUTHORITY-CHECK surface plus the IMPLICIT one (CALL TRANSACTION ->
  S_TCODE, SUBMIT -> S_PROGRAM, OPEN/DELETE DATASET/TRANSFER -> S_DATASET, CALL FUNCTION
  DESTINATION -> S_RFC, DDIC table writes -> S_TABU_DIS incl. dynamic MODIFY (var)), traces each
  value to its nearest literal, and validates every object/field/activity against the live
  catalog (TOBJ / TACTZ) — emitting a required-auth matrix with per-row CONFIRMED / INFERRED
  honesty plus an SU24 proposal draft. su24-audit lists Z/Y tcodes against USOBX_C / USOBT_C and
  flags the real gap: NO_PROPOSAL / CHECK_DISABLED / ONLY_S_TCODE / PROPOSAL_PRESENT with a
  staleness date. Pure RFC + offline extraction (no wrapper FM, no dev-init, runs on a bare
  security profile); a static value that cannot be resolved is INFERRED, never silently
  CONFIRMED. Class/interface source needs an SE24 GUI download (pass --source-files) or degrades
  to COULD_NOT_CHECK. Owns the AUTHREQ_* finding namespace so it never double-reports with
  /sap-review-abap's security dimension. v2: su24-maintain / su21-create (confirm-gated GUI).
  Prerequisites: pinned /sap-login RFC profile; NCo 3.1 (32-bit).
argument-hint: "<OBJECT> | derive <OBJECT> [--type program|fm|class] [--source-files a,b] | su24-audit [--tcodes Z*|list]"
---

# SAP Authorization Requirements Skill

You produce a security-team-ready authorization matrix from real code (`derive`) and audit which
Z-transactions lack SU24 proposals (`su24-audit`) — all read-only. Every value is CONFIRMED
(literal) or INFERRED (variable/dynamic), and a value you cannot resolve statically is INFERRED
with its stop point, never a confident guess.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_auth_requirements_rfc.ps1` | `-Mode derive\|su24-audit` | Source read + validation + su24-audit backend |
| `<SKILL_DIR>/references/sap_auth_extract.ps1` | `-SourceFiles -OutJson` | Offline ABAP auth-surface extractor + value tracer (unit-testable) |
| `<SKILL_DIR>/references/auth_extract_fixture.abap.txt` | offline corpus | Extractor test fixture (explicit/implicit/DUMMY/dynamic/trace cases) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_read_source.ps1` | dot-source | `Read-SapAbapSource` (RPY program/FM read) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` · `sap_artifact_lib.ps1` | dot-source | Findings + evidence registration |
| `/sap-se24` · `/sap-review-abap` · `/sap-explain-object` | sub-skills | Class source download / security-review positioning / object dossier |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_auth_requirements_run.json`). Pinned RFC profile via `/sap-login`.

## Step 1 — Parse & Dispatch

Default / `derive <OBJECT>` | `su24-audit`. v2 modes (`su24-maintain`, `su21-create`,
`su24-diff`) are NOT implemented yet — reject with a clear "planned for v2" message.

## Step 2 — derive

```bash
... sap_auth_requirements_rfc.ps1 -Mode derive -Object <n> -Type program|fm -OutDir "{RUN_TEMP}\ar"
```

For a **class/interface**, RFC source read is unsupported: run `/sap-se24` check-and-download
(security-sidecar pre-armed) to fetch the source, then pass `-SourceFiles "<file>"`; with
`--no-gui` the class degrades to `COULD_NOT_CHECK` (never a guessed empty matrix). The backend
resolves+reads source (RPY), runs the offline extractor, and validates each row against TOBJ
(object + its FIEL1..FIEL0 fields) and TACTZ (allowed ACTVT). Emits `AUTHVAL:` per row +
`AUTHREQ:` summary; writes `auth_requirements.tsv` (seq/source/statement/object/field/value/
status/validation/trace_note) + `su24_proposal_draft.tsv`. Map `validation` != OBJECT_OK and
INFERRED rows to `New-SapFinding` (categories `AUTHREQ_INVALID_OBJECT/_FIELD/_VALUE`,
`AUTHREQ_TRACE_STOPPED`, `AUTHREQ_UNPROTECTED_SUBMIT`); a no-AUTHORITY-CHECK program that writes
tables is worth an `AUTHREQ_MISSING_CHECK` observation. COULD_NOT_CHECK caps the verdict.

## Step 3 — su24-audit

```bash
... sap_auth_requirements_rfc.ps1 -Mode su24-audit -Tcodes "Z*"  (or "ZA,ZB")  -OutDir "{RUN_TEMP}\ar"
```

`SU24:` per tcode (objects/checked/value_rows/newest_moddate/verdict) + `su24_audit.tsv`.
Verdicts: `NO_PROPOSAL` (no USOBX_C data — role builders must guess; the headline gap),
`CHECK_DISABLED` (all OKFLAG=N), `ONLY_S_TCODE`, `PROPOSAL_PRESENT`. Findings per NO_PROPOSAL /
stale tcode.

## Step 4 — Report + Register

Summarize (n CONFIRMED / n INFERRED / validation issues, or the NO_PROPOSAL count), verdict
line, file paths. `Register-SapArtifact` (Kind `auth-requirements` / `su24-audit`, coverage
tri-state, verdict) for `/sap-evidence-pack`.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class). Error classes: `AUTHREQ_SOURCE_UNREADABLE`,
`AUTHREQ_EXTRACT_FAILED`, `AUTHREQ_INPUT`; reused `RFC_LOGON_FAILED` / `RFC_ERROR`. (`AUTHREQ_*`
finding categories are NOT error classes — they keep /sap-review-abap from double-reporting.)

---

## Scope & Limitations (v1)

- **Live-verified on S4D (S/4HANA 1909, rel 754) 2026-07-11.** `su24-audit`: 12 Z tcodes all
  `NO_PROPOSAL`, while standard SE38/VA01/ME21N correctly show `PROPOSAL_PRESENT` (47/200/200
  objects, value rows, MODDATE) — the query logic is sound and the Z-tcode gap is real. `derive`:
  the offline extractor passes an 11-case fixture (explicit literal/variable-traced/DUMMY,
  CALL TRANSACTION/SUBMIT/DATASET/RFC-DESTINATION, static + dynamic DDIC writes) and end-to-end on
  ZCMRUPDATE_ADDON_TABLE surfaced its dynamic `MODIFY (mv_table)` as an INFERRED S_TABU_DIS row
  validated OBJECT_OK against TOBJ/TACTZ. EC2 (ECC 6) was probed in-plan (full USOB*/TOBJ parity)
  but was unreachable at build time; the code path is release-agnostic (RFC_READ_TABLE + RPY,
  identical catalog) — TDDAT is POOL on ECC, read the same way.
- **INFERRED is honest, not a defect.** Dynamic tcodes/reports/tables and untraced variables are
  INFERRED with the stop point in the note; a single-pass in-source backward trace resolves the
  easy literals. Multi-hop / cross-unit tracing is out of v1 (a human finishes from the note).
- **Class/interface source is not RFC-readable** — SE24 GUI download (`--source-files`) or
  `COULD_NOT_CHECK`. FM-include source read over RPY was verified on S4D; on other releases a
  read failure degrades to COULD_NOT_CHECK, never an empty matrix.
- **Read-only v1.** No SU24/SU21 writes, no report execution, no TR. The SU24 output is a LOCAL
  DRAFT. **v2:** `su24-maintain` (apply a reviewed proposal via probe-recorded SU24 GUI, TR via
  /sap-transport-request, USOBT_C/USOBX_C re-read verify) and `su21-create` — both confirm-gated;
  no update/delete of auth objects in any phase. `su24-diff` (derive vs USOBT_C) is v1.5.
- **Namespace discipline:** this skill owns `AUTHREQ_*` findings; /sap-review-abap keeps line-
  cited security judgments — the two never double-report the same requirement.
