---
name: sap-cc-inventory
description: |
  Enumerates and classifies the custom (Z/Y / customer-namespace) repository
  objects in scope for an S/4HANA migration campaign. Reads TADIR + TRDIR over
  read-only RFC against the campaign's SOURCE system, writes inventory.tsv, and
  upserts every object into the state ledger as INVENTORIED (never touching
  objects further along, so it is safe to re-run as new custom code appears). No
  SAP GUI, no writes, no TR — pure read-only. First SAP-touching step of the
  sap-migrate pipeline; run after /sap-cc-campaign init, before /sap-cc-usage.
  When RFC is blocked, --source-mode GUI ingests /sap-se16n exports of TADIR
  (+ TRDIR) instead (identical output, no NCo). Scope defaults to the brief's
  in_scope_packages; override with --namespace / --packages / --types / --exclude.
  Prerequisites (RFC): SAP NCo 3.1 (32-bit) + a saved source_profile (or pinned
  /sap-login). GUI mode needs only a SAP GUI session for the /sap-se16n export.
argument-hint: "--campaign <id> [--source <profile>] [--source-mode RFC|GUI] [--tadir-file <path>] [--trdir-file <path>] [--namespace Z,Y] [--packages <pat,...>] [--types PROG,CLAS,...] [--exclude <pat,...>]"
---

# SAP Custom-Code Migration — Inventory

You build the custom-code inventory for a migration campaign: list every
in-scope Z/Y repository object on the SOURCE system, write it to the campaign's
`inventory.tsv`, and seed the `state.tsv` ledger with one INVENTORIED row per
object. Everything is **read-only** — `RFC_READ_TABLE` on TADIR/TRDIR only.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. Reads are always allowed; this skill performs none of the forbidden writes. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution contract. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` | *(dot-source)* | `Get-SapWorkDir` / `Get-SapSettingValue`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`, `Resolve-SapProfileHint` (resolves the named `source_profile`). |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | *(dot-source)* | NCo 3.1 connect + `New-RfcReadTable` / `Add-RfcField` / `Add-RfcOption`. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_dpapi.ps1` | *(invoke)* | Decrypt the source profile's stored password. Invoked as a subprocess — never dot-sourced (it has a `$Action` param that would clobber the caller's). |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging. |
| `<SKILL_DIR>/references/sap_cc_inventory.ps1` | *(invoke)* | The enumerator. **RFC mode** resolves the source profile and reads TADIR/TRDIR; **GUI mode** (`-SourceMode GUI`) ingests `/sap-se16n` TADIR (+ TRDIR) exports instead. Both write `inventory.tsv`, upsert `state.tsv`, and emit `INVENTORY:` / `TYPE:` / `STATUS:` lines. |
| `/sap-se16n` | *(skill, GUI fallback)* | Drives SE16N to export TADIR/TRDIR as TSV when RFC is unavailable; the GUI-mode helper ingests those exports. |

The campaign workspace contract (`inventory.tsv` + `state.tsv` columns, the
INVENTORIED state, the upsert rule) is defined by `/sap-cc-campaign`.

> Read-only RFC skill: no SAP GUI, so it does NOT use the session broker, the
> attach library, language-independence VBS rules, or `/sap-transport-request`.

---

## Step 0 — Resolve Work Directory and Settings

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp`; ensure it exists:

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{CAMPAIGN_DIR}` = `{work_dir}\migrations\{campaign-id}`.

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates
`{work_dir}\temp\run_<id>`):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Per the CLAUDE.md "Two-bucket temp model" write this skill's per-run scratch
(the log state file below) under `{RUN_TEMP}`, never at a fixed name under the
`{WORK_TEMP}` root.

---

## Step 0.5 — Start Logging

State file: `{RUN_TEMP}\sap_cc_inventory_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_cc_inventory_run.json" -Skill sap-cc-inventory -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments & Pre-flight

Parse `$ARGUMENTS`:

- `--campaign <id>` — **required.** If `{CAMPAIGN_DIR}\campaign.json` is missing,
  print `ERROR: campaign '<id>' not found — run /sap-cc-campaign init` and exit `1`.
- `--source <profile>` — override the campaign's `systems.source_profile`.
- `--namespace <list>` — object-name prefixes (e.g. `Z,Y`). Defaults to the
  brief's `scope.in_scope_packages`, then `Z,Y`.
- `--packages <list>` — DEVCLASS patterns (e.g. `ZHK*,ZFI*`); when given, scope
  is by package instead of object-name prefix.
- `--types <list>` — restrict to these TADIR OBJECT values (e.g. `PROG,FUGR,CLAS,TABL`).
- `--exclude <list>` — drop objects whose name matches any pattern (e.g. `ZLEGACY_*,ZTEST_*`).

This skill **reads** the SAP system; per `skill_operating_rules.md` reads need
no confirmation. It writes only to the campaign workspace on disk.

---

## Step 2 — Run the Inventory Enumerator (32-bit PowerShell)

NCo 3.1 lives in `GAC_32`, so run via 32-bit PowerShell:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_inventory.ps1" -CampaignDir "{CAMPAIGN_DIR}" -WorkDir "{work_dir}" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>\scripts"
```

Append any of `-SourceProfile "<p>"`, `-Namespace "Z,Y"`, `-Packages "ZHK*"`,
`-Types "PROG,CLAS"`, `-Exclude "ZLEGACY_*"` to mirror the CLI flags.

**How it connects:** the helper resolves the source profile via
`Resolve-SapProfileHint` (the campaign's `source_profile`, or `--source`),
decrypts its password through `sap_dpapi.ps1`, and connects read-only. With no
profile it falls back to the pinned `/sap-login` connection. Point `source` at
an ECC system copy / sandbox — never production-write paths (this skill never
writes, but keep the topology disciplined).

**What it reads:** `TADIR` (`OBJECT`, `OBJ_NAME`, `DEVCLASS`, `AUTHOR`, filtered
`PGMID='R3TR'` + namespace/package) and `TRDIR` (`SUBC`, for program sub-type).
Only rock-solid fields are requested, so it won't trip `FIELD_NOT_VALID` across
releases. `REPOSRC` is never touched (cluster table — `sap_rfc_lib` forbids it).

---

## Step 2 (GUI fallback) — `--source-mode GUI` (no RFC)

When RFC to the source is blocked but you can reach it via **SAP GUI**, export
TADIR (and optionally TRDIR) with `/sap-se16n`, then ingest. No NCo; the ingest
runs in any PowerShell.

1. **Export TADIR** — the in-scope custom objects. Filter `PGMID = R3TR` plus
   your scope (`DEVCLASS` for a package, or `OBJ_NAME` CP `Z*` for a namespace),
   selecting at least `OBJECT`, `OBJ_NAME`, `DEVCLASS`, `AUTHOR` (+ `PGMID`):

   ```
   /sap-se16n TADIR PGMID=R3TR DEVCLASS=ZHK* select=PGMID,OBJECT,OBJ_NAME,DEVCLASS,AUTHOR
   ```

2. **(Optional) Export TRDIR** for program `sub_type` enrichment:

   ```
   /sap-se16n TRDIR NAME=Z* select=NAME,SUBC
   ```

3. **Ingest the exports** (plain `powershell` — no 32-bit / NCo needed). Each
   `/sap-se16n` run writes its export to its OWN per-run scratch dir and
   reports the path (`{RUN_TEMP}\se16n_<TABLE>.txt` of THAT run) — pass those
   reported paths here:

   ```bash
   powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_inventory.ps1" -CampaignDir "{CAMPAIGN_DIR}" -SourceMode GUI -TadirFile "<path se16n reported for TADIR>" -TrdirFile "<path se16n reported for TRDIR>" -Packages "ZHK*"
   ```

   Pass the same `-Packages` / `-Namespace` / `-Types` / `-Exclude` flags as RFC
   mode — GUI mode re-applies them (and drops any non-`R3TR` rows), so a slightly
   broad export still yields the correct in-scope inventory. The parser maps
   columns by **technical field name** (`OBJ_NAME`, `OBJECT`, `DEVCLASS`,
   `AUTHOR`, `PGMID`), so the export's column order does not matter. Output
   grammar, files, and exit codes are identical to RFC mode (Step 3 / Step 4).

---

## Step 3 — Interpret the Output

The helper prints:

```
TYPE: <OBJECT> | COUNT: <n>
...
INVENTORY: total=<n> new=<n> existing=<n> file=<path>
STATUS: OK | PARTIAL failed_slices=<k> | EMPTY | ERROR
```

| Exit | Meaning |
|---|---|
| `0` | `STATUS: OK` — `inventory.tsv` written, `state.tsv` upserted. |
| `1` | `STATUS: EMPTY` — no in-scope objects found. Re-check `--namespace`/`--packages`. |
| `2` | `STATUS: ERROR` — bad workspace, profile not found/ambiguous, or RFC failure. Also emitted when EVERY namespace/package slice failed (one `ERROR:` line per slice) — nothing is written then, so a previous good inventory is never clobbered. |
| `3` | `STATUS: PARTIAL failed_slices=<k>` — (RFC mode) `<k>` namespace/package slice(s) failed while others succeeded (one `ERROR: RFC_READ_TABLE TADIR failed for [...]` line each). `inventory.tsv` / `state.tsv` **are** written but are **INCOMPLETE**. |

**A PARTIAL inventory must NOT silently become the campaign scope.** On exit
`3`, STOP the pipeline: report which slices failed, fix the cause (RFC error,
authorization, bad pattern) and re-run until `STATUS: OK` — or get the
operator's **explicit** approval to proceed with the reduced scope. Never run
`/sap-cc-usage` on a PARTIAL inventory as if it were complete: every object in
a failed slice would silently fall out of the migration campaign.

Render a short summary (total + new/existing + the per-type breakdown). On
success, recommend the next step:

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\..\sap-cc-campaign\references\sap_cc_campaign.ps1" -Action next -CampaignDir "{CAMPAIGN_DIR}"
```

(or just tell the operator to run `/sap-cc-campaign next` / `/sap-cc-usage`).

---

## Step 4 — Outputs (campaign workspace)

- `{CAMPAIGN_DIR}\inventory.tsv` — `obj_name · obj_type · sub_type · package · app_component · author · created_on · changed_on` (this skill owns this file).
- `{CAMPAIGN_DIR}\state.tsv` — one `INVENTORIED` row per **newly** discovered object (existing rows untouched).

---

## Limitations / Known gaps (draft)

- **Enrichment is partial in v1.** `sub_type` is populated for programs (TRDIR
  `SUBC` → REPORT / MODULE_POOL / INCLUDE / …) on the namespace-enumeration
  path. `app_component`, `created_on`, and `changed_on` are left blank — they
  need TDEVC / per-type date joins whose field names vary by release, deferred
  to keep the RFC reads `FIELD_NOT_VALID`-proof.
- **R3TR top-level objects only.** Individual function modules (LIMU FUNC) are
  not listed separately; their function group (FUGR) is. ATC analyzes at the
  group/include level, so this matches the analysis unit.
- **No pruning.** Objects deleted on the source since a previous run are not
  removed from `inventory.tsv` / `state.tsv` (re-run adds; it never deletes).
- **Scale.** Each namespace/package pattern is one `RFC_READ_TABLE` returning
  all matches; bounded by the customer namespace (typically thousands–low tens
  of thousands). Very large estates may want package-batched runs.
- **Package-scope sub_type.** When scoping by `--packages` (DEVCLASS) rather than
  name prefix, `sub_type` is left blank (no cheap TRDIR prefix to join on).
- **GUI fallback (`--source-mode GUI`).** For RFC-blocked sites, ingests
  `/sap-se16n` TADIR (+ TRDIR) exports instead of reading over RFC. Re-applies
  the scope / type / exclude filters and the `PGMID=R3TR` guard in-helper, and
  maps columns by technical field name (export column order irrelevant). Needs
  the export to carry SE16N's technical-name header (the default). `sub_type`
  is enriched only when a TRDIR export is supplied via `-TrdirFile`.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_cc_inventory_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status SKIPPED -ExitCode 1 -ErrorClass CC_INVENTORY_EMPTY`;
for exit `2` use `-Status FAILED -ExitCode 2 -ErrorClass CC_INVENTORY_RFC`;
for exit `3` use `-Status FAILED -ExitCode 3 -ErrorClass CC_INVENTORY_PARTIAL`.
