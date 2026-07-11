# sap-explain-role

Explain **what a PFCG role actually lets a user do** — read-only over RFC (no GUI,
no PFCG, no Z-object). Turns raw authorization codes into an audit dossier.

```
/sap-explain-role <ROLE_NAME> [--no-holders] [--critical-only] [--audience audit|technical] [--lang <L>] [--critical-file <path>] [--max-rows N]
```

## What it does

1. **Extracts** the role's content over RFC: granted/menu **transactions**, decoded
   **authorization values** (auth-object + activity texts — "C_DRAW_TCD → Authorization
   for document activities", "ACTVT 02 → Change"), **org levels**, and **holders**
   (with lock/validity/name). Composite roles are decomposed one level (AGR_AGRS).
2. **Flags critical grants** deterministically against a co-owned, customer-extensible
   `critical_auths.tsv` — table-maintenance change, debug-replace, SE38/SM30/SM49/SU01/
   PFCG, wildcard transaction/RFC grants — with severity + rationale.
3. **Narrates** an audit dossier grounded strictly in the extracted TSVs — no invented
   values.

## Deterministic, reproducible

Extraction and critical matching are in PowerShell (the audit-relevant facts are
reproducible); the LLM only narrates data present in the TSVs. The matcher: a wildcard
grant (`LOW='*'`) hits any rule; a rule `low='*'` flags only a wildcard grant;
trailing-`*` prefix match; `low..high` interval containment; DELETED tombstones excluded.

## Reads

`AGR_DEFINE`/`AGR_TEXTS`/`AGR_AGRS` (header/composite), `AGR_TCODES` + S_TCODE grants
(transactions), `AGR_1251` (auth values), `AGR_1252`×`USORG` (org levels),
`AGR_USERS`×`USR02`×`USER_ADDR` (holders), `TOBJT`/`TACTT`/`TSTCT` (decode). All
TRANSP/FMODE=R, identical on both releases.

Read-only; no confirm gates; no TR; no GUI. The co-owned `critical_auths.tsv` is shared
with `/sap-suim`. Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) — one code
path; the S/4 Fiori (S_START) grant gap is disclosed, never silently under-reported.
