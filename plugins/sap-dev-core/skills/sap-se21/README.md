# SAP Package (SE21) Skill

Creates or checks SAP development packages via transaction SE21 using SAP GUI
Scripting. First verifies package existence using `RFC_READ_TABLE` on `TDEVC`
to avoid an unnecessary GUI round-trip; if the package doesn't exist, drives
SE21 to create it.

Transport request resolution is delegated to `/sap-transport-request` —
this skill never prompts the user for a TR or calls `/sap-se01` directly.

## Skill Overview

1. Parse: package name + optional description
2. Pre-check via `RFC_READ_TABLE` on `TDEVC`
3. If exists — report and exit
4. If not — call `/sap-transport-request` to obtain a TR
5. Drive SE21 GUI to create the package: enter name → enter attributes
   (description, software component, transport layer) → save → handle TR
   popup with the resolved TR

## Auto-Trigger Keywords

- `create package`, `new package`, `check package`
- `does package X exist`, `make package X`
- `se21 X`

## Usage

```text
/sap-se21 ZHK_MM
/sap-se21 ZHK_MM "MM module developments"
```

Conversational forms:

- "Does package ZHK_MM exist?"
- "Create package ZHK_MM with description 'MM module developments'"
- "Make sure ZHK_MM exists; create it if not"

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- SAP NCo 3.1 in the GAC (for the existence pre-check)
- Authorisation S_DEVELOP for object class DEVC
- `way_to_get_transport_request` policy configured per `tr_resolution.md`

## Limitations

- Customer namespace only (Z*/Y*)
- Default attributes only (no custom transport layer / software component
  selection beyond defaults). Edit the VBS template if your environment needs
  non-default values.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
