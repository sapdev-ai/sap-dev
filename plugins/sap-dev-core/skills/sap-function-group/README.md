# SAP Function Group Skill

Full lifecycle for SAP function groups: check existence, create,
re-activate, query PROGDIR state, and delete. Mode-aware — picks the
RFC fast-path when possible (`RFC_READ_TABLE`,
`RS_FUNCTION_POOL_INSERT`), falls through to GUI scripting (SE37
menus + SE38 delete) for operations RFC can't cover.

This skill **replaces the now-removed `sap-se37-fugr`**. Call
`/sap-function-group` for every FG operation; the dispatcher inside
picks the right transport per `userConfig.sap_dev_mode`.

## Skill Overview

| Operation | Default transport | When to use |
|---|---|---|
| Check + create | RFC (single round-trip via `RS_FUNCTION_POOL_INSERT`) | Idempotent setup; default flow |
| Activate-only | GUI (SE37 *Change Group* + Ctrl+F3) | After single-FM updates leave `SAPL<FG>` inactive |
| Check PROGDIR state | RFC (`PROGDIR` for `SAPL<FG>`) | Diagnose `Object REPS SAPLZxxx is inactive` errors |
| Delete | GUI — delegates to `/sap-se38` with `PROGRAM_NAME = SAPL<FG>` | One-shot removal of a whole FG and its FMs |

## Auto-Trigger Keywords

- `function group`, `fugr`, `create function group`, `check function group`
- `does function group X exist`
- `(re-)activate function group <FG>`
- `check state of function group <FG>`
- `delete function group <FG>`, `drop function group <FG>`, `remove FUGR <FG>`

## Usage

```text
# Create / ensure exists (RFC fast-path)
/sap-function-group ZHKFG001
/sap-function-group ZHKFG001 "Demo function group"

# Re-activate after FM-level change (GUI)
/sap-function-group ZHKFG001 --activate-only

# Inspect PROGDIR state (RFC)
/sap-function-group ZHKFG001 --check-state

# Delete (GUI, delegates to /sap-se38)
/sap-function-group ZHKFG001 --delete
```

Conversational forms:

- "Does function group ZHKFG001 exist?"
- "Create function group ZHKFG001 with short text 'Demo'"
- "Reactivate function group ZHKFG001"
- "Delete function group ZHKFG001"

## Prerequisites

- **RFC paths** (create / check-state): SAP NCo 3.1 (32-bit, .NET 4.0)
  in the GAC; SAP connection configured in
  `sap-dev-core/settings.json`.
- **GUI paths** (activate / delete): active SAP GUI session — run
  `/sap-login` first.
- Authorisation `S_DEVELOP` for object class `FUGR`.
- For transportable FGs: `sap_dev_package` and
  `sap_dev_transport_request` set in `sap-dev-core/settings.json`, or a
  resolved TR via `/sap-transport-request`.

## Limitations

- Customer namespace only (Z*/Y*).
- Skeleton creation only — no function modules added; use `/sap-se37`
  for individual FMs.
- Long text not supported.
- Deletion is irreversible — the skill confirms with the operator
  (showing the dependent-FM list) before delegating to `/sap-se38`.

## Version

- Skill Version: 2.0.0 (merged sap-se37-fugr into this skill)
- Last Updated: 2026-05-09

## License

GPL-3.0 License - See LICENSE file in repository root.
