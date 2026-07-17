# SAP CDS View Generation Skill

Generates an ABAP CDS view (Core Data Services) from a spec or a
natural-language description and deploys it to a live SAP system **without
ADT** — the DDL source is created and activated through the RFC-enabled
installer FM `Z_CDS_DDL_INSTALL` (which hosts `CL_DD_DDL_HANDLER_FACTORY`).

Part of the clean-core codegen lane, alongside `/sap-gen-abap`: where the spec
pipeline (`/sap-docs-extract` → `/sap-docs-check` → `/sap-gen-abap`) produces
classic ABAP, this skill covers the CDS view artefact on systems where no ADT
/ Eclipse tooling is available.

## Skill Overview

1. **Release gate** — probe `SAP_BASIS` via RFC (`sap_cds_release_probe.ps1`).
   Below 7.50 the skill stops with an honest `NOT_SUPPORTED` (use
   `/sap-gen-abap` instead). Classic DDL (`DEFINE VIEW` +
   `@AbapCatalog.sqlViewName`) works on 7.50–7.54; view entities
   (`DEFINE VIEW ENTITY`) need 7.55+ and are opt-in
2. Resolve the view spec (name, base source(s), field list, annotations,
   package/TR, dialect) from the arguments, a spec file, or the extracted
   spec pipeline; validate names against the `CDS_VIEW` / `CDS_SQL_VIEW`
   naming rules
3. Generate the DDL offline and present it to the user before deploying
4. Ensure the installer FM exists (one-time bootstrap per system via
   `/sap-se37`, Remote-Enabled), then deploy: create the DDLS source,
   register its TADIR entry under the package, activate (generating the SQL
   view for classic views)
5. Verify via RFC — TADIR (DDLS) plus DD02L / DD25L for the generated SQL view
6. Quality gate via `/sap-atc` (currently emitted as `ATC: SKIPPED` — see
   Limitations)

A `--delete` flow removes the view through the DDL handler API and clears the
leftover DDLS TADIR orphan, with confirmation first.

## Auto-Trigger Keywords

- `generate cds view`, `create a CDS view for table ...`
- `deploy cds without ADT`, `delete cds view Z...`

## Usage

```text
/sap-gen-cds <VIEW_NAME> [--from <spec-or-desc>] [--sql-view <NAME>] [--base <TABLE>] [--package <PKG>] [--delete] [--activate|--no-activate]
```

Examples:

```text
/sap-gen-cds ZCDS_MARA_BASIC --base MARA --package $TMP
/sap-gen-cds ZCDS_SALES_ITEMS --from "join VBAK and VBAP, key order + item"
/sap-gen-cds ZCDS_MARA_BASIC --delete
```

Flags:

- `--from <spec-or-desc>` — spec file or natural-language description of the view
- `--sql-view <NAME>` — SQL view name for classic views (≤16 chars; derived
  from the view name when omitted)
- `--base <TABLE>` — base table / CDS view
- `--package <PKG>` — default `$TMP` (no TR); a Z package resolves a TR via
  `/sap-transport-request`
- `--no-activate` — stage the DDL source inactive (`EV_STATE=CREATED`)
- `--delete` — remove the view (irreversible; confirmed first)

## Key Files

| File | Purpose |
|---|---|
| `references/sap_cds_release_probe.ps1` | RFC read of CVERS SAP_BASIS for the release gate |
| `references/Z_CDS_DDL_INSTALL.abap` | Installer FM source of record (one-time bootstrap) |
| `references/sap_cds_deploy.ps1` | RFC caller for the installer FM (CREATE / DELETE) |
| `references/sap_cds_verify.ps1` | RFC verification: TADIR(DDLS) + generated SQL view active |

## Prerequisites

- SAP profile saved via `/sap-login` (RFC password required)
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC
- `SAP_BASIS >= 7.50` on the target system
- Installer FM `Z_CDS_DDL_INSTALL` present + Remote-Enabled (Step 3 bootstraps
  it via `/sap-se37` if absent; needs an active GUI session for that one-time
  deploy)

## Suggested next steps

- `/sap-atc` — once its SCI object-set builder gains a DDLS/CDS category
  (tracked follow-up)
- `/sap-se16n <SQL_VIEW_NAME>` — inspect the generated SQL view's data

## Limitations

- **Phase 1 = basic / composite views only.** RAP behaviour definitions and
  OData binding are out of scope (demand-gated Phase 2).
- **No ATC gate for CDS yet** — `/sap-atc` has no DDLS object-set category, so
  the skill reports `ATC: SKIPPED` rather than a false pass.
- View entities require 7.55+; on 7.50–7.54 only classic views are emitted.
- `DDDDLSRC` is not `RFC_READ_TABLE`-safe, so verification goes through TADIR
  + DD02L / DD25L rather than reading the DDL source back.
- Deletion is irreversible and always confirmed with the user first.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
