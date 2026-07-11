# sap-suim

Answer **SUIM questions as repeatable, diffable commands** — read-only over RFC (no
GUI, no RSUSR* report submits, no Z-object).

```
/sap-suim users --role=<R|R*>              [--valid-on YYYYMMDD] [--include-locked] [--max N]
/sap-suim users --tcode=<T>                [same flags]
/sap-suim users --auth=<OBJ>:<FIELD>=<VAL> [same flags]
/sap-suim critical [--matrix <tsv>] [--users]
```

## What it does

- **`users`** — who has access, three ways: by **role** (composite-aware), by
  **transaction** (S_TCODE grant primary, menu presence secondary — TSTC-validated),
  or by **authorization** object/field/value. Joined to `USR02` lock/validity +
  `USER_ADDR` names, validity-filtered on `--valid-on` (today by default).
- **`critical`** — a **targeted** scan (the critical objects only, never a full
  AGR_1251 table scan) against a co-owned, customer-extensible `critical_auths.tsv`
  — table-maintenance change, debug-replace, SE38/SM49/SU01/PFCG, wildcard S_TCODE /
  S_RFC grants — with a GO/GO_WITH_WARNINGS/NO_GO verdict. **SAP_ALL holders are
  always flagged.**

## Honest by construction

Every `users` report carries a **PROFILE_COVERAGE** header: it analyzes role-based
grants only, and discloses how many users also hold **manual profiles** (computed as
`UST04` minus role-generated `AGR_1016` profiles — not a name guess), how many inherit
via **reference users** (`USREFUS`), and names every **SAP_ALL** holder. A user whose
only access is a manual profile is disclosed, never counted as "has access" or "no
access". No SUIM screenshot tells you any of that.

## Reads

`AGR_DEFINE`/`AGR_AGRS` (roles/composite), `AGR_1251` (grants), `AGR_USERS` (assignment
+ validity), `USR02` (lock), `USER_ADDR` (name), `UST04`+`AGR_1016` (manual-profile
math), `USREFUS` (reference users), `TSTC` (tcode validation). All TRANSP/FMODE=R,
identical on both releases.

Read-only; never drives SUIM; never submits RSUSR* reports. The co-owned
`critical_auths.tsv` is shared with `/sap-explain-role`. `role-diff`/`user-diff`
(offline grant-set diff) and `sod` are the next phases. Verified live on S/4HANA 1909
(S4D) and ECC 6 (EC2/ERP).
