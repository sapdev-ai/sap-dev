# sap-cc-decommission

**Execute the retirement of unused custom code — behind a hard signed gate and
a per-object safety chain.**
`/sap-cc-usage` only *flags* objects for decommission; this skill physically
deletes them on the campaign's source system, turning "40–60% of custom code
is unused" into a realized, audited scope reduction. Sits in the sap-migrate
pipeline after `/sap-cc-usage` (inventory → usage → **decommission** → analyze
→ triage → remediate, orchestrated by `/sap-cc-campaign`). Deletions are
irreversible and transported to QA/PROD — so nothing runs unsigned, nothing
still-referenced is deleted, and nothing is ledgered that wasn't confirmed
gone.

```
/sap-cc-decommission plan   --campaign <id>
/sap-cc-decommission plan   --campaign <id> --objects ZOLD1,ZOLD2
/sap-cc-decommission plan   --campaign <id> --include-review
/sap-cc-decommission record --campaign <id> --results <results.tsv>
```

## Two actions

- **`plan`** — behind the **`decommission_signoff`** gate: builds the ordered
  retirement worklist from `scope.tsv` (consumers before providers). If the
  gate is not APPROVED it prints `BLOCKED:` and exits `3` — record it via
  `/sap-cc-campaign signoff --gate decommission_signoff` first. Nothing is
  deleted by `plan`. Even with the gate signed, the operator's explicit OK for
  THIS batch is obtained before executing.
- **`record`** — after the delegated deletes: appends confirmed-gone objects
  to the `decommission\decommissioned.tsv` audit ledger and stamps their
  `state.tsv` row DECOMMISSIONED. FAILED/SKIPPED rows are counted, never
  ledgered, and stay candidates for a later run (`plan` is idempotent).

## The per-object safety chain (execute step)

A mandatory **system assertion** first confirms the pinned connection IS the
campaign's decommission target — never "delete on whatever is connected".
Then, per worklist row in order:

1. **Re-verify** — `/sap-where-used-list` (any inbound caller from a
   still-used object → SKIP) + `sap_object_resolver.ps1` (still exists, not
   locked in another user's TR).
2. **Back up the source** — `Read-SapAbapSource` (classes via `/sap-se24`
   download), registered as a `source_backup` artifact for
   `/sap-evidence-pack`.
3. **Resolve a Workbench TR** via `/sap-transport-request` (never Local — the
   retirement must propagate).
4. **Delete via the routed skill** — PROG→`/sap-se38`, CLAS/INTF→`/sap-se24`,
   FUGR→`/sap-function-group`, DDIC→`/sap-se11`; unmapped types route to
   `MANUAL`. Delegation is skill→skill, never by driving their VBS directly.
5. **Confirm gone** — the resolver must return `NOT_FOUND` before the object
   may be ledgered; still resolvable = FAILED, not retired.

## Prerequisites

- `scope.tsv` with DECOMMISSION rows (or operator-promoted REVIEW objects that
  cleared the `/sap-cc-usage` where-used gate).
- SAP NCo 3.1 (32-bit) + the source connection (`/sap-login`); the workbench
  delete skills additionally need an active SAP GUI session.

## Key reference files

- `references/sap_cc_decommission.ps1` — the offline engine: `plan` (gated
  worklist) and `record` (audit ledger + state advance). Every SAP action is
  delegated to the RFC libs and workbench skills.

## Limitations

The source backup is an audit/re-create copy, not a rollback (a transported
deletion is undone by re-creating + re-transporting); dependency cycles
surface as where-used SKIPs — re-run `plan` after handling the blocker;
message classes and unmapped types are `VIA: MANUAL`; the end-to-end live
retirement smoke pass (throwaway objects → flag → sign off → decommission →
verify) is still pending on a system with co-located RFC + GUI. Part of the
sap-migrate plugin (`/sap-cc-*` campaign pipeline).
