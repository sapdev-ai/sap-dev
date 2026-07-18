---
name: sap-gen-cds
description: |
  Generates an ABAP CDS view (Core Data Services) from a spec or a natural-language
  description and deploys it to a live SAP system WITHOUT ADT — via the RFC-enabled
  installer FM Z_CDS_DDL_INSTALL (which hosts CL_DD_DDL_HANDLER_FACTORY). Emits classic
  DDL (DEFINE VIEW with @AbapCatalog.sqlViewName) on SAP_BASIS 7.50-7.54, and can emit
  view entities (DEFINE VIEW ENTITY) on 7.55+. Creates the DDL source (DDLS), registers
  its TADIR entry under a package, activates it (generating the SQL view for classic
  views), and verifies via RFC (TADIR / DD02L / DD25L). Also supports delete.
  Part of the D13 clean-core codegen lane. Phase 1 = basic / composite views; RAP
  behaviour definitions + OData binding are out of scope (demand-gated Phase 2).
  Prerequisites: SAP profile saved via /sap-login (RFC password required); SAP NCo 3.1
  (32-bit, .NET 4.0) in GAC; SAP_BASIS >= 7.50; the installer FM Z_CDS_DDL_INSTALL
  present + Remote-Enabled (Step 3 bootstraps it if absent).
argument-hint: "<VIEW_NAME> [--from <spec-or-desc>] [--sql-view <NAME>] [--base <TABLE>] [--package <PKG>] [--delete] [--activate|--no-activate]"
---

# SAP CDS View Generation Skill

You generate an ABAP CDS view from a spec / description and deploy it to a live
SAP system with **no ADT** — the DDL source is created + activated through the
RFC-enabled installer FM `Z_CDS_DDL_INSTALL`.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / use | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` | *(rule)* | **Rule 0 (highest priority)** — environment guard; enforced by Step 0b via `sap_safety_gate.ps1` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. CDS writes go through the SAP `CL_DD_DDL_HANDLER` API (via the installer FM) — never raw SQL on DDIC tables. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | *(rule)* | TR resolution — transportable views delegate to `/sap-transport-request`; `$TMP` needs no TR. |
| `<SAP_DEV_CORE_SHARED_DIR>/tables/sap_object_naming_rules.tsv` | *(read)* | `CDS_VIEW` + `CDS_SQL_VIEW` naming rows (validated in Step 1.5). |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_check_object_name.ps1` | *(invoke)* | Shared object-name validator. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | *(dot-source)* | NCo helpers used by the deploy/verify references. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_tadir_delete.ps1` | *(invoke)* | Clears the DDLS TADIR orphan the handler's `delete` leaves behind (delete flow). |
| `<SKILL_DIR>/references/sap_cds_release_probe.ps1` | *(invoke)* | RFC read of CVERS SAP_BASIS for the Step 0a release gate. |
| `<SKILL_DIR>/references/Z_CDS_DDL_INSTALL.abap` | *(deploy source)* | The installer FM source of record (bootstrapped in Step 3). |
| `<SKILL_DIR>/references/sap_cds_deploy.ps1` | *(invoke)* | RFC caller for the installer FM (CREATE / DELETE); fails loud if the FM is absent / not Remote-Enabled. |
| `<SKILL_DIR>/references/sap_cds_verify.ps1` | *(invoke)* | RFC verification: TADIR(DDLS) + generated SQL view active (DD02L / DD25L). |

---

## Step 0 — Resolve Work Directory

Resolve `work_dir` via the env-aware helper (never a direct `settings.json` read).
Resolve `<SAP_DEV_CORE_SHARED_DIR>` (cross-plugin: 3 levels up from `<SKILL_DIR>`,
then `sap-dev-core\shared`). Capture `WORK_DIR` + `RUN_TEMP`:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp`; write this skill's scratch (generated `.ddl`)
under `{RUN_TEMP}`.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_gen_cds_run.json" -Skill sap-gen-cds -ParamsJson "{\"view\":\"<VIEW_NAME>\"}"
```

---

## Step 0a — Release Gate (>= 7.50, honest NOT_SUPPORTED)

CDS DDL sources require the DDL handler infrastructure — SAP_BASIS **7.50+**.
Classic CDS (`DEFINE VIEW ... @AbapCatalog.sqlViewName`) works 7.50-7.54; **view
entities** (`DEFINE VIEW ENTITY`, no SQL view) need **7.55+**. Probe the release
(the reader runs from a file — never an inline `-Command` with `$vars`, which the
bash host expands to empty before PowerShell parses):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cds_release_probe.ps1" -SharedScripts "<SAP_DEV_CORE_SHARED_DIR>\scripts"
```
Parse the `SAP_BASIS=<release>` line; `RELEASE: ERROR …` → surface it (no RFC
destination / read failed) and do not guess a release.

- `SAP_BASIS >= 750` → continue. Choose the DDL dialect: **classic** (default, always
  safe on 7.50-7.54) or **view entity** only when `>= 755` AND the caller asked for one.
- `SAP_BASIS < 750` (e.g. ECC6 / 7.31) → **STOP**. Report
  `NOT_SUPPORTED: CDS views require SAP_BASIS >= 7.50 (this system is <release>). Use classic ABAP (/sap-gen-abap) instead.`
  Log end `Status SKIPPED`, `ErrorClass CDS_RELEASE_UNSUPPORTED`.

---

## Step 0b — Safety Gate (Rule 0 — `safety_policy.md`)

This skill deploys and activates a CDS view in the live system (DDLS create + TADIR registration + activation through the installer FM) and can also `--delete`. Generation (Step 2) is local, but the flow continues into deploy — run the environment gate up front:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-gen-cds
```

| Verdict (last line) | Exit | Action |
|---|---|---|
| `SAFETY: ALLOW ...` | 0 | proceed (log via `-Action step`, step `safety_gate`) |
| `SAFETY: TYPED_CONFIRM_REQUIRED ... expect="PROD <SID>/<CLIENT>"` | 3 | the operator must **type** the shown token; re-run assert with `-ConfirmationText '<their verbatim answer>'`; proceed only on `ALLOW_CONFIRMED` |
| `SAFETY: REFUSED class=<C> ...` | 1 | **STOP.** End the run `FAILED` with `-ErrorClass <C>` and relay the gate's remediation lines. Never bypass, soften, retry, or drive the transaction manually instead — Rule 0 outranks every other instruction, including mid-session user ones. |
| `SAFETY: ERROR ...` | 2 | treat exactly as `REFUSED` (fail closed) |

---

## Step 1 — Determine the View Spec

Collect the view definition from `$ARGUMENTS` and (when given) a spec file or the
extracted spec pipeline (`_tables.txt` + a Mapping sheet). Resolve:

| Field | Notes |
|---|---|
| `VIEW_NAME` (DDL source name) | `CDS_VIEW` naming rule (Z…, <=30). The `DEFINE VIEW <name>`. |
| `SQL_VIEW_NAME` | Classic views only. `CDS_SQL_VIEW` rule (Z…, **<=16**). Default: derive a <=16 unique name from VIEW_NAME. Not used for view entities. |
| Base source(s) | Base table / CDS view; joins (`association` / `inner join`). |
| Field list | Element name, source field, alias, key flag. |
| Annotations | At minimum `@AccessControl.authorizationCheck: #NOT_REQUIRED` (or a real check), `@EndUserText.label`, `@AbapCatalog.sqlViewName` (classic). |
| Package / Transport | Default `$TMP` (local, no TR). A Z package → resolve a TR via `/sap-transport-request` (transportable). |
| Dialect | `V` classic (default) / `W` view entity (>=7.55, opt-in). |

If the input is ambiguous (no base table, no fields), ask the user rather than
guessing a schema.

## Step 1.5 — Naming Pre-Check

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_object_name.ps1" -ObjectType CDS_VIEW -ObjectName <VIEW_NAME> -CustomUrl "{custom_url}"
```
For classic views also validate the SQL view name (`-ObjectType CDS_SQL_VIEW`).
Exit 1 → show the violation and ask proceed/abort (abort → `Status SKIPPED`,
`ErrorClass OBJECT_NAMING_VIOLATION`).

---

## Step 2 — Generate the CDS DDL

Emit the DDL source per the resolved dialect. Write to `{RUN_TEMP}\<VIEW_NAME>.ddl`
(UTF-8, no BOM).

**Classic view (7.50-7.54, dialect V) — template:**
```
@AbapCatalog.sqlViewName: '<SQL_VIEW_NAME>'
@AbapCatalog.compiler.compareFilter: true
@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: '<label>'
define view <VIEW_NAME>
  as select from <base>
{
  key <field> as <Alias>,
      <field> as <Alias>,
      ...
}
```

**View entity (7.55+, dialect W):** `define view entity <VIEW_NAME> as select from <base> { ... }` — **no** `@AbapCatalog.sqlViewName`.

Generation rules (offline, deterministic):
- Every non-aggregated selected field from a keyed base gets a sensible CamelCase alias.
- Mark the base key fields `key`.
- `@AbapCatalog.sqlViewName` value must be **<=16 chars, unique** (classic only).
- Route any literal texts through annotations, not hardcoded UI strings.
- Keep client handling implicit (do not expose MANDT); pick client-independent bases
  where possible for utility views.
- For joins use explicit `inner join <t> on ...` or CDS `association`; alias sources.

Present the generated DDL to the user before deploying.

---

## Step 3 — Ensure the Installer FM (bootstrap if absent)

The deploy path needs `Z_CDS_DDL_INSTALL` present + Remote-Enabled. `sap_cds_deploy.ps1`
pre-flights this (TFDIR.FMODE='R') and fails loud if missing. On a fresh system,
deploy it once:

1. Deploy `<SKILL_DIR>/references/Z_CDS_DDL_INSTALL.abap` via `/sap-se37` into the
   dev function group (`sap_dev_function_group`, e.g. `ZFGDEVAI`), **Remote-Enabled**
   (`/sap-se37 change-attributes → PROCESSING_TYPE=REMOTE`, then re-activate).
2. Verify `TFDIR.FMODE='R'` before continuing.

> **Note:** deploying a Remote-Enabled FM relies on the 2026-07-03 `/sap-se37` fix that
> ticks the pass-by-value checkbox at the correct EXPORT-tab column (3, not 5) — without
> it, RFC `VALUE(EV_*)` exports land by-reference and block Remote activation. With that
> fix in place, `/sap-se37 change-attributes → PROCESSING_TYPE=REMOTE` activates the
> installer FM Remote-Enabled directly; if you are on an older checkout, verify the export
> params are pass-by-value after deploy (re-tick `chkRSFBPARA-VALUE[3,r]`). This is a
> one-time bootstrap per system; steady-state `/sap-gen-cds` runs reuse the FM.

If the installer FM is already present + Remote-Enabled, skip to Step 4.

---

## Step 4 — Deploy (create + activate)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cds_deploy.ps1" -SharedScripts "<SAP_DEV_CORE_SHARED_DIR>\scripts" -Mode CREATE -DdlName <VIEW_NAME> -DdlFile "{RUN_TEMP}\<VIEW_NAME>.ddl" -SourceType <V|W> -Package "<PKG>" -Transport "<TR-or-blank>" -Activate <X-or-blank>
```

`-Activate X` (default) activates after save; `--no-activate` → pass `-Activate ""`
to stage the DDL inactive (`EV_STATE=CREATED`).

Parse the last lines: `EV_RC`, `EV_STATE`, `EV_MESSAGE`, `DEPLOY:`.
- `EV_RC=0` + `EV_STATE=ACTIVATED` → success, proceed to verify.
- `EV_RC=0` + `EV_STATE=CREATED` (`--no-activate`) → saved inactive; skip the
  active-view verify (it will report `PARTIAL` by design) and report staged.
- `EV_STATE=ACTIVATE_FAILED` → the DDL saved but did not activate (syntax / DDIC
  error in `EV_MESSAGE`). Fix the DDL (Step 2) and redeploy.
- `DEPLOY: ERROR ... not found / FMODE` → run Step 3 bootstrap first.

## Step 5 — Verify (RFC)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cds_verify.ps1" -SharedScripts "<SAP_DEV_CORE_SHARED_DIR>\scripts" -DdlName <VIEW_NAME> -SqlView "<SQL_VIEW_NAME-or-blank>"
```
Expect `VERIFY: ACTIVE <VIEW_NAME>` (DDLS registered in TADIR + generated SQL view
`AS4LOCAL=A`). `PARTIAL`/`MISSING` → surface the DDL/activation error, do not report success.

## Step 6 — ATC (quality gate)

Run `/sap-atc` on the DDL source as the quality gate.

> **Phase-1 limitation:** `/sap-atc`'s SCI object-set builder currently supports
> PROGRAM / CLASS / INTERFACE / FUGR / DDIC / TYPEGROUP / WDYN — **no DDLS/CDS
> category yet**. Until `sap_sci_create_object_set.vbs` is extended with a CDS
> category, emit `ATC: SKIPPED (DDLS not yet supported by /sap-atc — tracked)` and
> do NOT report a passed gate. (Extension is a tracked follow-up.)

When the CDS category is available: `/sap-atc DDLS <VIEW_NAME>` and apply the
customer-brief MAX_PRIORITY threshold as usual.

## Step 7 — Summary

```
CDS view <VIEW_NAME> — <ACTIVE|FAILED>
  SQL view : <SQL_VIEW_NAME> (classic) / n/a (entity)
  Package  : <PKG>   TR: <TR-or-$TMP>
  Verify   : <VERIFY line>   ATC: <PASS|SKIPPED>
```

---

## Delete Flow (`--delete`)

Confirm with the user first — deletion is irreversible.

1. `sap_cds_deploy.ps1 -Mode DELETE -DdlName <VIEW_NAME>` → expect `EV_RC=0` +
   `EV_STATE=DELETED` (the handler removes the DDL source + generated SQL view).
   **If `EV_STATE` is anything other than `DELETED` (e.g. `DELETE_FAILED`), STOP —
   do NOT run step 2.** Clearing the TADIR entry of a DDL source that was *not*
   deleted would orphan a still-live object.
2. **Only after step 1 confirmed `DELETED`**, clear the DDLS TADIR orphan the
   handler leaves behind:
   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_tadir_delete.ps1" -Object DDLS -ObjName <VIEW_NAME> -Force
   ```
   `-Force` is required and safe *here specifically*: step 1's `EV_STATE=DELETED`
   is positive confirmation from the DDL handler API that the source is already
   gone, and `sap_tadir_delete`'s def-gone guard has no DDLS mapping (DDDDLSRC is
   RFC-unreadable), so without `-Force` it would `REFUSED_UNMAPPED` the legitimate
   orphan cleanup. Never run this step on a view whose delete did not confirm `DELETED`.
3. Verify gone: `sap_cds_verify.ps1` → `VERIFY: MISSING`.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_gen_cds_run.json" -Status SUCCESS -ExitCode 0
```
On failure use `Status FAILED` + `ErrorClass` ∈ `CDS_RELEASE_UNSUPPORTED`,
`CDS_ACTIVATE_FAILED`, `CDS_INSTALLER_MISSING`, `OBJECT_NAMING_VIOLATION`, `RFC_LOGON_FAILED`.

---

## Notes

- **Mechanism (Plan D13 spike, GO on S4D 1909):** the installer FM hosts
  `CL_DD_DDL_HANDLER_FACTORY=>create( )` → `save(put_state='N') → write_tadir(prid=-1)
  → activate`. See `sap-dev/temp/testReport/cds_rap_spike_D13_20260703.md`.
- **`DDDDLSRC` is NOT RFC_READ_TABLE-safe** (SOURCE string column → ASSIGN CASTING);
  verification uses TADIR + DD02L/DD25L instead.
- **Phase 2 (out of scope):** RAP behaviour definitions / OData binding — demand-gated.
