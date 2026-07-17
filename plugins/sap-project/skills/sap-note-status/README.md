# sap-note-status

**Answers "is SAP Note N implemented, where, and will it clash with our mods?" across
every saved /sap-login profile in one read-only RFC pass** — a notes × systems verdict
matrix instead of logging into each system's SNOTE. Pure RFC_READ_TABLE (no GUI, no
Z object, no dev-init), so it runs against PRD/QA systems as-is.

```
/sap-note-status <NOTE> [<NOTE> ...] [--systems <SID,SID/CLIENT,...|ALL>]
                 [--no-collisions] [--ticket <ID>] [--json]
```

## What it does

- **Fans out across the landscape**: default = every saved `/sap-login` profile (each
  with an RFC password is queried; each without becomes a COULD_NOT_CHECK row). Note
  numbers are accepted in any form (`3123456` / `0003123456` / with spaces).
- **Per note × system verdict** from CWBNTHEAD + CWBNTCUST: `IMPLEMENTED` / `INCOMPLETE` /
  `NOT_IMPLEMENTED` (downloaded, not implemented) / `OBSOLETE` / `CANNOT_BE_IMPLEMENTED` /
  `UNKNOWN_STATUS` / `UNKNOWN_NOT_DOWNLOADED` / `COULD_NOT_CHECK`.
- **Component-level skew** from CVERS — differing verdicts or component levels across
  systems are called out in the matrix's AI skew/risk summary.
- **Mod-collision check** (skip with `--no-collisions`): joins the note's touched
  repository objects (CWBNTCI → CWBCIOBJ) against the modification/adjustment log
  (SMODILOG) and object existence (TADIR). `MOD_COLLISION` objects become HIGH findings
  with the recommended follow-up `/sap-compare` source diff.
- **Registers CAB/audit-grade evidence** per note (scope `NOTE_<number>`, `--ticket`
  stamped) so `/sap-evidence-pack` collects it.

## Honest by construction

Tri-state throughout: an unreachable system or one with no RFC password is
COULD_NOT_CHECK — never rendered clean. A note absent from CWBNTHEAD is
UNKNOWN_NOT_DOWNLOADED, **never** NOT_IMPLEMENTED — SP/TCI-delivered fixes leave no CWB
customer status, a documented honest limit. NTSTATUS/PRSTATUS have **no DDIC fixed
values**, so decode comes from the shipped, customer-overridable
`note_status_codes.tsv` with a confidence flag (D=documented / I=inferred / U=unknown)
and the raw code always shown — an inferred decode is never upgraded to a certain claim.
MOD_COLLISION means "has SMODILOG history" at R3TR granularity — a *potential*-conflict
signal (note-driven corrections included), not proof of a hand modification.

## Reads

`CWBNTHEAD` / `CWBNTCUST` (verdict), `CVERS` (component levels), `CWBNTCI` → `CWBCIOBJ`
(touched objects), `SMODILOG` + `TADIR` (collisions) — all FMODE=R. The whole backend is
one script: `references/sap_note_status_rfc.ps1` (multi-profile fan-out, matrix rows +
collisions TSV).

Read-only; never writes, never opens a GUI. Landscape coverage equals the saved
`/sap-login` profiles with an RFC password on THIS Windows account (DPAPI CurrentUser) —
absent systems are shown, never silently omitted. Live-verified on S/4HANA 1909 (S4D) and
ECC 6 (EC2/ERP), identical code path on both releases. v1.5: `--validity` (CWBNTVALID
ranges) and SMODILOG OPERATION-based hand-mod discrimination; v2: TCI/SP-implemented
detection. Prerequisites: ≥1 saved profile with RFC password; SAP NCo 3.1 (32-bit).
