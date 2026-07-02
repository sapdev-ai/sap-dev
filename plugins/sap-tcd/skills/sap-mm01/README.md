# sap-mm01 — SAP Material Master Maintenance Skill

Manages SAP material masters via MM01 (Create), MM02 (Change), and MM03
(Display) using SAP GUI Scripting.

## Prerequisites

- SAP GUI for Windows installed (7.x or later)
- SAP GUI Scripting enabled on both client and server
- Windows OS (VBScript execution via cscript)

## What It Does

1. **Login** — Use the `/sap-login` skill first; this skill attaches to the active session
2. **Check** — Uses MM03 to determine if a material already exists
3. **Create** — Uses MM01 to create a new material with specified views and fields
4. **Update** — Uses MM02 to change fields on an existing material

## VBS Templates

| File | Transaction | Tokens |
|---|---|---|
| `sap_mm01_check.vbs` | MM03 | `%%MATERIAL%%` |
| `sap_mm01_create.vbs` | MM01 | `%%MATERIAL%%`, `%%INDUSTRY%%`, `%%MATERIAL_TYPE%%`, `%%DEFINITION_FILE%%` |
| `sap_mm01_update.vbs` | MM02 | `%%MATERIAL%%`, `%%DEFINITION_FILE%%` |

On a successful save the create/update scripts echo a machine-readable
`MATERIAL: <number>` line before the final `SUCCESS:` line.

## Field Definition File Format

Tab-separated file with one field per line:

```
SECTION	FIELD_NAME	VALUE
```

- `ORG` section: organizational level fields (Plant, Storage Location, etc.)
- `SP01`–`SP35` sections: tab panel fields (Basic Data 1, MRP 1, etc.)

Example:
```
ORG	RMMG1-WERKS	1000
SP01	MAKT-MAKTX	My Material
SP01	MARA-MEINS	PC
SP13	MARC-DISMM	PD
```

## Component IDs

Recorded from SAP GUI 7.60 on S/4HANA 1909 (S4D system).

### Tab Panel IDs

| Tab ID | View Name |
|---|---|
| SP01 | Basic Data 1 |
| SP02 | Basic Data 2 |
| SP04 | Sales: Sales Org. 1 |
| SP05 | Sales: Sales Org. 2 |
| SP06 | Sales: General/Plant |
| SP10 | Purchasing |
| SP13 | MRP 1 |
| SP14 | MRP 2 |
| SP15 | MRP 3 |
| SP16 | MRP 4 |
| SP20 | Work Scheduling |
| SP21 | Plant Data / Storage 1 |
| SP22 | Plant Data / Storage 2 |
| SP26 | Quality Management |
| SP27 | Accounting 1 |
| SP28 | Accounting 2 |
| SP29 | Costing 1 |
| SP30 | Costing 2 |
