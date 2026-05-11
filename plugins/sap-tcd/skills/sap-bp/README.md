# sap-bp — SAP Business Partner Maintenance Skill

Manages SAP Business Partners via the BP transaction (Create, Change,
Display) using SAP GUI Scripting.

## Prerequisites

- SAP GUI for Windows installed (7.x or later)
- SAP GUI Scripting enabled on both client and server
- Windows OS (VBScript execution via cscript)

## What It Does

1. **Login** — Opens a SAP GUI connection and logs in (auto or manual)
2. **Check** — Uses BP Open Partner to determine if a BP already exists
3. **Create** — Creates a new Business Partner (Organization) with specified role and fields
4. **Update** — Changes fields on an existing Business Partner

## VBS Templates

| File | Action | Tokens |
|---|---|---|
| `sap_bp_login.vbs` | Login | `%%SAP_LOGON_DESCRIPTION%%`, `%%SAP_CLIENT%%`, `%%SAP_USER%%`, `%%SAP_PASSWORD%%`, `%%SAP_LANGUAGE%%` |
| `sap_bp_check.vbs` | Check existence | `%%BP_NUMBER%%` |
| `sap_bp_create.vbs` | Create Organization | `%%BP_NUMBER%%`, `%%BP_ROLE%%`, `%%BP_GROUPING%%`, `%%DEFINITION_FILE%%` |
| `sap_bp_update.vbs` | Update partner | `%%BP_NUMBER%%`, `%%DEFINITION_FILE%%` |

## Field Definition File Format

Tab-separated file with one field per line:

```
SECTION	FIELD_NAME	VALUE
```

- `TAB_01`–`TAB_14` sections: tab panel fields in General Data view (Address, Identification, etc.)

Example:
```
TAB_01	BUT000-NAME_ORG1	Test Company Ltd
TAB_01	ADDR1_DATA-STREET	123 Main Street
TAB_01	ADDR1_DATA-CITY1	Beijing
TAB_01	ADDR1_DATA-COUNTRY	CN
TAB_01	SZA1_D0100-SMTP_ADDR	info@test.com
```

## Important Behavior Notes

- **Role change popup:** Setting a non-default role (`BP_ROLE` other than empty or
  `000000`) on the Create screen triggers a popup *"Change to another BP role in
  create mode"*. The create script handles this by pressing the popup's **Create**
  button, which refreshes the screen with editable fields for the chosen role.
- **Grouping must match role:** The grouping must be configured for the chosen role's
  account group. A mismatch produces an error like *"Grouping has not been assigned
  to any customer accounts group"*.
- **Language key:** Some roles (e.g., `FLCU01` Customer) require the Language field
  (`ADDR1_DATA-LANGU`) in the definition file.

## Component IDs

Recorded from SAP GUI 7.60 on S/4HANA 1909 (S4D system).

### BP Transaction Architecture

Unlike MM01/MM02/MM03, the BP transaction is a **single unified transaction** for
Create, Change, and Display. Navigation is via toolbar buttons:

| Button | Action | Shortcut |
|---|---|---|
| btn[5] | Create Person | F5 |
| btn[29] | Create Organization | Ctrl+F5 |
| btn[41] | Create Group | Ctrl+Shift+F5 |
| btn[17] | Open BP | Shift+F5 |
| btn[6] | Switch Display/Change | F6 |
| btn[25] | General Data | Ctrl+F1 |
| btn[11] | Save | Ctrl+S |

### Header Fields

| Field | Type | Description |
|---|---|---|
| `BUS_JOEL_MAIN-CHANGE_NUMBER` | GuiCTextField | BP number (Display/Change — read only) |
| `BUS_JOEL_MAIN-CREATION_NUMBER` | GuiTextField | BP number (Create — optional external) |
| `BUS_JOEL_MAIN-PARTNER_ROLE` | GuiComboBox | BP Role |
| `BUS_JOEL_MAIN-CREATION_GROUP` | GuiComboBox | Grouping (Create only) |
| `BUS_JOEL_MAIN-OPEN_NUMBER` | GuiCTextField | BP number (Open popup) |

### Tab Panel IDs (General Data View)

| Tab ID | Tab Name |
|---|---|
| SCREEN_1100_TAB_01 | Address |
| SCREEN_1100_TAB_02 | Address Overview |
| SCREEN_1100_TAB_03 | Identification |
| SCREEN_1100_TAB_04 | Control |
| SCREEN_1100_TAB_05 | Payment Transactions |
| SCREEN_1100_TAB_06 | Status |
| SCREEN_1100_TAB_07 | Where-Used List |

### Address Tab Fields

| Field | Type | Description |
|---|---|---|
| `BUT000-NAME_ORG1` | GuiTextField | Organization name line 1 |
| `BUT000-NAME_ORG2` | GuiTextField | Organization name line 2 |
| `BUT000-NAME_ORG4` | GuiTextField | Organization name line 3 |
| `BUS000FLDS-TITLE_MEDI` | GuiComboBox | Title |
| `BUT000-TITLE_LET` | GuiTextField | Salutation |
| `BUS000FLDS-BU_SORT1_TXT` | GuiTextField | Search term 1 |
| `ADDR1_DATA-STREET` | GuiTextField | Street |
| `ADDR1_DATA-HOUSE_NUM1` | GuiTextField | House number |
| `ADDR1_DATA-POST_CODE1` | GuiTextField | Postal code |
| `ADDR1_DATA-CITY1` | GuiTextField | City |
| `ADDR1_DATA-COUNTRY` | GuiCTextField | Country key |
| `ADDR1_DATA-REGION` | GuiCTextField | Region |
| `ADDR1_DATA-LANGU` | GuiComboBox | Language |
| `SZA1_D0100-TEL_NUMBER` | GuiTextField | Phone |
| `SZA1_D0100-SMTP_ADDR` | GuiTextField | Email |
| `SZA1_D0100-MOB_NUMBER` | GuiTextField | Mobile |
