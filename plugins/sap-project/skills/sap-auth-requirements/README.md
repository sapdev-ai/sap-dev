# sap-auth-requirements

**Derive the authorization requirements a custom development actually needs** — the
required-auth matrix Z-transactions never hand the security team — plus an SU24 proposal
audit across Z/Y tcodes. Read-only; pure RFC + offline extraction, runs on a bare security
profile (no wrapper FM, no dev-init).

```
/sap-auth-requirements <OBJECT>
/sap-auth-requirements derive <OBJECT> [--type program|fm|class] [--source-files a,b]
/sap-auth-requirements su24-audit [--tcodes Z*|list]
```

## What it does

- **`derive`** reads the program/FM source over RFC (RPY reads), extracts the EXPLICIT
  AUTHORITY-CHECK surface plus the IMPLICIT one (CALL TRANSACTION → S_TCODE, SUBMIT →
  S_PROGRAM, OPEN/DELETE DATASET/TRANSFER → S_DATASET, CALL FUNCTION DESTINATION → S_RFC,
  DDIC table writes → S_TABU_DIS incl. dynamic `MODIFY (var)`), traces each value to its
  nearest literal, and validates every object/field/activity against the live catalog
  (TOBJ / TACTZ). Output: `auth_requirements.tsv` with per-row **CONFIRMED / INFERRED**
  honesty + `su24_proposal_draft.tsv` (a LOCAL draft, never written to SAP).
- **`su24-audit`** lists Z/Y tcodes against USOBX_C / USOBT_C and names the real gap per
  tcode: `NO_PROPOSAL` (no SU24 data — role builders must guess; the headline finding),
  `CHECK_DISABLED`, `ONLY_S_TCODE`, `PROPOSAL_PRESENT`, with a staleness date.
- **Findings, not prose**: validation issues and INFERRED rows map into the shared finding
  model under the skill's own `AUTHREQ_*` namespace, so it never double-reports the same
  requirement as `/sap-review-abap`'s line-cited security dimension.

## Honest by construction

A static value that cannot be resolved is INFERRED with its stop point noted — never
silently CONFIRMED (a single-pass in-source backward trace resolves the easy literals;
multi-hop tracing is out of v1). Class/interface source is not RFC-readable: pass
`--source-files` (from an SE24 GUI download via `/sap-se24`) or the class degrades to
`COULD_NOT_CHECK`, never a guessed empty matrix. COULD_NOT_CHECK caps the verdict. The v2
modes (`su24-maintain`, `su21-create`) are rejected with a clear "planned for v2" message,
not half-run.

## Reads

Program/FM source via RPY reads, `TOBJ` / `TACTZ` (object + activity catalog), `USOBX_C` /
`USOBT_C` (SU24 data). Pure RFC off the pinned `/sap-login` profile (SAP NCo 3.1, 32-bit);
the extractor itself (`references/sap_auth_extract.ps1`) is offline and unit-tested against
an 11-case fixture (`references/auth_extract_fixture.abap.txt`).

Read-only, always — no SU24/SU21 writes, no report execution, no TR. Live-verified on
S/4HANA 1909 (S4D): 12 Z tcodes all `NO_PROPOSAL` while standard SE38/VA01/ME21N correctly
read `PROPOSAL_PRESENT`, and `derive` surfaced a real dynamic `MODIFY (mv_table)` as an
INFERRED S_TABU_DIS row validated against TOBJ/TACTZ. ECC 6 was probed in-plan (full
USOB*/TOBJ parity); `su24-diff` (v1.5) and the confirm-gated SU24/SU21 write modes (v2) are
the documented next phases.
