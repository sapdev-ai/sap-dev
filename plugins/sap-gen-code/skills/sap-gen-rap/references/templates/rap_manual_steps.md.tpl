# RAP Manual Steps — %%STEM%%

Generated file set for a **managed, root-only, OData V2** RAP business object over
table `%%TABLE%%` (SAP_BASIS %%RELEASE%%). Names:

| Artifact | Name | File |
|---|---|---|
| Interface (root) CDS view | `%%ROOT_VIEW%%` | `%%ROOT_FILE%%` |
| Projection CDS view | `%%PROJ_VIEW%%` | `%%STEM_LOWER%%_zc.ddls.asddls` |
| Interface behavior definition | `%%ROOT_VIEW%%` | `%%STEM_LOWER%%_zi.bdef.asbdef` |
| Projection behavior definition | `%%PROJ_VIEW%%` | `%%STEM_LOWER%%_zc.bdef.asbdef` |
| Behavior pool (impl class) | `%%BEHAVIOR_CLASS%%` | `zbp_%%STEM_LOWER%%.clas.abap` |
| Service definition | `%%SERVICE_DEF%%` | `zui_%%STEM_LOWER%%.srvd.assrvd` |
| Service binding (OData V2 UI) | `%%SERVICE_BINDING%%` | `srvb_spec.md` (create in ADT) |

## Import path A — abapGit (no ADT)

`/sap-gen-rap package %%WORKDIR%%` builds `%%STEM_LOWER%%_rap_abapgit.zip`. Import it
with **ZABAPGIT_STANDALONE** (verified present on the target). Activate in dependency
order (below). SRVB has no stable serialization → create it manually (step 6).

## Import path B — guided deploy (`/sap-gen-rap deploy`, v1.5)

Delegates the CDS legs to `/sap-gen-cds --ddl-file` and pauses (confirm-gated) for the
two ADT-only steps. Requires the `/sap-gen-cds --ddl-file` passthrough.

## Activation order (compile dependencies — do not reorder)

1. **Root CDS** `%%ROOT_VIEW%%` (`%%ROOT_FILE%%`) — activate first.
2. **Projection CDS** `%%PROJ_VIEW%%` — depends on the root view.
3. **Interface BDEF** `%%ROOT_VIEW%%` (`%%STEM_LOWER%%_zi.bdef.asbdef`) — paste in ADT
   (**ADT-only** — no RFC create API on this release); the behavior pool compiles only
   after it exists.
4. **Behavior pool** `%%BEHAVIOR_CLASS%%` — deploy via `/sap-se24` (empty managed pool;
   no handler code needed for managed CRUD).
5. **Projection BDEF** `%%PROJ_VIEW%%` — paste in ADT.
6. **Service definition** `%%SERVICE_DEF%%` — paste in ADT (or `/sap-gen-cds`-style).
7. **Service binding** `%%SERVICE_BINDING%%` — create in ADT as **OData V2 - UI**,
   bind `%%SERVICE_DEF%%`, then **Publish**. Publish via tcode `/IWFND/MAINT_SERVICE`.

## Verify

`/sap-gen-rap verify %%WORKDIR%%` re-reads every artifact over RFC (TADIR, DDLS active,
SRVD source, SRVB registered/published). BDEF **activation state is COULD_NOT_CHECK** on
this release (no BDEF source table exists under any probed name) — presence via TADIR
`R3TR BDEF` is verified; activation is never falsely reported as passed.
