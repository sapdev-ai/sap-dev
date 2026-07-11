---
name: sap-fiori-flp-audit
description: |
  Answers "why does user U (not) see launchpad content T" and finds broken/dead launchpad
  references by deterministically cross-joining what the FLP designer, PFCG, and web designers
  each show only half of: user -> roles (BAPI_USER + AGR_USERS + composite expansion, with
  validity) -> each role's Fiori menu references (AGR_HIER/AGR_HIERT/AGR_BUFFI: catalog and group
  providers with their real IDs, OData services, Web Dynpro apps, and classic transaction targets)
  -> TSTC validation of every transaction target. RFC-only, read-only, S/4-oriented (a runtime
  presence probe stops loud with FLP_NOT_PRESENT on a non-FLP box, never an empty-but-green audit).
  IMPORTANT HONESTY: RFC_READ_TABLE CANNOT read the /UI2 Page Builder persistence
  (/UI2/PB_C_PAGE/CHIP, /UI2/CHIP_CHDR) — those tables carry STRING columns and RFC_READ_TABLE
  dies with "ASSIGN CASTING in SAPLSDTX" even for narrow non-string fields (live-proven on S4D) —
  so the persistence-integrity checks (BROKEN_CHIP_REF, ROLE_REFERENCES_MISSING_CATALOG,
  EMPTY/UNASSIGNED_CATALOG) are reported COULD_NOT_CHECK with that exact reason and need the wrapper
  route (v1.5) or an SE16N read; the role-menu-content audit + dead-transaction-target detection are
  fully delivered. Tri-state honest (COULD_NOT_CHECK never renders green; the verdict caps at
  PARTIAL). No writes, no Z objects, no GUI. Prerequisites: pinned RFC profile via /sap-login; NCo
  3.1 (32-bit). ECC without the UI addon: FLP_NOT_PRESENT (not supported).
argument-hint: "user <USER> | broken-tm [--catalog <pat>] | unassigned | full --user <USER> [--include-sap] [--lang L] [--max-rows N]"
---

# SAP Fiori FLP Audit Skill

You audit classic Fiori Launchpad content from the RFC-readable angle: resolve a user's roles and
their Fiori menu references (catalogs, groups, services, transactions), validate transaction
targets against TSTC, and report the /UI2 Page-Builder persistence-integrity checks honestly as
COULD_NOT_CHECK (RFC_READ_TABLE cannot read those STRING-column tables). Read-only, no writes.

Task: $ARGUMENTS

The facts come from `sap_flp_extract_rfc.ps1` (TSVs + findings); **you** narrate `flp_audit.md`
including the per-tile "why chain" — narrating only rows that exist.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_flp_extract_rfc.ps1` | `-Mode user\|broken-tm\|unassigned\|full -User <U>` | The RFC extractor (all readable areas) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | `Register-SapArtifact`, scope key |
| `/sap-login` | sub-skill | Pinned RFC profile (no GUI session needed) |
| `/sap-run-report` | sub-skill | `--flc` (v1.5) `/UI2/FLC` corroboration (Rule-5 confirm) |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_fiori_flp_audit_run.json" -Skill sap-fiori-flp-audit -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

Modes: `user <USER>` | `broken-tm` | `unassigned` | `full --user <USER>`. `spaces` ->
`MODE_NOT_IMPLEMENTED` (v2). Flags: `--catalog <pat>`, `--include-sap`, `--lang L`, `--max-rows N`
(default 50000). `user`/`full` require `<USER>` (uppercased).

## Step 2 — RFC Preflight

Pinned RFC profile via `/sap-login` (no GUI session). Connect failure -> `RFC_LOGON_FAILED`.

## Step 3 — Extract

`{OUT}` = `Get-SapArtifactDir -ScopeKey <FLP_USER_<U> | FLP_SYSTEM> -Skill sap-fiori-flp-audit`.

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_flp_extract_rfc.ps1" -Mode <mode> -User <U> -Lang <L> -MaxRows <N> -OutDir "{OUT}" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Interpret the last `STATUS:`: `FLP_NOT_PRESENT` -> stop loud (not an FLP box); `FLP_USER_NOT_FOUND`
-> stop; `PARTIAL` -> continue carrying the COULD_NOT_CHECK areas; `RFC_ERROR` -> stop. Read the
`FLP_PERSISTENCE:` line — when `rfc_readable=NO`, the /UI2 persistence-integrity checks are
COULD_NOT_CHECK (surface the reason in Coverage). Each `SECTION:` line carries its per-area coverage.

## Step 4 — Render + Register

Read the TSVs (`flp_user_roles.tsv`, `flp_role_content.tsv`, `flp_findings.tsv`) and write
`flp_audit.md`: header (system/client/mode/user), executive summary, per-query sections, the
per-tile **why chain** for `user` mode ("visible because role R (valid to D) whose menu references
catalog C / launches transaction T"), findings table severity-sorted, and a **Coverage** section
that states explicitly: the /UI2 Page-Builder persistence integrity is COULD_NOT_CHECK (RFC
limitation), user personalization deltas are out of v1 scope. Register:

```bash
powershell -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-fiori-flp-audit' -ScopeKey '<FLP_USER_<U>|FLP_SYSTEM>' -Kind 'flp-audit' -Format 'md' -Path '{OUT}\flp_audit.md' -Coverage '<CHECKED|PARTIAL>' -Verdict '<CLEAN|FINDINGS|PARTIAL>'"
```

Echo `FLP: mode=<m> roles=<n> menu_nodes=<n> findings=<n> coverage=<...>`.

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_fiori_flp_audit_run.json" -Status SUCCESS -ExitCode 0
```

`FLP_NOT_PRESENT` / `FLP_USER_NOT_FOUND` / `MODE_NOT_IMPLEMENTED` / `RFC_LOGON_FAILED` on failure
paths. A PARTIAL run (persistence COULD_NOT_CHECK) is SUCCESS with `coverage=PARTIAL`.

---

## Scope & Limitations (v1)

- **v1 implemented:** `user` / `full` (roles + composite expansion + validity + role-menu FLP
  references + TSTC target validation), `broken-tm` (dead transaction targets across Z role menus),
  `unassigned` (COULD_NOT_CHECK — needs /UI2). Pure RFC, read-only, S/4-oriented.
- **Live-verified on S4D (S/4HANA 1909):** `user MICHAELLI` -> 35 roles (direct + composite),
  4934 menu nodes classified (1921 OData SERVICE, 999 TCODE, 194 CATALOG with real IDs like
  `X-SAP-UI2-CATALOGPAGE:SAP_SFIN_BC_AP_OPER_CN`, 80 GROUP, 10 WebDynpro), user lock/validity
  rendered, and **2 real TM_TARGET_TCODE_MISSING findings** (classic transactions SECR + SO80,
  removed in S/4HANA, still in role menus). `STATUS: PARTIAL` because the persistence integrity is
  honestly COULD_NOT_CHECK.
- **Live-proven RFC limitation (the key honesty point):** RFC_READ_TABLE **cannot** read
  `/UI2/PB_C_PAGE`, `/UI2/PB_C_CHIP`, `/UI2/CHIP_CHDR`, `/UI2/PB_C_TM` — they carry STRING columns
  and RFC_READ_TABLE dies with "Error with ASSIGN ... CASTING in SAPLSDTX" (and DATA_BUFFER_EXCEEDED)
  **even for explicit narrow non-string FIELDS** (the plan's "narrow FIELDS" mitigation does not
  work; existence-only probes could not catch this). So BROKEN_CHIP_REF /
  ROLE_REFERENCES_MISSING_CATALOG / EMPTY_ASSIGNED_CATALOG / UNASSIGNED_CATALOG are reported
  COULD_NOT_CHECK with that reason — never a false "no findings". The `FLP_PERSISTENCE: rfc_readable=NO`
  line makes the limitation explicit every run.
- **v1.5 (the persistence route):** read the /UI2 tables through `Z_GENERIC_RFC_WRAPPER_TBL` (a
  dynamic narrow-column SELECT that OpenSQL handles fine, unlike RFC_READ_TABLE) to promote the four
  persistence checks CHECKED; `--flc` corroboration via `/UI2/FLC` (confirm-gated /sap-run-report).
  **v2:** spaces/pages (CDM3) audit (probe reports absent on 1909 -> SKIPPED).
- **Read-only (Rule 1), no TR, no Z deployment (Rule 2):** the wrapper is only consumed if present
  (v1.5). Fail-loud: FLP_NOT_PRESENT on a non-FLP box; COULD_NOT_CHECK (not empty) on the /UI2
  limitation or a denied read; `--max-rows` truncation -> PARTIAL. **ECC** without the UI addon is
  FLP_NOT_PRESENT (not supported); EC2 was unavailable for the ECC negative-path check this session.
