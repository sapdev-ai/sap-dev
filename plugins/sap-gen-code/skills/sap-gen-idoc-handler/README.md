# SAP Generate IDoc Handler Skill

Generates a **correct inbound IDoc processing function module** from two
machine-readable inputs — the IDoc type's segment metadata (read live via
`IDOCTYPE_READ_COMPLETE`) and a field-mapping spec — plus a golden template
that encodes the trap-rich inbound protocol once: the fixed
EDIDC/EDIDD/BDIDOCSTAT/BDWFRETVAR signature WE57 demands, the per-DOCNUM
packet loop (the classic mass-processing trap), typed segment decode, the
53(ok)/51(error) status-record-per-IDoc protocol, RETURN_VARIABLES, and BAL
application-log hooks. A seeded ABAP Unit test proves status 53 on the happy
path before anything is wired.

## Skill Overview

Two modes:

- **`generate`** — read the segment tree, cross-check every mapping-spec
  segment against it (a spec segment not in the tree is a hard error), resolve
  segment structures + the target BAPI signature, fill the golden handler and
  test templates, gate offline via `/sap-check-abap`, then (Rule-2-gated,
  confirm first) deploy through `/sap-function-group` → `/sap-se37` (FM) →
  `/sap-se38` (test report) and verify via `/sap-run-abap-unit`. The
  WE57/BD51/WE42/WE20 wiring is emitted as **numbered operator instructions**
  — never auto-written (those are SAP-standard config tables).
- **`verify-wiring`** — read-only RFC check of EDIFCT / TBD51 / TEDE2 / EDP21
  reporting PRESENT / MISSING / COULD_NOT_CHECK per expected row plus a
  WIRED / PARTIAL / UNWIRED verdict. A read that errors is COULD_NOT_CHECK,
  never a false PRESENT.

One golden template serves ECC 6 and S/4 (ABAP release level from the
customer brief). The generated FM is the deliverable — no extra Z helper
objects are created.

## Auto-Trigger Keywords

- `generate idoc handler`, `inbound IDoc function module for MATMAS...`
- `check idoc wiring`, `is Z_IDOC_INPUT_X wired in WE57`

## Usage

```text
/sap-gen-idoc-handler generate <mapping.tsv> --idoctype <BASICTYPE> [--message-type <MESTYP>] [--fm-name Z_IDOC_INPUT_X] [--fugr FG] [--bapi BAPI] [--deploy ask|yes|no]
/sap-gen-idoc-handler verify-wiring <FM> --idoctype <BT> --message-type <MT> [--process-code PC] [--partner P --partner-type LS|KU|LI]
```

Conversational forms:

- "Generate an inbound IDoc handler for MATMAS05 from this mapping spec"
- "Is Z_IDOC_INPUT_ORDERS wired for ORDERS05 / message type ORDERS?"

The mapping-spec input shape is `references/idoc_mapping_template.tsv`
(segment, field, target, rule, sample_value).

## Key Files

| File | Purpose |
|---|---|
| `references/sap_idoc_type_read.ps1` | Segment-tree metadata via `IDOCTYPE_READ_COMPLETE` |
| `references/sap_idoc_wiring_check.ps1` | verify-wiring RFC read (EDIFCT/TBD51/TEDE2/EDP21) |
| `references/idoc_inbound_handler_template.abap` | Golden handler (fixed signature + packet loop + 53/51 protocol) |
| `references/idoc_inbound_test_template.abap` | Seeded ABAP Unit test (canned EDIDD) |
| `references/idoc_mapping_template.tsv` | Mapping-spec input shape |

## Prerequisites

- Pinned RFC profile via `/sap-login`; SAP NCo 3.1 (32-bit) in GAC
- An active SAP GUI session only for the (gated) deploy step
- A mapping spec in the template's TSV shape

## Suggested next steps

- Work through the emitted `<name>_wiring_instructions.md` (WE57 / BD51 /
  WE42 / WE20) in SAP, then re-run `verify-wiring` until WIRED
- `/sap-run-abap-unit Z<FM_STEM>_TEST` — re-run the seeded test standalone
- `/sap-idoc` (sap-project) — monitor real inbound IDocs once wired

## Limitations

- **v1 = inbound only.** `generate --outbound` and an automated `wire` mode
  are deferred (the latter needs a writable API for EDIFCT/TEDE2 — open
  question).
- The SAP-standard wiring tables are **never auto-written** — the skill emits
  operator instructions plus a read-only check only.
- Honesty invariants: unknown IDoc type → `IDOC_TYPE_NOT_FOUND`; a spec
  segment missing from the tree → hard error; a failed wiring read →
  COULD_NOT_CHECK; deploy declined → SKIPPED with the sources left on disk.
- Live-verified on S/4HANA 1909 (MATMAS05: 28 segments, 7 mandatory; wiring
  checker verified against real and fake FMs). The deploy leg is confirm-gated
  and delegated, not run autonomously. CIMTYP extension types are untested
  (needs a live extension type).

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
