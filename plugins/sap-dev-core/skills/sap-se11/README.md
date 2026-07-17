# SAP SE11 ABAP Dictionary Skill

Create and update ABAP Dictionary objects in SAP via SE11 using SAP GUI Scripting.

## Skill Overview

This skill automates the full ABAP Dictionary object lifecycle via SE11:

- **All 9 DDIC Object Types**: Database table, View, Data element, Structure, Table type, Type group, Domain, Search help, Lock object
- **Create or Update**: Automatically detects whether the object exists and runs the appropriate flow
- **Tab-Delimited Definition Files**: Structured input for field lists, properties, and parameters
- **Full Lifecycle**: Create → define fields/properties → technical settings → save → activate
- **Login Required**: Use `/sap-login` first to establish SAP GUI session
- **Centralized Login**: Connection parameters stored in sap-dev-core settings.json
- **Transport Handling**: TR resolved via `/sap-transport-request` (per `way_to_get_transport_request`); the VBS fills the resolved TR into the KO008 popup and aborts loud when a TR is required but missing — it never silently presses Local Object
- **Enhancement Category**: Automatically handles enhancement category popup on first activation

## Auto-Trigger Keywords

This skill activates when discussing:

### SE11 & ABAP Dictionary
- SE11, ABAP Dictionary, Data Dictionary, DDIC
- dictionary object, dictionary maintenance
- create table, create domain, create data element
- create structure, create table type, create view
- create search help, create lock object, create type group

### Database Tables
- database table, transparent table, table fields
- delivery class, data class, size category
- technical settings, table maintenance
- field catalog, key fields, table definition

### Domains & Data Elements
- domain, data element, data type
- fixed values, value range, value table
- field labels, short text, medium text, long text, heading

### Structures & Table Types
- structure, flat structure, deep structure, components
- table type, line type, access mode
- sorted table, hashed table, standard table

### Views
- database view, projection view, maintenance view, help view
- join conditions, view fields, base tables

### Search Helps & Lock Objects
- search help, elementary search help, collective search help
- selection method, dialog type, search help parameters
- lock object, enqueue object, lock mode, lock arguments

### Type Groups
- type group, type pool
- TYPE-POOL statement, global types

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, open connection, login to SAP
- sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-se11/
├── SKILL.md                              # Main skill file (step-by-step workflow)
├── README.md                             # This file (keywords for discoverability)
└── references/
    ├── sap_se11_check.vbs                # VBScript: check if DDIC object exists (universal)
    ├── sap_se11_table_create.vbs         # VBScript: create database table
    ├── sap_se11_table_update.vbs         # VBScript: update database table
    ├── sap_se11_domain_create.vbs        # VBScript: create domain
    ├── sap_se11_domain_update.vbs        # VBScript: update domain
    ├── sap_se11_dataelement_create.vbs   # VBScript: create data element
    ├── sap_se11_dataelement_update.vbs   # VBScript: update data element
    ├── sap_se11_structure_create.vbs     # VBScript: create structure
    ├── sap_se11_structure_update.vbs     # VBScript: update structure
    ├── sap_se11_tabletype_create.vbs     # VBScript: create table type
    ├── sap_se11_tabletype_update.vbs     # VBScript: update table type
    ├── sap_se11_view_create.vbs          # VBScript: create view
    ├── sap_se11_view_update.vbs          # VBScript: update view
    ├── sap_se11_searchhelp_create.vbs    # VBScript: create search help
    ├── sap_se11_searchhelp_update.vbs    # VBScript: update search help
    ├── sap_se11_lockobject_create.vbs    # VBScript: create lock object
    ├── sap_se11_lockobject_update.vbs    # VBScript: update lock object
    ├── sap_se11_typegroup_create.vbs     # VBScript: create type group
    ├── sap_se11_typegroup_update.vbs     # VBScript: update type group
    ├── sap_se11_delete.vbs               # VBScript: delete a DDIC object (Shift+F2 from the initial screen)
    ├── sap_se11_change_package.vbs       # VBScript: change the object directory entry (package)
    ├── sap_se11_set_enh_category.vbs     # VBScript: set the table enhancement category
    ├── sap_se11_check_domains.ps1        # PowerShell: RFC batch-check that referenced domains exist (DD01L)
    ├── sap_se11_check_dataelements.ps1   # PowerShell: RFC batch-check that referenced data elements exist (DD04L)
    ├── sap_se11_normalize_def.ps1        # PowerShell: sanity-check / auto-repair a .def definition file
    ├── sap_se11_verify_active.ps1        # PowerShell: RFC post-deploy verification (object ACTIVE)
    └── *.screens.json                    # Golden-screen baselines (one per driving VBS)
```

Login is centralized in `/sap-login` (shared `sap_login.vbs`); this skill attaches to
the existing session.

## Usage

Invoke with an object type, name, and definition:

- "Create table ZTMYDATA in SAP with these fields: ..."
- "Add a domain ZDOM_STATUS with fixed values A/I/D"
- "Create data element ZDE_STATUS using domain ZDOM_STATUS"
- "Define structure ZSMYSTRUC with components BUKRS, WERKS, CUSTOM1"
- "Create a database view ZVITEMS joining ZTABLE1 and ZTABLE2"
- "Add search help ZSH_PLANT for plant lookup"
- "Create lock object EZMYLOCK for table ZTMYDATA"
- "Create type group ZTYP with custom types"
- "Update table ZTMYDATA — add field ZSTATUS"

## Prerequisites

- SAP GUI for Windows installed
- SAP GUI Scripting enabled (client + server side)
- SAP user with authorization for SE11 and DDIC activation

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-03-31

## License

GPL-3.0 License - See LICENSE file in repository root.
