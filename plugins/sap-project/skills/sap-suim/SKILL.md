---
name: sap-suim
description: |
  Answers SUIM questions as repeatable, diffable commands — read-only over RFC (no
  GUI, no RSUSR* report submits). `users` finds who has access: by role
  (composite-aware), by transaction (S_TCODE grant primary, menu secondary), or by
  authorization object/field/value — joined to USR02 lock/validity + USER_ADDR
  names, with a PROFILE_COVERAGE header disclosing that only role-based grants are
  analyzed (manual profiles + reference users counted, SAP_ALL holders named).
  `critical` scans the system for dangerous authorizations against a co-owned,
  customer-extensible critical_auths.tsv (table-maintenance change, debug-replace,
  SE38/SM49/SU01/PFCG, wildcard grants) and always flags SAP_ALL holders, with a
  GO/GO_WITH_WARNINGS/NO_GO verdict. Turns SUIM screenshots into artifacts an audit
  can diff. Prerequisites: SAP profile via /sap-login (RFC); SAP NCo 3.1 (32-bit).
  No GUI session, no Z-object dependency.
argument-hint: "users --role=<R|R*> | --tcode=<T> | --auth=<OBJ>:<FIELD>=<VALUE>  [--valid-on YYYYMMDD] [--include-locked] [--max N]   |   critical [--matrix <tsv>] [--users]"
---

# SAP User & Authorization Info (SUIM, over RFC)

You answer "who has access to X", and "who holds critical authorizations", as
one-line commands producing diffable TSV/MD artifacts — never SUIM screenshots.
Every report is honest about its coverage (role-based grants; manual profiles and
reference users are disclosed, not silently included or excluded).

Task: $ARGUMENTS

**You are read-only against SAP.** No confirm gates, no report submits, no GUI.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_suim_query.ps1` | `[-Role\|-Tcode\|-Auth] [-ValidOn -IncludeLocked -Max]` | who-has-access engine (RFC) |
| `<SKILL_DIR>/references/sap_suim_critical.ps1` | `-CriticalTsv <tsv> [-Users -Max]` | targeted critical-access scan (RFC) |
| `<SKILL_DIR>/../../shared/tables/critical_auths.tsv` | matrix | Co-owned critical-grant seed (with /sap-explain-role); customer override at `{custom_url}\critical_auths.tsv` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` / `sap_object_resolver.ps1` / `sap_artifact_lib.ps1` | dot-sourced / registration | RFC connect, `Read-SapTableRows`, artifact index |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```
Set `{RUN_TEMP}` via `Get-SapRunTemp`; `{OUT}` via `Get-SapArtifactDir` (scope
`SID_<SID>_<CLIENT>` or `ROLE_<R>`).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_suim_run.json" -Skill sap-suim -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

| Mode | Args | Access |
|---|---|---|
| `users` | exactly one of `--role=<R\|R*>` / `--tcode=<T>` / `--auth=<OBJ>:<FIELD>=<VALUE>`; `[--valid-on YYYYMMDD]` `[--include-locked]` `[--max N]` | read-only |
| `critical` | `[--matrix <tsv>]` `[--users]` `[--max N]` | read-only |

`role-diff` / `user-diff` (offline grant-set diff) are **v1.5 (not yet)**; `sod`
(offline tcode-pair conflict analysis) is **v2**. If asked, say so and continue.

## Step 2 — Ensure the RFC Profile

RFC only — no GUI session. Profile pinned via `/sap-login`; the engines
self-connect. RFC unavailable → fail loud (`RFC_LOGON_FAILED`), pointer to manual
SUIM; never a partial "nobody has access".

## Step 3 — Resolve the Critical Matrix (critical mode)

`--matrix` → `{custom_url}\critical_auths.tsv` → the plugin seed. Schema-invalid /
missing → `AUTH_MATRIX_INVALID` (`NO_MATRIX` from the engine); echo matrix
provenance + row count into the report header.

---

## Step 4 — `users` (read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_suim_query.ps1" -Tcode "SE16N" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Use `-Role <R>` / `-Auth "<OBJ>:<FIELD>=<VALUE>"` for the other selectors; add
`-ValidOn`, `-IncludeLocked`, `-Max`. Parse:

```
USER: bname=.. name=.. locked=<Y|N> valid=<from..to> via=<..> source=<direct|composite>
PROFILE_COVERAGE: users=<n> with_manual_profiles=<n> sap_all=<n> ref_users=<n>
STATUS: OK users=<n> capped=<Y|N> | AUTH_ROLE_NOT_FOUND | AUTH_TCODE_NOT_FOUND | RFC_ERROR
```

Render the user table, then **always show the PROFILE_COVERAGE disclosure verbatim**:
"Role-based grants only. N of M users also hold manual profiles (SAP_ALL: k), and R
inherit via reference users — NOT analyzed here." `AUTH_ROLE_NOT_FOUND` → show the
`NEAR:` candidates. `capped=Y` → "at least Max — narrow or raise `--max`". A
menu-only role (`--tcode` shows the tcode in a role's menu but no S_TCODE grant) is
itself worth noting.

## Step 5 — `critical` (read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_suim_critical.ps1" -CriticalTsv "<matrix>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Add `-Users` to map each flagged check to the holder count (slower — per-role
AGR_USERS reads). Parse `CRIT:` + `SAPALL:` lines + `STATUS: OK checks_hit=..
critical=.. high=.. sapall=.. verdict=<GO|GO_WITH_WARNINGS|NO_GO>`. Render the
critical checks (severity-sorted) + the SAP_ALL holder list; state the verdict
(any CRITICAL grant or any SAP_ALL holder → NO_GO). Note the scope loudly:
"role-based coverage — a manual-profile-only holder of a critical grant is not seen
here (COULD_NOT_CHECK), never rendered as clean."

---

## Step 6 — Register & Log End

Write the TSV/MD to `{OUT}` and `Register-SapArtifact` (kind `auth-user-list` /
`auth-critical`; Verdict for critical; Coverage `CHECKED`/`PARTIAL`). Then:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_suim_run.json" -Status SUCCESS -ExitCode 0
```

A report that runs — even NO_GO — is `SUCCESS`. Use `-Status FAILED` with the mapped
`-ErrorClass` for the STOPs (`AUTH_ROLE_NOT_FOUND`, `AUTH_TCODE_NOT_FOUND`,
`AUTH_MATRIX_INVALID`, `AUTH_VOLUME_CAPPED`, `RFC_LOGON_FAILED`).

---

## Scope & Limitations

- **v1 implemented:** `users` (by role composite-aware / by tcode / by auth
  object-field-value, validity-filtered, USR02 lock + USER_ADDR name +
  PROFILE_COVERAGE), `critical` (targeted scan of the critical objects against the
  co-owned `critical_auths.tsv`, SAP_ALL holders always flagged, GO/GO_WITH_WARNINGS/
  NO_GO verdict). Read-only.
- Single code path on ECC 6 and S/4HANA (all 14 tables + USER_ADDR probed identical).
- **PROFILE_COVERAGE is the honesty center**: manual profiles are computed as
  `UST04` profiles minus role-generated profiles (`AGR_1016`) — not a name heuristic;
  reference users (`USREFUS`) and SAP_ALL are disclosed on every report. Role-based
  grants only — a user whose ONLY access is a manual profile or reference user is
  disclosed, never counted as "has access" or "no access".
- **Phase 1.5 (not yet):** `role-diff` / `user-diff` (offline grant-set diff, incl.
  cross-system `--against`), `--cross-check` (validate the join against the S/4 SUIM
  APIs `SUSR_SUIM_API_*`). **Phase 2:** `sod` (tcode-pair conflict analysis).
- **Never drives SUIM and never submits RSUSR* reports** (report execution would need
  a gate and adds nothing over direct reads). Matcher semantics identical to
  /sap-explain-role (wildcard grant hits any rule; rule `low='*'` flags only a
  wildcard grant; interval containment; DELETED tombstones excluded).
- Verified live on S/4HANA 1909 (S4D — `users --tcode=SE16N` → 71 holders; `critical`
  → NO_GO with 23 SAP_ALL holders) and ECC 6 (EC2/ERP) 2026-07-11.
