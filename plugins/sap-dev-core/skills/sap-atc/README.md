# SAP ATC / Code Inspector Quality Gate Skill

Runs SAP Code Inspector (SCI) / ATC against an SAP repository object via SAP
GUI Scripting and writes findings to a TSV. Acts as the **in-system quality
gate** that complements the offline `/sap-check-abap` static checker. The
customer brief's `MAX_PRIORITY` controls which findings block deployment
(priority 1 = critical, 2 = high, 3 = medium, 4 = low; lower = worse).

## Skill Overview

1. Parse: object type + object name + optional check variant + optional
   `MAX_PRIORITY` override
2. Route by object type to the appropriate SCI scope
   (PROGRAM / CLASS / FUGR / FM / INTERFACE / PACKAGE)
3. Run the check variant (default reads `MAX_PRIORITY` from `customer_brief.md`)
4. Read findings from the ALV grid and write to
   `<OBJECT_NAME>.atc.tsv` in the work folder
5. Apply the gate: any finding with `priority ≤ MAX_PRIORITY` blocks
   deployment; rest are reported as warnings

## Auto-Trigger Keywords

- `atc <name>`, `code inspector <name>`, `quality gate <name>`
- `run atc on report ZHK*`, `check program ZHK* with sci`
- `atc package ZHK_*`

## Usage

```text
/sap-atc PROGRAM ZHKR001
/sap-atc PROGRAM ZHKR001 STANDARD
/sap-atc PROGRAM ZHKR001 STANDARD 2
/sap-atc CLASS   ZCL_HK_UTIL
/sap-atc PACKAGE ZHK_MM
```

Conversational forms:

- "Run ATC on program ZHKR001"
- "Quality-gate ZCL_HK_UTIL — block on priority 2 or worse"
- "Check the whole package ZHK_MM"

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- `RZ11` parameter `sapgui/user_scripting` set to TRUE on the SAP server
- Customer brief at `{custom_url}\customer_brief.md` (or shared default)
  — the `MAX_PRIORITY` field is the gate threshold

## One-time setup

This skill ships with **default** SCI screen IDs observed on S/4HANA 1909.
Run a one-off Scripting Recorder pass against transaction SCI in your target
system and update any constants in
`references/sap_atc_run.vbs` whose IDs differ. SKILL.md documents the
recording steps.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
