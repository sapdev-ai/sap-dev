---
name: sap-explain-role
description: |
  Explains what a PFCG role actually lets a user do — read-only over RFC (no GUI,
  no PFCG). Extracts the role's menu/granted transactions, decoded authorization
  values in plain language (auth-object + activity texts, not raw codes), org
  levels, and holders (with lock/validity), decomposing composite roles one level.
  A deterministic critical-grant matcher flags dangerous authorizations
  (table-maintenance change, debug-replace, SE38/SM30/SM49/SU01/PFCG, wildcard
  transaction/RFC grants, …) against a co-owned, customer-extensible
  critical_auths.tsv. Claude then narrates an audit dossier — "this role lets a
  user create and change purchase orders for company codes 1000–1999" — grounded
  strictly in the extracted TSVs. Turns the annual manual role rewrite into a
  repeatable, artifact-registered dossier. Prerequisites: SAP profile via
  /sap-login (RFC); SAP NCo 3.1 (32-bit). No GUI session, no Z-object, no dev-init.
argument-hint: "<ROLE_NAME> [--no-holders] [--critical-only] [--audience audit|technical] [--lang <L>] [--critical-file <path>] [--max-rows N]"
---

# SAP Role Explainer (PFCG) — Audit Dossier

You explain **what a role actually permits**, read-only over RFC. PFCG's display
answers this for no one — auth values are raw codes, composites hide their
children. This extracts the facts deterministically and narrates them into
sign-off prose an auditor accepts, grounded only in the extracted data.

Task: $ARGUMENTS

**You are read-only against SAP.** No confirm gates, no TR, no GUI. The dossier and
its TSVs stay local under `{work_dir}`.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_explain_role_rfc.ps1` | `-Role <n> [-IncludeHolders -Lang -MaxRows] -OutDir <d>` | The one RFC extractor (AGR_*/USR*/decode tables) |
| `<SKILL_DIR>/references/sap_role_critical_match.ps1` | `-AuthsTsv -CriticalTsv -OutDir [-Role]` | Offline deterministic critical-grant matcher |
| `<SKILL_DIR>/../../shared/tables/critical_auths.tsv` | matrix | Co-owned critical-grant seed (with /sap-suim); customer override at `{custom_url}\critical_auths.tsv` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` / `sap_object_resolver.ps1` / `sap_artifact_lib.ps1` | dot-sourced / Step 7 | RFC connect, `Read-SapTableRows`, artifact index |

---

## Step 0 — Resolve Work Directory & OUT

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Set `{RUN_TEMP}` via `Get-SapRunTemp`. `{OUT}` = `Get-SapArtifactDir -ScopeKey
ROLE_<NAME> -Skill sap-explain-role` (manual scope key — PFCG roles are not TADIR
objects).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_explain_role_run.json" -Skill sap-explain-role -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

Default mode is **role** (bare `<ROLE>` arg). Flags: `--no-holders` (skip the USR
reads), `--critical-only` (render header + criticals + coverage only — the full
AGR_1251 read still runs, matching needs it), `--audience audit|technical` (default
`audit` = business language), `--lang <L>`, `--critical-file <path>`, `--max-rows N`
(default 50000). Uppercase the role name.

`concept <PATTERN>` is **Phase 2 (not implemented)** → say `MODE_NOT_IMPLEMENTED`
and STOP.

---

## Step 2 — Ensure the RFC Profile

RFC only — no GUI session. Profile pinned via `/sap-login`; the extractor
self-connects. RFC unavailable → fail loud (`RFC_LOGON_FAILED`).

## Step 3 — Resolve the Critical Matrix

`--critical-file` → `{custom_url}\critical_auths.tsv` → the plugin seed
(`sap-project/shared/tables/critical_auths.tsv`). Log which tier won; a missing
matrix marks the whole critical section COULD_NOT_CHECK (never a silent "0 hits").

---

## Step 4 — Extract (RFC)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_explain_role_rfc.ps1" -Role "<ROLE>" -IncludeHolders -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutDir "{OUT}"
```

Drop `-IncludeHolders` for `--no-holders`; add `-MaxRows N`. Parse:

```
ROLE: name=.. composite=<Y|N> children=.. text="<short text>"
SECTION: <area> rows=<n> coverage=<CHECKED|COULD_NOT_CHECK> [reason=..]
STATUS: OK | PARTIAL | ROLE_NOT_FOUND | RFC_ERROR
```

- `ROLE_NOT_FOUND` (exit 1) → show the `NEAR:` candidates, log end `ROLE_NOT_FOUND`, STOP.
- `PARTIAL` → carry the per-`SECTION:` coverage flags into the dossier (a
  `COULD_NOT_CHECK` area — auth-denied read or `--max-rows` truncation — is rendered
  as such, never as empty/clean). A denied **core** area (auths) is `ROLE_READ_DENIED`;
  a denied **holders** area alone stays SUCCESS + PARTIAL.
- `RFC_ERROR` (exit 2) → `RFC_LOGON_FAILED`, STOP. A composite with >20 children →
  volume check-in with the user before continuing (not a write gate).

The extractor writes `role_header.tsv`, `role_tcodes.tsv`, `role_auths_decoded.tsv`
(src_role / object / **object_text** / auth / field / low / high / **activity_text**),
`role_orglevels.tsv`, `role_holders.tsv`, `role_children.tsv` into `{OUT}`.

## Step 5 — Match Critical Grants (offline)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_role_critical_match.ps1" -AuthsTsv "{OUT}\role_auths_decoded.tsv" -CriticalTsv "<matrix>" -OutDir "{OUT}" -Role "<ROLE>"
```

Parse `CRIT:` lines + `STATUS: OK found=.. critical=.. high=.. medium=..`. `NO_MATRIX`
→ critical section COULD_NOT_CHECK, verdict PARTIAL (never CLEAN).

---

## Step 6 — Write the Dossier (you narrate this)

Write `role_dossier.md` into `{OUT}` from the TSVs. **Grounding rule: every claim
traces to a TSV row — never invent an auth value, holder, or purpose.** Sections:

1. **Header** — role, short text, type (single/composite), created/changed, system/client.
2. **Executive summary** — audience-tuned ("this role lets a user …"); `technical`
   surfaces object/field codes, `audit` stays in business language.
3. **Critical grants first** — severity-sorted from `critical_findings.tsv`; name the
   grant + rationale ("S_TABU_DIS ACTVT 02 — change access to table maintenance").
4. **Transactions** — `role_tcodes.tsv` (menu vs S_TCODE grant; note a menu tcode
   with no S_TCODE grant, and vice-versa).
5. **Authorizations by object** — group `role_auths_decoded.tsv` by object, using the
   decoded `object_text`/`activity_text`; render ranges as "for X 1000–1999".
6. **Org levels** — `role_orglevels.tsv` (org field + value).
7. **Holders** — `role_holders.tsv`, flagging locked / expired users; `--no-holders`
   → say holders were not read.
8. **Composite rollup** — for a composite, summarize each child + the merged picture.
9. **Coverage** — name every `COULD_NOT_CHECK`/truncated area. **On S/4** (release
   marker) add: "Classic grants only — Fiori catalog/S_START app grants are NOT read
   in v1", so the verdict never over-claims completeness.

## Step 7 — Register & Log End

Register `role_dossier.md` (kind `role-dossier`, Verdict `CLEAN|CRITICAL_GRANTS|PARTIAL`,
Coverage from Step 4), each TSV (kind `role-data`), and `findings.json` (kind
`findings`) via `Register-SapArtifact` under scope `ROLE_<NAME>`. Echo:

```
ROLE: <name> tcodes=<n> objects=<n> critical=<n> holders=<n|SKIPPED|DENIED> verdict=<..>
```

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_explain_role_run.json" -Status SUCCESS -ExitCode 0
```

PARTIAL data still ends `SUCCESS` (with `coverage=PARTIAL`). Use `-Status FAILED`
with the mapped `-ErrorClass` for the STOPs (`ROLE_NOT_FOUND`, `ROLE_READ_DENIED`,
`ROLE_DATA_TRUNCATED`, `RFC_LOGON_FAILED`, `MODE_NOT_IMPLEMENTED`).

---

## Scope & Limitations

- **v1 implemented:** `role` dossier for single + composite roles (decomposed one
  level) — decoded transactions, authorizations (object + activity texts), org
  levels, holders (lock/validity/name), deterministic critical-grant matching against
  the co-owned `critical_auths.tsv`. `--no-holders`, `--critical-only`, `--audience`,
  `--lang`, `--max-rows`. Read-only.
- Single code path on ECC 6 and S/4HANA (all 21 tables + USER_ADDR probed identical);
  the only divergence is *coverage* — the S/4 Fiori (S_START/catalog) gap, disclosed.
- **Matcher semantics** (deterministic, never the LLM): a rule hits when the granted
  `LOW..HIGH` covers the rule value — a wildcard grant (`LOW='*'`) hits any rule; a
  rule `low='*'` flags only a wildcard grant; trailing-`*` prefix match; `low..high`
  interval containment; blank `field` = object-presence. DELETED='X' tombstones excluded.
- **Phase 2 (not yet):** `concept <pattern>` (batch role-model documentation +
  role-to-user matrix), `--format docx`. Fiori catalog analysis (AGR_HIER/S_START).
- **Honesty:** an auth-denied or truncated area is `COULD_NOT_CHECK`, never rendered
  as empty/clean; a missing matrix caps the verdict at PARTIAL; the dossier narrates
  only data present in the TSVs.
- **Privacy:** the holder section carries user IDs + names (audit-legitimate);
  `--no-holders` for privacy-lean runs; all output stays under `{work_dir}`.
- Verified live on S/4HANA 1909 (S4D — a 401-auth / 448-holder business role) and
  ECC 6 (EC2/ERP — SAP_AUDITOR_A, SM30 flagged HIGH) 2026-07-11; matcher unit-checked
  for wildcard, interval-containment, prefix, and no-false-positive cases.
