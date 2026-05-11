# SAP Dev Init Skill

Initialises the SAP development environment after plugin installation. Ensures
a transport request, package, and function group exist in SAP, then deploys
the `ZCMRUPDATE_ADDON_TABLE` utility program. Mode-aware: respects
`sap_dev_mode` (GUI / RFC / BDC) and selects the preferred skill variant for
each step, falling back to the next mode in the chain when no implementation
exists for the preferred mode.

Run this **once** after installing the sap-dev-core plugin.

## Skill Overview

1. Read `sap_dev_mode` from settings — pick the preferred implementation
   chain (GUI → RFC → BDC, or RFC → BDC → GUI, or BDC → RFC → GUI)
2. Delegate to `/sap-transport-request` to create or validate a modifiable TR
   and persist it to `sap_dev_transport_request`
3. Delegate to `/sap-se21` (or RFC variant) to create or validate a development
   package and persist it to `sap_dev_package`
4. Delegate to `/sap-function-group` (mode-aware: RFC fast-path, SE37 GUI fallback) to
   create or validate a function group and persist it to `sap_dev_function_group`
5. Delegate to `/sap-se38` to deploy the `ZCMRUPDATE_ADDON_TABLE.abap` utility
   program (used by `/sap-update-addon` as a fallback for tables without
   maintenance views)

## Auto-Trigger Keywords

- `init`, `setup`, `bootstrap`
- `sap dev init`, `init sap dev`
- `set up sap dev environment`

## Usage

```text
/sap-dev-init
```

No arguments — everything is read from `sap-dev-core/settings.json`.

Conversational forms:

- "Initialise the SAP dev environment"
- "Bootstrap sap-dev-core"
- "Set up sap-dev for the first time"

## Prerequisites

- SAP GUI installed (for GUI mode)
- SAP NCo 3.1 in GAC (for RFC mode)
- SAP connection parameters configured in `sap-dev-core/settings.json`
  (`sap_application_server`, `sap_system_number`, `sap_client`, `sap_user`,
  `sap_password`)
- Authorisation to create packages, function groups, and programs in the
  target client

## What gets persisted to settings.json

- `sap_dev_transport_request` — the new TR
- `sap_dev_package` — the new or validated package
- `sap_dev_function_group` — the new or validated function group

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
