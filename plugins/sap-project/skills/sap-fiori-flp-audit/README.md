# sap-fiori-flp-audit

**Answer "why does user U (not) see launchpad content T" and find broken/dead launchpad
references** by deterministically cross-joining what the FLP designer, PFCG, and web
designers each show only half of — user → roles → each role's Fiori menu references →
TSTC validation of every transaction target. RFC-only, read-only, S/4-oriented.

```
/sap-fiori-flp-audit user <USER>
/sap-fiori-flp-audit broken-tm [--catalog <pat>]
/sap-fiori-flp-audit unassigned
/sap-fiori-flp-audit full --user <USER> [--include-sap] [--lang L] [--max-rows N]
```

## What it does

- **Resolves user → roles** (BAPI_USER + AGR_USERS + composite expansion, with validity
  windows and lock state).
- **Walks each role's Fiori menu references** (AGR_HIER/AGR_HIERT/AGR_BUFFI): catalog and
  group providers with their real IDs, OData services, Web Dynpro apps, and classic
  transaction targets.
- **Validates every transaction target against TSTC** — `broken-tm` finds classic
  transactions still referenced in Z role menus but removed from the system.
- **Narrates the per-tile "why chain"** in `flp_audit.md` for `user` mode — "visible
  because role R (valid to D) whose menu references catalog C / launches transaction T" —
  narrating only rows that exist.
- **Probes FLP presence at runtime** and stops loud with `FLP_NOT_PRESENT` on a non-FLP box
  (ECC without the UI addon), never an empty-but-green audit.

## Honest by construction

The key honesty point is live-proven: **RFC_READ_TABLE CANNOT read the /UI2 Page Builder
persistence** (`/UI2/PB_C_PAGE`, `/UI2/PB_C_CHIP`, `/UI2/CHIP_CHDR`, `/UI2/PB_C_TM` — their
STRING columns dump "ASSIGN … CASTING in SAPLSDTX" even for narrow non-string FIELDS). The
persistence-integrity checks (BROKEN_CHIP_REF, ROLE_REFERENCES_MISSING_CATALOG,
EMPTY/UNASSIGNED_CATALOG — which is why the `unassigned` mode reports this way today) are
therefore COULD_NOT_CHECK with that exact reason, never a false "no findings", and the
verdict caps at PARTIAL. The `FLP_PERSISTENCE: rfc_readable=NO` line makes the limitation
explicit every run. Promoting those checks to CHECKED via the wrapper-FM route is v1.5;
spaces/pages (CDM3) audit is v2; user personalization deltas are out of v1 scope.

## Reads

`AGR_USERS` / `AGR_HIER` / `AGR_HIERT` / `AGR_BUFFI` (roles + menus), BAPI_USER (user),
`TSTC` (target validation) — extracted by `references/sap_flp_extract_rfc.ps1` into
`flp_user_roles.tsv`, `flp_role_content.tsv`, `flp_findings.tsv`. Pure RFC off the pinned
`/sap-login` profile (SAP NCo 3.1, 32-bit) — no GUI session, no writes, no Z objects.

Verified live on S/4HANA 1909 (S4D): one user resolved to 35 roles and 4,934 classified
menu nodes (OData services, tcodes, catalogs with real IDs, groups, WebDynpro), with 2 real
dead-transaction findings (SECR + SO80, removed in S/4HANA, still in role menus). ECC
without the UI addon is `FLP_NOT_PRESENT` (not supported).
