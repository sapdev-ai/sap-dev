# SAP SNRO Number Range Object Skill

Create, maintain, and manage SAP Number Range Objects (NRO) and their
intervals via SNRO using SAP GUI Scripting.

## Skill Overview

Number Range Objects are crucial for generating unique identifiers for SAP
master data and document numbers (material numbers, order numbers, custom
Z document IDs, etc.). This skill automates the full SNRO lifecycle:

- **Existence check** via SNRO Display
- **Create** new NRO with short text, long text, domain (with length suffix), warning %
- **Update** header attributes (short/long text, domain length, warning %)
- **Maintain intervals** (sub-objects: from-number / to-number / external flag)
- **Transport handling**: explicit TR via `/sap-transport-request`, `$TMP` local object,
  or new transport (3-way pattern). Intervals (table NRIV) are client-dependent and
  not transportable.
- **Login required**: use `/sap-login` first to establish the SAP GUI session.

## Auto-Trigger Keywords

This skill activates when discussing:

### SNRO & Number Range Objects
- SNRO, SNUM, number range, number range object, NRO
- number range maintenance, number range interval
- TNRO, TNROT, NRIV, INOB
- create number range, maintain number range, change number range
- next free number, current number, number length
- internal numbering, external numbering, internal/external number assignment
- to-year flag, fiscal year intervals, number range groups
- buffering, NUMBER_GET_NEXT, INTERVAL_LIST

### Document & Master Data Numbering
- material number range, document number range, customer number range
- vendor number range, sales order number range, purchase order number range
- Z-document number, custom ID generator, sequence object
- unique identifier, sequence generator, primary-key allocation

### SAP GUI Scripting
- SAP GUI Scripting, VBScript, cscript
- SAP Logon, sendVKey, findById, Scripting Recorder

## Directory Structure

```
sap-snro/
├── SKILL.md                       # Main skill file (step-by-step workflow)
├── README.md                      # This file (keywords for discoverability)
└── references/
    ├── sap_snro_check.vbs         # VBScript: check if NRO exists
    ├── sap_snro_create.vbs        # VBScript: create new NRO (header attributes)
    ├── sap_snro_update.vbs        # VBScript: update existing NRO header
    └── sap_snro_intervals.vbs     # VBScript: maintain number range intervals
```

## Usage

Invoke with an NRO name and optional attributes / intervals:

- "Create number range object ZMM_0004 'MM SEQ004' domain NUMC15 warn 10%"
- "Add a number range object ZHK_DOC for my custom document IDs (CHAR10)"
- "Change warning percentage of ZMM_0004 to 5"
- "Maintain interval 01 from 0000000001 to 0099999999 on ZMM_0004"
- "Set up internal interval 02 0100000000–0199999999 for ZMM_0004"
