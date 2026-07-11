# sap-gen-rap

**Generate a complete, consistent managed-RAP business object from a base table —
without ADT.** Writing a RAP file set by hand (interface CDS + projection + a BDEF pair
+ behavior pool + SRVD/SRVB, all cross-referencing each other with exact names) is
error-prone even in ADT. This renders the whole set, packages it for a no-ADT abapGit
import, and verifies the result with authoritative RFC re-reads.

```
/sap-gen-rap generate SalesOrder --table ZSALES_ORDER   # render the full file set
/sap-gen-rap package  {work}\rap\salesorder             # abapGit zip -> ZABAPGIT_STANDALONE
/sap-gen-rap verify   --stem SalesOrder                 # RFC re-read every artifact
```

## The no-ADT loop

**generate** resolves the table's fields + keys live (`DDIF_FIELDINFO_GET`, MANDT
skipped) and renders 7 artifacts — root CDS (`ZI_*`), projection CDS (`ZC_*`), the two
behavior definitions, the (empty, managed) behavior pool (`ZBP_*`), the service
definition (`ZUI_*`), a service-binding spec, and `MANUAL_STEPS.md`. Dialect-forked:
**7.54** classic `define root view` + `@AbapCatalog.sqlViewName`; **7.55+**
`define root view entity` + `strict ( 2 )`. **package** lays them out as an abapGit
`/src/` repo (`.abapgit.xml` + object-named files + the class `.clas.xml`) so
**ZABAPGIT_STANDALONE** (verified present on S4D) imports them with no ADT. **verify**
re-reads every object over RFC.

## Honest by construction

BDEF activation and SRVB publish-state are **always `COULD_NOT_CHECK`** — no BDEF/SRVB
source table exists on 1909 under any probed name, so TADIR presence is verified but
deep state is **never** rendered as a pass; a `MISSING`/`INACTIVE` object holds the
verdict at `PARTIAL`. `DDDDLSRC`/`SRVDSRC` SOURCE columns are RFC-forbidden (string
columns), so CDS/SRVD active-state comes from TADIR + `DWINACTIV`, not source reads.

## Scope

**S/4-only** — refuses SAP_BASIS < 7.54 or a system with no RAP infrastructure
(`RAP_RELEASE_UNSUPPORTED`). Managed / OData V2 / root-only / non-draft. `generate`,
`package`, `verify` are read-only/local and shipped. **`deploy`** (guided partial deploy
with two ADT-only paste pauses + the `/sap-gen-cds --ddl-file` passthrough) is a
confirm-gated **write** path deferred to v1.5 — the abapGit-import loop above is the
complete no-ADT alternative.

Verified live 2026-07-11 on S/4HANA 1909 (S4D): generate from real T001 (both dialects);
verify read a real SAP-delivered RAP BO as COMPLETE and an undeployed set as PARTIAL;
package produced a valid abapGit tree. Part of the sap-gen-code plugin (joins the
clean-core codegen lane next to /sap-gen-cds and /sap-gen-abap).
