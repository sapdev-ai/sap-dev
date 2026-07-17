# sap-cc-inventory

**Build the custom-code inventory a migration campaign starts from.**
First SAP-touching step of the sap-migrate pipeline (inventory → usage →
decommission → analyze → triage → remediate, orchestrated by
`/sap-cc-campaign`). It enumerates every in-scope custom (Z/Y /
customer-namespace) repository object on the campaign's **SOURCE** system,
writes the campaign's `inventory.tsv`, and seeds the `state.tsv` ledger with
one `INVENTORIED` row per object — never touching objects further along the
pipeline, so it is safe to re-run as new custom code appears.

```
/sap-cc-inventory --campaign <id>
/sap-cc-inventory --campaign <id> --packages ZHK*,ZFI* --types PROG,CLAS
/sap-cc-inventory --campaign <id> --namespace Z,Y --exclude ZLEGACY_*,ZTEST_*
/sap-cc-inventory --campaign <id> --source-mode GUI --tadir-file <se16n export>
```

Scope defaults to the migration brief's `in_scope_packages`; override with
`--namespace` / `--packages` / `--types` / `--exclude`. Run after
`/sap-cc-campaign init`, before `/sap-cc-usage`.

## What it reads (pure read-only)

`RFC_READ_TABLE` on `TADIR` (`OBJECT`, `OBJ_NAME`, `DEVCLASS`, `AUTHOR`,
filtered `PGMID='R3TR'`) and `TRDIR` (`SUBC`, for program sub-type). No SAP
GUI, no writes, no TR — it writes only to the campaign workspace on disk. The
connection resolves via the campaign's `source_profile` (or `--source`),
falling back to the pinned `/sap-login` connection. `REPOSRC` is never touched.

When RFC to the source is blocked, `--source-mode GUI` ingests `/sap-se16n`
exports of TADIR (+ optionally TRDIR) instead — identical output files and
exit codes, no NCo required. The parser maps columns by technical field name,
so export column order does not matter.

## Outputs and exit codes

- `{CAMPAIGN_DIR}\inventory.tsv` — one row per in-scope object (this skill
  owns the file).
- `{CAMPAIGN_DIR}\state.tsv` — one `INVENTORIED` row per newly discovered
  object; existing rows untouched.

| Exit | Meaning |
|---|---|
| `0` | `STATUS: OK` — inventory written, ledger upserted. |
| `1` | `STATUS: EMPTY` — no in-scope objects; re-check the scope flags. |
| `2` | `STATUS: ERROR` — bad workspace / profile / RFC failure; nothing written (a previous good inventory is never clobbered). |
| `3` | `STATUS: PARTIAL` — some namespace/package slices failed; the files ARE written but **incomplete**. |

**A PARTIAL inventory must never silently become the campaign scope.** On exit
`3` the pipeline stops: fix the failing slices and re-run until `STATUS: OK`,
or get the operator's explicit approval for the reduced scope — otherwise
every object in a failed slice would silently fall out of the campaign.

## Prerequisites

- A campaign workspace (`/sap-cc-campaign init` first).
- RFC mode: SAP NCo 3.1 (32-bit, .NET 4.0) in GAC + a saved `source_profile`
  (or a pinned `/sap-login` connection).
- GUI mode: only an active SAP GUI session for the `/sap-se16n` export.

## Key reference files

- `references/sap_cc_inventory.ps1` — the enumerator: RFC mode reads
  TADIR/TRDIR; GUI mode (`-SourceMode GUI`) ingests the SE16N exports. Both
  write `inventory.tsv`, upsert `state.tsv`, and emit parseable `INVENTORY:` /
  `TYPE:` / `STATUS:` lines.

## Limitations

R3TR top-level objects only (function modules appear via their FUGR, matching
the ATC analysis unit); enrichment is partial in v1 (`sub_type` for programs
on the namespace path only; `app_component` / dates left blank); no pruning of
source-side deletions on re-run; very large estates may want package-batched
runs. Part of the sap-migrate plugin (`/sap-cc-*` campaign pipeline).
