# sap-va01

SAP Sales Order maintenance skill using SAP GUI Scripting (VA01/VA02/VA03).

## What it does

- **VA01** — Create a new sales order with header fields, sales tab settings, and item lines
- **VA02** — Update an existing sales order (change header, sales fields, or items)
- **VA03** — Check if a sales order exists (used internally before update)
- **Login** — Use `/sap-login` skill first

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client and server side)
- Valid SAP user with VA01/VA02/VA03 authorization

## VBScript Templates

| File | Transaction | Tokens |
|---|---|---|
| `sap_va01_login.vbs` | — | `%%SAP_LOGON_DESCRIPTION%%`, `%%SAP_CLIENT%%`, `%%SAP_USER%%`, `%%SAP_PASSWORD%%`, `%%SAP_LANGUAGE%%` |
| `sap_va01_check.vbs` | VA03 | `%%ORDER_NUMBER%%` |
| `sap_va01_create.vbs` | VA01 | `%%ORDER_TYPE%%`, `%%SALES_ORG%%`, `%%DIST_CHANNEL%%`, `%%DIVISION%%`, `%%DEFINITION_FILE%%` |
| `sap_va01_update.vbs` | VA02 | `%%ORDER_NUMBER%%`, `%%DEFINITION_FILE%%` |

## Definition File Format

Tab-separated file with sections `HEADER`, `SALES`, and `ITEM_NN`:

```
# Header fields
HEADER	KUAGV-KUNNR	20000000
HEADER	VBKD-BSTKD	PO-REF-001
# Sales tab
SALES	RV45A-KETDAT	2026.04.15
SALES	VBKD-ZTERM	BX01
# Items
ITEM_01	RV45A-MABNR	500070
ITEM_01	RV45A-KWMENG	5
```

## Component IDs

Recorded from SAP GUI 7.60 on S/4HANA 1909 (system S4D).

### VA01 Initial Screen
- `VBAK-AUART` — Order Type
- `VBAK-VKORG` — Sales Organization
- `VBAK-VTWEG` — Distribution Channel
- `VBAK-SPART` — Division

### Header Subscreen (SAPMV45A:4021)
- `KUAGV-KUNNR` — Sold-To Party
- `KUWEV-KUNNR` — Ship-To Party
- `VBKD-BSTKD` — Customer Reference
- `VBKD-BSTDK` — Customer Reference Date
- `VBAK-NETWR` — Net Value (read-only)

### Tab Strip (TAXI_TABSTRIP_OVERVIEW)
| Tab | Name |
|---|---|
| `T\01` | Sales |
| `T\02` | Item Overview |
| `T\03` | Item detail |
| `T\04` | Ordering party |
| `T\05` | Procurement |
| `T\06` | Shipping |
| `T\07` | Configuration |
| `T\08` | Reason for rejection |

### Item Table (SAPMV45ATCTRL_U_ERF_AUFTRAG)
| Col | Field ID | Description |
|---|---|---|
| 0 | `VBAP-POSNR` | Item Number |
| 1 | `RV45A-MABNR` | Material |
| 2 | `RV45A-KWMENG` | Order Quantity |
| 3 | `KOMV-KBETR` | Condition Rate |
| 4 | `VBAP-ARKTX` | Item Description |
| 5 | `VBAP-WERKS` | Plant |
| 6 | `VBAP-VRKME` | Sales Unit |
| 11 | `VBAP-PSTYV` | Item Category |
| 16 | `VBAP-NETPR` | Net Price |
| 19 | `VBAP-NETWR` | Net Value |
