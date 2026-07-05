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
/sap-atc PROGRAM ZHKR001 --variant=S4HANA_READINESS
/sap-atc PROGRAM ZHKR001 --variant=S4HANA_READINESS --max-priority=2
/sap-atc CLASS   ZCL_HK_UTIL
/sap-atc FUGR    ZHK_MM_FG
```

The check variant is now the named flag **`--variant=<NAME>`** (the old
positional `[CHECK_VARIANT]` is gone). Omit it to run the system default
variant; pass `--variant=S4HANA_READINESS` for an S/4HANA-conversion readiness
check (the connected system must offer that GLOBAL variant with the
Simplification Database loaded). See `SKILL.md` for the full flag list.

Conversational forms:

- "Run ATC on program ZHKR001"
- "Run the S/4HANA readiness check on ZHKR001"
- "Quality-gate ZCL_HK_UTIL — block on priority 2 or worse"

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- `RZ11` parameter `sapgui/user_scripting` set to TRUE on the SAP server
- Customer brief at `{custom_url}\customer_brief.md` (or shared default)
  — the `MAX_PRIORITY` field is the gate threshold

## One-time setup

This skill drives a four-stage flow — SCI Object Set → ATC Run Series → Run
Monitor → Manage Results — across four VBS references
(`sap_sci_create_object_set.vbs`, `sap_atc_create_run_series.vbs`,
`sap_atc_check_run_status.vbs`, `sap_atc_get_results.vbs`), with default tree
node + grid IDs observed on S/4HANA 1909. On a different release, re-record the
affected stage via `/sap-gui-probe --record` and patch that VBS — see SKILL.md
"Recording references".

**Check-variant field:** when you first use `--variant=` on a live system, the
run-series config screen's check-variant field id may differ from the built-in
candidate list. Stage 2 fails loud if it cannot locate the field; record the
config screen and add the real id to `chkvCands` in
`sap_atc_create_run_series.vbs` (SKILL.md "Component IDs" documents the
candidates).

## Version

- Skill Version: 1.1.0
- Last Updated: 2026-06-03

## License

GPL-3.0 License - See LICENSE file in repository root.
