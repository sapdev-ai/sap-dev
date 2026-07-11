---
name: sap-gen-rap
description: |
  Generate a complete, mutually-consistent managed-RAP business object file set
  from a base table — the biggest capability gap for on-prem clean-core dev without
  ADT. `generate` renders the root CDS + projection CDS + two behavior definitions +
  behavior pool + service definition + service-binding spec + MANUAL_STEPS.md (field
  list/keys resolved live via DDIF_FIELDINFO_GET; dialect-forked 7.54 classic vs
  7.55+ view-entity); `package` builds an abapGit-layout zip so ZABAPGIT_STANDALONE
  imports it with no ADT; `verify` re-reads every artifact over RFC (TADIR + DDLS/
  CLAS/SRVD active via DWINACTIV; BDEF/SRVB presence — activation/publish honestly
  COULD_NOT_CHECK, never a false pass). S/4-ONLY (refuses SAP_BASIS < 7.54 or a
  system with no RAP infrastructure — RAP_RELEASE_UNSUPPORTED). generate/package/
  verify are read-only/local; `deploy` (guided partial deploy with ADT pauses) is
  v1.5. Scope: managed, OData V2, root-only, non-draft. Prerequisites: /sap-login
  pinned to the S/4 system; SAP NCo 3.1 (32-bit).
argument-hint: "generate <STEM> --table <ZTABLE> [--package <PKG>]  |  package <work_folder>  |  verify <work_folder | --stem <STEM>>"
---

# SAP RAP Business Object Generation (no ADT)

Writing a consistent RAP file set by hand — interface CDS + projection + a BDEF pair
+ behavior pool + SRVD/SRVB, all cross-referencing each other with exact names — is
error-prone even in ADT. This generates the whole set from a base table, packages it
for a no-ADT abapGit import, and verifies the result with authoritative RFC re-reads.

Task: $ARGUMENTS

**S/4-only.** RAP does not exist on ECC. Step 1.2 refuses a system below SAP_BASIS
7.54 or with no `R3TR BDEF` rows (`RAP_RELEASE_UNSUPPORTED`), pointing to /sap-gen-abap
+ /sap-gen-cds. **generate/package/verify are read-only/local** (the only SAP touch is
a DDIC read + verify re-reads); no writes, no TR.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/tables/sap_object_naming_rules.tsv` | *(read)* | `RAP_INTERFACE_VIEW` / `RAP_PROJECTION_VIEW` / `RAP_BEHAVIOR_CLASS` / `RAP_SERVICE_DEFINITION` / `RAP_SERVICE_BINDING` rows |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_check_object_name.ps1` | *(invoke)* | Naming validator (Step 1.5) |
| `<SKILL_DIR>/references/sap_gen_rap_generate.ps1` | `-Table -Stem -Release -OutDir` | Render the RAP file set (DDIF_FIELDINFO_GET + templates) |
| `<SKILL_DIR>/references/sap_gen_rap_package.ps1` | `-WorkDir -Stem` | abapGit-layout zip |
| `<SKILL_DIR>/references/sap_gen_rap_verify.ps1` | `-Ddls -Bdef -Clas -Srvd -Srvb` | RFC verification (read-only) |
| `<SKILL_DIR>/references/templates/*.tpl` | *(render)* | 7 templates (root 754/755, projection, 2 BDEF, behavior pool, SRVD, manual steps) |
| `../sap-gen-cds/references/sap_cds_release_probe.ps1` | *(invoke)* | CVERS SAP_BASIS for the Step 1.2 release gate |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` / `sap_finding_lib.ps1` | `%%ARTIFACT_LIB_PS1%% %%FINDING_LIB_PS1%%` | Register outputs + verdict |

> Ships **no GUI VBS**. The RFC legs (generate DDIC lookup, verify) connect to the
> pinned profile. `<SAP_DEV_CORE_SHARED_DIR>` is 3 levels up from `<SKILL_DIR>` then
> `sap-dev-core\shared` (cross-plugin).

## Step 0 / 0.5 — Work Dir + Logging

Resolve `work_dir`/`{RUN_TEMP}`/`{custom_url}` (house one-liner), then
`sap_log_helper.ps1 -Action start` (state `{RUN_TEMP}\sap_gen_rap_run.json`).

## Step 1 — Mode Dispatch

`generate` | `package` | `verify` (implemented) | `deploy` (**v1.5** — see Scope;
refuse with that note). Parse `--table`, `--package` (default `$TMP`), `--stem`.

## Step 1.2 — Release + Capability Gate (generate/verify)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\..\sap-gen-cds\references\sap_cds_release_probe.ps1" -SharedScripts "<SAP_DEV_CORE_SHARED_DIR>\scripts"
```

Parse `SAP_BASIS=<n>`. **`< 754` → STOP `RAP_RELEASE_UNSUPPORTED`** (RAP infrastructure
absent; use /sap-gen-abap + /sap-gen-cds). `754` → the **classic** root-view dialect
(`-Release 754`); `>= 755` → **view-entity** dialect (`-Release 755`). Capability
cross-check: `verify` reading `TADIR R3TR BDEF` returning zero on the whole system also
means no RAP → same refusal. (Verified: S4D 1909 = 754, has BDEF rows.)

## Step 1.5 — Naming Pre-Check (generate)

Validate all five names via `sap_check_object_name.ps1` (`RAP_INTERFACE_VIEW ZI_<stem>`,
`RAP_PROJECTION_VIEW ZC_<stem>`, `RAP_BEHAVIOR_CLASS ZBP_<stem>`,
`RAP_SERVICE_DEFINITION ZUI_<stem>`, `RAP_SERVICE_BINDING ZUI_<stem>_O2`). A violation →
ask proceed/abort (`OBJECT_NAMING_VIOLATION`).

## Step 2 — generate

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_gen_rap_generate.ps1" -Table <ZTABLE> -Stem <STEM> -Release <754|755> -OutDir "{work_dir}\rap\<stem>" -Package "<PKG>" -Label "<text>" -WorkDir "<work_dir>"
```

Reads the base table's fields + keys over RFC (`DDIF_FIELDINFO_GET`, skips MANDT),
renders the file set (`RAPGEN:` per artifact) + `MANUAL_STEPS.md` + `srvb_spec.md`.
Present the generated set to the user. **The behavior pool is empty** (managed CRUD
needs no handler); validations/determinations from a spec are a manual-paste follow-up
(v1.5). `STATUS: ERROR` on a table with no fields/keys.

## Step 3 — package

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_gen_rap_package.ps1" -WorkDir "{work_dir}\rap\<stem>" -Stem <STEM>
```

Builds `<stem>_rap_abapgit.zip` (abapGit `/src/` PREFIX layout, object-named files +
`.abapgit.xml` + the class `.clas.xml`; SRVB spec + MANUAL_STEPS carried in). Import via
**ZABAPGIT_STANDALONE** (verified present on S4D), then activate in the dependency order
in `MANUAL_STEPS.md`.

## Step 4 — verify (RFC, read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_gen_rap_verify.ps1" -Ddls "ZI_<stem>,ZC_<stem>" -Bdef "ZI_<stem>,ZC_<stem>" -Clas "ZBP_<stem>" -Srvd "ZUI_<stem>" -Srvb "ZUI_<stem>_O2" -WorkDir "<work_dir>"
```

`RAPOBJ:` per object (`ACTIVE|PRESENT|INACTIVE|MISSING|COULD_NOT_CHECK`) +
`STATUS: COMPLETE|PARTIAL`. **BDEF activation and SRVB publish-state are always
`COULD_NOT_CHECK`** (no BDEF/SRVB source table exists on 1909; TADIR presence is
verified, deep state is never falsely passed). Map to findings via `sap_finding_lib.ps1`
(tri-state; a MISSING/INACTIVE object holds the verdict at PARTIAL).

## Step 5 — Register & Log End

Register the file set (kind `rap_fileset`), the zip (`rap_package`), and the verify
report (`rap_verify`, coverage tri-state, verdict COMPLETE/PARTIAL) via
`Register-SapArtifact`. Echo the headline. Then `sap_log_helper.ps1 -Action end`
(SUCCESS / SKIPPED+`RAP_RELEASE_UNSUPPORTED` / FAILED+`RFC_LOGON_FAILED`).

---

## Scope & Limitations

- **v1 implemented (read-only / local):** `generate` (7 templates + live DDIC field/key
  lookup + 7.54/7.55 dialect dispatch + 5-name validation), `package` (abapGit zip),
  `verify` (RFC). Scope guard: **managed, OData V2, root-only, non-draft**. Verified
  live 2026-07-11 on S/4HANA 1909 (S4D): generate rendered a consistent set from real
  T001 (80 fields, MANDT skipped, BUKRS key) in both dialects; verify read a real
  SAP-delivered RAP BO as `COMPLETE` (DDLS/CLAS/SRVD `ACTIVE`, BDEF/SRVB `PRESENT` +
  `COULD_NOT_CHECK`) and an undeployed set as `PARTIAL` (all `MISSING`); package built a
  valid abapGit `/src/` tree. Offline golden-file tested (both dialects, MANDT skip,
  key/non-key aliasing, no trailing comma, `strict ( 2 )` only on 7.55).
- **Honest by construction:** BDEF activation + SRVB publish-state are **always
  `COULD_NOT_CHECK`** (no source table under any probed name on 1909) — never rendered
  passed; a MISSING/INACTIVE object holds the verdict at PARTIAL. `DDDDLSRC`/`SRVDSRC`
  SOURCE columns are RFC-forbidden (string columns → ASSIGN CASTING), so verify uses
  TADIR + DWINACTIV, not source reads.
- **`deploy` (v1.5, not implemented):** the orchestrated partial deploy — root+projection
  CDS via `/sap-gen-cds --ddl-file` (a small passthrough extension to gen-cds, its own
  prerequisite), a confirm-gated **PAUSE 1** to paste the two BDEFs in ADT (no RFC BDEF
  create API on 1909), the behavior pool via `/sap-se24`, a **PAUSE 2** for SRVD/SRVB +
  `/IWFND/MAINT_SERVICE` publish, then a full re-verify. It is a confirm-gated **write**
  path with two ADT-only manual steps, so it ships after the gen-cds extension + a live
  run; until then the **abapGit-import loop (generate → package → import → verify)** is
  the complete no-ADT path. New error class reserved: `RAP_MANUAL_STEP_PENDING`.
- **Not in v1:** `--child` (parent-child compositions), `--draft` (release-gated >= 2020;
  1909 managed RAP has no draft), DDLX metadata, BDEF/SRVD/SRVB installer FMs (a
  reverse-engineering project — real half-install risk). SRVB has no stable text
  serialization → shipped as a spec (`srvb_spec.md`), created in ADT.
