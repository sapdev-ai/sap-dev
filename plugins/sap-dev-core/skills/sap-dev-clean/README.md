# SAP Dev Environment Clean Skill

Conservative cleanup of the artefacts `/sap-dev-init` created. Walks
reverse dependency order, asks for confirmation per artefact, and
skips anything the operator has extended (function group with extra
FMs, package with extra Z* objects) unless `--force` is set.

Deleted artefacts are unassigned from their transport request(s)
(`/sap-se01 remove-objects`) so their name-locks are freed; a request
that ends up empty is then deleted even on the default path, while a
request still holding other work is always kept. `--reset` (or legacy
`--force`) force-deletes the dev TR after showing its E071 contents.
Settings.json keys are preserved unless `--settings` is passed
(`--reset` implies it).

## Skill Overview

1. Pre-flight via `/sap-dev-status` to learn what's actually there.
2. Walk reverse dependency order:
   1. Wrapper FM `Z_GENERIC_RFC_WRAPPER_TBL`
   2. Table type `ZCMCT_RFC_PARAM`, then structure `ZCMST_RFC_PARAM`,
      then data element `ZCMDE_RFCVAL`, then domain `ZCMD_RFCVAL`
   3. Utility program `ZCMRUPDATE_ADDON_TABLE`
   4. Function group (skip if it has extra FMs)
   5. Package (skip if it has extra TADIR children)
   6. Transport request — dev-init entries cleared; deleted if it ends
      up empty, kept if other work remains (force-deleted under
      `--reset`/`--force` after confirmation)
3. Post-flight via `/sap-dev-status` and report a before/after diff.
4. Optionally clear `sap_dev_*` settings keys.

## Auto-Trigger Keywords

- `clean dev env`, `clean my sap-dev environment`
- `remove sap-dev-init artefacts`, `wipe wrapper FM`

## Usage

```text
# Default — conservative, settings preserved
/sap-dev-clean

# Also clear settings keys so next init asks fresh names
/sap-dev-clean --settings

# Force: skip the "extras present" guards (read the dry-run first!)
/sap-dev-clean --dry-run
/sap-dev-clean --force --settings

# Full truly-clean reset (implies --force + --settings, deletes the dev TR)
/sap-dev-clean --reset

# Reset (clean then init) — conservative:
/sap-dev-clean
/sap-dev-init

# Reset (clean then init) — full:
/sap-dev-clean --reset
/sap-dev-init
```

There is intentionally no `/sap-dev-reset` skill. The chain
`/sap-dev-clean ; /sap-dev-init` IS the reset, and it has the same
failure surface as a hypothetical merged skill, with the bonus that
"clean without re-init" is a trivial one-step.

## Prerequisites

- SAP NCo 3.1 (32-bit, .NET 4.0) installed in the GAC
- Active SAP GUI session (clean delegates to GUI-driven delete skills)
- Modifiable transport request resolved by `/sap-transport-request`
  (only when transportable artefacts are involved)

## Limitations

- An emptied dev TR is deleted automatically on the default path;
  deleting a NON-empty dev TR requires `--reset` (or legacy `--force`)
  and the operator must read the E071 child list and confirm — a TR
  holding non-dev-init objects is refused.
- Conservative guards stop at the first user object inside an
  otherwise-clean container — use `--force` to override after reading
  the dry-run.
- Delegated delete paths inherit their owners' caveats (see SE11 /
  SE38 / SE37 / sap-function-group SKILL.md troubleshooting).

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-09

## License

GPL-3.0 License - See LICENSE file in repository root.
