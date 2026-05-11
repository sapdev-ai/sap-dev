# SAP Dev Environment Status Skill

Read-only health check for the artefacts `/sap-dev-init` is responsible
for. Runs over RFC, completes in well under a second, and is safe to
auto-invoke as a pre-flight from any other sap-dev skill.

## What it checks

| Artefact | Catalog table | Healthy state |
|---|---|---|
| Transport request (`sap_dev_transport_request`) | `E070` | `MODIFIABLE` (TRSTATUS in D / L) |
| Development package (`sap_dev_package`) | `TDEVC` + `TADIR` | exists; `EMPTY` or `NON_EMPTY` |
| Function group (`sap_dev_function_group`) | `TLIBG` + `PROGDIR` for `SAPL<FG>` | `ACTIVE` |
| Wrapper FM `Z_GENERIC_RFC_WRAPPER_TBL` | `TFDIR` | exists |
| Wrapper structure `ZCMST_RFC_PARAM` | `DD02L AS4LOCAL='A'` | active |
| Wrapper table type `ZCMCT_RFC_PARAM` | `DD40L AS4LOCAL='A'` | active |
| Utility program `ZCMRUPDATE_ADDON_TABLE` | `PROGDIR STATE='A'` | active |

## Auto-Trigger Keywords

- `dev env status`, `is my dev env ok`, `is my dev environment healthy`
- `is the wrapper FM deployed`, `is sap-dev-init done`

## Usage

```text
/sap-dev-status
```

Prints a per-artefact line plus a summary. Returns exit code 0 (all
ok), 1 (gaps), or 2 (RFC failure).

## Composition

```text
/sap-dev-status      # → exit 1 with GAPS=N
/sap-dev-init        # → fix the gaps
/sap-dev-status      # → exit 0 (verify)
```

`/sap-dev-clean` calls this skill internally as its pre-flight to
list what actually exists before deleting anything.

## Prerequisites

- SAP NCo 3.1 (32-bit, .NET 4.0) installed in the GAC
- SAP RFC connection configured in `sap-dev-core/settings.json`

## Limitations

- Hardcoded artefact list — customer forks of `/sap-dev-init` that add
  artefacts must extend the shared `sap_dev_artefacts.ps1` checker.
- Package emptiness counts direct `TADIR` children only (no
  sub-package recursion).

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-09

## License

GPL-3.0 License - See LICENSE file in repository root.
