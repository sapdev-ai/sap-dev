# sap-file-transfer

Transfers files between the local PC and the SAP application server, and lists
app-server directories.

| Mode | Backend | Direction |
|---|---|---|
| `upload` | CG3Z (GUI scripting) | PC → application server |
| `download` | CG3Y (GUI scripting) | application server → PC |
| `list` / `exists` | RFC `EPS2_GET_DIRECTORY_LISTING` (legacy `EPS_` fallback) | read-only |

Text (`ASC`) or binary (`BIN`) transfer, explicit `--overwrite`, popup-guarded
(overwrite Query `SAPLSPO1/300`, cannot-open-file Information popup
`SAPMSDYP/10`), locale-independent outcome detection (control IDs +
`MessageType` only). No AL11 scraping, no transport request.

Provenance: scaffolded by `/sap-gui-skill-scaffold` from live `/sap-gui-probe`
runs on S/4HANA 1909 (S4D, 2026-07-09) covering: fresh upload, upload onto an
existing target (decline / confirm-Yes / overwrite-checkbox paths), fresh
download, download onto an existing local file, download of a missing source.
Hand-hardened afterwards: explicit `MessageType=S` success contract, wnd[2]
popup discrimination, SAP GUI Security precheck/sidecar wiring, RFC list mode,
target-identity guard.

Typical loop it closes: `upload` test input → `/sap-run-report` → `list` /
`exists` output → `download` → `/sap-compare`.
