# SAP Call BDC Skill

SAP RFC integration for executing BDC sessions via SHDB recordings.

## Skill Overview

This skill automates BDC (Batch Data Communication) execution in SAP:

- **SHDB recordings**: Record in SHDB, download, place in `bdc/` folder, run skill
- **Command-style invocation**: `/sap-call-bdc MM01` — just pass the transaction code
- **Centralized credentials**: Reads connection parameters from sap-dev-core settings.json
- **32-bit PowerShell execution**: Runs via `SysWOW64\WindowsPowerShell\v1.0\powershell.exe` for SAP NCo 3.1 in the 32-bit GAC
- **RFC connection**: Connects via SAP NCo 3.1 (sapnco.dll / sapnco_utils.dll)
- **Full BDCMSGCOLL output**: All 13 message fields written to tab-delimited result file
- **CTU parameters**: Configurable display mode (A/E/N/P) and update mode (A/S/L)

## Auto-Trigger Keywords

This skill activates when discussing:

### BDC & Transactions
- BDC, Batch Data Communication, BDC recording
- SHDB, transaction recorder, BDC recording download
- ABAP4_CALL_TRANSACTION, call transaction
- BDCDATA, BDC table, BDC file
- BDCMSGCOLL, BDC messages
- transaction code, t-code, update mode, display mode

### RFC
- RFC, Remote Function Call, SAP RFC
- SAP NCo 3.1, sapnco.dll, sapnco_utils.dll

## Directory Structure

```
sap-call-bdc/
├── SKILL.md                           # Main skill file
├── README.md                          # This file
├── bdc/                               # SHDB recording files
│   ├── bdc_recording_MM01.txt         # Example: MM01 Create Material
│   └── bdc_recording_BP.txt           # Example: BP Business Partner
└── references/
    └── sap_bdc_transaction.ps1        # PowerShell template (used by skill)
```

## Usage

Invoke with a transaction code:

- `/sap-call-bdc MM01` — runs BDC for MM01 (Create Material)
- `/sap-call-bdc BP` — runs BDC for BP (Business Partner)
- `/sap-call-bdc MM01 E S` — display errors, synchronous update

Or ask conversationally:

- "Execute the MM01 BDC recording"
- "Run BDC for BP transaction"

## Creating BDC Files

1. Run transaction **SHDB** in SAP GUI
2. Click **New Recording**, enter a name and the transaction code
3. Perform the transaction steps
4. Go back to SHDB, select the recording, click **Download**
5. Save as `<TCODE>_<description>.txt` in the `bdc/` folder

## Prerequisites

- SAP NCo 3.1 (32-bit, .NET 4.0) installed in GAC
- Windows with 32-bit PowerShell at `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`
- SAP user with S_RFC and S_TCODE authorizations
- Login Required: Use `/sap-login` first
- Centralized Login: Connection parameters stored in sap-dev-core settings.json

## Version

- Skill Version: 2.0.0
- Last Updated: 2026-04-19

## License

GPL-3.0 License - See LICENSE file in repository root.
