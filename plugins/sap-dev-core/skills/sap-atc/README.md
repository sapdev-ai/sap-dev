# SAP ATC / Code Inspector Quality Gate Skill

Runs the SAP ABAP Test Cockpit (ATC) end-to-end against an SAP repository
object via SAP GUI Scripting — SCI Object Set → ATC Run Series → Run Monitor
→ Manage Results — and gates on the Priority 1 / 2 / 3 finding counts. Acts
as the **in-system quality gate** that complements the offline
`/sap-check-abap` static checker. The customer brief's `MAX_PRIORITY`
controls which findings block deployment (priority 1 = critical, 2 = high,
3 = medium, 4 = low; lower = worse).

## Skill Overview

1. Parse: object type + object name (or an `--object-list=<file>` batch) +
   optional `--variant=<NAME>` + optional `--max-priority=<n>` override
   (default reads `MAX_PRIORITY` from `customer_brief.md`)
2. Build an SCI Object Set scoped to the target(s) — PROGRAM / CLASS /
   INTERFACE / FUGR / DDIC / TYPEGROUP / WDYN; `FM` is rejected (SCI has no
   per-FM category — pass `FUGR <function-group-name>` instead)
3. Create + execute an ATC Run Series bound to that set, then poll the ATC
   Run Monitor until the run completes
4. Read the Priority 1 / 2 / 3 counts from Manage Results (best-effort
   result-TXT download; on FAIL or `--drill`, export the per-finding ALV as
   `<save-to>.findings.tsv`)
5. Apply the gate: emit `PRIORITY_COUNTS:` + `GATE_VERDICT: PASS|FAIL` — FAIL
   when any priority ≤ `MAX_PRIORITY` has findings; plan errors
   (`COUNT_PLNERR` > 0 → `ATC_PLAN_ERRORS`) and unverified 0/0/0 results
   (`ATC_EMPTY_SCOPE`) never PASS

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

## Re-recording on other releases (no one-time setup)

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
