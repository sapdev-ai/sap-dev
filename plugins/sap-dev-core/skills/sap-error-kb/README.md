# SAP frequently_errors Knowledge-Base Curator Skill

Curates the team **frequently_errors** knowledge base — the per-object store
of recurring FM / class-method / codegen traps + remedies that
`/sap-gen-abap` reads to steer generation away from known mistakes. The
deploy skills (`/sap-se38`, `/sap-se37`, `/sap-se24`) and `/sap-atc`
auto-record new FM/METHOD errors here as `CANDIDATE` rows; this skill lets a
human review, fill in the remedy, and promote them. Pure-local — no SAP
connection required.

## Skill Overview

Four operations:

1. **`list`** (default) — show `CANDIDATE` rows awaiting review across all
   per-object files; `--all` also shows `CONFIRMED` rows
2. **`promote <OBJECT> <KEY>`** — mark a row `CONFIRMED` so it starts
   influencing generation
3. **`mute <OBJECT> <KEY>`** — suppress a row (seed or candidate) so it is
   never injected
4. **`show <OBJECT>`** — print one per-object TSV for inspection / manual
   editing (plain TAB-separated, UTF-8 no BOM)

`<OBJECT>` is the FM or class name; `<KEY>` is the 4-part merge key shown by
`list`: `OBJECT_TYPE|OBJECT_NAME|CONTEXT|ERROR_CLASS`.

The store lives at `{custom_url}\frequently_errors\` (per-object files) plus
the hand-authored override `{custom_url}\frequently_errors.tsv`. The full
loop contract (tiers, precedence, schema, statuses) is in
`sap-dev-core/shared/rules/frequently_errors.md`.

## Auto-Trigger Keywords

- `error kb`, `review error candidates`, `curate frequently errors`
- `promote <fm> error`, `mute <fm> error`
- "show the known traps for BAPI_PO_CREATE1"

## Usage

```text
/sap-error-kb list
/sap-error-kb list --all
/sap-error-kb promote BAPI_PO_CREATE1 "FM|BAPI_PO_CREATE1|CALL|MISSING_COMMIT"
/sap-error-kb mute    BAPI_PO_CREATE1 "FM|BAPI_PO_CREATE1|CALL|MISSING_COMMIT"
/sap-error-kb show    BAPI_PO_CREATE1
```

Conversational forms:

- "List the error-KB candidates awaiting review"
- "Promote that BAPI_PO_CREATE1 trap so generation avoids it"
- "Show the frequently_errors file for CL_SALV_TABLE"

**Before promoting**, make sure the row has a `CORRECT_PATTERN` — the
load-bearing remedy. Auto-recorded candidates typically arrive without one;
open the file (`show`), add the remedy, THEN promote. Promoting without a
remedy is allowed but teaches the generator nothing.

## Prerequisites

- None SAP-side — pure-local; only reads/writes TSV files under
  `{custom_url}` (never MEMORY files, never the SAP system)
- To share the knowledge base across a team, point `custom_url` at a shared
  drive or a checked-out git repo

## Directory Structure

```
sap-error-kb/
├── SKILL.md
└── README.md
```

The engine it drives is shared:
`sap-dev-core/shared/scripts/sap_error_hints.ps1` (+ `sap_error_hints_lib.ps1`),
with the TIER-3 seed at `sap-dev-core/shared/tables/frequently_errors.tsv`.

## Limitations

- Only `CONFIRMED` rows are injected into generation by default
  (`frequently_errors_inject_status`); set it to `ALL` to also inject
  un-curated candidates (faster feedback, higher noise).
- The seed table is a read-only baseline — suppress a noisy seed row with
  `mute` rather than editing the shipped file.
- Row edits beyond status changes (adding `CORRECT_PATTERN`, fixing
  `RELEASE`) are manual file edits via `show` — keep real TABs and UTF-8
  (no BOM).

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
